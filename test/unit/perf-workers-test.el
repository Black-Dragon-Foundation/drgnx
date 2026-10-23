;;; perf-workers-test.el --- batch tests: the perf lab's worker rows (DRGNX_PERF_WORKERS, report-only rows, completion metrics, digests, phases, the 2-core shape) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-perf)
(require 'drgnx-perf-run)
(require 'drgnx-paths)
(require 'drgnx-timer)

;; special here too: `features' is not special in Emacs (fns.c), so a `let' of it needs the declaration
(defvar features)

(defun perf-workers-test--applied (value)
  "What `nidhogg-workers-apply' receives when $DRGNX_PERF_WORKERS is VALUE (nil: unset), as the lab applies it."
  (let ((process-environment (if value (cons (concat "DRGNX_PERF_WORKERS=" value) process-environment)
                               (cons "DRGNX_PERF_WORKERS" process-environment)))
        (features (cons 'nidhogg-workers features))
        (drgnx-perf--workers-applied nil) got)
    (cl-letf (((symbol-function 'nidhogg-workers-apply) (lambda (spec) (push spec got))))
      (drgnx-perf--workers-env)
      (drgnx-perf--workers-env))                ; once per session
    got))

(ert-deftest drgnx-perf-workers/env-maps-to-apply ()
  (should (equal (perf-workers-test--applied "off") '("off")))
  (should (equal (perf-workers-test--applied "on") '("on")))
  (should (equal (perf-workers-test--applied "+nidhogg-workers-treesit+nidhogg-treesit-defer")
                 '("+nidhogg-workers-treesit+nidhogg-treesit-defer")))
  (should (equal (perf-workers-test--applied nil) '("default")))
  ;; without the feature: nothing is applied, and the probe says so
  (let ((features (remq 'nidhogg-workers features)) (drgnx-perf--workers-applied nil))
    (should-not (drgnx-perf--workers-env))
    (should (equal (drgnx-perf--workers-end) '(:workers nil)))))

(ert-deftest drgnx-perf-workers/report-only-row ()
  (let ((results '((typing :alloc (:p50 20))))
        (budgets '((typing (:alloc :p50) 10 :report-only ot2))))
    (let ((process-environment (cons "DRGNX_PERF_LANDED" process-environment)))
      (should-not (drgnx-perf-verdict results budgets))
      (should (string-match-p "report" (car (drgnx-perf-report results budgets)))))
    (let ((process-environment (cons "DRGNX_PERF_LANDED=ot2" process-environment)))
      (should (string-match-p "typing alloc p50 20 > 10" (car (drgnx-perf-verdict results budgets))))
      (should-not (drgnx-perf-report results budgets)))
    ;; another step landing does not promote it
    (let ((process-environment (cons "DRGNX_PERF_LANDED=ot1,ot3" process-environment)))
      (should-not (drgnx-perf-verdict results budgets)))))

(ert-deftest drgnx-perf-workers/completion-metric ()
  (let ((now 100.0) (done nil) (drgnx-perf--complete nil))
    (cl-letf (((symbol-function 'drgnx-timer--now) (lambda () now))
              ((symbol-function 'drgnx-timer-start) #'ignore)
              ((symbol-function 'drgnx-timer-cancel) #'ignore))
      (drgnx-perf-complete-begin (lambda () done))
      (setq now 100.05)
      (drgnx-perf-complete-poll)
      (should-not (nth 2 drgnx-perf--complete))
      (setq now 100.12 done t)
      (drgnx-perf-complete-poll)
      (setq now 101.0)                  ; later polls do not move it
      (drgnx-perf-complete-poll)
      (should (equal (drgnx-perf-complete-end) '(:complete-ms 120.0))))
    (should-not drgnx-perf--complete)
    ;; never complete: nil
    (cl-letf (((symbol-function 'drgnx-timer-start) #'ignore)
              ((symbol-function 'drgnx-timer-cancel) #'ignore))
      (drgnx-perf-complete-begin (lambda () nil))
      (should (equal (drgnx-perf-complete-end) '(:complete-ms nil))))))

(defun perf-workers-test--rounds (a b)
  "ROUNDS where the A side's runs are the plists A and B's the plists B (ten rounds)."
  (cl-loop repeat 10 collect (list :a a :b b)))

(ert-deftest drgnx-perf-workers/digest-mismatch-fails-ab ()
  (should (equal (drgnx-perf-ab-digest-verdict (perf-workers-test--rounds '(:digest "x") '(:digest "y")))
                 '(:verdict regressed :why digest)))
  (should (eq (plist-get (drgnx-perf-ab-digest-verdict (perf-workers-test--rounds '(:digest "x") '(:digest "x"))) :verdict)
              'no-regression))
  (should (eq (plist-get (drgnx-perf-ab-digest-verdict (perf-workers-test--rounds '(:input nil) '(:input nil))) :verdict)
              'not-comparable))
  (let ((line (drgnx-perf-ab--extra-lines
               (list :digest-verdict (drgnx-perf-ab-digest-verdict (perf-workers-test--rounds '(:digest "x") '(:digest "y")))))))
    (should (string-match-p "regressed (digest)" line))))

(ert-deftest drgnx-perf-workers/phase-ms-in-verdict ()
  (let* ((run (lambda (wait) (list :workers (list :phase-ms (list :treesit-wait wait :json 5.0)) :input (list :p95 4.0))))
         (rounds (cl-loop for i below 10 collect (list :a (funcall run (+ 2.0 (* 0.1 (% i 3)))) :b (funcall run (+ 5.0 (* 0.1 (% i 3)))))))
         (vs (drgnx-perf-ab-metric-verdicts rounds)))
    (should (eq (plist-get (cdr (assoc '(:workers :phase-ms :treesit-wait) vs)) :verdict) 'regressed))
    (should (eq (plist-get (cdr (assoc '(:workers :phase-ms :json) vs)) :verdict) 'no-regression))
    (should (eq (plist-get (cdr (assoc '(:input :p95) vs)) :verdict) 'no-regression))
    ;; a path neither side reports is left out
    (should-not (assoc '(:complete-ms) vs))))

(ert-deftest drgnx-perf-workers/cpus-cpuset ()
  (should (equal (drgnx-perf-cpuset-args "2") '("--cpuset-cpus" "0-1")))
  (should (equal (drgnx-perf-cpuset-args "4") '("--cpuset-cpus" "0-3")))
  (should-not (drgnx-perf-cpuset-args nil))
  (should-error (drgnx-perf-cpuset-args "3"))
  ;; the container runner builds the same arguments
  (let ((text (with-temp-buffer (insert-file-contents (expand-file-name "bin/drgnx" drgnx-dir)) (buffer-string))))
    (should (string-match-p "--cpuset-cpus 0-1" text))
    (should (string-match-p "--cpuset-cpus 0-3" text))))

;;; perf-workers-test.el ends here
