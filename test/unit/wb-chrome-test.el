;;; wb-chrome-test.el --- batch tests: chrome by role, tabs, breadcrumbs (I3) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-chrome)

(defmacro drgnx-chrome-test--with (dir &rest body)
  "BODY with chrome on, one editor window, a temp DIR for files."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let ((,dir (file-name-as-directory (make-temp-file "drgnx-chrome" t)))
           (display-buffer-alist nil))
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
         (delete-directory ,dir t)))))

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

(ert-deftest drgnx-chrome/role-from-the-table ()
  "A window's chrome is its role's `:chrome' in the store's role table; a role not in it is an editor window."
  (drgnx-test-with-state
    (delete-other-windows)
    (let ((w (split-window nil nil 'below)))
      (unwind-protect
          (progn
            (set-window-parameter w 'drgnx-role 'drgnx-chrome-test-strip)
            (should (eq 'editor (drgnx-chrome--role w)))
            (drgnx-state-define-role 'drgnx-chrome-test-strip :chrome 'dock)
            (should (eq 'dock (drgnx-chrome--role w)))
            (drgnx-state-define-role 'drgnx-chrome-test-strip :chrome 'area)
            (should (eq 'area (drgnx-chrome--role w)))
            (drgnx-state-define-role 'drgnx-chrome-test-strip)
            (should-not (drgnx-chrome--role w))                       ; no chrome: left alone
            (set-window-parameter w 'drgnx-popup '(:borrowed nil))    ; a popup lane, whatever else it is
            (should (eq 'lane (drgnx-chrome--role w)))
            (should (eq 'editor (drgnx-chrome--role (selected-window))))
            (should-not (drgnx-chrome--role (minibuffer-window))))
        (set-window-parameter w 'drgnx-popup nil)
        (delete-window w)))))

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

;;;; The store's events (Task 18): chrome is applied inside the observation, before a frame is drawn

(ert-deftest drgnx-chrome/a-new-window-has-chrome-before-it-is-drawn ()
  "A window made by anything gets its tab line and header at the store's next observation — no command, no idle
call, no bus flush: the `windows-changed' `now' subscriber."
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (drgnx-state-sync)
    (should (eq 'now (drgnx-state--lane-of 'windows-changed #'drgnx-chrome--windows-changed)))
    (let ((w (split-window nil nil 'right)))
      (should-not (window-parameter w 'tab-line-format))
      (should-not (window-parameter w 'header-line-format))
      (drgnx-state-sync)
      (should (window-parameter w 'tab-line-format))
      (should (window-parameter w 'header-line-format))
      (should (eq (window-parameter w 'mode-line-format) drgnx-chrome-editor-mode-line)))))

(ert-deftest drgnx-chrome/tab-lines-follow-the-editor-at-once ()
  "The editor's new buffer is a tab, and the window's header names it, at the store's observation."
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (drgnx-state-sync)
    (should (eq 'now (drgnx-state--lane-of 'editor-changed #'drgnx-chrome--editor-changed)))
    (let* ((f (expand-file-name "b.txt" dir)) (w (selected-window)))
      (write-region "y\n" nil f nil 'silent)
      (switch-to-buffer (find-file-noselect f))
      (should-not (memq (current-buffer) (drgnx-chrome-tabs w)))
      (drgnx-state-sync)
      (should (memq (current-buffer) (drgnx-chrome-tabs w)))
      (should (string-match-p "b\\.txt" (substring-no-properties (window-parameter w 'tab-line-format))))
      (should (string-match-p "b\\.txt" (format "%S" (window-parameter w 'header-line-format)))))))

(ert-deftest drgnx-chrome/the-subscribers-repair-chrome-someone-else-changed ()
  "A window whose chrome was cleared is set again at the next observation; a panel gets its title-only chrome."
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (drgnx-state-sync)
    (let ((w (selected-window)) (panel (drgnx-wb-area-show 'panel 'output)))
      (drgnx-state-sync)
      (should (equal (mapcar #'cl-plusp (drgnx-chrome-test--heights panel)) '(nil t nil)))
      (should (window-parameter w 'tab-line-format))
      (set-window-parameter w 'tab-line-format nil)
      (drgnx-chrome--windows-changed (list :frame (selected-frame)))
      (should (window-parameter w 'tab-line-format)))))

(ert-deftest drgnx-chrome/the-mode-subscribes-to-the-store-only ()
  (drgnx-test-with-state
    (unwind-protect
        (progn
          (drgnx-chrome-mode 1)
          (should (eq 'now (drgnx-state--lane-of 'windows-changed #'drgnx-chrome--windows-changed)))
          (should (eq 'now (drgnx-state--lane-of 'editor-changed #'drgnx-chrome--editor-changed)))
          (should (memq #'drgnx-chrome--refresh (alist-get 'buffer-set-changed drgnx-signal--subscribers)))
          (should (memq #'drgnx-chrome--refresh (alist-get 'modified-changed drgnx-signal--subscribers)))
          (should-not (memq #'drgnx-chrome--refresh (alist-get 'editor-changed drgnx-signal--subscribers)))
          (with-suppressed-warnings ((obsolete drgnx-signal-window-functions))
            (should-not (memq #'drgnx-chrome-apply drgnx-signal-window-functions)))
          (drgnx-chrome-mode -1)
          (should-not (drgnx-state--lane-of 'windows-changed #'drgnx-chrome--windows-changed))
          (should-not (drgnx-state--lane-of 'editor-changed #'drgnx-chrome--editor-changed))
          (should-not (memq #'drgnx-chrome--refresh (alist-get 'buffer-set-changed drgnx-signal--subscribers))))
      (drgnx-chrome-mode -1))))

(ert-deftest drgnx-chrome/now-subscribers-are-cheap ()
  "With nothing to change, both `now' subscribers cost little on a 7-window frame (byte-compiled)."
  :tags '(:timing)
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (dolist (fn '(drgnx-chrome--windows-changed drgnx-chrome--editor-changed drgnx-chrome--apply-changed drgnx-chrome--memo-current-p drgnx-chrome--memo-set drgnx-chrome-apply drgnx-chrome--apply-window
                                                drgnx-chrome--role drgnx-chrome--set drgnx-chrome--tab-line drgnx-chrome--note drgnx-chrome--note-history
                                                drgnx-chrome-tabs drgnx-chrome-breadcrumb drgnx-chrome--project-root drgnx-chrome--text
                                                drgnx-chrome--tab-buffer-p drgnx-chrome--close-glyph))
      (unless (compiled-function-p (symbol-function fn))      ; the tests load drgnx from source: measure what users run
        (let ((byte-compile-warnings nil)) (byte-compile fn))))
    (let ((window-min-width 2) (window-min-height 2))        ; a small batch frame
      (dotimes (_ 6) (split-window (get-largest-window) nil 'right)))
    (drgnx-state-sync)
    (let* ((f (selected-frame)) (w (selected-window))
           (win (list :frame f :windows (window-list f 'nomini)))
           (ed (list :frame f :window w :buffer (window-buffer w)))
           (n 500)
           (loop (byte-compile (lambda (win ed n)
                                 (dotimes (_ n) (drgnx-chrome--windows-changed win) (drgnx-chrome--editor-changed ed)))))
           (runs nil))
      (should (= 7 (length (window-list f 'nomini))))
      (funcall loop win ed 2)                 ; settle: every window has its chrome
      (dotimes (_ 21)
        (let ((t0 (float-time)))
          (funcall loop win ed n)
          (push (/ (* 1e6 (- (float-time) t0)) n 2) runs)))   ; per subscriber call
      (setq runs (sort runs #'<))
      (message "chrome now subscribers, 7 windows: %.1f µs per call (median of 21 × %d)" (nth 10 runs) n)
      (should (<= (nth 10 runs) (* 50 (drgnx-run-ert-time-factor)))))))
