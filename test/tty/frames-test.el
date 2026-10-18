;;; frames-test.el --- tty tier: a terminal window is a workbench; EDITOR frames; what a terminal can do, asked once -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.
(require 'ert)
(require 'drgnx-tty-session)

(defconst drgnx-tty-frames-test--clients
  '(seq-filter (lambda (f) (and (frame-live-p f) (frame-parameter f 'client))) (frame-list))
  "A form, in the inner daemon: its client frames, newest first.")

(defun drgnx-tty-frames-test--in-client (sess form)
  "FORM's value in SESS's daemon with its newest client frame selected."
  (drgnx-tty-session-eval sess `(with-selected-frame (car ,drgnx-tty-frames-test--clients) ,form)))

(defun drgnx-tty-frames-test--workbench (sess eval)
  "SESS's screen shows the workbench: the tab line, the status bar (the mode line), the main role, and the
Explorer once the sidebar is shown.  EVAL evaluates a form in the frame on that screen."
  (drgnx-tty-session-wait-screen sess "\\*scratch\\* ×" 20)            ; the editor's tab line
  (drgnx-tty-session-wait-screen sess "\\*scratch\\* +All +L[0-9]")    ; the status bar
  (should (eq (funcall eval '(drgnx-frame-role)) 'main))
  (should (eq (funcall eval '(plist-get (terminal-parameter nil 'drgnx-tty-caps) :id)) 'tmux))
  (funcall eval '(progn (drgnx-wb-show-sidebar) t))
  (should (funcall eval '(and (drgnx-wb--dock-windows) t)))
  (drgnx-tty-session-wait-screen sess "EXPLORER"))

(ert-deftest drgnx-tty-frames/emacs-nw-gets-the-workbench ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-frames-test--workbench s (lambda (form) (drgnx-tty-session-eval s form)))))

(ert-deftest drgnx-tty-frames/a-daemon-client-gets-the-workbench ()
  (drgnx-tty-session-with (s :daemon t :size "120x40")
    (drgnx-tty-frames-test--workbench s (lambda (form) (drgnx-tty-frames-test--in-client s form)))
    ;; the daemon's own frame is no window of the workbench
    (should (equal (drgnx-tty-session-eval s '(mapcar (lambda (f) (frame-parameter f 'drgnx-frame-role))
                                                      (seq-remove (lambda (f) (frame-parameter f 'client))
                                                                  (frame-list))))
                   '(nil)))))

(ert-deftest drgnx-tty-frames/an-editor-frame-for-emacsclient-t-file ()
  (drgnx-tty-session-with (s :daemon t)
    (let ((file (expand-file-name "COMMIT_EDITMSG" (plist-get s :run))))
      (drgnx-ui--write file "Terminal frames are workbench frames\n")
      ;; the first client has its sidebar shown: it is a workbench
      (drgnx-tty-frames-test--in-client s '(progn (drgnx-wb-show-sidebar) t))
      (let ((c (drgnx-tty-session-client s :args (list file))))
        (drgnx-tty-session-wait-screen c "Terminal frames are workbench frames")
        (should (equal (drgnx-tty-frames-test--in-client
                        s '(list (frame-parameter nil 'drgnx-tty-editor-only)
                                 (seq-filter (lambda (w) (memq (window-parameter w 'drgnx-role) '(dock panel right)))
                                             (window-list nil 'nomini))
                                 (buffer-name (window-buffer (selected-window)))))
                       '(t nil "COMMIT_EDITMSG")))
        ;; the workbench client is not editor-only, and keeps its sidebar
        (should (equal (drgnx-tty-session-eval
                        s `(mapcar (lambda (f) (list (frame-parameter f 'drgnx-tty-editor-only)
                                                     (and (drgnx-wb--dock-windows f) t)))
                                   ,drgnx-tty-frames-test--clients))
                       '((t nil) (nil t))))
        ;; Close Tab ends the edit: the client returns, as `code --wait' does
        (drgnx-tty-session-eval s `(let ((f (car ,drgnx-tty-frames-test--clients)))
                                     (with-selected-frame f
                                       (select-window (get-buffer-window "COMMIT_EDITMSG" f))
                                       (drgnx-chrome-close-tab))
                                     t))
        (drgnx-tty-session-wait-screen c "\\[emacsclient exited 0\\]" 10)
        (should (= (drgnx-tty-session-eval s `(length ,drgnx-tty-frames-test--clients)) 1))))))

(defconst drgnx-tty-frames-test--count-queries
  '(progn
     (defvar kx-queries nil)
     (setq kx-queries nil)
     (advice-add 'send-string-to-terminal :before
                 (lambda (string &optional _terminal)
                   (when (string-match-p "\\`\e\\[\\(>[0-9]*[cq]\\|\\?u\\)" string) (push string kx-queries)))
                 '((name . kx-count-queries)))
     t)
  "A form, in the inner daemon: count the terminal queries sent from now on (DA2, XTVERSION, kkp) in
`kx-queries'.")

(ert-deftest drgnx-tty-frames/caps-are-cached-per-terminal ()
  (drgnx-tty-session-with (s :daemon t)
    ;; the first client's terminal was asked, and answered (tmux answers XTVERSION)
    (should (stringp (drgnx-tty-session-wait s `(plist-get (terminal-parameter (frame-terminal (car ,drgnx-tty-frames-test--clients))
                                                                               'drgnx-tty-caps)
                                                           :version))))
    (drgnx-tty-session-eval s drgnx-tty-frames-test--count-queries)
    ;; a second client of the same terminal asks nothing, and has the same capabilities
    (drgnx-tty-session-client s)
    (should (equal (drgnx-tty-session-eval s 'kx-queries) nil))
    (should (equal (drgnx-tty-session-eval s `(seq-uniq (mapcar (lambda (f) (terminal-parameter (frame-terminal f) 'drgnx-tty-caps))
                                                                ,drgnx-tty-frames-test--clients)))
                   (list (drgnx-tty-frames-test--in-client s '(terminal-parameter nil 'drgnx-tty-caps)))))
    ;; the report has an entry per client's terminal: neither replaced the other's
    (should (equal (drgnx-tty-session-eval
                    s `(list (sort (mapcar (lambda (f) (terminal-name (frame-terminal f))) ,drgnx-tty-frames-test--clients)
                                   #'string<)
                             (sort (mapcar #'car (plist-get (with-temp-buffer
                                                              (insert-file-contents
                                                               (expand-file-name "terminal-report.eld" (drgnx-state-dir)))
                                                              (read (current-buffer)))
                                                            :terminals))
                                   #'string<)))
                   (let ((ttys (drgnx-tty-session-eval s `(sort (mapcar (lambda (f) (terminal-name (frame-terminal f)))
                                                                        ,drgnx-tty-frames-test--clients)
                                                                #'string<))))
                     (should (= (length ttys) 2))
                     (list ttys ttys))))
    ;; a terminal of another kind is asked (the count sees queries)
    (drgnx-tty-session-client s :env '("TERM=screen-256color"))
    (should (drgnx-tty-session-eval s 'kx-queries))))

(ert-deftest drgnx-tty-frames/a-silent-terminal-does-not-freeze-the-daemon ()
  (drgnx-tty-session-with (s :daemon t)
    (let ((limit (1+ (drgnx-tty-session-eval s 'xterm-query-timeout)))
          (slowest 0)
          (deadline (+ (float-time) 15))
          frame)
      (drgnx-tty-session-pty-start :daemon-sess s)
      ;; every call answers in time while the silent terminal's frame is made and asked
      (while (and (not frame) (< (float-time) deadline))
        (let ((t0 (float-time)))
          (setq frame (drgnx-tty-session-eval
                       s '(seq-find (lambda (f) (equal (tty-type (frame-terminal f)) "xterm-256color")) (frame-list))
                       (+ limit 5)))
          (setq slowest (max slowest (- (float-time) t0))))
        (unless frame (sleep-for 0.05)))
      (should frame)
      (should (< slowest limit))
      ;; it got its capabilities, without an answer
      (should (equal (drgnx-tty-session-wait
                      s '(when-let* ((f (seq-find (lambda (f) (equal (tty-type (frame-terminal f)) "xterm-256color"))
                                                  (frame-list))))
                           (let ((caps (terminal-parameter (frame-terminal f) 'drgnx-tty-caps)))
                             (and caps (list (plist-get caps :id) (plist-get caps :version))))))
                     '(unknown nil))))))

(ert-deftest drgnx-tty-frames/a-killed-terminal-leaves-the-daemon-well ()
  (drgnx-tty-session-with (s :daemon t :keys 'emacs)
    (let* ((ttys '(mapcar (lambda (f) (terminal-name (frame-terminal f))) (frame-list)))
           (before (drgnx-tty-session-eval s ttys))
           (c (drgnx-tty-session-client s))
           (tty (car (seq-difference (drgnx-tty-session-eval s ttys) before)))
           (problems (drgnx-tty-session-eval s 'drgnx-hooks-problems))
           (messages (drgnx-tty-session-eval s '(with-current-buffer "*Messages*" (point-max)))))
      (should tty)
      (drgnx-tty-session-wait-screen c "\\*scratch\\*")
      ;; a prompt open in that terminal
      (drgnx-tty-session-key c "C-x")
      (drgnx-tty-session-key c "b")
      (drgnx-tty-session-wait s '(and (active-minibuffer-window) t))
      ;; the terminal goes away (the SSH connection drops, the pane is killed)
      (drgnx-tty-session-tmux s "kill-window" "-t" (plist-get c :target))
      (drgnx-tty-session-wait s `(not (seq-find (lambda (f) (equal (terminal-name (frame-terminal f)) ,tty)) (frame-list)))
                              10)
      (should (eq (drgnx-tty-session-eval s t) t))
      (should (= (drgnx-tty-session-eval s `(length ,drgnx-tty-frames-test--clients)) 1))
      (should (equal (drgnx-tty-session-eval s 'drgnx-hooks-problems) problems))
      (let ((new (drgnx-tty-session-eval s `(with-current-buffer "*Messages*"
                                              (buffer-substring-no-properties (min ,messages (point-max)) (point-max))))))
        (should-not (string-match-p "[Ee]rror" new)))
      ;; and keeps answering a while later (nothing errors in a loop)
      (sleep-for 1)
      (should (eq (drgnx-tty-session-eval s t) t))
      (should (equal (drgnx-tty-session-eval s 'drgnx-hooks-problems) problems)))))

;;; frames-test.el ends here
