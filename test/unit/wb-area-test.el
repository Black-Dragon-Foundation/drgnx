;;; wb-area-test.el --- batch tests: the bottom panel and the right dock (tabbed areas) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-area)

(defmacro drgnx-area-test--with (&rest body)
  "BODY with rules on, one editor window, the panel and right dock hidden, fresh area state."
  `(let ((drgnx-signal--editor-window nil) (drgnx-wb-unrouted nil)
         (display-buffer-alist nil) (display-buffer-overriding-action '(nil)))
     (delete-other-windows)
     (set-frame-parameter nil 'drgnx-wb-areas nil)
     (set-frame-parameter nil 'drgnx-wb-panel-px nil)
     (set-frame-parameter nil 'drgnx-wb-right-px nil)
     (drgnx-rules-mode 1)
     (unwind-protect (progn ,@body)
       (drgnx-rules-mode -1)
       (drgnx-wb-area-hide 'panel)
       (drgnx-wb-area-hide 'right)
       (delete-other-windows)
       (dolist (b '("*Help*" "*drgnx-results*" "*notes*")) (when (get-buffer b) (kill-buffer b))))))

(defun drgnx-area-test--results ()
  "A results buffer with 100 lines."
  (with-current-buffer (get-buffer-create "*drgnx-results*")
    (erase-buffer)
    (dotimes (i 100) (insert (format "line %d\n" i)))
    (current-buffer)))

(ert-deftest drgnx-area/help-goes-to-the-panel-help-tab ()
  (drgnx-area-test--with
   (let ((editor (selected-window)))
     (describe-function 'car)
     (let ((w (drgnx-wb-area-window 'panel)))
       (should (window-live-p w))
       (should (eq (window-buffer w) (get-buffer "*Help*")))
       (should (eq (drgnx-wb-area-tab 'panel) 'help))
       (should (eq (selected-window) editor))
       (should-not drgnx-wb-unrouted)))))

(ert-deftest drgnx-area/tabs-swap-in-place ()
  (drgnx-area-test--with
   (let* ((w (drgnx-wb-area-show 'panel 'results (drgnx-area-test--results)))
          (h (window-pixel-height w)))
     (with-selected-window w (goto-char (point-min)) (forward-line 40) (recenter 0))
     (let ((start (window-start w)) (pt (window-point w)))
       (describe-function 'car)
       (with-selected-window (selected-window)    ; shown elsewhere meanwhile, at its top
         (set-window-buffer (selected-window) "*drgnx-results*")
         (set-window-start (selected-window) 1))
       (switch-to-buffer "*scratch*")
       (should (eq (drgnx-wb-area-window 'panel) w))
       (should (= h (window-pixel-height w)))
       (should (eq (drgnx-wb-area-show 'panel 'results) w))
       (should (eq (window-buffer w) (get-buffer "*drgnx-results*")))
       (should (= start (window-start w)))
       (should (= pt (window-point w)))))))

(ert-deftest drgnx-area/size-kept-over-ten-cycles ()
  (drgnx-area-test--with
   (drgnx-wb-define-tab 'right 'notes :title "Notes")
   (let ((h (window-pixel-height (drgnx-wb-area-show 'panel 'output)))
         (wd (window-pixel-width (drgnx-wb-area-show 'right 'notes))))
     (dotimes (_ 10)
       (drgnx-wb-area-toggle 'panel) (drgnx-wb-area-toggle 'panel)
       (drgnx-wb-area-toggle 'right) (drgnx-wb-area-toggle 'right))
     (drgnx-wb-area-show 'panel 'help)
     (should (= h (window-pixel-height (drgnx-wb-area-window 'panel))))
     (should (= wd (window-pixel-width (drgnx-wb-area-window 'right)))))))

(ert-deftest drgnx-area/killing-the-shown-buffer-shows-the-placeholder ()
  (drgnx-area-test--with
   (describe-function 'car)
   (let ((w (drgnx-wb-area-window 'panel)) (file (find-file-noselect (make-temp-file "drgnx-area"))))
     (kill-buffer "*Help*")
     (should (window-live-p w))
     (should (eq (drgnx-wb-area-window 'panel) w))
     (should (string-prefix-p " *drgnx " (buffer-name (window-buffer w))))
     (should-not (eq (window-buffer w) file))
     (kill-buffer file))))

(ert-deftest drgnx-area/c-x-1-in-the-panel-keeps-the-layout ()
  (drgnx-area-test--with
   (let ((editor (selected-window)) (w (drgnx-wb-area-show 'panel 'output)))
     (select-window w)
     (ignore-errors (delete-other-windows))
     (should (window-live-p editor))
     (should (window-live-p w)))))

(ert-deftest drgnx-area/the-tab-row-is-in-the-window-parameter ()
  (drgnx-area-test--with
   (let ((w (drgnx-wb-area-show 'panel 'output)))
     (should (window-parameter w 'header-line-format))
     (with-current-buffer (window-buffer w) (setq-local header-line-format nil))
     (should (> (window-header-line-height w) 0)))))

(ert-deftest drgnx-area/right-dock-shows-a-routed-tab ()
  (drgnx-area-test--with
   (drgnx-wb-define-tab 'right 'notes :title "Notes")
   (drgnx-wb-place "\\`\\*notes\\*\\'" 'right :tab 'notes)
   (let ((editor (selected-window)))
     (display-buffer (get-buffer-create "*notes*"))
     (should (eq (window-buffer (drgnx-wb-area-window 'right)) (get-buffer "*notes*")))
     (should (eq (selected-window) editor))
     (let ((wd (window-pixel-width (drgnx-wb-area-window 'right))))
       (drgnx-wb-area-toggle 'right)
       (should-not (drgnx-wb-area-window 'right))
       (drgnx-wb-area-toggle 'right)
       (should (eq (window-buffer (drgnx-wb-area-window 'right)) (get-buffer "*notes*")))
       (should (= wd (window-pixel-width (drgnx-wb-area-window 'right))))))))

(ert-deftest drgnx-area/tabs-keep-their-order ()
  (drgnx-area-test--with
   (let ((row (window-parameter (drgnx-wb-area-show 'panel 'output) 'header-line-format)))
     (should (string-match-p "Problems +Output +Results +Terminal +Help" (substring-no-properties row))))))

(ert-deftest drgnx-area/the-panel-is-under-the-editor-only ()
  (drgnx-area-test--with
   (let ((drgnx-wb--sections nil))
     (drgnx-wb-define-section 'top :slot 0 :title "TOP" :buffer (lambda () (get-buffer-create "*drgnx-test-top*")))
     (drgnx-wb-show-sidebar)
     (unwind-protect
         (let ((panel (drgnx-wb-area-show 'panel 'output)) (dock (drgnx-wb-section-window 'top)))
           ;; The dock runs the full height; the panel starts right of it.
           (should (>= (nth 0 (window-pixel-edges panel)) (nth 2 (window-pixel-edges dock)))))
       (drgnx-wb-hide-sidebar)
       (kill-buffer "*drgnx-test-top*")))))

(ert-deftest drgnx-area/deleting-the-area-window-hides-the-area ()
  ;; C-x 0 in the panel, or a package deleting "its" window that is the panel: the panel hides,
  ;; keeping its size and tabs.
  (drgnx-area-test--with
   (let* ((w (drgnx-wb-area-show 'panel 'output))
          (h (progn (window-resize w 3) (window-pixel-height w))))    ; the user dragged it taller
     (delete-window w)
     (should-not (drgnx-wb-area-window 'panel))
     (should (= h (window-pixel-height (drgnx-wb-area-show 'panel))))
     (should (eq (drgnx-wb-area-tab 'panel) 'output)))))

(ert-deftest drgnx-area/more-help-and-output-buffers ()
  (drgnx-area-test--with
   (pcase-dolist (`(,name ,tab) '(("*Shortdoc string*" help) ("*Finder*" help) ("*Holidays*" help)
                                  ("*timer-list*" output) ("*Process List*" output)))
     (let ((b (get-buffer-create name)))
       (display-buffer b)
       (should (eq (window-buffer (drgnx-wb-area-window 'panel)) b))
       (should (eq (drgnx-wb-area-tab 'panel) tab))
       (kill-buffer b)))
   (should-not drgnx-wb-unrouted)))

(ert-deftest drgnx-area/balancing-touches-only-the-editors ()
  ;; finder (and others) call `balance-windows' on the whole frame: docks and panel keep their size.
  (drgnx-area-test--with
   (drgnx-wb-define-tab 'right 'notes :title "Notes")
   (let* ((drgnx-wb--sections nil)
          (_ (drgnx-wb-define-section 'top :slot 0 :title "TOP" :buffer (lambda () (get-buffer-create "*drgnx-test-top*"))))
          (_ (drgnx-wb-show-sidebar))
          (panel (drgnx-wb-area-show 'panel 'output)) (right (drgnx-wb-area-show 'right 'notes))
          (dock (drgnx-wb-section-window 'top))
          (sizes (list (window-pixel-width dock) (window-pixel-height panel) (window-pixel-width right))))
     (unwind-protect
         (progn
           (balance-windows)
           (should (equal sizes (list (window-pixel-width dock) (window-pixel-height panel) (window-pixel-width right)))))
       (drgnx-wb-hide-sidebar)
       (kill-buffer "*drgnx-test-top*")))))
