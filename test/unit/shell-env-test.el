;;; shell-env-test.el --- batch tests: the login shell's environment in the daemon -*- lexical-binding: t -*-
;; Fake shells are scripts in a temp dir (the runner's HOME is a temp dir too); the one real shell (zsh) runs with a
;; temp HOME and ZDOTDIR.  Never the user's rc files, keyring or live Emacs.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-shell-env)
(require 'drgnx-hub)
(load (expand-file-name "test/fixtures/scripted-process" drgnx-dir) nil t)

(defmacro drgnx-shell-env-test--with (&rest body)
  "BODY in a temp dir DIR, as an interactive Emacs (`noninteractive' nil), with this Emacs's environment and
`exec-path' copies (`setenv' changes the list in place), PATH = DIR/oldbin:/usr/bin:/bin, the switch off, and
MESSAGES the messages said."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-shell-env" t)))
          (messages nil)
          (noninteractive nil)
          (exec-path (copy-sequence exec-path))
          (process-environment (append (list (concat "PATH=" dir "oldbin:/usr/bin:/bin") "DRGNX_NO_SHELL_ENV"
                                             "MANPATH" "INFOPATH" "FOO" "OPENROUTER_API_KEY" "ANTHROPIC_API_KEY"
                                             "GITHUB_TOKEN" "OPENAI_API_KEY")
                                       (copy-sequence process-environment)))
          (drgnx-shell-env-extra-names nil)
          (drgnx-shell-env-timeout 5))
     (cl-letf (((symbol-function 'message)
                (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages)))))
       (unwind-protect (progn ,@body)
         (delete-directory dir t)))))

(defun drgnx-shell-env-test--fake (dir body)
  "A fake shell in DIR running BODY (sh), made the user's SHELL.  Its path."
  (let ((file (expand-file-name "fakeshell" dir)))
    (with-temp-file file (insert "#!/bin/sh\n" body "\n"))
    (set-file-modes file #o700)
    (setenv "SHELL" file)
    file))

(defun drgnx-shell-env-test--env-shell (dir before vars &optional after)
  "A fake shell in DIR: BEFORE (sh), then drgnx's script (its last argument) run by sh with only VARS (\"N=V\"…) in
its environment, then AFTER."
  (drgnx-shell-env-test--fake
   dir (concat (or before "") "\n"
               "for a; do script=$a; done\n"
               "env -i " (mapconcat #'shell-quote-argument vars " ") " /bin/sh -c \"$script\"\n"
               (or after ""))))

(defun drgnx-shell-env-test--run (&optional callback)
  "Start reading the shell's environment, wait (5 s at most) until it is done: (PROCESS . CHANGED)."
  (let* ((done nil) (changed nil)
         (proc (drgnx-shell-env-start (lambda (c) (setq done t changed c) (when callback (funcall callback c)))))
         (deadline (+ (float-time) 5)))
    (should (processp proc))
    (while (and (or (process-live-p proc) (not done)) (< (float-time) deadline)
                (not (and (not (process-live-p proc)) (seq-find #'drgnx-shell-env-test--failure-p messages))))
      (accept-process-output nil 0.05))
    (cons proc changed)))

(defun drgnx-shell-env-test--failure-p (m)
  (string-prefix-p "drgnx: your login shell's environment was not read" m))

(ert-deftest drgnx-shell-env/only-the-allowlist-is-taken ()
  (drgnx-shell-env-test--with
    (let ((key (concat "not-a-" "real-key")))
      (drgnx-shell-env-test--env-shell dir "echo hi"
                                       (list (concat "PATH=" dir "shellbin:/usr/bin") "MANPATH=/fake/man" "FOO=bar"
                                             (concat "OPENROUTER_API_KEY=" key) (concat "ANTHROPIC_API_KEY=" key)
                                             (concat "GITHUB_TOKEN=" key)))
      (let ((changed (cdr (drgnx-shell-env-test--run))))
        (should (equal (sort (copy-sequence changed) #'string<) '("MANPATH" "PATH")))
        (should (equal (getenv "MANPATH") "/fake/man"))
        (should-not (getenv "FOO"))
        (should-not (getenv "OPENROUTER_API_KEY")))
      ;; more names: FOO is taken, a key never, also when listed
      (let ((drgnx-shell-env-extra-names '("FOO" "ANTHROPIC_API_KEY" "GITHUB_TOKEN")))
        (drgnx-shell-env-test--run)
        (should (equal (getenv "FOO") "bar"))
        (should-not (getenv "ANTHROPIC_API_KEY"))
        (should-not (getenv "GITHUB_TOKEN")))
      (should-not (seq-find (lambda (m) (string-search key m)) messages))
      ;; any provider's key variable is refused, whatever its name
      (cl-letf (((symbol-function 'drgnx-ai-providers) (lambda () '((zeta :name "Z" :key-env "ZETA_AUTH")))))
        (should (drgnx-shell-env-refused-p "ZETA_AUTH"))
        (should (drgnx-shell-env-refused-p "my_db_password"))
        (should (drgnx-shell-env-refused-p "AWS_CREDENTIALS"))
        (should-not (drgnx-shell-env-refused-p "PATH"))
        (should-not (drgnx-shell-env-parse "\036drgnx-env-begin\nZETA_AUTH=x\n\036drgnx-env-end\n" '("ZETA_AUTH")))))))

(ert-deftest drgnx-shell-env/noise-before-and-after-the-markers ()
  (let ((out (concat "\e[?1h\e=\e]0;p10k\a" "hi\n" "PATH=/evil\n"
                     "\036drgnx-env-begin\nPATH=/old\n\036drgnx-env-end\n"   ; an earlier block: only the last counts
                     "PATH=/evil2\n" "\e[1m%\e[0m \036drgnx-env-begin\n" "HOME=/h\nPATH=/good:/bin\nMANPATH=/m\n"
                     "\036drgnx-env-end\n" "PATH=/evil3\n" "\e[32m❯\e[0m ")))
    (should (equal (drgnx-shell-env-parse out '("PATH" "MANPATH")) '(("PATH" . "/good:/bin") ("MANPATH" . "/m"))))
    (should-not (drgnx-shell-env-parse "PATH=/x\n" '("PATH")))
    (should-not (drgnx-shell-env-parse "\036drgnx-env-begin\nPATH=/x\n" '("PATH"))))   ; no end: nothing
  ;; and through a process: noise on both sides
  (drgnx-shell-env-test--with
    (drgnx-shell-env-test--env-shell dir "printf '\\033[?1h\\033=hi\\nPATH=/evil\\n'"
                                     (list (concat "PATH=" dir "shellbin:/usr/bin"))
                                     "printf 'PATH=/evil2\\n\\033[32m> '")
    (drgnx-shell-env-test--run)
    (should (string-prefix-p (concat dir "shellbin:/usr/bin:") (getenv "PATH")))
    (should-not (string-search "evil" (getenv "PATH")))))

(ert-deftest drgnx-shell-env/a-slow-shell-times-out-quietly ()
  :tags '(:timing)
  (drgnx-shell-env-test--with
    (drgnx-shell-env-test--fake dir "sleep 30")
    (let* ((drgnx-shell-env-timeout 0.3)
           (before (getenv "PATH"))
           (called nil)
           (t0 (float-time))
           (proc (drgnx-shell-env-start (lambda (_) (setq called t)))))
      (should (processp proc))
      (while (and (process-live-p proc) (< (float-time) (+ t0 3))) (accept-process-output nil 0.05))
      (accept-process-output nil 0.1)
      (should-not (process-live-p proc))
      (should (< (- (float-time) t0) 1))
      (should (equal (getenv "PATH") before))
      (should-not called)
      (should (= 1 (length (seq-filter #'drgnx-shell-env-test--failure-p messages)))))))

(ert-deftest drgnx-shell-env/a-shell-that-reads-input-gets-eof ()
  (drgnx-shell-env-test--with
    (drgnx-shell-env-test--env-shell dir "read x" (list "PATH=/usr/bin" "MANPATH=/read/man"))
    (let ((r (drgnx-shell-env-test--run)))
      (should-not (process-live-p (car r)))
      (should (equal (getenv "MANPATH") "/read/man")))))

(ert-deftest drgnx-shell-env/a-shell-that-exited-before-its-input-is-closed-still-answers ()
  ;; a fast shell has exited, and Emacs knows, before its input is closed: its environment is read, no failure said
  ;; (the closing raised "not running": no process, a failure, and the sentinel's answer too).  The race made certain.
  (drgnx-shell-env-test--with
    (drgnx-shell-env-test--env-shell dir nil (list "PATH=/usr/bin" "MANPATH=/fast/man"))
    (let* ((done nil)
           (proc (drgnx-test-with-exit-before-read (drgnx-shell-env-start (lambda (_) (setq done t))))))
      (should (processp proc))
      (should (drgnx-test-wait (lambda () done) :what "the shell's answer")))
    (should (equal (getenv "MANPATH") "/fast/man"))
    (should-not (seq-find #'drgnx-shell-env-test--failure-p messages))))

(ert-deftest drgnx-shell-env/path-merges-shell-first ()
  (drgnx-shell-env-test--with
    (make-directory (concat dir "shellbin"))
    (let ((prog (concat dir "shellbin/drgnx-shell-env-prog")))
      (with-temp-file prog (insert "#!/bin/sh\n"))
      (set-file-modes prog #o700)
      (should-not (executable-find "drgnx-shell-env-prog"))
      (drgnx-shell-env-test--env-shell dir nil (list (concat "PATH=" dir "shellbin:/usr/bin")))
      (drgnx-shell-env-test--run)
      (should (equal (getenv "PATH") (concat dir "shellbin:/usr/bin:" dir "oldbin:/bin")))
      (should (equal exec-path (append (parse-colon-path (getenv "PATH")) (list exec-directory))))
      (should (equal (executable-find "drgnx-shell-env-prog") prog)))))

(ert-deftest drgnx-shell-env/off-switch ()
  (drgnx-shell-env-test--with
    (drgnx-shell-env-test--fake dir "echo should-not-run")
    (let ((procs (length (process-list))))
      (setenv "DRGNX_NO_SHELL_ENV" "1")
      (should-not (drgnx-shell-env-start))
      (should (= procs (length (process-list))))
      (setenv "DRGNX_NO_SHELL_ENV" nil)
      (let ((noninteractive t)) (should-not (drgnx-shell-env-start))))))

(ert-deftest drgnx-shell-env/the-hub-gets-the-new-path ()
  (drgnx-shell-env-test--with
    (let ((calls nil))
      (cl-letf (((symbol-function 'drgnx-hub-running-p) (lambda () t))
                ((symbol-function 'drgnx-hub-call) (lambda (method params cb) (push (list method params cb) calls) 1)))
        (drgnx-shell-env-test--env-shell dir nil (list (concat "PATH=" dir "shellbin:/usr/bin")
                                                       (concat "OPENROUTER_API_KEY=" "k")))
        (drgnx-shell-env-test--run)
        (should (= 1 (length calls)))
        (should (equal (car (car calls)) "env/set"))
        (should (equal (cadr (car calls)) (list :env (list (list :name "PATH" :value (concat dir "shellbin:/usr/bin"))))))
        (drgnx-shell-env-test--run)          ; the same PATH again: unchanged, the hub is not told
        (should (= 1 (length calls)))))))

(ert-deftest drgnx-shell-env/the-hub-refuses-keys ()
  (let ((process-environment (append (list "PATH=/usr/bin" "OPENAI_API_KEY" "MANPATH") (copy-sequence process-environment)))
        (exec-path (copy-sequence exec-path)))
    (drgnx-hub--set-env '((:name "PATH" :value "/x") (:name "OPENAI_API_KEY" :value "k")))
    (should (equal (getenv "PATH") "/x:/usr/bin"))
    (should-not (getenv "OPENAI_API_KEY"))
    ;; as it comes over the socket: {"env": [{"name": …, "value": …}]}; the object form is refused
    (should-error (drgnx-hub--method "env/set" (list :env (list :PATH "/z"))))
    (should (equal (getenv "PATH") "/x:/usr/bin"))
    (should (equal (drgnx-hub--method "env/set" (list :env (list (list :name "PATH" :value "/y")
                                                                 (list :name "MANPATH" :value "/m")
                                                                 (list :name "OPENAI_API_KEY" :value "k"))))
                   (list :applied ["PATH" "MANPATH"])))
    (should (equal (getenv "PATH") "/y:/x:/usr/bin"))
    (should (equal (getenv "MANPATH") "/m"))
    (should-not (getenv "OPENAI_API_KEY"))))

(ert-deftest drgnx-shell-env/a-real-zsh-login ()
  (skip-unless (executable-find "zsh"))
  (drgnx-shell-env-test--with
    (let ((home (concat dir "home/")))
      (make-directory (concat home "mybin") t)
      (with-temp-file (concat home ".zprofile") (insert "export PATH=\"$HOME/mybin:$PATH\"\n"))
      (with-temp-file (concat home ".zshrc") (insert "echo hello from zshrc\n"))
      (setenv "HOME" (directory-file-name home))
      (setenv "ZDOTDIR" (directory-file-name home))
      (setenv "HISTFILE" "/dev/null")
      (setenv "SHELL" (executable-find "zsh"))
      (drgnx-shell-env-test--run)
      (should (string-prefix-p (concat home "mybin:") (getenv "PATH"))))))

(provide 'shell-env-test)
;;; shell-env-test.el ends here
