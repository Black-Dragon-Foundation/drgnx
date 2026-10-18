;;; wb-chrome-edge-test.el --- batch tests: chrome edge cases (killed buffers) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-chrome)

(defmacro drgnx-chrome-edge-test--with (dir &rest body)
  "BODY with chrome on, one editor window, a temp DIR for files."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let ((,dir (file-name-as-directory (make-temp-file "drgnx-chrome-edge" t)))
           (display-buffer-alist nil))
       (delete-other-windows)
       (set-window-parameter (selected-window) 'drgnx-tabs nil)
       (set-window-prev-buffers (selected-window) nil)
       (drgnx-rules-mode 1)
       (drgnx-chrome-mode 1)
       (unwind-protect (progn ,@body)
         (drgnx-chrome-mode -1)
         (drgnx-rules-mode -1)
         (delete-other-windows)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
         (delete-directory ,dir t)))))

(defun drgnx-chrome-edge-test--open (dir name)
  "Visit DIR/NAME in the selected window; return the buffer."
  (let ((f (expand-file-name name dir)))
    (write-region "x\n" nil f nil 'silent)
    (switch-to-buffer (find-file-noselect f))
    (drgnx-chrome-apply nil t)
    (current-buffer)))

(ert-deftest drgnx-chrome-edge/killing-the-shown-buffer-shows-its-neighbour-tab ()
  "M3d-2: after a restore a window has no previous buffers; killing the shown file shows the
tab to its right, not whatever buffer Emacs picks."
  (drgnx-chrome-edge-test--with dir
    (let* ((a (drgnx-chrome-edge-test--open dir "a.txt")) (b (drgnx-chrome-edge-test--open dir "b.txt"))
           (c (drgnx-chrome-edge-test--open dir "c.txt")) (w (selected-window)))
      (switch-to-buffer a)                            ; the most recent other buffer is a, the neighbour c
      (switch-to-buffer b)
      (drgnx-chrome-apply nil t)
      (set-window-prev-buffers w nil)                 ; as after a restore
      (kill-buffer b)
      (should (eq (window-buffer w) c))
      (should (equal (window-parameter w 'drgnx-tabs) (list a c))))))

(ert-deftest drgnx-chrome-edge/killing-the-last-tab-shows-its-left-neighbour-in-every-window ()
  (drgnx-chrome-edge-test--with dir
    (let* ((a (drgnx-chrome-edge-test--open dir "a.txt")) (b (drgnx-chrome-edge-test--open dir "b.txt"))
           (w1 (selected-window)) (w2 (split-window w1 nil 'right)))
      (with-selected-window w2
        (switch-to-buffer a) (drgnx-chrome-apply nil t) (switch-to-buffer b) (drgnx-chrome-apply nil t))
      (dolist (w (list w1 w2)) (set-window-prev-buffers w nil))
      (kill-buffer b)
      (dolist (w (list w1 w2))
        (should (eq (window-buffer w) a))
        (should (equal (window-parameter w 'drgnx-tabs) (list a)))))))

(ert-deftest drgnx-chrome-edge/a-killed-tab-leaves-the-tab-line-at-once ()
  "M4-10: a killed buffer that is not a file (no bus edge follows) leaves the tabs and the tab line."
  (drgnx-chrome-edge-test--with dir
    (let ((a (drgnx-chrome-edge-test--open dir "a.txt")) (n (get-buffer-create "*drgnx-edge-note*"))
          (w (selected-window)))
      (switch-to-buffer n)
      (drgnx-chrome-apply nil t)
      (switch-to-buffer a)
      (drgnx-chrome-apply nil t)
      (should (memq n (window-parameter w 'drgnx-tabs)))
      (kill-buffer n)
      (should (equal (window-parameter w 'drgnx-tabs) (list a)))
      (should-not (string-search "drgnx-edge-note" (format "%s" (window-parameter w 'tab-line-format)))))))

(ert-deftest drgnx-chrome-edge/killing-a-buffer-with-chrome-off-changes-nothing ()
  (drgnx-chrome-edge-test--with dir
    (let ((a (drgnx-chrome-edge-test--open dir "a.txt")) (b (drgnx-chrome-edge-test--open dir "b.txt")))
      (ignore a)
      (drgnx-chrome-mode -1)
      (should-not (memq #'drgnx-chrome--killed kill-buffer-hook))
      (kill-buffer b))))

;;; wb-chrome-edge-test.el ends here
