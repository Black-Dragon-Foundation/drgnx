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

(defconst drgnx-tty-frames-test--docks-on-new-frames
  '(progn (add-hook 'server-after-make-frame-hook
                    (lambda () (drgnx-wb-show-sidebar) (drgnx-wb-area-show 'panel) (drgnx-wb-area-show 'right))
                    -50)
          t)
  "A form, in the inner daemon: every new client frame opens its sidebar, panel and right dock (as a user's
config may), before ui/terminal looks at it.")

(defconst drgnx-tty-frames-test--docks
  '(seq-filter (lambda (w) (memq (window-parameter w 'drgnx-role) '(dock panel right))) (window-list nil 'nomini))
  "A form: the selected frame's dock, panel and right-dock windows.")

(defun drgnx-tty-frames-test--editor-client (sess text)
  "Open COMMIT_EDITMSG holding TEXT in a new `emacsclient -t FILE' client of SESS; return (CLIENT . FILE)
once TEXT is on its screen."
  (let ((file (expand-file-name "COMMIT_EDITMSG" (plist-get sess :run))))
    (drgnx-ui--write file text)
    (let ((c (drgnx-tty-session-client sess :args (list file))))
      (drgnx-tty-session-wait-screen c (regexp-quote (string-trim text)))
      (cons c file))))

(ert-deftest drgnx-tty-frames/an-editor-frame-for-emacsclient-t-file ()
  (drgnx-tty-session-with (s :daemon t)
    (drgnx-tty-session-eval s drgnx-tty-frames-test--docks-on-new-frames)
    ;; a client without a file is a workbench: the docks open there
    (let ((w (drgnx-tty-session-client s)))
      (should (equal (drgnx-tty-frames-test--in-client
                      s `(sort (seq-uniq (mapcar (lambda (w) (symbol-name (window-parameter w 'drgnx-role)))
                                                 ,drgnx-tty-frames-test--docks))
                               #'string<))
                     '("dock" "panel" "right")))
      (let ((c (car (drgnx-tty-frames-test--editor-client s "Terminal frames are workbench frames\n"))))
        ;; the EDITOR client shows the editor only, and is never the main window
        (should (equal (drgnx-tty-frames-test--in-client
                        s `(list (frame-parameter nil 'drgnx-tty-editor-only) (length ,drgnx-tty-frames-test--docks)
                                 (buffer-name (window-buffer (selected-window))) (drgnx-frame-role)))
                       '(t 0 "COMMIT_EDITMSG" aux)))
        ;; the workbench clients keep theirs
        (should (equal (drgnx-tty-session-eval
                        s `(mapcar (lambda (f) (list (frame-parameter f 'drgnx-tty-editor-only)
                                                     (and (drgnx-wb--dock-windows f) t)))
                                   ,drgnx-tty-frames-test--clients))
                       '((t nil) (nil t) (nil nil))))
        ;; Close Tab ends the edit: the client returns, as `code --wait' does
        (drgnx-tty-session-eval s `(let ((f (car ,drgnx-tty-frames-test--clients)))
                                     (with-selected-frame f
                                       (select-window (get-buffer-window "COMMIT_EDITMSG" f))
                                       (drgnx-chrome-close-tab))
                                     t))
        (drgnx-tty-session-wait-screen c "\\[emacsclient exited 0\\]" 10)
        (should (= (drgnx-tty-session-eval s `(length ,drgnx-tty-frames-test--clients)) 2))
        (drgnx-tty-session-wait-screen w "EXPLORER")))))

(ert-deftest drgnx-tty-frames/closing-an-unsaved-editor-tab-asks-to-save ()
  (drgnx-tty-session-with (s :daemon t :keys 'vscode)
    (pcase-let ((`(,c . ,file) (drgnx-tty-frames-test--editor-client s "\n# Please enter the commit message\n")))
      (drgnx-tty-session-send c "Fix the frames")
      (drgnx-tty-session-wait s '(with-current-buffer "COMMIT_EDITMSG" (buffer-modified-p)))
      ;; Close Tab (C-w) on a changed file: asked, as VS Code and C-x # ask; the text is never dropped
      (drgnx-tty-session-key c "C-w" 'legacy)
      (drgnx-tty-session-wait-screen c "Save file .*COMMIT_EDITMSG")
      (should (drgnx-tty-session-eval s '(buffer-live-p (get-buffer "COMMIT_EDITMSG"))))
      (drgnx-tty-session-send c "y")
      (drgnx-tty-session-wait-screen c "\\[emacsclient exited 0\\]" 10)
      (should (string-prefix-p "Fix the frames" (with-temp-buffer (insert-file-contents file) (buffer-string)))))))

(ert-deftest drgnx-tty-frames/moving-an-editor-tab-does-not-end-the-edit ()
  (drgnx-tty-session-with (s :daemon t)
    (pcase-let ((`(,c . ,_) (drgnx-tty-frames-test--editor-client s "Moved, not closed\n")))
      ;; Move Editor into Next Group takes the tab out of this group (which keeps another tab): the edit goes on
      (drgnx-tty-frames-test--in-client s '(progn (set-window-parameter nil 'drgnx-tabs
                                                                        (list (get-buffer-create "kx-other")
                                                                              (current-buffer)))
                                                  (drgnx-groups-move-to-next)
                                                  t))
      (sleep-for 0.5)
      (should (drgnx-tty-session-eval s '(let ((b (get-buffer "COMMIT_EDITMSG")))
                                           (and b (buffer-local-value 'server-buffer-clients b) t))))
      (should-not (drgnx-tty-session-find c "emacsclient exited"))
      ;; C-x # still ends it
      (drgnx-tty-session-eval s '(with-current-buffer "COMMIT_EDITMSG" (server-edit) t))
      (drgnx-tty-session-wait-screen c "\\[emacsclient exited 0\\]" 10))))

(ert-deftest drgnx-tty-frames/a-client-made-while-a-prompt-is-open-is-set-up ()
  ;; the server skips `server-after-make-frame-hook' while the minibuffer is current: the client is set up anyway
  (drgnx-tty-session-with (s :daemon t :keys 'emacs)
    (drgnx-tty-session-key s "C-x")
    (drgnx-tty-session-key s "b")
    (drgnx-tty-session-wait s '(and (active-minibuffer-window) t))
    (let ((c (drgnx-tty-session-client s)))
      (drgnx-tty-session-wait-screen c "\\*scratch\\* ×")
      (should (drgnx-tty-frames-test--in-client s '(frame-parameter nil 'drgnx-tty-shown))))))

(ert-deftest drgnx-tty-frames/two-clients-at-once ()
  (drgnx-tty-session-with (s :daemon t)
    (let ((cmd (drgnx-tty-session--client-command s (drgnx-tty-session--env s) nil)))
      ;; both windows in one tmux call: the two clients connect together
      (drgnx-tty-session-tmux s "new-window" "-d" "-c" (plist-get s :run) cmd ";"
                              "new-window" "-d" "-c" (plist-get s :run) cmd)
      (drgnx-tty-session-wait s `(= (length ,drgnx-tty-frames-test--clients) 3) 30)
      (should (equal (drgnx-tty-session-wait
                      s `(let ((fs ,drgnx-tty-frames-test--clients))
                           (and (seq-every-p (lambda (f) (terminal-parameter (frame-terminal f) 'drgnx-tty-caps)) fs)
                                (list (seq-count (lambda (f) (eq (frame-parameter f 'drgnx-frame-role) 'main)) fs)
                                      (length (plist-get (with-temp-buffer
                                                           (insert-file-contents
                                                            (expand-file-name "terminal-report.eld" (drgnx-state-dir)))
                                                           (read (current-buffer)))
                                                         :terminals))
                                      drgnx-hooks-problems))))
                     '(1 3 nil))))))

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

(ert-deftest drgnx-tty-frames/a-terminal-killed-mid-query-leaves-the-daemon-well ()
  ;; a silent terminal is killed while Emacs (its DA2, 2 s) or drgnx (XTVERSION, 0.2 s after) waits for an answer
  (dolist (delay '(0.5 2.1))
    (drgnx-tty-session-with (s :daemon t)
      (let ((problems (drgnx-tty-session-eval s 'drgnx-hooks-problems))
            (messages (drgnx-tty-session-eval s '(with-current-buffer "*Messages*" (point-max))))
            (pty (drgnx-tty-session-pty-start :daemon-sess s)))
        (sleep-for delay)
        (delete-process pty)
        (drgnx-tty-session-wait s '(not (seq-find (lambda (f) (equal (tty-type (frame-terminal f)) "xterm-256color"))
                                                  (frame-list)))
                                10)
        (should (eq (drgnx-tty-session-eval s t) t))
        (should (= (drgnx-tty-session-eval s `(length ,drgnx-tty-frames-test--clients)) 1))
        (should (equal (drgnx-tty-session-eval s 'drgnx-hooks-problems) problems))
        (should-not (string-match-p "[Ee]rror" (drgnx-tty-session-eval
                                                s `(with-current-buffer "*Messages*"
                                                     (buffer-substring-no-properties (min ,messages (point-max))
                                                                                     (point-max))))))))))

;;; frames-test.el ends here
