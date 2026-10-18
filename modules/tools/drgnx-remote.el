;;; drgnx-remote.el --- Module tools/remote: Open Remote…, the remote segment, Reconnect -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Edit on another machine (ssh) or in a podman container through TRAMP, as VS Code's Remote: Open Remote…
;; picks a host from ~/.ssh/config or a running container, then a folder, which becomes an Explorer folder.  A
;; status-line segment shows the host and whether the connection is up; Reconnect brings a lost connection back
;; without closing a buffer; language servers run on the remote side (lang/eglot reads what Open Remote… found).
;;
;; Everything that reaches a remote is a command the user ran: Open Remote…, Reconnect, a typed ssh path.
;; Nothing automatic does — the segment and the hook only read the process table and what the commands stored;
;; ssh asks its questions (host keys, passwords) only from those commands: while the module is on, TRAMP's password,
;; yes/no and one-time-password questions are refused unless a command of the user is running
;; (`drgnx-lang--user-command-p': kept from `pre-command-hook' and `post-command-hook', and false in a timer, a process
;; filter or a sentinel that fires meanwhile) or one of these commands bound `drgnx-remote-may-prompt'.  See docs/guide/remote.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
;; The remote side of lang/eglot is that module's (its file sits beside the tools folder).
(unless (featurep 'drgnx-lang)
  (load (expand-file-name "../lang/drgnx-lang" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(declare-function drgnx-session-open-folder "drgnx-session")
(declare-function drgnx-explorer-roots "drgnx-explorer")
(declare-function drgnx-lang-probe-remote "drgnx-lang")
(declare-function drgnx-lang--remote-live-p "drgnx-lang")
(declare-function drgnx-lang-start-remote-server "drgnx-lang")
(defvar drgnx-lang--user-command)
(defvar drgnx-lang--remote-pending)
(defvar drgnx-lang--attaching)
(defvar drgnx-explorer--remote-reads)
(declare-function tramp-dissect-file-name "tramp")
(declare-function tramp-get-connection-process "tramp")
(declare-function tramp-cleanup-connection "tramp-cmds")
(declare-function eglot-shutdown "eglot")
(declare-function eglot--project "eglot")
(declare-function project-root "project")
(defvar eglot--servers-by-project)

(defvar drgnx-remote-podman-timeout 5 "Seconds `podman ps' may take when Open Remote… lists the containers.")

(defface drgnx-remote-connected '((t :inherit success))
  "The remote segment while its connection is up." :group 'drgnx)

(defface drgnx-remote-lost '((t :inherit warning))
  "The remote segment while its connection is down (Reconnect brings it back)." :group 'drgnx)

(defvar drgnx-remote-may-prompt nil
  "Non-nil while Open Remote… or Reconnect run: TRAMP may ask for a password, a host key or a code.")

(defvar drgnx-remote--roots nil
  "Alist CONNECTION (\"/ssh:HOST:\") → (:root DIR): the folders Open Remote… opened, the newest first.")

;;;; Hosts and containers

(defun drgnx-remote--config-lines (file regexp)
  "The first group of REGEXP (anchored at a line start, case-insensitive) for every line of FILE that matches."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((case-fold-search t) found)
        (while (re-search-forward regexp nil t) (push (string-trim (match-string 1)) found))
        (nreverse found)))))

(defun drgnx-remote--config-hosts (file)
  "The host names the Host lines of the ssh config FILE give — patterns (`*', `?', `!') are not names."
  (seq-remove (lambda (h) (string-match-p "[*?!]" h))
              (mapcan (lambda (line) (split-string line "[ \t]+" t))
                      (drgnx-remote--config-lines file "^[ \t]*host[ \t=]+\\([^#\n]*\\)"))))

(defun drgnx-remote-ssh-hosts ()
  "The host names in ~/.ssh/config and the files it includes (one level, globs allowed), without patterns."
  (let* ((ssh (file-name-as-directory (expand-file-name "~/.ssh")))
         (config (expand-file-name "config" ssh))
         (included (mapcan (lambda (line)
                             (mapcan (lambda (pattern) (seq-filter #'file-regular-p (file-expand-wildcards (expand-file-name pattern ssh))))
                                     (split-string line "[ \t]+" t)))
                           (drgnx-remote--config-lines config "^[ \t]*include[ \t=]+\\([^#\n]*\\)"))))
    (delete-dups (append (drgnx-remote--config-hosts config) (mapcan #'drgnx-remote--config-hosts included)))))

(defun drgnx-remote-containers ()
  "The names of the running podman containers, or nil without podman (or when it takes longer than
`drgnx-remote-podman-timeout' seconds)."
  (let* ((default-directory (file-name-as-directory temporary-file-directory))     ; local, whatever the buffer
         (podman (executable-find "podman")))
    (when podman
      (let* ((out (generate-new-buffer " *drgnx-podman*" t))
             (proc (make-process :name "drgnx-podman" :buffer out :noquery t :connection-type 'pipe :sentinel #'ignore
                                 :command (list podman "ps" "--format" "{{.Names}}")))
             (deadline (+ (float-time) drgnx-remote-podman-timeout)))
        (unwind-protect
            (progn
              (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output proc 0.05))
              (if (process-live-p proc) (delete-process proc)
                (when (eql (process-exit-status proc) 0)
                  (with-current-buffer out (split-string (buffer-string) "\n" t)))))
          (when (process-live-p proc) (delete-process proc))
          (kill-buffer out))))))

;;;; Open Remote…

(defun drgnx-remote--remember (root)
  "Remember the folder ROOT as the newest one of its connection."
  (let ((key (file-remote-p root)))
    (setq drgnx-remote--roots (cons (cons key (list :root root)) (assoc-delete-all key drgnx-remote--roots)))))

(defun drgnx-remote-open-folder (dir)
  "Show the remote folder DIR as the Explorer's first folder, remember its connection and look for the language
servers on its host.  Opens the connection if it is not up (the user ran the command that got us here)."
  (let* ((drgnx-remote-may-prompt t)
         (root (file-name-as-directory (expand-file-name dir))))
    (drgnx-session-open-folder root)
    (drgnx-remote--remember root)
    (drgnx-lang-probe-remote root)
    (drgnx-remote--start-servers (file-remote-p root))
    (drgnx-remote--forget (file-remote-p root))
    (force-mode-line-update t)
    root))

(defun drgnx-remote--other-start ()
  "A start folder for \"Other host…\": the user's own TRAMP name, or a host (USER@HOST) reached by ssh."
  (let ((answer (string-trim (read-string "Host (USER@HOST), or a name such as /ssh:HOST:/path: "))))
    (when (string-empty-p answer) (user-error "No host given"))
    (if (string-prefix-p "/" answer) (file-name-as-directory answer) (format "/ssh:%s:~/" answer))))

(defun drgnx-remote-open ()
  "Pick an ssh host or a podman container (or type another host), then a folder on it, and open it as an
Explorer folder.  ssh asks for host keys and passwords here, as it does for `C-x C-f /ssh:HOST:'."
  (interactive)
  (require 'tramp)
  (let* ((drgnx-remote-may-prompt t)
         (choice (completing-read "Open remote: "
                                  (append (mapcar (lambda (h) (concat "ssh: " h)) (drgnx-remote-ssh-hosts))
                                          (mapcar (lambda (c) (concat "podman: " c)) (drgnx-remote-containers))
                                          (list "Other host…"))
                                  nil t))
         (start (cond ((string-prefix-p "ssh: " choice) (format "/ssh:%s:~/" (substring choice 5)))
                      ((string-prefix-p "podman: " choice) (format "/podman:%s:/" (substring choice 8)))
                      (t (drgnx-remote--other-start)))))
    (drgnx-remote-open-folder (read-directory-name "Remote folder: " start nil t))))

;;;; The status-line segment

(defun drgnx-remote--explorer-roots ()
  "The Explorer's folders (every remembered root when there is no Explorer)."
  (if (fboundp 'drgnx-explorer-roots) (drgnx-explorer-roots)
    (mapcar (lambda (e) (plist-get (cdr e) :root)) drgnx-remote--roots)))

(defun drgnx-remote--keys ()
  "The connections of the Explorer's remote folders, without duplicates."
  (delete-dups (delq nil (mapcar (lambda (r) (and (stringp r) (file-remote-p r))) (drgnx-remote--explorer-roots)))))

;; The segment is evaluated for every mode line on every redisplay: everything it needs is kept here, worked out again
;; only when what it depends on changes (a buffer's name, the Explorer's folders, the connection's process).

(defvar-local drgnx-remote--here-cache nil
  "(NAME . CONNECTION): the buffer's file or folder name (the string itself, compared with `eq') and its connection.")

(defvar drgnx-remote--shown-cache nil
  "(EXPLORER-ROOTS ROOTS . CONNECTION): the connection shown for a local buffer, for these two lists (compared with
`eq': both are replaced, never changed in place).")

(defvar drgnx-remote--processes (make-hash-table :test #'equal)
  "Connection → (PROCESS . TIME): its TRAMP connection process as last looked up, and when.  Liveness is then
`process-live-p'; a connection that is not up is looked up again at most every two seconds (or at once after Open
Remote… or Reconnect, which forget it).  Bounded: emptied when it holds more than 32 connections.")

(defvar drgnx-remote--segments (make-hash-table :test #'equal)
  "Connection → a vector of its four segment strings (up or lost, ⇄ or <>), each with a space before it, made once.
Bounded: emptied when it holds more than 32 connections.")

(defvar drgnx-remote--arrows (make-hash-table :test #'eq :weakness 'key)
  "Terminal → `yes' when its frames can draw ⇄, else `no' (asked once per terminal).")

(defun drgnx-remote--here ()
  "The connection of the current buffer's file or folder, or nil (worked out again when the name changes)."
  (let ((name (or buffer-file-name default-directory)))
    (if (and drgnx-remote--here-cache (eq (car drgnx-remote--here-cache) name))
        (cdr drgnx-remote--here-cache)
      (let ((key (and (stringp name) (file-remote-p name))))
        (setq drgnx-remote--here-cache (cons name key))
        key))))

(defun drgnx-remote--shown ()
  "The connection the segment shows: the current buffer's, else the newest remembered one that has a folder in
the Explorer."
  (or (drgnx-remote--here)
      (let ((roots (and (fboundp 'drgnx-explorer-roots) (drgnx-explorer-roots))))
        (if (and drgnx-remote--shown-cache (eq (car drgnx-remote--shown-cache) roots)
                 (eq (cadr drgnx-remote--shown-cache) drgnx-remote--roots))
            (cddr drgnx-remote--shown-cache)
          (let* ((keys (drgnx-remote--keys))
                 (key (car (seq-find (lambda (e) (member (car e) keys)) drgnx-remote--roots))))
            (setq drgnx-remote--shown-cache (cons roots (cons drgnx-remote--roots key)))
            key)))))

(defun drgnx-remote--up-p (key)
  "Is the connection KEY up?  The process table only (`drgnx-remote--processes')."
  (let ((hit (gethash key drgnx-remote--processes)))
    (or (and hit (process-live-p (car hit)))
        (when (or (null hit) (> (- (float-time) (cdr hit)) 2))
          (let ((proc (and (featurep 'tramp)
                           (ignore-errors (tramp-get-connection-process (tramp-dissect-file-name key))))))
            (when (> (hash-table-count drgnx-remote--processes) 32) (clrhash drgnx-remote--processes))
            (puthash key (cons proc (float-time)) drgnx-remote--processes)
            (and proc (process-live-p proc) t))))))

(defun drgnx-remote--forget (key)
  "The connection KEY was just opened again: the segment looks its process up at once."
  (remhash key drgnx-remote--processes))

(defun drgnx-remote--arrows-p ()
  "Can the selected frame's terminal draw ⇄?  Asked once per terminal."
  (let* ((terminal (frame-terminal)) (v (gethash terminal drgnx-remote--arrows)))
    (unless v
      (setq v (if (char-displayable-p ?⇄) 'yes 'no))
      (puthash terminal v drgnx-remote--arrows))
    (eq v 'yes)))

(defun drgnx-remote-menu (event)
  "Offer Reconnect and Open Remote… (a click on the segment).  EVENT is the click."
  (interactive "e")
  (let ((win (posn-window (event-start event))))
    (with-selected-window (if (window-live-p win) win (selected-window))
      (pcase (completing-read "Remote: " '("Reconnect" "Open Remote…") nil t)
        ("Reconnect" (call-interactively #'drgnx-remote-reconnect))
        ("Open Remote…" (call-interactively #'drgnx-remote-open))))))

(defvar drgnx-remote-segment-map
  (let ((m (make-sparse-keymap))) (define-key m [mode-line mouse-1] #'drgnx-remote-menu) m)
  "A click on the segment.")

(defun drgnx-remote--strings (key)
  "The four segment strings of the connection KEY (`drgnx-remote--segments')."
  (or (gethash key drgnx-remote--segments)
      (let* ((host (file-remote-p key 'host))
             (make (lambda (up arrows)
                     (concat " " (propertize (format "%s %s" (if arrows "⇄" "<>") host)
                                             'face (if up 'drgnx-remote-connected 'drgnx-remote-lost)
                                             'mouse-face 'mode-line-highlight 'local-map drgnx-remote-segment-map
                                             'help-echo (format "%s: %s.  Click for Reconnect or Open Remote…" host
                                                                (if up "connected" "connection lost")))))))
        (when (> (hash-table-count drgnx-remote--segments) 32) (clrhash drgnx-remote--segments))
        (puthash key (vector (funcall make t t) (funcall make nil t) (funcall make t nil) (funcall make nil nil))
                 drgnx-remote--segments))))

(defun drgnx-remote--mode-line ()
  "The segment with a space before it, or \"\": a string made once (`drgnx-remote--strings'), chosen by the
connection's state and the terminal — no I/O, no new string."
  (if-let* ((key (drgnx-remote--shown)))
      (aref (drgnx-remote--strings key) (+ (if (drgnx-remote--up-p key) 0 1) (if (drgnx-remote--arrows-p) 0 2)))
    ""))

(defun drgnx-remote-segment ()
  "\"⇄ HOST\" (\"<> HOST\" where the frame cannot show ⇄) while a remote folder is open or the buffer is remote:
green while the connection is up, a warning when it is lost.  Reads the process table only — no I/O, ever."
  (let ((s (drgnx-remote--mode-line))) (if (string-empty-p s) "" (substring s 1))))

;;;; Reconnect

(defun drgnx-remote--pick ()
  "The connection to reconnect: the current buffer's, else the Explorer's (asking when it has several)."
  (or (drgnx-remote--here)
      (pcase (drgnx-remote--keys)
        ('nil (user-error "No remote folder or file is open"))
        (`(,only) only)
        (keys (completing-read "Reconnect: " keys nil t)))))

(defun drgnx-remote--root (key)
  "A folder on the connection KEY to read when reconnecting: the one Open Remote… opened, else an Explorer
folder of it, else its home."
  (or (plist-get (cdr (assoc key drgnx-remote--roots)) :root)
      (seq-find (lambda (r) (equal (file-remote-p r) key)) (drgnx-remote--explorer-roots))
      (concat key "~/")))

(defun drgnx-remote--code-buffers (key)
  "The code buffers visiting files on the connection KEY."
  (seq-filter (lambda (b) (and (buffer-file-name b) (equal (file-remote-p (buffer-file-name b)) key)
                               (provided-mode-derived-p (buffer-local-value 'major-mode b) 'prog-mode)))
              (buffer-list)))

(defun drgnx-remote--start-servers (key)
  "Start a language server in the code buffers of the connection KEY that the probe found one for."
  (setq drgnx-lang--remote-pending       ; this host's starts are forgotten: its servers were just stopped
        (seq-remove (lambda (p) (equal (file-remote-p (caar p)) key)) drgnx-lang--remote-pending))
  (dolist (b (drgnx-remote--code-buffers key))
    (drgnx-lang-start-remote-server b)))

(defun drgnx-remote--servers (key)
  "The eglot servers running on the connection KEY."
  (when (and (featurep 'eglot) (boundp 'eglot--servers-by-project))
    (let (servers)
      (maphash (lambda (_project list)
                 (dolist (s list)
                   (when (equal (ignore-errors (file-remote-p (project-root (eglot--project s)))) key) (push s servers))))
               eglot--servers-by-project)
      (delete-dups servers))))

(defun drgnx-remote-reconnect (&optional key)
  "Bring the connection KEY back (default: the current buffer's, else the Explorer's): stop its language
servers without closing their buffers, close the connection, open it again by reading the folder, look for the
servers again and start them in its code buffers.  Buffers, their unsaved changes and point stay."
  (interactive (list (drgnx-remote--pick)))
  (require 'tramp)
  (let* ((drgnx-remote-may-prompt t) (key (or key (drgnx-remote--pick))) (host (file-remote-p key 'host))
         (root (drgnx-remote--root key)))
    (dolist (server (drgnx-remote--servers key))
      (with-demoted-errors "Remote: language server: %S" (eglot-shutdown server nil 2 t)))
    (tramp-cleanup-connection (tramp-dissect-file-name key) t t t)   ; keep other processes (shells) of the host
    (condition-case err (file-directory-p root)
      (error (user-error "Cannot reconnect to %s: %s" host (error-message-string err))))
    (unless (drgnx-lang--remote-live-p key) (user-error "Cannot reconnect to %s" host))
    (drgnx-lang-probe-remote root)
    (drgnx-remote--start-servers key)
    (drgnx-remote--forget key)
    (force-mode-line-update t)
    (message "Reconnected to %s" host)))

;;;; The module

(defconst drgnx-remote--mode-line-entry '(:eval (drgnx-remote--mode-line)))

(defconst drgnx-remote--prompt-functions
  '(tramp-action-login tramp-action-password tramp-action-yesno tramp-action-yn tramp-action-otp-password
                       tramp-action-show-and-confirm-message)
  "What TRAMP calls to ask the user something while it logs in.")

(defun drgnx-remote--guard-prompt (ask &rest args)
  "Around advice of `drgnx-remote--prompt-functions': call ASK (with ARGS) while a command of the user is running or
one of the Remote commands asked for it (`drgnx-remote-may-prompt'); otherwise refuse, so that a login nobody asked
for (a timer, a sentinel, a language server) fails with an error instead of freezing Emacs on a hidden question."
  (if (and (not inhibit-quit) (or drgnx-remote-may-prompt drgnx-lang--user-command))
      (apply ask args)
    (signal 'remote-file-error
            (list "A remote asked a question outside of a command of yours; use Reconnect or Open Remote…"))))

(defun drgnx-remote--timer-without-command (run timer)
  "Around advice of `timer-event-handler': a timer is never part of the command that happens to wait while it
fires, whatever its body does with `inhibit-quit' (`with-local-quit').  Nor does it list a remote folder in the
Explorer, if it fires while the user's listing waits for the host (Find's own timer binds the variable again), nor
attach a buffer to a server on the strength of the attaching that is going on."
  (let ((drgnx-lang--user-command nil) (drgnx-lang--attaching nil) (drgnx-remote-may-prompt nil)
        (drgnx-explorer--remote-reads nil))
    (funcall run timer)))

(defun drgnx-remote--command-start ()
  "In `pre-command-hook': a command of the user starts."
  (setq drgnx-lang--user-command t))

(defun drgnx-remote--command-end ()
  "In `post-command-hook': the command is done (a key in the minibuffer is not the outer command's end)."
  (when (zerop (minibuffer-depth)) (setq drgnx-lang--user-command nil)))

(defun drgnx-remote--command-failed (&rest _)
  "Before `command-error-function': a command that ends in an error or C-g runs no `post-command-hook'."
  (setq drgnx-lang--user-command nil))

(defvar tramp-auto-save-directory)

(defvar drgnx-remote--auto-save-directory nil
  "The folder `drgnx-remote--setup' gave TRAMP's auto-save files, or nil when the user had set one of their own.")

(defun drgnx-remote--private-auto-saves ()
  "Unless the user set `tramp-auto-save-directory', make it a private folder (0700) in drgnx's state dir.  Outside
the temp dir, a root-owned remote file (any container's) has its auto-save file there without TRAMP asking
\"Autosave file on local temporary directory, do you want to continue?\" — a question that would freeze a daemon or a
sentinel that visits it."
  (unless (bound-and-true-p tramp-auto-save-directory)
    (let ((d (file-name-as-directory (expand-file-name "tramp-auto-save" (drgnx-state-dir)))))
      (with-file-modes #o700 (make-directory d t))
      (set-file-modes d #o700)
      (setq tramp-auto-save-directory d drgnx-remote--auto-save-directory d))))

(defun drgnx-remote--setup ()
  "Define the commands, put the segment on the mode line, follow the user's commands, guard TRAMP's questions and
keep remote auto-save files in a private folder."
  (drgnx-command-define 'remote-open :category "Remote" :title "Open Remote…" :command #'drgnx-remote-open
                        :doc "Edit on another machine: pick an ssh host or a podman container, then a folder")
  (drgnx-command-define 'remote-reconnect :category "Remote" :title "Reconnect" :command #'drgnx-remote-reconnect
                        :doc "Bring a lost remote connection back; buffers and changes stay, language servers start again")
  (add-to-list 'global-mode-string drgnx-remote--mode-line-entry t)
  (add-hook 'pre-command-hook #'drgnx-remote--command-start)
  (add-hook 'post-command-hook #'drgnx-remote--command-end)
  (add-function :before command-error-function #'drgnx-remote--command-failed)
  (advice-add 'timer-event-handler :around #'drgnx-remote--timer-without-command)
  (dolist (f drgnx-remote--prompt-functions) (advice-add f :around #'drgnx-remote--guard-prompt))
  (drgnx-remote--private-auto-saves))

(defun drgnx-remote--teardown ()
  "Undo `drgnx-remote--setup' except the commands (modules are switched off at the next start; tests use this)."
  (setq global-mode-string (delete drgnx-remote--mode-line-entry global-mode-string))
  (remove-hook 'pre-command-hook #'drgnx-remote--command-start)
  (remove-hook 'post-command-hook #'drgnx-remote--command-end)
  (remove-function command-error-function #'drgnx-remote--command-failed)
  (advice-remove 'timer-event-handler #'drgnx-remote--timer-without-command)
  (dolist (f drgnx-remote--prompt-functions) (advice-remove f #'drgnx-remote--guard-prompt))
  (when (and drgnx-remote--auto-save-directory
             (equal (bound-and-true-p tramp-auto-save-directory) drgnx-remote--auto-save-directory))
    (setq tramp-auto-save-directory nil))
  (setq drgnx-remote--auto-save-directory nil drgnx-lang--user-command nil))

(drgnx-module-define 'tools/remote
                     :doc "Open Remote… (ssh hosts, podman containers), a status-line segment, Reconnect, language servers on the remote side"
                     :stage 'idle
                     :setup #'drgnx-remote--setup)

(provide 'drgnx-remote)
;;; drgnx-remote.el ends here
