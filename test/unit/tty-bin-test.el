;;; tty-bin-test.el --- bin/drgnx: `drgnx -t' (the workbench in this terminal) and the tty test tiers -*- lexical-binding: t -*-
;; Fake emacs, emacsclient, infocmp and kitty scripts on a temp PATH record their argv; bin/drgnx runs in a temp
;; HOME, never the user's.  The environment each test sets is complete for what the decision reads (DISPLAY, SSH_*,
;; VTE_VERSION, TERM…), so the host's own does not matter.
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
    (tty-bin-test--script (expand-file-name "emacs" pathdir)
                          (format "echo \"$*\" >> %s\ncase \"$*\" in *--bg-daemon=*) touch %s ;; esac"
                                  (funcall f "emacs.log") (funcall f "running")))
    (tty-bin-test--script (expand-file-name "infocmp" pathdir)
                          (format "echo \"$*\" >> %s\n[ -f %s ] && exit 1\nexit 0" (funcall f "infocmp.log") (funcall f "no-terminfo")))
    (tty-bin-test--script (expand-file-name "kitty" pathdir)
                          (format "printf '%%s\\037' \"$@\" >> %s; echo >> %s" (funcall f "kitty.log") (funcall f "kitty.log")))))

(defconst tty-bin-test--defaults
  '(("DISPLAY" . ":99") ("WAYLAND_DISPLAY") ("SSH_CONNECTION") ("SSH_TTY") ("VTE_VERSION") ("TERM_PROGRAM")
    ("TERM" . "xterm-256color") ("DRGNX_EMACS") ("DRGNX_OPEN_WAIT" . "5"))
  "What a test starts from: a graphical, local terminal; a cons without a value unsets the variable.")

(defmacro tty-bin-test--with (&rest body)
  "BODY with DIR (a temp directory, deleted afterwards), PATHDIR (the fakes), and `call' (a function: ARGS and
optionally :env (an alist like `tty-bin-test--defaults' overriding it) → (EXIT . OUTPUT), stderr included)."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "drgnx-ttybin" t))
          (pathdir (expand-file-name "path" dir)))
     (make-directory pathdir)
     (make-directory (expand-file-name "config" dir))
     (tty-bin-test--fakes dir pathdir)
     (unwind-protect
         (cl-flet ((call (args &optional env)
                     (let* ((merged (append env (seq-remove (lambda (d) (assoc (car d) env)) tty-bin-test--defaults)))
                            (process-environment
                             (append (mapcar (lambda (e) (if (cdr e) (concat (car e) "=" (cdr e)) (car e))) merged)
                                     (list (concat "HOME=" dir) (concat "DRGNX_CONFIG_DIR=" dir "/config")
                                           (concat "XDG_STATE_HOME=" dir "/state")
                                           (concat "DRGNX_SERVER_NAME=" tty-bin-test--server)
                                           (concat "PATH=" pathdir ":/usr/bin:/bin"))
                                     process-environment))
                            (default-directory (file-name-as-directory dir)))
                       (with-temp-buffer (cons (apply #'call-process tty-bin-test--bin nil t nil args) (buffer-string))))))
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
      (should (eql 0 (car (call '("open" "dir") env))))      ; DISPLAY is set: ssh wins
      (should (member "-t" (car (last (tty-bin-test--calls dir)))))
      (should-not (seq-find (lambda (c) (member "-c" c)) (tty-bin-test--calls dir))))))

(ert-deftest drgnx-bin/open-without-a-display-uses-the-terminal ()
  (skip-unless (eq system-type 'gnu/linux))
  (tty-bin-test--with
    (tty-bin-test--touch dir "running")
    (should (eql 0 (car (call '("open" "dir") '(("DISPLAY") ("WAYLAND_DISPLAY"))))))
    (should (member "-t" (car (last (tty-bin-test--calls dir)))))
    ;; one display of either kind is enough to stay graphical
    (delete-file (expand-file-name "client.log" dir))
    (tty-bin-test--touch dir "gui")
    (should (eql 0 (car (call '("open" "dir") '(("DISPLAY") ("WAYLAND_DISPLAY" . "wayland-0"))))))
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

(ert-deftest drgnx-bin/paths-with-spaces-and-quotes-reach-the-form ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running")
    (let ((folder (expand-file-name "My \"Project\"" dir)) (file (expand-file-name "café.py" dir)))
      (make-directory folder)
      (should (eql 0 (car (call (list "-t" "My \"Project\"" "café.py")))))
      (let ((form (tty-bin-test--form (car (last (tty-bin-test--calls dir))))))
        (should (equal (read form)
                       `(progn (find-file ,file) (drgnx-session-open-folder ,folder))))
        (should (string-search "My \\\"Project\\\"" form))))))

(ert-deftest drgnx-bin/open-t-in-a-capable-terminal-when-opted-in ()
  (tty-bin-test--with
    (tty-bin-test--touch dir "running")
    (write-region "(\"kitty\" \"--\")\n" nil (expand-file-name "capable" dir))
    (make-directory (expand-file-name "proj" dir))
    (should (equal (call '("-t" "proj") '(("VTE_VERSION" . "7600"))) '(0 . "")))
    ;; the new terminal runs the client; this one does not
    (let ((deadline (+ (float-time) 10)))
      (while (and (null (tty-bin-test--calls dir "kitty.log")) (< (float-time) deadline)) (sleep-for 0.05)))
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
      (tty-bin-test--script (expand-file-name "emacs" pathdir)
                            (format "printf '%%s\\n' \"$@\" > %s\ngrep -E '^SigIgn:' /proc/$$/status >> %s" seen seen))
      (should (eql 0 (car (call '("test" "--tty")))))
      (let ((lines (split-string (tty-bin-test--slurp seen) "\n" t)))
        (should (equal (seq-take (reverse (seq-take lines (- (length lines) 1))) 3)
                       (list (expand-file-name "test/tty" tty-bin-test--root) "drgnx-run-ert-batch" "-f")))
        ;; SIGPIPE is signal 13: bit 12 of the mask, 0x1000
        (let ((mask (string-to-number (car (last (split-string (car (last lines)))) ) 16)))
          (should (/= 0 (logand mask #x1000))))))))

(ert-deftest drgnx-bin/container-tty-builds-and-runs-the-tty-image ()
  (tty-bin-test--with
    (let ((log (expand-file-name "rt.log" dir)))
      (tty-bin-test--script (expand-file-name "fake-rt" dir) (format "echo \"$*\" >> %s" log))
      (dolist (case '((nil "45") (("--fedora" "44") "44")))
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
      (should (eql 2 (car (call '("test" "--container" "--tty" "--fedora" "43") `(("DRGNX_CONTAINER" . ,(expand-file-name "fake-rt" dir)))))))
      (should (eql 2 (car (call '("test" "--container" "--fedora" "44") `(("DRGNX_CONTAINER" . ,(expand-file-name "fake-rt" dir))))))))))

(ert-deftest drgnx-bin/the-tty-workflow-runs-both-fedoras-like-the-gui-one ()
  (let ((yml (tty-bin-test--slurp (expand-file-name ".github/workflows/tty.yml" tty-bin-test--root)))
        (gui (tty-bin-test--slurp (expand-file-name ".github/workflows/gui.yml" tty-bin-test--root))))
    (skip-unless (not (string-empty-p yml)))
    (dolist (s '("schedule:" "workflow_dispatch:" "fedora: [44, 45]" "bin/drgnx test --container --tty --fedora ${{ matrix.fedora }}"
                 "permissions:\n  contents: read" "persist-credentials: false"))
      (should (string-search s yml)))
    ;; the checkout action is the one gui.yml pins, by hash
    (let ((pin (and (string-match "uses: \\(actions/checkout@[0-9a-f]\\{40\\}\\)" gui) (match-string 1 gui))))
      (should pin)
      (should (string-search pin yml)))))

(provide 'tty-bin-test)
;;; tty-bin-test.el ends here
