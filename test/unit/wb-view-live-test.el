;;; wb-view-live-test.el --- batch tests: views drawing live — timer, visibility, slices, places -*- lexical-binding: t -*-
;;
;; Every test runs on the virtual clock (test/fixtures/clock-fixture.el): marks arm the view's timers through the
;; timer layer, and `drgnx-test-advance' runs them.  Slices read `drgnx-timer-now', which a test replaces with a clock
;; that moves a fixed step per read.  Batch Emacs runs no redisplay, so no `window-buffer-change-functions' either:
;; the visibility tests call the view's hook function the way redisplay would.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-signal)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/view-fixture" drgnx-dir) nil t)

;;;; Helpers

(defvar drgnx-view-live-test--model nil "KEY → its content, read by the test renderers.")
(defvar drgnx-view-live-test--slices nil "Each draw's PATCHED call, newest first: (BUFFER . KEYS).")
(defvar drgnx-view-live-test--reads 0 "How many times the replaced `drgnx-timer-now' was read.")
(defvar drgnx-view-live-test--times nil "Virtual times at which the timed renderer ran.")

(defun drgnx-view-live-test--render (key) (format "%s: %s\n" key (gethash key drgnx-view-live-test--model "")))
(defun drgnx-view-live-test--render-body (key)
  (cons (format "%s: %s" key (gethash key drgnx-view-live-test--model "")) "\n"))
(defun drgnx-view-live-test--grow (key len) (substring (car (drgnx-view-live-test--render-body key)) len))
(defun drgnx-view-live-test--render-timed (key)
  (push (drgnx-test-clock-now) drgnx-view-live-test--times)
  (drgnx-view-live-test--render key))
(defun drgnx-view-live-test--patched (view keys)
  (push (cons (drgnx-view--buffer view) keys) drgnx-view-live-test--slices))

(defmacro drgnx-view-live-test--with (spec &rest body)
  "SPEC: (VAR &rest ARGS).  BODY on the virtual clock, in a fresh buffer shown in the only window, with VAR a view
of type `drgnx-view-live-t' (`drgnx-view-define' with ARGS and the recording PATCHED) attached at `point-min'."
  (declare (indent 1))
  `(let ((drgnx-view-live-test--model (make-hash-table :test #'equal)) (drgnx-view-live-test--slices nil)
         (drgnx-view--deadline nil))
     (drgnx-view-test-with-type ('drgnx-view-live-t :patched #'drgnx-view-live-test--patched ,@(cdr spec))
       (let ((buffer (generate-new-buffer " *drgnx-view-live*")) (config (current-window-configuration)))
         (unwind-protect
             (progn
               (delete-other-windows)
               (set-window-buffer (selected-window) buffer)
               (with-current-buffer buffer
                 (let ((,(car spec) (drgnx-view-attach 'drgnx-view-live-t)))
                   (drgnx-test-with-clock (:allow-pending t) ,@body))))
           (set-window-configuration config)
           (kill-buffer buffer))))))

(defmacro drgnx-view-live-test--ticking (step &rest body)
  "BODY with `drgnx-timer-now' returning 1000 + STEP × the reads so far (`drgnx-view-live-test--reads')."
  (declare (indent 1))
  `(let ((drgnx-view-live-test--reads 0))
     (cl-letf (((symbol-function 'drgnx-timer-now)
                (lambda () (prog1 (+ 1000.0 (* drgnx-view-live-test--reads ,step))
                             (setq drgnx-view-live-test--reads (1+ drgnx-view-live-test--reads))))))
       ,@body)))

(defun drgnx-view-live-test--stat (view name) (plist-get (drgnx-view-stats view) name))

(defun drgnx-view-live-test--ok (view)
  (should-not (drgnx-view--check view))
  (should (equal (drgnx-view-test--expected view) (drgnx-view-test--text view))))

(defun drgnx-view-live-test--rows (view n)
  "Append rows 0..N-1 to VIEW and draw them at once."
  (dotimes (k n) (puthash k (format "row %d" k) drgnx-view-live-test--model))
  (drgnx-view-append view (number-sequence 0 (1- n)))
  (drgnx-view-draw-now view))

(defun drgnx-view-live-test--slice-sizes (buffer)
  "The number of keys of each PATCHED call for BUFFER, oldest first."
  (mapcar (lambda (s) (length (cdr s)))
          (cl-remove-if-not (lambda (s) (eq (car s) buffer)) (reverse drgnx-view-live-test--slices))))

;;;; Timing

(ert-deftest drgnx-view-live/a-mark-draws-after-the-delay ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render)
    (drgnx-view-append v '(a))
    (should (equal "" (drgnx-view-test--text v)))      ; a mark draws nothing
    (drgnx-test-advance 0.09)
    (should (equal "" (drgnx-view-test--text v)))
    (drgnx-test-advance 0.01)
    (should (equal "a: \n" (drgnx-view-test--text v)))
    (should-not (drgnx-view-pending-p v))))

(ert-deftest drgnx-view-live/marks-in-a-burst-draw-once ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :key-test 'eq)
    (dotimes (k 50) (drgnx-view-append v (list k)) (drgnx-view-dirty v '(0)))
    (should (equal "" (drgnx-view-test--text v)))
    (drgnx-test-advance 0.1)
    (should (= 1 (length drgnx-view-live-test--slices)))
    (should (= 50 (drgnx-view-row-count v)))
    (should (= 50 (drgnx-view-live-test--stat v :rows-drawn)))
    (drgnx-test-advance 1)
    (should (= 1 (length drgnx-view-live-test--slices)))
    (drgnx-view-live-test--ok v)))

(ert-deftest drgnx-view-live/the-throttle-holds-the-min-interval ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render-timed)
    (let ((drgnx-view-live-test--times nil))
      (drgnx-view-append v '(a))
      (drgnx-test-advance 0.1)
      (dotimes (k 100)                            ; a mark every 10 ms for a second
        (puthash 'a (format "%d" k) drgnx-view-live-test--model)
        (drgnx-view-dirty v '(a))
        (drgnx-test-advance 0.01))
      (let ((times (reverse drgnx-view-live-test--times)))
        (should (>= (length times) 5))
        (should (<= (length times) 11))
        (cl-loop for (a b) on times while b do (should (>= (- b a) 0.0999)))))))

(defvar drgnx-view-live-test--view nil "The view the test filter marks.")
(defvar drgnx-view-live-test--seen nil "What the test filter saw when it returned: (TEXT ROWS-DRAWN) per call.")
(defvar drgnx-view-live-test--lines 0 "How many lines the test filter got.")

(defun drgnx-view-live-test--filter (_process string)
  "A process filter that only marks: each line of STRING is a new row."
  (let ((v drgnx-view-live-test--view))
    (dolist (line (split-string string "\n" t))
      (drgnx-view-append v (list (intern line)))
      (setq drgnx-view-live-test--lines (1+ drgnx-view-live-test--lines)))
    (push (list (drgnx-view-test--text v) (drgnx-view-live-test--stat v :rows-drawn)) drgnx-view-live-test--seen)))

(ert-deftest drgnx-view-live/a-mark-from-a-process-filter-only-marks ()
  (skip-unless (executable-find "cat"))
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render)
    (let* ((drgnx-view-live-test--view v) (drgnx-view-live-test--seen nil) (drgnx-view-live-test--lines 0)
           (p (make-process :name "drgnx-view-live-cat" :command '("cat") :connection-type 'pipe :noquery t
                            :filter #'drgnx-view-live-test--filter)))
      (unwind-protect
          (progn (process-send-string p "x\ny\n")
                 (let ((tries 0))
                   (while (and (< drgnx-view-live-test--lines 2) (< tries 50))
                     (accept-process-output p 0.1)
                     (setq tries (1+ tries)))))
        (delete-process p))
      (should drgnx-view-live-test--seen)
      (dolist (seen drgnx-view-live-test--seen) (should (equal '("" 0) seen)))
      (drgnx-test-advance 0.1)
      (should (equal "x: \ny: \n" (drgnx-view-test--text v))))))

;;;; Visibility

(ert-deftest drgnx-view-live/hidden-draws-nothing-and-allocates-nothing ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render)
    (let ((buffer (current-buffer)) (other (generate-new-buffer " *drgnx-view-live-other*")))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) other)
            (should-not (drgnx-view-shown-p v))
            (drgnx-view-append v '(a b))
            (drgnx-test-advance 0.1)
            (should (equal "" (drgnx-view-test--text v)))
            (should (= 0 (drgnx-view-live-test--stat v :rows-drawn)))
            (should (= 1 (drgnx-view-live-test--stat v :stale-skips)))
            (should (drgnx-view--stale v))
            (drgnx-view-dirty v '(a))           ; a stale view still hidden arms nothing
            (should-not (drgnx-timer-active-p (cons 'drgnx-view buffer)))
            (should (= 0 (drgnx-view-test--alloc (lambda () (drgnx-view--draw-buffer buffer)))))
            (should (equal "" (drgnx-view-test--text v))))
        (kill-buffer other)))))

(ert-deftest drgnx-view-live/showing-a-stale-view-draws-it ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render)
    (let ((buffer (current-buffer)) (other (generate-new-buffer " *drgnx-view-live-other*")))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) other)
            (drgnx-view-append v '(a b))
            (drgnx-test-advance 0.1)
            (should (drgnx-view--stale v))
            (should (memq #'drgnx-view--buffer-shown window-buffer-change-functions))
            (set-window-buffer (selected-window) buffer)
            (drgnx-view--buffer-shown (selected-window))      ; what redisplay runs
            (should-not (drgnx-view--stale v))
            (drgnx-test-advance 0.1)
            (should (equal "a: \nb: \n" (drgnx-view-test--text v))))
        (kill-buffer other)))))

(ert-deftest drgnx-view-live/shown-draws-once ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render)
    (let ((buffer (current-buffer)) (other (generate-new-buffer " *drgnx-view-live-other*")))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) other)
            (drgnx-view-append v '(a b))
            (drgnx-test-advance 0.1)
            (let ((w2 (split-window)))
              (set-window-buffer (selected-window) buffer)
              (set-window-buffer w2 buffer)
              (drgnx-view--buffer-shown (selected-window))
              (drgnx-view--buffer-shown w2))
            (drgnx-test-advance 0.1)
            (should (= 1 (length drgnx-view-live-test--slices)))
            (should (= 2 (drgnx-view-live-test--stat v :rows-drawn)))
            (drgnx-test-advance 1)
            (should (= 1 (length drgnx-view-live-test--slices))))
        (kill-buffer other)))))

;;;; Slices

(ert-deftest drgnx-view-live/a-slice-stops-at-the-deadline ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :slice 0.004 :key-test 'eq)
    (drgnx-view-live-test--rows v 200)
    (let ((drawn (drgnx-view-live-test--stat v :rows-drawn)))
      (drgnx-view-dirty v t)
      (drgnx-view-live-test--ticking 0.0005
        (drgnx-view--draw-buffer (current-buffer))
        (should (= 9 drgnx-view-live-test--reads)))     ; the deadline, then one read per 8 rows
      (should (= 64 (- (drgnx-view-live-test--stat v :rows-drawn) drawn)))
      (should (= 1 (drgnx-view-live-test--stat v :slices)))
      (should (= 64 (drgnx-view-live-test--stat v :max-slice-rows)))
      (should (drgnx-view-pending-p v))
      (should (drgnx-timer-active-p (cons 'drgnx-view-more (current-buffer))))
      (should-not (drgnx-view--check v)))))

(ert-deftest drgnx-view-live/a-slice-draws-at-least-one-row ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :slice 0.004 :key-test 'eq)
    (drgnx-view-live-test--rows v 20)
    (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
      (drgnx-view-live-test--ticking 1.0                  ; every read is past the deadline
        (drgnx-view-dirty v '(5))
        (should (= 1 (drgnx-view-live-test--draw-rows v)))
        (drgnx-view-dirty v t)
        (should (= 8 (drgnx-view-live-test--draw-rows v)))))))

(defun drgnx-view-live-test--draw-rows (view)
  "Run VIEW's timer draw once; the rows it drew."
  (let ((before (drgnx-view-live-test--stat view :rows-drawn)))
    (drgnx-view--draw-buffer (drgnx-view--buffer view))
    (- (drgnx-view-live-test--stat view :rows-drawn) before)))

(ert-deftest drgnx-view-live/input-stops-a-slice ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :slice 0.004 :key-test 'eq)
    (drgnx-view-live-test--rows v 100)
    (drgnx-view-dirty v t)
    (cl-letf (((symbol-function 'input-pending-p) (lambda (&rest _) t)))
      (drgnx-view-live-test--ticking 0.0                  ; the clock stands still: only input stops it
        (should (= 8 (drgnx-view-live-test--draw-rows v)))
        (should (= 2 drgnx-view-live-test--reads))))
    (should (drgnx-view-pending-p v))))

(ert-deftest drgnx-view-live/two-views-share-one-deadline ()
  "A view drawn 24 rows into the slice leaves the next view what is left of it: 40 rows, not a slice of its own."
  (let ((drgnx-view-live-test--model (make-hash-table :test #'equal)) (drgnx-view-live-test--slices nil)
        (drgnx-view--deadline nil) (config (current-window-configuration))
        (a (generate-new-buffer " *drgnx-view-live-a*")) (b (generate-new-buffer " *drgnx-view-live-b*")))
    (drgnx-view-test-with-type ('drgnx-view-live-soon :render #'drgnx-view-live-test--render :slice 0.004
                                                      :delay 0.05 :key-test 'eq
                                                      :patched #'drgnx-view-live-test--patched)
      (drgnx-view-test-with-type ('drgnx-view-live-t :render #'drgnx-view-live-test--render :slice 0.004
                                                     :key-test 'eq :patched #'drgnx-view-live-test--patched)
        (unwind-protect
            (progn
              (delete-other-windows)
              (set-window-buffer (selected-window) a)
              (set-window-buffer (split-window) b)
              (let ((va (with-current-buffer a (drgnx-view-attach 'drgnx-view-live-soon)))
                    (vb (with-current-buffer b (drgnx-view-attach 'drgnx-view-live-t))))
                (drgnx-test-with-clock (:allow-pending t)
                  (drgnx-view-live-test--rows va 24)
                  (drgnx-view-live-test--rows vb 200)
                  (setq drgnx-view-live-test--slices nil)
                  (drgnx-view-dirty va t)
                  (drgnx-view-dirty vb t)
                  (drgnx-view-live-test--ticking 0.0005
                    (drgnx-test-advance 0.1))
                  (should (equal '(24) (drgnx-view-live-test--slice-sizes a)))
                  (should (= 40 (car (drgnx-view-live-test--slice-sizes b))))
                  (should (equal a (car (car (last drgnx-view-live-test--slices)))))
                  (should (= 200 (apply #'+ (drgnx-view-live-test--slice-sizes b)))))))
          (set-window-configuration config)
          (kill-buffer a)
          (kill-buffer b))))))

(ert-deftest drgnx-view-live/visible-rows-first ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :slice 0.004 :key-test 'eq)
    (drgnx-view-live-test--rows v 10000)
    (set-window-start (selected-window) (drgnx-view-row-start v 5000))
    (setq drgnx-view-live-test--slices nil)
    (drgnx-view-dirty v t)
    (cl-letf (((symbol-function 'window-body-height) (lambda (&rest _) 41)))
      (drgnx-view-live-test--ticking 0.0005
        (drgnx-view--draw-buffer (current-buffer))))
    (let ((keys (cdr (car drgnx-view-live-test--slices))))
      (should (= 64 (length keys)))
      (should (equal (number-sequence 5000 5040) (take 41 keys)))
      (should (equal (number-sequence 0 22) (nthcdr 41 keys))))
    (should-not (drgnx-view--check v))))

(ert-deftest drgnx-view-live/the-rest-follows-at-0 ()
  "Every slice is 64 rows: the clock steps and the slice are binary fractions (1/2048 s, 8/2048 s), so a deadline
computed from any read is reached exactly at the 8th check."
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :slice (/ 8.0 2048) :key-test 'eq)
    (drgnx-view-live-test--rows v 1000)
    (let ((drawn (drgnx-view-live-test--stat v :rows-drawn)))
      (dotimes (k 1000) (puthash k (format "new %d" k) drgnx-view-live-test--model))
      (drgnx-view-dirty v t)
      (drgnx-view-live-test--ticking (/ 1.0 2048)
        (drgnx-view--draw-buffer (current-buffer))
        (should (drgnx-timer-active-p (cons 'drgnx-view-more (current-buffer))))
        (drgnx-test-advance 0))
      (should-not (drgnx-view-pending-p v))
      (should-not (drgnx-timer-active-p (cons 'drgnx-view-more (current-buffer))))
      (should (= 1000 (- (drgnx-view-live-test--stat v :rows-drawn) drawn)))
      (should (= 16 (drgnx-view-live-test--stat v :slices)))
      (should (= 64 (drgnx-view-live-test--stat v :max-slice-rows)))
      (should (= 0 (drgnx-view-live-test--stat v :full-draws)))
      (drgnx-view-live-test--ok v))))

(ert-deftest drgnx-view-live/a-mark-during-a-chain-arms-nothing ()
  "A mark while a slice chain runs arms no throttle draw beside the continuation: the next slice takes it, so one view
never draws two slices in one gap (review T4-I1)."
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :slice (/ 8.0 2048) :key-test 'eq)
    (let ((throttle (cons 'drgnx-view (current-buffer))) (more (cons 'drgnx-view-more (current-buffer))))
      (drgnx-view-live-test--rows v 1000)
      (drgnx-view-dirty v t)
      (drgnx-timer-cancel throttle)                       ; as if it had fired: it starts the chain
      (drgnx-view-live-test--ticking (/ 1.0 2048)
        (drgnx-view--draw-buffer (current-buffer))
        (should (drgnx-timer-active-p more))
        (puthash 'tail "appended mid-chain" drgnx-view-live-test--model)
        (drgnx-view-append v '(tail))
        (should-not (drgnx-timer-active-p throttle))
        (drgnx-test-advance 0))
      (should-not (drgnx-timer-active-p more))
      (should-not (drgnx-timer-active-p throttle))
      (should-not (drgnx-view-pending-p v))
      (should (eq 'tail (aref (drgnx-view--keys v) 1000)))
      (drgnx-view-live-test--ok v))))

(ert-deftest drgnx-view-live/a-reset-removes-rows-in-slices ()
  "A reset of 300 rows deletes them a row at a time across slices; between slices the view is consistent."
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :slice 0.004 :key-test 'eq)
    (drgnx-view-live-test--rows v 300)
    (drgnx-view-reset v (number-sequence 1000 1099))
    (drgnx-view-live-test--ticking 0.0005
      (drgnx-view--draw-buffer (current-buffer))
      (should-not (drgnx-view--check v))
      (should (= 64 (drgnx-view-live-test--stat v :removed)))
      (should (= 0 (drgnx-view-live-test--stat v :full-draws)))
      (drgnx-test-advance 0))
    (should (= 300 (drgnx-view-live-test--stat v :removed)))
    (should (equal (number-sequence 1000 1099)
                   (let (l) (dotimes (i (drgnx-view-row-count v)) (push (aref (drgnx-view--keys v) i) l)) (nreverse l))))
    (drgnx-view-live-test--ok v)))

;;;; Places

(ert-deftest drgnx-view-live/keeps-start-and-point-by-key-in-two-windows ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render-body :grow #'drgnx-view-live-test--grow
                                 :key-test 'eq)
    (drgnx-view-live-test--rows v 100)
    (let ((w1 (selected-window)) (w2 (split-window)))
      (set-window-buffer w2 (current-buffer))
      (set-window-start w1 (drgnx-view-row-start v 30))
      (set-window-point w1 (+ (drgnx-view-row-start v 35) 3))
      (set-window-start w2 (drgnx-view-row-start v 60))
      (set-window-point w2 (+ (drgnx-view-row-start v 70) 2))
      (dolist (k '(10 20 30 35 60 70)) (puthash k (format "row %d, much longer now" k) drgnx-view-live-test--model))
      (drgnx-view-dirty v '(10 20 30 35 60 70))           ; patches, above and on the rows
      (drgnx-view-remove v '(0 1 2 3 4))                  ; removals above
      (puthash 25 "row 25 and then some" drgnx-view-live-test--model)
      (drgnx-view-grow v 25)                              ; growth above
      (drgnx-test-advance 0.1)
      (should (> (drgnx-view-live-test--stat v :rows-grown) 0))
      (drgnx-view-live-test--ok v)
      (should (= (window-start w1) (drgnx-view-row-start v 30)))
      (should (= (window-point w1) (+ (drgnx-view-row-start v 35) 3)))
      (should (= (point) (+ (drgnx-view-row-start v 35) 3)))
      (should (= (window-start w2) (drgnx-view-row-start v 60)))
      (should (= (window-point w2) (+ (drgnx-view-row-start v 70) 2))))))

(ert-deftest drgnx-view-live/a-removed-row-falls-to-the-next ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :key-test 'eq)
    (drgnx-view-live-test--rows v 10)
    (let ((w2 (split-window)))
      (set-window-buffer w2 (current-buffer))
      (goto-char (+ (drgnx-view-row-start v 5) 2))
      (set-window-point w2 (+ (drgnx-view-row-start v 9) 1))
      (drgnx-view-remove v '(5 9))
      (drgnx-test-advance 0.1)
      (drgnx-view-live-test--ok v)
      (should (= (point) (drgnx-view-row-start v 6)))
      (should (= (window-point w2) (drgnx-view-row-start v 8))))))      ; the last row: the previous one

(ert-deftest drgnx-view-live/rows-all-replaced-go-to-the-top ()
  ;; UI audit #3: a sync whose keys share none with the rows (a new source) drew the new rows before the old ones
  ;; went, so window start and point fell to the previous live row: the last new one.  A new row set starts at the top.
  (dolist (how '(sync reset))
    (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :key-test 'eq)
      (drgnx-view-live-test--rows v 10)
      (dotimes (k 10) (puthash (+ 100 k) (format "new %d" k) drgnx-view-live-test--model))
      (let ((w (selected-window)) (keys (number-sequence 100 109)))
        (set-window-start w (drgnx-view-row-start v 0))
        (set-window-point w (point-max))
        (goto-char (point-max))
        (if (eq how 'sync)
            (drgnx-view-sync-rows v keys #'drgnx-view-live-test--render)
          (drgnx-view-reset v keys))
        (drgnx-test-advance 0.1)
        (drgnx-view-live-test--ok v)
        (should (equal keys (let (l) (dotimes (i (drgnx-view-row-count v)) (push (aref (drgnx-view--keys v) i) l))
                                 (nreverse l))))
        (should (= (window-start w) (point-min)))
        (should (= (window-point w) (point-min)))
        (should (= (point) (point-min)))))))

(ert-deftest drgnx-view-live/follow-tail ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :key-test 'eq :follow-tail t)
    (drgnx-view-live-test--rows v 10)
    (let ((w2 (split-window)))
      (set-window-buffer w2 (current-buffer))
      (goto-char (point-max))                             ; the selected window, at the end
      (set-window-point w2 (+ (drgnx-view-row-start v 3) 1))
      (drgnx-view-append v (number-sequence 10 14))
      (drgnx-test-advance 0.1)
      (should (= 15 (drgnx-view-row-count v)))
      (should (= (point) (point-max)))
      (should (= (window-point (selected-window)) (point-max)))
      (should (= (window-point w2) (+ (drgnx-view-row-start v 3) 1)))))
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :key-test 'eq)
    (drgnx-view-live-test--rows v 10)
    (goto-char (point-max))                               ; no FOLLOW-TAIL: the end stays after row 9
    (drgnx-view-append v (number-sequence 10 14))
    (drgnx-test-advance 0.1)
    (should (= (point) (drgnx-view-row-start v 10)))))

(defun drgnx-view-live-test--line-key (pos)
  (save-excursion (goto-char pos) (forward-line 0)
                  (and (looking-at "\\(k[0-9]+\\) ") (match-string-no-properties 1))))

(defun drgnx-view-live-test--line-pos (key)
  (save-excursion (goto-char (point-min))
                  (and (re-search-forward (concat "^" (regexp-quote key) " ") nil t) (match-beginning 0))))

(defun drgnx-view-live-test--fill (keys)
  (erase-buffer)
  (dolist (k keys) (insert k " text of " k "\n")))

(defun drgnx-view-live-test--line-keys (from to)
  (mapcar (lambda (i) (format "k%d" i)) (number-sequence from to)))

(ert-deftest drgnx-view-live/kept-windows-macro-keeps-places-by-key ()
  (drgnx-test-with-clock ()
    (let ((buffer (generate-new-buffer " *drgnx-view-live-kept*")) (config (current-window-configuration)))
      (unwind-protect
          (with-current-buffer buffer
            (delete-other-windows)
            (set-window-buffer (selected-window) buffer)
            (let ((w1 (selected-window)) (w2 (split-window)))
              (set-window-buffer w2 buffer)
              (drgnx-view-live-test--fill (drgnx-view-live-test--line-keys 1 20))
              (set-window-start w1 (drgnx-view-live-test--line-pos "k5"))
              (goto-char (+ (drgnx-view-live-test--line-pos "k7") 4))
              (set-window-start w2 (drgnx-view-live-test--line-pos "k10"))
              (set-window-point w2 (+ (drgnx-view-live-test--line-pos "k12") 2))
              (should (eq 'done
                          (drgnx-view-with-kept-windows (:key-at #'drgnx-view-live-test--line-key
                                                                 :pos-of #'drgnx-view-live-test--line-pos)
                            (drgnx-view-live-test--fill (cons "k0" (reverse (drgnx-view-live-test--line-keys 1 20))))
                            'done)))
              (should (= (window-start w1) (drgnx-view-live-test--line-pos "k5")))
              (should (= (point) (+ (drgnx-view-live-test--line-pos "k7") 4)))
              (should (= (window-start w2) (drgnx-view-live-test--line-pos "k10")))
              (should (= (window-point w2) (+ (drgnx-view-live-test--line-pos "k12") 2)))))
        (set-window-configuration config)
        (kill-buffer buffer)))))

(ert-deftest drgnx-view-live/kept-windows-macro-falls-back-to-the-line ()
  (drgnx-test-with-clock ()
    (with-temp-buffer
      (drgnx-view-live-test--fill (drgnx-view-live-test--line-keys 1 10))
      (goto-char (+ (drgnx-view-live-test--line-pos "k4") 2))
      (drgnx-view-with-kept-windows (:key-at #'drgnx-view-live-test--line-key :pos-of #'drgnx-view-live-test--line-pos)
        (drgnx-view-live-test--fill (cl-remove "k4" (drgnx-view-live-test--line-keys 0 10) :test #'equal)))
      (should (= 4 (line-number-at-pos)))
      (should (bolp)))))

(ert-deftest drgnx-view-live/kept-windows-macro-keeps-an-offset-on-its-row ()
  ;; A row drawn shorter: a place past its new end stays at the end of that row, never on the next one.
  (with-temp-buffer
    (drgnx-view-live-test--fill (drgnx-view-live-test--line-keys 1 5))
    (goto-char (1- (drgnx-view-live-test--line-pos "k4")))          ; the end of k3's row
    (drgnx-view-with-kept-windows (:key-at #'drgnx-view-live-test--line-key :pos-of #'drgnx-view-live-test--line-pos)
      (erase-buffer)
      (dolist (k (drgnx-view-live-test--line-keys 1 5)) (insert k (if (equal k "k3") " " " a longer text ") "\n")))
    (should (equal "k3" (drgnx-view-live-test--line-key (point))))
    (should (eolp))))

(ert-deftest drgnx-view-live/kept-windows-macro-falls-to-the-last-row-at-the-end ()
  ;; A place whose row went, on a line past the rows left, falls to the last row, not to the empty end of the buffer.
  (with-temp-buffer
    (drgnx-view-live-test--fill (drgnx-view-live-test--line-keys 1 10))
    (goto-char (drgnx-view-live-test--line-pos "k9"))
    (drgnx-view-with-kept-windows (:key-at #'drgnx-view-live-test--line-key :pos-of #'drgnx-view-live-test--line-pos)
      (drgnx-view-live-test--fill (drgnx-view-live-test--line-keys 1 5)))
    (should (equal "k5" (drgnx-view-live-test--line-key (point))))
    (should (bolp))))

;;;; The pass over

(ert-deftest drgnx-view-live/the-pass-over-calls-the-gc-gap-once ()
  (let ((gaps 0) (b2 (generate-new-buffer " *drgnx-view-live-2*")))
    (unwind-protect
        (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render)
          (set-window-buffer (split-window) b2)
          (let ((v2 (with-current-buffer b2 (drgnx-view-attach 'drgnx-view-live-t))))
            (cl-letf (((symbol-function 'drgnx-gc-gap) (lambda () (setq gaps (1+ gaps)))))
              (drgnx-view-append v '(a b))
              (drgnx-view-append v2 '(c))
              (drgnx-test-advance 0.1)
              (should (equal "c: \n" (drgnx-view-test--text v2)))
              (should (equal "a: \nb: \n" (drgnx-view-test--text v)))
              (should (= 1 gaps)))))
      (kill-buffer b2))))

;;;; Jank

(defvar drgnx-view-live-test--owned nil "For each window move: whether the window was the caller's own.")
(defun drgnx-view-live-test--note-owned (window &rest _)
  (push (and (memq window drgnx-wb--owned) t) drgnx-view-live-test--owned))

(ert-deftest drgnx-view-live/restores-are-owned-windows ()
  (drgnx-view-live-test--with (v :render #'drgnx-view-live-test--render :key-test 'eq)
    (drgnx-view-live-test--rows v 20)
    (set-window-buffer (split-window) (current-buffer))
    (let ((drgnx-view-live-test--owned nil))
      (advice-add 'set-window-start :before #'drgnx-view-live-test--note-owned)
      (advice-add 'set-window-point :before #'drgnx-view-live-test--note-owned)
      (unwind-protect
          (progn (puthash 3 "changed" drgnx-view-live-test--model)
                 (drgnx-view-dirty v '(3))
                 (drgnx-test-advance 0.1))
        (advice-remove 'set-window-start #'drgnx-view-live-test--note-owned)
        (advice-remove 'set-window-point #'drgnx-view-live-test--note-owned))
      (should (= 4 (length drgnx-view-live-test--owned)))   ; two windows, start and point each
      (should (cl-every #'identity drgnx-view-live-test--owned)))))

;;; wb-view-live-test.el ends here
