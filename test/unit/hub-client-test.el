;;; hub-client-test.el --- batch tests: the editor's v1 client (hello, proofs, deadlines, skew, the line reader) -*- lexical-binding: t -*-
;; Fake hubs (test/fixtures/fake-hub.el) lie about their proof or speak protocol 0; the tests marked "binary" run
;; against Ratatoskr (DRGNX_RATATOSKR_BIN) with its Lisp backend, and skip without it (test/no-skip.eld lists them).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-notice)
(require 'drgnx-hub-client)
(require 'drgnx-hub)
(require 'drgnx-agents-mirror)
(require 'drgnx-coord-mcp)
(require 'drgnx-ai)
(require 'auth-source)                  ; its variables are let-bound below
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/fake-hub" drgnx-dir) nil t)

(defmacro drgnx-hub-client-test--with (&rest body)
  "BODY with drgnx's dirs under ROOT (the hub's socket in ROOT/run/drgnx), the client's state fresh."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-hc" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "XDG_RUNTIME_DIR=" root "run")
                                             (concat "XDG_DATA_HOME=" root "xdg-data") (concat "XDG_CONFIG_HOME=" root "xdg-config")
                                             (concat "XDG_CACHE_HOME=" root "cache") (concat "HOME=" root "home")
                                             "OPENROUTER_API_KEY" "DRGNX_JOBS_LAUNCHER=detached" "DRGNX_NO_HUB_START"
                                             (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid)))
                                       process-environment))
          (drgnx-hub--client nil) (drgnx-hub--events nil) (drgnx-hub--subscribing nil)
          (drgnx-hub--pending (make-hash-table)) (drgnx-hub--last-hello nil) (drgnx-hub-client-proves t)
          (drgnx-hub--ensuring nil) (drgnx-hub--binary-version nil) (drgnx-hub--binary-reading nil)
          (drgnx-hub-event-functions nil) (drgnx-hub-disconnect-functions nil) (drgnx-hub-skew-functions nil)
          (drgnx-hub--clear-text-told nil) (drgnx-hub--keys-had nil))
     (dolist (d '("run" "home" "config" "data")) (with-file-modes #o700 (make-directory (concat root d) t)))
     (unwind-protect (progn ,@body)
       (drgnx-hub-disconnect)
       (delete-directory root t))))

(defun drgnx-hub-client-test--wait (pred &optional what)
  (drgnx-test-wait pred :secs 30 :what (or what "the client's condition")))

(defun drgnx-hub-client-test--calls ()
  "A list to collect callbacks' (RESULT ERROR) in, and the callback that pushes onto it (newest first)."
  (let ((cell (list nil)))
    (cons cell (lambda (r e) (setcar cell (cons (list r e) (car cell)))))))

;;;; Ratatoskr (the binary tests)

(defun drgnx-hub-client-test--bin ()
  "Ratatoskr for the binary tests: DRGNX_RATATOSKR_BIN when it is an absolute executable, else nil."
  (let ((b (getenv "DRGNX_RATATOSKR_BIN")))
    (and b (file-name-absolute-p b) (file-executable-p b) (not (file-directory-p b)) b)))

(defvar drgnx-hub-client-test--serve-fn nil
  "A function (ROOT) → (BINARY ARG…) that replaces the binary `with-ratatoskr' serves with, and adds arguments.")

(defmacro drgnx-hub-client-test--with-ratatoskr (&rest body)
  "BODY with Ratatoskr serving ROOT (`drgnx-hub-client-test--with'), its Lisp backend this checkout's; skipped
without the binary."
  (declare (indent 0))
  `(drgnx-hub-client-test--with
     (skip-unless (drgnx-hub-client-test--bin))
     (let* ((process-environment (append (list (concat "DRGNX_DIR=" (directory-file-name drgnx-dir)) "RATATOSKR_SUPERVISOR=none"
                                               (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory)))
                                         process-environment))
            (hub (make-process :name "ratatoskr" :noquery t :connection-type 'pipe :buffer (generate-new-buffer " *ratatoskr*")
                               :sentinel (lambda (p _event) (unless (process-live-p p) (process-put p :done t)))
                               :command (let ((s (if drgnx-hub-client-test--serve-fn
                                                     (funcall drgnx-hub-client-test--serve-fn root)
                                                   (list (drgnx-hub-client-test--bin)))))
                                          (append (list (car s) "serve" "--foreground"
                                                        "--parent-pid" (number-to-string (emacs-pid)))
                                                  (cdr s))))))
       (unwind-protect
           (progn (drgnx-hub-client-test--wait #'drgnx-hub-running-p "Ratatoskr answers a ping")
                  ,@body)
         (drgnx-hub-disconnect)
         (when (process-live-p hub) (signal-process hub 'term))
         (ignore-errors (drgnx-test-wait (lambda () (process-get hub :done)) :secs 10 :what "Ratatoskr ends"))
         (when (process-live-p hub) (signal-process hub 'kill))
         (kill-buffer (process-buffer hub))))))

(defun drgnx-hub-client-test--backend-up ()
  "Wait for Ratatoskr's Lisp backend to run."
  (drgnx-hub-client-test--wait
   (lambda () (equal (plist-get (plist-get (drgnx-hub-call-sync "status" nil 10) :backend) :state) "running"))
   "the Lisp backend runs"))

(defun drgnx-hub-client-test--mock-profile (root)
  "The profile \"mock\" (test/fixtures/mock-acp.el) in ROOT's agents.eld."
  (with-temp-file (concat root "config/agents.eld")
    (prin1 (list :profiles (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir)
                                                             (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                             "-l" (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir)))))
           (current-buffer))))

(ert-deftest drgnx-hub-client/proves-itself-and-is-user ()
  ;; binary: the hello's proof makes the connection user class, and Ratatoskr's proof back checks out
  (drgnx-hub-client-test--with-ratatoskr
    (should (natnump (plist-get (drgnx-hub-call-sync "ping" nil 10) :pid)))
    (should (equal (plist-get drgnx-hub--last-hello :class) "user"))
    (should (process-get drgnx-hub--client :drgnx-proven))
    (should (drgnx-hub-has-method-p "agents/list"))
    (should-not (drgnx-hub-has-method-p "no/such-method"))))

(ert-deftest drgnx-hub-client/ping-probe-and-coord-mcp-skip-the-challenge ()
  ;; binary: the challenge is the first line on every connection; the probe and a coordination server's client read
  ;; past it to the answer
  (drgnx-hub-client-test--with-ratatoskr
    (should (drgnx-hub--ping-socket (drgnx-hub-socket)))
    (drgnx-hub-client-test--backend-up)
    (drgnx-hub-disconnect)
    (let ((drgnx-hub-client-proves nil))
      (should (listp (drgnx-coord-mcp--hub-agents))))))

(ert-deftest drgnx-hub-client/coord-mcp-stays-service-class ()
  ;; binary (review C1): a coordination server started by an agent never reads the cap, so it stays service class
  (drgnx-hub-client-test--with-ratatoskr
    (let ((inside nil))
      (cl-letf (((symbol-function 'drgnx-gc-batch-setup) #'ignore)
                ((symbol-function 'drgnx-coord-mcp--parent) #'ignore)
                ((symbol-function 'drgnx-mcp-serve)
                 (lambda (&rest _)
                   (drgnx-hub-call-sync "ping" nil 10)
                   (setq inside (plist-get drgnx-hub--last-hello :class)))))
        (drgnx-coord-mcp-main))
      (should (equal inside "service")))
    (drgnx-hub-disconnect)
    (drgnx-hub-call-sync "ping" nil 10)
    (should (equal (plist-get drgnx-hub--last-hello :class) "user"))))

(ert-deftest drgnx-hub-client/outside-coord-server-still-works ()
  ;; binary: an outside agent's coordination server tells the hub with a raw `coord/notify' (service class, no
  ;; hello): never refused, while a service line that asks for keys is
  (drgnx-hub-client-test--with-ratatoskr
    (let ((refused (lambda () (plist-get (plist-get (drgnx-hub-call-sync "status" nil 10) :refusals) :count))))
      (should (eql (funcall refused) 0))
      (let ((c (make-network-process :name "raw" :family 'local :service (drgnx-hub-socket) :noquery t)))
        (process-send-string c "{\"id\":1,\"method\":\"gateway/keys\",\"params\":{\"keys\":{}}}\n")
        (drgnx-hub-client-test--wait (lambda () (eql (funcall refused) 1)) "the service's gateway/keys is refused")
        (delete-process c))
      (drgnx-coord-mcp--notify-hub)
      (drgnx-test-pause 0.5)
      (should (eql (funcall refused) 1)))))

(ert-deftest drgnx-hub-client/mirror-over-ratatoskr ()
  ;; binary + the Lisp backend: a session the hub starts reaches this Emacs's mirror through Ratatoskr's relay
  (drgnx-hub-client-test--with-ratatoskr
    (drgnx-hub-client-test--mock-profile root)
    (drgnx-hub-client-test--backend-up)
    (let ((drgnx-agents--sessions nil) (drgnx-agents-profiles nil))
      (unwind-protect
          (let ((id (plist-get (drgnx-hub-call-sync "agents/start" (list :profile "mock" :cwd root) 30) :id)))
            (should (stringp id))
            (drgnx-agents-mirror-sync)
            (drgnx-hub-client-test--wait (lambda () (drgnx-agents-mirror--find id)) "the mirror of the hub's session")
            (drgnx-hub-call-sync "agents/kill" (list :id id) 10))
        (drgnx-agents-mirror-stop)))))

(defvar drgnx-hub-client-test--traffic nil "(METHOD PARAMS ERROR) of each answered call, newest first.")

(defun drgnx-hub-client-test--record (orig method params callback &rest keys)
  "Around `drgnx-hub-call': the call goes as it would, with FULL, so its error's code is recorded."
  (apply orig method params
         (lambda (r e)
           (push (list method params e) drgnx-hub-client-test--traffic)
           (funcall callback r (if (and (consp e) (not (plist-get keys :full))) (plist-get e :message) e)))
         :full t (cl-loop for (k v) on keys by #'cddr unless (eq k :full) append (list k v))))

(defun drgnx-hub-client-test--cli (&rest args)
  "(STATUS . OUTPUT) of bin/drgnx ARGS."
  (with-temp-buffer
    (cons (apply #'call-process (expand-file-name "bin/drgnx" drgnx-dir) nil t nil args) (buffer-string))))

(defun drgnx-hub-client-test--answered (method)
  (cl-count method drgnx-hub-client-test--traffic :key #'car :test #'equal))

(ert-deftest drgnx-hub-client/editor-traffic-over-ratatoskr ()
  ;; binary + the Lisp backend (review I6): the calls the cockpit, the job UI, the agents mirror and `drgnx job' make,
  ;; with the params their own code builds, over a store with a proposed job, a card and a mock-acp session: none is
  ;; refused for its params, and none fails inside
  (let ((load-path (append (list (expand-file-name "modules/tools" drgnx-dir) (expand-file-name "modules/ui" drgnx-dir))
                           load-path)))
    (dolist (f '(drgnx-job drgnx-job-ui drgnx-cockpit-cards drgnx-cockpit-feed drgnx-agents-ui)) (require f)))
  (drgnx-hub-client-test--with-ratatoskr
    (drgnx-hub-client-test--mock-profile root)
    (drgnx-hub-client-test--backend-up)
    (let ((plan (concat root "plan.md")) (drgnx-hub-client-test--traffic nil)
          (drgnx-agents--sessions nil) (drgnx-agents-profiles nil) job card)
      (with-temp-file plan
        (insert "# Two tasks\n\n**Repo:** " root "repo\n\n### Task 1: Do the thing\n\n**Role:** implement\n\nNothing.\n\n"
                "### Task 2: Check the thing\n\n**Role:** review\n\nNeeds Task 1.\n"))
      ;; `drgnx job': its own process, its own hello (a CLI: user class)
      (let ((r (drgnx-hub-client-test--cli "job" "propose" plan)))
        (should (equal r (cons 0 (cdr r))))
        (should (let ((case-fold-search nil)) (string-match "drgnx job approve \\([^ \n]+\\)" (cdr r))))
        (setq job (match-string 1 (cdr r))))
      (let ((r (drgnx-hub-client-test--cli "job" "status" "--json"))) (should (equal r (cons 0 (cdr r)))))
      (let ((r (drgnx-hub-client-test--cli "job" "status" job))) (should (equal r (cons 0 (cdr r)))))
      (advice-add 'drgnx-hub-call :around #'drgnx-hub-client-test--record)
      ;; the filter the cockpit's graph would hold (not loaded here)
      (cl-letf* ((filter nil) ((symbol-function 'drgnx-cockpit-cards-job) (lambda () filter)))
        (unwind-protect
            (progn
              ;; the job UI: propose (with this Emacs's gate), list, reject
              (let ((second nil))
                (cl-letf (((symbol-function 'drgnx-job-ui-show) (lambda (id) (setq second id))))
                  (drgnx-job-ui-start plan))
                (drgnx-job-ui-status)
                (drgnx-job-ui-stop second))
              ;; a card of the CLI's job, and the cockpit's parts: every job, then the job with its decisions
              (let ((db (sqlite-open (concat root "data/work.db"))))
                (sqlite-execute db "insert into card (job, task, kind, title, data, state, at) values (?, null, 'note', 'a note', '{}', 'open', 1.5)"
                                (list job))
                (sqlite-close db))
              (drgnx-cockpit-cards-refresh)
              (setq filter job)
              (drgnx-cockpit-cards-refresh)
              (drgnx-hub-client-test--wait (lambda () (>= (drgnx-hub-client-test--answered "job/status") 3)) "the cockpit's answers")
              (setq card (seq-find (lambda (c) (equal (plist-get c :kind) "note"))
                                   (plist-get (drgnx-hub-call-sync "job/status" (list :id job) 10) :cards)))
              (should card)
              (drgnx-cockpit-cards--act job card "dismiss")
              (drgnx-hub-client-test--wait (lambda () (>= (drgnx-hub-client-test--answered "job/card") 1)) "the card's answer")
              ;; a durable session and its mirror: the agents UI starts it, the mirror and the feed drive it
              (cl-letf (((symbol-function 'drgnx-agents-ui--cwd) (lambda () root))) (drgnx-agents-ui-new-durable "mock"))
              (let ((m (drgnx-hub-client-test--wait (lambda () (seq-find #'drgnx-agent-session-remote drgnx-agents--sessions))
                                                    "the mirror")))
                (drgnx-hub-client-test--wait (lambda () (eq (drgnx-agent-session-status m) 'idle)) "the mirror is idle")
                (drgnx-agents-send m "hello mirror")
                (drgnx-cockpit-feed--queue (drgnx-agent-session-remote m) "and again" #'ignore)
                (drgnx-agents-deliver-queue m)
                (drgnx-hub-client-test--wait (lambda () (and (>= (drgnx-hub-client-test--answered "agents/send") 2)
                                                             (>= (drgnx-hub-client-test--answered "agents/do") 1)))
                                             "the mirror's answers")
                (drgnx-agents-kill m)
                (drgnx-hub-client-test--wait (lambda () (>= (drgnx-hub-client-test--answered "agents/kill") 1)) "the kill's answer")))
          (advice-remove 'drgnx-hub-call #'drgnx-hub-client-test--record)
          (drgnx-agents-mirror-stop)
          (drgnx-hub-disconnect)
          (drgnx-timer-cancel-owner :core)))
      (dolist (m '("job/propose" "job/status" "job/stop" "job/card" "agents/start" "agents/list" "agents/get"
                   "agents/send" "agents/do" "agents/kill"))
        (should (member m (mapcar #'car drgnx-hub-client-test--traffic))))
      (should-not (seq-filter (lambda (c) (member (plist-get (nth 2 c) :code) '("invalid-params" "internal")))
                              drgnx-hub-client-test--traffic)))))

;;;; Fake hubs

(defmacro drgnx-hub-client-test--with-fake (args &rest body)
  "BODY with HUB a fake hub (`drgnx-fake-hub-start' ARGS) on this test's socket."
  (declare (indent 1))
  `(drgnx-hub-client-test--with
     (let ((hub (apply #'drgnx-fake-hub-start (drgnx-hub-socket) (list ,@args))))
       (unwind-protect (progn ,@body)
         (drgnx-hub-disconnect)
         (drgnx-fake-hub-stop hub)))))

(ert-deftest drgnx-hub-client/a-wrong-hub-proof-gets-no-keys ()
  ;; a hub that answers the hello without the cap's proof is closed: the calls waiting fail once, no key reaches it,
  ;; the user is told
  (drgnx-hub-client-test--with-fake (:mode 'wrong-proof)
    (let ((keys (drgnx-hub-client-test--calls)) (other (drgnx-hub-client-test--calls)))
      (unwind-protect
          (progn
            (drgnx-hub-call "gateway/keys" (list :keys (list :openrouter "sk-never-sent")) (cdr keys))
            (drgnx-hub-call "agents/list" nil (cdr other))
            (drgnx-hub-client-test--wait (lambda () (and (car (car keys)) (car (car other)))) "both calls fail")
            (drgnx-test-pause 0.2)
            (dolist (c (list keys other))
              (should (= (length (car (car c))) 1))
              (should (string-match-p "did not prove it read .*\\.cap" (format "%s" (cadr (car (car (car c))))))))
            (should-not (member "gateway/keys" (drgnx-fake-hub-methods hub)))
            (should-not (string-search "sk-never-sent" (prin1-to-string (drgnx-fake-hub-lines hub))))
            (should-not (process-live-p drgnx-hub--client))
            (should (gethash '(hub . unproven) drgnx-notice--table)))
        (drgnx-notice-clear 'hub 'unproven)))))

(ert-deftest drgnx-hub-client/a-legacy-hub-gets-no-keys ()
  ;; a hub of before protocol 1 (no challenge) gets the calls, never a key: gateway/keys is refused here, and
  ;; gateway/register goes without its keys
  (drgnx-hub-client-test--with-fake (:mode 'legacy)
    (let ((keys (drgnx-hub-client-test--calls)) (reg (drgnx-hub-client-test--calls)) (other (drgnx-hub-client-test--calls))
          (skews nil))
      (add-hook 'drgnx-hub-skew-functions (lambda (skew _reply) (push skew skews)))
      (drgnx-hub-call "gateway/keys" (list :keys (list :openrouter "sk-legacy")) (cdr keys))
      (drgnx-hub-call "gateway/register" (list :chain [["openrouter" nil]] :keys (list :openrouter "sk-legacy")) (cdr reg))
      (drgnx-hub-call "agents/list" nil (cdr other))
      (drgnx-hub-client-test--wait (lambda () (and (car (car keys)) (car (car reg)) (car (car other)))) "the three answers")
      (should (equal (car (car keys)) '((nil "keys go only to a hub that proved itself"))))
      (should (equal (car (car reg)) '((t nil))))
      (should (equal (car (car other)) '((t nil))))
      (should-not (member "gateway/keys" (drgnx-fake-hub-methods hub)))
      (should (member "gateway/register" (drgnx-fake-hub-methods hub)))
      (should-not (string-search "sk-legacy" (prin1-to-string (drgnx-fake-hub-lines hub))))
      (should (eq drgnx-hub--last-hello :legacy))
      (should (equal skews '(restart-when-idle)))
      (should-not (drgnx-hub-has-method-p "agents/list")))))

(ert-deftest drgnx-hub-client/calls-wait-for-hello ()
  ;; nothing but the probe and the hello goes before the hub's answer to the hello
  (drgnx-hub-client-test--with-fake (:hold-hello t)
    (let ((got (drgnx-hub-client-test--calls)))
      (drgnx-hub-call "agents/list" nil (cdr got))
      (drgnx-hub-client-test--wait (lambda () (member "hello" (drgnx-fake-hub-methods hub))) "the hello")
      (drgnx-test-pause 0.3)
      (should (equal (drgnx-fake-hub-methods hub) '("ping" "hello")))
      (should-not (car (car got)))
      (drgnx-fake-hub-release hub)
      (drgnx-hub-client-test--wait (lambda () (car (car got))) "the call's answer")
      (should (equal (car (car got)) '((t nil))))
      (should (equal (drgnx-fake-hub-methods hub) '("ping" "hello" "agents/list")))
      (should (equal (plist-get drgnx-hub--last-hello :class) "user"))
      (should (process-get drgnx-hub--client :drgnx-proven)))))

(ert-deftest drgnx-hub-client/deadline-and-disconnect-fire-once ()
  ;; a call's callback runs exactly once: at its deadline, or when its connection goes — never again after
  (drgnx-test-with-clock ()
    (drgnx-hub-client-test--with-fake (:silent '("slow"))
      (let ((a (drgnx-hub-client-test--calls)) (b (drgnx-hub-client-test--calls)))
        (drgnx-hub-call "slow" nil (cdr a) :deadline 5)
        (drgnx-hub-client-test--wait (lambda () (member "slow" (drgnx-fake-hub-methods hub))) "the call reaches the hub")
        (drgnx-test-advance 5)
        (should (equal (car (car a)) '((nil "the drgnx hub did not answer slow in time"))))
        (drgnx-test-advance 60)
        (should (= (length (car (car a))) 1))
        (drgnx-hub-call "slow" nil (cdr b) :deadline 5 :full t)
        (drgnx-hub-client-test--wait (lambda () (= (cl-count "slow" (drgnx-fake-hub-methods hub) :test #'equal) 2))
                                     "the second call reaches the hub")
        (drgnx-fake-hub-close-clients hub)
        (drgnx-hub-client-test--wait (lambda () (car (car b))) "the closed connection fails the call")
        (should (equal (car (car b)) '((nil (:message "the drgnx hub's connection closed")))))
        (drgnx-test-advance 60)
        (should (= (length (car (car b))) 1))
        (should (= (length (car (car a))) 1))))))

(ert-deftest drgnx-hub-client/a-late-challenge-is-read-not-taken-for-legacy ()
  ;; review S2: Emacs was busy past the challenge wait, so its timer runs before the filter reads the challenge that
  ;; is already in the socket; the connection still ends up proven (not `legacy', where every user call is refused)
  (drgnx-test-with-clock ()
    (drgnx-hub-client-test--with-fake ()
      (let ((got (drgnx-hub-client-test--calls)))
        (drgnx-hub-call "agents/list" nil (cdr got))
        (let ((conn drgnx-hub--client))
          (stop-process conn)                   ; this Emacs reads nothing from it: busy
          (drgnx-hub-client-test--wait (lambda () (member "ping" (drgnx-fake-hub-methods hub))) "the hub's challenge is sent")
          (continue-process conn)
          (drgnx-test-advance drgnx-hub--challenge-wait)  ; the timer, before any read
          (drgnx-hub-client-test--wait (lambda () (car (car got))) "the call's answer")
          (should (equal (car (car got)) '((t nil))))
          (should (eq drgnx-hub--client conn))
          (should (process-get conn :drgnx-proven))
          (should (equal (plist-get drgnx-hub--last-hello :class) "user")))))))

(ert-deftest drgnx-hub-client/a-hub-that-says-nothing-is-closed-not-legacy ()
  ;; review S2: no challenge and no probe answer within the wait: the connection is closed and its calls fail once;
  ;; it is never `legacy'
  (drgnx-test-with-clock ()
    (drgnx-hub-client-test--with-fake (:mode 'legacy :silent '("ping"))
      (let ((got (drgnx-hub-client-test--calls)))
        (drgnx-hub-call "agents/list" nil (cdr got))
        (let ((conn drgnx-hub--client))
          (drgnx-hub-client-test--wait (lambda () (member "ping" (drgnx-fake-hub-methods hub))) "the probe reaches the hub")
          (drgnx-test-advance drgnx-hub--challenge-wait)
          (should (= (length (car (car got))) 1))
          (should (string-match-p "sent nothing within" (cadr (car (car (car got))))))
          (should-not (process-live-p conn))
          (should-not (eq drgnx-hub--last-hello :legacy))
          (should-not (member "agents/list" (drgnx-fake-hub-methods hub))))))))

;;;; This Emacs's own hub

(defmacro drgnx-hub-client-test--in-process (&rest body)
  "BODY with this Emacs serving the hub (the Lisp backend's tests: keys never leave the process)."
  (declare (indent 0))
  `(drgnx-hub-client-test--with
     (let ((drgnx-ai--keys (make-hash-table :test #'eq)) (auth-sources nil) (drgnx-work-db--handles nil)
           (drgnx-gateway--keys (make-hash-table :test #'eq)) (drgnx-gateway--registrations (make-hash-table :test #'equal))
           (drgnx-hub--exit-function #'drgnx-hub-stop))
       (unwind-protect (progn (drgnx-hub-serve (drgnx-hub-socket)) ,@body)
         (drgnx-hub-disconnect)
         (drgnx-hub-stop)
         (drgnx-work-db-close-all)))))

(ert-deftest drgnx-hub-client/a-hub-in-this-emacs-counts-as-proven ()
  (drgnx-hub-client-test--in-process
    (should (eq (drgnx-hub-call-sync "gateway/keys" (list :keys (list :openrouter "sk-here")) 5) t))
    (should (equal (gethash 'openrouter drgnx-gateway--keys) "sk-here"))
    (should (process-get drgnx-hub--client :drgnx-proven))
    (should-not drgnx-hub--last-hello)))

(defvar drgnx-hub-client-test--timers nil "The keys `drgnx-timer-start' was given.")
(defun drgnx-hub-client-test--note-timer (key &rest _) (push key drgnx-hub-client-test--timers))

(ert-deftest drgnx-hub-client/an-in-process-hub-is-not-waited-for ()
  ;; review I13: an in-process Lisp hub never sends a challenge, so the client does not wait for one
  (drgnx-hub-client-test--in-process
    (let ((drgnx-hub-client-test--timers nil) (t0 (float-time)))
      (advice-add 'drgnx-timer-start :before #'drgnx-hub-client-test--note-timer)
      (unwind-protect (should (natnump (plist-get (drgnx-hub-call-sync "ping" nil 5) :pid)))
        (advice-remove 'drgnx-timer-start #'drgnx-hub-client-test--note-timer))
      (should (< (- (float-time) t0) 0.1))
      (should-not (seq-find (lambda (k) (and (consp k) (eq (car k) 'hub-challenge))) drgnx-hub-client-test--timers)))))

;;;; Skew

(ert-deftest drgnx-hub-client/skew-rules ()
  (cl-letf (((symbol-function 'drgnx-hub-client-binary-version) (lambda (&rest _) "abc")))
    (let ((ok (list :proto 1 :proto_min 1 :records 2 :drgnx_version "abc" :schema drgnx-work-db-schema-version)))
      (dolist (row `((:legacy restart-when-idle)
                     (,ok ok)
                     (,(append '(:schema 0) ok) ok)                  ; no work.db yet
                     (,(append '(:proto 0) ok) incompatible)
                     (,(append '(:proto nil) ok) incompatible)
                     (,(append '(:proto_min 2) ok) incompatible)
                     (,(append '(:records 1) ok) restart-when-idle)
                     (,(append '(:drgnx_version "def") ok) restart-when-idle)
                     (,(append (list :schema (1+ drgnx-work-db-schema-version)) ok) restart-when-idle)
                     (,(append (list :schema (1- drgnx-work-db-schema-version)) ok) restart-when-idle)))
        (should (equal (list (car row) (drgnx-hub-skew (car row))) row)))))
  ;; no binary on disk: its version is not compared
  (cl-letf (((symbol-function 'drgnx-hub-client-binary-version) #'ignore))
    (should (eq (drgnx-hub-skew (list :proto 1 :proto_min 1 :records 2 :drgnx_version "def" :schema 6)) 'ok))))

(ert-deftest drgnx-hub-client/records-pause-the-mirror ()
  ;; a hub that sends another record layout is not mirrored until it changes
  (drgnx-hub-client-test--with-fake (:records 1)
    (let ((drgnx-agents--sessions nil))
      (unwind-protect
          (progn
            (drgnx-agents-mirror-sync)
            (drgnx-hub-client-test--wait (lambda () drgnx-agents-mirror--paused) "the mirror pauses")
            (drgnx-agents-mirror--event "agent" (list :id "s-1" :seq 1 :session (list :id "s-1" :name "x")))
            (should-not drgnx-agents--sessions)
            (drgnx-agents-mirror--skew 'ok (list :records 2))
            (should-not drgnx-agents-mirror--paused))
        (drgnx-agents-mirror-stop)))))

;;;; The line reader

(defvar drgnx-hub-client-test--searched 0 "Characters `string-search' and `string-match' were given to look through.")

(defun drgnx-hub-client-test--count-search (orig needle haystack &optional start)
  (cl-incf drgnx-hub-client-test--searched (- (length haystack) (or start 0)))
  (funcall orig needle haystack start))

(defun drgnx-hub-client-test--count-match (orig regexp string &optional start inhibit-modify)
  (cl-incf drgnx-hub-client-test--searched (- (length string) (or start 0)))
  (funcall orig regexp string start inhibit-modify))

(ert-deftest drgnx-hub-client/only-the-new-chunk-is-searched ()
  ;; HUB-LINES-1, PERF-M3: a long line in many chunks is searched once per chunk, never from its start again
  (let ((p (make-pipe-process :name "drgnx-lines" :noquery t)) (got nil) (drgnx-hub-client-test--searched 0)
        (chunk (make-string 1000 ?x)) (n 300))
    (unwind-protect
        (progn
          (advice-add 'string-search :around #'drgnx-hub-client-test--count-search)
          (advice-add 'string-match :around #'drgnx-hub-client-test--count-match)
          (unwind-protect
              (progn (dotimes (_ n) (drgnx-hub--lines p chunk (lambda (j) (push j got))))
                     (drgnx-hub--lines p "\n{\"a\":1}\n{\"b\":" (lambda (j) (push j got)))
                     (drgnx-hub--lines p "2}\n" (lambda (j) (push j got))))
            (advice-remove 'string-search #'drgnx-hub-client-test--count-search)
            (advice-remove 'string-match #'drgnx-hub-client-test--count-match))
          (should (equal (nreverse got) '((:a 1) (:b 2))))
          (should (< drgnx-hub-client-test--searched (* 2 n (length chunk)))))
      (delete-process p))))

(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-hub-client/a-failing-callback-does-not-drop-the-rest-of-the-chunk ()
  ;; each answer's callback runs in the guard: the answers after it in the chunk, and its open line, still go on
  (drgnx-notice-test-with-model
    (let ((p (make-pipe-process :name "drgnx-settle" :noquery t)) (drgnx-hub--pending (make-hash-table)) (got nil))
      (unwind-protect
          (progn
            (puthash 1 (list :cb (lambda (_r _e) (error "Bad data")) :conn p :method "job/status") drgnx-hub--pending)
            (dolist (id '(2 3)) (puthash id (list :cb (lambda (r _e) (push r got)) :conn p :method "ping") drgnx-hub--pending))
            (funcall (drgnx-guard-wrap #'drgnx-hub--client-filter "hub connection") p
                     "{\"id\":1,\"result\":{\"x\":1}}\n{\"id\":2,\"result\":{\"a\":2}}\n{\"id\":3,\"res")
            (should (equal got '((:a 2))))
            (drgnx-hub--client-filter p "ult\":{\"b\":3}}\n")
            (should (equal got '((:b 3) (:a 2))))
            (should (equal (mapcar (lambda (n) (plist-get n :text)) (drgnx-notices :source 'guard))
                           '("hub answer job/status: Bad data"))))
        (delete-process p)))))

(ert-deftest drgnx-hub-client/a-failing-should-in-a-callback-fails-its-test ()
  ;; the guard around each answer's callback lets ERT's failure through
  (let* ((drgnx-hub--pending (make-hash-table))
         (inner (make-ert-test :name 'drgnx-hub-client-test--inner
                               :body (lambda ()
                                       (puthash 1 (list :cb (lambda (_r _e) (should nil)) :method "ping") drgnx-hub--pending)
                                       (drgnx-hub--settle 1 '(:ok t) nil)))))
    (should (ert-test-failed-p (ert-run-test inner)))))

;;;; Starting Ratatoskr, and Hub: Restart Now

(defun drgnx-hub-client-test--stub (root body)
  "A /bin/sh script in ROOT that runs BODY; its name."
  (let ((f (concat root "stub-ratatoskr")))
    (with-temp-file f (insert "#!/bin/sh\n" body "\n"))
    (set-file-modes f #o755)
    f))

(defun drgnx-hub-client-test--lines (file)
  (and (file-exists-p file) (with-temp-buffer (insert-file-contents file) (split-string (buffer-string) "\n" t))))

(ert-deftest drgnx-hub-client/ensure-is-one-async-process ()
  ;; the hub is started by one `ratatoskr ensure --timeout 5', which does not block the caller; no Emacs starts
  (drgnx-hub-client-test--with
    (let* ((log (concat root "stub.log")) (done 'waiting)
           (process-environment
            (cons (concat "DRGNX_RATATOSKR_BIN="
                          (drgnx-hub-client-test--stub root (format "echo \"$* emacs=$DRGNX_EMACS dir=$DRGNX_DIR\" >> '%s'" log)))
                  process-environment)))
      (drgnx-hub--ensure-running (lambda (err) (setq done err)))
      (should (eq done 'waiting))
      (drgnx-hub-client-test--wait (lambda () (not (eq done 'waiting))) "ensure ends")
      (should-not done)
      (should (equal (drgnx-hub-client-test--lines log)
                     (list (format "ensure --timeout 5 emacs=%s dir=%s" (expand-file-name invocation-name invocation-directory)
                                   (directory-file-name drgnx-dir)))))
      (should-not drgnx-hub--ensuring)
      (should-not (string-search "--batch" (or (car (drgnx-hub-client-test--lines log)) ""))))))

(ert-deftest drgnx-hub-client/ensure-says-why-it-failed ()
  (drgnx-hub-client-test--with
    (let* ((process-environment
            (cons (concat "DRGNX_RATATOSKR_BIN=" (drgnx-hub-client-test--stub root "echo 'ratatoskr: no way' >&2; exit 1"))
                  process-environment))
           (err (should-error (drgnx-hub-ensure))))
      (should (string-search "no way" (error-message-string err))))))

(ert-deftest drgnx-hub-client/ensure-never-waits-in-a-daemon-path ()
  (drgnx-hub-client-test--with
    (let ((process-environment
           (cons (concat "DRGNX_RATATOSKR_BIN=" (drgnx-hub-client-test--stub root "exec sleep 3")) process-environment))
          (inhibit-interaction t) (t0 (float-time)))
      (unwind-protect
          (progn
            (should-not (drgnx-hub-ensure))
            (should (< (- (float-time) t0) 1.0))
            (should (process-live-p drgnx-hub--ensuring)))
        (when (process-live-p drgnx-hub--ensuring) (delete-process drgnx-hub--ensuring))
        (drgnx-timer-cancel 'hub-ensure)))))

(ert-deftest drgnx-hub-client/no-binary-says-how-to-build ()
  (drgnx-hub-client-test--with
    (let ((process-environment (cons "DRGNX_RATATOSKR_BIN" process-environment)))
      (dolist (f '(drgnx-hub-ensure drgnx-hub-restart-now))
        ;; `error' quotes as `text-quoting-style' says: curved under a UTF-8 locale (macOS CI), grave elsewhere
        (should (string-search (format-message "Ratatoskr is not built: run `drgnx runtime build'")
                               (error-message-string (should-error (funcall f)))))))))

(ert-deftest drgnx-hub-client/the-first-hello-carries-the-binary-version ()
  ;; R-T17-2: the hello waits for the binary's version read, which the first connection of an Emacs starts
  (drgnx-hub-client-test--with-fake ()
    (let ((process-environment
           (cons (concat "DRGNX_RATATOSKR_BIN=" (drgnx-hub-client-test--stub root "echo '{\"commit\":\"abc123\"}'"))
                 process-environment)))
      (drgnx-hub-call "agents/list" nil #'ignore)
      (drgnx-hub-client-test--wait (lambda () (member "agents/list" (drgnx-fake-hub-methods hub))) "the call goes")
      (let ((hello (seq-find (lambda (l) (equal (plist-get l :method) "hello")) (drgnx-fake-hub-lines hub))))
        (should (equal (plist-get (plist-get hello :params) :drgnx_version) "abc123"))))))

(ert-deftest drgnx-hub-client/a-version-read-whose-child-has-exited-still-holds-the-hello ()
  ;; A fast `version --json' child is reaped (no longer live) before its sentinel stores the commit: the hello waits
  ;; for the read to end (its sentinel, or the 2 s expiry), not for the child's exit (Fedora CI: a hello without
  ;; drgnx_version when the challenge came in between)
  (let* ((process-environment (cons "DRGNX_RATATOSKR_BIN" process-environment))
         (drgnx-hub--binary-version nil)
         (p (make-process :name "drgnx-test-version" :command '("true") :noquery t :connection-type 'pipe
                          :sentinel #'ignore))
         (drgnx-hub--binary-reading p)
         (ran 0))
    (while (process-live-p p) (accept-process-output p 0.01))
    (drgnx-hub--with-binary-version (lambda () (cl-incf ran)))
    (should (= ran 0))
    (drgnx-hub--version-read-ended p)
    (should (= ran 1))))

(ert-deftest drgnx-hub-client/a-current-hello-clears-the-restart-notice ()
  ;; the notice is a condition: a hub that comes back from the binary's own commit takes it away
  (drgnx-hub-client-test--with-fake ()
    (let ((process-environment
           (cons (concat "DRGNX_RATATOSKR_BIN=" (drgnx-hub-client-test--stub root "echo '{\"commit\":\"fake\"}'"))
                 process-environment)))
      (unwind-protect
          (progn
            (drgnx-notify 'hub 'warn "drgnx was updated" :id 'restart-when-idle :life 'condition :command 'hub-restart-now)
            (should (gethash '(hub . restart-when-idle) drgnx-notice--table))
            (drgnx-hub-call-sync "agents/list" nil 10)
            (should-not (gethash '(hub . restart-when-idle) drgnx-notice--table)))
        (drgnx-notice-clear 'hub 'restart-when-idle)))))

(ert-deftest drgnx-hub-client/a-legacy-hub-offers-restart-now ()
  ;; a Lisp hub of before this update runs: the notice offers Hub: Restart Now, which shuts it down (v0 has no
  ;; restart) and starts Ratatoskr with one `ensure'
  (drgnx-hub-client-test--with-fake (:mode 'legacy)
    (let* ((log (concat root "stub.log")) (noninteractive nil)
           (process-environment
            (cons (concat "DRGNX_RATATOSKR_BIN=" (drgnx-hub-client-test--stub root (format "echo \"$*\" >> '%s'" log)))
                  process-environment)))
      (unwind-protect
          (progn
            (drgnx-hub-call-sync "ping" nil 10)
            (let ((n (gethash '(hub . restart-when-idle) drgnx-notice--table)))
              (should n)
              (should (eq (plist-get n :command) 'hub-restart-now))
              (should (string-search "restart it to use Ratatoskr (running agent sessions end)" (plist-get n :text))))
            (drgnx-hub-restart-now)
            ;; (the stub also answers the client's `version --json' read)
            (let ((ensures (lambda () (seq-filter (lambda (l) (string-prefix-p "ensure" l)) (drgnx-hub-client-test--lines log)))))
              (drgnx-hub-client-test--wait ensures "ratatoskr ensure runs")
              (should (member "shutdown" (drgnx-fake-hub-methods hub)))
              (should-not (member "restart" (drgnx-fake-hub-methods hub)))
              (should (equal (funcall ensures) '("ensure --timeout 5")))))
        (drgnx-notice-clear 'hub 'restart-when-idle)))))

(ert-deftest drgnx-hub-client/the-update-notice-offers-restart-now ()
  ;; binary: the file the hub runs from is replaced by another commit's (an update): the hub's `notice' event becomes
  ;; a notice whose command is Hub: Restart Now (needs the binary's test hooks: the 200 ms tick)
  (skip-unless (and (drgnx-hub-client-test--bin)
                    (string-search "\"test_hooks\":true"
                                   (shell-command-to-string (concat (shell-quote-argument (drgnx-hub-client-test--bin)) " version --json")))))
  (let ((drgnx-hub-client-test--serve-fn
         (lambda (root)
           (let ((live (concat root "ratatoskr-live")))
             (copy-file (drgnx-hub-client-test--bin) live)
             (set-file-modes live #o755)
             (list live "--idle-tick-ms" "200")))))
    (drgnx-hub-client-test--with-ratatoskr
      (unwind-protect
          (progn
            (drgnx-hub-client-test--backend-up)
            (drgnx-hub-connect)
            (drgnx-hub-client-test--wait (lambda () (process-live-p drgnx-hub--events)) "the subscription")
            (let ((other (drgnx-hub-client-test--stub root "echo '{\"commit\":\"another\"}'")))
              (rename-file other (concat root "ratatoskr-live") t))
            (let ((n (drgnx-hub-client-test--wait (lambda () (gethash '(hub . restart-when-idle) drgnx-notice--table))
                                                  "the update notice")))
              (should (eq (plist-get n :command) 'hub-restart-now))
              (should (eq (plist-get n :life) 'condition))))
        (drgnx-notice-clear 'hub 'restart-when-idle)))))

(ert-deftest drgnx-hub-client/restart-now-over-ratatoskr ()
  ;; binary + the Lisp backend (R-T17-3): ensure starts Ratatoskr, the editor's key reaches it, Hub: Restart Now
  ;; restarts it (self-supervised: it executes itself again), and the editor's next subscription gives the key again
  (skip-unless (drgnx-hub-client-test--bin))
  (require 'drgnx-ai)
  (drgnx-hub-client-test--with
    (let* ((bin (drgnx-hub-client-test--bin))
           (process-environment (append (list (concat "DRGNX_RATATOSKR_BIN=" bin) "RATATOSKR_SUPERVISOR=none"
                                              "OPENROUTER_API_KEY=sk-test-restart")
                                        process-environment))
           (drgnx-hub-client-test--traffic nil))
      (advice-add 'drgnx-hub-call :around #'drgnx-hub-client-test--record)
      (unwind-protect
          (progn
            (should (drgnx-hub-ensure))
            (should (drgnx-hub-running-p))
            (drgnx-hub-connect)
            (drgnx-hub-client-test--wait (lambda () (process-live-p drgnx-hub--events)) "the subscription")
            (let ((first drgnx-hub--events)
                  (given (lambda () (seq-count (lambda (c) (and (equal (car c) "gateway/keys") (null (nth 2 c))))
                                               drgnx-hub-client-test--traffic))))
              (drgnx-hub-client-test--wait (lambda () (>= (funcall given) 1)) "the key reaches the hub")
              (drgnx-hub-restart-now)
              (drgnx-hub-client-test--wait (lambda () (not (process-live-p first))) "the hub restarts")
              (let ((before (funcall given)))
                (drgnx-hub-client-test--wait (lambda () (ignore-errors (drgnx-hub-connect) (process-live-p drgnx-hub--events)))
                                             "the editor subscribes again")
                (drgnx-hub-client-test--wait (lambda () (> (funcall given) before)) "the key goes again"))))
        (advice-remove 'drgnx-hub-call #'drgnx-hub-client-test--record)
        (drgnx-hub-disconnect)
        (call-process bin nil nil nil "stop" "--timeout" "10")))))

;;;; MCP sessions (Task 14)

(ert-deftest drgnx-hub-client/mcp-session-calls-the-hub-and-returns-the-socket ()
  (drgnx-hub-client-test--with
    (let ((process-environment
           (cons (concat "DRGNX_RATATOSKR_BIN=" (drgnx-hub-client-test--stub root "exit 0")) process-environment))
          (asked nil) (closed nil))
      (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                 (lambda (method params &optional timeout)
                   (push (list method params timeout) asked)
                   (list :sid "x1" :socket "/run/s/x1/mcp.sock")))
                ((symbol-function 'drgnx-hub-call)
                 (lambda (method params cb) (push (list method params) closed) (funcall cb t nil))))
        (should (equal (drgnx-hub-mcp-session "s-0000000a" :job "j" :task "j#1" :cwd root)
                       '(:sid "x1" :socket "/run/s/x1/mcp.sock")))
        (let ((call (car asked)))
          (should (equal (nth 0 call) "mcp/session"))
          (should (equal (nth 2 call) 2))
          (should (equal (plist-get (nth 1 call) :agent) "s-0000000a"))
          (should (equal (plist-get (nth 1 call) :job) "j"))
          (should (equal (plist-get (nth 1 call) :task) "j#1"))
          (should (equal (plist-get (nth 1 call) :cwd) (expand-file-name root)))
          (should (eql (plist-get (nth 1 call) :owner) (emacs-pid)))
          (should-not (plist-member (nth 1 call) :sid)))
        (drgnx-hub-mcp-session-close "x1")
        (should (equal (car closed) '("mcp/session-close" (:sid "x1"))))))))

(ert-deftest drgnx-hub-client/mcp-session-without-a-binary-says-how ()
  (drgnx-hub-client-test--with
    (let ((process-environment (cons "DRGNX_RATATOSKR_BIN" process-environment)))
      (cl-letf (((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (ert-fail "asked the hub"))))
        (should (string-search (format-message "Ratatoskr is not built: run `drgnx runtime build'")
                               (error-message-string (should-error (drgnx-hub-mcp-session "s-0000000a")))))))))

(ert-deftest drgnx-hub-client/mcp-session-in-a-daemon-path-never-waits ()
  (drgnx-hub-client-test--with
    (let ((process-environment
           (cons (concat "DRGNX_RATATOSKR_BIN=" (drgnx-hub-client-test--stub root "exit 0")) process-environment))
          (inhibit-interaction t) (got :none) (pending nil))
      (cl-letf (((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (ert-fail "waited in a daemon path")))
                ((symbol-function 'drgnx-hub-call)
                 (lambda (method params cb) (should (equal method "mcp/session")) (setq pending (cons cb params)))))
        (should-not (drgnx-hub-mcp-session "s-0000000a" :callback (lambda (answer err) (setq got (list answer err)))))
        (should (eq got :none))                         ; asked, not answered yet
        (funcall (car pending) (list :sid "x1" :socket "/run/s/x1/mcp.sock") nil)
        (should (equal got '((:sid "x1" :socket "/run/s/x1/mcp.sock") nil)))
        ;; a refusal reaches the callback as its message
        (funcall (car pending) nil "no room")
        (should (equal got '(nil "no room")))))))

;;;; The provider table and need-keys (Task 23)

(defun drgnx-hub-client-test--sent (hub method)
  "The requests of METHOD the fake HUB read, oldest first."
  (seq-filter (lambda (l) (equal (plist-get l :method) method)) (drgnx-fake-hub-lines hub)))

(defun drgnx-hub-client-test--provider (line id)
  "Provider ID's entry in LINE, a `config/providers' request (as the fake hub read it)."
  (seq-find (lambda (p) (equal (plist-get p :id) id)) (plist-get (plist-get line :params) :providers)))

(defun drgnx-hub-client-test--no-keys-env ()
  "`process-environment' with every provider's key variable unset: this Emacs holds no key."
  (append (delq nil (mapcar (lambda (p) (plist-get (cdr p) :key-env)) (drgnx-ai-providers))) process-environment))

(defun drgnx-hub-client-test--subscribed (hub)
  "Wait until this Emacs is subscribed to the fake HUB and has handed it the provider table."
  (drgnx-hub-client-test--wait (lambda () (and (process-live-p drgnx-hub--events) (drgnx-hub-client-test--sent hub "config/providers")))
                               "the subscription and the table"))

(ert-deftest drgnx-hub-client/providers-sent-on-connect-and-on-change ()
  ;; the resolved table (the presets and ai.eld, with kinds and caps) goes once the subscription is answered, and again
  ;; when ai.eld changes
  (drgnx-test-with-config
    (drgnx-hub-client-test--with-fake ()
      (drgnx-hub-connect)
      (drgnx-hub-client-test--subscribed hub)
      (let ((first (car (drgnx-hub-client-test--sent hub "config/providers"))))
        (should (equal (drgnx-hub-client-test--provider first "openrouter")
                       '(:id "openrouter" :kind "openai" :base "https://openrouter.ai/api/v1" :auth "bearer" :messages t
                             :caps ("chat" "fim" "embed"))))
        (should (equal (drgnx-hub-client-test--provider first "anthropic")
                       '(:id "anthropic" :kind "anthropic" :base "https://api.anthropic.com/v1" :auth "x-api-key"
                             :messages t :caps nil)))
        (should (equal (drgnx-hub-client-test--provider first "ollama")
                       '(:id "ollama" :kind "ollama" :base "http://127.0.0.1:11434" :auth "none" :messages t
                             :caps ("chat" "fim" "embed"))))
        (should (equal (plist-get (drgnx-hub-client-test--provider first "lmstudio") :messages) :false))
        (should-not (drgnx-hub-client-test--provider first "lan")))
      (drgnx-test-config-put 'ai (concat "(:version 1 :providers ((lan :name \"LAN\" :kind openai :url \"http://192.0.2.10:8080/v1\""
                                         " :key-env \"LAN_KEY\" :caps (chat) :price (1 . 2))))\n"))
      (drgnx-config-reread 'ai)
      (let ((again (drgnx-hub-client-test--wait
                    (lambda () (seq-find (lambda (l) (drgnx-hub-client-test--provider l "lan"))
                                         (drgnx-hub-client-test--sent hub "config/providers")))
                    "the table again, with ai.eld's provider")))
        (should (equal (drgnx-hub-client-test--provider again "lan")
                       '(:id "lan" :kind "openai" :base "http://192.0.2.10:8080/v1" :auth "bearer" :messages :false
                             :caps ("chat") :price (:input 1 :output 2))))
        (should (drgnx-hub-client-test--provider again "openrouter"))))))

(ert-deftest drgnx-hub-client/providers-carry-no-key ()
  ;; a canary key in the environment: the keys carry it, the provider table never does
  (drgnx-hub-client-test--with-fake ()
    (let ((process-environment (cons "OPENROUTER_API_KEY=sk-canary-providers" process-environment)))
      (drgnx-hub-connect)
      (drgnx-hub-client-test--wait (lambda () (and (drgnx-hub-client-test--sent hub "config/providers")
                                                   (drgnx-hub-client-test--sent hub "gateway/keys")))
                                   "the table and the keys")
      (should (string-search "sk-canary-providers" (prin1-to-string (drgnx-hub-client-test--sent hub "gateway/keys"))))
      (should-not (string-search "sk-canary-providers"
                                 (prin1-to-string (drgnx-hub-client-test--sent hub "config/providers"))))
      (should-not (string-search "sk-canary-providers" (prin1-to-string (drgnx-hub--providers-table)))))))

(ert-deftest drgnx-hub-client/a-clear-text-warning-is-shown-once-per-provider ()
  ;; two answers to config/providers with the same warning (user's answer 4): one notice, posted once
  (drgnx-notice-test-with-model
    (drgnx-hub-client-test--with-fake
        (:results (list (cons "config/providers"
                              '(:applied 1 :warnings [(:provider "lan" :text "lan's key travels in clear text over http://192.0.2.10:8080; use https")]))))
      (let ((ids (list (drgnx-hub--send-providers) (drgnx-hub--send-providers))))
        (drgnx-hub-client-test--wait (lambda () (not (seq-some (lambda (id) (gethash id drgnx-hub--pending)) ids)))
                                     "both answers")
        (let ((n (gethash '(hub . clear-text-lan) drgnx-notice--table)))
          (should n)
          (should (equal (plist-get n :text) "lan's key travels in clear text over http://192.0.2.10:8080; use https"))
          (should-not (plist-get n :count)))))))

(ert-deftest drgnx-hub-client/need-keys-re-reads-the-environment ()
  ;; no key kept (`drgnx-ai--keys' empty) and none when the editor connected: the variable set since is read when the
  ;; hub asks, goes with gateway/keys, and is stored nowhere
  (drgnx-hub-client-test--with-fake ()
    (let ((drgnx-ai--keys (make-hash-table :test #'eq)) (process-environment (drgnx-hub-client-test--no-keys-env)))
      (drgnx-hub-connect)
      (drgnx-hub-client-test--subscribed hub)
      (let ((process-environment (cons "OPENROUTER_API_KEY=sk-read-again" process-environment)))
        (drgnx-fake-hub-event hub "gateway/need-keys" '(:providers ["openrouter"]))
        (drgnx-hub-client-test--wait (lambda () (drgnx-hub-client-test--sent hub "gateway/keys")) "the key goes"))
      (should (equal (mapcar (lambda (l) (plist-get (plist-get l :params) :keys)) (drgnx-hub-client-test--sent hub "gateway/keys"))
                     '((:openrouter "sk-read-again"))))
      (should (= (hash-table-count drgnx-ai--keys) 0))
      (should-not (gethash '(hub . need-key-openrouter) drgnx-notice--table)))))

(ert-deftest drgnx-hub-client/need-keys-without-a-key-raises-a-notice-never-prompts ()
  ;; a daemon path: nothing may ask; of auth-source only a file that never asks is read (never a .gpg file, the
  ;; Keychain or the keyring); a key not found is a notice naming the provider
  (drgnx-notice-test-with-model
    (drgnx-hub-client-test--with-fake ()
      (let ((drgnx-ai--keys (make-hash-table :test #'eq)) (process-environment (drgnx-hub-client-test--no-keys-env))
            (inhibit-interaction t) (auth-sources (list (concat root "authinfo.gpg") 'macos-keychain-internet (concat root "authinfo"))))
        (cl-letf (((symbol-function 'auth-source-search)
                   (lambda (&rest _) (unless (equal auth-sources (list (concat root "authinfo")))
                                       (ert-fail (format "a source that may ask was read: %S" auth-sources))))))
          (drgnx-hub-connect)
          (drgnx-hub-client-test--subscribed hub)
          (drgnx-fake-hub-event hub "gateway/need-keys" '(:providers ["openrouter"]))
          (let ((n (drgnx-hub-client-test--wait (lambda () (gethash '(hub . need-key-openrouter) drgnx-notice--table))
                                                "the notice")))
            (should (equal (plist-get n :text) "agents need your openrouter key in the drgnx hub: run AI: Load Keys"))
            (should (eq (plist-get n :command) 'drgnx-ai-load-keys))))
        (should-not (drgnx-hub-client-test--sent hub "gateway/keys"))
        (should-not (drgnx-notices :source 'guard))))))

(ert-deftest drgnx-hub-client/need-keys-on-an-unproven-connection-is-ignored ()
  ;; a subscription whose hub is not proven (this Emacs gave no proof: service class) never answers need-keys: no key
  ;; goes and no notice is raised; the event after it is still read
  (drgnx-notice-test-with-model
    (drgnx-hub-client-test--with-fake ()
      (let ((drgnx-hub-client-proves nil) (drgnx-ai--keys (make-hash-table :test #'eq))
            (process-environment (drgnx-hub-client-test--no-keys-env)))
        (drgnx-hub-connect)
        (drgnx-hub-client-test--subscribed hub)
        (should-not (process-get drgnx-hub--events :drgnx-proven))
        (drgnx-fake-hub-event hub "gateway/need-keys" '(:providers ["openrouter"]))
        (drgnx-fake-hub-event hub "notice" '(:id "after" :text "the next event" :severity "info"))
        (drgnx-hub-client-test--wait (lambda () (gethash '(hub . after) drgnx-notice--table)) "the next event")
        (should-not (gethash '(hub . need-key-openrouter) drgnx-notice--table))
        (should-not (drgnx-hub-client-test--sent hub "gateway/keys"))))))

(ert-deftest drgnx-hub-client/keys-again-after-a-restart ()
  ;; binary + the Lisp backend (R-T17-3): the editor's key reaches the hub, and a registration needs it; the hub restarts
  ;; (keys live in its memory only); its need-keys reaches the editor's new subscription, which reads the environment
  ;; again and hands the key over; a registration that needs the key then succeeds
  (skip-unless (drgnx-hub-client-test--bin))
  (drgnx-hub-client-test--with
    (let* ((bin (drgnx-hub-client-test--bin))
           (process-environment (append (list (concat "DRGNX_RATATOSKR_BIN=" bin) "RATATOSKR_SUPERVISOR=none"
                                              "OPENROUTER_API_KEY=sk-test-need-keys")
                                        process-environment))
           (drgnx-hub-client-test--traffic nil) (asked nil)
           (given (lambda () (seq-count (lambda (c) (and (equal (car c) "gateway/keys") (null (nth 2 c))))
                                        drgnx-hub-client-test--traffic))))
      (advice-add 'drgnx-hub-call :around #'drgnx-hub-client-test--record)
      (unwind-protect
          (progn
            (should (drgnx-hub-ensure))                 ; the table and the key, waited for
            (should (stringp (plist-get (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]]) 10) :token)))
            (drgnx-hub-connect)
            (add-hook 'drgnx-hub-event-functions (lambda (event data) (when (equal event "gateway/need-keys") (push data asked))))
            (drgnx-hub-client-test--wait (lambda () (process-live-p drgnx-hub--events)) "the subscription")
            (let ((first drgnx-hub--events))
              (drgnx-hub-restart-now)
              (drgnx-hub-client-test--wait (lambda () (not (process-live-p first))) "the hub restarts"))
            (let ((before (funcall given)))
              (drgnx-hub-client-test--wait (lambda () (ignore-errors (drgnx-hub-connect) (process-live-p drgnx-hub--events)))
                                           "the editor subscribes again")
              (drgnx-hub-client-test--wait (lambda () asked) "the hub asks for the keys")
              (should (member "openrouter" (plist-get (car asked) :providers)))
              ;; the subscription's own hand-over, and the answer to need-keys
              (drgnx-hub-client-test--wait (lambda () (>= (funcall given) (+ before 2))) "the key goes again"))
            (should (stringp (plist-get (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]]) 10) :token))))
        (advice-remove 'drgnx-hub-call #'drgnx-hub-client-test--record)
        (drgnx-hub-disconnect)
        (call-process bin nil nil nil "stop" "--timeout" "10")))))

(ert-deftest drgnx-hub-client/a-netrc-key-goes-again-after-a-restart ()
  ;; binary (review M3): openrouter's key lives only in a plain netrc, not the environment; the hub restarts (keys live
  ;; in its memory only); the reconnect's hand-over reads the file again, without asking, and the hub holds the key
  ;; again — while this Emacs keeps neither the key nor auth-source's copy of the file
  (skip-unless (drgnx-hub-client-test--bin))
  (drgnx-hub-client-test--with
    (let* ((bin (drgnx-hub-client-test--bin))
           (process-environment (append (list (concat "DRGNX_RATATOSKR_BIN=" bin) "RATATOSKR_SUPERVISOR=none")
                                        (drgnx-hub-client-test--no-keys-env)))
           (netrc (concat root "netrc"))
           (auth-sources (list netrc)) (auth-source-netrc-cache nil) (password-data (make-hash-table :test #'equal))
           (drgnx-ai--keys (make-hash-table :test #'eq)) (drgnx-hub--keys-held :unknown) (drgnx-hub--editor nil)
           (cached (lambda () (or auth-source-netrc-cache
                                  (let (found) (maphash (lambda (k _) (when (eq (car-safe k) 'auth-source) (setq found t)))
                                                        password-data)
                                       found)))))
      (with-temp-file netrc (insert "machine openrouter.ai login drgnx password sk-or-netrc-m3\n"))
      (set-file-modes netrc #o600)
      (unwind-protect
          (progn
            (should (drgnx-hub-ensure))
            (drgnx-hub-connect)
            (drgnx-hub-client-test--wait (lambda () (member "openrouter" (and (listp drgnx-hub--keys-held) drgnx-hub--keys-held)))
                                         "the hub holds the key")
            (let ((first drgnx-hub--events))
              (drgnx-hub-restart-now)
              (drgnx-hub-client-test--wait (lambda () (not (process-live-p first))) "the hub restarts"))
            (drgnx-hub-client-test--wait (lambda () (ignore-errors (drgnx-hub-connect) (process-live-p drgnx-hub--events)))
                                         "the editor subscribes again")
            ;; the new hub's own answer, not the list this Emacs kept from before
            (drgnx-hub-client-test--wait
             (lambda () (member "openrouter" (append (plist-get (ignore-errors (drgnx-hub-call-sync "gateway/keys-held" nil 5))
                                                                :providers)
                                                     nil)))
             "the hub holds the key again")
            (should (zerop (hash-table-count drgnx-ai--keys)))
            (should-not (funcall cached))
            (should-not (gethash '(hub . key-lost-openrouter) drgnx-notice--table)))
        (drgnx-hub-disconnect)
        (call-process bin nil nil nil "stop" "--timeout" "10")))))

(ert-deftest drgnx-hub-client/the-editor-token-and-held-keys-are-fetched-on-every-connect ()
  ;; the hand-over also asks gateway/editor-token and gateway/keys-held; a proven reconnect asks again; keys-changed
  ;; keeps the list current; a disconnect forgets both
  (drgnx-hub-client-test--with-fake
      (:results (list (cons "gateway/editor-token" '(:token "tok-1" :url "http://127.0.0.1:4242"))
                      (cons "gateway/keys-held" '(:providers ["openrouter"]))))
    (let ((drgnx-hub--editor nil) (drgnx-hub--keys-held :unknown) (hook-ran 0) (drgnx-hub-editor-token-hook nil)
          (process-environment (drgnx-hub-client-test--no-keys-env)))
      (add-hook 'drgnx-hub-editor-token-hook (lambda () (cl-incf hook-ran)))
      (should (eq (drgnx-hub-keys-held) :unknown))
      (drgnx-hub-connect)
      (drgnx-hub-client-test--wait (lambda () drgnx-hub--editor) "the editor token")
      (should (equal (drgnx-hub-editor-token) '("tok-1" . "http://127.0.0.1:4242")))
      (drgnx-hub-client-test--wait (lambda () (listp (drgnx-hub-keys-held))) "the held keys")
      (should (equal (drgnx-hub-keys-held) '("openrouter")))
      (should (>= hook-ran 1))
      (drgnx-fake-hub-event hub "gateway/keys-changed" '(:providers ["openrouter" "anthropic"]))
      (drgnx-hub-client-test--wait (lambda () (equal (drgnx-hub-keys-held) '("openrouter" "anthropic"))) "keys-changed")
      ;; the connection goes and comes back: both are asked again
      (let ((asked (length (drgnx-hub-client-test--sent hub "gateway/editor-token"))))
        (drgnx-hub-disconnect)
        (should (null drgnx-hub--editor))
        (should (eq (drgnx-hub-keys-held) :unknown))
        (drgnx-hub-connect)
        (drgnx-hub-client-test--wait (lambda () (> (length (drgnx-hub-client-test--sent hub "gateway/editor-token")) asked))
                                     "the token asked again")
        (drgnx-hub-client-test--wait (lambda () drgnx-hub--editor) "the token again")))))

(ert-deftest drgnx-hub-client/a-key-the-hub-lost-is-a-notice ()
  ;; review M3: the hub held openrouter's key earlier this session and, after a restart, holds none; this Emacs cannot
  ;; find it again without asking (it lived in a store that asks): a notice says to run AI: Load Keys, and goes once
  ;; the hub holds the key again.  A provider the hub never held raises nothing
  (drgnx-notice-test-with-model
    (drgnx-hub-client-test--with-fake (:results (list (cons "gateway/keys-held" '(:providers []))))
      (let ((drgnx-hub--keys-held :unknown) (drgnx-hub--keys-had '("openrouter")) (auth-sources nil)
            (drgnx-ai--keys (make-hash-table :test #'eq)) (process-environment (drgnx-hub-client-test--no-keys-env)))
        (drgnx-hub-connect)
        (let ((n (drgnx-hub-client-test--wait (lambda () (gethash '(hub . key-lost-openrouter) drgnx-notice--table))
                                              "the notice")))
          (should (equal (plist-get n :text) "the drgnx hub restarted without your openrouter key: run AI: Load Keys"))
          (should (eq (plist-get n :command) 'drgnx-ai-load-keys)))
        (should-not (gethash '(hub . key-lost-anthropic) drgnx-notice--table))
        (drgnx-fake-hub-event hub "gateway/keys-changed" '(:providers ["openrouter"]))
        (drgnx-hub-client-test--wait (lambda () (not (gethash '(hub . key-lost-openrouter) drgnx-notice--table)))
                                     "the notice goes")
        (should (member "openrouter" drgnx-hub--keys-had))))))

(ert-deftest drgnx-hub-client/a-key-found-again-quietly-raises-no-notice ()
  ;; the same restart, but the key is in a plain authinfo (a store that never asks): the hand-over carries it again,
  ;; and no notice is raised even when the hub's keys-held answer comes before it took the key
  (drgnx-notice-test-with-model
    (drgnx-hub-client-test--with-fake (:results (list (cons "gateway/keys-held" '(:providers []))))
      (let* ((drgnx-hub--keys-held :unknown) (drgnx-hub--keys-had '("openrouter"))
             (plain (concat root "authinfo"))
             (auth-sources (list plain)) (auth-source-netrc-cache nil)
             (drgnx-ai--keys (make-hash-table :test #'eq)) (process-environment (drgnx-hub-client-test--no-keys-env)))
        (with-temp-file plain (insert "machine openrouter.ai login drgnx password sk-or-quiet-m3\n"))
        (set-file-modes plain #o600)
        (drgnx-hub-connect)
        (drgnx-hub-client-test--wait (lambda () (listp drgnx-hub--keys-held)) "the held keys")
        (should (equal (mapcar (lambda (l) (plist-get (plist-get l :params) :keys)) (drgnx-hub-client-test--sent hub "gateway/keys"))
                       '((:openrouter "sk-or-quiet-m3"))))
        (should-not (gethash '(hub . key-lost-openrouter) drgnx-notice--table))
        (should (zerop (hash-table-count drgnx-ai--keys)))
        (should-not auth-source-netrc-cache)))))

;;; hub-client-test.el ends here
