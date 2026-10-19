;;; drgnx-signal.el --- The workbench change bus -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The subscription API for workbench edges.  Window answers come from the workbench state store
;; (`drgnx-state.el'): the most recently used editor window, whether a window is an editor window, and what
;; changed in a frame's windows.  The bus itself listens to Emacs' buffer hooks only.  A raw hook does no work:
;; it arms one idle flush, which the store's idle lane shares.  The flush observes the selected frame
;; (`drgnx-state-sync'), makes the store's waiting idle calls, then compares the buffer state with the last
;; flush and emits edges only — `editor-changed' (the buffer of the selected frame's MRU editor window, when it
;; is not the one sent last), `editor-point-changed' (that window's point moved, in the same buffer; data: the
;; buffer), `frame-changed' (the store saw another frame become the selected one), `buffer-set-changed' (the
;; set of user buffers: files and directories) and `modified-changed' (buffers whose modified flag flipped).
;; Internal buffers (names starting with a space) never count.
;; Followers (the Explorer's reveal, the Buffers panel) subscribe here and never to hooks, so a
;; focus change, a background buffer or a burst of events cannot make them fire.
;; See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-modules-record)
(require 'drgnx-state)                  ; also `drgnx-signal-delay' and `drgnx-signal-errors'

(defvar drgnx-signal--subscribers nil "Alist EVENT → list of functions, in subscription order.")
(defvar drgnx-signal--state nil "The buffer state at the last flush: (:set :modified :names :point).")
(defvar drgnx-signal--timer nil "The armed idle flush, or nil (the store's idle lane arms it too).")
(defvar drgnx-signal--editor nil
  "The buffer the bus's `editor-changed' subscribers got last (the store has the window).")
(defvar drgnx-signal--switched nil
  "The frame the store saw become the selected one since the last flush, or nil: the next `frame-changed'.")

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
  "Non-nil if WINDOW is an editor window: its role in the state store is `editor' (`drgnx-state-window-role').
Not the minibuffer, a package's side window or a window of a role in the store's role table — a dock, an
area, a popup lane, a find bar (once tools/replace defined `bar'), …"
  (eq (drgnx-state-window-role window) 'editor))

(defun drgnx-signal-editor-window ()
  "The selected frame's most recently used editor window, from the state store (`drgnx-state-editor-window').
When the store has none — the frame not observed yet, or its editor deleted since — the frame is observed now
\(`drgnx-state-sync').  Nil when the frame has no editor window or is no workbench frame."
  (or (drgnx-state-editor-window)
      (progn (drgnx-state-sync) (drgnx-state-editor-window))))

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

(defvar drgnx-signal-mode)

(defun drgnx-signal--flush ()
  "The idle flush: observe the selected frame (`drgnx-state-sync') and make the store's waiting idle calls,
then compare the buffer state with the last flush and emit the edges.
`editor-changed' gets the buffer of the selected frame's MRU editor window, only when it is not the one sent
last: two windows on one buffer are one edge.  Only the parts in `drgnx-signal--dirty' are rebuilt: `set'
\(the user buffers and their names), `modified' (their flags; a new set needs them too).  The mode off, no hook
says what changed, so all of it is rebuilt."
  (setq drgnx-signal--timer nil)
  (drgnx-state-sync)
  (drgnx-state--deliver-idle)
  (let* ((window (drgnx-signal-editor-window))
         (editor (and window (window-buffer window)))
         (last drgnx-signal--editor)
         (switched (prog1 drgnx-signal--switched (setq drgnx-signal--switched nil)))
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
    (setq drgnx-signal--state (list :set set :modified modified :names names
                                    :point (and window (window-point window)))
          drgnx-signal--editor editor)
    (unless (eq editor last)
      (drgnx-signal--emit 'editor-changed editor))
    (when (and old editor (eq editor last)
               (not (eql (plist-get drgnx-signal--state :point) (plist-get old :point))))
      (drgnx-signal--emit 'editor-point-changed editor))
    (when (frame-live-p switched)
      (drgnx-signal--emit 'frame-changed switched))
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
that follows the user's work subscribes to the edges instead.  Run from the state store's observation
\(its `windows-changed' event, `now' lane), which new code subscribes to instead.")
(make-obsolete-variable 'drgnx-signal-window-functions
                        "subscribe to the state store's `windows-changed' on the `now' lane (`drgnx-state-subscribe')."
                        "M12f")

(defun drgnx-signal--windows (frame)
  "Set up FRAME's windows now (`drgnx-signal-window-functions'; a function that fails is recorded, like a
subscriber), flush the edges later."
  (with-suppressed-warnings ((obsolete drgnx-signal-window-functions))
    (run-hook-wrapped 'drgnx-signal-window-functions
                      (lambda (fn) (drgnx-signal--call 'window-functions fn frame) nil)))
  (drgnx-signal--schedule))

;; What the bus takes from the state store (`now' lane: inside the observation, before the frame is drawn).

(defun drgnx-signal--windows-changed (data)
  "The store's `windows-changed': run `drgnx-signal-window-functions' with the frame."
  (drgnx-signal--windows (plist-get data :frame)))

(defun drgnx-signal--editor-changed (_data)
  "The store's `editor-changed': a frame's MRU editor window or its buffer changed, so arm the flush (it sends
the bus's `editor-changed' when the selected frame's editor shows another buffer)."
  (drgnx-signal--schedule))

(defun drgnx-signal--selected-changed (data)
  "The store's `selected-changed': arm the flush; when another frame became the selected one, the flush
sends `frame-changed' with it."
  (unless (eq (plist-get data :frame) (plist-get data :old-frame))
    (setq drgnx-signal--switched (plist-get data :frame)))
  (drgnx-signal--schedule))

(defconst drgnx-signal--store-events
  '((windows-changed . drgnx-signal--windows-changed)
    (editor-changed . drgnx-signal--editor-changed)
    (selected-changed . drgnx-signal--selected-changed))
  "The state store's events the bus follows, each with its named function (the mode subscribes them on the
`now' lane, and unsubscribes them).")

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

(defun drgnx-signal--mode-changed (&rest _)
  "`after-change-major-mode-hook': a buffer's major mode (and so maybe its place in the set) changed.
Internal buffers (a leading space) are skipped: mode calls in temporary buffers are no change."
  (unless (string-prefix-p " " (buffer-name))
    (drgnx-signal--set-dirty)))

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
  '((buffer-list-update-hook . drgnx-signal--set-dirty)
    (first-change-hook . drgnx-signal--modified-dirty)
    (after-save-hook . drgnx-signal--modified-dirty)
    (after-save-hook . drgnx-signal--set-dirty)                  ; `write-file' under the buffer's own name
    (after-change-major-mode-hook . drgnx-signal--mode-changed)  ; `dired-mode' on an existing buffer
    (after-revert-hook . drgnx-signal--modified-dirty)
    (kill-buffer-hook . drgnx-signal--killed)
    (post-command-hook . drgnx-signal--post-command))
  "The raw hooks the bus listens to, each with its named function (the mode adds and removes them).
`after-save-hook' has two: the flags, and the set (a saved non-file buffer becomes a file buffer, with no
rename or new buffer).  `after-change-major-mode-hook' covers a mode change on an existing buffer.  Window
changes come from the state store (`drgnx-signal--store-events').")

(define-minor-mode drgnx-signal-mode
  "The workbench change bus: raw buffer hooks and the state store's window events become deduplicated edges."
  :global t :group 'drgnx
  (pcase-dolist (`(,hook . ,fn) drgnx-signal--hooks)
    (if drgnx-signal-mode (add-hook hook fn) (remove-hook hook fn)))
  (pcase-dolist (`(,event . ,fn) drgnx-signal--store-events)
    (if drgnx-signal-mode (drgnx-state-subscribe event fn :lane 'now) (drgnx-state-unsubscribe event fn)))
  (setq drgnx-signal--seen-buffer nil drgnx-signal--switched nil)
  (when drgnx-signal-mode
    (setq drgnx-signal--dirty '(set modified))
    (drgnx-signal--schedule)))

(provide 'drgnx-signal)
;;; drgnx-signal.el ends here
