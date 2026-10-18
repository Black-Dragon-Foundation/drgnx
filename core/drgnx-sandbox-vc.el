;;; drgnx-sandbox-vc.el --- The VC guard: no git runs in a job's task folder outside its sandbox -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The `.git' of a job's task folder is the agent's: its config can name a program (`core.fsmonitor', `core.pager',
;; `core.sshCommand', a hook) that git runs the moment anything of the user's runs git there.  The hub keeps the
;; folders of live sandboxes in <state>/sandbox/folders.eld (`drgnx-sandbox-vc-register').  While
;; `drgnx-sandbox-vc-mode' is on, VC ignores them (`vc-ignore-dir-regexp') and one advice on `call-process',
;; `process-file', `call-process-region' and `make-process' refuses a `git' whose directory is inside one, whoever asked: VC, magit,
;; project.el, drgnx's own callers.  A `git' started through a shell, or any wrapper program, is outside its reach.
;; See docs/develop/sandbox.md ("The VC guard").

;;; Code:
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(define-error 'drgnx-sandbox-guarded
              "No git in a job's snapshot folder: its .git is the agent's; use the job window")

;;;; The registered folders

(defvar drgnx-sandbox-vc--cache nil
  "(STAMP . FOLDERS) of the last read of the folder list; nil before the first read.")

(defun drgnx-sandbox-vc--file () (expand-file-name "sandbox/folders.eld" (drgnx-state-dir)))

(defun drgnx-sandbox-vc--norm (dir)
  "DIR's true name with a trailing slash: a folder matches on directory boundaries (ID-1/ is not ID-10/)."
  (file-name-as-directory (file-truename dir)))

(defun drgnx-sandbox-vc--stamp (file)
  "What identifies this version of FILE: modification time, size and inode (a write is a rename, so a new inode)."
  (when-let* ((a (file-attributes file 'integer))) (list (nth 5 a) (nth 7 a) (nth 10 a))))

(defun drgnx-sandbox-vc--read (file)
  "The folders in FILE: absolute strings only; anything else in it is ignored."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (let ((read-circle nil))
          (seq-filter (lambda (f) (and (stringp f) (file-name-absolute-p f)))
                      (let ((v (read (current-buffer)))) (and (listp v) v)))))
    (error nil)))

(defun drgnx-sandbox-vc-folders ()
  "The registered folders (true names, trailing slash), re-read when the file's stamp changes."
  (let* ((file (drgnx-sandbox-vc--file)) (stamp (drgnx-sandbox-vc--stamp file)))
    (unless (and drgnx-sandbox-vc--cache (equal (car drgnx-sandbox-vc--cache) stamp))
      (setq drgnx-sandbox-vc--cache (cons stamp (and stamp (drgnx-sandbox-vc--read file))))
      (drgnx-sandbox-vc--sync-ignore))
    (cdr drgnx-sandbox-vc--cache)))

(defun drgnx-sandbox-vc--write (folders)
  "Keep FOLDERS in the list file (mode 0600), written beside it and renamed over it as `drgnx-hub--write-private' does."
  (let* ((file (drgnx-sandbox-vc--file))
         (tmp (progn (with-file-modes #o700 (make-directory (file-name-directory file) t))
                     (with-file-modes #o600 (make-temp-file (concat file "-"))))))
    (unwind-protect
        (progn
          (with-temp-buffer
            (let ((print-length nil) (print-level nil)) (prin1 folders (current-buffer)))
            (let ((coding-system-for-write 'utf-8-unix)) (write-region nil nil tmp nil 'silent)))
          (set-file-modes tmp #o600)
          (rename-file tmp file t))
      (when (file-exists-p tmp) (delete-file tmp)))
    (setq drgnx-sandbox-vc--cache nil)))

(defun drgnx-sandbox-vc-register (folder)
  "Guard FOLDER: no git of the user's runs there from now on."
  (let ((f (drgnx-sandbox-vc--norm folder)))
    (unless (member f (drgnx-sandbox-vc-folders))
      (drgnx-sandbox-vc--write (append (drgnx-sandbox-vc-folders) (list f))))
    (drgnx-sandbox-vc-folders)))

(defun drgnx-sandbox-vc-unregister (folder)
  "Stop guarding FOLDER (its sandbox has exited and the hub has scrubbed its git state)."
  (let ((f (drgnx-sandbox-vc--norm folder)))
    (when (member f (drgnx-sandbox-vc-folders))
      (drgnx-sandbox-vc--write (delete f (copy-sequence (drgnx-sandbox-vc-folders)))))
    (drgnx-sandbox-vc-folders)))

(defun drgnx-sandbox-vc-guarded-p (dir)
  "Non-nil when DIR's true name is a registered folder or inside one."
  (and (stringp dir) (not (file-remote-p dir))
       (when-let* ((folders (drgnx-sandbox-vc-folders)))
         (let ((d (drgnx-sandbox-vc--norm dir)))
           (seq-some (lambda (f) (string-prefix-p f d)) folders)))))

;;;; VC ignores the folders

(defvar vc-ignore-dir-regexp)

(defvar drgnx-sandbox-vc--added nil "What the mode appended to `vc-ignore-dir-regexp' (to take it off again).")

(defun drgnx-sandbox-vc--sync-ignore ()
  "Make `vc-ignore-dir-regexp' end with the registered folders while the mode is on, and without them when off."
  (when (and (boundp 'vc-ignore-dir-regexp) (stringp vc-ignore-dir-regexp))
    (let ((base (if (and drgnx-sandbox-vc--added (string-suffix-p drgnx-sandbox-vc--added vc-ignore-dir-regexp))
                    (substring vc-ignore-dir-regexp 0 (- (length drgnx-sandbox-vc--added)))
                  vc-ignore-dir-regexp))
          (folders (and (bound-and-true-p drgnx-sandbox-vc-mode) (cdr drgnx-sandbox-vc--cache))))
      (setq drgnx-sandbox-vc--added
            (and folders (concat "\\|\\(?:" (mapconcat (lambda (f) (concat "\\`" (regexp-quote f))) folders "\\|") "\\)")))
      (setq vc-ignore-dir-regexp (concat base drgnx-sandbox-vc--added)))))

;;;; Refusing git

(defun drgnx-sandbox-vc--git-p (program)
  (and (stringp program)
       (or (string= program "git") (and (string-suffix-p "git" program) (string= (file-name-nondirectory program) "git")))))

(defun drgnx-sandbox-vc--guarded-dir (args)
  "The first directory git would work in that is guarded: `default-directory', then what ARGS' global options
(-C DIR, --git-dir, --work-tree) name; nil when none is."
  (let ((base default-directory) found)
    (setq found (and (drgnx-sandbox-vc-guarded-p base) base))
    (while (and (not found) args (stringp (car args)) (string-prefix-p "-" (car args)))
      (let ((a (pop args)) (dir nil))
        (cond ((string= a "-C") (when args (setq base (expand-file-name (pop args) base) dir base)))
              ((string= a "-c") (pop args))
              ((member a '("--git-dir" "--work-tree")) (when args (setq dir (expand-file-name (pop args) base))))
              ((string-match "\\`--\\(?:git-dir\\|work-tree\\)=\\(.*\\)" a) (setq dir (expand-file-name (match-string 1 a) base))))
        (when (and dir (drgnx-sandbox-vc-guarded-p dir)) (setq found dir))))
    found))

(defvar drgnx-sandbox-vc-trusted nil
  "Non-nil (let-bound) while the hub runs one of its own trusted git steps in a task folder (a step that is not
the agent's and runs outside its sandbox, with an environment the hub built): the guard lets it through.  Bound only
by the hub's step code, around that call alone.  It is a variable of this Emacs process: nothing an agent writes or
sends can set it.")

(defun drgnx-sandbox-vc--check (program git-args)
  "Signal `drgnx-sandbox-guarded' when PROGRAM is git and its directory (GIT-ARGS: its arguments) is guarded."
  (when (and (not drgnx-sandbox-vc-trusted) (drgnx-sandbox-vc--git-p program) (drgnx-sandbox-vc-folders))
    (when-let* ((dir (drgnx-sandbox-vc--guarded-dir git-args)))
      (signal 'drgnx-sandbox-guarded (list dir)))))

(defun drgnx-sandbox-vc--refuse-git (orig &rest args)
  "`:around' advice of `call-process', `process-file' and `make-process': signal `drgnx-sandbox-guarded' for a
`git' whose directory is a registered folder (a `-C DIR' argument counts as DIR).  Anything else is ORIG's."
  (if (keywordp (car args))                                ; make-process takes keywords; the others a program
      (let ((cmd (plist-get args :command))) (drgnx-sandbox-vc--check (car cmd) (cdr cmd)))
    (drgnx-sandbox-vc--check (car args) (nthcdr 4 args)))
  (apply orig args))

(defun drgnx-sandbox-vc--refuse-git-region (orig &rest args)
  "`:around' advice of `call-process-region' (START END PROGRAM DELETE BUFFER DISPLAY ARGS…): like
`drgnx-sandbox-vc--refuse-git'."
  (drgnx-sandbox-vc--check (nth 2 args) (nthcdr 6 args))
  (apply orig args))

(defun drgnx-sandbox-vc--refresh ()
  "`find-file-hook': read the folder list before VC looks at the file (the hub may have registered one)."
  (drgnx-sandbox-vc-folders))

(defconst drgnx-sandbox-vc--advised
  '((call-process . drgnx-sandbox-vc--refuse-git) (process-file . drgnx-sandbox-vc--refuse-git)
    (make-process . drgnx-sandbox-vc--refuse-git) (call-process-region . drgnx-sandbox-vc--refuse-git-region))
  "The primitives git is started through: (PRIMITIVE . ADVICE).")

(define-minor-mode drgnx-sandbox-vc-mode
  "Refuse git in the folders of job sandboxes, and keep VC out of them (core; on in the editor and in the hub)."
  :global t :group 'drgnx
  (pcase-dolist (`(,f . ,advice) drgnx-sandbox-vc--advised)
    (if drgnx-sandbox-vc-mode
        (advice-add f :around advice)
      (advice-remove f advice)))
  (if drgnx-sandbox-vc-mode
      (add-hook 'find-file-hook #'drgnx-sandbox-vc--refresh -90)
    (remove-hook 'find-file-hook #'drgnx-sandbox-vc--refresh))
  (setq drgnx-sandbox-vc--cache nil)
  (drgnx-sandbox-vc-folders)
  (drgnx-sandbox-vc--sync-ignore))

;;;; Nested repositories

(defun drgnx-sandbox-vc-nested-git (folder)
  "The `.git' entries under FOLDER other than FOLDER/.git: a repository git finds when the user runs it in a
subdirectory, with the agent's config.  Links are not followed (a link to a directory is one entry, not a tree);
`.git' directories are not entered."
  (let ((top (expand-file-name ".git" (file-name-as-directory folder))))
    (seq-remove (lambda (p) (string= p top))
                (directory-files-recursively folder "\\`\\.git\\'" t
                                             (lambda (dir) (not (string= (file-name-nondirectory dir) ".git")))
                                             nil))))

(provide 'drgnx-sandbox-vc)
;;; drgnx-sandbox-vc.el ends here
