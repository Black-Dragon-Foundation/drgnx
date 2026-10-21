;;; core-notice-echo-test.el --- batch tests: the echo rule and the startup line (virtual time, one echo area stubbed) -*- lexical-binding: t -*-
(require 'ert)
(require 'ert-x)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-notice-echo)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defconst drgnx-notice-echo-test--real-seam (symbol-function 'drgnx-notice--can-echo-p)
  "The seam as the library defines it, before a test stubs it.")

(defvar drgnx-notice-echo-test--shown nil "The echo area's message, `current-message' in a test.")
(defvar drgnx-notice-echo-test--minibuffer nil "Non-nil: the minibuffer is active.")
(defvar drgnx-notice-echo-test--take nil "What the stubbed `drgnx-notice-desktop-take' answers.")

(defmacro drgnx-notice-echo-test--with (&rest body)
  "BODY on a fresh notice model and virtual time, the echo mode on after init, an echo area that can show, a notices
key (C-c n) and a titled command `x-fix' (key F9).  `lines' is the list of lines echoed, oldest first."
  (declare (indent 0) (debug t))
  `(drgnx-notice-test-with-model
     (drgnx-test-with-clock ()
       (let ((drgnx-notice-echo-test--shown nil) (drgnx-notice-echo-test--minibuffer nil)
             (drgnx-notice-echo-test--take nil) (after-init-time (current-time)) (this-command nil)
             (drgnx-notice-echo-interval 2))
         (setq drgnx-notice--echo-pending nil drgnx-notice--echo-last nil drgnx-notice--echo-waiting nil
               drgnx-notice--started nil)
         (cl-letf (((symbol-function 'drgnx-notice--can-echo-p) (lambda () t))
                   ((symbol-function 'active-minibuffer-window)
                    (lambda () drgnx-notice-echo-test--minibuffer))
                   ((symbol-function 'current-message) (lambda () drgnx-notice-echo-test--shown))
                   ((symbol-function 'drgnx-notice-desktop-take) (lambda (_) drgnx-notice-echo-test--take))
                   ((symbol-function 'drgnx-surfaces-key-label)
                    (lambda (id &rest _) (pcase id ('notices "C-c n") ('x-fix "F9"))))
                   ((symbol-function 'drgnx-commands-get)
                    (lambda (id) (and (eq id 'x-fix) (drgnx-cmd--make :id 'x-fix :title "Fix X")))))
           (ert-with-message-capture captured
                                     (unwind-protect
                                         (cl-flet ((lines () (split-string captured "\n" t)))
                                           (drgnx-notice-echo-mode 1)
                                           ,@body)
                                       (drgnx-notice-echo-mode -1))))))))

;;;; The rule, one cell per test

(ert-deftest drgnx-notice-echo/event-info-warn-echo-only-with-echo-t ()
  (drgnx-notice-echo-test--with
    (drgnx-notify 'hooks 'info "quiet info")
    (drgnx-notify 'hooks 'warn "quiet warn")
    (should-not (lines))
    (drgnx-notify 'hooks 'info "loud info" :echo t)
    (should (equal (lines) '("drgnx: loud info")))))

(ert-deftest drgnx-notice-echo/event-fail-echoes-once ()
  (drgnx-notice-echo-test--with
    (drgnx-notify 'hooks 'fail "boom")
    (drgnx-notify 'hooks 'fail "boom")                  ; a repeat only counts
    (drgnx-test-advance 5)
    (should (equal (lines) '("drgnx: boom")))))

(ert-deftest drgnx-notice-echo/condition-info-never-echoes ()
  (drgnx-notice-echo-test--with
    (drgnx-notify 'hooks 'info "fyi" :life 'condition)
    (should-not (lines))))

(ert-deftest drgnx-notice-echo/condition-warn-never-echoes ()
  (drgnx-notice-echo-test--with
    (drgnx-notify 'hooks 'warn "degraded" :life 'condition)
    (should-not (lines))
    (drgnx-notify 'hooks 'warn "degraded, said aloud" :id 'loud :life 'condition :echo t)   ; :echo t always does
    (should (equal (lines) '("drgnx: degraded, said aloud")))))

(ert-deftest drgnx-notice-echo/condition-fail-echoes-once-when-new ()
  (drgnx-notice-echo-test--with
    (drgnx-notify 'hooks 'fail "down" :id 'a :life 'condition)
    (drgnx-notify 'hooks 'fail "down" :id 'a :life 'condition)
    (drgnx-notice-clear 'hooks 'a)
    (should (equal (lines) '("drgnx: down")))
    (drgnx-test-advance 3)
    (drgnx-notify 'hooks 'fail "down" :id 'a :life 'condition)   ; new again after a clear
    (should (equal (lines) '("drgnx: down" "drgnx: down")))))

(ert-deftest drgnx-notice-echo/attention-echoes-once-when-new ()
  (drgnx-notice-echo-test--with
    (drgnx-notice-set 'agents (list (list :id 'a :text "s1 asks: run make?")))
    (should (equal (lines) '("drgnx: waiting on you: s1 asks: run make?")))
    (drgnx-notice-set 'agents (list (list :id 'a :text "s1 asks: run make?")))   ; the same set again
    (drgnx-notice-set 'agents (list (list :id 'a :text "s1 asks: run make?, now?")))   ; the same id, other text
    (drgnx-test-advance 5)
    (should (= 1 (length (lines))))))

(ert-deftest drgnx-notice-echo/attention-not-echoed-when-a-desktop-notification-went ()
  (drgnx-notice-echo-test--with
    (setq drgnx-notice-echo-test--take t)
    (drgnx-notice-set 'agents (list (list :id 'a :text "s1 asks?")))
    (should-not (lines))))

(ert-deftest drgnx-notice-echo/echo-nil-overrides ()
  (drgnx-notice-echo-test--with
    (drgnx-notify 'hooks 'fail "silent failure" :echo nil)
    (drgnx-notice-set 'agents (list (list :id 'a :text "silent ask" :echo nil)))
    (drgnx-test-advance 5)
    (should-not (lines))))

;;;; Pacing and texts

(ert-deftest drgnx-notice-echo/at-most-one-line-per-2-s-and-the-rest-merge ()
  (drgnx-notice-echo-test--with
    (drgnx-notify 'hooks 'fail "a")
    (should (equal (lines) '("drgnx: a")))
    (drgnx-test-advance 0.5)
    (drgnx-notify 'hooks 'fail "b")
    (drgnx-notify 'hooks 'fail "c")
    (should (= 1 (length (lines))))                     ; they wait
    (drgnx-test-advance 1.4)
    (should (= 1 (length (lines))))
    (drgnx-test-advance 0.2)                            ; 2 s after the first line
    (should (equal (lines) '("drgnx: a" "drgnx: 2 new problems — Show Notices (C-c n)")))))

(ert-deftest drgnx-notice-echo/merged-line-texts ()
  (drgnx-notice-echo-test--with
    (drgnx-notify 'hooks 'fail "first")
    (drgnx-notify 'hooks 'fail "x1") (drgnx-notify 'hooks 'fail "x2")
    (drgnx-test-advance 2)
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?") (list :id 'b :text "b?")))
    (drgnx-test-advance 2)
    (drgnx-notify 'hooks 'fail "y")
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?") (list :id 'b :text "b?") (list :id 'c :text "c?")))
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?") (list :id 'b :text "b?") (list :id 'c :text "c?")
                                    (list :id 'd :text "d?")))
    (drgnx-test-advance 2)
    (drgnx-test-advance 2)
    (should (equal (lines)
                   '("drgnx: first"
                     "drgnx: 2 new problems — Show Notices (C-c n)"
                     "drgnx: 2 new things wait on you — Show Notices (C-c n)"
                     "drgnx: 1 new problems and 2 things waiting on you — Show Notices (C-c n)")))))

(ert-deftest drgnx-notice-echo/a-single-line-names-its-command ()
  (drgnx-notice-echo-test--with
    (drgnx-notify 'hooks 'fail "boom" :command 'x-fix)
    (drgnx-test-advance 2)
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?" :command '(x-fix "arg"))))
    (should (equal (lines) '("drgnx: boom — Fix X (F9)" "drgnx: waiting on you: a? — Fix X (F9)")))))

;;;; Waiting

(ert-deftest drgnx-notice-echo/not-while-the-minibuffer-is-active ()
  (drgnx-notice-echo-test--with
    (setq drgnx-notice-echo-test--minibuffer t)
    (drgnx-notify 'hooks 'fail "boom")
    (should-not (lines))
    (should drgnx-notice--echo-waiting)
    (drgnx-notice--post-command)                        ; still active
    (should-not (lines))
    (setq drgnx-notice-echo-test--minibuffer nil)
    (drgnx-notice--post-command)
    (should (equal (lines) '("drgnx: boom")))
    (should-not drgnx-notice--echo-waiting)))

(ert-deftest drgnx-notice-echo/not-over-the-current-commands-message ()
  (drgnx-notice-echo-test--with
    (setq drgnx-notice-echo-test--shown "Wrote /tmp/file")
    (drgnx-notify 'hooks 'fail "boom")
    (should-not (lines))
    (drgnx-notice--post-command)                        ; the message is still there
    (should-not (lines))
    (setq drgnx-notice-echo-test--shown nil)
    (let ((this-command 'save-buffer))                  ; post-command-hook runs with this-command still set
      (drgnx-notice--post-command))
    (should (equal (lines) '("drgnx: boom")))))

(ert-deftest drgnx-notice-echo/not-while-a-command-runs ()
  (drgnx-notice-echo-test--with
    (let ((this-command 'save-buffer)) (drgnx-notify 'hooks 'fail "boom"))
    (should-not (lines))
    (drgnx-notice--post-command)
    (should (equal (lines) '("drgnx: boom")))))

(ert-deftest drgnx-notice-echo/our-own-line-is-not-a-commands-message ()
  (drgnx-notice-echo-test--with
    (drgnx-notify 'hooks 'fail "a")
    (setq drgnx-notice-echo-test--shown "drgnx: a")     ; still in the echo area
    (drgnx-test-advance 3)
    (drgnx-notify 'hooks 'fail "b")
    (should (equal (lines) '("drgnx: a" "drgnx: b")))))

(ert-deftest drgnx-notice-echo/post-command-is-one-flag-test ()
  (drgnx-notice-echo-test--with
    (should (memq 'drgnx-notice--post-command post-command-hook))
    (unwind-protect                                     ; depth 90: after the default depth 0, before depth 100
        (progn (add-hook 'post-command-hook 'ignore 100) (add-hook 'post-command-hook 'identity 0)
               (let ((order (seq-filter (lambda (f) (memq f '(identity drgnx-notice--post-command ignore)))
                                        post-command-hook)))
                 (should (equal order '(identity drgnx-notice--post-command ignore)))))
      (remove-hook 'post-command-hook 'ignore) (remove-hook 'post-command-hook 'identity))
    (should-not drgnx-notice--echo-waiting)
    (should (= 0 (drgnx-notice-test--alloc (drgnx-notice--post-command))))))

;;;; Never

(ert-deftest drgnx-notice-echo/none-in-batch ()
  (drgnx-notice-echo-test--with
    (cl-letf (((symbol-function 'drgnx-notice--can-echo-p) drgnx-notice-echo-test--real-seam))   ; not stubbed
      (should noninteractive)
      (drgnx-notify 'hooks 'fail "boom")
      (drgnx-notice-set 'agents (list (list :id 'a :text "a?")))
      (should-not (lines)))
    (should-not (lines))))

(ert-deftest drgnx-notice-echo/a-daemon-holds-lines-until-a-client-frame ()
  (drgnx-notice-echo-test--with
    (cl-letf (((symbol-function 'drgnx-notice--can-echo-p) (lambda () nil)))   ; a daemon, no client frame
      (drgnx-notify 'hooks 'fail "boom")
      (should-not (lines))
      (should (= 1 (length drgnx-notice--echo-pending))))
    (drgnx-notice--server-frame)                        ; server-after-make-frame-hook
    (should (equal (lines) '("drgnx: boom")))
    (should-not drgnx-notice--echo-pending)))

(ert-deftest drgnx-notice-echo/nothing-during-startup ()
  (drgnx-notice-echo-test--with
    (drgnx-notice-echo-mode -1)
    (let ((after-init-time nil))                        ; init is still running
      (drgnx-notice-echo-mode 1)
      (should-not drgnx-notice--started)
      (drgnx-notify 'hooks 'fail "early" :id 'a :life 'condition)
      (drgnx-notify 'hooks 'fail "early event")
      (drgnx-notice-set 'agents (list (list :id 'a :text "early ask")))
      (should-not (lines)))
    (should (memq 'drgnx-notice--startup-hook emacs-startup-hook))
    (drgnx-notice--startup-hook)
    (should drgnx-notice--started)
    (should (equal (lines) '("drgnx: early — Show Notices (C-c n)")))))

;;;; The startup line

(defun drgnx-notice-echo-test--fail-module (name)
  (drgnx-test-advance 1)
  (drgnx-notify 'modules 'fail (format "%s did not start" name) :id name :life 'condition))

(ert-deftest drgnx-notice-echo/the-startup-line-sums-failed-modules ()
  (drgnx-notice-echo-test--with
    (drgnx-notice-echo-mode -1)
    (let ((after-init-time nil))
      (drgnx-notice-echo-mode 1)
      (drgnx-notice-echo-test--fail-module 'tools/agents-ui)
      (drgnx-notice--startup-hook))
    (should (equal (lines) '("drgnx: 1 module did not start (tools/agents-ui) — Show Notices (C-c n)")))))

(ert-deftest drgnx-notice-echo/the-startup-line-names-at-most-three-modules ()
  (drgnx-notice-echo-test--with
    (drgnx-notice-echo-mode -1)
    (let ((after-init-time nil))
      (drgnx-notice-echo-mode 1)
      (drgnx-notice-echo-test--fail-module 'tools/agents-ui)
      (drgnx-notice-echo-test--fail-module 'extra/llm)
      (drgnx-notice--startup-hook))
    (should (equal (lines) '("drgnx: 2 modules did not start (tools/agents-ui, extra/llm) — Show Notices (C-c n)")))))

(ert-deftest drgnx-notice-echo/the-startup-line-names-at-most-three-modules-then-counts ()
  (drgnx-notice-echo-test--with
    (drgnx-notice-echo-mode -1)
    (let ((after-init-time nil))
      (drgnx-notice-echo-mode 1)
      (dolist (m '(tools/agents-ui extra/llm a/one a/two a/three)) (drgnx-notice-echo-test--fail-module m))
      (drgnx-notice--startup-hook))
    (should (equal (lines)
                   '("drgnx: 5 modules did not start (tools/agents-ui, extra/llm, a/one, and 2 more) — Show Notices (C-c n)")))))

(ert-deftest drgnx-notice-echo/the-startup-line-for-other-problems ()
  (drgnx-notice-echo-test--with
    (drgnx-notice-echo-mode -1)
    (let ((after-init-time nil))
      (drgnx-notice-echo-mode 1)
      (drgnx-notify 'hooks 'fail "a hook is broken" :id 'h :life 'condition)
      (drgnx-notice--startup-hook))
    (should (equal (lines) '("drgnx: a hook is broken — Show Notices (C-c n)")))))

(ert-deftest drgnx-notice-echo/the-startup-line-counts-mixed-problems ()
  (drgnx-notice-echo-test--with
    (drgnx-notice-echo-mode -1)
    (let ((after-init-time nil))
      (drgnx-notice-echo-mode 1)
      (drgnx-notify 'hooks 'fail "a hook is broken" :id 'h :life 'condition)
      (drgnx-notice-echo-test--fail-module 'tools/agents-ui)   ; a module and another problem
      (drgnx-notice--startup-hook))
    (should (equal (lines) '("drgnx: 2 problems at startup — Show Notices (C-c n)")))))

(ert-deftest drgnx-notice-echo/no-startup-line-without-failures ()
  (drgnx-notice-echo-test--with
    (drgnx-notice-echo-mode -1)
    (let ((after-init-time nil))
      (drgnx-notice-echo-mode 1)
      (drgnx-notify 'hooks 'warn "degraded" :id 'w :life 'condition)
      (drgnx-notice--startup-hook))
    (should drgnx-notice--started)
    (should-not (lines))))

(ert-deftest drgnx-notice-echo/mode-off-removes-everything ()
  (drgnx-notice-echo-test--with
    (drgnx-notice-echo-mode -1)
    (should-not (memq 'drgnx-notice--echo-change drgnx-notice-functions))
    (should-not (memq 'drgnx-notice--post-command post-command-hook))
    (should-not (memq 'drgnx-notice--startup-hook emacs-startup-hook))
    (should-not (memq 'drgnx-notice--server-frame server-after-make-frame-hook))
    (should-not (drgnx-timer-active-p 'notice-echo))))

(provide 'core-notice-echo-test)
;;; core-notice-echo-test.el ends here
