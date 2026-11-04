;;; lsp-replay.el --- a language server that replays a recording: batch Nidhogg, stdio, no network -*- lexical-binding: t -*-
;; emacs --batch -Q -l lsp-replay.el                               (Linux)
;; sh mock-acp-stdin.sh emacs --batch -Q -l lsp-replay.el          (any POSIX system: macOS too)
;; Reads LSP messages (Content-Length framing) from stdin and answers each request from the recorded exchange
;; ($LSP_REPLAY_EXCHANGE, default day/lsp-exchange.eld next to this file): the RESULT recorded for its METHOD, null for
;; any other.  Notifications are not answered; "exit" or the end of stdin ends it.  Used by the synthetic day
;; (`drgnx-perf-day'), so eglot has a server in a container that has none.  Batch Emacs cannot read its stdin while
;; timers run, so a `cat' reads it, as in mock-acp.el: of the FIFO in MOCK_ACP_IN (made by mock-acp-stdin.sh, which
;; copies stdin into it), else of /proc/PID/fd/0, which only Linux has.

;;; Code:
(defvar lsp-replay--exchange
  (let ((file (or (getenv "LSP_REPLAY_EXCHANGE")
                  (expand-file-name "day/lsp-exchange.eld" (file-name-directory (or load-file-name buffer-file-name))))))
    (with-temp-buffer (insert-file-contents file) (read (current-buffer))))
  "The recording: ((METHOD . RESULT-JSON)…).")

(defvar lsp-replay--pending "" "Input read but not yet a whole message.")

(defun lsp-replay--send (json)
  "JSON (text) to stdout, framed."
  (send-string-to-terminal (format "Content-Length: %d\r\n\r\n%s" (string-bytes json) json)))

(defun lsp-replay--answer (body)
  "Answer the message BODY if it is a request; end on \"exit\"."
  (let ((method (and (string-match "\"method\" *: *\"\\([^\"]+\\)\"" body) (match-string 1 body)))
        (id (and (string-match "\"id\" *: *\\([0-9]+\\|\"[^\"]*\"\\)" body) (match-string 1 body))))
    (cond ((equal method "exit") (kill-emacs 0))
          ((and id method)
           (lsp-replay--send (format "{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}" id
                                     (or (cdr (assoc method lsp-replay--exchange)) "null")))))))

(defun lsp-replay--input (s)
  "Add the input S to what is pending and answer every whole message in it."
  (setq lsp-replay--pending (concat lsp-replay--pending s))
  (while (and (string-match "\\`Content-Length: *\\([0-9]+\\)\r?\n\\(?:[A-Za-z-]+:[^\n]*\n\\)*\r?\n" lsp-replay--pending)
              (<= (+ (match-end 0) (string-to-number (match-string 1 lsp-replay--pending)))
                  (length lsp-replay--pending)))
    (let* ((start (match-end 0)) (end (+ start (string-to-number (match-string 1 lsp-replay--pending)))))
      (let ((body (substring lsp-replay--pending start end)))
        (setq lsp-replay--pending (substring lsp-replay--pending end))
        (lsp-replay--answer body)))))

(make-process :name "lsp-replay-in" :command (list "cat" (or (getenv "MOCK_ACP_IN") (format "/proc/%d/fd/0" (emacs-pid))))
              :connection-type 'pipe :noquery t :coding 'utf-8-unix
              :filter (lambda (_p s) (lsp-replay--input s))
              :sentinel (lambda (_p _e) (kill-emacs 0)))
(while t (accept-process-output nil 0.05))
