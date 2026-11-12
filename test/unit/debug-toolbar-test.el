;;; debug-toolbar-test.el --- batch tests: the debug toolbar, its docked form, the status segment, the Paused chip -*- lexical-binding: t -*-
;; test-class: det
;; Sessions come from `debug-state' events fed to the module's handler, as the hub sends them.  The batch frame is a
;; terminal, so the card's frame operations are replaced where a test needs a graphical frame: what is tested is which
;; card is shown, made, placed and hidden, and what its text says.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defmacro debug-toolbar-test--with (sessions &rest body)
  "BODY with the hub's `debug-state' saying SESSIONS in a project at /p; the toolbar's drawing is not run."
  (declare (indent 1))
  `(let ((drgnx-debug--sessions nil) (drgnx-debug--focus nil) (drgnx-debug-toolbar 'floating)
         (drgnx-debug-toolbar--docked nil))
     (cl-letf (((symbol-function 'drgnx-debug-launch-root) (lambda () "/p"))
               ((symbol-function 'drgnx-debug-toolbar-sync) #'ignore))
       (unwind-protect
           (progn (drgnx-debug--event "debug-state" (list :sessions (vconcat ,sessions)))
                  ,@body)
         (drgnx-debug-session-mode -1)))))

(defun debug-toolbar-test--ids (session)
  "The ids of SESSION's buttons, an enabled one as ID, a disabled one as (ID)."
  (mapcar (lambda (b) (if (nth 4 b) (car b) (list (car b)))) (drgnx-debug-toolbar--buttons session)))

(ert-deftest drgnx-debug-toolbar/buttons-follow-the-state ()
  "Continue while stopped, Pause while running (none while starting), the steps only while stopped, Restart always
\(the hub stops and starts again without `supportsRestartRequest'), Disconnect for an attach session."
  (should (equal (debug-toolbar-test--ids '(:id "s" :state "stopped"))
                 '(debug-start debug-step-over debug-step-in debug-step-out debug-restart debug-stop)))
  (should (equal (debug-toolbar-test--ids '(:id "s" :state "running"))
                 '(debug-pause (debug-step-over) (debug-step-in) (debug-step-out) debug-restart debug-stop)))
  (should (equal (debug-toolbar-test--ids '(:id "s" :state "starting"))
                 '((debug-pause) (debug-step-over) (debug-step-in) (debug-step-out) debug-restart debug-stop)))
  (should (equal (car (last (debug-toolbar-test--ids '(:id "s" :state "running" :attach t)))) 'debug-disconnect)))

(ert-deftest drgnx-debug-toolbar/hover-shows-the-profiles-key ()
  (cl-letf (((symbol-function 'drgnx-surfaces-key-label)
             (lambda (id &rest _) (pcase id ('debug-step-over "F10") ('debug-stop "Shift+F5")))))
    (let ((text (drgnx-debug-toolbar--text '(:id "s" :name "app" :state "stopped") nil (selected-frame) 'card)))
      (should (equal (get-text-property (text-property-any 0 (length text) 'drgnx-debug-button 'debug-step-over text)
                                        'help-echo text)
                     "Step Over (F10)"))
      (should (equal (get-text-property (text-property-any 0 (length text) 'drgnx-debug-button 'debug-stop text)
                                        'help-echo text)
                     "Stop (Shift+F5)"))
      ;; no key: the title alone
      (should (equal (get-text-property (text-property-any 0 (length text) 'drgnx-debug-button 'debug-restart text)
                                        'help-echo text)
                     "Restart"))
      ;; a disabled button runs nothing
      (let ((text (drgnx-debug-toolbar--text '(:id "s" :name "app" :state "running") nil (selected-frame) 'card)))
        (should-not (get-text-property (text-property-any 0 (length text) 'drgnx-debug-button 'debug-step-in text)
                                       'keymap text))
        (should (get-text-property (text-property-any 0 (length text) 'drgnx-debug-button 'debug-pause text)
                                   'keymap text))))))

(ert-deftest drgnx-debug-toolbar/the-card-has-a-grip-the-tab-row-none ()
  (let ((card (drgnx-debug-toolbar--text '(:id "s" :name "app" :state "stopped") nil (selected-frame) 'card))
        (row (drgnx-debug-toolbar--text '(:id "s" :name "app" :state "stopped") nil (selected-frame) 'tab-line)))
    (should (text-property-any 0 (length card) 'drgnx-debug-button 'grip card))
    (should-not (text-property-any 0 (length row) 'drgnx-debug-button 'grip row))
    ;; the tab row's buttons answer a click on the tab line
    (let ((km (get-text-property (text-property-any 0 (length row) 'drgnx-debug-button 'debug-start row) 'local-map row)))
      (should (lookup-key km [tab-line mouse-1])))))

(ert-deftest drgnx-debug-toolbar/session-chip-with-two-sessions ()
  (let ((one '((:id "a" :name "app" :state "stopped")))
        (two '((:id "a" :name "app" :state "stopped") (:id "b" :name "worker" :state "running"))))
    (should-not (string-search "app" (drgnx-debug-toolbar--text (car one) one (selected-frame) 'card)))
    (should (string-search "app" (drgnx-debug-toolbar--text (car two) two (selected-frame) 'card))))
  ;; picking a session makes the keys and the controls act on it
  (debug-toolbar-test--with '((:id "a" :name "app" :root "/p" :state "stopped") (:id "b" :name "worker" :root "/q" :state "running"))
    (cl-letf (((symbol-function 'completing-read) (lambda (_p coll &rest _) (car (nth 1 coll)))))
      (drgnx-debug-toolbar-pick-session))
    (should (equal (plist-get (drgnx-debug-toolbar--session) :id) "b"))
    (should (equal (plist-get (drgnx-debug--session) :id) "b"))))

(ert-deftest drgnx-debug-toolbar/one-card-per-frame-reused ()
  "The card is made once per root frame and kept: shown again, it is the same frame."
  (let ((drgnx-debug-toolbar--children (make-hash-table :test #'eq :weakness 'key)) (made 0) (live nil))
    (cl-letf (((symbol-function 'drgnx-debug-toolbar--make) (lambda (_p) (let ((f (list 'card (cl-incf made)))) (push f live) f)))
              ((symbol-function 'frame-live-p) (lambda (f) (or (memq f live) (framep f)))))
      (let* ((p1 (selected-frame)) (p2 (list 'other-root))
             (c1 (drgnx-debug-toolbar--child p1)))
        (should (eq c1 (drgnx-debug-toolbar--child p1)))
        (should (= made 1))
        (should-not (eq c1 (drgnx-debug-toolbar--child p2)))
        (should (= made 2))
        ;; a deleted card is made again
        (setq live (delq c1 live))
        (should-not (eq c1 (drgnx-debug-toolbar--child p1)))
        (should (= made 3))))))

(ert-deftest drgnx-debug-toolbar/where-the-controls-go ()
  "`floating' a card, `docked' the tab row, `hidden' neither; a terminal frame never gets a card or a tab row."
  (dolist (case '((floating t card) (docked t tab-line) (hidden t nil) (floating nil nil) (docked nil nil)))
    (let ((drgnx-debug-toolbar (nth 0 case)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) (nth 1 case))))
        (should (eq (drgnx-debug-toolbar--where (selected-frame)) (nth 2 case)))))))

(ert-deftest drgnx-debug-toolbar/sync-shows-and-hides-the-cards ()
  "A session shows the card of each graphical root frame; none hides it (kept, not deleted); a terminal frame gets none."
  (let ((drgnx-debug-toolbar 'floating) (drgnx-debug-toolbar--docked nil) (shown nil) (hidden nil) (graphic t))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) graphic))
              ((symbol-function 'drgnx-debug-toolbar--show) (lambda (f s _ss) (push (cons f (plist-get s :id)) shown)))
              ((symbol-function 'drgnx-debug-toolbar--hide) (lambda (f) (push f hidden)))
              ((symbol-function 'drgnx-debug-launch-root) (lambda () "/p")))
      (let ((drgnx-debug--sessions '((:id "a" :name "app" :root "/p" :state "stopped"))) (drgnx-debug--focus nil))
        (drgnx-debug-toolbar-sync)
        (should (equal shown (list (cons (selected-frame) "a"))))
        (should-not hidden)
        (setq shown nil drgnx-debug--sessions nil)
        (drgnx-debug-toolbar-sync)
        (should-not shown)
        (should (equal hidden (list (selected-frame))))
        (setq hidden nil graphic nil drgnx-debug--sessions '((:id "a" :name "app" :root "/p" :state "stopped")))
        (drgnx-debug-toolbar-sync)
        (should-not shown)))))

(ert-deftest drgnx-debug-toolbar/docked-buttons-in-the-tab-row ()
  (let ((drgnx-debug-toolbar 'docked) (drgnx-debug-toolbar--docked nil) (applied 0))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'drgnx-debug-toolbar--hide) #'ignore)
              ((symbol-function 'drgnx-chrome-apply) (lambda (&rest _) (cl-incf applied)))
              ((symbol-function 'drgnx-state-editor-window) (lambda (&optional _) (selected-window)))
              ((symbol-function 'drgnx-debug-launch-root) (lambda () "/p")))
      (let ((drgnx-debug--sessions '((:id "a" :name "app" :root "/p" :state "stopped"))) (drgnx-debug--focus nil))
        (drgnx-debug-toolbar-sync)
        (should (> applied 0))
        (let ((row (drgnx-debug-toolbar--tab-row (selected-window))))
          (should (text-property-any 0 (length row) 'drgnx-debug-button 'debug-step-over row)))
        ;; the same state draws no tab row again
        (setq applied 0)
        (drgnx-debug-toolbar-sync)
        (should (= applied 0))
        (setq drgnx-debug--sessions nil)
        (drgnx-debug-toolbar-sync)
        (should-not (drgnx-debug-toolbar--tab-row (selected-window)))
        (should (> applied 0))))))

(ert-deftest drgnx-debug-toolbar/the-grip-moves-the-card-per-frame ()
  "A drag keeps its offset per root frame, and the card is placed by it, inside its editor window."
  (let ((drgnx-debug-toolbar--offsets (make-hash-table :test #'eq :weakness 'key))
        (drgnx-debug-toolbar--children (make-hash-table :test #'eq :weakness 'key))
        (p1 (selected-frame)) (p2 (list 'other-root)) (child (list 'card)) moved)
    (puthash p1 child drgnx-debug-toolbar--children)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (f) (or (eq f child) (framep f))))
              ((symbol-function 'drgnx-state-editor-window) (lambda (&optional _) (selected-window)))
              ((symbol-function 'window-pixel-edges) (lambda (&optional _) '(100 50 900 700)))
              ((symbol-function 'window-tab-line-height) (lambda (&optional _) 30))
              ((symbol-function 'frame-pixel-width) (lambda (&optional _) 200))
              ((symbol-function 'set-frame-position) (lambda (_f x y) (setq moved (cons x y)))))
      (drgnx-debug-toolbar--place p1 child)
      (should (equal moved '(400 . 80)))            ; centred: 100 + (800 - 200) / 2, under the tab row
      (drgnx-debug-toolbar--nudge p1 -120)
      (should (equal moved '(280 . 80)))
      (should (= (gethash p1 drgnx-debug-toolbar--offsets) -120))
      (should (= (gethash p2 drgnx-debug-toolbar--offsets 0) 0))   ; another frame keeps its own
      (drgnx-debug-toolbar--nudge p1 -900)
      (should (equal moved '(100 . 80))))))           ; never out of the window

(ert-deftest drgnx-debug-toolbar/status-segment-and-paused-chip ()
  (debug-toolbar-test--with '((:id "a" :name "Python: plan the week" :root "/p" :state "stopped" :reason "breakpoint"))
    (should (equal (substring-no-properties (drgnx-debug-toolbar--segment) 2)
                   "Python: plan the week · paused on breakpoint"))
    (should (eq (get-text-property 3 'face (drgnx-debug-toolbar--segment)) 'drgnx-status-warn))
    (should (drgnx-debug-toolbar-paused-p))
    (drgnx-debug--event "debug-state" (list :sessions (vector '(:id "a" :name "app" :root "/p" :state "running"))))
    (should (equal (substring-no-properties (drgnx-debug-toolbar--segment) 2) "app · running"))
    (should-not (drgnx-debug-toolbar-paused-p))
    (drgnx-debug--event "debug-state" (list :sessions []))
    (should-not (drgnx-debug-toolbar--segment))
    (should-not (drgnx-debug-toolbar-paused-p))))

(ert-deftest drgnx-debug-toolbar/the-module-wires-it ()
  "The module defines the segment, puts it after the branch, sets the title row's chip, and its commands exist."
  (drgnx-test-with-modules '(ui/face extra/debug) :strict t
                           (should (memq 'debug drgnx-statusbar-left))
                           (should (eq drgnx-topline-paused-function #'drgnx-debug-toolbar-paused-p))
                           (should (eq drgnx-chrome-tab-row-function #'drgnx-debug-toolbar--tab-row))
                           (dolist (c '(debug-restart debug-pause debug-disconnect debug-show-stop debug-pick-session)) (should (drgnx-commands-get c))))
  (should-not (memq 'debug drgnx-statusbar-left)))

;;; debug-toolbar-test.el ends here
