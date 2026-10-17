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
                                             "OPENROUTER_API_KEY" "DRGNX_JOBS_LAUNCHER=detached")
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
       (delete-directory root t))))

(defun drgnx-hub-test--post (url token)
  "POST a small request to the gateway at URL with TOKEN; the status."
  (with-temp-buffer
    (call-process "curl" nil t nil "-s" "-o" "/dev/null" "-w" "%{http_code}" "-H" (concat "Authorization: Bearer " token)
                  "-H" "Content-Type: application/json" "--data" "{\"model\":\"x\"}" (concat url "/v1/messages"))
    (string-to-number (buffer-string))))

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
        (unless (equal (file-name-nondirectory f) "or.log")
          (should-not (string-search "sk-sock-only" (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally f) (buffer-string))))))
      (drgnx-hub-call-sync "shutdown" nil)
      (should (drgnx-hub-test--wait (lambda () (not (process-attributes pid))) 5)))))

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
