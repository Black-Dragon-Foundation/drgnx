;;; panel-replay-fixture.el --- one mock agent replaying the recorded turn into the agent panel -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The session side of the `panel-replay' workloads (docs/develop/perf.md, "The agent panel's workloads"): a hub of the
;; session's own (`$DRGNX_RATATOSKR_BIN', a test-hooks build, with `ratatoskr-mock' beside it) and one mock agent whose
;; first turn makes about 1,900 entries at once (an answer and a read, `drgnx-panel-replay-prefix' times), and whose
;; second, sent when the measure starts, streams the synthetic day's recording (test/fixtures/day/transcript.eld) at 20
;; updates a second, a read every tenth chunk, so the transcript ends near 2,000 entries.  The agent panel shows the session (its module on) while the mirror holds the
;; transcript: `drgnx-panel-replay-measure' takes what each update costs the editor, the events' handlers and the panel's
;; draws.  The mock agent only; nothing here reaches a subscription.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-panel-replay-prefix 950 "Answers and reads the turn opens with, at once: about 1,900 entries.")
(defconst drgnx-panel-replay-updates 600 "Chunks streamed after the prefix, 20 a second.")
(defconst drgnx-panel-replay-measured 400 "Updates the measure waits for (at most 40 s).")

(defvar drgnx-panel-replay--dir nil "The temp directory: the project and the hub's settings.")
(defvar drgnx-panel-replay--hub nil "The hub process.")
(defvar drgnx-panel-replay--mirror nil "The session's mirror.")
(defvar drgnx-panel-replay--panel nil "The panel's buffer.")
(defvar drgnx-panel-replay--module nil "Whether tools/agent-panel ran before the workload.")
(defvar drgnx-panel-replay--allocs nil "Objects each update's events made (newest first), while armed.")
(defvar drgnx-panel-replay--draws nil "kB each draw of the panel made (newest first), while armed.")
(defvar drgnx-panel-replay--armed nil "Non-nil while the updates are measured.")

(declare-function drgnx-agents-mirror-start "drgnx-agents-mirror")
(declare-function drgnx-agents-send "drgnx-agents")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(declare-function drgnx-agents-kill "drgnx-agents")
(declare-function drgnx-agents-mirror-stop "drgnx-agents-mirror")
(declare-function drgnx-agent-session-remote "drgnx-agents")
(declare-function drgnx-agent-session-entries "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agent-panel-open "drgnx-agent-panel")
(declare-function drgnx-hub-running-p "drgnx-hub-client")
(declare-function drgnx-hub-connect "drgnx-hub-client")
(declare-function drgnx-hub-ensure "drgnx-hub-client")
(declare-function drgnx-hub-disconnect "drgnx-hub-client")
(declare-function drgnx-modules-report "drgnx-modules")
(declare-function drgnx-modules-set-enabled "drgnx-modules")
(declare-function drgnx-modules-run "drgnx-modules")
(declare-function drgnx-gc--consed "drgnx-gc")
(declare-function drgnx-perf-stats "drgnx-perf")
(defvar drgnx-agents--sessions)
(defvar drgnx-agent-panel--loaded)
(defvar drgnx-agent-panel--entries)

(defun drgnx-panel-replay--chunks ()
  "The recording's chunks, as one-line texts."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "test/fixtures/day/transcript.eld" drgnx-dir))
    (mapcar (lambda (c) (string-trim (replace-regexp-in-string "[\n\\\\]" " " (cdr c)))) (read (current-buffer)))))

(defun drgnx-panel-replay-program ()
  "The mock's script: two lines (one per turn) with `\\n' between the words: the prefix at once, then the recording at
20 updates a second, a read every tenth chunk (no two reads the same call: the hub pauses an agent that repeats one)."
  (let* ((chunks (vconcat (drgnx-panel-replay--chunks))) (n (length chunks)) (read 0)
         (prefix (cl-loop for i below drgnx-panel-replay-prefix
                          append (list (concat "say " (aref chunks (% i n)))
                                       (format "provider:read src/main.el %d 1" (cl-incf read)))))
         (stream (cl-loop for u below drgnx-panel-replay-updates
                          append (append (list (concat "say " (aref chunks (% u n))) "silent 0.05")
                                         (and (zerop (% (1+ u) 10))
                                              (list (format "provider:read src/main.el %d 1" (cl-incf read))))))))
    (concat (mapconcat #'identity prefix "\\n") "\n" (mapconcat #'identity stream "\\n"))))

(defun drgnx-panel-replay--wait (secs pred)
  "Let the session run until PRED holds (at most SECS s); whether it does."
  (let ((d (+ (float-time) secs)))
    (while (and (not (funcall pred)) (< (float-time) d)) (accept-process-output nil 0.05))
    (and (funcall pred) t)))

(defun drgnx-panel-replay--entries ()
  (length (drgnx-agent-session-entries drgnx-panel-replay--mirror)))

(defun drgnx-panel-replay-up (bin)
  "Start a hub of BIN and the mock agent, wait for the prefix, open the panel on the session; the panel's buffer."
  (require 'drgnx-agents-mirror)
  (require 'drgnx-hub-client)
  (require 'drgnx-modules)
  (let ((mock (and bin (expand-file-name "ratatoskr-mock" (file-name-directory bin)))))
    (unless (and mock (file-executable-p bin) (file-executable-p mock))
      (error "panel-replay needs DRGNX_RATATOSKR_BIN (a test-hooks ratatoskr) with ratatoskr-mock beside it"))
    ;; the module is defined when its file loads (a module of an idle stage: its setup runs here, not at the first idle)
    (require 'drgnx-agent-panel)
    (setq drgnx-panel-replay--module (eq 'ok (plist-get (cdr (assq 'tools/agent-panel (drgnx-modules-report))) :status)))
    (drgnx-modules-set-enabled 'tools/agent-panel t)
    (drgnx-modules-run 'idle)
    (let ((r (cdr (assq 'tools/agent-panel (drgnx-modules-report)))))
      (unless (eq 'ok (plist-get r :status))
        (error "The module tools/agent-panel is not running: %S" r)))
    (setq drgnx-panel-replay--dir (make-temp-file "drgnx-panel-replay" t))
    (let* ((dir drgnx-panel-replay--dir) (project (expand-file-name "project" dir)) (config (expand-file-name "config" dir))
           (script (expand-file-name "replay.txt" config)))
      (make-directory (expand-file-name "src" project) t)
      (with-temp-file (expand-file-name "src/main.el" project) (insert ";; the file the agent reads\n"))
      (let ((default-directory (file-name-as-directory project)))
        (dolist (args '(("init" "-q" "-b" "main") ("add" "src") ("commit" "-q" "-m" "init")))
          (unless (zerop (apply #'call-process "git" nil nil nil "-c" "user.name=perf" "-c" "user.email=perf@localhost"
                                "-c" "commit.gpgsign=false" args))
            (error "git %S failed" args))))
      (make-directory config t)
      (with-temp-file script (insert (drgnx-panel-replay-program) "\n"))
      (with-temp-file (expand-file-name "settings.el" config)
        (prin1 (list 'drgnx-settings :version 1
                     (list 'drgnx-agents-profiles
                           (list (list "replay" :command (list mock "acp" "--as" "claude" "--script" script
                                                               "--log" (concat script ".log"))))))
               (current-buffer)))
      (let ((process-environment (append (list (concat "DRGNX_CONFIG_DIR=" config) "RATATOSKR_SUPERVISOR=none"
                                               (concat "DRGNX_DIR=" (directory-file-name drgnx-dir)))
                                         process-environment)))
        (setq drgnx-panel-replay--hub
              (make-process :name "ratatoskr" :noquery t :connection-type 'pipe
                            :buffer (generate-new-buffer " *ratatoskr-panel-replay*")
                            :command (list bin "serve" "--foreground" "--parent-pid" (number-to-string (emacs-pid))))))
      (unless (drgnx-panel-replay--wait 15 #'drgnx-hub-running-p) (error "Ratatoskr did not answer a ping"))
      (drgnx-hub-connect)
      (drgnx-hub-ensure)
      (setq drgnx-panel-replay--mirror (drgnx-agents-mirror-start "replay" project))
      (unless drgnx-panel-replay--mirror (error "The agent did not start"))
      ;; the panel first: the hub sends a session's entries only to a connection that asked, and the panel's
      ;; subscription brings them to the mirror too (the mirror subscribes only for a transcript a window shows)
      (require 'drgnx-agent-panel)
      (setq drgnx-panel-replay--panel (drgnx-agent-panel-open (drgnx-agent-session-remote drgnx-panel-replay--mirror)))
      (unless (drgnx-panel-replay--wait 15 (lambda () (buffer-local-value 'drgnx-agent-panel--loaded drgnx-panel-replay--panel)))
        (error "Premise: the panel did not load its first page"))
      (drgnx-agents-send drgnx-panel-replay--mirror "go")
      ;; the prefix is in when the mirror holds it; the waits stay inside the harness's 120 s for a setup, so a slow
      ;; one reports where it stopped
      (unless (drgnx-panel-replay--wait 75 (lambda () (>= (drgnx-panel-replay--entries) (* 2 drgnx-panel-replay-prefix))))
        (error "Premise: the mirror holds %d entries, not the prefix's %d (status %s; the hub: %s)"
               (drgnx-panel-replay--entries) (* 2 drgnx-panel-replay-prefix)
               (drgnx-agent-session-status drgnx-panel-replay--mirror) (drgnx-panel-replay--hub-facts)))
      drgnx-panel-replay--panel)))

(defun drgnx-panel-replay--update-p (event data)
  "Whether EVENT with DATA is an update of the replayed session: its entries, or a row patch of its panel."
  (let ((id (drgnx-agent-session-remote drgnx-panel-replay--mirror)))
    (or (and (equal event "agent-entries") (equal (plist-get data :id) id))
        (and (equal event "view-patch") (stringp (plist-get data :view)) (string-search id (plist-get data :view))))))

(defun drgnx-panel-replay--event (orig name &rest args)
  "Around `drgnx-hub--run-hook': the objects an update's handlers make, while armed."
  (if (not (and drgnx-panel-replay--armed (eq name 'events) (drgnx-panel-replay--update-p (nth 1 args) (nth 2 args))))
      (apply orig name args)
    (let ((a0 (apply #'+ (memory-use-counts))))
      (prog1 (apply orig name args)
        (push (- (apply #'+ (memory-use-counts)) a0) drgnx-panel-replay--allocs)))))

(defun drgnx-panel-replay--draw (orig buffer &rest args)
  "Around `drgnx-view--draw-buffer': the kB a draw of the panel makes, while armed."
  (if (not (and drgnx-panel-replay--armed (eq buffer drgnx-panel-replay--panel)))
      (apply orig buffer args)
    (let ((c0 (drgnx-gc--consed)))
      (prog1 (apply orig buffer args)
        (push (/ (- (drgnx-gc--consed) c0) 1024.0) drgnx-panel-replay--draws)))))

(defun drgnx-panel-replay--hub-facts ()
  "What the hub holds of the session (its status, its entries and the last ones' types and texts), for a premise
that failed."
  (condition-case err
      (let* ((r (drgnx-hub-call-sync "agents/get" (list :id (drgnx-agent-session-remote drgnx-panel-replay--mirror))))
             (es (append (plist-get r :entries) nil)))
        (format "%s, %d entries, last %S" (plist-get (plist-get r :session) :status) (length es)
                (mapcar (lambda (e) (list (plist-get e :type) (truncate-string-to-width
                                                               (format "%s" (or (plist-get e :text) (plist-get e :title) ""))
                                                               40)))
                        (last es 4))))
    (error (format "agents/get failed: %S" err))))

(defun drgnx-panel-replay--log-tail ()
  "The last lines of the mock agent's log (at most 800 characters), for a premise that failed."
  (let ((log (expand-file-name "config/replay.txt.log" drgnx-panel-replay--dir)))
    (if (not (file-readable-p log)) "(no log)"
      (with-temp-buffer
        (insert-file-contents log)
        (let ((text (buffer-substring-no-properties (max (point-min) (- (point-max) 800)) (point-max))))
          (replace-regexp-in-string "\n" " | " text))))))

(defun drgnx-panel-replay-measure ()
  "(:alloc STATS :draw_kb STATS :updates N :entries N :rows N): `drgnx-panel-replay-measured' updates of the stream
(at most 40 s), each update's events and each draw of the panel."
  (require 'drgnx-gc)
  (setq drgnx-panel-replay--allocs nil drgnx-panel-replay--draws nil drgnx-panel-replay--armed t)
  (advice-add 'drgnx-hub--run-hook :around #'drgnx-panel-replay--event)
  (advice-add 'drgnx-view--draw-buffer :around #'drgnx-panel-replay--draw)
  ;; the second turn: the recording streams
  (drgnx-agents-send drgnx-panel-replay--mirror "stream")
  (unwind-protect
      (drgnx-panel-replay--wait 40 (lambda () (>= (length drgnx-panel-replay--allocs) drgnx-panel-replay-measured)))
    (setq drgnx-panel-replay--armed nil)
    (advice-remove 'drgnx-hub--run-hook #'drgnx-panel-replay--event)
    (advice-remove 'drgnx-view--draw-buffer #'drgnx-panel-replay--draw))
  (when (< (length drgnx-panel-replay--allocs) 200)
    (error "Premise: %d updates measured, not 200 (status %s, %d entries; the hub: %s; the mock's log ends: %s)"
           (length drgnx-panel-replay--allocs)
           (drgnx-agent-session-status drgnx-panel-replay--mirror) (drgnx-panel-replay--entries)
           (drgnx-panel-replay--hub-facts) (drgnx-panel-replay--log-tail)))
  (list :alloc (drgnx-perf-stats drgnx-panel-replay--allocs)
        :draw_kb (mapcar (lambda (x) (if (floatp x) (/ (round (* 100 x)) 100.0) x)) (drgnx-perf-stats drgnx-panel-replay--draws))
        :updates (length drgnx-panel-replay--allocs) :entries (drgnx-panel-replay--entries)
        :rows (with-current-buffer drgnx-panel-replay--panel (count-lines (point-min) (point-max)))))

(defun drgnx-panel-replay-down ()
  "End the agent and the hub; drop the mirror, the panel and the fixture's folder; the module back as it was."
  (ignore-errors (when drgnx-panel-replay--mirror (drgnx-agents-kill drgnx-panel-replay--mirror)))
  (ignore-errors (drgnx-agents-mirror-stop))
  (ignore-errors (drgnx-hub-disconnect))
  (when (process-live-p drgnx-panel-replay--hub)
    (signal-process drgnx-panel-replay--hub 'term)
    (unless (drgnx-panel-replay--wait 10 (lambda () (not (process-live-p drgnx-panel-replay--hub))))
      (signal-process drgnx-panel-replay--hub 'kill)))
  (when (and drgnx-panel-replay--hub (buffer-live-p (process-buffer drgnx-panel-replay--hub)))
    (kill-buffer (process-buffer drgnx-panel-replay--hub)))
  (when (buffer-live-p drgnx-panel-replay--panel) (kill-buffer drgnx-panel-replay--panel))
  (setq drgnx-panel-replay--hub nil drgnx-panel-replay--mirror nil drgnx-panel-replay--panel nil
        drgnx-agents--sessions (seq-remove #'drgnx-agent-session-remote drgnx-agents--sessions))
  (drgnx-modules-set-enabled 'tools/agent-panel drgnx-panel-replay--module)
  (when drgnx-panel-replay--dir
    (ignore-errors (delete-directory drgnx-panel-replay--dir t))
    (setq drgnx-panel-replay--dir nil))
  t)

(provide 'panel-replay-fixture)
;;; panel-replay-fixture.el ends here
