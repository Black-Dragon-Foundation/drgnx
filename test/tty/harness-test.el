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
      (drgnx-tty-session-wait-screen c "\\*scratch\\*"))))

(ert-deftest drgnx-tty-harness/never-the-users-tmux-or-home ()
  (let* ((default-dir (expand-file-name (format "tmux-%d" (user-uid)) (or (getenv "TMUX_TMPDIR") "/tmp")))
         (before (and (file-directory-p default-dir) (directory-files default-dir)))
         run)
    (drgnx-tty-session-with (s :config "minimal")
      (setq run (plist-get s :run))
      (should (string-prefix-p (file-name-as-directory run) (plist-get s :tmux)))
      (should (file-exists-p (plist-get s :tmux)))
      (let ((home (drgnx-tty-session-eval s '(getenv "HOME"))))
        (should (string-prefix-p (file-name-as-directory run) home))
        (should-not (equal (directory-file-name home)
                           (directory-file-name (expand-file-name (concat "~" (user-login-name))))))))
    (should-not (file-exists-p run))
    (should (equal (and (file-directory-p default-dir) (directory-files default-dir)) before))))

;;; harness-test.el ends here
