;;; uitest-input-test.el --- batch tests: event construction -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(ert-deftest drgnx-uitest/key-events ()
  (should (equal (drgnx-uitest-key-events "C-x b") '(24 98)))
  (should (equal (drgnx-uitest-key-events "M-x") (list (aref (kbd "M-x") 0)))))

(ert-deftest drgnx-uitest/type-events ()
  (should (equal (drgnx-uitest-type-events "a\"✓") (list ?a ?\" ?✓)))
  (should (equal (drgnx-uitest-type-events "a\nb") (list ?a 'return ?b))))     ; a newline is the Return key, not C-j

(ert-deftest drgnx-uitest/click-events ()
  ;; The release is resolved when it is delivered (a click, or a drag if the text moved).
  (should (equal (drgnx-uitest-click-events 'P) '((down-mouse-1 P) (drgnx-uitest-release 1 P))))
  (should (equal (drgnx-uitest-click-events 'P 3 1 0.3)
                 '((down-mouse-3 P) (drgnx-uitest-pause . 0.3) (drgnx-uitest-release 3 P))))
  (should (equal (drgnx-uitest-click-events 'P 1 2)
                 '((down-mouse-1 P) (drgnx-uitest-release 1 P) (double-down-mouse-1 P 2) (double-mouse-1 P 2)))))

(defmacro drgnx-uitest-input-test--in-window (header &rest body)
  "Run BODY with a temp buffer (with a header line if HEADER) shown in the selected window."
  (declare (indent 1))
  `(let ((win (selected-window)) (old (window-buffer (selected-window))))
     (with-temp-buffer
       (when ,header (setq-local header-line-format "H"))
       (set-window-buffer win (current-buffer))
       (redisplay t)                    ; the window's header-line height is a redisplay result
       (unwind-protect (progn ,@body) (set-window-buffer win old)))))

(defun drgnx-uitest-input-test--posn (x y)
  (posn-at-x-y x y (selected-frame)))

(ert-deftest drgnx-uitest/drag-events-press-move-release ()
  (drgnx-uitest-input-test--in-window nil
    (let* ((from (drgnx-uitest-input-test--posn 5 5))
           (to (drgnx-uitest-input-test--posn 35 5))
           (events (drgnx-uitest-drag-events from to :steps 3)))
      (should (equal (mapcar #'car events)
                     '(down-mouse-1 mouse-movement mouse-movement mouse-movement drag-mouse-1)))
      (should (equal (car events) (list 'down-mouse-1 from)))
      ;; three movements on the straight line, the last one at TO
      (should (equal (mapcar (lambda (ev) (car (posn-x-y (cadr ev)))) (cl-subseq events 1 4))
                     '(15 25 35)))
      (should (equal (cl-subseq events 1 4)
                     (mapcar (lambda (x) (list 'mouse-movement (drgnx-uitest-input-test--posn x 5)))
                             '(15 25 35))))
      (should (equal (car (last events)) (list 'drag-mouse-1 from to))))
    ;; the button and the default of 8 steps
    (let ((events (drgnx-uitest-drag-events (drgnx-uitest-input-test--posn 2 2)
                                            (drgnx-uitest-input-test--posn 30 10) :button 3)))
      (should (eq (car (car events)) 'down-mouse-3))
      (should (eq (car (car (last events))) 'drag-mouse-3))
      (should (= (cl-count 'mouse-movement events :key #'car) 8)))))

(ert-deftest drgnx-uitest/a-drag-in-place-is-a-click ()
  (drgnx-uitest-input-test--in-window nil
    (let ((p (drgnx-uitest-input-test--posn 5 5)))
      (should (equal (drgnx-uitest-drag-events p p) (list (list 'down-mouse-1 p) (list 'mouse-1 p))))
      ;; a different posn object for the same pixel is the same position
      (should (equal (mapcar #'car (drgnx-uitest-drag-events p (drgnx-uitest-input-test--posn 5 5) :button 2))
                     '(down-mouse-2 mouse-2))))))

(ert-deftest drgnx-uitest/drag-from-a-header-line ()
  (drgnx-uitest-input-test--in-window t
    (let* ((top (nth 1 (window-pixel-edges)))     ; the header line is the window's first pixel row
           (from (drgnx-uitest-input-test--posn 5 top))
           (to (drgnx-uitest-input-test--posn 5 (+ top 12)))
           (events (drgnx-uitest-drag-events from to :steps 4)))
      (should (eq (posn-area from) 'header-line))
      ;; Emacs prefixes the area ([header-line down-mouse-1]) only for symbols of kind mouse-click
      (dolist (head '(down-mouse-1 drag-mouse-1 mouse-1))
        (should (eq (get head 'event-kind) 'mouse-click)))
      (should (eq (posn-area (cadr (car events))) 'header-line))        ; pressed on the header line
      (should (eq (posn-area (cadr (car (last events)))) 'header-line)) ; and released as a drag from it
      (should (equal (car (last events)) (list 'drag-mouse-1 from to)))
      ;; the pointer leaves the header line for the text on the way
      (should (null (posn-area (cadr (nth 4 events)))))
      (should (equal (cadr (nth 4 events)) to)))))

(ert-deftest drgnx-uitest/a-lazy-drag-is-placed-when-each-event-is-delivered ()
  ;; a divider drag moves the layout under the pointer: movements and release are resolved at delivery
  (drgnx-uitest-input-test--in-window nil
    (let* ((from (drgnx-uitest-input-test--posn 5 5))
           (events (drgnx-uitest-drag-events from (drgnx-uitest-input-test--posn 35 5) :steps 3 :lazy t)))
      (should (equal (mapcar #'car events)
                     '(down-mouse-1 drgnx-uitest-move drgnx-uitest-move drgnx-uitest-move drgnx-uitest-drag-end)))
      (should (equal (car (last events)) (list 'drgnx-uitest-drag-end 1 from 35 5))))
    (let* ((start (list (selected-frame) nil '(1 . 1) 0)) ; a press on no window
           (drgnx-uitest--queue (list '(drgnx-uitest-move 15 5) (list 'drgnx-uitest-drag-end 3 start 35 5)))
           (unread-command-events nil) (drgnx-uitest--timer 'dummy))
      (drgnx-uitest--tick)
      (drgnx-uitest--tick)
      (should (equal unread-command-events
                     (list (list 'mouse-movement (drgnx-uitest-posn 15 5))
                           (list 'drag-mouse-3 start (drgnx-uitest-posn 35 5)))))
      (setq unread-command-events nil))))

(ert-deftest drgnx-uitest/queued-mouse-events-move-the-pointer-a-drag-line-reads ()
  ;; `mouse-drag-line' measures a drag by `mouse-absolute-pixel-position'; a synthesized event moves no real pointer,
  ;; so the delivery of each event says where it is (the dock-drag GUI test never resized anything without it)
  (drgnx-uitest-input-test--in-window nil
    (let* ((from (drgnx-uitest-input-test--posn 5 5))
           (drgnx-uitest--queue (list (list 'down-mouse-1 from) '(drgnx-uitest-move 25 5)))
           (unread-command-events nil) (drgnx-uitest--timer 'dummy) (drgnx-uitest--pointer nil))
      (should-not drgnx-uitest--pointer)
      (drgnx-uitest--tick)
      (should (equal (mouse-absolute-pixel-position) (drgnx-uitest--posn-frame-xy from)))
      (drgnx-uitest--tick)
      (should (equal (mouse-absolute-pixel-position) (drgnx-uitest--posn-frame-xy (drgnx-uitest-posn 25 5))))
      (drgnx-uitest--tick)                   ; the queue is empty: the real pointer again
      (should-not drgnx-uitest--pointer)
      (setq unread-command-events nil))))

(ert-deftest drgnx-uitest/a-lazy-drag-from-a-header-line-stays-a-drag ()
  (drgnx-uitest-input-test--in-window t
    (let* ((top (nth 1 (window-pixel-edges)))
           (from (drgnx-uitest-input-test--posn 5 top))
           (events (drgnx-uitest-drag-events from (drgnx-uitest-input-test--posn 5 (+ top 12)) :steps 2 :lazy t))
           (drgnx-uitest--queue events) (unread-command-events nil) (drgnx-uitest--timer 'dummy))
      (should (eq (posn-area from) 'header-line))
      (dotimes (_ 4) (drgnx-uitest--tick))
      (should (equal (mapcar #'car unread-command-events) '(down-mouse-1 mouse-movement mouse-movement drag-mouse-1)))
      (should (eq (posn-area (cadr (car unread-command-events))) 'header-line))
      (should (null (posn-area (cadr (nth 2 unread-command-events)))))
      ;; a header line has no text position to still be on: the release is always the drag
      (should (eq (cadr (car (last unread-command-events))) from))
      (setq unread-command-events nil))))

(ert-deftest drgnx-uitest/a-lazy-release-on-the-pressed-text-is-a-click ()
  ;; as for a click (`drgnx-uitest--release-event'): the same buffer position and window
  (drgnx-uitest-input-test--in-window nil
    (insert (make-string 70 ?x))
    (redisplay t)
    (let* ((y (nth 1 (window-pixel-edges)))            ; the first line, which has the text
           (from (drgnx-uitest-input-test--posn 5 y))
           (drgnx-uitest--queue (list (list 'drgnx-uitest-drag-end 1 from 5 y)
                                      (list 'drgnx-uitest-drag-end 1 from 35 y)))
           (unread-command-events nil) (drgnx-uitest--timer 'dummy))
      (drgnx-uitest--tick)
      (drgnx-uitest--tick)
      (should (eq (car (nth 0 unread-command-events)) 'mouse-1))
      (should (eq (car (nth 1 unread-command-events)) 'drag-mouse-1))   ; another position: a drag
      (setq unread-command-events nil))))

(ert-deftest drgnx-uitest/clicks-find-the-area-binding-whatever-ran-before ()
  ;; Emacs prefixes [header-line ...] only for symbols of kind mouse-click; clicks must not depend on
  ;; a drag (or real input) having made the symbols first.
  (dolist (stem '("down" "drag" "double" "double-down" nil))
    (dolist (b '(1 2 3 4 5))
      (put (intern (if stem (format "%s-mouse-%d" stem b) (format "mouse-%d" b))) 'event-kind nil)))
  (drgnx-uitest-input-test--in-window t
    (let* ((map (make-sparse-keymap))
           (top (nth 1 (window-pixel-edges)))
           (posn (drgnx-uitest-input-test--posn 5 top)))
      (define-key map [header-line down-mouse-1] #'ignore)
      (define-key map [header-line mouse-1] #'ignore)
      (define-key map [header-line double-down-mouse-1] #'ignore)
      (define-key map [header-line double-mouse-1] #'ignore)
      (use-local-map map)
      (should (eq (posn-area posn) 'header-line))
      (dolist (ev (drgnx-uitest-click-events posn 1 2))
        (let ((ev (if (eq (car ev) 'drgnx-uitest-release)
                      (drgnx-uitest--release-event (nth 1 ev) (nth 2 ev))
                    ev)))
          (let* ((unread-command-events (list ev))
                 (keys (read-key-sequence nil)))
            (should (eq (aref keys 0) 'header-line))
            (should (key-binding keys)))))
      ;; the unprepared event is looked up in the text area instead: the failure this guards against
      (put 'down-mouse-1 'event-kind nil)
      (let ((unread-command-events (list (list 'down-mouse-1 posn))))
        (should-not (eq (aref (read-key-sequence nil) 0) 'header-line))))))

(ert-deftest drgnx-uitest/a-posn-is-turned-into-a-frame-pixel-by-area ()
  (drgnx-uitest-input-test--in-window t
    (let* ((win (selected-window))
           (edges (window-pixel-edges win))
           (left (nth 0 edges)) (top (nth 1 edges)) (bottom (nth 3 edges))
           (text-top (cdr (drgnx-uitest--text-origin win)))
           (body-left (car (drgnx-uitest--text-origin win))))
      ;; real posns of this window round-trip: text, header line, mode line
      (dolist (xy (list (cons (+ body-left 3) (+ text-top 2)) (cons 7 top) (cons 6 (1- bottom))))
        (should (equal (drgnx-uitest--posn-frame-xy (drgnx-uitest-input-test--posn (car xy) (cdr xy))) xy)))
      (should (eq (posn-area (drgnx-uitest-input-test--posn 6 (1- bottom))) 'mode-line))
      ;; areas a character-cell frame has none of: posns as a graphical frame reports them
      (should (equal (drgnx-uitest--posn-frame-xy (list win 'left-fringe '(3 . 10) 0))   ; x from the window's left edge, y from the text
                     (cons (+ left 3) (+ text-top 10))))
      (should (equal (drgnx-uitest--posn-frame-xy (list win 'right-fringe '(3 . 10) 0))
                     (cons (+ left 3) (+ text-top 10))))
      (should (equal (drgnx-uitest--posn-frame-xy (list win 'right-divider '(2 . 100) 0)) ; both from the window's top left
                     (cons (+ left 2) (+ top 100))))
      (should (equal (drgnx-uitest--posn-frame-xy (list win 'mode-line '(40 . 0) 0))
                     (cons (+ left 40) top)))
      ;; a posn on no window is frame-relative already
      (should (equal (drgnx-uitest--posn-frame-xy (list (selected-frame) nil '(9 . 8) 0)) '(9 . 8))))))

(ert-deftest drgnx-uitest/window-ids-are-stable ()
  (let ((w (selected-window)))
    (should (string-match-p "\\`w[0-9]+\\'" (drgnx-uitest-window-id w)))
    (should (equal (drgnx-uitest-window-id w) (drgnx-uitest-window-id w)))
    (should (equal (drgnx-uitest-window-id (minibuffer-window)) "mini"))))

(ert-deftest drgnx-uitest/queue-delivers-one-event-per-tick ()
  (let ((drgnx-uitest--queue nil) (unread-command-events nil) (drgnx-uitest--timer 'dummy))
    (setq drgnx-uitest--queue (list ?a '(drgnx-uitest-pause . 0) ?b))
    (drgnx-uitest--tick)
    (should (equal unread-command-events '(?a)))
    (drgnx-uitest--tick)                        ; pause becomes a deadline
    (drgnx-uitest--tick)                        ; deadline passed: dropped
    (drgnx-uitest--tick)
    (should (equal unread-command-events '(?a ?b)))
    (should (null drgnx-uitest--queue))
    (setq unread-command-events nil)))

(ert-deftest drgnx-uitest/settled-waits-from-the-start-of-a-measurement ()
  ;; A measurement with no input must still give followers (timers) the quiet period.
  (let ((drgnx-uitest--queue nil) (unread-command-events nil)
        (drgnx-uitest--last-delivery 0.0)
        (drgnx-uitest-record--last-change 0.0)
        (drgnx-uitest-record--t0 (float-time)))
    (should-not (drgnx-uitest-settled-p 0.3))
    (let ((drgnx-uitest-record--t0 (- (float-time) 1)))
      (should (drgnx-uitest-settled-p 0.3)))))

(ert-deftest drgnx-uitest/settle-scale-follows-the-load-per-core ()
  ;; M4-13/M5-6: a loaded machine settles slower; the 5 s default stretches with it.
  (should (= (drgnx-uitest-settle-scale 0.5 4 "") 1.0))        ; idle
  (should (= (drgnx-uitest-settle-scale 3.9 4 "") 1.0))        ; a core to spare: never shorter
  (should (= (drgnx-uitest-settle-scale 8.0 4 "") 2.0))        ; two runnable tasks per core
  (should (= (drgnx-uitest-settle-scale 400.0 4 "") drgnx-uitest-settle-scale-max)) ; bounded
  (should (= (drgnx-uitest-settle-scale nil 4 "") (drgnx-uitest-settle-scale (car (load-average t)) 4 "")))
  (should (>= (drgnx-uitest-settle-scale) 1.0)))

(ert-deftest drgnx-uitest/settle-scale-env-overrides ()
  (should (= (drgnx-uitest-settle-scale 0.1 4 "3") 3.0))
  (should (= (drgnx-uitest-settle-scale 0.1 4 "1.5") 1.5))
  (should (= (drgnx-uitest-settle-scale 8.0 4 "0.5") 0.5))     ; a lower factor is allowed: the user asked
  (should (= (drgnx-uitest-settle-scale 8.0 4 "0") 2.0))       ; zero and junk are ignored
  (should (= (drgnx-uitest-settle-scale 8.0 4 "fast") 2.0))
  (let ((process-environment (cons "DRGNX_UITEST_SETTLE_SCALE=4" process-environment)))
    (should (= (drgnx-uitest-settle-scale 0.1 4) 4.0))))

(ert-deftest drgnx-uitest/run-deadline-uses-the-scaled-default ()
  (let (deadline)
    (cl-letf (((symbol-function 'drgnx-uitest-settle-scale) (lambda (&rest _) 3.0))
              ((symbol-function 'drgnx-uitest-measure-begin) #'ignore)
              ((symbol-function 'drgnx-uitest-enqueue) #'ignore)
              ((symbol-function 'recursive-edit) (lambda () (setq deadline drgnx-uitest--run-deadline)))
              ((symbol-function 'drgnx-uitest-measure-end) (lambda () nil)))
      (let ((t0 (float-time)))
        (drgnx-uitest-run nil)
        (should (< 14.9 (- deadline t0) 15.5))                 ; 5 s * 3
        (drgnx-uitest-run nil 2)
        (should (< 1.9 (- deadline t0) 2.5))))))                ; an explicit timeout is not scaled
