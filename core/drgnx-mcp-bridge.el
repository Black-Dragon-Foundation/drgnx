;;; drgnx-mcp-bridge.el --- An agent's stdio MCP server, copied to a Unix socket (inside the sandbox) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A sandboxed agent starts this as its `drgnx' MCP server: `emacs --batch -Q -L CORE -l drgnx-mcp-bridge -f
;; drgnx-mcp-bridge-main SOCKET'.  It connects to SOCKET (the session's own, bound into the sandbox by the hub) and
;; copies stdin to it and it to stdout, one JSON-RPC message per line.  It opens nothing else: no file, no process,
;; no other socket.  The real server runs outside the sandbox (docs/develop/sandbox.md, "MCP through a socket").
;;
;; A batch Emacs cannot wait on stdin and a socket at once (`read-from-minibuffer' blocks in getchar, and no process
;; output is read meanwhile).  So the bridge runs in step: after it forwards a request (a message with an `id' and a
;; `method') it reads the socket until that id's answer has come back, and only then reads stdin again.  That is all
;; the parsing it does: each line must be one JSON object no larger than `drgnx-mcp-bridge-max-line', or the bridge
;; ends (status 1) without forwarding it.  A batch (a top-level array) is malformed: MCP 2025-06-18 has none.
;;
;; The bridge is not a security boundary: anything in the sandbox can reach the socket itself.  The hub side owns
;; size limits, frame checks and recovery from a wedged server.  A server request made during a call deadlocks (see
;; the docs); drgnx's servers make none.

;;; Code:
(require 'subr-x)

(defvar drgnx-mcp-bridge-max-line (* 16 1024 1024)
  "The largest message, in bytes, either way: a longer one ends the bridge.")

(declare-function drgnx-command-ignoring-sigpipe "drgnx-paths" (command))
(defvar drgnx-dir)

(defun drgnx-mcp-bridge-command (socket)
  "The argv that runs the bridge to SOCKET (a path as the agent sees it), with SIGPIPE ignored."
  (require 'drgnx-paths)
  (drgnx-command-ignoring-sigpipe
   (list (expand-file-name invocation-name invocation-directory)
         "--batch" "-Q" "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir)
         "-l" "drgnx-mcp-bridge" "-f" "drgnx-mcp-bridge-main" socket)))

(defun drgnx-mcp-bridge--die (status text)
  "End the bridge with STATUS, TEXT (if any) on stderr."
  (when text (message "drgnx-mcp-bridge: %s" text))
  (kill-emacs status))

(defun drgnx-mcp-bridge--state ()
  "A fresh line splitter's state: (PIECES . BYTES), the unfinished line's pieces (newest first) and their size."
  (cons nil 0))

(defun drgnx-mcp-bridge--feed (state chunk emit)
  "Split CHUNK into lines, continuing STATE's unfinished one: call EMIT with each whole line (no newline).
Each piece is kept once and joined once, at its newline: the work is linear in the input, whatever its chunking.
Signals `error' once the unfinished line passes `drgnx-mcp-bridge-max-line' bytes."
  (let ((start 0) nl)
    (while (setq nl (string-search "\n" chunk start))
      (let ((line (if (car state) (apply #'concat (nreverse (cons (substring chunk start nl) (car state))))
                    (substring chunk start nl))))
        (setcar state nil)
        (setcdr state 0)
        (funcall emit line))
      (setq start (1+ nl)))
    (when (< start (length chunk))
      (let ((piece (substring chunk start)))
        (setcar state (cons piece (car state)))
        (setcdr state (+ (cdr state) (string-bytes piece)))
        (when (> (cdr state) drgnx-mcp-bridge-max-line) (error "message too large"))))))

(defun drgnx-mcp-bridge--message (line)
  "LINE as a JSON object (a hash table), or an `error'.  Too large or not an object are errors."
  (when (> (string-bytes line) drgnx-mcp-bridge-max-line) (error "message too large"))
  (let ((msg (condition-case nil (json-parse-string line :null-object nil :false-object nil) (error nil))))
    (unless (hash-table-p msg) (error "malformed message"))
    msg))

(defvar drgnx-mcp-bridge--waiting nil "The ids of the requests sent whose answers have not come back.")

(defun drgnx-mcp-bridge--from-server (line)
  "Check LINE from the server and write it to stdout; an answer ends the wait for its id."
  (let ((msg (drgnx-mcp-bridge--message line)))
    (unless (gethash "method" msg) (setq drgnx-mcp-bridge--waiting (delete (gethash "id" msg) drgnx-mcp-bridge--waiting)))
    (princ line)
    (terpri)))

(defun drgnx-mcp-bridge--filter (proc chunk)
  "Split CHUNK from the server (PROC) into lines and write each to stdout.
A line too large or not a JSON object ends the bridge with status 1, unwritten."
  (condition-case err
      (drgnx-mcp-bridge--feed (process-get proc :lines) chunk #'drgnx-mcp-bridge--from-server)
    (error (drgnx-mcp-bridge--die 1 (format "from the server: %s" (error-message-string err))))))

(defun drgnx-mcp-bridge--sentinel (proc _event)
  "End the bridge with status 0 once the server (PROC) has closed; an unfinished line from it is dropped."
  (unless (process-live-p proc) (drgnx-mcp-bridge--die 0 nil)))

(defun drgnx-mcp-bridge-main ()
  "Batch entry: copy stdin to the socket named by the first argument, and the socket to stdout, until either ends.
Exits 0 when either side closes, 1 with a line on stderr when the socket cannot be reached or a message is too large
or not a JSON object."
  (set-language-environment "UTF-8")
  (setq locale-coding-system 'utf-8-unix)
  (let ((socket (car command-line-args-left)) proc)
    (setq command-line-args-left nil)
    (unless socket (drgnx-mcp-bridge--die 1 "usage: drgnx-mcp-bridge-main SOCKET"))
    (setq proc (condition-case err
                   (make-network-process :name "drgnx-mcp-bridge" :family 'local :service socket :noquery t
                                         :coding 'utf-8-unix :filter #'drgnx-mcp-bridge--filter
                                         :sentinel #'drgnx-mcp-bridge--sentinel)
                 (error (drgnx-mcp-bridge--die 1 (format "cannot connect to %s: %s" socket (error-message-string err))))))
    (process-put proc :lines (drgnx-mcp-bridge--state))
    (condition-case nil
        (while t
          ;; a close that came while idle ends the bridge here, before it reads another line
          (accept-process-output proc 0)
          (let ((line (read-from-minibuffer "")))
            (unless (string-blank-p line)
              (let ((msg (condition-case err (drgnx-mcp-bridge--message line)
                           (error (drgnx-mcp-bridge--die 1 (format "from the agent: %s" (error-message-string err))))))
                    (id nil))
                (when (and (setq id (gethash "id" msg)) (gethash "method" msg)) (push id drgnx-mcp-bridge--waiting))
                (condition-case nil (process-send-string proc (concat line "\n"))
                  (error (drgnx-mcp-bridge--die 0 nil)))
                (while drgnx-mcp-bridge--waiting
                  (unless (process-live-p proc) (drgnx-mcp-bridge--die 0 nil))
                  (accept-process-output proc 1))))))
      (end-of-file nil))
    (drgnx-mcp-bridge--die 0 nil)))

(provide 'drgnx-mcp-bridge)
;;; drgnx-mcp-bridge.el ends here
