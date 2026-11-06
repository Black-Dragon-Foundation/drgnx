;;; drgnx-affected.el --- bin/drgnx test --affected: the test groups a git range can affect, and a result cache -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx test --affected A..B [--run] [--no-cache]' reads the files the range changes, maps each to the test groups it
;; can affect with the table in test/affected.eld (first matching row wins; a path no row names runs everything), and
;; prints the groups with the reasons, or with --run runs them.  A group whose input files (the table's) are unchanged
;; since its last green run, on the same Emacs build and toolchain, is skipped; a red run is never recorded.
;; See docs/develop/testing.md, "Running only what a change affects".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-guard)

;;;; The map

(defun drgnx-affected-map (root)
  "The map of ROOT's test/affected.eld, as a plist."
  (let ((r (drgnx-file-read (expand-file-name "test/affected.eld" root))))
    (or (and (eq (plist-get r :status) 'ok) (plist-get r :data))
        (error "test/affected.eld: %s" (or (plist-get r :problem) (plist-get r :status))))))

(defun drgnx-affected--glob-match-p (glob path)
  "Non-nil when PATH matches GLOB (`*' matches across `/')."
  (string-match-p (concat "\\`" (mapconcat #'regexp-quote (split-string glob "\\*") ".*") "\\'") path))

(defun drgnx-affected--row (map path)
  "The first rule of MAP whose glob matches PATH, or nil."
  (seq-find (lambda (row) (drgnx-affected--glob-match-p (car row) path)) (plist-get map :rules)))

;;;; Groups

(defun drgnx-affected--group (map kind &rest args)
  "A group of KIND from MAP's :kinds; ARGS: :file, :crate, :name (its id suffix) and :inputs (extra patterns)."
  (let* ((spec (cdr (assq kind (plist-get map :kinds))))
         (name (plist-get args :name))
         (sub (lambda (s)
                (replace-regexp-in-string
                 "%[fng]" (lambda (m) (pcase m ("%f" (or (plist-get args :file) "")) ("%n" (or (plist-get args :crate) ""))
                                             ("%g" (or (plist-get args :name) "*"))))
                 s t t))))
    (list :id (if name (format "%s:%s" kind name) (symbol-name kind))
          :kind kind
          :dir (plist-get spec :dir)
          :run (mapcar sub (plist-get spec :run))
          :inputs (append (apply #'append
                                 (mapcar (lambda (p) (if (eq p 'lisp) (plist-get map :lisp-inputs) (list p)))
                                         (plist-get spec :inputs)))
                          (plist-get args :inputs)))))

;;;; The workspace

(defun drgnx-affected-crates (root)
  "The workspace's crates under ROOT as (NAME DIR DEPS): DIR relative to ROOT, DEPS the names of the workspace crates it
depends on (any kind).  `cargo metadata --no-deps' reads the manifests (DRGNX_AFFECTED_METADATA: a saved answer).
:unavailable when there is none."
  (let* ((saved (getenv "DRGNX_AFFECTED_METADATA"))
         (json (with-temp-buffer
                 (cond (saved (ignore-errors (insert-file-contents saved) (buffer-string)))
                       ((executable-find "cargo")
                        (let ((default-directory (file-name-as-directory root)))
                          (when (eq 0 (call-process "cargo" nil (list (current-buffer) nil) nil "metadata" "--no-deps"
                                                    "--format-version" "1" "--offline"
                                                    "--manifest-path" "runtime/Cargo.toml"))
                            (buffer-string))))))))
    (if (not (and json (not (string-empty-p json))))
        :unavailable
      (let* ((pkgs (append (gethash "packages" (json-parse-string json)) nil))
             (names (mapcar (lambda (p) (gethash "name" p)) pkgs)))
        (mapcar (lambda (p)
                  (list (gethash "name" p)
                        (file-relative-name (file-name-directory (gethash "manifest_path" p)) (expand-file-name root))
                        (seq-filter (lambda (d) (member d names))
                                    (delete-dups (mapcar (lambda (d) (gethash "name" d))
                                                         (seq-filter (lambda (d) (gethash "path" d))
                                                                     (append (gethash "dependencies" p) nil)))))))
                pkgs)))))

(defun drgnx-affected--crate-of (crates path)
  "The name of the crate in CRATES whose directory holds PATH (the deepest), or nil."
  (let (best)
    (dolist (c crates)
      (let ((dir (file-name-as-directory (file-name-as-directory (nth 1 c)))))
        (when (and (string-prefix-p dir path) (> (length dir) (length (or (nth 1 best) ""))))
          (setq best c))))
    (car best)))

(defun drgnx-affected--dependents (crates names)
  "NAMES and every crate of CRATES that depends on one of them, directly or not."
  (let ((seen (copy-sequence names)) (grew t))
    (while grew
      (setq grew nil)
      (dolist (c crates)
        (when (and (not (member (car c) seen)) (seq-some (lambda (d) (member d seen)) (nth 2 c)))
          (push (car c) seen) (setq grew t))))
    seen))

(defun drgnx-affected--crate-dirs (crates name)
  "The directories of crate NAME and of the workspace crates it depends on, in CRATES."
  (let ((todo (list name)) done)
    (while todo
      (let ((n (pop todo)))
        (unless (member n done)
          (push n done)
          (setq todo (append (nth 2 (assoc n crates)) todo)))))
    (mapcar (lambda (n) (concat (file-name-as-directory (nth 1 (assoc n crates))) "**")) done)))

;;;; The plan

(defun drgnx-affected--file-text (cache root file)
  (or (gethash file cache)
      (puthash file (with-temp-buffer
                      (ignore-errors (insert-file-contents (expand-file-name file root)))
                      (buffer-string))
               cache)))

(defun drgnx-affected--names (map root cache file)
  "The unit test files that name the feature of FILE (its file name): a `require', or its symbols as a test's prefix."
  (let* ((feature (file-name-sans-extension (file-name-nondirectory file)))
         (re (concat (regexp-quote feature) "\\(?:[^-[:alnum:]]\\|\\'\\)"))
         (dir (plist-get map :test-dir)))
    (seq-filter (lambda (test) (string-match-p re (drgnx-affected--file-text cache root test)))
                (mapcar (lambda (f) (concat (file-name-as-directory dir) f))
                        (directory-files (expand-file-name dir root) nil "-test\\.el\\'")))))

(defun drgnx-affected--test-file-p (f)
  (string-match-p "\\`test/unit/[^/]+-test\\.el\\'" f))

(cl-defun drgnx-affected-plan (root files &key map crates)
  "The groups a change to FILES (relative to ROOT) can affect, as (:groups G… :why STRING…).
MAP: the table (default ROOT's); CRATES: the workspace as `drgnx-affected-crates' returns it, or a function giving it."
  (let* ((map (or map (drgnx-affected-map root)))
         (groups nil) (why nil) (everything nil) (unit nil)
         (texts (make-hash-table :test 'equal))
         (crate-list 'unset)
         (noted nil)
         (hits (make-hash-table :test 'equal)))
    (cl-labels
        ((add (g) (unless (assoc (plist-get g :id) groups) (push (cons (plist-get g :id) g) groups)))
         (note (fmt &rest a) (push (apply #'format fmt a) why))
         (crates () (when (eq crate-list 'unset)
                      (setq crate-list (if (functionp crates) (funcall crates) crates)))
           crate-list)
         (rust (names reason)
           ;; the crates, their dependents, and the conformance rows when the hub or the harness is among them
           (let ((all (drgnx-affected--dependents (crates) names)))
             (dolist (n all)
               (add (drgnx-affected--group map 'rust :name n :crate n
                                           :inputs (drgnx-affected--crate-dirs (crates) n))))
             (when (or (member "drgnx-ratatoskr" all) (member "domr" all)) (add (drgnx-affected--group map 'domr)))
             (note "%s: %s" reason (string-join (reverse all) " "))))
         (act (a file row)
           (pcase a
             ('everything (setq everything t))
             ('none nil)
             ('unit (setq unit t))
             ('rules (add (drgnx-affected--group map 'rules)))
             ('self (when (drgnx-affected--test-file-p file)
                      (add (drgnx-affected--group map 'lisp :name file :file file :inputs (list file)))))
             ('names
              (let ((tests (drgnx-affected--names map root texts file)))
                (if tests
                    (dolist (tf tests)
                      (add (drgnx-affected--group map 'lisp :name tf :file tf :inputs (list tf))))
                  (setq unit t)
                  (note "%s: no unit test names %s: the whole unit suite" file
                        (file-name-sans-extension (file-name-nondirectory file))))))
             (`(docs . ,tests)
              (dolist (tf tests)
                (add (drgnx-affected--group map 'docs :name tf :file tf :inputs (list tf)))))
             (`(rust ,crate)
              (if (eq (crates) :unavailable)
                  (progn (add (drgnx-affected--group map 'rust-workspace))
                         (note "%s: cargo metadata is unavailable: the whole workspace" file))
                ;; said once, for the first file: every Lisp file under core/ and modules/ asks for the same crate
                (unless (memq crate noted)
                  (push crate noted)
                  (rust (list (format "%s" crate))
                        (format "%s (and every other core/ or modules/ file) is read by crate %s: it and its dependents"
                                file crate)))))
             ('rust-path
              (let* ((cs (crates))
                     (c (and (listp cs) (drgnx-affected--crate-of cs file))))
                (cond ((eq cs :unavailable)
                       (add (drgnx-affected--group map 'rust-workspace))
                       (note "%s: cargo metadata is unavailable: the whole workspace" file))
                      (c (puthash c t hits))
                      (t (setq everything t)
                         (note "%s: sits in no workspace crate: everything" file)))))
             ('rust-workspace (add (drgnx-affected--group map 'rust-workspace)))
             ('rust-rules (add (drgnx-affected--group map 'rust-rules)))
             ('domr (add (drgnx-affected--group map 'domr)))
             ('domr-path
              (if (string-match "\\`test/conformance/\\([^/]+\\)/" file)
                  (add (drgnx-affected--group map 'domr :name (match-string 1 file)
                                              :inputs (list (format "test/conformance/%s/**" (match-string 1 file)))))
                (add (drgnx-affected--group map 'domr))))
             ((or 'ui 'scenario 'tty 'perf) (add (drgnx-affected--group map a)))
             (_ (error "affected.eld: unknown action %S in the row for %s" a (car row))))))
      (dolist (file files)
        (let ((row (drgnx-affected--row map file)))
          (if (null row)
              (progn (setq everything t)
                     (note "%s: no row in test/affected.eld names it: everything" file))
            (dolist (a (cdr row)) (act a file row)))))
      (when (> (hash-table-count hits) 0)
        (let ((names (hash-table-keys hits)))
          (rust names (format "changed crates %s: their dependents" (string-join (sort (copy-sequence names) #'string<) " ")))))
      (setq groups (nreverse (mapcar #'cdr groups)))
      (cond
       (everything
        (setq groups (mapcar (lambda (k) (drgnx-affected--group map k)) (plist-get map :everything))))
       (unit
        ;; the whole suite includes every unit file and docs check
        (setq groups (cons (drgnx-affected--group map 'unit)
                           (seq-remove (lambda (g) (memq (plist-get g :kind) '(lisp docs rules))) groups)))))
      ;; rust-workspace includes every crate
      (when (seq-find (lambda (g) (eq (plist-get g :kind) 'rust-workspace)) groups)
        (setq groups (seq-remove (lambda (g) (eq (plist-get g :kind) 'rust)) groups)))
      ;; the whole conformance run includes each group
      (when (seq-find (lambda (g) (equal (plist-get g :id) "domr")) groups)
        (setq groups (seq-remove (lambda (g) (string-prefix-p "domr:" (plist-get g :id))) groups)))
      (list :groups groups :why (nreverse why)))))

;;;; The cache

(defun drgnx-affected-cache-dir ()
  "The directory of the cache: DRGNX_AFFECTED_CACHE, else $XDG_CACHE_HOME/drgnx/affected, else ~/.cache/drgnx/affected.
Never inside a checkout."
  (file-name-as-directory
   (or (getenv "DRGNX_AFFECTED_CACHE")
       (expand-file-name "drgnx/affected" (or (getenv "XDG_CACHE_HOME") (expand-file-name ".cache" (getenv "HOME")))))))

(defun drgnx-affected-stamp ()
  "The Emacs build and the Rust toolchain, as one string: part of every cache key."
  (let ((tool (lambda (prog &rest args)
                (or (and (executable-find prog)
                         (with-temp-buffer
                           (when (eq 0 (apply #'call-process prog nil t nil args))
                             (string-trim (buffer-string)))))
                    "none"))))
    (string-join (list (replace-regexp-in-string "\n" " " (emacs-version))
                       (funcall tool "rustc" "--version") (funcall tool "cargo" "--version"))
                 "\n")))

(defconst drgnx-affected--skip-dirs '(".git" ".claude" "target" "node_modules")
  "Directories an input pattern never reads.")

(defun drgnx-affected--input-files (root pattern)
  "The files under ROOT that PATTERN names: `DIR/**' (all below), `DIR/*.ext' (one directory), or a file."
  (cond
   ((string-suffix-p "/**" pattern)
    (let ((dir (expand-file-name (substring pattern 0 -3) root)))
      (when (file-directory-p dir)
        (seq-remove (lambda (f)
                      (or (string-match-p "\\.\\(?:elc\\|eln\\)\\'" f)
                          (seq-some (lambda (d) (string-match-p (format "/%s/" (regexp-quote d)) f))
                                    drgnx-affected--skip-dirs)))
                    (directory-files-recursively dir "" nil
                                                 (lambda (d) (not (member (file-name-nondirectory d) drgnx-affected--skip-dirs))))))))
   ((string-match-p "\\*" pattern)
    (let ((dir (expand-file-name (or (file-name-directory pattern) "") root)))
      (when (file-directory-p dir)
        (directory-files dir t (concat "\\`" (mapconcat #'regexp-quote (split-string (file-name-nondirectory pattern) "\\*") ".*") "\\'")))))
   (t (let ((f (expand-file-name pattern root))) (and (file-regular-p f) (list f))))))

(defun drgnx-affected-key (root group stamp)
  "The cache key of GROUP: a hash of its id, its command, STAMP and the contents of its input files under ROOT."
  (let ((files (sort (delete-dups (apply #'append (mapcar (lambda (p) (drgnx-affected--input-files root p))
                                                          (plist-get group :inputs))))
                     #'string<))
        (parts (list (plist-get group :id) (string-join (plist-get group :run) " ") stamp)))
    (dolist (f files)
      (push (format "%s %s" (file-relative-name f root)
                    (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally f)
                                      (secure-hash 'sha256 (current-buffer))))
            parts))
    (secure-hash 'sha256 (string-join (nreverse parts) "\n"))))

;;;; Running

(defun drgnx-affected--command (group)
  "GROUP's argv, behind DRGNX_AFFECTED_WRAP (words) when set."
  (append (when-let* ((w (getenv "DRGNX_AFFECTED_WRAP"))) (split-string w))
          (plist-get group :run)))

(defun drgnx-affected--exec (root group)
  "Run GROUP in ROOT, its output to `standard-output'; its exit code (2: refused)."
  (let ((default-directory (file-name-as-directory (expand-file-name (or (plist-get group :dir) ".") root)))
        (argv (drgnx-affected--command group)))
    (if (and (memq (plist-get group :kind) '(rust rust-workspace rust-rules domr))
             (not (getenv "DRGNX_AFFECTED_WRAP")))
        (progn (princ (format "affected: %s runs cargo, never on the host: set DRGNX_AFFECTED_WRAP to the container wrapper\n"
                              (plist-get group :id)))
               2)
      (let ((p (make-process :name "affected" :command argv :connection-type 'pipe :noquery t
                             :filter (drgnx-guard-wrap (lambda (_p s) (princ s)) "affected output")
                             :sentinel (drgnx-guard-wrap #'ignore "affected end"))))
        (while (process-live-p p) (accept-process-output p 0.2))
        (while (accept-process-output p 0.05))
        (process-exit-status p)))))

(defun drgnx-affected-run (root groups &rest args)
  "Run GROUPS (as `drgnx-affected-plan' returns them) in ROOT, skipping each whose key is in the cache; a group's
result is recorded only when it is green.  ARGS: :cache-dir, :no-cache, :runner (a function of the group giving its
exit code), :stamp.  Returns ((ID . green|red|cached)…); every group runs, whatever an earlier one said."
  (let* ((cache (or (plist-get args :cache-dir) (drgnx-affected-cache-dir)))
         (stamp (or (plist-get args :stamp) (drgnx-affected-stamp)))
         (runner (or (plist-get args :runner) (lambda (g) (drgnx-affected--exec root g))))
         result)
    (dolist (g groups)
      (let* ((id (plist-get g :id))
             (key (drgnx-affected-key root g stamp))
             (entry (expand-file-name key cache)))
        (if (and (not (plist-get args :no-cache)) (file-exists-p entry))
            (progn (princ (format "affected: skipped %s: inputs unchanged since its last green run\n" id))
                   (push (cons id 'cached) result))
          (princ (format "affected: running %s\n" id))
          (let ((rc (funcall runner g)))
            (if (eql rc 0)
                (progn (make-directory cache t)
                       (drgnx-file-write-text entry (format "%s\n" id))
                       (push (cons id 'green) result))
              (push (cons id 'red) result))))))
    (nreverse result)))

;;;; The command line

(defun drgnx-affected--changed-files (root range)
  "The paths RANGE (A..B) changes in ROOT's repository (a rename counts both its paths), or an error."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory root)))
      (unless (eq 0 (call-process "git" nil (list (current-buffer) nil) nil "diff" "--name-only" "-z" "--no-renames" range "--"))
        (error "git diff %s failed" range))
      (split-string (buffer-string) "\0" t))))

(defconst drgnx-affected--usage "usage: drgnx test --affected A..B [--run] [--no-cache]")

(defun drgnx-affected-cli-run (args)
  "`drgnx test --affected A..B [--run] [--no-cache]'; the exit code (2: bad arguments)."
  (let (range run no-cache bad)
    (dolist (a args)
      (cond ((equal a "--run") (setq run t))
            ((equal a "--no-cache") (setq no-cache t))
            ((and (null range) (string-match-p "\\`[[:alnum:]._~^@{}/][[:alnum:]._~^@{}/-]*\\.\\.\\.?[[:alnum:]._~^@{}/-]+\\'" a))
             (setq range a))
            (t (setq bad t))))
    (cond
     ((or bad (null range)) (princ (concat drgnx-affected--usage "\n")) 2)
     ((and no-cache (not run)) (princ "drgnx test --affected: --no-cache goes with --run\n") 2)
     (t
      (let* ((root (directory-file-name drgnx-dir))
             (files (drgnx-affected--changed-files root range))
             (plan (drgnx-affected-plan root files :crates (lambda () (drgnx-affected-crates root))))
             (groups (plist-get plan :groups)))
        (princ (format "affected %s: %d files changed, %d groups\n" range (length files) (length groups)))
        (dolist (w (plist-get plan :why)) (princ (format "why: %s\n" w)))
        (when (and files (null groups)) (princ "why: nothing the changed files can affect needs a test\n"))
        (if (not run)
            (progn (dolist (g groups)
                     (princ (format "%-44s %s\n" (plist-get g :id) (string-join (plist-get g :run) " "))))
                   0)
          (let ((results (drgnx-affected-run root groups :no-cache no-cache)))
            (princ "affected: result\n")
            (dolist (r results) (princ (format "  %-44s %s\n" (car r) (pcase (cdr r) ('cached "skipped (cached green)") (s s)))))
            (if (seq-every-p (lambda (r) (memq (cdr r) '(green cached))) results) 0 1))))))))

(defun drgnx-affected-cli ()
  "bin/drgnx test --affected: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (drgnx-affected-cli-run args))))

(provide 'drgnx-affected)
;;; drgnx-affected.el ends here
