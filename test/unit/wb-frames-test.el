;;; wb-frames-test.el --- batch tests: frame roles, saving every window, the bus's frame edges -*- lexical-binding: t -*-
;; Batch Emacs has one frame: frame lists are mocked here; real frames are tested live.
(require 'ert)
(require 'drgnx-frames)
(require 'drgnx-persist)

(defmacro drgnx-frames-test--fake (frames &rest body)
  "BODY with `frame-list' answering FRAMES (newest first, as Emacs does) and every frame graphical,
visible, without parent."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'frame-list) (lambda () ,frames))
             ((symbol-function 'frame-live-p) (lambda (f) (memq f ,frames)))
             ((symbol-function 'display-graphic-p) (lambda (&optional _) t))
             ((symbol-function 'frame-visible-p) (lambda (_) t))
             ((symbol-function 'frame-parent) (lambda (&optional _) nil)))
     ,@body))

(ert-deftest drgnx-frames/main-is-the-selected-or-oldest-frame-never-a-child ()
  ;; C1: `frame-list' is newest first; a child frame (posframe) is never main.
  (let* ((old (selected-frame)) (params (make-hash-table)))
    (cl-letf (((symbol-function 'frame-parameter) (lambda (f p) (and (eq p 'drgnx-frame-role) (gethash f params))))
              ((symbol-function 'set-frame-parameter) (lambda (f p v) (when (eq p 'drgnx-frame-role) (puthash f v params)))))
      (drgnx-frames-test--fake (list 'newest 'child old)
        (cl-letf (((symbol-function 'frame-parent) (lambda (&optional f) (and (eq f 'child) old)))
                  ((symbol-function 'selected-frame) (lambda () 'child)))
          (drgnx-frames-mark-main)
          (should (eq (gethash old params) 'main))     ; not the child, not the newest
          (should-not (gethash 'newest params)))))))

(ert-deftest drgnx-frames/the-restored-home-window-is-main ()
  ;; C1: restoring puts the main layout in the selected frame and makes it the main window.
  (let* ((dir (make-temp-file "drgnx-frames" t)) (drgnx-persist-file (expand-file-name "s.eld" dir)))
    (unwind-protect
        (progn
          (set-frame-parameter nil 'drgnx-frame-role nil)
          (with-temp-file drgnx-persist-file
            (prin1 '(:version 2 :frames ((:role main :left (:shown nil) :panel (:shown nil) :right (:shown nil)
                                                :main nil :groups nil)))
                   (current-buffer)))
          (drgnx-persist-restore)
          (should (eq (frame-parameter nil 'drgnx-frame-role) 'main)))
      (delete-directory dir t))))

(ert-deftest drgnx-frames/invisible-frames-are-not-windows ()
  ;; A daemon's hidden frames are not windows of the workbench (Buffers panel scope, saving).
  (cl-letf (((symbol-function 'frame-visible-p) (lambda (_) nil)))
    (should-not (drgnx-frames--workbench-p (selected-frame)))))

(ert-deftest drgnx-frames/a-closing-client-saves-every-window ()
  ;; I1: `server-delete-client' deletes a daemon client's frames one by one; save them all first.
  (let* ((dir (make-temp-file "drgnx-frames" t)) (drgnx-persist-file (expand-file-name "s.eld" dir))
         (drgnx-persist--saved-at-exit nil))
    (unwind-protect
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
          (set-frame-parameter nil 'client 'kx-proc)
          (drgnx-persist--before-client-delete 'kx-proc)
          (should (file-exists-p drgnx-persist-file))
          (should drgnx-persist--saved-at-exit)
          (delete-file drgnx-persist-file)
          (drgnx-persist--on-delete-frame (selected-frame))     ; the frames go: no second, partial save
          (should-not (file-exists-p drgnx-persist-file)))
      (set-frame-parameter nil 'client nil)
      (delete-directory dir t))))

(ert-deftest drgnx-frames/the-bus-tells-when-the-window-or-tabs-change ()
  ;; I2: switching to another frame, or a tab set changing, re-renders frame-scoped lists.
  (let ((drgnx-signal--subscribers nil) (drgnx-signal--state nil) (seen nil))
    (drgnx-signal-subscribe 'frame-changed (lambda (_) (push 'frame seen)))
    (drgnx-signal-subscribe 'tabs-changed (lambda (_) (push 'tabs seen)))
    (drgnx-signal--flush)
    (setq seen nil)
    (cl-letf (((symbol-function 'drgnx-signal--frame) (lambda () 'another)))
      (drgnx-signal--flush))
    (should (memq 'frame seen))
    (drgnx-signal-post 'tabs-changed)
    (drgnx-signal--flush)
    (should (memq 'tabs seen))))
