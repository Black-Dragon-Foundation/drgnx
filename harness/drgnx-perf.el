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
  "(:n :p50 :p95 :max :mean) of VALUES (nearest rank)."
  (if (null values) (list :n 0)
    (let* ((v (sort (copy-sequence values) #'<)) (n (length v))
           (rank (lambda (p) (nth (max 0 (1- (ceiling (* p n)))) v))))
      (list :n n :p50 (funcall rank 0.5) :p95 (funcall rank 0.95) :max (car (last v))
            :mean (/ (apply #'+ v) (float n))))))

(defun drgnx-perf--round (x) (if (floatp x) (/ (round (* x 10)) 10.0) x))

(defun drgnx-perf-rss-kb ()
  "This Emacs's resident memory in kB (Linux), or 0."
  (or (ignore-errors
        (with-temp-buffer
          (insert-file-contents "/proc/self/status")
          (when (re-search-forward "^VmRSS:[ \t]+\\([0-9]+\\)" nil t) (string-to-number (match-string 1)))))
      0))

;;;; Recording input latency, GC, memory

(defvar drgnx-perf--t0 nil)
(defvar drgnx-perf--latencies nil)
(defvar drgnx-perf--start nil "(gcs-done gc-elapsed rss) at the start.")
(defvar drgnx-perf--gc-pauses nil "Each collection's time (ms) while recording.")
(defvar drgnx-perf--gc-last 0.0 "`gc-elapsed' after the last collection seen.")

(defun drgnx-perf--pre () (setq drgnx-perf--t0 (float-time)))

(defun drgnx-perf--post ()
  (when drgnx-perf--t0
    (let ((t0 drgnx-perf--t0))
      (setq drgnx-perf--t0 nil)
      (run-at-time 0 nil (lambda ()
                           (redisplay)           ; the screen showing the command is part of its latency
                           (push (* 1000 (- (float-time) t0)) drgnx-perf--latencies))))))

(defun drgnx-perf--gc ()
  "After each collection: its own time (`gc-elapsed' grows by it)."
  (push (* 1000 (- gc-elapsed drgnx-perf--gc-last)) drgnx-perf--gc-pauses)
  (setq drgnx-perf--gc-last gc-elapsed))

(defun drgnx-perf-begin ()
  "Start recording: every command's latency, every GC pause, memory."
  (setq drgnx-perf--latencies nil drgnx-perf--t0 nil drgnx-perf--gc-pauses nil drgnx-perf--gc-last gc-elapsed
        drgnx-perf--start (list gcs-done gc-elapsed (drgnx-perf-rss-kb)))
  (add-hook 'pre-command-hook #'drgnx-perf--pre -100)
  (add-hook 'post-command-hook #'drgnx-perf--post 100)
  (add-hook 'post-gc-hook #'drgnx-perf--gc))

(defun drgnx-perf-end ()
  "Stop recording: (:input STATS :gc_count N :gc_ms MS :gc_pause STATS :rss_kb KB :rss_start_kb KB)."
  (remove-hook 'pre-command-hook #'drgnx-perf--pre)
  (remove-hook 'post-command-hook #'drgnx-perf--post)
  (remove-hook 'post-gc-hook #'drgnx-perf--gc)
  (pcase-let ((`(,gcs ,elapsed ,rss) drgnx-perf--start))
    (list :input (mapcar #'drgnx-perf--round (drgnx-perf-stats drgnx-perf--latencies))
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
                     window-size-change-functions buffer-list-update-hook find-file-hook after-make-frame-functions
                     server-after-make-frame-hook pre-redisplay-functions window-scroll-functions)
  "Hooks the audit times by default.")

(defvar drgnx-perf--audit nil
  "While auditing: (TABLE ADVISED WRAPPED).  TABLE: function name → (HOOKS . DURATIONS).  ADVISED:
(FN . ADVICE) — named functions timed by advice, their hooks untouched (a function can still remove
itself).  WRAPPED: (HOOK . ((WRAPPER . LAMBDA)…)) — lambdas, wrapped in place; on the way out only
the wrappers are swapped back, so whatever else changed on the hook stays.")

(defun drgnx-perf--name (fn) (if (symbolp fn) (symbol-name fn) (format "lambda@%s" (sxhash-eq fn))))

(defun drgnx-perf--note (table name hook t0)
  (let ((cell (or (gethash name table) (puthash name (cons nil nil) table))))
    (cl-pushnew (symbol-name hook) (car cell) :test #'equal)
    (push (* 1000 (- (float-time) t0)) (cdr cell))))

(defun drgnx-perf--timer-for (fn table)
  "An :around advice timing FN (one sample per call, whichever hook ran it)."
  (lambda (orig &rest args)
    (let ((t0 (float-time)))
      (unwind-protect (apply orig args)
        (let ((cell (or (gethash (symbol-name fn) table) (puthash (symbol-name fn) (cons nil nil) table))))
          (push (* 1000 (- (float-time) t0)) (cdr cell)))))))

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
    (setq drgnx-perf--audit (list table advised wrapped))))

(defun drgnx-perf-audit-end ()
  "Undo the audit; its rows, costliest first: ((:fn :hooks :calls :ms :p95 :max)…)."
  (pcase-let ((`(,table ,advised ,wrapped) drgnx-perf--audit) (rows nil))
    (setq drgnx-perf--audit nil)
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
                                 :p95 (drgnx-perf--round (plist-get s :p95)) :max (drgnx-perf--round (plist-get s :max)))
                           rows))))
               table))
    (sort rows (lambda (a b) (> (plist-get a :ms) (plist-get b :ms))))))

(defun drgnx-perf-audit-verdict (rows limit)
  "Lines for the hook functions of ROWS whose p95 passes LIMIT ms."
  (delq nil (mapcar (lambda (r) (when (> (or (plist-get r :p95) 0) limit)
                                  (format "hook function %s (%s) p95 %s > %s ms" (plist-get r :fn) (plist-get r :hooks)
                                          (plist-get r :p95) limit)))
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

;;;; A quiet machine: timings taken while other processes compete for the CPU are not judged

(defun drgnx-perf-load ()
  "The 1-minute load average, or nil where the system reports none."
  (ignore-errors (car (load-average t))))

(defun drgnx-perf-max-load ()
  "The load above which timings are not judged: $DRGNX_PERF_MAX_LOAD, else a quarter of the CPUs, at
least 3 (the measured session adds its own load)."
  (let ((env (getenv "DRGNX_PERF_MAX_LOAD")))
    (if (and env (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" env)) (string-to-number env)
      (max 3 (/ (num-processors) 4.0)))))

(defun drgnx-perf-busy (loads limit)
  "The highest of LOADS (samples; nil ones ignored) when it is above LIMIT, else nil."
  (let ((top (seq-max (cons 0 (delq nil (copy-sequence loads))))))
    (and (> top limit) top)))

(provide 'drgnx-perf)
;;; drgnx-perf.el ends here
