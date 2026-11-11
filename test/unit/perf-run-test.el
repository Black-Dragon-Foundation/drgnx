;;; perf-run-test.el --- batch tests: the perf runner (repeats, teardown, the daemon probe) -*- lexical-binding: t -*-
;; test-class: det
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
  :tags '(:cond)
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
                   ((symbol-function 'drgnx-perf-run--compiled) #'ignore)   ; no tree to build: the session is fake
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

(ert-deftest drgnx-perf-run/a-run-waits-for-native-compilation-before-its-first-workload ()
  "Pattern D.  A built tree's session compiles the files it loads natively, in the background, when it starts; the
first workload (typing) paid for it (its calibration loop ran 4x slower than the later workloads').  The run waits for
that to drain (`drgnx-perf-ab--settle-form', as an A/B does) before it calibrates or measures anything."
  (drgnx-perf-run-test--with-fake-run '(1.0)
    (let* ((forms nil) (fake (symbol-function 'drgnx-perf-run--call)))
      (cl-letf (((symbol-function 'drgnx-perf-run--call) (lambda (s form &rest r) (push form forms) (apply fake s form r))))
        (with-output-to-string (drgnx-perf-run)))
      (setq forms (nreverse forms))
      (let ((settle (seq-position forms drgnx-perf-ab--settle-form))
            (calibrate (seq-position forms "(drgnx-perf-calibrate)")))
        (should settle)
        (should calibrate)
        (should (< settle calibrate))))))

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
  (let ((process-environment (append '("DRGNX_MODAL_ELPA=/tmp/drgnx-elpa-x" "DRGNX_CHILDFRAME_ELPA=/tmp/drgnx-cf-x")
                                     process-environment)))   ; the evil and popup workloads exist with them
    (dolist (u drgnx-perf-run-unseeded)
      (should (assq (car u) (drgnx-perf-run--workloads)))
      (should (stringp (cdr u))))))

(ert-deftest drgnx-perf-run/the-container-skip-list-names-workloads-with-reasons-and-seeds-none ()
  ;; a workload the GUI container cannot run is named and left out there (it would fail the lab); it is also unseeded
  (let ((process-environment (cons "DRGNX_MODAL_ELPA=/tmp/drgnx-elpa-x" process-environment)))
    (dolist (u drgnx-perf-run-container-skipped)
      (should (assq (car u) (drgnx-perf-run--workloads)))
      (should (assq (car u) drgnx-perf-run-unseeded))
      (should (stringp (cdr u))))))

(ert-deftest drgnx-perf-run/the-terminal-workloads-run-in-the-container ()
  ;; drgnx's terminal needs no package: the terminal workloads are never skipped, and their setup starts the workload's
  ;; hub (its worker beside it) and runs tools/term on it
  (let ((process-environment (cons "DRGNX_USER_ELPA" process-environment)))
    (should-not (drgnx-perf-run--container-skip 'terminal-output))
    (should-not (drgnx-perf-run--container-skip 'terminal-typing))
    (should (stringp (drgnx-perf-run--container-skip 'live-view)))
    (let ((setup (plist-get (cdr (assq 'terminal-output (drgnx-perf-run--workloads))) :setup)))
      (should (string-search "(drgnx-perf--hub-start nil)" setup))
      (should (string-search "drgnx-term-start" setup)))))

(ert-deftest drgnx-perf-run/the-live-view-runs-in-the-container-with-websocket ()
  ;; DRGNX_USER_ELPA with a websocket package: live-view is not skipped, its setup names that directory and counts
  ;; blank frames (its :measure)
  (let ((elpa (make-temp-file "drgnx-perf-elpa" t)))
    (unwind-protect
        (let ((process-environment (cons (concat "DRGNX_USER_ELPA=" elpa) process-environment)))
          (should (stringp (drgnx-perf-run--container-skip 'live-view)))
          (make-directory (expand-file-name "websocket-1.16" elpa))
          (should-not (drgnx-perf-run--container-skip 'live-view))
          (let ((w (cdr (assq 'live-view (drgnx-perf-run--workloads)))))
            (should (string-search (prin1-to-string elpa) (plist-get w :setup)))
            (should (equal (plist-get w :measure) "(drgnx-perf--live-measure)"))
            (should (string-search "drgnx-perf--live-blank-sample" (plist-get w :setup)))))
      (delete-directory elpa t))))

(ert-deftest drgnx-perf-run/the-terminal-workloads-run-a-program-not-a-shell ()
  "terminal-typing runs cat, terminal-output a seq loop; their setup forms are readable and name no shell config."
  (let ((ws (drgnx-perf-run--workloads)))
    (dolist (spec '((terminal-typing "\"cat\"") (terminal-output "\"sh\"")))
      (let ((setup (plist-get (cdr (assq (car spec) ws)) :setup)))
        (should (stringp setup))
        (should (consp (read setup)))
        (should (string-match-p (regexp-quote (cadr spec)) setup))
        (should (string-match-p "tools/term\\_>" setup))   ; the session's modules ran before its hub: the module runs here
        (should (string-match-p "need the tools/term module" setup))   ; and the workload stops when it did not reach ok
        (should-not (string-match-p "\\.bashrc\\|\\.zshrc\\|SHELL" setup))))
    (should (string-match-p "seq 1 2000" (plist-get (cdr (assq 'terminal-output ws)) :setup)))))

(defvar drgnx-perf-run-test--reach 0 "The furthest point a `forward-sexp' reached (`point-max' for a failed one).")

(defun drgnx-perf-run-test--forward-sexp (f &rest args)
  "Around `forward-sexp': note how far F got in `drgnx-perf-run-test--reach'."
  (condition-case err
      (prog1 (apply f args) (setq drgnx-perf-run-test--reach (max drgnx-perf-run-test--reach (point))))
    (scan-error (setq drgnx-perf-run-test--reach (point-max)) (signal (car err) (cdr err)))))

(ert-deftest drgnx-perf-run/typing-at-the-fixtures-spot-never-scans-past-its-form ()
  "Pattern D (pure: the real fixture in a buffer, the typing workload's characters inserted one by one and the line
fontified after each, as redisplay does; no session, no clock).  The fixture is core/ three times, so where its middle
falls changes with every core file; when the keys went to a line with too few lists around it, each `(let ((x' typed
left a list open past its form, and Emacs Lisp's font-lock (`lisp--el-funcall-position-p', through `forward-sexp')
scanned the rest of the 4 MB file at every key.  The keys go to a spot of the fixture's own, the same in every tree:
no `forward-sexp' of the font-lock goes past the form that holds it."
  (let* ((drgnx-perf-run--fixture (drgnx-perf-run--make-fixture))
         (text (mapconcat (lambda (a) (plist-get a :type)) (plist-get (cdr (assq 'typing (drgnx-perf-run--workloads))) :actions) ""))
         (drgnx-perf-run-test--reach 0))
    (unwind-protect
        (progn
          (should (eq t (eval (read (drgnx-perf-run--visit-fixture-form)) t)))
          (with-current-buffer (find-buffer-visiting drgnx-perf-run--fixture)
            (let* ((top (car (nth 9 (syntax-ppss)))) (end (and top (scan-lists top 1 0))))
              (should top)                      ; inside a form
              (font-lock-set-defaults)
              (font-lock-fontify-region (line-beginning-position) (line-end-position))
              (advice-add 'forward-sexp :around #'drgnx-perf-run-test--forward-sexp)
              (dotimes (i (length text))
                (insert (aref text i))
                (font-lock-fontify-region (line-beginning-position) (line-end-position)))
              (should (<= drgnx-perf-run-test--reach (+ end (length text)))))))
      (advice-remove 'forward-sexp #'drgnx-perf-run-test--forward-sexp)
      (when-let* ((b (find-buffer-visiting drgnx-perf-run--fixture))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
      (delete-file drgnx-perf-run--fixture))))



(ert-deftest drgnx-perf-run/the-typing-workloads-cpu-rows-catch-a-key-spike ()
  "Pattern D.  The typing workloads' CPU rows were 350-420 ms at p90 while one key in ten cost 100-200 ms; with that
gone (seeded 2026-11-05: p90 5-8.5 ms in the GUI container) a key that costs 20 ms at p90, or 15 at p50, fails the
run, also before `DRGNX_PERF_CPU_FACTOR'."
  (let ((budgets (drgnx-perf-run--budgets)))
    (dolist (w '(typing typing-with-ghost remote-typing))
      (dolist (row '(((:cpu_ms :p50) . 15) ((:cpu_ms :p90) . 20)))
        (let ((b (seq-find (lambda (b) (and (eq (car b) w) (equal (cadr b) (car row)))) budgets)))
          (should b)
          (should (<= (nth 2 b) (cdr row))))))))

(ert-deftest drgnx-perf-run/a-profile-wraps-the-measure-and-goes-next-to-the-results ()
  "Pattern D: with $DRGNX_PERF_PROFILE the measure runs under `drgnx-perf-profiled', its report beside the results
file; without it the measure is as written."
  (let (forms)
    (cl-letf (((symbol-function 'drgnx-perf-run--call) (lambda (_s f &rest _) (push f forms) (list :x 1))))
      (with-environment-variables (("DRGNX_PERF_PROFILE" "1") ("DRGNX_PERF_RESULTS" "/out/run.eld"))
        (should (equal (drgnx-perf-run--profile-file "panel-replay") "/out/run-panel-replay.profile.txt"))
        (let ((drgnx-perf-run--profile (drgnx-perf-run--profile-file "panel-replay")))
          (drgnx-perf-run-workload 'sess '(:measure "(m)" :repeat 1))))
      (should (member "(drgnx-perf-profiled \"/out/run-panel-replay.profile.txt\" (lambda () (m)))" forms))
      (setq forms nil)
      (with-environment-variables (("DRGNX_PERF_PROFILE" nil))
        (should-not (drgnx-perf-run--profile-file "panel-replay"))
        (let ((drgnx-perf-run--profile (drgnx-perf-run--profile-file "panel-replay")))
          (drgnx-perf-run-workload 'sess '(:measure "(m)" :repeat 1))))
      (should (member "(m)" forms)))))

(ert-deftest drgnx-perf-run/a-profile-covers-the-typed-keys-of-a-workload-with-actions ()
  "Pattern D: a workload with typed actions is profiled from before its first key to after the work it started is done
\(the profilers start before the recording and stop after the completion wait), not only its measure."
  (let (forms)
    (cl-letf (((symbol-function 'drgnx-perf-run--call) (lambda (_s f &rest _) (push f forms) (list :x 1)))
              ((symbol-function 'drgnx-perf-run--extras) (lambda (_s _spec) (push "extras" forms) nil))
              ((symbol-function 'drgnx-ui-measure) (lambda (_s a) (push (format "keys %S" a) forms))))
      (let ((drgnx-perf-run--profile "/out/run-w.profile.txt"))
        (drgnx-perf-run-workload 'sess '(:actions (a) :measure "(m)" :repeat 1)))
      (setq forms (nreverse forms))
      (let ((begin (seq-position forms "(drgnx-perf-profile-begin)"))
            (keys (seq-position forms "keys (a)"))
            (extras (seq-position forms "extras"))
            (end (seq-position forms "(drgnx-perf-profile-end \"/out/run-w.profile.txt\")")))
        (should (and begin keys extras end (< begin keys extras end))))
      (should (member "(m)" forms))                         ; the measure itself is not wrapped again
      (should-not (cl-some (lambda (f) (string-prefix-p "(drgnx-perf-profiled" f)) forms)))))

(ert-deftest drgnx-perf-run/the-terminal-flood-is-a-wait-the-profiler-can-see-into ()
  "Pattern D: `terminal-flood' types no key and its measure is the wait itself (`drgnx-perf--term-watch'), with the
setup that opens the streaming terminal outside it, so a profile of the measure is the stream's own work; the
terminal workloads that profile only the driver (a file built in the measure) are not it."
  (let ((w (cdr (assq 'terminal-flood (drgnx-perf-run--workloads)))))
    (should w)
    (should-not (plist-get w :actions))
    (should (string-match-p "drgnx-perf--term-watch" (plist-get w :measure)))
    (should (string-match-p "seq 1 2000" (plist-get w :setup)))
    (should (assq 'terminal-flood drgnx-perf-run-unseeded))))

(ert-deftest drgnx-perf-run/a-tree-of-sources-is-built-before-the-run ()
  "Pattern D: a tree with a Lisp file whose .elc is missing or older than it is built before the sessions start (a
run of sources measures the interpreter); a compiled tree is not."
  (let* ((root (make-temp-file "perf-tree" t)) (el (expand-file-name "core/a.el" root)) built)
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-perf-ab--build) (lambda (tree) (push tree built))))
          (make-directory (file-name-directory el))
          (write-region "" nil el nil 'silent)
          (drgnx-perf-run--compiled root)
          (should (equal built (list root)))
          (write-region "" nil (concat el "c") nil 'silent)
          (set-file-times el (time-subtract nil 60))       ; backdated: file times sit on coarse ticks
          (setq built nil)
          (drgnx-perf-run--compiled root)
          (should-not built)
          (set-file-times (concat el "c") (time-subtract nil 120))
          (drgnx-perf-run--compiled root)
          (should (equal built (list root))))
      (delete-directory root t))))

;;; perf-run-test.el ends here

(defvar drgnx-perf--wait-on)            ; the hub form's (special: the wait binds it)
(declare-function drgnx-perf--wait-check nil)

(ert-deftest drgnx-perf-run/a-wait-times-the-change-and-leaves-no-advice ()
  "The agent workloads' wait (`drgnx-perf--wait', from the hub form): after a timer or a hub batch the check notes when
the condition first held, in the wait's buffer, and the wait returns that time; an error inside the wait still takes
its advice off `timer-event-handler' and the hub batch."
  (eval (car (read-from-string (drgnx-perf-run--hub-form))) t)
  (let ((buf (generate-new-buffer " wait")) (flag nil))
    (unwind-protect
        (let ((drgnx-perf--wait-on (list buf (lambda () (and flag (eq (current-buffer) buf))) nil)))
          (drgnx-perf--wait-check)
          (should-not (nth 2 drgnx-perf--wait-on))
          (setq flag t)
          (drgnx-perf--wait-check)
          (let ((met (nth 2 drgnx-perf--wait-on)))
            (should (numberp met))
            (drgnx-perf--wait-check)
            (should (eql met (nth 2 drgnx-perf--wait-on)))))
      (kill-buffer buf)))
  (let ((n 0))
    (should-error (funcall 'drgnx-perf--wait 2 (lambda () (when (> (cl-incf n) 1) (error "Inside the wait")))))
    (should-not (advice-member-p 'drgnx-perf--wait-check 'timer-event-handler))
    (should-not (advice-member-p 'drgnx-perf--wait-check 'drgnx-hub--client-batch))))

(ert-deftest drgnx-perf-run/the-column-may-add-five-percent-over-a-claimed-margin ()
  ;; the breakpoint column judged against the same scroll with hunks' margin and its own claimed and empty: what a user
  ;; sees when a session starts in a file that shows hunks (p50s: n is 60, too few for a p95)
  (let ((res (lambda (g b) `((debug-gutter-scroll :input (:p50 ,g)) (debug-gutter-baseline :input (:p50 ,b))))))
    (should-not (seq-filter (lambda (l) (string-search "debug-gutter-scroll" l))
                            (drgnx-perf-run--relative-fails (funcall res 4.8 4.6))))
    (should (seq-some (lambda (l) (string-search "debug-gutter-scroll input p50" l))
                      (drgnx-perf-run--relative-fails (funcall res 5.0 4.6))))
    ;; one side missing: not judged
    (should-not (drgnx-perf-run--relative-fails '((debug-gutter-scroll :input (:p50 9.0)))))
    ;; the baseline is a workload of its own, with the column's setup
    (should (assq 'debug-gutter-baseline (drgnx-perf-run--workloads)))))
