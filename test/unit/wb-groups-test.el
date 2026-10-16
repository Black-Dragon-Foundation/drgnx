;;; wb-groups-test.el --- batch tests: editor groups -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-groups)

(defmacro drgnx-groups-test--with (dir &rest body)
  "BODY with rules and chrome on, one editor window showing DIR/a.txt."
  (declare (indent 1))
  `(let ((,dir (file-name-as-directory (make-temp-file "drgnx-groups" t)))
         (drgnx-signal--editor-window nil) (display-buffer-alist nil))
     (delete-other-windows)
     (set-window-parameter (selected-window) 'drgnx-tabs nil)
     (set-window-prev-buffers (selected-window) nil)
     (drgnx-rules-mode 1)
     (drgnx-chrome-mode 1)
     (unwind-protect
         (progn (switch-to-buffer (drgnx-groups-test--file ,dir "a.txt")) (drgnx-chrome-apply nil t) ,@body)
       (drgnx-chrome-mode -1)
       (drgnx-rules-mode -1)
       (delete-other-windows)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b))) (kill-buffer b)))
       (delete-directory ,dir t))))

(defun drgnx-groups-test--file (dir name)
  (let ((f (expand-file-name name dir))) (write-region "x\n" nil f nil 'silent) (find-file-noselect f)))

(ert-deftest drgnx-groups/split-makes-a-group-with-the-same-buffer ()
  (drgnx-groups-test--with dir
    (let ((g1 (selected-window)) (a (window-buffer)))
      (drgnx-groups-split-right)
      (let ((g2 (selected-window)))
        (should-not (eq g1 g2))
        (should (eq (window-buffer g2) a))
        (should (equal (drgnx-groups-list) (list g1 g2)))
        (should (equal (drgnx-chrome-tabs g2) (list a)))
        (drgnx-groups-split-down)
        (should (= 3 (length (drgnx-groups-list))))))))

(ert-deftest drgnx-groups/the-last-group-stays ()
  (drgnx-groups-test--with dir
    (should-error (drgnx-groups-close) :type 'user-error)
    (drgnx-groups-split-right)
    (drgnx-groups-close)
    (should (= 1 (length (drgnx-groups-list))))))

(ert-deftest drgnx-groups/focus-by-visual-order ()
  (drgnx-groups-test--with dir
    (let ((g1 (selected-window)))
      (drgnx-groups-split-right)
      (let ((g2 (selected-window)))
        (drgnx-groups-focus-1)
        (should (eq (selected-window) g1))
        (drgnx-groups-focus-2)
        (should (eq (selected-window) g2))
        (drgnx-groups-focus-3)                      ; one past the last: a new group to the right
        (should (= 3 (length (drgnx-groups-list))))))))

(ert-deftest drgnx-groups/move-to-next-moves-the-tab ()
  (drgnx-groups-test--with dir
    (let* ((g1 (selected-window)) (a (window-buffer)) (b (drgnx-groups-test--file dir "b.txt")))
      (switch-to-buffer b) (drgnx-chrome-apply nil t)
      (drgnx-groups-move-to-next)                 ; no next group: one is made
      (let ((g2 (selected-window)))
        (should-not (eq g1 g2))
        (should (eq (window-buffer g2) b))
        (should (equal (drgnx-chrome-tabs g1) (list a)))
        (should (eq (window-buffer g1) a))))))

(ert-deftest drgnx-groups/other-group-place ()
  (drgnx-groups-test--with dir
    (let ((g1 (selected-window)) (c (drgnx-groups-test--file dir "c.txt")))
      (should (eq (drgnx-groups--other-group c nil nil) g1))   ; one group: that one (never a split)
      (drgnx-groups-split-right)
      (let ((g2 (selected-window)))
        (should (eq (drgnx-groups--other-group c nil nil) g1))
        (should (eq (window-buffer g1) c))
        (should (eq (selected-window) g2))))))
