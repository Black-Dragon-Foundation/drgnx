;;; drgnx-packs.el --- Language packs: manifests, the lock's packs and grammars, the pack job, active.eld -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A language pack is a folder with a manifest, `pack.eld' (docs/develop/packs.md).  The packs drgnx ships are in its
;; `packs/' folder; the lock (drgnx.lock.eld) records the installed ones under `:packs' and the grammars built for them
;; under `:grammars'.  `drgnx packs sync' hands the grammars to `ratatoskr packs sync --plan' (fetch at the pinned
;; commit, check the tree hash, build, load-check in a child process), writes the lock, makes a generation, and only
;; then moves the built folders into `<data>/grammars/LANG/COMMIT/' and writes `<state>/packs/active.eld', the file
;; the `lang/packs' module reads at startup.  A failure before the lock write changes nothing.  `drgnx rollback' brings
;; back the lock and derives `active.eld' from it.  Nothing here prompts.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-pkg)

(define-error 'drgnx-packs-error "Language pack error")

(defconst drgnx-packs-min-abi 14
  "The lowest tree-sitter ABI a grammar may report.  The modes' pins are ABI 14 parsers (Rust's is 15), which every
libtree-sitter from 0.22 to 0.26 loads.")

(defvar drgnx-packs-dir nil "Test seam: the folder of built-in packs, when not `packs/' in drgnx's checkout.")

(defvar drgnx-packs--manifests nil
  "Alist FOLDER → ((NAME . MANIFEST)…): the packs read from each folder (drgnx's own, a test's).  One entry per folder
read and cleared by `drgnx-packs-forget', so it holds a handful of small plists.")

(defvar drgnx-packs-job-function #'drgnx-packs--run-job
  "Runs the pack job: called with the plan (a plist), returns the job's answer plist `(:ok t :staged …)' or
`(:ok nil :error TEXT)'.  Tests replace it.")

(defvar drgnx-packs-translate-function #'drgnx-packs--run-translate
  "Writes the generic mode's queries for a pack: called with the pack's folder and the file to write, signals
`drgnx-packs-error' naming what is refused.  Tests replace it.")

(defvar drgnx-packs-install-packages-function #'drgnx-packs--install-packages
  "Installs the Emacs packages a pack requires: called with their names (symbols) before the pack job runs; a failure
signals `drgnx-packs-error' and nothing of the packs changes.  Tests replace it.")

(defun drgnx-packs--error (fmt &rest args) (signal 'drgnx-packs-error (list (apply #'format fmt args))))

;;;; Where things are

(defun drgnx-packs-builtin-dir () (file-name-as-directory (or drgnx-packs-dir (expand-file-name "packs" drgnx-dir))))
(defun drgnx-packs-grammars-dir () (expand-file-name "grammars/" (drgnx-data-dir)))
(defun drgnx-packs-grammar-dir (lang commit)
  "Where LANG's grammar built from COMMIT lives: `<data>/grammars/LANG/COMMIT/' (content-addressed, never rewritten)."
  (expand-file-name (format "%s/%s/" lang commit) (drgnx-packs-grammars-dir)))
(defun drgnx-packs-staging-dir () (expand-file-name "packs-staging/" (drgnx-state-dir)))
(defun drgnx-packs-active-file () (expand-file-name "packs/active.eld" (drgnx-state-dir)))
(defun drgnx-packs-in-use-dir () (expand-file-name "packs-in-use/" (drgnx-state-dir)))

;;;; Manifests

(defun drgnx-packs-read-manifest (file)
  "The manifest in FILE, read as data (nothing is evaluated): a plist with `:pack' and `:schema' 1."
  (let ((data (with-temp-buffer
                (insert-file-contents file)
                (let ((read-circle nil) (read-eval nil))
                  (condition-case err (read (current-buffer))
                    (error (drgnx-packs--error "%s: %s" file (error-message-string err))))))))
    (unless (and (consp data) (keywordp (car data)) (stringp (plist-get data :pack)))
      (drgnx-packs--error "%s is not a pack manifest" file))
    (unless (eql (plist-get data :schema) 1)
      (drgnx-packs--error "%s: manifest format %S is not one this drgnx reads (1)" file (plist-get data :schema)))
    data))

(defun drgnx-packs-forget () "Forget the packs read so far (a folder's contents changed)." (setq drgnx-packs--manifests nil))

(defun drgnx-packs-builtins ()
  "The built-in packs, ((NAME . MANIFEST)…) sorted by name.  A pack that does not read is an error naming it: a
shipped pack that is broken is a bug, never skipped."
  (let ((dir (drgnx-packs-builtin-dir)))
    (or (cdr (assoc dir drgnx-packs--manifests))
        (let ((packs (mapcar (lambda (d)
                               (let ((m (drgnx-packs-read-manifest (expand-file-name "pack.eld" d))))
                                 (unless (equal (plist-get m :pack) (file-name-nondirectory (directory-file-name d)))
                                   (drgnx-packs--error "%s names the pack %s" d (plist-get m :pack)))
                                 (cons (plist-get m :pack) m)))
                             (seq-filter (lambda (d) (file-exists-p (expand-file-name "pack.eld" d)))
                                         (and (file-directory-p dir) (directory-files dir t "\\`[^.]"))))))
          (setq packs (sort packs (lambda (a b) (string< (car a) (car b)))))
          (push (cons dir packs) drgnx-packs--manifests)
          packs))))

(defun drgnx-packs-manifest (name)
  "The manifest of the built-in pack NAME (a string or symbol), or nil."
  (cdr (assoc (format "%s" name) (drgnx-packs-builtins))))

(defun drgnx-packs-tree-hash (dir)
  "The tree hash of DIR (docs/develop/packs.md): sha256 over the sorted lines `MODE PATH sha256(blob)' of its files, a
top-level `.git' left out.  What `ratatoskr packs pin' prints, and a built-in pack's `:commit'."
  (let (lines (root (file-name-as-directory (expand-file-name dir))))
    (dolist (f (directory-files-recursively root "" nil (lambda (d) (not (equal (file-name-nondirectory d) ".git")))))
      (let ((rel (file-relative-name f root)))
        (unless (string-prefix-p ".git/" rel)
          (when (file-symlink-p f) (drgnx-packs--error "%s is a symlink" f))
          (push (cons rel (format "%s %s %s" (if (zerop (logand (file-modes f) #o111)) "100644" "100755") rel
                                  (with-temp-buffer
                                    (set-buffer-multibyte nil)
                                    (insert-file-contents-literally f)
                                    (secure-hash 'sha256 (current-buffer)))))
                lines))))
    (secure-hash 'sha256 (mapconcat (lambda (l) (concat (cdr l) "\n"))
                                    (sort lines (lambda (a b) (string< (car a) (car b)))) ""))))

(defun drgnx-packs--owned-grammars (manifest)
  "The grammars MANIFEST pins itself (not the ones it references from another pack)."
  (seq-filter (lambda (g) (plist-get g :repo)) (plist-get manifest :grammars)))

;;;; The lock

(defun drgnx-packs-locked () "The lock's installed packs, ((NAME :commit … :wanted …)…) (names are symbols)."
       (plist-get (drgnx-pkg--config 'lock) :packs))
(defun drgnx-packs-locked-grammars () "The lock's built grammars, ((LANG :commit … :lib-sha256 …)…)."
       (plist-get (drgnx-pkg--config 'lock) :grammars))

(defun drgnx-packs--write-lock (packs grammars)
  "Make PACKS and GRAMMARS the lock's `:packs' and `:grammars'; every other key and the comments stay."
  (let ((sort-fn (lambda (es) (sort (copy-sequence es) (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b))))))))
    (drgnx-pkg--update-lock
     (lambda (data)
       (let ((data (copy-sequence (or data (list :packages nil)))))
         (setq data (plist-put data :packs (funcall sort-fn packs)))
         (plist-put data :grammars (funcall sort-fn grammars)))))))

(defun drgnx-packs--built-p (lang commit)
  "Whether LANG's library from COMMIT is in its folder."
  (let ((dir (drgnx-packs-grammar-dir lang commit)))
    (seq-some (lambda (suffix) (file-exists-p (expand-file-name (format "libtree-sitter-%s%s" lang suffix) dir)))
              dynamic-library-suffixes)))

;;;; The plan and the job

(defun drgnx-packs--closure (names)
  "NAMES (strings) with every built-in pack their grammars reference (`:from-pack') or `:requires', each once."
  (let (out (todo (copy-sequence names)))
    (while todo
      (let ((n (pop todo)))
        (unless (member n out)
          (unless (drgnx-packs-manifest n) (drgnx-packs--error "no language pack %s" n))
          (push n out)
          (dolist (g (plist-get (drgnx-packs-manifest n) :grammars))
            (when-let* ((o (plist-get g :from-pack))) (push o todo)))
          (dolist (r (plist-get (plist-get (drgnx-packs-manifest n) :requires) :packs)) (push r todo)))))
    (nreverse out)))

(defun drgnx-packs--missing-units (names)
  "The grammars of the packs NAMES that are not built yet: plists (:name :repo :commit :tree-sha256 :src)."
  (let (units)
    (dolist (n names)
      (dolist (g (drgnx-packs--owned-grammars (drgnx-packs-manifest n)))
        (let ((lang (symbol-name (plist-get g :name))))
          (unless (or (drgnx-packs--built-p lang (plist-get g :commit)) (assoc lang units))
            (push (list lang :name lang :repo (plist-get g :repo) :commit (plist-get g :commit)
                        :tree-sha256 (plist-get g :tree-sha256) :src (or (plist-get g :src) "src"))
                  units)))))
    (mapcar #'cdr (nreverse units))))

(defun drgnx-packs--queries (names units)
  "The query files (`queries/*.scm') of the packs NAMES whose main grammar (the first one they pin themselves and
require) is among UNITS: plists (:grammar :file :path), for the job to compile against the grammar it builds."
  (let (out)
    (dolist (n names)
      (let* ((main (seq-find (lambda (g) (plist-get g :required)) (drgnx-packs--owned-grammars (drgnx-packs-manifest n))))
             (dir (expand-file-name (format "%s/queries/" n) (drgnx-packs-builtin-dir))))
        (when (and main (assoc (format "%s" (plist-get main :name)) (mapcar (lambda (u) (cons (plist-get u :name) u)) units))
                   (file-directory-p dir))
          (dolist (f (directory-files dir nil "\\.scm\\'"))
            (push (list :grammar (format "%s" (plist-get main :name)) :file (concat "queries/" f) :path (expand-file-name f dir))
                  out)))))
    (nreverse out)))

(defun drgnx-packs-translated-file (name commit)
  "Where the generic mode's queries of the pack NAME at COMMIT (its tree hash) are kept."
  (expand-file-name (format "packs/translated/%s-%s.eld" name (substring commit 0 12)) (drgnx-state-dir)))

(defun drgnx-packs--install-packages (names)
  "`drgnx sync --add NAMES': the packages the lock lacks, from the archives, as the user's (a pack names them and the
Extensions card lists them)."
  (let ((r (condition-case err (drgnx-pkg-sync :add (mapcar #'list names))
             (drgnx-pkg-error (drgnx-packs--error "installing %s: %s" (mapconcat #'symbol-name names " ") (cadr err))))))
    (unless (plist-get r :ok)
      (drgnx-packs--error "could not install %s" (mapconcat #'symbol-name names " ")))))

(defun drgnx-packs--missing-packages (names)
  "The Emacs packages the packs NAMES require that the lock does not have yet."
  (let (out)
    (dolist (n names)
      (dolist (p (plist-get (plist-get (drgnx-packs-manifest n) :requires) :packages))
        (unless (or (assq p (drgnx-pkg-read-lock)) (memq p out)) (push p out))))
    (nreverse out)))

(defun drgnx-packs--run-translate (dir out)
  "`ratatoskr packs translate DIR OUT'."
  (let ((bin (or (progn (require 'drgnx-hub-client) (drgnx-hub-client-binary))
                 (drgnx-packs--error "Ratatoskr is not built: run `drgnx runtime build'"))))
    (make-directory (file-name-directory out) t)
    (with-temp-buffer
      (unless (eql 0 (call-process bin nil t nil "packs" "translate" (directory-file-name dir) out))
        (drgnx-packs--error "%s" (string-trim (buffer-string)))))))

(defun drgnx-packs--translate (names)
  "Write the generic mode's queries of the generic packs among NAMES, before the lock is written."
  (dolist (n names)
    (when (plist-get (plist-get (drgnx-packs-manifest n) :mode) :generic)
      (let* ((dir (expand-file-name (concat n "/") (drgnx-packs-builtin-dir)))
             (out (drgnx-packs-translated-file n (drgnx-packs-tree-hash dir))))
        (make-directory (file-name-directory out) t)
        (funcall drgnx-packs-translate-function dir out)))))

(defun drgnx-packs--run-job (plan)
  "Run `ratatoskr packs sync' on PLAN (a plist) and return its answer."
  (let* ((bin (or (progn (require 'drgnx-hub-client) (drgnx-hub-client-binary)) (drgnx-packs--error "Ratatoskr is not built: run `drgnx runtime build'")))
         (dir (make-temp-file "drgnx-packs-" t)) (plan-file (expand-file-name "plan.eld" dir))
         (out (expand-file-name "answer.eld" dir)))
    (unwind-protect
        (progn
          (drgnx-file-write-text plan-file (prin1-to-string plan))
          (call-process bin nil nil nil "packs" "sync" "--plan" plan-file "--out" out)
          (if (file-exists-p out)
              (with-temp-buffer (insert-file-contents out) (let ((read-eval nil)) (read (current-buffer))))
            (list :ok nil :error "the pack job gave no answer")))
      (delete-directory dir t))))

;;;; active.eld

(defun drgnx-packs-derive-active ()
  "Write `active.eld' from the lock: each installed pack's manifest and its grammars' folders that exist.  What a
session activates; written only after the lock is (sync, rollback).  Returns its data."
  (let* ((grammars (drgnx-packs-locked-grammars))
         (packs
          (delq nil
                (mapcar
                 (lambda (e)
                   (when-let* ((m (drgnx-packs-manifest (car e))))
                     (list (car e) :manifest (expand-file-name (format "%s/pack.eld" (car e)) (drgnx-packs-builtin-dir))
                           :translated (and (plist-get (plist-get m :mode) :generic)
                                            (drgnx-packs-translated-file (car e) (plist-get (cdr e) :commit)))
                           :grammars
                           (delq nil (mapcar (lambda (g)
                                               (let* ((lang (plist-get g :name))
                                                      (locked (cdr (assq lang grammars)))
                                                      (dir (and locked (drgnx-packs-grammar-dir lang (plist-get locked :commit)))))
                                                 (and dir (drgnx-packs--built-p lang (plist-get locked :commit)) (cons lang dir))))
                                             (plist-get m :grammars))))))
                 (drgnx-packs-locked))))
         (data (list :version 1 :packs packs)))
    (drgnx-file-write (drgnx-packs-active-file) data :header ";; drgnx active language packs — derived from the lock" :pretty t)
    data))

(defun drgnx-packs-active ()
  "The data of `active.eld' (`(:version 1 :packs ((NAME :manifest FILE :grammars ((LANG . DIR)…))…))'), or nil."
  (let ((f (drgnx-packs-active-file)))
    (and (file-exists-p f) (plist-get (ignore-errors (drgnx-file-read f)) :data))))

;;;; Sync

(defun drgnx-packs--lock-entry (name old wanted)
  (let ((hash (drgnx-packs-tree-hash (expand-file-name (concat name "/") (drgnx-packs-builtin-dir)))))
    (list (intern name) :commit hash :tree-sha256 hash :source 'builtin :wanted (or wanted (plist-get (cdr old) :wanted) 'default))))

(cl-defun drgnx-packs-sync (&key add remove (mark 'user))
  "Install the built-in packs ADD and remove REMOVE (names), building the grammars the lock lacks.  The lock, a
generation, the grammar folders and `active.eld' follow, in that order; a failure before the lock write leaves
everything as it was.  Returns (:ok t :packs NAMES :built LANGS :generation N)."
  (drgnx-pkg--with-sync-lock
    (let* ((add (mapcar (lambda (n) (format "%s" n)) add)) (remove (mapcar (lambda (n) (format "%s" n)) remove))
           (locked (drgnx-packs-locked))
           (wanted (drgnx-packs--closure
                    (seq-difference (delete-dups (append (mapcar #'symbol-name (mapcar #'car locked)) add)) remove #'equal)))
           (units (drgnx-packs--missing-units wanted))
           (staging (drgnx-packs-staging-dir)) answer built)
      (unwind-protect (progn
                        (dolist (r remove)                                  ; refused while an installed pack references its grammars
                          (dolist (n wanted)
                            (when (seq-some (lambda (g) (equal (plist-get g :from-pack) r)) (plist-get (drgnx-packs-manifest n) :grammars))
                              (drgnx-packs--error "%s is needed by %s" r n))))
                        (when-let* ((pkgs (drgnx-packs--missing-packages wanted)))
                          (funcall drgnx-packs-install-packages-function pkgs))
                        (when units
                          (when (file-exists-p staging) (delete-directory staging t))
                          (make-directory staging t)
                          (setq answer (funcall drgnx-packs-job-function
                                                (list :version 1 :staging staging :min-abi drgnx-packs-min-abi
                                                      :units units :queries (drgnx-packs--queries wanted units))))
                          (unless (plist-get answer :ok)
                            (when (file-exists-p staging) (delete-directory staging t))
                            (drgnx-packs--error "%s" (or (plist-get answer :error) "the pack job failed"))))
                        (drgnx-packs--translate wanted)   ; the generic mode's queries, before anything is written
                        ;; the lock, then the generation
                        (let* ((staged (plist-get answer :staged))
                               (grammars (seq-filter (lambda (e) (seq-some (lambda (n) (seq-some (lambda (g) (eq (plist-get g :name) (car e)))
                                                                                                 (drgnx-packs--owned-grammars (drgnx-packs-manifest n))))
                                                                           wanted))
                                                     (drgnx-packs-locked-grammars))))
                          (dolist (s staged)
                            (let ((lang (intern (plist-get s :name))))
                              (setq grammars (cons (list lang :commit (plist-get s :commit) :tree-sha256 (plist-get s :tree-sha256)
                                                         :lib-sha256 (plist-get s :lib-sha256)
                                                         :owner (seq-find (lambda (n) (seq-some (lambda (g) (eq (plist-get g :name) lang))
                                                                                                (drgnx-packs--owned-grammars (drgnx-packs-manifest n))))
                                                                          wanted))
                                                   (assq-delete-all lang grammars)))
                              (push (plist-get s :name) built)))
                          (drgnx-packs--write-lock
                           (mapcar (lambda (n) (drgnx-packs--lock-entry n (assq (intern n) locked)
                                                                        (and (member n add) mark)))
                                   wanted)
                           grammars)
                          (let ((generation (drgnx-pkg-snapshot (format "packs %s" (mapconcat #'identity (or add remove '("sync")) " ")))))
                            ;; only now do the built folders go in, and the session's file
                            (dolist (s staged)
                              (let ((dest (directory-file-name (drgnx-packs-grammar-dir (plist-get s :name) (plist-get s :commit))))
                                    (from (file-name-directory (plist-get s :lib))))
                                (unless (file-exists-p dest)
                                  (make-directory (file-name-directory dest) t)
                                  (rename-file (directory-file-name from) dest))))
                            (when (file-exists-p staging) (delete-directory staging t))
                            (drgnx-packs-derive-active)
                            (drgnx-packs-sweep)
                            (list :ok t :packs wanted :built (nreverse built) :generation generation))))
        (when (file-exists-p staging) (delete-directory staging t))))))

(defun drgnx-packs-after-rollback ()
  "A rollback brought back an older lock: `active.eld' is derived from it, and folders nothing names go."
  (drgnx-packs-derive-active)
  (drgnx-packs-sweep))

;;;; The build before packs

(defun drgnx-packs--legacy-dir () (expand-file-name "tree-sitter/" (drgnx-data-dir)))

(defun drgnx-packs-migrate ()
  "The build before packs left grammars in `<data>/tree-sitter/': install the built-in packs that own them (as
`:wanted default'), and drop that folder once every language it holds has a build of its own.  Nothing is lost when
the build fails (no compiler, offline): the folder stays on the load path after the packs'.  Returns the names asked."
  (let* ((dir (drgnx-packs--legacy-dir))
         (langs (and (file-directory-p dir)
                     (delete-dups (delq nil (mapcar (lambda (f) (and (string-match "\\`libtree-sitter-\\(.+\\)\\.[a-z]+\\'" f)
                                                                     (intern (match-string 1 f))))
                                                    (directory-files dir nil "\\`libtree-sitter-"))))))
         (owner (lambda (lang) (car (seq-find (lambda (p) (seq-some (lambda (g) (eq (plist-get g :name) lang))
                                                                    (drgnx-packs--owned-grammars (cdr p))))
                                              (drgnx-packs-builtins)))))
         (names (seq-filter (lambda (n) (not (assq (intern n) (drgnx-packs-locked))))
                            (delete-dups (delq nil (mapcar owner langs))))))
    (when names (drgnx-packs-sync :add names :mark 'default))
    (when (and langs (seq-every-p (lambda (l) (let ((g (cdr (assq l (drgnx-packs-locked-grammars)))))
                                                (and g (drgnx-packs--built-p l (plist-get g :commit)))))
                                  langs))
      (delete-directory dir t))
    names))

;;;; Sweep

(defun drgnx-packs--named-grammars ()
  "The (LANG . COMMIT) pairs the lock, every kept generation's lock and every live session's claim name."
  (let (out)
    (cl-flet ((add (lock-data)
                (dolist (g (plist-get lock-data :grammars))
                  (cl-pushnew (cons (symbol-name (car g)) (plist-get (cdr g) :commit)) out :test #'equal))))
      (add (drgnx-pkg--config 'lock))
      (dolist (g (drgnx-pkg-generations))
        (let ((f (expand-file-name "drgnx.lock.eld" (drgnx-pkg--generation-dir (car g)))))
          (when (file-exists-p f) (add (plist-get (ignore-errors (drgnx-file-read f)) :data))))))
    (dolist (f (and (file-directory-p (drgnx-packs-in-use-dir)) (directory-files (drgnx-packs-in-use-dir) t "\\.eld\\'")))
      (let* ((data (plist-get (ignore-errors (drgnx-file-read f)) :data)) (pid (plist-get data :pid)) (start (plist-get data :start)))
        (if (and (natnump pid) (numberp start) (drgnx-pkg--lock-live-p (format "%d %f" pid start)))
            (dolist (c (plist-get data :grammars)) (cl-pushnew c out :test #'equal))
          (ignore-errors (delete-file f)))))
    out))

(defun drgnx-packs-sweep ()
  "Delete the grammar folders no lock, kept generation or live session names.  Returns the folders deleted."
  (let ((named (drgnx-packs--named-grammars)) deleted)
    (dolist (lang-dir (and (file-directory-p (drgnx-packs-grammars-dir)) (directory-files (drgnx-packs-grammars-dir) t "\\`[^.]")))
      (dolist (commit-dir (directory-files lang-dir t "\\`[^.]"))
        (unless (member (cons (file-name-nondirectory lang-dir) (file-name-nondirectory commit-dir)) named)
          (delete-directory commit-dir t)
          (push commit-dir deleted)))
      (unless (directory-files lang-dir nil "\\`[^.]") (delete-directory lang-dir)))
    deleted))

(defun drgnx-packs-claim (grammars)
  "This session uses GRAMMARS, ((LANG . COMMIT)…): their folders stay while it lives (`drgnx-packs-sweep')."
  (drgnx-file-write (expand-file-name (format "%d.eld" (emacs-pid)) (drgnx-packs-in-use-dir))
                    (list :pid (emacs-pid) :start (float-time (alist-get 'start (process-attributes (emacs-pid))))
                          :grammars grammars)))

;;;; What the formatting module reads

(defconst drgnx-packs-format-config-extra '(".scalafmt.conf")
  "Config files that mean \"this project formats its code\" for languages with no built-in pack (Scala).")

(defun drgnx-packs-format-modes ()
  "Every mode (a symbol) of a built-in pack whose `:format' is `:standard': formatted in any project.  Read from the
manifests, installed or not: formatting needs no grammar."
  (let (out)
    (dolist (p (drgnx-packs-builtins))
      (let ((mode (plist-get (cdr p) :mode)))
        (when (plist-get (plist-get (cdr p) :format) :standard)
          (dolist (m (list (plist-get mode :ts) (plist-get mode :classic))) (when m (cl-pushnew m out))))))
    out))

(defun drgnx-packs-format-config-files ()
  "The files that say a project formats its code: every built-in pack's `:config-files', and the extra list."
  (let ((out (copy-sequence drgnx-packs-format-config-extra)))
    (dolist (p (drgnx-packs-builtins))
      (dolist (f (plist-get (plist-get (cdr p) :format) :config-files)) (cl-pushnew f out :test #'equal)))
    (nreverse out)))

;;;; `drgnx packs …'

(defun drgnx-packs-cli (args)
  "Run `drgnx packs ARGS': `sync [--add NAME…] [--remove NAME…]' and `list'.  The exit code."
  (pcase args
    (`("list")
     (let ((locked (mapcar #'car (drgnx-packs-locked))))
       (pcase-dolist (`(,name . ,m) (drgnx-packs-builtins))
         (princ (format "%-12s %-10s %s\n" name (if (memq (intern name) locked) "installed" "available") (plist-get m :name)))))
     0)
    (`("sync" . ,flags)
     (let (add remove cur)
       (dolist (f flags)
         (pcase f ("--add" (setq cur 'add)) ("--remove" (setq cur 'remove))
                ((pred (lambda (s) (string-prefix-p "--" s))) (drgnx-packs--error "unknown packs sync option %s" f))
                (_ (pcase cur ('add (push f add)) ('remove (push f remove)) (_ (drgnx-packs--error "packs sync takes --add NAME… or --remove NAME…"))))))
       (let ((r (drgnx-packs-sync :add (nreverse add) :remove (nreverse remove))))
         (princ (format "packs: %s; built: %s; generation %d\n" (mapconcat #'identity (plist-get r :packs) " ")
                        (or (mapconcat #'identity (plist-get r :built) " ") "nothing") (plist-get r :generation)))
         0)))
    (`("migrate") (princ (format "packs migrated: %s\n" (or (mapconcat #'identity (drgnx-packs-migrate) " ") "nothing to do"))) 0)
    (_ (drgnx-packs--error "usage: drgnx packs list | sync [--add NAME…] [--remove NAME…] | migrate | check DIR | pin REPO COMMIT"))))

(declare-function drgnx-hub-client-binary "drgnx-hub-client" ())
(declare-function drgnx-pkg--generation-dir "drgnx-pkg" (n))

(provide 'drgnx-packs)
;;; drgnx-packs.el ends here
