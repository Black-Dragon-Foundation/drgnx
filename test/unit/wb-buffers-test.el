;;; wb-buffers-test.el --- batch tests: the Buffers panel -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'bytecomp)                                  ; `byte-compile-warnings' is let-bound below
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-buffers)

(defmacro drgnx-buffers-test--with (dir &rest body)
  "BODY with a fresh bus, an empty Buffers panel shown in the dock, and a temp DIR for files."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let* ((,dir (make-temp-file "drgnx-buffers" t))
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
         (delete-directory ,dir t)))))

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
      ;; the dot takes the close button's place at the right edge, always shown
      (let* ((tail (drgnx-buffers-test--tail a)) (i (string-search (drgnx-face-glyph 'dot) tail)))
        (should i)
        (should (get-text-property i 'drgnx-row-control tail))
        (should (memq 'drgnx-buffers-modified (ensure-list (get-text-property i 'face tail))))
        (should-not (string-search (drgnx-face-glyph 'close) tail))))))

(defun drgnx-buffers-test--tail (b)
  "The string at the right edge of buffer B's row, painted."
  (with-current-buffer drgnx-buffers-buffer-name
    (drgnx-buffers--fontify (point-min) (point-max))
    (let ((row (drgnx-buffers--row-pos b)))
      (seq-some (lambda (o) (and (overlay-get o 'drgnx-row-tail) (overlay-get o 'after-string)))
                (overlays-in row (1+ (save-excursion (goto-char row) (pos-eol))))))))

(ert-deftest drgnx-buffers/a-row-is-the-icon-and-the-name ()
  ;; window-dark.html's Open rows: the file's icon and name; no folder, no close column at the start; the close
  ;; button is the control at the right edge, hidden until the row is hovered (a terminal always shows it)
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "sub/a.el")))     ; no x in it: an ASCII terminal's close glyph is x
      (with-current-buffer drgnx-buffers-buffer-name
        (let* ((row (drgnx-buffers--row-pos a))
               (text (buffer-substring-no-properties row (save-excursion (goto-char row) (pos-eol)))))
          (should (equal "a.el" (string-trim text)))
          (should-not (string-search "sub" text))
          (should-not (string-search (drgnx-face-glyph 'close) text))))
      (let* ((tail (drgnx-buffers-test--tail a)) (i (string-search (drgnx-face-glyph 'close) tail)))
        (should i)
        (should (get-text-property i 'drgnx-row-control tail))))))

(ert-deftest drgnx-buffers/a-click-on-the-control-closes-the-row ()
  ;; a click on the right edge's × closes that row's buffer; a click elsewhere on the row opens it
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt")))
      (let* ((tail (drgnx-buffers-test--tail b)) (i (string-search (drgnx-face-glyph 'close) tail))
             (w (drgnx-wb-section-window 'buffers))
             (eol (with-current-buffer drgnx-buffers-buffer-name
                    (save-excursion (goto-char (drgnx-buffers--row-pos b)) (pos-eol))))
             (posn (list w eol '(0 . 0) 0 (cons tail i) eol)))
        (should (drgnx-buffers--on-control-p posn))
        (drgnx-buffers-mouse-click (list 'mouse-1 posn posn)))
      (should (buffer-live-p a))
      (should-not (buffer-live-p b)))))

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

(ert-deftest drgnx-buffers/a-render-keeps-each-window-on-its-buffer ()
  ;; Two windows on the panel and its own point: rows closing above them keep each start and point on its buffer, at
  ;; the same place in the row; a window whose first row closed falls to the row now in its place, not to the top.
  (drgnx-buffers-test--with dir
    (let* ((bufs (mapcar (lambda (i) (drgnx-buffers-test--open dir (format "f%02d.txt" i))) (number-sequence 0 39)))
           (w1 (drgnx-wb-section-window 'buffers)) (w2 (split-window (drgnx-wb-editor-window)))
           (pos (lambda (i) (drgnx-buffers--row-pos (nth i bufs)))))
      (select-window (drgnx-wb-editor-window))
      (set-window-buffer w2 drgnx-buffers-buffer-name)
      (with-current-buffer drgnx-buffers-buffer-name
        (set-window-start w1 (funcall pos 15))
        (set-window-point w1 (+ (funcall pos 20) 4))
        (set-window-start w2 (funcall pos 5))
        (set-window-point w2 (+ (funcall pos 8) 2))
        (goto-char (1+ (funcall pos 30))))
      (kill-buffer (nth 12 bufs))                       ; between the two windows' rows
      (kill-buffer (nth 5 bufs))                        ; the second window's first row
      (drgnx-signal--flush)
      (with-current-buffer drgnx-buffers-buffer-name
        (should-not (drgnx-buffers--row-pos (nth 5 bufs)))
        (should (= (window-start w1) (funcall pos 15)))
        (should (= (window-point w1) (+ (funcall pos 20) 4)))
        (should (= (window-start w2) (funcall pos 6)))
        (should (= (window-point w2) (+ (funcall pos 8) 2)))
        (should (= (point) (1+ (funcall pos 30))))))))

(ert-deftest drgnx-buffers/close-kills-exactly-the-rows-buffer ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (with-current-buffer drgnx-buffers-buffer-name
        (drgnx-buffers-close-at (drgnx-buffers--row-pos b)))
      (should (buffer-live-p a))
      (should-not (buffer-live-p b))
      (should (buffer-live-p c)))))

(ert-deftest drgnx-buffers/the-header-is-the-windows ()
  (drgnx-buffers-test--with dir
    (let ((w (drgnx-wb-section-window 'buffers)))
      (with-current-buffer drgnx-buffers-buffer-name (setq header-line-format nil))
      (should (stringp (window-parameter w 'header-line-format))))))

(defun drgnx-buffers-test--compile ()
  "Byte-compile drgnx's functions in place, as an install runs them: the tests load source, and an interpreted call
conses (a refresh of 500 rows made 20,000 conses interpreted, 4,000 compiled)."
  (mapatoms (lambda (s)
              (when (and (fboundp s) (string-prefix-p "drgnx-" (symbol-name s))
                         (not (string-prefix-p "drgnx-buffers-test" (symbol-name s)))
                         (functionp (symbol-function s)) (not (compiled-function-p (symbol-function s))))
                (let ((byte-compile-warnings nil)) (byte-compile s))))))

(defun drgnx-buffers-test--bytes (fn)
  "The bytes calling FN allocates (conses, vector cells, string characters, intervals): the least of three warm runs."
  (funcall fn)
  (let (best)
    (dotimes (_ 3)
      (let* ((m0 (memory-use-counts)) (_ (funcall fn)) (m1 (memory-use-counts))
             (bytes (+ (* 16 (- (nth 0 m1) (nth 0 m0))) (* 8 (- (nth 2 m1) (nth 2 m0))) (- (nth 4 m1) (nth 4 m0))
                       (* 56 (- (nth 5 m1) (nth 5 m0))))))
        (setq best (if best (min best bytes) bytes))))
    best))

(ert-deftest drgnx-buffers/rendering-allocates-little ()
  ;; 500 rows under 400 KB (a GUI session's full GC takes ~15 ms; a refresh must not cause one), compiled as an
  ;; install runs it: the 437 KB once measured here were the interpreter's conses.
  (drgnx-buffers-test--with dir
    (dotimes (i 500)
      (let ((f (expand-file-name (format "d%d/f%03d.txt" (/ i 100) i) dir)))
        (make-directory (file-name-directory f) t) (write-region "" nil f nil 'silent) (find-file-noselect f)))
    (drgnx-buffers--refresh)
    (should (<= 500 (with-current-buffer drgnx-buffers-buffer-name (length drgnx-buffers--rows))))
    (drgnx-buffers-test--compile)
    (let ((byte-compile-warnings nil))
      (should (< (drgnx-buffers-test--bytes
                  (byte-compile (lambda () (setq drgnx-buffers--signature nil) (drgnx-buffers--refresh))))
                 (* 400 1024))))))

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
        (drgnx-wb-selection-sync))
      (with-current-buffer a (insert "x"))           ; ● on a: a re-render
      (drgnx-signal--flush)
      (with-current-buffer drgnx-buffers-buffer-name
        (should (= (overlay-start drgnx-wb--selected-overlay) (drgnx-buffers--row-pos b)))))))

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
  (unwind-protect
      (progn (drgnx-signal-mode 1)
             (drgnx-timer-cancel 'signal-flush)                    ; enabling arms one itself
             (run-hooks 'post-command-hook)
             (should (drgnx-timer-active-p 'signal-flush)))
    (drgnx-timer-cancel 'signal-flush)))

;;;; Actions (M3b)

(ert-deftest drgnx-buffers/save-all-and-close-saved ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (with-current-buffer a (insert "A"))
      (with-current-buffer b (insert "B"))
      (drgnx-buffers-close-saved)                    ; c only: a and b have unsaved changes
      (should-not (buffer-live-p c))
      (should (and (buffer-live-p a) (buffer-live-p b)))
      (drgnx-buffers-save-all)
      (should-not (buffer-modified-p a))
      (should (string-prefix-p "A" (with-temp-buffer (insert-file-contents (expand-file-name "a.txt" dir)) (buffer-string)))))))

(ert-deftest drgnx-buffers/close-others-and-close-all ()
  (drgnx-buffers-test--with dir
    (let ((a (drgnx-buffers-test--open dir "a.txt")) (b (drgnx-buffers-test--open dir "b.txt"))
          (c (drgnx-buffers-test--open dir "c.txt")))
      (with-current-buffer drgnx-buffers-buffer-name
        (goto-char (drgnx-buffers--row-pos b))
        (drgnx-buffers-close-others))
      (should (buffer-live-p b))
      (should-not (or (buffer-live-p a) (buffer-live-p c)))
      (drgnx-buffers-close-all)
      (should-not (buffer-live-p b)))))

(ert-deftest drgnx-buffers/filter-by-name ()
  (drgnx-buffers-test--with dir
    (drgnx-buffers-test--open dir "alpha.txt")
    (drgnx-buffers-test--open dir "beta.txt")
    (drgnx-buffers-test--open dir "alphabet.md")
    (drgnx-buffers--filter-apply "ALPHA")
    (should (equal (drgnx-buffers-test--rows dir) '("alpha.txt" "alphabet.md")))
    (drgnx-buffers-test--open dir "gamma.txt")       ; a new buffer while filtered: still filtered
    (should (equal (drgnx-buffers-test--rows dir) '("alpha.txt" "alphabet.md")))
    (drgnx-buffers-filter-clear)
    (should (equal (drgnx-buffers-test--rows dir) '("alpha.txt" "beta.txt" "alphabet.md" "gamma.txt")))))

(ert-deftest drgnx-buffers/one-shown-per-render ()
  "A render that draws the rows works out the shown buffers once, not once for the signature and twice for the rows."
  (drgnx-buffers-test--with dir
    (drgnx-buffers-test--open dir "a.txt")
    (let ((calls 0) (orig (symbol-function 'drgnx-buffers--shown)))
      (cl-letf (((symbol-function 'drgnx-buffers--shown) (lambda () (cl-incf calls) (funcall orig))))
        (drgnx-buffers-test--open dir "b.txt")
        (setq calls 0)
        (setq drgnx-buffers--signature nil)
        (drgnx-buffers--render)
        (should (= calls 1))))))
