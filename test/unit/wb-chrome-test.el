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

(defun drgnx-chrome-test--heights (w)
  (list (window-tab-line-height w) (window-header-line-height w) (window-mode-line-height w)))

(ert-deftest drgnx-chrome/roles-decide-the-chrome ()
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (let ((editor (selected-window)) (panel (drgnx-wb-area-show 'panel 'output)))
      (drgnx-chrome-apply nil t)
      (should (seq-every-p #'cl-plusp (drgnx-chrome-test--heights editor)))      ; tab line, header, mode line
      (should (equal (mapcar #'cl-plusp (drgnx-chrome-test--heights panel)) '(nil t nil))))))  ; tab row only

(ert-deftest drgnx-chrome/a-buffer-adds-to-the-breadcrumb ()
  ;; sticky scroll's scopes after the breadcrumb, from the buffer's own `drgnx-chrome-header-tail'
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "src/a.el")
    (setq-local drgnx-chrome-header-tail '(:eval " › (defun f ()"))
    (drgnx-chrome-apply nil t)
    (let ((h (window-parameter (selected-window) 'header-line-format)))   ; (format-mode-line is "" in batch)
      (should (string-search "a.el" (car h)))
      (should (equal (cadr h) '(:eval " › (defun f ()"))))
    (kill-local-variable 'drgnx-chrome-header-tail)
    (drgnx-chrome-apply nil t)
    (should (stringp (window-parameter (selected-window) 'header-line-format)))))

(ert-deftest drgnx-chrome/a-mode-cannot-change-the-height ()
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (let ((before (drgnx-chrome-test--heights (selected-window))))
      (switch-to-buffer (get-buffer-create "*drgnx-odd*"))
      (setq-local header-line-format nil tab-line-format nil mode-line-format nil)
      (drgnx-chrome-apply nil t)
      (should (equal before (drgnx-chrome-test--heights (selected-window))))
      (kill-buffer "*drgnx-odd*"))))

(ert-deftest drgnx-chrome/tabs-keep-open-order ()
  (drgnx-chrome-test--with dir
    (let ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
          (c (drgnx-chrome-test--open dir "c.txt")))
      (switch-to-buffer a)
      (drgnx-chrome-apply nil t)
      (should (equal (drgnx-chrome-tabs (selected-window)) (list a b c))))))

(ert-deftest drgnx-chrome/killing-a-buffer-drops-its-tab-everywhere ()
  (drgnx-chrome-test--with dir
    (let* ((a (drgnx-chrome-test--open dir "a.txt")) (b (drgnx-chrome-test--open dir "b.txt"))
           (w1 (selected-window)) (w2 (split-window w1 nil 'right)))
      (with-selected-window w2 (switch-to-buffer a) (drgnx-chrome-apply nil t) (switch-to-buffer b) (drgnx-chrome-apply nil t))
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

(ert-deftest drgnx-chrome/child-frames-get-no-chrome ()
  ;; C1: posframe, vertico-posframe, corfu, eldoc-box windows live in child frames.
  (cl-letf (((symbol-function 'frame-parent) (lambda (&optional _f) (selected-frame))))
    (should-not (drgnx-chrome--role (selected-window)))))

(ert-deftest drgnx-chrome/the-project-root-is-looked-up-once ()
  ;; I7: outside a repository `project-current' walks the tree every time.
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (let ((n 0))
      (cl-letf* ((orig (symbol-function 'project-current))
                 ((symbol-function 'project-current) (lambda (&rest a) (setq n (1+ n)) (apply orig a))))
        (drgnx-chrome-breadcrumb (selected-window))
        (drgnx-chrome-breadcrumb (selected-window))
        (should (<= n 1))))))

(ert-deftest drgnx-chrome/a-buffer-with-its-own-header-keeps-it ()
  ;; I8: tabulated-list column headings (click to sort) are the header line.  (`format-mode-line'
  ;; returns "" in batch: the window parameter is checked.)
  (drgnx-chrome-test--with dir
    (switch-to-buffer (get-buffer-create "*drgnx-table*"))
    (unwind-protect
        (progn
          (setq-local header-line-format " Name   Size")
          (drgnx-chrome-apply nil t)
          (should (equal (window-parameter (selected-window) 'header-line-format) '(:eval header-line-format)))
          (setq-local header-line-format nil)
          (drgnx-chrome-apply nil t)
          (should (stringp (window-parameter (selected-window) 'header-line-format))))
      (kill-buffer "*drgnx-table*"))))

(ert-deftest drgnx-chrome/previews-leave-no-tabs ()
  ;; I9: consult/xref previews show buffers for a moment, inside a minibuffer or a restored excursion.
  (drgnx-chrome-test--with dir
    (let ((a (drgnx-chrome-test--open dir "a.txt")) (p (find-file-noselect (expand-file-name "p.txt" dir))))
      (save-window-excursion (switch-to-buffer p) (drgnx-chrome-apply))  ; drawn, not noted
      (drgnx-chrome--refresh)
      (should (equal (drgnx-chrome-tabs (selected-window)) (list a))))))

(ert-deftest drgnx-chrome/percent-signs-are-shown-as-is ()
  ;; Minor 1 (re-graded): %b in a name must reach the formatter as %%b (shown as %b).
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "rate%b-50%.txt")
    (should (string-search "rate%%b-50%%.txt" (window-parameter (selected-window) 'header-line-format)))
    (should (string-search "rate%%b-50%%.txt" (window-parameter (selected-window) 'tab-line-format)))))

(ert-deftest drgnx-chrome/a-tab-closes-with-the-themed-close-mark ()
  "One close mark everywhere: the tab's comes from the glyph table (ASCII on a terminal that is not UTF-8)."
  (drgnx-chrome-test--with dir
    (cl-letf (((symbol-function 'drgnx-face-glyph) (lambda (name &optional _frame) (and (eq name 'close) "x"))))
      (drgnx-chrome-test--open dir "a.txt")
      (let ((tabs (window-parameter (selected-window) 'tab-line-format)))
        (should (string-search " a.txt x " tabs))
        (should-not (string-search "×" tabs))
        (should (equal (get-text-property (string-search "x " tabs (string-search "a.txt" tabs)) 'help-echo tabs)
                       "Close this tab"))))))

(defun drgnx-chrome-test--mouse-runs (s)
  "The runs of S (start . value) where its `mouse-face' is set, split where the value is not `eq'."
  (let ((i 0) runs)
    (while i
      (let ((v (get-text-property i 'mouse-face s)) (next (next-single-property-change i 'mouse-face s)))
        (when v (push (cons i v) runs))
        (setq i next)))
    (nreverse runs)))

(ert-deftest drgnx-chrome/hover-lights-one-tab-not-the-strip ()
  ;; Emacs highlights the run of text whose mouse-face is `eq': one shared value lit every tab.
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (drgnx-chrome-test--open dir "b.txt")
    (drgnx-chrome-test--open dir "c.txt")
    (let* ((tabs (window-parameter (selected-window) 'tab-line-format))
           (runs (drgnx-chrome-test--mouse-runs tabs)))
      (should (= 6 (length runs)))                      ; a name and a × for each of the three tabs
      (should (= 6 (length (seq-uniq (mapcar #'cdr runs) #'eq))))
      (should-not (get-text-property (1- (string-search "  b.txt" tabs)) 'mouse-face tabs))   ; the gap: no hover
      (should (get-text-property (string-search "b.txt" tabs) 'mouse-face tabs)))))

(ert-deftest drgnx-chrome/tab-faces-pad-dim-and-mark-the-active-group ()
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (drgnx-chrome-test--open dir "b.txt")
    (let* ((tabs (window-parameter (selected-window) 'tab-line-format))
           (face-of (lambda (name) (get-text-property (string-search name tabs) 'face tabs))))
      (should (string-search "  a.txt " tabs))            ; 2-space padding
      (should (eq (funcall face-of "a.txt") 'drgnx-chrome-tab))
      (should (eq (funcall face-of "b.txt") 'drgnx-chrome-tab-active)))
    (dolist (f '(drgnx-chrome-tab drgnx-chrome-tab-current drgnx-chrome-tab-active))
      (should (eql (face-attribute f :height nil nil) 1.0))))
  (should (eq (face-attribute 'drgnx-chrome-tab-active :overline nil nil) t))
  (should (memq (face-attribute 'drgnx-chrome-tab-current :overline nil nil) '(nil unspecified))))

(ert-deftest drgnx-chrome/header-rows-are-one-band-to-the-edge ()
  (let ((s (drgnx-wb-bar "x")))
    (should (eq (get-text-property 0 'face s) 'drgnx-wb-bar))
    (should (equal (get-text-property 1 'display s) '(space :align-to right)))
    (should (eq (get-text-property 1 'face s) 'drgnx-wb-bar))))

(ert-deftest drgnx-chrome/tab-faces-are-defined ()
  ;; Minor 2 (re-graded): the faces we inherit exist without loading tab-line by hand.
  (should (facep 'tab-line-tab-current))
  (should (facep 'tab-line-tab-inactive)))

(ert-deftest drgnx-chrome/unchanged-chrome-is-not-set-again ()
  ;; Setting a window parameter redraws the window: an unchanged tab line or header must not be set.
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (let ((sets 0))
      (cl-letf* ((orig (symbol-function 'set-window-parameter))
                 ((symbol-function 'set-window-parameter) (lambda (&rest a) (setq sets (1+ sets)) (apply orig a))))
        (drgnx-chrome-apply nil t)
        (drgnx-chrome--refresh)
        (should (= sets 0))))))
