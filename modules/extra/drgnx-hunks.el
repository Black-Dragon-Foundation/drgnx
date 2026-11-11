;;; drgnx-hunks.el --- Module extra/hunks: the change marks in the gutter, from the hub -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The gutter of a file buffer shows what changed against the last commit: a solid 3 px bar beside each added line
;; (green) and each changed line (blue), and a short mark where lines were deleted (red), as the look's mockups draw
;; it.  The hub does the diffing (`history/hunks/head': its mirror of the buffer against HEAD, `git diff -U0' numbers),
;; so the editor runs no git and no diff of its own: after each drain of the buffer's changes to the hub the marks are
;; asked for again, on a short debounce.  Show Change, Revert Change and Stage Change work on the hunk at point from
;; the same answer (`git/stage-hunk' stages it in the hub).  Only local files the edit history tracks.  See
;; docs/guide/git.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-large-file)
(require 'drgnx-pixels)                 ; `drgnx-px'
(require 'drgnx-history)                ; `drgnx-history-ask'
(require 'drgnx-ui-kit)                 ; the status faces

(defface drgnx-hunk-added '((t :inherit drgnx-status-ok))
  "The gutter bar beside an added line." :group 'drgnx)
(defface drgnx-hunk-changed '((t :inherit drgnx-status-info))
  "The gutter bar beside a changed line." :group 'drgnx)
(defface drgnx-hunk-deleted '((t :inherit drgnx-status-fail))
  "The gutter mark where lines were deleted." :group 'drgnx)

(defvar drgnx-hunks-skip-line-function nil
  "A function of a line number, non-nil when something else draws the gutter on that line (an agent's strip).")

(defvar drgnx-hunks-delay 0.25 "Seconds after the last drain before the marks are asked for again.")

(defvar drgnx-hunks--tries-max 12 "How often a buffer the history does not track yet is tried again (every 0.5 s).")

(defvar-local drgnx-hunks--data nil
  "The hub's hunks for the buffer: a list of plists (:old-start :old-count :new-start :new-count :old-lines).")
(defvar-local drgnx-hunks--overlays nil "The overlays drawing the marks.")
(defvar-local drgnx-hunks--tries 0)
(defvar-local drgnx-hunks--request nil "The token of the question out.")
(defvar-local drgnx-hunks--margin nil "Whether this file put the left margin in the buffer (terminals).")
(defvar drgnx-hunks-mode)
(defvar drgnx-hunks--bitmap-width nil "The device pixels wide the bar bitmaps are now.")

;;;; The marks

(defun drgnx-hunks--define-bitmaps ()
  "The bar and the deleted-mark bitmaps at the frame's scale: 3 logical pixels, whole device pixels."
  (when (fboundp 'define-fringe-bitmap)
    (let ((w (min 8 (max 1 (drgnx-px 3)))))
      (unless (eql w drgnx-hunks--bitmap-width)
        (let ((row (ash (1- (ash 1 w)) (- 8 w))))
          (define-fringe-bitmap 'drgnx-hunk-bar (vector row) 1 8 '(top t))
          (define-fringe-bitmap 'drgnx-hunk-delete (make-vector w row) w 8 'top))
        (setq drgnx-hunks--bitmap-width w)))))

(defun drgnx-hunks--mark (kind)
  "The `before-string' of one marked line: a fringe bitmap in GUI frames, a margin character in terminals."
  (let ((face (pcase kind ('added 'drgnx-hunk-added) ('changed 'drgnx-hunk-changed) (_ 'drgnx-hunk-deleted)))
        (text (pcase kind ('added "added") ('changed "changed") (_ "lines deleted"))))
    (if (display-graphic-p)
        (propertize " " 'display `(left-fringe ,(if (eq kind 'deleted) 'drgnx-hunk-delete 'drgnx-hunk-bar) ,face)
                    'help-echo text)
      (propertize " " 'display (list '(margin left-margin)
                                     (propertize (pcase kind ('added "▎") ('changed "▎") (_ "▁")) 'face face))
                  'help-echo text))))

(defun drgnx-hunks--clear ()
  "Take the marks out of the buffer."
  (mapc #'delete-overlay drgnx-hunks--overlays)
  (setq drgnx-hunks--overlays nil)
  (drgnx-hunks--margin nil))

(defun drgnx-hunks--margin (on)
  "A one-column left margin in the buffer's windows while ON, for the terminal's marks."
  (unless (eq on drgnx-hunks--margin)
    (setq drgnx-hunks--margin on)
    (if on (setq-local left-margin-width 1) (kill-local-variable 'left-margin-width))
    (dolist (w (get-buffer-window-list (current-buffer) nil t))
      (set-window-margins w (and on 1) (cdr (window-margins w))))))

(defun drgnx-hunks--lines (hunks)
  "HUNKS as marked lines: a sorted list of (LINE . KIND), KIND `added', `changed' or `deleted' (the line after a
deletion carries it)."
  (let (out)
    (dolist (h hunks)
      (let ((oc (plist-get h :old-count)) (nc (plist-get h :new-count)) (ns (plist-get h :new-start)))
        (if (zerop nc)
            (push (cons (1+ ns) 'deleted) out)
          (dotimes (i nc)
            (push (cons (+ ns i) (if (< i oc) 'changed 'added)) out)))))
    (sort out (lambda (a b) (< (car a) (car b))))))

(defun drgnx-hunks--draw ()
  "Put the marks of `drgnx-hunks--data' in the buffer (those on lines something else draws are left out)."
  (drgnx-hunks--define-bitmaps)
  (drgnx-hunks--clear)
  (when drgnx-hunks--data
    (let ((marks (drgnx-hunks--lines drgnx-hunks--data)) (line 1) (last (line-number-at-pos (point-max))))
      (unless (display-graphic-p) (drgnx-hunks--margin t))
      (save-excursion
        (goto-char (point-min))
        (dolist (m marks)
          (let ((target (min (car m) last)))
            (forward-line (- target line))
            (setq line target)
            (unless (and drgnx-hunks-skip-line-function (funcall drgnx-hunks-skip-line-function target))
              (let ((o (make-overlay (point) (point) nil t nil)))
                (overlay-put o 'drgnx-hunk (cdr m))
                (overlay-put o 'before-string (drgnx-hunks--mark (cdr m)))
                (push o drgnx-hunks--overlays)))))))))

(defun drgnx-hunks-redraw (&optional buffer)
  "Draw BUFFER's marks again (something else's claim on its gutter lines changed)."
  (with-current-buffer (or buffer (current-buffer))
    (when drgnx-hunks-mode (drgnx-hunks--draw))))

;;;; Asking the hub

(defun drgnx-hunks--hunk (h)
  "The hub's hunk H (a plist as the JSON gave it) in this file's shape."
  (list :old-start (plist-get h :old_start) :old-count (plist-get h :old_count)
        :new-start (plist-get h :new_start) :new-count (plist-get h :new_count)
        :old-lines (plist-get h :old_lines)))

(defun drgnx-hunks--answered (buffer token result error)
  "The hub's answer RESULT (or ERROR) to the question TOKEN about BUFFER."
  (when (and (buffer-live-p buffer) (eq token (buffer-local-value 'drgnx-hunks--request buffer)))
    (with-current-buffer buffer
      (setq drgnx-hunks--request nil)
      (when drgnx-hunks-mode
        (if (or error (not (plist-get result :tracked)))
            (progn (setq drgnx-hunks--data nil) (drgnx-hunks--clear))
          (setq drgnx-hunks--data (mapcar #'drgnx-hunks--hunk (plist-get result :hunks)))
          (drgnx-hunks--draw))))))

(defun drgnx-hunks--refresh (buffer)
  "Ask the hub for BUFFER's hunks against HEAD; a buffer the history does not track yet is tried again a few times."
  (when (and (buffer-live-p buffer) (buffer-local-value 'drgnx-hunks-mode buffer))
    (with-current-buffer buffer
      (let ((token (list 'hunks)))
        (if (condition-case nil
                (drgnx-history-ask buffer "history/hunks/head"
                                   (lambda (result error) (drgnx-hunks--answered buffer token result error)))
              (error nil))
            (setq drgnx-hunks--request token drgnx-hunks--tries 0)
          (when (< (cl-incf drgnx-hunks--tries) drgnx-hunks--tries-max)
            (drgnx-hunks--schedule buffer 0.5)))))))

(defun drgnx-hunks--schedule (buffer &optional delay)
  "Ask for BUFFER's hunks after DELAY (default `drgnx-hunks-delay') s with no further call."
  (drgnx-timer-debounce (cons 'hunks buffer) (or delay drgnx-hunks-delay) #'drgnx-hunks--refresh
                        :args (list buffer) :owner buffer))

(defun drgnx-hunks--drained (buffer _counter _changes)
  "`drgnx-history-drained-functions': BUFFER's changes went to the hub, so its marks may have moved."
  (when (and (buffer-live-p buffer) (buffer-local-value 'drgnx-hunks-mode buffer))
    (drgnx-hunks--schedule buffer)))

(defun drgnx-hunks--changed-on-disk ()
  "`after-save-hook' and `after-revert-hook': the file and maybe HEAD moved."
  (when drgnx-hunks-mode (drgnx-hunks--schedule (current-buffer))))

(defun drgnx-hunks--refresh-all ()
  "A git front end refreshed (Magit): every buffer with marks asks again."
  (dolist (b (buffer-list))
    (when (buffer-local-value 'drgnx-hunks-mode b) (drgnx-hunks--schedule b))))

;;;; The mode

(define-minor-mode drgnx-hunks-mode
  "Change marks in the gutter of a file buffer, against the last commit."
  :lighter nil
  (if drgnx-hunks-mode
      (progn
        (add-hook 'after-save-hook #'drgnx-hunks--changed-on-disk nil t)
        (add-hook 'after-revert-hook #'drgnx-hunks--changed-on-disk nil t)
        (setq drgnx-hunks--tries 0)
        (drgnx-hunks--schedule (current-buffer)))
    (remove-hook 'after-save-hook #'drgnx-hunks--changed-on-disk t)
    (remove-hook 'after-revert-hook #'drgnx-hunks--changed-on-disk t)
    (drgnx-timer-cancel (cons 'hunks (current-buffer)))
    (setq drgnx-hunks--request nil drgnx-hunks--data nil)
    (drgnx-hunks--clear)))

(defun drgnx-hunks--maybe ()
  "`find-file-hook': marks in a local file in a git project (not a large file)."
  (when (and buffer-file-name (not (drgnx-large-file-p)) (not (file-remote-p buffer-file-name))
             (locate-dominating-file buffer-file-name ".git"))
    (drgnx-hunks-mode 1)))

;;;; The hunk at point

(defun drgnx-hunks--at-point ()
  "The hunk the current line belongs to, or a user error."
  (let ((line (line-number-at-pos)))
    (or (seq-find (lambda (h)
                    (let ((ns (plist-get h :new-start)) (nc (plist-get h :new-count)))
                      (if (zerop nc) (= line (1+ ns)) (and (>= line ns) (< line (+ ns nc))))))
                  drgnx-hunks--data)
        (user-error "No change here"))))

(defun drgnx-hunks--text (h)
  "The hunk H as a unified diff hunk of the buffer against HEAD."
  (let ((ns (plist-get h :new-start)) (nc (plist-get h :new-count)))
    (concat (format "@@ -%d,%d +%d,%d @@\n" (plist-get h :old-start) (plist-get h :old-count) ns nc)
            (mapconcat (lambda (l) (concat "-" (string-remove-suffix "\n" l) "\n")) (plist-get h :old-lines) "")
            (save-excursion
              (goto-char (point-min))
              (forward-line (1- (max 1 ns)))
              (let (out)
                (dotimes (_ nc)
                  (push (concat "+" (buffer-substring-no-properties (line-beginning-position) (line-end-position)) "\n") out)
                  (forward-line 1))
                (apply #'concat (nreverse out)))))))

(defun drgnx-hunks-show ()
  "Show Change: the change at point, against the last commit."
  (interactive)
  (let ((text (drgnx-hunks--text (drgnx-hunks--at-point))))
    ;; a one-shot buffer: the last one goes, a new one is made (a view never erases)
    (when-let* ((old (get-buffer "*drgnx change*"))) (kill-buffer old))
    (with-current-buffer (generate-new-buffer "*drgnx change*")
      (insert text)
      (diff-mode)
      (goto-char (point-min))
      (setq buffer-read-only t)
      (display-buffer (current-buffer)))))

(defun drgnx-hunks-revert ()
  "Revert Change: put the last commit's lines back in place of the change at point."
  (interactive)
  (let* ((h (drgnx-hunks--at-point)) (ns (plist-get h :new-start)) (nc (plist-get h :new-count)))
    (when (y-or-n-p "Revert this change to the last commit? ")
      (save-excursion
        (goto-char (point-min))
        (forward-line (if (zerop nc) ns (1- ns)))
        (let ((beg (point)))
          (forward-line nc)
          (delete-region beg (point))
          (goto-char beg)
          (insert (apply #'concat (plist-get h :old-lines)))))
      (drgnx-hunks--schedule (current-buffer)))))

(defun drgnx-hunks-stage ()
  "Stage Change: the change at point goes into git's index (the file is not touched)."
  (interactive)
  (let ((h (drgnx-hunks--at-point)) (buffer (current-buffer)))
    (unless (drgnx-history-ask buffer "git/stage-hunk"
                               (lambda (result error)
                                 (cond (error (message "Could not stage: %s" error))
                                       ((plist-get result :staged) (message "Staged"))
                                       (t (message "Nothing to stage here")))
                                 (drgnx-hunks--schedule buffer))
                               (list :new_start (plist-get h :new-start)))
      (user-error "The history does not track this file yet"))))

(defun drgnx-hunks--teardown ()
  "The marks out of every buffer."
  (dolist (b (buffer-list))
    (with-current-buffer b (when drgnx-hunks-mode (drgnx-hunks-mode -1)))))

(drgnx-module-define 'extra/hunks
                     :doc "Changed lines in the gutter against the last commit, from the hub; show, revert or stage a change."
                     :stage 'idle
                     :teardown #'drgnx-hunks--teardown
                     :setup
                     (lambda ()
                       (add-hook 'find-file-hook #'drgnx-hunks--maybe)
                       (add-hook 'drgnx-history-drained-functions #'drgnx-hunks--drained)
                       (eval-after-load 'magit
                         (drgnx-modules-with-owner (add-hook 'magit-post-refresh-hook #'drgnx-hunks--refresh-all)))
                       (dolist (b (buffer-list)) (with-current-buffer b (drgnx-hunks--maybe)))
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((git-hunk-show "Show Change" drgnx-hunks-show "The change at point, against the last commit")
                                        (git-hunk-revert "Revert Change" drgnx-hunks-revert "Undo the change at point")
                                        (git-hunk-stage "Stage Change" drgnx-hunks-stage "Stage the change at point")))
                         (drgnx-command-define id :category "Source Control" :title title :command fn :doc doc))))

(provide 'drgnx-hunks)
;;; drgnx-hunks.el ends here
