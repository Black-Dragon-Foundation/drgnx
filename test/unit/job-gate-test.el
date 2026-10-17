;;; job-gate-test.el --- batch tests: a permission request of an agent behind the decision log is the gate -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/job-fixture" drgnx-dir) nil t)   ; a repo, the hub, mock agents

(defmacro drgnx-job-gate-test--with (&rest body)
  "BODY with a running job ID (nothing started by itself) and S, a mock agent on its task 1 (idle), the log moved
on since S read it."
  (declare (indent 0))
  `(drgnx-job-run-test--with "# One\n\n### Task 1: one\n"
     (let* ((drgnx-job-max-agents 0) (drgnx-job-review nil) (id (drgnx-job-propose plan)) (tid (concat id "#1")) s)
       (drgnx-job-approve id)
       (setq s (drgnx-agents-start "mock" repo tid id))
       (drgnx-coord-force-status tid "running" (drgnx-agent-session-id s))
       (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle)))
       (drgnx-coord-decide :kind "wont-build" :subject "the importer" :author "user" :job id :seen (drgnx-coord-version))
       ,@body)))

(defun drgnx-job-gate-test--said (s text)
  (drgnx-job-run-test--wait (lambda () (string-search text (format "%S" (drgnx-agent-session-entries s)))) 10))

(ert-deftest drgnx-job-gate/a-behind-agent-is-refused-and-told ()
  (drgnx-job-gate-test--with
    (drgnx-agents-send s "permission execute :: make test")                     ; routine, but it is behind
    (should (drgnx-job-gate-test--said s "permission: reject"))
    (should (seq-find (lambda (e) (and (plist-get e :steer) (string-search "[decision log v" (format "%s" (plist-get e :text)))
                                       (string-search "refused" (format "%s" (plist-get e :text)))))
                      (drgnx-agent-session-entries s)))))

(ert-deftest drgnx-job-gate/caught-up-agents-are-not-gated ()
  (drgnx-job-gate-test--with
    (drgnx-coord-set-seen (drgnx-agent-session-id s) (drgnx-coord-version))
    (drgnx-agents-send s "permission execute :: make test")
    (should (drgnx-job-gate-test--said s "permission: allow"))
    (should-not (seq-find (lambda (e) (plist-get e :steer)) (drgnx-agent-session-entries s)))))

(ert-deftest drgnx-job-gate/the-snapshot-says-enforced ()
  (drgnx-job-gate-test--with
    (should (eq (plist-get (drgnx-hub--snapshot s) :enforced) t))               ; it can be steered: the gate holds
    (let ((plain (drgnx-agents-start "mock" repo)))                             ; no job: nothing to enforce
      (drgnx-job-run-test--wait (lambda () (eq (drgnx-agent-session-status plain) 'idle)))
      (should-not (plist-get (drgnx-hub--snapshot plain) :enforced)))))

;;; job-gate-test.el ends here
