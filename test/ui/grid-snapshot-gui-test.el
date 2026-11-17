;;; grid-snapshot-gui-test.el --- GUI test: the layout snapshot across frames (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; `drgnx-grid-snapshot' records every workbench frame, `drgnx-grid-restore' makes again an aux frame that was closed
;; and deletes one the snapshot lacks, keeping its buffers.  Batch cannot make a second frame, so these rows run in
;; the session; the stack's rows are batch rows (test/unit/grid-snapshot-test.el).  The session's own frames are in
;; every snapshot and left as they are (a restore leaves alone a frame already as the snapshot has it); a row's main
;; frame is one of its own, and the frames a row makes are deleted after.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-grid-snapshot--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-grid-snapshot--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-grid-snapshot--repo))
(require 'drgnx-grid)
(require 'drgnx-groups)
(require 'drgnx-frames)
(require 'drgnx-grid-frames)

(defmacro drgnx-ui-grid-snapshot--with (&rest body)
  "BODY with `drgnx-grid-mode' on, an empty stack and a main frame of its own (the session's main frame is an aux
one meanwhile, left as it is by every restore); the frames BODY made deleted after, the main role, the mode and the
selected frame as they were."
  (declare (indent 0))
  `(progn
     (unless (display-graphic-p) (ert-skip "needs a graphical frame"))
     (let* ((frames (frame-list)) (selected (selected-frame)) (was drgnx-grid-mode)
            (old-main (drgnx-frames--main))
            (drgnx-grid--stack nil))
       (unwind-protect
           (let ((main (make-frame '((width . 100) (height . 30)))))
             (when old-main (set-frame-parameter old-main 'drgnx-frame-role nil))
             (set-frame-parameter main 'drgnx-frame-role 'main)
             (unless was (drgnx-grid-mode 1))
             (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p main)) :secs 10 :what "the main frame mapped")
             (select-frame main)
             ,@body)
         (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
         (unless was (drgnx-grid-mode -1))
         (when (frame-live-p old-main) (set-frame-parameter old-main 'drgnx-frame-role 'main))
         (when (frame-live-p selected) (select-frame selected))))))

(defun drgnx-ui-grid-snapshot--aux ()
  "A new aux frame showing *scratch*, its size settled; the frame selected before selected again."
  (let* ((was (selected-frame)) (f (drgnx-frames--new (get-scratch-buffer-create) nil)))
    (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p f)) :secs 10 :what "the new frame mapped")
    (select-frame was)
    f))

(defun drgnx-ui-grid-snapshot--of (snap frame)
  "FRAME's part of SNAP."
  (seq-find (lambda (s) (eql (plist-get s :id) (drgnx-grid-frame-id frame))) (plist-get snap :frames)))

(ert-deftest drgnx-ui-grid-snapshot/records-every-frame-and-its-monitor ()
  (drgnx-ui-grid-snapshot--with
    (let ((aux (drgnx-ui-grid-snapshot--aux)))
      (with-selected-frame aux (drgnx-groups-split-right))
      (set-frame-parameter aux 'drgnx-monitor '(:name "DP-2" :geometry [1920 0 2560 1440] :workarea [1920 0 2560 1400]))
      (let* ((snap (drgnx-grid-snapshot 'move)) (mine (drgnx-ui-grid-snapshot--of snap aux)))
        (should (eq (plist-get snap :why) 'move))
        (should (numberp (plist-get snap :at)))
        (should (eq (plist-get (car (plist-get snap :frames)) :role) 'main))
        (should (= 1 (seq-count (lambda (s) (eq (plist-get s :role) 'main)) (plist-get snap :frames))))
        (should mine)
        (should (eq (plist-get mine :role) 'aux))
        (should (equal (plist-get mine :monitor) '(:name "DP-2" :geometry (1920 0 2560 1440))))
        (should (equal (plist-get mine :tree) (drgnx-grid-tree aux)))
        (should (= 2 (length (drgnx-grid-tree-leaves (plist-get mine :tree)))))
        (should (cl-every #'integerp (plist-get mine :geometry)))
        (should (= 4 (length (plist-get mine :geometry))))
        (should-not (plist-get mine :full))
        (should (drgnx-grid-valid-snapshot-p snap))
        ;; it reads back: no window, frame or buffer in it
        (should (equal (car (read-from-string (prin1-to-string snap))) snap))))))

(ert-deftest drgnx-ui-grid-snapshot/restore-recreates-a-closed-aux-frame ()
  (drgnx-ui-grid-snapshot--with
    (let* ((aux (drgnx-ui-grid-snapshot--aux)) (id (drgnx-grid-frame-id aux)) snap)
      (with-selected-frame aux (drgnx-groups-split-right))
      (setq snap (drgnx-grid-snapshot 'test))
      (delete-frame aux t)
      (should (drgnx-grid-restore snap))
      (let ((again (drgnx-grid--frame-by-id id)))
        (should (frame-live-p again))
        (should (eq (drgnx-frame-role again) 'aux))
        (should (= 2 (length (drgnx-grid-tiles again 'editor))))
        (should (equal (mapcar (lambda (s) (plist-get s :id)) (plist-get (drgnx-grid-snapshot) :frames))
                       (mapcar (lambda (s) (plist-get s :id)) (plist-get snap :frames))))))))

(ert-deftest drgnx-ui-grid-snapshot/restore-deletes-an-extra-frame-keeping-its-buffers ()
  (drgnx-ui-grid-snapshot--with
    (let* ((snap (drgnx-grid-snapshot 'test))
           (b (get-buffer-create "*g-extra*"))
           (aux (drgnx-ui-grid-snapshot--aux))
           (main (drgnx-frames--main)))
      (unwind-protect
          (progn
            (with-selected-frame aux
              (set-window-buffer (selected-window) b)
              (set-window-parameter (selected-window) 'drgnx-tabs (list b)))
            (with-current-buffer b (insert "unsaved") (set-buffer-modified-p t))
            (should (drgnx-grid-restore snap))
            (should-not (frame-live-p aux))
            (should (buffer-live-p b))
            (should (buffer-modified-p b))
            (should (seq-some (lambda (w) (memq b (window-parameter w 'drgnx-tabs))) (drgnx-grid-tiles main 'editor))))
        (dolist (w (drgnx-grid-tiles main 'editor))
          (set-window-parameter w 'drgnx-tabs (delq b (window-parameter w 'drgnx-tabs))))
        (when (buffer-live-p b) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))))))

(provide 'grid-snapshot-gui-test)
;;; grid-snapshot-gui-test.el ends here
