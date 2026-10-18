;;; onboard-portability-test.el --- batch tests: onboarding step 8, Portability -*- lexical-binding: t -*-
;; Every test runs in a temp HOME with its own config, data and state dirs: never ~, ~/.config or the keyring.
;; git is real (in the temp config dir); chezmoi is a fake script that records its argv; questions are stubbed.
;; Test keys are built at run time, never written literally (the pre-commit hook rejects them).
(require 'ert)
(require 'drgnx-onboard)
(require 'drgnx-portable)
(require 'drgnx-secrets)

(defmacro drgnx-onboard-portability-test--with (root &rest body)
  "BODY with ROOT a temp dir holding home/, config/ (with a keys.eld), data/, state/ and bin/ (first on the path).
git has an identity from the environment; chezmoi is not found unless a test puts one in bin/."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-portability" t)))
          (process-environment (append (list (concat "HOME=" ,root "home")
                                             (concat "DRGNX_CONFIG_DIR=" ,root "config")
                                             (concat "DRGNX_DATA_DIR=" ,root "data")
                                             (concat "XDG_STATE_HOME=" ,root "state")
                                             "GIT_CONFIG_NOSYSTEM=1"
                                             "GIT_AUTHOR_NAME=Test" "GIT_AUTHOR_EMAIL=test@example.invalid"
                                             "GIT_COMMITTER_NAME=Test" "GIT_COMMITTER_EMAIL=test@example.invalid")
                                       process-environment))
          (exec-path (cons (concat ,root "bin") exec-path)))
     (dolist (d '("home" "config" "bin")) (make-directory (concat ,root d) t))
     (write-region "(:profile vscode)\n" nil (concat ,root "config/keys.eld") nil 'silent)
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-onboard--keys-to-export-p) #'ignore))
           ,@body)
       (delete-directory ,root t))))

(defun drgnx-onboard-portability-test--run (interactive &optional answers)
  "Step 8 with CTX INTERACTIVE; ANSWERS: alist (REGEXP . ANSWER) for `y-or-n-p' (a question none matches fails).
Returns (RESULT QUESTIONS)."
  (let ((questions nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (q)
                 (push q questions)
                 (let ((a (seq-find (lambda (a) (string-match-p (car a) q)) answers)))
                   (unless a (error "Unexpected question: %s" q))
                   (cdr a)))))
      (list (drgnx-onboard--portability-step (list :interactive interactive :options nil)) (nreverse questions)))))

(defun drgnx-onboard-portability-test--git (dir &rest args)
  "git ARGS in DIR: its output, trimmed."
  (with-temp-buffer
    (apply #'call-process "git" nil t nil "-C" dir args)
    (string-trim (buffer-string))))

(defun drgnx-onboard-portability-test--chezmoi (root managed)
  "A fake chezmoi in ROOT/bin that records its argv to ROOT/chezmoi.log; `source-path' succeeds when MANAGED."
  (let ((f (concat root "bin/chezmoi")))
    (write-region (format "#!/bin/sh\nprintf '%%s\\n' \"$*\" >> '%schezmoi.log'\n%s\n" root
                          (if managed (format "echo '%shome/.local/share/chezmoi'; exit 0" root) "exit 1"))
                  nil f nil 'silent)
    (set-file-modes f #o755)))

(ert-deftest drgnx-onboard-portability/none-makes-a-repo-when-asked ()
  (drgnx-onboard-portability-test--with root
    (let* ((config (concat root "config"))
           (r (drgnx-onboard-portability-test--run t '(("git repository" . t)))))
      (should (file-directory-p (concat config "/.git")))
      (should (equal (drgnx-onboard-portability-test--git config "rev-list" "--count" "HEAD") "1"))
      (should (equal (drgnx-onboard-portability-test--git config "ls-tree" "-r" "--name-only" "HEAD") "keys.eld"))
      (should (equal (drgnx-onboard-portability-test--git config "remote") ""))   ; never a remote
      (should (equal (drgnx-onboard-portability-test--git config "log" "-1" "--format=%s") "drgnx configuration"))
      (should (string-match-p "YOUR-REPO-URL" (cadr (car r))))
      (should (= 1 (length (cadr r))))))
  ;; no → no repository
  (drgnx-onboard-portability-test--with root
    (let ((r (drgnx-onboard-portability-test--run t '(("git repository" . nil)))))
      (should-not (file-exists-p (concat root "config/.git")))
      (should (string-match-p "not a git repository" (cadr (car r)))))))

(ert-deftest drgnx-onboard-portability/never-commits-a-plain-key ()
  (drgnx-onboard-portability-test--with root
    (write-region (format "(setq my-key %S)\n" (concat "sk-or-v1-" (make-string 24 ?x))) nil
                  (concat root "config/config.el") nil 'silent)
    (let ((r (drgnx-onboard-portability-test--run t)))   ; nothing is asked: no question matches
      (should-not (file-exists-p (concat root "config/.git")))
      (should (eq (car (car r)) 'warn))
      (should (string-match-p "config\\.el" (cadr (car r))))
      (should (string-match-p "never committed: move the key to your keyring first" (cadr (car r))))
      (should-not (string-match-p "sk-or-v1-" (cadr (car r))))
      (should (null (cadr r))))))

(ert-deftest drgnx-onboard-portability/machine-local-files-leave-first ()
  (drgnx-onboard-portability-test--with root
    (write-region "/usr/bin/emacs\n" nil (concat root "config/emacs") nil 'silent)
    (let* ((config (concat root "config"))
           (r (drgnx-onboard-portability-test--run t '(("git repository" . t)))))
      (should-not (file-exists-p (concat config "/emacs")))
      (should (file-exists-p (concat root "data/emacs")))
      (should (equal (drgnx-onboard-portability-test--git config "ls-tree" "-r" "--name-only" "HEAD") "keys.eld"))
      (should (string-match-p "moved to the data dir: emacs" (cadr (car r))))))
  ;; a different copy in the data dir: the config dir's stays, and is never committed
  (drgnx-onboard-portability-test--with root
    (write-region "/usr/bin/emacs\n" nil (concat root "config/emacs") nil 'silent)
    (make-directory (concat root "data") t)
    (write-region "/opt/emacs/bin/emacs\n" nil (concat root "data/emacs") nil 'silent)
    (let* ((config (concat root "config"))
           (r (drgnx-onboard-portability-test--run t '(("git repository" . t)))))
      (should (file-exists-p (concat config "/emacs")))
      (should (equal (drgnx-onboard-portability-test--git config "ls-tree" "-r" "--name-only" "HEAD") "keys.eld"))
      (should (string-match-p "emacs stays" (cadr (car r)))))))

(ert-deftest drgnx-onboard-portability/a-repo-is-reported-with-the-next-command ()
  (drgnx-onboard-portability-test--with root
    (let ((config (concat root "config")))
      (drgnx-onboard-portability-test--git config "init" "-q")
      (drgnx-onboard-portability-test--git config "remote" "add" "origin" "https://example.org/ana/drgnx-config.git")
      (should (equal (drgnx-onboard--config-source) '(git . "https://example.org/ana/drgnx-config.git")))
      (let ((r (drgnx-onboard-portability-test--run t)))   ; a repository already: nothing asked, nothing committed
        (should (eq (car (car r)) 'ok))
        (should (string-match-p (regexp-quote (concat "curl -fsSL " drgnx-portable-install-url
                                                      " | bash -s -- --config https://example.org/ana/drgnx-config.git"))
                                (cadr (car r))))
        (should (equal (drgnx-onboard-portability-test--git config "rev-list" "--all" "--count") "0")))
      ;; a password in the remote is never shown
      (drgnx-onboard-portability-test--git config "remote" "set-url" "origin" "https://ana:hunter2@example.org/ana/c.git")
      (let ((m (cadr (car (drgnx-onboard-portability-test--run nil)))))
        (should-not (string-match-p "hunter2" m))
        (should (string-match-p "--config https://example.org/ana/c\\.git" m)))
      ;; an ssh remote: install.sh takes https, so the command has a placeholder
      (drgnx-onboard-portability-test--git config "remote" "set-url" "origin" "git@example.org:ana/c.git")
      (let ((m (cadr (car (drgnx-onboard-portability-test--run nil)))))
        (should (string-match-p "--config YOUR-REPO-URL" m))
        (should (string-match-p "git@example.org:ana/c.git" m)))))
  ;; a repo with no remote: the command has a placeholder
  (drgnx-onboard-portability-test--with root
    (drgnx-onboard-portability-test--git (concat root "config") "init" "-q")
    (should (equal (drgnx-onboard--config-source) '(git)))
    (let ((r (drgnx-onboard-portability-test--run t)))
      (should (eq (car (car r)) 'info))
      (should (string-match-p "--config YOUR-REPO-URL" (cadr (car r)))))))

(ert-deftest drgnx-onboard-portability/a-missing-git-identity-says-how ()
  (drgnx-onboard-portability-test--with root
    (let ((process-environment (append (list (concat "GIT_CONFIG_GLOBAL=" root "gitconfig"))
                                       (seq-remove (lambda (e) (string-match-p "\\`GIT_\\(AUTHOR\\|COMMITTER\\)_" e))
                                                   process-environment))))
      (write-region "[user]\n\tuseConfigOnly = true\n" nil (concat root "gitconfig") nil 'silent)
      (let ((r (drgnx-onboard-portability-test--run t '(("git repository" . t)))))
        (should (file-directory-p (concat root "config/.git")))   ; the repository stays initialised
        (should (eq (car (car r)) 'info))
        (should (string-match-p "git config --global user.email" (cadr (car r))))))))

(ert-deftest drgnx-onboard-portability/chezmoi-is-explained-not-run ()
  (drgnx-onboard-portability-test--with root
    (drgnx-onboard-portability-test--chezmoi root nil)
    (let ((r (drgnx-onboard-portability-test--run t '(("git repository" . nil)))))
      (should (string-match-p "chezmoi add ~/\\.config/drgnx\\|chezmoi add .*config" (cadr (car r))))
      (should (string-match-p "not --encrypt" (cadr (car r))))
      (let ((log (with-temp-buffer (insert-file-contents (concat root "chezmoi.log")) (buffer-string))))
        (should (string-match-p "\\`source-path " log))
        (dolist (line (split-string log "\n" t)) (should (string-prefix-p "source-path " line))))))
  ;; managed by chezmoi: reported, nothing asked, the next machine's command uses --chezmoi
  (drgnx-onboard-portability-test--with root
    (drgnx-onboard-portability-test--chezmoi root t)
    (should (equal (drgnx-onboard--config-source) (cons 'chezmoi (concat root "home/.local/share/chezmoi"))))
    (let ((r (drgnx-onboard-portability-test--run t)))
      (should (string-match-p "chezmoi" (cadr (car r))))
      (should (string-match-p "--chezmoi YOUR-REPO-URL" (cadr (car r))))
      (should-not (file-exists-p (concat root "config/.git"))))))

(ert-deftest drgnx-onboard-portability/non-interactive-changes-nothing ()
  (drgnx-onboard-portability-test--with root
    (write-region "/usr/bin/emacs\n" nil (concat root "config/emacs") nil 'silent)
    (let ((r (drgnx-onboard-portability-test--run nil)))   ; any question fails the test
      (should (eq (car (car r)) 'info))
      (should (null (cadr r)))
      (should-not (file-exists-p (concat root "config/.git")))
      (should (file-exists-p (concat root "config/emacs")))
      (should-not (file-exists-p (concat root "data/emacs")))
      (should (string-match-p "not a git repository" (cadr (car r))))
      (should (string-match-p "bash -s -- --config YOUR-REPO-URL" (cadr (car r)))))))

(ert-deftest drgnx-onboard-portability/export-opens-the-terminal ()
  (drgnx-onboard-portability-test--with root
    (let ((calls nil))
      (cl-letf (((symbol-function 'drgnx-onboard--keys-to-export-p) (lambda () t))
                ((symbol-function 'drgnx-onboard--install) (lambda (tool _ctx) (push (list 'install tool) calls) 'ok))
                ((symbol-function 'drgnx-secrets-export-keys) (lambda () (push '(export) calls))))
        (let ((r (drgnx-onboard-portability-test--run t '(("git repository" . nil) ("Export your provider keys" . t)))))
          (should (equal (nreverse calls) '((install age) (export))))
          (should (eq (car (car r)) 'info))
          (should (string-match-p "finish in the terminal" (cadr (car r)))))
        ;; no → nothing installed, no terminal
        (setq calls nil)
        (drgnx-onboard-portability-test--run t '(("git repository" . nil) ("Export your provider keys" . nil)))
        (should (null calls))
        ;; age could not be installed: no terminal, the step says why
        (cl-letf (((symbol-function 'drgnx-onboard--install) (lambda (_ _) (list 'fail "age is not there" nil))))
          (let ((r (drgnx-onboard-portability-test--run t '(("git repository" . nil) ("Export your provider keys" . t)))))
            (should (null calls))
            (should (string-match-p "age is not there" (cadr (car r))))))))))

(defun drgnx-onboard-portability-test--script (file text)
  "An executable shell script FILE with body TEXT."
  (make-directory (file-name-directory file) t)
  (write-region (concat "#!/bin/sh\n" text "\n") nil file nil 'silent)
  (set-file-modes file #o755))

(ert-deftest drgnx-onboard-portability/the-users-hooks-and-signing-never-run ()
  ;; The user's global config names a hooks directory and signs every commit: neither runs for drgnx's commit.
  (drgnx-onboard-portability-test--with root
    (let ((marker (concat root "ran")))
      (dolist (hook '("pre-commit" "commit-msg" "post-commit" "post-checkout"))
        (drgnx-onboard-portability-test--script (concat root "hooks/" hook) (format "echo %s >> '%s'" hook marker)))
      (drgnx-onboard-portability-test--script (concat root "gpg") (format "echo gpg >> '%s'; sleep 30; exit 1" marker))
      (drgnx-onboard-portability-test--script (concat root "templates/hooks/post-commit") (format "echo template >> '%s'" marker))
      (write-region (format "[core]\n\thooksPath = %shooks\n[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = %sgpg\n[init]\n\ttemplateDir = %stemplates\n"
                            root root root)
                    nil (concat root "gitconfig") nil 'silent)
      (let* ((process-environment (cons (concat "GIT_CONFIG_GLOBAL=" root "gitconfig") process-environment))
             (start (float-time))
             (r (drgnx-onboard-portability-test--run t '(("git repository" . t)))))
        (should (< (- (float-time) start) 10))
        (should (eq (car (car r)) 'ok))
        (should (equal (drgnx-onboard-portability-test--git (concat root "config") "rev-list" "--count" "HEAD") "1"))
        (should-not (file-exists-p marker))))))

(ert-deftest drgnx-onboard-portability/a-hung-git-fails-with-a-clear-problem ()
  (drgnx-onboard-portability-test--with root
    (drgnx-onboard-portability-test--script (concat root "bin/git") "sleep 30")
    (let* ((drgnx-onboard-call-timeout 0.5)
           (start (float-time))
           (r (drgnx-onboard-portability-test--run t '(("git repository" . t)))))
      (should (< (- (float-time) start) 10))
      (should (eq (car (car r)) 'warn))
      (should (string-match-p "git init did not finish within 0.5 s" (cadr (car r)))))))

(ert-deftest drgnx-onboard-portability/inside-another-repository-no-init ()
  (drgnx-onboard-portability-test--with root
    (drgnx-onboard-portability-test--git root "init" "-q")   ; the temp root holds config/: an enclosing work tree
    (should (eq (car (drgnx-onboard--config-source)) 'inside))
    (let ((r (drgnx-onboard-portability-test--run t)))   ; no question: none matches
      (should-not (file-exists-p (concat root "config/.git")))
      (should (null (cadr r)))
      (should (string-match-p (concat "inside the git repository " (regexp-quote (directory-file-name root)))
                              (cadr (car r)))))))

(ert-deftest drgnx-onboard-portability/credentials-in-a-remote-never-show ()
  (dolist (c '(("http://u:tok@h.example/x.git" . "http://h.example/x.git")
               ("ssh://u:pw@h.example/x.git" . "ssh://h.example/x.git")
               ("https://u:tok@h.example/x.git?private_token=abc#frag" . "https://h.example/x.git")
               ("git@h.example:ana/x.git" . "git@h.example:ana/x.git")))
    (should (equal (drgnx-onboard--remote-label (car c)) (cdr c))))
  (should (equal (drgnx-onboard--https-remote "https://u:tok@h.example/x.git?private_token=abc") "https://h.example/x.git"))
  (drgnx-onboard-portability-test--with root
    (let ((config (concat root "config")))
      (drgnx-onboard-portability-test--git config "init" "-q")
      (dolist (url '("http://u:tok@h.example/x.git" "ssh://u:pw@h.example/x.git"))
        (drgnx-onboard-portability-test--git config "remote" "remove" "origin")
        (drgnx-onboard-portability-test--git config "remote" "add" "origin" url)
        (drgnx-onboard-run :only '(portability) :non-interactive t)   ; the result is saved in onboarding.eld
        (let ((saved (with-temp-buffer (insert-file-contents (drgnx-onboard-state-file)) (buffer-string))))
          (should (string-match-p "h\\.example/x\\.git" saved))
          (should-not (string-match-p "u:tok\\|u:pw\\|tok@\\|pw@" saved)))))))

(ert-deftest drgnx-onboard-portability/no-export-question-when-secrets-age-is-there ()
  (drgnx-onboard-portability-test--with root
    (write-region "age ciphertext\n" nil (concat root "config/secrets.age") nil 'silent)
    (let ((calls nil))
      (cl-letf (((symbol-function 'drgnx-onboard--keys-to-export-p) (lambda () (push 'keyring calls) t))
                ((symbol-function 'drgnx-secrets-export-keys) (lambda () (push 'export calls))))
        (let ((r (drgnx-onboard-portability-test--run t '(("git repository" . nil)))))   ; the export question fails
          (should (null calls))
          (should (string-match-p "secrets.age is there" (cadr (car r)))))))))

(ert-deftest drgnx-onboard-portability/the-keyring-is-not-opened-in-batch ()
  ;; Only a step run in drgnx's window looks into the keyring (whether there is a key to export).
  (let ((opened nil))
    (cl-letf (((symbol-function 'drgnx-secrets-keyring-p) (lambda () (setq opened t) t))
              ((symbol-function 'drgnx-secrets--entries) (lambda () (setq opened t) nil)))
      (should-not (drgnx-onboard--keys-to-export-p))
      (should-not opened))))

(ert-deftest drgnx-onboard-portability/the-step-runs-it ()
  (should (eq (plist-get (alist-get 'portability drgnx-onboard--steps) :run) #'drgnx-onboard--portability-step)))

;;; onboard-portability-test.el ends here
