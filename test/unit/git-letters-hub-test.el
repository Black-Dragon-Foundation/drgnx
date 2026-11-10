;;; git-letters-hub-test.el --- git letters from a real hub reach `drgnx-git-status' -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; A real hub as its own process, this Emacs playing the editor inside the delivery gate (`drgnx-test-gated'), the
;; repository real (git init, one commit, one change).  Needs Sjá (a Nidhogg with `nidhogg-view--call') and the hub's
;; binary; skipped without either.  Nothing of the hub's side is stubbed: the env, the call, the patch.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-hub-client)
(require 'drgnx-git)
(require 'drgnx-view)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)   ; its helpers and the hub fixtures

(defmacro drgnx-git-letters-hub-test--with (root &rest body)
  "BODY with a gated hub, this Emacs connected to it, and ROOT a repository with src/a.txt changed."
  (declare (indent 1))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (drgnx-test-with-clock (:allow-pending t)
       (drgnx-agents-mirror-test--with '()
         (drgnx-hub-connect)
         (drgnx-agents-mirror-test--settle (lambda () (process-live-p drgnx-hub--events)) "the subscribed connection")
         (let ((,root (file-name-as-directory (make-temp-file "drgnx-git-hub" t))) (drgnx-view-old-path nil))
           (unwind-protect
               (progn
                 (make-directory (expand-file-name "src" ,root))
                 (write-region "one\n" nil (expand-file-name "src/a.txt" ,root) nil 'silent)
                 (let ((default-directory ,root))
                   (dolist (args '(("init" "-q") ("add" "-A")
                                   ("-c" "user.name=t" "-c" "user.email=t@t" "commit" "-qm" "x")))
                     (should (zerop (apply #'call-process "git" nil nil nil args)))))
                 (write-region "two\n" nil (expand-file-name "src/a.txt" ,root) nil 'silent)
                 ,@body)
             (drgnx-git-letters-clear)
             (delete-directory ,root t)))))))

(ert-deftest drgnx-git/letters-from-a-real-hub-answer-status-also-after-a-reattach ()
  "Pattern G: the hub's letters answer `drgnx-git-status' of a changed file; after the view was dropped (a root
evicted, the old path used for a while) and made again, the hub sends the rows again and the answer is the same."
  (drgnx-git-letters-hub-test--with root
    (let ((file (concat root "src/a.txt")))
      (drgnx-git-refresh root)
      (should (drgnx-agents-mirror-test--settle (lambda () (drgnx-git-status file)) "the first letters"))
      (should (eq 'modified (drgnx-git-status file)))
      (should (drgnx-git-letters-active-p))
      (drgnx-git-letters-clear)
      (should-not (drgnx-git-letters-active-p))
      (drgnx-git-refresh root)
      (should (drgnx-agents-mirror-test--settle (lambda () (drgnx-git-status file)) "the letters after the view was made again"))
      (should (eq 'modified (drgnx-git-status file))))))

;;; git-letters-hub-test.el ends here
