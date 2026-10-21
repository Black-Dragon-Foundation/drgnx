;;; drgnx-sandbox-relay.el --- Loopback ports inside the sandbox, forwarded to the session's sockets -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; With an isolated network (phase 2) the sandbox has only its own loopback.  The agent is told to use
;; `http://127.0.0.1:3128' as its proxy and, for gateway profiles, `http://127.0.0.1:3129' as its API; this relay
;; listens on those ports inside and forwards every connection, as bytes, to a Unix socket the hub bound in (the
;; per-job proxy's and the gateway's, under `/run/drgnx').  It reads nothing it forwards: the boundary is the proxy
;; and the gateway outside (docs/develop/sandbox.md, "Network: phase 2").
;;
;; `drgnx-sandbox-relay-entry' wraps the agent's command: a shell starts the relay in the background, waits for its
;; `ready' line, and then `exec's the agent, so the agent's stdin and stdout stay the sandbox's own and its first
;; connect finds the ports listening.  The relay ends when the agent does: it checks its parent (the agent, after the
;; `exec') once a second.

;;; Code:
(require 'drgnx-guard)

(defvar drgnx-dir)

(defun drgnx-sandbox-relay--die (status text)
  "End the relay with STATUS, TEXT on stderr."
  (message "drgnx-sandbox-relay: %s" text)
  (kill-emacs status))

(defun drgnx-sandbox-relay--parse (args)
  "ARGS (strings `PORT=SOCKET') as a list of (PORT . SOCKET), or an `error' naming the bad one."
  (unless args (error "usage: drgnx-sandbox-relay-main PORT=SOCKET…"))
  (mapcar (lambda (arg)
            (let ((port (and (string-match "\\`\\([0-9]+\\)=\\(.+\\)\\'" arg) (string-to-number (match-string 1 arg)))))
              (unless (and port (<= 1 port 65535)) (error "not PORT=SOCKET: %s" arg))
              (cons port (match-string 2 arg))))
          args))

(defun drgnx-sandbox-relay--to-peer (proc chunk)
  "Send CHUNK, read from PROC, to PROC's peer; with no live peer, close PROC."
  (let ((peer (process-get proc :peer)))
    (unless (and (process-live-p peer) (condition-case nil (progn (process-send-string peer chunk) t) (error nil)))
      (delete-process proc))))

(defun drgnx-sandbox-relay--closed (proc _event)
  "Once PROC has closed, close its peer: an end on either side ends the pair."
  (unless (process-live-p proc)
    (let ((peer (process-get proc :peer)))
      (when (process-live-p peer) (delete-process peer)))))

(defun drgnx-sandbox-relay--accept (server client _message)
  "A connection CLIENT came on SERVER: connect it to SERVER's socket, or close it when that cannot be reached."
  (let* ((socket (process-get server :socket))
         (up (condition-case err
                 (make-network-process :name "drgnx-relay-up" :family 'local :service socket :noquery t :coding 'binary
                                       :filter (drgnx-guard-wrap #'drgnx-sandbox-relay--to-peer "sandbox relay")
                                       :sentinel (drgnx-guard-wrap #'drgnx-sandbox-relay--closed "sandbox relay"))
               (error (message "drgnx-sandbox-relay: cannot reach %s: %s" socket (error-message-string err)) nil))))
    (if (not up) (delete-process client)
      (process-put up :peer client)
      (process-put client :peer up))))

(defun drgnx-sandbox-relay--parent ()
  "This Emacs's parent's pid, or nil where it cannot be read."
  (alist-get 'ppid (process-attributes (emacs-pid))))

(defun drgnx-sandbox-relay-main ()
  "Batch entry: listen on 127.0.0.1:PORT for each argument `PORT=SOCKET' and forward each connection to SOCKET.
Writes `ready' to stdout once every port listens, and ends (status 0) when its parent, the agent, has ended.  Exits
1 with a line on stderr for a bad argument or a port it cannot listen on."
  (setq gc-cons-percentage 0.1)
  (let ((args command-line-args-left) pairs)
    (setq command-line-args-left nil)
    (setq pairs (condition-case err (drgnx-sandbox-relay--parse args)
                  (error (drgnx-sandbox-relay--die 1 (error-message-string err)))))
    (dolist (pair pairs)
      (condition-case err
          (process-put (make-network-process :name "drgnx-relay" :server t :host "127.0.0.1" :service (car pair)
                                             :family 'ipv4 :noquery t :coding 'binary
                                             :log #'drgnx-sandbox-relay--accept
                                             :filter (drgnx-guard-wrap #'drgnx-sandbox-relay--to-peer "sandbox relay")
                                             :sentinel (drgnx-guard-wrap #'drgnx-sandbox-relay--closed "sandbox relay"))
                       :socket (cdr pair))
        (error (drgnx-sandbox-relay--die 1 (format "cannot listen on 127.0.0.1:%d: %s"
                                                   (car pair) (error-message-string err))))))
    (let ((parent (drgnx-sandbox-relay--parent)) (next (1+ (float-time))))
      ;; not `princ': in batch it leaves a FIFO's or a pipe's stdout unflushed; this writes and flushes
      (send-string-to-terminal "ready\n")
      (while t
        (accept-process-output nil 1)
        (when (>= (float-time) next)
          (unless (eql (drgnx-sandbox-relay--parent) parent) (kill-emacs 0))
          (setq next (1+ (float-time))))))))

(defun drgnx-sandbox-relay-command (pairs)
  "The argv that runs the relay for PAIRS, a list of (PORT . SOCKET), SOCKET as the agent sees it."
  (require 'drgnx-paths)
  (append (list (expand-file-name invocation-name invocation-directory)
                "--batch" "-Q" "--eval" "(setq load-prefer-newer t)" "-L" (expand-file-name "core" drgnx-dir)
                "-l" "drgnx-sandbox-relay" "-f" "drgnx-sandbox-relay-main")
          (mapcar (lambda (pair) (format "%d=%s" (car pair) (cdr pair))) pairs)))

(defun drgnx-sandbox-relay-entry (relay-pairs command)
  "The argv the sandbox runs: the relay for RELAY-PAIRS (a list of (PORT . SOCKET)), then, once it is ready, COMMAND.
A shell starts the relay in the background with its stdout on a FIFO in a fresh directory under `$TMPDIR' (or
/tmp), reads its `ready' line, removes the directory and `exec's COMMAND: the agent keeps the shell's stdio, and the
relay's stdin is /dev/null.  A relay that does not get ready ends the shell with status 1 before COMMAND runs."
  (append (list "/bin/sh" "-c"
                (concat "d=$(mktemp -d \"${TMPDIR:-/tmp}/drgnx-relay.XXXXXX\") || exit 1\n"
                        "mkfifo \"$d/ready\" || { rm -rf \"$d\"; exit 1; }\n"
                        (mapconcat #'shell-quote-argument (drgnx-sandbox-relay-command relay-pairs) " ")
                        " </dev/null >\"$d/ready\" &\n"
                        "read -r r <\"$d/ready\"\n"
                        "rm -rf \"$d\"\n"
                        "[ \"$r\" = ready ] || { echo 'drgnx-sandbox-relay: the relay did not start' >&2; exit 1; }\n"
                        "exec \"$@\"")
                "drgnx-sandbox-relay")
          command))

(provide 'drgnx-sandbox-relay)
;;; drgnx-sandbox-relay.el ends here
