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
(require 'drgnx-frame-kind)
(require 'drgnx-config)
(require 'drgnx-setting)
(require 'drgnx-settings-area)
(require 'drgnx-registry)

(defvar server-name)
(defvar server-process)
(defvar server-socket-dir)
(defvar server-client-instructions)
(declare-function server-running-p "server")
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-explorer-roots "drgnx-explorer")
(declare-function drgnx-explorer-set-roots "drgnx-explorer")
(declare-function drgnx-explorer-focus "drgnx-explorer")
(defvar drgnx-explorer-buffer-name)

(defvar drgnx-session-server-name (let ((n (getenv "DRGNX_SERVER_NAME"))) (if (and n (not (string-empty-p n))) n "drgnx"))
  "The server `drgnx PATH' talks to: $DRGNX_SERVER_NAME, else \"drgnx\" (bin/drgnx uses the same).")

(defvaralias 'drgnx-keep-running 'drgnx-session-keep-running
  "The old name of `drgnx-session-keep-running'.")

(drgnx-defsetting drgnx-session-keep-running t
  "Non-nil: drgnx keeps running in the background when its last window closes (reopening is instant).
nil: closing the last window quits drgnx (after asking to save changed files).  Set it with
Preferences: Keep drgnx Running in the Background, which remembers it in settings.el.  Read when a window closes."
  :type 'boolean :group 'drgnx :scope 'global :workspace 'never)

;;;; The choice, remembered

;; session.eld is the old file: it is still defined for one reason, `drgnx-settings-migrate-maybe' reads it once to
;; move its value into settings.el.
(drgnx-config-define 'session
                     :file "session.eld" :shape 'plist :version 1 :reload 'start :last-good t
                     :schema '(plist (:keep-running boolean "Keep drgnx running when its last window closes"))
                     :default nil
                     :doc "Whether drgnx keeps running when its last window closes (moved into settings.el).")

(defun drgnx-session-set-keep-running (keep)
  "Keep drgnx running when its last window closes (KEEP non-nil) or quit then; saved in settings.el.
Only that entry changes in the file; a file with a mistake is refused (`drgnx-settings-refused'), never replaced."
  (let ((keep (and keep t)))
    (drgnx-settings-area-set (list (cons 'drgnx-session-keep-running keep)))
    (setq drgnx-session-keep-running keep)
    keep))

(defun drgnx-session-toggle-keep-running ()
  "Switch between keeping drgnx running when its last window closes and quitting; say which it is now."
  (interactive)
  (drgnx-session-set-keep-running (not drgnx-keep-running))
  (message (if drgnx-keep-running
               "drgnx keeps running in the background when its last window closes"
             "drgnx quits when its last window closes")))

;;;; Windows

(defun drgnx-session--windows ()
  "The frames that count as windows: the workbench frames (`drgnx-state-workbench-frame-p'), shown or minimised."
  (seq-filter (lambda (f) (and (drgnx-state-workbench-frame-p f) (frame-visible-p f))) (frame-list)))

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
    (when (memq (drgnx-state-frame-kind (selected-frame)) '(gui initial))
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

;;;; The keys that close a window (M12a-32)

(defun drgnx-session--closes-window-p ()
  "Non-nil in a graphical, top-level frame: the windows `drgnx-keep-running' is about.  Terminal frames and
child frames keep Emacs' own behaviour."
  (and (display-graphic-p) (not (frame-parent))))

(defun drgnx-session-kill-terminal (&optional arg)
  "`C-x C-c' (the remap of `save-buffers-kill-terminal'): in a graphical window, close it as its close button
does (`drgnx-session-close-frame': the last one keeps drgnx running or quits it, per `drgnx-keep-running').
Elsewhere — a terminal frame — as in Emacs; ARG is then passed on."
  (interactive "P")
  (if (drgnx-session--closes-window-p)
      (drgnx-session-close-frame)
    (save-buffers-kill-terminal arg)))

(defun drgnx-session-delete-frame ()
  "`C-x 5 0' (the remap of `delete-frame'): in a graphical window, close it as its close button does
(`drgnx-session-close-frame'); elsewhere as in Emacs.  Programmatic `delete-frame' calls are not remapped."
  (interactive)
  (if (drgnx-session--closes-window-p)
      (drgnx-session-close-frame)
    (delete-frame)))

;;;; The server socket on macOS (M12a-31)

(defun drgnx-session--darwin-socket-dir ()
  "Emacs' default `server-socket-dir' when XDG_RUNTIME_DIR is not set: emacs<uid> under $TMPDIR (else /tmp)."
  (expand-file-name (format "emacs%d" (user-uid)) (or (getenv "TMPDIR") "/tmp")))

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
  "The title bar's close button runs `drgnx-session-close-frame', and so do `C-x C-c' and `C-x 5 0' (remapped).
The remembered choice is a setting, read when a window closes.  On macOS the server socket ignores XDG_RUNTIME_DIR: a
shell exports it, Finder does not, and `drgnx PATH' (bin/drgnx runs emacsclient without it there) must find the same
socket from both."
  (setq server-client-instructions nil)         ; every `emacsclient -c' frame said "When done with a buffer, type C-x 5 0"
  (define-key special-event-map [delete-frame] #'drgnx-session-close-frame)
  (define-key global-map [remap save-buffers-kill-terminal] #'drgnx-session-kill-terminal)
  (define-key global-map [remap delete-frame] #'drgnx-session-delete-frame)
  (when (eq system-type 'darwin)
    (setq server-socket-dir (drgnx-session--darwin-socket-dir))))

;;;; `drgnx open' never asks about a file that changed on disk

(defvar drgnx-session-before-open-functions nil
  "Functions called with the files (absolute names) `drgnx open' is about to visit, before
`drgnx-session-open-unasked' reverts their buffers whose file changed on disk.  editor/large-files reopens a buffer
whose file grew past `:ask-above' here.  They run in the server's process filter: they never ask.")

(defun drgnx-session-open-unasked (files fn)
  "Call FN, which visits FILES (absolute names) for `drgnx open', so that it asks nothing about a buffer already
holding one of them whose file changed on disk.  Emacs asks there, in the server's process filter:
`server-visit-files' reverts such a buffer with (revert-buffer t nil), `find-file' asks \"Reread from disk?\".
Here an unmodified one is reverted first, without a question (only safe local variables are set); a modified one is
never reverted silently: it is left as it is (its record of the file's time is current while FN runs, then stale
again, so saving it still asks, as a command may) and the echo area says so.  A file that is gone is left to FN."
  (run-hook-with-args 'drgnx-session-before-open-functions files)
  (let ((kept nil))
    (dolist (file files)
      (when-let* ((b (find-buffer-visiting file)))
        (when (and (not (verify-visited-file-modtime b)) (file-exists-p file))
          (with-current-buffer b
            (if (buffer-modified-p)
                (progn (push (cons b (visited-file-modtime)) kept)
                       (set-visited-file-modtime))
              (let ((enable-local-variables (if (memq enable-local-variables '(nil :all :safe))
                                                enable-local-variables
                                              :safe)))
                (revert-buffer t t)))))))
    (unwind-protect (funcall fn)
      (pcase-dolist (`(,b . ,time) kept)
        (when (buffer-live-p b)
          (with-current-buffer b (set-visited-file-modtime time))
          (message "%s changed on disk; its buffer has unsaved changes and is left as it is"
                   (file-name-nondirectory (buffer-file-name b))))))))

(defun drgnx-session--visit-unasked (orig files &rest args)
  "Around `server-visit-files' (ORIG, FILES ((NAME . POSITION) …), ARGS): the files of a request to drgnx's server,
`drgnx open FILE' and `drgnx open --wait FILE', are visited without a question (`drgnx-session-open-unasked')."
  (drgnx-session-open-unasked (mapcar #'car files) (lambda () (apply orig files args))))

;; The core is never turned off: the advice is on from the load (it applies once server.el is loaded)
(advice-add 'server-visit-files :around #'drgnx-session--visit-unasked)

(defun drgnx-session-open-file (file)
  "Show FILE in the selected window as `drgnx -t FILE' does (its -e form), without a question about a buffer whose
file changed on disk (`drgnx-session-open-unasked'); return its buffer."
  (let ((file (expand-file-name file)))
    (drgnx-session-open-unasked (list file) (lambda () (find-file file)))))

(defun drgnx-session-start-server ()
  "In a drgnx started as a plain graphical Emacs (not a daemon, not drgnx safe, not a harness session),
serve `drgnx-session-server-name' so `drgnx PATH' opens there — unless another drgnx already does."
  (unless (or noninteractive (daemonp) (not initial-window-system) (getenv "DRGNX_SAFE") (getenv "DRGNX_UI_RUN"))
    (require 'server)
    (unless (or (and (processp server-process) (process-live-p server-process))
                (eq t (server-running-p drgnx-session-server-name)))
      (setq server-name drgnx-session-server-name)
      (condition-case err (server-start)
        (error (require 'drgnx-notice)
               (drgnx-notify 'config 'warn (format "no server for drgnx PATH: %s" (error-message-string err))
                             :id 'session-server))))))

(provide 'drgnx-session)
;;; drgnx-session.el ends here
