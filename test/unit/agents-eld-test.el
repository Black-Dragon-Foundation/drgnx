;;; agents-eld-test.el --- batch tests: agents.eld through the config layer -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-config' (temp config and state folders).  Values here are fakes; the file
;; holds command names and variable names, never keys.  The hub test loads drgnx-config and drgnx-agents in a child
;; `emacs --batch -Q', waited for under a 30 s bound.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-agents)
(require 'drgnx-job)

(defun drgnx-agents-eld-test--put (text) (drgnx-test-config-put 'agents text))
(defun drgnx-agents-eld-test--text () (drgnx-test-config-text 'agents))

(defconst drgnx-agents-eld-test--builtin-names
  (mapcar #'car drgnx-agents-builtin-profiles) "The built-in profiles' names.")

;;;; The fallback

(ert-deftest drgnx-agents-eld/a-mistake-falls-back-to-the-built-in-profiles-only ()
  (drgnx-test-with-config
    (let ((drgnx-agents-profiles nil))
      (drgnx-agents-eld-test--put
       "(:profiles ((\"mine\" :command \"not-a-list\")) :default \"mine\" :mcp (coordination search))\n")
      (should (drgnx-config-problem 'agents))
      (should (equal (drgnx-agents-profile-names) drgnx-agents-eld-test--builtin-names))
      (should-error (drgnx-agents-profile "mine") :type 'user-error)
      (should (equal (drgnx-agents-mcp-names) '(coordination)))
      (should (equal (drgnx-agents-default-profile) "claude")))))

(ert-deftest drgnx-agents-eld/there-is-no-last-good-copy ()
  (drgnx-test-with-config
    (let ((drgnx-agents-profiles nil))
      (drgnx-agents-eld-test--put "(:profiles ((\"mine\" :command (\"x\"))) :default \"mine\" :mcp (search))\n")
      (should (equal (drgnx-agents-default-profile) "mine"))
      (should (equal (drgnx-agents-mcp-names) '(search)))
      (drgnx-agents-eld-test--put "(:profiles ((\"mine\" :command (\"x\"))) :default \"mine\" :mcp (search)\n") ; unclosed
      (should (drgnx-config-problem 'agents))
      (should-not (drgnx-config-get 'agents :default))
      (should (equal (drgnx-agents-default-profile) "claude"))
      (should (equal (drgnx-agents-mcp-names) '(coordination)))
      (should-not (member "mine" (drgnx-agents-profile-names))))))

(ert-deftest drgnx-agents-eld/an-empty-mcp-list-is-none-and-an-absent-one-is-coordination ()
  (drgnx-test-with-config
    (should (equal (drgnx-agents-mcp-names) '(coordination)))          ; no file
    (drgnx-agents-eld-test--put "(:default \"claude\")\n")
    (should (equal (drgnx-agents-mcp-names) '(coordination)))
    (drgnx-agents-eld-test--put "(:mcp ())\n")
    (should (null (drgnx-agents-mcp-names)))))

;;;; OpenRouter

(ert-deftest drgnx-agents-eld/openrouter-agents-refuse-while-it-has-a-mistake ()
  (drgnx-test-with-config
    (drgnx-agents-eld-test--put "(:openrouter (:only (\"anthropic\"))\n :mcp (coordination\n")
    (let ((err (should-error (drgnx-agents-openrouter-restrictions) :type 'user-error)))
      (should (string-match-p "agents\\.eld has a mistake (line [0-9]+: .+): OpenRouter agents do not start until it is fixed"
                              (error-message-string err))))
    (drgnx-agents-eld-test--put "(:openrouter (:only (\"anthropic\")))\n")                ; fixed
    (should (equal (drgnx-agents-openrouter-restrictions) '(:only ("anthropic"))))))

(ert-deftest drgnx-agents-eld/a-bad-openrouter-value-is-a-problem ()
  (drgnx-test-with-config
    (drgnx-agents-eld-test--put "(:openrouter (:zdr yes))\n")
    (let ((p (drgnx-config-problem 'agents)))
      (should p)
      (should (string-search "not an OpenRouter restriction" (plist-get p :text)))
      (should (string-search ":zdr is yes" (plist-get p :text))))
    (should-error (drgnx-agents-openrouter-restrictions) :type 'user-error)
    (drgnx-agents-eld-test--put "(:openrouter (:only (\"ok\") :data-collection deny :zdr t))\n")
    (should-not (drgnx-config-problem 'agents))
    (should (equal (drgnx-agents-openrouter-restrictions) '(:only ("ok") :data-collection deny :zdr t)))
    (drgnx-agents-eld-test--put "(:profiles nil)\n")                                       ; none set
    (should-not (drgnx-agents-openrouter-restrictions))))

;;;; Writing

(ert-deftest drgnx-agents-eld/set-setting-keeps-comments-and-env ()
  (drgnx-test-with-config
    (let ((text ";; my agents\n(:profiles ((\"mine\" :command (\"x\" \"--flag\") ; the program\n               :env (\"FOO=bar\" \"BAZ=1\")))\n :routes ((implement \"mine\"))) ; end\n"))
      (drgnx-agents-eld-test--put text)
      (drgnx-agents-set-setting :default "mine")
      (drgnx-agents-set-setting :mcp '(coordination search))
      (let ((new (drgnx-agents-eld-test--text)))
        (should (string-prefix-p ";; my agents\n(:profiles ((\"mine\" :command (\"x\" \"--flag\") ; the program\n               :env (\"FOO=bar\" \"BAZ=1\")))" new))
        (should (string-search ":routes ((implement \"mine\"))\n" new))
        (should (string-suffix-p ") ; end\n" new))
        (should (string-search ":default \"mine\"" new)))
      (should (equal (drgnx-agents-default-profile) "mine"))
      (should (equal (drgnx-agents-mcp-names) '(coordination search)))
      (should (equal (plist-get (cdr (drgnx-agents-profile "mine")) :env) '("FOO=bar" "BAZ=1")))
      (drgnx-agents-set-setting :mcp nil)
      (should (null (drgnx-agents-mcp-names)))
      (should (string-search ":mcp nil" (drgnx-agents-eld-test--text))))))

(ert-deftest drgnx-agents-eld/set-setting-refuses-a-file-with-a-mistake ()
  (drgnx-test-with-config
    (let ((text "(:profiles ((\"mine\" :command (\"x\"))) ; typo below\n :default 5)\n"))
      (drgnx-agents-eld-test--put text)
      (should-error (drgnx-agents-set-setting :mcp '(search)) :type 'drgnx-config-refused)
      (should-error (drgnx-agents-set-setting :mcp '(search)) :type 'user-error)
      (should (equal (drgnx-agents-eld-test--text) text)))
    (let ((text "(:profiles ((\"mine\" :command (\"x\"))\n"))                          ; does not read
      (drgnx-agents-eld-test--put text)
      (should-error (drgnx-agents-set-setting :default "mine") :type 'user-error)
      (should (equal (drgnx-agents-eld-test--text) text)))))

;;;; Routes and cost

(ert-deftest drgnx-agents-eld/routes-come-from-the-layer ()
  (drgnx-test-with-config
    (let ((drgnx-job-routes nil))
      (drgnx-agents-eld-test--put "(:routes ((implement \"a\" \"b\") (review \"c\")))\n")
      (should (equal (drgnx-job--routes) '((implement "a" "b") (review "c"))))
      (should (equal (drgnx-job-route 'implement) '("a" "b")))
      (let ((drgnx-job-routes '((implement "z")))) (should (equal (drgnx-job-route 'implement) '("z"))))
      (drgnx-agents-eld-test--put "(:routes ((implement . \"a\") (review \"c\")))\n")  ; one name, dotted: the v1 form
      (should-not (drgnx-config-problem 'agents))
      (should (equal (drgnx-job-route 'implement) '("a")))
      (should (equal (drgnx-job-route 'review) '("c")))
      (drgnx-agents-eld-test--put "(:routes ((implement . 5)))\n")                  ; neither a name nor a list: a mistake
      (should (drgnx-config-problem 'agents))
      (should-not (drgnx-job--routes)))))

(ert-deftest drgnx-agents-eld/a-dotted-route-keeps-the-profiles-and-openrouter-agents ()
  ;; (ROLE . "profile") is a documented v1 form: it is never a mistake that voids the rest of the file
  (drgnx-test-with-config
    (drgnx-agents-eld-test--put
     "(:profiles ((\"mine\" :command (\"x\"))) :openrouter (:only (\"anthropic\"))\n :routes ((review . \"claude\") (implement \"a\")))\n")
    (should-not (drgnx-config-problem 'agents))
    (should (drgnx-agents-profile "mine"))
    (should (equal (drgnx-agents-openrouter-restrictions) '(:only ("anthropic"))))
    (should (equal (drgnx-job-route 'review) '("claude")))
    (should (equal (drgnx-job-route 'implement) '("a")))))

(ert-deftest drgnx-agents-eld/one-stat-per-get ()
  (drgnx-test-with-config
    (drgnx-agents-eld-test--put "(:profiles ((\"mine\" :command (\"x\"))) :mcp (search))\n")
    (drgnx-agents-mcp-names)
    (let* ((n 0) (count (lambda (&rest _) (setq n (1+ n)))))
      (advice-add 'file-attributes :before count)
      (unwind-protect
          (progn (should (equal (drgnx-agents-mcp-names) '(search)))
                 (should (= n 1))
                 (setq n 0)
                 (should (drgnx-agents-profile "mine"))
                 (should (= n 1))
                 (setq n 0)
                 (should-not (drgnx-job--routes))
                 (should (= n 1)))
        (advice-remove 'file-attributes count)))))

;;;; The hub

(defun drgnx-agents-eld-test--wait (proc buf pattern)
  "Wait for PROC's output in BUF to match PATTERN, under 30 s; the output."
  (let ((deadline (+ (float-time) 30)))
    (while (and (process-live-p proc) (< (float-time) deadline)
                (not (string-match-p pattern (with-current-buffer buf (buffer-string)))))
      (accept-process-output proc 0.05))
    (with-current-buffer buf (buffer-string))))

(ert-deftest drgnx-agents-eld/the-hub-reads-it-under-batch-q ()
  (drgnx-test-with-config
    (let* ((core (file-name-directory (locate-library "drgnx-config.el")))
           (go (concat drgnx-test-config-root "go"))
           (buf (generate-new-buffer " *drgnx-agents-eld-hub*" t)))
      (unwind-protect
          (progn
            (drgnx-agents-eld-test--put "(:profiles ((\"one\" :command (\"x\"))) :default \"one\")\n")
            (let ((proc (make-process
                         :name "drgnx-agents-eld-hub" :buffer buf :noquery t
                         :stderr (generate-new-buffer " *drgnx-agents-eld-hub-err*" t)
                         :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                        "-L" (directory-file-name core) "-l" "drgnx-config" "-l" "drgnx-agents"
                                        "--eval" (format "(progn (prin1 (list 'first (drgnx-config-get 'agents :default) (drgnx-config-problem 'agents))) (terpri)
 (while (not (file-exists-p %S)) (sleep-for 0.05))
 (prin1 (list 'second (drgnx-config-get 'agents :default))) (terpri))" go)))))
              (should (string-match-p "(first \"one\" nil)" (drgnx-agents-eld-test--wait proc buf "(first")))
              (drgnx-agents-eld-test--put "(:profiles ((\"two\" :command (\"x\"))) :default \"two\")\n")
              (write-region "" nil go nil 'silent)
              (should (string-match-p "(second \"two\")" (drgnx-agents-eld-test--wait proc buf "(second")))
              (let ((deadline (+ (float-time) 30)))
                (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output proc 0.05)))
              (should (eql (process-exit-status proc) 0))))
        (kill-buffer buf)))))

(ert-deftest drgnx-agents-eld/the-hub-sees-a-change-without-polling ()
  (drgnx-test-with-config
    (let ((timers (copy-sequence timer-list)) (idle (copy-sequence timer-idle-list)))
      (drgnx-agents-eld-test--put "(:default \"claude\")\n")
      (drgnx-agents-default-profile)
      (drgnx-agents-eld-test--put "(:default \"claude (Ollama)\")\n")
      (should (equal (drgnx-config-get 'agents :default) "claude (Ollama)"))        ; seen at the next get
      (should (equal timer-list timers))
      (should (equal timer-idle-list idle)))))

;;; agents-eld-test.el ends here
