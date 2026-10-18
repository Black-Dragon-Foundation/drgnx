;;; wb-state-intent-test.el --- batch tests: intent — what was asked for a frame's panes, and by whom -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-state-intent)
(require 'drgnx-panes)
(require 'drgnx-persist)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)

(defconst drgnx-state-intent-test--parameters
  '(drgnx-wb-dock-px drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-areas drgnx-wb-view drgnx-intent-by
                     drgnx-layouts-current drgnx-layouts-previous drgnx-layouts-zen-return)
  "The frame parameters intent reads or writes: nil for each test, put back after.")

(defun drgnx-state-intent-test--call (fn)
  (let ((saved (mapcar (lambda (p) (cons p (frame-parameter nil p))) drgnx-state-intent-test--parameters)))
    (unwind-protect
        (progn (dolist (p drgnx-state-intent-test--parameters) (set-frame-parameter nil p nil))
               (drgnx-test-with-state (funcall fn)))
      (pcase-dolist (`(,p . ,v) saved) (set-frame-parameter nil p v)))))

(defmacro drgnx-state-intent-test--with (&rest body)
  "BODY with a fresh store and the intent parameters of the selected frame cleared, put back after."
  (declare (indent 0))
  `(drgnx-state-intent-test--call (lambda () ,@body)))

(defmacro drgnx-state-intent-test--with-panel (&rest body)
  "BODY with a fresh store, intent, pane kinds and areas; kind `st-term' lives in the panel."
  (declare (indent 0))
  `(drgnx-state-intent-test--with
     (let ((drgnx-pane--kinds nil) (drgnx-pane-backend 'areas) (drgnx-wb--sections nil)
           (drgnx-wb--areas (copy-tree drgnx-wb--areas)) (drgnx-rules--table (copy-sequence drgnx-rules--table))
           (display-buffer-alist nil))
       (delete-other-windows)
       (drgnx-pane-define-kind 'st-term :home 'bottom)
       (unwind-protect (progn ,@body)
         (drgnx-wb-area-hide 'panel)
         (delete-other-windows)))))

;;;; Homes: today's parameters

(ert-deftest drgnx-state-intent/reads-todays-parameters ()
  (drgnx-state-intent-test--with
    (set-frame-parameter nil 'drgnx-wb-dock-px 210)
    (set-frame-parameter nil 'drgnx-wb-panel-px 120)
    (set-frame-parameter nil 'drgnx-wb-right-px 300)
    (set-frame-parameter nil 'drgnx-wb-areas '((panel :tab help) (right :tab chat)))
    (set-frame-parameter nil 'drgnx-wb-view 'search)
    (set-frame-parameter nil 'drgnx-layouts-current 'zen)
    (set-frame-parameter nil 'drgnx-layouts-previous 'code)
    (set-frame-parameter nil 'drgnx-layouts-zen-return 'back)
    (should (equal '(:px 210 :by nil) (drgnx-state-intent nil :sizes 'left)))
    (should (equal '(:px 120 :by nil) (drgnx-state-intent nil :sizes 'bottom)))
    (should (equal '(:px 120 :by nil) (drgnx-state-intent nil :sizes 'panel)))
    (should (equal '(:px 300 :by nil) (drgnx-state-intent (selected-frame) :sizes 'right)))
    (should (equal '((left :px 210 :by nil) (bottom :px 120 :by nil) (right :px 300 :by nil))
                   (drgnx-state-intent nil :sizes)))
    (should (eq 'help (drgnx-state-intent nil :front 'panel)))
    (should (equal '((panel . help) (right . chat)) (drgnx-state-intent nil :front)))
    (should (eq 'search (drgnx-state-intent nil :view)))
    (should (eq 'zen (drgnx-state-intent nil :layout)))
    (should (eq 'code (drgnx-state-intent nil :previous)))
    (should (eq 'back (drgnx-state-intent nil :zen-return)))
    (should-not (drgnx-state-intent nil :places))
    (should-not (drgnx-state-intent nil :arrangement))
    (should-not (drgnx-state-intent nil :sizes 'editor))
    ;; written through the accessor, read back from the same homes
    (should (drgnx-state-note-intent nil :sizes 'panel 140 :by 'user))
    (should (= 140 (frame-parameter nil 'drgnx-wb-panel-px)))
    (should (equal '(:px 140 :by user) (drgnx-state-intent nil :sizes 'bottom)))
    (should (drgnx-state-note-intent nil :front 'panel 'output :by 'user))
    (should (eq 'output (drgnx-wb-area-tab 'panel)))
    (should (drgnx-state-note-intent nil :view nil 'explorer :by 'user))
    (should (eq 'explorer (frame-parameter nil 'drgnx-wb-view)))
    (should-not (drgnx-state-note-intent nil :layout nil 'code :by 'user)) ; read-only until B10
    (should (eq 'zen (drgnx-state-intent nil :layout)))
    (should-error (drgnx-state-intent nil :nothing))
    (should-error (drgnx-state-note-intent nil :sizes 'left 100 :by 'someone))))

(ert-deftest drgnx-state-intent/nothing-stored-twice ()
  (drgnx-state-intent-test--with
    (drgnx-state-note-intent nil :sizes 'left 250 :by 'auto)
    (drgnx-state-note-intent nil :view nil 'search :by 'auto)
    (let ((before (drgnx-persist-state)))
      (should (drgnx-state-note-intent nil :sizes 'left 250 :by 'user))
      (should (drgnx-state-note-intent nil :view nil 'search :by 'user))
      (should (equal before (drgnx-persist-state))))
    (should (= 250 (frame-parameter nil 'drgnx-wb-dock-px)))
    ;; who asked holds symbols only: the value lives in today's parameter alone
    (let ((by (frame-parameter nil 'drgnx-intent-by)))
      (should by)
      (should (cl-every #'symbolp (flatten-tree by))))))

;;;; Who asked

(ert-deftest drgnx-state-intent/user-is-not-overwritten-by-auto-layout-other ()
  (drgnx-state-intent-test--with
    (should (drgnx-state-note-intent nil :sizes 'bottom 300 :by 'user))
    (dolist (by '(auto layout other teardown))
      (should-not (drgnx-state-note-intent nil :sizes 'bottom 100 :by by))
      (should (equal '(:px 300 :by user) (drgnx-state-intent nil :sizes 'bottom))))
    (should (drgnx-state-note-intent nil :sizes 'bottom 200 :by 'user))
    (should (equal '(:px 200 :by user) (drgnx-state-intent nil :sizes 'bottom)))
    ;; an `auto' size is replaced by anyone
    (should (drgnx-state-note-intent nil :sizes 'left 90 :by 'auto))
    (should (drgnx-state-note-intent nil :sizes 'left 80 :by 'layout))
    (should (equal '(:px 80 :by layout) (drgnx-state-intent nil :sizes 'left)))
    ;; with no BY, outside a command: `auto'
    (should-not (drgnx-state-note-intent nil :sizes 'bottom 50))
    (should (= 200 (frame-parameter nil 'drgnx-wb-panel-px)))))

(ert-deftest drgnx-state-intent/restore-replaces-and-counts-as-user ()
  (drgnx-state-intent-test--with
    (drgnx-state-note-intent nil :sizes 'right 300 :by 'user)
    (should (drgnx-state-note-intent nil :sizes 'right 250 :by 'restore))
    (should (equal '(:px 250 :by user) (drgnx-state-intent nil :sizes 'right)))
    (should-not (drgnx-state-note-intent nil :sizes 'right 100 :by 'auto))
    (should (= 250 (frame-parameter nil 'drgnx-wb-right-px)))))

(ert-deftest drgnx-state-intent/hide-notes-the-size-as-auto ()
  (drgnx-state-intent-test--with-panel
    (let ((w (drgnx-pane-show 'st-term)) (window-resize-pixelwise t))
      (window-resize w (- 8 (window-pixel-height w)) nil 'preserved t)
      (should (= 8 (window-pixel-height w)))
      (drgnx-pane-hide 'st-term :by 'user)
      (should (equal '(:px 8 :by auto) (drgnx-state-intent nil :sizes 'bottom))))
    ;; a size you chose survives a squeezed panel being hidden
    (should (drgnx-state-note-intent nil :sizes 'bottom 7 :by 'user))
    (let ((w (drgnx-pane-show 'st-term)) (window-resize-pixelwise t))
      (should (= 7 (window-pixel-height w)))
      (window-resize w (- 4 (window-pixel-height w)) nil 'preserved t)
      (should (= 4 (window-pixel-height w)))
      (drgnx-pane-hide 'st-term)
      (should (equal '(:px 7 :by user) (drgnx-state-intent nil :sizes 'bottom)))
      (should (= 7 (window-pixel-height (drgnx-pane-show 'st-term)))))))

(ert-deftest drgnx-state-intent/by-is-readable-data ()
  (drgnx-state-intent-test--with
    (drgnx-state-note-intent nil :sizes 'left 90 :by 'user)
    (drgnx-state-note-intent nil :front 'panel 'help :by 'auto)
    (drgnx-state-note-intent nil :view nil 'search :by 'layout)
    (let ((by (frame-parameter nil 'drgnx-intent-by)))
      (should (equal by (car (read-from-string (prin1-to-string by)))))
      (should (equal '(((:view) . layout) ((:front . panel) . auto) ((:sizes . left) . user)) by)))))

(ert-deftest drgnx-state-intent/capped-at-64 ()
  (drgnx-state-intent-test--with
    (dotimes (i 70)
      (drgnx-state-note-intent nil :front (intern (format "st-area-%d" i)) 'help :by 'auto))
    (let ((by (frame-parameter nil 'drgnx-intent-by)))
      (should (= 64 (length by)))
      (should (assoc '(:front . st-area-69) by))
      (should (assoc '(:front . st-area-6) by))
      (should-not (assoc '(:front . st-area-5) by)))
    ;; noting an entry again moves it to the front instead of adding one
    (drgnx-state-note-intent nil :front 'st-area-6 'help :by 'user)
    (let ((by (frame-parameter nil 'drgnx-intent-by)))
      (should (= 64 (length by)))
      (should (equal '((:front . st-area-6) . user) (car by))))))

;;;; A size you set by hand (M12c-3-1)

(defvar drgnx-state-intent-test--log nil "Events the recorder got, newest first.")

(defun drgnx-state-intent-test--record (data) (push data drgnx-state-intent-test--log))

(defun drgnx-state-intent-test--side (side role params size)
  "Show a side window on SIDE with the `drgnx-role' ROLE and window PARAMS, SIZE columns or lines."
  (display-buffer-in-side-window
   (get-buffer-create (format " *st-%s*" role))
   `((side . ,side) (slot . 0) (,(if (eq side 'left) 'window-width 'window-height) . ,size)
     (window-parameters . ((drgnx-role . ,role) ,@params)))))

(defmacro drgnx-state-intent-test--resizing (&rest body)
  "BODY with a fresh store, one plain window, the intent subscriber and a recorder on `pane-resized' (both
`now'), the selected frame's size parameters clear; the side windows deleted after."
  (declare (indent 0))
  `(drgnx-state-intent-test--with
     (setq drgnx-state-intent-test--log nil)
     (let ((ignore-window-parameters t))
       (delete-other-windows))
     (drgnx-state-subscribe 'pane-resized #'drgnx-state-intent--user-resized :lane 'now)
     (drgnx-state-subscribe 'pane-resized #'drgnx-state-intent-test--record :lane 'now)
     (unwind-protect (progn ,@body)
       (let ((ignore-window-parameters t))
         (dolist (w (window-list nil 'nomini))
           (when (window-parameter w 'window-side) (delete-window w)))
         (delete-other-windows)))))

(ert-deftest drgnx-state-intent/a-user-resize-becomes-intent ()
  (drgnx-state-intent-test--resizing
    (let* ((f (selected-frame))
           (dock (drgnx-state-intent-test--side 'left 'dock '((drgnx-section . explorer)) 20))
           (panel (drgnx-state-intent-test--side 'bottom 'panel nil 6)))
      (drgnx-state-sync f)
      (should-not (frame-parameter f 'drgnx-wb-dock-px))
      ;; a drag on the dock's divider
      (setq drgnx-state--in-command t)
      (let ((this-command 'mouse-drag-vertical-line))
        (window-resize dock 4 t)
        (drgnx-state-sync f))
      (should (= (window-pixel-width dock) (frame-parameter f 'drgnx-wb-dock-px)))
      (should (equal (list :px (window-pixel-width dock) :by 'user) (drgnx-state-intent f :sizes 'left)))
      (should (= (window-body-width dock t) (window-preserved-size dock t)))   ; the width is kept
      ;; the panel: `enlarge-window' is a resize of the user's; the height counts
      (let ((this-command 'enlarge-window))
        (window-resize panel 2)
        (drgnx-state-sync f))
      (should (equal (list :px (window-pixel-height panel) :by 'user) (drgnx-state-intent f :sizes 'bottom)))
      (should (= (window-body-height panel t) (window-preserved-size panel nil)))
      ;; nothing was asked for the right dock
      (should-not (drgnx-state-intent f :sizes 'right)))))

(ert-deftest drgnx-state-intent/a-popup-squeeze-is-not-intent ()
  (drgnx-state-intent-test--resizing
    (let* ((f (selected-frame))
           (panel (drgnx-state-intent-test--side 'bottom 'panel nil 8)))
      (drgnx-state-note-intent f :sizes 'bottom 99 :by 'user)
      (drgnx-state-sync f)
      ;; no command, no write: a window-manager resize, a popup squeezing the panel
      (window-resize panel -2)
      (drgnx-state-sync f)
      (should (cl-some (lambda (d) (eq (plist-get d :window) panel)) drgnx-state-intent-test--log))
      (dolist (d drgnx-state-intent-test--log) (should (eq 'other (plist-get d :cause))))
      (should (equal '(:px 99 :by user) (drgnx-state-intent f :sizes 'bottom)))
      (should-not (window-preserved-size panel nil))
      ;; nor is a command that is not a resize
      (setq drgnx-state--in-command t)
      (let ((this-command 'next-line))
        (window-resize panel 1)
        (drgnx-state-sync f))
      (should (equal '(:px 99 :by user) (drgnx-state-intent f :sizes 'bottom))))))

(ert-deftest drgnx-state-intent/a-write-labels-its-events ()
  (drgnx-state-intent-test--resizing
    (let* ((f (selected-frame))
           (dock (drgnx-state-intent-test--side 'left 'dock '((drgnx-section . explorer)) 20)))
      (drgnx-state-sync f)
      (setq drgnx-state--in-command t)
      ;; a layout's resize inside a user's command is still the layout's: :cause write, :by layout
      (let ((this-command 'mouse-drag-vertical-line))
        (drgnx-state-with-write (f 'layout) (window-resize dock 4 t))
        (drgnx-state-sync f))
      (should drgnx-state-intent-test--log)
      (dolist (d drgnx-state-intent-test--log)
        (should (eq 'write (plist-get d :cause)))
        (should (eq 'layout (plist-get d :by))))
      (should-not (frame-parameter f 'drgnx-wb-dock-px))
      (should-not (window-preserved-size dock t)))))

;;;; Unknown kinds and views

(ert-deftest drgnx-state-intent/an-unknown-view-is-kept-and-comes-back ()
  (drgnx-state-intent-test--with
    (let ((drgnx-wb--sections nil))
      (should (drgnx-state-note-intent nil :view nil 'st-gone :by 'restore))
      (should (eq 'st-gone (drgnx-state-intent nil :view)))
      (should (eq 'explorer (drgnx-wb-sidebar-view)))         ; nothing defines it: the dock shows the Explorer
      (drgnx-wb-define-section 'st-section :slot 0 :view 'st-gone :buffer (lambda () (get-buffer-create " *st-gone*")))
      (should (eq 'st-gone (drgnx-wb-sidebar-view)))          ; its module came back: so does the view
      (kill-buffer (get-buffer-create " *st-gone*")))))

;;; wb-state-intent-test.el ends here
