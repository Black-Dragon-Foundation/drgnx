;;; plans-sync-test.el --- batch tests: plan checklists and board TODOs stay in step -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-projects)

(defmacro drgnx-plans-test--with (root &rest body)
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-plans" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" ,root "config") (concat "XDG_STATE_HOME=" ,root "state"))
                                       process-environment))
          (drgnx-projects-board-file (concat ,root "org/board.org"))
          (drgnx-projects-gryphn-file (concat ,root "none.tsv")))
     (unwind-protect (progn ,@body) (delete-directory ,root t))))

(defun drgnx-plans-test--repo (root)
  (let ((dir (concat root "ws/alpha/")))
    (make-directory (concat dir "docs/plans") t)
    (let ((default-directory dir)) (call-process "git" nil nil nil "init" "-q"))
    (write-region "### Task 1\n- [ ] **Step 1: test first**\n- [ ] Step 2: code\n" nil (concat dir "docs/plans/p.md") nil 'silent)
    dir))

(defun drgnx-plans-test--read (f) (with-temp-buffer (insert-file-contents f) (buffer-string)))

(ert-deftest drgnx-plans/imported-steps-know-their-plan ()
  (drgnx-plans-test--with root
    (let ((alpha (drgnx-plans-test--repo root)))
      (drgnx-projects-import (list alpha))
      (let ((board (drgnx-plans-test--read (drgnx-projects-board-file))))
        (should (string-match-p ":PLAN_FILE: docs/plans/p.md" board))
        (should (string-match-p ":PLAN_TEXT: \\*\\*Step 1: test first\\*\\*" board))))))

(ert-deftest drgnx-plans/done-on-the-board-ticks-the-plan-and-back ()
  (drgnx-plans-test--with root
    (let* ((alpha (drgnx-plans-test--repo root)) (plan (concat alpha "docs/plans/p.md")))
      (drgnx-projects-import (list alpha))
      ;; DONE on the board → ticked in the plan
      (let ((b (drgnx-plans-test--read (drgnx-projects-board-file))))
        (write-region (replace-regexp-in-string "\\*\\* TODO \\*\\*Step 1" "** DONE **Step 1" b) nil (drgnx-projects-board-file) nil 'silent))
      (should (equal (drgnx-projects-sync-plans) '(:ticked 1 :done 0)))
      (should (string-match-p "^- \\[x\\] \\*\\*Step 1: test first\\*\\*$" (drgnx-plans-test--read plan)))
      ;; ticked in the plan → DONE on the board
      (write-region (replace-regexp-in-string "- \\[ \\] Step 2" "- [x] Step 2" (drgnx-plans-test--read plan)) nil plan nil 'silent)
      (should (equal (drgnx-projects-sync-plans) '(:ticked 0 :done 1)))
      (should (string-match-p "^\\*\\* DONE Step 2: code" (drgnx-plans-test--read (drgnx-projects-board-file))))
      ;; nothing left to do
      (should (equal (drgnx-projects-sync-plans) '(:ticked 0 :done 0))))))

;;; plans-sync-test.el ends here
