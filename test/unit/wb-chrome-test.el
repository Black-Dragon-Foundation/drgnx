;;; wb-chrome-test.el --- batch tests: chrome by role, tabs, breadcrumbs (I3) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-chrome)

(defmacro drgnx-chrome-test--with (dir &rest body)
  "BODY with chrome on, one editor window, a temp DIR for files."
  (declare (indent 1))
  `(let ((,dir (file-name-as-directory (make-temp-file "drgnx-chrome" t)))
         (drgnx-signal--editor-window nil) (display-buffer-alist nil))
     (delete-other-windows)
     (set-window-parameter (selected-window) 'drgnx-tabs nil)
     (set-window-parameter (selected-window) 'drgnx-closed nil)
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
    (drgnx-chrome-apply)
    (current-buffer)))

(defun drgnx-chrome-test--heights (w)
  (list (window-tab-line-height w) (window-header-line-height w) (window-mode-line-height w)))

(ert-deftest drgnx-chrome/roles-decide-the-chrome ()
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (let ((editor (selected-window)) (panel (drgnx-wb-area-show 'panel 'output)))
      (drgnx-chrome-apply)
      (should (seq-every-p #'cl-plusp (drgnx-chrome-test--heights editor)))      ; tab line, header, mode line
      (should (equal (mapcar #'cl-plusp (drgnx-chrome-test--heights panel)) '(nil t nil))))))  ; tab row only

(ert-deftest drgnx-chrome/a-mode-cannot-change-the-height ()
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (let ((before (drgnx-chrome-test--heights (selected-window))))
      (switch-to-buffer (get-buffer-create "*drgnx-odd*"))
      (setq-local header-line-format nil tab-line-format nil mode-line-format nil)
      (drgnx-chrome-apply)
      (should (equal before (drgnx-chrome-test--heights (selected-window))))
      (kill-buffer "*drgnx-odd*"))))

(ert-deftest drgnx-chrome/tabs-keep-open-order ()
  (drgnx-chrome-test--with dir
    (let ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
          (c (drgnx-chrome-test--open dir "c.txt")))
      (switch-to-buffer a)
      (drgnx-chrome-apply)
      (should (equal (drgnx-chrome-tabs (selected-window)) (list a b c))))))

(ert-deftest drgnx-chrome/killing-a-buffer-drops-its-tab-everywhere ()
  (drgnx-chrome-test--with dir
    (let* ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
           (w1 (selected-window)) (w2 (split-window w1 nil 'right)))
      (with-selected-window w2 (switch-to-buffer a) (switch-to-buffer b) (drgnx-chrome-apply))
      (kill-buffer b)
      (should (equal (drgnx-chrome-tabs w1) (list a)))
      (should (equal (drgnx-chrome-tabs w2) (list a)))
      (should (eq (window-buffer w1) a)))))

(ert-deftest drgnx-chrome/closing-the-shown-tab-shows-its-neighbour ()
  (drgnx-chrome-test--with dir
    (let ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
          (c (drgnx-chrome-test--open dir "c.txt")))
      (switch-to-buffer b)
      (drgnx-chrome-close-tab)
      (should (eq (window-buffer) c))                      ; the tab to its right
      (should (equal (drgnx-chrome-tabs (selected-window)) (list a c)))
      (should (buffer-live-p b))                           ; closing a tab is not killing the buffer
      (drgnx-chrome-next-tab)
      (should (eq (window-buffer) a)))))                   ; wraps around

(ert-deftest drgnx-chrome/breadcrumb-shows-the-path ()
  (drgnx-chrome-test--with dir
    (make-directory (expand-file-name ".git" dir))
    (drgnx-chrome-test--open dir "src/app/main.py")
    (let ((crumb (substring-no-properties (drgnx-chrome-breadcrumb (selected-window)))))
      (should (string-match-p "src › app › main\\.py" crumb))
      (insert "y")
      (should (string-match-p "●" (drgnx-chrome-breadcrumb (selected-window)))))))

(ert-deftest drgnx-chrome/buffers-shown-within-one-command-are-tabs ()
  ;; A command that visits two files in a row: both are tabs (the window was drawn once).
  (drgnx-chrome-test--with dir
    (let ((a (drgnx-chrome-test--open dir "a.txt")))
      (let ((f1 (find-file-noselect (expand-file-name "b.txt" dir))) (f2 (find-file-noselect (expand-file-name "c.txt" dir))))
        (switch-to-buffer f1) (switch-to-buffer f2)
        (drgnx-chrome-apply)
        (should (equal (drgnx-chrome-tabs (selected-window)) (list a f1 f2)))
        (drgnx-chrome--close (selected-window) f1)        ; a closed tab does not come back
        (drgnx-chrome-apply)
        (should (equal (drgnx-chrome-tabs (selected-window)) (list a f2)))))))
