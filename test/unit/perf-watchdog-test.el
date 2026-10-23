;;; perf-watchdog-test.el --- batch tests: the perf lab's stall-watchdog rows (env switch, stalls probe, GC and budget rows) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-perf)
(require 'drgnx-paths)

;; special here too: without the feature (Emacs 31.1), the stubs' `let' would otherwise bind them lexically
;; (`features' is not special in Emacs either: fns.c makes it non-special)
(defvar features)
(defvar nidhogg-watchdog-mode)
(defvar nidhogg-watchdog-threshold)
(defvar nidhogg-watchdog-record-functions)

(defmacro perf-watchdog-test--with-feature (&rest body)
  "Run BODY as if `nidhogg-watchdog' were loaded, with its mode and functions stubbed."
  `(let ((features (cons 'nidhogg-watchdog features))
         (drgnx-perf--watchdog-applied nil)
         (nidhogg-watchdog-mode nil)
         (nidhogg-watchdog-threshold 100))
     (cl-letf (((symbol-function 'nidhogg-watchdog-mode)
                (lambda (&optional arg) (setq nidhogg-watchdog-mode (and (not (eq arg -1)) t)))))
       ,@body)))

(defun perf-watchdog-test--env (value)
  "The (MODE-ON . THRESHOLD) `drgnx-perf--watchdog-env' leaves with $DRGNX_PERF_WATCHDOG set to VALUE (nil: unset)."
  (let ((process-environment (if value (cons (concat "DRGNX_PERF_WATCHDOG=" value) process-environment)
                               (cons "DRGNX_PERF_WATCHDOG" process-environment))))
    (perf-watchdog-test--with-feature
     (drgnx-perf--watchdog-env)
     (cons nidhogg-watchdog-mode nidhogg-watchdog-threshold))))

(ert-deftest drgnx-perf/watchdog-env ()
  (should (equal (perf-watchdog-test--env "on") '(t . 1)))
  (should (equal (perf-watchdog-test--env nil) '(t . 100)))
  (should (equal (perf-watchdog-test--env "default") '(t . 100)))
  (should (null (car (perf-watchdog-test--env "off")))))

(ert-deftest drgnx-perf/stalls-probe-shape ()
  (perf-watchdog-test--with-feature
   (let ((drains 0) (drgnx-perf--stalls nil) (nidhogg-watchdog-record-functions nil))
     (setq nidhogg-watchdog-mode t)
     (cl-letf (((symbol-function 'nidhogg-watchdog-drain-now) (lambda () (cl-incf drains)))
               ((symbol-function 'nidhogg-watchdog-stats)
                (lambda (&optional _reset) '(:missed 2 :monitor-cpu-ms 3.5 :drain-p95-ms 1.3))))
       (drgnx-perf--stalls-begin)
       (should (memq #'drgnx-perf--stall-record nidhogg-watchdog-record-functions))
       (funcall #'drgnx-perf--stall-record '(:wall-ms 120.0 :felt t))
       (funcall #'drgnx-perf--stall-record '(:wall-ms 40.0 :felt nil))
       (let ((r (drgnx-perf--stalls-end)))
         (should (= drains 2))                  ; at the start and the end
         (should-not (memq #'drgnx-perf--stall-record nidhogg-watchdog-record-functions))
         (should (= (plist-get r :stalls) 2))
         (should (= (plist-get r :stalls-felt) 1))
         (should (= (plist-get r :stall-max-ms) 120.0))
         (should (equal (plist-get r :watchdog) '(:missed 2 :monitor-cpu-ms 3.5 :drain-p95-ms 1.3))))))
   (should (equal (drgnx-perf--gc-row '(10.0 30.0 20.0)) '(:count 3 :max 30.0 :p95 30.0)))
   (should (equal (plist-get (drgnx-perf--typing-row '(5 10 20 30)) :ge16) 50.0))))

(ert-deftest drgnx-perf/stalls-probe-without-the-flag ()
  (let ((features (remq 'nidhogg-watchdog features)))
    (should (equal (drgnx-perf--stalls-end) '(:watchdog nil)))
    ;; no stalls row to judge, so nothing fails
    (let ((drgnx-perf-watchdog-gated t))
      (should-not (drgnx-perf-verdict '((typing :watchdog nil :gc (:count 0))) '((typing (:stalls) 0) (typing (:gc :max) 250)))))))

(ert-deftest drgnx-perf/gc-p95-needs-20 ()
  (let ((drgnx-perf-watchdog-gated t) (budgets '((typing (:gc :p95) 50))))
    (should-not (drgnx-perf-verdict `((typing :gc (:count 19 :max 90.0 :p95 90.0))) budgets))
    (should (drgnx-perf-verdict `((typing :gc (:count 20 :max 90.0 :p95 90.0))) budgets))))

(ert-deftest drgnx-perf/budget-rows-parse ()
  (let ((rows (with-temp-buffer
                (insert-file-contents (expand-file-name "test/perf/budgets.eld" drgnx-dir))
                (goto-char (point-min))
                (read (current-buffer)))))
    (dolist (r rows)
      (should (symbolp (car r)))
      (should (consp (cadr r)))
      (should (numberp (nth 2 r))))
    (should (member '(typing (:stalls) 0) rows))
    (should (member '(typing (:gc :max) 250) rows))
    (should (member '(typing (:gc :p95) 50) rows))))

;;; perf-watchdog-test.el ends here
