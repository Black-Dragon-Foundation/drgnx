;;; drgnx-signal.el --- The workbench change bus -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The only subscriber to Emacs' raw window and buffer hooks.  A raw hook does no work: it arms
;; one idle flush.  The flush compares the state with the last one and emits edges only —
;; `editor-changed' (the buffer of the most recently used editor window), `editor-point-changed'
;; (that window's point moved, in the same buffer; data: the buffer), `buffer-set-changed'
;; (the set of user buffers: files and directories) and `modified-changed' (buffers whose
;; modified flag flipped).  Internal buffers (names starting with a space) never count.
;; Followers (the Explorer's reveal, the Buffers panel) subscribe here and never to hooks, so a
;; focus change, a background buffer or a burst of events cannot make them fire.
;; See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-modules-record)

(defvar drgnx-signal-delay 0.05 "Idle seconds before raw events are flushed as edges.")
(defvar drgnx-signal--subscribers nil "Alist EVENT → list of functions, in subscription order.")
(defvar drgnx-signal--state nil "The state at the last flush: (:editor :set :modified :names :frame :point).")
(defvar drgnx-signal--timer nil "The armed idle flush, or nil.")
(defvar drgnx-signal--editor-window nil "The most recently selected editor window.")
(defvar drgnx-signal-errors nil "Recent subscriber errors (newest first).")

(defvar drgnx-signal--owners nil
  "Subscriptions made from module setups: a list of (EVENT FN COUNT FOREIGN), COUNT the modules holding
the subscription, FOREIGN non-nil when FN was already subscribed by code that records nothing.")

(defun drgnx-signal--release (entry)
  "A module lets go of ENTRY's subscription; the last one unsubscribes (a FOREIGN one stays)."
  (when (zerop (cl-decf (nth 2 entry)))
    (setq drgnx-signal--owners (delq entry drgnx-signal--owners))
    (unless (nth 3 entry) (drgnx-signal-unsubscribe (nth 0 entry) (nth 1 entry)))))

(defun drgnx-signal-subscribe (event fn)
  "Call FN with the event's data whenever EVENT is emitted (once per FN).
Called from a module's setup, the subscription is counted for that module and its release is
recorded (module teardown): two modules subscribing the same FN both hold it, and it goes when the
last lets go.  A subscription made before the first module's, by code that records nothing, stays."
  (let ((present (memq fn (alist-get event drgnx-signal--subscribers))))
    (unless present
      (setf (alist-get event drgnx-signal--subscribers)
            (append (alist-get event drgnx-signal--subscribers) (list fn))))
    (when (drgnx-modules--recording-p)
      (let ((entry (or (seq-find (lambda (e) (and (eq (nth 0 e) event) (eq (nth 1 e) fn))) drgnx-signal--owners)
                       (car (push (list event fn 0 (and present t)) drgnx-signal--owners)))))
        (cl-incf (nth 2 entry))
        (drgnx-modules-push-undo (format "signal %s" event) (lambda () (drgnx-signal--release entry)))))
    nil))

(defun drgnx-signal-unsubscribe (event fn)
  "Stop calling FN for EVENT."
  (setf (alist-get event drgnx-signal--subscribers) (remq fn (alist-get event drgnx-signal--subscribers))))

(defun drgnx-signal-user-buffer-p (buffer)
  "Non-nil for buffers the user works with: files and directories, never internal buffers."
  (and (buffer-live-p buffer)
       (not (string-prefix-p " " (buffer-name buffer)))
       (or (buffer-local-value 'buffer-file-name buffer)
           (eq (buffer-local-value 'major-mode buffer) 'dired-mode))))

(defun drgnx-signal-editor-window-p (window)
  "Non-nil if WINDOW is an editor window: not the minibuffer, a side window, a dock or a find bar."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (window-parameter window 'window-side))
       (not (memq (window-parameter window 'drgnx-role) '(dock panel bar)))))

(defun drgnx-signal-editor-window ()
  "The most recently used editor window (falls back to any editor window of the selected frame)."
  (if (and (window-live-p drgnx-signal--editor-window)
           (eq (window-frame drgnx-signal--editor-window) (selected-frame)))
      drgnx-signal--editor-window
    (seq-find #'drgnx-signal-editor-window-p (window-list nil 'nomini))))

(defun drgnx-signal--call (event fn data)
  "Call FN with DATA; an error is recorded in `drgnx-signal-errors' (under EVENT), never raised."
  (condition-case err (funcall fn data)
    (error (push (format "%s %s: %s" event fn (error-message-string err)) drgnx-signal-errors)
           (setq drgnx-signal-errors (seq-take drgnx-signal-errors 20)))))

(defun drgnx-signal--emit (event data)
  (dolist (fn (alist-get event drgnx-signal--subscribers))
    (drgnx-signal--call event fn data)))

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

(defvar drgnx-signal--dirty nil
  "The parts of the state the next flush rebuilds: `set' (buffers and names), `modified'.
Set by the raw-hook functions below; a flush with the mode off rebuilds both.")

(defvar drgnx-signal--seen-buffer nil
  "The current buffer at the last `post-command-hook'; with the next two, what it looked like then.")
(defvar drgnx-signal--seen-modified nil "Whether `drgnx-signal--seen-buffer' was modified (t or nil).")
(defvar drgnx-signal--seen-name nil "The name of `drgnx-signal--seen-buffer'.")

(defun drgnx-signal-post (event)
  "Emit EVENT at the next flush, once however often it is posted (a tab set changed, …)."
  (cl-pushnew event drgnx-signal--posted)
  (drgnx-signal--schedule))

(defun drgnx-signal--frame () (selected-frame))

(defvar drgnx-signal-mode)

(defun drgnx-signal--flush ()
  "Compare the state with the last flush and emit the edges.
Only the parts in `drgnx-signal--dirty' are rebuilt: `set' (the user buffers and their names), `modified'
\(their flags; a new set needs them too).  The mode off, no hook says what changed, so all of it is rebuilt."
  (setq drgnx-signal--timer nil)
  (when (drgnx-signal-editor-window-p (selected-window))
    (setq drgnx-signal--editor-window (selected-window)))
  (let* ((editor (when-let* ((w (drgnx-signal-editor-window))) (window-buffer w)))
         (old drgnx-signal--state)
         (dirty (prog1 (if (and old drgnx-signal-mode) drgnx-signal--dirty '(set modified))
                  (setq drgnx-signal--dirty nil)))
         (set-dirty (memq 'set dirty))
         (modified-dirty (or set-dirty (memq 'modified dirty)))
         (set (if set-dirty (seq-filter #'drgnx-signal-user-buffer-p (buffer-list)) (plist-get old :set)))
         (modified (if modified-dirty
                       (mapcar (lambda (b) (cons b (buffer-modified-p b))) set)
                     (plist-get old :modified)))
         (names (if set-dirty (mapcar (lambda (b) (cons b (buffer-name b))) set) (plist-get old :names))))
    (setq drgnx-signal--state (list :editor editor :set set :modified modified :names names
                                    :frame (drgnx-signal--frame)
                                    :point (when-let* ((w (drgnx-signal-editor-window))) (window-point w))))
    (unless (eq editor (plist-get old :editor))
      (drgnx-signal--emit 'editor-changed editor))
    (when (and old editor (eq editor (plist-get old :editor))
               (not (eql (plist-get drgnx-signal--state :point) (plist-get old :point))))
      (drgnx-signal--emit 'editor-point-changed editor))
    (when (and old (not (eq (plist-get old :frame) (plist-get drgnx-signal--state :frame))))
      (drgnx-signal--emit 'frame-changed (plist-get drgnx-signal--state :frame)))
    (let ((posted (reverse drgnx-signal--posted)))
      (setq drgnx-signal--posted nil)
      (dolist (e posted) (drgnx-signal--emit e nil)))
    (when (and set-dirty
               (not (and (drgnx-signal--same-set-p set (plist-get old :set))
                         (drgnx-signal--same-names-p names (plist-get old :names)))))
      (drgnx-signal--emit 'buffer-set-changed set))
    (when-let* ((modified-dirty)
                (was (let ((h (make-hash-table :test #'eq :size (length set))))
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
  "From `window-buffer-change-functions': set up the windows now, flush the edges later (a function
that fails is recorded, like a subscriber)."
  (when (framep frame-or-window)
    (run-hook-wrapped 'drgnx-signal-window-functions
                      (lambda (fn) (drgnx-signal--call 'window-functions fn frame-or-window) nil)))
  (drgnx-signal--schedule))

(defun drgnx-signal--schedule (&rest _)
  "Raw hooks land here: arm one idle flush, nothing else."
  (unless (timerp drgnx-signal--timer)
    (setq drgnx-signal--timer (run-with-idle-timer drgnx-signal-delay nil #'drgnx-signal--flush))))

(defun drgnx-signal--mark (part)
  "Note that the flush has to rebuild PART."
  (unless (memq part drgnx-signal--dirty) (push part drgnx-signal--dirty)))

(defun drgnx-signal--set-dirty (&rest _)
  "`buffer-list-update-hook': a buffer was created, killed, selected or renamed."
  (drgnx-signal--mark 'set)
  (drgnx-signal--schedule))

(defun drgnx-signal--modified-dirty (&rest _)
  "`first-change-hook', `after-save-hook', `after-revert-hook': a modified flag changed."
  (drgnx-signal--mark 'modified)
  (drgnx-signal--schedule))

(defun drgnx-signal--killed (&rest _)
  "`kill-buffer-hook': the buffer leaves the set (and the cache of `drgnx-signal--post-command')."
  (when (eq (current-buffer) drgnx-signal--seen-buffer) (setq drgnx-signal--seen-buffer nil))
  (drgnx-signal--mark 'set)
  (drgnx-signal--mark 'modified)
  (drgnx-signal--schedule))

(defun drgnx-signal--post-command ()
  "`post-command-hook': undo back to the saved state and `set-buffer-modified-p' run no buffer hook, so
compare the current buffer's modified flag and name with the cached ones.  Nothing else: no buffer list."
  (let ((buf (current-buffer))
        (modified (and (buffer-modified-p) t))
        (name (buffer-name)))
    (if (eq buf drgnx-signal--seen-buffer)
        (progn (unless (eq modified drgnx-signal--seen-modified) (drgnx-signal--mark 'modified))
               (unless (equal name drgnx-signal--seen-name) (drgnx-signal--mark 'set)))
      ;; Another buffer than last time: compare with what the last flush saw of it.
      (let ((state drgnx-signal--state))
        (when-let* ((m (assq buf (plist-get state :modified))))
          (unless (eq (cdr m) modified) (drgnx-signal--mark 'modified)))
        (when-let* ((n (assq buf (plist-get state :names))))
          (unless (equal (cdr n) name) (drgnx-signal--mark 'set))))
      (setq drgnx-signal--seen-buffer buf))
    (setq drgnx-signal--seen-modified modified
          drgnx-signal--seen-name name)
    (drgnx-signal--schedule)))

(defconst drgnx-signal--hooks
  '((window-selection-change-functions . drgnx-signal--schedule)
    (buffer-list-update-hook . drgnx-signal--set-dirty)
    (first-change-hook . drgnx-signal--modified-dirty)
    (after-save-hook . drgnx-signal--modified-dirty)
    (after-revert-hook . drgnx-signal--modified-dirty)
    (kill-buffer-hook . drgnx-signal--killed)
    (post-command-hook . drgnx-signal--post-command))
  "The raw hooks the bus listens to, each with its named function (the mode adds and removes them).")

(define-minor-mode drgnx-signal-mode
  "The workbench change bus: raw window and buffer hooks become deduplicated edges."
  :global t :group 'drgnx
  (pcase-dolist (`(,hook . ,fn) drgnx-signal--hooks)
    (if drgnx-signal-mode (add-hook hook fn) (remove-hook hook fn)))
  (if drgnx-signal-mode (add-hook 'window-buffer-change-functions #'drgnx-signal--windows)
    (remove-hook 'window-buffer-change-functions #'drgnx-signal--windows))
  (when drgnx-signal-mode
    (setq drgnx-signal--dirty '(set modified) drgnx-signal--seen-buffer nil)
    (drgnx-signal--schedule)))

(provide 'drgnx-signal)
;;; drgnx-signal.el ends here
