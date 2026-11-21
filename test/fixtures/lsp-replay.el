;;; lsp-replay.el --- a language server that replays a recording: batch Nidhogg, stdio, no network -*- lexical-binding: t -*-
;; emacs --batch -Q -l lsp-replay.el                               (Linux)
;; sh mock-acp-stdin.sh emacs --batch -Q -l lsp-replay.el          (any POSIX system: macOS too)
;; Reads LSP messages (Content-Length framing) from stdin and answers each request from the recorded exchange
;; ($LSP_REPLAY_EXCHANGE, default day/lsp-exchange.eld next to this file): the RESULT recorded for its METHOD, null for
;; any other.  Notifications are not answered; "exit" or the end of stdin ends it.  Used by the synthetic day
;; (`drgnx-perf-day'), so eglot has a server in a container that has none.  Batch Emacs cannot read its stdin
;; while timers run, so a `cat' reads it, as in mock-acp.el: of the FIFO in MOCK_ACP_IN (made by mock-acp-stdin.sh,
;; which copies stdin into it), else of /proc/PID/fd/0, which only Linux has.
;;
;; With $LSP_REPLAY_CORPUS (a corpus recorded from a real server by workers/capture-lsp.sh: a plist :init, :notify,
;; :replies, see capture-lsp.el) it serves the recording instead:
;;  - "initialize" gets the recorded result, and every other request the recorded result of its method;
;;  - after "initialized" it sends the server's own recorded messages (notifications and requests), once, in order, or,
;;    with $LSP_REPLAY_FLOOD=N, cycles through them at N a second until the client exits (a diagnostics flood);
;;  - $LSP_REPLAY_COMPLETION_SIZES (comma separated bytes, e.g. 500000,1000000,3000000) makes the answers to
;;    textDocument/completion that many bytes, in turn: the recorded items are repeated to size, so a 3 MB answer has the
;;    shape of the real server's items;
;;  - $LSP_REPLAY_STAMP=1 follows every answer with a notification "$/replaySent" {"id": ID, "t": SECONDS}: the time
;;    (`float-time') its last byte was written, which lsp-burst measures its handlers from (the client cannot see it
;;    when the reader thread frames the messages).
;; $LSP_REPLAY_LIBRARY loads the functions only (the tests use them).

;;; Code:
(require 'json)
(require 'seq)
(require 'subr-x)

(defun lsp-replay-corpus-read (file)
  "The corpus in FILE (an .eld, or .eld.gz which Emacs reads through its auto compression)."
  (with-temp-buffer
    (insert-file-contents file)
    (read (current-buffer))))

(defun lsp-replay-corpus-payloads (corpus)
  "The payload texts a full replay of CORPUS sends: the initialize result, the server's messages, every other result."
  (append (list (plist-get corpus :init)) (plist-get corpus :notify)
          (mapcar (lambda (r) (if (member (cdr r) '(nil "")) "null" (cdr r))) (plist-get corpus :replies))))

(defun lsp-replay-corpus-totals (corpus)
  "(:messages N :bytes B) of the payloads of CORPUS (what the manifest records and a replay must reproduce)."
  (let ((ps (lsp-replay-corpus-payloads corpus)))
    (list :messages (length ps) :bytes (apply #'+ (mapcar #'string-bytes ps)))))

(defvar lsp-replay--corpus
  (when-let* ((f (getenv "LSP_REPLAY_CORPUS"))) (lsp-replay-corpus-read f))
  "The recording ($LSP_REPLAY_CORPUS), or nil.")

(defvar lsp-replay--exchange
  (if lsp-replay--corpus
      (cons (cons "initialize" (plist-get lsp-replay--corpus :init)) (plist-get lsp-replay--corpus :replies))
    (let ((file (or (getenv "LSP_REPLAY_EXCHANGE")
                    (expand-file-name "day/lsp-exchange.eld" (file-name-directory (or load-file-name buffer-file-name))))))
      (with-temp-buffer (insert-file-contents file) (read (current-buffer)))))
  "The recording: ((METHOD . RESULT-JSON)…).")

(defvar lsp-replay--pending "" "Input read but not yet a whole message.")

(defvar lsp-replay--sizes
  (mapcar #'string-to-number (split-string (or (getenv "LSP_REPLAY_COMPLETION_SIZES") "") "," t))
  "The sizes of the answers to completion requests, in turn (nil: the recorded answer).")

(defvar lsp-replay--size-next nil "The sizes still to use in this round.")

(defun lsp-replay--sized-completion (size)
  "A completion result of about SIZE bytes made of the recorded items repeated."
  (let* ((recorded (cdr (assoc "textDocument/completion" lsp-replay--exchange)))
         (parsed (and recorded (ignore-errors (json-parse-string recorded :object-type 'plist :null-object :null :false-object :false))))
         (items (cond ((vectorp parsed) (append parsed nil)) ((listp parsed) (append (plist-get parsed :items) nil))))
         ;; json-serialize gives UTF-8 bytes (unibyte): decode them, or joining them with the text makes mojibake
         (texts (mapcar (lambda (i) (decode-coding-string (json-serialize i :null-object :null :false-object :false) 'utf-8)) items)))
    (unless texts (setq texts (list "{\"label\":\"item\",\"kind\":6}")))
    (let ((parts nil) (n 0) (bytes 40) (cycle texts))
      (while (< bytes size)
        (let ((text (car cycle)))
          (push text parts) (setq bytes (+ bytes (string-bytes text) 1) n (1+ n)
                                  cycle (or (cdr cycle) texts))))
      (concat "{\"isIncomplete\":false,\"items\":[" (mapconcat #'identity (nreverse parts) ",") "]}"))))

(defun lsp-replay--result (method)
  "The result text served for METHOD."
  (if (and lsp-replay--sizes (equal method "textDocument/completion"))
      (progn (unless lsp-replay--size-next (setq lsp-replay--size-next lsp-replay--sizes))
             (lsp-replay--sized-completion (pop lsp-replay--size-next)))
    (let ((r (cdr (assoc method lsp-replay--exchange)))) ; a recorded result that came back empty is null
      (if (member r '(nil "")) "null" r))))

(defun lsp-replay--send (json)
  "JSON (text) to stdout, framed."
  (send-string-to-terminal (format "Content-Length: %d\r\n\r\n%s" (string-bytes json) json)))

(defvar lsp-replay--flood nil "The flood's cycle: the recorded server messages still to send in this round.")

(defun lsp-replay--flood-tick ()
  (unless lsp-replay--flood (setq lsp-replay--flood (plist-get lsp-replay--corpus :notify)))
  (when lsp-replay--flood (lsp-replay--send (pop lsp-replay--flood))))

(defun lsp-replay--initialized ()
  "After `initialized': the recorded server messages, once, or as a flood."
  (when lsp-replay--corpus
    (let ((rate (string-to-number (or (getenv "LSP_REPLAY_FLOOD") ""))))
      (if (> rate 0)
          (run-with-timer 0 (/ 1.0 rate) #'lsp-replay--flood-tick)
        (mapc #'lsp-replay--send (plist-get lsp-replay--corpus :notify))))))

(defun lsp-replay--answer (body)
  "Answer the message BODY if it is a request; end on \"exit\"."
  (let ((method (and (string-match "\"method\" *: *\"\\([^\"]+\\)\"" body) (match-string 1 body)))
        (id (and (string-match "\"id\" *: *\\([0-9]+\\|\"[^\"]*\"\\)" body) (match-string 1 body))))
    (cond ((equal method "exit") (kill-emacs 0))
          ((equal method "initialized") (lsp-replay--initialized))
          ((and id method)
           (lsp-replay--send (format "{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}" id (lsp-replay--result method)))
           ;; written and flushed: the answer's last byte is in the pipe now
           (when (equal (getenv "LSP_REPLAY_STAMP") "1")
             (lsp-replay--send (format "{\"jsonrpc\":\"2.0\",\"method\":\"$/replaySent\",\"params\":{\"id\":%s,\"t\":%.6f}}"
                                       id (float-time))))))))

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

(unless (getenv "LSP_REPLAY_LIBRARY")
  (make-process :name "lsp-replay-in" :command (list "cat" (or (getenv "MOCK_ACP_IN") (format "/proc/%d/fd/0" (emacs-pid))))
                :connection-type 'pipe :noquery t :coding 'utf-8-unix
                :filter (lambda (_p s) (lsp-replay--input s))
                :sentinel (lambda (_p _e) (kill-emacs 0)))
  (while t (accept-process-output nil 0.05)))
;;; lsp-replay.el ends here
