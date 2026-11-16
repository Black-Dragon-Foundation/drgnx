;;; drgnx-basics.el --- Module core/basics: defaults every drgnx session gets -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'seq)
(require 'drgnx-modules)
(require 'drgnx-paths)
(require 'drgnx-session)
(require 'drgnx-trust)

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

(defvar-local drgnx-untitled-p nil
  "Non-nil in a buffer made by New Untitled: an editor like a file's (line numbers, the status bar) though it visits
none.  It survives a change of major mode (Change Language Mode).")
(put 'drgnx-untitled-p 'permanent-local t)

(defun drgnx-basics-new-untitled ()
  "A new empty buffer Untitled-N; Save asks for its file name."
  (interactive)
  (let ((n 1))
    (while (get-buffer (format "Untitled-%d" n)) (setq n (1+ n)))
    (let ((b (get-buffer-create (format "Untitled-%d" n))))
      (with-current-buffer b (setq drgnx-untitled-p t))   ; before the mode: its hooks (line numbers) see it
      (switch-to-buffer b)
      (funcall (default-value 'major-mode))
      (setq buffer-offer-save t)          ; Quit and Save All offer it: typed text is never dropped unasked
      b)))

;;;; A view is never saved (audit: Ctrl+S in the Explorer wrote its rows to a file called " *drgnx explorer*")

(defun drgnx-basics-view-buffer-p (&optional buffer)
  "Non-nil when BUFFER (default: the current one) is one of drgnx's views, not a file or an untitled editor: a buffer
that visits no file and is a hub-fed view, a special-mode page or one named for drgnx's own (`*drgnx …*')."
  (with-current-buffer (or buffer (current-buffer))
    (and (not buffer-file-name) (not drgnx-untitled-p)
         (or (bound-and-true-p drgnx-view-patch)
             (derived-mode-p 'special-mode)
             (string-match-p "\\` ?\\*drgnx" (buffer-name))))))

(defun drgnx-basics--save-from-view (orig &rest args)
  "Around `save-buffer': in a view (the Explorer, Outline, a panel page) it saves the editor the user works in, as
VS Code's Ctrl+S does with focus in a side view; with no editor to save it says so.  It never asks for a file name."
  (if (not (drgnx-basics-view-buffer-p))
      (apply orig args)
    (let* ((w (and (fboundp 'drgnx-state-editor-window) (drgnx-state-editor-window)))
           (b (and w (window-buffer w))))
      (if (and b (or (buffer-file-name b) (buffer-local-value 'drgnx-untitled-p b)))
          (with-current-buffer b (apply orig args))
        (message "Nothing to save: no editor is open")
        nil))))

(defun drgnx-basics--no-file-for-view (&rest _)
  "Before `set-visited-file-name': a view never visits a file."
  (when (drgnx-basics-view-buffer-p)
    (user-error "%s is a view: it is not saved to a file" (buffer-name))))

(drgnx-module-define 'core/basics
                     :doc "Quiet, predictable defaults and the basic file and view commands."
                     :stage 'startup
                     ;; Everything it sets is recorded (a test turns it off cleanly); Preferences stops it at the next start.
                     :teardown 'restart
                     :setup
                     (lambda ()
                       (drgnx-module-set 'ring-bell-function #'ignore)
                       (drgnx-module-set 'use-dialog-box nil)
                       (drgnx-module-set 'use-short-answers t)
                       (drgnx-module-set 'inhibit-startup-screen t)
                       ;; Background native compilation: warnings go to the log, never a window popping up.
                       (drgnx-module-set 'native-comp-async-report-warnings-errors 'silent)
                       ;; Trusted folders and the guards for files from the others, before any file opens
                       (drgnx-trust-setup)
                       (drgnx-module-advice #'save-buffer :around save-from-view (orig &rest args)
                         (apply #'drgnx-basics--save-from-view orig args))
                       (drgnx-module-advice #'set-visited-file-name :before no-file-for-view (&rest args)
                         (apply #'drgnx-basics--no-file-for-view args))
                       (drgnx-command-define 'open-file :category "File" :title "Open File…" :command #'find-file
                                             :doc "Open a file")
                       (drgnx-command-define 'save-file :category "File" :title "Save" :command #'save-buffer
                                             :doc "Save this buffer")
                       (drgnx-command-define 'line-numbers :category "View" :title "Toggle Line Numbers"
                                             :command #'display-line-numbers-mode :menu '("View") :doc "Line numbers in this buffer")
                       (add-hook 'kill-buffer-hook #'drgnx-basics--note-closed)
                       ;; project.el's list of known projects in drgnx's state dir, not in the checkout (--init-directory)
                       (drgnx-module-set 'project-list-file (expand-file-name "projects" (drgnx-state-dir)))
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
