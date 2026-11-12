;;; hub-client-fixture.el --- the hub client tests' helpers: a root, a waiting, Ratatoskr, a gated hub -*- lexical-binding: t -*-
;; Loaded by test/unit/hub-client-test.el and by every test that drives Ratatoskr through these macros.  They live
;; here, apart from the tests, so that loading them registers no test: a file that loaded hub-client-test.el whole ran
;; its 54 tests again in its own session (the GUI tier's failed on the 11 that need the binary or the test clock).
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
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)   ; `drgnx-test-no-hub'
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
binary (failed where the hub is required: `drgnx-test-no-hub').  For the tests of other files that drive a real agent through the hub and wait on conditions of their own (the
agents mirror's): their order is the agent's, not the gate's."
  (declare (indent 0))
  `(drgnx-hub-client-test--with
     (unless (drgnx-hub-client-test--bin) (drgnx-test-no-hub))
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

(provide 'hub-client-fixture)
;;; hub-client-fixture.el ends here
