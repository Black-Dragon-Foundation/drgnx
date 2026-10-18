;;; harness-test.el --- tty tier: the tmux harness itself is sound -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.
(require 'ert)
(require 'drgnx-tty-session)

(defun drgnx-tty-harness-test--wait-file (file size &optional timeout)
  "Wait until FILE has SIZE bytes (at most TIMEOUT s, default 5); its bytes, or what arrived."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (< (or (file-attribute-size (file-attributes file)) -1) size) (< (float-time) deadline))
      (sleep-for 0.05))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (when (file-exists-p file) (insert-file-contents-literally file))
      (buffer-string))))

(ert-deftest drgnx-tty-harness/raw-bytes-arrive-unchanged ()
  (let* ((bytes (concat "\e[112;6u" "\e[27;6;80~" "\e[<0;10;5M\e[<0;10;5m"
                        "\e[200~" (encode-coding-string "é" 'utf-8) "\e[201~"
                        (apply #'unibyte-string (number-sequence 1 #x7f))))
         (n (length bytes)))
    (should-not (multibyte-string-p bytes))
    (drgnx-tty-session-with (s :command (format "stty raw -echo -iexten && printf READY && head -c %d > bytes; sleep 30"
                                                n))
      (drgnx-tty-session-wait-screen s "READY")
      (drgnx-tty-session-send s bytes)
      (should (equal (drgnx-tty-harness-test--wait-file (expand-file-name "bytes" (plist-get s :run)) n)
                     bytes)))))

(ert-deftest drgnx-tty-harness/capture-is-stable ()
  (drgnx-tty-session-with (s :config "minimal")
    (drgnx-tty-session-wait-screen s "\\*scratch\\*")
    (let ((a (drgnx-tty-session-quiet s)))
      (should (string-match-p "\\*scratch\\*" a))
      (should (equal a (drgnx-tty-session-screen s))))))

(ert-deftest drgnx-tty-harness/the-inner-emacs-answers-on-its-socket ()
  (drgnx-tty-session-with (s :config "minimal")
    (should (eq (drgnx-tty-session-eval s '(display-graphic-p)) nil))
    (should (eq (drgnx-tty-session-eval s '(frame-width)) 120))
    (should (equal (drgnx-tty-session-eval s '(tty-type)) "tmux-256color"))))

(ert-deftest drgnx-tty-harness/a-daemon-and-its-terminal-client ()
  (drgnx-tty-session-with (s :config "minimal" :daemon t)
    ;; a tty frame of the pane's 120x40, its windows on 39 lines above the minibuffer's
    (should (equal (drgnx-tty-session-eval
                    s '(let ((f (seq-find (lambda (f) (frame-parameter f 'client)) (frame-list))))
                         (list (framep f) (display-graphic-p f) (frame-width f) (frame-height f)
                               (window-total-height (frame-root-window f)))))
                   '(t nil 120 40 39)))
    ;; the client's terminal is the pane: what it shows is on screen
    (drgnx-tty-session-wait-screen s "\\*scratch\\*")
    ;; a second client is another window of the same server, with its own target
    (let ((c (drgnx-tty-session-client s :env '("TERM=xterm-256color"))))
      (should-not (equal (plist-get c :target) (plist-get s :target)))
      (should (equal (drgnx-tty-session-eval
                      s '(seq-count (lambda (f) (frame-parameter f 'client)) (frame-list)))
                     2))
      (should (equal (drgnx-tty-session-eval
                      s '(sort (mapcar (lambda (f) (tty-type (frame-terminal f)))
                                       (seq-filter (lambda (f) (frame-parameter f 'client))
                                                   (frame-list)))
                               #'string<))
                     '("tmux-256color" "xterm-256color")))
      (drgnx-tty-session-wait-screen c "\\*scratch\\*"))
    ;; emacsclient arguments: a file to visit
    (let ((file (expand-file-name "note.txt" (plist-get s :run))))
      (drgnx-ui--write file "hello from a file\n")
      (drgnx-tty-session-wait-screen (drgnx-tty-session-client s :args (list file)) "hello from a file"))))

(ert-deftest drgnx-tty-harness/never-the-users-tmux-or-home ()
  ;; only our own server's name is looked for in the default socket dir: the user's tmux may start meanwhile
  (let ((default-dir (expand-file-name (format "tmux-%d" (user-uid)) (or (getenv "TMUX_TMPDIR") "/tmp")))
        run name)
    (drgnx-tty-session-with (s :config "minimal")
      (setq run (plist-get s :run) name (plist-get s :name))
      (should (string-prefix-p (file-name-as-directory run) (plist-get s :tmux)))
      (should (file-exists-p (plist-get s :tmux)))
      (should-not (file-exists-p (expand-file-name name default-dir)))
      (let ((home (drgnx-tty-session-eval s '(getenv "HOME"))))
        (should (string-prefix-p (file-name-as-directory run) home))
        (should-not (equal (directory-file-name home)
                           (directory-file-name (expand-file-name (concat "~" (user-login-name))))))))
    (should-not (file-exists-p run))
    (should-not (file-exists-p (expand-file-name name default-dir)))))

(defun drgnx-tty-harness-test--tmux-argvs (fn)
  "Call FN; every argv it ran (call-process, make-process) that runs tmux."
  (let (argvs)
    (cl-flet ((note (argv) (when (member "tmux" argv) (push argv argvs))))
      (let ((cp (lambda (program _infile _dest _display &rest args) (note (cons program args))))
            (mp (lambda (&rest plist) (note (plist-get plist :command)))))
        (advice-add 'call-process :before cp)
        (advice-add 'make-process :before mp)
        (unwind-protect (funcall fn)
          (advice-remove 'call-process cp)
          (advice-remove 'make-process mp))))
    (nreverse argvs)))

(ert-deftest drgnx-tty-harness/every-tmux-call-names-our-server ()
  (let (name cmdline)
    (let ((argvs (drgnx-tty-harness-test--tmux-argvs
                  (lambda ()
                    (drgnx-tty-session-with (s :config "minimal" :daemon t)
                      (setq name (plist-get s :name))
                      (drgnx-tty-session-screen s)
                      (drgnx-tty-session-key s "C-l")
                      (drgnx-tty-session-tmux s "list-windows")
                      ;; the server itself, as it runs: no config file, bounded by timeout
                      (setq cmdline (string-trim (cdr (drgnx-ui--run "pgrep" "-af" "--" (format "-L %s " name))))))))))
      (should (> (length argvs) 5))
      (dolist (argv argvs)
        (let ((tail (member "tmux" argv)))
          (should (equal (seq-take (cdr tail) 4) (list "-L" name "-f" "/dev/null")))))
      (should (string-match-p (format "timeout -s TERM -k 10 [0-9]+ tmux -L %s -f /dev/null -D" (regexp-quote name))
                              cmdline)))))

(ert-deftest drgnx-tty-harness/the-server-ends-at-its-budget ()
  (let ((process-environment (cons "DRGNX_TTY_MAX_RUNTIME=2" process-environment)))
    (drgnx-tty-session-with (s :command "sleep 60")
      (let ((pattern (format "(%s/|-L %s )" (regexp-quote (plist-get s :run)) (regexp-quote (plist-get s :name))))
            (deadline (+ (float-time) 20)))
        (should (eq 0 (car (drgnx-ui--run "pgrep" "-f" "--" pattern))))
        (while (and (eq 0 (car (drgnx-ui--run "pgrep" "-f" "--" pattern))) (< (float-time) deadline))
          (sleep-for 0.2))
        (should-not (eq 0 (car (drgnx-ui--run "pgrep" "-f" "--" pattern))))
        (should-not (drgnx-tty-session--pane-alive-p s))))))

(defun drgnx-tty-harness-test--dead-pid ()
  (let ((p (make-process :name "drgnx-tty-dead" :command '("true") :noquery t)))
    (while (process-live-p p) (accept-process-output p 0.05))
    (process-id p)))

(ert-deftest drgnx-tty-harness/a-dead-owner-s-session-is-swept ()
  ;; a runner SIGKILLed mid-test leaves its tmux server, its Emacs and its run dir, in its own temp state root
  (let* ((other-root (make-temp-file "drgnx-tty-other" t))
         (stale (let ((process-environment (cons (concat "DRGNX_UI_STATE=" other-root) process-environment))
                      (drgnx-tty-session--owner (drgnx-tty-harness-test--dead-pid)))
                  (drgnx-tty-session-start :config "minimal")))
         (pattern (format "(%s/|-L %s )" (regexp-quote (plist-get stale :run)) (regexp-quote (plist-get stale :name)))))
    (unwind-protect
        (progn
          ;; …and no hook of its runner ever stops it
          (setq drgnx-tty-session--live (delq stale drgnx-tty-session--live))
          (should (eq 0 (car (drgnx-ui--run "pgrep" "-f" "--" pattern))))
          (should (file-directory-p (plist-get stale :run)))
          (drgnx-tty-session-with (s :command "true")
            (should (plist-get s :target))
            (should-not (eq 0 (car (drgnx-ui--run "pgrep" "-f" "--" pattern))))
            (should-not (file-exists-p (plist-get stale :run)))
            (should-not (file-exists-p (file-name-directory (plist-get stale :socket))))))
      (let ((process-environment (cons (concat "DRGNX_UI_STATE=" other-root) process-environment)))
        (drgnx-tty-session-stop stale))
      (delete-directory other-root t))))

(ert-deftest drgnx-tty-harness/the-key-profile-is-the-session-s ()
  (drgnx-tty-session-with (s :keys 'emacs)
    (should (equal (drgnx-tty-session-wait s '(and (boundp 'drgnx-keys-last) (plist-get drgnx-keys-last :layers)) 20)
                   '((emacs app editing window))))))

(ert-deftest drgnx-tty-harness/flags-resize-keys-and-clipboard ()
  (drgnx-tty-session-with (s :config "minimal")
    (drgnx-tty-session-wait-screen s "\\*scratch\\*")
    ;; the pane's mouse mode follows what Emacs asks of its terminal
    (should (equal (plist-get (drgnx-tty-session-pane-flags s) :mouse-sgr) 0))
    (drgnx-tty-session-eval s '(xterm-mouse-mode 1))
    (let ((deadline (+ (float-time) 5)))
      (while (and (/= 1 (plist-get (drgnx-tty-session-pane-flags s) :mouse-sgr)) (< (float-time) deadline))
        (sleep-for 0.05)))
    (should (equal (plist-get (drgnx-tty-session-pane-flags s) :mouse-sgr) 1))
    (should (string-match-p "\\`\\(VT10x\\|Ext [0-9]\\)\\'" (plist-get (drgnx-tty-session-pane-flags s) :key-mode)))
    ;; resizing reaches the frame
    (drgnx-tty-session-resize s "80x24")
    (should (equal (drgnx-tty-session-wait s '(and (= (frame-width) 80) (list (frame-width) (frame-height))))
                   '(80 24)))
    ;; keys: text (as UTF-8), RET, a named key, a chord
    (drgnx-tty-session-send s "é1")
    (drgnx-tty-session-key s "RET")
    (drgnx-tty-session-send s "2")
    (should (equal (drgnx-tty-session-wait s '(with-current-buffer "*scratch*"
                                                (and (string-suffix-p "2" (buffer-string)) (buffer-string))))
                   "é1\n2"))
    (drgnx-tty-session-key s "<up>")
    (should (eq (drgnx-tty-session-wait s '(with-current-buffer "*scratch*" (and (= (line-number-at-pos) 1) 1))) 1))
    (drgnx-tty-session-key s "C-x")
    (drgnx-tty-session-key s "b")
    (should (string-prefix-p "Switch to buffer" (drgnx-tty-session-wait s '(minibuffer-prompt))))
    (drgnx-tty-session-key s "C-g")
    (drgnx-tty-session-wait s '(not (active-minibuffer-window)))
    ;; an OSC 52 copy lands in the server's paste buffer
    (should-not (drgnx-tty-session-clipboard s))
    (drgnx-tty-session-eval s '(send-string-to-terminal (concat "\e]52;c;" (base64-encode-string "hello") "\a")))
    (let ((deadline (+ (float-time) 5)))
      (while (and (not (drgnx-tty-session-clipboard s)) (< (float-time) deadline)) (sleep-for 0.05)))
    (should (equal (drgnx-tty-session-clipboard s) "hello"))))

;;; harness-test.el ends here
