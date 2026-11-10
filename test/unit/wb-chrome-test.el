;;; wb-chrome-test.el --- batch tests: chrome by role, tabs, breadcrumbs (I3) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'bytecomp)                                  ; `byte-compile-warnings' is let-bound below
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
      ;; from the project's root, which the Explorer and the title row name already (window-dark.html `.crumbs')
      (should (equal "src › app › main.py" (string-trim crumb)))
      (insert "y")
      (should (string-match-p "●" (drgnx-chrome-breadcrumb (selected-window)))))))

(ert-deftest drgnx-chrome/a-buffer-without-a-file-has-no-path-to-show ()
  ;; the tab already names it (the start page used to repeat "*drgnx start*"); the row stays: rows never change
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (let ((rows (drgnx-chrome-test--heights (selected-window))))
      (switch-to-buffer (get-buffer-create "*drgnx-nofile*"))
      (unwind-protect
          (progn
            (drgnx-chrome-apply nil t)
            (should (equal (string-trim (substring-no-properties (drgnx-chrome-breadcrumb (selected-window)))) ""))
            (should (equal rows (drgnx-chrome-test--heights (selected-window)))))
        (kill-buffer "*drgnx-nofile*")))))

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
      ;; one run for each tab that is not shown (the whole tab, its × included); the shown tab has none
      (should (= 2 (length runs)))
      (should (= 2 (length (seq-uniq (mapcar #'cdr runs) #'eq))))
      (should-not (get-text-property (1- (string-search "  b.txt" tabs)) 'mouse-face tabs))   ; the gap: no hover
      (should (get-text-property (string-search "b.txt" tabs) 'mouse-face tabs))
      (should-not (get-text-property (string-search "c.txt" tabs) 'mouse-face tabs)))))

(ert-deftest drgnx-chrome/tab-faces-pad-dim-and-mark-the-active-group ()
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (drgnx-chrome-test--open dir "b.txt")
    (let* ((tabs (window-parameter (selected-window) 'tab-line-format))
           (face-of (lambda (name) (get-text-property (string-search name tabs) 'face tabs))))
      (should (string-search "  a.txt " tabs))            ; 2-space padding
      (should (eq (funcall face-of "a.txt") 'drgnx-chrome-tab))
      (should (eq (funcall face-of "b.txt") 'drgnx-chrome-tab-active)))
    ;; no height of their own: a relative 1.0 kept the tab line's height and cost a font spec copy per tab run
    (dolist (f '(drgnx-chrome-tab drgnx-chrome-tab-current drgnx-chrome-tab-active))
      (should (eq (face-attribute f :height nil nil) 'unspecified))))
  ;; the look (design §4 tabs, §3.8 Current): the shown tab joins the editor in the body text's colour, no link colour,
  ;; line or bold; the shown tab of another group is muted
  (dolist (f '(drgnx-chrome-tab-active drgnx-chrome-tab-current))
    (should (memq (face-attribute f :overline nil nil) '(nil unspecified)))
    (should (memq (face-attribute f :weight nil nil) '(normal unspecified)))
    (should-not (memq 'link (ensure-list (face-attribute f :inherit nil nil)))))
  (should (memq 'drgnx-text-muted (ensure-list (face-attribute 'drgnx-chrome-tab-current :inherit nil nil)))))

(ert-deftest drgnx-chrome/the-breadcrumb-sits-on-the-editor ()
  "The look (design §4 editor): the breadcrumb row is part of the editor's surface, under the shown tab: the header is
not painted with the tab row's band (`drgnx-wb-bar'); the theme's `header-line' gives the editor's colour."
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "src/a.el")
    (drgnx-chrome-apply nil t)
    (let ((h (window-parameter (selected-window) 'header-line-format)))
      (should (stringp h))
      (should-not (seq-some (lambda (i) (memq 'drgnx-wb-bar (ensure-list (get-text-property i 'face h))))
                            (number-sequence 0 (1- (length h))))))))

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

(ert-deftest drgnx-chrome/tab-line-is-made-again-when-the-row-colour-changes ()
  "A theme switch enables the new theme before its faces reach the frame, so a line made in between keeps the old
row colour (light's tab row had dark's lift above the shown tab): the row's colour is part of what the line shows."
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (let ((w (selected-window)) (made 0) (bg "#18191e") (orig (symbol-function 'drgnx-chrome--tab))
          (face-bg (symbol-function 'face-background)))
      (cl-letf (((symbol-function 'drgnx-chrome--tab) (lambda (&rest args) (setq made (1+ made)) (apply orig args)))
                ((symbol-function 'face-background)
                 (lambda (face &rest r) (if (eq face 'drgnx-chrome-tab) bg (apply face-bg face r)))))
        (drgnx-chrome--tab-line w)
        (setq made 0)
        (drgnx-chrome--tab-line w)
        (should (= made 0))
        (setq bg "#f6f6f8")
        (drgnx-chrome--tab-line w)
        (should (= made 1))))))

(ert-deftest drgnx-chrome/a-theme-switch-makes-the-tab-lines-again ()
  "Nothing else moves an editor's inputs when only the theme changes, so its tab line, painted with the old row colour
\(light and high contrast had dark's lift above the shown tab), is made again when a theme is enabled or disabled."
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (drgnx-chrome-apply nil t)
    (let ((made 0) (bg "#f6f6f8") (orig (symbol-function 'drgnx-chrome--tab))
          (face-bg (symbol-function 'face-background)))
      (cl-letf (((symbol-function 'drgnx-chrome--tab) (lambda (&rest args) (setq made (1+ made)) (apply orig args)))
                ((symbol-function 'face-background)
                 (lambda (face &rest r) (if (eq face 'drgnx-chrome-tab) bg (apply face-bg face r)))))
        (run-hook-with-args 'enable-theme-functions 'drgnx-light)
        (should (= made 1))
        (setq bg "#000000")
        (run-hook-with-args 'disable-theme-functions 'drgnx-light)
        (should (= made 2))))))

(ert-deftest drgnx-chrome/tab-line-memo-hits ()
  "The tab line is made once for 20 self-inserts and 20 applies, and again when a tab's name or modified flag changes."
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "a.txt")
    (let ((w (selected-window)) (made 0) (orig (symbol-function 'drgnx-chrome--tab)))
      (cl-letf (((symbol-function 'drgnx-chrome--tab)
                 (lambda (&rest args) (setq made (1+ made)) (apply orig args))))     ; one tab: one call a build
        (drgnx-chrome--tab-line w)
        (setq made 0)
        (dotimes (_ 20) (goto-char (point-max)) (self-insert-command 1 ?x) (drgnx-chrome--tab-line w))
        (should (= made 1))               ; the first insert flips the modified flag; the other 19 change nothing shown
        (dotimes (_ 20) (drgnx-chrome-apply nil t))
        (should (= made 1))
        (rename-buffer "renamed.txt")
        (should (string-search "renamed.txt" (drgnx-chrome--tab-line w)))
        (should (= made 2))))))

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
                                                drgnx-chrome--tab-buffer-p drgnx-chrome--close-glyph drgnx-chrome--rows-key))
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

;;;; Docked panes as cards (ui/look under Glitnir)
;; Race-proof pattern D (pure): window and frame parameters of one frame, no timing.

(load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)

(ert-deftest drgnx-chrome/wb-card-params-set-and-undone ()
  "A docked pane and an editor window get the card parameters and the frame the gap in its dividers; a popup lane
window gets none.  Taking the cards off gives back the parameters and the divider widths the frame had."
  (drgnx-chrome-test--with _dir
    (let* ((f (selected-frame)) (editor (selected-window))
           (dock (split-window editor nil 'left))
           (lane (split-window editor nil 'below))
           (gap (drgnx-look-density-value 'gap))
           (before (list (frame-parameter f 'right-divider-width) (frame-parameter f 'bottom-divider-width))))
      (set-window-parameter dock 'drgnx-role 'dock)
      (set-window-parameter lane 'drgnx-popup (list :popup nil))
      (drgnx-look--card-frame f)
      (dolist (p '(corner-radius shadow))
        (should (equal (window-parameter dock p) (drgnx-look--card-value p)))
        (should (equal (window-parameter editor p) (drgnx-look--card-value p)))
        (should-not (window-parameter lane p)))
      (should (equal (window-parameter dock 'ring) (drgnx-look--card-value 'ring)))
      (should-not (window-parameter lane 'ring))
      (should (eql (frame-parameter f 'right-divider-width) (round (* gap (frame-scale-factor f)))))
      (should (eql (frame-parameter f 'bottom-divider-width) (round (* gap (frame-scale-factor f)))))
      (drgnx-look--card-frame f)               ; again: the saved widths are still the first ones
      (drgnx-look--card-restore f)
      (dolist (p '(corner-radius shadow ring))
        (should-not (window-parameter dock p))
        (should-not (window-parameter editor p)))
      (should (equal before (list (frame-parameter f 'right-divider-width) (frame-parameter f 'bottom-divider-width)))))))

(ert-deftest drgnx-chrome/wb-card-gap-is-in-logical-pixels ()
  "The gap is logical: at a frame scale of 2 the dividers are twice the gap, in device pixels, and a change of the
scale re-applies it.  Race-proof pattern D (pure: the scale is stubbed)."
  (drgnx-chrome-test--with _dir
    (let* ((f (selected-frame)) (gap (drgnx-look-density-value 'gap)) (scale 2)
           (border (frame-parameter f 'internal-border-width)))
      (cl-letf (((symbol-function 'frame-scale-factor) (lambda (&optional _frame) scale)))
        (drgnx-look--card-frame f)
        (should (eql (frame-parameter f 'right-divider-width) 12))
        (should (eql (frame-parameter f 'bottom-divider-width) 12))
        (should (eql (frame-parameter f 'internal-border-width) 12)) ; the frame's outer gap
        (setq scale 1.25)
        (drgnx-look--card-follow-scale f)
        (should (eql (frame-parameter f 'right-divider-width) (round (* gap 1.25))))
        (should (eql (frame-parameter f 'internal-border-width) (round (* gap 1.25))))
        (drgnx-look--card-restore f)
        (should (eql (frame-parameter f 'internal-border-width) (or border 0)))))))

(ert-deftest drgnx-wb-chrome/card-ring-per-variant ()
  "A card's ring is the border face at 0.6 (dark), 0.8 (light) and 1.0 (high contrast); its shadow 0.45, 0.08 and
none.  The selected window's ring is the accent at 1.0 in every variant.  Race-proof pattern D (the variant is
stubbed)."
  (drgnx-chrome-test--with _dir
    (let* ((editor (selected-window)) (other (split-window editor nil 'below)) (variant 'dark))
      (cl-letf (((symbol-function 'drgnx-look-variant) (lambda (&optional _frame) variant)))
        (pcase-dolist (`(,v ,ring ,opacity) '((dark 0.6 0.45) (light 0.8 0.08) (hc 1.0 nil)))
          (setq variant v)
          (should (equal (drgnx-look--card-value 'ring) (cons 'drgnx-border ring)))
          (should (equal (plist-get (drgnx-look--card-value 'shadow) :opacity) opacity))
          (drgnx-look--card-set other)
          (drgnx-look--card-set editor)
          (should (equal (window-parameter other 'ring) (cons 'drgnx-border ring)))
          (should (equal (window-parameter editor 'ring) '(drgnx-accent . 1.0)))
          (should (equal (window-parameter other 'shadow) (drgnx-look--card-value 'shadow))))))))

(ert-deftest drgnx-wb-chrome/the-accent-ring-only-among-editor-groups ()
  "window-dark.html: one editor group and the docked panes show no focus ring (the selected pane is told by its
rows); tiling.html: with two editor groups the selected one's card is ringed in the accent.  Race-proof pattern
D."
  (drgnx-chrome-test--with _dir
    (let ((editor (selected-window)))
      (drgnx-look--card-set editor)
      (should (equal (window-parameter editor 'ring) (drgnx-look--card-value 'ring)))
      (let ((other (split-window editor nil 'right)))
        (drgnx-look--card-set editor)
        (should (equal (window-parameter editor 'ring) '(drgnx-accent . 1.0)))
        (drgnx-look--card-set other)
        (should (equal (window-parameter other 'ring) (drgnx-look--card-value 'ring)))))))

(ert-deftest drgnx-wb-chrome/the-sidebar-is-one-card-group ()
  "window-dark.html `.card.ex': the sidebar's sections are one island, so every dock window names the same card group
\(Glitnir draws one card around windows of a group that tile a rectangle), filled with the panel surface; an editor
group names none, and taking the card off takes the group too.  Race-proof pattern D."
  (drgnx-chrome-test--with _dir
    (let* ((editor (selected-window)) (top (split-window editor nil 'left)) (low (split-window top nil 'below)))
      (dolist (w (list top low)) (set-window-parameter w 'drgnx-role 'dock))
      (dolist (w (list editor top low)) (drgnx-look--card-set w))
      (should (equal (window-parameter top 'card-group) '(drgnx-sidebar . drgnx-surface-panel)))
      (should (equal (window-parameter low 'card-group) (window-parameter top 'card-group)))
      (should-not (window-parameter editor 'card-group))
      (drgnx-look--card-unset top)
      (should-not (window-parameter top 'card-group)))))

(ert-deftest drgnx-wb-chrome/gap-follows-density ()
  "The dividers and the frame's edge are the density's gap in device pixels, and a density change gives them again
at once (the density's changed hook).  Race-proof pattern D (the scale is stubbed)."
  (drgnx-chrome-test--with _dir
    (let ((f (selected-frame)) (drgnx-look-density 'comfortable) (scale 2))
      (cl-letf (((symbol-function 'frame-scale-factor) (lambda (&optional _frame) scale)))
        (unwind-protect
            (progn
              (drgnx-look--islands-on)
              (drgnx-look--card-frame f)
              (should (eql (frame-parameter f 'right-divider-width) 12))
              (setq drgnx-look-density 'roomy)
              (run-hooks 'drgnx-look-density-changed-hook)
              (dolist (p '(right-divider-width bottom-divider-width internal-border-width))
                (should (eql (frame-parameter f p) 16)))
              (setq drgnx-look-density 'compact)
              (run-hooks 'drgnx-look-density-changed-hook)
              (dolist (p '(right-divider-width bottom-divider-width internal-border-width))
                (should (eql (frame-parameter f p) 8))))
          (drgnx-look--islands-off)
          (drgnx-look--card-restore f))))))

(defvar glitnir-enable)
(defvar drgnx-look--edge-before)
(defvar drgnx-look--edge-door)

(ert-deftest drgnx-wb-chrome/edge-at-birth-follows-density ()
  "Under Glitnir a window made from now on is born with the density's gap as its edge (`default-frame-alist'), and
after a density change with the new gap, so it never grows once shown.  Race-proof pattern D (Glitnir, the density
and the alist are bound)."
  (let ((features (cons 'glitnir features)) (glitnir-enable t) (default-frame-alist default-frame-alist)
        (drgnx-look-density 'comfortable) (drgnx-look--edge-before nil) (drgnx-look--edge-door nil))
    (unwind-protect
        (progn
          (drgnx-look--islands-on)
          (drgnx-look--edge-at-birth)
          (should (eql (alist-get 'internal-border-width default-frame-alist) 6))
          (setq drgnx-look-density 'roomy)
          (run-hooks 'drgnx-look-density-changed-hook)
          (should (eql (alist-get 'internal-border-width default-frame-alist) 8)))
      (drgnx-look--islands-off))))

(ert-deftest drgnx-wb-chrome/divider-faces-restored-when-cards-go ()
  "While cards show, the divider faces and the frame's edge take the gap's background on the frame, whatever the theme
says (modus's grey stripes); a theme change gives them again; taking the cards off gives the theme's faces back.
Race-proof pattern D."
  (drgnx-chrome-test--with _dir
    (let* ((f (selected-frame)) (gap "#102030")
           (faces '((window-divider . :foreground) (window-divider-first-pixel . :foreground)
                    (window-divider-last-pixel . :foreground) (internal-border . :background)))
           (read (lambda () (mapcar (lambda (c) (face-attribute (car c) (cdr c) f)) faces)))
           (spec (get 'drgnx-surface-gap 'face-defface-spec)))
      (unwind-protect
          (progn
            (face-spec-set 'drgnx-surface-gap `((t :background ,gap)) 'face-defface-spec)
            (set-face-foreground 'window-divider "#9f9f9f" f)
            (drgnx-look--islands-on)
            (drgnx-look--card-frame f)
            (should (equal (funcall read) (make-list 4 gap)))
            (set-face-foreground 'window-divider "#9f9f9f" f)       ; a theme change sets them again
            (run-hook-with-args 'enable-theme-functions 'wombat)
            (should (equal (funcall read) (make-list 4 gap)))
            (drgnx-look--card-restore f)
            (should-not (member gap (funcall read))))
        (drgnx-look--islands-off)
        (face-spec-set 'drgnx-surface-gap spec 'face-defface-spec)
        (set-face-foreground 'window-divider nil f)))))

;;;; Tail providers

(defun drgnx-chrome-test--tail-a (_w) "A")
(defun drgnx-chrome-test--tail-b (_w) "B")
(defun drgnx-chrome-test--tail-none (_w) nil)

(ert-deftest drgnx-chrome/tail-providers-in-depth-order ()
  (let ((drgnx-chrome-tail-providers nil))
    (unwind-protect
        (progn
          (drgnx-chrome-add-tail-provider #'drgnx-chrome-test--tail-a 30)
          (drgnx-chrome-add-tail-provider #'drgnx-chrome-test--tail-none 20)
          (drgnx-chrome-add-tail-provider #'drgnx-chrome-test--tail-b 10)
          (should (equal '(drgnx-chrome-test--tail-b drgnx-chrome-test--tail-none drgnx-chrome-test--tail-a)
                         drgnx-chrome-tail-providers))
          (should (equal "BA" (drgnx-chrome--tail-string (selected-window))))
          ;; adding one again moves it
          (drgnx-chrome-add-tail-provider #'drgnx-chrome-test--tail-b 40)
          (should (equal "AB" (drgnx-chrome--tail-string (selected-window))))
          (drgnx-chrome-remove-tail-provider #'drgnx-chrome-test--tail-b)
          (should (equal "A" (drgnx-chrome--tail-string (selected-window)))))
      (dolist (f '(drgnx-chrome-test--tail-a drgnx-chrome-test--tail-b drgnx-chrome-test--tail-none))
        (drgnx-chrome-remove-tail-provider f)))))

(ert-deftest drgnx-chrome/a-header-with-providers-keeps-the-breadcrumb-first ()
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "src/a.el")
    (let ((drgnx-chrome-tail-providers nil))
      (unwind-protect
          (progn
            (drgnx-chrome-add-tail-provider #'drgnx-chrome-test--tail-a 10)
            (drgnx-chrome-apply nil t)
            (let ((h (window-parameter (selected-window) 'header-line-format)))
              (should (string-search "a.el" (car h)))
              (should (equal drgnx-chrome--providers-tail (cadr h)))))
        (drgnx-chrome-remove-tail-provider #'drgnx-chrome-test--tail-a)
        (drgnx-chrome-apply nil t)
        (should (stringp (window-parameter (selected-window) 'header-line-format)))))))

(ert-deftest drgnx-chrome/the-breadcrumb-is-spaced-as-the-mockup ()
  "window-dark.html `.crumbs': on a graphical frame the row starts 12 px in and its parts are 6 px either side of
each `›' (the text stays `a › b')."
  (drgnx-chrome-test--with dir
    (make-directory (expand-file-name ".git" dir))
    (drgnx-chrome-test--open dir "src/main.py")
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'drgnx-pixels-font-extent) (lambda (&rest _) '(12 . 4))))
      (let* ((crumb (drgnx-chrome-breadcrumb (selected-window)))
             (sep (string-search "›" crumb)))
        (should (equal "src › main.py" (string-trim (substring-no-properties crumb))))
        (should (equal '(space :width (6)) (get-text-property (1- sep) 'display crumb)))
        (should (equal '(space :width (6)) (get-text-property (1+ sep) 'display crumb)))
        (should (equal '(space :width (12)) (get-text-property (1- (string-search "src" crumb)) 'display crumb)))))))

(ert-deftest drgnx-chrome/the-breadcrumb-names-the-definition-at-point ()
  "window-dark.html `.crumbs': the breadcrumb ends with the definition point is in (`.cur', muted; the file then in
the crumbs' colour).  The name is looked up on idle (a command only arms the debounce), kept in the window, and the
breadcrumb only reads it: making it calls no lookup.  A window showing another buffer shows no stale name.  Pattern D
(the idle timer's function is called)."
  (drgnx-chrome-test--with dir
    (make-directory (expand-file-name ".git" dir))
    (let* ((w (selected-window)) (b (drgnx-chrome-test--open dir "src/a.el")))
      (with-current-buffer b
        (erase-buffer)
        (insert "(defun drgnx-test-one ()\n  1)\n\n(defun drgnx-test-two ()\n  2)\n")
        (emacs-lisp-mode)
        (goto-char (point-min)) (search-forward "2)") (set-buffer-modified-p nil))
      (set-window-point w (with-current-buffer b (point)))
      (drgnx-chrome--symbol-schedule)
      (should (drgnx-timer-active-p 'chrome-symbol))
      (drgnx-chrome--symbol-update)
      (let ((crumb (cl-letf (((symbol-function 'add-log-current-defun) (lambda () (error "Looked up while drawing"))))
                     (drgnx-chrome-breadcrumb w))))
        (should (equal "src › a.el › drgnx-test-two" (string-trim (substring-no-properties crumb))))
        (should (memq 'drgnx-text-muted (ensure-list (get-text-property (string-search "drgnx-test-two" crumb) 'face crumb))))
        (should (memq 'drgnx-chrome-crumb (ensure-list (get-text-property (string-search "a.el" crumb) 'face crumb)))))
      (should (string-search "drgnx-test-two" (format "%s" (window-parameter w 'header-line-format))))
      (drgnx-chrome-test--open dir "b.txt")
      (should-not (string-search "drgnx-test" (drgnx-chrome-breadcrumb w)))
      (drgnx-timer-cancel 'chrome-symbol))))

(defun drgnx-chrome-test--face-key (s pos key)
  "The value of KEY in the anonymous face at POS of S (a plist in its `face' list), or nil."
  (let ((found nil))
    (dolist (f (let ((v (get-text-property pos 'face s))) (if (keywordp (car-safe v)) (list v) (ensure-list v))))
      (when (and (consp f) (keywordp (car f)) (plist-member f key) (not found)) (setq found (plist-get f key))))
    found))

(defun drgnx-chrome-test--at (s prop value)
  "The first position of S whose PROP is VALUE."
  (let ((i 0) (n (length s)) (found nil))
    (while (and (< i n) (not found))
      (when (equal (get-text-property i prop s) value) (setq found i))
      (setq i (1+ i)))
    found))

(ert-deftest drgnx-chrome/the-tab-row-is-drawn-as-the-mockup ()
  "window-dark.html `.tabs': on a graphical frame the row starts 6 px in; the shown tab is lifted 4 px off the row's
top by a box in the row's colour (its rounded top is Glitnir's); every other part of the row (the other tabs, the
gaps, the buttons) is underlined by the subtle border, the hairline under the row the shown tab joins the editor
through; a tab's × is the 14 px icon in an 18 px slot; a modified tab shows its dot in that slot; the buttons are
split, then more.  Pattern D (the frame's kind and fonts are stubbed)."
  (drgnx-chrome-test--with dir
    (unwind-protect
        (progn
          (load-theme 'drgnx-dark t)
          (let* ((w (selected-window)) (a (drgnx-chrome-test--open dir "a.el")) (_b (drgnx-chrome-test--open dir "b.el"))
                 (drgnx-look-icons 'glyphs))   ; the × as its glyph, so the text shows it
            (with-current-buffer a (insert "y"))
            (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
                      ((symbol-function 'drgnx-pixels-font-extent) (lambda (&rest _) '(12 . 4))))
              (let* ((line (drgnx-chrome--tab-line-make w))
                     (rule (face-foreground 'drgnx-border-subtle nil t))
                     (pa (string-search "a.el" line)) (pb (string-search "b.el" line)))
                (should (stringp rule))
                (should (equal '(space :width (6)) (get-text-property 1 'display line)))
                ;; the shown tab: lifted by the row's colour, no hairline
                (should (equal '(0 . 4) (plist-get (drgnx-chrome-test--face-key line pb :box) :line-width)))
                (should (equal (face-background 'drgnx-chrome-tab nil t)
                               (plist-get (drgnx-chrome-test--face-key line pb :box) :color)))
                (should-not (drgnx-chrome-test--face-key line pb :underline))
                ;; another tab, the gap after it and the buttons: the hairline
                (dolist (p (list pa (+ pa 5) (1- (length line))))
                  (should (equal rule (plist-get (drgnx-chrome-test--face-key line p :underline) :color))))
                (should (string-search "●" (substring-no-properties line pa pb)))
                (should-not (string-search "×" (substring-no-properties line pa pb)))
                (let ((x (string-search "×" line pb)))
                  (should x)
                  (should (equal '(space :width (2)) (get-text-property (1- x) 'display line))))
                (let ((split (drgnx-chrome-test--at line 'help-echo "Split the editor right"))
                      (more (drgnx-chrome-test--at line 'help-echo "Tabs of this group")))
                  (should (< split more)))))))
      (disable-theme 'drgnx-dark))))

(ert-deftest drgnx-chrome/a-preview-tab-is-italic-until-kept ()
  "As VS Code's preview: a file opened as a preview (the Explorer's single click) is an italic tab that the next
preview replaces; an edit, or opening it to work in (a double click, Open), keeps it as a normal tab.  A file that
was already a tab never becomes a preview."
  (drgnx-chrome-test--with dir
    (let* ((w (selected-window))
           (kept (drgnx-chrome-test--open dir "kept.el"))
           (visit (lambda (name preview)
                    (let ((b (find-file-noselect (expand-file-name name dir))))
                      (let ((new (not (drgnx-chrome-tab-p b))))
                        (switch-to-buffer b) (drgnx-chrome-apply nil t)
                        (drgnx-chrome-note-preview b (and preview new)))
                      b)))
           (italic (lambda (b) (memq 'drgnx-chrome-tab-preview
                                     (ensure-list (get-text-property 2 'face (drgnx-chrome--tab w b t t nil)))))))
      (write-region "x\n" nil (expand-file-name "a.el" dir) nil 'silent)
      (write-region "x\n" nil (expand-file-name "b.el" dir) nil 'silent)
      (let ((a (funcall visit "a.el" t)))
        (should (funcall italic a))
        (should-not (funcall italic kept))
        (let ((b (funcall visit "b.el" t)))              ; the next preview takes a's place
          (should (funcall italic b))
          (should-not (memq a (drgnx-chrome-tabs w)))
          (with-current-buffer b (insert "y"))          ; an edit keeps it
          (should-not (funcall italic b))
          (let ((a2 (funcall visit "a.el" t)))
            (should (memq b (drgnx-chrome-tabs w)))
            (should (funcall italic a2))
            (funcall visit "a.el" nil)                  ; opened to work in: kept
            (should-not (funcall italic a2))
            (funcall visit "kept.el" t)                 ; already a tab: not a preview
            (should-not (funcall italic kept))
            (with-current-buffer b (set-buffer-modified-p nil))))))))

(ert-deftest drgnx-chrome/the-breadcrumb-shortens-on-request ()
  (drgnx-chrome-test--with dir
    (drgnx-chrome-test--open dir "src/deep/a.el")
    (let ((full (drgnx-chrome-breadcrumb (selected-window)))
          (short (let ((drgnx-chrome-short-breadcrumb-functions (list (lambda (_w) t))))
                   (drgnx-chrome-breadcrumb (selected-window)))))
      (should (string-search "deep" full))
      (should (string-search "a.el" short))
      (should-not (string-search "deep" short)))))
