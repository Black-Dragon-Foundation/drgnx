;;; drgnx-acp.el --- A small Agent Client Protocol client: JSON-RPC 2.0, one JSON object per line -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; An ACP agent is a process speaking JSON-RPC 2.0 on its stdin/stdout, one object per line.  This
;; file is the transport: requests with callbacks, notifications both ways, and the agent's own
;; requests to us (permissions, file reads and writes) answered by a handler — immediately, or later
;; with `drgnx-acp-respond'.  Everything runs from process filters and sentinels: nothing here ever
;; waits or asks.  A malformed line is logged and skipped; when the agent exits, pending requests
;; fail and the handler hears the exit status with the end of its stderr.  See docs/guide/agents.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-timer)

(cl-defstruct (drgnx-acp-conn (:constructor drgnx-acp--make) (:copier nil))
  process stderr-process (next-id 0) (pending (make-hash-table :test #'eql)) input-buffer (stderr "")
  on-notification on-request on-exit log exited)

(defconst drgnx-acp--stderr-max 8000 "Characters of the agent's stderr kept.")
(defconst drgnx-acp--log-max 50 "Protocol problems kept (newest first).")

(defun drgnx-acp--note (conn fmt &rest args)
  (let ((l (cons (apply #'format fmt args) (drgnx-acp-conn-log conn))))
    (setf (drgnx-acp-conn-log conn) (seq-take l drgnx-acp--log-max))))

(defun drgnx-acp--send (conn obj)
  (let ((p (drgnx-acp-conn-process conn)))
    (if (process-live-p p)
        (process-send-string p (concat (json-serialize obj) "\n"))
      (drgnx-acp--note conn "not sent (agent gone): %s" (plist-get obj :method)))))

;;;; Input: framing and dispatch

(defun drgnx-acp--input-buffer (conn)
  (let ((b (drgnx-acp-conn-input-buffer conn)))
    (unless (buffer-live-p b)
      (setq b (generate-new-buffer " *drgnx-acp-input*"))
      (with-current-buffer b (set-buffer-multibyte t))
      (setf (drgnx-acp-conn-input-buffer conn) b))
    b))

(defun drgnx-acp--input (conn string)
  "Take STRING from the agent: every complete line is one message; the rest waits for more."
  (let (lines)
    (with-current-buffer (drgnx-acp--input-buffer conn)
      (goto-char (point-max))
      (insert string)
      (goto-char (point-min))
      (while (search-forward "\n" nil t)
        (push (buffer-substring-no-properties (point-min) (1- (point))) lines)
        (delete-region (point-min) (point))))
    (dolist (line (nreverse lines))
      (unless (string-blank-p line)
        (let ((msg (condition-case err
                       (json-parse-string line :object-type 'plist :array-type 'list :null-object nil :false-object :false)
                     (error (drgnx-acp--note conn "malformed line (%s): %s" (error-message-string err)
                                             (truncate-string-to-width line 200))
                            nil))))
          (when msg
            (condition-case err (drgnx-acp--dispatch conn msg)
              (error (drgnx-acp--note conn "handler error: %s" (error-message-string err))))))))))

(defun drgnx-acp--dispatch (conn msg)
  (let ((id (plist-get msg :id)) (method (plist-get msg :method)))
    (cond
     ((and id (not method))                               ; a response to us
      (when-let* ((cb (gethash id (drgnx-acp-conn-pending conn))))
        (remhash id (drgnx-acp-conn-pending conn))
        (funcall cb (cons (plist-get msg :result) (plist-get msg :error)))))
     ((and id method)                                     ; the agent asks us
      (let ((answer (if-let* ((h (drgnx-acp-conn-on-request conn)))
                        (condition-case err (funcall h conn method (plist-get msg :params) id)
                          (error (list :error (list :code -32603 :message (error-message-string err)))))
                      (list :error (list :code -32601 :message (format "%s is not supported" method))))))
        (unless (eq answer :deferred)
          (drgnx-acp-respond conn id (plist-get answer :result) (plist-get answer :error)))))
     (method
      (when-let* ((h (drgnx-acp-conn-on-notification conn))) (funcall h conn method (plist-get msg :params)))))))

;;;; API

(cl-defun drgnx-acp-start (command &key env cwd on-notification on-request on-exit)
  "Start the agent COMMAND (a list) in CWD with ENV (\"NAME=value\" strings added to the environment).
ON-NOTIFICATION: (CONN METHOD PARAMS); ON-REQUEST: (CONN METHOD PARAMS ID) → (:result R), (:error E) or
`:deferred' (answer later with `drgnx-acp-respond'); ON-EXIT: (CONN STATUS STDERR-TAIL).  Returns the connection."
  (let* ((command (if (string-prefix-p "~/" (car command))   ; agents.eld writes paths under home "~/…" (it travels)
                      (cons (expand-file-name (car command)) (cdr command))
                    command))
         (conn (drgnx-acp--make :on-notification on-notification :on-request on-request :on-exit on-exit))
         (default-directory (file-name-as-directory (expand-file-name (or cwd default-directory))))
         (process-environment (append env process-environment))
         (stderr (make-pipe-process :name "drgnx-acp-stderr" :noquery t :coding 'utf-8
                                    :filter (lambda (_p s)
                                              (let ((all (concat (drgnx-acp-conn-stderr conn) s)))
                                                (setf (drgnx-acp-conn-stderr conn)
                                                      (substring all (max 0 (- (length all) drgnx-acp--stderr-max))))))
                                    :sentinel #'ignore))
         (proc (condition-case err
                   (make-process :name "drgnx-acp" :connection-type 'pipe :noquery t
                                 ;; SIGPIPE ignored, as the hub runs; a program that is not there is reported by make-process
                                 :command (if-let* ((program (executable-find (car command))))
                                              (drgnx-command-ignoring-sigpipe (cons program (cdr command)))
                                            command)
                                 :coding 'utf-8-unix :stderr stderr
                                 :filter (lambda (_p s) (drgnx-acp--input conn s))
                                 :sentinel (lambda (p _event)
                                             (unless (process-live-p p) (drgnx-acp--exited conn p))))
                 (error (delete-process stderr) (signal (car err) (cdr err))))))
    (setf (drgnx-acp-conn-process conn) proc (drgnx-acp-conn-stderr-process conn) stderr)
    ;; A sentinel can go uncalled (seen in the unit suite after the Explorer's tests): a watchdog
    ;; reports a dead agent within half a second anyway.  One per process; a failing one stops after 3.
    (drgnx-timer-start (cons 'acp-watchdog proc) 0.5 #'drgnx-acp--watchdog :repeat 0.5
                       :args (list conn proc) :owner :core)
    conn))

(defun drgnx-acp--watchdog (conn proc)
  "The agent PROC died without its sentinel being called: report it."
  (unless (process-live-p proc) (drgnx-acp--exited conn proc)))

(defun drgnx-acp--exited (conn proc)
  "The agent PROC ended: pending requests fail now; the exit is reported a moment later, once the
last of its stderr has arrived (never waiting here: this runs in a sentinel).  Once only."
  (unless (drgnx-acp-conn-exited conn)
    (setf (drgnx-acp-conn-exited conn) t)
    (drgnx-timer-cancel (cons 'acp-watchdog (drgnx-acp-conn-process conn)))
    (let ((pending (drgnx-acp-conn-pending conn)) cbs)
      (maphash (lambda (_id cb) (push cb cbs)) pending)
      (clrhash pending)
      (dolist (cb cbs)
        (condition-case err (funcall cb (cons nil (list :code -32000 :message "the agent exited")))
          (error (drgnx-acp--note conn "callback error: %s" (error-message-string err))))))
    (drgnx-timer-start (cons 'acp-exit proc) 0.05 #'drgnx-acp--report-exit
                       :args (list conn (process-exit-status proc)) :owner :core)))

(defun drgnx-acp--report-exit (conn status)
  "Tell CONN's on-exit handler the agent ended with STATUS, once the last of its stderr has arrived.
Runs in a timer (not the sentinel) because it waits for the stderr pipe; leaves nothing behind
whatever the handler does."
  (when-let* ((e (drgnx-acp-conn-stderr-process conn)))
    (when (process-live-p e) (with-local-quit (ignore-errors (accept-process-output e 0.1 nil t)))))
  (unwind-protect
      (when-let* ((h (drgnx-acp-conn-on-exit conn))) (funcall h conn status (drgnx-acp-conn-stderr conn)))
    (when-let* ((e (drgnx-acp-conn-stderr-process conn))) (when (process-live-p e) (delete-process e)))
    (when (buffer-live-p (drgnx-acp-conn-input-buffer conn)) (kill-buffer (drgnx-acp-conn-input-buffer conn)))))

(defun drgnx-acp-request (conn method params callback)
  "Send request METHOD with PARAMS; CALLBACK gets (RESULT . ERROR) when the agent answers.  Returns the id."
  (let ((id (cl-incf (drgnx-acp-conn-next-id conn))))
    (puthash id callback (drgnx-acp-conn-pending conn))
    (drgnx-acp--send conn (list :jsonrpc "2.0" :id id :method method :params (or params (make-hash-table))))
    id))

(defun drgnx-acp-notify (conn method params)
  (drgnx-acp--send conn (list :jsonrpc "2.0" :method method :params (or params (make-hash-table)))))

(defun drgnx-acp-respond (conn id result &optional error)
  "Answer the agent's request ID with RESULT (or ERROR, a plist :code :message)."
  (drgnx-acp--send conn (if error (list :jsonrpc "2.0" :id id :error error)
                          (list :jsonrpc "2.0" :id id :result (if (null result) :null result)))))

(defun drgnx-acp-live-p (conn) (process-live-p (drgnx-acp-conn-process conn)))

(defun drgnx-acp-stop (conn)
  "End the connection: the agent process and its stderr pipe."
  (drgnx-timer-cancel (cons 'acp-watchdog (drgnx-acp-conn-process conn)))
  (dolist (p (list (drgnx-acp-conn-process conn) (drgnx-acp-conn-stderr-process conn)))
    (when (process-live-p p) (delete-process p)))
  (when (buffer-live-p (drgnx-acp-conn-input-buffer conn)) (kill-buffer (drgnx-acp-conn-input-buffer conn))))

(provide 'drgnx-acp)
;;; drgnx-acp.el ends here
