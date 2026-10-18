;;; wb-groups-edge-test.el --- batch tests: editor groups, emptied groups -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-groups)
(require 'drgnx-keys)

(defmacro drgnx-groups-edge-test--with (dir &rest body)
  "BODY with rules and chrome on, one editor window showing DIR/a.txt."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let ((,dir (file-name-as-directory (make-temp-file "drgnx-groups-edge" t)))
           (display-buffer-alist nil))
       (delete-other-windows)
       (set-window-parameter (selected-window) 'drgnx-tabs nil)
       (set-window-prev-buffers (selected-window) nil)
       (drgnx-rules-mode 1)
       (drgnx-chrome-mode 1)
       (unwind-protect
           (progn (switch-to-buffer (drgnx-groups-edge-test--file ,dir "a.txt")) (drgnx-chrome-apply nil t) ,@body)
         (drgnx-chrome-mode -1)
         (drgnx-rules-mode -1)
         (delete-other-windows)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b))) (kill-buffer b)))
         (delete-directory ,dir t)))))

(defun drgnx-groups-edge-test--file (dir name)
  (let ((f (expand-file-name name dir))) (write-region "x\n" nil f nil 'silent) (find-file-noselect f)))

(ert-deftest drgnx-groups-edge/moving-the-last-tab-closes-the-emptied-group ()
  "M3d-5: Move Editor into Next Group closes the group it emptied (VS Code), not show *scratch*."
  (drgnx-groups-edge-test--with dir
    (let ((g1 (selected-window)) (a (window-buffer)))
      (drgnx-groups-split-right)
      (let ((g2 (selected-window)))
        (drgnx-groups-focus-1)
        (drgnx-groups-move-to-next)
        (should-not (window-live-p g1))
        (should (equal (drgnx-groups-list) (list g2)))
        (should (eq (selected-window) g2))
        (should (eq (window-buffer g2) a))))))

(ert-deftest drgnx-groups-edge/moving-the-only-tab-of-the-only-group-leaves-one-group ()
  (drgnx-groups-edge-test--with dir
    (let ((a (window-buffer)))
      (drgnx-groups-move-to-next)
      (should (= 1 (length (drgnx-groups-list))))
      (should (eq (window-buffer (car (drgnx-groups-list))) a))
      (should (equal (drgnx-chrome-tabs (selected-window)) (list a))))))

(ert-deftest drgnx-groups-edge/close-all-editors-in-a-group ()
  "C-k w (VS Code): every tab of the group goes (the files stay open); the group closes unless it is
the last, which then shows *scratch* with no tabs."
  (drgnx-groups-edge-test--with dir
    (let* ((g1 (selected-window)) (a (window-buffer)) (b (drgnx-groups-edge-test--file dir "b.txt")))
      (switch-to-buffer b) (drgnx-chrome-apply nil t)
      (drgnx-groups-split-right)
      (drgnx-groups-close-all-editors)
      (should (equal (drgnx-groups-list) (list g1)))
      (should (eq (selected-window) g1))
      (drgnx-groups-close-all-editors)
      (should (equal (drgnx-groups-list) (list g1)))
      (should (equal (buffer-name (window-buffer g1)) "*scratch*"))
      (should (equal (seq-remove (lambda (x) (equal (buffer-name x) "*scratch*")) (drgnx-chrome-tabs g1)) nil))
      (should (and (buffer-live-p a) (buffer-live-p b))))))

(ert-deftest drgnx-groups-edge/c-k-w-closes-the-editors-of-the-group-in-vscode ()
  (let* ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))
         (vscode (plist-get (alist-get 'vscode profiles) :bind)))
    (should (equal (cdr (assq 'close-group-editors vscode)) '("C-k w")))
    (should (eq (cadr (assq 'close-group vscode)) :none))))

;;; wb-groups-edge-test.el ends here
