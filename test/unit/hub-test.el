;;; hub-test.el --- batch tests: the hub process, its socket, its client, drgnx hub -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-hub)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)

(defmacro drgnx-hub-test--with (&rest body)
  "BODY with drgnx's dirs under ROOT (so the hub's socket is this test's own), a mock OpenRouter on OR-PORT logging
to OR-LOG, OPENROUTER_API_KEY unset."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-hub" t)))
          (or-port (+ 20000 (random 20000))) (or-log (concat root "or.log"))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "HOME=" root "home")
                                             "OPENROUTER_API_KEY" "DRGNX_JOBS_LAUNCHER=detached"
                                             "DRGNX_NO_HUB_START"                 ; these tests start hubs (and stop them)
                                             (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid)))   ; …ending with this Emacs
                                       process-environment))
          (drgnx-ai--keys (make-hash-table :test #'eq)) (auth-sources nil) (drgnx-work-db--handles nil)
          (drgnx-gateway--keys (make-hash-table :test #'eq)) (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-hub--exit-function #'drgnx-hub-stop) (mock nil))
     (unwind-protect
         (progn
           (make-directory (concat root "config") t) (make-directory (concat root "home") t)
           (with-temp-file (concat root "or.eld")
             (prin1 '((:path "/api/v1/messages" :body "{\"usage\":{\"input_tokens\":3,\"output_tokens\":4}}")) (current-buffer)))
           (with-temp-file (concat root "config/ai.eld")
             (prin1 `(:version 1 :providers ((openrouter :name "OR" :kind openai :url ,(format "http://127.0.0.1:%d/api/v1" or-port)
                                                         :key-env "OPENROUTER_API_KEY" :caps (chat) :messages t)))
                    (current-buffer)))
           (setq mock (drgnx-ai-test-mock-llm or-port (concat root "or.eld") or-log))
           ,@body)
       (ignore-errors (drgnx-hub-call-sync "shutdown" nil 2))
       (drgnx-hub-stop)
       (drgnx-hub-disconnect)
       (when mock (delete-process mock))
       (drgnx-work-db-close-all)
       (ignore-errors (delete-file (drgnx-hub-socket)))
       (ignore-errors (delete-directory (concat (drgnx-hub-socket) ".lock") t))
       ;; a hub started as a job: its wrapper writes the exit code just after the hub ends — before the tree goes
       (drgnx-hub-test--wait (lambda () (not (seq-some (lambda (j) (eq (plist-get j :status) 'running)) (drgnx-jobs-list)))) 5)
       (delete-directory root t))))

(defun drgnx-hub-test--post (url token)
  "POST a small request to the gateway at URL with TOKEN; the status.  Asynchronous: the gateway may be this Emacs."
  (let* ((out (generate-new-buffer " *post*" t))
         (p (make-process :name "post" :buffer out :noquery t
                          :command (list "curl" "-s" "--max-time" "10" "-o" "/dev/null" "-w" "%{http_code}"
                                         "-H" (concat "Authorization: Bearer " token) "-H" "Content-Type: application/json"
                                         "--data" "{\"model\":\"x\"}" (concat url "/v1/messages")))))
    (drgnx-hub-test--wait (lambda () (not (process-live-p p))) 12)
    (prog1 (string-to-number (with-current-buffer out (buffer-string))) (kill-buffer out))))

(defun drgnx-hub-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 5)))) (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.02)))
  (funcall pred))

(ert-deftest drgnx-hub/ping-status-and-register-over-the-socket ()
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (should (= (plist-get (drgnx-hub-call-sync "ping" nil) :pid) (emacs-pid)))
    (let ((r (drgnx-hub-call-sync "gateway/register" '(:job "j" :task "t" :agent "a" :chain [["openrouter" "m"]]))))
      (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (plist-get r :token)))
      (should (string-match-p "\\`http://127\\.0\\.0\\.1:[0-9]+\\'" (plist-get r :url))))
    (let ((s (drgnx-hub-call-sync "status" nil)))
      (should (= (plist-get s :registrations) 1))
      (should (integerp (plist-get s :gateway_port))))
    (should (equal (file-modes (file-name-directory (drgnx-hub-socket))) #o700))))

(ert-deftest drgnx-hub/a-stopped-hub-s-shutdown-never-reaches-the-next-one ()
  ;; shutdown exits 0.1 s later: a hub stopped meanwhile (a test's cleanup) must not take the next hub down with it
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (drgnx-hub-call-sync "shutdown" nil)
    (drgnx-hub-stop)
    (drgnx-hub-disconnect)
    (drgnx-hub-serve (drgnx-hub-socket))
    (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]]))
    (drgnx-hub-test--wait #'ignore 0.4)
    (should (drgnx-hub-serving-p))
    (should (= (plist-get (drgnx-hub-call-sync "status" nil) :registrations) 1))))

(ert-deftest drgnx-hub/subscribers-hear-gateway-events ()
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((heard nil) (drgnx-hub-event-functions (list (lambda (e d) (push (cons e d) heard))))
           (r (drgnx-hub-call-sync "gateway/register" (list :agent "a1" :chain [["openrouter" nil]] :keys '(:openrouter "sk-k")))))
      (drgnx-hub-connect)
      (drgnx-hub-test--wait (lambda () drgnx-hub--events))
      ;; the request from another process (curl), so this Emacs serves the gateway meanwhile
      (let ((p (start-process "post" nil "curl" "-s" "-H" (concat "Authorization: Bearer " (plist-get r :token))
                              "--data" "{}" (concat (plist-get r :url) "/v1/messages"))))
        (drgnx-hub-test--wait (lambda () (assoc "request" heard)) 8)
        (ignore-errors (delete-process p)))
      (should (equal (plist-get (cdr (assoc "request" heard)) :agent) "a1")))))

(ert-deftest drgnx-hub/a-restarted-hub-takes-the-same-tokens ()
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let ((token (plist-get (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]])) :token))
          (file (expand-file-name "hub/registrations.eld" (drgnx-state-dir))))
      (drgnx-hub-disconnect)
      (drgnx-hub-stop)
      (should (= (hash-table-count drgnx-gateway--registrations) 0))
      (should (file-exists-p file))
      (should (equal (file-modes file) #o600))
      (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (should-not (string-search token text))
        (should (string-search (secure-hash 'sha256 token) text)))
      (drgnx-hub-serve (drgnx-hub-socket))
      (should (= (hash-table-count drgnx-gateway--registrations) 1))
      (should (gethash (secure-hash 'sha256 token) drgnx-gateway--registrations)))))

(ert-deftest drgnx-hub/registrations-survive-a-torn-write ()
  ;; a file cut off mid-write (the old in-place write, a full disk) is logged and the hub serves; a save writes a
  ;; temporary file and renames it over the old one (a new inode), leaves no temporary file, and is 0600
  (drgnx-hub-test--with
    (let ((file (expand-file-name "hub/registrations.eld" (drgnx-state-dir))) (logged nil))
      (make-directory (file-name-directory file) t)
      (write-region "((\"abc\" :job \"j\" :chain" nil file nil 'silent)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (when fmt (push (apply #'format-message fmt args) logged)) nil)))
        (drgnx-hub-serve (drgnx-hub-socket)))
      (should (seq-some (lambda (m) (string-search "registrations.eld" m)) logged))
      (should (drgnx-hub-call-sync "ping" nil))
      (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]]))
      (let ((inode (file-attribute-inode-number (file-attributes file))))
        (drgnx-hub-call-sync "gateway/register" '(:chain [["openrouter" nil]]))
        (should-not (equal (file-attribute-inode-number (file-attributes file)) inode)))
      (should (equal (directory-files (file-name-directory file) nil "regist") '("registrations.eld")))
      (should (equal (file-modes file) #o600))
      (should (= (length (with-temp-buffer (insert-file-contents file) (read (current-buffer)))) 2)))))

(ert-deftest drgnx-hub/a-second-hub-exits ()
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((out (generate-new-buffer " *hub2*" t))
           (p (make-process :name "hub2" :buffer out :noquery t
                            :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                           "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub" "-f" "drgnx-hub-main"))))
      (drgnx-hub-test--wait (lambda () (not (process-live-p p))) 15)
      (should (eq (process-status p) 'exit))
      (should (= (process-exit-status p) 3))
      (should (string-search "a hub already serves" (with-current-buffer out (buffer-string))))
      (kill-buffer out)))
  ;; a socket file nobody listens on is taken over
  (drgnx-hub-test--with
    (make-directory (file-name-directory (drgnx-hub-socket)) t)
    (write-region "" nil (drgnx-hub-socket) nil 'silent)
    (drgnx-hub-serve (drgnx-hub-socket))
    (should (drgnx-hub-call-sync "ping" nil))))

(ert-deftest drgnx-hub/startup-error-exit-code ()
  ;; 3 says "a hub already serves" (a-second-hub-exits); any other reason a hub cannot start is 1
  (drgnx-hub-test--with
    (let ((state (concat root "state-file")))
      (write-region "" nil state nil 'silent)         ; a state dir that is a plain file: no socket dir under it
      (let* ((process-environment (append (list "XDG_RUNTIME_DIR" (concat "XDG_STATE_HOME=" state)) process-environment))
             (out (generate-new-buffer " *hub-err*" t))
             (rc (call-process (expand-file-name invocation-name invocation-directory) nil out nil "--batch" "-Q"
                               "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub" "-f" "drgnx-hub-main")))
        (should (= rc 1))
        (should (string-search "drgnx hub: " (with-current-buffer out (buffer-string))))
        (kill-buffer out)))))

(ert-deftest drgnx-hub/a-test-hub-exits-with-its-parent ()
  ;; DRGNX_HUB_PARENT_PID (tests only): a hub whose test Emacs is gone stops instead of outliving the test's dir
  (drgnx-hub-test--with
    (let* ((gone (let ((p (start-process "gone" nil "true")))
                   (drgnx-hub-test--wait (lambda () (not (process-live-p p))))
                   (process-id p)))
           (process-environment (cons (format "DRGNX_HUB_PARENT_PID=%d" gone) process-environment))
           (p (make-process :name "orphan-hub" :noquery t
                            :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                           "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub" "-f" "drgnx-hub-main"))))
      (unwind-protect
          (progn
            (should (drgnx-hub-test--wait (lambda () (not (process-live-p p))) 10))
            (should (eql (process-exit-status p) 0))
            (should-not (file-exists-p (drgnx-hub-socket))))
        (ignore-errors (delete-process p))))))

(ert-deftest drgnx-hub/the-hub-outlives-the-emacs-that-started-it ()
  (drgnx-hub-test--with
    (let ((rc (call-process (expand-file-name invocation-name invocation-directory) nil nil nil "--batch" "-Q"
                            "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub"
                            "--eval" "(kill-emacs (if (drgnx-hub-ensure) 0 1))")))
      (should (= rc 0)))
    (should (drgnx-hub-running-p))                    ; the starter is gone; the hub serves
    (let* ((pid (plist-get (drgnx-hub-call-sync "status" nil) :pid))
           (cmdline (with-temp-buffer (insert-file-contents-literally (format "/proc/%d/cmdline" pid)) (buffer-string))))
      (should (/= pid (emacs-pid)))
      (should (string-search "drgnx-hub-main" cmdline))
      ;; keys sent over the socket: in the hub's memory only
      (let ((r (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]] :keys '(:openrouter "sk-sock-only")))))
        (should (= (drgnx-hub-test--post (plist-get r :url) (plist-get r :token)) 200))
        (should (string-search "Bearer sk-sock-only" (with-temp-buffer (insert-file-contents or-log) (buffer-string)))))
      (should-not (string-search "sk-sock" cmdline))
      (dolist (f (directory-files-recursively root "" nil))
        (unless (or (equal (file-name-nondirectory f) "or.log") (not (file-regular-p f)))   ; the socket, without XDG_RUNTIME_DIR
          (should-not (string-search "sk-sock-only" (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally f) (buffer-string))))))
      (drgnx-hub-call-sync "shutdown" nil)
      ;; judged by its socket: where PID 1 never reaps (a CI container) the stopped hub lingers as a zombie
      (should (drgnx-hub-test--wait (lambda () (not (drgnx-hub-running-p))) 5))
      ;; and its job ends: the wrapper records the exit (the tree is removed only then — a CI race)
      (should (drgnx-hub-test--wait (lambda () (memq (plist-get (car (drgnx-jobs-list)) :status) '(exited stopped))) 5)))))

(defun drgnx-hub-test--sigpipe-ignored-p ()
  "Does this Emacs ignore SIGPIPE, as every hub does (Linux: SigIgn in /proc/self/status)?"
  (with-temp-buffer
    (and (ignore-errors (insert-file-contents "/proc/self/status") t)
         (re-search-forward "^SigIgn:[ \t]+\\([0-9a-f]+\\)" nil t)
         (/= 0 (logand (string-to-number (match-string 1) 16) (ash 1 12))))))   ; SIGPIPE is 13

(ert-deftest drgnx-hub/a-client-that-leaves-before-the-answer-is-no-error ()
  ;; a coordination server's notify, a probe: they write and go; the hub's answer must not raise an error (under
  ;; ERT, or with debug-on-error, a filter error ends a batch Emacs).  The hub here is this Emacs: a hub always
  ;; runs with SIGPIPE ignored (`drgnx-hub-ensure'), so this one must too — the runners (bin/drgnx test, check)
  ;; ignore it; a plain `emacs --batch' would be killed by the write instead of seeing its error
  (skip-unless (drgnx-hub-test--sigpipe-ignored-p))
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (dotimes (_ 5)
      (let ((c (make-network-process :name "leaver" :family 'local :service (drgnx-hub-socket) :noquery t)))
        (process-send-string c "{\"id\":7,\"method\":\"status\"}\n{\"method\":\"coord/notify\"}\n")
        (delete-process c)))
    (let ((deadline (+ (float-time) 1))) (while (< (float-time) deadline) (accept-process-output nil 0.05)))
    (should (drgnx-hub-call-sync "ping" nil))))

(ert-deftest drgnx-hub/long-line-and-malformed-answered ()
  ;; a line that is not JSON but names its id is answered with an error (the client never waits for nothing); a
  ;; line over the cap (1 MiB) closes its connection; the hub serves on
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((got "")
           (c (make-network-process :name "raw" :family 'local :service (drgnx-hub-socket) :noquery t :coding 'utf-8-unix
                                    :filter (lambda (_p s) (setq got (concat got s))))))
      (process-send-string c "{\"id\":7,\"method\":\n")
      (should (drgnx-hub-test--wait (lambda () (string-search "\n" got)) 1))
      (let ((answer (json-parse-string got :object-type 'plist)))
        (should (eql (plist-get answer :id) 7))
        (should (stringp (plist-get (plist-get answer :error) :message))))
      ;; 2 MiB without an end of line (the write to a closed connection is an error only where SIGPIPE is ignored,
      ;; as the runner does)
      (when (drgnx-hub-test--sigpipe-ignored-p)
        (ignore-errors (process-send-string c (make-string (* 2 1024 1024) ?x)))
        (should (drgnx-hub-test--wait (lambda () (not (process-live-p c))) 5)))
      (delete-process c))
    (should (drgnx-hub-call-sync "ping" nil))))

(ert-deftest drgnx-hub/an-agent-hanging-up-never-kills-the-hub ()
  ;; the editing Emacs starts the hub without ignoring SIGPIPE: a write to a connection the agent closed must not
  ;; end the hub (exit 141)
  (drgnx-hub-test--with
    (with-temp-file (concat root "or.eld")
      (prin1 '((:path "/api/v1/messages" :chunks ((0 . "data: {}\n\n") (0.2 . "data: {}\n\n") (0.2 . "data: {}\n\n") (0.2 . "data: {}\n\n")
                                                  (0.2 . "data: {}\n\n") (0.2 . "data: {}\n\n") (0.2 . "data: {}\n\n"))))
             (current-buffer)))
    (delete-process mock) (setq mock (drgnx-ai-test-mock-llm or-port (concat root "or.eld") or-log))
    (should (= 0 (call-process "sh" nil nil nil "-c" "trap - PIPE; exec \"$0\" \"$@\""
                               (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                               "-L" (expand-file-name "core" drgnx-dir) "-l" "drgnx-hub"
                               "--eval" "(kill-emacs (if (drgnx-hub-ensure) 0 1))")))
    (let* ((r (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]] :keys '(:openrouter "sk-k"))))
           (port (string-to-number (car (last (split-string (plist-get r :url) ":"))))))
      (dotimes (_ 3)                                                   ; three agents hang up mid-answer
        (let ((got "") (c (open-network-stream "agent" nil "127.0.0.1" port :coding 'binary)))
          (set-process-filter c (lambda (_p s) (setq got (concat got s))))
          (process-send-string c (format "POST /v1/messages HTTP/1.1\r\nAuthorization: Bearer %s\r\nContent-Length: 2\r\n\r\n{}"
                                         (plist-get r :token)))
          (drgnx-hub-test--wait (lambda () (string-search "data:" got)) 5)
          (delete-process c)))
      (sleep-for 2)
      (should (drgnx-hub-running-p)))))

(ert-deftest drgnx-hub/agents-keep-their-address-across-a-restart ()
  ;; a running agent keeps the URL it started with: a restarted hub's gateway must be there
  (drgnx-hub-test--with
    (drgnx-hub-serve (drgnx-hub-socket))
    (let* ((r (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]] :keys '(:openrouter "sk-k"))))
           (url (plist-get r :url)))
      (drgnx-hub-disconnect)
      (drgnx-hub-stop)
      (drgnx-hub-serve (drgnx-hub-socket))
      (should (equal (format "http://127.0.0.1:%d" (drgnx-gateway-port)) url))
      (drgnx-gateway-set-key 'openrouter "sk-k")      ; (a key from the socket lives in memory: sent again)
      (should (= (drgnx-hub-test--post url (plist-get r :token)) 200)))))

(ert-deftest drgnx-hub/a-hub-that-holds-the-lock-is-never-replaced ()
  ;; a live hub too busy to answer a ping within a second keeps its socket
  (drgnx-hub-test--with
    (let ((socket (drgnx-hub-socket)) (other (start-process "busy-hub" nil "sleep" "30")))   ; a live process
      (make-directory (concat socket ".lock") t)
      (write-region (number-to-string (process-id other)) nil (concat socket ".lock/pid") nil 'silent)
      (write-region "" nil socket nil 'silent)                          ; its socket (not answering just now)
      (should-error (drgnx-hub-serve socket))
      (should (file-exists-p socket))
      (delete-process other)
      ;; a lock left by a process that is gone is taken over
      (write-region "999999999" nil (concat socket ".lock/pid") nil 'silent)
      (drgnx-hub-serve socket)
      (should (drgnx-hub-call-sync "ping" nil))
      (should (equal (string-to-number (with-temp-buffer (insert-file-contents (concat socket ".lock/pid")) (buffer-string)))
                     (emacs-pid)))
      ;; stopping removes only what is its own
      (drgnx-hub-disconnect)
      (drgnx-hub-stop)
      (should-not (file-exists-p socket))
      (should-not (file-exists-p (concat socket ".lock"))))))

(ert-deftest drgnx-hub/without-a-runtime-dir-the-socket-is-short-and-private ()
  (drgnx-hub-test--with
    (let ((process-environment (cons "XDG_RUNTIME_DIR" process-environment)))
      (should (string-prefix-p (drgnx-state-dir) (drgnx-hub-socket)))
      (drgnx-hub-serve (drgnx-hub-socket))
      (should (drgnx-hub-call-sync "ping" nil))
      (drgnx-hub-disconnect) (drgnx-hub-stop))
    ;; a state dir so deep the socket path would pass the system's limit (103 bytes on macOS, 107 on Linux)
    (let* ((deep (concat root (make-string 120 ?d) "/"))
           (process-environment (append (list "XDG_RUNTIME_DIR" (concat "XDG_STATE_HOME=" deep)) process-environment)))
      (should (<= (string-bytes (drgnx-hub-socket)) 103))
      (drgnx-hub-serve (drgnx-hub-socket))
      (should (drgnx-hub-call-sync "ping" nil))
      (should (equal (file-modes (file-name-directory (drgnx-hub-socket))) #o700))
      (drgnx-hub-disconnect) (drgnx-hub-stop))))

(ert-deftest drgnx-hub/a-socket-path-of-104-bytes-is-too-long ()
  ;; macOS's limit is 104 bytes with the closing NUL (Linux's 108): 103 is kept, 104 gets the short private path
  (drgnx-hub-test--with
    (let ((at (lambda (bytes)
                ;; a runtime dir whose socket ($RUN/drgnx/hub-HASH.sock, 24 bytes past it) is BYTES long
                (let ((run (expand-file-name (make-string (- bytes 24 (length (directory-file-name root)) 1) ?r) root)))
                  (make-directory run t)
                  (let ((process-environment (cons (concat "XDG_RUNTIME_DIR=" run) process-environment)))
                    (drgnx-hub-socket))))))
      (let ((kept (funcall at 103)))
        (should (eql (string-bytes kept) 103))
        (should (string-prefix-p root kept)))
      (let ((moved (funcall at 104)))
        (should (string-prefix-p (file-name-as-directory (expand-file-name (format "drgnx-hub-%d" (user-uid)) temporary-file-directory))
                                 moved))))))

(ert-deftest drgnx-hub/no-hub-is-started-where-starting-is-off ()
  (drgnx-hub-test--with
    (let ((process-environment (cons "DRGNX_NO_HUB_START=1" process-environment)) (started nil))
      (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest _) (setq started t))))
        (should-error (drgnx-hub-ensure))
        (should-not started))
      (drgnx-hub-serve (drgnx-hub-socket))            ; one that runs is used
      (should (drgnx-hub-ensure)))))

(ert-deftest drgnx-hub/the-cli ()
  (drgnx-hub-test--with
    (let ((cli (lambda (&rest args)
                 (with-temp-buffer
                   (cons (apply #'call-process (expand-file-name "bin/drgnx" drgnx-dir) nil t nil "hub" args) (buffer-string))))))
      (should (= (car (funcall cli "status" "--json")) 1))
      (should (= (car (funcall cli "start")) 0))
      (let ((s (funcall cli "status" "--json")))
        (should (= (car s) 0))
        (should (integerp (plist-get (json-parse-string (cdr s) :object-type 'plist) :gateway_port))))
      (should (= (car (funcall cli "stop")) 0))
      (should (drgnx-hub-test--wait (lambda () (not (drgnx-hub-running-p))) 5)))))

;;; hub-test.el ends here
