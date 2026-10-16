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
          (when-let* ((b (drgnx-buffers-buffer-at (point))))
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
        (should (eq (drgnx-buffers-buffer-at (window-start w)) (nth 15 bufs)))
        (should (eq (drgnx-buffers-buffer-at (window-point w)) (nth 20 bufs)))))))

(ert-deftest drgnx-buffers/close-kills-exactly-the-rows-buffer ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (with-current-buffer drgnx-buffers-buffer-name
        (let ((x (save-excursion (goto-char (drgnx-buffers--row-pos b)) (search-forward "×" (pos-eol)) (match-beginning 0))))
          (should (drgnx-buffers--close-p x))
          (drgnx-buffers-close-at x)))
      (should (buffer-live-p a))
      (should-not (buffer-live-p b))
      (should (buffer-live-p c)))))

(ert-deftest drgnx-buffers/the-header-is-the-windows ()
  (drgnx-buffers-test--with dir
    (let ((w (drgnx-wb-section-window 'buffers)))
      (with-current-buffer drgnx-buffers-buffer-name (setq header-line-format nil))
      (should (stringp (window-parameter w 'header-line-format))))))

(ert-deftest drgnx-buffers/rendering-allocates-little ()
  ;; 500 rows under 400 KB (a GUI session's full GC takes ~15 ms; a refresh must not cause one).
  (drgnx-buffers-test--with dir
    (dotimes (i 500)
      (let ((f (expand-file-name (format "d%d/f%03d.txt" (/ i 100) i) dir)))
        (make-directory (file-name-directory f) t) (write-region "" nil f nil 'silent) (find-file-noselect f)))
    (drgnx-buffers--refresh)
    (let ((m0 (memory-use-counts)))
      (setq drgnx-buffers--signature nil)
      (drgnx-buffers--refresh)
      (let* ((m1 (memory-use-counts))
             (bytes (+ (* 16 (- (nth 0 m1) (nth 0 m0))) (* 8 (- (nth 2 m1) (nth 2 m0))) (- (nth 4 m1) (nth 4 m0))
                       (* 56 (- (nth 5 m1) (nth 5 m0))))))
        (should (< bytes (* 400 1024)))))))

(ert-deftest drgnx-buffers/a-newline-in-a-name-keeps-rows-in-step ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (with-current-buffer b (rename-buffer "b\nodd"))
      (setq drgnx-buffers--signature nil)
      (drgnx-buffers--refresh)
      (with-current-buffer drgnx-buffers-buffer-name
        (should (= (count-lines (point-min) (point-max)) (length drgnx-buffers--rows)))
        (goto-char (point-min)) (search-forward "c.txt")
        (should (eq (drgnx-buffers-buffer-at (point)) c))
        (ignore a)))))

(ert-deftest drgnx-buffers/the-selection-highlight-survives-a-re-render ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt")))
      (with-current-buffer drgnx-buffers-buffer-name
        (goto-char (drgnx-buffers--row-pos b))
        (hl-line-highlight))
      (with-current-buffer a (insert "x"))           ; ● on a: a re-render
      (drgnx-signal--flush)
      (with-current-buffer drgnx-buffers-buffer-name
        (should (= (overlay-start hl-line-overlay) (drgnx-buffers--row-pos b)))))))

(ert-deftest drgnx-buffers/no-re-render-while-a-button-is-held ()
  (drgnx-buffers-test--with dir
    (drgnx-buffers-test--open dir "a.txt")
    (let ((n drgnx-buffers--renders))
      (setq drgnx-buffers--pressed t)
      (drgnx-buffers-test--open dir "b.txt")
      (should (= n drgnx-buffers--renders))          ; deferred: rows stay under the pointer
      (drgnx-buffers-mouse-ignore nil)               ; the release
      (should (= (1+ n) drgnx-buffers--renders))
      (should (member "b.txt" (drgnx-buffers-test--rows dir))))))

(ert-deftest drgnx-buffers/renames-and-saved-flags-show-up ()
  ;; M3a-2: a rename, or a buffer marked unmodified without saving, is reflected after the next flush.
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")))
      (drgnx-signal--flush)
      (with-current-buffer a (rename-buffer "renamed.txt"))     ; a rename alone
      (drgnx-signal--flush)
      (with-current-buffer drgnx-buffers-buffer-name
        (should (string-search "renamed.txt" (buffer-string))))
      (with-current-buffer a (insert "x"))
      (drgnx-signal--flush)
      (with-current-buffer a (set-buffer-modified-p nil))        ; unmodified without a save
      (drgnx-signal--flush)
      (with-current-buffer drgnx-buffers-buffer-name
        (let ((row (buffer-substring (drgnx-buffers--row-pos a) (save-excursion (goto-char (drgnx-buffers--row-pos a)) (pos-eol)))))
          (should (string-search "renamed.txt" row))
          (should-not (string-search "●" row)))))))

(ert-deftest drgnx-signal/every-command-arms-a-flush ()
  ;; Undo back to the saved state flips the modified flag without any buffer hook.
  (let ((drgnx-signal--timer nil))
    (unwind-protect
        (progn (drgnx-signal-mode 1)
               (cancel-timer drgnx-signal--timer) (setq drgnx-signal--timer nil)   ; enabling arms one itself
               (run-hooks 'post-command-hook)
               (should (timerp drgnx-signal--timer)))
      (when (timerp drgnx-signal--timer) (cancel-timer drgnx-signal--timer)))))
