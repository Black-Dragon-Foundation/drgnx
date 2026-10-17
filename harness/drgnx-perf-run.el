;;; drgnx-perf-run.el --- `drgnx test --perf' and `--soak': workloads in a GUI session, budgets, history -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The controller side of the perf lab.  A workload is a setup form (run in the session), the input
;; to send (real key events through the harness) and an optional form that measures what input
;; cannot (frames, redisplay, startup, memory).  Each input workload runs three times and the median
;; of its p95 and max is kept, so one noisy run never decides.  Results are judged against
;; test/perf/budgets.eld, appended to the history (perf-history.jsonl in the harness state root) and
;; compared with the median of the last five runs.  See docs/perf.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-ui)
(require 'drgnx-perf)

(defvar drgnx-perf-run--fixture nil "The typing fixture of this run (one file, reused, deleted at the end).")

(defun drgnx-perf-run--make-fixture ()
  "A large Emacs Lisp file — drgnx's own core three times (~12k lines) — written once per run."
  (let ((f (make-temp-file "drgnx-perf-" nil ".el")))
    (with-temp-file f
      (dotimes (_ 3)
        (dolist (x (directory-files (expand-file-name "core" drgnx-ui-repo-dir) t "\\.el\\'"))
          (insert-file-contents x) (goto-char (point-max)))))
    f))

(defun drgnx-perf-run--visit-fixture-form ()
  (format "(let ((f %S)) (when-let* ((b (find-buffer-visiting f))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
                         (find-file f) (goto-char (/ (point-max) 2)) (forward-line 0) t)"
          drgnx-perf-run--fixture))

(defun drgnx-perf-run--workloads ()
  "The workloads: (NAME :setup FORM :each FORM :actions ACTIONS :check FORM :measure FORM :teardown FORM :repeat N).
Every workload runs three times (medians are kept); :each runs before each repeat, :check after it (an
error if it does not hold)."
  (let ((type (lambda (s) (list :type s))) (keys (lambda (k n) (make-list n (list :keys k))))
        (kill-fixture (format "(progn (when-let* ((b (find-buffer-visiting %S))) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)) t)"
                              (or drgnx-perf-run--fixture ""))))
    `((typing :each ,(drgnx-perf-run--visit-fixture-form)
              :actions ,(make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) ")) :teardown ,kill-fixture)
      (scrolling :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form) " (goto-char (point-min)) t)")
                 :actions ,(append (funcall keys "<next>" 30) (funcall keys "<prior>" 30)) :teardown ,kill-fixture)
      (tabs :setup ,(format "(progn (dolist (f (seq-take (directory-files %S t \"\\\\.el\\'\") 20)) (find-file f)) t)"
                            (expand-file-name "wb" drgnx-ui-repo-dir))
            :actions ,(funcall keys "C-<next>" 20)
            :teardown ,(format "(progn (dolist (b (buffer-list)) (when (and (buffer-file-name b) (string-prefix-p %S (buffer-file-name b))) (kill-buffer b))) t)"
                               (expand-file-name "wb" drgnx-ui-repo-dir)))
      (explorer :setup ,(format "(progn (drgnx-explorer-set-roots (list %S)) (drgnx-wb-show-sidebar) t)" drgnx-ui-repo-dir)
                :each "(progn (drgnx-explorer-focus) (goto-char (point-min)) (drgnx-wb-focus-editor) t)"
                ;; the root shows ~12 rows: 10 downs, each one moves
                :actions ,(append (list (list :keys "C-S-e")) (funcall keys "<down>" 10) (list (list :keys "<escape>"))))
      (agent-typing :setup ,(format "(progn (setq drgnx-agents-profiles (list (list \"mock\" :command (list (expand-file-name invocation-name invocation-directory) \"--batch\" \"-Q\" \"-l\" %S))))
                                          (setq drgnx-perf--agent (drgnx-agents-start \"mock\" temporary-file-directory))
                                          (let ((d (+ (float-time) 10))) (while (and (not (eq (drgnx-agent-session-status drgnx-perf--agent) 'idle)) (< (float-time) d)) (accept-process-output nil 0.05)))
                                          (drgnx-agents-ui-view) t)"
                                    (expand-file-name "test/fixtures/mock-acp.el" drgnx-ui-repo-dir))
                    :each ,(concat "(progn " (drgnx-perf-run--visit-fixture-form)
                                   " (let ((d (+ (float-time) 5))) (while (and (eq (drgnx-agent-session-status drgnx-perf--agent) 'busy) (< (float-time) d)) (accept-process-output nil 0.05)))"
                                   " (drgnx-agents-send drgnx-perf--agent \"slow\") t)")
                    :actions ,(make-list 2 (funcall type "(setq y 2) "))
                    :check "(eq (drgnx-agent-session-status drgnx-perf--agent) 'busy)"   ; typed while it streamed
                    :teardown ,(concat "(progn (ignore-errors (drgnx-agents-kill drgnx-perf--agent)) " kill-fixture ")"))
      (frames :measure "(list :frame (drgnx-perf-frame-ms 5))")
      (redisplay :each ,(drgnx-perf-run--visit-fixture-form) :measure "(list :redisplay (drgnx-perf-redisplay-ms 30))" :teardown ,kill-fixture)
      (startup :daemon t)
      (memory :measure "(progn (garbage-collect) (list :rss_kb (drgnx-perf-rss-kb)))"))))

(defun drgnx-perf-run--daemon-env (tmp)
  "The environment of a measured daemon: the harness's allowlist (never tokens, never a trace or safe
mode), its own HOME and drgnx dirs under TMP."
  (append (mapcar (lambda (v) (format "%s=%s" (car v) (expand-file-name (cdr v) tmp)))
                  '(("HOME" . "home") ("DRGNX_CONFIG_DIR" . "config") ("XDG_STATE_HOME" . "state")
                    ("DRGNX_DATA_DIR" . "data") ("XDG_CACHE_HOME" . "cache") ("XDG_CONFIG_HOME" . "xdg-config")))
          (delq nil (mapcar (lambda (name) (and (getenv name) (not (member name '("HOME" "DRGNX_STARTUP_TRACE")))
                                                (concat name "=" (getenv name))))
                            (append drgnx-ui-keep-env '("XDG_RUNTIME_DIR"))))))

(defun drgnx-perf-run--client (name timeout &rest args)
  "emacsclient to daemon NAME, never starting another Emacs (-a false), at most TIMEOUT s: (EXIT . OUTPUT)."
  (with-temp-buffer
    (let ((rc (apply #'call-process "timeout" nil t nil (number-to-string timeout)
                     (or (executable-find "emacsclient") "emacsclient") "-a" "false" "-s" name args)))
      (cons rc (string-trim (buffer-string))))))

(defun drgnx-perf-run-daemon-startup (&optional runs init-dir)
  "The spec's startup measure: a drgnx daemon (isolated, temp dirs) until its server answers, RUNS (4)
times; the first warms the caches and is dropped.  A daemon that never answers is an error.
INIT-DIR: drgnx's init/ (default).  (:server_ms STATS :modules_ms N)."
  (let* ((tmp (make-temp-file "drgnx-perf-daemon" t))
         (emacs (expand-file-name invocation-name invocation-directory))
         (init-dir (and init-dir (expand-file-name init-dir)))
         (default-directory (file-name-as-directory tmp))     ; absolute: HOME is about to change
         (process-environment (drgnx-perf-run--daemon-env tmp))
         (init (or init-dir (expand-file-name "init" drgnx-ui-repo-dir)))
         times modules)
    (make-directory (expand-file-name "home" tmp) t)
    (unwind-protect
        (dotimes (i (or runs 4))
          (let* ((name (format "drgnx-perf-%d-%d" (emacs-pid) i)) (t0 (float-time))
                 (p (start-process name nil emacs (concat "--fg-daemon=" name) (concat "--init-directory=" init)))
                 (served nil))
            (unwind-protect
                (progn
                  (while (and (not served) (process-live-p p) (< (- (float-time) t0) 30))
                    (if (eql 0 (car (drgnx-perf-run--client name 2 "-e" "t"))) (setq served t) (sleep-for 0.01)))
                  (unless served (error "The daemon never answered (%s)" (if (process-live-p p) "30 s" "it exited")))
                  (when (or (> i 0) (= (or runs 4) 1)) (push (* 1000 (- (float-time) t0)) times))
                  (let ((m (drgnx-perf-run--client name 5 "-e" "(apply #'+ (mapcar (lambda (m) (or (plist-get (cdr m) :ms) 0)) (drgnx-modules-report)))")))
                    (unless (and (eql 0 (car m)) (string-match-p "\\`[0-9.]+\\'" (cdr m)))
                      (error "No module report from the daemon: %s" (cdr m)))
                    (setq modules (string-to-number (cdr m)))))
              (drgnx-perf-run--client name 3 "-e" "(kill-emacs)")
              (let ((d (+ (float-time) 5))) (while (and (process-live-p p) (< (float-time) d)) (sleep-for 0.05)))
              (when (process-live-p p) (delete-process p)))))
      (delete-directory tmp t))
    (list :server_ms (mapcar #'drgnx-perf--round (drgnx-perf-stats times)) :modules_ms modules)))

(defun drgnx-perf-run--call (sess form &optional timeout)
  (drgnx-ui-call sess (format "(progn (require 'drgnx-perf) (drgnx-uitest--json %s))" form) (or timeout 60)))

(defun drgnx-perf-run--median (runs path)
  (plist-get (drgnx-perf-stats (delq nil (mapcar (lambda (r) (let ((v r)) (dolist (k path) (setq v (plist-get v k))) (and (numberp v) v))) runs)))
             :p50))

(defun drgnx-perf-run--medians (runs)
  "One result from RUNS: every numeric value (also inside stats plists) the median over the runs."
  (let ((first (car runs)) out)
    (cl-loop for (k v) on first by #'cddr
             do (setq out (plist-put out k
                                     (cond ((numberp v) (drgnx-perf-run--median runs (list k)))
                                           ((and (consp v) (keywordp (car v)))
                                            (let (inner)
                                              (cl-loop for (k2 v2) on v by #'cddr
                                                       do (setq inner (plist-put inner k2 (if (numberp v2) (drgnx-perf-run--median runs (list k k2)) v2))))
                                              inner))
                                           (t v)))))
    out))

(defun drgnx-perf-run-workload (sess spec &optional audit)
  "Run workload SPEC in SESS: its setup, then :repeat (3) runs, the medians of their numbers.  AUDIT:
the hook audit on (its rows under :audit).  The probes, the audit and the teardown are undone even
when a step fails."
  (let ((actions (plist-get spec :actions)) (measure (plist-get spec :measure)))
    (if (plist-get spec :daemon) (drgnx-perf-run-daemon-startup)
      (unwind-protect
          (progn
            (when (plist-get spec :setup) (drgnx-perf-run--call sess (plist-get spec :setup) 120) (drgnx-ui-measure sess nil))
            (let (runs audit-rows)
              (dotimes (_ (or (plist-get spec :repeat) 3))
                (when (plist-get spec :each) (drgnx-perf-run--call sess (plist-get spec :each) 120) (drgnx-ui-measure sess nil))
                (if (not actions)
                    (push (drgnx-perf-run--call sess measure 120) runs)
                  (drgnx-perf-run--call sess (format "(progn %s (drgnx-perf-begin) t)" (if audit "(drgnx-perf-audit-begin)" "")))
                  (drgnx-ui-measure sess actions)
                  (push (drgnx-perf-run--call sess "(drgnx-perf-end)") runs)
                  (when audit
                    (setq audit-rows (append audit-rows (append (drgnx-perf-run--call sess "(vconcat (seq-take (drgnx-perf-audit-end) 30))") nil)))))
                (when (plist-get spec :check)
                  (unless (eq t (drgnx-perf-run--call sess (plist-get spec :check)))
                    (error "The workload did not do what it measures (%s)" (plist-get spec :check)))))
              (let ((r (drgnx-perf-run--medians runs)))
                (if audit (plist-put r :audit (vconcat audit-rows)) r))))
        ;; never leave the probes or the audit on, nor what the workload made
        (ignore-errors (drgnx-perf-run--call sess "(progn (when drgnx-perf--audit (drgnx-perf-audit-end)) (drgnx-perf-end) t)"))
        (when (plist-get spec :teardown) (ignore-errors (drgnx-perf-run--call sess (plist-get spec :teardown))))))))

(defun drgnx-perf-run--budgets ()
  (with-temp-buffer (insert-file-contents (expand-file-name "test/perf/budgets.eld" drgnx-ui-repo-dir)) (read (current-buffer))))

(defun drgnx-perf-run--commit ()
  (with-temp-buffer
    (if (eql 0 (call-process "git" nil t nil "-C" drgnx-ui-repo-dir "rev-parse" "--short" "HEAD")) (string-trim (buffer-string)) "unknown")))

(defun drgnx-perf-run--table (results)
  (mapconcat (lambda (r)
               (let ((p (cdr r)))
                 (format "%-13s %s" (car r)
                         (string-join
                          (delq nil (list (when-let* ((i (plist-get p :input))) (format "input p50 %s p95 %s max %s ms (n=%s)" (plist-get i :p50) (plist-get i :p95) (plist-get i :max) (plist-get i :n)))
                                          (when (plist-get p :gc_count) (format "gc %s/%s ms (pause p95 %s)" (plist-get p :gc_count) (plist-get p :gc_ms)
                                                                                (or (plist-get (plist-get p :gc_pause) :p95) "-")))
                                          (when-let* ((f (plist-get p :frame))) (format "frame p50 %s p95 %s ms" (plist-get f :p50) (plist-get f :p95)))
                                          (when-let* ((d (plist-get p :redisplay))) (format "redisplay p50 %s p95 %s ms" (plist-get d :p50) (plist-get d :p95)))
                                          (when-let* ((sv (plist-get p :server_ms))) (format "daemon server ready p50 %s max %s ms, modules %s ms" (plist-get sv :p50) (plist-get sv :max) (plist-get p :modules_ms)))
                                          (when (and (plist-get p :rss_kb) (not (plist-get p :input))) (format "rss %d MB" (/ (plist-get p :rss_kb) 1024)))))
                          ", "))))
             results "\n"))

(defconst drgnx-perf-run-hook-budget 2 "ms: any hook function's p95 (the spec), judged in the --audit pass.")

(defun drgnx-perf-run (&optional audit)
  "`drgnx test --perf': every workload in one session; print, judge (budgets, regressions against the
history), keep the history.  An exit code.  AUDIT (`--audit'): the hook audit on — judged on the hook
budget only (the audit adds its own cost to the other numbers)."
  (let* ((drgnx-perf-run--fixture (drgnx-perf-run--make-fixture))
         (s (drgnx-ui-start "drgnx" "1400x800" 60)) (sess (drgnx-ui-own-session (plist-get s :name))) results)
    (unwind-protect
        (dolist (w (drgnx-perf-run--workloads))
          (message "perf: %s…" (car w))
          (push (cons (car w) (condition-case err (drgnx-perf-run-workload sess (cdr w) audit)
                                (error (list :error (error-message-string err)))))
                results))
      (drgnx-ui-stop (plist-get s :name))
      (delete-file drgnx-perf-run--fixture))
    (setq results (nreverse results))
    (princ (concat (drgnx-perf-run--table results) "\n"))
    (let ((errors (seq-filter (lambda (r) (plist-get (cdr r) :error)) results)))
      (pcase-dolist (`(,w . ,p) errors) (princ (format "ERROR %s: %s\n" w (plist-get p :error))))
      (if audit
          (let ((rows (seq-mapcat (lambda (r) (append (plist-get (cdr r) :audit) nil)) results)))
            (dolist (row (seq-take (sort (copy-sequence rows) (lambda (a b) (> (plist-get a :ms) (plist-get b :ms)))) 40))
              (princ (format "audit %-40s %-34s %6s calls  p95 %6s  max %6s  total %8s ms\n" (plist-get row :fn) (plist-get row :hooks)
                             (plist-get row :calls) (plist-get row :p95) (plist-get row :max) (plist-get row :ms))))
            (let ((fails (drgnx-perf-audit-verdict rows drgnx-perf-run-hook-budget)))
              (dolist (f fails) (princ (format "FAIL %s\n" f)))
              (if (or fails errors) 1 (princ "perf audit: every hook function within its budget\n") 0)))
        (let* ((history (expand-file-name "perf-history.jsonl" (drgnx-ui-state-root)))
               (fails (drgnx-perf-verdict results (drgnx-perf-run--budgets)))
               (worse (drgnx-perf-regressions history results)))
          (dolist (f fails) (princ (format "FAIL %s\n" f)))
          (dolist (r worse) (princ (format "FAIL regression: %s\n" r)))
          (unless errors (drgnx-perf-history-append history (drgnx-perf-run--commit) results))
          (princ (format "history: %s%s\n" history (if errors " (not written: a workload failed)" "")))
          (if (or fails worse errors) 1
            (princ "perf: every budget holds\n") 0))))))

(defun drgnx-perf-soak (&optional minutes)
  "`drgnx test --soak [MINUTES]': the input workloads in a loop for MINUTES (30); memory sampled after
each round; fails when RSS grows by more than 20% from the first round or passes 400 MB."
  (let* ((minutes (max 1 (or minutes 30))) (deadline (+ (float-time) (* 60 minutes)))
         (drgnx-perf-run--fixture (drgnx-perf-run--make-fixture))
         (process-environment (cons (format "DRGNX_UI_MAX_RUNTIME=%d" (+ (* 60 minutes) 900)) process-environment))
         (s (drgnx-ui-start "drgnx" "1400x800" 60)) (sess (drgnx-ui-own-session (plist-get s :name)))
         (loads (seq-filter (lambda (w) (plist-get (cdr w) :actions)) (drgnx-perf-run--workloads)))
         samples)
    (unwind-protect
        (while (< (float-time) deadline)
          (dolist (w loads) (ignore-errors (drgnx-perf-run-workload sess (cdr w))))   ; each cleans up after itself
          (push (plist-get (drgnx-perf-run--call sess "(progn (garbage-collect) (list :rss_kb (drgnx-perf-rss-kb)))") :rss_kb) samples)
          (message "soak: round %d, %d MB" (length samples) (/ (car samples) 1024)))
      (drgnx-ui-stop (plist-get s :name))
      (delete-file drgnx-perf-run--fixture))
    (unless samples (error "The soak finished no round"))
    (let* ((rounds (reverse samples)) (first (car rounds)) (last (car samples))
           (growth (and first (> first 0) (/ (* 100.0 (- last first)) first))))
      (princ (format "soak: %d rounds in %d min; RSS %d → %d MB (%+.1f%%)\n" (length rounds) minutes (/ first 1024) (/ last 1024) growth))
      (if (or (> growth 20) (> last (* 400 1024)))
          (progn (princ "FAIL soak: memory grew more than 20% or passed 400 MB\n") 1)
        (princ "soak: memory holds\n") 0))))

(provide 'drgnx-perf-run)
;;; drgnx-perf-run.el ends here
