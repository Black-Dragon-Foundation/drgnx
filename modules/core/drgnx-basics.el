;;; drgnx-basics.el --- Module core/basics: defaults every drgnx session gets -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'seq)
(defvar native-comp-async-report-warnings-errors)
(defvar project-list-file)
(require 'drgnx-paths)
(require 'drgnx-session)

(defvar drgnx-basics--closed nil "Files of the buffers closed, newest first (Reopen Closed Tab).")

(defun drgnx-basics--note-closed ()
  "Remember the file of the buffer being killed."
  (when-let* ((f buffer-file-name))
    (setq drgnx-basics--closed (seq-take (cons f (delete f drgnx-basics--closed)) 30))))

(defun drgnx-basics-reopen-tab ()
  "Open the file closed last."
  (interactive)
  (let ((f (seq-find #'file-exists-p drgnx-basics--closed)))
    (unless f (user-error "No closed file to reopen"))
    (setq drgnx-basics--closed (delete f drgnx-basics--closed))
    (find-file f)))

(defun drgnx-basics-new-untitled ()
  "A new empty buffer Untitled-N; Save asks for its file name."
  (interactive)
  (let ((n 1))
    (while (get-buffer (format "Untitled-%d" n)) (setq n (1+ n)))
    (let ((b (get-buffer-create (format "Untitled-%d" n))))
      (switch-to-buffer b)
      (funcall (default-value 'major-mode))
      (setq buffer-offer-save t)          ; Quit and Save All offer it: typed text is never dropped unasked
      b)))

(drgnx-module-define 'core/basics
                     :doc "Quiet, predictable defaults and the basic file and view commands."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (setq ring-bell-function #'ignore
                             use-dialog-box nil
                             use-short-answers t
                             inhibit-startup-screen t
                             ;; Background native compilation: warnings go to the log, never a window popping up.
                             native-comp-async-report-warnings-errors 'silent)
                       (drgnx-command-define 'open-file :category "File" :title "Open File…" :command #'find-file
                                             :doc "Open a file")
                       (drgnx-command-define 'save-file :category "File" :title "Save" :command #'save-buffer
                                             :doc "Save this buffer")
                       (drgnx-command-define 'line-numbers :category "View" :title "Toggle Line Numbers"
                                             :command #'display-line-numbers-mode :menu '("View") :doc "Line numbers in this buffer")
                       (add-hook 'kill-buffer-hook #'drgnx-basics--note-closed)
                       ;; project.el's list of known projects in drgnx's state dir, not in the checkout (--init-directory)
                       (setq project-list-file (expand-file-name "projects" (drgnx-state-dir)))
                       (make-directory (drgnx-state-dir) t)
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((file-save-as "Save As…" write-file "Save under a new name")
                                        (file-new "New Untitled" drgnx-basics-new-untitled "An empty buffer; Save asks for a name")
                                        (file-reopen-tab "Reopen Closed Tab" drgnx-basics-reopen-tab "Open the file closed last")
                                        (file-new-window "New Window" make-frame-command "Open another Emacs window")
                                        (file-close-window "Close Window" drgnx-session-close-frame
                                                           "Close this window; the last one quits, unless drgnx keeps running in the background")))
                         (drgnx-command-define id :category "File" :title title :command fn :doc doc))
                       (drgnx-command-define 'view-escape :category "View" :title "Cancel / Close Popup" :command #'keyboard-escape-quit
                                             :doc "Like Escape in VS Code: cancel, leave the selection, close a popup")))

;;; drgnx-basics.el ends here
