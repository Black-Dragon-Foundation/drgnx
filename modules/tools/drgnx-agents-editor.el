;;; drgnx-agents-editor.el --- Module tools/agents-in-editor: the editor watches the buffers it shows -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Agents drawn in the buffer: this file is the client.  A file buffer a window shows is watched (the hub is asked
;; for its frame, `agents/buffer/watch'); one no window shows is unwatched, so a hidden buffer receives no frame and
;; has nothing drawn.  The hub sends `agent-buffer' events: a full frame, or a delta that names its base version.
;;
;; The core, `drgnx-agents-editor--core-step', is pure: (STATE EVENT) -> (STATE . EFFECTS).  Events are `watch',
;; `unwatch', `frame', `delta', `buffer-changed' and `restart'.  A delta older than the state is dropped, a delta
;; whose base is not the state's version asks for a full frame, and a frame (or delta) whose `doc_version' is older
;; than the buffer's last change sent to the hub is dropped.  Effects: `call-watch', `call-unwatch', `apply'.
;; The shell keeps one state per watched buffer, runs the effects and, for `apply', calls the functions of
;; `drgnx-agents-editor-apply-functions' (the drawing, drgnx-agents-editor-draw.el) straight away: frames do not go
;; through any 50 ms flush, the hub already coalesces them.  Nothing here draws or reads the buffer.
;; See docs/guide/agents-in-the-editor.md and docs/develop/agents-editor.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-hub-client)

(declare-function drgnx-agent-identity-clear "drgnx-agent-identity")
(defvar drgnx-agent-identity-watched-function)

;;;; The pure core

(cl-defstruct (drgnx-agents-editor--state (:constructor drgnx-agents-editor--state-make)
                                          (:copier drgnx-agents-editor--state-copy))
  "One watched buffer.  FRAME: the hub's last frame (a plist: :version :doc_version :agents :gutter :approximate).
VERSION: the frame's version, nil after a restart (no delta then has a base).  SENT: the buffer's last change
number sent to the hub."
  frame version (sent 0))

(defun drgnx-agents-editor--core-step (state event)
  "The next state and the effects of EVENT in STATE: (NEW-STATE . EFFECTS).  Pure.
STATE is nil for an unwatched buffer.  EVENT: (watch), (unwatch), (frame FRAME), (delta DELTA), (buffer-changed N)
or (restart).  A frame is a plist with :version, :doc_version, :agents and :gutter; a delta has :version, :base and
the :agents and :gutter that changed (each replaces the frame's whole list)."
  (pcase event
    (`(watch) (cons (or state (drgnx-agents-editor--state-make)) '((call-watch))))
    (`(unwatch) (cons nil (and state '((call-unwatch)))))
    (`(buffer-changed ,n)
     (if state
         (let ((s (drgnx-agents-editor--state-copy state)))
           (setf (drgnx-agents-editor--state-sent s) (max n (drgnx-agents-editor--state-sent s)))
           (cons s nil))
       (cons nil nil)))
    (`(restart) (if state
                    (let ((s (drgnx-agents-editor--state-copy state)))
                      (setf (drgnx-agents-editor--state-version s) nil)
                      (cons s '((call-watch))))
                  (cons nil nil)))
    (`(frame ,f)
     (if (or (null state) (drgnx-agents-editor--stale-p state f))
         (cons state nil)
       (let ((s (drgnx-agents-editor--state-copy state)))
         (setf (drgnx-agents-editor--state-frame s) f (drgnx-agents-editor--state-version s) (plist-get f :version))
         (cons s '((apply))))))
    (`(delta ,d)
     (let ((version (and state (drgnx-agents-editor--state-version state))))
       (cond ((null state) (cons nil nil))
             ((and version (<= (or (plist-get d :version) 0) version)) (cons state nil))   ; older than what is held
             ((drgnx-agents-editor--stale-p state d) (cons state nil))
             ((or (null version) (not (eql (plist-get d :base) version))) (cons state '((call-watch))))   ; a gap: a full frame
             (t (let ((s (drgnx-agents-editor--state-copy state))
                      (f (copy-sequence (drgnx-agents-editor--state-frame state))))
                  (dolist (key '(:agents :gutter :approximate :doc_version))
                    (when (plist-member d key) (setq f (plist-put f key (plist-get d key)))))
                  (setf f (plist-put f :version (plist-get d :version)))
                  (setf (drgnx-agents-editor--state-frame s) f
                        (drgnx-agents-editor--state-version s) (plist-get d :version))
                  (cons s '((apply))))))))
    (_ (error "drgnx-agents-editor: no event %S" event))))

(defun drgnx-agents-editor--stale-p (state f)
  "Non-nil when F (a frame or delta) was made for a document older than the buffer's last change sent to the hub."
  (let ((doc (plist-get f :doc_version)))
    (and doc (< doc (drgnx-agents-editor--state-sent state)))))

;;;; The shell

(defvar drgnx-agents-editor-apply-functions nil
  "Functions called with (BUFFER FRAME) when the hub's frame for a watched BUFFER changes.  They draw from FRAME only.")

(defvar drgnx-agents-editor--states (make-hash-table :test 'eq :weakness 'key)
  "Watched BUFFER → its `drgnx-agents-editor--state'.  Weak on the buffer; pruned when a window change finds it dead.")
(defvar drgnx-agents-editor--views (make-hash-table :test 'equal)
  "View id (a string) → the watched buffer, pruned of dead buffers at each window change.")
(defvar drgnx-agents-editor--view-count 0)
(defvar-local drgnx-agents-editor--view nil "This buffer's view id at the hub while it is watched.")

(defun drgnx-agents-editor-frame (buffer)
  "The cached frame of watched BUFFER (a plist), or nil when it is not watched or has none yet."
  (when-let* ((s (gethash buffer drgnx-agents-editor--states)))
    (drgnx-agents-editor--state-frame s)))

(defun drgnx-agents-editor-watched-buffers ()
  "The buffers watched now."
  (let (out) (maphash (lambda (b _) (when (buffer-live-p b) (push b out))) drgnx-agents-editor--states) out))

(defun drgnx-agents-editor--ask (method params fn)
  "Ask the hub METHOD with PARAMS; FN gets a result.  A missing hub or an error is quiet: the next connection watches again."
  (condition-case nil
      (drgnx-hub-call method params (lambda (result err) (when (and (not err) result) (funcall fn result))))
    (error nil)))

(defun drgnx-agents-editor--watch-call (buffer)
  (when (buffer-live-p buffer)
    (let ((view (buffer-local-value 'drgnx-agents-editor--view buffer))
          (file (buffer-file-name buffer))
          (state (gethash buffer drgnx-agents-editor--states)))
      (when (and view file state)
        (drgnx-agents-editor--ask
         "agents/buffer/watch"
         (list :view view :file file :doc_version (drgnx-agents-editor--state-sent state))
         (lambda (frame) (drgnx-agents-editor--feed buffer (list 'frame frame))))))))

(defun drgnx-agents-editor--run (buffer effects)
  (dolist (e effects)
    (pcase (car e)
      ('call-watch (drgnx-agents-editor--watch-call buffer))
      ('apply (when-let* ((s (gethash buffer drgnx-agents-editor--states)))
                (run-hook-with-args 'drgnx-agents-editor-apply-functions buffer (drgnx-agents-editor--state-frame s)))))))

(defun drgnx-agents-editor--feed (buffer event)
  "Run EVENT through the core for BUFFER (a watched buffer: any other is ignored) and run its effects."
  (when (and (buffer-live-p buffer) (gethash buffer drgnx-agents-editor--states))
    (let ((r (drgnx-agents-editor--core-step (gethash buffer drgnx-agents-editor--states) event)))
      (puthash buffer (car r) drgnx-agents-editor--states)
      (drgnx-agents-editor--run buffer (cdr r)))))

(defun drgnx-agents-editor-note-change (buffer version)
  "BUFFER's change number VERSION was sent to the hub: a frame made for an older document is dropped from now on."
  (drgnx-agents-editor--feed buffer (list 'buffer-changed version)))

(defun drgnx-agents-editor--shown ()
  "The file buffers a window of any frame shows now."
  (let (out)
    (dolist (w (window-list-1 nil 'never t))
      (let ((b (window-buffer w)))
        (when (and (buffer-file-name b) (not (file-remote-p (buffer-file-name b))))
          (cl-pushnew b out))))
    out))

(defun drgnx-agents-editor--watch (buffer)
  (with-current-buffer buffer
    (unless drgnx-agents-editor--view
      (setq drgnx-agents-editor--view (format "view:%d" (cl-incf drgnx-agents-editor--view-count))))
    (puthash drgnx-agents-editor--view buffer drgnx-agents-editor--views))
  (let ((r (drgnx-agents-editor--core-step nil '(watch))))
    (puthash buffer (car r) drgnx-agents-editor--states)
    (drgnx-agents-editor--run buffer (cdr r))))

(defun drgnx-agents-editor--unwatch (view buffer)
  (remhash view drgnx-agents-editor--views)
  (when buffer (remhash buffer drgnx-agents-editor--states))
  (when (buffer-live-p buffer) (with-current-buffer buffer (setq drgnx-agents-editor--view nil)))
  (drgnx-agents-editor--ask "agents/buffer/unwatch" (list :view view) #'ignore))

(defun drgnx-agents-editor-sync-windows (&optional _frame)
  "Watch the file buffers windows show, unwatch (and forget) those none does."
  (let ((shown (drgnx-agents-editor--shown)) gone)
    (maphash (lambda (view b) (unless (and (buffer-live-p b) (memq b shown)) (push (cons view b) gone)))
             drgnx-agents-editor--views)
    (dolist (g gone) (drgnx-agents-editor--unwatch (car g) (cdr g)))
    (dolist (b shown)
      (unless (gethash b drgnx-agents-editor--states) (drgnx-agents-editor--watch b)))))

(defun drgnx-agents-editor--event (event data)
  "An event from the hub (`drgnx-hub-event-functions'): `agent-buffer' for a view this Emacs watches."
  (when (equal event "agent-buffer")
    (when-let* ((buffer (gethash (plist-get data :view) drgnx-agents-editor--views)))
      (drgnx-agents-editor--feed buffer (if (plist-get data :full) (list 'frame data) (list 'delta data))))))

(defun drgnx-agents-editor--rewatch ()
  "A new connection to the hub: every watched buffer asks for its frame again."
  (maphash (lambda (b _) (drgnx-agents-editor--feed b '(restart))) drgnx-agents-editor--states))

(defun drgnx-agents-editor--present-ordinals ()
  "The ordinals of the agents present in a watched buffer (for `drgnx-agent-identity-watched-function')."
  (let (out)
    (maphash (lambda (_ s)
               (dolist (a (plist-get (drgnx-agents-editor--state-frame s) :agents))
                 (cl-pushnew (plist-get a :ordinal) out)))
             drgnx-agents-editor--states)
    out))

(defun drgnx-agents-editor-probe (buffer frame n)
  "Time N frame applies of FRAME on watched BUFFER through the core and the apply functions: a list of milliseconds."
  (let (ms)
    (dotimes (i n)
      (let ((f (plist-put (copy-sequence frame) :version (+ 1000 i))))
        (push (* 1000 (car (benchmark-run 1 (drgnx-agents-editor--feed buffer (list 'frame f))))) ms)))
    ms))

(defun drgnx-agents-editor--setup ()
  (require 'drgnx-agent-identity)
  (setq drgnx-agent-identity-watched-function #'drgnx-agents-editor--present-ordinals)
  (drgnx-module-hook 'drgnx-hub-event-functions event (event data) (drgnx-agents-editor--event event data))
  (drgnx-module-hook 'drgnx-hub-connected-functions rewatch () (drgnx-agents-editor--rewatch))
  (drgnx-module-hook 'window-buffer-change-functions windows (frame) (drgnx-agents-editor-sync-windows frame))
  (drgnx-module-hook 'window-size-change-functions sizes (frame) (drgnx-agents-editor-sync-windows frame))
  (drgnx-agents-editor-sync-windows))

(defun drgnx-agents-editor--teardown ()
  "Unwatch every buffer, forget every frame and give identity its watched-function back."
  (when (eq drgnx-agent-identity-watched-function #'drgnx-agents-editor--present-ordinals)
    (setq drgnx-agent-identity-watched-function nil))
  (maphash (lambda (view b) (drgnx-agents-editor--unwatch view b)) (copy-hash-table drgnx-agents-editor--views))
  (clrhash drgnx-agents-editor--states)
  (clrhash drgnx-agents-editor--views))

(drgnx-module-define 'tools/agents-in-editor
                     :doc "Agents drawn in the buffer: the editor watches the file buffers it shows and keeps the hub's frames."
                     :stage 'idle :setup #'drgnx-agents-editor--setup :teardown #'drgnx-agents-editor--teardown)

(provide 'drgnx-agents-editor)
;;; drgnx-agents-editor.el ends here
