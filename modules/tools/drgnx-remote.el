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
;; ssh asks its questions (host keys, passwords) only from those commands.  See docs/guide/remote.md.

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
(declare-function drgnx-lang--maybe-eglot "drgnx-lang")
(declare-function tramp-dissect-file-name "tramp")
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
                             (mapcan (lambda (pattern) (file-expand-wildcards (expand-file-name pattern ssh)))
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
  (let ((root (file-name-as-directory (expand-file-name dir))))
    (drgnx-session-open-folder root)
    (drgnx-remote--remember root)
    (drgnx-lang-probe-remote root)
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
  (let* ((choice (completing-read "Open remote: "
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

(defun drgnx-remote--here ()
  "The connection of the current buffer's file or folder, or nil."
  (let ((name (or buffer-file-name default-directory)))
    (and (stringp name) (file-remote-p name))))

(defun drgnx-remote--shown ()
  "The connection the segment shows: the current buffer's, else the newest remembered one that has a folder in
the Explorer."
  (or (drgnx-remote--here)
      (let ((keys (drgnx-remote--keys)))
        (car (seq-find (lambda (e) (member (car e) keys)) drgnx-remote--roots)))))

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

(defun drgnx-remote-segment ()
  "\"⇄ HOST\" (\"<> HOST\" where the frame cannot show ⇄) while a remote folder is open or the buffer is remote:
green while the connection is up, a warning when it is lost.  Reads the process table only — no I/O, ever."
  (if-let* ((key (drgnx-remote--shown)))
      (let ((up (drgnx-lang--remote-live-p key)) (host (file-remote-p key 'host)))
        (propertize (format "%s %s" (if (char-displayable-p ?⇄) "⇄" "<>") host)
                    'face (if up 'drgnx-remote-connected 'drgnx-remote-lost)
                    'mouse-face 'mode-line-highlight 'local-map drgnx-remote-segment-map
                    'help-echo (format "%s: %s.  Click for Reconnect or Open Remote…" host
                                       (if up "connected" "connection lost"))))
    ""))

(defun drgnx-remote--mode-line ()
  "The segment with a space before it (or nothing)."
  (let ((s (drgnx-remote-segment))) (if (string-empty-p s) "" (concat " " s))))

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
  (let* ((key (or key (drgnx-remote--pick))) (host (file-remote-p key 'host))
         (root (drgnx-remote--root key)) (code (drgnx-remote--code-buffers key)))
    (dolist (server (drgnx-remote--servers key))
      (with-demoted-errors "Remote: language server: %S" (eglot-shutdown server nil 2 t)))
    (tramp-cleanup-connection (tramp-dissect-file-name key) t t)
    (condition-case err (file-directory-p root)
      (error (user-error "Cannot reconnect to %s: %s" host (error-message-string err))))
    (unless (drgnx-lang--remote-live-p key) (user-error "Cannot reconnect to %s" host))
    (drgnx-lang-probe-remote root)
    (dolist (b code)
      (when (buffer-live-p b) (with-current-buffer b (drgnx-lang--maybe-eglot))))
    (force-mode-line-update t)
    (message "Reconnected to %s" host)))

;;;; The module

(defconst drgnx-remote--mode-line-entry '(:eval (drgnx-remote--mode-line)))

(defun drgnx-remote--setup ()
  "Define the commands and put the segment on the mode line."
  (drgnx-command-define 'remote-open :category "Remote" :title "Open Remote…" :command #'drgnx-remote-open
                        :doc "Edit on another machine: pick an ssh host or a podman container, then a folder")
  (drgnx-command-define 'remote-reconnect :category "Remote" :title "Reconnect" :command #'drgnx-remote-reconnect
                        :doc "Bring a lost remote connection back; buffers, changes and language servers continue")
  (add-to-list 'global-mode-string drgnx-remote--mode-line-entry t))

(drgnx-module-define 'tools/remote
                     :doc "Open Remote… (ssh hosts, podman containers), a status-line segment, Reconnect, language servers on the remote side"
                     :stage 'idle
                     :setup #'drgnx-remote--setup)

(provide 'drgnx-remote)
;;; drgnx-remote.el ends here
