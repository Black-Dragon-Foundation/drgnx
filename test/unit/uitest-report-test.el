;;; uitest-report-test.el --- batch tests: jank report reduction -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(defun drgnx-test--sig (&rest kv)
  (append kv (list :buffer "b" :start 1 :point 1 :edges '(0 0 10 10) :header 0 :modeline 20)))

(ert-deftest drgnx-uitest/report-quiet ()
  (let ((r (drgnx-uitest-jank-report nil 100.0 nil '("w1") 100.0)))
    (should (equal (plist-get r :settle_ms) 0))
    (should (equal (plist-get r :collateral_moves) 0))
    (should (equal (plist-get r :layout_changes) 0))))

(ert-deftest drgnx-uitest/report-collateral-oscillation-chrome-echo ()
  (let* ((a (drgnx-test--sig)) (b (drgnx-test--sig :point 9)) (c (drgnx-test--sig :point 9 :header 22))
         (initial (list (cons "w1" a) (cons "w2" a) (cons "mini" '(:height 20))))
         (log (list (list 100.10 'change "w1" a b)        ; target: not collateral
                    (list 100.20 'change "w2" a b)        ; collateral
                    (list 100.30 'change "w2" b a)        ; back to an earlier value: oscillation
                    (list 100.35 'change "w1" b c)        ; chrome change
                    (list 100.40 'change "mini" '(:height 20) '(:height 40))
                    (list 100.45 'scroll "w2" 5)))
         (r (drgnx-uitest-jank-report log 100.0 initial '("w1") 100.05)))
    (should (equal (plist-get r :collateral_moves) 1))
    (should (equal (plist-get r :collateral) ["w2"]))
    (should (equal (plist-get r :oscillations) 1))
    (should (equal (plist-get r :chrome_changes) 1))
    (should (equal (plist-get r :echo_changes) 1))
    (should (equal (plist-get r :scrolls) 1))
    (should (equal (plist-get r :settle_ms) 400))))   ; 100.45 - 100.05

(ert-deftest drgnx-uitest/report-layout ()
  (let* ((a (drgnx-test--sig)) (moved (drgnx-test--sig :edges '(0 0 10 5)))
         (log (list (list 1.1 'change "w1" a moved) (list 1.2 'change "w3" nil a)))
         (r (drgnx-uitest-jank-report log 1.0 (list (cons "w1" a)) '("w1" "w3") 1.0)))
    (should (equal (plist-get r :layout_changes) 2))
    (should (equal (plist-get r :collateral_moves) 0))))

(ert-deftest drgnx-uitest/report-oscillation-is-per-field ()
  ;; Point snaps back to where it was while the window's edges changed meanwhile: still a snap-back.
  (let* ((a (drgnx-test--sig))
         (b (drgnx-test--sig :point 73 :edges '(0 0 10 12)))
         (c (drgnx-test--sig :point 1 :edges '(0 0 10 12)))
         (r (drgnx-uitest-jank-report (list (list 1.1 'change "w1" a b) (list 1.3 'change "w1" b c))
                                      1.0 (list (cons "w1" a)) '("w1") 1.0)))
    (should (= (plist-get r :oscillations) 1))))

(ert-deftest drgnx-uitest/report-causes-and-trace ()
  (let* ((a (drgnx-test--sig)) (b (drgnx-test--sig :point 9)) (c (drgnx-test--sig :point 1))
         (log (list (list 1.1 'change "w1" a b "command:mouse-set-point")
                    (list 1.3 'change "w1" b c "timer:follow")))
         (r (drgnx-uitest-jank-report log 1.0 (list (cons "w1" a)) '("w1") 1.0)))
    (should (= (plist-get r :timer_moves) 1))
    (should (equal (plist-get r :causes)
                   [(:cause "command:mouse-set-point" :count 1) (:cause "timer:follow" :count 1)]))
    (let ((step (aref (plist-get r :trace) 1)))
      (should (equal (plist-get step :cause) "timer:follow"))
      (should (equal (plist-get step :t_ms) 300))
      (should (equal (plist-get step :window) "w1"))
      (should (equal (plist-get step :fields) ["point"]))
      (should (equal (plist-get step :from) '(:point 9)))
      (should (equal (plist-get step :to) '(:point 1))))))

(ert-deftest drgnx-uitest/report-uncaused-changes-are-other ()
  (let* ((a (drgnx-test--sig)) (b (drgnx-test--sig :start 5))
         (r (drgnx-uitest-jank-report (list (list 1.1 'change "w1" a b)) 1.0 (list (cons "w1" a)) '("w1") 1.0)))
    (should (equal (plist-get (aref (plist-get r :trace) 0) :cause) "other"))
    (should (= (plist-get r :timer_moves) 0))))

;; DEFERRED M3e-6: the windows focused when the measurement ends are not aimed at: a timer that moves
;; focus to another window is a collateral move.
(ert-deftest drgnx-uitest/timer-change-in-focused-window-is-collateral ()
  (save-window-excursion
    (delete-other-windows)
    (let* ((w1 (selected-window)) (w2 (split-window w1 nil 'right)))
      (drgnx-uitest-measure-begin)
      (unwind-protect
          (progn
            (select-window w2 'norecord)        ; what a timer does, with no command of ours
            (let ((r (drgnx-uitest-measure-end)))
              (should (member (drgnx-uitest-window-id w2) (append (plist-get r :collateral) nil)))
              (should (>= (plist-get r :collateral_moves) 1))))
        (drgnx-uitest-measure-end)))))

(ert-deftest drgnx-uitest/scroll-without-a-new-start-is-not-a-change ()
  ;; window-scroll-functions also run when redisplay re-uses the same start; that must not
  ;; count as a change (it kept busy configurations from ever settling).
  (let ((drgnx-uitest-record--log nil) (drgnx-uitest-record--scroll-starts nil)
        (drgnx-uitest-record--last-change 0.0) (w (selected-window)))
    (drgnx-uitest-record--on-scroll w 1)
    (drgnx-uitest-record--on-scroll w 1)
    (drgnx-uitest-record--on-scroll w 9)
    (should (= (length drgnx-uitest-record--log) 2))))

(ert-deftest drgnx-uitest/a-redraw-with-an-unchanged-start-is-not-a-scroll ()
  ;; The first `window-scroll-functions' call of a measurement for a window whose start did not
  ;; change (any redisplay, e.g. a timer's) must not count as a change: it inflated settle times.
  (require 'drgnx-uitest)
  (drgnx-uitest-measure-begin)
  (unwind-protect
      (progn
        (drgnx-uitest-record--on-scroll (selected-window) (window-start))
        (should-not (seq-find (lambda (e) (eq (nth 1 e) 'scroll)) drgnx-uitest-record--log)))
    (drgnx-uitest-measure-end)))

;; M12c: a tiling WM resizes the frame itself (a new window halves it, a `resize' command).  The recorder
;; books those changes to `wm:resize': counted as layout, never as collateral or a snap-back.
(ert-deftest drgnx-uitest/a-wm-resize-is-not-collateral ()
  (let* ((a (drgnx-test--sig)) (b (drgnx-test--sig :edges '(0 0 5 10)))
         (log (list (list 1.1 'change "w1" a b "wm:resize") (list 1.1 'change "w2" a b "wm:resize")))
         (r (drgnx-uitest-jank-report log 1.0 (list (cons "w1" a) (cons "w2" a)) nil 1.0)))
    (should (= (plist-get r :collateral_moves) 0))
    (should (= (plist-get r :wm_resizes) 2))
    (should (= (plist-get r :layout_changes) 2))))

(ert-deftest drgnx-uitest/a-wm-resize-back-is-no-oscillation ()
  ;; The WM halves the frame, then gives it its width back: two resizes, no snap-back.
  (let* ((a (drgnx-test--sig)) (b (drgnx-test--sig :edges '(0 0 5 10)))
         (log (list (list 1.1 'change "w1" a b "wm:resize") (list 1.2 'change "w1" b a "wm:resize")))
         (r (drgnx-uitest-jank-report log 1.0 (list (cons "w1" a)) nil 1.0)))
    (should (= (plist-get r :oscillations) 0))
    (should (= (plist-get r :wm_resizes) 2))
    (should (= (plist-get r :collateral_moves) 0))))

(defmacro drgnx-uitest-test--resized (size-before &rest body)
  "BODY with the recorder's last frame size SIZE-BEFORE, the frame now 640x400, and no window seen yet."
  (declare (indent 1))
  `(let ((drgnx-uitest-record--sigs nil) (drgnx-uitest-record--log nil)
         (drgnx-uitest-record--last-change 0.0) (drgnx-uitest-record--frame nil)
         (drgnx-uitest-record--size ,size-before))
     (cl-letf (((symbol-function 'drgnx-uitest-record--frame-size) (lambda (_frame) '(640 . 400))))
       ,@body)))

(defun drgnx-uitest-test--causes ()
  (delete-dups (mapcar (lambda (e) (nth 5 e)) drgnx-uitest-record--log)))

(ert-deftest drgnx-uitest/a-frame-resize-no-command-made-is-the-wms ()
  (drgnx-uitest-test--resized '(1280 . 400)
    (drgnx-uitest-record--snapshot "other")
    (should (equal (drgnx-uitest-test--causes) '("wm:resize")))
    (should (equal drgnx-uitest-record--size '(640 . 400)))
    ;; the next snapshot, the size unchanged: `other' again
    (setq drgnx-uitest-record--sigs nil drgnx-uitest-record--log nil)
    (drgnx-uitest-record--snapshot "other")
    (should (equal (drgnx-uitest-test--causes) '("other")))))

(ert-deftest drgnx-uitest/a-frame-resize-during-a-command-stays-the-commands ()
  (drgnx-uitest-test--resized '(1280 . 800)
    (drgnx-uitest-record--snapshot "command:toggle-frame-fullscreen")
    (should (equal (drgnx-uitest-test--causes) '("command:toggle-frame-fullscreen")))
    (should (equal drgnx-uitest-record--size '(640 . 400)))))      ; the command's resize is not the WM's later

(ert-deftest drgnx-uitest/the-measurement-keeps-its-frame ()
  ;; A frame made during a measurement comes first in `frame-list': the recorder stays on the frame it began
  ;; with, so the new frame's windows are not taken for the old ones' deletion.
  (drgnx-uitest-measure-begin)
  (unwind-protect
      (progn
        (should (eq drgnx-uitest-record--frame (drgnx-uitest-root-frame)))
        (should (equal drgnx-uitest-record--size
                       (drgnx-uitest-record--frame-size (drgnx-uitest-root-frame))))
        ;; the snapshots read that frame, whatever comes first in `frame-list' now
        (cl-letf (((symbol-function 'drgnx-uitest-root-frame) (lambda () (error "Not the measured frame"))))
          (should (assoc "mini" (drgnx-uitest-record--signatures)))))
    (drgnx-uitest-measure-end)))

(ert-deftest drgnx-uitest/measure-begin-takes-the-frame ()
  ;; A test that made a second frame measures the first one: the targets and the snapshots are FRAME's.
  (cl-letf (((symbol-function 'drgnx-uitest-root-frame) (lambda () (error "Not the given frame"))))
    (drgnx-uitest-measure-begin (selected-frame))
    (unwind-protect
        (should (eq drgnx-uitest-record--frame (selected-frame)))
      (should (plist-member (drgnx-uitest-measure-end) :wm_resizes))))
  (should-not drgnx-uitest-record--frame)
  (should-not drgnx-uitest-record--size))

(ert-deftest drgnx-uitest/a-dead-measured-frame-books-nothing ()
  ;; The measured frame was deleted: no later change is recorded (another frame's windows are not its windows,
  ;; and that frame's other size is no WM resize).
  (let* ((orig (symbol-function 'frame-live-p))
         (drgnx-uitest-record--frame 'drgnx-test-dead-frame) (drgnx-uitest-record--size '(1 . 1))
         (drgnx-uitest-record--sigs nil) (drgnx-uitest-record--log nil) (drgnx-uitest-record--last-change 0.0))
    (cl-letf (((symbol-function 'frame-live-p) (lambda (f) (and (not (eq f 'drgnx-test-dead-frame)) (funcall orig f)))))
      (drgnx-uitest-record--snapshot "other"))
    (should-not drgnx-uitest-record--log)))
