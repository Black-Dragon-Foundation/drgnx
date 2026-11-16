;;; changes-test.el --- the Changes view: what the editor asks of the hub and what a row does -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: the calls are caught at `drgnx-hub--call-on'.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/scm))

(declare-function drgnx-changes--subscribe "drgnx-changes")
(declare-function drgnx-changes-refresh "drgnx-changes")
(declare-function drgnx-changes-group-by "drgnx-changes")
(declare-function drgnx-changes-open-hunk "drgnx-changes")
(declare-function drgnx-changes-revert-hunk "drgnx-changes")
(defvar drgnx-changes-by)
(defvar drgnx-hub--events)

(ert-deftest drgnx-changes/subscribe-and-refresh-ask-the-hub ()
  (let (calls (drgnx-hub--events nil))
    (cl-letf (((symbol-function 'drgnx-changes--hub-p) (lambda () t))
              ((symbol-function 'drgnx-hub--call-on)
               (lambda (_c m p _cb &rest _) (push (cons m p) calls))))
      (drgnx-changes--subscribe)
      (should (equal '("changes/subscribe" :view "changes") (car calls)))
      (with-current-buffer (get-buffer-create "*Changes*")
        (drgnx-changes-refresh)
        (kill-buffer))
      (should (equal '("changes/set" :view "changes" :refresh t) (car calls))))))

(ert-deftest drgnx-changes/by-repo-shows-source-control-and-by-task-the-changes ()
  (let (shown)
    (cl-letf (((symbol-function 'drgnx-scm--buffer) (lambda () (get-buffer-create "*scm-stand-in*")))
              ((symbol-function 'drgnx-changes--buffer) (lambda () (get-buffer-create "*changes-stand-in*")))
              ((symbol-function 'switch-to-buffer) (lambda (b &rest _) (push (buffer-name b) shown))))
      (drgnx-changes-group-by 'repo)
      (should (equal "*scm-stand-in*" (car shown)))
      (should (eq 'repo drgnx-changes-by))
      (drgnx-changes-group-by 'task)
      (should (equal "*changes-stand-in*" (car shown)))
      (should (eq 'task drgnx-changes-by)))
    (mapc #'kill-buffer (list "*scm-stand-in*" "*changes-stand-in*"))))

(ert-deftest drgnx-changes/a-hunk-without-an-operation-is-not-reverted ()
  (with-temp-buffer
    (insert (propertize "hunk\n" 'drgnx-hunk (list :path "a.rs" :op nil :index 0 :session "s1")))
    (goto-char (point-min))
    (should-error (drgnx-changes-revert-hunk) :type 'user-error)))

(ert-deftest drgnx-changes/a-revert-names-the-agents-worktree ()
  (let (calls (drgnx-hub--events nil))
    (with-temp-buffer
      (insert (propertize "hunk\n" 'drgnx-hunk (list :path "a.rs" :op 7 :index 2 :session "s1")))
      (goto-char (point-min))
      (cl-letf (((symbol-function 'drgnx-changes--hub-p) (lambda () t))
                ((symbol-function 'drgnx-work-code--worktree) (lambda (_) "/wt/s1"))
                ((symbol-function 'drgnx-hub--call-on) (lambda (_c m p _cb &rest _) (push (cons m p) calls))))
        (drgnx-changes-revert-hunk)
        (should (equal '("history/revert/hunk" :worktree "/wt/s1" :op 7 :path "a.rs" :hunk 2) (car calls)))))))
