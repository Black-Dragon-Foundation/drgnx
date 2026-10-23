;;; agents-eld-test.el --- batch tests: agents.eld folded into settings.el (the drgnx-agents-* settings) -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-runtime-settings' (the eight runtime settings at their defaults, a temp
;; config folder, the applier's state fresh).  Values here are fakes; the file holds command names and variable
;; names, never keys.  The old file's layer behaviours (last good copy, one stat, the hub reading it) are the
;; config layer's and the live re-read's now (settings-live-test.el).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(require 'drgnx-agents)
(require 'drgnx-job)

(defconst drgnx-agents-eld-test--builtin-names
  (mapcar #'car drgnx-agents-builtin-profiles) "The built-in profiles' names.")

;;;; The declarations

(ert-deftest drgnx-agents/settings-are-strict-and-never-for-agents ()
  (dolist (var '(drgnx-agents-profiles drgnx-agents-default drgnx-agents-mcp drgnx-agents-routes
                                       drgnx-agents-openrouter drgnx-agents-allow-unsandboxed))
    (let ((meta (drgnx-setting-meta var)))
      (should (drgnx-setting-own-p var))
      (should (eq (plist-get meta :on-error) 'strict))
      (should (eq (plist-get meta :agents) 'never))
      (should (eq (plist-get meta :scope) 'global))
      (should (eq (plist-get meta :workspace) 'never)) ; US-WORKSPACE-NEVER-1: a workspace file's refusal catches them
      (should (stringp (plist-get meta :runtime)))))
  (dolist (var '(drgnx-ai-providers drgnx-ai-roles))
    (let ((meta (drgnx-setting-meta var)))
      (should (eq (plist-get meta :agents) 'never))
      (should (stringp (plist-get meta :runtime)))))
  (should (eq (plist-get (drgnx-setting-meta 'drgnx-ai-providers) :workspace) 'never)))

(ert-deftest drgnx-agents/the-defaults-are-the-shipped-ones ()
  (dolist (var '(drgnx-agents-profiles drgnx-agents-default drgnx-agents-mcp drgnx-agents-routes
                                       drgnx-agents-openrouter drgnx-agents-allow-unsandboxed))
    (should (equal (eval (car (get var 'standard-value)) t) (drgnx-settings-defaults-value var))))
  (should (equal (eval (car (get 'drgnx-agents-mcp 'standard-value)) t) '(coordination)))
  (should (null (eval (car (get 'drgnx-agents-allow-unsandboxed 'standard-value)) t))))

;;;; The fallback

(ert-deftest drgnx-agents-eld/a-mistake-falls-back-to-the-built-in-profiles-only ()
  (drgnx-test-with-runtime-settings
    (drgnx-test-runtime-settings-put
     "(drgnx-agents-profiles ((\"mine\" :command \"not-a-list\")))"
     "(drgnx-agents-default \"mine\")"
     "(drgnx-agents-mcp (coordination search))")
    ;; the bad profiles entry is replaced by the default; the others apply
    (should (seq-find (lambda (p) (eq (plist-get p :var) 'drgnx-agents-profiles)) drgnx-settings-apply-problems))
    (should (equal (drgnx-agents-profile-names) drgnx-agents-eld-test--builtin-names))
    (should-error (drgnx-agents-profile "mine") :type 'user-error)
    (should (equal (drgnx-agents-mcp-names) '(coordination search)))
    (should (equal (drgnx-agents-default-profile) "claude"))))

(ert-deftest drgnx-agents-eld/a-file-that-does-not-read-gives-the-strict-defaults ()
  (drgnx-test-with-runtime-settings
    (drgnx-test-runtime-settings-put "(drgnx-agents-default \"mine\")"
                                     "(drgnx-agents-profiles ((\"mine\" :command (\"x\"))))")
    (should (equal (drgnx-agents-default-profile) "mine"))
    (drgnx-test-config-put 'settings "(drgnx-settings :version 1 (drgnx-agents-default \"mine\")\n") ; unclosed
    (drgnx-settings-apply-global)
    (should (equal (drgnx-agents-default-profile) "claude"))
    (should (equal (drgnx-agents-mcp-names) '(coordination)))
    (should-not (member "mine" (drgnx-agents-profile-names)))))

(ert-deftest drgnx-agents-eld/an-empty-mcp-list-is-none-and-an-absent-one-is-coordination ()
  (drgnx-test-with-runtime-settings
    (should (equal (drgnx-agents-mcp-names) '(coordination)))          ; no file
    (drgnx-test-runtime-settings-put "(drgnx-agents-default \"claude\")")
    (should (equal (drgnx-agents-mcp-names) '(coordination)))
    (drgnx-test-runtime-settings-put "(drgnx-agents-mcp ())")
    (should (null (drgnx-agents-mcp-names)))))

(ert-deftest drgnx-agents-eld/a-buffer-local-value-never-reaches-the-callers ()
  (drgnx-test-with-runtime-settings
    (drgnx-test-set-runtime 'drgnx-agents-mcp '(search))
    (with-temp-buffer
      (setq-local drgnx-agents-mcp '(coordination search))
      (setq-local drgnx-agents-profiles '(("evil" :command ("rm"))))
      (should (equal (drgnx-agents-mcp-names) '(search)))
      (should-not (member "evil" (drgnx-agents-profile-names))))))

;;;; OpenRouter

(ert-deftest drgnx-agents-eld/openrouter-agents-refuse-while-it-has-a-mistake ()
  (drgnx-test-with-runtime-settings
    (drgnx-test-runtime-settings-put "(drgnx-agents-openrouter (:only (\"anthropic\")))")
    (should (equal (drgnx-agents-openrouter-restrictions) '(:only ("anthropic"))))
    (drgnx-test-config-put 'settings "(drgnx-settings :version 1 (drgnx-agents-openrouter (:only (\"anthropic\")))\n")
    (drgnx-settings-apply-global)
    (let ((err (should-error (drgnx-agents-openrouter-restrictions) :type 'user-error)))
      (should (string-match-p "settings\\.el has a mistake (line [0-9]+: .+): OpenRouter agents do not start until it is fixed"
                              (error-message-string err))))
    (drgnx-test-runtime-settings-put "(drgnx-agents-openrouter (:only (\"anthropic\")))")        ; fixed
    (should (equal (drgnx-agents-openrouter-restrictions) '(:only ("anthropic"))))))

(ert-deftest drgnx-agents-eld/a-bad-openrouter-value-is-a-problem ()
  (drgnx-test-with-runtime-settings
    (drgnx-test-runtime-settings-put "(drgnx-agents-openrouter (:zdr yes))")
    (let ((p (seq-find (lambda (p) (eq (plist-get p :var) 'drgnx-agents-openrouter)) drgnx-settings-apply-problems)))
      (should p)
      (should (string-search "not an OpenRouter restriction" (plist-get p :text)))
      (should (string-search ":zdr is yes" (plist-get p :text))))
    (should-error (drgnx-agents-openrouter-restrictions) :type 'user-error)
    (drgnx-test-runtime-settings-put "(drgnx-agents-openrouter (:only (\"ok\") :data-collection deny :zdr t))")
    (should-not drgnx-settings-apply-problems)
    (should (equal (drgnx-agents-openrouter-restrictions) '(:only ("ok") :data-collection deny :zdr t)))
    (drgnx-test-runtime-settings-put "(drgnx-agents-openrouter nil)")                          ; none set
    (should-not (drgnx-agents-openrouter-restrictions))))

;;;; Writing

(ert-deftest drgnx-agents-eld/set-setting-keeps-comments-and-env ()
  (drgnx-test-with-runtime-settings
    (let ((text ";; my agents\n(drgnx-settings\n :version 1\n ;; mine\n (drgnx-agents-profiles ((\"mine\" :command (\"x\" \"--flag\") ; the program\n                          :env (\"FOO=bar\" \"BAZ=1\")))\n )\n ) ; end\n"))
      (drgnx-test-config-put 'settings text)
      (drgnx-settings-apply-global)
      (drgnx-agents-set-setting :default "mine")
      (drgnx-agents-set-setting :mcp '(coordination search))
      (let ((new (drgnx-test-settings-text)))
        (should (string-search ";; mine\n (drgnx-agents-profiles ((\"mine\" :command (\"x\" \"--flag\") ; the program" new))
        (should (string-search "(drgnx-agents-default \"mine\")" new))
        (should (string-search "(drgnx-agents-mcp (coordination search))" new)))
      (should (equal (drgnx-agents-default-profile) "mine"))
      (should (equal (drgnx-agents-mcp-names) '(coordination search)))
      (should (equal (plist-get (cdr (drgnx-agents-profile "mine")) :env) '("FOO=bar" "BAZ=1")))
      (drgnx-agents-set-setting :mcp nil)
      (should (null (drgnx-agents-mcp-names)))
      (should (string-search "(drgnx-agents-mcp nil)" (drgnx-test-settings-text))))))

(ert-deftest drgnx-agents-eld/set-setting-refuses-a-file-with-a-mistake ()
  (drgnx-test-with-runtime-settings
    (let ((text "(drgnx-settings :version 1 (drgnx-agents-default \"mine\")\n"))                  ; does not read
      (drgnx-test-config-put 'settings text)
      (should-error (drgnx-agents-set-setting :default "mine") :type 'user-error)
      (should-error (drgnx-agents-set-setting :mcp '(search)) :type 'drgnx-settings-refused)
      (should (equal (drgnx-test-settings-text) text)))
    (should-error (drgnx-agents-set-setting :nonsense 1) :type 'user-error)))

;;;; Routes

(ert-deftest drgnx-agents-eld/routes-come-from-the-settings ()
  (drgnx-test-with-runtime-settings
    (let ((drgnx-job-routes nil))
      (drgnx-test-runtime-settings-put "(drgnx-agents-routes ((implement \"a\" \"b\") (review \"c\")))")
      (should (equal (drgnx-job--routes) '((implement "a" "b") (review "c"))))
      (should (equal (drgnx-job-route 'implement) '("a" "b")))
      (let ((drgnx-job-routes '((implement "z")))) (should (equal (drgnx-job-route 'implement) '("z"))))
      (drgnx-test-runtime-settings-put "(drgnx-agents-routes ((implement . \"a\") (review \"c\")))") ; the v1 dotted form
      (should-not drgnx-settings-apply-problems)
      (should (equal (drgnx-job-route 'implement) '("a")))
      (should (equal (drgnx-job-route 'review) '("c")))
      (drgnx-test-runtime-settings-put "(drgnx-agents-routes ((implement . 5)))")                  ; neither: a mistake
      (should drgnx-settings-apply-problems)
      (should-not (drgnx-job--routes)))))

(ert-deftest drgnx-agents-eld/a-dotted-route-keeps-the-profiles-and-openrouter-agents ()
  ;; (ROLE . "profile") is a documented v1 form: it is never a mistake that voids the rest of the file
  (drgnx-test-with-runtime-settings
    (drgnx-test-runtime-settings-put
     "(drgnx-agents-profiles ((\"mine\" :command (\"x\"))))"
     "(drgnx-agents-openrouter (:only (\"anthropic\")))"
     "(drgnx-agents-routes ((review . \"claude\") (implement \"a\")))")
    (should-not drgnx-settings-apply-problems)
    (should (drgnx-agents-profile "mine"))
    (should (equal (drgnx-agents-openrouter-restrictions) '(:only ("anthropic"))))
    (should (equal (drgnx-job-route 'review) '("claude")))
    (should (equal (drgnx-job-route 'implement) '("a")))))

;;; agents-eld-test.el ends here
