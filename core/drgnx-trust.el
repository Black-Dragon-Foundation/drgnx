;;; drgnx-trust.el --- Trusted folders, and guards for files from the others -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Files from a folder the user has not trusted must not make Emacs run checkers or code they did not ask for.
;; The trusted set is Emacs's own `trusted-content': drgnx's checkout, config and packages dirs, Emacs's Lisp, and the
;; folders the user trusted with Trust This Folder (kept in trusted-folders.eld in drgnx's state dir).  Outside it:
;; - Flymake runs only backends marked `flymake-always-safe' (eglot's is): an advice on builds whose
;;   `flymake--run-backend' has no trust check of its own;
;; - a file's `read-symbol-shorthands' is held back (and given back when its folder is trusted);
;; - always: TRAMP ignores names with a control character, or whose user@host part holds a shell character,
;;   compile or grep output in a local buffer never names a remote file or directory, and ffap pings no host.
;; A quiet "restricted" mark in the mode line shows a local file outside the trusted set; clicking it trusts the
;; folder.  Nothing here prompts.  docs/guide/security.md.

;;; Code:
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)
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
  "drgnx's own trees (the checkout, the config dir, the packages dir) and Emacs's own Lisp."
  (delete-dups (mapcar #'drgnx-trust--entry (list drgnx-dir (drgnx-user-dir) (drgnx-elpa-dir) lisp-directory))))

(defconst drgnx-trust--header ";; drgnx: the folders you trusted (Trust This Folder; docs/guide/security.md)\n"
  "The comment line trusted-folders.eld starts with.")

(defun drgnx-trust--folders-of (data)
  "The folders DATA, trusted-folders.eld's form, lists: a list of strings (nil for no file), else `newer' when a
newer drgnx wrote it (:version above 1), or `bad' for a mistake.  A missing :version is version 1."
  (let ((version (and (plistp data) (plist-get data :version))) (folders (and (plistp data) (plist-get data :folders))))
    (cond ((null data) nil)
          ((not (plistp data)) 'bad)
          ((and (natnump version) (> version 1)) 'newer)
          ((not (memq version '(nil 1))) 'bad)
          ((not (plist-member data :folders)) 'bad)
          ((not (and (proper-list-p folders) (seq-every-p #'stringp folders))) 'bad)
          (t folders))))

(defvar drgnx-trust--told nil
  "(STAMP WHY) of the unusable trusted-folders.eld the user was told about, so that each change is told once.")

(defvar drgnx-trust--added nil
  "The user's folders drgnx put into `trusted-content' this session (from trusted-folders.eld or Trust This
Folder): Untrust This Folder can take them back even when the file has since become unusable.")

(defun drgnx-trust--read ()
  "trusted-folders.eld: (t . FOLDERS), FOLDERS nil when there is none, or (nil . WHY) when it cannot be used
\(unreadable, a mistake, or a newer drgnx's): then it trusts nothing, never a part of it or an older copy, and a
message says WHY once per change of the file.  Only entries `drgnx-trust--read-entry-p' accepts are kept."
  (let* ((file (drgnx-trust-folders-file)) (r (drgnx-file-read file)) (status (plist-get r :status))
         (folders (and (eq status 'ok) (drgnx-trust--folders-of (plist-get r :data))))
         (why (cond ((eq status 'unreadable) (format "cannot be read: %s" (plist-get (plist-get r :problem) :text)))
                    ((eq folders 'newer) "was written by a newer drgnx")
                    ((eq folders 'bad) "has a mistake (:folders must be a list of folder names)"))))
    (if (not why)
        (progn (setq drgnx-trust--told nil) (cons t (seq-filter #'drgnx-trust--read-entry-p folders)))
      (setq why (format "%s %s" (abbreviate-file-name file) why))
      (unless (equal drgnx-trust--told (list (plist-get r :stamp) why))
        (setq drgnx-trust--told (list (plist-get r :stamp) why))
        (message "drgnx: no folder you trusted is trusted: %s" why))
      (cons nil why))))

(defun drgnx-trust-folders ()
  "The folders the user trusted, as trusted-folders.eld holds them (none when it cannot be used)."
  (let ((r (drgnx-trust--read))) (and (car r) (cdr r))))

(defun drgnx-trust--known ()
  "The folders Untrust This Folder can take back: trusted-folders.eld's and those trusted this session."
  (seq-union (drgnx-trust-folders) drgnx-trust--added))

(defun drgnx-trust--write (fn)
  "Change trusted-folders.eld under its lock: FN gets the folders in it now and returns the new list, so two
changes at once both stay.  Only :folders changes; other keys are kept.  A file that cannot be read or holds a
mistake is copied aside (NAME.bak-…) and FN gets nil; a newer drgnx's file is a `user-error', left as it is."
  (let ((file (drgnx-trust-folders-file)))
    (drgnx-file-update
     file
     (lambda (data)
       (let ((old (drgnx-trust--folders-of data)))
         (pcase old
           ('newer (user-error "%s was written by a newer drgnx, which this one never changes: trust folders there"
                               (abbreviate-file-name file)))
           ('bad (drgnx-file-backup file) (setq data nil old nil)))
         (let ((new (funcall fn old)))
           (if (and data (equal new old)) data
             (plist-put (or data (list :version 1 :folders nil)) :folders new)))))
     :on-unreadable 'backup :pretty t :header drgnx-trust--header)))

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

(defconst drgnx-trust--mark-help
  "Restricted Mode: this folder is not trusted, so Flymake checkers and symbol shorthands from its files are off.
Click, or run Trust This Folder, to trust it."
  "What Restricted Mode is and how to leave it: the mark's help text.")

(defconst drgnx-trust--mark-text
  (propertize " Restricted Mode" 'face 'drgnx-trust-restricted 'mouse-face 'mode-line-highlight 'local-map drgnx-trust-mark-map
              'help-echo drgnx-trust--mark-help)
  "The mark.")

(defun drgnx-trust--mark ()
  "The mode-line mark: \"Restricted Mode\" for a local file outside the trusted set, else nothing."
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
               (or (seq "-" (not (any ":")))              ; a user starting with -: an ssh option (/-: is a method)
                   (seq (* (not (any ":|[@"))) "@-")     ; a host starting with -
                   (seq (* (not (any ":|[")))
                        (or (any "](){}`;&<>!'\"\\*?," blank)
                            (seq "$" (or eos (not (any "_" alnum))))))))))
  "Names TRAMP must not handle: a control character anywhere, or a user@host part whose user or host starts with -
or that holds a shell character.  $VAR is fine: TRAMP expands it before it checks this.")

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

(defconst drgnx-trust--shared-dirs '("/tmp/" "/var/tmp/" "/dev/shm/")
  "Folders anyone may write to, whatever the temp dir is.")

(defun drgnx-trust--broad-p (entry)
  "Is ENTRY (as `drgnx-trust--entry' gives it) `/', home, the temp dir or a folder of `drgnx-trust--shared-dirs', or
one of their ancestors?"
  (let ((dir (file-truename (expand-file-name entry))))
    (seq-some (lambda (d) (string-prefix-p dir (file-name-as-directory (file-truename d))))
              (cons "~" (cons temporary-file-directory drgnx-trust--shared-dirs)))))

(defun drgnx-trust--read-entry-p (entry)
  "Is ENTRY, read from trusted-folders.eld, one to trust?  Not a remote name (`file-remote-p' only parses it: it
never connects, also for an unknown method), and not one Trust This Folder refuses, its truenames taken with no
file name handlers.  An entry that signals is not trusted.  Called at startup and from the palette: nothing here
connects or prompts."
  (condition-case nil
      (and (not (file-remote-p entry))
           (let ((file-name-handler-alist nil)) (not (drgnx-trust--broad-p entry))))
    (error nil)))

(defun drgnx-trust--user-entry ()
  "The user-trusted folder holding this buffer's file, or nil."
  (when buffer-file-truename
    (let ((name (abbreviate-file-name buffer-file-truename)))
      (seq-find (lambda (f) (string-prefix-p f name)) (drgnx-trust--known)))))

(defun drgnx-trust--refresh ()
  "After trust changed: every file buffer's mark, held shorthands and Flymake follow it."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when buffer-file-name
        (let ((was drgnx-trust--state))
          (drgnx-trust--update)
          (cond ((and drgnx-trust--held-shorthands (eq drgnx-trust--state 'trusted))
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
its files.  Kept in drgnx's state (trusted-folders.eld).  A remote folder is refused: its entry would never be
read back (`drgnx-trust--read-entry-p')."
  (interactive)
  (let* ((folder (or dir (drgnx-trust--folder)))
         (e (if (file-remote-p folder)
                (user-error "%s is remote: Trust This Folder trusts local folders (remote files are never marked)" folder)
              (drgnx-trust--entry folder))))
    (when (drgnx-trust--broad-p e)
      (user-error "%s holds far more than one project: open a file in a project folder below it and trust that" e))
    (drgnx-trust--write (lambda (folders) (if (member e folders) folders (append folders (list e)))))
    (drgnx-trust--add (list e))
    (unless (member e drgnx-trust--added) (push e drgnx-trust--added))
    (drgnx-trust--refresh)
    (message "Trusted %s" e)
    e))

(defun drgnx-trust-untrust-folder (&optional dir)
  "Stop trusting DIR (default: the folder you trusted that holds this buffer's file).  It takes effect at once,
also when trusted-folders.eld cannot be changed (unusable, or a newer drgnx's): then the message says the folder
is untrusted for this session only, and why."
  (interactive)
  (let ((e (if dir (drgnx-trust--entry dir) (drgnx-trust--user-entry))) (r (drgnx-trust--read)))
    (unless (and e (member e (drgnx-trust--known)))
      (user-error "Not a folder you trusted (drgnx's own folders stay trusted)"))
    (setq drgnx-trust--added (delete e drgnx-trust--added))
    (unless (or (eq trusted-content :all) (member e (drgnx-trust--builtin)))
      (setq trusted-content (delete e (copy-sequence trusted-content))))
    (drgnx-trust--refresh)
    (let ((not-saved (cond ((not (car r)) (cdr r))
                           ((member e (cdr r))
                            (condition-case err (ignore (drgnx-trust--write (lambda (folders) (remove e folders))))
                              ((user-error file-error) (error-message-string err)))))))
      (if not-saved (message "No longer trusted, for this session only: %s (not saved: %s)" e not-saved)
        (message "No longer trusted: %s" e)))
    e))

;;;; ffap: never ping a host name taken from text

(defvar ffap-machine-p-known)
(defvar auto-revert-remote-files)

(defvar drgnx-trust--ffap-set nil "drgnx set `ffap-machine-p-known' to `reject' (from its default, `ping').")

(defun drgnx-trust--ffap-guard (on)
  "Set (ON non-nil) `ffap-machine-p-known' to `reject' while it is at its default; put the default back after."
  (cond ((and on (or (not (boundp 'ffap-machine-p-known)) (eq ffap-machine-p-known 'ping)))
         (setq ffap-machine-p-known 'reject drgnx-trust--ffap-set t))
        ((and (not on) drgnx-trust--ffap-set)
         (when (eq ffap-machine-p-known 'reject) (setq ffap-machine-p-known 'ping))
         (setq drgnx-trust--ffap-set nil))))

(defvar drgnx-trust--auto-save-set nil
  "drgnx set `remote-file-name-inhibit-auto-save-visited' to t (from its default, nil).")

(defun drgnx-trust--auto-save-guard (on)
  "Set (ON non-nil) `remote-file-name-inhibit-auto-save-visited' to t while it is at its default, so that
`auto-save-visited-mode', if the user turns it on, never saves a remote file; put the default back after."
  (cond ((and on (null remote-file-name-inhibit-auto-save-visited))
         (setq remote-file-name-inhibit-auto-save-visited t drgnx-trust--auto-save-set t))
        ((and (not on) drgnx-trust--auto-save-set)
         (when (eq remote-file-name-inhibit-auto-save-visited t) (setq remote-file-name-inhibit-auto-save-visited nil))
         (setq drgnx-trust--auto-save-set nil))))

;;;; The mode, and what other parts of drgnx ask

(define-minor-mode drgnx-trust-mode
  "Guards for files from folders the user has not trusted (docs/guide/security.md)."
  :global t :group 'drgnx
  (if drgnx-trust-mode
      (progn
        ;; a state file never stops the guards: whatever its read signals, the user's folders are none
        (let ((user (condition-case err (drgnx-trust-folders)
                      (error (message "drgnx: no folder you trusted is trusted: %s" (error-message-string err))
                             nil))))
          (drgnx-trust--add (append (drgnx-trust--builtin) user))
          (setq drgnx-trust--added (seq-union drgnx-trust--added user)))
        (drgnx-trust--tramp-guard t)
        (drgnx-trust--ffap-guard t)
        (drgnx-trust--auto-save-guard t)
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
    (drgnx-trust--ffap-guard nil)
    (drgnx-trust--auto-save-guard nil)
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
:ffap — `ffap-machine-p-known' is `reject'; :remote-file-name-inhibit-auto-save-visited — that setting (drgnx
sets t while it is at its default); :enable-remote-dir-locals, :auto-revert-remote-files — those settings, as
they are (drgnx does not set them; Emacs's defaults, nil, keep them off remote files); :trusted —
`trusted-content'."
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
        :ffap (eq (bound-and-true-p ffap-machine-p-known) 'reject)
        :enable-remote-dir-locals enable-remote-dir-locals
        :auto-revert-remote-files (bound-and-true-p auto-revert-remote-files)
        :remote-file-name-inhibit-auto-save-visited remote-file-name-inhibit-auto-save-visited
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
