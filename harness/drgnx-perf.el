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

(defvar drgnx-perf--audit)
(defvar drgnx-perf--timers-on nil "While recording: timers are timed per command (`drgnx-perf--timers-ad').")
(defvar drgnx-perf--timer-cur nil
  "While recording: the ms every timer took under the current command (its start to the next command's), or nil
before the first command.")
(defvar drgnx-perf--timer-after 0.0 "Of `drgnx-perf--timer-cur', the ms of the timers that ran after the screen showed the command.")
(defvar drgnx-perf--cmd-lat nil "The current command's latency (ms) once the screen shows it, else nil.")
(defvar drgnx-perf--timer-ms nil "Per finished command: the ms its timers took.")
(defvar drgnx-perf--busy-ms nil
  "Per finished command: the main thread's busy ms, its latency (start to the screen showing it) plus the timers
that ran after, up to the next command.")

(defun drgnx-perf--busy-flush ()
  "The current command is complete: keep its timer ms and its busy ms."
  (when drgnx-perf--timer-cur
    (push drgnx-perf--timer-cur drgnx-perf--timer-ms)
    (when drgnx-perf--cmd-lat (push (+ drgnx-perf--cmd-lat drgnx-perf--timer-after) drgnx-perf--busy-ms))))

(defun drgnx-perf--pre ()
  (drgnx-perf--hooks-flush)
  (drgnx-perf--busy-flush)
  (setq drgnx-perf--timer-cur 0.0 drgnx-perf--timer-after 0.0 drgnx-perf--cmd-lat nil)
  (setq drgnx-perf--t0 (list (float-time) (drgnx-perf--cpu-ms) (drgnx-perf--alloc-sum))))   ; allocation last

(defvar drgnx-perf--ahead nil "While recording: the pty read-ahead (bytes) of the terminal's process, sampled per command.")
(defvar drgnx-perf--term)
(declare-function nidhogg-workers--test-io-info "nidhogg-io.c")

(defun drgnx-perf--ahead-sample ()
  "Note the terminal process's `:ahead' (Nidhogg's pty read-ahead) when a terminal workload has one."
  (when (and (fboundp 'nidhogg-workers--test-io-info) (bound-and-true-p drgnx-perf--term) (buffer-live-p drgnx-perf--term))
    (when-let* ((p (get-buffer-process drgnx-perf--term))
                (a (plist-get (nidhogg-workers--test-io-info p) :ahead)))
      (when (numberp a) (push a drgnx-perf--ahead)))))

(defun drgnx-perf--finish (t0)
  "The 0 s timer: the screen shows the command; record its wall, CPU and allocation."
  (redisplay)                           ; the screen showing the command is part of its latency
  (let ((alloc (drgnx-perf--alloc-sum)) (ms (* 1000 (- (float-time) (car t0)))))
    (push (- alloc (nth 2 t0) 7) drgnx-perf--allocs)           ; less the first reading's own 7 conses
    (push (- (drgnx-perf--cpu-ms) (nth 1 t0)) drgnx-perf--cpus)
    (push ms drgnx-perf--latencies)
    (setq drgnx-perf--cmd-lat ms)
    (drgnx-perf--ahead-sample)))

(defun drgnx-perf--post ()
  (when drgnx-perf--t0
    (let ((t0 drgnx-perf--t0))
      (setq drgnx-perf--t0 nil)
      (run-at-time 0 nil #'drgnx-perf--finish t0))))

(defun drgnx-perf--gc ()
  "After each collection: its own time (`gc-elapsed' grows by it)."
  (push (* 1000 (- gc-elapsed drgnx-perf--gc-last)) drgnx-perf--gc-pauses)
  (setq drgnx-perf--gc-last gc-elapsed))

(defvar glitnir-enable)
(declare-function glitnir-stats "glitnir")

(defun drgnx-perf--glitnir-env ()
  "Apply $DRGNX_PERF_GLITNIR (on or off) to `glitnir-enable' in this session; anything else leaves it alone."
  (when-let* ((v (getenv "DRGNX_PERF_GLITNIR")) ((member v '("on" "off"))) ((boundp 'glitnir-enable)))
    (setq glitnir-enable (equal v "on"))))

(defun drgnx-perf--compose-stats (&optional reset)
  "Glitnir's frame-time record (`glitnir-stats'; RESET clears it), or nil on a build or a root without it."
  (and (fboundp 'glitnir-stats) (glitnir-stats nil reset)))

;;;; The stall watchdog (docs/develop/perf.md, "The stalls probe")

(defvar nidhogg-watchdog-mode)
(defvar nidhogg-watchdog-threshold)
(defvar nidhogg-watchdog-record-functions)
(declare-function nidhogg-watchdog-mode "nidhogg-watchdog")
(declare-function nidhogg-watchdog-drain-now "nidhogg-watchdog")
(declare-function nidhogg-watchdog-stats "nidhogg-watchdog")

(defvar drgnx-perf--watchdog-applied nil "Non-nil once $DRGNX_PERF_WATCHDOG has been applied in this session.")
(defvar drgnx-perf--stalls nil "While recording: the stall records the watchdog resolved, newest first.")

(defun drgnx-perf--watchdog-env ()
  "Apply $DRGNX_PERF_WATCHDOG once per session: unset or `default' runs `nidhogg-watchdog-mode' at 100 ms (the shipped
configuration), `on' at 1 ms (the stress case), a number at that many ms (16: the gates' `stalls-ge16' rows), `off'
leaves it off.  Without the feature, nothing."
  (when (and (not drgnx-perf--watchdog-applied) (featurep 'nidhogg-watchdog))
    (setq drgnx-perf--watchdog-applied t)
    (let* ((v (getenv "DRGNX_PERF_WATCHDOG"))
           (ms (cond ((equal v "off") nil) ((equal v "on") 1)
                     ((and v (string-match-p "\\`[1-9][0-9]*\\'" v)) (string-to-number v))
                     (t 100))))
      (when (and (boundp 'nidhogg-watchdog-mode) nidhogg-watchdog-mode) (nidhogg-watchdog-mode -1))
      (when ms
        (setq nidhogg-watchdog-threshold ms)
        (nidhogg-watchdog-mode 1)))))

(defun drgnx-perf--watchdog-on-p ()
  (and (featurep 'nidhogg-watchdog) (boundp 'nidhogg-watchdog-mode) nidhogg-watchdog-mode))

(defun drgnx-perf--stall-record (record)
  "A `nidhogg-watchdog-record-functions' entry: keep RECORD's wall time and whether the user felt it."
  (push (cons (plist-get record :wall-ms) (plist-get record :felt)) drgnx-perf--stalls))

(defun drgnx-perf--stalls-begin ()
  "Drain what came before, and start keeping the records."
  (setq drgnx-perf--stalls nil)
  (when (drgnx-perf--watchdog-on-p)
    (nidhogg-watchdog-drain-now)
    (nidhogg-watchdog-stats t)
    (add-hook 'nidhogg-watchdog-record-functions #'drgnx-perf--stall-record)))

(defun drgnx-perf--stalls-end ()
  "The probe's keys (:stalls :stalls-felt :stall-max-ms :watchdog) for the workload just run: only :watchdog nil
without the watchdog."
  (if (not (drgnx-perf--watchdog-on-p))
      (list :watchdog nil)
    (nidhogg-watchdog-drain-now)
    (remove-hook 'nidhogg-watchdog-record-functions #'drgnx-perf--stall-record)
    (let ((s (nidhogg-watchdog-stats)) (walls (delq nil (mapcar #'car drgnx-perf--stalls))))
      (list :stalls (length drgnx-perf--stalls)
            :stalls-felt (length (seq-filter #'cdr drgnx-perf--stalls))
            :stalls-ge16 (seq-count (lambda (w) (>= w 16)) walls)
            :stalls-ge100 (seq-count (lambda (w) (>= w 100)) walls)
            :stall-max-ms (drgnx-perf--round (if walls (apply #'max walls) 0.0))
            :watchdog (list :missed (or (plist-get s :missed) 0)
                            :monitor-cpu-ms (drgnx-perf--round (or (plist-get s :monitor-cpu-ms) 0.0))
                            :drain-p95-ms (drgnx-perf--round (or (plist-get s :drain-p95-ms) 0.0)))))))

;;;; The worker threads (docs/develop/perf.md, "The workers probe")

(declare-function nidhogg-workers-apply "nidhogg-workers")
(declare-function nidhogg-workers-stats "nidhogg-workers")

(defvar drgnx-perf--workers-applied nil "Non-nil once $DRGNX_PERF_WORKERS has been applied in this session.")

(defun drgnx-perf--workers-p () (featurep 'nidhogg-workers))

(defun drgnx-perf--workers-env ()
  "Apply $DRGNX_PERF_WORKERS once per session, before any workload: `nidhogg-workers-apply' gets the value as the
Nidhogg switch grammar has it (`default', `on', `off', `inline', or +SW/-SW items) and `default' when it is unset or
empty.  Without the feature, nothing."
  (when (and (not drgnx-perf--workers-applied) (drgnx-perf--workers-p))
    (setq drgnx-perf--workers-applied t)
    (let ((v (getenv "DRGNX_PERF_WORKERS")))
      (nidhogg-workers-apply (if (or (null v) (string-empty-p v)) "default" v)))))

(defun drgnx-perf--workers-begin ()
  "Zero the worker counters: the next `drgnx-perf--workers-end' reads this workload alone."
  (when (drgnx-perf--workers-p) (nidhogg-workers-stats t)))

(defun drgnx-perf--workers-fallbacks (stats)
  "The fallbacks of every worker in STATS, summed."
  (let ((n 0))
    (cl-loop for (_k v) on stats by #'cddr
             when (and (consp v) (keywordp (car v)))
             do (dolist (f (plist-get v :fallbacks)) (when (consp f) (cl-incf n (or (cdr f) 0)))))
    n))

(defun drgnx-perf--workers-phases (ph)
  "Nidhogg's :phase-ms PH (PHASE MS …, `worker-wait' a plist of REASON MS) as PHASE MS with numbers only: the
`worker-wait' total and one `worker-wait-REASON' per reason, rounded."
  (cl-loop for (k v) on ph by #'cddr
           if (numberp v) append (list k (drgnx-perf--round v))
           else if (consp v)
           append (cons k (cons (drgnx-perf--round (cl-loop for (_r ms) on v by #'cddr when (numberp ms) sum ms))
                                (cl-loop for (r ms) on v by #'cddr when (numberp ms)
                                         append (list (intern (format "%s-%s" k r)) (drgnx-perf--round ms)))))))

(defun drgnx-perf--workers-end ()
  "(:workers (:phase-ms PLIST :wait-ms F :fallbacks N :deferrals PLIST)) for the workload just run; (:workers nil)
without the feature.  :phase-ms is the busy time of each phase, :wait-ms the main thread's waits for a worker
(`treesit-wait' and `worker-wait'), :fallbacks the number of jobs that ran inline, :deferrals the deferred work.
Nidhogg reports `worker-wait' by reason (a plist): the probe gives its total as `worker-wait' and each reason as
`worker-wait-REASON', all numbers, so the A/B judges them like every other phase."
  (if (not (drgnx-perf--workers-p))
      (list :workers nil)
    (let* ((s (nidhogg-workers-stats)) (ph (drgnx-perf--workers-phases (plist-get s :phase-ms))))
      ;; the main thread's whole time for images: its own image work and its waits for nh-img (the display and
      ;; image-pixels reasons), so an image decode moved into a wait is not counted as gone
      (when (numberp (plist-get ph 'image))
        (setq ph (append ph (list 'image-with-waits
                                  (drgnx-perf--round (+ (plist-get ph 'image) (or (plist-get ph 'worker-wait-display) 0)
                                                        (or (plist-get ph 'worker-wait-image-pixels) 0)))))))
      ;; the main thread's whole tree-sitter time: its synchronous parses (Nidhogg counts them in `treesit' with the
      ;; workers on or off) and its waits for nh-parse, so a parse moved into a wait is not counted as gone
      (when (numberp (plist-get ph 'treesit))
        (setq ph (append ph (list 'treesit-with-waits
                                  (drgnx-perf--round (+ (plist-get ph 'treesit) (or (plist-get ph 'treesit-wait) 0)))))))
      (list :workers (list :phase-ms ph
                           :wait-ms (drgnx-perf--round (+ (or (plist-get ph 'treesit-wait) 0) (or (plist-get ph 'worker-wait) 0)))
                           :fallbacks (drgnx-perf--workers-fallbacks s)
                           :deferrals (plist-get s :deferrals))))))

;;;; Completion metrics: how long until the work a workload started is done

(defvar drgnx-perf--complete nil "While recording: (PREDICATE START-S DONE-MS) of the workload's completion metric.")

(defun drgnx-perf-complete-poll ()
  "When the predicate holds, note the ms since `drgnx-perf-complete-begin' (once)."
  (when (and drgnx-perf--complete (null (nth 2 drgnx-perf--complete)) (funcall (nth 0 drgnx-perf--complete)))
    (require 'drgnx-timer)
    (setf (nth 2 drgnx-perf--complete) (drgnx-perf--round (* 1000 (- (drgnx-timer-now) (nth 1 drgnx-perf--complete)))))
    (drgnx-timer-cancel 'perf-complete)))

(defun drgnx-perf--complete-tick ()
  "The completion timer: poll while Emacs is idle, not inside a command."
  (when (current-idle-time) (drgnx-perf-complete-poll)))

(defun drgnx-perf-complete-begin (predicate)
  "Start timing until PREDICATE (a function of no arguments, the workload's `:complete-when') holds, polled every
10 ms while Emacs is idle, through the timer layer.  Not an idle timer: that runs once per idle period, and the lab's
own calls after the keys do not end one, so work that finished later in the pause was never seen."
  (require 'drgnx-timer)
  (setq drgnx-perf--complete (list predicate (drgnx-timer-now) nil))
  (drgnx-timer-start 'perf-complete 0.01 #'drgnx-perf--complete-tick :repeat 0.01 :owner :core))

(defun drgnx-perf-complete-end ()
  "(:complete-ms MS) since `drgnx-perf-complete-begin', or (:complete-ms nil) when it never held; stops the polling."
  (drgnx-perf-complete-poll)
  (when (fboundp 'drgnx-timer-cancel) (drgnx-timer-cancel 'perf-complete))
  (prog1 (list :complete-ms (nth 2 drgnx-perf--complete))
    (setq drgnx-perf--complete nil)))

(defun drgnx-perf--gc-row (pauses)
  "(:count N :max MS :p95 MS) of PAUSES (ms); :max and :p95 are nil with no collection."
  (list :count (length pauses)
        :max (and pauses (drgnx-perf--round (apply #'max pauses)))
        :p95 (and pauses (drgnx-perf--round (drgnx-perf--p95 pauses)))))

(defun drgnx-perf--typing-row (latencies)
  "(:ge16 PERCENT :p95 MS) of the commands' LATENCIES (ms): the share at or over one 60 Hz frame, and the tail."
  (list :ge16 (if latencies (drgnx-perf--round (/ (* 100.0 (seq-count (lambda (l) (>= l 16)) latencies)) (length latencies))) 0.0)
        :p95 (and latencies (drgnx-perf--round (drgnx-perf--p95 latencies)))))

(defvar drgnx-perf--timer-key nil "Non-nil while recording a `:timers t' row: `drgnx-perf-end' reports `:timer-ms'.")

(defun drgnx-perf--cal-end ()
  "(:cal PLIST) for the calibration rows, or nil without a key to report: `:costs', `:decisions' and `:pressure' as
`nidhogg-workers-stats' gives them, `:policy' from `nidhogg-workers--policy', `:ahead' (:p50 :max) from the samples of
the terminal's pty read-ahead.  A key the Nidhogg build lacks is left out (the report prints `n/a')."
  (let (out (s (and (featurep 'nidhogg-workers) (fboundp 'nidhogg-workers-stats) (nidhogg-workers-stats))))
    (dolist (k '(:costs :decisions :pressure))
      (when (plist-member s k) (setq out (append out (list k (plist-get s k))))))
    (when (fboundp 'nidhogg-workers--policy)
      (setq out (append out (list :policy (nidhogg-workers--policy)))))
    (when drgnx-perf--ahead
      (setq out (append out (list :ahead (list :p50 (plist-get (drgnx-perf-stats drgnx-perf--ahead) :p50)
                                               :max (apply #'max drgnx-perf--ahead))))))
    (and out (list :cal out))))

(defun drgnx-perf-begin (&optional timers)
  "Start recording: every command's latency, every GC pause, memory, Glitnir's frame-time record (the
compose probe: reset here, read by `drgnx-perf-end' under :compose) and the stall watchdog's records (`:stalls').
Every command's main-thread busy ms is kept too (`:busy-ms'); TIMERS (a `:timers t' row) also reports the ms the
timers took per command (`:timer-ms')."
  (drgnx-perf--glitnir-env)
  (drgnx-perf--watchdog-env)
  (drgnx-perf--workers-env)
  (drgnx-perf--workers-begin)
  (drgnx-perf--stalls-begin)
  (drgnx-perf--compose-stats t)
  (setq drgnx-perf--latencies nil drgnx-perf--allocs nil drgnx-perf--cpus nil drgnx-perf--t0 nil
        drgnx-perf--gc-pauses nil drgnx-perf--gc-last gc-elapsed
        drgnx-perf--start (list gcs-done gc-elapsed (drgnx-perf-rss-kb) (drgnx-perf--rows))
        drgnx-perf--timer-key timers drgnx-perf--timers-on t drgnx-perf--timer-cur nil drgnx-perf--timer-after 0.0
        drgnx-perf--cmd-lat nil drgnx-perf--timer-ms nil drgnx-perf--busy-ms nil drgnx-perf--ahead nil)
  (advice-add 'timer-event-handler :around #'drgnx-perf--timers-ad)
  (add-hook 'pre-command-hook #'drgnx-perf--pre -100)
  (add-hook 'post-command-hook #'drgnx-perf--post 100)
  (add-hook 'post-gc-hook #'drgnx-perf--gc))

(defun drgnx-perf-end ()
  "Stop recording: (:input STATS :alloc STATS :cpu_ms STATS :rows N :gc_count N :gc_ms MS :gc_pause STATS
:rss_kb KB :rss_start_kb KB).  :input is wall ms, :alloc objects, :cpu_ms CPU ms, per command (pre-command-hook
to the redisplay after it); :rows the growth of `drgnx-perf-row-counters'.  Allocation, CPU and rows do not move
with the load on the machine; wall clock does.  :compose is Glitnir's record since `drgnx-perf-begin' (absent
without Glitnir)."
  (remove-hook 'pre-command-hook #'drgnx-perf--pre)
  (remove-hook 'post-command-hook #'drgnx-perf--post)
  (remove-hook 'post-gc-hook #'drgnx-perf--gc)
  (drgnx-perf--busy-flush)
  (setq drgnx-perf--timers-on nil drgnx-perf--timer-cur nil)
  (unless drgnx-perf--audit (advice-remove 'timer-event-handler #'drgnx-perf--timers-ad))
  (pcase-let ((`(,gcs ,elapsed ,rss ,rows) drgnx-perf--start)
              (compose (drgnx-perf--compose-stats))
              (stalls (drgnx-perf--stalls-end))
              (workers (drgnx-perf--workers-end)))
    (append
     stalls workers (drgnx-perf--cal-end)
     (list :busy-ms (append (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--busy-ms))
                            (list :sum (drgnx-perf--round (apply #'+ 0.0 drgnx-perf--busy-ms)))))
     (and drgnx-perf--timer-key
          (list :timer-ms (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--timer-ms))))
     (list :gc (drgnx-perf--gc-row drgnx-perf--gc-pauses)
           :typing (drgnx-perf--typing-row drgnx-perf--latencies))
     (list :input (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--latencies))
           :alloc (drgnx-perf-stats drgnx-perf--allocs)
           :cpu_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats drgnx-perf--cpus))
           :rows (- (drgnx-perf--rows) rows)
           :gc_count (- gcs-done gcs) :gc_ms (drgnx-perf--round (* 1000 (- gc-elapsed elapsed)))
           :gc_pause (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--gc-pauses))
           :rss_kb (drgnx-perf-rss-kb) :rss_start_kb rss)
     (and compose (list :compose compose)))))

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

(defun drgnx-perf--timer-note (ms)
  "A timer took MS: it counts for the current command, and for its busy time when the screen already shows it."
  (when (and drgnx-perf--timers-on drgnx-perf--timer-cur)
    (cl-incf drgnx-perf--timer-cur ms)
    (when drgnx-perf--cmd-lat (cl-incf drgnx-perf--timer-after ms))))

(defun drgnx-perf--timers-ad (orig timer &rest args)
  "An :around advice on `timer-event-handler': its time counts for the command it ran under (not the probe's own
timer, which holds the redisplay)."
  (if (eq (timer--function timer) #'drgnx-perf--finish)
      (apply orig timer args)
    (let ((t0 (float-time)))
      (unwind-protect (apply orig timer args)
        (let ((ms (* 1000 (- (float-time) t0))))
          (drgnx-perf--hooks-add ms)
          (drgnx-perf--timer-note ms))))))

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
    (unless drgnx-perf--timers-on (advice-remove 'timer-event-handler #'drgnx-perf--timers-ad))
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

(defconst drgnx-perf-gated-metrics '(:alloc :cpu_ms :rows :processes :rss_kb)
  "The metrics a budget can fail a run on: what load does not move.  Every other path (wall clock) is reported.")

(defvar drgnx-perf-watchdog-gated nil
  "Non-nil once the watchdog rows (`:stalls', `:gc') are seeded: they then fail a run.  Until then they are reported
(docs/develop/perf.md: a new row is reported first).")

(defconst drgnx-perf-gc-p95-min-collections 20
  "A GC p95 is judged only over at least this many collections (fewer: the tail is the maximum).")

(defun drgnx-perf--gated-p (path)
  "Whether a budget at PATH can fail a run."
  (or (memq (car path) drgnx-perf-gated-metrics)
      (and drgnx-perf-watchdog-gated (memq (car path) '(:stalls :gc)))))

(defun drgnx-perf--watchdog-row-skipped-p (results w path)
  "Whether the watchdog row at PATH of W has nothing to judge: the stalls rows without the watchdog (`:watchdog' nil),
the GC max with no collection, the GC p95 over fewer than `drgnx-perf-gc-p95-min-collections' collections."
  (let ((gcs (or (drgnx-perf--get results w '(:gc :count)) 0)))
    (or (and (eq (car path) :stalls) (not (drgnx-perf--get results w '(:watchdog))))
        (and (equal path '(:gc :max)) (= gcs 0))
        (and (equal path '(:gc :p95)) (< gcs drgnx-perf-gc-p95-min-collections)))))

(defun drgnx-perf--cpu-factor ()
  "$DRGNX_PERF_CPU_FACTOR (a number; default 1, 2 on hosted runners): the headroom CPU budgets get."
  (let ((env (getenv "DRGNX_PERF_CPU_FACTOR")))
    (if (and env (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" env)) (string-to-number env) 1)))

(defun drgnx-perf--landed-steps ()
  "The steps $DRGNX_PERF_LANDED names (comma or space separated), as strings."
  (split-string (or (getenv "DRGNX_PERF_LANDED") "") "[, ]+" t))

(defun drgnx-perf--report-only-p (budget)
  "Whether BUDGET (WORKLOAD PATH LIMIT &rest PLIST) is a report-only row whose step has not landed: `:report-only STEP'
in PLIST, STEP not in $DRGNX_PERF_LANDED.  Such a row never fails; it is reported."
  (when-let* ((step (plist-get (nthcdr 3 budget) :report-only)))
    (not (member (format "%s" step) (drgnx-perf--landed-steps)))))

(defun drgnx-perf--landed-p (budget)
  "Whether BUDGET is a `:report-only' row whose step has landed: from then on it is judged like any other."
  (and (plist-get (nthcdr 3 budget) :report-only) (not (drgnx-perf--report-only-p budget))))

(defun drgnx-perf--path-name (path)(mapconcat (lambda (k) (substring (symbol-name k) 1)) path " "))

(defun drgnx-perf--budget-applies-p (budget emacs-major)
  "BUDGET is (WORKLOAD PATH LIMIT &rest PLIST); `:emacs MAJOR' in PLIST limits it to that Emacs major version."
  (let ((major (plist-get (nthcdr 3 budget) :emacs)))
    (or (null major) (eql major emacs-major))))

(cl-defun drgnx-perf-verdict (results budgets &key (emacs-major emacs-major-version) (cpu-factor (drgnx-perf--cpu-factor)))
  "What RESULTS break of the gated BUDGETS ((WORKLOAD PATH LIMIT &rest PLIST)…): a list of lines, nil when all
hold.  Gated: `drgnx-perf-gated-metrics' — allocation (:alloc :p50, measured x 1.25 rounded up), CPU (:cpu_ms
:p90, x CPU-FACTOR) and rows (exact).  Entries for another EMACS-MAJOR are skipped; wall-clock paths are
`drgnx-perf-report's."
  (let (out)
    (dolist (b budgets)
      (pcase-let ((`(,w ,path ,limit . ,_) b))
        (when (and (or (drgnx-perf--gated-p path) (drgnx-perf--landed-p b)) (drgnx-perf--budget-applies-p b emacs-major)
                   (not (drgnx-perf--report-only-p b))
                   (not (and (assq w results) (drgnx-perf--watchdog-row-skipped-p results w path))))
          (let ((v (drgnx-perf--get results w path))
                (limit (if (eq (car path) :cpu_ms) (* limit cpu-factor) limit)))
            (cond ((not (assq w results)) (cl-pushnew (format "%s: not measured" w) out :test #'equal))
                  ((not (numberp v)) (push (format "%s %s: no value" w (drgnx-perf--path-name path)) out))
                  ((> v limit) (push (format "%s %s %s > %s" w (drgnx-perf--path-name path) (drgnx-perf--round v) limit) out)))))))
    (nreverse out)))

(cl-defun drgnx-perf-report (results budgets &key (emacs-major emacs-major-version))
  "Lines for every BUDGETS path of a measured workload that is not gated (wall clock): the value, the budget,
and that it is reported, not judged.  A p95 or p99 below n = 100 has no value."
  (let (out)
    (dolist (b budgets)
      (pcase-let ((`(,w ,path ,limit . ,_) b))
        (when (and (assq w results) (drgnx-perf--budget-applies-p b emacs-major))
          (cond ((drgnx-perf--report-only-p b)
                 (push (format "%s %s %s (budget %s, report-only until %s lands): report" w (drgnx-perf--path-name path)
                               (or (drgnx-perf--round (drgnx-perf--get results w path)) "-") limit
                               (plist-get (nthcdr 3 b) :report-only))
                       out))
                ((or (drgnx-perf--gated-p path) (drgnx-perf--landed-p b)))
                (t (push (format "%s %s %s (budget %s): reported (wall clock; judge with --perf --ab)" w (drgnx-perf--path-name path)
                                 (or (drgnx-perf--round (drgnx-perf--get results w path)) "-") limit)
                         out))))))
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

(defconst drgnx-perf-regression-floors '((:alloc . 8) (:cpu_ms . 0.5))
  "What a metric must also worsen by, to count: 8 conses of allocation, 0.5 ms of CPU.  The floor of a metric is
the larger of this and twice its spread over the runs compared.")

(defun drgnx-perf-regressions (file results &optional paths)
  "Metrics of RESULTS more than 15% worse than the median of the last five runs in FILE, and worse by more than
their floor: the larger of `drgnx-perf-regression-floors' and twice the metric's spread (max - min) over those
runs.  PATHS: the metrics compared (default allocation and CPU, the p50s).  A local report: the caller prints it
and never fails on it — CI has no history and gates on budgets."
  (let ((past (last (drgnx-perf--history file) 5)) out)
    (when past
      (pcase-dolist (`(,w . ,_) results)
        (dolist (path (or paths '((:alloc :p50) (:cpu_ms :p50))))
          (let ((now (drgnx-perf--get results w path))
                (old (delq nil (mapcar (lambda (r) (let ((v (drgnx-perf--get r w path))) (and (numberp v) v))) past))))
            (when (and (numberp now) old)
              (let* ((median (plist-get (drgnx-perf-stats old) :p50))
                     (floor (max (or (alist-get (car path) drgnx-perf-regression-floors) 0)
                                 (* 2 (- (seq-max old) (seq-min old))))))
                (when (and (> now (* 1.15 median)) (> (- now median) floor))
                  (push (format "%s %s %s vs %s (median of the last %d)" w (drgnx-perf--path-name path)
                                (drgnx-perf--round now) (drgnx-perf--round median) (length old))
                        out))))))))
    (nreverse out)))

;;;; Paired A/B: the bootstrap interval and the verdict (`drgnx-perf-ab' in drgnx-perf-run.el)

(defun drgnx-perf--median (values)
  "The median of the list or vector VALUES (the mean of the middle two for an even count)."
  (let* ((v (sort (append values nil) #'<)) (n (length v)))
    (if (cl-oddp n) (nth (/ n 2) v) (/ (+ (nth (1- (/ n 2)) v) (nth (/ n 2) v)) 2.0))))

(cl-defun drgnx-perf-bootstrap-diff (a b &key (iterations 2000) (seed 1))
  "(:diff D :lo L :hi H): the median of B minus the median of A, with a 95% interval from resampling both with
replacement ITERATIONS times.  It draws from its own generator (a seeded linear congruential one, MINSTD), never
from the global `random' state: the same samples and SEED give the same interval."
  (let* ((state (max 1 (mod seed 2147483647)))
         (va (vconcat a)) (vb (vconcat b)) (na (length va)) (nb (length vb)) diffs)
    (cl-flet ((draw (vec n)
                (setq state (mod (* state 48271) 2147483647))
                (aref vec (mod state n))))
      (dotimes (_ iterations)
        (push (- (drgnx-perf--median (cl-loop repeat nb collect (draw vb nb)))
                 (drgnx-perf--median (cl-loop repeat na collect (draw va na))))
              diffs)))
    (let ((d (vconcat (sort diffs #'<))))
      (list :diff (- (drgnx-perf--median vb) (drgnx-perf--median va))
            :lo (aref d (floor (* 0.025 iterations))) :hi (aref d (min (1- iterations) (floor (* 0.975 iterations))))))))

(defun drgnx-perf--p95 (values)
  "The nearest-rank 95th percentile of the list or vector VALUES."
  (let ((v (vconcat (sort (append values nil) #'<))))
    (aref v (1- (ceiling (* 0.95 (length v)))))))

(defun drgnx-perf--pairs (list)
  "LIST in consecutive pairs (the last may be alone): the unit of the round bootstrap (ABBA, the order reversed in
the second round of a pair, so an order bias cancels inside it)."
  (cl-loop while list collect (if (cdr list) (list (pop list) (pop list)) (list (pop list)))))

(defun drgnx-perf--resample (items iterations seed stat)
  "The sorted vector of ITERATIONS values of STAT (a function of a list of ITEMS) over draws of (length ITEMS)
items with replacement, from its own MINSTD generator seeded with SEED."
  (let* ((v (vconcat items)) (n (length v)) (state (max 1 (mod seed 2147483647))) out)
    (dotimes (_ iterations)
      (push (funcall stat (cl-loop repeat n collect (progn (setq state (mod (* state 48271) 2147483647)) (aref v (mod state n)))))
            out))
    (vconcat (sort out #'<))))

(defun drgnx-perf--interval (d diff iterations)
  "(:diff DIFF :lo L :hi H): the 95% interval of the sorted vector D of ITERATIONS resampled statistics."
  (list :diff diff :lo (aref d (floor (* 0.025 iterations))) :hi (aref d (min (1- iterations) (floor (* 0.975 iterations))))))

(defun drgnx-perf--bootstrap-per-round (per-round iterations seed)
  "(:diff D :lo L :hi H) from PER-ROUND, one difference (B minus A) per round: the unit is a pair of rounds, the mean
of its two differences; D is the median of those and the interval resamples the pairs with replacement."
  (let ((diffs (mapcar (lambda (p) (/ (apply #'+ p) (float (length p)))) (drgnx-perf--pairs per-round))))
    (drgnx-perf--interval (drgnx-perf--resample diffs iterations seed #'drgnx-perf--median) (drgnx-perf--median diffs) iterations)))

(cl-defun drgnx-perf-bootstrap-rounds (rounds &key (iterations 2000) (seed 1) (stat 'median))
  "(:diff D :lo L :hi H) from ROUNDS, a list of (:a SAMPLES :b SAMPLES): the unit is the round (a run of each side),
not the sample, because samples within a run share a spike, a GC and a cache state.  Consecutive rounds run in
opposite order (`drgnx-perf-ab-rounds'), so the unit is a pair of them.  STAT `median' (default): per round the
median of B minus the median of A, a pair's statistic is the mean of its two; D is the median of those and the 95%
interval resamples the pairs with replacement.  STAT `p95': the pairs are resampled with replacement, each side's
samples of the drawn pairs are pooled and the statistic is the nearest-rank p95 of B minus that of A; D is the same
over all samples.  Its own seeded generator, like `drgnx-perf-bootstrap-diff'."
  (pcase stat
    ('median (drgnx-perf--bootstrap-per-round
              (mapcar (lambda (r) (- (drgnx-perf--median (plist-get r :b)) (drgnx-perf--median (plist-get r :a)))) rounds)
              iterations seed))
    ('p95 (let ((pool (lambda (rs key) (apply #'append (mapcar (lambda (r) (plist-get r key)) rs)))))
            (cl-flet ((diff (pairs) (let ((rs (apply #'append pairs)))
                                      (- (drgnx-perf--p95 (funcall pool rs :b)) (drgnx-perf--p95 (funcall pool rs :a))))))
              (drgnx-perf--interval (drgnx-perf--resample (drgnx-perf--pairs rounds) iterations seed #'diff)
                                    (diff (list rounds)) iterations))))
    (_ (error "perf: unknown statistic %S" stat))))

(defun drgnx-perf--classify (ci th)
  "The verdict symbol for the interval CI against the threshold TH: regressed (all above TH), improved (all below
0; it counts as no regression), no-regression (all at or below TH), else inconclusive."
  (cond ((> (plist-get ci :lo) th) 'regressed)
        ((< (plist-get ci :hi) 0) 'improved)
        ((<= (plist-get ci :hi) th) 'no-regression)
        (t 'inconclusive)))

(cl-defun drgnx-perf-ab-verdict (a b &optional rounds &key (stat 'median) threshold)
  "(:verdict V :diff :lo :hi :threshold T) for the wall-clock samples A (the REF) and B (the work tree): T is
THRESHOLD, else max(1 ms, 10% of A's median).  regressed: the whole interval is above T; improved: all of it below
0; no-regression: all of it at or below T; inconclusive: T is inside it.  With ROUNDS (see
`drgnx-perf-bootstrap-rounds') the interval is over the rounds, not the pooled samples A and B (which then only
give the median T is taken from).  STAT `p95' needs ROUNDS."
  (let* ((ci (cond (rounds (drgnx-perf-bootstrap-rounds rounds :stat stat))
                   ((eq stat 'median) (drgnx-perf-bootstrap-diff a b))
                   (t (error "perf: the %s verdict needs rounds" stat))))
         (th (or threshold (max 1.0 (* 0.10 (drgnx-perf--median a))))))
    (append (list :verdict (drgnx-perf--classify ci th)) ci (list :threshold th))))

(defun drgnx-perf-ab-probe-verdict (rounds path)
  "The verdict on a probe value: ROUNDS is a list of (:a PLIST :b PLIST), both sides' probe plists of a round (a
run's result); PATH, e.g. (:compose :draw-ms :p95), is read from each.  Per round B minus A; pairs and bootstrap as
the median statistic; T = max(1 ms, 10% of A's median value).  (:verdict not-comparable) when a side of a round
lacks a number at PATH."
  (let ((as (mapcar (lambda (r) (drgnx-perf--path-value (plist-get r :a) path)) rounds))
        (bs (mapcar (lambda (r) (drgnx-perf--path-value (plist-get r :b) path)) rounds)))
    (if (or (null rounds) (not (seq-every-p #'numberp as)) (not (seq-every-p #'numberp bs)))
        (list :verdict 'not-comparable)
      (let ((ci (drgnx-perf--bootstrap-per-round (cl-mapcar #'- bs as) 2000 1)) (th (max 1.0 (* 0.10 (drgnx-perf--median as)))))
        (append (list :verdict (drgnx-perf--classify ci th)) ci (list :threshold th))))))

(defconst drgnx-perf-ab-metric-paths
  '((:input :p50) (:input :p95) (:input :p99) (:input :max) (:cpu_ms :p50) (:cpu_ms :p90)
    (:busy-ms :p50) (:busy-ms :p95) (:timer-ms :p95)
    (:stalls-ge16) (:stalls-ge100) (:complete-ms) (:lsp :handler_ms :max))
  "The probe values (read from each round's run) whose A/B verdict counts besides the wall samples: per-command input
p50, p95, p99 and max, the main thread's CPU ms, its busy ms per command (latency plus the timers after it) at p50 and
p95, the timers' ms per command (p95), the stalls of 16 ms and of 100 ms or more, and the completion metrics
(`:complete-ms', lsp-burst's slowest handler after its answer's last byte).  The
workers' phases get no verdict: `drgnx-perf-ab-phase-paths' lists them for the explain block.")

(defun drgnx-perf-ab-phase-paths (rounds)
  "(:workers :phase-ms PHASE) for every PHASE (a number) either side of any of ROUNDS reports."
  (let (phases)
    (dolist (r rounds)
      (dolist (side '(:a :b))
        (let ((ph (drgnx-perf--path-value (plist-get r side) '(:workers :phase-ms))))
          (cl-loop for (k v) on ph by #'cddr when (numberp v) do (cl-pushnew k phases)))))
    (mapcar (lambda (k) (list :workers :phase-ms k)) (nreverse phases))))

(defun drgnx-perf-ab-metric-verdicts (rounds)
  "((PATH . VERDICT)…) for ROUNDS (see `drgnx-perf-ab-probe-verdict') over `drgnx-perf-ab-metric-paths': only the
paths both sides report in every round (a path with no number is left out, not failed).  Worker phases are not
here: they explain (`drgnx-perf-ab-phase-explain'), they do not decide."
  (let (out)
    (dolist (path drgnx-perf-ab-metric-paths)
      (let ((v (drgnx-perf-ab-probe-verdict rounds path)))
        (unless (eq (plist-get v :verdict) 'not-comparable) (push (cons path v) out))))
    (nreverse out)))

(defun drgnx-perf-ab-phase-explain (run-a run-b)
  "((PHASE A B)…): each worker phase's ms in RUN-A and RUN-B (a run's `:workers :phase-ms', numbers only; the median over
its rounds), for phases either side reports.  The explain block prints them; no verdict is made of them."
  (let ((pa (drgnx-perf--path-value run-a '(:workers :phase-ms))) (pb (drgnx-perf--path-value run-b '(:workers :phase-ms))) keys)
    (cl-loop for (k v) on (append pa pb) by #'cddr when (numberp v) do (cl-pushnew k keys))
    (mapcar (lambda (k) (list k (plist-get pa k) (plist-get pb k))) (nreverse keys))))

(defun drgnx-perf-ab--phase-total (run)
  "(PHASES . BUSY) of RUN: the sum of its `:workers :phase-ms' (the `worker-wait-REASON' entries repeat `worker-wait',
so they are left out) and its `(:busy-ms :sum)'; nil when it has no phases, BUSY nil when it has no busy time."
  (let ((ph (drgnx-perf--path-value run '(:workers :phase-ms))) (sum 0.0) found)
    (cl-loop for (k v) on ph by #'cddr
             when (and (numberp v) (not (string-prefix-p "worker-wait-" (symbol-name k))))
             do (setq found t sum (+ sum v)))
    (and found (cons sum (let ((b (drgnx-perf--path-value run '(:busy-ms :sum)))) (and (numberp b) b))))))

(defun drgnx-perf-ab-phase-sum (run-a run-b)
  "The phase-sum check of the runs RUN-A and RUN-B (a run is the median over a side's rounds): nil when it holds or
there is nothing to check, else (:phase-sum-mismatch :why TEXT).  Per arm, the sum of the worker phases' ms must not
exceed the main thread's busy ms (`(:busy-ms :sum)') by more than 1 ms (a phase is time the main thread spent, so
more means a phase counted time it was not busy).  The change across arms is not judged:
`drgnx-perf-ab-phase-delta-line' explains it."
  (let ((a (drgnx-perf-ab--phase-total run-a)) (b (drgnx-perf-ab--phase-total run-b)) why)
    (cl-loop for (arm . tot) in (list (cons "A" a) (cons "B" b))
             when (and tot (cdr tot) (> (car tot) (+ (cdr tot) 1.0)))
             do (push (format "arm %s: phases %.1f ms > busy %.1f ms + 1" arm (car tot) (cdr tot)) why))
    (and why (list :phase-sum-mismatch :why (string-join (nreverse why) "; ")))))

(defun drgnx-perf-ab-phase-delta-line (run-a run-b)
  "An explain line (a string, never a verdict) with the change of `(:busy-ms :sum)' and of the phases' sum from RUN-A
to RUN-B; nil when either run lacks phases or busy time.  `:busy-ms' is a stand-in (latency plus the timers after the
screen showed the command; Nidhogg reports no per-command main-thread busy time), so run sums of it and of the phases
do not have to agree, and no run carries a watchdog busy measure to prefer."
  (let ((a (drgnx-perf-ab--phase-total run-a)) (b (drgnx-perf-ab--phase-total run-b)))
    (when (and a b (cdr a) (cdr b))
      (format "busy changed by %.1f ms, the phases' sum by %.1f ms (busy is latency plus timers, a stand-in; not judged)"
              (- (cdr b) (cdr a)) (- (car b) (car a))))))

(defun drgnx-perf-ab-digest-verdict (rounds)
  "The correctness verdict on ROUNDS' `:digest' strings: (:verdict regressed :why digest) when any round's two sides
differ, (:verdict no-regression) when all agree, (:verdict not-comparable) when no round has a digest on both sides."
  (let ((pairs (delq nil (mapcar (lambda (r) (let ((a (plist-get (plist-get r :a) :digest)) (b (plist-get (plist-get r :b) :digest)))
                                               (and (stringp a) (stringp b) (cons a b))))
                                 rounds))))
    (cond ((null pairs) (list :verdict 'not-comparable))
          ((seq-some (lambda (p) (not (equal (car p) (cdr p)))) pairs) (list :verdict 'regressed :why 'digest))
          (t (list :verdict 'no-regression)))))

(defun drgnx-perf-cpuset-args (cpus &optional topology)
  "The container run arguments that give the lab CPUS cores (\"2\" or \"4\", $DRGNX_PERF_CPUS; review M14):
`--cpuset-cpus' with the first thread of each of the first CPUS physical cores, so a machine that numbers a core's two
threads next to each other (a 4900HS: 0,2) gets the same shape as one that does not (a 7900X: 0,1).  TOPOLOGY is
a list of (CPU . CORE), by default from `lscpu -p=CPU,CORE'; without one, CPUs 0 to CPUS - 1.  Nil for an empty
CPUS; an error for any other."
  (let ((n (pcase (format "%s" (or cpus ""))
             ("" nil)
             ((and v (or "2" "4")) (string-to-number v))
             (v (error "perf: DRGNX_PERF_CPUS must be 2 or 4, not %s" v)))))
    (when n
      (let ((topology (or topology
                          (ignore-errors
                            (mapcar (lambda (l) (let ((f (split-string l ","))) (cons (car f) (cadr f))))
                                    (seq-remove (lambda (l) (string-prefix-p "#" l))
                                                (process-lines "lscpu" "-p=CPU,CORE"))))))
            (seen nil) (picked nil))
        (dolist (c topology)
          (when (and (< (length picked) n) (not (member (format "%s" (cdr c)) seen)))
            (push (format "%s" (cdr c)) seen)
            (push (format "%s" (car c)) picked)))
        (list "--cpuset-cpus" (if (= (length picked) n)
                                  (string-join (nreverse picked) ",")
                                (format "0-%d" (1- n))))))))

(defun drgnx-perf--path-value (plist path)
  "The value at PATH (a list of keys) in the nested PLIST."
  (dolist (k path plist) (setq plist (and (consp plist) (plist-get plist k)))))

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

;;;; Transcript replay (the synthetic day, `transcript-replay'): a streaming transcript with no agent behind it

(cl-defstruct (drgnx-perf-replay (:constructor drgnx-perf-replay--make) (:copier nil))
  name session chunks left (fed 0))

(defvar drgnx-perf--replays nil "Live replays (`drgnx-perf-replay'), newest first.")

(defun drgnx-perf-replay--get (name) (seq-find (lambda (r) (equal (drgnx-perf-replay-name r) name)) drgnx-perf--replays))

(defun drgnx-perf-replay--arm (r)
  "Set the timer of the next chunk of replay R, after the delay recorded for it."
  (drgnx-timer-start (cons 'perf-replay (drgnx-perf-replay-name r))
                     (/ (car (car (drgnx-perf-replay-left r))) 1000.0) #'drgnx-perf-replay-tick
                     :args (list (drgnx-perf-replay-name r)) :owner :core))

(defun drgnx-perf-replay-start (name chunks)
  "Start a transcript session NAME fed from CHUNKS, ((DELAY-MS . TEXT)…), in a loop: no agent process.
Each timer tick calls `drgnx-agents--append-text' and `drgnx-agents--changed' as a streaming agent's event does;
the recording's end finishes the answer and starts it over.  Returns the session."
  (require 'drgnx-agents)
  (require 'drgnx-timer)
  (drgnx-perf-replay-stop name)
  (let* ((s (drgnx-agents--make :name name :profile "replay" :cwd temporary-file-directory :status 'busy :id name))
         (r (drgnx-perf-replay--make :name name :session s :chunks chunks :left chunks)))
    (push s drgnx-agents--sessions)
    (push r drgnx-perf--replays)
    (drgnx-perf-replay--arm r)
    s))

(defun drgnx-perf-replay-tick (name)
  "Feed replay NAME its next chunk and set the timer of the one after."
  (when-let* ((r (drgnx-perf-replay--get name)))
    (let ((s (drgnx-perf-replay-session r)) (chunk (pop (drgnx-perf-replay-left r))))
      (drgnx-agents--append-text s 'agent (cdr chunk))
      (cl-incf (drgnx-perf-replay-fed r))
      (unless (drgnx-perf-replay-left r)
        (plist-put (car (last (drgnx-agent-session-entries s))) :done t)
        (setf (drgnx-perf-replay-left r) (drgnx-perf-replay-chunks r)))
      (drgnx-agents--changed s)
      (drgnx-perf-replay--arm r))))

(defun drgnx-perf-replay-count (name)
  "How many chunks replay NAME has fed (0 for none)."
  (if-let* ((r (drgnx-perf-replay--get name))) (drgnx-perf-replay-fed r) 0))

(defun drgnx-perf-replay-stop (name)
  "Stop replay NAME: its timer, its session and its transcript buffer."
  (when-let* ((r (drgnx-perf-replay--get name)))
    (drgnx-timer-cancel (cons 'perf-replay name))
    (setq drgnx-perf--replays (delq r drgnx-perf--replays)
          drgnx-agents--sessions (delq (drgnx-perf-replay-session r) drgnx-agents--sessions))
    (when-let* ((b (get-buffer (format "*agent: %s*" name))))
      (when-let* ((w (get-buffer-window b))) (ignore-errors (delete-window w)))
      (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))

(defun drgnx-perf-replay-buffer (name)
  "Replay NAME's transcript buffer, drawn (not shown)."
  (require 'drgnx-agents-ui)
  (drgnx-agents-ui-transcript-buffer (drgnx-perf-replay-session (drgnx-perf-replay--get name))))

(defun drgnx-perf-live-mb ()
  "The live Lisp heap in MB after a collection, from `garbage-collect-heapsize' (Nidhogg), else `drgnx-perf-heap-mb'."
  (if (fboundp 'garbage-collect-heapsize)
      (let ((bytes 0))
        (dolist (e (garbage-collect-heapsize))
          (when (and (numberp (nth 1 e)) (numberp (nth 2 e))) (cl-incf bytes (* (nth 1 e) (nth 2 e)))))
        (/ bytes 1048576.0))
    (drgnx-perf-heap-mb)))

(defun drgnx-perf-heap-mb ()
  "The live Lisp heap in MB after a collection: SIZE × USED over `garbage-collect''s entries."
  (let ((bytes 0))
    (dolist (e (garbage-collect))
      (when (and (numberp (nth 1 e)) (numberp (nth 2 e))) (cl-incf bytes (* (nth 1 e) (nth 2 e)))))
    (/ bytes 1048576.0)))

(provide 'drgnx-perf)
;;; drgnx-perf.el ends here
