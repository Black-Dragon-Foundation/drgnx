;;; persist-test.el --- tty tier: a terminal session never writes the desktop layout -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.
(require 'ert)
(require 'drgnx-tty-session)

(ert-deftest drgnx-tty-persist/a-terminal-session-never-writes-the-layout ()
  (drgnx-tty-session-with (s :size "120x40" :keys 'emacs)
    (drgnx-tty-session-wait-screen s "\\*scratch\\* ×" 20)
    (should (drgnx-tty-session-eval s '(bound-and-true-p drgnx-persist-mode)))       ; else nothing is tested
    (should (memq 'drgnx-persist--on-exit (drgnx-tty-session-eval s 'kill-emacs-hook)))
    (let* ((file (drgnx-tty-session-eval s '(drgnx-persist--file)))
           (saved "(:version 2 :frames ((:role main :groups ((:tabs nil)))))"))
      ;; a layout saved by a desktop session, an hour old
      (drgnx-tty-session-eval s `(progn (make-directory (file-name-directory ,file) t)
                                        (write-region ,saved nil ,file nil 'silent)
                                        (set-file-times ,file (time-subtract (current-time) 3600))
                                        t))
      (let ((bytes (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))
            (mtime (file-attribute-modification-time (file-attributes file))))
        ;; a session as a person has one: files, a split
        (drgnx-tty-session-eval s '(progn (find-file (expand-file-name "a.txt" temporary-file-directory))
                                          (split-window-right)
                                          (find-file (expand-file-name "b.txt" temporary-file-directory))
                                          t))
        (drgnx-tty-session-eval s '(progn (drgnx-wb-show-sidebar) t))
        (drgnx-tty-session-wait-screen s "EXPLORER")
        ;; the commands answer, and write nothing
        (drgnx-tty-session-eval s '(progn (drgnx-persist-save) t))
        (should (equal (drgnx-tty-session-eval s '(current-message))
                       "Layouts are saved and restored from graphical windows"))
        ;; C-x C-c
        (drgnx-tty-session-key s "C-x")
        (drgnx-tty-session-key s "C-c")
        (let ((deadline (+ (float-time) 20)))
          (while (and (drgnx-tty-session--pane-alive-p s) (< (float-time) deadline))
            (when (drgnx-tty-session-find s "\\((yes or no)\\|(y or n)\\)")        ; whatever Emacs asks before it exits
              (drgnx-tty-session-send s "yes\r"))
            (sleep-for 0.1)))
        (should-not (drgnx-tty-session--pane-alive-p s))
        (should (equal (with-temp-buffer (insert-file-contents-literally file) (buffer-string)) bytes))
        (should (equal (file-attribute-modification-time (file-attributes file)) mtime))))))

;;; persist-test.el ends here
