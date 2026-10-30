;;; tty-bin-test.el --- bin/drgnx: `drgnx -t' (the workbench in this terminal) and the tty test tiers -*- lexical-binding: t -*-
;; Fake emacs, emacsclient, infocmp and kitty scripts on a temp PATH record their argv; bin/drgnx runs in a temp
;; HOME, never the user's.  The environment each test sets is complete for what the decision reads (DISPLAY, SSH_*,
;; VTE_VERSION, TERM…), so the host's own does not matter.
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst tty-bin-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defconst tty-bin-test--bin (expand-file-name "bin/drgnx" tty-bin-test--root))

(defconst tty-bin-test--server (format "drgnx-ttybin-%d" (emacs-pid)) "A server name no real daemon has.")

(defconst tty-bin-test--capable "(progn (require 'drgnx-tty-recommend nil t) (and (fboundp 'drgnx-tty-capable-terminal-argv) (drgnx-tty-capable-terminal-argv)))"
  "What `drgnx -t' asks the daemon about a capable terminal.")

(defun tty-bin-test--slurp (file)
  (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))

(defun tty-bin-test--script (file body)
  (write-region (concat "#!/bin/sh\n" body "\n") nil file nil 'silent)
  (set-file-modes file #o755))

(defun tty-bin-test--fakes (dir pathdir)
  "Fake `emacs', `emacsclient', `infocmp' and `kitty' in PATHDIR.  State files in DIR: running (the server
answers), gui (a window is open), no-terminfo (infocmp fails), capable (the daemon's answer about a capable
terminal; absent: nil).  emacsclient and kitty log each call to client.log and kitty.log, one line per call,
every argument followed by \\037."
  (let ((f (lambda (name) (shell-quote-argument (expand-file-name name dir)))))
    (tty-bin-test--script
     (expand-file-name "emacsclient" pathdir)
     (format "printf '%%s\\037' \"$@\" >> %s; echo >> %s
for a in \"$@\"; do last=\"$a\"; done
case \"$last\" in
  t) [ -f %s ] || exit 1 ;;
  '(drgnx-session-gui-frame-p)') if [ -f %s ]; then echo t; else echo nil; fi ;;
  *drgnx-tty-capable-terminal-argv*) if [ -f %s ]; then cat %s; else echo nil; fi ;;
esac"
             (funcall f "client.log") (funcall f "client.log") (funcall f "running") (funcall f "gui")
             (funcall f "capable") (funcall f "capable")))
    (tty-bin-test--script (expand-file-name "nidhogg" pathdir)
                          (format "echo \"$*\" >> %s\ncase \"$*\" in *--bg-daemon=*) touch %s ;; esac"
                                  (funcall f "emacs.log") (funcall f "running")))
    (tty-bin-test--script (expand-file-name "infocmp" pathdir)
                          (format "echo \"$*\" >> %s\n[ -f %s ] && exit 1\nexit 0" (funcall f "infocmp.log") (funcall f "no-terminfo")))
    (tty-bin-test--script (expand-file-name "kitty" pathdir)
                          (format "printf '%%s\\037' \"$@\" >> %s; echo >> %s" (funcall f "kitty.log") (funcall f "kitty.log")))))

(defconst tty-bin-test--defaults
  '(("DISPLAY" . ":99") ("WAYLAND_DISPLAY") ("SSH_CONNECTION") ("SSH_TTY") ("VTE_VERSION") ("TERM_PROGRAM")
    ("TERM" . "xterm-256color") ("DRGNX_EMACS") ("DRGNX_OPEN_WAIT" . "5")
    ("DRGNX_MODAL_ELPA"))   ; a machine that runs the modal tests has it set; `test --container' would mount it
  "What a test starts from: a graphical, local terminal; a cons without a value unsets the variable.")

(defmacro tty-bin-test--with (&rest body)
  "BODY with DIR (a temp directory, deleted afterwards), PATHDIR (the fakes), and `call' (a function: ARGS and
optionally ENV (an alist like `tty-bin-test--defaults' overriding it) and PTY (non-nil: stdin and stdout are a
terminal, as when a person types the command; else /dev/null and a pipe) → (EXIT . OUTPUT), stderr included)."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "drgnx-ttybin" t))
          (pathdir (expand-file-name "path" dir)))
     (make-directory pathdir)
     (make-directory (expand-file-name "config" dir))
     (tty-bin-test--fakes dir pathdir)
     (unwind-protect
         (cl-flet ((call (args &optional env pty)
                     (let* ((merged (append env (seq-remove (lambda (d) (assoc (car d) env)) tty-bin-test--defaults)))
                            (process-environment
                             (append (mapcar (lambda (e) (if (cdr e) (concat (car e) "=" (cdr e)) (car e))) merged)
                                     (list (concat "HOME=" dir) (concat "DRGNX_CONFIG_DIR=" dir "/config")
                                           (concat "XDG_STATE_HOME=" dir "/state")
                                           (concat "DRGNX_SERVER_NAME=" tty-bin-test--server)
                                           (concat "PATH=" pathdir ":/usr/bin:/bin"))
                                     process-environment))
                            (default-directory (file-name-as-directory dir)))
                       (if pty
                           (let* ((buf (generate-new-buffer " ttybin"))
                                  (p (make-process :name "ttybin" :buffer buf :command (cons tty-bin-test--bin args)
                                                   :connection-type 'pty :noquery t :sentinel #'ignore)))
                             (while (process-live-p p) (accept-process-output p 0.05))
                             (accept-process-output p 0.1)
                             (prog1 (cons (process-exit-status p) (with-current-buffer buf (buffer-string)))
                               (kill-buffer buf)))
                         (with-temp-buffer (cons (apply #'call-process tty-bin-test--bin nil t nil args) (buffer-string)))))))
           ,@body)
       (delete-directory dir t))))

(defun tty-bin-test--calls (dir &optional name)
  "The fake emacsclient's (or NAME's) calls so far, each a list of its arguments."
  (mapcar (lambda (line) (split-string line "\037" t))
          (split-string (tty-bin-test--slurp (expand-file-name (or name "client.log") dir)) "\n" t)))

(defun tty-bin-test--touch (dir &rest names)
  (dolist (n names) (write-region "" nil (expand-file-name n dir))))

(defun tty-bin-test--form (call)
  "The form after -e in the emacsclient CALL."
  (cadr (member "-e" call)))

(ert-deftest drgnx-bin/open-t-runs-emacsclient-in-this-terminal ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running" "gui")
    (make-directory (expand-file-name "proj" dir))
    (dolist (args '(("-t" "proj") ("open" "-t" "proj")))
      (delete-file (expand-file-name "client.log" dir))
      (should (equal (call args) '(0 . "")))
      (let ((last (car (last (tty-bin-test--calls dir)))))
        (dolist (a '("-t" "-s" "-e")) (should (member a last)))
        (should (equal (cadr (member "-s" last)) tty-bin-test--server))
        (should-not (member "-c" last))
        (should-not (member "-n" last))
        (should (string-search (format "(drgnx-session-open-folder %S)" (expand-file-name "proj" dir))
                               (tty-bin-test--form last)))))
    ;; the graphical frame is not touched: no raise, no window made
    (should-not (seq-find (lambda (c) (or (member "-c" c) (member "(drgnx-session-raise)" c))) (tty-bin-test--calls dir)))))

(ert-deftest drgnx-bin/open-t-starts-the-daemon-first-and-without-paths-opens-no-form ()
  (tty-bin-test--with
    (should (equal (call '("-t")) '(0 . "")))
    (should (string-search (format "--bg-daemon=%s" tty-bin-test--server) (tty-bin-test--slurp (expand-file-name "emacs.log" dir))))
    (let ((last (car (last (tty-bin-test--calls dir)))))
      (should (member "-t" last))
      (should-not (member "-e" last)))))

(ert-deftest drgnx-bin/open-over-ssh-uses-the-terminal ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running" "gui")
    (dolist (env '((("SSH_CONNECTION" . "1.2.3.4 22 5.6.7.8 22")) (("SSH_TTY" . "/dev/pts/3"))))
      (delete-file (expand-file-name "client.log" dir))
      (should (eql 0 (car (call '("open" "dir") env t))))      ; DISPLAY is set: ssh wins
      (should (member "-t" (car (last (tty-bin-test--calls dir)))))
      (should-not (seq-find (lambda (c) (member "-c" c)) (tty-bin-test--calls dir))))))

(ert-deftest drgnx-bin/open-without-a-display-uses-the-terminal ()
  (skip-unless (eq system-type 'gnu/linux))
  (tty-bin-test--with
    (tty-bin-test--touch dir "running")
    (should (eql 0 (car (call '("open" "dir") '(("DISPLAY") ("WAYLAND_DISPLAY")) t))))
    (should (member "-t" (car (last (tty-bin-test--calls dir)))))
    ;; one display of either kind is enough to stay graphical
    (delete-file (expand-file-name "client.log" dir))
    (tty-bin-test--touch dir "gui")
    (should (eql 0 (car (call '("open" "dir") '(("DISPLAY") ("WAYLAND_DISPLAY" . "wayland-0")) t))))
    (should-not (seq-find (lambda (c) (member "-t" c)) (tty-bin-test--calls dir)))))

(ert-deftest drgnx-bin/open-with-a-display-stays-graphical ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running" "gui")
    (make-directory (expand-file-name "proj" dir))
    (should (equal (call '("open" "proj")) '(0 . "")))
    (let ((s tty-bin-test--server))
      (should (equal (tty-bin-test--calls dir)
                     (list (list "-a" "false" "-s" s "--timeout=5" "-e" "t")
                           (list "-a" "false" "-s" s "--timeout=5" "-e" "(drgnx-session-gui-frame-p)")
                           (list "-a" "false" "-s" s "-n" "-e" "(drgnx-session-raise)")
                           (list "-a" "false" "-s" s "-n" "-e" "(progn (require 'drgnx-ai) (drgnx-ai-load-keys-soon))")
                           (list "-a" "false" "-s" s "-n" "-e"
                                 (format "(drgnx-session-open-folder %S)" (expand-file-name "proj" dir)))))))))

(ert-deftest drgnx-bin/open-t-with-an-unknown-term-says-the-fix ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running" "no-terminfo")
    (let ((r (call '("-t") '(("TERM" . "xterm-kitty")))))
      (should (eql 1 (car r)))
      (dolist (s '("kitten ssh" "tic -x -" "TERM=xterm-256color")) (should (string-search s (cdr r))))
      (should (string-search "xterm-kitty" (cdr r))))
    (should (string-search "xterm-kitty" (tty-bin-test--slurp (expand-file-name "infocmp.log" dir))))
    ;; nothing was opened
    (should-not (seq-find (lambda (c) (member "-t" c)) (tty-bin-test--calls dir)))
    ;; an unset TERM is no terminal type either
    (should (eql 1 (car (call '("-t") '(("TERM"))))))))

(ert-deftest drgnx-bin/gui-takes-a-window-whatever-the-terminal ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running" "gui")
    (make-directory (expand-file-name "proj" dir))
    (dolist (args '(("open" "--gui" "proj") ("--gui" "proj")))
      (delete-file (expand-file-name "client.log" dir))
      ;; a person at a terminal, over SSH and with no display: still a window
      (should (eql 0 (car (call args '(("SSH_CONNECTION" . "1.2.3.4 22 5.6.7.8 22") ("DISPLAY")) t))))
      (should-not (seq-find (lambda (c) (member "-t" c)) (tty-bin-test--calls dir)))
      (should (seq-find (lambda (c) (member "(drgnx-session-raise)" c)) (tty-bin-test--calls dir))))
    ;; the two exclude each other
    (delete-file (expand-file-name "client.log" dir))
    (dolist (args '(("open" "-t" "--gui" "proj") ("--gui" "-t") ("open" "--gui" "-t")))
      (let ((r (call args)))
        (should (eql 2 (car r)))
        (should (string-search "--gui" (cdr r)))))
    (should-not (tty-bin-test--calls dir))))

(ert-deftest drgnx-bin/without-a-terminal-the-choice-is-a-window ()
  ;; a script, a launcher or a hook (stdin and stdout are not a terminal) over SSH or without a display gets a window
  ;; and no terminfo question; only -t asks for the terminal then
  (tty-bin-test--with
    (tty-bin-test--touch dir "running" "gui" "no-terminfo")
    (dolist (env '((("SSH_CONNECTION" . "1.2.3.4 22 5.6.7.8 22")) (("DISPLAY") ("WAYLAND_DISPLAY"))))
      (delete-file (expand-file-name "client.log" dir))
      (should (eql 0 (car (call '("open" "dir") env))))
      (should-not (seq-find (lambda (c) (member "-t" c)) (tty-bin-test--calls dir)))
      (should (seq-find (lambda (c) (member "(drgnx-session-raise)" c)) (tty-bin-test--calls dir)))
      (should-not (file-exists-p (expand-file-name "infocmp.log" dir))))
    (delete-file (expand-file-name "client.log" dir))
    (should (eql 1 (car (call '("-t")))))))                    ; asked for: the terminfo check speaks

(ert-deftest drgnx-bin/the-terminfo-check-waits-for-the-capable-terminal-decision ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running" "no-terminfo")
    (write-region "(\"kitty\" \"--\")\n" nil (expand-file-name "capable" dir))
    ;; the frame opens in kitty: this terminal's description does not matter
    (should (eql 0 (car (call '("-t") '(("VTE_VERSION" . "7600") ("TERM" . "xterm-unknown"))))))
    (drgnx-test-wait (lambda () (tty-bin-test--calls dir "kitty.log")) :secs 10 :what "the terminal to start")
    (should (tty-bin-test--calls dir "kitty.log"))
    (should-not (file-exists-p (expand-file-name "infocmp.log" dir)))
    ;; no capable terminal (the option is off): it matters, and says so
    (delete-file (expand-file-name "capable" dir))
    (should (eql 1 (car (call '("-t") '(("VTE_VERSION" . "7600") ("TERM" . "xterm-unknown"))))))
    (should (file-exists-p (expand-file-name "infocmp.log" dir)))))

(ert-deftest drgnx-bin/paths-with-spaces-and-quotes-reach-the-form ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running")
    (let ((folder (expand-file-name "My \"Project\"" dir)) (file (expand-file-name "café.py" dir)))
      (make-directory folder)
      (should (eql 0 (car (call (list "-t" "My \"Project\"" "café.py")))))
      (let ((form (tty-bin-test--form (car (last (tty-bin-test--calls dir))))))
        (should (equal (read form)
                       `(progn (drgnx-session-open-file ,file) (drgnx-session-open-folder ,folder))))
        (should (string-search "My \\\"Project\\\"" form))))))

(ert-deftest drgnx-bin/open-t-in-a-capable-terminal-when-opted-in ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running")
    (write-region "(\"kitty\" \"--\")\n" nil (expand-file-name "capable" dir))
    (make-directory (expand-file-name "proj" dir))
    ;; a Linux host (macOS runs the client through `env -u XDG_RUNTIME_DIR': drgnx-bin/emacsclient-ignores-…)
    (tty-bin-test--script (expand-file-name "uname" pathdir) "echo Linux")
    (should (equal (call '("-t" "proj") '(("VTE_VERSION" . "7600"))) '(0 . "")))
    ;; the new terminal runs the client; this one does not
    (drgnx-test-wait (lambda () (tty-bin-test--calls dir "kitty.log")) :secs 10 :what "the terminal to start")
    (let ((kitty (car (tty-bin-test--calls dir "kitty.log"))))
      (should (equal (car kitty) "--"))
      (should (string-suffix-p "/path/emacsclient" (nth 1 kitty)))
      (let ((argv (nthcdr 2 kitty)))
        (should (equal (seq-take argv 3) (list "-t" "-s" tty-bin-test--server)))
        (should (string-search (expand-file-name "proj" dir) (tty-bin-test--form argv)))))
    (should-not (seq-find (lambda (c) (and (member "-t" c) (not (member "emacsclient" c)))) (tty-bin-test--calls dir)))
    ;; Apple's Terminal and the Linux console are limited too
    (dolist (env '((("VTE_VERSION") ("TERM_PROGRAM" . "Apple_Terminal")) (("VTE_VERSION") ("TERM" . "linux"))))
      (delete-file (expand-file-name "kitty.log" dir))
      (call '("-t") env)
      (sleep-for 0.5)
      (should (tty-bin-test--calls dir "kitty.log")))))

(ert-deftest drgnx-bin/open-t-over-ssh-or-without-a-display-stays-here-when-opted-in ()
  ;; the caller's environment decides, not the daemon's (a desktop daemon has a display and no SSH variables): a
  ;; limited terminal over SSH, or on a console with no display, gets the frame in this terminal; kitty is not started
  ;; on the remote desktop and the daemon is not asked
  (tty-bin-test--with
    (tty-bin-test--touch dir "running")
    (write-region "(\"kitty\" \"--\")\n" nil (expand-file-name "capable" dir))
    (dolist (env (append '((("SSH_CONNECTION" . "1.2.3.4 22 5.6.7.8 22") ("VTE_VERSION" . "7600"))
                           (("SSH_TTY" . "/dev/pts/3") ("TERM" . "linux")))
                         (and (eq system-type 'gnu/linux) '((("DISPLAY") ("WAYLAND_DISPLAY") ("TERM" . "linux"))))))
      (delete-file (expand-file-name "client.log" dir))
      (should (eql 0 (car (call '("-t") env))))
      (should (member "-t" (car (last (tty-bin-test--calls dir)))))
      (should-not (seq-find (lambda (c) (member tty-bin-test--capable c)) (tty-bin-test--calls dir)))
      (sleep-for 0.3)
      (should-not (file-exists-p (expand-file-name "kitty.log" dir))))))

(ert-deftest drgnx-bin/open-t-stays-here-by-default ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running")
    ;; the daemon has no capable terminal to offer (the option is off): this terminal, kitty not started
    (should (eql 0 (car (call '("-t") '(("VTE_VERSION" . "7600"))))))
    (should (member "-t" (car (last (tty-bin-test--calls dir)))))
    (sleep-for 0.3)
    (should-not (file-exists-p (expand-file-name "kitty.log" dir)))
    ;; a terminal that sends every key is not asked about at all
    (write-region "(\"kitty\" \"--\")\n" nil (expand-file-name "capable" dir))
    (delete-file (expand-file-name "client.log" dir))
    (should (eql 0 (car (call '("-t") '(("TERM" . "xterm-kitty"))))))
    (should-not (seq-find (lambda (c) (member tty-bin-test--capable c)) (tty-bin-test--calls dir)))
    (sleep-for 0.3)
    (should-not (file-exists-p (expand-file-name "kitty.log" dir)))))

(ert-deftest drgnx-bin/test-tty-tiers-are-listed ()
  (tty-bin-test--with
    (let ((usage (cdr (call '("help")))))
      (should (string-search "drgnx test --tty" usage))
      (should (string-search "--container --tty" usage))
      (should (string-search "-t [PATH" usage)))))

(ert-deftest drgnx-bin/test-tty-runs-the-tty-directory-with-sigpipe-ignored ()
  (tty-bin-test--with
    (let ((seen (expand-file-name "seen" dir)))
      (tty-bin-test--script (expand-file-name "nidhogg" pathdir)
                            ;; SIGPIPE ignored: `yes' into a closed pipe gets a write error (exit 1), not the signal
                            ;; (141); no /proc on macOS
                            (format "printf '%%s\\n' \"$@\" > %s\necho \"ENV ${DISPLAY-unset} ${WAYLAND_DISPLAY-unset} ${SWAYSOCK-unset} $DBUS_SESSION_BUS_ADDRESS\" >> %s\n{ yes 2>/dev/null; echo \"PIPE $?\" >> %s; } | head -n 1 >/dev/null" seen seen seen))
      (should (eql 0 (car (call '("test" "--tty") '(("WAYLAND_DISPLAY" . "wayland-0") ("SWAYSOCK" . "/run/sway"))))))
      (let ((lines (split-string (tty-bin-test--slurp seen) "\n" t)))
        (should (equal (seq-take (reverse (seq-take lines (- (length lines) 2))) 3)
                       (list (expand-file-name "test/tty" tty-bin-test--root) "drgnx-run-ert-batch" "-f")))
        ;; no display or compositor, a dead session bus: the tier never reaches the user's desktop
        (should (member "ENV unset unset unset unix:path=/nonexistent/drgnx-unit-test" lines))
        (should (equal (car (last lines)) "PIPE 1"))))))

(ert-deftest drgnx-bin/container-tty-builds-and-runs-the-tty-image ()
  (tty-bin-test--with
    (let ((log (expand-file-name "rt.log" dir)))
      (tty-bin-test--script (expand-file-name "fake-rt" dir) (format "echo \"$*\" >> %s" log))
      (dolist (case '((nil "45") (("--fedora" "45") "45")))
        (when (file-exists-p log) (delete-file log))
        (let ((env `(("DRGNX_CONTAINER" . ,(expand-file-name "fake-rt" dir)) ("DRGNX_TEST_TTY_IMAGE")
                     ("DRGNX_TEST_SELECTOR" . "\"x\""))))
          (should (eql 0 (car (call (append '("test" "--container" "--tty") (car case)) env)))))
        (let ((lines (split-string (tty-bin-test--slurp log) "\n" t)) (n (cadr case)))
          (should (= (length lines) 2))
          (should (string-prefix-p "build " (car lines)))
          (dolist (s (list (format "-t drgnx-test-tty:f%s" n) (format "--build-arg FEDORA=%s" n)
                           "/test/container/Containerfile.tty"))
            (should (string-search s (car lines))))
          (should (string-prefix-p "run --rm " (cadr lines)))
          (dolist (s '("--memory 3g" "seccomp=unconfined" "label=disable"))
            (should (string-search s (cadr lines))))
          (should (string-suffix-p (format " drgnx-test-tty:f%s bin/drgnx test --tty" n) (cadr lines)))
          (should (string-search "DRGNX_TEST_SELECTOR=\"x\"" (cadr lines)))))
      ;; a Fedora we have no image for is refused, and --fedora belongs to --tty
      (should (eql 2 (car (call '("test" "--container" "--ui" "--tty") `(("DRGNX_CONTAINER" . ,(expand-file-name "fake-rt" dir)))))))
      (should (eql 2 (car (call '("test" "--container" "--tty" "--ui") `(("DRGNX_CONTAINER" . ,(expand-file-name "fake-rt" dir)))))))
      (should (eql 2 (car (call '("test" "--container" "--tty" "--fedora" "44") `(("DRGNX_CONTAINER" . ,(expand-file-name "fake-rt" dir)))))))
      (should (eql 2 (car (call '("test" "--container" "--tty" "--fedora" "43") `(("DRGNX_CONTAINER" . ,(expand-file-name "fake-rt" dir)))))))
      (should (eql 2 (car (call '("test" "--container" "--fedora" "44") `(("DRGNX_CONTAINER" . ,(expand-file-name "fake-rt" dir))))))))))

(ert-deftest drgnx-bin/container-tty-takes-the-user-elpa-read-only ()
  ;; DRGNX_USER_ELPA (kkp for the key tests and the kitty exit test) goes into the container read-only; without it
  ;; nothing is mounted and those tests skip
  (tty-bin-test--with
    (let ((log (expand-file-name "rt.log" dir))
          (elpa (expand-file-name "elpa" dir))
          (rt `("DRGNX_CONTAINER" . ,(expand-file-name "fake-rt" dir))))
      (make-directory elpa)
      (tty-bin-test--script (expand-file-name "fake-rt" dir) (format "echo \"$*\" >> %s" log))
      (should (eql 0 (car (call '("test" "--container" "--tty") `(,rt ("DRGNX_TEST_TTY_IMAGE") ("DRGNX_USER_ELPA" . ,elpa))))))
      (let ((run (cadr (split-string (tty-bin-test--slurp log) "\n" t))))
        (should (string-search (format "-v %s:/elpa:ro" elpa) run))
        (should (string-search "-e DRGNX_USER_ELPA=/elpa" run)))
      (delete-file log)
      (should (eql 0 (car (call '("test" "--container" "--tty") `(,rt ("DRGNX_TEST_TTY_IMAGE") ("DRGNX_USER_ELPA"))))))
      (should-not (string-search "/elpa" (tty-bin-test--slurp log)))
      ;; a `:' would split -v's SOURCE:TARGET:OPTIONS: refused, nothing run
      (let ((colon (expand-file-name "el:pa" dir)))
        (make-directory colon)
        (delete-file log)
        (should (eql 2 (car (call '("test" "--container" "--tty") `(,rt ("DRGNX_TEST_TTY_IMAGE") ("DRGNX_USER_ELPA" . ,colon))))))
        (should-not (file-exists-p log))))))

(ert-deftest drgnx-bin/the-tty-workflow-runs-the-fedora-matrix-like-the-gui-one ()
  (let ((yml (tty-bin-test--slurp (expand-file-name ".github/workflows/tty.yml" tty-bin-test--root)))
        (gui (tty-bin-test--slurp (expand-file-name ".github/workflows/gui.yml" tty-bin-test--root))))
    (skip-unless (not (string-empty-p yml)))
    (dolist (s '("schedule:" "workflow_dispatch:" "fedora: [45]" "bin/drgnx test --container --tty --fedora ${{ matrix.fedora }}"
                 "permissions:\n  contents: read" "persist-credentials: false"))
      (should (string-search s yml)))
    ;; the checkout action is the one gui.yml pins, by hash
    (let ((pin (and (string-match "uses: \\(actions/checkout@[0-9a-f]\\{40\\}\\)" gui) (match-string 1 gui))))
      (should pin)
      (should (string-search pin yml)))))

(provide 'tty-bin-test)
;;; tty-bin-test.el ends here
