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

;; the session's agent code, which the replay workloads drive
(defvar drgnx-agents--sessions)
(declare-function drgnx-agents-ui-transcript-buffer "drgnx-agents-ui")
(declare-function drgnx-timer-cancel "drgnx-timer")
(declare-function drgnx-timer-start "drgnx-timer")
(declare-function drgnx-agents--changed "drgnx-agents")
(declare-function drgnx-agent-session-entries "drgnx-agents")
(declare-function drgnx-agents--append-text "drgnx-agents")
(declare-function drgnx-agents--make "drgnx-agents")

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
  '(drgnx-explorer--renders drgnx-buffers--renders)
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

(defvar drgnx-perf--presents nil
  "Per command, on a Glitnir build: ms from its start to the frame clock's after-paint that sent the next paint to
the compositor (`wl_surface.commit'), on either side of an A/B.")

(declare-function glitnir--now-ns "nidhogg-glitnir.c")
(declare-function glitnir--last-paint "nidhogg-glitnir.c")

(defun drgnx-perf--present-ns ()
  "Glitnir's monotonic ns now (no allocation), or nil on a build without the present time."
  (and (fboundp 'glitnir--last-paint) (plist-member (glitnir--last-paint) :present-ns) (glitnir--now-ns)))

(defun drgnx-perf--pre ()
  (drgnx-perf--hooks-flush)
  (let ((ns (drgnx-perf--present-ns)))
    (setq drgnx-perf--t0 (list (float-time) (drgnx-perf--cpu-ms) (drgnx-perf--alloc-sum) ns))))   ; allocation last

(defun drgnx-perf--await-present (ns)
  "Wait (100 ms at most) for the first paint sent to the compositor after NS; push its delay, if it came."
  (let ((end (+ (float-time) 0.1)) (p 0))
    (while (and (< (setq p (plist-get (glitnir--last-paint) :present-ns)) ns) (< (float-time) end))
      (accept-process-output nil 0.001))
    (when (>= p ns) (push (/ (- p ns) 1e6) drgnx-perf--presents))))

(defun drgnx-perf--finish (t0)
  "The 0 s timer: the screen shows the command; record its wall, CPU and allocation, then (Glitnir) its present."
  (redisplay)                           ; the screen showing the command is part of its latency
  (let ((alloc (drgnx-perf--alloc-sum)))
    (push (- alloc (nth 2 t0) 7) drgnx-perf--allocs)           ; less the first reading's own 7 conses
    (push (- (drgnx-perf--cpu-ms) (nth 1 t0)) drgnx-perf--cpus)
    (push (* 1000 (- (float-time) (car t0))) drgnx-perf--latencies))
  (when (nth 3 t0) (drgnx-perf--await-present (nth 3 t0))))

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
(defvar drgnx-watchdog-mode)
(defvar nidhogg-watchdog--bucket-edges)
(defvar nidhogg-watchdog--drain-edges)
(declare-function nidhogg-watchdog--stats-delta "nidhogg-watchdog")
(declare-function drgnx-watchdog-mode "drgnx-watchdog")
(defvar nidhogg-watchdog-threshold)
(defvar nidhogg-watchdog-record-functions)
(declare-function nidhogg-watchdog-mode "nidhogg-watchdog")
(declare-function nidhogg-watchdog-drain-now "nidhogg-watchdog")
(declare-function nidhogg-watchdog-stats "nidhogg-watchdog")

(defvar drgnx-perf--watchdog-applied nil "Non-nil once $DRGNX_PERF_WATCHDOG has been applied in this session.")
(defvar drgnx-perf--stalls nil "While recording: the stall records the watchdog resolved, newest first.")

(defvar drgnx-perf--watchdog-prior nil
  "What the running recording's `drgnx-perf-begin' applied of $DRGNX_PERF_WATCHDOG, for `drgnx-perf-end' to undo: nil
(nothing applied), t (applied, nothing changed) or (ON . THRESHOLD), the watchdog as it was before.")

(declare-function drgnx-watchdog-available-p "drgnx-watchdog")

(defun drgnx-perf--watchdog-runs-p ()
  "Non-nil when the watchdog is built into this Emacs and can start on this system: drgnx's
`drgnx-watchdog-available-p' where drgnx is loaded, else the same test (the feature, on Linux: Nidhogg's C side
refuses to start elsewhere)."
  (if (fboundp 'drgnx-watchdog-available-p)
      (drgnx-watchdog-available-p)
    (and (featurep 'nidhogg-watchdog) (eq system-type 'gnu/linux))))

(defun drgnx-perf--watchdog-env ()
  "Apply $DRGNX_PERF_WATCHDOG once (until `drgnx-perf--watchdog-restore'): unset or `default' runs
`nidhogg-watchdog-mode' at 100 ms (the shipped configuration), `on' at 1 ms (the stress case), `off' leaves it off.
A watchdog already in that state is not restarted.  Without the feature, or on a system it does not run on, nothing.
Returns nil when it did not apply, t when nothing had to change, else (ON . THRESHOLD) as they were before."
  (when (and (not drgnx-perf--watchdog-applied) (drgnx-perf--watchdog-runs-p))
    (setq drgnx-perf--watchdog-applied t)
    (let* ((v (getenv "DRGNX_PERF_WATCHDOG"))
           (ms (cond ((equal v "off") nil) ((equal v "on") 1) (t 100)))
           (prior (cons (and (drgnx-perf--watchdog-on-p) t)
                        (and (boundp 'nidhogg-watchdog-threshold) nidhogg-watchdog-threshold))))
      (if (if ms (and (car prior) (eql (cdr prior) ms)) (not (car prior)))
          t
        (drgnx-perf--watchdog-set nil)
        (when ms
          (setq nidhogg-watchdog-threshold ms)
          (drgnx-perf--watchdog-set t))
        prior))))

(defun drgnx-perf--watchdog-restore ()
  "Undo what `drgnx-perf-begin' applied of $DRGNX_PERF_WATCHDOG: the watchdog's mode and threshold as they were, and
the next `drgnx-perf-begin' applies it again.  What another caller of `drgnx-perf--watchdog-env' applied (the
synthetic day) stays."
  (let ((prior drgnx-perf--watchdog-prior))
    (setq drgnx-perf--watchdog-prior nil)
    (when prior
      (setq drgnx-perf--watchdog-applied nil)
      (when (consp prior)
        (drgnx-perf--watchdog-set nil)
        (when (cdr prior) (setq nidhogg-watchdog-threshold (cdr prior)))
        (when (car prior) (drgnx-perf--watchdog-set t))))))

(defun drgnx-perf--watchdog-set (on)
  "Turn the whole watchdog stack on or off.  A drgnx session has already started it at init, through
`drgnx-watchdog-mode', which also carries the doctor's record hook and idle timer; so that is the switch, and Nidhogg's
mode is only touched directly where drgnx is not loaded."
  (if (fboundp 'drgnx-watchdog-mode)
      (drgnx-watchdog-mode (if on 1 -1))
    (nidhogg-watchdog-mode (if on 1 -1)))
  (when (and (not on) (boundp 'nidhogg-watchdog-mode) nidhogg-watchdog-mode)
    (nidhogg-watchdog-mode -1)))

(defun drgnx-perf--watchdog-on-p ()
  (and (featurep 'nidhogg-watchdog) (boundp 'nidhogg-watchdog-mode) nidhogg-watchdog-mode))

(defun drgnx-perf--drain-edges ()
  "The upper edges (ms) of the drain histogram's buckets: Nidhogg's `nidhogg-watchdog--drain-edges', for a build
without them its C bucket edges, else the C defaults."
  (cond ((boundp 'nidhogg-watchdog--drain-edges) nidhogg-watchdog--drain-edges)
        ((boundp 'nidhogg-watchdog--bucket-edges) nidhogg-watchdog--bucket-edges)
        (t [4 8 16 33 50 100 250 1000])))

(defun drgnx-perf-watchdog-snapshot ()
  "The watchdog's cumulative counters now, without resetting them (nil when it is off): :spans :samples :missed :stale
:stalls :monitor-cpu-ms and :drain, the drain histogram as a vector; with Nidhogg's newer stats also :drain-take (a
vector) and :drain-over-budget.  `:samples' is Nidhogg's own count when it has one, else its spans."
  (when-let* (((drgnx-perf--watchdog-on-p)) (s (nidhogg-watchdog-stats)))
    (append (list :spans (or (plist-get s :spans) 0)
                  :samples (or (plist-get s :samples) (plist-get s :spans) 0)
                  :missed (or (plist-get s :missed) 0) :stale (or (plist-get s :stale) 0)
                  :stalls (or (plist-get s :stalls) 0)
                  :monitor-cpu-ms (or (plist-get s :monitor-cpu-ms) 0.0)
                  :drain (vconcat (plist-get s :drain)))
            (when (plist-member s :drain-take) (list :drain-take (vconcat (plist-get s :drain-take))))
            (when (plist-member s :drain-over-budget) (list :drain-over-budget (plist-get s :drain-over-budget))))))

(defun drgnx-perf--hist-edge (hist edges q)
  "The upper edge (ms) of the bucket of HIST (counts by bucket; the last bucket is open) that holds the share Q (0..1)
of its counts, 0 when HIST is empty.  EDGES are the buckets' upper edges."
  (let ((total (apply #'+ (append hist nil))) (acc 0) (i 0))
    (if (zerop total)
        0
      (while (and (< i (1- (length edges))) (< (* 100 (setq acc (+ acc (aref hist i)))) (* 100 q total)))
        (setq i (1+ i)))
      (aref edges (min i (1- (length edges)))))))

(defun drgnx-perf-watchdog-delta (before after &optional edges)
  "The counters AFTER minus those of BEFORE (both snapshots; nil BEFORE is zero).  With Nidhogg's
`nidhogg-watchdog--stats-delta' it does the subtraction (it copes with a counter reset in between) and its ready
`:drain-p95-ms' is used; without, counters never go below zero and the p95 comes from the difference of the
histograms.  The largest bucket is read by EDGES (default `drgnx-perf--drain-edges')."
  (let* ((edges (let ((e (vconcat edges))) (if (> (length e) 0) e (drgnx-perf--drain-edges))))
         (d (if (fboundp 'nidhogg-watchdog--stats-delta)
                (funcall 'nidhogg-watchdog--stats-delta after before)
              (let* ((num (lambda (k) (max 0 (- (or (plist-get after k) 0) (or (plist-get before k) 0)))))
                     (a (vconcat (plist-get after :drain))) (b (vconcat (plist-get before :drain))))
                (list :spans (funcall num :spans) :samples (funcall num :samples) :missed (funcall num :missed)
                      :stale (funcall num :stale) :stalls (funcall num :stalls)
                      :monitor-cpu-ms (funcall num :monitor-cpu-ms)
                      :drain-over-budget (funcall num :drain-over-budget)
                      :drain (vconcat (cl-loop for i from 0 below (length a)
                                               collect (max 0 (- (aref a i) (if (< i (length b)) (aref b i) 0)))))))))
         (hist (vconcat (plist-get d :drain)))
         (top (cl-position-if (lambda (n) (> n 0)) hist :from-end t)))
    (list :spans (or (plist-get d :spans) 0) :samples (or (plist-get d :samples) 0) :missed (or (plist-get d :missed) 0)
          :stale (or (plist-get d :stale) 0) :stalls (or (plist-get d :stalls) 0)
          :monitor-cpu-ms (drgnx-perf--round (float (or (plist-get d :monitor-cpu-ms) 0)))
          :drain-over-budget (or (plist-get d :drain-over-budget) 0)
          :drain hist
          :drain-p95-ms (drgnx-perf--round (float (or (plist-get d :drain-p95-ms) (drgnx-perf--hist-edge hist edges 0.95))))
          :drain-max-ms (drgnx-perf--round (float (if top (aref edges (min top (1- (length edges)))) 0))))))

(defun drgnx-perf--stall-record (record)
  "A `nidhogg-watchdog-record-functions' entry: keep what RECORD says of the stall (wall time, felt, signature, culprit)."
  (push (list :wall-ms (plist-get record :wall-ms) :felt (plist-get record :felt)
              :signature (plist-get record :signature) :culprit (plist-get record :culprit))
        drgnx-perf--stalls))

(defvar drgnx-perf--stalls-snapshot nil "The watchdog's counters when the stalls probe began.")

(defun drgnx-perf--stalls-begin ()
  "Drain what came before, snapshot the counters (they are not reset: the watchdog's summaries and the day's totals
read them) and start keeping the records."
  (setq drgnx-perf--stalls nil drgnx-perf--stalls-snapshot nil)
  (when (drgnx-perf--watchdog-on-p)
    (nidhogg-watchdog-drain-now)
    (setq drgnx-perf--stalls-snapshot (drgnx-perf-watchdog-snapshot))
    (add-hook 'nidhogg-watchdog-record-functions #'drgnx-perf--stall-record)))

(defun drgnx-perf--stalls-end ()
  "The probe's keys (:stalls :stalls-felt :stall-max-ms :watchdog) for the workload just run: only :watchdog nil
without the watchdog."
  (if (not (drgnx-perf--watchdog-on-p))
      (list :watchdog nil)
    (nidhogg-watchdog-drain-now)
    (remove-hook 'nidhogg-watchdog-record-functions #'drgnx-perf--stall-record)
    (let ((d (drgnx-perf-watchdog-delta drgnx-perf--stalls-snapshot (drgnx-perf-watchdog-snapshot)))
          (walls (delq nil (mapcar (lambda (s) (plist-get s :wall-ms)) drgnx-perf--stalls))))
      (list :stalls (length drgnx-perf--stalls)
            :stalls-felt (length (seq-filter (lambda (s) (plist-get s :felt)) drgnx-perf--stalls))
            :stall-max-ms (drgnx-perf--round (if walls (apply #'max walls) 0.0))
            :watchdog (list :missed (plist-get d :missed) :spans (plist-get d :spans) :samples (plist-get d :samples)
                            :monitor-cpu-ms (plist-get d :monitor-cpu-ms)
                            :drain-p95-ms (plist-get d :drain-p95-ms)
                            :drain-max-ms (plist-get d :drain-max-ms))))))

(defvar drgnx-perf--day-stalls nil "The stalls the day's session has seen since the last `drgnx-perf-watchdog-day-read'.")

(defun drgnx-perf--day-stall-record (record)
  "A record function of the day: keep the stall's wall time, felt, signature and culprit, for the phase report."
  (let ((c (plist-get record :culprit)))
    (push (list :wall-ms (or (plist-get record :wall-ms) 0.0) :felt (if (plist-get record :felt) t :false)
                :signature (or (plist-get record :signature) "")
                :culprit (cond ((stringp c) c) (c (format "%S" c)) (t "")))
          drgnx-perf--day-stalls)))

(defun drgnx-perf-watchdog-day-read ()
  "For the synthetic day, in the session: what the watchdog shows now, as a plist for the harness.  No reset.  :on,
:native (the preloaded Lisp is compiled), :version-dir, :drgnx-mode, :stats (`drgnx-perf-watchdog-snapshot') and :stalls
(the vector of stalls since the last call).  Collecting begins on the first call."
  (if (not (drgnx-perf--watchdog-on-p))
      (list :on :false :drgnx-mode (if (and (boundp 'drgnx-watchdog-mode) drgnx-watchdog-mode) t :false))
    (nidhogg-watchdog-drain-now)
    (add-hook 'nidhogg-watchdog-record-functions #'drgnx-perf--day-stall-record)
    (prog1 (list :on t
                 :native (if (and (fboundp 'native-comp-function-p) (native-comp-function-p (symbol-function 'nidhogg-watchdog-mode))) t :false)
                 :version-dir (if (boundp 'comp-native-version-dir) (format "%s" comp-native-version-dir) "")
                 :drgnx-mode (if (and (boundp 'drgnx-watchdog-mode) drgnx-watchdog-mode) t :false)
                 :stats (drgnx-perf-watchdog-snapshot)
                 :edges (vconcat (drgnx-perf--drain-edges))
                 :stalls (vconcat (reverse drgnx-perf--day-stalls)))
      (setq drgnx-perf--day-stalls nil))))

(defun drgnx-perf--gc-row (pauses)
  "(:count N :max MS :p95 MS) of PAUSES (ms); :max and :p95 are nil with no collection."
  (list :count (length pauses)
        :max (and pauses (drgnx-perf--round (apply #'max pauses)))
        :p95 (and pauses (drgnx-perf--round (drgnx-perf--p95 pauses)))))

(defun drgnx-perf--typing-row (latencies)
  "(:ge16 PERCENT :p95 MS) of the commands' LATENCIES (ms): the share at or over one 60 Hz frame, and the tail."
  (list :ge16 (if latencies (drgnx-perf--round (/ (* 100.0 (seq-count (lambda (l) (>= l 16)) latencies)) (length latencies))) 0.0)
        :p95 (and latencies (drgnx-perf--round (drgnx-perf--p95 latencies)))))

(defun drgnx-perf-begin ()
  "Start recording: every command's latency, every GC pause, memory, Glitnir's frame-time record (the
compose probe: reset here, read by `drgnx-perf-end' under :compose) and the stall watchdog's records (`:stalls')."
  (drgnx-perf--glitnir-env)
  (setq drgnx-perf--watchdog-prior (drgnx-perf--watchdog-env))
  (drgnx-perf--stalls-begin)
  (drgnx-perf--compose-stats t)
  (setq drgnx-perf--latencies nil drgnx-perf--allocs nil drgnx-perf--cpus nil drgnx-perf--t0 nil drgnx-perf--presents nil
        drgnx-perf--gc-pauses nil drgnx-perf--gc-last gc-elapsed
        drgnx-perf--start (list gcs-done gc-elapsed (drgnx-perf-rss-kb) (drgnx-perf--rows)))
  (add-hook 'pre-command-hook #'drgnx-perf--pre -100)
  (add-hook 'post-command-hook #'drgnx-perf--post 100)
  (add-hook 'post-gc-hook #'drgnx-perf--gc))

(defun drgnx-perf-end ()
  "Stop recording: (:input STATS :alloc STATS :cpu_ms STATS :rows N :gc_count N :gc_ms MS :gc_pause STATS
:rss_kb KB :rss_start_kb KB).  :input is wall ms, :alloc objects, :cpu_ms CPU ms, per command (pre-command-hook
to the redisplay after it); :rows the growth of `drgnx-perf-row-counters'.  Allocation, CPU and rows do not move
with the load on the machine; wall clock does.  :compose is Glitnir's record since `drgnx-perf-begin' and
:present the commands' key-to-present ms (both absent without Glitnir)."
  (remove-hook 'pre-command-hook #'drgnx-perf--pre)
  (remove-hook 'post-command-hook #'drgnx-perf--post)
  (remove-hook 'post-gc-hook #'drgnx-perf--gc)
  (pcase-let ((`(,gcs ,elapsed ,rss ,rows) drgnx-perf--start)
              (compose (drgnx-perf--compose-stats))
              (stalls (prog1 (drgnx-perf--stalls-end) (drgnx-perf--watchdog-restore))))
    (append
     stalls
     (list :gc (drgnx-perf--gc-row drgnx-perf--gc-pauses)
           :typing (drgnx-perf--typing-row drgnx-perf--latencies))
     (list :input (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--latencies))
           :alloc (drgnx-perf-stats drgnx-perf--allocs)
           :cpu_ms (mapcar #'drgnx-perf--round2 (drgnx-perf-stats drgnx-perf--cpus))
           :rows (- (drgnx-perf--rows) rows)
           :gc_count (- gcs-done gcs) :gc_ms (drgnx-perf--round (* 1000 (- gc-elapsed elapsed)))
           :gc_pause (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--gc-pauses))
           :rss_kb (drgnx-perf-rss-kb) :rss_start_kb rss)
     (and drgnx-perf--presents
          (list :present (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--presents))))
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

(defvar drgnx-perf--audit-stats nil "The last audit's per-command stats (`drgnx-perf-audit-hooks').")

(defun drgnx-perf-audit-hooks ()
  "The last audit's :hooks: STATS (:n :p50 :p90 …) over the commands of the ms the audited hook functions and the
timers took while each ran, up to the next command's start.  Process filters are not timed (DEFERRED)."
  drgnx-perf--audit-stats)

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
      (setq drgnx-perf--audit-stats (mapcar #'drgnx-perf--round2 (drgnx-perf-stats drgnx-perf--hook-samples))))
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

(defun drgnx-perf--path-name (path) (mapconcat (lambda (k) (substring (symbol-name k) 1)) path " "))

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
        (when (and (drgnx-perf--gated-p path) (drgnx-perf--budget-applies-p b emacs-major)
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
        (when (and (not (drgnx-perf--gated-p path)) (assq w results)
                   (drgnx-perf--budget-applies-p b emacs-major))
          (push (format "%s %s %s (budget %s): reported (wall clock; judge with --perf --ab)" w (drgnx-perf--path-name path)
                        (or (drgnx-perf--round (drgnx-perf--get results w path)) "-") limit)
                out))))
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
