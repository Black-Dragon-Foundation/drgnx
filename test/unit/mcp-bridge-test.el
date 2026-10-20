;;; mcp-bridge-test.el --- batch tests: the MCP bridge inside the sandbox -*- lexical-binding: t -*-
;; The bridge runs as a child batch Emacs, as an agent starts it; a fake MCP server listens on a Unix socket in the
;; test's temporary directory, and the test speaks JSON-RPC over the bridge's stdio.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-mcp-bridge)
(require 'drgnx-paths)
(load(expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/measure-fixture" drgnx-dir) nil t)

(defvar drgnx-mcp-bridge-test--got nil "The lines the fake server received, oldest first.")
(defvar drgnx-mcp-bridge-test--conns nil "The connections the fake server accepted.")

(defun drgnx-mcp-bridge-test--echo (conn line)
  "The fake server's default: answer a request with its line as the result."
  (let ((msg (json-parse-string line :null-object nil)))
    (when (and (gethash "id" msg) (gethash "method" msg))
      (process-send-string conn (concat (json-serialize (list :jsonrpc "2.0" :id (gethash "id" msg) :result (list :line line)))
                                        "\n")))))

(defun drgnx-mcp-bridge-test--server (sock handler)
  "A fake MCP server listening on SOCK: HANDLER gets (CONN LINE) for each line it receives."
  (make-network-process
   :name "fake-mcp" :family 'local :server t :service sock :noquery t :coding 'utf-8-unix
   :log (lambda (_server conn _msg) (push conn drgnx-mcp-bridge-test--conns))
   :filter (lambda (conn s)
             (let* ((all (concat (or (process-get conn :pending) "") s)) (start 0) nl)
               (while (setq nl (string-search "\n" all start))
                 (let ((line (substring all start nl)))
                   (setq drgnx-mcp-bridge-test--got (append drgnx-mcp-bridge-test--got (list line)))
                   (funcall handler conn line))
                 (setq start (1+ nl)))
               (process-put conn :pending (substring all start))))))

(defun drgnx-mcp-bridge-test--start (sock &optional eval)
  "The bridge to SOCK, EVAL (a form's text) run before its entry: its process (stdout and stderr in buffers)."
  (let* ((command (drgnx-mcp-bridge-command sock))
         (i (cl-position "-f" command :test #'equal))
         (err (generate-new-buffer " *bridge-err*")))
    (when eval (setq command (append (cl-subseq command 0 i) (list "--eval" eval) (nthcdr i command))))
    (let ((p (make-process :name "mcp-bridge" :noquery t :connection-type 'pipe :coding 'utf-8-unix :command command
                           :buffer (generate-new-buffer " *bridge-out*") :stderr err :sentinel #'ignore)))
      (process-put p :err err)
      p)))

(defun drgnx-mcp-bridge-test--wait (pred &optional secs)
  "Wait until PRED is true: its value (`drgnx-test-wait', at least 30 s or SECS)."
  (drgnx-test-wait pred :secs (max 30 (or secs 0)) :what "the bridge test's predicate"))

(defun drgnx-mcp-bridge-test--out (bridge)
  "The JSON messages BRIDGE wrote to its stdout so far (hash tables), whole lines only."
  (with-current-buffer (process-buffer bridge)
    (goto-char (point-max))
    (mapcar (lambda (l) (json-parse-string l :null-object nil))
            (split-string (buffer-substring (point-min) (if (search-backward "\n" nil t) (point) (point-min))) "\n" t))))

(defun drgnx-mcp-bridge-test--exit (bridge)
  "BRIDGE's exit status once it has ended."
  (and (drgnx-mcp-bridge-test--wait (lambda () (memq (process-status bridge) '(exit signal))))
       (process-exit-status bridge)))

(defun drgnx-mcp-bridge-test--err (bridge)
  "What BRIDGE wrote to its stderr, once it has ended."
  (drgnx-mcp-bridge-test--exit bridge)
  (accept-process-output nil 0.1)
  (with-current-buffer (process-get bridge :err) (buffer-string)))

(defun drgnx-mcp-bridge-test--written (bridge)
  "What BRIDGE wrote to its stdout."
  (with-current-buffer (process-buffer bridge) (buffer-string)))

(defun drgnx-mcp-bridge-test--kill (bridge)
  (delete-process bridge)
  (kill-buffer (process-buffer bridge))
  (kill-buffer (process-get bridge :err)))

(defmacro drgnx-mcp-bridge-test--with (handler &rest body)
  "BODY with `sock' (the fake server's socket, HANDLER per line) and `bridge' (the bridge to it), both ended after."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "mb" t)) (sock (expand-file-name "mcp.sock" dir)) (drgnx-mcp-bridge-test--got nil)
          (drgnx-mcp-bridge-test--conns nil) (server (drgnx-mcp-bridge-test--server sock ,handler)) (bridge nil))
     (unwind-protect (progn ,@body)
       (when (processp bridge) (drgnx-mcp-bridge-test--kill bridge))
       (mapc #'delete-process drgnx-mcp-bridge-test--conns)
       (delete-process server)
       (delete-directory dir t))))

(defun drgnx-mcp-bridge-test--send (bridge &rest msgs)
  "Write MSGS (plists) to BRIDGE's stdin, one line each."
  (dolist (m msgs) (process-send-string bridge (concat (json-serialize m) "\n"))))

(ert-deftest drgnx-mcp-bridge/copies-both-ways ()
  ;; a notification passes without an answer; a request's answer comes back, after the server's own notification
  (drgnx-mcp-bridge-test--with
      (lambda (conn line)
        (when (string-search "\"ping\"" line)
          (process-send-string conn "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}\n"))
        (drgnx-mcp-bridge-test--echo conn line))
    (setq bridge (drgnx-mcp-bridge-test--start sock))
    (drgnx-mcp-bridge-test--send bridge '(:jsonrpc "2.0" :method "notifications/initialized")
                                 '(:jsonrpc "2.0" :id 1 :method "ping"))
    (should (drgnx-mcp-bridge-test--wait (lambda () (= 2 (length (drgnx-mcp-bridge-test--out bridge))))))
    (should (equal drgnx-mcp-bridge-test--got
                   '("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
                     "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}")))
    (let ((out (drgnx-mcp-bridge-test--out bridge)))
      (should (equal (gethash "method" (nth 0 out)) "notifications/message"))
      (should (equal (gethash "id" (nth 1 out)) 1))
      (should (equal (gethash "line" (gethash "result" (nth 1 out))) (nth 1 drgnx-mcp-bridge-test--got))))
    (should (process-live-p bridge))))

(ert-deftest drgnx-mcp-bridge/a-server-request-does-not-end-the-wait ()
  ;; during a call the server asks the client something (an id and a method): it is written at once, and the
  ;; call's answer, sent later, still comes through without another input line.  Its id is the call's own (each side
  ;; numbers its requests): only an answer, which has no method, ends the wait
  (let ((timer nil))
    (drgnx-mcp-bridge-test--with
        (lambda (conn line)
          (process-send-string conn "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"roots/list\"}\n")
          (setq timer (run-at-time 0.3 nil #'drgnx-mcp-bridge-test--echo conn line)))
      (unwind-protect
          (progn
            (setq bridge (drgnx-mcp-bridge-test--start sock))
            (drgnx-mcp-bridge-test--send bridge '(:jsonrpc "2.0" :id 7 :method "tools/call"))
            (should (drgnx-mcp-bridge-test--wait (lambda () (= 2 (length (drgnx-mcp-bridge-test--out bridge))))))
            (let ((out (drgnx-mcp-bridge-test--out bridge)))
              (should (equal (gethash "method" (nth 0 out)) "roots/list"))
              (should (equal (gethash "id" (nth 1 out)) 7))))
        (when timer (cancel-timer timer))))))

(ert-deftest drgnx-mcp-bridge/an-idle-notification-waits-for-the-next-line ()
  ;; the documented limit: what the server sends while no request is pending reaches the agent at the latest with its
  ;; next line, and before that line's answer.  Not that it is held back until then: a macOS Emacs reads the socket
  ;; while it waits for a line, a Linux one does not (the bridge's own order is what is promised, not the delay)
  (drgnx-mcp-bridge-test--with #'drgnx-mcp-bridge-test--echo
    (setq bridge (drgnx-mcp-bridge-test--start sock))
    (should (drgnx-mcp-bridge-test--wait (lambda () drgnx-mcp-bridge-test--conns)))
    (process-send-string (car drgnx-mcp-bridge-test--conns)
                         "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}\n")
    (drgnx-mcp-bridge-test--send bridge '(:jsonrpc "2.0" :id 1 :method "ping"))
    (should (drgnx-mcp-bridge-test--wait (lambda () (= 2 (length (drgnx-mcp-bridge-test--out bridge))))))
    (let ((out (drgnx-mcp-bridge-test--out bridge)))
      (should (equal (gethash "method" (nth 0 out)) "notifications/message"))
      (should (equal (gethash "id" (nth 1 out)) 1)))))

(ert-deftest drgnx-mcp-bridge/long-and-unicode-lines ()
  ;; a 1 MB line with U+061C (Arabic letter mark) and other non-ASCII text arrives intact, both ways
  (drgnx-mcp-bridge-test--with #'drgnx-mcp-bridge-test--echo
    (setq bridge (drgnx-mcp-bridge-test--start sock))
    (let* ((text (apply #'concat (make-list 50000 "ab؜cé日本 \\\"x\" ")))
           (line (json-serialize (list :jsonrpc "2.0" :id "big" :method "tools/call" :params (list :text text)))))
      (should (> (string-bytes line) (* 1024 1024)))
      (process-send-string bridge (concat line "\n"))
      (should (drgnx-mcp-bridge-test--wait (lambda () (drgnx-mcp-bridge-test--out bridge))))
      (should (equal drgnx-mcp-bridge-test--got (list (decode-coding-string line 'utf-8))))
      (let ((answer (car (drgnx-mcp-bridge-test--out bridge))))
        (should (equal (gethash "id" answer) "big"))
        (should (equal (gethash "text" (gethash "params" (json-parse-string (gethash "line" (gethash "result" answer)))))
                       text))))))

(ert-deftest drgnx-mcp-bridge/exits-when-the-socket-closes ()
  ;; the server goes away while a request waits: the bridge ends, status 0, and writes nothing
  (drgnx-mcp-bridge-test--with (lambda (conn _line) (delete-process conn))
    (setq bridge (drgnx-mcp-bridge-test--start sock))
    (drgnx-mcp-bridge-test--send bridge '(:jsonrpc "2.0" :id 1 :method "ping"))
    (should (equal (drgnx-mcp-bridge-test--exit bridge) 0))
    (should (equal (drgnx-mcp-bridge-test--written bridge) ""))))

(ert-deftest drgnx-mcp-bridge/exits-on-an-abrupt-close-mid-line ()
  ;; half an answer, then the connection drops: the half is never written
  (drgnx-mcp-bridge-test--with (lambda (conn _line) (process-send-string conn "{\"jsonrpc\":\"2.0\",\"id\":1,") (delete-process conn))
    (setq bridge (drgnx-mcp-bridge-test--start sock))
    (drgnx-mcp-bridge-test--send bridge '(:jsonrpc "2.0" :id 1 :method "ping"))
    (should (equal (drgnx-mcp-bridge-test--exit bridge) 0))
    (should (equal (drgnx-mcp-bridge-test--written bridge) ""))))

(ert-deftest drgnx-mcp-bridge/exits-when-the-socket-closes-while-idle ()
  ;; the server closes while the bridge waits for input: it notices at its next line and forwards nothing
  (drgnx-mcp-bridge-test--with #'drgnx-mcp-bridge-test--echo
    (setq bridge (drgnx-mcp-bridge-test--start sock))
    (should (drgnx-mcp-bridge-test--wait (lambda () drgnx-mcp-bridge-test--conns)))
    (mapc #'delete-process drgnx-mcp-bridge-test--conns)
    (accept-process-output nil 0.2)
    (should (process-live-p bridge))
    (drgnx-mcp-bridge-test--send bridge '(:jsonrpc "2.0" :id 1 :method "ping"))
    (should (equal (drgnx-mcp-bridge-test--exit bridge) 0))
    (should-not drgnx-mcp-bridge-test--got)))

(ert-deftest drgnx-mcp-bridge/exits-when-stdin-ends ()
  ;; the agent closes the bridge's stdin: status 0, and the server sees its connection close
  (drgnx-mcp-bridge-test--with #'drgnx-mcp-bridge-test--echo
    (setq bridge (drgnx-mcp-bridge-test--start sock))
    (drgnx-mcp-bridge-test--send bridge '(:jsonrpc "2.0" :id 1 :method "ping"))
    (should (drgnx-mcp-bridge-test--wait (lambda () (drgnx-mcp-bridge-test--out bridge))))
    (process-send-eof bridge)
    (should (equal (drgnx-mcp-bridge-test--exit bridge) 0))
    (should (drgnx-mcp-bridge-test--wait (lambda () (not (cl-some #'process-live-p drgnx-mcp-bridge-test--conns)))))))

(ert-deftest drgnx-mcp-bridge/missing-socket-says-so ()
  (let* ((dir (make-temp-file "mb" t)) (sock (expand-file-name "none.sock" dir))
         (bridge (drgnx-mcp-bridge-test--start sock)))
    (unwind-protect
        (progn (should (equal (drgnx-mcp-bridge-test--exit bridge) 1))
               (should (string-match-p "drgnx-mcp-bridge: .*none\\.sock" (drgnx-mcp-bridge-test--err bridge)))
               (should (equal (drgnx-mcp-bridge-test--written bridge) "")))
      (drgnx-mcp-bridge-test--kill bridge)
      (delete-directory dir t))))

(ert-deftest drgnx-mcp-bridge/oversize-from-the-agent-closes ()
  ;; a line over the limit ends the bridge (status 1) before anything reaches the server
  (drgnx-mcp-bridge-test--with #'drgnx-mcp-bridge-test--echo
    (setq bridge (drgnx-mcp-bridge-test--start sock "(setq drgnx-mcp-bridge-max-line 1000)"))
    (drgnx-mcp-bridge-test--send bridge (list :jsonrpc "2.0" :id 1 :method "ping" :params (list :x (make-string 2000 ?a))))
    (should (equal (drgnx-mcp-bridge-test--exit bridge) 1))
    (should (string-match-p "drgnx-mcp-bridge: .*too large" (drgnx-mcp-bridge-test--err bridge)))
    (should-not drgnx-mcp-bridge-test--got)))

(ert-deftest drgnx-mcp-bridge/oversize-from-the-server-closes ()
  ;; an answer over the limit, even in many pieces, ends the bridge (status 1) and is never written
  (drgnx-mcp-bridge-test--with
      (lambda (conn _line) (process-send-string conn (concat "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"" (make-string 5000 ?b))))
    (setq bridge (drgnx-mcp-bridge-test--start sock "(setq drgnx-mcp-bridge-max-line 1000)"))
    (drgnx-mcp-bridge-test--send bridge '(:jsonrpc "2.0" :id 1 :method "ping"))
    (should (equal (drgnx-mcp-bridge-test--exit bridge) 1))
    (should (string-match-p "drgnx-mcp-bridge: .*too large" (drgnx-mcp-bridge-test--err bridge)))
    (should (equal (drgnx-mcp-bridge-test--written bridge) ""))))

(ert-deftest drgnx-mcp-bridge/malformed-frames-close ()
  ;; a line that is not a JSON object ends the bridge (status 1); nothing reaches the other side
  (dolist (bad '("not json" "[1,2]" "\"text\""))
    (drgnx-mcp-bridge-test--with #'drgnx-mcp-bridge-test--echo
      (setq bridge (drgnx-mcp-bridge-test--start sock))
      (process-send-string bridge (concat bad "\n"))
      (should (equal (drgnx-mcp-bridge-test--exit bridge) 1))
      (should (string-match-p "drgnx-mcp-bridge: .*malformed" (drgnx-mcp-bridge-test--err bridge)))
      (should-not drgnx-mcp-bridge-test--got)))
  (drgnx-mcp-bridge-test--with (lambda (conn _line) (process-send-string conn "{\"id\":1,\n"))
    (setq bridge (drgnx-mcp-bridge-test--start sock))
    (drgnx-mcp-bridge-test--send bridge '(:jsonrpc "2.0" :id 1 :method "ping"))
    (should (equal (drgnx-mcp-bridge-test--exit bridge) 1))
    (should (equal (drgnx-mcp-bridge-test--written bridge) ""))))

(ert-deftest drgnx-mcp-bridge/many-messages ()
  ;; 2000 requests written at once all come back, in order
  (drgnx-mcp-bridge-test--with #'drgnx-mcp-bridge-test--echo
    (setq bridge (drgnx-mcp-bridge-test--start sock))
    (process-send-string bridge (mapconcat (lambda (i) (concat (json-serialize (list :jsonrpc "2.0" :id i :method "ping")) "\n"))
                                           (number-sequence 1 2000)))
    (should (drgnx-mcp-bridge-test--wait (lambda () (= 2000 (length drgnx-mcp-bridge-test--got))) 60))
    (should (drgnx-mcp-bridge-test--wait
             (lambda () (with-current-buffer (process-buffer bridge)
                          (= 2000 (how-many "\n" (point-min) (point-max)))))
             60))
    (should (equal (mapcar (lambda (m) (gethash "id" m)) (drgnx-mcp-bridge-test--out bridge)) (number-sequence 1 2000)))))

(ert-deftest drgnx-mcp-bridge/split-is-linear ()
  ;; one line in 64-byte pieces: copying the pending input per piece is quadratic, so 4× the input would cost 16×
  ;; the allocation, not 4×
  (drgnx-test-compile "drgnx-mcp-bridge-")
  (let* ((drgnx-mcp-bridge-max-line (* 16 1024 1024)) (piece (make-string 64 ?x))
         (feed (lambda (pieces) (let ((state (drgnx-mcp-bridge--state)))
                                  (dotimes (_ pieces) (drgnx-mcp-bridge--feed state piece #'ignore)))))
         (small (drgnx-test-alloc (funcall feed 4096))) (big (drgnx-test-alloc (funcall feed 16384))))
    (should (<= big (* 1.25 4 small))))
  ;; 4 MB in all
  (let* ((drgnx-mcp-bridge-max-line (* 16 1024 1024)) (state (drgnx-mcp-bridge--state)) (lines nil)
         (piece (make-string 64 ?x)) (n (/ (* 4 1024 1024) 64)))
    (dotimes (_ n) (drgnx-mcp-bridge--feed state piece (lambda (l) (push l lines))))
    (drgnx-mcp-bridge--feed state "y\nz1\nz2\nrest" (lambda (l) (push l lines)))
    (should (equal (mapcar #'length lines) (list 2 2 (1+ (* n 64)))))
    (should (equal (cdr (reverse lines)) '("z1" "z2")))))

(provide 'mcp-bridge-test)
;;; mcp-bridge-test.el ends here
