;;; doctor-past-sessions-test.el --- batch tests: the doctor's past-sessions check -*- lexical-binding: t -*-
;; test-class: det
;; The check reads the facts plist (:past-sessions, built from the hub's `agents/history/status'); nothing here
;; starts a hub.
(require 'ert)
(require 'drgnx-doctor)

(ert-deftest doctor-past-sessions/format-drift-warns-and-names-the-fix ()
  (let ((r (drgnx-doctor-check
            'past-sessions
            (list :past-sessions '(:hub t :on t :sessions 40
                                        :drift ((:provider "claude" :files 3 :unknown_pct 40)))))))
    (should (eq (car r) 'warn))
    (should (equal (nth 1 r) "History: 3 Claude Code files had 40% unknown lines; update drgnx"))
    (should (equal (nth 2 r) "drgnx update"))))

(ert-deftest doctor-past-sessions/ok-without-a-hub-when-off-or-without-drift ()
  (dolist (s '((:hub nil) (:hub t :on nil :sessions 0 :drift nil) (:hub t :on t :sessions 2 :drift nil)))
    (should (eq (car (drgnx-doctor-check 'past-sessions (list :past-sessions s))) 'ok))))

(ert-deftest doctor-past-sessions/a-failed-query-warns ()
  (should (eq (car (drgnx-doctor-check 'past-sessions '(:past-sessions (:error "timed out")))) 'warn)))

;;; doctor-past-sessions-test.el ends here
