;;; wb-chrome-mru-test.el --- batch tests: closing a tab returns to the previously used tab -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-chrome)

(defmacro drgnx-chrome-test--with (dir &rest body)
  "BODY with chrome on, one editor window, a temp DIR for files."
  (declare (indent 1))
  `(let ((,dir (file-name-as-directory (make-temp-file "drgnx-chrome" t)))
         (drgnx-signal--editor-window nil) (display-buffer-alist nil)
         (drgnx-chrome-closed-positions nil))
     (delete-other-windows)
     (set-window-parameter (selected-window) 'drgnx-tabs nil)
     (set-window-parameter (selected-window) 'drgnx-tab-history nil)
     (set-window-prev-buffers (selected-window) nil)
     (drgnx-rules-mode 1)
     (drgnx-chrome-mode 1)
     (unwind-protect (progn ,@body)
       (drgnx-chrome-mode -1)
       (drgnx-rules-mode -1)
       (drgnx-wb-area-hide 'panel)
       (delete-other-windows)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p ,dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
       (delete-directory ,dir t))))

(defun drgnx-chrome-test--open (dir name)
  "Visit DIR/NAME in the selected window (as C-x C-f does); return the buffer."
  (let ((f (expand-file-name name dir)))
    (make-directory (file-name-directory f) t)
    (write-region "x\n" nil f nil 'silent)
    (switch-to-buffer (find-file-noselect f))
    (drgnx-chrome-apply nil t)
    (current-buffer)))

(defun drgnx-chrome-test--show (b)
  "Show B in the selected window, as the user switching to its tab does."
  (switch-to-buffer b)
  (drgnx-chrome-apply nil t))

(ert-deftest drgnx-chrome/close-returns-to-the-previous-tab ()
  (drgnx-chrome-test--with dir
    (let ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
          (c (drgnx-chrome-test--open dir "c.txt")))
      (drgnx-chrome-test--show a)
      (drgnx-chrome-test--show c)                          ; used: c, a, b (most recent first)
      (drgnx-chrome-close-tab)
      (should (eq (window-buffer) a))                      ; not the neighbour b
      (should (equal (drgnx-chrome-tabs (selected-window)) (list a b)))
      (drgnx-chrome-close-tab)
      (should (eq (window-buffer) b))
      (drgnx-chrome-close-tab)                             ; the last tab: *scratch*
      (should (equal (buffer-name (window-buffer)) "*scratch*")))))

(ert-deftest drgnx-chrome/close-returns-the-neighbour-without-history ()
  ;; no history (a restored layout): the old rule, the tab to the right, else the left
  (drgnx-chrome-test--with dir
    (let ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
          (c (drgnx-chrome-test--open dir "c.txt")))
      (set-window-parameter (selected-window) 'drgnx-tab-history nil)
      (drgnx-chrome--close (selected-window) b)            ; b is not shown: nothing changes
      (should (eq (window-buffer) c))
      (set-window-parameter (selected-window) 'drgnx-tab-history nil)
      (drgnx-chrome--close (selected-window) c)
      (should (eq (window-buffer) a)))))                   ; no right neighbour: the left

(ert-deftest drgnx-chrome/close-returns-the-position-capped ()
  (drgnx-chrome-test--with dir
    (let ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
          (c (drgnx-chrome-test--open dir "c.txt")))
      (drgnx-chrome--close (selected-window) b)
      (should (equal (cdr (assoc (buffer-file-name b) drgnx-chrome-closed-positions)) '(0 1)))
      (drgnx-chrome--close (selected-window) a)            ; most recent first, one entry per file
      (should (equal (mapcar #'car drgnx-chrome-closed-positions)
                     (list (buffer-file-name a) (buffer-file-name b))))
      (let ((drgnx-chrome-closed-positions (mapcar (lambda (i) (list (format "/f%d" i) 0 0)) (number-sequence 1 40))))
        (drgnx-chrome--record-closed-position (selected-window) c)
        (should (= (length drgnx-chrome-closed-positions) 30))
        (should (equal (caar drgnx-chrome-closed-positions) (buffer-file-name c)))))))

(ert-deftest drgnx-chrome/killed-buffer-too ()
  (drgnx-chrome-test--with dir
    (let ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
          (c (drgnx-chrome-test--open dir "c.txt")))
      (drgnx-chrome-test--show a)
      (drgnx-chrome-test--show c)
      (kill-buffer c)
      (should (eq (window-buffer) a))                      ; the previously used, not b
      (should (equal (drgnx-chrome-tabs (selected-window)) (list a b)))
      (should (equal (cdr (assoc (buffer-file-name c) drgnx-chrome-closed-positions)) '(0 2))))))

(ert-deftest drgnx-chrome/history-is-per-group ()
  (drgnx-chrome-test--with dir
    (let* ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
           (c (drgnx-chrome-test--open dir "c.txt"))
           (w1 (selected-window)) (w2 (split-window w1 nil 'right)))
      (set-window-parameter w2 'drgnx-tabs (list a b c))
      (with-selected-window w2
        (drgnx-chrome-test--show b)
        (drgnx-chrome-test--show a))                       ; w2 used: a, b
      (should (equal (window-parameter w1 'drgnx-tab-history) (list c b a)))
      (should (equal (seq-take (window-parameter w2 'drgnx-tab-history) 2) (list a b)))
      (drgnx-chrome--close w2 a)
      (should (eq (window-buffer w2) b))                   ; w2's history, not w1's (c)
      (should (eq (window-buffer w1) c)))))

(ert-deftest drgnx-chrome/history-is-live-buffers-only ()
  (drgnx-chrome-test--with dir
    (let ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
          (c (drgnx-chrome-test--open dir "c.txt")))
      (with-current-buffer b (set-buffer-modified-p nil))
      (kill-buffer b)
      (drgnx-chrome-apply nil t)
      (should (equal (window-parameter (selected-window) 'drgnx-tab-history) (list c a)))
      (drgnx-chrome-test--show a)
      (should (equal (window-parameter (selected-window) 'drgnx-tab-history) (list a c))))))
