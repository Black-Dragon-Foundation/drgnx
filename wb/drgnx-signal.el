;;; drgnx-signal.el --- The workbench change bus -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The only subscriber to Emacs' raw window and buffer hooks.  A raw hook does no work: it arms
;; one idle flush.  The flush compares the state with the last one and emits edges only —
;; `editor-changed' (the buffer of the most recently used editor window), `buffer-set-changed'
;; (the set of user buffers: files and directories) and `modified-changed' (buffers whose
;; modified flag flipped).  Internal buffers (names starting with a space) never count.
;; Followers (the Explorer's reveal, the Buffers panel) subscribe here and never to hooks, so a
;; focus change, a background buffer or a burst of events cannot make them fire.
;; See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)

(defvar drgnx-signal-delay 0.05 "Idle seconds before raw events are flushed as edges.")
(defvar drgnx-signal--subscribers nil "Alist EVENT → list of functions, in subscription order.")
(defvar drgnx-signal--state nil "The state at the last flush: (:editor :set :modified).")
(defvar drgnx-signal--timer nil "The armed idle flush, or nil.")
(defvar drgnx-signal--editor-window nil "The most recently selected editor window.")
(defvar drgnx-signal-errors nil "Recent subscriber errors (newest first).")

(defun drgnx-signal-subscribe (event fn)
  "Call FN with the event's data whenever EVENT is emitted (once per FN)."
  (unless (memq fn (alist-get event drgnx-signal--subscribers))
    (setf (alist-get event drgnx-signal--subscribers)
          (append (alist-get event drgnx-signal--subscribers) (list fn)))))

(defun drgnx-signal-unsubscribe (event fn)
  (setf (alist-get event drgnx-signal--subscribers) (remq fn (alist-get event drgnx-signal--subscribers))))

(defun drgnx-signal-user-buffer-p (buffer)
  "Non-nil for buffers the user works with: files and directories, never internal buffers."
  (and (buffer-live-p buffer)
       (not (string-prefix-p " " (buffer-name buffer)))
       (or (buffer-local-value 'buffer-file-name buffer)
           (eq (buffer-local-value 'major-mode buffer) 'dired-mode))))

(defun drgnx-signal-editor-window-p (window)
  "Non-nil if WINDOW is an editor window: not the minibuffer, a side window or a dock."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (window-parameter window 'window-side))
       (not (memq (window-parameter window 'drgnx-role) '(dock panel)))))

(defun drgnx-signal-editor-window ()
  "The most recently used editor window (falls back to any editor window of the selected frame)."
  (if (and (window-live-p drgnx-signal--editor-window)
           (eq (window-frame drgnx-signal--editor-window) (selected-frame)))
      drgnx-signal--editor-window
    (seq-find #'drgnx-signal-editor-window-p (window-list nil 'nomini))))

(defun drgnx-signal--emit (event data)
  (dolist (fn (alist-get event drgnx-signal--subscribers))
    (condition-case err (funcall fn data)
      (error (push (format "%s %s: %s" event fn (error-message-string err)) drgnx-signal-errors)
             (setq drgnx-signal-errors (seq-take drgnx-signal-errors 20))))))

(defun drgnx-signal--same-set-p (a b)
  "Non-nil if the lists A and B hold the same objects (linear time: a flush runs on every switch)."
  (and (= (length a) (length b))
       (let ((seen (make-hash-table :test #'eq :size (length a))))
         (dolist (x a) (puthash x t seen))
         (seq-every-p (lambda (x) (gethash x seen)) b))))

(defun drgnx-signal--same-names-p (a b)
  "Non-nil if the alists A and B (buffer . name) give every buffer the same name (order ignored)."
  (let ((old (make-hash-table :test #'eq :size (length b))))
    (pcase-dolist (`(,buf . ,name) b) (puthash buf name old))
    (seq-every-p (lambda (p) (equal (gethash (car p) old) (cdr p))) a)))

(defvar drgnx-signal--posted nil "Events posted since the last flush (`drgnx-signal-post').")

(defun drgnx-signal-post (event)
  "Emit EVENT at the next flush, once however often it is posted (a tab set changed, …)."
  (cl-pushnew event drgnx-signal--posted)
  (drgnx-signal--schedule))

(defun drgnx-signal--frame () (selected-frame))

(defun drgnx-signal--flush ()
  "Compare the state with the last flush and emit the edges."
  (setq drgnx-signal--timer nil)
  (when (drgnx-signal-editor-window-p (selected-window))
    (setq drgnx-signal--editor-window (selected-window)))
  (let* ((editor (when-let* ((w (drgnx-signal-editor-window))) (window-buffer w)))
         (set (seq-filter #'drgnx-signal-user-buffer-p (buffer-list)))
         (modified (mapcar (lambda (b) (cons b (buffer-modified-p b))) set))
         (names (mapcar (lambda (b) (cons b (buffer-name b))) set))
         (old drgnx-signal--state))
    (setq drgnx-signal--state (list :editor editor :set set :modified modified :names names
                                    :frame (drgnx-signal--frame)))
    (unless (eq editor (plist-get old :editor))
      (drgnx-signal--emit 'editor-changed editor))
    (when (and old (not (eq (plist-get old :frame) (plist-get drgnx-signal--state :frame))))
      (drgnx-signal--emit 'frame-changed (plist-get drgnx-signal--state :frame)))
    (let ((posted (reverse drgnx-signal--posted)))
      (setq drgnx-signal--posted nil)
      (dolist (e posted) (drgnx-signal--emit e nil)))
    (unless (and (drgnx-signal--same-set-p set (plist-get old :set))
                 (drgnx-signal--same-names-p names (plist-get old :names)))
      (drgnx-signal--emit 'buffer-set-changed set))
    (when-let* ((was (let ((h (make-hash-table :test #'eq :size (length set))))
                       (pcase-dolist (`(,b . ,m) (plist-get old :modified)) (puthash b (if m 'yes 'no) h))
                       h))
                (flipped (seq-filter (lambda (b) (when-let* ((m (gethash b was)))
                                                  (not (eq (eq m 'yes) (and (buffer-modified-p b) t)))))
                                     set)))
      (drgnx-signal--emit 'modified-changed flipped))))

(defvar drgnx-signal-window-functions nil
  "Called with a frame, synchronously, when its windows or their buffers changed — before they are
drawn.  For window *setup* only (chrome: a new window must not be drawn once without it); anything
that follows the user's work subscribes to the edges instead.")

(defun drgnx-signal--windows (frame-or-window)
  "From `window-buffer-change-functions': set up the windows now, flush the edges later."
  (when (framep frame-or-window)
    (run-hook-with-args 'drgnx-signal-window-functions frame-or-window))
  (drgnx-signal--schedule))

(defun drgnx-signal--schedule (&rest _)
  "Raw hooks land here: arm one idle flush, nothing else."
  (unless (timerp drgnx-signal--timer)
    (setq drgnx-signal--timer (run-with-idle-timer drgnx-signal-delay nil #'drgnx-signal--flush))))

(defconst drgnx-signal--hooks
  '(window-selection-change-functions buffer-list-update-hook
    first-change-hook after-save-hook after-revert-hook kill-buffer-hook
    ;; Undo back to the saved state, `set-buffer-modified-p' and `rename-buffer' run no buffer
    ;; hook: every command arms the (cheap, idle) flush too.
    post-command-hook)
  "The raw hooks the bus listens to.")

(define-minor-mode drgnx-signal-mode
  "The workbench change bus: raw window and buffer hooks become deduplicated edges."
  :global t :group 'drgnx
  (dolist (h drgnx-signal--hooks)
    (if drgnx-signal-mode (add-hook h #'drgnx-signal--schedule) (remove-hook h #'drgnx-signal--schedule)))
  (if drgnx-signal-mode (add-hook 'window-buffer-change-functions #'drgnx-signal--windows)
    (remove-hook 'window-buffer-change-functions #'drgnx-signal--windows))
  (when drgnx-signal-mode (drgnx-signal--schedule)))

(provide 'drgnx-signal)
;;; drgnx-signal.el ends here
