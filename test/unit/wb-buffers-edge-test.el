;;; wb-buffers-edge-test.el --- batch tests: the Buffers panel, edge cases -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-buffers)
(require 'drgnx-explorer)
(require 'drgnx-frames)

(defmacro drgnx-buffers-edge--with (dir &rest body)
  "BODY with a fresh bus, an empty Buffers panel shown in the dock, and a temp DIR for files."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let* ((,dir (make-temp-file "drgnx-buffers-edge" t))
            (drgnx-wb--sections nil) (drgnx-buffers--order nil) (drgnx-buffers--signature nil)
            (drgnx-buffers--filter nil) (drgnx-buffers-all-windows nil))
       (unwind-protect
           (progn
             (delete-other-windows)
             (drgnx-buffers-setup)
             (drgnx-signal--flush)
             (drgnx-wb-show-sidebar)
             ,@body)
         (drgnx-wb-hide-sidebar)
         (delete-other-windows)
         (dolist (b (buffer-list))
           (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b)))
             (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
         (when (get-buffer drgnx-buffers-buffer-name) (kill-buffer drgnx-buffers-buffer-name))
         (delete-directory ,dir t)))))

(defun drgnx-buffers-edge--open (dir name)
  (let ((f (expand-file-name name dir)))
    (make-directory (file-name-directory f) t)
    (write-region "x\n" nil f nil 'silent)
    (prog1 (find-file-noselect f) (drgnx-signal--flush))))

(defun drgnx-buffers-edge--header (section)
  (format "%s" (window-parameter (drgnx-wb-section-window section) 'header-line-format)))

(ert-deftest drgnx-buffers/the-filter-title-survives-hide-and-show ()
  (drgnx-buffers-edge--with dir
    (drgnx-buffers-edge--open dir "alpha.txt")
    (drgnx-buffers--filter-apply "alp")
    (should (string-search "alp" (drgnx-buffers-edge--header 'buffers)))
    (drgnx-wb-hide-sidebar)
    (drgnx-wb-show-sidebar)
    (should (string-search "alp" (drgnx-buffers-edge--header 'buffers)))
    (drgnx-buffers--filter-apply nil)
    (drgnx-wb-hide-sidebar)
    (drgnx-wb-show-sidebar)
    (should-not (string-search "alp" (drgnx-buffers-edge--header 'buffers)))
    (should (string-search "save all" (drgnx-buffers-edge--header 'buffers)))))   ; the buttons are back

(ert-deftest drgnx-buffers/the-explorer-find-title-survives-hide-and-show ()
  (drgnx-test-with-state
    (let ((dir (file-name-as-directory (make-temp-file "drgnx-find-edge" t)))
          (drgnx-wb--sections nil) (drgnx-explorer-git nil))
      (unwind-protect
          (progn
            (write-region "x\n" nil (expand-file-name "needle.txt" dir) nil 'silent)
            (delete-other-windows)
            (drgnx-explorer-setup)
            (drgnx-explorer-set-roots (list dir))
            (drgnx-wb-show-sidebar)
            (drgnx-explorer--find-apply "needle")
            (should (string-search "needle" (drgnx-buffers-edge--header 'explorer)))
            (drgnx-wb-hide-sidebar)
            (drgnx-wb-show-sidebar)
            (should (string-search "needle" (drgnx-buffers-edge--header 'explorer))))
        (ignore-errors (drgnx-explorer-find-clear))
        (drgnx-wb-hide-sidebar)
        (drgnx-explorer-set-roots nil)
        (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
        (delete-directory dir t)))))

(defun drgnx-buffers-edge--alive (bufs) (seq-filter #'buffer-live-p bufs))

(ert-deftest drgnx-buffers/close-commands-act-on-the-rows-shown ()
  ;; Close Saved, Close Others and Close All never touch buffers the filter hides.
  (drgnx-buffers-edge--with dir
    (let ((alpha (drgnx-buffers-edge--open dir "alpha.txt")) (alps (drgnx-buffers-edge--open dir "alps.txt"))
          (zzz (drgnx-buffers-edge--open dir "zzz.txt")))
      (drgnx-buffers--filter-apply "alp")
      (with-current-buffer drgnx-buffers-buffer-name
        (goto-char (drgnx-buffers--row-pos alpha))
        (drgnx-buffers-close-others))
      (should (equal (drgnx-buffers-edge--alive (list alpha alps zzz)) (list alpha zzz)))
      (drgnx-buffers-close-saved)
      (should (equal (drgnx-buffers-edge--alive (list alpha zzz)) (list zzz)))
      (let ((other (drgnx-buffers-edge--open dir "alpine.txt")))
        (drgnx-buffers-close-all)
        (should-not (buffer-live-p other))
        (should (buffer-live-p zzz))))))

(ert-deftest drgnx-buffers/a-name-with-two-spaces-is-painted-whole ()
  ;; The name ends where its length says, not at the first two spaces.
  (drgnx-buffers-edge--with dir
    (let ((b (drgnx-buffers-edge--open dir "a  b.txt")))
      (drgnx-buffers--refresh)
      (with-current-buffer drgnx-buffers-buffer-name
        (drgnx-buffers--fontify (point-min) (point-max))
        (let* ((bol (drgnx-buffers--row-pos b)) (b-pos (+ bol 4 3)))     ; the "b" of "a  b.txt"
          (should (equal (buffer-substring-no-properties b-pos (1+ b-pos)) "b"))
          (should (eq (get-text-property b-pos 'mouse-face) 'highlight))
          (should-not (eq (get-text-property b-pos 'face) 'drgnx-buffers-dir))
          (should (eq (get-text-property (+ bol 4 (length "a  b.txt") 2) 'face) 'drgnx-buffers-dir)))))))

(defun drgnx-buffers-edge--fake-files (n)
  "N user buffers (visiting files that need not exist), oldest first."
  (cl-loop for i below n
           collect (with-current-buffer (generate-new-buffer (format "drgnx-edge-%d" i))
                     (setq buffer-file-name (format "/nonexistent/drgnx-edge-%d" i))
                     (current-buffer))))

(defun drgnx-buffers-edge--kill (bufs)
  (dolist (b bufs) (with-current-buffer b (set-buffer-modified-p nil) (setq buffer-file-name nil)) (kill-buffer b)))

(ert-deftest drgnx-buffers/the-order-keeps-old-rows-and-appends-new-ones ()
  (let* ((bufs (drgnx-buffers-edge--fake-files 4)) (a (nth 0 bufs)) (b (nth 1 bufs)) (c (nth 2 bufs)) (d (nth 3 bufs))
         (drgnx-buffers--order (list c a b)))
    (unwind-protect
        (progn
          (kill-buffer b)
          (drgnx-buffers--update-order)
          (should (equal (seq-filter (lambda (x) (memq x bufs)) drgnx-buffers--order) (list c a d))))
      (drgnx-buffers-edge--kill (seq-filter #'buffer-live-p bufs)))))

(ert-deftest drgnx-buffers/this-windows-rows-keep-the-panel-order ()
  (let* ((bufs (drgnx-buffers-edge--fake-files 4)) (drgnx-buffers--order bufs) (drgnx-buffers-all-windows nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-frames-count) (lambda () 2))
                  ((symbol-function 'drgnx-frame-buffers) (lambda (&optional _) (list (nth 3 bufs) (nth 1 bufs)))))
          (should (equal (drgnx-buffers--in-window) (list (nth 1 bufs) (nth 3 bufs)))))
      (drgnx-buffers-edge--kill bufs))))

(defun drgnx-buffers-edge--ms (n)
  "Milliseconds (best of 3) to order N buffers, pick one window's half and work out the main window's."
  (let ((bufs (drgnx-buffers-edge--fake-files n)) (gc-cons-threshold most-positive-fixnum) (best nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-frames-count) (lambda () 2))
                  ((symbol-function 'drgnx-frame-role) (lambda (&optional _) 'main))
                  ((symbol-function 'frame-list) (lambda () (list (selected-frame) 'other)))
                  ((symbol-function 'drgnx-frames--workbench-p) (lambda (_) t))
                  ((symbol-function 'drgnx-frames--tabs)
                   (lambda (f) (if (eq f 'other) (seq-drop bufs (/ n 2)) (seq-take bufs (/ n 3))))))
          (dotimes (_ 3)
            (let ((drgnx-buffers--order (reverse bufs)) (t0 (float-time)))
              (drgnx-buffers--update-order)
              (drgnx-buffers--in-window)
              (setq best (min (or best most-positive-fixnum) (* 1000 (- (float-time) t0)))))))
      (drgnx-buffers-edge--kill bufs))
    best))

(ert-deftest drgnx-buffers/thousands-of-buffers-stay-linear ()
  ;; M3e-7: membership by hash sets.  Four times the buffers must cost about four times as much, not
  ;; sixteen (quadratic `memq' filters: ~10x measured, against ~4x); and 4000 buffers stay fast.
  :tags '(:timing)
  (let* ((small (drgnx-buffers-edge--ms 1000)) (big (drgnx-buffers-edge--ms 4000)))
    (should (< big 100))
    (should (< big (* 7 (max small 0.5))))))

(provide 'wb-buffers-edge-test)
;;; wb-buffers-edge-test.el ends here
