;;; hub-client-test.el --- batch tests: the editor's v1 client (hello, proofs, deadlines, skew, the line reader) -*- lexical-binding: t -*-
;; Fake hubs (test/fixtures/fake-hub.el) lie about their proof or speak protocol 0; the tests marked "binary" run
;; against Ratatoskr (DRGNX_RATATOSKR_BIN), and skip without it (test/no-skip.eld lists them).  A binary test that
;; connects chooses its order through the delivery gate (`drgnx-test-gated': a test-hooks Ratatoskr, its clock and
;; sequencer; docs/develop/harness.md, "The delivery gate").
;; test-class: cond
;; test-pattern: gated
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-notice)
(require 'drgnx-hub-client)
(require 'drgnx-shell-env)
(require 'drgnx-registry)               ; the notice tests register a command
(require 'drgnx-agents-mirror)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/work-fixture" drgnx-dir) nil t)   ; seeding as the hub's stand-in
(require 'drgnx-ai)
(require 'drgnx-settings-prov)
(require 'auth-source)                  ; its variables are let-bound below
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/fake-hub" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(require 'drgnx-exec)
(require 'drgnx-settings-runtime)
(require 'drgnx-settings-agents nil t)
(require 'drgnx-records-review nil t)

(defvar drgnx-exec--jobs)
(defvar drgnx-exec--stale)

(defmacro drgnx-hub-client-test--with (&rest body)
  "BODY with drgnx's dirs under ROOT (the hub's socket in ROOT/run/drgnx), the client's state fresh; the client is
disconnected at the end."
  (declare (indent 0))
  `(drgnx-hub-client-test--in-root
     (unwind-protect (progn ,@body)
       (drgnx-hub-disconnect))))

(defmacro drgnx-hub-client-test--in-root (&rest body)
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
          (drgnx-hub--keys-had nil)
          (drgnx-hub--asked-disconnect nil) (drgnx-hub--resubscribe-since nil) (drgnx-hub--resubscribe-delay 1))
     (dolist (d '("run" "home" "config" "data")) (with-file-modes #o700 (make-directory (concat root d) t)))
     (unwind-protect (progn ,@body)
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
  "BODY with Ratatoskr serving ROOT (`drgnx-hub-client-test--with'), this Emacs not yet connected; skipped without the
binary.  For the tests of other files that drive a real agent through the hub and wait on conditions of their own (the
agents mirror's): their order is the agent's, not the gate's."
  (declare (indent 0))
  `(drgnx-hub-client-test--with
     (skip-unless (drgnx-hub-client-test--bin))
     (let* ((process-environment (append (list (concat "DRGNX_DIR=" (directory-file-name drgnx-dir)) "RATATOSKR_SUPERVISOR=none"
                                               (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory)))
                                         process-environment))
            (hub (make-process :name "ratatoskr" :noquery t :connection-type 'pipe :buffer (generate-new-buffer " *ratatoskr*")
                               :sentinel (lambda (p _event) (unless (process-live-p p) (process-put p :done t)))
                               :command (list (drgnx-hub-client-test--bin) "serve" "--foreground"
                                              "--parent-pid" (number-to-string (emacs-pid))))))
       (unwind-protect
           (progn (drgnx-hub-client-test--wait #'drgnx-hub-running-p "Ratatoskr answers a ping")
                  ,@body)
         (drgnx-hub-disconnect)
         (when (process-live-p hub) (signal-process hub 'term))
         (ignore-errors (drgnx-test-wait (lambda () (process-get hub :done)) :secs 10 :what "Ratatoskr ends"))
         (when (process-live-p hub) (signal-process hub 'kill))
         (kill-buffer (process-buffer hub))))))

(defmacro drgnx-hub-client-test--with-hub (&rest body)
  "BODY with a gated Ratatoskr serving ROOT (`drgnx-hub-client-test--in-root'), this Emacs not connected: BODY
connects inside `drgnx-test-gated'.  `hub' is the hub's process; the fixture disconnects at the end."
  (declare (indent 0))
  `(drgnx-hub-client-test--in-root
     (let ((drgnx-hub--presence-sent :unknown) (drgnx-hub-editor-token-hook nil)
           (drgnx-exec--jobs (make-hash-table :test #'equal)) (drgnx-exec--stale nil))
       (drgnx-test-with-ratatoskr root :gated t ,@body))))

(defun drgnx-hub-client-test--answer-held-p (name key)
  "Whether the gate holds an answer on connection NAME with KEY in its result."
  (cl-some (lambda (line)
             (let ((j (and (stringp line) (ignore-errors (json-parse-string line :object-type 'plist :null-object nil
                                                                            :false-object nil)))))
               (and (plist-get j :id) (not (plist-get j :event)) (consp (plist-get j :result))
                    (plist-member (plist-get j :result) key))))
           (drgnx-test-gate-held name)))

(defun drgnx-hub-client-test--mock-profile (root)
  "The profile \"mock\" (test/fixtures/mock-acp.el) in ROOT's settings.el."
  (drgnx-test-write-settings
   (concat root "config/settings.el")
   'drgnx-agents-profiles (list (list "mock" :command (list "sh" (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir)
                                                            (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                                            "-l" (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))))))

(ert-deftest drgnx-hub-client/proves-itself-and-is-user ()
  ;; binary: the hello's proof makes the connection user class, and Ratatoskr's proof back checks out
  (drgnx-hub-client-test--with-hub
    (let (pid class proven agents nope)
      (drgnx-test-gated '((call-1 :answer "ping"))
        (setq pid (plist-get (drgnx-hub-call-sync "ping" nil 10) :pid)
              class (plist-get drgnx-hub--last-hello :class)
              proven (process-get drgnx-hub--client :drgnx-proven)
              agents (drgnx-hub-has-method-p "agents/list")
              nope (drgnx-hub-has-method-p "no/such-method"))
        (drgnx-test-deliver-all))
      (should (natnump pid))
      (should (equal class "user"))
      (should proven)
      (should agents)
      (should-not nope))))

(ert-deftest drgnx-hub-client/ping-probe-skips-the-challenge ()
  ;; binary: the challenge is the first line on every connection; the probe reads past it to the answer.  The probe is
  ;; its own socket and its own real-time look, so it runs outside the gate: there is no client connection to order.
  (drgnx-hub-client-test--with-hub
    (should (drgnx-hub--ping-socket (drgnx-hub-socket)))))

(ert-deftest drgnx-hub-client/a-service-line-asking-for-keys-is-refused ()
  ;; binary: a connection with no hello is service class: a line that asks for keys is refused and counted
  (drgnx-hub-client-test--with-hub
    (let (before after reply)
      (drgnx-test-gated '((call-1 :answer "status") (call-1 :answer "status"))
        (let* ((refused (lambda () (plist-get (plist-get (drgnx-hub-call-sync "status" nil 10) :refusals) :count)))
               (c (make-network-process :name "raw" :family 'local :service (drgnx-hub-socket) :noquery t
                                        :filter (lambda (_p s) (setq reply (concat reply s))))))
          (unwind-protect
              (progn
                (setq before (funcall refused))
                (process-send-string c "{\"id\":1,\"method\":\"gateway/keys\",\"params\":{\"keys\":{}}}\n")
                ;; the hub's answer to the raw line says it was served (and counted)
                (drgnx-test-wait (lambda () (and reply (string-search "\"id\":1" reply))) :what "the refusal's answer")
                (setq after (funcall refused)))
            (delete-process c))
          (drgnx-test-deliver-all)))
      (should (eql before 0))
      (should (string-search "\"error\"" reply))
      (should (eql after 1)))))

(ert-deftest drgnx-hub-client/mirror-over-ratatoskr ()
  ;; binary: a session the hub starts reaches this Emacs's mirror
  (drgnx-hub-client-test--with-hub
    (drgnx-hub-client-test--mock-profile root)
    (let ((drgnx-agents--sessions nil) (drgnx-agents-profiles nil) id)
      (drgnx-test-gated '((call-1 :answer "agents/start") (call-1 :answer "agents/list") (:pause "mirrored")
                          (call-1 :answer "agents/kill"))
        (unwind-protect
            (progn
              (setq id (plist-get (drgnx-hub-call-sync "agents/start" (list :profile "mock" :cwd root) 30) :id))
              (drgnx-agents-mirror-sync)
              (drgnx-hub-client-test--wait (lambda () (drgnx-agents-mirror--find id)) "the mirror of the hub's session")
              (drgnx-test-gate-continue "mirrored")
              (drgnx-hub-call-sync "agents/kill" (list :id id) 10)
              (drgnx-test-deliver-all))
          (drgnx-agents-mirror-stop)))
      (should (stringp id)))))

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
  ;; refused for its params, and none fails inside.  :frozen until agent system part 1's Task 16a: the hub serves
  ;; job/* itself and answers "not yet" until 16a ports plan runs from the frozen Lisp (the job UI and cockpit are
  ;; frozen Lisp too)
  :tags '(:frozen)
  (let ((load-path (append (list (expand-file-name "modules/tools" drgnx-dir) (expand-file-name "modules/ui" drgnx-dir))
                           load-path)))
    (dolist (f '(drgnx-job drgnx-job-ui drgnx-cockpit-cards drgnx-cockpit-feed drgnx-agents-ui)) (require f)))
  (drgnx-hub-client-test--with-ratatoskr
    (drgnx-hub-client-test--mock-profile root)
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
              (drgnx-work-fixture-as-hub
                (let ((db (sqlite-open (concat root "data/work.db"))))
                  (sqlite-execute db "insert into card (job, task, kind, title, data, state, at) values (?, null, 'note', 'a note', '{}', 'open', 1.5)"
                                  (list job))
                  (sqlite-close db)))
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
            (drgnx-test-pause 0.2 "no call may fail twice")
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
      (drgnx-test-pause 0.3 "no call may go before the hello's answer")
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
                     (,(append (list :schema (+ 2 drgnx-hub-schema-readable-max)) ok) restart-when-idle)
                     (,(append (list :schema (1- drgnx-work-db-schema-version)) ok) restart-when-idle)))
        (should (equal (list (car row) (drgnx-hub-skew (car row))) row)))))
  ;; no binary on disk: its version is not compared
  (cl-letf (((symbol-function 'drgnx-hub-client-binary-version) #'ignore))
    (should (eq (drgnx-hub-skew (list :proto 1 :proto_min 1 :records 2 :drgnx_version "def" :schema 6)) 'ok))))

(ert-deftest drgnx-hub-client/skew-accepts-schema-7 ()
  ;; the hub's schema 7 is read through the compatibility views: not a reason to restart
  (cl-letf (((symbol-function 'drgnx-hub-client-binary-version) #'ignore))
    (should (eq (drgnx-hub-skew (list :proto 1 :proto_min 1 :records 2 :schema 7)) 'ok))
    (should (eq (drgnx-hub-skew (list :proto 1 :proto_min 1 :records 2 :schema 8)) 'restart-when-idle))))

(ert-deftest drgnx-hub-client/mcp-session-passes-the-profile ()
  (let (sent)
    (cl-letf (((symbol-function 'drgnx-hub-client-binary) (lambda () "ratatoskr"))
              ((symbol-function 'drgnx-hub-call-sync) (lambda (m p &optional _) (setq sent (cons m p)) (list :sid "s1" :socket "/x"))))
      (let ((inhibit-interaction nil))
        (should (equal (drgnx-hub-mcp-session "a" :profile "claude (OpenRouter)") '(:sid "s1" :socket "/x")))
        (should (equal (plist-get (cdr sent) :profile) "claude-OpenRouter"))
        (should-not (plist-member (cdr sent) :tools))))))

(ert-deftest drgnx-hub-client/mcp-session-passes-the-tool-switch ()
  (let (sent)
    (cl-letf (((symbol-function 'drgnx-hub-client-binary) (lambda () "ratatoskr"))
              ((symbol-function 'drgnx-hub-call-sync) (lambda (m p &optional _) (setq sent (cons m p)) (list :sid "s1" :socket "/x"))))
      (let ((inhibit-interaction nil))
        (drgnx-hub-mcp-session "a" :profile "p" :tools '(:tracker :false))
        (should (equal (plist-get (cdr sent) :tools) '(:tracker :false)))
        (should (equal (json-serialize (drgnx-hub--jsonable (plist-get (cdr sent) :tools))) "{\"tracker\":false}"))))))

(ert-deftest drgnx-hub-client/the-close-option-is-sent-on-connect-and-change ()
  (let (calls (drgnx-store-only-i-close-my-tasks nil))
    (cl-letf (((symbol-function 'drgnx-hub-call)
               (lambda (m p cb &rest _) (push (cons m p) calls) (funcall cb nil nil) 1))
              ((symbol-function 'drgnx-hub--open) (lambda (&rest _) (make-pipe-process :name "close-option-test" :noquery t)))
              ((symbol-function 'drgnx-hub--call-on) #'ignore)
              ((symbol-function 'drgnx-hub--send-keys) #'ignore)
              (drgnx-hub--client nil) (drgnx-hub--events nil) (drgnx-hub--subscribing nil))
      (unwind-protect
          (progn
            ;; on connect: the current value, false
            (drgnx-hub-connect)
            (should (equal (car calls) '("graph/settings" :set (:only_user_closes :false))))
            ;; on change: at once, true (a connection is live)
            (setq calls nil)
            (setq drgnx-hub--events drgnx-hub--subscribing)
            (drgnx-hub--only-closes-set 'drgnx-store-only-i-close-my-tasks t)
            (should drgnx-store-only-i-close-my-tasks)
            (should (equal (car calls) '("graph/settings" :set (:only_user_closes t)))))
        (dolist (f '(drgnx-hub--note-notice drgnx-hub--need-keys drgnx-hub--keys-changed))
          (remove-hook 'drgnx-hub-event-functions f))
        (when (processp drgnx-hub--subscribing) (delete-process drgnx-hub--subscribing))
        (when (processp drgnx-hub--events) (delete-process drgnx-hub--events))))))

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
           (cons (concat "DRGNX_RATATOSKR_BIN=" (drgnx-hub-client-test--stub root "read x")) process-environment))
          (inhibit-interaction t))
      (unwind-protect
          (progn
            (should-not (drgnx-hub-ensure))
            ;; it came back while the stub (which reads its stdin, held open by Emacs) still runs: it did not wait for it
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

(defun drgnx-hub-client-test--register ()
  "Register what drgnx registers at start (Hub: Restart Now) in the registry bound by the caller: bind both the table and the order."
  (drgnx-command-define 'hub-restart-now :category "Agents" :title "Hub: Restart Now" :command #'drgnx-hub-restart-now :doc "Restart the hub"))

(ert-deftest drgnx-hub-client/a-hub-notice-keeps-only-a-registered-command ()
  ;; the click runs the command through the registry: a hub (any process on its socket) must not name `delete-file'
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-hub-client-test--register)
    (unwind-protect
        (progn
          (drgnx-hub--note-notice "notice" '(:id "restart-when-idle" :text "updated" :severity "warn" :life "condition"
                                                 :command "hub-restart-now"))
          (should (eq (plist-get (gethash '(hub . restart-when-idle) drgnx-notice--table) :command) 'hub-restart-now))
          (drgnx-notice-clear 'hub 'restart-when-idle)
          (drgnx-hub--note-notice "notice" '(:id "restart-when-idle" :text "updated" :severity "warn" :life "condition"
                                                 :command "delete-file"))
          (let ((n (gethash '(hub . restart-when-idle) drgnx-notice--table)))
            (should n)
            (should-not (plist-get n :command))))
      (drgnx-notice-clear 'hub 'restart-when-idle))))

(ert-deftest drgnx-hub-client/the-update-notice-offers-restart-now ()
  ;; binary: the file the hub runs from is replaced by another commit's (an update): the hub's `notice' event becomes
  ;; a notice whose command is Hub: Restart Now (needs the binary's test hooks: the idle tick on the hub's clock).
  ;; One idle tick sends the notice and, nothing being busy, ends the hub: the notice is held by the sequencer, which
  ;; writes it before the hub's connections close, and the gate hands it over at `drgnx-test-deliver-all'
  (skip-unless (and (drgnx-hub-client-test--bin)
                    (string-search "\"test_hooks\":true"
                                   (shell-command-to-string (concat (shell-quote-argument (drgnx-hub-client-test--bin)) " version --json")))))
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil) n)
    (drgnx-hub-client-test--register)
    (drgnx-hub-client-test--in-root
      ;; the hub runs from a copy of the binary, started by a wrapper that gives `serve' the 200 ms tick
      (let* ((live (concat root "ratatoskr-live"))
             (drgnx-hub--presence-sent :unknown) (drgnx-hub-editor-token-hook nil)
             (drgnx-exec--jobs (make-hash-table :test #'equal)) (drgnx-exec--stale nil)
             (process-environment
              (cons (concat "DRGNX_RATATOSKR_BIN="
                            (progn (copy-file (drgnx-hub-client-test--bin) live)
                                   (set-file-modes live #o755)
                                   (drgnx-hub-client-test--stub
                                    root (format "case \"$1\" in serve) exec %s \"$@\" --idle-tick-ms 200;; esac\nexec %s \"$@\""
                                                 (shell-quote-argument live) (shell-quote-argument live)))))
                    process-environment)))
        (drgnx-test-with-ratatoskr root :gated t
                                   (unwind-protect
                                       (progn
                                         (drgnx-test-gated '((sub-1 :answer "subscribe"))
                                           (drgnx-hub-connect)
                                           (drgnx-hub-client-test--wait (lambda () (process-live-p drgnx-hub--events)) "the subscription")
                                           (let ((other (drgnx-hub-client-test--stub root "echo '{\"commit\":\"another\"}'")))
                                             (rename-file other live t))
                                           ;; the tick; no barrier after it: the hub ends on its own
                                           (drgnx-test-hub-advance 200 t)
                                           (drgnx-hub-client-test--wait (lambda () (process-get hub :done)) "the hub ends (restart-when-idle)")
                                           (drgnx-test-deliver-all)
                                           (setq n (gethash '(hub . restart-when-idle) drgnx-notice--table)))
                                         (should n)
                                         (should (eq (plist-get n :command) 'hub-restart-now))
                                         (should (eq (plist-get n :life) 'condition)))
                                     (drgnx-notice-clear 'hub 'restart-when-idle)))))))

(defmacro drgnx-hub-client-test--restart-and-redial ()
  "Inside `drgnx-test-gated', after the hand-over, in a body that has the fixture's `hub': Hub: Restart Now (the schedule
answers its ping and restart, then pauses as \"restarted\"); the foreground hub ends, as it does without a supervisor, and
its connections end (held); the test starts the hub again (`hub' is the new process), the pause is lifted and the
client's clock reaches the redial."
  `(let ((old drgnx-hub--events))
     (drgnx-hub-restart-now)
     (drgnx-hub-client-test--wait (lambda () (and (memq :eof (drgnx-test-gate-held 'sub-1))
                                                  (memq :eof (drgnx-test-gate-held 'call-1))))
                                  "the old hub's connections end, held")
     (drgnx-hub-client-test--wait (lambda () (process-get hub :done)) "the hub ends")
     (setq hub (drgnx-hub-client-test--serve))
     (drgnx-hub-client-test--wait #'drgnx-hub-client-test--hub-listens-p "the new hub listens")
     (drgnx-test-gate-continue "restarted")
     ;; the sentinel's own mark: it lets go of the subscription when it ran
     (drgnx-hub-client-test--wait (lambda () (not (eq drgnx-hub--events old))) "the subscription's sentinel ran")
     (drgnx-test-advance 1)))               ; the redial's delay

(ert-deftest drgnx-hub-client/restart-now-over-ratatoskr ()
  ;; binary + the Lisp backend (R-T17-3): the editor's key reaches the hub, Hub: Restart Now restarts it
  ;; (self-supervised: it executes itself again), and the editor's next subscription gives the key again; the old
  ;; hub's connections end behind the gate, and the client's clock reaches the redial
  (drgnx-hub-client-test--with-hub
    (let* ((process-environment (cons "OPENROUTER_API_KEY=sk-test-restart" process-environment))
           (drgnx-hub-client-test--traffic nil) before
           (given (lambda () (seq-count (lambda (c) (and (equal (car c) "gateway/keys") (null (nth 2 c))))
                                        drgnx-hub-client-test--traffic))))
      (advice-add 'drgnx-hub-call :around #'drgnx-hub-client-test--record)
      (unwind-protect
          (drgnx-test-gated '((sub-1 :answer "subscribe") (call-1 :answer "gateway/keys-held")
                              (call-1 :answer "ping") (call-1 :answer "restart") (:pause "restarted")
                              (sub-1 :eof) (call-1 :eof)
                              (sub-2 :answer "subscribe") (call-2 :answer "gateway/keys-held"))
            (drgnx-hub-connect)
            (drgnx-hub-client-test--wait (lambda () (and (process-live-p drgnx-hub--events) (listp drgnx-hub--keys-held)))
                                         "the subscription and the hand-over's answers")
            (setq before (funcall given))
            (let ((first drgnx-hub--events))
              (drgnx-hub-client-test--restart-and-redial)
              (drgnx-hub-client-test--wait (lambda () (and (process-live-p drgnx-hub--events) (not (eq drgnx-hub--events first))
                                                           (listp drgnx-hub--keys-held)))
                                           "the editor subscribes again and the hand-over is answered"))
            (drgnx-test-deliver-all))
        (advice-remove 'drgnx-hub-call #'drgnx-hub-client-test--record))
      (should (>= before 1))
      (should (> (funcall given) before)))))

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
  "Provider ID's override value in LINE, a `config/settings' request (as the fake hub read it)."
  (let ((o (seq-find (lambda (o) (equal (plist-get o :name) "drgnx-ai-providers")) (plist-get (plist-get line :params) :overrides))))
    (plist-get (plist-get o :value) (intern (concat ":" id)))))

(defun drgnx-hub-client-test--no-keys-env ()
  "`process-environment' with every provider's key variable unset: this Emacs holds no key."
  (append (delq nil (mapcar (lambda (p) (plist-get (cdr p) :key-env)) (drgnx-ai-providers))) process-environment))

(defmacro drgnx-hub-client-test--with-lisp-providers (providers &rest body)
  "BODY with `drgnx-ai-providers' set to PROVIDERS as if your Lisp had set it (so the editor sends it)."
  (declare (indent 1))
  `(let ((old (default-value 'drgnx-ai-providers)))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-settings-explain) (lambda (&rest _) '(:kind lisp :file "/c/config.el"))))
           (set-default 'drgnx-ai-providers ,providers)
           ,@body)
       (set-default 'drgnx-ai-providers old))))

(defun drgnx-hub-client-test--subscribed (hub)
  "Wait until this Emacs is subscribed to the fake HUB and has handed it its runtime settings."
  (drgnx-hub-client-test--wait (lambda () (and (process-live-p drgnx-hub--events) (drgnx-hub-client-test--sent hub "config/settings")))
                               "the subscription and the settings"))

(ert-deftest drgnx-hub-client/providers-sent-on-connect-and-on-change ()
  ;; your Lisp's providers go as a config/settings override once the subscription is answered, and again when
  ;; settings change; the presets are the hub's own
  (drgnx-hub-client-test--with-lisp-providers
      '((lan :name "LAN" :kind openai :url "http://192.0.2.10:8080/v1" :key-env "LAN_KEY" :caps (chat chat) :price (1 . 2)))
    (drgnx-hub-client-test--with-fake ()
      (drgnx-hub-connect)
      (drgnx-hub-client-test--subscribed hub)
      (let ((first (car (drgnx-hub-client-test--sent hub "config/settings"))))
        (should (equal (drgnx-hub-client-test--provider first "lan")
                       '(:name "LAN" :kind "openai" :url "http://192.0.2.10:8080/v1" :key_env "LAN_KEY" :caps ("chat")
                               :price (1 2))))
        (should-not (drgnx-hub-client-test--provider first "openrouter")))
      (let ((n (length (drgnx-hub-client-test--sent hub "config/settings"))))
        (run-hook-with-args 'drgnx-settings-changed-functions "x" nil)
        (drgnx-hub-client-test--wait (lambda () (> (length (drgnx-hub-client-test--sent hub "config/settings")) n))
                                     "the settings again")))))

(ert-deftest drgnx-hub-client/providers-carry-no-key ()
  ;; a canary key in the environment: the keys carry it, the settings never do
  (drgnx-hub-client-test--with-lisp-providers '((openrouter :kind openai :url "https://openrouter.ai/api/v1" :key-env "OPENROUTER_API_KEY"))
    (drgnx-hub-client-test--with-fake ()
      (let ((process-environment (cons "OPENROUTER_API_KEY=sk-canary-providers" process-environment)))
        (drgnx-hub-connect)
        (drgnx-hub-client-test--wait (lambda () (and (drgnx-hub-client-test--sent hub "config/settings")
                                                     (drgnx-hub-client-test--sent hub "gateway/keys")))
                                     "the settings and the keys")
        (should (string-search "sk-canary-providers" (prin1-to-string (drgnx-hub-client-test--sent hub "gateway/keys"))))
        (should-not (string-search "sk-canary-providers"
                                   (prin1-to-string (drgnx-hub-client-test--sent hub "config/settings"))))))))

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
  (drgnx-hub-client-test--with-hub
    (let* ((process-environment (cons "OPENROUTER_API_KEY=sk-test-need-keys" process-environment))
           (drgnx-hub-client-test--traffic nil) (asked nil) before token-1 token-2
           (given (lambda () (seq-count (lambda (c) (and (equal (car c) "gateway/keys") (null (nth 2 c))))
                                        drgnx-hub-client-test--traffic))))
      (advice-add 'drgnx-hub-call :around #'drgnx-hub-client-test--record)
      (unwind-protect
          (drgnx-test-gated '((sub-1 :answer "subscribe") (call-1 :answer "gateway/keys-held")
                              (call-1 :answer "gateway/register")
                              (call-1 :answer "ping") (call-1 :answer "restart") (:pause "restarted")
                              (sub-1 :eof) (call-1 :eof)
                              (sub-2 :answer "subscribe") (call-2 :answer "gateway/keys-held")
                              (sub-2 :event "gateway/need-keys") (call-2 :answer "gateway/register"))
            (add-hook 'drgnx-hub-event-functions (lambda (event data) (when (equal event "gateway/need-keys") (push data asked))))
            (drgnx-hub-connect)
            ;; the hand-over's key reaches the hub before the registration that needs it
            (drgnx-hub-client-test--wait (lambda () (and (process-live-p drgnx-hub--events) (listp drgnx-hub--keys-held)))
                                         "the subscription and the hand-over's answers")
            (setq token-1 (plist-get (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]]) 10) :token))
            (setq before (funcall given))
            (drgnx-hub-client-test--restart-and-redial)
            (drgnx-hub-client-test--wait (lambda () asked) "the hub asks for the keys")
            ;; the keys went (the subscription's own hand-over, and the answer to need-keys) before this registration
            (setq token-2 (plist-get (drgnx-hub-call-sync "gateway/register" (list :chain [["openrouter" nil]]) 10) :token))
            (drgnx-test-deliver-all))
        (advice-remove 'drgnx-hub-call #'drgnx-hub-client-test--record))
      (should (stringp token-1))
      (should (member "openrouter" (plist-get (car asked) :providers)))
      (should (>= (funcall given) (+ before 2)))
      (should (stringp token-2)))))

(ert-deftest drgnx-hub-client/a-netrc-key-goes-again-after-a-restart ()
  ;; binary (review M3): openrouter's key lives only in a plain netrc, not the environment; the hub restarts (keys live
  ;; in its memory only); the reconnect's hand-over reads the file again, without asking, and the hub holds the key
  ;; again — while this Emacs keeps neither the key nor auth-source's copy of the file
  (drgnx-hub-client-test--with-hub
    (let* ((process-environment (drgnx-hub-client-test--no-keys-env))
           (netrc (concat root "netrc")) held-again
           (auth-sources (list netrc)) (auth-source-netrc-cache nil) (password-data (make-hash-table :test #'equal))
           (drgnx-ai--keys (make-hash-table :test #'eq)) (drgnx-hub--keys-held :unknown) (drgnx-hub--editor nil)
           (cached (lambda () (or auth-source-netrc-cache
                                  (let (found) (maphash (lambda (k _) (when (eq (car-safe k) 'auth-source) (setq found t)))
                                                        password-data)
                                       found)))))
      (with-temp-file netrc (insert "machine openrouter.ai login drgnx password sk-or-netrc-m3\n"))
      (set-file-modes netrc #o600)
      (drgnx-test-gated '((sub-1 :answer "subscribe") (call-1 :answer "gateway/keys-held")
                          (call-1 :answer "ping") (call-1 :answer "restart") (:pause "restarted")
                          (sub-1 :eof) (call-1 :eof)
                          (sub-2 :answer "subscribe") (call-2 :answer "gateway/keys-held"))
        (drgnx-hub-connect)
        (drgnx-hub-client-test--wait (lambda () (and (process-live-p drgnx-hub--events)
                                                     (member "openrouter" (and (listp drgnx-hub--keys-held) drgnx-hub--keys-held))))
                                     "the editor subscribed, and the hub holds the key")
        (let ((first drgnx-hub--events))
          (drgnx-hub-client-test--restart-and-redial)
          ;; the new hub's own answer, not the list this Emacs kept from before (the old subscription's end forgot it)
          (drgnx-hub-client-test--wait (lambda () (and (not (eq drgnx-hub--events first)) (process-live-p drgnx-hub--events)
                                                       (listp drgnx-hub--keys-held)))
                                       "the new hub's answer"))
        (drgnx-test-deliver-all)
        (setq held-again drgnx-hub--keys-held))
      (should (member "openrouter" held-again))
      (should (zerop (hash-table-count drgnx-ai--keys)))
      (should-not (funcall cached))
      (should-not (gethash '(hub . key-lost-openrouter) drgnx-notice--table)))))

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

(ert-deftest drgnx-hub-client/env-resent-on-reconnect ()
  ;; the hub keeps the login shell's variables in memory only: each subscription that proved itself sends them again
  (drgnx-hub-client-test--with-fake
      (:results (list (cons "gateway/editor-token" '(:token "tok-1" :url "http://127.0.0.1:4242"))
                      (cons "gateway/keys-held" '(:providers []))))
    (let ((drgnx-hub-connected-functions (list #'drgnx-shell-env--resend))
          (drgnx-shell-env--last '(("PATH" . "/opt/x/bin:/usr/bin")))
          (process-environment (drgnx-hub-client-test--no-keys-env)))
      (drgnx-hub-connect)
      (drgnx-hub-client-test--wait (lambda () (= 1 (length (drgnx-hub-client-test--sent hub "env/set")))) "env/set sent")
      (should (equal (plist-get (car (drgnx-hub-client-test--sent hub "env/set")) :params)
                     '(:env ((:name "PATH" :value "/opt/x/bin:/usr/bin")))))
      (drgnx-hub-disconnect)
      (drgnx-hub-connect)
      (drgnx-hub-client-test--wait (lambda () (= 2 (length (drgnx-hub-client-test--sent hub "env/set")))) "env/set sent again"))))

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

;;;; The editor's subscription (HUB-RESUBSCRIBE-1)

(defun drgnx-hub-client-test--serve ()
  "Start Ratatoskr (foreground, no supervisor) on the current dirs; the process (a peer: the gate never waits on it)."
  (let ((process-environment (append (list (concat "DRGNX_DIR=" (directory-file-name drgnx-dir)) "RATATOSKR_SUPERVISOR=none"
                                           (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory)))
                                     process-environment)))
    (let ((p (make-process :name "ratatoskr" :noquery t :connection-type 'pipe :buffer (generate-new-buffer " *ratatoskr*")
                           :sentinel (lambda (p _event) (unless (process-live-p p) (process-put p :done t)))
                           :command (append (list (drgnx-hub-client-test--bin) "serve" "--foreground"
                                                  "--parent-pid" (number-to-string (emacs-pid)))
                                            drgnx-test-gate-hub-args))))
      (process-put p :drgnx-test-peer t)
      p)))

(defun drgnx-hub-client-test--hub-listens-p ()
  "Whether something accepts connections on the hub's socket (a connect, closed at once; it waits for nothing)."
  (condition-case nil
      (let ((p (make-network-process :name "drgnx-listen-probe" :family 'local :service (drgnx-hub-socket) :noquery t)))
        (delete-process p)
        t)
    (error nil)))

(defun drgnx-hub-client-test--stop (hub)
  (when (process-live-p hub) (signal-process hub 'term))
  (ignore-errors (drgnx-test-wait (lambda () (process-get hub :done)) :secs 10 :what "Ratatoskr ends"))
  (when (process-live-p hub) (signal-process hub 'kill)))

(defmacro drgnx-hub-client-test--spy (fn var &rest body)
  "BODY with every call of FN pushed (its arguments) onto VAR."
  (declare (indent 2))
  (let ((adv (make-symbol "adv")))
    `(let ((,var nil))
       (let ((,adv (lambda (orig &rest args) (push args ,var) (apply orig args))))
         (advice-add ,fn :around ,adv)
         (unwind-protect (progn ,@body) (advice-remove ,fn ,adv))))))

(ert-deftest drgnx-hub-client/resubscribes-after-restart ()
  ;; the hub ends, the client schedules its redial and, when the client's clock reaches it, subscribes again to the
  ;; hub that is back: no real time is waited
  (drgnx-hub-client-test--with-hub
    (let (scheduled since timer)
      (drgnx-test-gated '((sub-1 :answer "subscribe") (call-1 :answer "gateway/keys-held") (:pause "up")
                          (sub-1 :eof) (:pause "down") (sub-2 :answer "subscribe"))
        (drgnx-hub-connect)
        ;; the hand-over's keys-held answer is the step before the pause: the hub is stopped after it answered
        (drgnx-hub-client-test--wait (lambda () (and (process-live-p drgnx-hub--events) (listp drgnx-hub--keys-held)))
                                     "the first subscription and the hand-over's answers")
        (let ((old drgnx-hub--events))
          (signal-process hub 'term)
          (drgnx-hub-client-test--wait (lambda () (memq :eof (drgnx-test-gate-held 'sub-1)))
                                       "the first subscription's end, held")
          (drgnx-test-gate-continue "up")
          ;; the sentinel's own mark: it lets go of the subscription when it ran (`process-live-p' is nil before that)
          (drgnx-hub-client-test--wait (lambda () (not (eq drgnx-hub--events old))) "the subscription's sentinel ran")
          (setq scheduled (and (gethash 'hub-resubscribe drgnx-timer--table) t))
          (drgnx-hub-client-test--wait (lambda () (process-get hub :done)) "the hub ends")
          (setq hub (drgnx-hub-client-test--serve))
          (drgnx-hub-client-test--wait #'drgnx-hub-client-test--hub-listens-p "the hub is back")
          (drgnx-test-gate-continue "down")
          (drgnx-test-advance 1)              ; the redial's delay
          (drgnx-hub-client-test--wait (lambda () (and (process-live-p drgnx-hub--events) (not (eq drgnx-hub--events old))))
                                       "the editor subscribes again")
          (setq since drgnx-hub--resubscribe-since
                timer (gethash 'hub-resubscribe drgnx-timer--table))
          (drgnx-test-deliver-all)))
      (should scheduled)
      (should-not since)
      (should-not timer))))

(defun drgnx-hub-client-test--forget-after (after-stop)
  "Subscribe, hold the hand-over's answers on the call connection, end the hub, then release AFTER-STOP (a schedule
of `(sub-1 :eof)' and `(call-1 :answer \"gateway/keys-held\")' in some order).  (EDITOR KEYS-HELD TOKEN-SEEN): the
token and the held keys at the end, and whether the token reached `drgnx-hub-editor-token-hook'."
  (let (editor keys seen)
    (drgnx-hub-client-test--with-hub
      (drgnx-test-gated (append '((sub-1 :answer "subscribe") (:pause "stop")) after-stop)
        (add-hook 'drgnx-hub-editor-token-hook (lambda () (setq seen t)))
        (drgnx-hub-connect)
        (drgnx-hub-client-test--wait (lambda () (and (drgnx-hub-client-test--answer-held-p 'call-1 :token)
                                                     (drgnx-hub-client-test--answer-held-p 'call-1 :providers)))
                                     "the hand-over's answers, held")
        (signal-process hub 'term)
        (drgnx-hub-client-test--wait (lambda () (and (memq :eof (drgnx-test-gate-held 'sub-1))
                                                     (memq :eof (drgnx-test-gate-held 'call-1))))
                                     "both ends, held")
        (drgnx-test-gate-continue "stop")
        (drgnx-test-deliver-all)
        (setq editor drgnx-hub--editor keys drgnx-hub--keys-held)))
    (list editor keys seen)))

(ert-deftest drgnx-hub-client/forgets-token-and-keys-on-disconnect ()
  ;; the subscription's end forgets the token and the held keys, whichever order the call connection's hand-over
  ;; answers come in: after the end (they are the gone hub's, and dropped) or before it (taken, then forgotten)
  (pcase-let ((`(,editor-a ,keys-a ,seen-a)
               (drgnx-hub-client-test--forget-after '((sub-1 :eof) (call-1 :answer "gateway/keys-held"))))
              (`(,editor-b ,keys-b ,seen-b)
               (drgnx-hub-client-test--forget-after '((call-1 :answer "gateway/keys-held") (sub-1 :eof)))))
    (should-not editor-a)
    (should (eq keys-a :unknown))
    (should-not seen-a)
    (should-not editor-b)
    (should (eq keys-b :unknown))
    (should seen-b)))

(ert-deftest drgnx-hub-client/an-answer-read-after-the-subscription-ended-is-dropped ()
  ;; Ratatoskr ends its connections in any order: the hand-over's answers on the call connection can be read after the
  ;; subscription's end forgot the token and the held keys.  They are the gone hub's, and are dropped.
  (drgnx-hub-client-test--with-fake (:silent '("gateway/editor-token" "gateway/keys-held"))
    (let ((drgnx-hub--editor nil) (drgnx-hub--keys-held :unknown) (process-environment (drgnx-hub-client-test--no-keys-env))
          (questions nil))
      (drgnx-hub-connect)
      (drgnx-hub-client-test--wait (lambda () (member "gateway/keys-held" (drgnx-fake-hub-methods hub))) "the hand-over's questions")
      (setq questions (seq-filter (lambda (l) (member (plist-get l :method) '("gateway/editor-token" "gateway/keys-held")))
                                  (drgnx-fake-hub-lines hub)))
      (should (= (length questions) 2))
      ;; the subscription ends unasked: the token and the held keys are forgotten
      (delete-process drgnx-hub--events)
      (drgnx-hub-client-test--wait (lambda () (null drgnx-hub--events)) "the subscription ends")
      (should (eq drgnx-hub--keys-held :unknown))
      ;; then the answers come, on the call connection
      (dolist (q questions)
        (drgnx-fake-hub-answer hub q (if (equal (plist-get q :method) "gateway/keys-held")
                                         '(:providers ["openrouter"])
                                       '(:token "tok-late" :url "http://127.0.0.1:4242"))))
      (drgnx-hub-client-test--wait (lambda () (cl-notany (lambda (q) (gethash (plist-get q :id) drgnx-hub--pending)) questions))
                                   "the answers read")
      (should-not drgnx-hub--editor)
      (should (eq drgnx-hub--keys-held :unknown)))))

(ert-deftest drgnx-hub-client/no-resubscribe-after-asked-disconnect ()
  (drgnx-hub-client-test--with-hub
    (let (timer-1 since-1 dials-1 asked timer-2 since-2)
      (drgnx-test-gated '((sub-1 :answer "subscribe") (sub-2 :answer "subscribe") (:pause "shutdown") (sub-2 :eof))
        ;; drgnx-hub-disconnect
        (drgnx-hub-client-test--spy 'drgnx-hub-connect dials
          (drgnx-hub-connect)
          (drgnx-hub-client-test--wait (lambda () (process-live-p drgnx-hub--events)) "the subscription")
          (drgnx-hub-disconnect)
          (drgnx-test-advance 5)            ; past the first redial's delay
          (setq timer-1 (gethash 'hub-resubscribe drgnx-timer--table)
                since-1 drgnx-hub--resubscribe-since
                dials-1 (length dials)))
        ;; a shutdown this editor sent
        (drgnx-hub-connect)
        (drgnx-hub-client-test--wait (lambda () (process-live-p drgnx-hub--events)) "the second subscription")
        (drgnx-test-gate-continue "shutdown")
        (drgnx-hub-call "shutdown" nil #'ignore)
        (drgnx-hub-client-test--wait (lambda () (process-get hub :done)) "Ratatoskr shuts down")
        (drgnx-hub-client-test--wait (lambda () (null drgnx-hub--events)) "the subscription ends")
        (setq asked drgnx-hub--asked-disconnect
              timer-2 (gethash 'hub-resubscribe drgnx-timer--table)
              since-2 drgnx-hub--resubscribe-since))
      (should-not timer-1)
      (should-not since-1)
      (should (= dials-1 1))
      (should asked)
      (should-not timer-2)
      (should-not since-2))))

(ert-deftest drgnx-hub-client/gives-up-after-ten-minutes ()
  ;; the clock is injected: backoff 1, 2, 4 … 30 s; at 600 s one notice naming Hub: Restart Now
  (let ((now 1000.0) (drgnx-hub--resubscribe-since nil) (drgnx-hub--resubscribe-delay 1) (starts nil) (notices nil))
    (cl-letf (((symbol-function 'drgnx-timer--now) (lambda () now))
              ((symbol-function 'drgnx-timer-start)
               (lambda (key secs &rest _) (when (eq key 'hub-resubscribe) (push secs starts))))
              ((symbol-function 'drgnx-notify) (lambda (&rest args) (push args notices))))
      (dotimes (_ 8) (drgnx-hub--resubscribe-schedule))
      (should (equal (nreverse starts) '(1 2 4 8 16 30 30 30)))
      (setq now (+ 1000.0 599))
      (drgnx-hub--resubscribe-schedule)
      (should-not notices)
      (setq now (+ 1000.0 600))
      (drgnx-hub--resubscribe-schedule)
      (should (= (length notices) 1))
      (should (eq (plist-get (cdddr (car notices)) :command) 'hub-restart-now))
      (should (string-match-p "Hub: Restart Now" (nth 2 (car notices))))
      (should-not drgnx-hub--resubscribe-since))))

(ert-deftest drgnx-hub-client/never-runs-ensure ()
  (drgnx-hub-client-test--with-hub
    (let (redials ensured ran)
      (drgnx-test-gated '((sub-1 :answer "subscribe") (:pause "down") (sub-1 :eof))
        (drgnx-hub-connect)
        (drgnx-hub-client-test--wait (lambda () (process-live-p drgnx-hub--events)) "the subscription")
        (drgnx-hub-client-test--spy 'drgnx-hub-ensure ensures
          (drgnx-hub-client-test--spy 'drgnx-hub--ensure-running runs
            (drgnx-hub-client-test--spy 'drgnx-hub-connect dials
              (drgnx-hub-client-test--stop hub)
              (drgnx-test-gate-continue "down")
              (drgnx-hub-client-test--wait (lambda () (null drgnx-hub--events)) "the subscription ends")
              (drgnx-test-advance 1)        ; the first redial, against a hub that stays down
              (drgnx-test-advance 2)        ; the second
              (setq redials (length dials) ensured ensures ran runs)))))
      (should (>= redials 2))
      (should-not ensured)
      (should-not ran))))

(ert-deftest drgnx-hub-client/matrix-card-shown ()
  ;; a matrix card and a supervisor pause become notices of the hub; nothing asks, nothing waits; agent-step is ignored
  (drgnx-notice-test-with-model
    (let ((conn (make-pipe-process :name "matrix-card-test" :noquery t)))
      (unwind-protect
          (progn
            (process-put conn :drgnx-proven t)
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (error "prompted")))
                      ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "prompted"))))
              (let ((inhibit-interaction t) (drgnx-hub--event-conn conn))
                (drgnx-hub--note-card "agent-step" '(:session "s1"))
                (should-not (drgnx-notices :source 'hub))
                (drgnx-hub--note-card "card" '(:id 7 :kind "matrix" :title "Run make?"))
                (drgnx-hub--note-card "supervisor" '(:rule "loop" :session "s1" :card 8 :text "same call 5 times"))))
            (should (= (length (drgnx-notices :source 'hub)) 2)))
        (delete-process conn)))))

;;; hub-client-test.el ends here
