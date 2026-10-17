;;; mod-prs-test.el --- batch tests: the Pull Requests tab — forge's PRs, stacks, Changes in the diff view -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-diff" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-prs" drgnx-dir) nil t)

(defun drgnx-prs-test--pr (n base head &optional state)
  (list :number n :title (format "PR %d" n) :author "ada" :state (or state 'open) :base base :head head :updated "2026-10-17T10:00:00Z"))

(defmacro drgnx-prs-test--with (prs &rest body)
  "BODY in a repo whose forge PRs are PRS (`drgnx-prs--pullreqs' stubbed)."
  (declare (indent 1))
  `(drgnx-git-test-with-repo
     (drgnx-git-test-write repo "a" "a\n")
     (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "a")
     (let ((default-directory repo))
       (cl-letf (((symbol-function 'drgnx-prs--pullreqs) (lambda (_root) ,prs)))
         (unwind-protect (progn ,@body)
           (when (get-buffer "*drgnx pull requests*") (kill-buffer "*drgnx pull requests*")))))))

(defun drgnx-prs-test--rows ()
  (with-current-buffer "*drgnx pull requests*"
    (mapcar (lambda (e) (aref (cadr e) 1)) tabulated-list-entries)))

(ert-deftest drgnx-prs/stacks-nest-under-their-base ()
  (let ((s (drgnx-prs-stacks (list (drgnx-prs-test--pr 3 "main" "a") (drgnx-prs-test--pr 5 "a" "b")
                                   (drgnx-prs-test--pr 7 "b" "c") (drgnx-prs-test--pr 4 "main" "d")))))
    (should (equal (mapcar (lambda (e) (cons (plist-get (car e) :number) (cdr e))) s) '((4 . 0) (3 . 0) (5 . 1) (7 . 2))))))

(ert-deftest drgnx-prs/stacks-survive-cycles ()
  (let ((s (drgnx-prs-stacks (list (drgnx-prs-test--pr 1 "y" "x") (drgnx-prs-test--pr 2 "x" "y") (drgnx-prs-test--pr 9 "main" "main")))))
    (should (equal (sort (mapcar (lambda (e) (plist-get (car e) :number)) s) #'<) '(1 2 9)))))

(ert-deftest drgnx-prs/the-tab-lists-open-prs ()
  (drgnx-prs-test--with (list (drgnx-prs-test--pr 3 "main" "a") (drgnx-prs-test--pr 5 "a" "b" 'draft)
                              (drgnx-prs-test--pr 6 "main" "e") (drgnx-prs-test--pr 2 "main" "f" 'merged))
    (drgnx-prs-view)
    (let ((rows (drgnx-prs-test--rows)))
      (should (= 3 (length rows)))
      (should (member "└ PR 5" rows)))
    (with-current-buffer "*drgnx pull requests*" (drgnx-prs-toggle-closed))
    (should (= 4 (length (drgnx-prs-test--rows))))
    (with-current-buffer "*drgnx pull requests*"
      (should (seq-some (lambda (e) (equal (aref (cadr e) 3) "draft")) tabulated-list-entries)))))

(ert-deftest drgnx-prs/no-forge-no-error ()
  (drgnx-prs-test--with :untracked
    (drgnx-prs-view)
    (should (string-search "No pull requests here yet" (with-current-buffer "*drgnx pull requests*" (buffer-string)))))
  ;; the real reader without forge: untracked, never an error
  (unless (featurep 'forge)
    (drgnx-git-test-with-repo
      (should (eq (drgnx-prs--pullreqs repo) :untracked)))))

(ert-deftest drgnx-prs/changes-fetch-then-diff ()
  (drgnx-prs-test--with (list (drgnx-prs-test--pr 5 "feature-a" "b"))
    (let ((cmd nil) (sentinel nil) (shown nil))
      (cl-letf (((symbol-function 'make-process) (lambda (&rest args) (setq cmd (plist-get args :command) sentinel (plist-get args :sentinel)) 'fake))
                ((symbol-function 'drgnx-diff-show) (lambda (&rest args) (setq shown args))))
        (drgnx-prs-view)
        (with-current-buffer "*drgnx pull requests*"
          (goto-char (point-min))
          (search-forward "PR 5")
          (drgnx-prs-changes))
        (should (equal cmd '("git" "fetch" "origin" "+refs/pull/5/head:refs/pullreqs/5")))
        (should-not shown)                                   ; not before the fetch ends
        (funcall sentinel 'fake "finished\n")
        (should (equal (car shown) '(range "origin/feature-a" "refs/pullreqs/5")))
        (setq shown nil)
        (funcall sentinel 'fake "exited abnormally with code 128\n")
        (should-not shown)))))

(ert-deftest drgnx-prs/adapter-reads-forge ()
  (skip-unless (require 'forge nil t))                     ; DEFERRED: a live forge check
  (drgnx-git-test-with-repo
    (should (memq (drgnx-prs--pullreqs repo) '(:untracked nil)))))

;;; mod-prs-test.el ends here
