;;; drgnx-blame.el --- Module extra/blame: inline blame — who changed this line, when, and why -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Like VS Code's inline blame: after a short pause, the end of the line point is on says who last changed it, how
;; long ago and the commit's subject ("Ada, 3 days ago · Fix the parser"); a line you changed and have not committed
;; says "You · Uncommitted changes", a line an agent wrote "agent s1 · …".  The hub does all of it: it blames the
;; buffer's text once (`git/blame', cached by path, HEAD and text), finds the line the position is on, words the text
;; and cuts it to the columns this window has left (`git/blame/line'), so this file counts no line, follows no edit and
;; formats nothing: when point rests on a new line it asks, once, with the line's position and the room, and draws the
;; answer.  Typing on a line asks nothing; a resize asks again with the new room.  Only local files the edit history
;; tracks (the hub is connected and the file is in a git project); a file git refuses is not asked again.  Blame: Show
;; Commit of Line opens that commit in the diff view.  See docs/guide/git.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-large-file)
(require 'drgnx-pixels)                 ; `drgnx-pixels-scale'
(require 'drgnx-history)                ; `drgnx-history-ask'
(require 'drgnx-faces)                  ; `drgnx-text-subtle'
(require 'drgnx-type-faces)             ; `drgnx-ui-caption'

(declare-function drgnx-diff-show "drgnx-diff")

(defface drgnx-blame '((t :inherit (italic drgnx-text-subtle drgnx-ui-caption)))
  "Inline blame at the end of the line: italic subtle text in the caption face." :group 'drgnx)

(defvar drgnx-blame-delay 0.6 "Seconds of idle time before the line's blame is asked for.")

(defvar-local drgnx-blame--overlay nil "The overlay showing the blame.")
(defvar-local drgnx-blame--bol nil "Where the line the overlay (or the last answer) belongs to starts.")
(defvar-local drgnx-blame--info nil "The hub's last answer for that line: (:text :sha :time), `:text' absent when none.")
(defvar-local drgnx-blame--request nil "The token of the `git/blame/line' question out, or nil.")
(defvar-local drgnx-blame--off nil "The hub refused this file: not asked again.")
(defvar drgnx-blame-mode)

(defconst drgnx-blame--gap 3 "Columns the blame's room leaves for the gap between the end of the line and the blame.")
(defconst drgnx-blame--gap-px 24 "The gap in logical pixels.")

(defun drgnx-blame--room ()
  "Columns left in the window after the end of the current line, less the gap and a column kept free (the
continuation arrow): what the blame may use without wrapping.  Counted from the line's text, not from what is on
screen: the screen still shows the last blame at the line's end."
  (let* ((win (or (get-buffer-window) (selected-window)))
         (numbers (line-number-display-width))
         (text (- (window-body-width win) numbers))
         (col (save-excursion (goto-char (line-end-position)) (current-column))))
    (- text (if truncate-lines (- col (window-hscroll win)) (mod col (max text 1))) drgnx-blame--gap 1)))

(defun drgnx-blame--hide ()
  (when drgnx-blame--overlay (delete-overlay drgnx-blame--overlay))
  (setq drgnx-blame--bol nil drgnx-blame--info nil))

(defun drgnx-blame--show (info)
  "Show INFO (the hub's answer for the current line) at the end of it: the hub's text, in the blame's face (nothing
when the answer has none, or inline values hold the line)."
  (setq drgnx-blame--info info drgnx-blame--bol (line-beginning-position))    ; answered for this line, shown or not
  (if-let* (((not (seq-some (lambda (o) (overlay-get o 'drgnx-blame-yield))           ; inline values hold the line
                            (overlays-in (line-beginning-position) (1+ (line-end-position))))))
            (text (plist-get info :text)))
      (progn
        (unless drgnx-blame--overlay (setq drgnx-blame--overlay (make-overlay 1 1 nil t nil)))
        (move-overlay drgnx-blame--overlay (line-end-position) (line-end-position))
        (overlay-put drgnx-blame--overlay 'after-string
                     (concat (propertize " " 'cursor t 'display `(space :width (,(round (* drgnx-blame--gap-px (drgnx-pixels-scale))))))
                             (propertize text 'face 'drgnx-blame))))
    (when drgnx-blame--overlay (delete-overlay drgnx-blame--overlay))))

(defun drgnx-blame--resized (window)
  "`window-size-change-functions' (buffer-local; called for each WINDOW showing the buffer, with another buffer
current): the selected window's line is asked for again, with the room it has now."
  (when (eq window (selected-window))
    (with-current-buffer (window-buffer window)
      (when (and drgnx-blame--bol drgnx-blame--info (= (line-beginning-position) drgnx-blame--bol))
        (drgnx-blame--ask)))))

(defun drgnx-blame--follow ()
  "`post-command-hook': the blame goes when point leaves its line or a region is active."
  (when (and drgnx-blame--bol (or (/= (line-beginning-position) drgnx-blame--bol) (region-active-p)))
    (drgnx-blame--hide)))

(defun drgnx-blame--answered (buffer token bol result error)
  "The hub's answer RESULT (or ERROR) to the question TOKEN about the line of BUFFER that started at BOL."
  (when (and (buffer-live-p buffer) (eq token (buffer-local-value 'drgnx-blame--request buffer)))
    (with-current-buffer buffer
      (setq drgnx-blame--request nil)
      (cond (error
             ;; git has no history for the file, or the hub could not read it: not asked again until it is turned on
             (setq drgnx-blame--off t))
            ;; point moved on while the answer came: not this line's to draw (the next tick asks for the new one)
            ((and drgnx-blame-mode (eql bol (line-beginning-position)))
             (drgnx-blame--show result))))))

(defun drgnx-blame--ask ()
  "Ask the hub for the blame of the current line, fitted to the room it has (one question at a time)."
  (unless (or drgnx-blame--request drgnx-blame--off)
    (let ((buf (current-buffer)) (token (list 'blame)) (bol (line-beginning-position)))
      (when (condition-case nil
                (drgnx-history-ask buf "git/blame/line"
                                   (lambda (result error) (drgnx-blame--answered buf token bol result error))
                                   (list :pos bol :width (drgnx-blame--room)))
              (error nil))
        (setq drgnx-blame--request token)))))

(defun drgnx-blame--update ()
  "Ask for the blame of the current line.  The empty line after the last newline has none."
  (unless (or drgnx-blame--off (not buffer-file-name) (region-active-p) (and (eobp) (bolp)))
    (drgnx-blame--ask)))

(defun drgnx-blame--tick ()
  "The idle timer: the selected window's buffer, if it has inline blame."
  (with-current-buffer (window-buffer (selected-window))
    (when (and drgnx-blame-mode (not (eql drgnx-blame--bol (line-beginning-position))))
      (with-demoted-errors "drgnx blame: %S" (drgnx-blame--update)))))

(defun drgnx-blame--release-timer ()
  "Cancel the idle timer when no buffer but this one has inline blame (this one is going: off or killed)."
  (unless (seq-some (lambda (b) (and (not (eq b (current-buffer))) (buffer-local-value 'drgnx-blame-mode b))) (buffer-list))
    (drgnx-timer-cancel 'blame-tick)))

(define-minor-mode drgnx-blame-mode
  "Inline blame: who last changed the current line, when, and the commit's subject, at its end."
  :lighter nil
  (if drgnx-blame-mode
      (progn
        (setq drgnx-blame--off nil)                          ; turned on again: asked again
        (add-hook 'post-command-hook #'drgnx-blame--follow nil t)
        (add-hook 'window-size-change-functions #'drgnx-blame--resized nil t)
        (add-hook 'kill-buffer-hook #'drgnx-blame--release-timer nil t)
        (unless (drgnx-timer-active-p 'blame-tick)           ; one idle timer for every buffer
          (drgnx-timer-start 'blame-tick drgnx-blame-delay #'drgnx-blame--tick :repeat t :idle t)))
    (remove-hook 'post-command-hook #'drgnx-blame--follow t)
    (remove-hook 'window-size-change-functions #'drgnx-blame--resized t)
    (remove-hook 'kill-buffer-hook #'drgnx-blame--release-timer t)
    (drgnx-blame--release-timer)
    (setq drgnx-blame--request nil)
    (drgnx-blame--hide)))

(defun drgnx-blame--maybe ()
  "`find-file-hook': inline blame in a local file git tracks (not a large file: the hub gives it no blame either)."
  (when (and buffer-file-name (not (drgnx-large-file-p)) (not (file-remote-p buffer-file-name))
             (eq (vc-backend buffer-file-name) 'Git))
    (drgnx-blame-mode 1)))

(defun drgnx-blame-show-commit ()
  "Blame: Show Commit of Line — the commit that last changed this line, in the diff view."
  (interactive)
  (unless buffer-file-name (user-error "Not a file"))
  (let ((info (and drgnx-blame--bol (= drgnx-blame--bol (line-beginning-position)) drgnx-blame--info)))
    (cond ((null info) (user-error "No blame yet for this line: the hub has not answered"))
          ((null (plist-get info :time)) (user-error "This line is not committed yet"))
          ((not (fboundp 'drgnx-diff-show)) (user-error "The diff view (module tools/diff) is off"))
          (t (drgnx-diff-show (list 'commit (plist-get info :sha)))))))

(defun drgnx-blame--teardown ()
  "Inline blame off in every buffer that has it (the last one cancels the timer)."
  (dolist (b (buffer-list))
    (with-current-buffer b (when drgnx-blame-mode (drgnx-blame-mode -1)))))

(drgnx-module-define 'extra/blame
                     :doc "Inline blame: the current line's author, age and commit subject at its end."
                     :stage 'idle
                     :teardown #'drgnx-blame--teardown
                     :setup
                     (lambda ()
                       (add-hook 'find-file-hook #'drgnx-blame--maybe)
                       (dolist (b (buffer-list)) (with-current-buffer b (drgnx-blame--maybe)))
                       (drgnx-command-define 'toggle-inline-blame :category "Source Control" :title "Toggle Inline Blame"
                                             :command #'drgnx-blame-mode :doc "Who changed the current line, at its end; off or on")
                       (drgnx-command-define 'blame-show-commit :category "Source Control" :title "Blame: Show Commit of Line"
                                             :command #'drgnx-blame-show-commit :doc "The commit that last changed this line")))

(provide 'drgnx-blame)
;;; drgnx-blame.el ends here
