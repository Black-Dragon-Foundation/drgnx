;;; tramp-mock.el --- a TRAMP method that runs a shell on this machine, for tests -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Like Emacs's own TRAMP tests: the method `drgnx-mock' logs in with a local `sh', so a "remote" file name
;; "/drgnx-mock::DIR" is DIR on this machine, reached through a real TRAMP connection (its process, its caches),
;; and nothing leaves the machine.  `drgnx-tramp-mock-sends' counts what would touch a remote: opening a
;; connection and sending a command.

;;; Code:
(require 'tramp)

(defconst drgnx-tramp-mock-host "localhost" "The host name of the mock method (TRAMP's sh methods accept local names only).")

(defvar drgnx-tramp-mock-sends 0
  "Calls of `tramp-maybe-open-connection' and `tramp-send-command' since the setup (or the last reset).")

(defun drgnx-tramp-mock--count (&rest _) (setq drgnx-tramp-mock-sends (1+ drgnx-tramp-mock-sends)))

(defconst drgnx-tramp-mock-line-max 1000
  "The longest command line the mock lets through, in bytes.  TRAMP talks to the remote shell through a terminal in
canonical mode, and a macOS terminal takes at most 1024 bytes per line (MAX_CANON): it drops the rest, the newline
too, so the shell never runs the line and TRAMP waits for its prompt forever (Linux takes 4096).  TRAMP adds its echo
mark and line end to what it sends, so the mock stops at 1000: a line that would hang on macOS fails here at once.")

(defun drgnx-tramp-mock--check-line (_vec command &rest _)
  "Signal an error when a line of COMMAND is longer than `drgnx-tramp-mock-line-max'."
  (dolist (line (split-string command "\n"))
    (when (> (string-bytes line) drgnx-tramp-mock-line-max)
      (error "TRAMP command line of %d bytes (a macOS terminal takes 1024): %s…"
             (string-bytes line) (substring line 0 200)))))

(defvar drgnx-tramp-mock--saved nil
  "What `drgnx-tramp-mock-setup' changed, as it was before: a plist; nil while the mock is not set up.")

(defun drgnx-tramp-mock-setup ()
  "Add the method `drgnx-mock' and count what is sent.  Safe to call again; `drgnx-tramp-mock-teardown' puts back
everything changed here.  No file under the home is written."
  (unless drgnx-tramp-mock--saved
    (setq drgnx-tramp-mock--saved
          (list :syntax (alist-get 'default tramp-method-regexp-alist)
                :method (assoc "drgnx-mock" tramp-methods)
                :hosts tramp-default-host-alist
                :verbose tramp-verbose
                :persistency tramp-persistency-file-name
                :inhibit-cache remote-file-name-inhibit-cache)))
  ;; TRAMP's method names are letters and digits only; this one has a hyphen, so the syntax is rebuilt to allow it
  (setf (alist-get 'default tramp-method-regexp-alist)
        (rx (| (literal tramp-default-method-marker) (>= 2 (any alnum "-")))))
  (tramp-change-syntax 'default)
  (setf (alist-get "drgnx-mock" tramp-methods nil nil #'equal)
        `((tramp-login-program ,tramp-default-remote-shell)
          (tramp-login-args (("-i")))
          (tramp-remote-shell ,tramp-default-remote-shell)
          (tramp-remote-shell-args ("-c"))
          (tramp-connection-timeout 10)))
  (add-to-list 'tramp-default-host-alist `("\\`drgnx-mock\\'" nil ,drgnx-tramp-mock-host))
  (setq tramp-persistency-file-name nil tramp-verbose 0 remote-file-name-inhibit-cache nil
        drgnx-tramp-mock-sends 0)
  (advice-add 'tramp-maybe-open-connection :before #'drgnx-tramp-mock--count)
  (advice-add 'tramp-send-command :before #'drgnx-tramp-mock--count)
  (advice-add 'tramp-send-command :before #'drgnx-tramp-mock--check-line))

(defun drgnx-tramp-mock-teardown ()
  "Close every connection, stop counting and put back what the setup changed."
  (advice-remove 'tramp-maybe-open-connection #'drgnx-tramp-mock--count)
  (advice-remove 'tramp-send-command #'drgnx-tramp-mock--count)
  (advice-remove 'tramp-send-command #'drgnx-tramp-mock--check-line)
  (ignore-errors (tramp-cleanup-all-connections))
  (when-let* ((saved drgnx-tramp-mock--saved))
    (setq drgnx-tramp-mock--saved nil)
    (setf (alist-get 'default tramp-method-regexp-alist) (plist-get saved :syntax))
    (tramp-change-syntax 'default)
    (setq tramp-methods (assoc-delete-all "drgnx-mock" tramp-methods))
    (when-let* ((method (plist-get saved :method))) (push method tramp-methods))
    (setq tramp-default-host-alist (plist-get saved :hosts)
          tramp-verbose (plist-get saved :verbose)
          tramp-persistency-file-name (plist-get saved :persistency)
          remote-file-name-inhibit-cache (plist-get saved :inhibit-cache))))

(defun drgnx-tramp-mock-name (dir)
  "The mock-remote file name of the local DIR: \"/drgnx-mock::DIR\"."
  (concat "/drgnx-mock::" (expand-file-name dir)))

(provide 'drgnx-tramp-mock)
;;; tramp-mock.el ends here
