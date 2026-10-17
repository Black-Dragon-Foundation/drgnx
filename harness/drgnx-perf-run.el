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

(defun drgnx-perf-run--fixture-form ()
  "A form (string) that visits a large Emacs Lisp file: drgnx's own core concatenated, in a temp file."
  (format "(let* ((dir %S) (f (make-temp-file \"drgnx-perf-\" nil \".el\")))
             (with-temp-file f (dotimes (_ 3) (dolist (x (directory-files dir t \"\\\\.el\\\\'\")) (insert-file-contents x) (goto-char (point-max)))))
             (find-file f) (goto-char (/ (point-max) 2)) (forward-line 0) t)"
          (expand-file-name "core" drgnx-ui-repo-dir)))

(defun drgnx-perf-run--workloads ()
  "The workloads: (NAME :setup FORM :actions ACTIONS :measure FORM :repeat N)."
  (let ((type (lambda (s) (list :type s))) (keys (lambda (k n) (make-list n (list :keys k)))))
    `((typing :setup ,(drgnx-perf-run--fixture-form)
              :actions ,(make-list 6 (funcall type "(let ((x 1)) (message \"%s\" x)) ")) :repeat 3)
      (scrolling :setup "(progn (goto-char (point-min)) t)"
                 :actions ,(append (funcall keys "<next>" 30) (funcall keys "<prior>" 30)) :repeat 3)
      (tabs :setup ,(format "(progn (dolist (f (seq-take (directory-files %S t \"\\\\.el\\\\'\") 20)) (find-file f)) t)"
                            (expand-file-name "wb" drgnx-ui-repo-dir))
            :actions ,(funcall keys "C-<next>" 20) :repeat 3)
      (explorer :setup ,(format "(progn (drgnx-explorer-set-roots (list %S)) (drgnx-wb-show-sidebar) t)" drgnx-ui-repo-dir)
                :actions ,(append (list (list :keys "C-S-e")) (funcall keys "<down>" 30) (list (list :keys "<escape>"))) :repeat 3)
      (agent-typing :setup ,(format "(progn (setq drgnx-agents-profiles (list (list \"mock\" :command (list (expand-file-name invocation-name invocation-directory) \"--batch\" \"-Q\" \"-l\" %S))))
                                          (setq drgnx-perf--agent (drgnx-agents-start \"mock\" temporary-file-directory))
                                          (let ((d (+ (float-time) 10))) (while (and (not (eq (drgnx-agent-session-status drgnx-perf--agent) 'idle)) (< (float-time) d)) (accept-process-output nil 0.05)))
                                          (drgnx-agents-ui-view) (drgnx-agents-send drgnx-perf--agent \"slow\") (select-window (get-buffer-window (car (seq-filter #'buffer-file-name (buffer-list))))) t)"
                                    (expand-file-name "test/fixtures/mock-acp.el" drgnx-ui-repo-dir))
                    :actions ,(make-list 3 (funcall type "(setq y 2) ")) :repeat 1
                    :teardown "(progn (drgnx-agents-kill drgnx-perf--agent) t)")
      (frames :measure "(list :frame (drgnx-perf-frame-ms 5))")
      (redisplay :measure "(list :redisplay (drgnx-perf-redisplay-ms 30))")
      (startup :daemon t)
      (memory :measure "(progn (garbage-collect) (list :rss_kb (drgnx-perf-rss-kb)))"))))

(defun drgnx-perf-run-daemon-startup (&optional runs)
  "The spec's startup measure: a drgnx daemon (in temp dirs) until its server answers, RUNS (4) times;
the first warms the caches and is dropped.  (:server_ms STATS :modules_ms N)."
  (let* ((tmp (make-temp-file "drgnx-perf-daemon" t))
         (emacs (expand-file-name invocation-name invocation-directory))
         (client (or (executable-find "emacsclient") "emacsclient"))
         (process-environment (append (mapcar (lambda (v) (format "%s=%s" (car v) (expand-file-name (cdr v) tmp)))
                                              '(("DRGNX_CONFIG_DIR" . "config") ("XDG_STATE_HOME" . "state")
                                                ("DRGNX_DATA_DIR" . "data") ("XDG_CACHE_HOME" . "cache")))
                                      process-environment))
         times modules)
    (unwind-protect
        (dotimes (i (or runs 4))
          (let* ((name (format "drgnx-perf-%d-%d" (emacs-pid) i)) (t0 (float-time))
                 (p (start-process name nil emacs (concat "--fg-daemon=" name)
                                   (concat "--init-directory=" (expand-file-name "init" drgnx-ui-repo-dir)))))
            (while (and (process-live-p p) (< (- (float-time) t0) 30)
                        (not (eql 0 (call-process client nil nil nil "-s" name "-e" "t"))))
              (sleep-for 0.01))
            (let ((ms (* 1000 (- (float-time) t0))))
              (when (> i 0) (push ms times))
              (setq modules (with-temp-buffer
                              (call-process client nil t nil "-s" name "-e"
                                            "(apply #'+ (mapcar (lambda (m) (or (plist-get (cdr m) :ms) 0)) (drgnx-modules-report)))")
                              (string-to-number (buffer-string)))))
            (call-process client nil nil nil "-s" name "-e" "(kill-emacs)")
            (let ((d (+ (float-time) 5))) (while (and (process-live-p p) (< (float-time) d)) (sleep-for 0.05)))
            (when (process-live-p p) (delete-process p))))
      (delete-directory tmp t))
    (list :server_ms (mapcar #'drgnx-perf--round (drgnx-perf-stats times)) :modules_ms modules)))

(defun drgnx-perf-run--call (sess form &optional timeout)
  (drgnx-ui-call sess (format "(progn (require 'drgnx-perf) (drgnx-uitest--json %s))" form) (or timeout 60)))

(defun drgnx-perf-run--median (runs path)
  (plist-get (drgnx-perf-stats (delq nil (mapcar (lambda (r) (let ((v r)) (dolist (k path v) (setq v (plist-get v k))))) runs))) :p50))

(defun drgnx-perf-run-workload (sess spec &optional audit)
  "Run workload SPEC in SESS; its result plist.  AUDIT: the hook audit on (rows under :audit)."
  (let ((setup (plist-get spec :setup)) (actions (plist-get spec :actions)) (measure (plist-get spec :measure)))
    (when setup (drgnx-perf-run--call sess setup 120) (drgnx-ui-measure sess nil))
    (prog1
        (cond
         ((plist-get spec :daemon) (drgnx-perf-run-daemon-startup))
         ((not actions)
            (drgnx-perf-run--call sess measure 120))
         (t
          (let (runs)
            (dotimes (_ (or (plist-get spec :repeat) 1))
              (drgnx-perf-run--call sess (format "(progn %s (drgnx-perf-begin) t)" (if audit "(drgnx-perf-audit-begin)" "")))
              (drgnx-ui-measure sess actions)
              (push (drgnx-perf-run--call sess (format "(let ((r (drgnx-perf-end))) %s r)"
                                                       (if audit "(plist-put r :audit (vconcat (seq-take (drgnx-perf-audit-end) 15)))" "")))
                    runs))
            (let ((first (car runs)))
              (plist-put (copy-sequence first) :input
                         (list :n (plist-get (plist-get first :input) :n)
                               :p50 (drgnx-perf-run--median runs '(:input :p50))
                               :p95 (drgnx-perf-run--median runs '(:input :p95))
                               :max (drgnx-perf-run--median runs '(:input :max))))))))
      (when (plist-get spec :teardown) (ignore-errors (drgnx-perf-run--call sess (plist-get spec :teardown)))))))

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
                                          (when (plist-get p :gc_count) (format "gc %s/%s ms" (plist-get p :gc_count) (plist-get p :gc_ms)))
                                          (when-let* ((f (plist-get p :frame))) (format "frame p50 %s p95 %s ms" (plist-get f :p50) (plist-get f :p95)))
                                          (when-let* ((d (plist-get p :redisplay))) (format "redisplay p50 %s p95 %s ms" (plist-get d :p50) (plist-get d :p95)))
                                          (when-let* ((sv (plist-get p :server_ms))) (format "daemon server ready p50 %s max %s ms, modules %s ms" (plist-get sv :p50) (plist-get sv :max) (plist-get p :modules_ms)))
                                          (when (and (plist-get p :rss_kb) (not (plist-get p :input))) (format "rss %d MB" (/ (plist-get p :rss_kb) 1024)))))
                          ", "))))
             results "\n"))

(defun drgnx-perf-run (&optional audit)
  "`drgnx test --perf': every workload in one session; print, judge, keep the history.  An exit code.
AUDIT (`--audit'): the hook audit on, printed, never judged (it adds its own cost)."
  (let* ((s (drgnx-ui-start "drgnx" "1400x800" 60)) (sess (drgnx-ui-own-session (plist-get s :name))) results)
    (unwind-protect
        (dolist (w (drgnx-perf-run--workloads))
          (message "perf: %s…" (car w))
          (push (cons (car w) (condition-case err (drgnx-perf-run-workload sess (cdr w) audit)
                                (error (list :error (error-message-string err)))))
                results))
      (drgnx-ui-stop (plist-get s :name)))
    (setq results (nreverse results))
    (princ (concat (drgnx-perf-run--table results) "\n"))
    (pcase-dolist (`(,w . ,p) results) (when (plist-get p :error) (princ (format "ERROR %s: %s\n" w (plist-get p :error)))))
    (if audit
        (progn (pcase-dolist (`(,w . ,p) results)
                 (dolist (row (append (plist-get p :audit) nil))
                   (princ (format "audit %-12s %-28s %-50s %5s calls %8s ms\n" w (plist-get row :hook) (plist-get row :fn)
                                  (plist-get row :calls) (plist-get row :ms)))))
               0)
      (let* ((history (expand-file-name "perf-history.jsonl" (drgnx-ui-state-root)))
             (fails (drgnx-perf-verdict results (drgnx-perf-run--budgets)))
             (worse (drgnx-perf-regressions history results)))
        (dolist (f fails) (princ (format "FAIL %s\n" f)))
        (dolist (r worse) (princ (format "WORSE %s\n" r)))
        (unless (seq-some (lambda (r) (plist-get (cdr r) :error)) results)
          (drgnx-perf-history-append history (drgnx-perf-run--commit) results))
        (princ (format "history: %s\n" history))
        (if (or fails (seq-some (lambda (r) (plist-get (cdr r) :error)) results))
            1
          (princ "perf: every budget holds\n") 0)))))

(defun drgnx-perf-soak (&optional minutes)
  "`drgnx test --soak [MINUTES]': the input workloads in a loop for MINUTES (30); memory sampled after
each round; fails when RSS grows by more than 20% from the first round or passes 400 MB."
  (let* ((minutes (or minutes 30)) (deadline (+ (float-time) (* 60 minutes)))
         (s (drgnx-ui-start "drgnx" "1400x800" 60)) (sess (drgnx-ui-own-session (plist-get s :name)))
         (loads (seq-filter (lambda (w) (plist-get (cdr w) :actions)) (drgnx-perf-run--workloads)))
         samples)
    (unwind-protect
        (while (< (float-time) deadline)
          (dolist (w loads) (ignore-errors (drgnx-perf-run-workload sess (cdr w))))
          (push (plist-get (drgnx-perf-run--call sess "(progn (garbage-collect) (list :rss_kb (drgnx-perf-rss-kb)))") :rss_kb) samples)
          (message "soak: round %d, %d MB" (length samples) (/ (car samples) 1024)))
      (drgnx-ui-stop (plist-get s :name)))
    (let* ((rounds (reverse samples)) (first (car rounds)) (last (car samples))
           (growth (and first (> first 0) (/ (* 100.0 (- last first)) first))))
      (princ (format "soak: %d rounds in %d min; RSS %d → %d MB (%+.1f%%)\n" (length rounds) minutes (/ first 1024) (/ last 1024) growth))
      (if (or (> growth 20) (> last (* 400 1024)))
          (progn (princ "FAIL soak: memory grew more than 20% or passed 400 MB\n") 1)
        (princ "soak: memory holds\n") 0))))

(provide 'drgnx-perf-run)
;;; drgnx-perf-run.el ends here
