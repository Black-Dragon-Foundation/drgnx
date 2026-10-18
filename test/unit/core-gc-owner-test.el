;;; core-gc-owner-test.el --- batch tests: the one GC owner (idle rule, gcmh watcher, gap, batch setup) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-gc)
(require 'drgnx-paths)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defvar gcmh-mode)                      ; the tests bind and set it; only a test makes it bound

(defmacro drgnx-gc-owner-test--with (&rest body)
  "BODY on the virtual clock with the GC settings, the owner's state and `gcmh-mode' restored after it."
  (declare (indent 0))
  `(let ((gc-cons-threshold gc-cons-threshold) (gc-cons-percentage gc-cons-percentage)
         (drgnx-gc--base drgnx-gc--base))
     (skip-unless (not (boundp 'gcmh-mode)))   ; never shadow a loaded gcmh
     (drgnx-test-with-clock ()
       (unwind-protect (progn ,@body)
         (drgnx-gc-mode -1)
         (drgnx-timer-cancel 'gc-idle)
         (makunbound 'gcmh-mode)))))

(defmacro drgnx-gc-owner-test--counting (var &rest body)
  "BODY with `garbage-collect' stubbed: VAR counts its calls."
  (declare (indent 1))
  `(let ((,var 0))
     (cl-letf (((symbol-function 'garbage-collect) (lambda () (cl-incf ,var) nil)))
       ,@body)))

(ert-deftest drgnx-gc/no-idle-collection-without-allocation ()
  (drgnx-gc-owner-test--with
    (setq gc-cons-threshold most-positive-fixnum)
    (drgnx-gc-setup)                                   ; the steady threshold, mode on, key started
    (setq gc-cons-threshold 1200000)
    (drgnx-gc-owner-test--counting gcs
      (setq drgnx-gc--base (drgnx-gc--consed))
      (drgnx-test-idle 9)
      (should (= gcs 0))                                  ; nothing consed since the last collection
      (let ((junk (make-string 400000 ?x)))               ; a third of the threshold
        (ignore junk)
        (drgnx-test-idle 9))
      (should (= gcs 1)))))

(ert-deftest drgnx-gc/consed-weighs-the-counters ()
  (let ((a (drgnx-gc--consed)))
    (let ((junk (make-string 100000 ?x))) (ignore junk))
    (should (>= (- (drgnx-gc--consed) a) 100000))
    (should (integerp a))))

(ert-deftest drgnx-gc/gcmh-off-restores-drgnx ()
  (drgnx-gc-owner-test--with
    (setq gc-cons-threshold most-positive-fixnum)
    (drgnx-gc-setup)
    (set 'gcmh-mode t)
    (should-not (drgnx-timer-active-p 'gc-idle))
    (setq gc-cons-threshold 12345 gc-cons-percentage 0.9)
    (set 'gcmh-mode nil)
    (should (= gc-cons-threshold drgnx-gc-cons-threshold))
    (should (= gc-cons-percentage 0.1))
    (should (drgnx-timer-active-p 'gc-idle))))

(ert-deftest drgnx-gc/gcmh-sets-its-own-threshold-after-the-watcher-and-the-off-hook-restores ()
  ;; gcmh's mode function sets the variable first and its low threshold after: the watcher alone is overwritten.
  (drgnx-gc-owner-test--with
    (setq gc-cons-threshold most-positive-fixnum)
    (drgnx-gc-setup)
    (set 'gcmh-mode t)
    (set 'gcmh-mode nil)
    (setq gc-cons-threshold 800000 gc-cons-percentage 0.3)   ; gcmh-mode's body, after the watcher
    (run-hooks 'gcmh-mode-off-hook)
    (should (= gc-cons-threshold drgnx-gc-cons-threshold))
    (should (= gc-cons-percentage 0.1))
    (drgnx-gc-mode -1)
    (should-not (memq 'drgnx-gc--gcmh-off gcmh-mode-off-hook))))

(ert-deftest drgnx-gc/gcmh-on-cancels-the-idle-collection ()
  (drgnx-gc-owner-test--with
    (setq gc-cons-threshold most-positive-fixnum)
    (drgnx-gc-setup)
    (should (drgnx-timer-active-p 'gc-idle))
    (set 'gcmh-mode t)
    (should-not (drgnx-timer-active-p 'gc-idle))))

(ert-deftest drgnx-gc/a-let-of-gcmh-mode-changes-nothing ()
  (drgnx-gc-owner-test--with
    (setq gc-cons-threshold most-positive-fixnum)
    (drgnx-gc-setup)
    (let ((threshold gc-cons-threshold))
      (let ((gcmh-mode t))
        (should (drgnx-timer-active-p 'gc-idle)))
      (should (drgnx-timer-active-p 'gc-idle))
      (should (= gc-cons-threshold threshold))
      (set 'gcmh-mode t)
      (should-not (drgnx-timer-active-p 'gc-idle))
      (let ((gcmh-mode nil)) nil)                         ; and a let to nil does not start it again
      (should-not (drgnx-timer-active-p 'gc-idle)))))

(ert-deftest drgnx-gc/gap-collects-only-when-quiet-and-nearly-full ()
  (let ((gc-cons-threshold 1000000) (drgnx-gc-gap-quiet 0.02) (idle (seconds-to-time 0.05))
        (pending nil) (drgnx-gc--base 0))
    (cl-letf (((symbol-function 'current-idle-time) (lambda () idle))
              ((symbol-function 'input-pending-p) (lambda (&rest _) pending)))
      (drgnx-gc-owner-test--counting gcs
        (setq drgnx-gc--base (- (drgnx-gc--consed) 900000))   ; 90% of the threshold consed: nearly full
        (setq idle nil)                                       ; busy: no idle time at all
        (should-not (drgnx-gc-gap))
        (setq idle (seconds-to-time 0.01))                    ; quiet for less than `drgnx-gc-gap-quiet'
        (should-not (drgnx-gc-gap))
        (setq idle (seconds-to-time 0.05) pending t)          ; input pending
        (should-not (drgnx-gc-gap))
        (setq pending nil drgnx-gc--base (- (drgnx-gc--consed) 800000))   ; below 85%
        (should-not (drgnx-gc-gap))
        (should (= gcs 0))
        (setq drgnx-gc--base (- (drgnx-gc--consed) 900000))   ; all clear
        (should (eq t (drgnx-gc-gap)))
        (should (= gcs 1))
        (setq drgnx-gc-gap-quiet nil)                         ; nil: never
        (should-not (drgnx-gc-gap))
        (should (= gcs 1))))))

(ert-deftest drgnx-gc/post-gc-note-belongs-to-the-mode ()
  (drgnx-gc-owner-test--with
    (drgnx-gc-mode 1)
    (should (= 1 (cl-count 'drgnx-gc--note post-gc-hook)))
    (drgnx-gc-mode 1)
    (should (= 1 (cl-count 'drgnx-gc--note post-gc-hook)))
    (let ((drgnx-gc--base 0))                              ; a real collection moves the base
      (garbage-collect)
      (should (> drgnx-gc--base 0)))
    (drgnx-gc-mode -1)
    (should-not (memq 'drgnx-gc--note post-gc-hook))
    (should-not (memq 'drgnx-gc--gcmh-changed (get-variable-watchers 'gcmh-mode)))))

(ert-deftest drgnx-gc/batch-setup-sets-32-mb-and-0.2 ()
  (let ((gc-cons-threshold 800000) (gc-cons-percentage 0.1))
    (drgnx-gc-batch-setup)
    (should (= gc-cons-threshold (* 32 1024 1024)))
    (should (= gc-cons-threshold drgnx-gc-batch-threshold))
    (should (= gc-cons-percentage 0.2))))

;;; core-gc-owner-test.el ends here
