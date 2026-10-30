;;; sandbox-relay-test.el --- batch tests: the network relay inside the sandbox -*- lexical-binding: t -*-
;; The relay runs as the sandbox runs it: `drgnx-sandbox-relay-entry' around a fake agent, here without the sandbox.
;; A fake upstream (the proxy's or the gateway's socket) listens on a Unix socket in the test's temporary directory,
;; and the ports are free ones on the host's 127.0.0.1, found at run time: no real host is reached.
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'drgnx-sandbox-relay)

(defvar drgnx-sandbox-relay-test--conns nil "The connections the fake upstream accepted, newest first.")

(defun drgnx-sandbox-relay-test--upstream (sock &optional greeting)
  "A fake upstream on SOCK: it sends GREETING (if any) on each connection, then echoes every byte it receives.  Its
listen queue holds every connection a test makes before this Emacs accepts one: on macOS a Unix socket's connect is
refused once the queue (Emacs's default, 5) is full, where Linux waits."
  (make-network-process
   :name "fake-upstream" :family 'local :server 32 :service sock :noquery t :coding 'binary
   :log (lambda (_server conn _msg)
          (push conn drgnx-sandbox-relay-test--conns)
          (when greeting (process-send-string conn greeting)))
   :filter (lambda (conn s) (process-send-string conn s))))

(defun drgnx-sandbox-relay-test--free-port ()
  "A TCP port free on 127.0.0.1 a moment ago."
  (let* ((p (make-network-process :name "free-port" :server t :host "127.0.0.1" :service t :family 'ipv4 :noquery t))
         (port (process-contact p :service)))
    (delete-process p)
    port))

(defun drgnx-sandbox-relay-test--wait (pred &optional secs)
  "Wait until PRED is true (at most SECS, default 20): its value."
  (drgnx-test-wait pred :secs (or secs 20) :what "the sandbox condition"))

(defun drgnx-sandbox-relay-test--start (pairs command)
  "`drgnx-sandbox-relay-entry' of PAIRS around COMMAND, started: its process (stdout and stderr in buffers)."
  (let ((err (generate-new-buffer " *relay-err*")))
    (let ((p (make-process :name "relay-entry" :noquery t :connection-type 'pipe :coding 'binary
                           :command (drgnx-sandbox-relay-entry pairs command)
                           :buffer (generate-new-buffer " *relay-out*") :stderr err :sentinel #'ignore)))
      (process-put p :err err)
      p)))

(defun drgnx-sandbox-relay-test--out (proc)
  (with-current-buffer (process-buffer proc) (buffer-string)))

(defun drgnx-sandbox-relay-test--exit (proc)
  "PROC's exit status once it has ended, or nil after 20 s."
  (and (drgnx-sandbox-relay-test--wait (lambda () (memq (process-status proc) '(exit signal))))
       (process-exit-status proc)))

(defun drgnx-sandbox-relay-test--connect (port)
  "A connection to 127.0.0.1:PORT; what it receives accumulates in its `:got' property."
  (let ((c (make-network-process :name "relay-client" :host "127.0.0.1" :service port :family 'ipv4 :noquery t
                                 :coding 'binary
                                 :filter (lambda (c s) (process-put c :got (concat (process-get c :got) s)))
                                 :sentinel #'ignore)))
    (process-put c :got "")
    c))

(defmacro drgnx-sandbox-relay-test--with (greeting &rest body)
  "BODY with `sock' (a fake upstream, GREETING per connection), `port' (free) and `entry' (nil; set it), cleaned after."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "relay" t)) (sock (expand-file-name "up.sock" dir)) (drgnx-sandbox-relay-test--conns nil)
          (upstream (drgnx-sandbox-relay-test--upstream sock ,greeting)) (port (drgnx-sandbox-relay-test--free-port))
          (entry nil))
     (unwind-protect (progn ,@body)
       (when (processp entry)
         (delete-process entry)
         (kill-buffer (process-buffer entry))
         (kill-buffer (process-get entry :err)))
       (mapc #'delete-process drgnx-sandbox-relay-test--conns)
       (delete-process upstream)
       (delete-directory dir t))))

(defun drgnx-sandbox-relay-test--agent-up (entry)
  "Wait for ENTRY's agent to say `up' on its stdout: non-nil once it has."
  (drgnx-sandbox-relay-test--wait (lambda () (string-search "up\n" (drgnx-sandbox-relay-test--out entry)))))

(ert-deftest drgnx-sandbox-relay/forwards-bytes-both-ways ()
  ;; every byte value passes unchanged, the upstream's own first bytes too, and the agent's stdout is the entry's own
  (let ((bytes (apply #'unibyte-string (number-sequence 0 255))))
    (drgnx-sandbox-relay-test--with "hello\0\377"
      (setq entry (drgnx-sandbox-relay-test--start (list (cons port sock)) '("sh" "-c" "echo up; exec sleep 60")))
      (should (drgnx-sandbox-relay-test--agent-up entry))
      (let ((c (drgnx-sandbox-relay-test--connect port)))
        (unwind-protect
            (progn
              (should (drgnx-sandbox-relay-test--wait (lambda () (equal (process-get c :got) "hello\0\377"))))
              (process-send-string c bytes)
              (should (drgnx-sandbox-relay-test--wait
                       (lambda () (= (length (process-get c :got)) (+ 7 256)))))
              (should (equal (string-to-unibyte (process-get c :got)) (concat "hello\0\377" bytes))))
          (delete-process c))))))

(ert-deftest drgnx-sandbox-relay/ready-before-the-agent ()
  ;; the agent connects as its very first act, three times over, and never fails; its stdin is its own.  A relay
  ;; that cannot listen keeps the agent from starting at all
  (drgnx-sandbox-relay-test--with nil
    (let ((agent (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "--eval"
                       (format "(let* ((got \"\") (n 0) (p (make-network-process :name \"a\" :host \"127.0.0.1\"
                                  :service %d :family 'ipv4 :coding 'binary
                                  :filter (lambda (_ s) (setq got (concat got s))))))
                                  (process-send-string p \"ping\")
                                  (while (and (< (length got) 4) (< (setq n (1+ n)) 100)) (accept-process-output p 0.1))
                                  (princ (format \"reply:%%s\\n\" got))
                                  (princ (format \"stdin:%%s\\n\" (read-from-minibuffer \"\"))))"
                               port))))
      (dotimes (_ 3)
        (setq entry (drgnx-sandbox-relay-test--start (list (cons port sock)) agent))
        (process-send-string entry "from-the-hub\n")
        (should (eql (drgnx-sandbox-relay-test--exit entry) 0))
        (should (equal (drgnx-sandbox-relay-test--out entry) "reply:ping\nstdin:from-the-hub\n"))
        (delete-process entry)
        (kill-buffer (process-buffer entry))
        (kill-buffer (process-get entry :err))
        (setq entry nil)
        ;; the previous relay has left the port before the next one listens on it
        (should (drgnx-sandbox-relay-test--wait
                 (lambda () (condition-case nil (progn (delete-process (drgnx-sandbox-relay-test--connect port)) nil)
                              (file-error t)))))))
    (let ((taken (make-network-process :name "taken" :server t :host "127.0.0.1" :service port
                                       :family 'ipv4 :noquery t)))
      (unwind-protect
          (progn
            (setq entry (drgnx-sandbox-relay-test--start (list (cons port sock)) '("sh" "-c" "echo agent-ran")))
            (should (eql (drgnx-sandbox-relay-test--exit entry) 1))
            (should-not (string-search "agent-ran" (drgnx-sandbox-relay-test--out entry))))
        (delete-process taken)))))

(ert-deftest drgnx-sandbox-relay/many-connections ()
  ;; twenty connections at once, on two ports to two sockets: each gets its own bytes back, none another's
  (drgnx-sandbox-relay-test--with nil
    (let* ((sock2 (expand-file-name "up2.sock" dir)) (up2 (drgnx-sandbox-relay-test--upstream sock2 "2:"))
           (port2 (drgnx-sandbox-relay-test--free-port)) (clients nil))
      (unwind-protect
          (progn
            (setq entry (drgnx-sandbox-relay-test--start (list (cons port sock) (cons port2 sock2))
                                                         '("sh" "-c" "echo up; exec sleep 60")))
            (should (drgnx-sandbox-relay-test--agent-up entry))
            (dotimes (i 20)
              (let ((c (drgnx-sandbox-relay-test--connect (if (cl-evenp i) port port2))))
                (process-put c :want (format "%sconn-%d;" (if (cl-evenp i) "" "2:") i))
                (process-send-string c (format "conn-%d;" i))
                (push c clients)))
            (should (drgnx-sandbox-relay-test--wait
                     (lambda () (cl-every (lambda (c) (equal (process-get c :got) (process-get c :want))) clients))))
            (should (= 20 (length drgnx-sandbox-relay-test--conns))))
        (mapc #'delete-process clients)
        (delete-process up2)))))

(ert-deftest drgnx-sandbox-relay/ends-with-the-agent ()
  ;; when the agent ends, the relay ends too: its open connections close and its port is free again
  (drgnx-sandbox-relay-test--with nil
    (setq entry (drgnx-sandbox-relay-test--start (list (cons port sock)) '("sh" "-c" "echo up; read x")))
    (should (drgnx-sandbox-relay-test--agent-up entry))
    (let ((c (drgnx-sandbox-relay-test--connect port)))
      (process-send-string c "x")
      (should (drgnx-sandbox-relay-test--wait (lambda () (equal (process-get c :got) "x"))))
      (process-send-string entry "\n")
      (should (eql (drgnx-sandbox-relay-test--exit entry) 0))
      (should (drgnx-sandbox-relay-test--wait (lambda () (not (process-live-p c))) 10))
      (should (drgnx-sandbox-relay-test--wait
               (lambda () (condition-case nil (progn (delete-process (drgnx-sandbox-relay-test--connect port)) nil)
                            (file-error t)))
               10)))))

;;; sandbox-relay-test.el ends here
