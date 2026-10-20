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

(ert-deftest drgnx-perf-run/a-measure-joins-an-input-run ()
  ;; replace-retype: the input's numbers and its own (:slice_ms) in one run, medians over the runs
  (let ((n 0))
    (cl-letf (((symbol-function 'drgnx-perf-run--call)
               (lambda (_s f &rest _)
                 (cond ((equal f "(drgnx-perf-end)") (list :input (list :p95 5)))
                       ((equal f "m") (setq n (1+ n)) (list :slice_ms (list :max (* n 2))))
                       (t t))))
              ((symbol-function 'drgnx-ui-measure) #'ignore))
      (let ((r (drgnx-perf-run-workload 'sess '(:actions ((:keys "a")) :measure "m" :repeat 3))))
        (should (= n 3))
        (should (eql (plist-get (plist-get r :input) :p95) 5))
        (should (eql (plist-get (plist-get r :slice_ms) :max) 4))))))

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

(defvar drgnx-perf-run-test--loaded nil "What the fake session's calibration says.")
(defvar drgnx-perf-run-test--gc-now 1 "The fake session's gc-cons-threshold (drgnx's is 1).")

(defmacro drgnx-perf-run-test--with-fake-run (loads &rest body)
  "BODY with a fake session (one :measure workload, no budgets) and the load averages LOADS returned one
after another (the last repeats).  Binds `history' (the history file) and `started' (sessions started)."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "drgnx-perf-run" t)) (history (expand-file-name "perf-history.jsonl" dir))
          (loads ,loads) (started 0))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-perf-load) (lambda () (if (cdr loads) (pop loads) (car loads))))
                   ((symbol-function 'drgnx-ui-state-root) (lambda () dir))
                   ((symbol-function 'drgnx-ui-start) (lambda (&rest _) (setq started (1+ started)) '(:name "fake")))
                   ((symbol-function 'drgnx-ui-own-session) (lambda (_) 'sess))
                   ((symbol-function 'drgnx-ui-stop) #'ignore)
                   ((symbol-function 'drgnx-perf-run--make-fixture) (lambda () (make-temp-file "drgnx-perf-fixture")))
                   ((symbol-function 'drgnx-perf-run--workloads) (lambda () '((frames :measure "m"))))
                   ((symbol-function 'drgnx-perf-run--call)
                    (lambda (_s form &rest _)
                      (cond ((string-match-p "gc-cons-threshold" form) (list :now drgnx-perf-run-test--gc-now :want 1))
                            ((string-match-p "calibrate" form) (list :wall_ms 10.0 :cpu_ms 5.0 :loaded drgnx-perf-run-test--loaded))
                            (t '(:frame (:p50 1 :p95 1 :max 1))))))
                   ((symbol-function 'drgnx-perf-run--budgets) #'ignore)
                   ((symbol-function 'drgnx-perf-run--commit) (lambda () "c0")))
           ,@body)
       (delete-directory dir t))))

(ert-deftest drgnx-perf/a-loaded-machine-is-judged-and-the-wall-numbers-say-so ()
  ;; The load never refuses a run (it did: exit 3, M7b-1): allocation, CPU and rows do not move with it.  The calibration
  ;; marks the wall-clock numbers instead.
  (drgnx-perf-run-test--with-fake-run '(1.0 9.0)
    (let ((drgnx-perf-run-test--loaded t) out)
      (setq out (with-output-to-string (should (eql (drgnx-perf-run) 0))))
      (should (file-exists-p history))
      (should (string-match-p "frame p50 1 p90 nil ms (loaded)" out)))))

(ert-deftest drgnx-perf/results-are-written-as-json ()
  (drgnx-perf-run-test--with-fake-run '(1.0)
    (let* ((file (expand-file-name "out/results.json" dir))
           (process-environment (cons (concat "DRGNX_PERF_RESULTS=" file) process-environment)))
      (cl-letf (((symbol-function 'drgnx-perf-run--workloads) (lambda () '((typing :measure "m"))))
                ((symbol-function 'drgnx-perf-run--call)
                 (lambda (_s form &rest _)
                   (cond ((string-match-p "gc-cons-threshold" form) '(:now 1 :want 1))
                         ((string-match-p "calibrate" form) '(:wall_ms 10.0 :cpu_ms 5.0 :loaded nil))
                         (t '(:input (:n 3 :p50 2.0 :p95 nil) :alloc (:n 3 :p50 120) :rows 7))))))
        (with-output-to-string (drgnx-perf-run)))
      (let* ((j (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string)) :object-type 'plist :null-object nil))
             (r (plist-get (plist-get j :results) :typing)))
        (should (equal (plist-get j :emacs) emacs-version))
        (should (equal (plist-get j :commit) "c0"))
        (should (eql (plist-get (plist-get r :alloc) :p50) 120))
        (should (eql (plist-get r :rows) 7))
        (should (eql (plist-get (plist-get r :input) :p50) 2.0))
        (should (plist-member (plist-get r :input) :p95))                ; null, kept
        (should (eq (plist-get (plist-get r :calibration) :loaded) :false))))))

(ert-deftest drgnx-perf/a-session-at-another-gc-setting-is-refused ()
  ;; HARNESS-GC-1: perf at the settings of a user's session, or not at all
  (drgnx-perf-run-test--with-fake-run '(1.0)
    (let ((drgnx-perf-run-test--gc-now 536870912))
      (should-error (with-output-to-string (drgnx-perf-run)) :type 'error)
      (should-not (file-exists-p history)))))

(ert-deftest drgnx-perf/the-audit-judges-hooks-per-command ()
  (should (equal (drgnx-perf-run--hooks-fails '((typing :hooks (:p90 1.4)) (tabs :hooks (:p90 4.5)) (frames)))
                 '("tabs: hook functions and timers take 4.5 ms per command (p90) > 1.5 ms"))))

(ert-deftest drgnx-perf-run/the-soak-census-fails-a-cache-over-its-cap ()
  (let* ((rows (vector (vector "git-status" "cache" 17 16) (vector "explorer-listing" "cache" 64 64)
                       (vector "statusbar-bar" "memo" 3 :null) (vector "windows" "cache" 900 :null)))
         (r (drgnx-perf-run--census-lines rows)))
    (should (equal '("  cache git-status 17/16" "  cache explorer-listing 64/64" "  memo statusbar-bar 3"
                     "  cache windows 900")
                   (car r)))
    (should (equal '("git-status holds 17, over its cap of 16") (cdr r)))
    (should-not (cdr (drgnx-perf-run--census-lines [])))))

;; The state store's perf baseline (workbench-state Task 1): C-x o across 3 editor groups with the three areas shown.
(ert-deftest drgnx-perf-run/window-switch-is-a-workload ()
  (let* ((spec (cdr (assq 'window-switch (drgnx-perf-run--workloads))))
         (actions (plist-get spec :actions)))
    (should spec)
    (should (plist-get spec :setup))
    (should (plist-get spec :check))
    (should (plist-get spec :repeat))
    (should (= (length actions) 50))
    (should (seq-every-p (lambda (a) (equal a '(:keys "C-x o"))) actions))
    ;; setup: 3 groups, the dock, the panel and the right dock
    (should (string-match-p "drgnx-groups-focus-3" (plist-get spec :setup)))
    (dolist (f '("drgnx-wb-show-sidebar" "'panel" "'right"))
      (should (string-match-p (regexp-quote f) (plist-get spec :setup))))
    ;; the check: the selected window changed 50 times
    (should (string-match-p "50" (plist-get spec :check)))
    (dolist (f '("drgnx-wb-sidebar-showing-p" "'panel" "'right"))      ; and the layout it measures is there
      (should (string-match-p (regexp-quote f) (plist-get spec :check))))))

(ert-deftest drgnx-perf-run/workloads-can-be-filtered ()
  (let ((all '((typing) (window-switch) (frames))))
    (let ((process-environment (cons "DRGNX_PERF_WORKLOADS" process-environment)))   ; unset
      (should (equal (drgnx-perf-run--select all) all)))
    (let ((process-environment (cons "DRGNX_PERF_WORKLOADS=" process-environment)))   ; empty is unset
      (should (equal (drgnx-perf-run--select all) all)))
    (let ((process-environment (cons "DRGNX_PERF_WORKLOADS=window-switch typing" process-environment)))
      (should (equal (drgnx-perf-run--select all) '((typing) (window-switch)))))   ; the runner's order, not the filter's
    (let ((process-environment (cons "DRGNX_PERF_WORKLOADS=window-switch nope" process-environment)))
      (should-error (drgnx-perf-run--select all)))))      ; a typo must not run nothing and pass

(ert-deftest drgnx-perf-run/a-filtered-run-is-judged-on-its-workloads-and-not-kept ()
  (drgnx-perf-run-test--with-fake-run '(1.0)
    (let ((process-environment (cons "DRGNX_PERF_WORKLOADS=frames" process-environment)))
      (cl-letf (((symbol-function 'drgnx-perf-run--workloads) (lambda () '((frames :measure "m") (typing :measure "m"))))
                ((symbol-function 'drgnx-perf-run--budgets)
                 (lambda () '((frames (:frame :p95) 500) (typing (:rows) 0)))))
        (should (eql (drgnx-perf-run) 0))        ; typing's budget is not "not measured"
        (should-not (file-exists-p history))))))  ; a partial run is no history line

;; Review I1: only a filtered run drops the budgets of workloads it did not run.
(ert-deftest drgnx-perf-run/a-full-run-reports-a-budget-with-no-workload ()
  (drgnx-perf-run-test--with-fake-run '(1.0)
    (cl-letf (((symbol-function 'drgnx-perf-run--budgets)
               (lambda () '((frames (:frame :p95) 500) (ghost (:rows) 0)))))
      (should (eql (drgnx-perf-run) 1)))))

(ert-deftest drgnx-perf-run/an-unfiltered-run-keeps-its-history ()
  (drgnx-perf-run-test--with-fake-run '(1.0)
    (should (eql (drgnx-perf-run) 0))
    (should (file-exists-p history))))
(ert-deftest drgnx-perf-run/every-input-workload-has-allocation-cpu-and-rows-budgets ()
  "A workload that types or scrolls is gated: a budget row for its allocation, its CPU and its rows (a new workload
without them would pass unjudged), unless `drgnx-perf-run-unseeded' says why it has none yet."
  (let ((budgets (drgnx-perf-run--budgets)))
    (dolist (w (drgnx-perf-run--workloads))
      (when (plist-get (cdr w) :actions)
        (let ((rows (mapcar (lambda (path) (seq-find (lambda (b) (and (eq (car b) (car w)) (equal (cadr b) path))) budgets))
                            '((:alloc :p50) (:cpu_ms :p90) (:rows)))))
          (if (assq (car w) drgnx-perf-run-unseeded)
              (should-not (seq-some #'identity rows))        ; seeded: take it off the list
            (should (seq-every-p #'identity rows))))))))

(ert-deftest drgnx-perf-run/the-unseeded-list-names-workloads-and-reasons ()
  (let ((process-environment (cons "DRGNX_MODAL_ELPA=/tmp/drgnx-elpa-x" process-environment)))   ; the evil workloads exist with it
    (dolist (u drgnx-perf-run-unseeded)
      (should (assq (car u) (drgnx-perf-run--workloads)))
      (should (stringp (cdr u))))))

(ert-deftest drgnx-perf-run/the-terminal-workloads-run-a-program-not-a-shell ()
  "terminal-typing runs cat, terminal-output a seq loop; their setup forms are readable and name no shell config."
  (let ((ws (drgnx-perf-run--workloads)))
    (dolist (spec '((terminal-typing "\"cat\"") (terminal-output "\"sh\"")))
      (let ((setup (plist-get (cdr (assq (car spec) ws)) :setup)))
        (should (stringp setup))
        (should (consp (read setup)))
        (should (string-match-p (regexp-quote (cadr spec)) setup))
        (should (string-match-p "tools/terminal-eat" setup))   ; the session has no eat package at start: the module runs here
        (should (string-match-p "need the tools/terminal-eat module" setup))   ; and the workload stops when it did not reach ok
        (should-not (string-match-p "\\.bashrc\\|\\.zshrc\\|SHELL" setup))))
    (should (string-match-p "seq 1 2000" (plist-get (cdr (assq 'terminal-output ws)) :setup)))))


;;; perf-run-test.el ends here

(ert-deftest drgnx-perf-run/the-typing-workloads-gate-a-normal-keys-cpu-too ()
  "p90 sits on the 1-in-10 key spike (PERF-KEYSPIKE-1); the p50 row gates the keys that are not spikes."
  (let ((budgets (drgnx-perf-run--budgets)))
    (dolist (w '(typing typing-with-ghost remote-typing))
      (let ((b (seq-find (lambda (b) (and (eq (car b) w) (equal (cadr b) '(:cpu_ms :p50)))) budgets)))
        (should b)
        (should (<= (nth 2 b) 30))))))
