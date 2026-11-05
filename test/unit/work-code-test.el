;;; work-code-test.el --- files an agent is still editing open read-only; take the wheel -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process; this Emacs plays the editor inside the delivery gate.  The agents are real children
;; (mock-acp) in a linked worktree of the test's home folder: a file there is the agent's while the agent is live.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-agents)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)   ; its helpers and the hub fixtures

(defvar drgnx-work-live-file-mode)
(defvar drgnx-work-live-file--lighter)
(declare-function drgnx-work-take-wheel "drgnx-work-space")

(defmacro drgnx-work-code-test--with (&rest body)
  "BODY with the module `tools/work-space' set up, a gated hub, this Emacs mirroring its sessions, and `wt' a linked
worktree (its .git is a file) and `own' a checkout of the user's (its .git is a directory) under the test's home."
  (declare (indent 0))
  `(drgnx-test-with-modules '(tools/work-space)
     (drgnx-agents-mirror-test--with '()
       (drgnx-agents-mirror-sync)
       (let* ((home (file-name-as-directory (getenv "HOME")))
              (wt (file-name-as-directory (expand-file-name "agent-worktree" home)))
              (own (file-name-as-directory (expand-file-name "own-checkout" home))))
         (make-directory wt t) (make-directory (concat own ".git") t)
         (with-temp-file (concat wt ".git") (insert "gitdir: /elsewhere/.git/worktrees/agent\n"))
         (dolist (d (list wt own)) (with-temp-file (concat d "a.txt") (insert "one\n")))
         ,@body))))

(defun drgnx-work-code-test--start (cwd)
  "A mock session in CWD; its mirror once it is idle."
  (let ((id (plist-get (drgnx-agents-mirror-test--ask "agents/start" (list :profile "mock" :cwd (directory-file-name cwd)))
                       :id)))
    (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "the session's mirror, idle")))

(ert-deftest drgnx-work-code/live-agent-file-opens-read-only ()
  (drgnx-work-code-test--with
    (let* ((m (drgnx-work-code-test--start wt)) (buf (find-file-noselect (concat wt "a.txt"))))
      (unwind-protect
          (with-current-buffer buf
            (should drgnx-work-live-file-mode)
            (should buffer-read-only)
            ;; the chip is the mode's lighter: " live · NAME"
            (should (equal (concat " live · " (drgnx-agent-session-name m)) drgnx-work-live-file--lighter))
            (should (assq 'drgnx-work-live-file-mode minor-mode-alist))
            (should (equal 'drgnx-work-live-file--lighter (cadr (assq 'drgnx-work-live-file-mode minor-mode-alist)))))
        (kill-buffer buf)))))

(ert-deftest drgnx-work-code/take-the-wheel-pauses-and-makes-it-editable ()
  (drgnx-work-code-test--with
    (let* ((m (drgnx-work-code-test--start wt)) (buf (find-file-noselect (concat wt "a.txt"))))
      (unwind-protect
          (with-current-buffer buf
            (should buffer-read-only)
            (drgnx-work-take-wheel)
            (should-not buffer-read-only)
            ;; the hub paused the agent: the mirror hears it in the next snapshot
            (drgnx-agents-mirror-test--settle (lambda () (drgnx-agent-session-paused m)) "the agent is paused")
            ;; the user's edit queues as a message to the agent on save
            (goto-char (point-max)) (insert "two\n")
            (let ((sent nil))
              (cl-letf (((symbol-function 'drgnx-hub-call)
                         (lambda (method params &rest _) (push (cons method params) sent) 1)))
                (save-buffer))
              (should (seq-some (lambda (c) (and (equal (car c) "agents/send")
                                                 (string-search "a.txt" (plist-get (cdr c) :text))))
                                sent))))
        (set-buffer-modified-p nil)
        (kill-buffer buf)))))

(ert-deftest drgnx-work-code/own-checkout-stays-editable ()
  ;; an agent working in the user's own checkout (not a linked worktree) does not lock the file
  (drgnx-work-code-test--with
    (drgnx-work-code-test--start own)
    (let ((buf (find-file-noselect (concat own "a.txt"))))
      (unwind-protect
          (with-current-buffer buf
            (should-not drgnx-work-live-file-mode)
            (should-not buffer-read-only))
        (kill-buffer buf)))))

(ert-deftest drgnx-work-code/finished-agent-file-is-editable ()
  (drgnx-work-code-test--with
    (let ((m (drgnx-work-code-test--start wt)))
      (setf (drgnx-agent-session-status m) 'exited)
      (let ((buf (find-file-noselect (concat wt "a.txt"))))
        (unwind-protect
            (with-current-buffer buf
              (should-not drgnx-work-live-file-mode)
              (should-not buffer-read-only))
          (kill-buffer buf))))))

(provide 'work-code-test)
;;; work-code-test.el ends here
