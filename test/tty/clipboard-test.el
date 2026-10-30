;;; clipboard-test.el --- tty tier: a copy reaches the terminal's clipboard (OSC 52); what a paste does -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  The tmux of
;; the harness has `set-clipboard on': an OSC 52 copy becomes its paste buffer (`drgnx-tty-session-clipboard').
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-tty-session)

(defconst drgnx-tty-clip-test--log
  '(progn
     (defvar kx-writes nil)
     (setq kx-writes nil)
     (advice-add 'send-string-to-terminal :before
                 (lambda (string &optional _terminal) (push string kx-writes))
                 '((name . kx-log-writes)))
     t)
  "A form, in the inner Emacs: log every string written to the terminal in `kx-writes'.")

(defun drgnx-tty-clip-test--ready (sess)
  "Wait until SESS's Emacs has set its terminal up (the workbench is on the screen); log what it writes."
  (drgnx-tty-session-wait-screen sess "\\*scratch\\* ×" 20)
  (drgnx-tty-session-eval sess drgnx-tty-clip-test--log))

(defun drgnx-tty-clip-test--copy (sess text)
  "Select TEXT in a buffer of SESS's Emacs and copy it with `kill-ring-save', the profile's copy command."
  (drgnx-tty-session-eval
   sess `(with-temp-buffer
           (insert ,text)
           (kill-ring-save (point-min) (point-max))
           t)))

(ert-deftest drgnx-tty-clip/copy-reaches-the-terminal-clipboard ()
  (drgnx-tty-session-with (s :keys "vscode")
    (drgnx-tty-clip-test--ready s)
    (should (drgnx-tty-session-eval s '(plist-get (terminal-parameter nil 'drgnx-tty-caps) :osc52)))
    (should-not (drgnx-tty-session-clipboard s))
    (drgnx-tty-clip-test--copy s "hello drgnx")
    (drgnx-tty-session-wait s '(and (member "hello drgnx" (list (car kill-ring))) t))
    (drgnx-test-wait (lambda () (drgnx-tty-session-clipboard s)) :secs 5 :what "the clipboard")
    (should (equal (drgnx-tty-session-clipboard s) "hello drgnx"))))

(ert-deftest drgnx-tty-clip/paste-key-yanks-the-last-copy-without-asking ()
  (drgnx-tty-session-with (s :keys "vscode")
    (drgnx-tty-clip-test--ready s)
    (drgnx-tty-clip-test--copy s "hello drgnx")
    (drgnx-tty-session-eval s '(progn (switch-to-buffer (get-buffer-create "*paste*")) t))
    ;; the VS Code profile's own paste key
    (should (eq (drgnx-tty-session-eval s '(key-binding (kbd "C-v"))) 'drgnx-editing-paste))
    (drgnx-tty-session-key s "C-v")
    (should (equal (drgnx-tty-session-wait s '(with-current-buffer "*paste*"
                                                (and (> (buffer-size) 0) (buffer-string))))
                   "hello drgnx"))
    ;; the terminal's clipboard was never asked for
    (should-not (drgnx-tty-session-eval s '(seq-find (lambda (w) (string-match-p "\e\\]52;[a-z]*;\\?" w)) kx-writes)))))

(ert-deftest drgnx-tty-clip/ctrl-c-copies-to-the-terminal-clipboard ()
  ;; The VS Code profile end to end: select with Shift+Right, press C-c (byte 0x03), the text is on the clipboard.
  (drgnx-tty-session-with (s :keys "vscode")
    (drgnx-tty-clip-test--ready s)
    (drgnx-tty-session-eval s '(progn (switch-to-buffer (get-buffer-create "*copy*"))
                                      (insert "hello drgnx")
                                      (goto-char (point-min))
                                      t))
    (should-not (drgnx-tty-session-clipboard s))
    (dotimes (_ 5) (drgnx-tty-session-send s "\e[1;2C"))     ; S-<right>
    (drgnx-tty-session-wait s '(with-current-buffer "*copy*" (and (use-region-p) (= (- (region-end) (region-beginning)) 5))))
    (drgnx-tty-session-send s "\C-c")
    (drgnx-tty-session-wait s '(equal (car kill-ring) "hello"))
    (drgnx-test-wait (lambda () (drgnx-tty-session-clipboard s)) :secs 5 :what "the clipboard")
    (should (equal (drgnx-tty-session-clipboard s) "hello"))
    (should (equal (drgnx-tty-session-eval s '(with-current-buffer "*copy*" (buffer-string))) "hello drgnx"))
    (should-not (drgnx-tty-session-eval s '(with-current-buffer "*copy*" (use-region-p))))))

(defun drgnx-tty-clip-test--select-five (sess)
  "In SESS, a buffer *sel* with `hello drgnx', its first five characters selected with Shift+Right."
  (drgnx-tty-session-eval sess '(progn (switch-to-buffer (get-buffer-create "*sel*"))
                                       (insert "hello drgnx")
                                       (goto-char (point-min))
                                       t))
  (dotimes (_ 5) (drgnx-tty-session-send sess "\e[1;2C"))
  (drgnx-tty-session-wait sess '(with-current-buffer "*sel*" (and (use-region-p) (= (- (region-end) (region-beginning)) 5)))))

(ert-deftest drgnx-tty-clip/c-x-alone-cuts-after-the-delay ()
  (drgnx-tty-session-with (s :keys "vscode")
    (drgnx-tty-clip-test--ready s)
    (drgnx-tty-clip-test--select-five s)
    (drgnx-tty-session-send s "\C-x")
    (drgnx-tty-session-wait s '(equal (car kill-ring) "hello"))
    (should (equal (drgnx-tty-session-eval s '(with-current-buffer "*sel*" (buffer-string))) " drgnx"))))

(ert-deftest drgnx-tty-clip/c-x-then-a-key-is-the-prefix-and-the-text-stays ()
  ;; C-x h (mark the whole buffer) typed at once: nothing is cut.
  (drgnx-tty-session-with (s :keys "vscode")
    (drgnx-tty-clip-test--ready s)
    (drgnx-tty-clip-test--select-five s)
    (drgnx-tty-session-send s "\C-xh")
    (drgnx-tty-session-wait s '(with-current-buffer "*sel*" (and (use-region-p) (= (- (region-end) (region-beginning)) 11))))
    (sleep-for 0.6)                                          ; past the delay: still no cut
    (should (equal (drgnx-tty-session-eval s '(with-current-buffer "*sel*" (buffer-string))) "hello drgnx"))
    (should-not (drgnx-tty-session-eval s '(car kill-ring)))))

(ert-deftest drgnx-tty-clip/bracketed-paste-arrives-as-text ()
  (drgnx-tty-session-with (s :keys "vscode")
    (drgnx-tty-clip-test--ready s)
    (drgnx-tty-session-eval s '(progn (switch-to-buffer (get-buffer-create "*paste*"))
                                      (defvar kx-commands nil)
                                      (add-hook 'post-command-hook (lambda () (push this-command kx-commands)))
                                      t))
    (drgnx-tty-session-send s "\e[200~pasted text\e[201~")
    (should (equal (drgnx-tty-session-wait s '(with-current-buffer "*paste*"
                                                (and (> (buffer-size) 0) (buffer-string))))
                   "pasted text"))
    ;; one command, the paste itself (Emacs's `xterm-paste' yanks it): none of its letters ran as a key
    (should (equal (drgnx-tty-session-eval s 'kx-commands) '(yank)))))

;;; clipboard-test.el ends here
