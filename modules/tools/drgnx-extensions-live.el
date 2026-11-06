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
;;   Modules that waited for packages then run (`drgnx-modules-retry-waiting').
;; Nothing here prompts, waits or reaches the network, and nothing writes elpa/, the lock or the quickstart file.  See
;; docs/guide/extensions.md, "When a restart is needed".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-pkg-progress)

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

(defun drgnx-extensions-live--where (path)
  "Where PATH is: (N DIR REL) when it is at or under the package directory DIR (\"fa-1.0\") of generation N's elpa/
\(N nil: elpa/ itself); REL is the rest (\"\" or \"lisp\").  Nil for any other path."
  (let* ((p (file-name-as-directory (expand-file-name path)))
         (elpa (drgnx-extensions-live--elpa)) (gens (drgnx-extensions-live--gens))
         (hit (cond ((string-prefix-p elpa p) (cons nil (substring p (length elpa))))
                    ((string-prefix-p gens p)
                     (let ((rest (substring p (length gens))))
                       (when (string-match "\\`\\([0-9]+\\)/elpa/" rest)
                         (cons (string-to-number (match-string 1 rest)) (substring rest (match-end 0)))))))))
    (when-let* ((rest (cdr hit)) ((string-match "\\`\\([^/]+\\)/\\(.*?\\)/?\\'" rest))
                (dir (match-string 1 rest)) (sub (match-string 2 rest))
                ((drgnx-pkg--dir-package dir)))
      (list (car hit) dir sub))))

(defun drgnx-extensions-live--path (n dir rel)
  "The entry REL of the package directory DIR in generation N's elpa/ (N nil: elpa/)."
  (directory-file-name (expand-file-name (concat dir "/" rel)
                                         (if n (drgnx-extensions-live--gen-elpa n) (drgnx-extensions-live--elpa)))))

(defun drgnx-extensions-live--name (dir) (intern (car (drgnx-pkg--dir-package dir))))

(defun drgnx-extensions-live--version (dir) (cdr (drgnx-pkg--dir-package dir)))

(defun drgnx-extensions-live--session ()
  "The packages this session activated, by its `load-path': ((NAME . DIR)…), DIR the package directory it uses."
  (let (out)
    (dolist (e load-path)
      (when-let* (((stringp e)) (w (drgnx-extensions-live--where e)) (name (drgnx-extensions-live--name (nth 1 w))))
        (unless (assq name out) (push (cons name (nth 1 w)) out))))
    (nreverse out)))

(defun drgnx-extensions-live--cells (dir)
  "The `load-path' cells at or under the package directory DIR, wherever they point: ((CELL . WHERE)…)."
  (let (out (cell load-path))
    (while cell
      (when-let* (((stringp (car cell))) (w (drgnx-extensions-live--where (car cell))) ((equal (nth 1 w) dir)))
        (push (cons cell w) out))
      (setq cell (cdr cell)))
    (nreverse out)))

(defun drgnx-extensions-live--loaded ()
  "The package directories (\"fa-1.0\") a file of which this session loaded, by `load-history' (autoloads and
descriptor files do not count: activation loads them)."
  (let (out)
    (dolist (h load-history)
      (let ((f (car h)))
        (when (and (stringp f) (not (string-match-p "-\\(autoloads\\|pkg\\)\\.elc?\\'" f)))
          (when-let* ((w (drgnx-extensions-live--where (file-name-directory f))))
            (cl-pushnew (nth 1 w) out :test #'equal)))))
    out))

(defun drgnx-extensions-live--copy (dir)
  "The newest generation whose elpa/ holds the package directory DIR, or nil."
  (let ((gens (drgnx-extensions-live--gens)))
    (seq-find (lambda (n) (file-directory-p (concat (drgnx-extensions-live--gen-elpa n) dir)))
              (sort (mapcar #'string-to-number (and (file-directory-p gens) (directory-files gens nil "\\`[0-9]+\\'")))
                    #'>))))

(defun drgnx-extensions-live--move (dir n)
  "Point the entries of the package directory DIR at generation N's elpa/ (N nil: elpa/), where the target exists."
  (pcase-dolist (`(,cell . ,w) (drgnx-extensions-live--cells dir))
    (let ((new (drgnx-extensions-live--path n dir (nth 2 w))))
      (when (file-directory-p new) (setcar cell new)))))

;;;; The session's claim on its generations

(defun drgnx-extensions-live--in-use-file () (expand-file-name (format "%d.eld" (emacs-pid)) (drgnx-pkg-in-use-dir)))

(defun drgnx-extensions-live--claim ()
  "Name the generations the session's `load-path' points into in its in-use file; with none, remove the file."
  (let ((gens nil) (file (drgnx-extensions-live--in-use-file)))
    (dolist (e load-path)
      (when-let* (((stringp e)) (n (car (drgnx-extensions-live--where e)))) (cl-pushnew n gens)))
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
elpa/ (one `setcar' each), where the copy exists; a package with no copy (or N nil) is marked at once."
  (dolist (dir dirs)
    (let ((seen nil) (moved nil))
      (pcase-dolist (`(,cell . ,w) (drgnx-extensions-live--cells dir))
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
          (cl-pushnew name drgnx-extensions-live--marked))))))

(defun drgnx-extensions-live-before (names)
  "Before a job for the packages NAMES starts: the package directories of theirs this session uses from elpa/ point
at the current generation's copies.  Never signals."
  (condition-case err
      (progn
        (require 'drgnx-pkg)
        (let ((names (mapcar (lambda (n) (if (stringp n) (intern n) n)) names)))
          (drgnx-extensions-live--repoint
           (delq nil (mapcar (lambda (p) (and (memq (car p) names) (cdr p))) (drgnx-extensions-live--session)))
           (drgnx-pkg-current-generation)))
        (drgnx-extensions-live--claim))
    (error (drgnx-extensions-live--warn "the running packages' files were not kept" err))))

(defun drgnx-extensions-live-plan (plan)
  "At a job's plan step: PLAN is its plan object (:generation N :replaces DIRS :removes DIRS, package directory
names); the directories this session uses from elpa/ that the swap takes away point at generation N's copies.
Never signals."
  (condition-case err
      (let ((n (plist-get plan :generation)))
        (drgnx-extensions-live--repoint (append (plist-get plan :replaces) (plist-get plan :removes) nil)
                                        (and (natnump n) n))
        (drgnx-extensions-live--claim))
    (error (drgnx-extensions-live--warn "the running packages' files were not kept" err))))

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
         (loaded (drgnx-extensions-live--loaded))
         (changed (seq-remove (lambda (p) (equal (cdr p) (alist-get (car p) elpa))) session))
         ;; each changed package with what its running and its new version need
         (links (mapcar (lambda (p)
                          (cons (car p)
                                (append (drgnx-extensions-live--reqs (cdr p) (nth 1 (car (drgnx-extensions-live--cells (cdr p)))))
                                        (when-let* ((new (alist-get (car p) elpa))) (drgnx-extensions-live--reqs new nil)))))
                        changed))
         ;; a loaded one keeps its old version, and so does everything changed linked to it
         (kept (drgnx-extensions-live--grow (delq nil (mapcar (lambda (p) (and (member (cdr p) loaded) (car p))) changed))
                                            links))
         (marks nil))
    (dolist (p session)
      (let ((new (alist-get (car p) elpa)))
        (cond ((not (memq p changed)) (drgnx-extensions-live--move (cdr p) nil))   ; the version elpa/ has: back there
              ((memq (car p) kept)
               (push (cons (car p) (if new (format "Restart to use %s (%s is running)" (drgnx-extensions-live--version new)
                                                   (drgnx-extensions-live--version (cdr p)))
                                     "Restart to finish removing"))
                     marks))
              (new                               ; nothing of it is loaded: its new version takes its place
               (pcase-dolist (`(,cell . ,_) (drgnx-extensions-live--cells (cdr p))) (setcar cell nil))
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
      (let ((package-alist nil) (package-user-dir (drgnx-extensions-live--elpa)) (package-directory-list nil))
        (package-load-all-descriptors)
        (pcase-dolist (`(,name . ,dir) fresh)
          (if (memq name blocked)
              (push (cons name (format "Restart to use %s %s (it needs %s, which runs at another version)" name
                                       (drgnx-extensions-live--version dir)
                                       (seq-find (lambda (r) (memq r blocked)) (alist-get name needs))))
                    marks)
            (condition-case err (package-activate name)
              (error (push (cons name (format "%s did not activate: %s" name (error-message-string err))) marks)))))))
    ;; every package directory the session uses is there, or comes from a generation that has it
    (pcase-dolist (`(,name . ,dir) (drgnx-extensions-live--session))
      (let ((n (nth 1 (car (drgnx-extensions-live--cells dir)))))
        (unless (file-directory-p (drgnx-extensions-live--path n dir ""))
          (if-let* ((copy (drgnx-extensions-live--copy dir)))
              (drgnx-extensions-live--move dir copy)
            (setq marks (drgnx-extensions-live--put
                         marks name (format "files of %s %s are gone: restart drgnx" name (drgnx-extensions-live--version dir))))))))
    (setq drgnx-extensions-live--restart marks)))

(defun drgnx-extensions-live-after (result)
  "When a job ends (RESULT: its done object; :ok t when it went well): settle the session on the packages directory,
or point back into it after a failed or stopped job; claim the generations still used; then run the modules that
waited for packages.  Never signals."
  (condition-case err
      (let ((ok (eq (plist-get result :ok) t)))
        (if ok (drgnx-extensions-live--settle) (drgnx-extensions-live--point-back))
        (setq drgnx-extensions-live--moved nil drgnx-extensions-live--marked nil)
        (drgnx-extensions-live--claim)
        (when (and ok (fboundp 'drgnx-modules-retry-waiting)) (drgnx-modules-retry-waiting)))
    (error (drgnx-extensions-live--warn "the session did not take the changed packages" err))))

(defun drgnx-extensions-live--done (_job result)
  "On `drgnx-extensions-jobs-done-functions': a job ended with RESULT."
  (drgnx-extensions-live-after result))

;;;; Setup

(defun drgnx-extensions-live-setup ()
  "Take part in Extensions jobs: repoint at their plan steps, settle when they end; the in-use file goes at exit.
For the Extensions module's setup, which records the hooks (its teardown removes them; a session that points into a
generation keeps its in-use file, which the next snapshot sweeps once the session is gone)."
  (add-hook 'drgnx-extensions-jobs-plan-functions #'drgnx-extensions-live-plan)
  (add-hook 'drgnx-extensions-jobs-done-functions #'drgnx-extensions-live--done)
  (add-hook 'kill-emacs-hook #'drgnx-extensions-live--kill))

(provide 'drgnx-extensions-live)
;;; drgnx-extensions-live.el ends here
