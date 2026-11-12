;;; debug-bisect-test.el --- batch tests: bisect over the edit history -*- lexical-binding: t -*-
;; test-class: det
;; The hub's answers are scripted (`drgnx-hub-call' replaced): what is tested is what the editor asks, sends and draws.
;; The search, the states and the card's rows have Rust tests (debug::tests_bisect, tests_bisect_wire).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug-bisect" drgnx-dir) nil t)

(defvar debug-bisect-test--calls nil "Every (METHOD . PARAMS) the test's hub was asked, in order.")

(defconst debug-bisect-test--found
  (list :bisect "b1" :state "found"
        :result (list :first_bad (list :id "record-7" :kind "agent_step" :label "Tighten the stock check"
                                       :session "S1" :step "7" :decision "dec-3")
                      :last_good (list :id "good" :kind "commit" :label "first")
                      :skipped [] :flaky [] :runs 5
                      :diff "diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1 +1 @@\n-x = 1\n+x = 2\n")
        :rows (vector (list :key "head" :text "Bisect · 9 states · found"
                            :runs (vector (vector 0 6 "drgnx-debug-timeline-head")))
                      (list :key "actions" :text "Show Step  Cancel"
                            :props (vector (vector 0 9 "drgnx-debug-bisect-action" "show")
                                           (vector 11 17 "drgnx-debug-bisect-action" "cancel")))))
  "A `debug-bisect' event: the first bad state found, with its card.")

(defmacro debug-bisect-test--with (&rest body)
  "BODY with the hub scripted, the events mode on, and the project /p."
  (declare (indent 0))
  `(let ((debug-bisect-test--calls nil))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params cb &rest _)
                  (setq debug-bisect-test--calls (append debug-bisect-test--calls (list (cons method params))))
                  (funcall cb (pcase method
                                ("debug/bisect" (list :bisect "b1" :states [] :estimate (list :runs 6 :slots 3 :states 9)))
                                (_ t))
                           nil)
                  1))
               ((symbol-function 'drgnx-hub-call-sync)
                (lambda (method params &rest _)
                  (setq debug-bisect-test--calls (append debug-bisect-test--calls (list (cons method params))))
                  (list :states (vector (list :id "commit-abc123" :kind "commit" :label "first" :at 1.0)))))
               ((symbol-function 'drgnx-debug-launch-root) (lambda () "/p")))
       (unwind-protect (progn (drgnx-debug-bisect-events-mode 1) ,@body)
         (drgnx-debug-bisect-events-mode -1)))))

(defun debug-bisect-test--last (method)
  "The params of the last METHOD call."
  (cdr (car (last (seq-filter (lambda (c) (equal (car c) method)) debug-bisect-test--calls)))))

(defun debug-bisect-test--card ()
  "The card's text."
  (with-current-buffer drgnx-debug-bisect-buffer (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest drgnx-debug-bisect/a-state-names-the-good-state-the-hub-takes ()
  (should (equal (drgnx-debug-bisect--good-of "commit-abc123") '(:kind "commit" :id "abc123")))
  (should (equal (drgnx-debug-bisect--good-of "run-r1-x") '(:kind "run" :id "r1-x")))
  (should (equal (drgnx-debug-bisect--good-of "record-12") '(:kind "record" :id "12")))
  (should-not (drgnx-debug-bisect--good-of "now")))

(ert-deftest drgnx-debug-bisect/starting-sends-the-predicate-and-opens-the-card ()
  (debug-bisect-test--with
    (drgnx-debug-bisect '(:kind "commit" :id "abc123") '("pytest" "-x" "tests/test_stock.py"))
    (let ((p (debug-bisect-test--last "debug/bisect")))
      (should (equal (plist-get p :root) "/p"))
      (should (equal (plist-get p :good) '(:kind "commit" :id "abc123")))
      (should (equal (plist-get p :predicate) '(:kind "test" :argv ["pytest" "-x" "tests/test_stock.py"]))))
    (should (equal drgnx-debug-bisect--id "b1"))
    (should (get-buffer drgnx-debug-bisect-buffer))
    (should (string-match-p "about 6 runs in 3 slots" (debug-bisect-test--card)))))

(ert-deftest drgnx-debug-bisect/the-card-is-the-hubs-rows-of-this-bisect ()
  (debug-bisect-test--with
    (drgnx-debug-bisect '(:kind "commit" :id "abc123") '("make" "test"))
    ;; another bisect's event is not drawn
    (drgnx-debug-bisect--event "debug-bisect" (list :bisect "b0" :rows (vector (list :key "head" :text "Other"))))
    (drgnx-debug-bisect--render)
    (should-not (string-match-p "Other" (debug-bisect-test--card)))
    (drgnx-debug-bisect--event "debug-bisect" debug-bisect-test--found)
    (drgnx-debug-bisect--render)
    (should (equal (debug-bisect-test--card) "Bisect · 9 states · found\nShow Step  Cancel\n"))
    (should (equal (plist-get (plist-get drgnx-debug-bisect--result :first_bad) :step) "7"))
    (with-current-buffer drgnx-debug-bisect-buffer
      (goto-char (point-min))
      (should (eq (get-text-property (point) 'face) 'drgnx-debug-timeline-head))
      ;; an action at point: Cancel
      (forward-line 1) (forward-char 12)
      (drgnx-debug-bisect-act)
      (should (equal (debug-bisect-test--last "debug/bisect/cancel") '(:bisect "b1"))))))

(ert-deftest drgnx-debug-bisect/the-result-s-actions ()
  (debug-bisect-test--with
    (drgnx-debug-bisect '(:kind "commit" :id "abc123") '("make" "test"))
    (drgnx-debug-bisect--event "debug-bisect" debug-bisect-test--found)
    ;; Show Step: the change, as a diff
    (drgnx-debug-bisect-show-step)
    (with-current-buffer drgnx-debug-bisect-step-buffer
      (should (string-match-p "^\\+x = 2$" (buffer-string)))
      (should (derived-mode-p 'diff-mode))
      (should buffer-read-only))
    ;; Revert Step: the revert card of the step before it (nothing changes until its Apply)
    (let (asked)
      (cl-letf (((symbol-function 'drgnx-history-revert-to-here) (lambda (s n) (setq asked (list s n)))))
        (drgnx-debug-bisect-revert-step))
      (should (equal asked '("S1" 6))))
    ;; Ask the Agent: a message to the session that made it
    (let (sent)
      (cl-letf (((symbol-function 'drgnx-agents-get) (lambda (id) (and (equal id "S1") 'session-1)))
                ((symbol-function 'drgnx-agents-send) (lambda (s text) (setq sent (list s text)))))
        (drgnx-debug-bisect-ask-agent))
      (should (eq (car sent) 'session-1))
      (should (string-match-p "step 7" (cadr sent)))
      (should (string-match-p "make test" (cadr sent))))
    (drgnx-debug-bisect-narrow)
    (should (equal (debug-bisect-test--last "debug/bisect/narrow") '(:bisect "b1")))
    (kill-buffer drgnx-debug-bisect-step-buffer)))

(ert-deftest drgnx-debug-bisect/off-leaves-nothing ()
  (debug-bisect-test--with
    (drgnx-debug-bisect '(:kind "commit" :id "abc123") '("make" "test"))
    (drgnx-debug-bisect--event "debug-bisect" debug-bisect-test--found)
    (drgnx-debug-bisect-events-mode -1)
    (should-not (memq #'drgnx-debug-bisect--event drgnx-hub-event-functions))
    (should-not (get-buffer drgnx-debug-bisect-buffer))
    (should-not drgnx-debug-bisect--id)
    (should-not drgnx-debug-bisect--result)))

;;; debug-bisect-test.el ends here
