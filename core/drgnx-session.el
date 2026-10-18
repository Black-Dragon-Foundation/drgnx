;;; drgnx-session.el --- Opening drgnx, and keep running or quit when the last window closes -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx PATH' and `drgnx open' (bin/drgnx) reach one drgnx — a daemon named `drgnx-session-server-name',
;; started on the first open — through emacsclient, and call the functions here: is a window open
;; (`drgnx-session-gui-frame-p'), bring it to the front (`drgnx-session-raise'), show a folder in the
;; Explorer (`drgnx-session-open-folder').  When the last window closes, drgnx keeps running in the
;; background (`drgnx-keep-running', the default, like VS Code on a Mac) or quits; the choice is kept in
;; (drgnx-user-dir)/session.eld.  Quitting asks to save changed files — it is a command, never a hook.
;; See docs/guide/opening.md.

;;; Code:
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-registry)

(defvar server-name)
(defvar server-process)
(declare-function server-running-p "server")
(declare-function drgnx-explorer-roots "drgnx-explorer")
(declare-function drgnx-explorer-set-roots "drgnx-explorer")
(declare-function drgnx-explorer-focus "drgnx-explorer")
(defvar drgnx-explorer-buffer-name)

(defvar drgnx-session-server-name (let ((n (getenv "DRGNX_SERVER_NAME"))) (if (and n (not (string-empty-p n))) n "drgnx"))
  "The server `drgnx PATH' talks to: $DRGNX_SERVER_NAME, else \"drgnx\" (bin/drgnx uses the same).")

(defcustom drgnx-keep-running t
  "Non-nil: drgnx keeps running in the background when its last window closes (reopening is instant).
nil: closing the last window quits drgnx (after asking to save changed files).  Set it with
Preferences: Keep drgnx Running in the Background, which remembers it (session.eld)."
  :type 'boolean :group 'drgnx)

;;;; The choice, remembered

(defun drgnx-session-file () (expand-file-name "session.eld" (drgnx-user-dir)))

(defun drgnx-session-load ()
  "Set `drgnx-keep-running' from session.eld when it holds the choice; anything else leaves it alone."
  (let ((data (and (file-readable-p (drgnx-session-file))
                   (ignore-errors (with-temp-buffer (insert-file-contents (drgnx-session-file)) (read (current-buffer)))))))
    (when (and (proper-list-p data) (plist-member data :keep-running))
      (setq drgnx-keep-running (and (plist-get data :keep-running) t)))))

(defun drgnx-session-set-keep-running (keep)
  "Keep drgnx running when its last window closes (KEEP non-nil) or quit then; saved in session.eld."
  (setq drgnx-keep-running (and keep t))
  (let ((dir (file-name-directory (drgnx-session-file))))
    (make-directory dir t)
    (let ((tmp (make-temp-file (expand-file-name ".session-" dir))))
      (with-temp-file tmp (prin1 (list :keep-running drgnx-keep-running) (current-buffer)) (insert "\n"))
      (rename-file tmp (drgnx-session-file) t)))
  drgnx-keep-running)

(defun drgnx-session-toggle-keep-running ()
  "Switch between keeping drgnx running when its last window closes and quitting; say which it is now."
  (interactive)
  (drgnx-session-set-keep-running (not drgnx-keep-running))
  (message (if drgnx-keep-running
               "drgnx keeps running in the background when its last window closes"
             "drgnx quits when its last window closes")))

;;;; Windows

(defun drgnx-session--windows ()
  "The frames that count as windows: live, top-level, shown or minimised — not a daemon's own terminal frame."
  (seq-filter (lambda (f) (and (frame-live-p f) (not (frame-parent f)) (frame-visible-p f)
                               (not (equal (terminal-name (frame-terminal f)) "initial_terminal"))))
              (frame-list)))

(defun drgnx-session--gui-frame ()
  "The graphical window to show things in: the selected frame if it is one, else the first."
  (let ((windows (seq-filter #'display-graphic-p (drgnx-session--windows))))
    (if (memq (selected-frame) windows) (selected-frame) (car windows))))

(defun drgnx-session-gui-frame-p ()
  "Non-nil when a graphical window (a live, top-level frame, shown or minimised) is open.  bin/drgnx asks
this to decide whether `drgnx PATH' needs a new window."
  (and (drgnx-session--gui-frame) t))

(defun drgnx-session-raise ()
  "Select drgnx's graphical window, bring it to the front and give it focus; nil when there is none."
  (when-let* ((f (drgnx-session--gui-frame)))
    (select-frame-set-input-focus f)
    f))

(defun drgnx-session-open-folder (dir)
  "Show DIR in front as the Explorer's first folder (`drgnx DIR'), the Explorer selected — as VS Code after
`code DIR' — with DIR as its `default-directory', so quick open and project search work in DIR's project.
The Explorer's other folders stay.  Without the workbench (drgnx safe), DIR opens in dired.
In a terminal frame (`drgnx -t DIR', or the command typed there) DIR opens in that frame: the graphical window
is not raised.  As File → Open Folder… it asks for DIR; bin/drgnx's call never asks."
  (interactive (list (read-directory-name "Open folder: " nil nil t)))
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (when (or (display-graphic-p) (equal (terminal-name (frame-terminal)) "initial_terminal"))
      (drgnx-session-raise))
    (if (not (fboundp 'drgnx-explorer-set-roots))
        (dired dir)
      (drgnx-explorer-set-roots (cons dir (remove dir (drgnx-explorer-roots))))
      (drgnx-explorer-focus)
      (with-current-buffer drgnx-explorer-buffer-name (setq default-directory dir)))
    t))

;;;; Closing and quitting

(defun drgnx-session--unsaved-buffers ()
  "Buffers whose changes would be lost: changed file buffers, and changed buffers that offer to be saved
(`buffer-offer-save': New Untitled)."
  (seq-filter (lambda (b) (and (buffer-modified-p b) (or (buffer-file-name b) (buffer-local-value 'buffer-offer-save b))))
              (buffer-list)))

(defun drgnx-session--running-programs ()
  "The live processes whose end Emacs would ask about (`process-query-on-exit-flag'): terminals, shells, servers
you started — not drgnx's own background helpers.  The terminal module, when it is there, first brings its
terminals' flags up to date (a shell at a prompt does not ask)."
  (when (fboundp 'drgnx-terminal-eat-refresh-query-flags)
    (ignore-errors (funcall 'drgnx-terminal-eat-refresh-query-flags)))   ; a failing refresh never stops the question
  (seq-filter (lambda (p) (and (process-live-p p) (process-query-on-exit-flag p))) (process-list)))

(defun drgnx-session-quit-confirm ()
  "Ask what quitting needs: offer to save each changed file and New Untitled buffer, then confirm losing what
stays unsaved, then — once — confirm stopping the programs still running (terminals, shells).  t when drgnx may
quit; nil when it keeps running (the answer was no).  C-g or an error while saving leaves through the signal, so
a caller that quits afterwards never gets there."
  (save-some-buffers nil t)          ; t: buffers with `buffer-offer-save' too, as `save-buffers-kill-emacs' does
  (let ((unsaved (drgnx-session--unsaved-buffers)))
    (cond ((and unsaved (not (yes-or-no-p (format "%d buffer%s not saved; quit and lose the changes? "
                                                  (length unsaved) (if (cdr unsaved) "s are" " is")))))
           (message "drgnx keeps running; nothing was lost")
           nil)
          ((when-let* ((running (drgnx-session--running-programs)))
             (not (yes-or-no-p (format "%d program%s still running (%s); quit and stop %s? "
                                       (length running) (if (cdr running) "s are" " is")
                                       (mapconcat #'process-name running ", ") (if (cdr running) "them" "it")))))
           (message "drgnx keeps running; nothing was stopped")
           nil)
          (t t))))

(defun drgnx-session-quit ()
  "Quit drgnx — the daemon too: offer to save each changed file and New Untitled buffer, then stop.  C-g, an
error while saving, or saying no to losing a change or to stopping running programs leaves drgnx running with
everything open."
  (interactive)
  (when (drgnx-session-quit-confirm) (kill-emacs)))

(defun drgnx-session-close-frame (&optional event)
  "Close this window — or the one whose close button sent EVENT (a `delete-frame' event).  Closing the last
one quits drgnx unless it keeps running in the background (`drgnx-keep-running', a daemon)."
  (interactive (list last-input-event))
  (let ((frame (if (eq (car-safe event) 'delete-frame) (posn-window (event-start event)) (selected-frame))))
    (cond ((remq frame (drgnx-session--windows)) (delete-frame frame t))
          ((and drgnx-keep-running (daemonp)) (delete-frame frame t))
          (t (when (frame-live-p frame) (select-frame-set-input-focus frame))   ; the questions show here
             (drgnx-session-quit)))))

;;;; Setup

(defun drgnx-session-register-commands ()
  "Quit drgnx, Open Folder… and the keep-running preference, in the registry."
  (drgnx-command-define 'quit :category "File" :title "Quit drgnx" :command #'drgnx-session-quit :menu '("File")
                        :doc "Stop drgnx, the background one too, after offering to save changed files")
  (drgnx-command-define 'open-folder :category "File" :title "Open Folder…" :command #'drgnx-session-open-folder
                        :menu '("File") :doc "Show a folder in the Explorer, first, the Explorer selected (as `drgnx DIR')")
  (drgnx-command-define 'preferences-keep-running :category "Preferences" :title "Keep drgnx Running in the Background"
                        :command #'drgnx-session-toggle-keep-running :menu '("Options")
                        :doc "When the last window closes: keep running (reopening is instant), or quit"))

(defun drgnx-session-setup ()
  "Read the remembered choice; the title bar's close button runs `drgnx-session-close-frame'."
  (drgnx-session-load)
  (define-key special-event-map [delete-frame] #'drgnx-session-close-frame))

(defun drgnx-session-start-server ()
  "In a drgnx started as a plain graphical Emacs (not a daemon, not drgnx safe, not a harness session),
serve `drgnx-session-server-name' so `drgnx PATH' opens there — unless another drgnx already does."
  (unless (or noninteractive (daemonp) (not initial-window-system) (getenv "DRGNX_SAFE") (getenv "DRGNX_UI_RUN"))
    (require 'server)
    (unless (or (and (processp server-process) (process-live-p server-process))
                (eq t (server-running-p drgnx-session-server-name)))
      (setq server-name drgnx-session-server-name)
      (condition-case err (server-start)
        (error (message "drgnx: no server for drgnx PATH: %s" (error-message-string err)))))))

(provide 'drgnx-session)
;;; drgnx-session.el ends here
