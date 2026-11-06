;;; core-gc-test.el --- batch tests: GC during and after startup -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx-gc)
(require 'drgnx-paths)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defmacro drgnx-gc-test--clocked (&rest body)
  "BODY on the virtual clock, the idle GC's key cancelled after it."
  (declare (indent 0))
  `(drgnx-test-with-clock (:auto t)
     (unwind-protect (progn ,@body) (drgnx-gc-mode -1) (drgnx-timer-cancel 'gc-idle))))

(ert-deftest drgnx-gc/startup-collects-rarely-then-a-steady-threshold-and-idle-collection ()
  (let ((gc-cons-threshold most-positive-fixnum) (gc-cons-percentage 0.6))
    (drgnx-gc-test--clocked
      (drgnx-gc-setup)
      (should (= gc-cons-threshold drgnx-gc-cons-threshold))
      (should (< gc-cons-percentage 0.6))
      (should (drgnx-timer-active-p 'gc-idle))
      (should (equal (drgnx-timer-describe (car timer-idle-list))
                     '(:key gc-idle :owner :core :kind start :fn drgnx-gc--idle))))))

(ert-deftest drgnx-gc/setup-twice-leaves-one-idle-timer ()
  (let ((gc-cons-threshold most-positive-fixnum) (gc-cons-percentage 0.6))
    (drgnx-gc-test--clocked
      (drgnx-gc-setup)
      (drgnx-gc-setup)                                    ; the key is replaced: once only
      (should (= 1 (length timer-idle-list)))
      (should (equal (drgnx-timer-pending) '((gc-idle :core start))))
      (let ((gcs 0) (gc-cons-threshold 1000000))          ; and it collects, once per pause (after allocation)
        (cl-letf (((symbol-function 'garbage-collect) (lambda () (cl-incf gcs) nil))
                  ((symbol-function 'drgnx-gc--someone-waits-p) (lambda () t)))
          ;; 600000 bytes since the last collection, stated and not allocated: a real allocation can end in a real
          ;; collection (post-gc-hook moves the base) or be dropped by the byte compiler
          (setq drgnx-gc--base (- (drgnx-gc--consed) 600000))
          (drgnx-test-idle (+ drgnx-gc-idle-seconds 1)))
        (should (= gcs 1))))))

(defmacro drgnx-gc-test--pause (consed &rest body)
  "BODY on the virtual clock with the idle collection set up, a threshold of 1,000,000 bytes, CONSED bytes allocated
since the last collection, a frame someone works in, and `garbage-collect' counted in `gcs' (it allocates nothing,
so the share stays what it was)."
  (declare (indent 1))
  `(let ((gc-cons-threshold most-positive-fixnum) (gc-cons-percentage 0.6) (gcs 0))
     (drgnx-gc-test--clocked
       (drgnx-gc-setup)
       (let ((gc-cons-threshold 1000000))
         (cl-letf (((symbol-function 'garbage-collect) (lambda () (cl-incf gcs) nil))
                   ((symbol-function 'drgnx-gc--someone-waits-p) (lambda () t)))
           (setq drgnx-gc--base (- (drgnx-gc--consed) ,consed))
           ,@body)))))

(ert-deftest drgnx-gc/a-pause-in-typing-with-enough-garbage-collects-once ()
  "Pattern D (virtual clock).  The collection moves off the keys into a typing pause: one second without input and
half the threshold allocated since the last collection collect once; a pause with less allocated collects nothing."
  (drgnx-gc-test--pause 600000
    (drgnx-test-idle 1.5)
    (should (= gcs 1)))
  (drgnx-gc-test--pause 300000
    (drgnx-test-idle 1.5)
    (should (= gcs 0))))

(ert-deftest drgnx-gc/input-pending-at-the-pause-collects-nothing ()
  "Pattern D (virtual clock).  A key waiting when the pause's second is up: no collection (the key would wait for it)."
  (drgnx-gc-test--pause 600000
    (drgnx-test-idle 3 :input-at drgnx-gc-idle-seconds)
    (should (= gcs 0))))

(defun drgnx-gc-test--again ()
  "A second look in the same pause, as a second idle timer would make it."
  (drgnx-gc--idle))

(ert-deftest drgnx-gc/a-second-tick-in-the-same-pause-collects-nothing ()
  "Pattern D (virtual clock).  One collection per pause however often the idle collection is asked in it (the
counted `garbage-collect' leaves the allocation where it was, so only the pause rule stops a second one); the next
pause may collect again."
  (drgnx-gc-test--pause 600000
    (drgnx-timer-start 'gc-test-again (+ drgnx-gc-idle-seconds 0.5) #'drgnx-gc-test--again :idle t :owner :core)
    (unwind-protect (drgnx-test-idle 3) (drgnx-timer-cancel 'gc-test-again))
    (should (= gcs 1))
    (drgnx-test-advance 1)
    (drgnx-test-idle 1.5)
    (should (= gcs 2))))

(ert-deftest drgnx-gc/batch-and-a-daemon-without-a-client-frame-never-collect-at-idle ()
  "Pattern D.  Nobody types in a batch Emacs or in a daemon no client is connected to: no idle collection there."
  (should noninteractive)
  (should-not (drgnx-gc--someone-waits-p)))

(ert-deftest drgnx-gc/early-init-defers-collection-while-starting-and-always-ends-it ()
  ;; bounded while starting; restored after startup even when drgnx-init never ran (I4)
  (let ((gc-cons-threshold 800000) (gc-cons-percentage 0.1) (default-frame-alist default-frame-alist)
        (emacs-startup-hook nil) (load-prefer-newer load-prefer-newer)
        (process-environment (seq-remove (lambda (e) (string-prefix-p "DRGNX_STARTUP_TRACE=" e)) process-environment))
        (early (expand-file-name "init/early-init.el" drgnx-dir)))
    (load early nil t)
    (should (> gc-cons-threshold (* 100 1024 1024)))
    (should (< gc-cons-threshold most-positive-fixnum))
    (run-hooks 'emacs-startup-hook)                       ; drgnx-init did not run
    (should (<= gc-cons-threshold drgnx-gc-cons-threshold))))

(ert-deftest drgnx-gc/a-failing-drgnx-init-still-sets-the-steady-threshold ()
  (require 'drgnx)
  ;; on the virtual clock: the timers the steps before the failure start (the notice session file's, …) end with it
  (let ((gc-cons-threshold most-positive-fixnum))
    (drgnx-test-with-clock (:allow-pending t :auto t)
      (cl-letf (((symbol-function 'drgnx-guard-mode) #'ignore) ((symbol-function 'drgnx-hooks-install) #'ignore)
                ((symbol-function 'drgnx-pkg-activate) #'ignore) ((symbol-function 'drgnx-pkg-guard-mode) #'ignore)
                ((symbol-function 'drgnx--core-commands) (lambda () (error "Broken"))))
        (unwind-protect
            (progn (should-error (drgnx-init))
                   (should (= gc-cons-threshold drgnx-gc-cons-threshold)))
          (drgnx-gc-mode -1)
          (drgnx-timer-cancel 'gc-idle))))))

(ert-deftest drgnx-gc/the-users-own-threshold-is-kept ()
  ;; M8-5: a threshold the user set (no longer early-init's startup value) is left alone.
  (let ((gc-cons-threshold (* 16 1024 1024)) (gc-cons-percentage 0.2))
    (drgnx-gc-test--clocked
      (drgnx-gc-setup)
      (should (= gc-cons-threshold (* 16 1024 1024)))
      (should (= gc-cons-percentage 0.2))
      (should (drgnx-timer-active-p 'gc-idle)))))

(ert-deftest drgnx-gc/gcmh-is-left-to-do-its-work ()
  ;; M8-5: gcmh-mode collects at idle and sets the threshold itself: no idle timer, no threshold.
  (skip-unless (not (boundp 'gcmh-mode)))   ; never shadow a loaded gcmh
  (let ((gc-cons-threshold (* 1024 1024 1024)))
    (set 'gcmh-mode t)
    (unwind-protect
        (progn (drgnx-gc-setup)
               (should (= gc-cons-threshold (* 1024 1024 1024)))
               (should-not (drgnx-timer-active-p 'gc-idle)))
      (drgnx-gc-mode -1)
      (drgnx-timer-cancel 'gc-idle)
      (makunbound 'gcmh-mode))))

;;; core-gc-test.el ends here
