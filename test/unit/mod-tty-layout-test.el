;;; mod-tty-layout-test.el --- batch tests: ui/terminal-layout — the workbench's docks in a small terminal -*- lexical-binding: t -*-
;; Batch Emacs has one window and no terminal to resize: the frame's size and the docks are stubbed here; the
;; tty tier (test/tty/layout-test.el) runs the real thing.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-tty-layout" drgnx-dir) nil t)

(defmacro drgnx-tty-layout-test--frame (size &rest body)
  "BODY with the selected frame SIZE (COLUMNS . LINES), fresh frame parameters, the module on, and stand-in docks:
`shown' lists the docks showing (`dock', `panel', `right'), `now' their sizes (a dock shows at its size parameter),
`calls' the show calls in order.  A dock shows when `room' is non-nil; `room' set to nil makes a show leave a
half-built dock (3 wide) and signal, as `split-window' does in a small frame."
  (declare (indent 1))
  `(let ((size ,size) (shown nil) (now nil) (calls nil) (room t) (frame (selected-frame)) (drgnx-tty-layout--active t))
     (dolist (p '(drgnx-tty-layout-size drgnx-tty-layout-withheld drgnx-tty-layout-owned drgnx-tty-layout-set
                                        drgnx-chrome-breadcrumb drgnx-wb-dock-px drgnx-wb-right-px drgnx-wb-panel-px))
       (set-frame-parameter frame p nil))
     (cl-flet ((open (key param)
                 (push key calls)
                 (push key shown)
                 (setf (alist-get key now) (if room (frame-parameter nil param) 3))
                 (unless room (error "Window too small")))
               (close (key param)
                 ;; hiding keeps the size the dock had, as the real hide does
                 (set-frame-parameter nil param (alist-get key now))
                 (setq shown (remq key shown) now (assq-delete-all key now))))
       (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) (car size)))
                 ((symbol-function 'frame-height) (lambda (&optional _) (cdr size)))
                 ((symbol-function 'drgnx-wb-sidebar-showing-p) (lambda (&optional _) (and (memq 'dock shown) t)))
                 ((symbol-function 'drgnx-wb-area-window) (lambda (area &optional _) (and (memq area shown) (selected-window))))
                 ((symbol-function 'drgnx-wb--dock-windows) (lambda (&optional _) nil))
                 ((symbol-function 'drgnx-wb-show-sidebar) (lambda () (open 'dock 'drgnx-wb-dock-px)))
                 ((symbol-function 'drgnx-wb-hide-sidebar) (lambda () (close 'dock 'drgnx-wb-dock-px)))
                 ((symbol-function 'drgnx-wb-area-show)
                  (lambda (area &rest _) (open area (if (eq area 'panel) 'drgnx-wb-panel-px 'drgnx-wb-right-px))))
                 ((symbol-function 'drgnx-wb-area-hide)
                  (lambda (area) (close area (if (eq area 'panel) 'drgnx-wb-panel-px 'drgnx-wb-right-px))))
                 ((symbol-function 'drgnx-tty-layout--size-of) (lambda (key) (alist-get key now)))
                 ((symbol-function 'drgnx-tty-layout--resize-dock)
                  (lambda (key size) (when (alist-get key now) (setf (alist-get key now) size)))))
         ,@body))))

(ert-deftest drgnx-tty-layout/docks-are-fractions-of-the-terminal ()
  (should (equal (drgnx-tty-layout-sizes 160 50) '(:dock 40 :right 48 :panel 15)))
  ;; a quarter of the columns, at least 20; 30%, at least 24; 30% of the lines, at least 6
  (should (equal (drgnx-tty-layout-sizes 80 24) '(:dock 20 :right 24 :panel 7)))
  (should (equal (drgnx-tty-layout-sizes 50 12) '(:dock 20 :right 24 :panel 6)))
  (should (equal (drgnx-tty-layout-sizes 200 100) '(:dock 50 :right 60 :panel 30))))

(ert-deftest drgnx-tty-layout/the-frame-parameters-hold-the-sizes ()
  (drgnx-tty-layout-test--frame '(160 . 50)
    (drgnx-tty-layout-apply (selected-frame) t)
    (should (equal (mapcar (lambda (p) (frame-parameter nil p)) '(drgnx-wb-dock-px drgnx-wb-right-px drgnx-wb-panel-px))
                   '(40 48 15)))))

(ert-deftest drgnx-tty-layout/opening-shows-by-size ()
  (drgnx-tty-layout-test--frame '(120 . 40)
    (drgnx-tty-layout-apply (selected-frame) t)
    (should (equal (sort (copy-sequence shown) #'string<) '(dock panel))))
  ;; wide enough for the sidebar, too few lines for the panel
  (drgnx-tty-layout-test--frame '(120 . 29)
    (drgnx-tty-layout-apply (selected-frame) t)
    (should (equal shown '(dock))))
  ;; the other way round
  (drgnx-tty-layout-test--frame '(119 . 40)
    (drgnx-tty-layout-apply (selected-frame) t)
    (should (equal shown '(panel))))
  ;; the thresholds are settings
  (drgnx-tty-layout-test--frame '(100 . 24)
    (let ((drgnx-tty-layout-columns 100) (drgnx-tty-layout-lines 24))
      (drgnx-tty-layout-apply (selected-frame) t)
      (should (equal (sort (copy-sequence shown) #'string<) '(dock panel))))))

(ert-deftest drgnx-tty-layout/a-tiny-terminal-shows-nothing-and-signals-nothing ()
  (dolist (size '((39 . 40) (120 . 11) (30 . 8) (1 . 1)))
    (drgnx-tty-layout-test--frame size
      (should-not (condition-case err (progn (drgnx-tty-layout-apply (selected-frame) t) nil) (error err)))
      (should-not calls)
      (should-not (frame-parameter nil 'drgnx-wb-dock-px))))
  ;; room by the numbers, none in fact: the failing split never reaches the caller, nothing stays shown
  (drgnx-tty-layout-test--frame '(120 . 40)
    (setq room nil)
    (should-not (condition-case err (progn (drgnx-tty-layout-apply (selected-frame) t) nil) (error err)))
    ;; a half-built dock is taken down, and the size it was meant to have stays for the next try
    (should-not shown)
    (should (= (frame-parameter nil 'drgnx-wb-dock-px) 30))
    (should (= (frame-parameter nil 'drgnx-wb-panel-px) 12))
    ;; and the dock is tried again when the size changes
    (setq room t size '(130 . 40))
    (drgnx-tty-layout-apply (selected-frame))
    (should (equal (sort (copy-sequence shown) #'string<) '(dock panel)))))

(ert-deftest drgnx-tty-layout/growing-shows-what-the-size-hid ()
  (drgnx-tty-layout-test--frame '(80 . 24)
    (drgnx-tty-layout-apply (selected-frame) t)
    (should-not shown)
    (setq size '(120 . 24))
    (drgnx-tty-layout-apply (selected-frame))
    (should (equal shown '(dock)))
    (setq size '(120 . 40))
    (drgnx-tty-layout-apply (selected-frame))
    (should (equal (sort (copy-sequence shown) #'string<) '(dock panel)))
    ;; shown once: a later resize does not call again
    (setq calls nil size '(130 . 45))
    (drgnx-tty-layout-apply (selected-frame))
    (should-not calls)))

(ert-deftest drgnx-tty-layout/shrinking-never-closes-a-dock ()
  (drgnx-tty-layout-test--frame '(120 . 40)
    (drgnx-tty-layout-apply (selected-frame) t)
    (setq size '(80 . 24))
    (drgnx-tty-layout-apply (selected-frame))
    (should (equal (sort (copy-sequence shown) #'string<) '(dock panel)))
    (setq size '(30 . 8))
    (drgnx-tty-layout-apply (selected-frame))
    (should (equal (sort (copy-sequence shown) #'string<) '(dock panel)))))

(ert-deftest drgnx-tty-layout/a-dock-the-user-opened-at-a-small-size-stays ()
  (drgnx-tty-layout-test--frame '(80 . 24)
    (drgnx-tty-layout-apply (selected-frame) t)
    (drgnx-tty-layout--install)
    (unwind-protect
        (progn (drgnx-wb-show-sidebar)               ; the user's toggle
               (setq size '(70 . 20))
               (drgnx-tty-layout-apply (selected-frame))
               (should (equal shown '(dock))))
      (drgnx-tty-layout--uninstall))))

(ert-deftest drgnx-tty-layout/growing-never-reopens-what-the-user-closed ()
  (drgnx-tty-layout-test--frame '(80 . 24)
    (drgnx-tty-layout-apply (selected-frame) t)
    (drgnx-tty-layout--install)
    (unwind-protect
        (progn (drgnx-wb-show-sidebar)               ; the user opens the sidebar …
               (drgnx-wb-hide-sidebar)               ; … and closes it again
               (setq size '(120 . 40))
               (drgnx-tty-layout-apply (selected-frame))
               ;; the panel, which the user did not touch, comes; the sidebar does not
               (should (equal shown '(panel))))
      (drgnx-tty-layout--uninstall))
    ;; the layout's own calls are no toggles
    (drgnx-tty-layout-test--frame '(80 . 24)
      (drgnx-tty-layout-apply (selected-frame) t)
      (drgnx-tty-layout--install)
      (unwind-protect
          (progn (setq size '(120 . 40))
                 (drgnx-tty-layout-apply (selected-frame))
                 (should (equal (sort (copy-sequence shown) #'string<) '(dock panel))))
        (drgnx-tty-layout--uninstall)))))

(ert-deftest drgnx-tty-layout/opening-happens-once-per-frame ()
  (drgnx-tty-layout-test--frame '(120 . 40)
    (drgnx-tty-layout-apply (selected-frame) t)
    (drgnx-wb-hide-sidebar)                           ; the user closes it (no advice here: state only)
    (set-frame-parameter nil 'drgnx-tty-layout-withheld nil)
    (setq calls nil)
    ;; a client reusing the frame runs the opening again: it is no new frame
    (drgnx-tty-layout-apply (selected-frame) t)
    (should-not calls)))

(ert-deftest drgnx-tty-layout/an-editor-frame-is-left-alone ()
  (drgnx-tty-layout-test--frame '(120 . 40)
    (set-frame-parameter nil 'drgnx-tty-editor-only t)
    (unwind-protect
        (progn (drgnx-tty-layout-apply (selected-frame) t)
               (should-not calls)
               (should-not (frame-parameter nil 'drgnx-wb-dock-px)))
      (set-frame-parameter nil 'drgnx-tty-editor-only nil))))

(ert-deftest drgnx-tty-layout/sets-no-breadcrumb-below-30-lines ()
  (drgnx-tty-layout-test--frame '(80 . 24)
    (drgnx-tty-layout-apply (selected-frame) t)
    (should (eq (frame-parameter nil 'drgnx-chrome-breadcrumb) 'off))
    (setq size '(120 . 29))
    (drgnx-tty-layout-apply (selected-frame))
    (should (eq (frame-parameter nil 'drgnx-chrome-breadcrumb) 'off))
    (setq size '(120 . 30))
    (drgnx-tty-layout-apply (selected-frame))
    (should-not (frame-parameter nil 'drgnx-chrome-breadcrumb)))
  ;; a tiny terminal too: the breadcrumb has no room there either
  (drgnx-tty-layout-test--frame '(30 . 8)
    (drgnx-tty-layout-apply (selected-frame) t)
    (should (eq (frame-parameter nil 'drgnx-chrome-breadcrumb) 'off))))

(ert-deftest drgnx-tty-layout/a-resize-with-the-same-size-does-nothing ()
  (drgnx-tty-layout-test--frame '(120 . 40)
    (drgnx-tty-layout-apply (selected-frame) t)
    (set-frame-parameter nil 'drgnx-wb-dock-px 99)    ; a drag the user made
    (drgnx-tty-layout-apply (selected-frame))
    (should (= (frame-parameter nil 'drgnx-wb-dock-px) 99))
    (setq size '(100 . 40))
    (drgnx-tty-layout-apply (selected-frame))
    (should (= (frame-parameter nil 'drgnx-wb-dock-px) 25))))

(ert-deftest drgnx-tty-layout/the-size-change-hook-never-signals ()
  (drgnx-tty-layout-test--frame '(120 . 40)
    (drgnx-tty-layout-apply (selected-frame) t)
    (setq size '(100 . 40))
    (cl-letf (((symbol-function 'drgnx-tty-layout-apply) (lambda (&rest _) (error "Boom"))))
      (let ((drgnx-hooks-problems nil))
        (drgnx-tty-layout--resized (selected-frame))
        (should (string-match-p "ui/terminal-layout.*Boom" (car drgnx-hooks-problems)))))))

(ert-deftest drgnx-tty-layout/the-module-hooks-itself-in ()
  (funcall (plist-get (alist-get 'ui/terminal-layout drgnx-modules--table) :setup))
  (unwind-protect
      (progn (should (memq #'drgnx-tty-layout--resized window-size-change-functions))
             (should (memq #'drgnx-tty-layout--startup window-setup-hook)))
    (drgnx-tty-layout--uninstall)))

(ert-deftest drgnx-tty-layout/the-module-off-lays-nothing-out ()
  ;; module files load even when the module is disabled (only its setup is skipped): without the setup, no layout
  (drgnx-tty-layout-test--frame '(120 . 40)
    (setq drgnx-tty-layout--active nil)
    (should-not (drgnx-tty-layout-apply (selected-frame) t))
    (should-not calls)
    (should-not (frame-parameter nil 'drgnx-wb-dock-px))
    (should-not (frame-parameter nil 'drgnx-chrome-breadcrumb))
    (should-not (frame-parameter nil 'drgnx-tty-layout-size))))

(ert-deftest drgnx-tty-layout/the-setup-turns-the-layout-on-and-its-removal-off ()
  (let ((drgnx-tty-layout--active nil))
    (funcall (plist-get (alist-get 'ui/terminal-layout drgnx-modules--table) :setup))
    (unwind-protect (should drgnx-tty-layout--active)
      (drgnx-tty-layout--uninstall))
    (should-not drgnx-tty-layout--active)))

(ert-deftest drgnx-tty-layout/a-size-you-dragged-a-dock-to-survives-a-resize ()
  (drgnx-tty-layout-test--frame '(120 . 40)
    (drgnx-tty-layout-apply (selected-frame) t)
    (should (equal (list (alist-get 'dock now) (alist-get 'panel now)) '(30 12)))
    ;; the user drags the sidebar's divider: the size changes, the terminal's does not
    (setf (alist-get 'dock now) 50)
    (drgnx-tty-layout-apply (selected-frame))
    ;; the terminal resizes: the panel follows the terminal, the sidebar keeps the dragged width
    (setq size '(100 . 50))
    (setf (alist-get 'dock now) 36)                   ; Emacs itself narrowed it with the frame
    (drgnx-tty-layout-apply (selected-frame))
    (should (= (alist-get 'dock now) 50))
    (should (= (alist-get 'panel now) 15))
    (should-not (= (frame-parameter nil 'drgnx-wb-dock-px) 25))
    ;; hidden, it still has the dragged width for the next show, not the layout's fraction
    (drgnx-wb-hide-sidebar)
    (setq size '(90 . 50))
    (drgnx-tty-layout-apply (selected-frame))
    (should (= (frame-parameter nil 'drgnx-wb-dock-px) 50))))

(ert-deftest drgnx-tty-layout/a-dock-you-did-not-drag-follows-every-resize ()
  (drgnx-tty-layout-test--frame '(120 . 40)
    (drgnx-tty-layout-apply (selected-frame) t)
    (drgnx-tty-layout-apply (selected-frame))         ; a size change that is none: nothing to notice
    (setq size '(100 . 40))
    (drgnx-tty-layout-apply (selected-frame))
    (should (= (alist-get 'dock now) 25))
    (setq size '(160 . 50))
    (drgnx-tty-layout-apply (selected-frame))
    (should (= (alist-get 'dock now) 40))
    (should (= (alist-get 'panel now) 15))))

(ert-deftest drgnx-tty-layout/a-tiny-terminal-is-no-drag ()
  ;; Emacs shrinks the docks in a tiny frame: that is no size the user chose
  (drgnx-tty-layout-test--frame '(120 . 40)
    (drgnx-tty-layout-apply (selected-frame) t)
    (setq size '(30 . 8))
    (drgnx-tty-layout-apply (selected-frame))
    (setf (alist-get 'dock now) 8)
    (drgnx-tty-layout-apply (selected-frame))
    (setq size '(120 . 40))
    (drgnx-tty-layout-apply (selected-frame))
    (should (= (alist-get 'dock now) 30))))

(ert-deftest drgnx-tty-layout/the-breadcrumb-parameter-is-set-only-when-it-changes ()
  (let (sets)
    (drgnx-tty-layout-test--frame '(80 . 24)
      (advice-add 'set-frame-parameter :before
                  (lambda (_frame param &rest _) (when (eq param 'drgnx-chrome-breadcrumb) (push param sets)))
                  '((name . layout-test)))
      (unwind-protect
          (progn (drgnx-tty-layout-apply (selected-frame) t)
                 (should (= (length sets) 1))
                 (setq size '(100 . 20))
                 (drgnx-tty-layout-apply (selected-frame))      ; still under 30 lines
                 (should (= (length sets) 1))
                 (setq size '(100 . 40))
                 (drgnx-tty-layout-apply (selected-frame))      ; it changes
                 (should (= (length sets) 2)))
        (advice-remove 'set-frame-parameter 'layout-test)))))
