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
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
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
          (drgnx-hub-event-functions nil) (drgnx-hub-disconnect-functions nil) (drgnx-hub-skew-functions nil))
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
                               :command (list (drgnx-hub-client-test--bin) "serve" "--foreground"
                                              "--parent-pid" (number-to-string (emacs-pid))))))
       (unwind-protect
           (progn (drgnx-hub-client-test--wait #'drgnx-hub-running-p "Ratatoskr answers a ping")
                  ,@body)
         (drgnx-hub-disconnect)
         (when (process-live-p hub) (signal-process hub 'term))
         (ignore-errors (drgnx-test-wait (lambda () (not (process-live-p hub))) :secs 10 :what "Ratatoskr ends"))
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

;;; hub-client-test.el ends here
