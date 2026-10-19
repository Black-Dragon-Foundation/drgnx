;;; bootstrap-test.el --- batch tests: drgnx bootstrap, a second machine from your configuration -*- lexical-binding: t -*-
;; Every test runs in a temp root of its own: HOME, config, data and state dirs, a bin/ first on the path with fake
;; age, chezmoi, sudo and dnf (each records its argv, never stdin), and a bare repository made from a fixture
;; config with real git.  The package sync, onboarding, the doctor and the key import are stubbed where a test says
;; so; the keyring is never opened (`drgnx-secrets-keyring-p' is stubbed).  No network: URLs are local paths.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-bootstrap)
(require 'drgnx-doctor)

(defun drgnx-bootstrap-test--git (dir &rest args)
  "git ARGS in DIR (the test's own, never a user's hooks): its output, trimmed."
  (with-temp-buffer
    (apply #'call-process "git" nil t nil "-c" "core.hooksPath=/dev/null" "-C" dir args)
    (string-trim (buffer-string))))

(defun drgnx-bootstrap-test--write (file text &optional modes)
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent)
  (when modes (set-file-modes file modes)))

(defun drgnx-bootstrap-test--text (file)
  (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))

(defun drgnx-bootstrap-test--fake (root name body)
  "A fake program NAME in ROOT/bin: it appends \"NAME ARGV\" to ROOT/argv.log, then runs the sh BODY."
  (drgnx-bootstrap-test--write (concat root "bin/" name)
                               (format "#!/bin/sh\nprintf '%%s\\n' \"%s $*\" >> '%sargv.log'\n%s\n" name root body)
                               #o755))

(defun drgnx-bootstrap-test--log (root) (drgnx-bootstrap-test--text (concat root "argv.log")))

(defun drgnx-bootstrap-test--fixture (root)
  "A bare repository ROOT/remote.git made from a fixture config (keys.eld, config.el); its path, the URL."
  (let ((src (concat root "fixture")))
    (drgnx-bootstrap-test--write (concat src "/keys.eld") "(:profile vscode)\n")
    (drgnx-bootstrap-test--write (concat src "/config.el") ";; my drgnx configuration\n")
    (drgnx-bootstrap-test--git src "init" "-q")
    (drgnx-bootstrap-test--git src "add" "-A")
    (drgnx-bootstrap-test--git src "commit" "-q" "-m" "config")
    (drgnx-bootstrap-test--git root "clone" "-q" "--bare" src "remote.git")
    (concat root "remote.git")))

(defvar drgnx-bootstrap-test--calls nil "Stubs called: (NAME . ARGS), newest first.")

(defmacro drgnx-bootstrap-test--with (spec &rest body)
  "BODY with SPEC (ROOT URL): ROOT a temp dir (home/, data/, state/, bin/ first on the path; config/ not made),
URL the fixture repository.  Sync, onboarding, the doctor and the import are stubs that record their calls in
`drgnx-bootstrap-test--calls'; the doctor is green (one `security' WARN); no keyring."
  (declare (indent 1))
  (pcase-let ((`(,root ,url) spec))
    `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-bootstrap" t)))
            (process-environment (append (list (concat "HOME=" ,root "home")
                                               "SHELL=/bin/bash"
                                               (concat "PATH=" ,root "bin:" (getenv "PATH"))
                                               (concat "DRGNX_CONFIG_DIR=" ,root "config")
                                               (concat "DRGNX_DATA_DIR=" ,root "data")
                                               (concat "XDG_STATE_HOME=" ,root "state")
                                               (concat "XDG_CONFIG_HOME=" ,root "home/.config")
                                               (concat "GIT_CONFIG_GLOBAL=" ,root "gitconfig")
                                               "GIT_CONFIG_NOSYSTEM=1" "DRGNX_STDIN_TTY" "DRGNX_BOOTSTRAP_HANDBACK"
                                               "GIT_AUTHOR_NAME=Test" "GIT_AUTHOR_EMAIL=test@example.invalid"
                                               "GIT_COMMITTER_NAME=Test" "GIT_COMMITTER_EMAIL=test@example.invalid")
                                         process-environment))
            (exec-path (cons (concat ,root "bin") exec-path))
            (abbreviated-home-dir nil)
            (drgnx-bootstrap-test--calls nil))
       (dolist (d '("home" "bin")) (make-directory (concat ,root d) t))
       (write-region "" nil (concat ,root "gitconfig") nil 'silent)
       (let ((,url (drgnx-bootstrap-test--fixture ,root)))
         (ignore ,url)
         (unwind-protect
             (cl-letf (((symbol-function 'drgnx-secrets-keyring-p) #'ignore)
                       ((symbol-function 'drgnx-pkg-sync)
                        (lambda (&rest a) (push (cons 'sync a) drgnx-bootstrap-test--calls) '(:ok t :installed nil :missing nil)))
                       ((symbol-function 'drgnx-onboard-run)
                        (lambda (&rest a) (push (cons 'onboard a) drgnx-bootstrap-test--calls) '((environment ok "recorded"))))
                       ((symbol-function 'drgnx-doctor-facts) (lambda () (push '(facts) drgnx-bootstrap-test--calls) nil))
                       ((symbol-function 'drgnx-doctor-run)
                        (lambda (&rest _) '((:name git :status ok :detail "git found")
                                            (:name security :status warn :detail "fixed in 31.2"))))
                       ((symbol-function 'drgnx-secrets-import)
                        (lambda (&rest a) (push (cons 'import a) drgnx-bootstrap-test--calls) '(:stored ("openrouter.ai")))))
               ,@body)
           (delete-directory ,root t))))))

(defun drgnx-bootstrap-test--run (&rest args)
  "`drgnx-bootstrap-run' with ARGS; returns (RESULTS . OUTPUT)."
  (let (results)
    (let ((out (with-output-to-string (setq results (apply #'drgnx-bootstrap-run args)))))
      (cons results out))))

(defun drgnx-bootstrap-test--row (results step) (assq step results))
(defun drgnx-bootstrap-test--status (results step) (nth 1 (assq step results)))
(defun drgnx-bootstrap-test--called (name) (seq-filter (lambda (c) (eq (car c) name)) drgnx-bootstrap-test--calls))

(defun drgnx-bootstrap-test--answers (answers &optional log)
  "An ASK function: ANSWERS an alist (REGEXP . ANSWER), ANSWER a value or a function giving it; a question none
matches fails the test.  LOG: a function called with each question and the output so far (when it goes to a buffer)."
  (lambda (q)
    (when log
      (funcall log q (if (bufferp standard-output) (with-current-buffer standard-output (buffer-string)) "")))
    (let ((a (seq-find (lambda (a) (string-match-p (car a) q)) answers)))
      (unless a (error "Unexpected question: %s" q))
      (if (functionp (cdr a)) (funcall (cdr a)) (cdr a)))))

;;;; config: clone, never overwrite

(ert-deftest drgnx-bootstrap/clones-into-an-empty-config-dir ()
  (drgnx-bootstrap-test--with (root url)
    (let* ((r (car (drgnx-bootstrap-test--run :config url)))
           (config (concat root "config")))
      (should (equal (drgnx-bootstrap-test--status r 'config) 'changed))
      (should (equal (drgnx-bootstrap-test--text (concat config "/keys.eld")) "(:profile vscode)\n"))
      (should (equal (drgnx-bootstrap-test--text (concat config "/config.el")) ";; my drgnx configuration\n"))
      (should (equal (drgnx-bootstrap-test--git config "config" "--get" "remote.origin.url") url))
      (should (equal (mapcar #'car r) drgnx-bootstrap-steps))
      (should-not (seq-some (lambda (x) (eq (nth 1 x) 'failed)) r))
      ;; nothing left beside it
      (should (equal (directory-files root nil "drgnx-clone") nil))))
  ;; an empty config dir counts as missing
  (drgnx-bootstrap-test--with (root url)
    (make-directory (concat root "config"))
    (let ((r (car (drgnx-bootstrap-test--run :config url :only '(config)))))
      (should (equal (drgnx-bootstrap-test--status r 'config) 'changed))
      (should (file-exists-p (concat root "config/keys.eld"))))))

(ert-deftest drgnx-bootstrap/existing-config-is-never-overwritten ()
  ;; another repository
  (drgnx-bootstrap-test--with (root url)
    (let ((config (concat root "config")))
      (drgnx-bootstrap-test--write (concat config "/mine.el") ";; mine\n")
      (drgnx-bootstrap-test--git config "init" "-q")
      (drgnx-bootstrap-test--git config "add" "-A")
      (drgnx-bootstrap-test--git config "commit" "-q" "-m" "mine")
      (let* ((head (drgnx-bootstrap-test--git config "rev-parse" "HEAD"))
             (r (car (drgnx-bootstrap-test--run :config url)))
             (row (drgnx-bootstrap-test--row r 'config)))
        (should (eq (nth 1 row) 'failed))
        (should (string-match-p "already holds a configuration" (nth 2 row)))
        (should (string-match-p "mv " (nth 2 row)))
        (should (equal (drgnx-bootstrap-test--git config "rev-parse" "HEAD") head))
        (should-not (file-exists-p (concat config "/keys.eld")))
        ;; the steps after config did not run
        (should-not (drgnx-bootstrap-test--called 'sync))
        (should-not (drgnx-bootstrap-test--called 'onboard))
        (should-not (drgnx-bootstrap-test--called 'facts))
        (dolist (s '(keys sync onboard desktop shell doctor))
          (should (eq (drgnx-bootstrap-test--status r s) 'skipped))))))
  ;; a plain dir with config.el
  (drgnx-bootstrap-test--with (root url)
    (let ((file (concat root "config/config.el")))
      (drgnx-bootstrap-test--write file ";; hand-made\n")
      (let ((r (car (drgnx-bootstrap-test--run :config url))))
        (should (eq (drgnx-bootstrap-test--status r 'config) 'failed))
        (should (string-match-p "config\\.el" (nth 2 (drgnx-bootstrap-test--row r 'config))))
        (should (equal (drgnx-bootstrap-test--text file) ";; hand-made\n"))
        (should-not (file-directory-p (concat root "config/.git")))
        (should-not (drgnx-bootstrap-test--called 'sync))))))

(ert-deftest drgnx-bootstrap/only-machine-local-items-count-as-empty ()
  (drgnx-bootstrap-test--with (root url)
    (drgnx-bootstrap-test--write (concat root "config/emacs") "/usr/bin/emacs\n")
    (let ((r (car (drgnx-bootstrap-test--run :config url))))
      (should (eq (drgnx-bootstrap-test--status r 'preflight) 'changed))
      (should (string-match-p "emacs" (nth 2 (drgnx-bootstrap-test--row r 'preflight))))
      (should (eq (drgnx-bootstrap-test--status r 'config) 'changed))
      (should (equal (drgnx-bootstrap-test--text (concat root "data/emacs")) "/usr/bin/emacs\n"))
      (should-not (file-exists-p (concat root "config/emacs")))
      (should (file-exists-p (concat root "config/keys.eld")))))
  ;; --step config alone moves them too (the doctor names it)
  (drgnx-bootstrap-test--with (root url)
    (drgnx-bootstrap-test--write (concat root "config/emacs") "/usr/bin/emacs\n")
    (let ((r (car (drgnx-bootstrap-test--run :config url :only '(config)))))
      (should (eq (drgnx-bootstrap-test--status r 'config) 'changed))
      (should (file-exists-p (concat root "data/emacs")))
      (should (file-exists-p (concat root "config/keys.eld"))))))

(ert-deftest drgnx-bootstrap/the-same-repo-is-ok ()
  (drgnx-bootstrap-test--with (root url)
    (drgnx-bootstrap-test--run :config url :only '(config))
    (let* ((r (car (drgnx-bootstrap-test--run :config url :only '(config))))
           (row (drgnx-bootstrap-test--row r 'config)))
      (should (eq (nth 1 row) 'ok))
      (should (string-match-p "git -C .* pull" (nth 2 row))))))

(ert-deftest drgnx-bootstrap/a-second-run-changes-nothing ()
  (drgnx-bootstrap-test--with (root url)
    (drgnx-bootstrap-test--write (concat root "config/emacs") "/usr/bin/emacs\n")
    (let ((first (car (drgnx-bootstrap-test--run :config url)))
          (second (car (drgnx-bootstrap-test--run :config url))))
      (should (memq 'changed (mapcar #'cadr first)))
      (should-not (memq 'changed (mapcar #'cadr second)))
      (should-not (memq 'failed (mapcar #'cadr second))))))

(ert-deftest drgnx-bootstrap/dry-run-changes-nothing ()
  (drgnx-bootstrap-test--with (root url)
    (drgnx-bootstrap-test--write (concat root "config/emacs") "/usr/bin/emacs\n")
    (let* ((snapshot (lambda ()
                       (mapcar (lambda (f) (cons f (file-attribute-modification-time (file-attributes f))))
                               (directory-files-recursively root "" t))))
           (before (funcall snapshot))
           (r (car (drgnx-bootstrap-test--run :config url :dry-run t :ask (lambda (q) (error "asked: %s" q))))))
      (should (equal (mapcar #'car r) drgnx-bootstrap-steps))
      (dolist (row r)
        (should (eq (nth 1 row) 'skipped))
        (should (string-prefix-p "would: " (nth 2 row))))
      (should (string-match-p "clone" (nth 2 (drgnx-bootstrap-test--row r 'config))))
      (should (string-match-p "emacs" (nth 2 (drgnx-bootstrap-test--row r 'preflight))))
      (should (equal (funcall snapshot) before))
      (should-not drgnx-bootstrap-test--calls))))

;;;; sync, doctor

(ert-deftest drgnx-bootstrap/a-missing-pin-fails ()
  (drgnx-bootstrap-test--with (root url)
    (cl-letf (((symbol-function 'drgnx-pkg-sync)
               (lambda (&rest _) '(:ok nil :installed nil :missing ((foo . "no archive serves foo 1.2"))))))
      (let* ((r (car (drgnx-bootstrap-test--run :config url)))
             (row (drgnx-bootstrap-test--row r 'sync)))
        (should (eq (nth 1 row) 'failed))
        (should (string-match-p "foo" (nth 2 row)))
        ;; onboarding and the rest depend on it
        (should-not (drgnx-bootstrap-test--called 'onboard))
        (should (eq (drgnx-bootstrap-test--status r 'doctor) 'skipped)))))
  (drgnx-bootstrap-test--with (root url)
    (cl-letf (((symbol-function 'drgnx-pkg-sync) (lambda (&rest _) '(:ok t :installed (eat magit) :missing nil))))
      (should (eq (drgnx-bootstrap-test--status (car (drgnx-bootstrap-test--run :only '(sync))) 'sync) 'changed)))))

(ert-deftest drgnx-bootstrap/the-doctor-fails-only-on-a-fail ()
  ;; a WARN is fine (Emacs 30.2 is supported, and warns): it is named; only a FAIL fails the step
  (drgnx-bootstrap-test--with (root _url)
    (should (eq (drgnx-bootstrap-test--status (car (drgnx-bootstrap-test--run :only '(doctor))) 'doctor) 'ok))
    (cl-letf (((symbol-function 'drgnx-doctor-run)
               (lambda (&rest _) '((:name security :status warn :detail "fixed in 31.2")
                                   (:name emacs-version :status warn :detail "Emacs 30.2 works, 31.1 is recommended")
                                   (:name ai :status info :detail "no provider")))))
      (let ((row (drgnx-bootstrap-test--row (car (drgnx-bootstrap-test--run :only '(doctor))) 'doctor)))
        (should (eq (nth 1 row) 'ok))
        (should (string-match-p "\\_<emacs-version\\_>" (nth 2 row)))
        (should (string-match-p "\\_<security\\_>" (nth 2 row)))))
    (cl-letf (((symbol-function 'drgnx-doctor-run)
               (lambda (&rest _) '((:name gui :status warn :detail "not a graphical build")
                                   (:name git :status fail :detail "git not found")))))
      (let ((row (drgnx-bootstrap-test--row (car (drgnx-bootstrap-test--run :only '(doctor))) 'doctor)))
        (should (eq (nth 1 row) 'failed))
        (should (string-match-p "\\_<git\\_>.*git not found" (nth 2 row)))
        (should-not (string-match-p "\\_<gui\\_>" (nth 2 row)))))))

;;;; Questions: --yes, desktop, shell, chezmoi, age

(ert-deftest drgnx-bootstrap/yes-never-writes-rc-or-desktop ()
  (drgnx-bootstrap-test--with (root url)
    (let ((r (car (drgnx-bootstrap-test--run :config url :yes t :ask (lambda (q) (error "asked: %s" q))))))
      (should (eq (drgnx-bootstrap-test--status r 'shell) 'skipped))
      (should (string-match-p "drgnx shell install" (nth 2 (drgnx-bootstrap-test--row r 'shell))))
      (should (eq (drgnx-bootstrap-test--status r 'desktop) 'skipped))
      ;; how to do it later: macOS has the app, Linux the service and desktop entry
      (should (string-match-p (if (eq (drgnx-platform) 'macos) "drgnx macos-app" "drgnx onboard --step daemon")
                              (nth 2 (drgnx-bootstrap-test--row r 'desktop))))
      (should-not (file-exists-p (concat root "home/.bashrc")))
      (should-not (file-exists-p (concat root "home/.config/systemd")))
      ;; onboarding ran once, non-interactive; never the daemon step on its own
      (should (equal (mapcar #'cdr (drgnx-bootstrap-test--called 'onboard)) '((:non-interactive t)))))))

(ert-deftest drgnx-bootstrap/chezmoi-shows-the-diff-first ()
  (cl-flet ((fake-chezmoi (root)
              (drgnx-bootstrap-test--fake
               root "chezmoi"
               (format "src='%shome/.local/share/chezmoi'
for a; do last=$a; done
case \" $* \" in
  *' source-path '*) echo \"$src\" ;;
  *' init '*) mkdir -p \"$src\" && git -C \"$src\" init -q && git -C \"$src\" remote add origin \"$last\" ;;
  *' diff '*) [ -e '%sapplied' ] || echo '+export EDITOR=drgnx' ;;
  *' apply '*) if [ -n \"${FAKE_APPLY_FAILS-}\" ]; then echo '+a line of a dotfile'; echo 'chezmoi: .netrc: permission denied' >&2; echo '+another line'; exit 1; fi
              : > '%sapplied' ;;
esac" root root root))))
    ;; two yeses: init, then apply after the diff was shown
    (drgnx-bootstrap-test--with (root url)
      (fake-chezmoi root)
      (let* ((asked nil)
             (out (with-output-to-string
                    (let ((r (drgnx-bootstrap-run :chezmoi url :only '(config)
                                                  :ask (drgnx-bootstrap-test--answers
                                                        '(("chezmoi init" . t) ("chezmoi apply" . t))
                                                        (lambda (q o) (setq asked (append asked (list (cons q o)))))))))
                      (should (eq (drgnx-bootstrap-test--status r 'config) 'changed)))))
             (log (split-string (drgnx-bootstrap-test--log root) "\n" t)))
        (should (= 2 (length asked)))
        ;; the diff was on the screen before the apply question
        (should (string-match-p "export EDITOR=drgnx" (cdr (nth 1 asked))))
        (should-not (string-match-p "export EDITOR=drgnx" (cdr (nth 0 asked))))
        (should (string-match-p "export EDITOR=drgnx" out))
        (let ((init (seq-position log url (lambda (l u) (and (string-match-p " init " l) (string-suffix-p (concat " -- " u) l)))))
              (diff (seq-position log "diff" (lambda (l _) (string-match-p " diff\\'" l))))
              (apply (seq-position log "apply" (lambda (l _) (string-match-p " apply\\'" l)))))
          (should (and init diff apply (< init diff apply))))))
    ;; a no to apply: nothing applied
    (drgnx-bootstrap-test--with (root url)
      (fake-chezmoi root)
      (let ((r (car (drgnx-bootstrap-test--run :chezmoi url :only '(config)
                                               :ask (drgnx-bootstrap-test--answers '(("chezmoi init" . t) ("chezmoi apply" . nil)))))))
        (should (eq (drgnx-bootstrap-test--status r 'config) 'skipped))
        (should (string-match-p "chezmoi apply" (nth 2 (drgnx-bootstrap-test--row r 'config))))
        (should-not (string-match-p " apply" (drgnx-bootstrap-test--log root)))))
    ;; --yes: init and diff, never apply; the diff is not printed (no question follows it: the output may be a log)
    (drgnx-bootstrap-test--with (root url)
      (fake-chezmoi root)
      (let* ((run (drgnx-bootstrap-test--run :chezmoi url :only '(config) :yes t))
             (row (drgnx-bootstrap-test--row (car run) 'config)))
        (should (string-match-p " init " (drgnx-bootstrap-test--log root)))
        (should (string-match-p " diff" (drgnx-bootstrap-test--log root)))
        (should-not (string-match-p " apply" (drgnx-bootstrap-test--log root)))
        (should (eq (nth 1 row) 'skipped))
        (should (string-match-p "chezmoi diff.*chezmoi apply" (nth 2 row)))
        (should-not (string-match-p "export EDITOR" (cdr run)))
        (should-not (string-match-p "export EDITOR" (nth 2 row)))
        ;; again with no terminal (nothing can be asked): not printed either
        (let ((again (drgnx-bootstrap-test--run :chezmoi url :only '(config))))
          (should (eq (drgnx-bootstrap-test--status (car again) 'config) 'skipped))
          (should-not (string-match-p "export EDITOR" (cdr again))))))
    ;; a failed apply: chezmoi's error, never a line of the files
    (drgnx-bootstrap-test--with (root url)
      (fake-chezmoi root)
      (let* ((process-environment (cons "FAKE_APPLY_FAILS=1" process-environment))
             (row (drgnx-bootstrap-test--row
                   (car (drgnx-bootstrap-test--run :chezmoi url :only '(config)
                                                   :ask (drgnx-bootstrap-test--answers '(("chezmoi init" . t) ("chezmoi apply" . t)))))
                   'config)))
        (should (eq (nth 1 row) 'failed))
        (should (string-match-p "chezmoi: \\.netrc: permission denied" (nth 2 row)))
        (should-not (string-match-p "a line of a dotfile\\|another line" (nth 2 row)))))))

(defun drgnx-bootstrap-test--age-setup (root)
  "secrets.age in the config dir, an identity file, a fake sudo and dnf (dnf install puts a fake age in bin/);
age is not on the path.  Returns the identity file."
  (drgnx-bootstrap-test--write (concat root "config/secrets.age") "ciphertext\n")
  (drgnx-bootstrap-test--fake root "sudo" "exec \"$@\"")
  (drgnx-bootstrap-test--fake root "dnf" (format "printf '#!/bin/sh\\nexit 0\\n' > '%sbin/age'; /bin/chmod 755 '%sbin/age'" root root))
  (let ((id (concat root "identity.txt")))
    (drgnx-bootstrap-test--write id "not a real identity\n" #o600)
    id))

(ert-deftest drgnx-bootstrap/age-install-is-announced-and-confirmed ()
  (drgnx-bootstrap-test--with (root _url)
    (let ((id (drgnx-bootstrap-test--age-setup root))
          (exec-path (list (concat root "bin")))       ; no age of this machine's
          (asked nil) r)
      (cl-letf (((symbol-function 'drgnx-secrets-keyring-p) (lambda () t))
                ((symbol-function 'drgnx-platform) (lambda () 'linux)))
        (let ((out (with-output-to-string
                     (setq r (drgnx-bootstrap-run :only '(keys) :identity id
                                                  :ask (drgnx-bootstrap-test--answers
                                                        `(("Import" . t)
                                                          ("Install age" . ,(lambda () (should (equal (drgnx-bootstrap-test--log root) "")) t)))
                                                        (lambda (q o) (setq asked (append asked (list (cons q o)))))))))))
          (ignore out)
          ;; the line was printed before the question, and sudo ran only after the yes
          (should (string-match-p "As root: sudo dnf install -y age" (cdr (nth 1 asked))))
          (should (equal (drgnx-bootstrap-test--log root) "sudo dnf install -y age\ndnf install -y age\n"))
          (should (eq (drgnx-bootstrap-test--status r 'keys) 'changed))
          (should (equal (cdr (car (drgnx-bootstrap-test--called 'import))) (list :identity id :replace nil)))))))
  ;; a no: keys failed, sudo never ran
  (drgnx-bootstrap-test--with (root _url)
    (let ((id (drgnx-bootstrap-test--age-setup root))
          (exec-path (list (concat root "bin"))))
      (cl-letf (((symbol-function 'drgnx-secrets-keyring-p) (lambda () t))
                ((symbol-function 'drgnx-platform) (lambda () 'linux)))
        (let* ((r (car (drgnx-bootstrap-test--run :only '(keys) :identity id
                                                  :ask (drgnx-bootstrap-test--answers '(("Import" . t) ("Install age" . nil))))))
               (row (drgnx-bootstrap-test--row r 'keys)))
          (should (eq (nth 1 row) 'failed))
          (should (string-match-p "age is needed" (nth 2 row)))
          (should (string-match-p "sudo dnf install -y age" (nth 2 row)))
          (should (equal (drgnx-bootstrap-test--log root) ""))
          (should-not (drgnx-bootstrap-test--called 'import))))))
  ;; --yes confirms the install, but never --replace
  (drgnx-bootstrap-test--with (root _url)
    (let ((id (drgnx-bootstrap-test--age-setup root))
          (exec-path (list (concat root "bin"))))
      (cl-letf (((symbol-function 'drgnx-secrets-keyring-p) (lambda () t))
                ((symbol-function 'drgnx-platform) (lambda () 'linux)))
        (let ((r (car (drgnx-bootstrap-test--run :only '(keys) :identity id :yes t))))
          (should (eq (drgnx-bootstrap-test--status r 'keys) 'changed))
          (should (string-match-p "sudo dnf install -y age" (drgnx-bootstrap-test--log root)))
          (should (equal (cdr (car (drgnx-bootstrap-test--called 'import))) (list :identity id :replace nil))))))))

(ert-deftest drgnx-bootstrap/keys-without-a-keyring-skip ()
  (drgnx-bootstrap-test--with (root _url)
    (drgnx-bootstrap-test--write (concat root "config/secrets.age") "ciphertext\n")
    (let* ((r (car (drgnx-bootstrap-test--run :only '(keys) :yes t)))
           (row (drgnx-bootstrap-test--row r 'keys)))
      (should (eq (nth 1 row) 'skipped))
      (should (string-match-p "no keyring" (nth 2 row)))
      (should-not (drgnx-bootstrap-test--called 'import))))
  ;; no secrets.age: nothing to do
  (drgnx-bootstrap-test--with (root _url)
    (should (eq (drgnx-bootstrap-test--status (car (drgnx-bootstrap-test--run :only '(keys) :yes t)) 'keys) 'ok))))

(ert-deftest drgnx-bootstrap/key-import-results ()
  (drgnx-bootstrap-test--with (root _url)
    (let ((id (drgnx-bootstrap-test--age-setup root)))
      (drgnx-bootstrap-test--write (concat root "bin/age") "#!/bin/sh\nexit 0\n" #o755)
      (cl-letf (((symbol-function 'drgnx-secrets-keyring-p) (lambda () t)))
        (dolist (c `(((:same ("openrouter.ai")) ok nil)
                     ((:stored ("openrouter.ai") :same ("x.ai")) changed "openrouter\\.ai")
                     ((:differs ("openrouter.ai")) failed "--replace")
                     ((:failed (("openrouter.ai" . "the keyring refused it"))) failed "refused")))
          (cl-letf (((symbol-function 'drgnx-secrets-import) (lambda (&rest _) (car c))))
            (let ((row (drgnx-bootstrap-test--row (car (drgnx-bootstrap-test--run :only '(keys) :identity id :yes t)) 'keys)))
              (should (equal (list (car c) (nth 1 row)) (list (car c) (nth 1 c))))
              (when (nth 2 c) (should (string-match-p (nth 2 c) (nth 2 row)))))))
        ;; --replace only when asked
        (drgnx-bootstrap-test--run :only '(keys) :identity id :yes t :replace t)
        (should (equal (cdr (car (drgnx-bootstrap-test--called 'import))) (list :identity id :replace t)))
        ;; no terminal and no identity: the command, nothing run
        (setq drgnx-bootstrap-test--calls nil)
        (let ((row (drgnx-bootstrap-test--row (car (drgnx-bootstrap-test--run :only '(keys) :yes t)) 'keys)))
          (should (eq (nth 1 row) 'skipped))
          (should (string-match-p "drgnx secrets import" (nth 2 row)))
          (should-not drgnx-bootstrap-test--calls))))))

(ert-deftest drgnx-bootstrap/one-step-runs-alone ()
  (drgnx-bootstrap-test--with (root _url)
    (let ((r (car (drgnx-bootstrap-test--run :only '(shell) :ask (drgnx-bootstrap-test--answers '(("\\.bashrc" . t)))))))
      (should (equal (mapcar #'car r) '(shell)))
      (should (eq (drgnx-bootstrap-test--status r 'shell) 'changed))
      (should (string-match-p "etc/shell/drgnx\\.bash" (drgnx-bootstrap-test--text (concat root "home/.bashrc"))))
      (should-not drgnx-bootstrap-test--calls)
      ;; again: the line is there
      (should (eq (drgnx-bootstrap-test--status (car (drgnx-bootstrap-test--run :only '(shell) :ask #'ignore)) 'shell) 'ok)))))

;;;; Fail closed

(ert-deftest drgnx-bootstrap/a-hung-clone-fails-and-changes-nothing ()
  (drgnx-bootstrap-test--with (root url)
    (drgnx-bootstrap-test--fake root "git" "for a; do last=$a; done; mkdir -p \"$last\"; exec /bin/sleep 30")
    (let* ((drgnx-bootstrap-call-timeout 0.5)
           (start (float-time))
           (r (car (drgnx-bootstrap-test--run :config url :only '(config))))
           (row (drgnx-bootstrap-test--row r 'config)))
      (should (< (- (float-time) start) 10))
      (should (eq (nth 1 row) 'failed))
      (should (string-match-p "did not finish" (nth 2 row)))
      (should-not (file-exists-p (concat root "config")))
      (should (equal (directory-files root nil "drgnx-clone") nil)))))

(ert-deftest drgnx-bootstrap/git-runs-without-the-users-hooks ()
  (drgnx-bootstrap-test--with (root url)
    (let ((hooks (concat root "hooks/")) (marker (concat root "hook-ran")))
      (dolist (h '("post-checkout" "post-merge" "reference-transaction"))
        (drgnx-bootstrap-test--write (concat hooks h) (format "#!/bin/sh\ntouch '%s'\n" marker) #o755))
      (drgnx-bootstrap-test--write (concat root "gitconfig") (format "[core]\n\thooksPath = %s\n[init]\n\ttemplateDir = %s\n" hooks root))
      (let ((r (car (drgnx-bootstrap-test--run :config url :only '(config)))))
        (should (eq (drgnx-bootstrap-test--status r 'config) 'changed))
        (should-not (file-exists-p marker))))))

(ert-deftest drgnx-bootstrap/a-url-with-a-query-is-refused ()
  ;; git would keep a query (a token, say) in .git/logs ("clone: from …?token=…"): refused before anything runs
  (let ((secret (concat "tok" (make-string 12 ?q))))
    (drgnx-bootstrap-test--with (root _url)
      (drgnx-bootstrap-test--fake root "git" "exit 0")
      (drgnx-bootstrap-test--fake root "chezmoi" "exit 0")
      (dolist (https (list (format "https://example.invalid/ana/config.git?token=%s" secret)
                           (format "https://example.invalid/ana/config.git#%s" secret)
                           "https://example.invalid/ana/config.git?"))
        (dolist (opt '("--config" "--chezmoi"))
          ;; the command line: a usage error that says what to do, the value never shown
          (let ((r (drgnx-bootstrap-test--cli opt https)))
            (should (equal (list opt https (car r)) (list opt https 2)))
            (should (string-match-p "credential helper" (cdr r)))
            (should (string-match-p "query" (cdr r)))
            (should-not (string-search secret (cdr r)))))
        ;; called from Lisp: config fails, nothing ran
        (dolist (key '(:config :chezmoi))
          (let ((row (drgnx-bootstrap-test--row (car (drgnx-bootstrap-test--run key https :only '(config))) 'config)))
            (should (eq (nth 1 row) 'failed))
            (should (string-match-p "credential helper" (nth 2 row)))
            (should-not (string-search secret (nth 2 row))))))
      (should (equal (drgnx-bootstrap-test--log root) ""))
      (should-not (file-exists-p (concat root "config"))))))

(ert-deftest drgnx-bootstrap/a-failed-clone-leaves-nothing ()
  (drgnx-bootstrap-test--with (root _url)
    (make-directory (concat root "not-a-repo"))   ; a path that exists, but git cannot clone it
    (let* ((r (car (drgnx-bootstrap-test--run :config (concat root "not-a-repo") :only '(config))))
           (row (drgnx-bootstrap-test--row r 'config)))
      (should (eq (nth 1 row) 'failed))
      (should (string-match-p "git clone failed: .*; nothing was changed" (nth 2 row)))
      (should-not (file-exists-p (concat root "config")))
      (should (equal (directory-files root nil "drgnx-clone") nil)))))

;;;; The command line

(defun drgnx-bootstrap-test--cli (&rest args)
  "`drgnx-bootstrap-cli-run' with ARGS: (EXIT . OUTPUT)."
  (let (code)
    (let ((out (with-output-to-string (setq code (drgnx-bootstrap-cli-run args)))))
      (cons code out))))

(ert-deftest drgnx-bootstrap/inputs-are-checked-again ()
  (drgnx-bootstrap-test--with (root url)
    (let ((pw (concat "pw" (make-string 12 ?z))))
      (dolist (bad (list "http://example.org/c.git" "ssh://example.org/c.git" "git@example.org:c.git"
                         "ext::sh -c touch% /tmp/pwned" "file:///tmp/c" (format "https://ana:%s@example.org/c.git" pw)
                         (format "https://%s@example.org/c.git" pw) "https://example.org/c\n.git" "https://example.org/c\r"
                         "https://exa mple.org/c" "https:///c.git" "-uhttps://example.org" "relative/path" "" "--upload-pack=x"
                         (concat "/tmp/a" (string 0) "b") "HTTPS://example.org/c.git"))
        (dolist (opt '("--config" "--chezmoi"))
          (let ((r (drgnx-bootstrap-test--cli opt bad "--dry-run")))
            (should (equal (list opt bad (car r)) (list opt bad 2)))
            (should-not (string-search pw (cdr r)))
            (unless (string-empty-p bad) (should-not (string-search bad (cdr r))))))))
    ;; good ones pass
    (should (equal (car (drgnx-bootstrap-test--cli "--config" url "--dry-run")) 0))
    (should (equal (car (drgnx-bootstrap-test--cli "--config" "https://example.org/ana/drgnx-config.git" "--dry-run")) 0))
    ;; the identity: a private regular file
    (let ((id (concat root "identity.txt")))
      (drgnx-bootstrap-test--write id "secret identity text\n" #o644)
      (let ((r (drgnx-bootstrap-test--cli "--identity" id "--dry-run")))
        (should (equal (car r) 2))
        (should (string-match-p "chmod 600" (cdr r)))
        (should-not (string-search "secret identity text" (cdr r))))
      (set-file-modes id #o600)
      (should (equal (car (drgnx-bootstrap-test--cli "--identity" id "--dry-run")) 0))
      (should (equal (car (drgnx-bootstrap-test--cli "--identity" (concat root "none.txt") "--dry-run")) 2))
      (should (equal (car (drgnx-bootstrap-test--cli "--identity" root "--dry-run")) 2)))
    ;; usage
    (dolist (args '(("--config" "https://example.org/a" "--chezmoi" "https://example.org/b") ("--step" "nope")
                    ("--config") ("--frobnicate") ("extra")))
      (should (equal (cons args (car (apply #'drgnx-bootstrap-test--cli args))) (cons args 2))))))

(ert-deftest drgnx-bootstrap/cli-prints-a-row-per-step ()
  (drgnx-bootstrap-test--with (root url)
    (let ((r (drgnx-bootstrap-test--cli "--config" url "--step" "shell" "--step" "config")))
      (should (equal (car r) 0))
      (should (string-match-p "^config   changed    cloned " (cdr r)))
      (should (string-match-p "^shell    skipped    " (cdr r)))
      (should-not (string-match-p "^doctor" (cdr r))))
    (cl-letf (((symbol-function 'drgnx-doctor-run) (lambda (&rest _) '((:name gui :status warn :detail "no GUI")))))
      (should (equal (car (drgnx-bootstrap-test--cli "--step" "doctor")) 0)))
    (cl-letf (((symbol-function 'drgnx-doctor-run) (lambda (&rest _) '((:name git :status fail :detail "no git")))))
      (should (equal (car (drgnx-bootstrap-test--cli "--step" "doctor")) 1)))))

(ert-deftest drgnx-bootstrap/a-program-that-exits-at-once ()
  ;; its stdin is closed after it has gone: never an error (a lost race made a fast git call fail the step)
  (dotimes (_ 50)
    (should (equal (drgnx-bootstrap--call "true" nil) '(0 . ""))))
  (should (equal (drgnx-bootstrap--call "sh" '("-c" "exit 3")) '(3 . "")))
  ;; the race made certain: the program has exited (and Emacs knows) before its stdin is closed
  (let ((orig (symbol-function 'make-process)))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (let ((p (apply orig args))) (sleep-for 0.3) p))))
      (should (equal (drgnx-bootstrap--call "true" nil) '(0 . "")))
      (should (equal (drgnx-bootstrap--call "sh" '("-c" "echo out; exit 4")) '(4 . "out"))))))

(ert-deftest drgnx-bootstrap/the-terminal-is-handed-back-and-the-run-goes-on ()
  ;; On a terminal, sudo (and age's passphrase) must run in bin/drgnx: a program Emacs starts has no terminal.
  ;; The run stops with exit 10 and the command in DIR/argv; bin/drgnx runs it, writes DIR/rc, runs us again.
  (drgnx-bootstrap-test--with (root _url)
    (let* ((id (drgnx-bootstrap-test--age-setup root))
           (dir (concat root "handback/"))
           (exec-path (list (concat root "bin")))
           (asked nil)
           (process-environment (append (list (concat "DRGNX_BOOTSTRAP_HANDBACK=" dir) "DRGNX_STDIN_TTY=1") process-environment)))
      (make-directory dir)
      (cl-letf (((symbol-function 'drgnx-secrets-keyring-p) (lambda () t))
                ((symbol-function 'drgnx-platform) (lambda () 'linux))
                ((symbol-function 'y-or-n-p) (lambda (q) (push q asked) t)))
        (let ((first (drgnx-bootstrap-test--cli "--step" "keys" "--identity" id)))
          (should (equal (car first) 10))
          (should (equal (drgnx-bootstrap-test--text (concat dir "argv")) "sudo\ndnf\ninstall\n-y\nage\n"))
          (should (equal (drgnx-bootstrap-test--log root) ""))   ; nothing ran here
          (should (= 2 (length asked)))
          ;; what bin/drgnx does
          (call-process (concat root "bin/sudo") nil nil nil "dnf" "install" "-y" "age")
          (drgnx-bootstrap-test--write (concat dir "rc") "0\n")
          (let ((second (drgnx-bootstrap-test--cli "--step" "keys" "--identity" id)))
            (should (equal (car second) 0))
            (should (string-match-p "^keys     changed " (cdr second)))
            (should (= 2 (length asked)))   ; the answers were kept: nothing asked again
            (should (equal (directory-files dir nil "\\`[^.]") nil))))))))

(ert-deftest drgnx-bootstrap/passphrase-import-is-handed-back ()
  (drgnx-bootstrap-test--with (root _url)
    (drgnx-bootstrap-test--write (concat root "config/secrets.age") "ciphertext\n")
    (drgnx-bootstrap-test--write (concat root "bin/age") "#!/bin/sh\nexit 0\n" #o755)
    (let* ((dir (concat root "handback/"))
           (process-environment (append (list (concat "DRGNX_BOOTSTRAP_HANDBACK=" dir) "DRGNX_STDIN_TTY=1") process-environment)))
      (make-directory dir)
      (cl-letf (((symbol-function 'drgnx-secrets-keyring-p) (lambda () t))
                ((symbol-function 'y-or-n-p) (lambda (_) t)))
        (should (equal (car (drgnx-bootstrap-test--cli "--step" "keys" "--replace")) 10))
        (should (equal (drgnx-bootstrap-test--text (concat dir "argv")) "secrets\nimport\n--replace\n"))
        (should-not (drgnx-bootstrap-test--called 'import))   ; never in this Emacs: age needs the terminal
        (drgnx-bootstrap-test--write (concat dir "rc") "0\n")
        (drgnx-bootstrap-test--write (concat dir "out") "stored   openrouter.ai\nsame     x.ai\n")
        (let ((r (drgnx-bootstrap-test--cli "--step" "keys" "--replace")))
          (should (equal (car r) 0))
          (should (string-match-p "^keys     changed .*openrouter\\.ai" (cdr r))))
        ;; all the same: ok; a failure: failed with the lines
        (pcase-dolist (`(,rc ,out ,status) '((0 "same     openrouter.ai\n" "ok")
                                             (1 "differs  openrouter.ai  (your keyring's key is kept)\n" "failed")))
          (should (equal (car (drgnx-bootstrap-test--cli "--step" "keys")) 10))
          (drgnx-bootstrap-test--write (concat dir "rc") (format "%d\n" rc))
          (drgnx-bootstrap-test--write (concat dir "out") out)
          (let ((r (drgnx-bootstrap-test--cli "--step" "keys")))
            (should (string-match-p (format "^keys     %s " status) (cdr r)))
            (should (equal (car r) (if (equal status "failed") 1 0)))))))))

(ert-deftest drgnx-bootstrap/bin-drgnx-runs-what-is-handed-back ()
  ;; bin/drgnx's half, with a fake Emacs: the first run hands back a command, the second reports what it got
  (drgnx-bootstrap-test--with (root _url)
    (drgnx-bootstrap-test--fake root "sudo" "echo sudo-ran")
    (let* ((emacs (concat root "fake-emacs"))
           (run (lambda (handback)
                  (drgnx-bootstrap-test--write
                   emacs
                   (format "#!/bin/bash
d=$DRGNX_BOOTSTRAP_HANDBACK
echo \"args: ${*: -2}\" >> '%semacs.log'
if [ -f \"$d/rc\" ]; then echo \"rc=$(cat \"$d/rc\") tty=$DRGNX_STDIN_TTY\" >> '%semacs.log'; rm -f \"$d\"/*; exit 0; fi
printf '%%s\\n' %s > \"$d/argv\"; exit 10
" root root handback)
                   #o755)
                  (with-temp-buffer
                    (let ((process-environment (append (list (concat "DRGNX_EMACS=" emacs)) process-environment)))
                      (cons (call-process (expand-file-name "bin/drgnx" drgnx-dir) nil t nil "bootstrap" "--step" "keys")
                            (buffer-string)))))))
      ;; a sudo line of the recipes: run, its exit code handed on, the directory removed
      (let ((r (funcall run "sudo dnf install -y age")))
        (should (equal (car r) 0))
        (should (string-match-p "sudo-ran" (cdr r)))
        (should (equal (drgnx-bootstrap-test--log root) "sudo dnf install -y age\n"))
        (should (string-match-p "args: --step keys\nrc=0 tty=\n" (drgnx-bootstrap-test--text (concat root "emacs.log")))))
      (should (equal (directory-files (or (getenv "TMPDIR") temporary-file-directory) nil "drgnx-bootstrap\\.") nil))
      ;; anything else is refused, and nothing runs
      (dolist (bad '("sudo rm -rf /x" "sh -c id" "secrets export" "secrets import --identity /x" "sudo"))
        (ignore-errors (delete-file (concat root "argv.log")))
        (let ((r (funcall run bad)))
          (should (equal (cons bad (car r)) (cons bad 1)))
          (should (equal (drgnx-bootstrap-test--log root) "")))))))

(ert-deftest drgnx-bootstrap/bin-drgnx-knows-every-root-line-of-the-recipes ()
  ;; bin/drgnx runs only the sudo lines it lists: each age/chezmoi recipe's sudo line must be there
  (let ((bin (with-temp-buffer (insert-file-contents (expand-file-name "bin/drgnx" drgnx-dir)) (buffer-string)))
        (lines 0))
    (dolist (tool '(age chezmoi))
      (pcase-dolist (`(,_pm . ,line) (plist-get (plist-get (alist-get tool drgnx-onboard-install-recipes) :linux) :by-program))
        (when (string-prefix-p "sudo " line)
          (cl-incf lines)
          (should (string-search (format "\"%s\"" line) bin)))))
    (should (>= lines 4))))

(ert-deftest drgnx-bootstrap/usage-descriptions-line-up ()
  ;; every description in bin/drgnx's usage starts in the same column (the bootstrap entry moved one once)
  (with-temp-buffer
    (insert-file-contents (expand-file-name "bin/drgnx" drgnx-dir))
    (goto-char (point-min))
    (re-search-forward "^usage() {$")
    (let ((end (save-excursion (re-search-forward "^USAGE$")))
          (bad nil) (seen 0))
      (while (re-search-forward "^       drgnx [^ \n][^\n]*?[^ \n]  +\\([^ \n]\\)" end t)
        (cl-incf seen)
        (goto-char (match-beginning 1))
        (unless (= (current-column) 31) (push (buffer-substring (line-beginning-position) (line-end-position)) bad))
        (forward-line 1))
      (should (>= seen 10))
      (should (equal bad nil)))))

;;; bootstrap-test.el ends here
