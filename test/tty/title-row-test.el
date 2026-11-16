;;; title-row-test.el --- tty tier: the title row in text, each part a click target -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Design docs/specs/drgnx/2026-11-16-title-bar-inbox-design.md (the org folder): in a terminal frame the row has the
;; same order as the window's, in text: `☰  name ▾  [Ctrl P search]  ● 2 need you  ◧ ▬ ◨'.  A real terminal, real clicks
;; (SGR mouse bytes through tmux): the toggle's click hides and shows its part, the pill's click opens the inbox's tab.
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-tty-session)

(defun drgnx-title-row-tty-test--top (s)
  "The terminal's first line."
  (car (split-string (drgnx-tty-session-screen s) "\n")))

(defun drgnx-title-row-tty-test--col (s regexp)
  "The 1-based column the first match of REGEXP starts at on the top line, or nil."
  (when (string-match regexp (drgnx-title-row-tty-test--top s)) (1+ (match-beginning 0))))

(ert-deftest drgnx-title-row-tty/the-row-is-text-in-the-designs-order ()
  (drgnx-tty-session-with (s :size "140x40")
    (should (drgnx-tty-session-eval
             s '(progn (drgnx-notice-set 'agents (list (list :id '(permission "s1" . 7) :text "a wants to run" :command 'ignore)))
                       (force-mode-line-update t) t)))
    (should (drgnx-tty-session-wait-screen s "needs you" 10))
    (let ((top (drgnx-title-row-tty-test--top s)))
      (should-not (string-match-p "File\\|Edit\\|Selection" top))
      (should-not (string-match-p "main" top))        ; no branch: the status bar has it
      (let ((cols (mapcar (lambda (re) (drgnx-title-row-tty-test--col s re))
                          '("☰" "▾\\|⌄" "\\[.*search\\]" "1 needs you" "◧"))))
        (should (cl-every #'identity cols))
        (should (equal cols (sort (copy-sequence cols) #'<)))))))

(ert-deftest drgnx-title-row-tty/a-click-on-the-toggle-hides-and-shows-the-side-bar ()
  (drgnx-tty-session-with (s :size "140x40")
    (let ((shown (lambda () (drgnx-tty-session-eval s '(and (drgnx-wb-sidebar-showing-p) t)))))
      (should (funcall shown))
      (let ((col (drgnx-title-row-tty-test--col s "◧")))
        (should col)
        (drgnx-tty-session-click s col 1)
        (ert-info ((format "the screen:\n%s" (drgnx-tty-session-screen s)))
          (should (drgnx-tty-session-wait s '(not (drgnx-wb-sidebar-showing-p)) 10)))
        (drgnx-tty-session-click s col 1)
        (should (drgnx-tty-session-wait s '(drgnx-wb-sidebar-showing-p) 10))))))

(ert-deftest drgnx-title-row-tty/a-click-on-the-pill-shows-the-inbox-tab ()
  (drgnx-tty-session-with (s :size "140x40")
    (should (drgnx-tty-session-eval
             s '(progn (drgnx-notice-set 'agents (list (list :id '(permission "s1" . 7) :text "a wants to run" :command 'ignore)))
                       (force-mode-line-update t) t)))
    (should (drgnx-tty-session-wait-screen s "needs you" 10))
    (drgnx-tty-session-click s (+ 2 (drgnx-title-row-tty-test--col s "1 needs you")) 1)
    (should (drgnx-tty-session-wait s '(and (drgnx-pane-window 'inbox) t) 10))
    (should (drgnx-tty-session-wait-screen s "Allow once" 10))))

(provide 'title-row-test)
;;; title-row-test.el ends here
