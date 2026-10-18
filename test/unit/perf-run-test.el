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

(defmacro drgnx-perf-run-test--with-fake-run (loads &rest body)
  "BODY with a fake session (one :measure workload, no budgets) and the load averages LOADS returned one
after another (the last repeats).  Binds `history' (the history file) and `started' (sessions started)."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-perf-run" t)) (history (expand-file-name "perf-history.jsonl" dir))
          (loads ,loads) (started 0)
          (process-environment (append '("DRGNX_PERF_MAX_LOAD=4" "DRGNX_PERF_WAIT=60") process-environment)))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-perf-load) (lambda () (if (cdr loads) (pop loads) (car loads))))
                   ((symbol-function 'sleep-for) #'ignore)
                   ((symbol-function 'drgnx-ui-state-root) (lambda () dir))
                   ((symbol-function 'drgnx-ui-start) (lambda (&rest _) (setq started (1+ started)) '(:name "fake")))
                   ((symbol-function 'drgnx-ui-own-session) (lambda (_) 'sess))
                   ((symbol-function 'drgnx-ui-stop) #'ignore)
                   ((symbol-function 'drgnx-perf-run--make-fixture) (lambda () (make-temp-file "drgnx-perf-fixture")))
                   ((symbol-function 'drgnx-perf-run--workloads) (lambda () '((frames :measure "m"))))
                   ((symbol-function 'drgnx-perf-run--call) (lambda (&rest _) '(:frame (:p50 1 :p95 1 :max 1))))
                   ((symbol-function 'drgnx-perf-run--budgets) #'ignore)
                   ((symbol-function 'drgnx-perf-run--commit) (lambda () "c0")))
           ,@body)
       (delete-directory dir t))))

(ert-deftest drgnx-perf-run/a-machine-busy-during-the-run-is-not-judged-nor-kept ()
  ;; DEFERRED M7b-1: a run next to other test suites failed the scrolling budget on unchanged code.
  (drgnx-perf-run-test--with-fake-run '(1.0 9.0)
    (should (eql (drgnx-perf-run) 3))
    (should-not (file-exists-p history))))

(ert-deftest drgnx-perf-run/a-machine-that-stays-busy-is-not-measured ()
  (drgnx-perf-run-test--with-fake-run '(9.0)
    (let ((process-environment (cons "DRGNX_PERF_WAIT=0" process-environment)))
      (should (eql (drgnx-perf-run) 3))
      (should (eql started 0)))))

(ert-deftest drgnx-perf-run/it-waits-for-a-quiet-machine-then-judges ()
  (drgnx-perf-run-test--with-fake-run '(9.0 9.0 1.5 2.0)
    (should (eql (drgnx-perf-run) 0))
    (should (eql started 1))
    (should (eql (plist-get (json-parse-string (with-temp-buffer (insert-file-contents history) (buffer-string)) :object-type 'plist) :load)
                 2.0))))

(ert-deftest drgnx-perf-run/every-input-workload-has-an-input-p95-and-max-budget ()
  "A workload that types or scrolls is judged: a budget row for its p95 and its max (a new workload without one would pass unjudged)."
  (let ((budgets (drgnx-perf-run--budgets)))
    (dolist (w (drgnx-perf-run--workloads))
      (when (plist-get (cdr w) :actions)
        (dolist (path '((:input :p95) (:input :max)))
          (should (seq-find (lambda (b) (and (eq (car b) (car w)) (equal (cadr b) path))) budgets)))))))

(ert-deftest drgnx-perf-run/the-terminal-workloads-run-a-program-not-a-shell ()
  "terminal-typing runs cat, terminal-output a seq loop; their setup forms are readable and name no shell config."
  (let ((ws (drgnx-perf-run--workloads)))
    (dolist (spec '((terminal-typing "\"cat\"") (terminal-output "\"sh\"")))
      (let ((setup (plist-get (cdr (assq (car spec) ws)) :setup)))
        (should (stringp setup))
        (should (consp (read setup)))
        (should (string-match-p (regexp-quote (cadr spec)) setup))
        (should-not (string-match-p "\\.bashrc\\|\\.zshrc\\|SHELL" setup))))
    (should (string-match-p "seq 1 2000" (plist-get (cdr (assq 'terminal-output ws)) :setup)))))


;;; perf-run-test.el ends here
