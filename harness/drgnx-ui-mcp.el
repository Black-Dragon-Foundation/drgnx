;;; drgnx-ui-mcp.el --- drgnx-ui: MCP server for harness sessions (stdio, batch Emacs) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Lets agents start, see and drive headless GUI Emacs sessions (docs/develop/harness.md).  Every
;; tool resolves its session through `drgnx-ui-own-session', so only sessions this harness
;; started are reachable — never the user's own Emacs.  Run it as
;;     bin/drgnx ui mcp
;; e.g. for Claude Code: claude mcp add -s user drgnx-ui -- <checkout>/bin/drgnx ui mcp
;; The small client at the end drives it from Emacs Lisp (tests, scripts).

;;; Code:
(require 'drgnx-ui)

(defconst drgnx-ui-mcp-protocol "2025-06-18")

(defun drgnx-ui-mcp--schema (props &optional required)
  (list :type "object"
        :properties (or props (make-hash-table))     ; {} — json-serialize turns nil into null
        :required (vconcat required)))

(defconst drgnx-ui-mcp--session
  '(:session (:type "string" :description "Session name from ui_start / ui_list, e.g. drgnx-ui-1")))

(defconst drgnx-ui-mcp--click
  '(:x (:type "integer") :y (:type "integer")
    :buffer (:type "string" :description "Buffer name or major mode of the target window")
    :text (:type "string" :description "Visible text to click on (first occurrence)")
    :button (:type "integer" :enum [1 2 3]) :count (:type "integer" :enum [1 2])
    :hold_ms (:type "integer" :description "Hold the button this long before releasing")))

(defconst drgnx-ui-mcp--report
  "Returns a jank report: settle_ms, layout_changes, collateral_moves (windows that changed without being \
the input's target), oscillations, chrome_changes, echo_changes, scrolls, redisplays, gc_count, gc_ms, \
guard_violations (window moves from timers).")

(defconst drgnx-ui-mcp-tools
  (list
   (list :name "ui_start"
         :description "Start a headless GUI Emacs session for testing (never the user's Emacs). config: minimal (stock Emacs), gryphn, or a config directory (read-only; state stays in the session)."
         :inputSchema (drgnx-ui-mcp--schema '(:config (:type "string")
                                              :size (:type "string" :description "WxH, default 1600x900")
                                              :daemon (:type "boolean" :description "Run Emacs as a daemon: no frame until ui_frame")
                                              :monitors (:type "integer" :description "Virtual monitors of that size (default 1)"))))
   (list :name "ui_frame"
         :description "Open a frame in a daemon session the way a user does (emacsclient -c); returns exit status, client_ms, visible_ms and the slowest frame hooks."
         :inputSchema (drgnx-ui-mcp--schema drgnx-ui-mcp--session '("session")))
   (list :name "ui_stop" :description "Stop a session and remove its files."
         :inputSchema (drgnx-ui-mcp--schema drgnx-ui-mcp--session '("session")))
   (list :name "ui_list" :description "List harness sessions." :inputSchema (drgnx-ui-mcp--schema nil))
   (list :name "ui_state"
         :description "Frame size, windows (id, buffer, mode, pixel edges, body, start/point/line, header/mode-line heights, selected), minibuffer height, child frames, busy."
         :inputSchema (drgnx-ui-mcp--schema drgnx-ui-mcp--session '("session")))
   (list :name "ui_screenshot"
         :description "Screenshot of the session with child frames (posframes) composited, plus the PNG path and the window map. Pixels are the coordinates ui_click uses."
         :inputSchema (drgnx-ui-mcp--schema (append drgnx-ui-mcp--session '(:path (:type "string")))
                                            '("session")))
   (list :name "ui_click"
         :description (concat "Click at frame pixel x,y, or on visible text in the window showing a buffer. Waits until the UI settles. "
                              drgnx-ui-mcp--report)
         :inputSchema (drgnx-ui-mcp--schema (append drgnx-ui-mcp--session drgnx-ui-mcp--click) '("session")))
   (list :name "ui_keys"
         :description (concat "Send keys in Emacs kbd syntax (\"C-x b\", \"M-x\", \"RET\"), one event per 40 ms tick; waits until settled. "
                              drgnx-ui-mcp--report)
         :inputSchema (drgnx-ui-mcp--schema (append drgnx-ui-mcp--session '(:keys (:type "string")))
                                            '("session" "keys")))
   (list :name "ui_type"
         :description (concat "Type text, one character per tick; waits until settled. " drgnx-ui-mcp--report)
         :inputSchema (drgnx-ui-mcp--schema (append drgnx-ui-mcp--session '(:text (:type "string")))
                                            '("session" "text")))
   (list :name "ui_wait"
         :description "Wait until no input is pending and nothing changed for quiet_ms (default 300)."
         :inputSchema (drgnx-ui-mcp--schema (append drgnx-ui-mcp--session
                                                    '(:quiet_ms (:type "integer") :timeout_ms (:type "integer")))
                                            '("session")))
   (list :name "ui_diff"
         :description "What changed between two states: give a and b (ui_state results), or only the session to compare its state now with the state the previous ui_state/ui_diff call saw. Returns changes: {window, field, old, new}; added/removed windows."
         :inputSchema (drgnx-ui-mcp--schema (append drgnx-ui-mcp--session '(:a (:type "object") :b (:type "object")))))
   (list :name "ui_record"
         :description (concat "Record everything that changes between action start and action stop (input you send in between, timers, redisplays); stop returns the report with its trace. "
                              drgnx-ui-mcp--report)
         :inputSchema (drgnx-ui-mcp--schema (append drgnx-ui-mcp--session '(:action (:type "string" :enum ["start" "stop"])))
                                            '("session" "action")))
   (list :name "ui_measure"
         :description (concat "Run several actions as one measurement. Each action is one of {keys}, {type}, {x,y} or {buffer,text}, with optional button/count/hold_ms. "
                              drgnx-ui-mcp--report)
         :inputSchema (drgnx-ui-mcp--schema (append drgnx-ui-mcp--session
                                                    '(:actions (:type "array" :items (:type "object"))))
                                            '("session" "actions")))
   (list :name "ui_perf"
         :description "Run a perf workload in the session (typing, scrolling, tabs, explorer, agent-typing, frames, redisplay, memory): input latency p50/p95/max, GC, redisplay or frame times — the numbers `drgnx test --perf' judges (docs/develop/perf.md)."
         :inputSchema (drgnx-ui-mcp--schema (append drgnx-ui-mcp--session '(:workload (:type "string") :audit (:type "boolean")))
                                            '("session" "workload")))))

;;;; Tool calls

(defun drgnx-ui-mcp--text (value)
  (list :content (vector (list :type "text" :text (drgnx-ui--json value)))))

(defun drgnx-ui-mcp--error (message)
  (list :content (vector (list :type "text" :text message)) :isError t))

(defun drgnx-ui-mcp--own (args)
  (drgnx-ui-own-session (plist-get args :session)))

(defun drgnx-ui-mcp--screenshot (args)
  (let* ((r (drgnx-ui-screenshot (drgnx-ui-mcp--own args) (plist-get args :path)))
         (data (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert-file-contents-literally (plist-get r :path))
                 (base64-encode-region (point-min) (point-max) t)
                 (buffer-string))))
    (list :content (vector (list :type "image" :data data :mimeType "image/png")
                           (list :type "text" :text (drgnx-ui--json r))))))

(defvar drgnx-ui-mcp--states (make-hash-table :test #'equal) "Session → the last state a tool saw.")

(defun drgnx-ui-mcp--remember (args state)
  (puthash (plist-get args :session) state drgnx-ui-mcp--states)
  state)

(defun drgnx-ui-mcp--diff (args)
  "ui_diff: A against B, or the session's previous state against its state now."
  (drgnx-ui-mcp--text
   (if (and (plist-get args :a) (plist-get args :b))
       (list :changes (vconcat (drgnx-ui-state-diff (plist-get args :a) (plist-get args :b))))
     (let* ((before (gethash (plist-get args :session) drgnx-ui-mcp--states))
            (now (drgnx-ui-mcp--remember args (drgnx-ui-state (drgnx-ui-mcp--own args)))))
       (list :changes (vconcat (and before (drgnx-ui-state-diff before now))) :baseline (if before t :false))))))

(defun drgnx-ui-mcp--click-action (args)
  (cl-loop for k in '(:x :y :buffer :text :button :count :hold_ms)
           when (plist-member args k) append (list k (plist-get args k))))

(defconst drgnx-ui-mcp--calls
  `(("ui_start" . ,(lambda (a) (drgnx-ui-mcp--text (drgnx-ui-start (plist-get a :config) (plist-get a :size) nil
                                                                    (eq (plist-get a :daemon) t) (plist-get a :monitors)))))
    ("ui_frame" . ,(lambda (a) (drgnx-ui-mcp--text (drgnx-ui-new-frame (drgnx-ui-mcp--own a)))))
    ("ui_stop" . ,(lambda (a) (drgnx-ui-mcp--text (drgnx-ui-stop (plist-get a :session)))))
    ("ui_list" . ,(lambda (_) (drgnx-ui-mcp--text (drgnx-ui-ls))))
    ("ui_state" . ,(lambda (a) (drgnx-ui-mcp--text (drgnx-ui-mcp--remember a (drgnx-ui-state (drgnx-ui-mcp--own a))))))
    ("ui_diff" . drgnx-ui-mcp--diff)
    ("ui_record" . ,(lambda (a) (drgnx-ui-mcp--text
                                 (let ((sess (drgnx-ui-mcp--own a)))
                                   (if (equal (plist-get a :action) "start")
                                       (progn (drgnx-ui-call sess "(drgnx-uitest-api-measure-begin)") (list :recording t))
                                     (drgnx-ui-call sess "(drgnx-uitest-api-measure-end)"))))))
    ("ui_screenshot" . drgnx-ui-mcp--screenshot)
    ("ui_click" . ,(lambda (a) (drgnx-ui-mcp--text
                                (drgnx-ui-measure (drgnx-ui-mcp--own a) (list (drgnx-ui-mcp--click-action a))))))
    ("ui_keys" . ,(lambda (a) (drgnx-ui-mcp--text
                               (drgnx-ui-measure (drgnx-ui-mcp--own a) (list (list :keys (plist-get a :keys)))))))
    ("ui_type" . ,(lambda (a) (drgnx-ui-mcp--text
                               (drgnx-ui-measure (drgnx-ui-mcp--own a) (list (list :type (plist-get a :text)))))))
    ("ui_wait" . ,(lambda (a) (drgnx-ui-mcp--text
                               (list :settled (if (drgnx-ui-wait (drgnx-ui-mcp--own a) (plist-get a :quiet_ms)
                                                                 (/ (or (plist-get a :timeout_ms) 10000) 1000.0))
                                                  t :false)))))
    ("ui_measure" . ,(lambda (a) (drgnx-ui-mcp--text
                                  (drgnx-ui-measure (drgnx-ui-mcp--own a) (append (plist-get a :actions) nil)))))
    ("ui_perf" . ,(lambda (a)
                    (require 'drgnx-perf-run)
                    (let ((w (assq (intern (plist-get a :workload)) (drgnx-perf-run--workloads))))
                      (unless w (error "No workload %s" (plist-get a :workload)))
                      (drgnx-ui-mcp--text (drgnx-perf-run-workload (drgnx-ui-mcp--own a) (cdr w)
                                                                   (eq (plist-get a :audit) t))))))))

(defun drgnx-ui-mcp-call (name args)
  "Run tool NAME with ARGS (a plist); every failure becomes an isError result."
  (let ((fn (alist-get name drgnx-ui-mcp--calls nil nil #'equal)))
    (if (not fn)
        (drgnx-ui-mcp--error (format "unknown tool %s" name))
      (condition-case err
          (funcall fn args)
        (error (drgnx-ui-mcp--error (format "error: %s" (error-message-string err))))))))

;;;; Protocol

(defun drgnx-ui-mcp--result (method params)
  (pcase method
    ("initialize" (list :protocolVersion (or (plist-get params :protocolVersion) drgnx-ui-mcp-protocol)
                        :capabilities (list :tools (make-hash-table))
                        :serverInfo (list :name "drgnx-ui" :version "0.1.0")))
    ("ping" (make-hash-table))
    ("tools/list" (list :tools (vconcat drgnx-ui-mcp-tools)))
    ("tools/call" (drgnx-ui-mcp-call (plist-get params :name) (plist-get params :arguments)))
    (_ 'unknown)))

(defun drgnx-ui-mcp-handle (msg)
  "The JSON-RPC reply (a plist) to MSG, or nil for a notification."
  (let ((id (plist-get msg :id)))
    (unless (memq id '(nil :null))
      (let ((result (condition-case err
                        (drgnx-ui-mcp--result (plist-get msg :method) (plist-get msg :params))
                      (error (list 'failed (error-message-string err))))))
        (pcase result
          ('unknown (list :jsonrpc "2.0" :id id
                          :error (list :code -32601
                                       :message (format "method not found: %s" (plist-get msg :method)))))
          (`(failed ,why) (list :jsonrpc "2.0" :id id :error (list :code -32603 :message why)))
          (_ (list :jsonrpc "2.0" :id id :result result)))))))

(defun drgnx-ui-mcp-main ()
  "Serve MCP over stdin/stdout until EOF, then exit."
  (drgnx-ui-batch-setup)
  (condition-case nil
      (while t
        (let ((line (read-from-minibuffer "")))
          (unless (string-blank-p line)
            (let* ((msg (ignore-errors (drgnx-ui--parse-json line)))
                   (reply (if msg
                              (drgnx-ui-mcp-handle msg)
                            (list :jsonrpc "2.0" :id :null :error (list :code -32700 :message "parse error")))))
              (when reply
                (princ (drgnx-ui--json reply))
                (terpri))))))
    (end-of-file nil))
  (kill-emacs 0))

;;;; A minimal client (tests, scripts)

(defun drgnx-ui-mcp-client-start ()
  "Start `drgnx ui mcp' as a subprocess; return the client process."
  (let ((proc (make-process
               :name "drgnx-ui-mcp-client" :buffer (generate-new-buffer " *drgnx-ui-mcp*")
               :command (list (expand-file-name "bin/drgnx" drgnx-ui-repo-dir) "ui" "mcp")
               :connection-type 'pipe :coding 'utf-8-unix :noquery t :sentinel #'ignore
               :stderr (generate-new-buffer " *drgnx-ui-mcp-stderr*"))))
    (process-put proc 'next-id 0)
    proc))

(defun drgnx-ui-mcp-client-request (proc method &optional params timeout)
  "Send METHOD with PARAMS to PROC and return the reply's result (signals on a JSON-RPC error)."
  (let ((id (process-put proc 'next-id (1+ (process-get proc 'next-id))))
        (deadline (+ (float-time) (or timeout 120)))
        reply)
    (setq id (process-get proc 'next-id))
    (process-send-string proc (concat (drgnx-ui--json (list :jsonrpc "2.0" :id id :method method
                                                            :params (or params (make-hash-table))))
                                      "\n"))
    (with-current-buffer (process-buffer proc)
      (while (not reply)
        (goto-char (point-min))
        (if (search-forward "\n" nil t)
            (let ((line (buffer-substring (point-min) (1- (point)))))
              (delete-region (point-min) (point))
              (setq reply (drgnx-ui--parse-json line)))
          (when (or (> (float-time) deadline) (not (process-live-p proc)))
            (error "drgnx-ui-mcp: no reply to %s" method))
          (accept-process-output proc 0.05))))
    (when (plist-get reply :error)
      (error "drgnx-ui-mcp: %s" (plist-get (plist-get reply :error) :message)))
    (plist-get reply :result)))

(defun drgnx-ui-mcp-client-tool (proc name &rest args)
  "Call tool NAME with ARGS (a plist) through PROC; return the content vector, signal on isError."
  (let ((r (drgnx-ui-mcp-client-request proc "tools/call"
                                        (list :name name :arguments (or args (make-hash-table))))))
    (when (eq (plist-get r :isError) t)
      (error "%s: %s" name (plist-get (aref (plist-get r :content) 0) :text)))
    (plist-get r :content)))

(defun drgnx-ui-mcp-client-stop (proc)
  (when (process-live-p proc) (process-send-eof proc))
  (let ((deadline (+ (float-time) 5)))
    (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output proc 0.05)))
  (when (process-live-p proc) (delete-process proc))
  (kill-buffer (process-buffer proc)))

(provide 'drgnx-ui-mcp)
;;; drgnx-ui-mcp.el ends here
