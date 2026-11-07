;;; perf-agents-test.el --- batch tests: the perf lab's agents-in-the-editor workloads and their rules -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: the specs, the fixture's scripts and the lab's relative rules, with no hub and no GUI (the workloads run on
;; the desktop island, docs/develop/perf.md).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-perf)
(require 'drgnx-perf-run)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/agents-editor-five-fixture" drgnx-dir) nil t)

(defconst perf-agents-test--names '(agents-typing agents-typing-none agents-follow agent-panel-stream pair-typing))

(ert-deftest drgnx-perf-agents/every-workload-types-checks-and-tears-down ()
  (let ((all (drgnx-perf-run--workloads)))
    (dolist (n perf-agents-test--names)
      (let ((spec (cdr (assq n all))))
        (should spec)
        (should (plist-get spec :setup))
        (should (plist-get spec :actions))
        (should (string-search "drgnx-agents-five-premise" (plist-get spec :check)))
        (should (string-search "drgnx-perf--agents-down" (plist-get spec :teardown)))))
    ;; the baseline runs the same agents with the module off; the others have it on
    (should (string-search "drgnx-perf--agents-up nil nil" (plist-get (cdr (assq 'agents-typing-none all)) :setup)))
    (should (string-search "drgnx-perf--agents-up t nil" (plist-get (cdr (assq 'agents-typing all)) :setup)))
    (should (string-search "drgnx-perf--agents-up t t" (plist-get (cdr (assq 'pair-typing all)) :setup)))
    (should (string-search ":pair_applied_ratio" (plist-get (cdr (assq 'pair-typing all)) :measure)))))

(ert-deftest drgnx-perf-agents/every-workload-has-its-time-budgets ()
  (let ((budgets (with-temp-buffer (insert-file-contents (expand-file-name "test/perf/budgets.eld" drgnx-dir))
                                   (read (current-buffer)))))
    (dolist (n perf-agents-test--names)
      (should (member (list n '(:input :p95) 16) budgets))
      (should (member (list n '(:stalls) 0) budgets)))))

(ert-deftest drgnx-perf-agents/the-five-scripts-edit-their-worktree-and-the-paired-one-the-users-file ()
  (let ((drgnx-agents-five--file "/p/src/main.el"))
    (dolist (i '(1 2 3 4 5))
      (let ((line (drgnx-agents-five--program i nil)))
        (should (string-search "tool:edit src/main.el" line))
        (should-not (string-search "call:edit_file" line))))
    (let ((paired (drgnx-agents-five--program 5 t)))
      (should (string-search "call:edit_file" paired))
      (should (string-search "/p/src/main.el" paired))
      (should-not (string-search "tool:edit" paired)))
    (should (string-search "tool:edit" (drgnx-agents-five--program 4 t)))
    ;; no two reads of one agent are the same call
    (let* ((words (split-string (drgnx-agents-five--program 1 nil) "\\\\n" t))
           (reads (seq-filter (lambda (w) (string-prefix-p "provider:read" w)) words)))
      (should (> (length reads) 100))
      (should (= (length reads) (length (delete-dups (copy-sequence reads))))))))

(ert-deftest drgnx-perf-agents/the-relative-rules-judge-one-millisecond-and-the-applied-share ()
  (let ((res (lambda (a n r) `((agents-typing :input (:p95 ,a)) (agents-typing-none :input (:p95 ,n))
                               (pair-typing :pair_applied_ratio ,r)))))
    (should-not (cl-remove-if-not (lambda (l) (or (string-search "agents-typing" l) (string-search "pair-typing" l)))
                                  (drgnx-perf-run--relative-fails (funcall res 5.0 4.5 0.9))))
    (should (cl-some (lambda (l) (string-search "agents-typing input p95" l))
                     (drgnx-perf-run--relative-fails (funcall res 6.0 4.5 0.9))))
    (should (cl-some (lambda (l) (string-search "pair-typing applied" l))
                     (drgnx-perf-run--relative-fails (funcall res 4.0 4.0 0.5))))))

(provide 'perf-agents-test)
;;; perf-agents-test.el ends here
