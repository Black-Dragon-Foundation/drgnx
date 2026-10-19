;;; drgnx-start.el --- The start page: what to do in an empty editor -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part A of M12f.  Someone who opens drgnx and sees an empty editor does not know what to do.  `*drgnx start*' says
;; what drgnx is in two lines, shows the three keys that open everything (the files, the commands, all keys: from
;; the active profile, as the top line shows them) and has buttons: Open a Folder…, Open the Work Graph, All Keys,
;; Don't show this again.
;;
;; It shows itself, only where nothing is lost: in the editor window used last, when that window shows `*scratch*'
;; (never a file), by changing that window's buffer — it never splits a window, never selects another one and never
;; asks anything, because it runs from hooks (`drgnx-persist-after-restore-functions', `server-after-make-frame-hook',
;; the first window of a start, the moment the last file tab of the editor closes, and when the first-run Welcome
;; closes).  "Don't show this again" is
;; kept in face.eld (`:start-dismissed', see `drgnx-face-state'); Show Start Page still shows it on request.  The
;; page is a tab only while it is shown (`drgnx-chrome-transient-tabs').  See docs/guide/face.md ("The start page").

;;; Code:
(require 'subr-x)
(require 'seq)
(require 'button)
(require 'drgnx-registry)
(require 'drgnx-face-state)
(require 'drgnx-timer)
(require 'drgnx-frame-kind)
(declare-function drgnx-face-glyph "drgnx-face")
(declare-function drgnx-surfaces-key "drgnx-surfaces")
(declare-function drgnx-surfaces-run "drgnx-surfaces")
(declare-function drgnx-tty-sendable-key "drgnx-tty-fallback")
(declare-function drgnx-signal-editor-window "drgnx-signal")
(declare-function drgnx-signal-editor-window-p "drgnx-signal")
(declare-function drgnx-signal-subscribe "drgnx-signal")
(declare-function drgnx-signal-unsubscribe "drgnx-signal")
(declare-function drgnx-chrome-tabs "drgnx-chrome")
(defvar drgnx-persist-after-restore-functions)
(defvar drgnx-first-gui-frame-hook)
(defvar server-after-make-frame-hook)

(defgroup drgnx-start nil
  "The start page shown in an empty editor."
  :group 'drgnx-face :prefix "drgnx-start-")

(defface drgnx-start-title '((t :inherit bold :height 1.4))
  "The name at the top of the start page."
  :group 'drgnx-start)

(defface drgnx-start-key '((t :inherit bold))
  "The keys on the start page."
  :group 'drgnx-start)

(defface drgnx-start-quiet '((t :inherit shadow))
  "The start page's explanations."
  :group 'drgnx-start)

(defconst drgnx-start-buffer-name "*drgnx start*" "The name of the start page's buffer.")

(defconst drgnx-start--keys
  '((go-quick-open "Open a file of the project by name")
    (palette "Run any command by name")
    (keys-sheet "See every key of this profile"))
  "The three keys the page shows: registry command ID and what it does.")

(defconst drgnx-start--buttons
  '((open-folder "Open a Folder…" "Choose a folder to work in; it opens in the Explorer")
    (work-graph "Open the Work Graph" "Specs, plans and branches as a graph")
    (keys-sheet "All Keys" "Every command with its key")
    (dismiss "Don't show this again" "Keep this page away; Show Start Page in the palette brings it back"))
  "The buttons: a registry command ID (or `dismiss'), the label and the help text.  A command that is not there
\(its module is off) has no button.")

(defvar drgnx-start--after-file nil
  "Non-nil when the editor used last showed a file (or the first-run Welcome) at the previous `editor-changed' (a
boolean, not the buffer).")

;;;; The page

(defun drgnx-start--key (id)
  "The key that runs registry command ID as the active profile has it, else the key Emacs gives its command, else nil.
On a terminal a chord it cannot send is shown the way it can (`drgnx-tty-sendable-key', when M12b is there)."
  (when-let* ((cmd (drgnx-commands-get id)))
    (let* ((s (drgnx-surfaces-key cmd))
           (key (if (string-empty-p s)
                    (let ((c (drgnx-cmd-command cmd)))
                      (when-let* ((k (and (symbolp c) (where-is-internal c nil t)))) (key-description k)))
                  (car (split-string s " (in " t)))))
      (when key
        (if (and (not (display-graphic-p)) (fboundp 'drgnx-tty-sendable-key))
            (or (ignore-errors (drgnx-tty-sendable-key (selected-frame) key)) key)
          key)))))

(defun drgnx-start--glyph ()
  "The bullet glyph for the selected frame (`drgnx-face-glyph'), an ASCII `>' when it is not known."
  (or (and (fboundp 'drgnx-face-glyph) (drgnx-face-glyph 'bullet)) ">"))

(defconst drgnx-start--width 76
  "Columns of the widest line of the page: the block is centred as this wide (a wider window shows it centred).")

(defconst drgnx-start--centre
  `(space :align-to (- (0.5 . text) ,(/ drgnx-start--width 2.0)))
  "A line's prefix: spaces up to the column that centres the block, whatever the window's width (a window narrower
than the block starts it at the left edge).")

(defun drgnx-start--top-padding ()
  "Blank lines above the name: the page sits in the upper third of the editor window that shows it."
  (let* ((w (drgnx-start--window (selected-frame)))
         (rows (if (window-live-p w) (window-body-height w) 24)))
    (max 1 (/ (- rows 17) 3))))

(defun drgnx-start--press (button)
  "Run what BUTTON stands for: a registry command (as if from the palette), or dismiss the page."
  (let ((id (button-get button 'drgnx-start-id)))
    (if (eq id 'dismiss)
        (drgnx-start-dismiss)
      (drgnx-surfaces-run id))))

(define-button-type 'drgnx-start-button
  'action #'drgnx-start--press 'follow-link t)

(defun drgnx-start--insert-button (id label help)
  "Insert the button LABEL for ID (a registry command ID or `dismiss'), resting on HELP, on a line of its own."
  (insert-text-button label :type 'drgnx-start-button 'drgnx-start-id id 'help-echo help)
  (insert "\n"))

(defun drgnx-start--render ()
  "Fill the current buffer: the name, two lines on what drgnx is, the three keys, the buttons.
The keys are read from the registry now, so a changed profile shows when the page shows again."
  (let ((inhibit-read-only t) (search (drgnx-start--glyph)))
    (erase-buffer)
    (insert (make-string (drgnx-start--top-padding) ?\n) (propertize "drgnx" 'face 'drgnx-start-title) "\n\n")
    (insert (propertize "A workbench for Emacs: your files, your agents and your work, side by side." 'face 'drgnx-start-quiet) "\n")
    (insert (propertize "Everything it does is a command, and the keys below find all of them." 'face 'drgnx-start-quiet) "\n\n")
    (pcase-dolist (`(,id ,what) drgnx-start--keys)
      (when-let* ((key (drgnx-start--key id)))
        (insert (propertize search 'face 'drgnx-start-quiet) " "
                (propertize (format "%-10s" key) 'face 'drgnx-start-key)
                (propertize what 'face 'drgnx-start-quiet) "\n")))
    (insert "\n")
    (pcase-dolist (`(,id ,label ,help) drgnx-start--buttons)
      (when (or (eq id 'dismiss) (drgnx-commands-get id))
        (drgnx-start--insert-button id label help)))
    (add-text-properties (point-min) (point-max)
                         (list 'line-prefix drgnx-start--centre 'wrap-prefix drgnx-start--centre))
    (goto-char (point-min))
    (when-let* ((b (next-button (point)))) (goto-char (button-start b)))
    (set-buffer-modified-p nil)))

(define-derived-mode drgnx-start-mode special-mode "drgnx-start"
  "Major mode of the start page: read-only, with buttons.  TAB and S-TAB move between the buttons, RET presses one."
  (buffer-disable-undo)
  (setq-local revert-buffer-function (lambda (&rest _) (drgnx-start--render))))

;; Emacs's own keys between buttons (TAB, S-TAB), on top of `special-mode's
(set-keymap-parent drgnx-start-mode-map (make-composed-keymap (list button-buffer-map special-mode-map)))

(defun drgnx-start--buffer ()
  "The page's buffer, made if needed and drawn again from the registry."
  ;; from "/", never the current buffer's folder, which may be remote (a remote *scratch*): expanding "~" there asks that host
  (let* ((default-directory "/") (buf (get-buffer-create drgnx-start-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'drgnx-start-mode) (drgnx-start-mode))
      (setq default-directory (expand-file-name "~/"))
      (drgnx-start--render))
    buf))

;;;; Showing it

(defun drgnx-start-dismissed-p ()
  "Non-nil when the user asked not to see the start page again (`:start-dismissed' in face.eld)."
  (and (plist-get (drgnx-face-state-read) :start-dismissed) t))

(defun drgnx-start--window (frame)
  "FRAME's editor window used last, or nil.  Never selects one."
  (or (and (eq frame (selected-frame)) (fboundp 'drgnx-signal-editor-window) (drgnx-signal-editor-window))
      (seq-find (lambda (w) (if (fboundp 'drgnx-signal-editor-window-p)
                                (drgnx-signal-editor-window-p w)
                              (not (window-minibuffer-p w))))
                (window-list frame 'nomini))))

(defun drgnx-start--untouched-scratch-p (buffer)
  "Non-nil when BUFFER is `*scratch*' as Emacs made it: not modified, empty,
or still holding `initial-scratch-message'.  Text the user typed there is theirs: it keeps the window.
Only a buffer under 2000 characters is compared."
  (and (equal (buffer-name buffer) "*scratch*")
       (with-current-buffer buffer
         (or (not (buffer-modified-p))
             (zerop (buffer-size))
             (and (stringp initial-scratch-message) (< (buffer-size) 2000)
                  (string= (string-trim (buffer-substring-no-properties (point-min) (point-max)))
                           (string-trim (substitute-command-keys initial-scratch-message))))))))

(defun drgnx-start--empty-p (window)
  "Non-nil when WINDOW shows nothing worth keeping on screen: an untouched `*scratch*'.
A file, any other buffer, or a scratch with the user's own text is kept."
  (drgnx-start--untouched-scratch-p (window-buffer window)))

(defun drgnx-start--welcome-due-p ()
  "Non-nil while the first-run Welcome is due (`drgnx-onboard--welcome-due-p'): it comes first, the page waits.
Run from \"/\": the state file's directory must not be worked out from a remote buffer's folder."
  (and (fboundp 'drgnx-onboard--welcome-due-p)
       (let ((default-directory "/")) (drgnx-onboard--welcome-due-p))))

(defun drgnx-start-maybe-show (&optional frame)
  "Show the start page in FRAME's editor window used last, when that window shows `*scratch*' and the page was not
dismissed.  FRAME defaults to the selected frame.  It changes that one window's buffer: it never splits, never
selects another window, never asks and never signals (it runs from hooks, so a failure is said in *Messages*).
Reads only face.eld (and, while the first-run Welcome may be due, onboarding's state file).
Always returns nil, so it can be a hook function."
  (let ((frame (or frame (selected-frame))))
    (condition-case err
        (when-let* (((frame-live-p frame)) ((not (eq (drgnx-state-frame-kind frame) 'child)))
                    (window (drgnx-start--window frame))
                    ((window-live-p window)) ((not (window-dedicated-p window)))
                    ((drgnx-start--empty-p window))
                    ((not (drgnx-start--welcome-due-p)))
                    ((not (drgnx-start-dismissed-p))))
          (set-window-buffer window (drgnx-start--buffer)))
      (error (message "drgnx: the start page did not show: %s" (error-message-string err))))
    nil))

(defun drgnx-start-show ()
  "Show the start page in the editor window used last and select it (also after \"Don't show this again\")."
  (interactive)
  (let ((window (or (drgnx-start--window (selected-frame)) (selected-window))))
    (set-window-buffer window (drgnx-start--buffer))
    (select-window window)))

(defun drgnx-start-dismiss ()
  "Never show the start page by itself again (kept in face.eld), and put it away: its windows show `*scratch*'."
  (interactive)
  (drgnx-face-state-put '(:start-dismissed t))
  (when-let* ((buf (get-buffer drgnx-start-buffer-name)))
    (dolist (w (get-buffer-window-list buf nil t))
      (set-window-buffer w (get-scratch-buffer-create)))
    (kill-buffer buf))
  (message "The start page will not show again; Show Start Page in the palette brings it back"))

;;;; When it shows

(defun drgnx-start--first-frame-run ()
  "The idle timer's function, a moment after a start's first window: show the page for the selected frame."
  (drgnx-start-maybe-show))

(defun drgnx-start--on-first-frame ()
  "From `drgnx-first-gui-frame-hook' and `window-setup-hook': show the page from an idle timer, never inside the
hook (the files asked for and the restored layout come first).  A daemon's own frame has no window to fill: its
clients are left to `server-after-make-frame-hook'.  The timer waits a second, after the Welcome's (0.5 s), which
comes first on a first run."
  (unless (or noninteractive (and (daemonp) (not (display-graphic-p))))
    (drgnx-timer-start 'start-first-frame 1 #'drgnx-start--first-frame-run :idle t :owner 'ui/face)))

(defun drgnx-start--no-file-tabs-p ()
  "Non-nil when the editor window used last holds no tab that visits a file."
  (or (not (fboundp 'drgnx-chrome-tabs))
      (let ((w (drgnx-start--window (selected-frame))))
        (not (and w (seq-some #'buffer-file-name (drgnx-chrome-tabs w)))))))

(defconst drgnx-start--welcome-buffer-name "*drgnx Welcome*" "The first-run Welcome's buffer (core/onboard).")

(defun drgnx-start--on-editor-changed (buffer)
  "From the bus's `editor-changed' (BUFFER is the editor now shown): when the editor went from a file, or from the
first-run Welcome, to `*scratch*' and no file tab is left, show the page — the last file closed, or the Welcome did.
Going to `*scratch*' from anything else is the user's own doing and stays."
  (let ((was-file drgnx-start--after-file))
    (setq drgnx-start--after-file
          (and (buffer-live-p buffer)
               (or (buffer-file-name buffer) (equal (buffer-name buffer) drgnx-start--welcome-buffer-name))
               t))
    (when (and was-file (not noninteractive) (buffer-live-p buffer)
               (equal (buffer-name buffer) "*scratch*") (drgnx-start--no-file-tabs-p))
      (drgnx-start-maybe-show))))

;;;; Setup

(defun drgnx-start-setup ()
  "Define Show Start Page and hang the page on the starts it belongs to (ui/face's setup); idempotent."
  (drgnx-command-define 'start-page :category "Help" :title "Show Start Page" :command #'drgnx-start-show
                        :doc "What drgnx is and the keys that open everything; it shows itself in an empty editor")
  (add-hook 'drgnx-persist-after-restore-functions #'drgnx-start-maybe-show)
  (add-hook 'server-after-make-frame-hook #'drgnx-start-maybe-show 90)   ; after the restore decided
  (add-hook 'drgnx-first-gui-frame-hook #'drgnx-start--on-first-frame)
  (add-hook 'window-setup-hook #'drgnx-start--on-first-frame)            ; a terminal has no first GUI frame
  (when (fboundp 'drgnx-signal-subscribe)
    (drgnx-signal-subscribe 'editor-changed #'drgnx-start--on-editor-changed)))

(defun drgnx-start-teardown ()
  "Take the page off every hook and the bus (what `drgnx-start-setup' added; the command stays).  Its timer
belongs to ui/face's run and ends with it."
  (remove-hook 'drgnx-persist-after-restore-functions #'drgnx-start-maybe-show)
  (remove-hook 'server-after-make-frame-hook #'drgnx-start-maybe-show)
  (remove-hook 'drgnx-first-gui-frame-hook #'drgnx-start--on-first-frame)
  (remove-hook 'window-setup-hook #'drgnx-start--on-first-frame)
  (when (fboundp 'drgnx-signal-unsubscribe)
    (drgnx-signal-unsubscribe 'editor-changed #'drgnx-start--on-editor-changed))
  (setq drgnx-start--after-file nil))

(provide 'drgnx-start)
;;; drgnx-start.el ends here
