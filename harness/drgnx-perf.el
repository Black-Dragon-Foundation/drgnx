;;; drgnx-perf.el --- The perf lab: probes in a session, budgets, history -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Probes run inside a harness session: input latency (a command's start until the screen shows it:
;; a 0 s timer set in post-command-hook, which redisplays before reading the clock — timers can run
;; before the command loop's own redisplay, so without it the redisplay would be left out), forced
;; redisplay time, frame creation, GC (count and time), memory (RSS), a CPU profile of a thunk, and a
;; hook audit (every function on the busy hooks timed, the hooks restored after).  The controller
;; (drgnx-perf-run.el) runs workloads in a session, judges them against budgets
;; (test/perf/budgets.eld) and keeps a history.  See docs/develop/perf.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;;; Statistics

(defun drgnx-perf-stats (values)
  "(:n :p50 :p90 :p95 :p99 :max :mean) of VALUES (nearest rank).  :p95 and :p99 are nil below n = 100: the
tail of fewer samples is the maximum or next to it, and says nothing about the code."
  (if (null values) (list :n 0)
    (let* ((v (sort (copy-sequence values) #'<)) (n (length v))
           (rank (lambda (p) (nth (max 0 (1- (ceiling (* p n)))) v)))
           (tail (>= n 100)))
      (list :n n :p50 (funcall rank 0.5) :p90 (funcall rank 0.9)
            :p95 (and tail (funcall rank 0.95)) :p99 (and tail (funcall rank 0.99)) :max (car (last v))
            :mean (/ (apply #'+ v) (float n))))))

(defun drgnx-perf--round (x) (if (floatp x) (/ (round (* x 10)) 10.0) x))
(defun drgnx-perf--round2 (x) (if (floatp x) (/ (round (* x 100)) 100.0) x))

(defun drgnx-perf-rss-kb ()
  "This Emacs's resident memory in kB: /proc/self/status (Linux), else `process-attributes' (macOS), or 0."
  (or (ignore-errors
        (with-temp-buffer
          (insert-file-contents "/proc/self/status")
          (when (re-search-forward "^VmRSS:[ \t]+\\([0-9]+\\)" nil t) (string-to-number (match-string 1)))))
      (alist-get 'rss (process-attributes (emacs-pid)))
      0))

;;;; Recording input latency, GC, memory

(defvar drgnx-perf--t0 nil "Wall time (s), CPU time (ms) and allocation (sum of `memory-use-counts') at the command's start.")
(defvar drgnx-perf--latencies nil)
(defvar drgnx-perf--allocs nil "Per command: the objects allocated from its start to the redisplay after it.")
(defvar drgnx-perf--cpus nil "Per command: CPU ms over the same span.")
(defvar drgnx-perf--start nil "(gcs-done gc-elapsed rss rows) at the start.")
(defvar drgnx-perf--gc-pauses nil "Each collection's time (ms) while recording.")
(defvar drgnx-perf--gc-last 0.0 "`gc-elapsed' after the last collection seen.")

(defvar drgnx-perf-row-counters
  '(drgnx-explorer--renders drgnx-buffers--renders drgnx-cockpit--draws drgnx-cockpit-edits--draws)
  "Counters of rows drawn; the run's `:rows' is the growth of their sum.  A counter whose library is not
loaded counts 0.  The render pipeline's `drgnx-view-stats' joins them when it exists (DEFERRED).")

(defun drgnx-perf--rows ()
  (let ((sum 0))
    (dolist (s drgnx-perf-row-counters sum)
      (when (and (boundp s) (numberp (symbol-value s))) (setq sum (+ sum (symbol-value s)))))))

(defun drgnx-perf--alloc-sum ()
  "Everything allocated so far: the seven `memory-use-counts' added (the reading's own list is 7 conses)."
  (apply #'+ (memory-use-counts)))

(defun drgnx-perf--cpu-ms ()
  "This process's CPU time in ms (`current-cpu-time': (TICKS . HZ))."
  (let ((c (current-cpu-time))) (/ (* 1000.0 (car c)) (cdr c))))

(defun drgnx-perf--pre ()
  (drgnx-perf--hooks-flush)
  (setq drgnx-perf--t0 (list (float-time) (drgnx-perf--cpu-ms) (drgnx-perf--alloc-sum))))   ; allocation last

(defun drgnx-perf--finish (t0)
  "The 0 s timer: the screen shows the command; record its wall, CPU and allocation."
  (redisplay)                           ; the screen showing the command is part of its latency
  (let ((alloc (drgnx-perf--alloc-sum)))
    (push (- alloc (nth 2 t0) 7) drgnx-perf--allocs)           ; less the first reading's own 7 conses
    (push (- (drgnx-perf--cpu-ms) (nth 1 t0)) drgnx-perf--cpus)
    (push (* 1000 (- (float-time) (car t0))) drgnx-perf--latencies)))

(defun drgnx-perf--post ()
  (when drgnx-perf--t0
    (let ((t0 drgnx-perf--t0))
      (setq drgnx-perf--t0 nil)
      (run-at-time 0 nil #'drgnx-perf--finish t0))))

(defun drgnx-perf--gc ()
  "After each collection: its own time (`gc-elapsed' grows by it)."
  (push (* 1000 (- gc-elapsed drgnx-perf--gc-last)) drgnx-perf--gc-pauses)
  (setq drgnx-perf--gc-last gc-elapsed))

(defun drgnx-perf-begin ()
  "Start recording: every command's latency, every GC pause, memory."
  (setq drgnx-perf--latencies nil drgnx-perf--allocs nil drgnx-perf--cpus nil drgnx-perf--t0 nil
        drgnx-perf--gc-pauses nil drgnx-perf--gc-last gc-elapsed
        drgnx-perf--start (list gcs-done gc-elapsed (drgnx-perf-rss-kb) (drgnx-perf--rows)))
  (add-hook 'pre-command-hook #'drgnx-perf--pre -100)
  (add-hook 'post-command-hook #'drgnx-perf--post 100)
  (add-hook 'post-gc-hook #'drgnx-perf--gc))

(defun drgnx-perf-end ()
  "Stop recording: (:input STATS :alloc STATS :cpu_ms STATS :rows N :gc_count N :gc_ms MS :gc_pause STATS
:rss_kb KB :rss_start_kb KB).  :input is wall ms, :alloc objects, :cpu_ms CPU ms, per command (pre-command-hook
to the redisplay after it); :rows the growth of `drgnx-perf-row-counters'.  Allocation, CPU and rows do not move
with the load on the machine; wall clock does."
  (remove-hook 'pre-command-hook #'drgnx-perf--pre)
  (remove-hook 'post-command-hook #'drgnx-perf--post)
  (remove-hook 'post-gc-hook #'drgnx-perf--gc)
  (pcase-let ((`(,gcs ,elapsed ,rss ,rows) drgnx-perf--start))
    (list :input (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--latencies))
          :alloc (drgnx-perf-stats drgnx-perf--allocs)
          :cpu_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats drgnx-perf--cpus))
          :rows (- (drgnx-perf--rows) rows)
          :gc_count (- gcs-done gcs) :gc_ms (drgnx-perf--round (* 1000 (- gc-elapsed elapsed)))
          :gc_pause (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--gc-pauses))
          :rss_kb (drgnx-perf-rss-kb) :rss_start_kb rss)))

;;;; Redisplay and frames

(defun drgnx-perf-redisplay-ms (n)
  "Stats of N forced redisplays of the selected frame."
  (let (times)
    (dotimes (_ n)
      (force-mode-line-update t)
      (force-window-update)
      (let ((t0 (float-time))) (redisplay t) (push (* 1000 (- (float-time) t0)) times)))
    (mapcar #'drgnx-perf--round (drgnx-perf-stats times))))

(defun drgnx-perf-frame-ms (n)
  "Stats of N new frames: `make-frame' until the frame is drawn (then it is deleted)."
  (let (times)
    (dotimes (_ n)
      (let* ((t0 (float-time)) (f (make-frame '((visibility . t)))))
        (redisplay t)
        (push (* 1000 (- (float-time) t0)) times)
        (delete-frame f)))
    (mapcar #'drgnx-perf--round (drgnx-perf-stats times))))

;;;; CPU profile

(declare-function profiler-cpu-log "profiler.c")
(declare-function profiler-cpu-start "profiler.c")
(declare-function profiler-cpu-stop "profiler.c")

(defun drgnx-perf-profile (thunk &optional top)
  "Run THUNK under the CPU profiler; the TOP (20) functions by own samples: ((NAME . SAMPLES)…)."
  (when (fboundp 'profiler-cpu-start)
    (profiler-cpu-start 1000000)                         ; 1 ms
    (unwind-protect (funcall thunk)
      (let ((log (profiler-cpu-log)) (counts (make-hash-table :test #'equal)) out)
        (profiler-cpu-stop)
        (maphash (lambda (bt n)
                   (let ((leaf (seq-find #'identity bt)))
                     (when leaf (cl-incf (gethash (format "%s" (if (symbolp leaf) leaf "lambda")) counts 0) n))))
                 log)
        (maphash (lambda (k v) (push (cons k v) out)) counts)
        (seq-take (sort out (lambda (a b) (> (cdr a) (cdr b)))) (or top 20))))))

;;;; Hook audit

(defconst drgnx-perf-busy-hooks
  '(pre-command-hook post-command-hook after-change-functions before-change-functions
                     window-configuration-change-hook window-buffer-change-functions window-selection-change-functions
                     window-size-change-functions window-state-change-functions buffer-list-update-hook find-file-hook after-make-frame-functions
                     server-after-make-frame-hook pre-redisplay-functions window-scroll-functions)
  "Hooks the audit times by default.")

(defvar drgnx-perf--audit nil
  "While auditing: (TABLE ADVISED WRAPPED).  TABLE: function name → (HOOKS . DURATIONS).  ADVISED:
(FN . ADVICE) — named functions timed by advice, their hooks untouched (a function can still remove
itself).  WRAPPED: (HOOK . ((WRAPPER . LAMBDA)…)) — lambdas, wrapped in place; on the way out only
the wrappers are swapped back, so whatever else changed on the hook stays.")

(defun drgnx-perf--name (fn) (if (symbolp fn) (symbol-name fn) (format "lambda@%s" (sxhash-eq fn))))

(defvar drgnx-perf--cmd-hooks nil "While auditing: ms the audited functions and timers took since the command began, or nil
before the first command.")
(defvar drgnx-perf--hook-samples nil "While auditing: the finished commands' totals (ms).")

(defvar drgnx-perf--audit-hooks nil "The last audit's per-command stats (`drgnx-perf-audit-hooks').")

(defun drgnx-perf-audit-hooks ()
  "The last audit's :hooks: STATS (:n :p50 :p90 …) over the commands of the ms the audited hook functions and the
timers took while each ran, up to the next command's start.  Process filters are not timed (DEFERRED)."
  drgnx-perf--audit-hooks)

(defun drgnx-perf--hooks-add (ms)
  (when drgnx-perf--cmd-hooks (setq drgnx-perf--cmd-hooks (+ drgnx-perf--cmd-hooks ms))))

(defun drgnx-perf--hooks-flush ()
  "A command begins: the last one's total is complete, a new one opens (only while auditing)."
  (when drgnx-perf--audit
    (when drgnx-perf--cmd-hooks (push drgnx-perf--cmd-hooks drgnx-perf--hook-samples))
    (setq drgnx-perf--cmd-hooks 0.0)))

(defun drgnx-perf--timers-ad (orig timer &rest args)
  "An :around advice on `timer-event-handler': its time counts for the command it ran under (not the probe's own
timer, which holds the redisplay)."
  (if (eq (timer--function timer) #'drgnx-perf--finish)
      (apply orig timer args)
    (let ((t0 (float-time)))
      (unwind-protect (apply orig timer args) (drgnx-perf--hooks-add (* 1000 (- (float-time) t0)))))))

(defun drgnx-perf--note (table name hook t0)
  (let ((cell (or (gethash name table) (puthash name (cons nil nil) table)))
        (ms (* 1000 (- (float-time) t0))))
    (cl-pushnew (symbol-name hook) (car cell) :test #'equal)
    (push ms (cdr cell))
    (drgnx-perf--hooks-add ms)))

(defun drgnx-perf--timer-for (fn table)
  "An :around advice timing FN (one sample per call, whichever hook ran it)."
  (lambda (orig &rest args)
    (let ((t0 (float-time)))
      (unwind-protect (apply orig args)
        (let ((cell (or (gethash (symbol-name fn) table) (puthash (symbol-name fn) (cons nil nil) table)))
              (ms (* 1000 (- (float-time) t0))))
          (push ms (cdr cell))
          (drgnx-perf--hooks-add ms))))))

(defun drgnx-perf-audit-begin (&optional hooks)
  "Time every function on HOOKS (default `drgnx-perf-busy-hooks'; their global values).  An error
if an audit is already running."
  (when drgnx-perf--audit (error "A hook audit is already running (drgnx-perf-audit-end first)"))
  (let ((table (make-hash-table :test #'equal)) advised wrapped)
    (dolist (hook (or hooks drgnx-perf-busy-hooks))
      (when (boundp hook)
        (let* ((orig (default-value hook)) (fns (if (listp orig) orig (list orig))) pairs)
          (dolist (fn fns)
            (cond
             ((and (symbolp fn) (not (eq fn t)) (fboundp fn))
              (let ((cell (or (gethash (symbol-name fn) table) (puthash (symbol-name fn) (cons nil nil) table))))
                (cl-pushnew (symbol-name hook) (car cell) :test #'equal))
              (unless (assq fn advised)
                (let ((ad (drgnx-perf--timer-for fn table)))
                  (advice-add fn :around ad)
                  (push (cons fn ad) advised))))
             ((and fn (not (symbolp fn)))
              (let* ((name (drgnx-perf--name fn)) (hook hook)
                     (w (lambda (&rest args)
                          (let ((t0 (float-time))) (unwind-protect (apply fn args) (drgnx-perf--note table name hook t0))))))
                (push (cons w fn) pairs)))))
          (when pairs
            (push (cons hook pairs) wrapped)
            (set-default hook (mapcar (lambda (fn) (or (car (rassq fn pairs)) fn)) fns))))))
    (advice-add 'timer-event-handler :around #'drgnx-perf--timers-ad)
    (setq drgnx-perf--cmd-hooks nil drgnx-perf--hook-samples nil
          drgnx-perf--audit (list table advised wrapped))))

(defun drgnx-perf-audit-end ()
  "Undo the audit; its rows, costliest first: ((:fn :hooks :calls :ms :p90 :p95 :max)…).  `drgnx-perf-audit-hooks'
then gives the per-command totals."
  (pcase-let ((`(,table ,advised ,wrapped) drgnx-perf--audit) (rows nil))
    (when drgnx-perf--audit
      (drgnx-perf--hooks-flush)
      (setq drgnx-perf--audit-hooks (mapcar #'drgnx-perf--round2 (drgnx-perf-stats drgnx-perf--hook-samples))))
    (setq drgnx-perf--audit nil drgnx-perf--cmd-hooks nil)
    (advice-remove 'timer-event-handler #'drgnx-perf--timers-ad)
    (pcase-dolist (`(,fn . ,ad) advised) (advice-remove fn ad))
    (pcase-dolist (`(,hook . ,pairs) wrapped)
      (let ((now (default-value hook)))
        (set-default hook (mapcar (lambda (f) (or (cdr (assq f pairs)) f)) (if (listp now) now (list now))))))
    (when table
      (maphash (lambda (name cell)
                 (when (cdr cell)
                   (let ((s (drgnx-perf-stats (cdr cell))))
                     (push (list :fn name :hooks (string-join (reverse (car cell)) " ") :calls (plist-get s :n)
                                 :ms (drgnx-perf--round (apply #'+ (cdr cell)))
                                 :p90 (drgnx-perf--round (plist-get s :p90)) :p95 (drgnx-perf--round (plist-get s :p95)) :max (drgnx-perf--round (plist-get s :max)))
                           rows))))
               table))
    (sort rows (lambda (a b) (> (plist-get a :ms) (plist-get b :ms))))))

(defun drgnx-perf-audit-verdict (rows limit)
  "Lines for the hook functions of ROWS whose p90 passes LIMIT ms (p90: a function runs fewer than 100 times in
most workloads, where there is no p95)."
  (delq nil (mapcar (lambda (r) (when (> (or (plist-get r :p90) 0) limit)
                                  (format "hook function %s (%s) p90 %s > %s ms" (plist-get r :fn) (plist-get r :hooks)
                                          (plist-get r :p90) limit)))
                    rows)))

;;;; Budgets and history (the controller's side)

(defun drgnx-perf--get (results workload path)
  "The value at PATH (e.g. (:input :p95)) of WORKLOAD in RESULTS ((WORKLOAD . PLIST)…)."
  (let ((v (cdr (assq workload results))))
    (dolist (k path v) (setq v (plist-get v k)))))

(defun drgnx-perf-verdict (results budgets)
  "What RESULTS break of BUDGETS ((WORKLOAD PATH LIMIT)…): a list of lines, nil when all hold."
  (let (out)
    (pcase-dolist (`(,w ,path ,limit) budgets)
      (let ((v (drgnx-perf--get results w path)))
        (cond ((not (assq w results)) (cl-pushnew (format "%s: not measured" w) out :test #'equal))
              ((and (null v) (memq (car (last path)) '(:p95 :p99))))   ; fewer than 100 samples: no tail to judge
              ((not (numberp v)) (push (format "%s %s: no value" w (mapconcat (lambda (k) (substring (symbol-name k) 1)) path " ")) out))
              ((> v limit) (push (format "%s %s %s > %s" w (mapconcat (lambda (k) (substring (symbol-name k) 1)) path " ")
                                         (drgnx-perf--round v) limit)
                                 out)))))
    (nreverse out)))

(defun drgnx-perf-history-append (file commit results &optional load)
  "Add RESULTS of COMMIT as one JSON line to FILE.  LOAD: the highest load average seen in the run."
  (make-directory (file-name-directory file) t)
  (write-region (concat (json-serialize (append (list :commit commit :time (format-time-string "%FT%T%z"))
                                                (and load (list :load (drgnx-perf--round load)))
                                                (list :results (prin1-to-string results))))
                        "\n")
                nil file t 'silent))

(defun drgnx-perf--history (file)
  (and (file-readable-p file)
       (delq nil (mapcar (lambda (line) (ignore-errors
                                          (car (read-from-string (plist-get (json-parse-string line :object-type 'plist) :results)))))
                         (split-string (with-temp-buffer (insert-file-contents file) (buffer-string)) "\n" t)))))

(defconst drgnx-perf-regression-floor 5 "Milliseconds a metric must also worsen by to count (noise below).")

(defun drgnx-perf-regressions (file results &optional paths)
  "Metrics of RESULTS more than 15% (and `drgnx-perf-regression-floor' ms) worse than the median of
the last five runs in FILE — the spec's regression gate.
PATHS: the metrics compared (default the p95s: input, redisplay, frame)."
  (let ((past (last (drgnx-perf--history file) 5)) out)
    (when past
      (pcase-dolist (`(,w . ,_) results)
        (dolist (path (or paths '((:input :p95) (:redisplay :p95) (:frame :p95))))
          (let ((now (drgnx-perf--get results w path))
                (old (delq nil (mapcar (lambda (r) (let ((v (drgnx-perf--get r w path))) (and (numberp v) v))) past))))
            (when (and (numberp now) old)
              (let ((median (plist-get (drgnx-perf-stats old) :p50)))
                (when (and (> now (* 1.15 median)) (> (- now median) drgnx-perf-regression-floor))
                  (push (format "%s %s %s vs %s (median of the last %d)" w
                                (mapconcat (lambda (k) (substring (symbol-name k) 1)) path " ")
                                (drgnx-perf--round now) (drgnx-perf--round median) (length old))
                        out))))))))
    (nreverse out)))

;;;; Calibration: how much of a wall-clock number is the machine's

(defun drgnx-perf-load ()
  "The 1-minute load average, or nil where the system reports none."
  (ignore-errors (car (load-average t))))

(defun drgnx-perf--spin (n)
  "A fixed CPU loop of N iterations (byte-compiled before it is timed)."
  (let ((i 0) (x 0))
    (while (< i n) (setq x (logxor x i) i (1+ i)))
    x))

(defun drgnx-perf-calibrate ()
  "(:wall_ms W :cpu_ms C :loaded BOOL): a fixed byte-compiled loop of 2,000,000 iterations, timed on the wall clock
and on this process's CPU clock.  Alone on a core, wall = CPU; :loaded is t when W/C > 1.3: other processes took
the core for a share of the loop, so the wall-clock numbers taken now carry that share."
  (unless (compiled-function-p (symbol-function 'drgnx-perf--spin)) (byte-compile 'drgnx-perf--spin))
  (let ((w0 (float-time)) (c0 (drgnx-perf--cpu-ms)))
    (drgnx-perf--spin 2000000)
    (let ((w (* 1000 (- (float-time) w0))) (c (- (drgnx-perf--cpu-ms) c0)))
      (list :wall_ms (drgnx-perf--round w) :cpu_ms (drgnx-perf--round c) :loaded (and (> c 0) (> (/ w c) 1.3) t)))))

(provide 'drgnx-perf)
;;; drgnx-perf.el ends here
