;;; ai-eld-test.el --- batch tests: ai.eld folded into settings.el (drgnx-ai-providers, drgnx-ai-roles); the project's ai.eld -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-runtime-settings' (the eight runtime settings at their defaults, config and
;; state folders in a fresh temp root); the project is ROOT/proj/.  Values are fakes: the settings name environment
;; variables, never a key.  A project's .drgnx/ai.eld and ai-project-routes.eld stay on the config layer until the
;; workspace layers fold them in.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/runtime-settings-fixture" drgnx-dir) nil t)
(require 'drgnx-ai)

(defmacro drgnx-ai-eld-test--with (&rest body)
  "BODY under `drgnx-test-with-runtime-settings', `default-directory' the project ROOT/proj/ (its .drgnx/ exists)."
  (declare (indent 0))
  `(drgnx-test-with-runtime-settings
     (let ((default-directory (concat drgnx-test-config-root "proj/")) (inhibit-message t) (noninteractive t))
       (make-directory (concat default-directory ".drgnx") t)
       ,@body)))

(defun drgnx-ai-eld-test--project-put (text)
  "The project's .drgnx/ai.eld holds TEXT; its path."
  (drgnx-test-config-put 'ai-project text (directory-file-name default-directory)))

(defun drgnx-ai-eld-test--bytes (file)
  (when (file-exists-p file)
    (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string))))

(defconst drgnx-ai-eld-test--good
  '("(drgnx-ai-providers ((box :name \"GPU box\" :kind openai :url \"http://box:9000/v1\" :key-env \"BOX_KEY\" :caps (chat fim))))"
    "(drgnx-ai-roles ((chat (box . \"big\") (ollama . \"small\"))))")
  "settings.el's entries for a provider and a role.")

;;;; The declarations

(ert-deftest drgnx-ai/providers-replace-presets-by-id ()
  (drgnx-ai-eld-test--with
    (should (equal (plist-get (drgnx-ai-provider 'ollama) :url) "http://127.0.0.1:11434"))
    (drgnx-test-runtime-settings-put
     "(drgnx-ai-providers ((ollama :name \"My Ollama\" :kind ollama :url \"http://box:11434\" :caps (chat)) (box :url \"http://box:1\")))")
    (let ((ps (drgnx-ai-providers)))
      (should (equal (plist-get (alist-get 'ollama ps) :url) "http://box:11434"))
      (should (equal (plist-get (alist-get 'ollama ps) :name) "My Ollama"))
      (should (= 1 (length (seq-filter (lambda (p) (eq (car p) 'ollama)) ps))))
      (should (alist-get 'box ps))
      (should (alist-get 'openrouter ps))
      (should (= (length ps) (1+ (length drgnx-ai-presets)))))
    ;; the constant itself is untouched
    (should (equal (plist-get (alist-get 'ollama drgnx-ai-presets) :url) "http://127.0.0.1:11434"))))

(ert-deftest drgnx-ai/the-settings-are-never-for-agents-and-read-by-the-runtime ()
  (dolist (var '(drgnx-ai-providers drgnx-ai-roles))
    (should (drgnx-setting-own-p var))
    (should (eq (plist-get (drgnx-setting-meta var) :agents) 'never))
    (should (stringp (plist-get (drgnx-setting-meta var) :runtime)))))

(ert-deftest drgnx-ai-eld/a-buffer-local-value-never-reaches-the-callers ()
  (drgnx-ai-eld-test--with
    (drgnx-test-set-runtime 'drgnx-ai-roles '((chat (ollama . "mine"))))
    (with-temp-buffer
      (setq-local drgnx-ai-roles '((chat (evil . "m"))))
      (setq-local drgnx-ai-providers '((evil :url "http://evil/v1")))
      (should (equal (drgnx-ai-role 'chat) '((ollama . "mine"))))
      (should-not (drgnx-ai-provider 'evil)))))

;;;; An entry with a mistake

(ert-deftest drgnx-ai-eld/a-mistake-keeps-the-last-good-value ()
  (drgnx-ai-eld-test--with
    (apply #'drgnx-test-runtime-settings-put drgnx-ai-eld-test--good)
    (should (equal (plist-get (drgnx-ai-provider 'box) :url) "http://box:9000/v1"))
    (should (equal (drgnx-ai-role 'chat) '((box . "big") (ollama . "small"))))
    ;; an edit that does not read: the providers and roles applied before stay
    (drgnx-test-config-put 'settings "(drgnx-settings :version 1 (drgnx-ai-roles ((chat (ollama . \"x\"))))\n;; mine\n")
    (drgnx-settings-apply-global)
    (should (equal (plist-get (drgnx-ai-provider 'box) :url) "http://box:9000/v1"))
    (should (equal (drgnx-ai-role 'chat) '((box . "big") (ollama . "small"))))
    ;; an entry that reads but does not fit the schema is a problem of its own (one, naming where)
    (drgnx-test-runtime-settings-put
     "(drgnx-ai-providers ((box :name \"GPU box\" :kind carrier-pigeon)))"
     "(drgnx-ai-roles ((chat (ollama . \"fixed\"))))")
    (should (seq-find (lambda (p) (eq (plist-get p :var) 'drgnx-ai-providers)) drgnx-settings-apply-problems))
    (should (string-search ":kind" (plist-get (car drgnx-settings-apply-problems) :text)))
    (should (equal (plist-get (drgnx-ai-provider 'box) :url) "http://box:9000/v1")) ; its last good value
    ;; the other entry applies
    (should (equal (drgnx-ai-role 'chat) '((ollama . "fixed"))))))

(ert-deftest drgnx-ai-eld/with-no-good-value-a-mistake-gives-the-presets ()
  (drgnx-ai-eld-test--with
    (drgnx-test-runtime-settings-put "(drgnx-ai-providers ((box :name 5)))")
    (should-not (drgnx-ai-provider 'box))
    (should (drgnx-ai-provider 'openrouter))
    (should (equal (drgnx-ai-role 'embed) (alist-get 'embed drgnx-ai-default-roles)))))

(ert-deftest drgnx-ai-eld/a-form-the-old-reader-took-is-still-taken ()
  ;; docs/guide/ai.md taught these forms; the presets use :kind anthropic and :auth
  (drgnx-ai-eld-test--with
    (drgnx-test-runtime-settings-put "(drgnx-ai-providers
  ((box :name \"GPU box\" :kind openai :url \"http://box:9000/v1\" :key-env \"BOX_KEY\" :caps (chat fim)
        :price (3 . 15.5) :messages t)
   (moonshot :name \"Moonshot\" :kind anthropic :url \"https://api.moonshot.ai/anthropic\" :key-env \"MY_KEY\"
             :auth x-api-key :messages t)
   (mine :url \"http://mine:1\")))"
                                     "(drgnx-ai-roles ((embed (tei)) (agent (openrouter)) (chat (box . \"big\") (ollama . \"small\"))))")
    (should-not drgnx-settings-apply-problems)
    (should (equal (plist-get (drgnx-ai-provider 'box) :price) '(3 . 15.5)))
    (should (equal (plist-get (drgnx-ai-provider 'moonshot) :key-env) "MY_KEY"))
    (should (equal (drgnx-ai-role 'embed) '((tei))))
    ;; a price that is not (IN . OUT) is a mistake
    (drgnx-test-runtime-settings-put "(drgnx-ai-providers ((box :price \"cheap\")))")
    (should (string-search "dollars per million tokens" (plist-get (car drgnx-settings-apply-problems) :text)))))

;;;; Writing

(ert-deftest drgnx-ai-eld/set-role-keeps-comments-and-providers ()
  (drgnx-ai-eld-test--with
    (let ((text ";; my notes, kept\n(drgnx-settings\n :version 1\n ;; the box\n (drgnx-ai-providers ((box :name \"GPU box\" :kind openai :url \"http://box:9000/v1\" :caps (chat))))\n (drgnx-ai-roles ((chat (box . \"big\")))))\n"))
      (drgnx-test-config-put 'settings text)
      (drgnx-settings-apply-global)
      (drgnx-ai-set-role 'complete '((box . "tiny")))
      (let ((now (drgnx-test-settings-text)))
        (should (string-prefix-p ";; my notes, kept\n(drgnx-settings\n :version 1\n ;; the box\n (drgnx-ai-providers ((box :name \"GPU box\" :kind openai :url \"http://box:9000/v1\" :caps (chat))))\n"
                                 now))
        (should (equal (drgnx-ai-role 'complete) '((box . "tiny"))))
        (should (equal (drgnx-ai-role 'chat) '((box . "big"))))
        (should (equal (plist-get (drgnx-ai-provider 'box) :url) "http://box:9000/v1")))
      ;; a role that is there changes in place
      (drgnx-ai-set-role 'chat '((ollama . "small")))
      (should (equal (drgnx-ai-user-role 'chat) '((ollama . "small"))))
      (should (string-prefix-p ";; my notes, kept\n" (drgnx-test-settings-text))))))

(ert-deftest drgnx-ai-eld/set-role-makes-the-file-with-its-header ()
  (drgnx-ai-eld-test--with
    (should-not (file-exists-p (drgnx-config-file 'settings)))
    (drgnx-ai-set-role 'embed '((ollama . "nomic-embed-text")))
    (let ((text (drgnx-test-settings-text)))
      (should (string-prefix-p drgnx-settings-file-global-header text))
      (should (string-search "drgnx-ai-roles" text)))
    (should (equal (drgnx-ai-role 'embed) '((ollama . "nomic-embed-text"))))))

(ert-deftest drgnx-ai-eld/set-role-never-replaces-a-file-it-cannot-read ()
  (drgnx-ai-eld-test--with
    (let* ((file (drgnx-test-config-put 'settings "(drgnx-settings :version 1 (drgnx-ai-providers ((box :name \"GPU box\"\n;; mine\n"))
           (bytes (drgnx-ai-eld-test--bytes file)))
      (should-error (drgnx-ai-set-role 'chat '((ollama . "m"))) :type 'user-error)
      (should (equal (drgnx-ai-eld-test--bytes file) bytes))
      ;; nor one a newer drgnx wrote
      (setq bytes (drgnx-ai-eld-test--bytes
                   (drgnx-test-config-put 'settings "(drgnx-settings :version 9 (drgnx-ai-roles ((chat (ollama . \"x\")))))\n")))
      (should-error (drgnx-ai-set-role 'chat '((ollama . "m"))) :type 'drgnx-settings-refused)
      (should (equal (drgnx-ai-eld-test--bytes file) bytes)))))

;;;; The project's file

(ert-deftest drgnx-ai-eld/a-65-kib-project-file-is-refused-not-truncated ()
  (drgnx-ai-eld-test--with
    (let* ((big (concat ";; " (make-string 66000 ?x) "\n(:version 1 :roles ((chat (ollama . \"project-model\"))))\n"))
           (file (drgnx-ai-eld-test--project-put big)))
      (should (> (file-attribute-size (file-attributes file)) 65536))
      (should (equal (drgnx-ai-role 'chat) (alist-get 'chat drgnx-ai-default-roles)))   ; not used, not cut short
      (let ((problems (seq-filter (lambda (p) (eq (plist-get p :name) 'ai-project)) (drgnx-config-problems))))
        (should (= (length problems) 1))
        (should (string-search "65536" (plist-get (car problems) :text))))
      (should (equal (drgnx-ai-eld-test--bytes file) (encode-coding-string big 'utf-8-unix)))
      ;; under the limit it is used
      (drgnx-ai-eld-test--project-put "(:version 1 :roles ((chat (ollama . \"project-model\"))))\n")
      (should (equal (drgnx-ai-role 'chat) '((ollama . "project-model")))))))

(ert-deftest drgnx-ai-eld/a-project-file-with-a-mistake-gives-no-roles ()
  (drgnx-ai-eld-test--with
    (apply #'drgnx-test-runtime-settings-put drgnx-ai-eld-test--good)
    (drgnx-ai-eld-test--project-put "(:version 1 :roles ((chat (ollama . \"project-model\"))))\n")
    (should (equal (drgnx-ai-role 'chat) '((ollama . "project-model"))))
    (drgnx-ai-eld-test--project-put "(:version 1 :roles ((chat (ollama . 5))))\n")      ; a model is a string
    (should (drgnx-config-problem 'ai-project (directory-file-name default-directory)))
    (should (equal (drgnx-ai-role 'chat) '((box . "big") (ollama . "small"))))       ; the user's, never a last good project copy
    ;; roles only: a provider in a project's file is ignored, as it always was
    (drgnx-ai-eld-test--project-put "(:version 1 :providers ((evil :url \"http://evil/v1\")) :roles ((chat (evil . \"m\"))))\n")
    (should-not (drgnx-ai-provider 'evil))))

(ert-deftest drgnx-ai-eld/a-project-file-is-never-written ()
  (drgnx-ai-eld-test--with
    (let* ((root (directory-file-name default-directory))
           (file (drgnx-ai-eld-test--project-put "(:version 1 :roles ((chat (ollama . \"project-model\"))))\n"))
           (bytes (drgnx-ai-eld-test--bytes file)))
      (should-error (drgnx-config-set 'ai-project :roles nil root))
      (should-error (drgnx-config-update 'ai-project #'identity :root root))
      (drgnx-ai-set-role 'chat '((ollama . "mine")))                   ; goes to the user's settings.el
      (should (equal (drgnx-ai-role 'chat) '((ollama . "project-model"))))
      (should (equal (drgnx-ai-user-role 'chat) '((ollama . "mine"))))
      (should (equal (drgnx-ai-eld-test--bytes file) bytes))
      (should (eq (plist-get (drgnx-config-definition 'ai-project) :dir) 'project)))))

;;;; A pause

(ert-deftest drgnx-ai-eld/ghost-text-asks-without-reading-a-file-for-the-user-roles ()
  ;; ghost text asks for the `complete' role on every pause: the user's roles are a variable, no file is read
  (drgnx-ai-eld-test--with
    (let ((noninteractive nil))
      (drgnx-test-runtime-settings-put
       "(drgnx-ai-providers ((o :name \"O\" :kind ollama :url \"http://127.0.0.1:9\" :caps (chat fim))))"
       "(drgnx-ai-roles ((complete (o . \"coder\"))))")
      (require 'drgnx-ai-client)
      (require 'drgnx-ai-probe)
      (let ((drgnx-ai-detected '((o :up t))) (reads 0) (asked nil)
            (read-orig (symbol-function 'drgnx-config--read)))
        (cl-letf (((symbol-function 'drgnx-config--read) (lambda (&rest args) (cl-incf reads) (apply read-orig args)))
                  ((symbol-function 'drgnx-ai--curl) (lambda (&rest _) (setq asked t) nil)))
          ;; what a pause does: is `complete' available, then ask its chain
          (should (seq-some (lambda (step) (drgnx-ai-usable-p (car step) 'fim)) (drgnx-ai-role 'complete)))
          (drgnx-ai-request 'complete 'fim '(:prefix "a" :suffix "b" :max-tokens 8) #'ignore :timeout 1))
        (should asked)
        (should (= reads 0))))))

;;;; ai-project-routes.eld

(defun drgnx-ai-eld-test--remote-project ()
  "The project routes complete to OpenRouter then Ollama; the routes file's path."
  (drgnx-ai-eld-test--project-put "(:version 1 :roles ((complete (openrouter . \"paid/m\") (ollama . \"local-m\"))))\n")
  (drgnx-ai-routes-file))

(ert-deftest drgnx-ai-eld/the-answer-is-kept-per-root-and-other-keys-stay ()
  (drgnx-ai-eld-test--with
    (let* ((routes (drgnx-ai-eld-test--remote-project)) (asks 0) (noninteractive nil))
      (make-directory (file-name-directory routes) t)
      (write-region "(:version 1 :note \"mine\" :projects ((\"/elsewhere/\" :allow nil :ids (openrouter))))\n" nil routes nil 'silent)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf asks) t)))
        (should (drgnx-ai-confirm-project-route))
        (should (drgnx-ai-confirm-project-route))
        (should (= asks 1)))
      (let ((data (plist-get (drgnx-file-read routes) :data)))
        (should (equal (plist-get data :note) "mine"))
        (should (assoc "/elsewhere/" (plist-get data :projects)))
        (should (equal (cdr (assoc (file-truename default-directory) (plist-get data :projects)))
                       '(:allow t :ids (openrouter)))))
      (should (equal (drgnx-ai-role 'complete) '((openrouter . "paid/m") (ollama . "local-m")))))))

(ert-deftest drgnx-ai-eld/an-unreadable-routes-file-is-copied-aside-before-the-answer ()
  (drgnx-ai-eld-test--with
    (let* ((routes (drgnx-ai-eld-test--remote-project)) (noninteractive nil)
           (broken "(:version 1 :projects ((\"/a/\" :allow t"))
      (make-directory (file-name-directory routes) t)
      (write-region broken nil routes nil 'silent)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (should (drgnx-ai-confirm-project-route)))
      (should (plist-get (drgnx-file-read routes) :data))
      (should (seq-some (lambda (f) (equal (drgnx-ai-eld-test--bytes f) (encode-coding-string broken 'utf-8-unix)))
                        (directory-files (file-name-directory routes) t "ai-project-routes.eld.+"))))))

;;; ai-eld-test.el ends here
