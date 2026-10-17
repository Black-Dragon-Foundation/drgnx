;;; perf-run-test.el --- batch tests: the perf runner (repeats, teardown, the daemon probe) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-perf-run)

(ert-deftest drgnx-perf-run/measure-workloads-repeat-and-take-medians ()
  ;; I6: frames, redisplay, memory: three runs, medians — never one sample.
  (let ((n 0))
    (cl-letf (((symbol-function 'drgnx-perf-run--call)
               (lambda (_s f &rest _) (when (equal f "x") (setq n (1+ n))) (list :frame (list :p50 (* n 10) :p95 (* n 100) :max (* n 100))))))
      (let ((r (drgnx-perf-run-workload 'sess '(:measure "x" :repeat 3))))
        (should (= n 3))
        (should (eql (plist-get (plist-get r :frame) :p95) 200))))))

(ert-deftest drgnx-perf-run/teardown-runs-when-a-workload-fails ()
  ;; I8
  (let (calls)
    (cl-letf (((symbol-function 'drgnx-perf-run--call) (lambda (_s f &rest _) (push f calls) t))
              ((symbol-function 'drgnx-ui-measure) (lambda (&rest _) (error "Boom"))))
      (should-error (drgnx-perf-run-workload 'sess '(:setup "s" :actions ((:keys "a")) :teardown "TEARDOWN")))
      (should (member "TEARDOWN" calls))
      (should (seq-find (lambda (f) (string-search "drgnx-perf-audit-end" f)) calls)))))   ; the probes are undone too

(ert-deftest drgnx-perf-run/a-daemon-that-never-serves-is-an-error ()
  ;; I1: a daemon that dies (or never answers) is not a fast start.
  (let ((init (make-temp-file "drgnx-perf-init" t)))
    (unwind-protect
        (progn
          (write-region "(kill-emacs 1)\n" nil (expand-file-name "init.el" init) nil 'silent)
          (should-error (drgnx-perf-run-daemon-startup 1 init)))
      (delete-directory init t))))

(ert-deftest drgnx-perf-run/the-daemon-probe-is-isolated ()
  ;; I3: the allowlist and temp dirs, never the controller's whole environment
  (let ((process-environment (append '("SECRET_TOKEN=x" "DRGNX_STARTUP_TRACE=/tmp/t" "DRGNX_SAFE=1") process-environment)))
    (let ((env (drgnx-perf-run--daemon-env "/tmp/drgnx-perf-x")))
      (should-not (seq-find (lambda (e) (string-prefix-p "SECRET_TOKEN=" e)) env))
      (should-not (seq-find (lambda (e) (string-prefix-p "DRGNX_STARTUP_TRACE=" e)) env))
      (should-not (seq-find (lambda (e) (string-prefix-p "DRGNX_SAFE=" e)) env))
      (should (member "HOME=/tmp/drgnx-perf-x/home" env)))))

;;; perf-run-test.el ends here
