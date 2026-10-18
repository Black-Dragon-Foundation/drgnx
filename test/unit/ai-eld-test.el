;;; ai-eld-test.el --- batch tests: ai.eld, the project's ai.eld and ai-project-routes.eld on the config layer -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-config' (config and state folders in a fresh temp root); the project is
;; ROOT/proj/.  Values are fakes: ai.eld names environment variables, never a key.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-ai)

(defmacro drgnx-ai-eld-test--with (&rest body)
  "BODY under `drgnx-test-with-config', `default-directory' the project ROOT/proj/ (its .drgnx/ exists)."
  (declare (indent 0))
  `(drgnx-test-with-config
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
  "(:version 1\n :providers ((box :name \"GPU box\" :kind openai :url \"http://box:9000/v1\" :key-env \"BOX_KEY\" :caps (chat fim)))\n :roles ((chat (box . \"big\") (ollama . \"small\"))))\n")

;;;; A file with a mistake

(ert-deftest drgnx-ai-eld/a-mistake-uses-the-last-good-providers ()
  (drgnx-ai-eld-test--with
    (let ((file (drgnx-test-config-put 'ai drgnx-ai-eld-test--good)))
      (should (equal (plist-get (drgnx-ai-provider 'box) :url) "http://box:9000/v1"))
      (should (equal (drgnx-ai-role 'chat) '((box . "big") (ollama . "small"))))
      ;; an edit that does not read: the providers and roles of the last good copy stay
      (let ((bad "(:version 1 :providers ((box :name \"GPU box\" :url \"http://box:9000/v1\"\n;; mine\n"))
        (drgnx-test-config-put 'ai bad)
        (should (equal (plist-get (drgnx-ai-provider 'box) :url) "http://box:9000/v1"))
        (should (equal (drgnx-ai-role 'chat) '((box . "big") (ollama . "small"))))
        (should (drgnx-config-problem 'ai))
        (should (equal (drgnx-ai-eld-test--bytes file) (encode-coding-string bad 'utf-8-unix))))
      ;; a form that reads but does not fit the schema is a mistake too (one problem, naming where)
      (drgnx-test-config-put 'ai "(:providers ((box :kind carrier-pigeon)))\n")
      (should (equal (plist-get (drgnx-ai-provider 'box) :url) "http://box:9000/v1"))
      (should (string-search ":kind" (plist-get (drgnx-config-problem 'ai) :text)))
      ;; fixed: the new file applies
      (drgnx-test-config-put 'ai "(:version 1 :roles ((chat (ollama . \"fixed\"))))\n")
      (should-not (drgnx-config-problem 'ai))
      (should (equal (drgnx-ai-role 'chat) '((ollama . "fixed"))))
      (should-not (drgnx-ai-provider 'box)))))

(ert-deftest drgnx-ai-eld/with-no-good-copy-a-mistake-gives-the-presets ()
  (drgnx-ai-eld-test--with
    (drgnx-test-config-put 'ai "(:version 1 :providers ((box :name \"GPU box\"")
    (should-not (drgnx-ai-provider 'box))
    (should (drgnx-ai-provider 'openrouter))
    (should (equal (drgnx-ai-role 'embed) (alist-get 'embed drgnx-ai-default-roles)))))

(ert-deftest drgnx-ai-eld/a-file-the-old-reader-took-is-still-taken ()
  ;; docs/guide/ai.md taught these forms; the presets use :kind anthropic and :auth
  (drgnx-ai-eld-test--with
    (drgnx-test-config-put 'ai "(:version 1
 :providers ((box :name \"GPU box\" :kind openai :url \"http://box:9000/v1\" :key-env \"BOX_KEY\" :caps (chat fim)
                  :price (3 . 15.5) :messages t)
             (moonshot :name \"Moonshot\" :kind anthropic :url \"https://api.moonshot.ai/anthropic\" :key-env \"MY_KEY\"
                       :auth x-api-key :messages t)
             (mine :url \"http://mine:1\"))
 :roles ((embed (tei)) (agent (openrouter)) (chat (box . \"big\") (ollama . \"small\")))
 :note \"an unknown key\")\n")
    (should-not (drgnx-config-problem 'ai))
    (should (equal (plist-get (drgnx-ai-provider 'box) :price) '(3 . 15.5)))
    (should (equal (plist-get (drgnx-ai-provider 'moonshot) :key-env) "MY_KEY"))
    (should (equal (drgnx-ai-role 'embed) '((tei))))
    ;; a price that is not (IN . OUT) is a mistake
    (drgnx-test-config-put 'ai "(:providers ((box :price \"cheap\")))\n")
    (should (string-search "dollars per million tokens" (plist-get (drgnx-config-problem 'ai) :text)))))

;;;; Writing

(ert-deftest drgnx-ai-eld/set-role-keeps-comments-and-providers ()
  (drgnx-ai-eld-test--with
    (let* ((text ";; my notes, kept\n(:version 1\n ;; the box\n :providers ((box :name \"GPU box\" :kind openai :url \"http://box:9000/v1\" :caps (chat)))\n :note (\"unknown\" key)\n :roles ((chat (box . \"big\"))))\n")
           (file (drgnx-test-config-put 'ai text)))
      (drgnx-ai-set-role 'complete '((box . "tiny")))
      (let ((now (drgnx-test-config-text 'ai)))
        (should (string-prefix-p ";; my notes, kept\n(:version 1\n ;; the box\n :providers ((box :name \"GPU box\" :kind openai :url \"http://box:9000/v1\" :caps (chat)))\n :note (\"unknown\" key)\n"
                                 now))
        (should (equal (drgnx-ai-role 'complete) '((box . "tiny"))))
        (should (equal (drgnx-ai-role 'chat) '((box . "big"))))
        (should (equal (plist-get (drgnx-ai-provider 'box) :url) "http://box:9000/v1")))
      ;; a role that is there changes in place
      (drgnx-ai-set-role 'chat '((ollama . "small")))
      (should (equal (drgnx-ai-user-role 'chat) '((ollama . "small"))))
      (should (string-prefix-p ";; my notes, kept\n" (drgnx-test-config-text 'ai)))
      (should (file-exists-p file)))))

(ert-deftest drgnx-ai-eld/set-role-makes-the-file-with-its-header ()
  (drgnx-ai-eld-test--with
    (should-not (file-exists-p (drgnx-ai-file)))
    (drgnx-ai-set-role 'embed '((ollama . "nomic-embed-text")))
    (let ((text (drgnx-test-config-text 'ai)))
      (should (string-prefix-p ";; drgnx AI providers and roles (docs/guide/ai.md) — never a key here\n" text))
      (should (string-search ":version 1" text)))
    (should (equal (drgnx-ai-role 'embed) '((ollama . "nomic-embed-text"))))))

(ert-deftest drgnx-ai-eld/set-role-never-replaces-a-file-it-cannot-read ()
  (drgnx-ai-eld-test--with
    (let* ((file (drgnx-test-config-put 'ai "(:version 1 :providers ((box :name \"GPU box\"\n;; mine\n"))
           (bytes (drgnx-ai-eld-test--bytes file)))
      (should-error (drgnx-ai-set-role 'chat '((ollama . "m"))) :type 'user-error)
      (should (equal (drgnx-ai-eld-test--bytes file) bytes))
      ;; nor one a newer drgnx wrote
      (setq bytes (drgnx-ai-eld-test--bytes (drgnx-test-config-put 'ai "(:version 9 :roles ((chat (ollama . \"x\"))))\n")))
      (should-error (drgnx-ai-set-role 'chat '((ollama . "m"))) :type 'drgnx-config-refused)
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
    (drgnx-test-config-put 'ai drgnx-ai-eld-test--good)
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
      (drgnx-ai-set-role 'chat '((ollama . "mine")))                   ; goes to the user's file
      (should (equal (drgnx-ai-role 'chat) '((ollama . "project-model"))))
      (should (equal (drgnx-ai-user-role 'chat) '((ollama . "mine"))))
      (should (equal (drgnx-ai-eld-test--bytes file) bytes))
      (should (eq (plist-get (drgnx-config-definition 'ai-project) :dir) 'project)))))

;;;; A pause

(ert-deftest drgnx-ai-eld/ghost-text-asks-with-one-stat-per-pause ()
  ;; ghost text asks for the `complete' role on every pause: each look at ai.eld is one stat of it, never a read
  (drgnx-ai-eld-test--with
    (let ((noninteractive nil))
      (drgnx-test-config-put 'ai "(:version 1 :providers ((o :name \"O\" :kind ollama :url \"http://127.0.0.1:9\" :caps (chat fim)))
 :roles ((complete (o . \"coder\"))))\n")
      (require 'drgnx-ai-client)
      (require 'drgnx-ai-probe)
      (let ((drgnx-ai-detected '((o :up t))) (file (drgnx-ai-file)) (stats 0) (reads 0) (gets 0) (asked nil)
            (read-orig (symbol-function 'drgnx-config--read)))
        (drgnx-ai-role 'complete)                                       ; the first look reads it
        (cl-letf (((symbol-function 'drgnx-config--read) (lambda (&rest args) (cl-incf reads) (apply read-orig args)))
                  ((symbol-function 'drgnx-ai--curl) (lambda (&rest _) (setq asked t) nil)))
          (let ((count (lambda (f &rest _) (when (equal f file) (cl-incf stats))))
                (get (lambda (name &rest _) (when (eq name 'ai) (cl-incf gets)))))
            (advice-add 'file-attributes :before count)
            (advice-add 'drgnx-config-get :before get)
            (unwind-protect
                (progn
                  ;; what a pause does: is `complete' available, then ask its chain
                  (should (seq-some (lambda (step) (drgnx-ai-usable-p (car step) 'fim)) (drgnx-ai-role 'complete)))
                  (drgnx-ai-request 'complete 'fim '(:prefix "a" :suffix "b" :max-tokens 8) #'ignore :timeout 1))
              (advice-remove 'file-attributes count)
              (advice-remove 'drgnx-config-get get))))
        (should asked)
        (should (>= gets 1))
        (should (= reads 0))
        (should (= stats gets))))))

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
