;;; drgnx-blame.el --- Module extra/blame: inline blame — who changed this line, when, and why -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Like VS Code's inline blame: after a short pause, the end of the line point is on says who last changed it, how
;; long ago and the commit's subject ("Ada, 3 days ago · Fix the parser"); a line you changed and have not committed
;; says "You · Uncommitted changes", a line an agent wrote "agent s1 · …".  The hub blames the whole file once
;; (`git/blame': the text of the buffer, unsaved edits included, cached by path, HEAD and text) and this file maps the
;; edits made since onto that answer, so typing asks for nothing; saving or reverting asks again.  Only local files
;; the edit history tracks (the hub is connected and the file is in a git project); a file git refuses is not asked
;; again.  Blame: Show Commit of Line opens that commit in the diff view.  See docs/guide/git.md.

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
(defvar drgnx-blame-max-edits 200
  "Edits mapped onto the hub's answer before the file is blamed again.")

(defvar-local drgnx-blame--overlay nil "The overlay showing the blame.")
(defvar-local drgnx-blame--bol nil "Where the line the overlay belongs to starts.")
(defvar-local drgnx-blame--info nil "What the overlay shows, kept to refit it when the window changes size.")
(defvar-local drgnx-blame--data nil
  "The hub's `git/blame' answer: (:commits VECTOR-OF-PLISTS :lines VECTOR-OF-INDEXES :agents LIST), for the buffer's
text at the time it was asked, or nil.")
(defvar-local drgnx-blame--edits nil
  "The edits since `drgnx-blame--data', newest first: (LINE DELETED . INSERTED), the line an edit started on and the
newlines it removed and added.")
(defvar-local drgnx-blame--before nil "The newlines in the region about to change.")
(defvar-local drgnx-blame--request nil "The token of the `git/blame' question out, or nil.")
(defvar-local drgnx-blame--off nil "The hub refused this file: not asked again.")
(defvar-local drgnx-blame--line-bol nil "A position that starts a line whose number is `drgnx-blame--line-number'.")
(defvar-local drgnx-blame--line-number nil)
(defvar drgnx-blame-mode)

(defun drgnx-blame--ago (seconds now)
  "How long before NOW the time SECONDS was, in words (whole counts: NOW is a float)."
  (let* ((d (floor (max 0 (- now seconds))))
         (say (lambda (n unit) (format "%d %s%s ago" n unit (if (= n 1) "" "s")))))
    (cond ((< d 60) "just now")
          ((< d 3600) (funcall say (/ d 60) "minute"))
          ((< d 86400) (funcall say (/ d 3600) "hour"))
          ((< d (* 30 86400)) (funcall say (/ d 86400) "day"))
          ((< d (* 365 86400)) (funcall say (/ d (* 30 86400)) "month"))
          (t (funcall say (/ d (* 365 86400)) "year")))))

(defconst drgnx-blame--gap 3 "Columns the blame's room leaves for the gap between the end of the line and the blame.")
(defconst drgnx-blame--gap-px 24 "The gap in logical pixels.")
(defconst drgnx-blame--min-width 20 "Fewer columns than this left: no blame (a stump says nothing).")
(defconst drgnx-blame--max-width 80 "The blame is never wider than this.")

(defun drgnx-blame--room ()
  "Columns left in the window after the end of the current line, less the gap and a column kept free (the
continuation arrow): what the blame may use without wrapping.  Counted from the line's text, not from what is on
screen: the screen still shows the last blame at the line's end."
  (let* ((win (or (get-buffer-window) (selected-window)))
         (numbers (line-number-display-width))
         (text (- (window-body-width win) numbers))
         (col (save-excursion (goto-char (line-end-position)) (current-column))))
    (- text (if truncate-lines (- col (window-hscroll win)) (mod col (max text 1))) drgnx-blame--gap 1)))

(defun drgnx-blame--text (info now width)
  "INFO (see `drgnx-blame--info-at') as one line in the face `drgnx-blame', at most WIDTH columns (cut with an
ellipsis) and at most `drgnx-blame--max-width'; nil when WIDTH is under `drgnx-blame--min-width'."
  (let ((width (min width drgnx-blame--max-width)))
    (when (>= width drgnx-blame--min-width)
      (let ((s (if (plist-get info :time)
                   (format "%s, %s · %s" (plist-get info :author) (drgnx-blame--ago (plist-get info :time) now) (plist-get info :summary))
                 (format "%s · %s" (plist-get info :author) (plist-get info :summary)))))
        (propertize (truncate-string-to-width (replace-regexp-in-string "[\n\r]" " " s) width nil nil "…") 'face 'drgnx-blame)))))

(defun drgnx-blame--hide ()
  (when drgnx-blame--overlay (delete-overlay drgnx-blame--overlay))
  (setq drgnx-blame--bol nil drgnx-blame--info nil))

(defun drgnx-blame--show (info)
  "Show INFO at the end of the current line, fitted to the room the window has there (nothing when there is none)."
  (setq drgnx-blame--info info drgnx-blame--bol (line-beginning-position))    ; answered for this line, shown or not
  (if-let* ((text (drgnx-blame--text info (float-time) (drgnx-blame--room))))
      (progn
        (unless drgnx-blame--overlay (setq drgnx-blame--overlay (make-overlay 1 1 nil t nil)))
        (move-overlay drgnx-blame--overlay (line-end-position) (line-end-position))
        (overlay-put drgnx-blame--overlay 'after-string
                     (concat (propertize " " 'cursor t 'display `(space :width (,(round (* drgnx-blame--gap-px (drgnx-pixels-scale))))))
                             text)))
    (when drgnx-blame--overlay (delete-overlay drgnx-blame--overlay))))

(defun drgnx-blame--resized (window)
  "`window-size-change-functions' (buffer-local; called for each WINDOW showing the buffer, with another buffer
current): the selected window's blame is fitted again to its new width (one line, not git)."
  (when (eq window (selected-window))
    (with-current-buffer (window-buffer window)
      (when (and drgnx-blame--bol drgnx-blame--info (= (line-beginning-position) drgnx-blame--bol))
        (drgnx-blame--show drgnx-blame--info)))))

(defun drgnx-blame--follow ()
  "`post-command-hook': the blame goes when point leaves its line or a region is active."
  (when (and drgnx-blame--bol (or (/= (line-beginning-position) drgnx-blame--bol) (region-active-p)))
    (drgnx-blame--hide)))

(defun drgnx-blame--line-at (pos)
  "The number of the line POS is on (the last answer is reused while edits stay at or after the line it was for)."
  (let ((bol (save-excursion (goto-char pos) (line-beginning-position))))
    (unless (and drgnx-blame--line-bol (= bol drgnx-blame--line-bol))
      (setq drgnx-blame--line-bol bol drgnx-blame--line-number (line-number-at-pos bol t)))
    drgnx-blame--line-number))

(defun drgnx-blame--newlines (beg end)
  "How many newlines the text from BEG to END holds."
  (save-excursion
    (goto-char beg)
    (let ((n 0)) (while (search-forward "\n" end t) (setq n (1+ n))) n)))

(defun drgnx-blame--before-change (beg end)
  "`before-change-functions': the newlines that go."
  (when drgnx-blame--data (setq drgnx-blame--before (drgnx-blame--newlines beg end))))

(defun drgnx-blame--after-change (beg end _len)
  "`after-change-functions': the edit is kept to map the hub's answer onto the text; past `drgnx-blame-max-edits' of
them the answer is dropped and the file is blamed again."
  (when (and drgnx-blame--data drgnx-blame--before)
    (when (and drgnx-blame--line-bol (< beg drgnx-blame--line-bol)) (setq drgnx-blame--line-bol nil))
    (let ((line (drgnx-blame--line-at beg)))
      (push (cons line (cons drgnx-blame--before (drgnx-blame--newlines beg end))) drgnx-blame--edits)
      (setq drgnx-blame--before nil)
      (when (> (length drgnx-blame--edits) drgnx-blame-max-edits) (drgnx-blame--forget)))))

(defun drgnx-blame--forget (&rest _)
  "The hub's answer no longer matches the text (a save, a revert, too many edits): it is asked for again."
  (setq drgnx-blame--data nil drgnx-blame--edits nil drgnx-blame--before nil drgnx-blame--line-bol nil))

(defun drgnx-blame--original (line)
  "The line of the hub's answer that LINE of the buffer was, `:new' for a line changed since, or nil."
  (let ((l line) (found nil))
    (catch 'done
      (dolist (e drgnx-blame--edits)
        (let ((start (car e)) (del (cadr e)) (ins (cddr e)))
          (cond ((< l start))
                ((<= l (+ start ins)) (setq found :new) (throw 'done nil))
                (t (setq l (+ (- l ins) del))))))
      (setq found l))
    found))

(defun drgnx-blame--info-at (line)
  "(:sha :author :time :summary) for LINE of the buffer from the hub's answer, or nil without one."
  (when drgnx-blame--data
    (let ((orig (drgnx-blame--original line)))
      (if (eq orig :new)
          (list :sha (make-string 40 ?0) :author "You" :time nil :summary "Uncommitted changes")
        (when (and (integerp orig) (<= 1 orig (length (plist-get drgnx-blame--data :lines))))
          (let* ((commit (aref (plist-get drgnx-blame--data :commits)
                               (aref (plist-get drgnx-blame--data :lines) (1- orig))))
                 (agent (seq-find (lambda (a) (<= (plist-get a :from) orig (plist-get a :to)))
                                  (plist-get drgnx-blame--data :agents))))
            (list :sha (plist-get commit :sha)
                  :author (if agent (format "agent %s" (or (plist-get agent :session) "")) (plist-get commit :author))
                  :time (plist-get commit :time) :summary (plist-get commit :summary))))))))

(defun drgnx-blame--answered (buffer token result error)
  "The hub's answer RESULT (or ERROR) to the question TOKEN about BUFFER."
  (when (and (buffer-live-p buffer) (eq token (buffer-local-value 'drgnx-blame--request buffer)))
    (with-current-buffer buffer
      (setq drgnx-blame--request nil)
      (if error
          ;; git has no history for the file, or the hub could not read it: not asked again until it is turned on
          (setq drgnx-blame--off t)
        (setq drgnx-blame--data (list :commits (vconcat (plist-get result :commits))
                                      :lines (vconcat (plist-get result :lines))
                                      :agents (plist-get result :agents))
              drgnx-blame--edits nil drgnx-blame--before nil drgnx-blame--line-bol nil)
        (setq drgnx-blame--bol nil)))))

(defun drgnx-blame--ask ()
  "Ask the hub to blame the whole file as the buffer holds it now (one question at a time)."
  (unless (or drgnx-blame--request drgnx-blame--off)
    (let ((buf (current-buffer)) (token (list 'blame)))
      (when (condition-case nil
                (drgnx-history-ask buf "git/blame"
                                   (lambda (result error) (drgnx-blame--answered buf token result error)))
              (error nil))
        (setq drgnx-blame--request token)))))

(defun drgnx-blame--update ()
  "Show the blame of the current line, from the hub's answer (asked for when there is none).  The empty line after
the last newline has none."
  (unless (or drgnx-blame--off (not buffer-file-name) (region-active-p) (and (eobp) (bolp)))
    (if-let* ((info (drgnx-blame--info-at (line-number-at-pos))))
        (drgnx-blame--show info)
      (drgnx-blame--ask))))

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
        (add-hook 'before-change-functions #'drgnx-blame--before-change nil t)
        (add-hook 'after-change-functions #'drgnx-blame--after-change nil t)
        (add-hook 'after-save-hook #'drgnx-blame--forget nil t)
        (add-hook 'after-revert-hook #'drgnx-blame--forget nil t)
        (add-hook 'kill-buffer-hook #'drgnx-blame--release-timer nil t)
        (unless (drgnx-timer-active-p 'blame-tick)           ; one idle timer for every buffer
          (drgnx-timer-start 'blame-tick drgnx-blame-delay #'drgnx-blame--tick :repeat t :idle t)))
    (remove-hook 'post-command-hook #'drgnx-blame--follow t)
    (remove-hook 'window-size-change-functions #'drgnx-blame--resized t)
    (remove-hook 'before-change-functions #'drgnx-blame--before-change t)
    (remove-hook 'after-change-functions #'drgnx-blame--after-change t)
    (remove-hook 'after-save-hook #'drgnx-blame--forget t)
    (remove-hook 'after-revert-hook #'drgnx-blame--forget t)
    (remove-hook 'kill-buffer-hook #'drgnx-blame--release-timer t)
    (drgnx-blame--release-timer)
    (setq drgnx-blame--request nil)
    (drgnx-blame--forget)
    (drgnx-blame--hide)))

(defun drgnx-blame--maybe ()
  "`find-file-hook': inline blame in a local file git tracks (not a large file: git blames it all)."
  (when (and buffer-file-name (not (drgnx-large-file-p)) (not (file-remote-p buffer-file-name))
             (eq (vc-backend buffer-file-name) 'Git))
    (drgnx-blame-mode 1)))

(defun drgnx-blame-show-commit ()
  "Blame: Show Commit of Line — the commit that last changed this line, in the diff view."
  (interactive)
  (unless buffer-file-name (user-error "Not a file"))
  (let ((info (drgnx-blame--info-at (line-number-at-pos))))
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
