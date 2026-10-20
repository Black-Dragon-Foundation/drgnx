;;; sandbox-proxy-test.el --- batch tests: the job's allowlisting proxy -*- lexical-binding: t -*-
;; The proxy runs as a child batch Emacs, as the hub starts it, on a Unix socket in the test's temporary directory.
;; Upstreams are local listeners on 127.0.0.1, reached by names pinned to that address
;; (`drgnx-sandbox-proxy-pinned-addresses'); no test resolves or reaches a real host.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-sandbox-proxy)
(require 'drgnx-paths)
(require 'drgnx-timer)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defvar drgnx-sandbox-proxy-test--got nil "What the upstream received, per connection: (CONN . BYTES), newest first.")
(defvar drgnx-sandbox-proxy-test--conns nil "The connections the upstream accepted.")

(defun drgnx-sandbox-proxy-test--upstream (&optional reply)
  "A local upstream on 127.0.0.1 (a random port): it records what each connection sends and answers its first chunk
with REPLY, if any."
  (make-network-process
   :name "up" :server t :host "127.0.0.1" :service t :family 'ipv4 :noquery t :coding 'binary
   :log (lambda (_server conn _msg) (push conn drgnx-sandbox-proxy-test--conns))
   :filter (lambda (conn s)
             (let ((cell (assq conn drgnx-sandbox-proxy-test--got)))
               (if cell (setcdr cell (concat (cdr cell) s))
                 (push (cons conn s) drgnx-sandbox-proxy-test--got)
                 (when reply (process-send-string conn reply)))))))

(defun drgnx-sandbox-proxy-test--wait (pred &optional secs)
  "Wait until PRED is true (at most SECS, default 20): its value."
  (let ((deadline (+ (float-time) (or secs 20))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    v))

(defun drgnx-sandbox-proxy-test--connect (proxy text)
  "A client connection to PROXY (its socket path, or a port on 127.0.0.1) that sends TEXT; it records the answer."
  (let ((c (if (stringp proxy)
               (make-network-process :name "client" :family 'local :service proxy :noquery t :coding 'binary
                                     :filter (lambda (p s) (process-put p :in (concat (process-get p :in) s))))
             (make-network-process :name "client" :host "127.0.0.1" :service proxy :family 'ipv4 :noquery t
                                   :coding 'binary
                                   :filter (lambda (p s) (process-put p :in (concat (process-get p :in) s)))))))
    (process-put c :in "")
    (process-send-string c text)
    c))

(defun drgnx-sandbox-proxy-test--status (client)
  "The status code of the answer CLIENT got (an integer), or nil after 20 s."
  (when (drgnx-sandbox-proxy-test--wait (lambda () (string-search "\r\n\r\n" (process-get client :in))))
    (let ((in (process-get client :in)))
      (and (string-match "\\`HTTP/1\\.1 \\([0-9]\\{3\\}\\) " in) (string-to-number (match-string 1 in))))))

(defun drgnx-sandbox-proxy-test--try (proxy authority)
  "Send `CONNECT AUTHORITY' to PROXY: the answer's status code; the connection is closed after."
  (let ((c (drgnx-sandbox-proxy-test--connect proxy (format "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n" authority authority))))
    (prog1 (drgnx-sandbox-proxy-test--status c) (delete-process c))))

(defvar drgnx-sandbox-proxy-test--eval nil "A form's text the proxy evaluates before its entry, or nil.")

(defun drgnx-sandbox-proxy-test--start (hosts sock)
  "`drgnx-sandbox-proxy-start' for job \"job-1\", with `drgnx-sandbox-proxy-test--eval' run first in the proxy."
  (if (not drgnx-sandbox-proxy-test--eval) (drgnx-sandbox-proxy-start "job-1" hosts sock)
    (let* ((command (drgnx-sandbox-proxy-command hosts sock)) (i (cl-position "-f" command :test #'equal))
           (p (make-process :name "proxy" :noquery t :connection-type 'pipe :coding 'utf-8-unix
                            :command (append (cl-subseq command 0 i) (list "--eval" drgnx-sandbox-proxy-test--eval)
                                             (nthcdr i command))
                            :filter #'drgnx-sandbox-proxy--hub-filter :sentinel #'ignore)))
      (process-put p :job "job-1")
      p)))

(defmacro drgnx-sandbox-proxy-test--with (hosts pins &rest body)
  "BODY with `up' (a local upstream), `port' (its port), `sock' and `proxy' (started for job \"job-1\" with HOSTS, a
form that may use `port') and `denied' (the reports, oldest first).  PINS are names pinned to 127.0.0.1."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "px" t)) (sock (expand-file-name "proxy.sock" dir))
          (drgnx-sandbox-proxy-test--got nil) (drgnx-sandbox-proxy-test--conns nil) (denied nil)
          (drgnx-sandbox-proxy-denied-functions (list (lambda (job hp) (setq denied (append denied (list (list job hp)))))))
          (drgnx-sandbox-proxy-pinned-addresses (mapcar (lambda (n) (cons n "127.0.0.1")) ,pins))
          (up (drgnx-sandbox-proxy-test--upstream)) (port (process-contact up :service)) (proxy nil))
     (ignore port)
     (unwind-protect
         (progn
           (setq proxy (drgnx-sandbox-proxy-test--start ,hosts sock))
           (should (drgnx-sandbox-proxy-test--wait (lambda () (process-get proxy :ready))))
           ,@body)
       (when (processp proxy) (delete-process proxy))
       (mapc #'delete-process drgnx-sandbox-proxy-test--conns)
       (delete-process up)
       (delete-directory dir t))))

(ert-deftest drgnx-sandbox-proxy/hosts-are-parsed-strictly ()
  ;; names: case and one trailing dot folded, IDNA to its ASCII form for entries, no suffix tricks
  (should (equal (drgnx-sandbox-proxy-normalize "API.Anthropic.com.:443") "api.anthropic.com:443"))
  (should (equal (drgnx-sandbox-proxy-normalize "Bücher.example:443") "xn--bcher-kva.example:443"))
  (should (equal (drgnx-sandbox-proxy-normalize "*.Example.com:443") "*.example.com:443"))
  (should (equal (drgnx-sandbox-proxy-normalize "[::1]:8443") "[0:0:0:0:0:0:0:1]:8443"))
  (should (equal (drgnx-sandbox-proxy-normalize "10.0.0.1:80") "10.0.0.1:80"))
  (dolist (bad '("example.com" "example.com:0" "example.com:65536" "example.com:+443" "example.com:0443"
                 "*.com:443" "*:443" "a.*.example.com:443" "exa mple.com:443" "user@example.com:443"
                 "example.com:443\nallow evil.com:443" "-x.example.com:443" "a..b:443" ".example.com:443"
                 ;; numeric names a resolver would read as an address: 127.0.0.1 four ways
                 "2130706433:443" "127.1:443" "0x7f.0.0.1:443" "127.0.0.0x1:443" "017.0.0.1:443" "256.0.0.1:443"
                 "[fe80::1%eth0]:443" "[::1]" ""))
    (should-not (drgnx-sandbox-proxy-normalize bad)))
  ;; a request's authority must already be ASCII: a client sends the A-label
  (should-not (drgnx-sandbox-proxy-normalize "bücher.example:443" t))
  (should (equal (drgnx-sandbox-proxy-normalize "xn--bcher-kva.example:443" t) "xn--bcher-kva.example:443")))

(ert-deftest drgnx-sandbox-proxy/private-addresses-are-not-public ()
  (dolist (a '([127 0 0 1 0] [10 1 2 3 0] [172 16 0 1 0] [172 31 255 255 0] [192 168 1 1 0] [169 254 169 254 0]
               [100 64 0 1 0] [0 0 0 0 0] [224 0 0 1 0] [255 255 255 255 0]
               [0 0 0 0 0 0 0 1 0] [0 0 0 0 0 0 0 0 0] [0 0 0 0 0 #xffff #x7f00 1 0] [#xfd00 0 0 0 0 0 0 1 0]
               [#xfe80 0 0 0 0 0 0 1 0] [#xff02 0 0 0 0 0 0 1 0] [#x64 #xff9b 0 0 0 0 #x0a00 1 0]
               [#x2002 #x7f00 1 0 0 0 0 1 0]))
    (should-not (drgnx-sandbox-proxy--public-p a)))
  (dolist (a '([93 184 216 34 0] [172 32 0 1 0] [1 1 1 1 0] [#x2606 #x4700 0 0 0 0 0 #x1111 0]
               [0 0 0 0 0 #xffff #x0101 #x0101 0]))
    (should (drgnx-sandbox-proxy--public-p a))))

(ert-deftest drgnx-sandbox-proxy/only-the-allowlist ()
  (drgnx-sandbox-proxy-test--with (list (format "up.test:%d" port) (format "localhost:%d" port))
      '("up.test" "other.test" "up.test.attacker" "xup.test")
    (should (= 200 (drgnx-sandbox-proxy-test--try sock (format "up.test:%d" port))))
    (should (= 200 (drgnx-sandbox-proxy-test--try sock (format "UP.Test.:%d" port))))
    (dolist (a (list (format "other.test:%d" port) (format "up.test.attacker:%d" port) (format "xup.test:%d" port)
                     (format "up.test:%d" (1+ port)) (format "127.0.0.1:%d" port) (format "93.184.216.34:%d" port)))
      (should (= 403 (drgnx-sandbox-proxy-test--try sock a))))
    ;; listed, but the name resolves to loopback and nothing pins it there: refused, and no card (Allow cannot help)
    (should (= 403 (drgnx-sandbox-proxy-test--try sock (format "localhost:%d" port))))
    ;; a loopback literal is refused as private, never offered on a card; a public one not listed is
    (should (drgnx-sandbox-proxy-test--wait (lambda () (= 5 (length denied)))))
    (accept-process-output nil 0.2)
    (should (equal (mapcar #'cadr denied)
                   (list (format "other.test:%d" port) (format "up.test.attacker:%d" port) (format "xup.test:%d" port)
                         (format "up.test:%d" (1+ port)) (format "93.184.216.34:%d" port))))
    ;; the upstream saw the two allowed connections only
    (should (= 2 (length drgnx-sandbox-proxy-test--conns)))))

(ert-deftest drgnx-sandbox-proxy/literal-addresses-need-listing ()
  ;; a private address is reached only when the allowlist names that very address; any other is refused as private,
  ;; with no `denied' line, so no card can offer a one-click Allow of the user's loopback or the metadata address
  (drgnx-sandbox-proxy-test--with (list (format "127.0.0.1:%d" port)) nil
    (should (= 200 (drgnx-sandbox-proxy-test--try sock (format "127.0.0.1:%d" port))))
    (dolist (a (list (format "[::ffff:127.0.0.1]:%d" port) (format "127.0.0.2:%d" port) (format "0.0.0.0:%d" port)
                     "169.254.169.254:80" (format "[::1]:%d" port) "10.0.0.1:443" "[fe80::1]:443"))
      (should (= 403 (drgnx-sandbox-proxy-test--try sock a))))
    (should (drgnx-sandbox-proxy-test--wait (lambda () (equal (process-get proxy :said) "refused [fe80:0:0:0:0:0:0:1]:443 private"))))
    (should-not denied)))

(ert-deftest drgnx-sandbox-proxy/no-tls-termination ()
  ;; after the 200 the bytes are spliced as they are: the upstream sees the client's own ClientHello (a TLS record,
  ;; every byte value), and the client the upstream's answer, unchanged
  (let ((hello (concat (unibyte-string #x16 #x03 #x01 #x01 #x00) (apply #'unibyte-string (number-sequence 0 255))))
        (answer (concat (unibyte-string #x16 #x03 #x03 #x00 #x40) (apply #'unibyte-string (number-sequence 255 0 -1)))))
    (drgnx-sandbox-proxy-test--with (list (format "up.test:%d" port)) '("up.test")
      (delete-process up)
      (setq up (drgnx-sandbox-proxy-test--upstream answer) port (process-contact up :service))
      (drgnx-sandbox-proxy-send proxy "allow" (format "up.test:%d" port))
      (let ((c nil))
        (should (drgnx-sandbox-proxy-test--wait
                 (lambda ()
                   (when c (delete-process c))
                   (setq c (drgnx-sandbox-proxy-test--connect sock (format "CONNECT up.test:%d HTTP/1.1\r\n\r\n" port)))
                   (eql 200 (drgnx-sandbox-proxy-test--status c)))))
        (should (equal (process-get c :in) "HTTP/1.1 200 Connection established\r\n\r\n"))
        (process-send-string c hello)
        (should (drgnx-sandbox-proxy-test--wait (lambda () (>= (length (cdar drgnx-sandbox-proxy-test--got)) (length hello)))))
        (should (equal (cdar drgnx-sandbox-proxy-test--got) hello))
        (should (drgnx-sandbox-proxy-test--wait (lambda () (string-suffix-p answer (process-get c :in)))))
        (should (equal (process-get c :in) (concat "HTTP/1.1 200 Connection established\r\n\r\n" answer)))
        (delete-process c)))))

(ert-deftest drgnx-sandbox-proxy/plain-http-refused ()
  ;; other methods, a bad request line and a head that never ends are refused; none reaches the upstream or asks
  (drgnx-sandbox-proxy-test--with (list (format "up.test:%d" port)) '("up.test")
    (dolist (text (list (format "GET http://up.test:%d/ HTTP/1.1\r\nHost: up.test\r\n\r\n" port)
                        (format "POST http://up.test:%d/ HTTP/1.1\r\n\r\n" port)
                        (format "CONNECT up.test:%d\r\n\r\n" port)
                        (format "CONNECT up.test:%d HTTP/1.1 x\r\n\r\n" port)
                        (format "CONNECT http://up.test:%d/ HTTP/1.1\r\n\r\n" port)
                        (format "CONNECT up.test:%d HTTP/1.1\r\nX: %s\r\n\r\n" port (make-string 9000 ?a))))
      (let ((c (drgnx-sandbox-proxy-test--connect sock text)))
        (should (eql 403 (drgnx-sandbox-proxy-test--status c)))
        (delete-process c)))
    (should-not drgnx-sandbox-proxy-test--conns)
    (should-not denied)))

(ert-deftest drgnx-sandbox-proxy/wildcard-matches-subdomains-only ()
  (drgnx-sandbox-proxy-test--with (list (format "*.up.test:%d" port))
      '("a.up.test" "b.a.up.test" "up.test" "evilup.test" "a.up.test.evil")
    (should (= 200 (drgnx-sandbox-proxy-test--try sock (format "a.up.test:%d" port))))
    (should (= 200 (drgnx-sandbox-proxy-test--try sock (format "b.a.up.test:%d" port))))
    (dolist (h '("up.test" "evilup.test" "a.up.test.evil"))
      (should (= 403 (drgnx-sandbox-proxy-test--try sock (format "%s:%d" h port)))))
    (should (= 403 (drgnx-sandbox-proxy-test--try sock (format "a.up.test:%d" (1+ port)))))
    ;; a wildcard is never a target: it would reach the apex, or ask the user for a wildcard grant
    (should (= 403 (drgnx-sandbox-proxy-test--try sock (format "*.up.test:%d" port))))
    (should (= 403 (drgnx-sandbox-proxy-test--try sock (format "*.other.test:%d" port))))
    (should (drgnx-sandbox-proxy-test--wait (lambda () (= 4 (length denied)))))
    (accept-process-output nil 0.2)
    (should (equal (mapcar #'cadr denied)
                   (list (format "up.test:%d" port) (format "evilup.test:%d" port) (format "a.up.test.evil:%d" port)
                         (format "a.up.test:%d" (1+ port)))))
    (should (= 2 (length drgnx-sandbox-proxy-test--conns)))))

(ert-deftest drgnx-sandbox-proxy/a-head-has-a-deadline ()
  ;; a client that never finishes its head is answered 403 and closed once the deadline passes
  (let ((drgnx-sandbox-proxy-test--eval "(setq drgnx-sandbox-proxy-head-timeout 0.5)"))
    (drgnx-sandbox-proxy-test--with (list (format "up.test:%d" port)) '("up.test")
      (let ((c (drgnx-sandbox-proxy-test--connect sock (format "CONNECT up.test:%d HTTP/1.1\r\n" port))))
        (should (eql 403 (drgnx-sandbox-proxy-test--status c)))
        (should (drgnx-sandbox-proxy-test--wait (lambda () (not (process-live-p c))) 5))
        (should-not drgnx-sandbox-proxy-test--conns)))))

(ert-deftest drgnx-sandbox-proxy/connections-are-capped ()
  ;; past the cap a new connection is answered 403 at once; a closed one frees its place
  (let ((drgnx-sandbox-proxy-test--eval "(setq drgnx-sandbox-proxy-max-connections 3)"))
    (drgnx-sandbox-proxy-test--with (list (format "up.test:%d" port)) '("up.test")
      (let ((held (list (drgnx-sandbox-proxy-test--connect sock "CONNECT ")
                        (drgnx-sandbox-proxy-test--connect sock "CONNECT ")
                        (drgnx-sandbox-proxy-test--connect sock "CONNECT "))))
        (accept-process-output nil 0.3)
        (should (= 403 (drgnx-sandbox-proxy-test--try sock (format "up.test:%d" port))))
        (should (cl-every (lambda (c) (equal (process-get c :in) "")) held))
        (delete-process (car held))
        (should (drgnx-sandbox-proxy-test--wait (lambda () (eql 200 (drgnx-sandbox-proxy-test--try sock (format "up.test:%d" port))))))
        (mapc #'delete-process held)))))

(ert-deftest drgnx-sandbox-proxy/allow-takes-effect-on-retry ()
  (drgnx-sandbox-proxy-test--with nil '("up.test")
    (let ((hp (format "up.test:%d" port)))
      (should (= 403 (drgnx-sandbox-proxy-test--try sock hp)))
      (should (drgnx-sandbox-proxy-test--wait (lambda () denied)))
      (should (equal denied (list (list "job-1" hp))))
      (should (equal (drgnx-sandbox-proxy-allow proxy (upcase hp)) hp))
      (should (drgnx-sandbox-proxy-test--wait (lambda () (eql 200 (drgnx-sandbox-proxy-test--try sock hp)))))
      ;; a line that is no entry never reaches the proxy
      (should-error (drgnx-sandbox-proxy-allow proxy (concat hp "\nallow evil.test:443")))
      ;; and `deny' takes it away again
      (drgnx-sandbox-proxy-send proxy "deny" hp)
      (should (drgnx-sandbox-proxy-test--wait (lambda () (eql 403 (drgnx-sandbox-proxy-test--try sock hp))))))))

(defun drgnx-sandbox-proxy-test--heads ()
  "The connections whose head deadline is pending: the OBJECTs of the timer layer's `sandbox-proxy-head' keys."
  (delq nil (mapcar (lambda (e) (and (eq (car-safe (car e)) 'sandbox-proxy-head) (cdr (car e)))) (drgnx-timer-pending))))

(ert-deftest drgnx-sandbox-proxy/the-head-deadline-is-a-layer-timer-of-its-connection ()
  "In this Emacs, on virtual time: each client's head deadline is the timer layer's (sandbox-proxy-head . CONN),
owned by CONN.  A client that went away takes its deadline with it; a whole head cancels it; past
`drgnx-sandbox-proxy-head-timeout' a client still sending its head is answered 403."
  (drgnx-test-with-clock ()
    (let* ((dir (make-temp-file "px" t)) (sock (expand-file-name "p.sock" dir))
           (drgnx-sandbox-proxy-head-timeout 10)
           (server (make-network-process :name "drgnx-sandbox-proxy-test" :server t :family 'local :service sock
                                         :noquery t :coding 'binary :log #'drgnx-sandbox-proxy--accept
                                         :filter #'drgnx-sandbox-proxy--client-filter
                                         :sentinel #'drgnx-sandbox-proxy--client-sentinel))
           (gone nil) (slow nil) (bad nil))
      (unwind-protect
          (progn
            (setq gone (drgnx-sandbox-proxy-test--connect sock "CONNECT "))
            (should (drgnx-test-wait (lambda () (drgnx-sandbox-proxy-test--heads)) :secs 5 :what "a head deadline"))
            (let* ((conn (car (drgnx-sandbox-proxy-test--heads))) (key (cons 'sandbox-proxy-head conn)))
              (should (equal (assoc key (drgnx-timer-pending)) (list key conn 'start)))
              (delete-process gone)
              (should (drgnx-test-wait (lambda () (eq (process-get conn :phase) 'closed))   ; its sentinel closed it
                                       :what "the server side of the client")))
            (setq slow (drgnx-sandbox-proxy-test--connect sock "CONNECT "))
            (should (drgnx-test-wait (lambda () (= 2 (length (drgnx-sandbox-proxy-test--heads)))) :what "a second deadline"))
            (setq bad (drgnx-sandbox-proxy-test--connect sock "GET / HTTP/1.1\r\n\r\n"))
            (should (eql 403 (drgnx-sandbox-proxy-test--status bad)))
            (should (= 2 (length (drgnx-sandbox-proxy-test--heads))))      ; the whole head cancelled its deadline
            (drgnx-test-advance 9)
            (should (equal (process-get slow :in) ""))
            (drgnx-test-advance 1)
            (should (eql 403 (drgnx-sandbox-proxy-test--status slow)))
            (should-not (drgnx-sandbox-proxy-test--heads)))              ; the gone client's: dropped, never called
        (dolist (p (list gone slow bad server)) (when (processp p) (delete-process p)))
        (delete-directory dir t)))))

(ert-deftest drgnx-sandbox-proxy/denials-reported-once-per-host ()
  (drgnx-sandbox-proxy-test--with nil '("other.test" "third.test")
    (dotimes (_ 3) (should (= 403 (drgnx-sandbox-proxy-test--try sock (format "other.test:%d" port)))))
    (should (= 403 (drgnx-sandbox-proxy-test--try sock (format "Third.test:%d" port))))
    (should (= 403 (drgnx-sandbox-proxy-test--try sock (format "other.test:%d" port))))
    (accept-process-output nil 0.2)
    (should (equal denied (list (list "job-1" (format "other.test:%d" port)) (list "job-1" (format "third.test:%d" port)))))))

(ert-deftest drgnx-sandbox-proxy/a-port-without-a-socket ()
  ;; macOS: no socket path, so the proxy listens on a random port of 127.0.0.1 and says which
  (let* ((drgnx-sandbox-proxy-test--conns nil) (drgnx-sandbox-proxy-pinned-addresses '(("up.test" . "127.0.0.1")))
         (up (drgnx-sandbox-proxy-test--upstream)) (port (process-contact up :service))
         (proxy (drgnx-sandbox-proxy-start "job-1" (list (format "up.test:%d" port)) nil)))
    (unwind-protect
        (progn
          (should (drgnx-sandbox-proxy-test--wait (lambda () (process-get proxy :port))))
          (should (= 200 (drgnx-sandbox-proxy-test--try (process-get proxy :port) (format "up.test:%d" port)))))
      (delete-process proxy)
      (mapc #'delete-process drgnx-sandbox-proxy-test--conns)
      (delete-process up))))

(ert-deftest drgnx-sandbox-proxy/ends-with-the-hub ()
  ;; a stand-in hub (a batch Emacs) starts the proxy and is killed: the proxy, its child, ends with it
  (let* ((dir (make-temp-file "px" t)) (sock (expand-file-name "proxy.sock" dir))
         (hub (make-process
               :name "hub" :noquery t :connection-type 'pipe :buffer (generate-new-buffer " *px-hub*")
               :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                              "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-sandbox-proxy"
                              "--eval" (format "(let ((p (drgnx-sandbox-proxy-start \"job-1\" nil %S)))
                                                 (message \"pid %%d\" (process-id p)) (sleep-for 60))"
                                               sock))))
         (pid nil))
    (unwind-protect
        (progn
          (should (drgnx-sandbox-proxy-test--wait
                   (lambda () (with-current-buffer (process-buffer hub)
                                (and (string-match "pid \\([0-9]+\\)\n" (buffer-string))
                                     (setq pid (string-to-number (match-string 1 (buffer-string)))))))))
          (should (drgnx-sandbox-proxy-test--wait (lambda () (file-exists-p sock))))
          (signal-process hub 'SIGKILL)
          (should (drgnx-sandbox-proxy-test--wait
                   (lambda () (not (member (alist-get 'state (process-attributes pid)) '("R" "S" "D")))))))
      (when (and pid (process-attributes pid)) (signal-process pid 'SIGKILL))
      (delete-process hub)
      (kill-buffer (process-buffer hub))
      (delete-directory dir t))))

;;; sandbox-proxy-test.el ends here
