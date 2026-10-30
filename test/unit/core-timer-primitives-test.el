;;; core-timer-primitives-test.el --- batch tests: debounce, soon, poll and idle steps over the timer layer -*- lexical-binding: t -*-
(require 'ert)
(require 'bytecomp)                                  ; `byte-compile-warnings' is let-bound below
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar drgnx-timer-prim-test--calls nil "What the test functions saw, newest first.")
(defvar drgnx-timer-prim-test--t0 nil "The virtual time a test started at.")
(defvar drgnx-timer-prim-test--plan nil "What `drgnx-timer-prim-test--poll-fn' does at each call: `done', `wait' or `fail'.")
(defvar drgnx-timer-prim-test--pending nil "What the stubbed `input-pending-p' answers.")
(defvar drgnx-timer-prim-test--work 0 "Steps left for `drgnx-timer-prim-test--step'.")
(defvar drgnx-timer-prim-test--on-step nil "Called by the step after it logged itself, then cleared.")

(defun drgnx-timer-prim-test--ms () (round (* 1000 (- (drgnx-test-clock-now) drgnx-timer-prim-test--t0))))
(defun drgnx-timer-prim-test--idle-ms () (round (* 1000 (float-time (drgnx-timer--idle-time)))))
(defun drgnx-timer-prim-test--log () (reverse drgnx-timer-prim-test--calls))

(defun drgnx-timer-prim-test--note (&rest args)
  (push (cons (drgnx-timer-prim-test--ms) args) drgnx-timer-prim-test--calls))

(defun drgnx-timer-prim-test--poll-fn (&rest args)
  "Logs (MS poll . ARGS); answers by the plan: `done' is non-nil, `fail' signals."
  (let ((step (pop drgnx-timer-prim-test--plan)))
    (push (cons (drgnx-timer-prim-test--ms) (cons 'poll args)) drgnx-timer-prim-test--calls)
    (when (eq step 'fail) (error "Boom"))
    (eq step 'done)))

(defun drgnx-timer-prim-test--timeout (&rest args)
  (push (cons (drgnx-timer-prim-test--ms) (cons 'timeout args)) drgnx-timer-prim-test--calls))

(defun drgnx-timer-prim-test--step (&rest args)
  "Logs (step IDLE-MS ARGS), runs the one-shot `--on-step', and answers non-nil while work is left."
  (push (list 'step (drgnx-timer-prim-test--idle-ms) args) drgnx-timer-prim-test--calls)
  (let ((hook drgnx-timer-prim-test--on-step))
    (when hook (setq drgnx-timer-prim-test--on-step nil) (funcall hook)))
  (> (cl-decf drgnx-timer-prim-test--work) 0))

(defun drgnx-timer-prim-test--bad-step (&rest _)
  (push (list 'step (drgnx-timer-prim-test--idle-ms)) drgnx-timer-prim-test--calls)
  (error "Boom"))

(defun drgnx-timer-prim-test--boom (&rest _) (error "Boom"))

(defvar tp-hook-a nil) (defvar tp-hook-b nil) (defvar tp-hook-c nil) (defvar tp-hook-d nil) (defvar tp-hook-e nil)
(defun drgnx-timer-prim-test--add-hook (&rest args) (add-hook (car args) #'ignore) nil)
(defun drgnx-timer-prim-test--add-hook-t (&rest args) (add-hook (car args) #'ignore) t)
(defun drgnx-timer-prim-test--finish (&rest _) nil)
(defun drgnx-timer-prim-test--finish-wait (&rest _) nil)

(defun drgnx-timer-prim-test--done (&rest args)
  (push (cons 'done args) drgnx-timer-prim-test--calls))

(defmacro drgnx-timer-prim-test--with (&rest body)
  "BODY on the virtual clock, with no recorded errors, a state dir of its own and the test's variables empty."
  `(let* ((state (make-temp-file "drgnx-timer-prim-state" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
          (drgnx-timer-errors nil) (drgnx-timer-prim-test--calls nil) (drgnx-timer-prim-test--plan nil)
          (drgnx-timer-prim-test--pending nil) (drgnx-timer-prim-test--work 0)
          (drgnx-timer-prim-test--on-step nil) (drgnx-timer-prim-test--t0 nil))
     (unwind-protect
         (drgnx-test-with-clock ()
           (setq drgnx-timer-prim-test--t0 (drgnx-test-clock-now))
           ,@body)
       (delete-directory state t))))

(defun drgnx-timer-prim-test--alloc (thunk)
  "The least `memory-use-counts' delta (CONSES FLOATS VECTOR-CELLS …) of 3 warm runs of byte-compiled THUNK,
less what reading the counters itself costs."
  ;; the runner loads a file's source when it is newer than its .elc, and interpreted code conses for its own
  ;; bookkeeping: measure the library and the fixture's clock seam compiled
  (dolist (fn '(drgnx-timer-debounce drgnx-test--seam-now drgnx-test--float-time))
    (unless (compiled-function-p (symbol-function fn))
      (let ((byte-compile-warnings '(not docstrings))) (byte-compile fn))))
  (let ((f (byte-compile thunk)) (best nil))
    (funcall f)
    (memory-use-counts)
    (let* ((a (memory-use-counts)) (b (memory-use-counts))
           (base (cl-mapcar #'- b a)))
      (dotimes (_ 3)
        (let* ((x (memory-use-counts)) (_ (funcall f)) (y (memory-use-counts))
               (d (cl-mapcar #'- (cl-mapcar #'- y x) base)))
          (setq best (if best (cl-mapcar #'min best d) d)))))
    best))

(defun drgnx-timer-prim-test--install-stub-now ()
  "A `drgnx-timer--now' that advances 5 ms per read."
  (let ((tick 0.0))
    (lambda () (setq tick (+ tick 0.005)))))

;;;; Debounce

(ert-deftest drgnx-timer-prim/debounce-runs-once-with-the-last-args ()
  (drgnx-timer-prim-test--with
   (should (eq 'tp-k (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :args '(a))))
   (drgnx-test-advance 0.2)
   (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :args '(b))
   (drgnx-test-advance 0.2)
   (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :args '(c))   ; now 0.4
   (drgnx-test-advance 0.4)                                                    ; the first timer is due at 0.5: early
   (should-not drgnx-timer-prim-test--calls)
   (should (drgnx-timer-active-p 'tp-k))
   (drgnx-test-advance 0.2)
   (should (equal (drgnx-timer-prim-test--log) '((900 c))))
   (should-not (drgnx-timer-active-p 'tp-k))))

(ert-deftest drgnx-timer-prim/an-early-firing-waits-the-remainder ()
  (drgnx-timer-prim-test--with
   (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :args '(a))
   (drgnx-test-advance 0.3)
   (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :args '(b))
   (drgnx-test-advance 0.2)                                                    ; 0.5: fires early, re-arms for 0.3
   (should-not drgnx-timer-prim-test--calls)
   (should (= 1 (length timer-list)))
   (drgnx-test-advance 0.29)
   (should-not drgnx-timer-prim-test--calls)
   (drgnx-test-advance 0.01)
   (should (equal (drgnx-timer-prim-test--log) '((800 b))))
   (should-not timer-list)))

(ert-deftest drgnx-timer-prim/debounce-while-pending-makes-no-timer ()
  (drgnx-timer-prim-test--with
   (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :args '(a))
   (let* ((timer (car timer-list))
          (d (drgnx-timer-prim-test--alloc
              (lambda ()
                (dotimes (_ 1000)
                  (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :args '(b)))))))
     (should (= 1 (length timer-list)))
     (should (eq timer (car timer-list)))
     (should (= 0 (nth 2 d)))                                  ; vector cells: no timer, no entry
     (should (<= (nth 1 d) 1000))                              ; floats: the one clock read per call
     (should (<= (nth 0 d) 4010)))                             ; conses per call: the &key rest list (measured 4)
   (drgnx-test-advance 1)
   (should (equal (drgnx-timer-prim-test--log) '((500 b))))))

(ert-deftest drgnx-timer-prim/an-idle-debounce-reads-no-clock ()
  (drgnx-timer-prim-test--with
   (let ((reads 0))
     (cl-letf (((symbol-function 'drgnx-timer--now) (lambda () (cl-incf reads) 0.0)))
       (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :idle t :args '(a))
       (let ((d (drgnx-timer-prim-test--alloc
                 (lambda ()
                   (dotimes (_ 1000)
                     (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :idle t :args '(b)))))))
         (should (= 0 reads))
         (should (= 0 (nth 1 d)))                              ; floats
         (should (= 0 (nth 2 d))))))                           ; vector cells
   (should-not timer-list)
   (should (= 1 (length timer-idle-list)))
   (drgnx-test-idle 0.4)
   (should-not drgnx-timer-prim-test--calls)
   (drgnx-test-idle 1)
   (should (equal (drgnx-timer-prim-test--log) '((900 b))))))              ; 0.5 into the second pause

(ert-deftest drgnx-timer-prim/another-kind-on-the-key-is-replaced ()
  (drgnx-timer-prim-test--with
   (drgnx-timer-start 'tp-k 1 #'drgnx-timer-prim-test--note :args '(start))
   (drgnx-timer-debounce 'tp-k 1 #'drgnx-timer-prim-test--note :args '(debounce))
   (should (= 1 (length timer-list)))
   (should (equal (drgnx-timer-pending) '((tp-k :core debounce))))
   (drgnx-timer-soon 'tp-k 2 #'drgnx-timer-prim-test--note :args '(soon))
   (should (= 1 (length timer-list)))
   (should (equal (drgnx-timer-pending) '((tp-k :core soon))))
   (drgnx-timer-debounce 'tp-k 1 #'drgnx-timer-prim-test--note :args '(again))
   (should (= 1 (length timer-list)))
   (drgnx-test-advance 3)
   (should (equal (drgnx-timer-prim-test--log) '((1000 again))))))

(ert-deftest drgnx-timer-prim/a-debounce-owner-that-goes-is-never-called ()
  (drgnx-timer-prim-test--with
   (let ((buf (generate-new-buffer " tp-owner")))
     (should (eq 'tp-k (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :owner buf)))
     (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :owner buf :args '(b))
     (kill-buffer buf)
     (should-not timer-list)
     (should-not (drgnx-timer-active-p 'tp-k))
     (drgnx-test-advance 2)
     (should-not drgnx-timer-prim-test--calls))
   ;; a buffer whose kill hooks do not run: the firing finds the owner gone
   (let ((buf (generate-new-buffer " tp-owner2" t)))
     (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :owner buf)
     (kill-buffer buf)
     (should (drgnx-timer-active-p 'tp-k))
     (drgnx-test-advance 2)
     (should-not drgnx-timer-prim-test--calls)
     (should-not (drgnx-timer-active-p 'tp-k)))))

(ert-deftest drgnx-timer-prim/every-primitive-refuses-a-gone-owner-and-a-lambda ()
  (drgnx-timer-prim-test--with
   (let ((buf (generate-new-buffer " tp-gone")))
     (kill-buffer buf)
     (should-not (drgnx-timer-debounce 'tp-a 1 #'drgnx-timer-prim-test--note :owner buf))
     (should-not (drgnx-timer-soon 'tp-b 1 #'drgnx-timer-prim-test--note :owner buf))
     (should-not (drgnx-timer-poll 'tp-c 1 #'drgnx-timer-prim-test--note :deadline 5 :owner buf))
     (should-not (drgnx-timer-idle-steps 'tp-d 1 #'drgnx-timer-prim-test--step :owner buf))
     (should-not (drgnx-timer-pending))
     (should-not (or timer-list timer-idle-list)))
   (should-error (drgnx-timer-debounce 'tp-a 1 (lambda ())) :type 'wrong-type-argument)
   (should-error (drgnx-timer-soon 'tp-a 1 (lambda ())) :type 'wrong-type-argument)
   (should-error (drgnx-timer-poll 'tp-a 1 #'ignore :deadline 5 :on-timeout (lambda ())) :type 'wrong-type-argument)
   (should-error (drgnx-timer-idle-steps 'tp-a 1 #'ignore :on-done (lambda ())) :type 'wrong-type-argument)
   (should-not (drgnx-timer-pending))))

;;;; Firings are not recorded as the module's code

(ert-deftest drgnx-timer-prim/a-module-primitive-firing-is-not-recorded ()
  (drgnx-timer-prim-test--with
   (let ((drgnx-modules--table (list (list 'test/m :doc "a module for the primitive tests")))
         (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
         (drgnx-modules--features nil) (drgnx-modules--left nil))
     (unwind-protect
         (progn
           (should-not (drgnx-modules--run-setup 'test/m #'ignore))
           (drgnx-modules--record 'test/m 'startup 0 'ok)
           (let ((stack (alist-get 'test/m drgnx-modules--stacks)))
             (drgnx-timer-debounce 'tp-a 0.1 #'drgnx-timer-prim-test--add-hook :args '(tp-hook-a) :owner 'test/m)
             (drgnx-timer-soon 'tp-b 0.1 #'drgnx-timer-prim-test--add-hook :args '(tp-hook-b) :owner 'test/m)
             (drgnx-timer-poll 'tp-c 0.1 #'drgnx-timer-prim-test--add-hook-t :deadline 5 :args '(tp-hook-c)
                               :owner 'test/m)
             (drgnx-timer-poll 'tp-d 0.5 #'drgnx-timer-prim-test--finish-wait :deadline 1 :args '(tp-hook-d)
                               :on-timeout #'drgnx-timer-prim-test--add-hook :owner 'test/m)
             (drgnx-timer-idle-steps 'tp-e 0.2 #'drgnx-timer-prim-test--finish :args '(tp-hook-e)
                                     :on-done #'drgnx-timer-prim-test--add-hook :owner 'test/m)
             (drgnx-test-advance 2)
             (drgnx-test-idle 1)
             (dolist (hook '(tp-hook-a tp-hook-b tp-hook-c tp-hook-d tp-hook-e))
               (should (memq #'ignore (symbol-value hook))))
             (should (equal stack (alist-get 'test/m drgnx-modules--stacks)))   ; no net: nothing recorded
             (should-not drgnx-modules--left)))
       (dolist (hook '(tp-hook-a tp-hook-b tp-hook-c tp-hook-d tp-hook-e)) (set hook nil))))))

;;;; Soon

(ert-deftest drgnx-timer-prim/soon-runs-once-per-burst-with-the-first-args ()
  (drgnx-timer-prim-test--with
   (should (eq 'tp-k (drgnx-timer-soon 'tp-k 0.1 #'drgnx-timer-prim-test--note :args '(a))))
   (drgnx-test-advance 0.05)
   (should (eq 'tp-k (drgnx-timer-soon 'tp-k 0.1 #'drgnx-timer-prim-test--note :args '(b))))
   (should (= 1 (length timer-list)))
   (drgnx-test-advance 0.1)
   (should (equal (drgnx-timer-prim-test--log) '((100 a))))
   (drgnx-timer-soon 'tp-k 0.1 #'drgnx-timer-prim-test--note :args '(c))        ; a new burst
   (drgnx-test-advance 0.2)
   (should (equal (drgnx-timer-prim-test--log) '((100 a) (250 c))))))

(ert-deftest drgnx-timer-prim/min-interval-holds ()
  (drgnx-timer-prim-test--with
   (drgnx-timer-soon 'tp-k 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4 :args '(a))
   (drgnx-test-advance 0.1)
   (should (equal (drgnx-timer-prim-test--log) '((100 a))))
   (drgnx-timer-soon 'tp-k 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4 :args '(b))
   (drgnx-test-advance 0.39)
   (should (equal (drgnx-timer-prim-test--log) '((100 a))))
   (drgnx-test-advance 0.01)
   (should (equal (drgnx-timer-prim-test--log) '((100 a) (500 b))))
   ;; long after the last run the delay is SECS again
   (drgnx-test-advance 5)
   (drgnx-timer-soon 'tp-k 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4 :args '(c))
   (drgnx-test-advance 0.1)
   (should (equal (drgnx-timer-prim-test--log) '((100 a) (500 b) (5600 c))))))

(ert-deftest drgnx-timer-prim/soon-idle-runs-in-the-pause ()
  (drgnx-timer-prim-test--with
   (drgnx-timer-soon 'tp-k 0.5 #'drgnx-timer-prim-test--note :idle t :args '(a))
   (drgnx-timer-soon 'tp-k 0.5 #'drgnx-timer-prim-test--note :idle t :args '(b))
   (should-not timer-list)
   (should (= 1 (length timer-idle-list)))
   (drgnx-test-idle 0.4)
   (should-not drgnx-timer-prim-test--calls)
   (drgnx-test-idle 1)
   (should (equal (drgnx-timer-prim-test--log) '((900 a))))))

(ert-deftest drgnx-timer-prim/cancel-forgets-the-last-run ()
  (drgnx-timer-prim-test--with
   (drgnx-timer-soon 'tp-k 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4)
   (drgnx-test-advance 0.1)
   (should (gethash 'tp-k drgnx-timer--last-run))
   (drgnx-timer-cancel 'tp-k)
   (should-not (gethash 'tp-k drgnx-timer--last-run))
   (drgnx-timer-soon 'tp-k 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4)
   (drgnx-test-advance 0.1)
   (should (equal (drgnx-timer-prim-test--log) '((100) (200))))))

(ert-deftest drgnx-timer-prim/an-owner-that-goes-and-a-reset-forget-the-last-run ()
  (drgnx-timer-prim-test--with
   (with-temp-buffer
     (let ((buf (current-buffer)) (key (cons 'tp-v (current-buffer))))
       (drgnx-timer-soon key 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4 :owner buf)
       (drgnx-test-advance 0.1)
       (should (eq buf (cdr (gethash key drgnx-timer--last-run))))
       (should (floatp (car (gethash key drgnx-timer--last-run))))
       (drgnx-timer-cancel-owner buf)
       (should-not (gethash key drgnx-timer--last-run))))
   ;; a killed buffer takes its entry with it, though no timer is pending
   (let* ((buf (generate-new-buffer " tp-last")) (key (cons 'tp-v buf)))
     (drgnx-timer-soon key 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4 :owner buf)
     (drgnx-test-advance 0.1)
     (should (gethash key drgnx-timer--last-run))
     (kill-buffer buf)
     (should-not (gethash key drgnx-timer--last-run)))
   (drgnx-timer-soon 'tp-w 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4)
   (drgnx-test-advance 0.1)
   (should (= 1 (hash-table-count drgnx-timer--last-run)))
   (drgnx-timer-reset)
   (should (= 0 (hash-table-count drgnx-timer--last-run)))))

;; T3-2: a clock that steps back never stretches a wait beyond its SECS (or MIN-INTERVAL)
(ert-deftest drgnx-timer-prim/a-clock-stepped-back-does-not-stretch-a-debounce ()
  (drgnx-timer-prim-test--with
   (drgnx-timer-debounce 'tp-k 0.5 #'drgnx-timer-prim-test--note :args '(a))
   (cl-letf (((symbol-function 'drgnx-timer--now) (lambda () (- (float-time) 100))))
     (drgnx-test-advance 0.5)                 ; due; the stepped-back clock says 100 s are left, SECS caps the hop
     (should-not drgnx-timer-prim-test--calls)
     (should (<= (float-time (time-subtract (drgnx-test--due (car timer-list)) drgnx-test--now)) 0.501)))
   (drgnx-test-advance 0.5)                   ; the clock is right again: it runs
   (should (equal (drgnx-timer-prim-test--log) '((1000 a))))))

(ert-deftest drgnx-timer-prim/a-clock-stepped-back-does-not-stretch-a-throttle ()
  (drgnx-timer-prim-test--with
   (drgnx-timer-soon 'tp-k 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4 :args '(a))
   (drgnx-test-advance 0.1)                   ; the last run is stamped 0.1
   (cl-letf (((symbol-function 'drgnx-timer--now) (lambda () (- (float-time) 100))))
     (drgnx-timer-soon 'tp-k 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4 :args '(b))   ; last is "in the future"
     (drgnx-test-advance 0.4))
   (should (equal (drgnx-timer-prim-test--log) '((100 a) (500 b))))))

;; T3-3: a (SYM . BUFFER) key that the buffer does not own still loses its last-run entry when the buffer dies
(ert-deftest drgnx-timer-prim/a-killed-key-buffer-forgets-the-last-run-of-a-core-timer ()
  (drgnx-timer-prim-test--with
   (let* ((buf (generate-new-buffer " tp-key")) (key (cons 'tp-v buf)))
     (drgnx-timer-soon key 0.1 #'drgnx-timer-prim-test--note :min-interval 0.4)   ; :core owner
     (drgnx-test-advance 0.1)
     (should (eq :core (cdr (gethash key drgnx-timer--last-run))))
     (kill-buffer buf)
     (should-not (gethash key drgnx-timer--last-run)))))

;;;; Poll

(ert-deftest drgnx-timer-prim/poll-stops-when-fn-says-done ()
  (drgnx-timer-prim-test--with
   (setq drgnx-timer-prim-test--plan '(wait wait done))
   (should (eq 'tp-k (drgnx-timer-poll 'tp-k 0.5 #'drgnx-timer-prim-test--poll-fn :deadline 10
                                       :on-timeout #'drgnx-timer-prim-test--timeout :args '(x))))
   (drgnx-test-advance 5)
   (should (equal (drgnx-timer-prim-test--log) '((500 poll x) (1000 poll x) (1500 poll x))))
   (should-not (drgnx-timer-active-p 'tp-k))))

(ert-deftest drgnx-timer-prim/poll-deadline-calls-on-timeout-once ()
  (drgnx-timer-prim-test--with
   (drgnx-timer-poll 'tp-k 0.5 #'drgnx-timer-prim-test--poll-fn :deadline 2
                     :on-timeout #'drgnx-timer-prim-test--timeout :args '(x))
   (drgnx-test-advance 5)
   (should (equal (drgnx-timer-prim-test--log)
                  '((500 poll x) (1000 poll x) (1500 poll x) (2000 timeout x))))
   (should-not (drgnx-timer-active-p 'tp-k))))

(ert-deftest drgnx-timer-prim/poll-without-a-deadline-signals ()
  (drgnx-timer-prim-test--with
   (should (equal '(wrong-type-argument numberp nil)
                  (should-error (drgnx-timer-poll 'tp-k 0.5 #'drgnx-timer-prim-test--poll-fn)
                                :type 'wrong-type-argument)))
   (should-error (drgnx-timer-poll 'tp-k 0.5 #'drgnx-timer-prim-test--poll-fn :deadline 0) :type 'wrong-type-argument)
   (should-error (drgnx-timer-poll 'tp-k 0.5 #'drgnx-timer-prim-test--poll-fn :deadline "5") :type 'wrong-type-argument)
   (should-not (drgnx-timer-pending))
   (should-not timer-list)))

(ert-deftest drgnx-timer-prim/a-failing-poll-stops-and-calls-on-timeout-once ()
  (drgnx-timer-prim-test--with
   (setq drgnx-timer-prim-test--plan '(fail fail fail fail))
   (drgnx-timer-poll 'tp-k 0.5 #'drgnx-timer-prim-test--poll-fn :deadline 60
                     :on-timeout #'drgnx-timer-prim-test--timeout :args '(x))
   (drgnx-test-advance 10)
   (should (equal (drgnx-timer-prim-test--log)
                  '((500 poll x) (1000 poll x) (1500 poll x) (1500 timeout x))))
   (should-not (drgnx-timer-active-p 'tp-k))
   (should (plist-get (car drgnx-timer-errors) :stopped))))

(ert-deftest drgnx-timer-prim/a-failing-on-timeout-is-recorded-and-stops-nothing-else ()
  (drgnx-timer-prim-test--with
   (setq drgnx-timer-prim-test--plan '(wait))
   (drgnx-timer-poll 'tp-k 0.5 #'drgnx-timer-prim-test--poll-fn :deadline 1
                     :on-timeout #'drgnx-timer-prim-test--boom)
   (drgnx-test-advance 3)
   (should (= 1 (length drgnx-timer-errors)))
   (should-not (plist-get (car drgnx-timer-errors) :stopped))
   (should-not (drgnx-timer-active-p 'tp-k))))

(ert-deftest drgnx-timer-prim/poll-owner-gone-calls-no-timeout ()
  (drgnx-timer-prim-test--with
   (let ((buf (generate-new-buffer " tp-poll" t)))               ; no kill hooks: the firing finds it gone
     (drgnx-timer-poll 'tp-k 0.5 #'drgnx-timer-prim-test--poll-fn :deadline 2
                       :on-timeout #'drgnx-timer-prim-test--timeout :owner buf)
     (drgnx-test-advance 0.5)
     (should (equal (drgnx-timer-prim-test--log) '((500 poll))))
     (kill-buffer buf)
     (drgnx-test-advance 5)
     (should (equal (drgnx-timer-prim-test--log) '((500 poll))))
     (should-not (drgnx-timer-active-p 'tp-k)))
   (let ((buf (generate-new-buffer " tp-poll2")))                ; with kill hooks: cancelled at once
     (drgnx-timer-poll 'tp-k 0.5 #'drgnx-timer-prim-test--poll-fn :deadline 2
                       :on-timeout #'drgnx-timer-prim-test--timeout :owner buf)
     (kill-buffer buf)
     (drgnx-test-advance 5)
     (should (equal (drgnx-timer-prim-test--log) '((500 poll)))))))

;;;; Idle steps

(ert-deftest drgnx-timer-prim/all-steps-in-one-pause ()
  (drgnx-timer-prim-test--with
   (setq drgnx-timer-prim-test--work 3)
   (should (eq 'tp-k (drgnx-timer-idle-steps 'tp-k 0.2 #'drgnx-timer-prim-test--step
                                             :args '(x) :on-done #'drgnx-timer-prim-test--done)))
   (drgnx-test-idle 3)
   (should (equal (drgnx-timer-prim-test--log)
                  '((step 200 (x)) (step 200 (x)) (step 200 (x)) (done x))))
   (should-not (drgnx-timer-active-p 'tp-k))
   (should-not timer-idle-list)))

(ert-deftest drgnx-timer-prim/input-stops-between-steps-and-the-next-pause-resumes-after-secs ()
  (drgnx-timer-prim-test--with
   (cl-letf (((symbol-function 'drgnx-timer--input-pending-p) (lambda () drgnx-timer-prim-test--pending)))
     (setq drgnx-timer-prim-test--work 3
           drgnx-timer-prim-test--on-step (lambda () (setq drgnx-timer-prim-test--pending t)))
     (drgnx-timer-idle-steps 'tp-k 0.2 #'drgnx-timer-prim-test--step :on-done #'drgnx-timer-prim-test--done)
     (drgnx-test-idle 1)
     (should (equal (drgnx-timer-prim-test--log) '((step 200 nil))))
     (should (= 1 (length timer-idle-list)))                    ; the starter; no chain
     (should-not (drgnx-timer--entry-chain (gethash 'tp-k drgnx-timer--table)))
     (setq drgnx-timer-prim-test--pending nil)
     (drgnx-test-idle 0.15)                                     ; SECS not yet into the pause
     (should (= 1 (length drgnx-timer-prim-test--calls)))
     (drgnx-test-idle 1)
     (should (equal (drgnx-timer-prim-test--log)
                    '((step 200 nil) (step 200 nil) (step 200 nil) (done)))))))

(ert-deftest drgnx-timer-prim/a-chain-yields-to-pending-input ()
  "A zero-delay chain's next link waits `drgnx-timer-chain-yield' while input is pending, so Emacs's wait returns
to read input queued on `unread-command-events' before the chain goes on; with no input it is 0.0."
  (cl-letf (((symbol-function 'drgnx-timer--input-pending-p) (lambda () drgnx-timer-prim-test--pending)))
    (setq drgnx-timer-prim-test--pending nil)
    (should (eql 0.0 (drgnx-timer-chain-delay)))
    (setq drgnx-timer-prim-test--pending t)
    (should (> drgnx-timer-chain-yield 0))
    (should (eql drgnx-timer-chain-yield (drgnx-timer-chain-delay)))))

(ert-deftest drgnx-timer-prim/chains-running-back-to-back-yield-to-process-input ()
  "Zero-delay links running back to back for `drgnx-timer-chain-span' make the next one wait
`drgnx-timer-chain-yield', so Emacs's wait finds no ripe timer and reads sockets and process output (an emacsclient
waited for a whole Search view's draw).  Every chain's link waits until that yield ends.  A timer armed otherwise
\(the yield's link, a throttle, even one at the integer 0) begins a new run: the pauses between runs never count."
  ;; times in 1/64 s steps from 1024: exact floats, so the span's edge is where the test says
  (let ((now 1024.0) (drgnx-timer--chain-start nil) (drgnx-timer--chain-resume 0) (drgnx-timer-chain-span 0.125)
        (drgnx-timer-chain-yield 0.016)
        (first (drgnx-timer--make :key 'x :kind 'start :secs 0.1))
        (throttle (drgnx-timer--make :key 'x :kind 'start :secs 0))
        (link (drgnx-timer--make :key 'x :kind 'start :secs 0.0)))
    (cl-letf (((symbol-function 'drgnx-timer--input-pending-p) #'ignore)
              ((symbol-function 'drgnx-timer--now) (lambda () now)))
      (let ((delays nil))
        (dotimes (i 9)                                                   ; a first link, then links of 1/64 s
          (let ((drgnx-timer--firing (if (= i 0) first link))) (push (drgnx-timer-chain-delay) delays))
          (setq now (+ now (/ 1.0 64))))
        (setq delays (nreverse delays))
        (should (equal (take 8 delays) (make-list 8 0.0)))               ; under the span: back to back
        (should (eql (nth 8 delays) 0.016)))                             ; at the span: this link waits
      (setq now (- now (/ 1.0 64) (- (/ 1.0 256))))                      ; 1/256 s into the yield
      (let* ((drgnx-timer--firing link) (other (drgnx-timer-chain-delay)))   ; another chain's link, during it
        (should (> other 0))
        (should (<= other 0.016)))
      (setq now (+ now 0.02))
      (let ((drgnx-timer--firing (drgnx-timer--make :key 'x :kind 'start :secs 0.016)))
        (should (eql 0.0 (drgnx-timer-chain-delay))))                    ; the link that waited: a new run
      (let ((drgnx-timer--firing link))
        (setq now (+ now 0.1))
        (should (eql 0.0 (drgnx-timer-chain-delay))))
      ;; a later chain whose first draw is a throttle at 0: a new run, the pause before it never counts
      (setq now (+ now 5.0))
      (let ((drgnx-timer--firing throttle)) (should (eql 0.0 (drgnx-timer-chain-delay))))
      (let ((drgnx-timer--firing link)) (should (eql 0.0 (drgnx-timer-chain-delay)))))))

(ert-deftest drgnx-timer-prim/budget-bounds-a-firing ()
  (drgnx-timer-prim-test--with
   (cl-letf (((symbol-function 'drgnx-timer--now) (drgnx-timer-prim-test--install-stub-now)))
     (setq drgnx-timer-prim-test--work 5)
     (drgnx-timer-idle-steps 'tp-k 0.2 #'drgnx-timer-prim-test--step :on-done #'drgnx-timer-prim-test--done)
     (drgnx-test-idle 3)
     ;; 2 steps per firing (5 ms a read, 8 ms budget); the chain, SECS after each firing, does the rest in this pause
     (should (equal (drgnx-timer-prim-test--log)
                    '((step 200 nil) (step 200 nil) (step 400 nil) (step 400 nil) (step 600 nil) (done))))
     (should-not timer-idle-list))))

(ert-deftest drgnx-timer-prim/a-stale-chain-never-delays-the-starter ()
  (drgnx-timer-prim-test--with
   (cl-letf (((symbol-function 'drgnx-timer--now) (drgnx-timer-prim-test--install-stub-now)))
     (setq drgnx-timer-prim-test--work 10)
     (drgnx-timer-idle-steps 'tp-k 0.2 #'drgnx-timer-prim-test--step)
     (drgnx-test-idle 1 :input-at 0.3)                          ; the chain, due at 0.4, never runs
     (should (= 2 (length drgnx-timer-prim-test--calls)))
     (should (= 2 (length timer-idle-list)))
     (let ((stale (drgnx-timer--entry-chain (gethash 'tp-k drgnx-timer--table))))
       (should (memq stale timer-idle-list))
       (drgnx-test-idle 0.25)                                   ; the starter runs 0.2 into the next pause
       (should (equal (mapcar #'cadr (drgnx-timer-prim-test--log)) '(200 200 200 200)))
       (should-not (memq stale timer-idle-list))
       (should (= 2 (length timer-idle-list))))
     (drgnx-timer-cancel 'tp-k))))

(ert-deftest drgnx-timer-prim/interruptible-aborts-a-step ()
  (drgnx-timer-prim-test--with
   (setq drgnx-timer-prim-test--work 3
         drgnx-timer-prim-test--on-step (lambda () (throw throw-on-input t)))   ; what arriving input does
   (drgnx-timer-idle-steps 'tp-k 0.2 #'drgnx-timer-prim-test--step :interruptible t
                           :on-done #'drgnx-timer-prim-test--done)
   (drgnx-test-idle 1)
   (should (equal (drgnx-timer-prim-test--log) '((step 200 nil))))
   (should (= 3 drgnx-timer-prim-test--work))                   ; the step did not finish
   (should (= 1 (length timer-idle-list)))                      ; no chain
   (drgnx-test-idle 1)                                          ; STEP runs again; its value t is more work, not an abort
   (should (equal (drgnx-timer-prim-test--log)
                  '((step 200 nil) (step 200 nil) (step 200 nil) (step 200 nil) (done))))
   (should-not (drgnx-timer-active-p 'tp-k))))

(ert-deftest drgnx-timer-prim/done-cancels-both-timers-and-runs-on-done ()
  (drgnx-timer-prim-test--with
   (cl-letf (((symbol-function 'drgnx-timer--now) (drgnx-timer-prim-test--install-stub-now)))
     (setq drgnx-timer-prim-test--work 3)
     (drgnx-timer-idle-steps 'tp-k 0.2 #'drgnx-timer-prim-test--step :args '(a b)
                             :on-done #'drgnx-timer-prim-test--done)
     (drgnx-test-idle 0.3)                                      ; steps 1 and 2, then the chain is armed
     (should (= 2 (length timer-idle-list)))
     (drgnx-test-idle 0.5)                                      ; the chain runs step 3: done
     (should (equal (car drgnx-timer-prim-test--calls) '(done a b)))
     (should-not timer-idle-list)
     (should-not (drgnx-timer-active-p 'tp-k)))))

(ert-deftest drgnx-timer-prim/a-clientless-daemon-pause-runs-them-all ()
  (drgnx-timer-prim-test--with
   (cl-letf (((symbol-function 'drgnx-timer--now) (drgnx-timer-prim-test--install-stub-now)))
     (setq drgnx-timer-prim-test--work 20)
     (drgnx-timer-idle-steps 'tp-k 0.2 #'drgnx-timer-prim-test--step :on-done #'drgnx-timer-prim-test--done)
     (drgnx-test-idle 30)
     (let ((log (drgnx-timer-prim-test--log)))
       (should (= 20 (cl-count 'step log :key #'car)))
       (should (equal (car (last log)) '(done)))
       (should (= 2000 (cadr (car (last log 2)))))))
   (should-not (drgnx-timer-active-p 'tp-k))
   (should-not timer-idle-list)))

(ert-deftest drgnx-timer-prim/a-failing-step-ends-its-firing-and-three-in-a-row-stop ()
  (drgnx-timer-prim-test--with
   (drgnx-timer-idle-steps 'tp-k 0.2 #'drgnx-timer-prim-test--bad-step :on-done #'drgnx-timer-prim-test--done)
   (drgnx-test-idle 1)
   (should (= 1 (length drgnx-timer-prim-test--calls)))         ; one failure per firing, no chain
   (should (= 1 (length timer-idle-list)))
   (drgnx-test-idle 1)
   (drgnx-test-idle 1)
   (should (= 3 (length drgnx-timer-prim-test--calls)))
   (should-not (drgnx-timer-active-p 'tp-k))
   (should (plist-get (car drgnx-timer-errors) :stopped))
   (should-not (assq 'done drgnx-timer-prim-test--calls))))

(provide 'core-timer-primitives-test)
;;; core-timer-primitives-test.el ends here
