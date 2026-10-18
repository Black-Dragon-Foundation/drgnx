;;; drgnx-trust.el --- Trusted folders, and guards for files from the others -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Files from a folder the user has not trusted must not make Emacs run checkers or code they did not ask for.
;; The trusted set is Emacs's own `trusted-content': drgnx's checkout, its config dir, its packages dir, and the
;; folders the user trusted with Trust This Folder (kept in trusted-folders.eld in drgnx's state dir).  Outside it:
;; - Flymake runs only backends marked `flymake-always-safe' (eglot's is): an advice on builds whose
;;   `flymake--run-backend' has no trust check of its own;
;; - a file's `read-symbol-shorthands' is held back (and given back when its folder is trusted);
;; - always: TRAMP ignores names whose user@host part holds control or shell characters, and compile or grep
;;   output in a local buffer never names a remote file or directory.
;; A quiet "restricted" mark in the mode line shows a local file outside the trusted set; clicking it trusts the
;; folder.  Nothing here prompts.  docs/guide/security.md.

;;; Code:
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-registry)

(defvar drgnx-trust-mode)
(defvar tramp-ignored-file-name-regexp)
(defvar flymake--state)
(defvar flymake-mode)
(defvar comint-file-name-prefix)
(defvar warning-minimum-log-level)
(declare-function flymake--disable-backend "flymake")
(declare-function flymake--run-backend "flymake")
(declare-function flymake-start "flymake")
(declare-function project-root "project")
(declare-function project-current "project")

(defface drgnx-trust-restricted '((t :inherit shadow))
  "The \"restricted\" mark in the mode line." :group 'drgnx)

;;;; The trusted set

(defun drgnx-trust-folders-file () (expand-file-name "trusted-folders.eld" (drgnx-state-dir)))

(defun drgnx-trust--entry (dir)
  "DIR as `trusted-content-p' compares it: abbreviated truename ending in /."
  (file-name-as-directory (abbreviate-file-name (file-truename (expand-file-name dir)))))

(defun drgnx-trust--builtin ()
  "drgnx's own trees: the checkout, the config dir, the packages dir."
  (delete-dups (mapcar #'drgnx-trust--entry (list drgnx-dir (drgnx-user-dir) (drgnx-elpa-dir)))))

(defun drgnx-trust-folders ()
  "The folders the user trusted, as trusted-folders.eld holds them."
  (let ((file (drgnx-trust-folders-file)))
    (ignore-errors
      (seq-filter #'stringp
                  (plist-get (and (file-readable-p file)
                                  (with-temp-buffer (insert-file-contents file) (read (current-buffer))))
                             :folders)))))

(defun drgnx-trust--write (folders)
  (let* ((file (drgnx-trust-folders-file)) (dir (file-name-directory file)))
    (make-directory dir t)
    (let ((tmp (make-temp-file (expand-file-name ".trusted-folders-" dir))))
      (with-temp-file tmp
        (insert ";; drgnx: the folders you trusted (Trust This Folder; docs/guide/security.md)\n")
        (let ((print-length nil) (print-level nil)) (pp (list :version 1 :folders folders) (current-buffer))))
      (rename-file tmp file t))))

(defun drgnx-trust--add (entries)
  "Append ENTRIES to `trusted-content' (never when it is :all, which trusts everything already)."
  (unless (eq trusted-content :all)
    (dolist (e entries)
      (unless (member e trusted-content) (setq trusted-content (append trusted-content (list e)))))))

;;;; The "restricted" mark: computed when a file is visited or trust changes, read by redisplay

(defvar-local drgnx-trust--state nil
  "`restricted' or `trusted' for a local file's buffer, else nil.  Kept so that redisplay reads no file.")
(put 'drgnx-trust--state 'permanent-local t)

(defun drgnx-trust--update ()
  "Compute this buffer's `drgnx-trust--state'."
  (setq drgnx-trust--state (and buffer-file-name (not (file-remote-p buffer-file-name))
                                (if (trusted-content-p) 'trusted 'restricted))))

(defun drgnx-trust-folder-at-click (event)
  "Trust the folder of the buffer whose \"restricted\" mark was clicked (EVENT)."
  (interactive "e")
  (with-selected-window (posn-window (event-start event)) (drgnx-trust-folder)))

(defvar drgnx-trust-mark-map
  (let ((m (make-sparse-keymap))) (define-key m [mode-line mouse-1] #'drgnx-trust-folder-at-click) m)
  "Keys on the \"restricted\" mark.")

(defconst drgnx-trust--mark-text
  (propertize " restricted" 'face 'drgnx-trust-restricted 'mouse-face 'mode-line-highlight 'local-map drgnx-trust-mark-map
              'help-echo "This folder is not trusted: Flymake checkers and symbol shorthands are off here.
mouse-1: Trust This Folder")
  "The mark.")

(defun drgnx-trust--mark ()
  "The mode-line mark: \"restricted\" for a local file outside the trusted set, else nothing."
  (if (eq drgnx-trust--state 'restricted) drgnx-trust--mark-text ""))

(defconst drgnx-trust--mark-segment '(:eval (drgnx-trust--mark)))

;;;; Shorthands: held back outside the trusted set

(defvar-local drgnx-trust--held-shorthands nil "The `read-symbol-shorthands' this file asked for, held back.")
(put 'drgnx-trust--held-shorthands 'permanent-local t)

(defun drgnx-trust--drop-shorthands ()
  "In `before-hack-local-variables-hook': outside trusted content, take `read-symbol-shorthands' out of the
variables about to be set (file and directory local) and hold it for Trust This Folder."
  (setq drgnx-trust--held-shorthands nil)
  (when-let* ((cell (assq 'read-symbol-shorthands file-local-variables-alist)))
    (unless (trusted-content-p)
      (setq drgnx-trust--held-shorthands (cdr cell)
            file-local-variables-alist (assq-delete-all 'read-symbol-shorthands file-local-variables-alist)))))

;;;; Flymake: only safe backends outside the trusted set

(defvar drgnx-trust--flymake-native 'unknown
  "t when this Emacs's `flymake--run-backend' refuses backends in untrusted buffers itself, nil when not.")

(defvar-local drgnx-trust--flymake-told nil "This buffer was told once why Flymake skipped a backend.")

(defun drgnx-trust--flymake-checks-trust-p ()
  "Run `flymake--run-backend' once, on a stub backend in a buffer marked untrusted: does it refuse?
An error says nothing either way: nil, so that drgnx's check is added."
  (let ((called nil))
    (with-temp-buffer
      (setq-local untrusted-content t)
      (setq-local flymake--state (make-hash-table))
      (let ((inhibit-message t) (message-log-max nil) (warning-minimum-log-level :emergency) (debug-on-error nil))
        (condition-case nil
            (progn (flymake--run-backend (lambda (&rest _) (setq called t))) (not called))
          (error nil))))))

(defun drgnx-trust--flymake-run-backend (run backend &optional args)
  "Around `flymake--run-backend' (RUN): BACKEND runs with ARGS only in trusted content or when it is
`flymake-always-safe'; else it is disabled, and the buffer says why once."
  (if (or (trusted-content-p) (function-get backend 'flymake-always-safe))
      (funcall run backend args)
    (flymake--disable-backend backend "untrusted content")
    (unless drgnx-trust--flymake-told
      (setq drgnx-trust--flymake-told t)
      (message "Flymake: %s not run in %s: its folder is not trusted (Trust This Folder)" backend (buffer-name)))))

(defun drgnx-trust--flymake-guard ()
  "Once Flymake is loaded: add drgnx's trust check unless this Emacs has one."
  (when (and drgnx-trust-mode (fboundp 'flymake--run-backend))
    (when (eq drgnx-trust--flymake-native 'unknown)
      (setq drgnx-trust--flymake-native (drgnx-trust--flymake-checks-trust-p)))
    (unless drgnx-trust--flymake-native
      (advice-add 'flymake--run-backend :around #'drgnx-trust--flymake-run-backend))))

;;;; TRAMP: crafted names stay local

(defconst drgnx-trust-tramp-ignored-regexp
  (rx (or (any cntrl ?\177)                              ; a control character anywhere in the name
          (seq bos "/"
               ;; the hops before the last one: [METHOD:]USER@HOST|
               (* (? (+ (any alnum "-")) ":") (* (not (any ":|["))) "|")
               (? (+ (any alnum "-")) ":")
               ;; the last USER@HOST#PORT, up to its ":" (or the "[" of an IPv6 host)
               (or "-"                                   ; an ssh option
                   (seq (* (not (any ":|[")))
                        (or (any "](){}`;&<>!'\"\\*?," blank)
                            (seq "$" (or eos (not (any "_" alnum))))))))))
  "Names TRAMP must not handle: a control character anywhere, or a user@host part that starts with - or holds a shell
character.  $VAR is fine: TRAMP expands it before it checks this.")

(defun drgnx-trust--tramp-guard (on)
  "Add (ON non-nil) or remove drgnx's part of `tramp-ignored-file-name-regexp', keeping the user's."
  (let ((cur (bound-and-true-p tramp-ignored-file-name-regexp))
        (ours drgnx-trust-tramp-ignored-regexp) (tail (concat "\\|" drgnx-trust-tramp-ignored-regexp)))
    (setq tramp-ignored-file-name-regexp
          (cond ((and on (or (null cur) (equal cur ""))) ours)
                (on (if (string-search ours cur) cur (concat cur tail)))
                ((equal cur ours) nil)
                ((and cur (string-search tail cur)) (string-replace tail "" cur))
                (t cur)))))

;;;; Compile and grep output: a local buffer never resolves a remote name

(defun drgnx-trust--local-name (name)
  "NAME, quoted (/:) when it is an absolute remote name."
  (if (and (stringp name) (file-name-absolute-p name) (file-remote-p name)) (file-name-quote name t) name))

(defun drgnx-trust--compile-local-p ()
  "Is this compilation buffer local (its directory, and no remote shell's file name prefix)?"
  (and (not (file-remote-p default-directory)) (member (bound-and-true-p comint-file-name-prefix) '(nil ""))))

(defun drgnx-trust--compile-dir-props (props)
  "Filter the text properties `compilation-directory-properties' returns (PROPS): in a local buffer, a remote
directory from an \"Entering directory\" line is quoted.  The output's parser would otherwise give it to TRAMP
\(`expand-file-name', `file-truename') while the text arrives."
  (let ((stack (plist-get props 'compilation-directory)))
    (if (not (and (stringp (car-safe stack)) (drgnx-trust--compile-local-p))) props
      (let ((dir (drgnx-trust--local-name (car stack))))
        (if (eq dir (car stack)) props
          (plist-put (copy-sequence props) 'compilation-directory (cons dir (cdr stack))))))))

(defun drgnx-trust--compile-file-args (args)
  "Filter the arguments (FILE FMT) of `compilation-get-file-structure': in a local compilation buffer, a remote
file or directory name is quoted, so that visiting the message opens nothing remote."
  (let ((file (car args)))
    (if (not (and (consp file) (drgnx-trust--compile-local-p))) args
      (let ((name (drgnx-trust--local-name (car file))) (dir (drgnx-trust--local-name (cdr file))))
        (if (and (eq name (car file)) (eq dir (cdr file))) args
          (cons (cons name dir) (cdr args)))))))

;;;; Trust This Folder

(defun drgnx-trust--folder ()
  "The folder Trust This Folder means here: the buffer's project, else its directory."
  (unless buffer-file-name (user-error "Trust This Folder works in a file's buffer"))
  (require 'project)
  (let ((pr (project-current nil))) (if pr (project-root pr) default-directory)))

(defun drgnx-trust--user-entry ()
  "The user-trusted folder holding this buffer's file, or nil."
  (when buffer-file-truename
    (let ((name (abbreviate-file-name buffer-file-truename)))
      (seq-find (lambda (f) (string-prefix-p f name)) (drgnx-trust-folders)))))

(defun drgnx-trust--refresh ()
  "After trust changed: every file buffer's mark, held shorthands and Flymake follow it."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when buffer-file-name
        (let ((was drgnx-trust--state))
          (drgnx-trust--update)
          (cond ((and drgnx-trust--held-shorthands (trusted-content-p))
                 (setq-local read-symbol-shorthands drgnx-trust--held-shorthands)
                 (setq drgnx-trust--held-shorthands nil)
                 (when (bound-and-true-p font-lock-mode) (font-lock-flush)))
                ((and (eq was 'trusted) (eq drgnx-trust--state 'restricted) (local-variable-p 'read-symbol-shorthands))
                 (setq drgnx-trust--held-shorthands read-symbol-shorthands)
                 (kill-local-variable 'read-symbol-shorthands)))
          (when (and (eq was 'restricted) (eq drgnx-trust--state 'trusted) (bound-and-true-p flymake-mode))
            (setq drgnx-trust--flymake-told nil)
            (flymake-start nil t))))))
  (force-mode-line-update t))

(defun drgnx-trust-folder (&optional dir)
  "Trust DIR (default: this buffer's project, else its folder): Flymake checkers and symbol shorthands work in
its files.  Kept in drgnx's state (trusted-folders.eld)."
  (interactive)
  (let* ((e (drgnx-trust--entry (or dir (drgnx-trust--folder)))) (folders (drgnx-trust-folders)))
    (unless (member e folders) (drgnx-trust--write (append folders (list e))))
    (drgnx-trust--add (list e))
    (drgnx-trust--refresh)
    (message "Trusted %s" e)
    e))

(defun drgnx-trust-untrust-folder (&optional dir)
  "Stop trusting DIR (default: the folder you trusted that holds this buffer's file)."
  (interactive)
  (let ((e (if dir (drgnx-trust--entry dir) (drgnx-trust--user-entry))) (folders (drgnx-trust-folders)))
    (unless (and e (member e folders)) (user-error "Not a folder you trusted (drgnx's own folders stay trusted)"))
    (drgnx-trust--write (delete e folders))
    (unless (or (eq trusted-content :all) (member e (drgnx-trust--builtin)))
      (setq trusted-content (delete e (copy-sequence trusted-content))))
    (drgnx-trust--refresh)
    (message "No longer trusted: %s" e)
    e))

;;;; The mode, and what other parts of drgnx ask

(define-minor-mode drgnx-trust-mode
  "Guards for files from folders the user has not trusted (docs/guide/security.md)."
  :global t :group 'drgnx
  (if drgnx-trust-mode
      (progn
        (drgnx-trust--add (append (drgnx-trust--builtin) (drgnx-trust-folders)))
        (drgnx-trust--tramp-guard t)
        ;; eglot's diagnostics come from a language server, not from running the file: safe on every build
        (function-put 'eglot-flymake-backend 'flymake-always-safe t)
        (if (featurep 'flymake) (drgnx-trust--flymake-guard) (eval-after-load 'flymake #'drgnx-trust--flymake-guard))
        (add-hook 'before-hack-local-variables-hook #'drgnx-trust--drop-shorthands)
        (advice-add 'compilation-get-file-structure :filter-args #'drgnx-trust--compile-file-args)
        (advice-add 'compilation-directory-properties :filter-return #'drgnx-trust--compile-dir-props)
        (add-hook 'find-file-hook #'drgnx-trust--update)
        (add-hook 'after-set-visited-file-name-hook #'drgnx-trust--update)
        (add-to-list 'global-mode-string drgnx-trust--mark-segment t)
        (dolist (b (buffer-list)) (with-current-buffer b (drgnx-trust--update))))
    (drgnx-trust--tramp-guard nil)
    (advice-remove 'flymake--run-backend #'drgnx-trust--flymake-run-backend)
    (remove-hook 'before-hack-local-variables-hook #'drgnx-trust--drop-shorthands)
    (advice-remove 'compilation-get-file-structure #'drgnx-trust--compile-file-args)
    (advice-remove 'compilation-directory-properties #'drgnx-trust--compile-dir-props)
    (remove-hook 'find-file-hook #'drgnx-trust--update)
    (remove-hook 'after-set-visited-file-name-hook #'drgnx-trust--update)
    (setq global-mode-string (delete drgnx-trust--mark-segment global-mode-string)))
  (force-mode-line-update t))

(defun drgnx-trust-guards-status ()
  "Which guards are on, for the doctor: a plist.
:mode — `drgnx-trust-mode'; :tramp — drgnx's part of `tramp-ignored-file-name-regexp' is there; :flymake —
`emacs' (this Emacs checks trust itself), `drgnx' (drgnx's check), `on-load' (added when Flymake loads) or nil;
:eglot-safe — eglot's backend runs in untrusted buffers; :shorthands, :compile — those guards are on;
:trusted — `trusted-content'."
  (list :mode drgnx-trust-mode
        :tramp (and (stringp (bound-and-true-p tramp-ignored-file-name-regexp))
                    (string-search drgnx-trust-tramp-ignored-regexp tramp-ignored-file-name-regexp) t)
        :flymake (cond ((eq drgnx-trust--flymake-native t) 'emacs)
                       ((advice-member-p #'drgnx-trust--flymake-run-backend 'flymake--run-backend) 'drgnx)
                       ((and drgnx-trust-mode (not (featurep 'flymake))) 'on-load))
        :eglot-safe (and (function-get 'eglot-flymake-backend 'flymake-always-safe) t)
        :shorthands (and (memq #'drgnx-trust--drop-shorthands (default-value 'before-hack-local-variables-hook)) t)
        :compile (and (advice-member-p #'drgnx-trust--compile-file-args 'compilation-get-file-structure)
                      (advice-member-p #'drgnx-trust--compile-dir-props 'compilation-directory-properties) t)
        :trusted trusted-content))

(defun drgnx-trust-link-ok-p (target &optional source)
  "May a link to TARGET, found in the buffer SOURCE (default: the current one), be followed?  Yes unless TARGET
is remote and SOURCE is not: a remote name taken from local text is never visited."
  (with-current-buffer (or source (current-buffer))
    (and (or (not (file-remote-p target)) (file-remote-p default-directory)) t)))

(defun drgnx-trust-setup ()
  "The Trust commands, and the guards on (core/basics calls this at startup)."
  (drgnx-command-define 'trust-folder :category "File" :title "Trust This Folder" :command #'drgnx-trust-folder
                        :when (lambda () buffer-file-name)
                        :doc "Trust this project's folder: its Flymake checkers and symbol shorthands run")
  (drgnx-command-define 'untrust-folder :category "File" :title "Untrust This Folder"
                        :command #'drgnx-trust-untrust-folder :when #'drgnx-trust--user-entry
                        :doc "Stop trusting the folder you trusted that holds this file")
  (drgnx-trust-mode 1))

(provide 'drgnx-trust)
;;; drgnx-trust.el ends here
