;;; wb-area-test.el --- batch tests: the bottom panel and the right dock (tabbed areas) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-area)

(defmacro drgnx-area-test--with (&rest body)
  "BODY with rules on, one editor window, the panel and right dock hidden, fresh area state."
  `(drgnx-test-with-state
     (let ((drgnx-wb-unrouted nil)
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
         (dolist (b '("*Help*" "*drgnx-results*" "*notes*")) (when (get-buffer b) (kill-buffer b)))))))

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
   (let* ((name (make-temp-file "drgnx-area"))
          (w (drgnx-wb-area-window 'panel)) (file (find-file-noselect name)))
     (unwind-protect
         (progn
           (kill-buffer "*Help*")
           (should (window-live-p w))
           (should (eq (drgnx-wb-area-window 'panel) w))
           (should (string-prefix-p " *drgnx " (buffer-name (window-buffer w))))
           (should-not (eq (window-buffer w) file)))
       (kill-buffer file)
       (delete-file name)))))

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

(ert-deftest drgnx-area/the-callers-body-function-runs ()
  ;; C1: Emacs fills *Completions*, *Process List* … through `body-function'.
  (drgnx-area-test--with
   (let ((b (get-buffer-create "*Help*")))
     (display-buffer b `(nil (body-function . ,(lambda (w) (with-current-buffer (window-buffer w) (insert "filled"))))))
     (should (equal (with-current-buffer b (buffer-string)) "filled")))))

(ert-deftest drgnx-area/the-window-stays-dedicated ()
  ;; I4: `set-window-buffer' drops weak dedication; nothing else may land in the panel.
  (drgnx-area-test--with
   (let ((w (drgnx-wb-area-show 'panel 'output)))
     (describe-function 'car)
     (should (eq (window-dedicated-p w) 'drgnx))
     (should-not (eq (display-buffer (get-buffer-create " *internal*") '(display-buffer-use-some-window)) w))
     (kill-buffer " *internal*"))))

(ert-deftest drgnx-area/q-in-the-panel-never-focuses-a-stale-window ()
  ;; I9 (review): the area window must not keep the quit-restore of its creation.
  (drgnx-area-test--with
   (should-not (window-parameter (drgnx-wb-area-show 'panel 'output) 'quit-restore))))

(ert-deftest drgnx-area/terminals-by-name ()
  ;; I7: shell and eshell show their buffer before setting its mode.
  (drgnx-area-test--with
   (dolist (name '("*shell*" "*eshell*" "*ielm*" "*terminal*" "*ansi-term*" "*vterm*"))
     (let ((b (get-buffer-create name)))
       (display-buffer b)
       (should (eq (window-buffer (drgnx-wb-area-window 'panel)) b))
       (kill-buffer b)))
   (should-not drgnx-wb-unrouted)))

(ert-deftest drgnx-area/a-package-side-window-never-takes-the-panel ()
  ;; I6: a direct `display-buffer-in-side-window' on the panel's side and slot.
  (drgnx-area-test--with
   (let* ((panel (drgnx-wb-area-show 'panel 'output)) (b (get-buffer-create "*pkg*"))
          (w (display-buffer-in-side-window b '((side . bottom)))))
     (should-not (eq w panel))
     (should (eq (window-buffer panel) (drgnx-area--placeholder 'panel 'output)))
     (delete-window w)
     (kill-buffer b))))

(ert-deftest drgnx-area/faces-are-in-the-drgnx-group ()
  ;; I10: Emacs 31 warns about a defface without a group (the build must have 0 warnings).
  (require 'drgnx-explorer) (require 'drgnx-buffers) (require 'drgnx-git)
  (dolist (f (face-list))
    (when (string-prefix-p "drgnx-" (symbol-name f))
      (should (assq f (get 'drgnx 'custom-group))))))

(ert-deftest drgnx-area/q-in-a-panel-buffer-hides-the-panel-and-returns-to-the-editor ()
  ;; DEFERRED M3c-6, ruled: `q' (quit-window) in a panel buffer hides the panel (size and tabs kept)
  ;; and focus goes back to the editor, as Escape does in VS Code.
  (drgnx-area-test--with
   (let ((editor (selected-window)))
     (with-current-buffer (get-buffer-create "*Help*") (help-mode))
     (display-buffer "*Help*")
     (let ((panel (drgnx-wb-area-window 'panel)))
       (should (window-live-p panel))
       (select-window panel)
       (call-interactively (key-binding "q"))
       (should-not (drgnx-wb-area-window 'panel))
       (should (eq (selected-window) editor))
       (should (eq (drgnx-wb-area-tab 'panel) 'help))        ; the tab is kept
       (should (window-live-p editor))))))

(ert-deftest drgnx-area/a-tab-switch-keeps-the-preserved-size ()
  ;; Emacs preserves a size only for the buffer it was set with: a tab switch must set it again, or a frame
  ;; resize (a tiling WM's) shares the change out to the area too (I11).
  (drgnx-area-test--with
   (drgnx-wb-define-tab 'right 'notes :title "Notes")
   (let ((p (drgnx-wb-area-show 'panel 'results (drgnx-area-test--results)))
         (r (drgnx-wb-area-show 'right 'notes (get-buffer-create "*notes*"))))
     (should (window--preserve-size p nil))
     (should (window--preserve-size r t))
     (describe-function 'car)                                   ; the panel's Help tab
     (should (eq (window-buffer p) (get-buffer "*Help*")))
     (should (window--preserve-size p nil))
     (drgnx-wb-area-show 'right 'notes (get-buffer-create "*drgnx-results*"))
     (should (window--preserve-size r t))
     (kill-buffer "*drgnx-results*")                            ; the tab's placeholder, not through a tab switch
     (should-not (eq (window-buffer r) (get-buffer "*drgnx-results*")))
     (should (window--preserve-size r t)))))

;;;; M12f A7: the ✕

(defun drgnx-area-test--click-event (window string index)
  "A mouse-1 click on character INDEX of STRING, which WINDOW shows in its header line."
  (list 'mouse-1 (list window 'header-line '(0 . 0) 0 (cons string index))))

(ert-deftest drgnx-area/tab-row-has-a-close-button ()
  (drgnx-area-test--with
   (let* ((w (drgnx-wb-area-show 'panel 'results (drgnx-area-test--results)))
          (row (window-parameter w 'header-line-format)) (i (1- (length row)))
          (h (window-pixel-height w)))
     (should (string-suffix-p (concat " " (drgnx-wb-close-glyph)) row))   ; ends with the ✕
     (should (equal (get-text-property i 'help-echo row) "Close (Esc, q)"))
     (should (eq (get-text-property i 'mouse-face row) 'highlight))
     (should (eq (lookup-key (get-text-property i 'local-map row) [header-line mouse-1]) #'drgnx-area--close-click))
     ;; a click hides the area, its size kept
     (funcall (lookup-key (get-text-property i 'local-map row) [header-line mouse-1])
              (drgnx-area-test--click-event w row i))
     (should-not (drgnx-wb-area-window 'panel))
     (should (= h (window-pixel-height (drgnx-wb-area-show 'panel)))))))      ; and it comes back as tall

(ert-deftest drgnx-area/the-close-button-is-built-with-the-row-not-while-drawing ()
  ;; the row is a plain string in a window parameter: nothing to evaluate or propertize on redisplay
  (drgnx-area-test--with
   (let ((row (window-parameter (drgnx-wb-area-show 'panel 'help) 'header-line-format)))
     (should (stringp row))
     (should (eq (get-text-property (1- (length row)) 'drgnx-area row) 'panel)))))
