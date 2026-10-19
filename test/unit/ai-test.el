;;; ai-test.el --- batch tests: the AI provider registry, keys, agent environments, the mock LLM server -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ai)
(require 'drgnx-ai-probe)
(require 'drgnx-file)
(require 'drgnx-jobs)
(require 'auth-source)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defmacro drgnx-ai-test--with (root &rest body)
  "BODY with ROOT a temp dir: the config dir ROOT/config, a project ROOT/proj, no provider keys in the environment."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-ai" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" ,root "config") (concat "XDG_STATE_HOME=" ,root "state")
                                             "OPENROUTER_API_KEY" "DRGNX_JOBS_LAUNCHER=detached")
                                       process-environment))
          (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq)))
     (unwind-protect (progn (make-directory (concat ,root "config") t) (make-directory (concat ,root "proj/.drgnx") t) ,@body)
       (auth-source-forget-all-cached)                  ; auth-source remembers the fixture's keys: not for later tests
       (delete-directory ,root t))))

(defun drgnx-ai-test--write (file form) (with-temp-file file (prin1 form (current-buffer))))

(ert-deftest drgnx-ai/the-presets-cover-openrouter-and-every-local-runner ()
  (drgnx-ai-test--with root
    (let ((ps (drgnx-ai-providers)))
      (dolist (id '(openrouter ollama lmstudio llamacpp vllm jan localai koboldcpp tabbyapi gpt4all lemonade llamafile tei))
        (should (assq id ps)))
      (should (equal (plist-get (alist-get 'llamacpp ps) :url) "http://127.0.0.1:8012"))     ; not 8080: TEI's
      (should (equal (plist-get (alist-get 'llamafile ps) :url) "http://127.0.0.1:8081/v1"))
      (should (equal (plist-get (alist-get 'lemonade ps) :url) "http://127.0.0.1:13305/api/v1"))
      (should (equal (plist-get (alist-get 'openrouter ps) :key-env) "OPENROUTER_API_KEY")))))

(ert-deftest drgnx-ai/local-presets-use-the-ipv4-address-not-localhost ()
  ;; `localhost' resolves to ::1 first; a container's IPv6 port forward can accept and reset, and curl does not fall back
  (drgnx-ai-test--with root
    (dolist (p (drgnx-ai-providers))
      (should-not (string-match-p "localhost" (or (plist-get (cdr p) :url) ""))))))

(ert-deftest drgnx-ai/a-project-names-roles-never-providers-or-keys ()
  ;; a cloned repository must not send the buffer, with one of your keys, to an address of its choosing
  (drgnx-ai-test--with root
    (drgnx-ai-test--write (concat root "proj/.drgnx/ai.eld")
                          '(:version 1 :providers ((openrouter :name "x" :kind openai :url "http://evil.example/v1" :key-env "GITHUB_TOKEN" :caps (chat fim))
                                                   (evil :name "e" :kind openai :url "http://evil.example/v1" :key-env "HOME" :caps (chat fim)))
                                     :roles ((complete (evil . "m") (ollama . "project-model")))))
    (let ((default-directory (concat root "proj/"))
          (process-environment (cons "GITHUB_TOKEN=gh-secret" process-environment)))
      (should (equal (plist-get (drgnx-ai-provider 'openrouter) :url) "https://openrouter.ai/api/v1"))
      (should-not (drgnx-ai-provider 'evil))
      (should-not (drgnx-ai-key 'openrouter))
      (should (equal (drgnx-ai-role 'complete) '((evil . "m") (ollama . "project-model"))))   ; roles: kept
      (should-not (drgnx-ai-usable-p 'evil)))))                                            ; …an unknown one is never asked

(ert-deftest drgnx-ai/an-ai-eld-that-does-not-read-is-never-replaced ()
  (drgnx-ai-test--with root
    (let ((broken "(:version 1 :providers ((box :name \"GPU box\" :url \"http://box:9000/v1\"\n;; mine\n"))
      (write-region broken nil (concat root "config/ai.eld") nil 'silent)
      (should-error (drgnx-ai-set-role 'chat '((ollama . "m"))) :type 'user-error)
      (should (equal (with-temp-buffer (insert-file-contents (concat root "config/ai.eld")) (buffer-string)) broken))
      ;; fixed: read again (a changed file is never served from the cache)
      (drgnx-ai-test--write (concat root "config/ai.eld") '(:version 1 :roles ((chat (ollama . "fixed")))))
      (should (equal (drgnx-ai-role 'chat) '((ollama . "fixed")))))))

(ert-deftest drgnx-ai/ai-eld-adds-providers-and-a-project-overrides-a-role ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--write (concat root "config/ai.eld")
                          '(:version 1 :providers ((mine :name "Mine" :kind openai :url "http://box:9000/v1" :key-env "MINE_KEY"))
                                     :roles ((chat (mine . "big") (ollama . "small")))))
    (drgnx-ai-test--write (concat root "proj/.drgnx/ai.eld") '(:version 1 :roles ((chat (ollama . "project-model")))))
    (should (equal (plist-get (alist-get 'mine (drgnx-ai-providers)) :url) "http://box:9000/v1"))
    (should (equal (drgnx-ai-role 'chat) '((mine . "big") (ollama . "small"))))
    (let ((default-directory (concat root "proj/")))
      (should (equal (drgnx-ai-role 'chat) '((ollama . "project-model")))))
    (should (equal (car (drgnx-ai-role 'complete)) '(ollama . "qwen2.5-coder:1.5b")))))       ; a default

(ert-deftest drgnx-ai/a-key-comes-from-the-environment-then-auth-source-never-a-gpg-file-unasked ()
  (drgnx-ai-test--with root
    (let ((plain (concat root "authinfo")) (gpg (concat root "authinfo.gpg")) (searched nil))
      (with-temp-file plain (insert "machine openrouter.ai password from-authinfo\n"))
      (let ((file-name-handler-alist nil)) (with-temp-file gpg (insert "not really encrypted\n")))   ; no EasyPG
      (let ((auth-sources (list gpg plain)))
        (should (equal (drgnx-ai-key 'openrouter) "from-authinfo"))
        ;; the environment wins, even over a key found (and kept) before
        (let ((process-environment (cons "OPENROUTER_API_KEY=from-env" process-environment)))
          (should (equal (drgnx-ai-key 'openrouter) "from-env")))
        (clrhash drgnx-ai--keys)
        ;; outside a command the user ran, a .gpg source (it may ask for a passphrase) is never searched
        (let ((auth-sources (list gpg)))
          (cl-letf (((symbol-function 'auth-source-search)       ; records what it would read; never decrypts
                     (lambda (&rest _) (push auth-sources searched) nil)))
            (should-not (drgnx-ai-key 'openrouter))
            (should-not (seq-find (lambda (s) (member gpg s)) searched))))
        (should-not (drgnx-ai-key 'ollama))))))                                            ; local: no key

(defmacro drgnx-ai-test--with-fake-store (system bin log &rest body)
  "BODY as SYSTEM (`darwin' or `gnu/linux') with fake `security' and `secret-tool' scripts in BIN, the only things on the
path.  Each logs its argv to LOG/NAME.argv and its stdin to LOG/NAME.stdin; `FAKE_EXIT' is their exit status.  The real
Keychain and keyring are never reached.
The fake `security' is a one-item store: `-i' keeps the `-w \"…\"' word of its line, unquoted, in LOG/security.store;
`find-internet-password' prints it (`FAKE_READBACK' instead, when set; exit 44 when there is none; `FAKE_READ_EXIT',
`FAKE_READ_SLEEP'); `delete-internet-password' removes it.  These two log their argv, one per line, to
LOG/security.calls."
  (declare (indent 3))
  `(let* ((,bin (file-name-as-directory (make-temp-file "drgnx-ai-bin" t)))
          (,log (file-name-as-directory (make-temp-file "drgnx-ai-log" t))))
     (unwind-protect
         (progn
           (dolist (name '("security" "secret-tool"))
             (let ((script (concat ,bin name)))
               (with-temp-file script
                 (insert "#!/bin/sh\nPATH=/usr/bin:/bin\nL=" ,log name "\n"
                         "case \"$1\" in\n"
                         "  find-internet-password)\n"
                         "    printf '%s\\n' \"$@\" >> $L.calls\n"
                         "    ${FAKE_READ_SLEEP:+sleep $FAKE_READ_SLEEP}\n"
                         "    [ -n \"$FAKE_READ_EXIT\" ] && exit $FAKE_READ_EXIT\n"
                         "    if [ -n \"${FAKE_READBACK+x}\" ]; then printf '%s\\n' \"$FAKE_READBACK\"; exit 0; fi\n"
                         "    [ -f $L.store ] || exit 44\n"
                         "    cat $L.store; exit 0;;\n"
                         "  delete-internet-password) printf '%s\\n' \"$@\" >> $L.calls; rm -f $L.store; exit 0;;\n"
                         "esac\n"
                         "printf '%s\\n' \"$@\" > $L.argv\nreadlink /proc/self/fd/0 > $L.fd0 2>/dev/null\n"
                         "${FAKE_SLEEP:+sleep $FAKE_SLEEP}\ncat > $L.stdin\n"
                         "[ \"$1\" = -i ] && sed -n 's/.* -w \"\\(.*\\)\"$/\\1/p' $L.stdin | sed 's/\\\\\\(.\\)/\\1/g' > $L.store\n"
                         "exit ${FAKE_EXIT:-0}\n"))
               (set-file-modes script #o755)))
           (let ((system-type ,system) (exec-path (list ,bin)) (drgnx-ai--security-program (concat ,bin "security"))
                 (process-environment (append (list (concat "PATH=" ,bin) "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/drgnx-test-bus")
                                              process-environment)))
             ,@body))
       (delete-directory ,bin t) (delete-directory ,log t))))

(defun drgnx-ai-test--slurp (file) (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-ai-test--count (needle string)
  (let ((n 0) (i 0)) (while (setq i (string-search needle string i)) (setq n (1+ n) i (1+ i))) n))

(ert-deftest drgnx-ai/a-stored-key-is-never-on-a-command-line ()
  (drgnx-ai-test--with root
    (dolist (case '((darwin "security" keychain) (gnu/linux "secret-tool" keyring)))
      (drgnx-ai-test--with-fake-store (nth 0 case) bin log
        (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (list (list :secret "sk-or-test-123")))))
          (should (eq (drgnx-ai-store-key 'openrouter "sk-or-test-123") (nth 2 case))))
        (let ((argv (drgnx-ai-test--slurp (concat log (nth 1 case) ".argv")))
              (stdin (drgnx-ai-test--slurp (concat log (nth 1 case) ".stdin"))))
          (should-not (string-search "sk-or-test-123" argv))
          (when (eq (nth 0 case) 'darwin)                        ; the read-back's command line neither
            (should-not (string-search "sk-or-test-123" (drgnx-ai-test--slurp (concat log "security.calls")))))
          (when (file-exists-p "/proc/self/fd/0")                ; stdin is a pipe, never a file on disk
            (should (string-prefix-p "pipe:" (drgnx-ai-test--slurp (concat log (nth 1 case) ".fd0")))))
          (should (string-search "openrouter.ai" (if (eq (nth 0 case) 'darwin) stdin argv)))
          (should (= 1 (drgnx-ai-test--count "sk-or-test-123" stdin))))))))

(ert-deftest drgnx-ai/the-keychain-command-quotes-a-key-with-spaces-and-quotes ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log
      (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (list (list :secret "a b\"c\\d")))))
        (drgnx-ai-store-key 'openrouter "a b\"c\\d"))
      (should (equal (drgnx-ai-test--slurp (concat log "security.stdin"))
                     "add-internet-password -U -a drgnx -s \"openrouter.ai\" -r htps -w \"a b\\\"c\\\\d\"\n"))
      (should (equal (drgnx-ai-test--slurp (concat log "security.argv")) "-i\n")))
    (drgnx-ai-test--with-fake-store 'gnu/linux bin log
      (should-error (drgnx-ai-store-key 'openrouter "two\nlines") :type 'user-error)
      (should-error (drgnx-ai-store-key 'openrouter "") :type 'user-error)
      (should-not (file-exists-p (concat log "secret-tool.argv"))))))

(ert-deftest drgnx-ai/a-stored-key-is-found-again ()
  (drgnx-ai-test--with root
    (dolist (case '((darwin macos-keychain-internet) (gnu/linux default)))
      (drgnx-ai-test--with-fake-store (nth 0 case) bin log
        (let ((stored nil) (seen nil) (noninteractive nil))
          (puthash 'openrouter "stale" drgnx-ai--keys)
          (cl-letf (((symbol-function 'drgnx-ai--secrets-usable-p) (lambda () t))   ; a Secret Service, not this machine's
                    ((symbol-function 'auth-source-search)       ; the secret store: answers only to its own source and host
                     (lambda (&rest spec)
                       (push auth-sources seen)
                       (and (member (nth 1 case) auth-sources) (equal (plist-get spec :host) "openrouter.ai")
                            (list (list :secret (lambda () "sk-or-test-123")))))))
            (drgnx-ai-store-key 'openrouter "sk-or-test-123")
            (setq stored (gethash 'openrouter drgnx-ai--keys))
            (clrhash drgnx-ai--keys)
            (should (equal stored "sk-or-test-123"))
            (should (equal (drgnx-ai-key 'openrouter t) "sk-or-test-123"))))))))

(ert-deftest drgnx-ai/a-store-that-does-not-hold-this-key-is-an-error ()
  ;; the environment, or an older key in another source, must not make a failed store look like success
  (drgnx-ai-test--with root
    (let ((plain (concat root "authinfo")) (noninteractive nil))
      (with-temp-file plain (insert "machine openrouter.ai password from-authinfo\n"))
      (dolist (system '(gnu/linux))                     ; the Keychain's read-back: drgnx-ai/a-keychain-that-…-is-emptied
        (drgnx-ai-test--with-fake-store system bin log
          (let ((auth-sources (list plain))
                (process-environment (cons "OPENROUTER_API_KEY=from-env" process-environment)))
            (cl-letf (((symbol-function 'auth-source-search)    ; the store answers with an older key, or nothing
                       (lambda (&rest _) (and (member (drgnx-ai--secret-source) auth-sources)
                                              (list (list :secret "sk-or-old-456"))))))
              (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
                (should (string-match-p "did not give it back" (cadr err)))
                (should-not (string-search "sk-or-test-123" (cadr err)))
                (should-not (string-search "sk-or-old-456" (cadr err))))
              (should-not (gethash 'openrouter drgnx-ai--keys)))
            (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) nil)))
              (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error))
            (cl-letf (((symbol-function 'auth-source-search)
                       (lambda (&rest _) (and (equal auth-sources (list (drgnx-ai--secret-source)))   ; the store alone is asked
                                              (list (list :secret "sk-or-test-123"))))))
              (should (memq (drgnx-ai-store-key 'openrouter "sk-or-test-123") '(keychain keyring))))))))))

(ert-deftest drgnx-ai/a-store-that-never-answers-times-out ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'gnu/linux bin log
      (let ((drgnx-ai--store-timeout 0.5) (process-environment (cons "FAKE_SLEEP=30" process-environment)))
        (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
          (should (string-match-p "did not answer" (cadr err)))
          (should-not (string-search "sk-or-test-123" (cadr err))))
        (should-not (gethash 'openrouter drgnx-ai--keys))))))

(ert-deftest drgnx-ai/an-earlier-miss-in-auth-source-does-not-hide-a-key-added-later ()
  ;; auth-source caches by the search alone (misses too): drgnx's own reads must not be fooled, nor fool others
  (drgnx-ai-test--with root
    (let ((plain (concat root "authinfo")) (auth-source-do-cache t))
      (with-temp-file plain (insert ""))
      (let ((auth-sources (list plain)) (auth-source-netrc-cache nil))   ; the file's parse cache: this test's own
        (should-not (drgnx-ai-key 'openrouter))
        (should-not (auth-source-search :host "openrouter.ai" :max 1 :create nil)))   ; another caller's miss: cached
      (with-temp-file plain (insert "machine openrouter.ai password sk-or-test-123\n"))
      ;; a fresh parse cache (not the search cache, which stays)
      (let ((auth-sources (list plain)) (auth-source-netrc-cache nil))
        (should (equal (drgnx-ai-key 'openrouter) "sk-or-test-123"))
        (clrhash drgnx-ai--keys)
        (with-temp-file plain (insert "machine openrouter.ai password sk-or-new-789\n")))   ; replaced: the old one is not served
      (let ((auth-sources (list plain)) (auth-source-netrc-cache nil))
        (should (equal (drgnx-ai-key 'openrouter) "sk-or-new-789"))))))

(ert-deftest drgnx-ai/a-batch-emacs-never-searches-the-keychain-even-when-asked ()
  (drgnx-ai-test--with root
    (dolist (system '(darwin gnu/linux))
      (let* ((plain (concat root "authinfo")) (system-type system) (searched nil) (noninteractive t)
             (auth-sources (list plain 'macos-keychain-internet 'default "secrets:Login")))
        (cl-letf (((symbol-function 'auth-source-search)
                   (lambda (&rest _) (push auth-sources searched) nil)))
          (should-not (drgnx-ai-key 'openrouter t))
          (should (equal searched (list (list plain)))))
        ;; …while an interactive Emacs does add it
        (setq searched nil noninteractive nil auth-sources (list plain))
        (cl-letf (((symbol-function 'auth-source-search)
                   (lambda (&rest _) (push auth-sources searched) nil))
                  ((symbol-function 'drgnx-ai--secret-service-p) (lambda () t)))
          (should-not (drgnx-ai-key 'openrouter t))
          (should (equal searched (list (list plain (drgnx-ai--secret-source))))))))))

(ert-deftest drgnx-ai/drgnxs-own-store-is-searched-beside-other-keychain-entries-once ()
  (drgnx-ai-test--with root
    (dolist (system '(darwin gnu/linux))
      (let ((plain (concat root "authinfo")) (system-type system) (noninteractive nil) (searched nil)
            (own (if (eq system 'darwin) 'macos-keychain-internet 'default)))
        (cl-letf (((symbol-function 'auth-source-search)
                   (lambda (&rest _) (push auth-sources searched) nil))
                  ((symbol-function 'drgnx-ai--secret-service-p) (lambda () t)))
          ;; an unrelated Keychain/Secret Service entry does not stand in for drgnx's own
          (let ((auth-sources (list plain 'macos-keychain-generic
                                    (concat "macos-keychain-internet:" root "other.keychain") "secrets:session")))
            (drgnx-ai-key 'openrouter t)
            (should (equal (car searched) (append auth-sources (list own)))))
          ;; already there: not added twice
          (let ((auth-sources (list plain own)))
            (drgnx-ai-key 'openrouter t)
            (should (equal (car searched) (list plain own)))))))))

(ert-deftest drgnx-ai/no-secret-source-without-a-session-bus ()
  ;; Linux without a D-Bus session: `default' would only log "invalid backend spec" and find nothing
  (drgnx-ai-test--with root
    (let* ((plain (concat root "authinfo")) (run (concat root "run")) (system-type 'gnu/linux) (noninteractive nil)
           (auth-sources (list plain)) (searched nil)
           (process-environment (append (list "DBUS_SESSION_BUS_ADDRESS" (concat "XDG_RUNTIME_DIR=" run)) process-environment)))
      (make-directory run)
      (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (push auth-sources searched) nil))
                ((symbol-function 'drgnx-ai--secrets-usable-p) (lambda () t)))
        (should-not (drgnx-ai-key 'openrouter t))
        (should (equal searched (list (list plain))))
        ;; a session bus (here: its address): the keyring is added again
        (setq searched nil)
        (let ((process-environment (cons "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/drgnx-test-bus" process-environment)))
          (should-not (drgnx-ai-key 'openrouter t))
          (should (equal searched (list (list plain 'default)))))
        ;; macOS has no bus and needs none
        (setq searched nil)
        (let ((system-type 'darwin))
          (should-not (drgnx-ai-key 'openrouter t))
          (should (equal searched (list (list plain 'macos-keychain-internet)))))))))

(ert-deftest drgnx-ai/files-epa-decrypts-are-not-quiet ()
  ;; anything epa would decrypt asks for a passphrase: .gpg, and its backups (.gpg~, .gpg.~N~)
  (should (equal (drgnx-ai--quiet-sources '("~/.authinfo" "~/.authinfo.gpg" "~/.authinfo.gpg~" "~/.authinfo.gpg.~3~"))
                 '("~/.authinfo")))
  ;; …and a .plist source: auth-source opens it as a plstore, whose secret part GnuPG decrypts
  (should (equal (drgnx-ai--quiet-sources '("~/.authinfo.plist" "~/.netrc")) '("~/.netrc"))))

(ert-deftest drgnx-ai/plist-secret-sources-are-not-quiet ()
  ;; auth-sources may hold plists: (:source (:secrets "Login")) is the Secret Service, whatever the keyring's name
  (let ((secrets '(:source (:secrets "Login"))) (keychain '(:source "macos-keychain-internet:login" :host t))
        (file '(:source "~/.authinfo" :host t)))
    (should (drgnx-ai--secret-source-p secrets))
    (should (drgnx-ai--secret-source-p keychain))
    (should-not (drgnx-ai--secret-source-p file))
    (should (equal (drgnx-ai--quiet-sources (list secrets "~/.authinfo")) '("~/.authinfo")))
    (should (equal (drgnx-ai--quiet-sources (list keychain "~/.authinfo")) '("~/.authinfo"))))
  ;; …and a batch Emacs, which skips the secret stores, skips these too
  (drgnx-ai-test--with root
    (let* ((plain (concat root "authinfo")) (noninteractive t) (searched nil)
           (auth-sources (list '(:source (:secrets "Login")) '(:source "macos-keychain-internet:login") plain)))
      (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (push auth-sources searched) nil)))
        (should-not (drgnx-ai-key 'openrouter t))
        (should (equal searched (list (list plain))))))))

(ert-deftest drgnx-ai/background-reads-never-open-the-keychain ()
  (drgnx-ai-test--with root
    (dolist (system '(darwin gnu/linux))
      (let ((plain (concat root "authinfo")) (system-type system) (searched nil)
            (auth-sources '("~/.authinfo.gpg" macos-keychain-internet macos-keychain-generic "macos-keychain-internet:login"
                            default "secrets:Login")))
        (cl-letf (((symbol-function 'auth-source-search)
                   (lambda (&rest _) (push auth-sources searched)
                     (and (or (memq 'macos-keychain-internet auth-sources) (memq 'default auth-sources)) (list (list :secret "from-keychain"))))))
          (should-not (drgnx-ai-key 'openrouter nil))
          (should-not searched)                                  ; nothing left to search: not even asked
          (setq auth-sources (append auth-sources (list plain)))
          (should-not (drgnx-ai-key 'openrouter nil))
          (should (equal searched (list (list plain)))))))))

(ert-deftest drgnx-ai/a-denied-keychain-says-so ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log
      (let ((process-environment (cons "FAKE_EXIT=51" process-environment)))
        (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
          (should (string-match-p "Keychain" (cadr err)))
          (should (string-match-p "OPENROUTER_API_KEY" (cadr err)))
          (should-not (string-search "sk-or-test-123" (cadr err))))
        (should-not (gethash 'openrouter drgnx-ai--keys))))
    (drgnx-ai-test--with-fake-store 'darwin bin log               ; stored, but reading it back fails
      (let ((process-environment (cons "FAKE_READ_EXIT=51" process-environment)))
        (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
          (should (string-match-p "Keychain" (cadr err)))
          (should-not (string-search "sk-or-test-123" (cadr err))))
        (should-not (gethash 'openrouter drgnx-ai--keys))))))

(ert-deftest drgnx-ai/without-a-secret-store-it-says-what-to-install ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log
      (let ((exec-path nil) (drgnx-ai--security-program (concat bin "no-security"))
            (process-environment (cons "PATH=/nonexistent" process-environment)))
        (should (string-match-p "security" (cadr (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error))))))
    (drgnx-ai-test--with-fake-store 'gnu/linux bin log
      (let ((exec-path nil) (process-environment (cons "PATH=/nonexistent" process-environment)))
        (should (string-match-p "libsecret" (cadr (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))))
      (let ((process-environment (cons "DBUS_SESSION_BUS_ADDRESS" (cons "XDG_RUNTIME_DIR=/nonexistent" process-environment))))
        (should (string-match-p "D-Bus" (cadr (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))))
      (should-error (drgnx-ai-store-key 'ollama "x") :type 'user-error))))                ; a local runner has no key

(ert-deftest drgnx-ai/macos-read-back-asks-for-drgnx-s-entry ()
  ;; another internet password for the host could answer first: the read-back names the account the store wrote
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log      ; the same `security', for drgnx's account, host and protocol
      (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (error "The Keychain is read with `security'"))))
        (should (eq (drgnx-ai-store-key 'openrouter "sk-or-test-123") 'keychain)))
      (should (equal (drgnx-ai-test--slurp (concat log "security.calls"))
                     "find-internet-password\n-a\ndrgnx\n-s\nopenrouter.ai\n-r\nhtps\n-w\n")))
    (drgnx-ai-test--with-fake-store 'gnu/linux bin log
      (let ((specs nil))
        (cl-letf (((symbol-function 'auth-source-search)
                   (lambda (&rest spec) (push spec specs) (list (list :secret "sk-or-test-123")))))
          (drgnx-ai-store-key 'openrouter "sk-or-test-123"))
        (should (equal (plist-get (car specs) :host) "openrouter.ai"))))))

(ert-deftest drgnx-ai/a-keychain-that-stores-a-mangled-key-is-emptied-and-says-so ()
  ;; `security -i' exits 0 whatever it made of the line: only reading the item back proves what it holds
  (drgnx-ai-test--with root
    (dolist (back '("sk-or-test-12" "" "sk-or-test-123x" "sk-or-test-123\n"))   ; the last prints "key\n\n": no trimming
      (drgnx-ai-test--with-fake-store 'darwin bin log
        (let ((process-environment (cons (concat "FAKE_READBACK=" back) process-environment)))
          (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
            (should (string-match-p "Keychain" (cadr err)))
            (should (string-match-p "removed" (cadr err)))
            (should-not (string-search "sk-or-test-12" (cadr err)))))   ; neither the key nor what came back
        (should-not (gethash 'openrouter drgnx-ai--keys))
        (let ((calls (drgnx-ai-test--slurp (concat log "security.calls"))))
          (should (string-search "delete-internet-password\n-a\ndrgnx\n-s\nopenrouter.ai\n-r\nhtps\n" calls))
          (should-not (string-search "sk-or-test" calls)))
        (should-not (file-exists-p (concat log "security.store")))))))

(ert-deftest drgnx-ai/a-keychain-read-back-that-never-answers-is-bounded ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log
      (let ((drgnx-ai--store-timeout 0.5) (process-environment (cons "FAKE_READ_SLEEP=30" process-environment))
            (start (float-time)))
        (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
          (should (string-match-p "did not answer" (cadr err)))
          (should-not (string-search "as it was given" (cadr err)))
          (should-not (string-search "sk-or-test-123" (cadr err))))
        (should (< (- (float-time) start) 10))
        (should-not (gethash 'openrouter drgnx-ai--keys))
        (should (string-search "delete-internet-password" (drgnx-ai-test--slurp (concat log "security.calls"))))))))

(ert-deftest drgnx-ai/a-keychain-with-no-item-after-storing-says-so ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log
      (let ((process-environment (cons "FAKE_READ_EXIT=44" process-environment)))   ; `security': item not found
        (let ((err (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)))
          (should (string-match-p "no drgnx item" (cadr err)))
          (should-not (string-search "Keychain Access" (cadr err)))  ; there is nothing to remove by hand
          (should-not (string-search "sk-or-test-123" (cadr err))))
        (should-not (gethash 'openrouter drgnx-ai--keys))))))

(ert-deftest drgnx-ai/c-g-during-the-keychain-read-back-still-deletes-the-item ()
  ;; a quit must not leave an item nobody verified: the delete runs, then the quit goes on
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log
      (let ((call (symbol-function 'drgnx-ai--security-call)))
        (cl-letf (((symbol-function 'drgnx-ai--security-call)
                   (lambda (args) (if (equal (car args) "find-internet-password") (signal 'quit nil) (funcall call args)))))
          (should (eq (condition-case nil (progn (drgnx-ai-store-key 'openrouter "sk-or-test-123") 'returned)
                        (quit 'quit))
                      'quit))))
      (should-not (gethash 'openrouter drgnx-ai--keys))
      (should (string-search "delete-internet-password\n-a\ndrgnx\n-s\nopenrouter.ai\n-r\nhtps\n"
                             (drgnx-ai-test--slurp (concat log "security.calls"))))
      (should-not (file-exists-p (concat log "security.store"))))))

(ert-deftest drgnx-ai/a-key-with-a-line-break-or-nul-is-refused-before-any-call ()
  (drgnx-ai-test--with root
    (dolist (system '(darwin gnu/linux))
      (drgnx-ai-test--with-fake-store system bin log
        (dolist (key '("sk-or\n-test" "sk-or\r-test" "sk-or\0-test" "sk-or-test\n"))
          (let ((err (should-error (drgnx-ai-store-key 'openrouter key) :type 'user-error)))
            (should-not (string-search "sk-or" (cadr err)))))
        (should-not (directory-files log nil "\\`[^.]"))))))         ; neither program ran

(ert-deftest drgnx-ai/security-is-the-system-one-on-macos ()
  ;; a `security' earlier on the path (a stray script, a Homebrew tool) must never get the key
  (should (equal (default-value 'drgnx-ai--security-program) "/usr/bin/security"))
  (drgnx-ai-test--with root
    (drgnx-ai-test--with-fake-store 'darwin bin log
      (let ((drgnx-ai--security-program (concat bin "not-here")))      ; not the real one either: the store is never reached
        (should-error (drgnx-ai-store-key 'openrouter "sk-or-test-123") :type 'user-error)
        (should-not (file-exists-p (concat log "security.argv")))))))      ; the fake on the path was not run

(ert-deftest drgnx-ai/refused-hook-without-probe-loaded ()
  ;; a process that only loaded the client (a search, a script) still starts the runner again when nothing listens
  (let ((out (with-temp-buffer
               (call-process (expand-file-name invocation-name invocation-directory) "/dev/null" t nil
                             "--batch" "-Q" "-L" (expand-file-name "core" drgnx-dir) "--eval" "(require 'drgnx-ai-client)"
                             "--eval" "(princ (list (featurep 'drgnx-ai-probe) (and (memq 'drgnx-ai--refused drgnx-ai-refused-functions) t) (fboundp 'drgnx-ai--refused)))")
               (buffer-string))))
    (should (equal out "(nil t t)"))))

(ert-deftest drgnx-ai/the-first-window-looks-at-the-local-runner-from-an-idle-timer ()
  (let ((looked 0))
    (drgnx-test-with-clock ()
      (cl-letf (((symbol-function 'drgnx-ai-ensure-local) (lambda () (cl-incf looked))))
        (drgnx-ai--on-first-window)
        (should (drgnx-timer-active-p 'ai-first-window))
        (should (= looked 0))                                          ; never inside the hook
        (drgnx-test-idle 1)
        (should (= looked 1))
        (should-not (drgnx-timer-active-p 'ai-first-window))))))

(ert-deftest drgnx-ai/an-answer-stamps-no-rate-limit ()
  ;; the first-window look finding the server up must not hold back the restart a refused request asks for a
  ;; moment later; only a look that finds it down counts toward the once-a-minute limit
  (let ((noninteractive nil) (drgnx-ai--ensure-time nil) (drgnx-ai--ensure-looking nil)
        (up t) (started nil))
    (cl-letf (((symbol-function 'drgnx-ai-managed) (lambda () '(ollama :start ("ollama" "serve") :name "Ollama")))
              ((symbol-function 'drgnx-ai-probe)
               (lambda (callback &optional _ids) (let ((drgnx-ai-detected `((ollama :up ,up)))) (funcall callback))))
              ((symbol-function 'run-at-time) (lambda (_time _repeat fn &rest args) (apply fn args) nil))
              ((symbol-function 'drgnx-ai--start-local) (lambda (id &rest _) (push id started))))
      (drgnx-ai-ensure-local)                                  ; the first-window look: it answers
      (should-not drgnx-ai--ensure-time)
      (should-not started)
      (setq up nil)
      (drgnx-ai--refused 'ollama)                              ; …so a refusal right after is not held back
      (should (equal started '(ollama)))
      (should drgnx-ai--ensure-time)
      (drgnx-ai--refused 'ollama)                              ; a second one within the minute is
      (should (equal started '(ollama))))))

(ert-deftest drgnx-ai/agent-profiles-get-their-environment-when-they-start ()
  (drgnx-ai-test--with root
    (let ((process-environment (cons "OPENROUTER_API_KEY=sk-or-test" process-environment)))
      (should (equal (drgnx-ai-agent-env '(:kind claude-openrouter))
                     '("ANTHROPIC_BASE_URL=https://openrouter.ai/api" "ANTHROPIC_AUTH_TOKEN=sk-or-test" "ANTHROPIC_API_KEY=")))
      (should (equal (drgnx-ai-agent-env '(:kind claude-ollama))
                     '("ANTHROPIC_BASE_URL=http://127.0.0.1:11434" "ANTHROPIC_AUTH_TOKEN=ollama" "ANTHROPIC_API_KEY=")))
      (should-not (drgnx-ai-agent-env '(:kind subscription))))                             ; its own login, never read
    (should-error (drgnx-ai-agent-env '(:kind claude-openrouter)) :type 'user-error)))     ; no key: said, not sent empty

(ert-deftest drgnx-ai/an-agent-profile-names-its-kind-and-gets-the-environment-at-start ()
  (require 'drgnx-agents)
  (drgnx-ai-test--with root
    (let ((drgnx-agents-profiles '(("local claude" :command ("claude-agent-acp") :ai claude-ollama))))
      (should (member "ANTHROPIC_AUTH_TOKEN=ollama" (drgnx-agents--env (drgnx-agents--make :profile "local claude"))))
      (should (assoc "claude (OpenRouter)" drgnx-agents-builtin-profiles))                 ; offered without setup
      (should (assoc "claude (Ollama)" drgnx-agents-builtin-profiles)))))

(ert-deftest drgnx-ai/a-job-receives-keys-that-no-command-line-or-state-file-shows ()
  (drgnx-ai-test--with root
    (let* ((id (drgnx-jobs-start "k" (list "sh" "-c" "printf %s \"$SECRET_FOR_JOB\" > got") :cwd root :env '("SECRET_FOR_JOB=s3cret")))
           (d (+ (float-time) 10)))
      (while (and (not (eq (plist-get (drgnx-jobs-get id) :status) 'exited)) (< (float-time) d)) (sleep-for 0.05))
      (should (equal (with-temp-buffer (insert-file-contents (concat root "got")) (buffer-string)) "s3cret"))
      (dolist (f (directory-files (drgnx-jobs--dir id) t "\\`[^.]"))
        (should-not (string-search "s3cret" (with-temp-buffer (insert-file-contents f) (buffer-string))))))
    ;; under systemd the value travels in systemd-run's environment: --setenv=NAME, never NAME=value
    (let ((args (drgnx-jobs--systemd-args "1" root "true" '("SECRET_FOR_JOB=s3cret"))))
      (should (member "--setenv=SECRET_FOR_JOB" args))
      (should-not (seq-find (lambda (a) (string-search "s3cret" a)) args)))))

(ert-deftest drgnx-ai/the-mock-llm-server-answers-from-its-script-and-logs-requests ()
  (drgnx-ai-test--with root
    (let* ((port (+ 20000 (random 20000))) (log (concat root "llm.log")) (script (concat root "llm.eld")))
      (drgnx-ai-test--write script '((:path "/v1/chat/completions" :status 200
                                            :body "{\"choices\":[{\"message\":{\"content\":\"hello\"}}]}")))
      (let ((p (drgnx-ai-test-mock-llm port script log)))
        (unwind-protect
            (let ((out (with-temp-buffer
                         (call-process "curl" nil t nil "-s" "-H" "Authorization: Bearer k1" "-d" "{}" (format "http://127.0.0.1:%d/v1/chat/completions" port))
                         (buffer-string))))
              (should (string-search "\"hello\"" out))
              (should (string-search "Authorization: Bearer k1" (with-temp-buffer (insert-file-contents log) (buffer-string)))))
          (delete-process p))))))

(ert-deftest drgnx-ai/load-keys-reads-the-roles-keys-as-a-command-and-keeps-them ()
  ;; The keys of the providers the roles name, through the sources a command may use (the Keychain); then the
  ;; background (ghost text: not interactive) has them.  Local runners have no key: nothing is read for them.
  (drgnx-ai-test--with root
    (drgnx-ai-test--write (concat root "config/ai.eld")
                          '(:version 1 :roles ((complete (openrouter . "m") (ollama . "c")) (chat (openrouter . "m")))))
    (let ((system-type 'darwin) (noninteractive nil) (asked nil) (auth-sources nil))
      (cl-letf (((symbol-function 'auth-source-search)
                 (lambda (&rest spec) (push (cons (plist-get spec :host) auth-sources) asked)
                   (and (memq 'macos-keychain-internet auth-sources) (list (list :secret "sk-or-from-keychain"))))))
        (should-not (drgnx-ai-key 'openrouter nil))                 ; before: the background has no key
        (setq asked nil)
        (should (equal (drgnx-ai-load-keys) '(openrouter)))
        (should (equal asked '(("openrouter.ai" macos-keychain-internet))))   ; once, OpenRouter's host only
        (setq asked nil)
        (should (equal (drgnx-ai-key 'openrouter nil) "sk-or-from-keychain"))
        (should-not asked)))))                                       ; from memory

(ert-deftest drgnx-ai/drgnx-open-loads-the-keys-once-from-a-timer-never-in-batch ()
  (drgnx-ai-test--with root
    (let ((loaded 0) (drgnx-ai--keys-loading nil))
      (drgnx-test-with-clock ()
        (cl-letf (((symbol-function 'drgnx-ai-load-keys) (lambda () (cl-incf loaded) nil)))
          (let ((noninteractive t)) (drgnx-ai-load-keys-soon))      ; batch: never
          (should-not (drgnx-timer-active-p 'ai-load-keys))
          (let ((noninteractive nil))
            (drgnx-ai-load-keys-soon)
            (should (= loaded 0))                                     ; nothing inside the emacsclient call
            (should (drgnx-timer-active-p 'ai-load-keys))             ; a keyed layer timer, Emacs-lifetime
            (drgnx-test-advance 0.5)
            (should (= loaded 1))
            (should-not (drgnx-timer-active-p 'ai-load-keys))
            (drgnx-ai-load-keys-soon)                                 ; once per daemon
            (should-not (drgnx-timer-active-p 'ai-load-keys))))))
    ;; bin/drgnx open asks the daemon for it, after the window
    (let ((bin (with-temp-buffer (insert-file-contents (expand-file-name "bin/drgnx" drgnx-dir)) (buffer-string))))
      (should (string-match-p "client -n -e '(drgnx-session-raise)'.*\n.*drgnx-ai-load-keys-soon" bin)))))

(require 'drgnx-keys)

(ert-deftest drgnx-ai/load-keys-is-a-command-without-a-key-in-every-profile ()
  (let ((src (with-temp-buffer (insert-file-contents (expand-file-name "modules/tools/drgnx-ai-ui.el" drgnx-dir)) (buffer-string))))
    (should (string-match-p "(ai-load-keys \"Load Keys\" drgnx-ai-load-keys" src)))      ; registered with the AI commands
  (should (commandp #'drgnx-ai-load-keys))
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (should (= 3 (length profiles)))
    (dolist (p profiles)
      (let ((entry (assq 'ai-load-keys (plist-get (cdr p) :bind))))
        (should entry)
        (should (eq (cadr entry) :none))
        (should (stringp (nth 2 entry)))))))                                            ; with its reason

(defmacro drgnx-ai-test--with-gptel-vars (vars &rest body)
  "BODY with the gptel variables VARS ((SYMBOL VALUE)…) set by hand and unset or restored after: gptel is not loaded
here, and a variable let-bound before it loads would turn special for good."
  (declare (indent 1))
  `(let ((saved (mapcar (lambda (v) (list (car v) (boundp (car v)) (and (boundp (car v)) (symbol-value (car v))))) ',vars)))
     (unwind-protect (progn ,@(mapcar (lambda (v) `(set ',(car v) ,(cadr v))) vars) ,@body)
       (dolist (s saved) (if (nth 1 s) (set (nth 0 s) (nth 2 s)) (makunbound (nth 0 s)))))))

(ert-deftest drgnx-ai/own-gptel-api-key-keeps-default-backend ()
  ;; gptel's default backend with the user's own `gptel-api-key' is the user's choice: not replaced
  (drgnx-ai-test--with root
    (let ((drgnx-ai--gptel-ours nil))
      (cl-letf (((symbol-function 'gptel-make-ollama) (lambda (name &rest _) (list 'backend name))))
        (drgnx-ai-test--with-gptel-vars ((gptel--openai 'the-default) (gptel-backend 'the-default) (gptel-model 'gpt-x)
                                         (gptel-api-key "sk-x"))
          (should-not (drgnx-ai-gptel-maybe-configure (lambda (id) (eq id 'ollama))))
          (should (eq gptel-backend 'the-default))
          (should (eq gptel-model 'gpt-x))
          ;; gptel's own default key function is nobody's choice: the default backend is still replaced
          (set 'gptel-api-key #'gptel-api-key-from-auth-source)
          (should (drgnx-ai-gptel-maybe-configure (lambda (id) (eq id 'ollama))))
          (should (equal gptel-backend '(backend "Ollama"))))))))

;;; ai-test.el ends here

;;;; A project's route to a remote provider (M9-10)

(defun drgnx-ai-test--remote-project (root)
  "ROOT/proj routes complete to OpenRouter then Ollama, chat to OpenRouter only; returns the project dir."
  (drgnx-ai-test--write (concat root "proj/.drgnx/ai.eld")
                        '(:version 1 :roles ((complete (openrouter . "paid/m") (ollama . "local-m"))
                                             (chat (openrouter . "paid/m")))))
  (concat root "proj/"))

(ert-deftest drgnx-ai/an-unconfirmed-remote-route-is-local-only-and-never-prompts ()
  (drgnx-ai-test--with root
    (let ((default-directory (drgnx-ai-test--remote-project root)) (asked nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (setq asked t)))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) (setq asked t))))
        (should (equal (drgnx-ai-role 'complete) '((ollama . "local-m"))))      ; the remote step is left out
        (should (equal (drgnx-ai-role 'chat) (alist-get 'chat drgnx-ai-default-roles)))   ; only remote: the user's chain
        (should-not asked)))))

(ert-deftest drgnx-ai/confirming-a-project-route-asks-once-and-remembers-per-root ()
  (drgnx-ai-test--with root
    (let ((default-directory (drgnx-ai-test--remote-project root)) (asks 0) (answer t) (noninteractive nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf asks) answer)))
        (should (drgnx-ai-confirm-project-route))
        (should (= asks 1))
        (should (equal (drgnx-ai-role 'complete) '((openrouter . "paid/m") (ollama . "local-m"))))   ; the project's own
        (should (drgnx-ai-confirm-project-route))
        (should (= asks 1))                                                      ; not asked again…
        (should (drgnx-ai-confirm-project-route))                                ; …the answer is on disk, per root
        (should (equal (drgnx-ai-role 'complete) '((openrouter . "paid/m") (ollama . "local-m"))))
        (should (= asks 1))
        (should (string-search (file-truename (concat root "proj/"))(with-temp-buffer (insert-file-contents (drgnx-ai-routes-file)) (buffer-string))))
        ;; another project root is asked on its own
        (make-directory (concat root "other/.drgnx") t)
        (copy-file (concat root "proj/.drgnx/ai.eld") (concat root "other/.drgnx/ai.eld"))
        (let ((default-directory (concat root "other/")))
          (setq answer nil)
          (should-not (drgnx-ai-confirm-project-route))
          (should (= asks 2))
          (should (equal (drgnx-ai-role 'complete) '((ollama . "local-m"))))      ; a no keeps it local…
          (should-not (drgnx-ai-confirm-project-route))
          (should (= asks 2)))))))                                                ; …and is not asked again

(ert-deftest drgnx-ai/confirming-never-asks-in-batch-or-for-a-local-route ()
  (drgnx-ai-test--with root
    (let ((asks 0))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf asks) t)))
        (let ((default-directory (drgnx-ai-test--remote-project root)) (noninteractive t))
          (should-not (drgnx-ai-confirm-project-route))                           ; batch: no, silently
          (should (= asks 0)))
        (drgnx-ai-test--write (concat root "proj/.drgnx/ai.eld") '(:version 1 :roles ((complete (ollama . "m")))))
        (let ((default-directory (concat root "proj/")) (noninteractive nil))
          (should (drgnx-ai-confirm-project-route))                               ; nothing remote: nothing to ask
          (should (= asks 0)))
        (let ((default-directory root) (noninteractive nil))                      ; no project file at all
          (should (drgnx-ai-confirm-project-route))
          (should (= asks 0)))))))

(ert-deftest drgnx-ai/a-route-to-a-new-remote-provider-is-asked-again ()
  (drgnx-ai-test--with root
    (let ((default-directory (drgnx-ai-test--remote-project root)) (asks 0) (noninteractive nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf asks) t)))
        (drgnx-ai-confirm-project-route)
        (drgnx-ai-test--write (concat root "proj/.drgnx/ai.eld")
                              '(:version 1 :roles ((chat (openrouter . "paid/m") (anthropic . "x")))))
        (set-file-times (concat root "proj/.drgnx/ai.eld") (time-add (current-time) 5))
        (should (equal (drgnx-ai-role 'chat) '((openrouter . "paid/m"))))         ; the new one is held back
        (drgnx-ai-confirm-project-route)
        (should (= asks 2))))))

;;;; Fix round 1

(ert-deftest drgnx-ai/auth-sources-own-keychain-plists-are-secret-sources ()
  (dolist (s '((:source (:macos-keychain-internet default)) (:source (:macos-keychain-generic "login"))
               (:source (:macos-keychain-internet "login.keychain"))))
    (should (drgnx-ai--secret-source-p s))
    (should-not (drgnx-ai--quiet-sources (list s "~/.authinfo.gpg"))))
  (should-not (drgnx-ai--secret-source-p '(:source (:other "x")))))

(ert-deftest drgnx-ai/no-secret-source-when-the-bus-has-no-secret-service ()
  ;; a session bus (SSH, WSL, a container) without a keyring daemon: `default' would log "invalid backend spec"
  (drgnx-ai-test--with root
    (let* ((plain (concat root "authinfo")) (system-type 'gnu/linux) (noninteractive nil)
           (auth-sources (list plain)) (searched nil)
           (process-environment (cons "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/drgnx-test-bus" process-environment)))
      (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) (push auth-sources searched) nil))
                ((symbol-function 'drgnx-ai--secrets-usable-p) (lambda () nil)))
        (should-not (drgnx-ai-key 'openrouter t))
        (should (equal searched (list (list plain))))))))

(ert-deftest drgnx-ai/a-provider-with-no-host-counts-as-remote ()
  (drgnx-ai-test--with root
    (drgnx-ai-test--write (concat root "config/ai.eld")
                          '(:version 1 :providers ((bare :name "b" :kind openai :url "openrouter.ai/api/v1" :caps (chat))
                                                   (none :name "n" :kind openai :caps (chat))
                                                   (spoof :name "s" :kind openai :url "http://localhost.evil.com/v1" :caps (chat))
                                                   (at :name "a" :kind openai :url "http://127.0.0.1@evil.com/v1" :caps (chat))
                                                   (v6 :name "v" :kind openai :url "http://[::1]:9/v1" :caps (chat)))))
    (dolist (id '(bare none spoof at)) (should (drgnx-ai-remote-p id)))
    (should-not (drgnx-ai-remote-p 'v6))
    (should-not (drgnx-ai-remote-p 'ollama))
    (should-not (drgnx-ai-remote-p 'not-a-provider))
    (should (drgnx-ai-remote-p 'openrouter))))

(ert-deftest drgnx-ai/one-repo-reached-by-two-paths-is-asked-once-and-a-repointed-link-asks-again ()
  (drgnx-ai-test--with root
    (let ((real (drgnx-ai-test--remote-project root)) (asks 0) (noninteractive nil)
          (link (concat root "link")))
      (make-directory (concat root "other/.drgnx") t)
      (copy-file (concat real ".drgnx/ai.eld") (concat root "other/.drgnx/ai.eld"))
      (make-symbolic-link (directory-file-name real) link)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf asks) t)))
        (let ((default-directory (file-name-as-directory link))) (should (drgnx-ai-confirm-project-route)))
        (should (= asks 1))
        (let ((default-directory real))                                           ; the same repo by its real path
          (should (drgnx-ai-confirm-project-route))
          (should (= asks 1))
          (should (assq (quote openrouter) (drgnx-ai-role (quote complete)))))
        ;; the link now points at another repository: it does not inherit the answer
        (delete-file link)
        (make-symbolic-link (directory-file-name (concat root "other")) link)
        (let ((default-directory (file-name-as-directory link)))
          (should-not (assq 'openrouter (drgnx-ai-role 'complete)))
          (should (drgnx-ai-confirm-project-route))
          (should (= asks 2)))))))

(ert-deftest drgnx-ai/an-empty-embed-sync-reports-no-provider ()
  (require 'drgnx-ai-client)
  (let ((drgnx-ai-embed-last-info '(:provider tei)) got)
    (should (equal [] (drgnx-ai-embed-sync [] :on-answer (lambda (i) (setq got i)))))
    (should (equal got '(:provider nil :model nil :fallbacks nil)))
    (should (equal drgnx-ai-embed-last-info got))))

;;;; ai-detected.eld and ai-local.eld (config Task 22)

(defun drgnx-ai-test--read-file (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defmacro drgnx-ai-test--with-answers (answers &rest body)
  "BODY with `drgnx-ai--curl' answering at once from ANSWERS ((URL-SUBSTRING STATUS TEXT)…): no server is asked."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'drgnx-ai--curl)
              (lambda (url callback &rest _)
                (let ((hit (seq-find (lambda (a) (string-search (car a) url)) ,answers)))
                  (funcall callback (or (nth 1 hit) 0) (or (nth 2 hit) ""))))))
     ,@body))

(defun drgnx-ai-test--probe (ids)
  "Probe IDS with the answers of `drgnx-ai-test--with-answers' (an Ollama that lists one model); the callback's count."
  (let ((called 0))
    (drgnx-ai-probe (lambda () (cl-incf called)) ids)
    called))

(ert-deftest drgnx-ai/a-probe-keeps-providers-another-process-found ()
  ;; the file is merged into under its lock: a provider only another Emacs found stays in it
  (drgnx-ai-test--with root
    (let ((drgnx-ai-detected nil) (file (drgnx-ai-detected-file)))
      (make-directory (file-name-directory file) t)
      (drgnx-ai-test--write file '((vllm :up t :models ("big")) (ollama :up nil)))
      (drgnx-ai-test--with-answers '(("/api/tags" 200 "{\"models\":[{\"name\":\"qwen:1b\"}]}"))
        (should (= 1 (drgnx-ai-test--probe '(ollama)))))
      (let ((saved (drgnx-ai-detected-cached)))
        (should (equal (alist-get 'vllm saved) '(:up t :models ("big"))))             ; the other process's, kept
        (should (equal (alist-get 'ollama saved) '(:up t :models ("qwen:1b"))))       ; this probe's, replacing the old
        (should (= (length saved) 2)))
      (should-not (alist-get 'vllm drgnx-ai-detected)))))                             ; this process only knows what it asked

(ert-deftest drgnx-ai/an-unreadable-detected-file-is-copied-aside-and-written-again ()
  (drgnx-ai-test--with root
    (let ((drgnx-ai-detected nil) (file (drgnx-ai-detected-file)) (broken "((ollama :up t\n;; mine\n"))
      (make-directory (file-name-directory file) t)
      (write-region broken nil file nil 'silent)
      (should-not (drgnx-ai-detected-cached))                                         ; a mistake reads as nothing
      (drgnx-ai-test--with-answers '(("/api/tags" 200 "{\"models\":[]}"))
        (drgnx-ai-test--probe '(ollama)))
      (should (plist-get (alist-get 'ollama (drgnx-ai-detected-cached)) :up))
      (let ((baks (directory-files (file-name-directory file) t "\\`ai-detected\\.eld\\.bak-")))
        (should (= (length baks) 1))
        (should (equal (drgnx-ai-test--read-file (car baks)) broken))))))             ; the mistake's bytes, kept

(ert-deftest drgnx-ai/a-busy-lock-skips-without-a-prompt ()
  (drgnx-ai-test--with root
    (let* ((drgnx-ai-detected nil) (file (drgnx-ai-detected-file)) (bytes "((vllm :up t))\n")
           (lock (expand-file-name ".ai-detected.eld.lock" (file-name-directory file)))
           (now (float-time)) (sleeps 0) (seen nil) (messages nil))
      (make-directory (file-name-directory file) t)
      (write-region bytes nil file nil 'silent)
      (make-directory lock)                                       ; another drgnx holds the file
      (write-region (prin1-to-string (list :pid (emacs-pid) :host (system-name)
                                           :started (drgnx-file--pid-start (emacs-pid)) :time now))
                    nil (expand-file-name "owner" lock) nil 'silent)
      (cl-letf (((symbol-function 'drgnx-file--now) (lambda () now))
                ((symbol-function 'drgnx-file--sleep) (lambda (s) (cl-incf sleeps) (setq now (+ now s))))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "asked")))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "asked")))
                ((symbol-function 'read-string) (lambda (&rest _) (ert-fail "asked")))
                ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages)))
                ((symbol-function 'drgnx-file--lock)
                 (let ((orig (symbol-function 'drgnx-file--lock)))
                   (lambda (&rest args) (push inhibit-interaction seen) (apply orig args)))))
        (drgnx-ai-test--with-answers '(("/api/tags" 200 "{\"models\":[]}"))
          (should (= 1 (drgnx-ai-test--probe '(ollama))))))          ; the callback still runs
      (should (equal seen '(t)))                                  ; …under inhibit-interaction
      (should (= sleeps 0))                                       ; one attempt: no wait
      (should (equal (drgnx-ai-test--read-file file) bytes))      ; skipped: the file is as it was
      (should (plist-get (alist-get 'ollama drgnx-ai-detected) :up))   ; this process still knows its answers
      (should-not messages)
      ;; the lock is gone: the next probe writes
      (delete-directory lock t)
      (drgnx-ai-test--with-answers '(("/api/tags" 200 "{\"models\":[]}"))
        (drgnx-ai-test--probe '(ollama)))
      (let ((saved (drgnx-ai-detected-cached)))
        (should (alist-get 'vllm saved))
        (should (plist-get (alist-get 'ollama saved) :up))))))

(ert-deftest drgnx-ai/set-managed-keeps-what-else-the-file-holds-and-reads-back ()
  (drgnx-ai-test--with root
    (let ((file (drgnx-ai-local-file)))
      (should-not (drgnx-ai-managed))
      (make-directory (file-name-directory file) t)
      (drgnx-ai-test--write file '(:note "kept" :managed (ollama :start ("old") :name "Old")))
      (should (equal (drgnx-ai-managed) '(ollama :start ("old") :name "Old")))
      (drgnx-ai-set-managed 'lmstudio '("/opt/lms" "server" "start") "LM Studio")
      (should (equal (drgnx-ai-managed) '(lmstudio :start ("/opt/lms" "server" "start") :name "LM Studio")))
      (should (equal (plist-get (car (read-from-string (drgnx-ai-test--read-file file))) :note) "kept"))
      ;; a mistake in the file is copied aside, not lost
      (write-region "(:managed (ollama\n" nil file nil 'silent)
      (should-not (drgnx-ai-managed))
      (drgnx-ai-set-managed 'ollama '("ollama" "serve") "Ollama")
      (should (equal (drgnx-ai-managed) '(ollama :start ("ollama" "serve") :name "Ollama")))
      (should (= 1 (length (directory-files (file-name-directory file) nil "\\`ai-local\\.eld\\.bak-")))))))
