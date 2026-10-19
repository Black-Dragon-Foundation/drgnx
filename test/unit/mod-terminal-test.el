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
       (advice-remove 'eat--process-output-queue #'drgnx-terminal-eat--collect-in-gap)
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

(ert-deftest drgnx-terminal/remote-folder-and-windows-open-eshell-without-a-notice ()
  (unless (drgnx-terminal-test--eat-dir) (ert-skip drgnx-terminal-test--skip))
  (drgnx-terminal-test--fresh t
    (let ((msgs nil) (opened nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) msgs)))
                ((symbol-function 'drgnx-terminal-new-eshell) (lambda (&optional dir) (push (cons 'eshell dir) opened) nil))
                ((symbol-function 'drgnx-terminal-eat-start) (lambda (dir) (push (cons 'eat dir) opened) nil))
                ((symbol-function 'file-remote-p) (lambda (f &rest _) (and (string-prefix-p "/ssh:" f) "/ssh:h:"))))
        (drgnx-terminal-new "/ssh:h:/tmp/")
        (let ((system-type 'windows-nt)) (drgnx-terminal-new "/tmp/"))
        (should (equal (reverse opened) '((eshell . "/ssh:h:/tmp/") (eshell . "/tmp/"))))
        (should-not msgs)
        (should-not drgnx-terminal--notice-shown)))))

(ert-deftest drgnx-terminal/the-shell-starts-in-the-folder ()
  (unless (drgnx-terminal-test--eat-dir) (ert-skip drgnx-terminal-test--skip))
  (let* ((dir (make-temp-file "drgnx-term" t)) (sub (file-name-as-directory (expand-file-name "work dir" dir)))
         (out (expand-file-name "pwd.txt" dir)))
    (make-directory sub)
    (let* ((script (drgnx-terminal-test--script dir (format "pwd -P > %s\nexec sleep 30" (shell-quote-argument out))))
           (process-environment (cons (concat "SHELL=" script) process-environment)))
      (unwind-protect
          (drgnx-terminal-test--fresh t
            (drgnx-terminal-new sub)
            (should (equal (string-trim (or (drgnx-terminal-test--wait-for-file out) ""))
                           (directory-file-name (file-truename sub)))))
        (delete-directory dir t)))))

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
  (let* ((dir (make-temp-file "drgnx-term" t))
         (script (drgnx-terminal-test--script dir "sleep 30 &\nread x"))
         (process-environment (cons (concat "SHELL=" script) process-environment)))
    (unwind-protect
        (drgnx-terminal-test--fresh t
          ;; a program is running: the shell has a child (the quit path refreshes the flag from the children; an idle
          ;; shell asks nothing)
          (let ((proc (get-buffer-process (drgnx-terminal-new dir))))
            (should (drgnx-terminal-test--wait-until (lambda () (drgnx-terminal-test--children proc)))))
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

;;;; An idle shell is never a running program; a busy one is (the quit and close-buffer questions)

(defun drgnx-terminal-test--running ()
  "Live processes that make drgnx's quit ask (what `drgnx-session--running-programs' collects)."
  (seq-filter (lambda (p) (and (process-live-p p) (process-query-on-exit-flag p))) (process-list)))

(defun drgnx-terminal-test--wait-until (pred)
  "Non-nil once PRED is (waits up to 5 s)."
  (let ((until (+ (float-time) 5)))
    (while (and (< (float-time) until) (not (funcall pred))) (accept-process-output nil 0.1))
    (funcall pred)))

(defmacro drgnx-terminal-test--shell (body &rest forms)
  "Run FORMS with `buf' and `proc' bound to a new eat terminal whose \"shell\" is a script running BODY."
  (declare (indent 1))
  `(progn
     (unless (drgnx-terminal-test--eat-dir) (ert-skip drgnx-terminal-test--skip))
     (let* ((dir (make-temp-file "drgnx-term" t))
            (script (drgnx-terminal-test--script dir ,body))
            (process-environment (cons (concat "SHELL=" script) process-environment)))
       (unwind-protect
           (drgnx-terminal-test--fresh t
             (let* ((buf (drgnx-terminal-new dir)) (proc (get-buffer-process buf)))
               ,@forms))
         (delete-directory dir t)))))

(defun drgnx-terminal-test--children (proc)
  "The pids of PROC's children."
  (seq-filter (lambda (p) (eql (alist-get 'ppid (process-attributes p)) (process-id proc))) (list-system-processes)))

(ert-deftest drgnx-terminal/an-idle-shell-is-not-a-running-program ()
  ;; with eat's integration the prompt clears the flag; without it (declined) nothing ever does: so drgnx starts it off
  (drgnx-terminal-test--shell "read x"
    (should (process-live-p proc))
    (should-not (process-query-on-exit-flag proc))
    (should-not (memq proc (drgnx-terminal-test--running)))
    (drgnx-terminal-eat-refresh-query-flags)
    (should-not (memq proc (drgnx-terminal-test--running)))))

(ert-deftest drgnx-terminal/without-integration-a-child-process-makes-it-running ()
  (drgnx-terminal-test--shell "sleep 30 &\nread x"
    (should (drgnx-terminal-test--wait-until (lambda () (drgnx-terminal-test--children proc))))
    (should-not (memq proc (drgnx-terminal-test--running)))          ; nothing refreshed it yet
    (drgnx-terminal-eat-refresh-query-flags)
    (should (memq proc (drgnx-terminal-test--running)))
    (dolist (child (drgnx-terminal-test--children proc)) (signal-process child 'TERM))
    (should (drgnx-terminal-test--wait-until (lambda () (not (drgnx-terminal-test--children proc)))))
    (drgnx-terminal-eat-refresh-query-flags)
    (should-not (memq proc (drgnx-terminal-test--running)))))

(ert-deftest drgnx-terminal/with-integration-the-flag-is-eats-own ()
  (drgnx-terminal-test--shell "sleep 30 &\nread x"
    (should (drgnx-terminal-test--wait-until (lambda () (drgnx-terminal-test--children proc))))
    ;; eat's integration has sent its prompt mark: the flag is what eat says (idle), whatever the children
    (with-current-buffer buf (drgnx-terminal-eat--note-integration))
    (drgnx-terminal-eat-refresh-query-flags)
    (should-not (memq proc (drgnx-terminal-test--running)))
    ;; and a command eat reports as running stays running, with no child at all
    (set-process-query-on-exit-flag proc t)
    (dolist (child (drgnx-terminal-test--children proc)) (signal-process child 'TERM))
    (should (drgnx-terminal-test--wait-until (lambda () (not (drgnx-terminal-test--children proc)))))
    (drgnx-terminal-eat-refresh-query-flags)
    (should (memq proc (drgnx-terminal-test--running)))))

(ert-deftest drgnx-terminal/closing-a-terminal-asks-only-when-something-runs ()
  (let ((asked nil))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (p) (push p asked) t)))
      (drgnx-terminal-test--shell "read x"
        (kill-buffer buf)
        (should-not asked))
      (drgnx-terminal-test--shell "sleep 30 &\nread x"
        (should (drgnx-terminal-test--wait-until (lambda () (drgnx-terminal-test--children proc))))
        (kill-buffer buf)
        (should (= 1 (length asked)))))))

(ert-deftest drgnx-terminal/with-drgnx-shell-files-the-prompt-clears-and-a-command-sets-the-flag ()
  ;; the real thing: zsh and bash with only the drgnx line in their rc, in eat (its integration comes on by itself)
  (dolist (shell '("zsh" "bash"))
    (when (executable-find shell)
      (let* ((home (make-temp-file "drgnx-term" t))
             (file (expand-file-name (concat "etc/shell/drgnx." shell) drgnx-dir))
             (rc (expand-file-name (if (equal shell "zsh") ".zshrc" "bashrc") home))
             (wrapper (drgnx-terminal-test--script
                       home (if (equal shell "zsh") (format "exec %s -d -i" (executable-find shell))
                              (format "exec %s --noprofile --rcfile %s -i" (executable-find shell) rc))))
             (process-environment (append (list (concat "SHELL=" wrapper) (concat "HOME=" home) (concat "ZDOTDIR=" home)
                                                "PS1=$ " "PROMPT=$ " "HISTFILE=/dev/null")   ; no history file written into HOME as the shell dies
                                          process-environment))
             (shell-proc nil))
        (with-temp-file rc (insert (format "PS1='$ '\nsource '%s'\n" file)))
        (unwind-protect
            (drgnx-terminal-test--fresh t
              (let* ((buf (drgnx-terminal-new home)) (proc (setq shell-proc (get-buffer-process buf))))
                ;; the first prompt: eat marked it, the shell is idle
                (should (drgnx-terminal-test--wait-until (lambda () (buffer-local-value 'drgnx-terminal-eat--integrated buf))))
                (should-not (process-query-on-exit-flag proc))
                ;; a builtin that waits has no child process: the flag is eat's, so a refresh leaves it set
                (process-send-string proc "read -t 2 x\n")
                (should (drgnx-terminal-test--wait-until (lambda () (process-query-on-exit-flag proc))))
                (drgnx-terminal-eat-refresh-query-flags)
                (should (process-query-on-exit-flag proc))
                ;; the prompt after it clears the flag again
                (should (drgnx-terminal-test--wait-until (lambda () (not (process-query-on-exit-flag proc)))))))
          ;; the shell may still be dying (the cleanup killed its terminal): not before it is gone, or HOME is not empty
          (when shell-proc (drgnx-terminal-test--wait-until (lambda () (not (process-live-p shell-proc)))))
          (delete-directory home t))))))

(ert-deftest drgnx-terminal/the-fallback-scan-is-local-and-runs-once-per-pass ()
  ;; no /proc children file (macOS): one scan of the process table per refresh pass, never dispatched to TRAMP
  (drgnx-terminal-test--shell "sleep 30 &\nread x"
    (should (drgnx-terminal-test--wait-until (lambda () (drgnx-terminal-test--children proc))))
    (let* ((idle (let ((process-environment (cons (concat "SHELL=" (drgnx-terminal-test--script dir "read x")) process-environment)))
                   (drgnx-terminal-new dir)))
           (idle-proc (get-buffer-process idle))
           (scans 0) (dirs nil)
           (list-fn (symbol-function 'list-system-processes)) (attr-fn (symbol-function 'process-attributes))
           (readable-fn (symbol-function 'file-readable-p)))
      (cl-letf (((symbol-function 'file-readable-p)
                 (lambda (f) (and (not (string-prefix-p "/proc/" f)) (funcall readable-fn f))))
                ((symbol-function 'list-system-processes) (lambda () (cl-incf scans) (funcall list-fn)))
                ((symbol-function 'process-attributes) (lambda (pid) (push default-directory dirs) (funcall attr-fn pid))))
        (let ((default-directory "/ssh:nohost:/tmp/")) (drgnx-terminal-eat-refresh-query-flags)))
      (should (= scans 1))
      (should dirs)
      (should-not (seq-some #'file-remote-p dirs))
      (should (process-query-on-exit-flag proc))
      (should-not (process-query-on-exit-flag idle-proc)))))

;;;; GC pauses off the typing path (M12e perf: a terminal flooding output allocates ~500 bytes per output line)
;; The rule itself (quiet, no input, 85% consed) is the GC owner's `drgnx-gc-gap' (core-gc-owner-test.el); here: eat's
;; output batches reach it, and its rule holds from that path.

(defun drgnx-terminal-test--collects-p (idle consed-share &optional pending)
  "Whether the gap hook collects when Emacs has been idle IDLE seconds (nil: it is not idle), CONSED-SHARE of
`gc-cons-threshold' has been consed since the last collection, and input is waiting when PENDING."
  (let* ((gc-cons-threshold 1000000)
         (drgnx-gc--base (- (drgnx-gc--consed) (* consed-share gc-cons-threshold)))
         (collected nil))
    (cl-letf (((symbol-function 'current-idle-time) (lambda () (and idle (seconds-to-time idle))))
              ((symbol-function 'input-pending-p) (lambda (&rest _) pending))
              ((symbol-function 'garbage-collect) (lambda () (setq collected t) nil)))
      (drgnx-terminal-eat--collect-in-gap))
    collected))

(ert-deftest drgnx-terminal/gc-gap-collects-when-quiet-and-nearly-due ()
  (drgnx-terminal-test--fresh nil
    (let ((drgnx-gc-gap-quiet 0.02))
      (should (drgnx-terminal-test--collects-p 0.05 0.9))        ; quiet long enough, 90% of the threshold consed
      (should-not (drgnx-terminal-test--collects-p 0.05 0.9 t))  ; a key is waiting to be read
      (should-not (drgnx-terminal-test--collects-p 0.005 0.9))   ; a key was handled a moment ago: the next batch may be in its span
      (should-not (drgnx-terminal-test--collects-p nil 0.9))     ; not idle at all (a command is running)
      (should-not (drgnx-terminal-test--collects-p 0.05 0.3)))   ; plenty of room left: nothing to do yet
    (let ((drgnx-gc-gap-quiet nil))
      (should-not (drgnx-terminal-test--collects-p 0.05 0.9)))   ; switched off
    (let ((drgnx-gc-gap-quiet "0.02"))
      (should-not (drgnx-terminal-test--collects-p 0.05 0.9)))))  ; a mistyped value never signals in eat's output path

(ert-deftest drgnx-terminal/gc-gap-collects-once-per-threshold ()
  ;; after a collection (the GC owner's post-gc-hook notes it) the next batch finds nothing consed: no second collection
  (drgnx-terminal-test--fresh nil
    (let* ((gc-cons-threshold 1000000) (drgnx-gc-gap-quiet 0.02) (collections 0)
           (drgnx-gc--base (- (drgnx-gc--consed) (* 0.9 gc-cons-threshold))))
      (cl-letf (((symbol-function 'current-idle-time) (lambda () (seconds-to-time 0.05)))
                ((symbol-function 'input-pending-p) (lambda (&rest _) nil))
                ((symbol-function 'garbage-collect) (lambda () (cl-incf collections) (drgnx-gc--note))))
        (drgnx-terminal-eat--collect-in-gap)
        (drgnx-terminal-eat--collect-in-gap)
        (should (= collections 1))))))

(ert-deftest drgnx-terminal/gc-gap-is-wired-to-eats-output-batches ()
  (unless (drgnx-terminal-test--eat-dir) (ert-skip drgnx-terminal-test--skip))
  (drgnx-terminal-test--fresh t
    (should (advice-member-p #'drgnx-terminal-eat--collect-in-gap 'eat--process-output-queue))
    (should-not (memq 'drgnx-terminal-eat--gc-note post-gc-hook))))   ; the GC owner keeps the one note

(provide 'mod-terminal-test)
;;; mod-terminal-test.el ends here
