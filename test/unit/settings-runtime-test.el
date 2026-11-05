;;; settings-runtime-test.el --- batch tests: the editor's override sender (unified settings Task 22) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-settings-runtime)
(require 'drgnx-hub-client)
(require 'drgnx-ai)
(require 'drgnx-agents)

(defmacro drgnx-settings-runtime-test--with (kind &rest body)
  "BODY with only `drgnx-agents-default' as a runtime setting, its winner of KIND, and the hub calls recorded in CALLS."
  (declare (indent 1))
  `(let ((calls nil) (old (default-value 'drgnx-agents-default)))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-settings-runtime--vars) (lambda () '(drgnx-agents-default)))
                   ((symbol-function 'drgnx-settings-explain)
                    (lambda (&rest _) '(:kind ,kind :file "/c/config.el")))
                   ((symbol-function 'drgnx-hub-call)
                    (lambda (method params _cb) (push (list method params) calls) 1)))
           (set-default 'drgnx-agents-default "mine")
           ,@body)
       (set-default 'drgnx-agents-default old))))

(ert-deftest drgnx-settings-runtime/lisp-winner-sends-an-override ()
  (drgnx-settings-runtime-test--with lisp
    (should (equal (drgnx-settings-runtime-overrides)
                   '((:name "drgnx-agents-default" :value "mine" :source "lisp:config.el"))))))

(ert-deftest drgnx-settings-runtime/settings-el-winner-sends-nothing ()
  (drgnx-settings-runtime-test--with settings
    (should-not (drgnx-settings-runtime-overrides))))

(ert-deftest drgnx-settings-runtime/a-workspace-value-is-a-project-override ()
  (drgnx-settings-runtime-test--with settings
    (cl-letf (((symbol-function 'drgnx-setting-for-root) (lambda (&rest _) "theirs"))
              ((symbol-function 'drgnx-settings-workspace-project) (lambda (_) '("proj" . "/r/"))))
      ;; the hub refuses a project override of a setting that is not `:scope project': it is not sent
      (should-not (drgnx-settings-runtime-overrides "/r/"))
      (cl-letf (((symbol-function 'drgnx-setting-meta) (lambda (_) '(:scope project))))
        (should (equal (drgnx-settings-runtime-overrides "/r/")
                       '((:name "drgnx-agents-default" :value "theirs" :source "workspace"))))
        (drgnx-settings-runtime-send "/r/")
        (should (equal (car calls)
                       '("config/settings" (:project "proj" :overrides
                                                     [(:name "drgnx-agents-default" :value "theirs" :source "workspace")]))))))
    ;; a root whose project Urdr does not know yet sends nothing
    (setq calls nil)
    (cl-letf (((symbol-function 'drgnx-settings-workspace-project) (lambda (_) nil)))
      (should-not (drgnx-settings-runtime-send "/r/"))
      (should-not calls))))

(ert-deftest drgnx-settings-runtime/empty-list-when-it-goes-away ()
  (drgnx-settings-runtime-test--with settings
    (drgnx-settings-runtime-send)
    (should (equal (car calls) '("config/settings" (:overrides []))))))

(ert-deftest drgnx-settings-runtime/provider-is-a-provider-entry-without-a-key ()
  (should (equal (funcall (alist-get 'drgnx-ai-providers drgnx-settings-runtime--encoders)
                          '((lan :name "LAN" :kind openai :url "http://h/v1" :key-env "LAN_KEY" :caps (chat chat embed)
                                 :price (1 . 2) :messages t :auth x-api-key)))
                 '(:lan (:name "LAN" :kind "openai" :url "http://h/v1" :key_env "LAN_KEY" :caps ["chat" "embed"]
                               :price [1 2] :messages t :auth "x-api-key")))))

(ert-deftest drgnx-settings-runtime/sent-on-connect-and-change ()
  (drgnx-settings-runtime-test--with lisp
    (cl-letf (((symbol-function 'drgnx-settings-runtime--live-p) (lambda () t))
              ((symbol-function 'drgnx-settings-live--global-p) (lambda (_) nil)))
      (run-hook-with-args 'drgnx-settings-changed-functions "/c/workspace.el" nil)
      (should (equal (mapcar #'car calls) '("config/settings"))))
    ;; not connected: nothing (the connection's hand-over sends the set)
    (setq calls nil)
    (cl-letf (((symbol-function 'drgnx-settings-runtime--live-p) (lambda () nil)))
      (run-hook-with-args 'drgnx-settings-changed-functions "/c/settings.el" nil)
      (should-not calls))))

(ert-deftest drgnx-settings-runtime/config-changed-after-a-write ()
  (drgnx-settings-runtime-test--with settings
    (cl-letf (((symbol-function 'drgnx-settings-runtime--live-p) (lambda () t))
              ((symbol-function 'drgnx-settings-live--global-p) (lambda (f) (equal f "/c/settings.el"))))
      (run-hook-with-args 'drgnx-settings-file-written-functions "/c/settings.el" nil nil)
      (should (equal (mapcar #'car calls) '("config/changed")))
      (setq calls nil)
      (run-hook-with-args 'drgnx-settings-file-written-functions "/c/workspace.el" nil nil)
      (should-not calls))))

;; Pattern D.  A runtime setting with no encoder never reaches the hub when only your Lisp or Customize sets it: every
;; one has one but the matrix itself, whose plist the hub reads from settings.el alone.
(ert-deftest drgnx-settings-runtime/every-runtime-setting-but-the-matrix-has-an-encoder ()
  (require 'drgnx-agents-matrix)
  (let (missing)
    (dolist (var (drgnx-setting-names))
      (when (and (plist-get (drgnx-setting-meta var) :runtime) (not (eq var 'drgnx-agents-matrix))
                 (not (assq var drgnx-settings-runtime--encoders)))
        (push var missing)))
    (should-not missing)))

;; Pattern D.  The pins and the agent limits go as the JSON the hub's `from_json' takes for their runtime types.
(ert-deftest drgnx-settings-runtime/pins-and-limits-encode-as-the-hub-reads-them ()
  (let ((enc (lambda (var value)
               (json-serialize (funcall (alist-get var drgnx-settings-runtime--encoders) value)))))
    (should (equal (funcall enc 'drgnx-sandbox-proxy-pinned-addresses
                            '(("registry.corp" . "10.0.0.5") ("v6.test" . "::1")))
                   "{\"registry.corp\":\"10.0.0.5\",\"v6.test\":\"::1\"}"))
    (should (equal (funcall enc 'drgnx-agents-net-hosts '((packages "crates.io:443")))
                   "{\"packages\":[\"crates.io:443\"]}"))
    (should (equal (funcall enc 'drgnx-agents-silent-after '((task . 600))) "{\"task\":600}"))
    (should (equal (funcall enc 'drgnx-agents-container-images '(("tools" . "r@sha256:00")))
                   "{\"tools\":\"r@sha256:00\"}"))
    (should (equal (funcall enc 'drgnx-agents-away-after 600) "600"))
    (should (equal (funcall enc 'drgnx-agents-job-memory "4G") "\"4G\""))
    (should (equal (funcall enc 'drgnx-agents-manager-context 0.7) "0.7"))))

(ert-deftest drgnx-settings-runtime/the-old-sender-is-gone ()
  (dolist (f '(drgnx-hub--send-providers drgnx-hub--providers-table drgnx-hub--provider-json drgnx-hub-resend-providers
                                         drgnx-ai--settings-changed drgnx-ai--config-changed))
    (should-not (fboundp f))))

;;; settings-runtime-test.el ends here
