;;; drgnx-lang.el --- Module lang/eglot: language servers, tree-sitter, code navigation -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Code buffers get a language server (eglot) when the server for their mode is installed — never a
;; question about which server to run — and the tree-sitter mode when its grammar is installed.
;; Go to Definition, Find References, Rename Symbol and Show Hover work with or without a server
;; (xref and eldoc fall back on what the mode knows).  See docs/guide/modules.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-modules)
(require 'drgnx-registry)
(defvar drgnx-grammars-modes)
;; The language/mode table is lang/grammars's: one table for both modules (its file sits beside this one).
(unless (featurep 'drgnx-grammars)
  (load (expand-file-name "drgnx-grammars" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(defvar eglot-server-programs)
(defvar warning-minimum-level)
(declare-function eglot--maybe-activate-editing-mode "eglot")
(declare-function eglot--major-modes "eglot")
(defvar xref-prompt-for-identifier)
(declare-function eglot-ensure "eglot")
(declare-function eglot-rename "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot-code-actions "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function eldoc-doc-buffer "eldoc")

(defvar eglot-sync-connect)
(defvar eglot-autoshutdown)

(defun drgnx-lang-remap-modes ()
  "Use the tree-sitter mode of every language whose grammar is installed."
  (when (fboundp 'treesit-language-available-p)
    (pcase-dolist (`(,lang ,mode ,ts . ,_) drgnx-grammars-modes)
      (when (and mode (treesit-language-available-p lang) (fboundp ts))
        (setf (alist-get mode major-mode-remap-alist) ts)))))

(defun drgnx-lang--program (contact)
  "The program CONTACT (an `eglot-server-programs' value) runs, or nil.  A function (such as
`eglot-alternatives') is asked non-interactively; one that would prompt or fails counts as none."
  (pcase contact
    (`(,(and prog (pred stringp)) . ,_) prog)
    ((pred stringp) contact)
    ((pred functionp)
     (let ((inhibit-interaction t))
       (drgnx-lang--program (ignore-errors (if (eql (cdr (func-arity contact)) 1) (funcall contact nil)
                                             (funcall contact nil nil))))))))

(defun drgnx-lang-server-available-p ()
  "Non-nil if a language server for the current major mode is installed (on `exec-path')."
  (require 'eglot)
  (seq-some (lambda (entry)
              (let ((modes (ensure-list (car entry))))
                (and (seq-some (lambda (m) (derived-mode-p (if (consp m) (car m) m))) modes)
                     (when-let* ((prog (drgnx-lang--program (cdr entry)))) (executable-find prog)))))
            eglot-server-programs))

;;;; Language servers on a remote host
;; Nothing here reaches a remote by itself.  `drgnx-lang-probe-remote' runs only from the user's commands (Open
;; Remote…, Reconnect); the hook below reads what it found.  A server starts only inside such a command or a command
;; of the user's that visits the file (`drgnx-lang--user-command'), at once and never from eglot's deferred
;; post-command connect, and eglot never reconnects it by itself: a login that nobody asked for could prompt.

(declare-function tramp-dissect-file-name "tramp")
(declare-function tramp-get-connection-process "tramp")
(declare-function eglot--guess-contact "eglot")
(declare-function eglot "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot--project "eglot")
(declare-function project-root "project")
(declare-function eieio-oref "eieio-core")
(declare-function eieio-oset "eieio-core")
(defvar eglot--managed-mode)
(defvar eglot-connect-timeout)

(defvar drgnx-lang--remote-servers (make-hash-table :test #'equal)
  "Connection (\"/ssh:HOST:\") → what `drgnx-lang-probe-remote' found there: ((MODES . PROGRAM-or-nil)…).")
(defvar drgnx-lang--remote-wanted (make-hash-table :test #'equal)
  "Connection → ((MODES . NAME)…): the program each entry looks for, found or not (the hint names it).")
(defvar drgnx-lang--remote-hinted nil "(CONNECTION . MODE) of the hints already given (one each).")
(defvar drgnx-lang--remote-pending nil
  "((PROJECT-ROOT . CONTACT) . TIME) of the servers just started: a server registers when it has answered, and a
second buffer of the same project must not start another meanwhile.")

(defvar drgnx-lang--user-command nil
  "Non-nil while a command the user ran is executing.  tools/remote keeps it from `pre-command-hook' and
`post-command-hook'; nil in a hook that runs between commands.  A timer, a process filter or a sentinel that runs
while the command waits sees it set, which is why `drgnx-lang--user-command-p' is what to ask.")

(defun drgnx-lang--user-command-p ()
  "Is the code running right now part of a command the user ran?  Not a timer, a process filter or a sentinel that
fires while one waits: C binds `inhibit-quit' for filters and sentinels, and the timer machinery for timers."
  (and drgnx-lang--user-command (not inhibit-quit)))

(defun drgnx-lang--names (contact)
  "The program names CONTACT may run, in the order it tries them; a function (`eglot-alternatives') is asked with
`executable-find' answering nothing, so that every name it looks for is seen without any I/O."
  (if (functionp contact)
      (let ((asked nil))
        (cl-letf (((symbol-function 'executable-find) (lambda (name &rest _) (push name asked) nil)))
          (let ((prog (drgnx-lang--program contact))) (or (nreverse asked) (and prog (list prog))))))
    (when-let* ((prog (drgnx-lang--program contact))) (list prog))))

(defun drgnx-lang--remote-which (names)
  "The ones of NAMES that are on the PATH of the host of `default-directory', asked in one shell call."
  (when names
    (with-temp-buffer
      (process-file "sh" nil t nil "-c"
                    (concat "for p in " (mapconcat (lambda (n) (shell-quote-argument n t)) names " ")
                            "; do command -v \"$p\" >/dev/null 2>&1 && echo \"$p\"; done"))
      (split-string (buffer-string) "\n" t))))

(defun drgnx-lang-probe-remote (root)
  "Look up, on the host of the remote folder ROOT, the program of every `eglot-server-programs' entry (one shell
call for all of them); remember the result for that connection and return it: ((MODES . PROGRAM-or-nil)…).  This
may open the connection, so it is only for the user's commands."
  (require 'eglot)
  (let* ((default-directory root) (key (file-remote-p root))
         (entries (mapcar (lambda (e) (cons (car e) (drgnx-lang--names (cdr e)))) eglot-server-programs))
         (found (drgnx-lang--remote-which (delete-dups (apply #'append (mapcar #'cdr entries))))))
    (puthash key (mapcar (lambda (e) (cons (car e) (seq-find (lambda (n) (member n found)) (cdr e)))) entries)
             drgnx-lang--remote-servers)
    (puthash key (mapcar (lambda (e) (cons (car e) (cadr e))) entries) drgnx-lang--remote-wanted)
    (gethash key drgnx-lang--remote-servers)))

(defun drgnx-lang--remote-live-p (file)
  "Is the connection of the remote FILE up?  Asks the process table only."
  (and (featurep 'tramp)
       (ignore-errors (process-live-p (tramp-get-connection-process (tramp-dissect-file-name file))))))

(defun drgnx-lang--remote-entries (file)
  "What the probe found for the major mode of the buffer visiting the remote FILE: the matching
`drgnx-lang--remote-servers' entries; nil when its connection was never probed."
  (when-let* ((result (gethash (file-remote-p file) drgnx-lang--remote-servers)))
    (seq-filter (lambda (e) (seq-some (lambda (m) (derived-mode-p (if (consp m) (car m) m))) (ensure-list (car e))))
                result)))

(defun drgnx-lang--remote-pending-p (key)
  "Was a server for KEY started in the last `eglot-connect-timeout' seconds (30 without it)?"
  (let ((limit (or (and (boundp 'eglot-connect-timeout) eglot-connect-timeout) 30)))
    (setq drgnx-lang--remote-pending
          (seq-filter (lambda (p) (< (- (float-time) (cdr p)) limit)) drgnx-lang--remote-pending))
    (assoc key drgnx-lang--remote-pending)))

(defun drgnx-lang-start-remote-server (&optional buffer)
  "Start now the language server for the remote code BUFFER (default: the current one), when the probe found one
for its mode, its connection is up and no server manages it.  Returns non-nil when it started one.  For the user's
commands only (Open Remote…, Reconnect, a command that visits the file): it uses the connection, and TRAMP may ask."
  (with-current-buffer (or buffer (current-buffer))
    (when-let* ((file buffer-file-name)
                ((file-remote-p file))
                ((not (bound-and-true-p eglot--managed-mode)))
                (entries (drgnx-lang--remote-entries file))
                ((seq-some #'cdr entries))
                ((drgnx-lang--remote-live-p file)))
      (require 'eglot)
      (condition-case err
          ;; a server of the project that has answered already manages this buffer too, once the mode is set up
          (if-let* ((server (eglot-current-server)))
              (progn (drgnx-lang--attach-buffers server) nil)  ; running already (a Reconnect, say): attach what is left
            (let* ((contact (eglot--guess-contact))
                   (key (cons (project-root (nth 1 contact)) (nth 3 contact))))
              (unless (drgnx-lang--remote-pending-p key)
                (push (cons key (float-time)) drgnx-lang--remote-pending)
                (apply #'eglot contact)
                t)))
        (error (message "No language server started for %s: %s" (file-name-nondirectory file) (error-message-string err))
               nil)))))

(defun drgnx-lang--no-remote-autoreconnect (server)
  "In `eglot-connect-hook': a server whose project is remote is never reconnected by eglot.  Eglot does it from the
server process's sentinel, and TRAMP would log in again there, from nowhere.  (The slot holds the timer of the
first seconds, or t; a buffer-local `eglot-autoreconnect' does not reach it.)"
  (when (ignore-errors (file-remote-p (project-root (eglot--project server))))
    (with-no-warnings                   ; eglot's private slot: the compiler checks it against whichever eglot it sees
      (when (slot-exists-p server 'inhibit-autoreconnect)
        (let ((timer (eieio-oref server 'inhibit-autoreconnect)))
          (when (timerp timer) (cancel-timer timer)))
        (eieio-oset server 'inhibit-autoreconnect t)))))

(defun drgnx-lang--guard-reconnect (reconnect server &rest args)
  "Around advice of `eglot-reconnect': call RECONNECT for SERVER and ARGS, except for a remote server outside a
command of the user's (eglot calls it from the server process's sentinel, and TRAMP would log in again there)."
  (if (or (drgnx-lang--user-command-p)
          (not (ignore-errors (file-remote-p (project-root (eglot--project server))))))
      (apply reconnect server args)
    (message "Not reconnecting the language server of %s by itself: use Reconnect"
             (ignore-errors (file-remote-p (project-root (eglot--project server)) 'host)))
    nil))

(defvar drgnx-lang--attaching nil
  "While `drgnx-lang--attach-buffers' attaches the buffers of a remote server, the expanded root of its project (a
directory name); nil otherwise.  The eglot guard lets through the buffers whose file is under it, and no others.")

(defun drgnx-lang--guard-eglot-activation (activate &rest args)
  "Around advice of `eglot--maybe-activate-editing-mode' (eglot's `after-change-major-mode-hook' function): call
ACTIVATE with ARGS, except in a remote buffer outside a command of the user's.  Eglot asks the buffer's project, and
for a remote buffer that is a round trip (about forty TRAMP calls).  Nothing is asked when skipped; in the command
that visits the file, eglot attaches the buffer to the running server as usual.  Eglot's own loop over all buffers
when a server has answered runs in a process filter, so it is skipped for remote buffers too; the buffers of a
server's project are attached by `drgnx-lang--attach-buffers' (which binds `drgnx-lang--attaching')."
  (when (or (and drgnx-lang--attaching buffer-file-name (string-prefix-p drgnx-lang--attaching buffer-file-name))
            (drgnx-lang--user-command-p)
            (not (file-remote-p default-directory)))
    (apply activate args)))

(defun drgnx-lang--attach-buffers (server)
  "Attach the unmanaged buffers under the remote project of SERVER to it (`eglot-connect-hook', and a start that
finds the server running).  The buffers are chosen by a prefix test on their file names against the project root
\(expanded: the project may say `/method:host:~/proj/', the file names never do) and by the major modes of the
server, with no I/O, so those of other hosts stay as they are.  One buffer that fails does not stop the others."
  (when-let* (((fboundp 'eglot--maybe-activate-editing-mode))
              (root (ignore-errors (project-root (eglot--project server))))
              ((file-remote-p root))
              (modes (condition-case nil (eglot--major-modes server) (error t)))) ; t: no accessor, no filter
    (let ((drgnx-lang--attaching (file-name-as-directory (expand-file-name root))))
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and buffer-file-name (string-prefix-p drgnx-lang--attaching buffer-file-name)
                     (not (bound-and-true-p eglot--managed-mode))
                     (or (eq modes t) (apply #'derived-mode-p modes)))
            (with-demoted-errors "Remote: language server: %S" (eglot--maybe-activate-editing-mode))))))))

(defvar drgnx-lang--eglot-warned nil "Was the missing eglot function reported?")

(defun drgnx-lang--install-eglot-guards ()
  "Put the remote guards on eglot (after it is loaded): no automatic reconnect of a remote server, no attaching of
a remote buffer from outside a command, and the attaching of a server's project after it answered."
  (add-hook 'eglot-connect-hook #'drgnx-lang--no-remote-autoreconnect)
  (add-hook 'eglot-connect-hook #'drgnx-lang--attach-buffers t)   ; after the other connect hooks
  (advice-add 'eglot-reconnect :around #'drgnx-lang--guard-reconnect)
  (if (fboundp 'eglot--maybe-activate-editing-mode)
      (advice-add 'eglot--maybe-activate-editing-mode :around #'drgnx-lang--guard-eglot-activation)
    (unless drgnx-lang--eglot-warned
      (setq drgnx-lang--eglot-warned t)
      ;; Before `after-init-time' a warning is kept and shown later at the global level, with a window: wait for it
      (if after-init-time
          (drgnx-lang--report-missing-activation)
        (add-hook 'after-init-hook #'drgnx-lang--report-missing-activation)))))

(defun drgnx-lang--report-missing-activation ()
  "Log, in *Warnings* and without showing it (this runs at startup, nobody is asked), that this eglot lacks the
function the remote guard is built on."
  (remove-hook 'after-init-hook #'drgnx-lang--report-missing-activation)
  (let ((warning-minimum-level :error))
    (display-warning 'drgnx-lang "This eglot has no `eglot--maybe-activate-editing-mode': the guard that keeps remote buffers from reaching the host on a mode change is off" :warning)))

(defun drgnx-lang--teardown-eglot-guards ()
  "Take the eglot hooks and advice of the module's setup away (tests; modules switch off at the next start)."
  (remove-hook 'eglot-connect-hook #'drgnx-lang--no-remote-autoreconnect)
  (remove-hook 'eglot-connect-hook #'drgnx-lang--attach-buffers)
  (remove-hook 'after-init-hook #'drgnx-lang--report-missing-activation)
  (advice-remove 'eglot-reconnect #'drgnx-lang--guard-reconnect)
  (advice-remove 'eglot--maybe-activate-editing-mode #'drgnx-lang--guard-eglot-activation))

(defun drgnx-lang--maybe-eglot-remote (file)
  "The code buffer of the remote FILE: a server when the probe found one here and a command of the user is running
(`drgnx-lang--user-command-p'; one per project); a one-time hint when the probe found none; nothing otherwise."
  (when-let* ((entries (drgnx-lang--remote-entries file)))
    (cond ((seq-some #'cdr entries)
           (when (drgnx-lang--user-command-p) (drgnx-lang-start-remote-server)))
          ((not (member (cons (file-remote-p file) major-mode) drgnx-lang--remote-hinted))
           (push (cons (file-remote-p file) major-mode) drgnx-lang--remote-hinted)
           (message "No language server for %s on %s: install %s there" major-mode (file-remote-p file 'host)
                    (or (alist-get (car (car entries)) (gethash (file-remote-p file) drgnx-lang--remote-wanted) nil nil #'equal)
                        "one"))))))

(defun drgnx-lang--maybe-eglot ()
  "In a file's code buffer: start eglot when the server is installed (never asks) — unless DRGNX_NO_LANGUAGE_SERVERS
is set non-empty (headless test sessions).  A remote file only looks at what Open Remote… or Reconnect found."
  (when (and buffer-file-name (member (getenv "DRGNX_NO_LANGUAGE_SERVERS") '(nil "")))
    (if (file-remote-p buffer-file-name)
        (drgnx-lang--maybe-eglot-remote buffer-file-name)
      (when (drgnx-lang-server-available-p) (eglot-ensure)))))

(defun drgnx-lang-rename ()
  "Rename the symbol at point everywhere (a language server is needed)."
  (interactive)
  (if (and (fboundp 'eglot-current-server) (eglot-current-server)) (call-interactively #'eglot-rename)
    (user-error "Rename Symbol needs a language server for this file (none is installed)")))

(defun drgnx-lang--server-p () (and (fboundp 'eglot-current-server) (eglot-current-server)))

(defun drgnx-lang-quick-fix ()
  "The language server's fixes and actions here."
  (interactive)
  (unless (drgnx-lang--server-p) (user-error "Quick Fix needs a language server for this file (none is installed)"))
  (call-interactively #'eglot-code-actions))

(defun drgnx-lang-format ()
  "Format the buffer with the language server; without one, re-indent it."
  (interactive)
  (if (drgnx-lang--server-p) (call-interactively #'eglot-format-buffer)
    (indent-region (point-min) (point-max))))

(defun drgnx-lang-hover ()
  "Show the documentation of the symbol at point (in the panel's Help tab)."
  (interactive)
  (eldoc-doc-buffer t))

(drgnx-module-define 'lang/eglot
                     :doc "Language servers when installed, tree-sitter modes when the grammar is, definitions, references, rename, hover."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (drgnx-lang-remap-modes)
                       (add-hook 'prog-mode-hook #'drgnx-lang--maybe-eglot)
                       (with-eval-after-load 'eglot (drgnx-lang--install-eglot-guards))
                       (setq xref-prompt-for-identifier nil
                             eglot-sync-connect nil                 ; a slow server never blocks opening the file
                             eglot-autoshutdown t)                  ; a server goes with its project's last buffer
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((code-definition "Go to Definition" xref-find-definitions "Jump to where the symbol is defined")
                                        (code-references "Find References" xref-find-references "Every use of the symbol (in the panel)")
                                        (code-rename "Rename Symbol" drgnx-lang-rename "Rename the symbol everywhere (language server)")
                                        (code-hover "Show Hover" drgnx-lang-hover "The symbol's documentation, in the panel")
                                        (code-quick-fix "Quick Fix" drgnx-lang-quick-fix "The language server's fixes and actions here")
                                        (code-problems "Problems" flymake-show-project-diagnostics "Errors and warnings of the project (in the panel)")
                                        (code-format "Format Document" drgnx-lang-format "Format with the language server (else re-indent)")))
                         (drgnx-command-define id :category "Code" :title title :command fn :scope 'editing :doc doc))))

(provide 'drgnx-lang)
;;; drgnx-lang.el ends here
