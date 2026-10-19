;;; wb-state-events-test.el --- batch tests: the workbench state store's events, lanes and causes -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-signal)
(require 'drgnx-panes)                                 ; `drgnx-pane--last': editor kinds
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)

;;;; Windows for the tests

(defun drgnx-state-events-test--clean ()
  "One plain window on the selected frame, without drgnx parameters; the test buffers killed."
  (let ((ignore-window-parameters t))
    (when-let* ((main (seq-find (lambda (w) (not (window-parameter w 'window-side))) (window-list nil 'nomini))))
      (select-window main))
    (dolist (w (window-list nil 'nomini))
      (when (and (window-live-p w) (window-parameter w 'window-side)) (delete-window w)))
    (delete-other-windows))
  (dolist (p '(drgnx-role drgnx-popup drgnx-section drgnx-layouts-pane))
    (set-window-parameter nil p nil))
  (dolist (p '(drgnx-wb-areas drgnx-frame-role drgnx-monitor))
    (set-frame-parameter nil p nil))
  (dolist (b (buffer-list))
    (when (string-prefix-p " *se-" (buffer-name b)) (kill-buffer b)))
  (switch-to-buffer "*scratch*"))

(defmacro drgnx-state-events-test--with (&rest body)
  "BODY with a fresh store and bus (`drgnx-test-with-state'), one plain window and an empty log."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-state
     (setq drgnx-state-events-test--log nil)
     (unwind-protect (progn (drgnx-state-events-test--clean) ,@body)
       (drgnx-state-events-test--clean))))

(defun drgnx-state-events-test--buffer (name)
  (get-buffer-create (format " *se-%s*" name)))

(defun drgnx-state-events-test--side (buffer side slot params &optional size)
  "Show BUFFER in a side window on SIDE at SLOT with window PARAMS; return the window."
  (display-buffer-in-side-window
   buffer `((side . ,side) (slot . ,slot)
            (,(if (memq side '(left right)) 'window-width 'window-height) . ,(or size 6))
            (window-parameters . ,params))))

(defun drgnx-state-events-test--panel ()
  "Show the panel (an area) with its front tab `terminal'; return its window."
  (set-frame-parameter nil 'drgnx-wb-areas '((panel :tab terminal)))
  (drgnx-state-events-test--side (drgnx-state-events-test--buffer "terminal") 'bottom 0 '((drgnx-role . panel)) 6))

(defun drgnx-state-events-test--dock (section)
  "Show a dock window with SECTION; return it."
  (drgnx-state-events-test--side (drgnx-state-events-test--buffer section) 'left 0
                                 `((drgnx-role . dock) (drgnx-section . ,section)) 20))

;;;; Listening

(defconst drgnx-state-events-test--events
  '(frame-added frame-kind frame-resized windows-changed groups-changed pane-hidden pane-shown pane-resized
                selected-changed editor-changed frame-removed)
  "Every event, in the order one observation emits them.")

(defvar drgnx-state-events-test--log nil "(EVENT . DATA) delivered, newest first.")

(defun drgnx-state-events-test--fn (event)
  "The recorder of EVENT: a named function (a lambda is refused)."
  (intern (format "drgnx-state-events-test--on-%s" event)))

(dolist (event drgnx-state-events-test--events)
  (let ((event event))
    (defalias (drgnx-state-events-test--fn event)
      (lambda (data) (push (cons event data) drgnx-state-events-test--log)))))

(defun drgnx-state-events-test--listen (&rest events)
  "Subscribe the recorder of each of EVENTS (all of them when none) on the `now' lane; clear the log."
  (dolist (e (or events drgnx-state-events-test--events))
    (drgnx-state-subscribe e (drgnx-state-events-test--fn e) :lane 'now))
  (setq drgnx-state-events-test--log nil))

(defun drgnx-state-events-test--take ()
  "The log, oldest first; cleared."
  (prog1 (reverse drgnx-state-events-test--log) (setq drgnx-state-events-test--log nil)))

(defun drgnx-state-events-test--of (event log)
  "The data of EVENT in LOG, in order."
  (delq nil (mapcar (lambda (e) (and (eq (car e) event) (cdr e))) log)))

;;;; One test per event

(ert-deftest drgnx-state-events/frame-added-on-first-observation ()
  (drgnx-state-events-test--with
    (drgnx-state-events-test--listen 'frame-added)
    (let ((f (selected-frame)))
      (drgnx-state-sync f)
      (should (equal (list (list :frame f :kind 'tty)) (drgnx-state-events-test--of 'frame-added (drgnx-state-events-test--take))))
      (drgnx-state-sync f)
      (split-window nil nil 'right)
      (drgnx-state-sync f)
      (should-not (drgnx-state-events-test--take)))))

(defvar drgnx-state-events-test--live nil "Whether the frame was live when `frame-removed' came.")

(defun drgnx-state-events-test--note-live (data)
  (setq drgnx-state-events-test--live (list (frame-live-p (plist-get data :frame))
                                            (gethash (plist-get data :frame) drgnx-state--frames))))

(ert-deftest drgnx-state-events/frame-removed-while-live ()
  (drgnx-state-events-test--with
    (let ((f (selected-frame)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'frame-removed)
      (drgnx-state-subscribe 'frame-removed #'drgnx-state-events-test--note-live :lane 'now)
      (setq drgnx-state-events-test--live nil)
      (drgnx-state--frame-deleted f)                     ; as `delete-frame-functions' calls it
      (should (equal (list (list :frame f)) (drgnx-state-events-test--of 'frame-removed (drgnx-state-events-test--take))))
      (should (equal '(t nil) drgnx-state-events-test--live)) ; live, its record already gone
      (drgnx-state--frame-deleted f)                     ; no record: nothing
      (should-not (drgnx-state-events-test--take)))))

(ert-deftest drgnx-state-events/frame-kind-on-role-change ()
  (drgnx-state-events-test--with
    (let ((f (selected-frame)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'frame-kind)
      (set-frame-parameter f 'drgnx-frame-role 'main)
      (drgnx-state-sync f)
      (should (equal (list (list :frame f :old '(:kind tty :role nil :monitor nil) :new '(:kind tty :role main :monitor nil)))
                     (drgnx-state-events-test--of 'frame-kind (drgnx-state-events-test--take))))
      (set-frame-parameter f 'drgnx-monitor '(:name "DP-1"))
      (drgnx-state-sync f)
      (should (equal '(:kind tty :role main :monitor (:name "DP-1"))
                     (plist-get (car (drgnx-state-events-test--of 'frame-kind (drgnx-state-events-test--take))) :new))))))

(ert-deftest drgnx-state-events/windows-changed-on-split ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'windows-changed)
      (let ((b (split-window a nil 'right)))
        (drgnx-state-sync f)
        (should (equal (list (list :frame f :windows (list a b)))
                       (drgnx-state-events-test--of 'windows-changed (drgnx-state-events-test--take))))
        ;; a resize alone changes no window, buffer or role
        (window-resize a 2 t)
        (drgnx-state-sync f)
        (should-not (drgnx-state-events-test--take))
        ;; another buffer, another role: changed
        (set-window-buffer b (drgnx-state-events-test--buffer "b"))
        (drgnx-state-sync f)
        (should (drgnx-state-events-test--of 'windows-changed (drgnx-state-events-test--take)))
        (set-window-parameter b 'drgnx-role 'panel)
        (drgnx-state-sync f)
        (should (drgnx-state-events-test--of 'windows-changed (drgnx-state-events-test--take)))))))

(ert-deftest drgnx-state-events/groups-changed ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'groups-changed)
      (let ((b (split-window a nil 'right)))
        (drgnx-state-sync f)
        (should (equal (list (list :frame f :added (list b) :removed nil))
                       (drgnx-state-events-test--of 'groups-changed (drgnx-state-events-test--take))))
        ;; a dock window is no group
        (drgnx-state-events-test--dock 'explorer)
        (drgnx-state-sync f)
        (should-not (drgnx-state-events-test--take))
        (delete-window b)
        (drgnx-state-sync f)
        (should (equal (list (list :frame f :added nil :removed (list b)))
                       (drgnx-state-events-test--of 'groups-changed (drgnx-state-events-test--take))))))))

(ert-deftest drgnx-state-events/pane-shown-and-hidden-for-an-area ()
  (drgnx-state-events-test--with
    (let ((f (selected-frame)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'pane-shown 'pane-hidden)
      (let ((panel (drgnx-state-events-test--panel)))
        (drgnx-state-sync f)
        (should (equal (list (cons 'pane-shown (list :frame f :kind 'terminal :window panel :cause 'other :by nil)))
                       (drgnx-state-events-test--take)))
        ;; the area's front tab changes
        (set-frame-parameter f 'drgnx-wb-areas '((panel :tab problems)))
        (set-window-buffer panel (drgnx-state-events-test--buffer "problems"))
        (drgnx-state-sync f)
        (should (equal (list (cons 'pane-hidden (list :frame f :kind 'terminal :window panel :cause 'other :by nil))
                             (cons 'pane-shown (list :frame f :kind 'problems :window panel :cause 'other :by nil)))
                       (drgnx-state-events-test--take)))
        (delete-window panel)
        (drgnx-state-sync f)
        (should (equal (list (cons 'pane-hidden (list :frame f :kind 'problems :window panel :cause 'other :by nil)))
                       (drgnx-state-events-test--take)))))))

(ert-deftest drgnx-state-events/a-view-swap-is-hidden-then-shown ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (dock (drgnx-state-events-test--dock 'explorer)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'pane-shown 'pane-hidden)
      ;; the dock window shows another view
      (set-window-parameter dock 'drgnx-section 'outline)
      (set-window-buffer dock (drgnx-state-events-test--buffer 'outline))
      (drgnx-state-sync f)
      (should (equal '((pane-hidden . explorer) (pane-shown . outline))
                     (mapcar (lambda (e) (cons (car e) (plist-get (cdr e) :kind))) (drgnx-state-events-test--take))))
      ;; the same kind in a new window (a restore makes new windows): hidden from the old, shown in the new
      (delete-window dock)
      (let ((new (drgnx-state-events-test--dock 'outline)))
        (drgnx-state-sync f)
        (should (equal (list (list 'pane-hidden 'outline dock) (list 'pane-shown 'outline new))
                       (mapcar (lambda (e) (list (car e) (plist-get (cdr e) :kind) (plist-get (cdr e) :window)))
                               (drgnx-state-events-test--take))))))))

(ert-deftest drgnx-state-events/pane-resized ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)) (panel (drgnx-state-events-test--panel)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'pane-resized)
      (let ((old-a (drgnx-state-edges a)) (old-p (drgnx-state-edges panel)))
        (window-resize panel 2)
        (drgnx-state-sync f)
        (let ((log (drgnx-state-events-test--of 'pane-resized (drgnx-state-events-test--take))))
          ;; both the panel (a pane) and the editor group it pushed
          (should (equal (list (list :frame f :window a :kind nil :old old-a :new (drgnx-state-edges a) :cause 'other :by nil)
                               (list :frame f :window panel :kind 'terminal :old old-p :new (drgnx-state-edges panel)
                                     :cause 'other :by nil))
                         log)))))))

(ert-deftest drgnx-state-events/selected-changed ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)) (dock (drgnx-state-events-test--dock 'explorer)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'selected-changed)
      (select-window dock)
      (drgnx-state-sync f)
      (should (equal (list (list :frame f :window dock :old-window a :old-frame f))
                     (drgnx-state-events-test--of 'selected-changed (drgnx-state-events-test--take))))
      (drgnx-state-sync f)
      (should-not (drgnx-state-events-test--take)))))

(ert-deftest drgnx-state-events/editor-changed-on-window-only ()
  ;; `C-x o' between two windows showing one buffer: the editor changes, its buffer does not
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)) (b (split-window a nil 'right)) (buf (window-buffer a)))
      (should (eq buf (window-buffer b)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'editor-changed)
      (select-window b)
      (drgnx-state-sync f)
      (should (equal (list (list :frame f :window b :buffer buf :old-window a :old-buffer buf))
                     (drgnx-state-events-test--of 'editor-changed (drgnx-state-events-test--take))))
      ;; a write: `drgnx-state-use-editor' replaces the record through the same path
      (select-window (drgnx-state-events-test--dock 'explorer))
      (drgnx-state-sync f)
      (should-not (drgnx-state-events-test--take))       ; the dock is no editor: b stays
      (drgnx-state-use-editor a)
      (should (equal (list (list :frame f :window a :buffer buf :old-window b :old-buffer buf))
                     (drgnx-state-events-test--of 'editor-changed (drgnx-state-events-test--take)))))))

(ert-deftest drgnx-state-events/editor-changed-on-buffer ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)) (old (window-buffer a)) (new (drgnx-state-events-test--buffer "x")))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'editor-changed)
      (set-window-buffer a new)
      (drgnx-state-sync f)
      (should (equal (list (list :frame f :window a :buffer new :old-window a :old-buffer old))
                     (drgnx-state-events-test--of 'editor-changed (drgnx-state-events-test--take)))))))

;;;; Delivery

(ert-deftest drgnx-state-events/order-within-one-observation ()
  (drgnx-state-events-test--with
    (let ((f (selected-frame)) (a (selected-window)))
      (drgnx-state-events-test--listen)
      ;; the first observation of a workbench: the frame comes, its windows, groups and panes show, a selection
      (drgnx-state-events-test--dock 'explorer)
      (drgnx-state-events-test--panel)
      (split-window a nil 'right)
      (drgnx-state-sync f)
      (let ((names (mapcar #'car (drgnx-state-events-test--take))))
        (should (equal '(frame-added windows-changed groups-changed pane-shown pane-shown selected-changed editor-changed)
                       names)))
      ;; a later one with nearly everything at once
      (set-frame-parameter f 'drgnx-frame-role 'main)
      (set-frame-parameter f 'drgnx-wb-areas '((panel :tab problems)))
      (let ((panel (car (drgnx-state-windows f 'panel))))
        (set-window-buffer panel (drgnx-state-events-test--buffer "problems"))
        (window-resize panel 1))
      (select-window (split-window a nil 'below))
      (drgnx-state-sync f)
      (let* ((names (mapcar #'car (drgnx-state-events-test--take)))
             (pos (mapcar (lambda (n) (cl-position n drgnx-state-events-test--events)) names)))
        (should (equal pos (sort (copy-sequence pos) #'<=)))
        (dolist (e '(frame-kind windows-changed groups-changed pane-hidden pane-shown pane-resized selected-changed
                                editor-changed))
          (should (memq e names)))))))

(defvar drgnx-state-events-test--inside nil "What a `now' subscriber saw.")

(defun drgnx-state-events-test--now-editor (data)
  "A `now' subscriber: note whether an observation runs and what the store says, then choose an editor."
  (push (list drgnx-state--observing (drgnx-state-editor-window (plist-get data :frame)) (plist-get data :window))
        drgnx-state-events-test--inside)
  (when (eq (length drgnx-state-events-test--inside) 1)
    (drgnx-state-use-editor (plist-get data :old-window))))

(ert-deftest drgnx-state-events/now-runs-inside-sync ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)) (b (split-window a nil 'right))
           (dock (drgnx-state-events-test--dock 'explorer)))
      (drgnx-state-sync f)
      (setq drgnx-state-events-test--inside nil)
      (drgnx-state-subscribe 'editor-changed #'drgnx-state-events-test--now-editor :lane 'now)
      (select-window b)
      (drgnx-state-sync f)
      ;; called inside the observation, the new record already stored
      (should (equal (list t b b) (car (last drgnx-state-events-test--inside))))
      ;; the subscriber chose `a' during delivery: the outer store did not overwrite its choice
      (select-window dock)
      (drgnx-state-sync f)
      (should (eq a (drgnx-state-editor-window f))))))

(defun drgnx-state-events-test--idle-note (data)
  (push data drgnx-state-events-test--inside))

(ert-deftest drgnx-state-events/idle-coalesces-per-subscriber-event-frame-kind ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)) (panel (drgnx-state-events-test--panel)))
      (drgnx-state-sync f)
      (setq drgnx-state-events-test--inside nil)
      (drgnx-state-subscribe 'pane-resized #'drgnx-state-events-test--idle-note)   ; idle: the default
      (window-resize panel 1) (drgnx-state-sync f)
      (window-resize panel 1) (drgnx-state-sync f)
      (window-resize panel 1) (drgnx-state-sync f)
      (should-not drgnx-state-events-test--inside)    ; nothing yet
      (should (timerp drgnx-signal--timer))           ; the bus's idle flush delivers them
      (drgnx-state--deliver-idle)
      ;; one call per kind (the panel's `terminal', the editor group's nil), each with the last data
      (should (= 2 (length drgnx-state-events-test--inside)))
      (should (equal (list nil 'terminal) (sort (mapcar (lambda (d) (plist-get d :kind)) drgnx-state-events-test--inside)
                                                (lambda (x _) (null x)))))
      (dolist (d drgnx-state-events-test--inside)
        (should (equal (plist-get d :new) (drgnx-state-edges (plist-get d :window)))))
      (should (eq a (plist-get (seq-find (lambda (d) (null (plist-get d :kind))) drgnx-state-events-test--inside) :window)))
      (should-not drgnx-state--queue)
      (setq drgnx-state-events-test--inside nil)
      (drgnx-state--deliver-idle)
      (should-not drgnx-state-events-test--inside))))

(defun drgnx-state-events-test--boom (_data) (error "Boom"))

(ert-deftest drgnx-state-events/an-error-is-recorded-not-raised ()
  (drgnx-state-events-test--with
    (let ((f (selected-frame)))
      (drgnx-state-sync f)
      (drgnx-state-subscribe 'windows-changed #'drgnx-state-events-test--boom :lane 'now)
      (drgnx-state-events-test--listen 'windows-changed)
      (split-window nil nil 'right)
      (should (drgnx-state-sync f))
      (should (equal '("windows-changed drgnx-state-events-test--boom: Boom") drgnx-signal-errors))
      (should (drgnx-state-events-test--take))          ; the next subscriber still got it
      ;; idle too
      (drgnx-state-unsubscribe 'windows-changed #'drgnx-state-events-test--boom)
      (drgnx-state-subscribe 'windows-changed #'drgnx-state-events-test--boom)
      (split-window nil nil 'right)
      (drgnx-state-sync f)
      (drgnx-state--deliver-idle)
      (should (= 2 (length drgnx-signal-errors)))
      ;; capped at 20
      (dotimes (_ 25) (drgnx-state--call 'windows-changed #'drgnx-state-events-test--boom nil))
      (should (= 20 (length drgnx-signal-errors))))))

(defun drgnx-state-events-test--ask (_data) (y-or-n-p "Really? "))

(ert-deftest drgnx-state-events/delivery-never-prompts ()
  (drgnx-state-events-test--with
    (let ((f (selected-frame)))
      (drgnx-state-sync f)
      (drgnx-state-subscribe 'windows-changed #'drgnx-state-events-test--ask :lane 'now)
      (drgnx-state-subscribe 'groups-changed #'drgnx-state-events-test--ask)
      (split-window nil nil 'right)
      (drgnx-state-sync f)
      (drgnx-state--deliver-idle)
      (should (= 2 (length drgnx-signal-errors)))
      (dolist (e drgnx-signal-errors)
        (should (string-match-p "drgnx-state-events-test--ask: .*inhibited" e))))))

;;;; Subscribing

(defmacro drgnx-state-events-test--with-modules (&rest body)
  "BODY with fresh module tables and claims, and an empty config dir (fake modules only)."
  (declare (indent 0) (debug t))
  `(let* ((cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
          (drgnx-module--claims (make-hash-table :test 'equal)))
     (unwind-protect (progn ,@body) (delete-directory cfg t))))

(defun drgnx-state-events-test--setup (name setup)
  "Run SETUP as fake module NAME's, through the recorder, and mark it running."
  (setf (alist-get name drgnx-modules--table) (list :doc "test" :stage 'startup :setup setup))
  (should-not (drgnx-modules--run-setup name setup))
  (drgnx-modules--record name 'startup 0 'ok))

(defun drgnx-state-events-test--sub-a ()
  (drgnx-state-subscribe 'pane-shown #'drgnx-state-events-test--on-pane-shown :lane 'now))

(ert-deftest drgnx-state-events/subscribe-pushes-its-undo ()
  (drgnx-state-events-test--with
    (drgnx-state-events-test--with-modules
      (drgnx-state-events-test--setup 'test/events-a #'drgnx-state-events-test--sub-a)
      (should (equal '("state subscription pane-shown drgnx-state-events-test--on-pane-shown")
                     (mapcar #'car (alist-get 'test/events-a drgnx-modules--stacks))))
      (should (equal '((pane-shown drgnx-state-events-test--on-pane-shown)) drgnx-state--now))
      (drgnx-state-events-test--sub-a)                   ; once per pair
      (should (equal '((pane-shown drgnx-state-events-test--on-pane-shown)) drgnx-state--now))
      (should-not (drgnx-module-teardown 'test/events-a))
      (should-not drgnx-state--now)
      ;; subscribed before the module: the undo leaves it
      (drgnx-state-events-test--sub-a)
      (drgnx-state-events-test--setup 'test/events-a #'drgnx-state-events-test--sub-a)
      (should-not (drgnx-module-teardown 'test/events-a))
      (should (equal '((pane-shown drgnx-state-events-test--on-pane-shown)) drgnx-state--now))
      (should (drgnx-state-unsubscribe 'pane-shown #'drgnx-state-events-test--on-pane-shown))
      (should-not drgnx-state--now)
      (should-not (drgnx-state-unsubscribe 'pane-shown #'drgnx-state-events-test--on-pane-shown))
      ;; subscription order; the default lane is idle
      (drgnx-state-subscribe 'pane-shown #'drgnx-state-events-test--on-pane-shown)
      (drgnx-state-subscribe 'pane-shown #'drgnx-state-events-test--on-pane-hidden)
      (should (equal '((pane-shown drgnx-state-events-test--on-pane-shown drgnx-state-events-test--on-pane-hidden))
                     drgnx-state--idle)))))

(ert-deftest drgnx-state-events/a-lambda-is-refused ()
  (drgnx-state-events-test--with
    (should-error (drgnx-state-subscribe 'pane-shown (lambda (_d) nil)))
    (should-error (drgnx-state-subscribe 'pane-shown nil))
    (should-error (drgnx-state-subscribe 'no-such-event #'ignore))
    (should-error (drgnx-state-subscribe 'pane-shown #'ignore :lane 'soon))
    (should-not drgnx-state--now)
    (should-not drgnx-state--idle)))

;;;; Cause

(ert-deftest drgnx-state-events/cause-write-carries-by ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (panel (drgnx-state-events-test--panel)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'pane-resized)
      (drgnx-state-with-write (f 'layout) (window-resize panel 2))
      (let ((log (drgnx-state-events-test--of 'pane-resized (drgnx-state-events-test--take))))
        (should log)
        (dolist (d log)
          (should (eq 'write (plist-get d :cause)))
          (should (eq 'layout (plist-get d :by))))))))

(ert-deftest drgnx-state-events/cause-user-for-resize-commands ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)))
      (split-window a nil 'below)
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'pane-resized)
      (setq drgnx-state--in-command t)
      (let ((this-command 'enlarge-window))
        (enlarge-window 2)
        (drgnx-state-sync f))
      (let ((log (drgnx-state-events-test--of 'pane-resized (drgnx-state-events-test--take))))
        (should log)
        (dolist (d log) (should (equal '(user user) (list (plist-get d :cause) (plist-get d :by))))))
      ;; another command is not the user's resize
      (let ((this-command 'next-line))
        (enlarge-window 1)
        (drgnx-state-sync f))
      (dolist (d (drgnx-state-events-test--of 'pane-resized (drgnx-state-events-test--take)))
        (should (eq 'other (plist-get d :cause)))))))

(ert-deftest drgnx-state-events/cause-user-for-a-divider-drag ()
  ;; Emacs 30+: each step of a divider drag is a command of a transient map, `this-command' a closure, `track-mouse' `dragging'.
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)))
      (split-window a nil 'below)
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'pane-resized)
      (setq drgnx-state--in-command t)
      (let ((this-command (lambda (_e) (interactive "e"))) (track-mouse 'dragging))
        (enlarge-window 2)
        (drgnx-state-sync f))
      (let ((log (drgnx-state-events-test--of 'pane-resized (drgnx-state-events-test--take))))
        (should log)
        (dolist (d log) (should (equal '(user user) (list (plist-get d :cause) (plist-get d :by)))))))))

(ert-deftest drgnx-state-events/cause-other-for-a-popup ()
  (drgnx-state-events-test--with
    (let* ((f (selected-frame)) (a (selected-window)))
      (drgnx-state-sync f)
      (drgnx-state-events-test--listen 'pane-resized)
      ;; a popup lane squeezes the editor, outside a write and outside a command
      (let ((lane (split-window a -6 'below)))
        (set-window-parameter lane 'drgnx-popup '(:borrowed nil))
        (drgnx-state-sync f))
      (should (equal (list (list a 'other nil))
                     (mapcar (lambda (d) (list (plist-get d :window) (plist-get d :cause) (plist-get d :by)))
                             (drgnx-state-events-test--of 'pane-resized (drgnx-state-events-test--take))))))))

(provide 'wb-state-events-test)
;;; wb-state-events-test.el ends here
