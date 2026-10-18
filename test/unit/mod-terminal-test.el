;;; mod-terminal-test.el --- batch tests: New Terminal is eat, with eshell as the fallback -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-area)
(require 'drgnx-persist)
(require 'server)

(defvar drgnx-terminal--notice-shown)
(defvar eat-eshell-fallback-if-stty-not-available)
(defvar eat-term-terminfo-directory)

(defconst drgnx-terminal-test--elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa"))
  "The user's ELPA, read-only, for eat (the runner passes it as DRGNX_USER_ELPA).")

(defconst drgnx-terminal-test--skip
  "eat is not installed: run drgnx sync (a temp elpa for tests: set DRGNX_USER_ELPA to a directory holding eat-0.9.4/)")

(defun drgnx-terminal-test--eat-dir ()
  "The eat package directory in the ELPA, or nil."
  (and (file-directory-p drgnx-terminal-test--elpa)
       (car (directory-files drgnx-terminal-test--elpa t "\\`eat-[0-9.]+\\'"))))

(defun drgnx-terminal-test--script (dir body)
  "An executable shell script with BODY in DIR; its path."
  (let ((f (expand-file-name (format "shell-%d" (random 1000000)) dir)))
    (write-region (concat "#!/bin/sh\n" body "\n") nil f nil 'silent)
    (set-file-modes f #o755)
    f))

(defmacro drgnx-terminal-test--fresh (eat &rest body)
  "Run BODY with only the terminal modules defined and run (eat on `load-path' when EAT), the panel's rules on."
  (declare (indent 1))
  `(let* ((cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
          (load-path (if ,eat (append load-path (list (drgnx-terminal-test--eat-dir)))
                       (seq-remove (lambda (d) (string-prefix-p drgnx-terminal-test--elpa d)) load-path)))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (display-buffer-alist nil) (drgnx-signal--editor-window nil) (drgnx-wb-unrouted nil)
          (drgnx-terminal--notice-shown nil))
     (unwind-protect
         (progn
           (dolist (m '("tools/drgnx-terminal" "tools/drgnx-terminal-eat"))
             (load (expand-file-name (concat "modules/" m) drgnx-dir) nil t))
           (delete-other-windows)
           (drgnx-rules-mode 1)
           (if ,eat (drgnx-modules-run 'startup)
             ;; eat is not there, even when an earlier test loaded it into this Emacs
             (let ((orig (symbol-function 'featurep)))
               (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) nil))
                         ((symbol-function 'featurep) (lambda (f &rest r) (and (not (eq f 'eat)) (apply orig f r)))))
                 (drgnx-modules-run 'startup))))
           ,@body)
       (drgnx-rules-mode -1)
       (drgnx-wb-area-hide 'panel)
       (dolist (b (buffer-list))
         (when (string-match-p "\\`\\*\\(eat\\|eshell\\)\\*" (buffer-name b))
           (let ((kill-buffer-query-functions nil) (p (get-buffer-process b)))
             (when p (set-process-query-on-exit-flag p nil))
             (kill-buffer b))))
       (delete-directory cfg t))))

(defun drgnx-terminal-test--wait-for-file (file)
  "FILE's text once the shell has written it (waits up to 5 s), else nil."
  (let ((until (+ (float-time) 5)))
    (while (and (< (float-time) until)
                (not (and (file-exists-p file) (> (file-attribute-size (file-attributes file)) 0))))
      (accept-process-output nil 0.1))
    (when (file-exists-p file)
      (sleep-for 0.2)
      (with-temp-buffer (insert-file-contents file) (buffer-string)))))

(ert-deftest drgnx-terminal/new-terminal-is-eat-running-the-users-shell ()
  (unless (drgnx-terminal-test--eat-dir) (ert-skip drgnx-terminal-test--skip))
  (let* ((dir (make-temp-file "drgnx-term" t))
         (script (drgnx-terminal-test--script dir "exec sh \"$@\""))
         (process-environment (cons (concat "SHELL=" script) process-environment)))
    (unwind-protect
        (drgnx-terminal-test--fresh t
          (let* ((b (drgnx-terminal-new dir)) (b2 (drgnx-terminal-new dir)))
            (should (eq (buffer-local-value 'major-mode b) 'eat-mode))
            (should (equal (car (last (process-command (get-buffer-process b)))) script))
            (should (eq (window-buffer (drgnx-wb-area-window 'panel)) b2))
            (should (eq (drgnx-wb-area-tab 'panel) 'terminal))
            (should-not drgnx-wb-unrouted)
            (should-not (eq b b2))
            (should (equal (buffer-name b) "*eat*"))
            (should (equal (buffer-name b2) "*eat*<2>"))))
      (delete-directory dir t))))

(ert-deftest drgnx-terminal/without-eat-it-is-eshell-with-one-notice ()
  (drgnx-terminal-test--fresh nil
    (should (eq (plist-get (alist-get 'tools/terminal-eat (drgnx-modules-report)) :status) 'missing-packages))
    (let ((msgs nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) msgs))))
        (let ((b (drgnx-terminal-new)) (b2 (drgnx-terminal-new)))
          (should (eq (buffer-local-value 'major-mode b) 'eshell-mode))
          (should (eq (buffer-local-value 'major-mode b2) 'eshell-mode))))
      (should (= 1 (seq-count (lambda (m) (equal m drgnx-terminal-eat-missing-notice)) msgs)))
      (should (string-match-p "eat is not installed yet" drgnx-terminal-eat-missing-notice)))))

(ert-deftest drgnx-terminal/a-remote-folder-gets-eshell ()
  (unless (drgnx-terminal-test--eat-dir) (ert-skip drgnx-terminal-test--skip))
  (drgnx-terminal-test--fresh t
    (should (drgnx-terminal-eat-usable-p "/tmp/"))
    (cl-letf (((symbol-function 'file-remote-p) (lambda (f &rest _) (and (string-prefix-p "/ssh:" f) "/ssh:h:"))))
      (should-not (drgnx-terminal-eat-usable-p "/ssh:h:/tmp/")))
    (let ((system-type 'windows-nt))
      (should-not (drgnx-terminal-eat-usable-p "/tmp/")))))

(ert-deftest drgnx-terminal/the-environment-names-this-server ()
  (let* ((dir (make-temp-file "drgnx-srv" t)) (server-socket-dir dir) (server-name "drgnx-term-test")
         (server-use-tcp nil) (server-process nil) (server-clients nil))
    (unwind-protect
        (progn
          (server-start)
          (let ((sock (expand-file-name "drgnx-term-test" dir)) (env (drgnx-terminal-environment)))
            (should (equal (drgnx-terminal-server-socket) sock))
            (should (= 4 (length env)))
            (dolist (e env) (should (string-search sock e)))
            (should (equal (car env) (concat "DRGNX_SERVER_NAME=" sock)))
            (dolist (var '("EDITOR=" "VISUAL=" "GIT_EDITOR="))
              (should (seq-find (lambda (e) (string-match-p (concat "\\`" var ".*emacsclient\\S-* -s ") e)) env)))
            (let ((git (seq-find (lambda (e) (string-prefix-p "GIT_EDITOR=" e)) env)))
              (should-not (string-match-p " -[ctn]\\b" git)))))
      (ignore-errors (server-force-delete))
      (delete-directory dir t))))

(ert-deftest drgnx-terminal/the-shell-sees-this-server ()
  (unless (drgnx-terminal-test--eat-dir) (ert-skip drgnx-terminal-test--skip))
  (let* ((dir (make-temp-file "drgnx-term" t)) (out (expand-file-name "env.txt" dir))
         (script (drgnx-terminal-test--script dir (format "env > %s\nexec sleep 30" (shell-quote-argument out))))
         (process-environment (cons (concat "SHELL=" script) process-environment))
         (server-socket-dir dir) (server-name "drgnx-term-test") (server-use-tcp nil) (server-process nil) (server-clients nil))
    (unwind-protect
        (drgnx-terminal-test--fresh t
          (server-start)
          (drgnx-terminal-new dir)
          (let ((env (drgnx-terminal-test--wait-for-file out)) (sock (expand-file-name "drgnx-term-test" dir)))
            (should env)
            (should (string-match-p (concat "^DRGNX_SERVER_NAME=" (regexp-quote sock) "$") env))
            (should (string-match-p (concat "^EDITOR=.* -s " (regexp-quote sock) "$") env))
            (should (string-match-p (concat "^GIT_EDITOR=.* -s " (regexp-quote sock) "$") env))))
      (ignore-errors (server-force-delete))
      (delete-directory dir t))))

(ert-deftest drgnx-terminal/no-server-no-editor ()
  (unless (drgnx-terminal-test--eat-dir) (ert-skip drgnx-terminal-test--skip))
  (let* ((dir (make-temp-file "drgnx-term" t)) (out (expand-file-name "env.txt" dir))
         (script (drgnx-terminal-test--script dir (format "env > %s\nexec sleep 30" (shell-quote-argument out))))
         (process-environment (append (list (concat "SHELL=" script) "EDITOR=their-editor") process-environment))
         (server-process nil))
    (unwind-protect
        (drgnx-terminal-test--fresh t
          (should-not (drgnx-terminal-environment))
          (drgnx-terminal-new dir)
          (let ((env (drgnx-terminal-test--wait-for-file out)))
            (should env)
            (should (string-match-p "^EDITOR=their-editor$" env))
            (should-not (string-match-p "^DRGNX_SERVER_NAME=" env))
            (should (string-match-p "^INSIDE_EMACS=" env))))
      (delete-directory dir t))))

(ert-deftest drgnx-terminal/quit-and-save-never-ask-eats-question ()
  (unless (drgnx-terminal-test--eat-dir) (ert-skip drgnx-terminal-test--skip))
  (skip-unless (or (fboundp 'drgnx-session-quit-confirm)
                   (ert-skip "drgnx-session-quit-confirm arrives with pass B (deferred-b); the quit half runs after it merges")))
  (let* ((dir (make-temp-file "drgnx-term" t))
         (script (drgnx-terminal-test--script dir "exec sleep 30"))
         (process-environment (cons (concat "SHELL=" script) process-environment)))
    (unwind-protect
        (drgnx-terminal-test--fresh t
          (drgnx-terminal-new dir)
          (let ((state (expand-file-name "state.eld" dir)) (asked nil) (killed 0))
            ;; saving the workbench asks nothing, eat running or not
            (let ((inhibit-interaction t)) (should (drgnx-persist-save state)))
            (should (file-exists-p state))
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (p) (push p asked) t))
                      ((symbol-function 'save-some-buffers) #'ignore)
                      ((symbol-function 'drgnx-session--unsaved-buffers) (lambda () nil))
                      ((symbol-function 'kill-emacs) (lambda (&rest _) (cl-incf killed))))
              (drgnx-session-quit))
            (should (= 1 (length asked)))
            (should (string-match-p "\\beat\\b" (car asked)))
            (should (= killed 1))))
      (delete-directory dir t))))

(ert-deftest drgnx-terminal/the-doctor-names-a-prompting-eat ()
  (unless (drgnx-terminal-test--eat-dir) (ert-skip drgnx-terminal-test--skip))
  (drgnx-terminal-test--fresh t
    (require (quote eat))
    (let ((doctor (plist-get (cdr (assq 'tools/terminal-eat drgnx-modules--table)) :doctor))
          (eat-eshell-fallback-if-stty-not-available nil))
      (should (functionp doctor))
      (should-not (funcall doctor))
      (let ((eat-eshell-fallback-if-stty-not-available 'ask))
        (should (member "eat would ask when stty is missing (eat-eshell-fallback-if-stty-not-available is ask)"
                        (funcall doctor))))
      (let ((eat-term-terminfo-directory "/nonexistent/drgnx-terminfo"))
        (should (member "eat's terminfo is missing: drgnx sync" (funcall doctor)))))))

(provide 'mod-terminal-test)
;;; mod-terminal-test.el ends here
