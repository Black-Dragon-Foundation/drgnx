;;; wb-buffers-test.el --- batch tests: the Buffers panel -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-buffers)

(defmacro drgnx-buffers-test--with (dir &rest body)
  "BODY with a fresh bus, an empty Buffers panel shown in the dock, and a temp DIR for files."
  (declare (indent 1))
  `(let* ((,dir (make-temp-file "drgnx-buffers" t))
          (drgnx-signal--subscribers nil) (drgnx-signal--state nil) (drgnx-signal--editor-window nil)
          (drgnx-wb--sections nil) (drgnx-buffers--order nil) (drgnx-buffers--signature nil)
          (drgnx-buffers--renders 0))
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
       (delete-directory ,dir t))))

(defun drgnx-buffers-test--open (dir name)
  (let ((f (expand-file-name name dir)))
    (make-directory (file-name-directory f) t)
    (write-region "x\n" nil f nil 'silent)
    (prog1 (find-file-noselect f) (drgnx-signal--flush))))

(defun drgnx-buffers-test--rows (dir)
  "Names of the rows for buffers of files under DIR, top to bottom."
  (with-current-buffer drgnx-buffers-buffer-name
    (save-excursion
      (goto-char (point-min))
      (let (rows)
        (while (not (eobp))
          (when-let* ((b (get-text-property (point) 'drgnx-buffer)))
            (when (and (buffer-live-p b) (string-prefix-p dir (or (buffer-file-name b) "")))
              (push (buffer-name b) rows)))
          (forward-line 1))
        (nreverse rows)))))

(ert-deftest drgnx-buffers/rows-keep-their-open-order ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (should (equal (drgnx-buffers-test--rows dir) '("a.txt" "b.txt" "c.txt")))
      ;; Switching (recency) never re-sorts.
      (switch-to-buffer a) (switch-to-buffer c) (switch-to-buffer b)
      (drgnx-signal--flush)
      (should (equal (drgnx-buffers-test--rows dir) '("a.txt" "b.txt" "c.txt")))
      (kill-buffer b)
      (drgnx-signal--flush)
      (should (equal (drgnx-buffers-test--rows dir) '("a.txt" "c.txt"))))))

(ert-deftest drgnx-buffers/renders-only-when-something-changed ()
  (drgnx-buffers-test--with dir
    (drgnx-buffers-test--open dir "a.txt")
    (let ((n drgnx-buffers--renders))
      (drgnx-signal--flush)
      (drgnx-buffers--refresh)
      (should (= n drgnx-buffers--renders))
      (drgnx-buffers-test--open dir "b.txt")
      (should (= (1+ n) drgnx-buffers--renders)))))

(ert-deftest drgnx-buffers/modified-files-show-a-dot ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")))
      (with-current-buffer a (insert "change"))
      (drgnx-signal--flush)
      (with-current-buffer drgnx-buffers-buffer-name
        (goto-char (drgnx-buffers--row-pos a))
        (should (string-search "●" (buffer-substring (pos-bol) (pos-eol))))))))

(ert-deftest drgnx-buffers/view-and-selection-stay-by-identity ()
  (drgnx-buffers-test--with dir
    (let ((bufs (mapcar (lambda (i) (drgnx-buffers-test--open dir (format "f%02d.txt" i))) (number-sequence 0 39)))
          (w (drgnx-wb-section-window 'buffers)))
      (with-current-buffer drgnx-buffers-buffer-name
        (set-window-start w (drgnx-buffers--row-pos (nth 15 bufs)))
        (set-window-point w (drgnx-buffers--row-pos (nth 20 bufs))))
      (drgnx-buffers-test--open dir "zz-new.txt")
      (with-current-buffer drgnx-buffers-buffer-name
        (should (eq (get-text-property (window-start w) 'drgnx-buffer) (nth 15 bufs)))
        (should (eq (get-text-property (window-point w) 'drgnx-buffer) (nth 20 bufs)))))))

(ert-deftest drgnx-buffers/close-kills-exactly-the-rows-buffer ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (with-current-buffer drgnx-buffers-buffer-name
        (let ((x (save-excursion (goto-char (drgnx-buffers--row-pos b)) (search-forward "×" (pos-eol)) (match-beginning 0))))
          (should (get-text-property x 'drgnx-close))
          (drgnx-buffers-close-at x)))
      (should (buffer-live-p a))
      (should-not (buffer-live-p b))
      (should (buffer-live-p c)))))

(ert-deftest drgnx-buffers/the-header-is-the-windows ()
  (drgnx-buffers-test--with dir
    (let ((w (drgnx-wb-section-window 'buffers)))
      (with-current-buffer drgnx-buffers-buffer-name (setq header-line-format nil))
      (should (stringp (window-parameter w 'header-line-format))))))
