;;; drgnx-extensions-live.el --- Extensions: new packages work at once; a running session keeps a consistent old set -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What a running drgnx does around an Extensions job (`drgnx sync', `upgrade' or `rollback' with `--progress'):
;; - Before the job starts (`drgnx-extensions-live-before') and at its plan step (`drgnx-extensions-live-plan'), every
;;   `load-path' entry this session has at or under a package directory the swap takes away (autoloads may add
;;   subdirectories) is pointed at its copy under generations/N/elpa/, N the generation holding what the swap takes
;;   away, so a file loaded later (lazily) is the version already running, never a missing file.  Only where the copy
;;   exists: a package with none is marked "restart drgnx" at once.  The session names the generations it points into
;;   in <state>/elpa-in-use/PID.eld, so snapshot rotation keeps them while it lives (the file goes at exit).
;; - When the job ends (`drgnx-extensions-live-after'): after a failed or stopped job the entries point back into
;;   elpa/.  After one that went well the session settles on the packages directory: a package new to it is activated;
;;   a changed one whose changed set (it and the changed packages it needs or that need it) has nothing loaded swaps to
;;   its new version; one with something loaded keeps its old version and says "Restart to use 1.1 (1.0 is running)";
;;   a removed one that is kept says "Restart to finish removing"; a directory that is gone with no copy says so.
;;   A removed package's modes go off: the plan step reads them from the modes index (the swap rewrites it without
;;   the package), and after the job its file-mode entries leave the mode alists, a buffer in one of its major modes
;;   takes the mode its file gets without it, and its buffer minor modes go off; other packages' modes stay on.
;;   Modules that waited for packages then run (`drgnx-modules-retry-waiting').
;; Nothing here prompts, waits or reaches the network, and nothing writes elpa/, the lock or the quickstart file.  See
;; docs/guide/extensions.md, "When a restart is needed".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-pkg-progress)
(require 'drgnx-extensions-index)

(defvar package-alist)
(defvar package-user-dir)
(defvar package-directory-list)
(defvar package-activated-list)
(declare-function package-load-all-descriptors "package-activate" ())
(declare-function package-load-descriptor "package-activate" (pkg-dir))
(declare-function package-activate "package-activate" (package &optional force))
(declare-function package-desc-reqs "package-activate" (desc))
(declare-function drgnx-pkg-current-generation "drgnx-pkg" ())
(declare-function drgnx-modules-retry-waiting "drgnx-modules" ())
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))

(defvar drgnx-extensions-live--restart nil
  "What waits for a restart: ((NAME . TEXT)…), NAME a package (a symbol).  `drgnx-extensions-live-restart-pending'.")

(defvar drgnx-extensions-live--moved nil
  "The repoints of the job under way: ((NEW . OLD)…), a `load-path' entry moved from OLD (under elpa/) to NEW.")

(defvar drgnx-extensions-live--marked nil "Packages the job under way marked for a restart (unmarked if it fails).")

(defvar drgnx-extensions-live--keys nil
  "The plan files of the jobs that repointed this session (a job's repoint is keyed by its plan file).  Only the end of
one of these settles or points back; a job that swapped nothing leaves the repoints alone.")

(defvar drgnx-extensions-live--removing nil
  "The packages the job under way takes away, with the modes they add, read at its plan step (the swap rewrites the
modes index): ((NAME . ENTRY)…), ENTRY as `drgnx-extensions-index-of' gives it.")

(defun drgnx-extensions-live--warn (what err)
  "Say that WHAT failed with ERR, as one notice.  Never signals."
  (ignore-errors
    (require 'drgnx-notice)
    (drgnx-notify 'config 'warn (format "%s: %s" what (error-message-string err)) :id 'extensions-live)))

(defun drgnx-extensions-live--put (alist name text)
  "ALIST ((NAME . TEXT)…) with NAME's entry TEXT, in place of any it had."
  (cons (cons name text) (assq-delete-all name alist)))

;;;; Where an entry lives

(defun drgnx-extensions-live--elpa () (file-name-as-directory (expand-file-name (drgnx-elpa-dir))))

(defun drgnx-extensions-live--gens () (file-name-as-directory (expand-file-name (drgnx-generations-dir))))

(defun drgnx-extensions-live--gen-elpa (n) (format "%s%d/elpa/" (drgnx-extensions-live--gens) n))

(defun drgnx-extensions-live--roots ()
  "(ELPA . GENS): the packages directory and the generations directory as directory names, read once per walk."
  (cons (drgnx-extensions-live--elpa) (drgnx-extensions-live--gens)))

(defun drgnx-extensions-live--where (path &optional roots)
  "Where PATH is: (N DIR REL) when it is at or under the package directory DIR (\"fa-1.0\") of generation N's elpa/
\(N nil: elpa/ itself); REL is the rest (\"\" or \"lisp\").  Nil for any other path.  ROOTS is
`drgnx-extensions-live--roots' when the caller read it already; a path under neither root costs two prefix tests."
  (let* ((roots (or roots (drgnx-extensions-live--roots))) (elpa (car roots)) (gens (cdr roots))
         (raw (if (string-prefix-p "/" path) path (expand-file-name path))))
    (when (or (string-prefix-p elpa raw) (string-prefix-p gens raw))
      (let* ((p (file-name-as-directory (expand-file-name raw)))
             (hit (cond ((string-prefix-p elpa p) (cons nil (substring p (length elpa))))
                        ((string-prefix-p gens p)
                         (let ((rest (substring p (length gens))))
                           (when (string-match "\\`\\([0-9]+\\)/elpa/" rest)
                             (cons (string-to-number (match-string 1 rest)) (substring rest (match-end 0)))))))))
        (when-let* ((rest (cdr hit)) ((string-match "\\`\\([^/]+\\)/\\(.*?\\)/?\\'" rest))
                    (dir (match-string 1 rest)) (sub (match-string 2 rest))
                    ((drgnx-pkg--dir-package dir)))
          (list (car hit) dir sub))))))

(defun drgnx-extensions-live--path (n dir rel)
  "The entry REL of the package directory DIR in generation N's elpa/ (N nil: elpa/)."
  (directory-file-name (expand-file-name (concat dir "/" rel)
                                         (if n (drgnx-extensions-live--gen-elpa n) (drgnx-extensions-live--elpa)))))

(defun drgnx-extensions-live--name (dir) (intern (car (drgnx-pkg--dir-package dir))))

(defun drgnx-extensions-live--version (dir) (cdr (drgnx-pkg--dir-package dir)))

(defun drgnx-extensions-live--session ()
  "The packages this session activated, by its `load-path': ((NAME . DIR)…), DIR the package directory it uses."
  (let ((roots (drgnx-extensions-live--roots)) (out nil))
    (dolist (e load-path)
      (when-let* (((stringp e)) (w (drgnx-extensions-live--where e roots)) (name (drgnx-extensions-live--name (nth 1 w))))
        (unless (assq name out) (push (cons name (nth 1 w)) out))))
    (nreverse out)))

(defun drgnx-extensions-live--table ()
  "One walk of `load-path': a hash table from each package directory (\"fa-1.0\") that has entries at or under it to
those entries' cells, in `load-path' order: ((CELL . WHERE)…).  Valid until `load-path' gains or loses a cell."
  (let ((roots (drgnx-extensions-live--roots)) (table (make-hash-table :test #'equal)) (cell load-path))
    (while cell
      (when-let* (((stringp (car cell))) (w (drgnx-extensions-live--where (car cell) roots)))
        (puthash (nth 1 w) (cons (cons cell w) (gethash (nth 1 w) table)) table))
      (setq cell (cdr cell)))
    (maphash (lambda (dir cells) (puthash dir (nreverse cells) table)) table)
    table))

(defun drgnx-extensions-live--cells (dir &optional table)
  "The `load-path' cells at or under the package directory DIR, wherever they point: ((CELL . WHERE)…).  TABLE is
a `drgnx-extensions-live--table' the caller made already."
  (gethash dir (or table (drgnx-extensions-live--table))))

(defun drgnx-extensions-live--loaded ()
  "The package directories (\"fa-1.0\") a file of which this session loaded, by `load-history' (autoloads and
descriptor files do not count: activation loads them)."
  (let ((roots (drgnx-extensions-live--roots)) (out nil))
    (dolist (h load-history)
      (let ((f (car h)))
        (when (and (stringp f) (not (string-match-p "-\\(autoloads\\|pkg\\)\\.elc?\\'" f)))
          (when-let* ((w (drgnx-extensions-live--where (file-name-directory f) roots)))
            (cl-pushnew (nth 1 w) out :test #'equal)))))
    out))

(defun drgnx-extensions-live--copy (dir)
  "The newest generation whose elpa/ holds the package directory DIR, or nil."
  (let ((gens (drgnx-extensions-live--gens)))
    (seq-find (lambda (n) (file-directory-p (concat (drgnx-extensions-live--gen-elpa n) dir)))
              (sort (mapcar #'string-to-number (and (file-directory-p gens) (directory-files gens nil "\\`[0-9]+\\'")))
                    #'>))))

(defun drgnx-extensions-live--move (dir n &optional table)
  "Point the entries of the package directory DIR at generation N's elpa/ (N nil: elpa/), where the target exists.
TABLE: as `drgnx-extensions-live--cells'."
  (pcase-dolist (`(,cell . ,w) (drgnx-extensions-live--cells dir table))
    (let ((new (drgnx-extensions-live--path n dir (nth 2 w))))
      (when (file-directory-p new) (setcar cell new)))))

;;;; The session's claim on its generations

(defun drgnx-extensions-live--in-use-file () (expand-file-name (format "%d.eld" (emacs-pid)) (drgnx-pkg-in-use-dir)))

(defun drgnx-extensions-live--claim ()
  "Name the generations the session's `load-path' points into in its in-use file; with none, remove the file."
  (let ((gens nil) (file (drgnx-extensions-live--in-use-file)) (roots (drgnx-extensions-live--roots)))
    (dolist (e load-path)
      (when-let* (((stringp e)) (n (car (drgnx-extensions-live--where e roots)))) (cl-pushnew n gens)))
    (if gens
        (drgnx-file-write file (list :pid (emacs-pid)
                                     :start (float-time (or (alist-get 'start (process-attributes (emacs-pid))) 0))
                                     :generations (sort gens #'<))
                          :header ";; drgnx: the package generations this session uses" :fsync nil)
      (when (file-exists-p file) (delete-file file)))))

(defun drgnx-extensions-live--kill ()
  "On `kill-emacs-hook': the session uses no generation any more."
  (ignore-errors (delete-file (drgnx-extensions-live--in-use-file))))

(defun drgnx-extensions-live-restart-pending ()
  "What waits for a restart of this session: ((NAME . TEXT)…), sorted by name.  A cache read."
  (sort (copy-sequence drgnx-extensions-live--restart) (lambda (a b) (string< (car a) (car b)))))

;;;; Before the swap

(defun drgnx-extensions-live--repoint (dirs n)
  "Point each `load-path' entry at or under the package directories DIRS of elpa/ at its copy in generation N's
elpa/ (one `setcar' each), where the copy exists; a package with no copy (or N nil) is marked at once.  One walk of
`load-path' for all of DIRS."
  (let ((table (drgnx-extensions-live--table)))
    (dolist (dir dirs)
      (let ((seen nil) (moved nil))
        (pcase-dolist (`(,cell . ,w) (drgnx-extensions-live--cells dir table))
          (unless (car w)                                 ; under elpa/, not already in a generation
            (setq seen t)
            (let ((new (and n (drgnx-extensions-live--path n dir (nth 2 w)))))
              (when (and new (file-directory-p new))
                (push (cons new (car cell)) drgnx-extensions-live--moved)
                (setcar cell new)
                (setq moved t)))))
        (when (and seen (not moved))
          (let ((name (drgnx-extensions-live--name dir)))
            (setq drgnx-extensions-live--restart
                  (drgnx-extensions-live--put drgnx-extensions-live--restart name
                                              (format "files of %s %s are not kept for this session: restart drgnx"
                                                      name (drgnx-extensions-live--version dir))))
            (cl-pushnew name drgnx-extensions-live--marked)))))))

(defun drgnx-extensions-live-before (names &optional key)
  "Before a job for the packages NAMES starts (t: every package, for a job that may swap any): the package
directories of theirs this session uses from elpa/ point at the current generation's copies.  KEY, the job's plan
file, makes its end settle (`drgnx-extensions-jobs-before-functions').  Never signals."
  (condition-case err
      (progn
        (require 'drgnx-pkg)
        (when key (cl-pushnew key drgnx-extensions-live--keys :test #'equal))
        (let ((names (if (eq names t) t (mapcar (lambda (n) (if (stringp n) (intern n) n)) names))))
          (drgnx-extensions-live--repoint
           (delq nil (mapcar (lambda (p) (and (or (eq names t) (memq (car p) names)) (cdr p)))
                             (drgnx-extensions-live--session)))
           (drgnx-pkg-current-generation)))
        (drgnx-extensions-live--claim))
    (error (drgnx-extensions-live--warn "the running packages' files were not kept" err))))

(defun drgnx-extensions-live-plan (plan)
  "At a job's plan step: PLAN is its plan object (:generation N :replaces DIRS :removes DIRS, package directory
names); the directories this session uses from elpa/ that the swap takes away point at generation N's copies.
Never signals."
  (condition-case err
      (let ((n (plist-get plan :generation)))
        (when-let* ((key (plist-get plan :file))) (cl-pushnew key drgnx-extensions-live--keys :test #'equal))
        (setq drgnx-extensions-live--removing (drgnx-extensions-live--modes-of (append (plist-get plan :removes) nil)))
        (drgnx-extensions-live--repoint (append (plist-get plan :replaces) (plist-get plan :removes) nil)
                                        (and (natnump n) n))
        (drgnx-extensions-live--claim))
    (error (drgnx-extensions-live--warn "the running packages' files were not kept" err))))

(defun drgnx-extensions-live--modes-of (dirs)
  "The modes the packages of the package directories DIRS (of elpa/) add, from the modes index as it is now, or from
a package's autoloads file when the index lacks it: ((NAME . ENTRY)…)."
  (let ((index (drgnx-extensions-index-read)) (out nil))
    (dolist (dir dirs)
      (when (drgnx-pkg--dir-package dir)
        (let ((name (drgnx-extensions-live--name dir)))
          (push (cons name (or (alist-get name index)
                               (drgnx-extensions-index-of
                                (expand-file-name (format "%s/%s-autoloads.el" dir name) (drgnx-extensions-live--elpa)))))
                out))))
    (nreverse out)))

;;;; After the job

(defun drgnx-extensions-live--point-back ()
  "The job failed or stopped, so elpa/ is as it was: the entries it moved go back where elpa/ has them, and its
marks go."
  (pcase-dolist (`(,new . ,old) drgnx-extensions-live--moved)
    (when-let* (((file-directory-p old)) (cell (member new load-path))) (setcar cell old)))
  (dolist (name drgnx-extensions-live--marked)
    (setq drgnx-extensions-live--restart (assq-delete-all name drgnx-extensions-live--restart))))

(defun drgnx-extensions-live--reqs (dir n)
  "The names of the packages the package directory DIR of generation N's elpa/ (N nil: elpa/) needs."
  (when-let* ((d (ignore-errors
                   (package-load-descriptor (drgnx-extensions-live--path n dir "")))))
    (mapcar #'car (package-desc-reqs d))))

(defun drgnx-extensions-live--grow (set links)
  "SET (names) with every name of LINKS ((NAME . NAMES)…) linked to one in it, either way, until none is added."
  (let ((more t))
    (while more
      (setq more nil)
      (pcase-dolist (`(,name . ,needs) links)
        (unless (memq name set)
          (when (or (seq-some (lambda (r) (memq r set)) needs)
                    (seq-some (lambda (k) (memq name (alist-get k links))) set))
            (push name set)
            (setq more t)))))
    set))

(defun drgnx-extensions-live--settle ()
  "The job went well: make the session match the packages directory where nothing loaded is in the way, and mark
the rest.  The marks are made again from what the session and elpa/ hold."
  (require 'package)
  (let* ((elpa (mapcar (lambda (d) (cons (drgnx-extensions-live--name d) d))
                       (drgnx-pkg--package-dirs (drgnx-extensions-live--elpa))))
         (session (drgnx-extensions-live--session))
         (table (drgnx-extensions-live--table))
         (loaded (drgnx-extensions-live--loaded))
         (changed (seq-remove (lambda (p) (equal (cdr p) (alist-get (car p) elpa))) session))
         ;; each changed package with what its running and its new version need
         (links (mapcar (lambda (p)
                          (cons (car p)
                                (append (drgnx-extensions-live--reqs (cdr p) (nth 1 (car (drgnx-extensions-live--cells (cdr p) table))))
                                        (when-let* ((new (alist-get (car p) elpa))) (drgnx-extensions-live--reqs new nil)))))
                        changed))
         ;; a loaded one keeps its old version, and so does everything changed linked to it
         (kept (drgnx-extensions-live--grow (delq nil (mapcar (lambda (p) (and (member (cdr p) loaded) (car p))) changed))
                                            links))
         (marks nil))
    (dolist (p session)
      (let ((new (alist-get (car p) elpa)))
        (cond ((not (memq p changed)) (drgnx-extensions-live--move (cdr p) nil table))   ; the version elpa/ has: back there
              ((memq (car p) kept)
               (push (cons (car p) (if new (format "Restart to use %s (%s is running)" (drgnx-extensions-live--version new)
                                                   (drgnx-extensions-live--version (cdr p)))
                                     "Restart to finish removing"))
                     marks))
              (new                               ; nothing of it is loaded: its new version takes its place
               (pcase-dolist (`(,cell . ,_) (drgnx-extensions-live--cells (cdr p) table)) (setcar cell nil))
               (setq load-path (delq nil load-path)
                     package-activated-list (delq (car p) package-activated-list))))))
    ;; packages new to the session, unless one they need runs at another version
    (let* ((now (drgnx-extensions-live--session))
           (fresh (seq-remove (lambda (e) (assq (car e) now)) elpa))
           (needs (mapcar (lambda (e) (cons (car e) (drgnx-extensions-live--reqs (cdr e) nil))) fresh))
           (blocked kept) (more t))
      (while more
        (setq more nil)
        (pcase-dolist (`(,name . ,reqs) needs)
          (when (and (not (memq name blocked)) (seq-some (lambda (r) (memq r blocked)) reqs))
            (push name blocked)
            (setq more t))))
      (let ((package-alist nil) (package-user-dir (drgnx-extensions-live--elpa)) (package-directory-list nil)
            (todo (mapcar #'car fresh)))
        ;; the descriptors of the new packages and of what they need, not of every installed package
        (while todo
          (let* ((name (pop todo)) (dir (alist-get name elpa)))
            (when (and dir (not (assq name package-alist)))
              (when-let* ((d (ignore-errors (package-load-descriptor (drgnx-extensions-live--path nil dir "")))))
                (dolist (r (package-desc-reqs d)) (push (car r) todo))))))
        (pcase-dolist (`(,name . ,dir) fresh)
          (if (memq name blocked)
              (push (cons name (format "Restart to use %s %s (it needs %s, which runs at another version)" name
                                       (drgnx-extensions-live--version dir)
                                       (seq-find (lambda (r) (memq r blocked)) (alist-get name needs))))
                    marks)
            (condition-case err (package-activate name)
              (error (push (cons name (format "%s did not activate: %s" name (error-message-string err))) marks)))))))
    ;; every package directory the session uses is there, or comes from a generation that has it
    (let ((table (drgnx-extensions-live--table)))       ; again: entries left and came
      (pcase-dolist (`(,name . ,dir) (drgnx-extensions-live--session))
        (let ((n (nth 1 (car (drgnx-extensions-live--cells dir table)))))
          (unless (file-directory-p (drgnx-extensions-live--path n dir ""))
            (if-let* ((copy (drgnx-extensions-live--copy dir)))
                (drgnx-extensions-live--move dir copy table)
              (setq marks (drgnx-extensions-live--put
                           marks name (format "files of %s %s are gone: restart drgnx" name (drgnx-extensions-live--version dir)))))))))
    (setq drgnx-extensions-live--restart marks)))

(defun drgnx-extensions-live--modes-off (removed)
  "The packages REMOVED ((NAME . ENTRY)…) are gone: their file-mode entries leave the mode alists, a buffer in one of
their major modes takes the mode its file gets without them (keeping the other packages' buffer minor modes it had
on), and their buffer minor modes go off in every buffer.  Never prompts."
  (let ((majors (seq-mapcat (lambda (r) (drgnx-extensions-index-modes (cdr r))) removed))
        (minors (seq-mapcat (lambda (r) (plist-get (cdr r) :minor)) removed))
        (others (seq-mapcat (lambda (e) (unless (assq (car e) removed) (plist-get (cdr e) :minor)))
                            (drgnx-extensions-index-read))))
    (pcase-dolist (`(,var . ,key) drgnx-extensions-index--alists)
      (dolist (r removed)
        (dolist (e (plist-get (cdr r) key)) (set var (delete e (symbol-value var))))))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (memq major-mode majors)
          (let ((on (seq-filter (lambda (m) (and (boundp m) (symbol-value m))) others))
                (enable-local-variables :safe) (inhibit-interaction t))
            (condition-case nil (normal-mode) (error (fundamental-mode)))
            (dolist (m on)
              (unless (symbol-value m) (condition-case nil (funcall m 1) (error nil))))))
        (dolist (m minors)
          (when (and (fboundp m) (boundp m) (symbol-value m)) (condition-case nil (funcall m -1) (error nil))))))))

(defun drgnx-extensions-live--gone ()
  "The packages the job under way took away that elpa/ has no version of now: entries of
`drgnx-extensions-live--removing'."
  (let ((there (mapcar (lambda (d) (drgnx-extensions-live--name d))
                       (drgnx-pkg--package-dirs (drgnx-extensions-live--elpa)))))
    (seq-remove (lambda (r) (memq (car r) there)) drgnx-extensions-live--removing)))

(defun drgnx-extensions-live-after (result)
  "When a job ends (RESULT: the job layer's result, `drgnx-extensions-jobs-done-functions'; :status `done' when it
went well, `failed' or `stopped' otherwise): settle the session on the packages directory and turn off the modes of
the packages it took away, or point back into it after a failed or stopped job; claim the generations still used;
then run the modules that waited for packages.  Never signals."
  (condition-case err
      (let ((ok (eq (plist-get result :status) 'done)))
        (if ok
            (progn (drgnx-extensions-live--settle)
                   (drgnx-extensions-live--modes-off (drgnx-extensions-live--gone)))
          (drgnx-extensions-live--point-back))
        (setq drgnx-extensions-live--moved nil drgnx-extensions-live--marked nil drgnx-extensions-live--removing nil)
        (drgnx-extensions-live--claim)
        (when (and ok (fboundp 'drgnx-modules-retry-waiting)) (drgnx-modules-retry-waiting)))
    (error (drgnx-extensions-live--warn "the session did not take the changed packages" err))))

(defun drgnx-extensions-live--settle-key (key result)
  "The job keyed KEY (its plan file) ended with RESULT: when it repointed this session, take it off the keys; the
last of them to end settles (or points back)."
  (when (member key drgnx-extensions-live--keys)
    (setq drgnx-extensions-live--keys (delete key drgnx-extensions-live--keys))
    (unless drgnx-extensions-live--keys (drgnx-extensions-live-after result))))

(defun drgnx-extensions-live--done (_job result)
  "On `drgnx-extensions-jobs-done-functions': a job of this session ended with RESULT."
  (drgnx-extensions-live--settle-key (plist-get result :plan) result))

(defun drgnx-extensions-live--plan-gone (file)
  "On `drgnx-extensions-jobs-plan-gone-functions': another session's job, plan FILE, ended.  Its packages directory is
what it left, so the session settles on it."
  (drgnx-extensions-live--settle-key file '(:status done)))

;;;; Setup

(defun drgnx-extensions-live-setup ()
  "Take part in Extensions jobs: repoint before a job of this session that swaps starts and at every plan step,
settle when the job that repointed ends (another session's when its plan goes); the in-use file goes at exit.
For the Extensions module's setup, which records the hooks (its teardown removes them; a session that points into a
generation keeps its in-use file, which the next snapshot sweeps once the session is gone)."
  (add-hook 'drgnx-extensions-jobs-before-functions #'drgnx-extensions-live-before)
  (add-hook 'drgnx-extensions-jobs-plan-functions #'drgnx-extensions-live-plan)
  (add-hook 'drgnx-extensions-jobs-done-functions #'drgnx-extensions-live--done)
  (add-hook 'drgnx-extensions-jobs-plan-gone-functions #'drgnx-extensions-live--plan-gone)
  (add-hook 'kill-emacs-hook #'drgnx-extensions-live--kill))

(provide 'drgnx-extensions-live)
;;; drgnx-extensions-live.el ends here
