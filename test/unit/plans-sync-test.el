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

;;;; Review fixes (M7 final review)

(ert-deftest drgnx-plans/repeated-steps-tick-their-own-checkbox ()
  ;; I5: "Run tests" under two tasks: DONE for the second ticks the second.
  (drgnx-plans-test--with root
    (let* ((alpha (drgnx-plans-test--repo root)) (plan (concat alpha "docs/plans/p.md")))
      (write-region "### Task 1\n- [ ] Run tests\n### Task 2\n- [ ] Run tests\n" nil plan nil 'silent)
      (drgnx-projects-import (list alpha))
      (let* ((b (drgnx-plans-test--read (drgnx-projects-board-file)))
             (second (string-match "\\*\\* TODO Run tests" b (1+ (string-match "\\*\\* TODO Run tests" b)))))
        (write-region (concat (substring b 0 second) "** DONE" (substring b (+ second 7))) nil (drgnx-projects-board-file) nil 'silent))
      (drgnx-projects-sync-plans)
      (should (equal (drgnx-plans-test--read plan) "### Task 1\n- [ ] Run tests\n### Task 2\n- [x] Run tests\n"))
      (should (equal (drgnx-projects-sync-plans) '(:ticked 0 :done 0))))))

(ert-deftest drgnx-plans/a-plan-keeps-its-line-endings-and-unsaved-edits-win ()
  ;; I6
  (drgnx-plans-test--with root
    (let* ((alpha (drgnx-plans-test--repo root)) (plan (concat alpha "docs/plans/p.md")))
      (let ((coding-system-for-write 'utf-8-dos)) (write-region "- [ ] Step A\n" nil plan nil 'silent))
      (drgnx-projects-import (list alpha))
      (let ((b (drgnx-plans-test--read (drgnx-projects-board-file))))
        (write-region (replace-regexp-in-string "\\*\\* TODO Step A" "** DONE Step A" b) nil (drgnx-projects-board-file) nil 'silent))
      ;; the plan is open with unsaved edits: left alone
      (let ((buf (find-file-noselect plan)))
        (unwind-protect
            (progn (with-current-buffer buf (goto-char (point-max)) (insert "- [ ] mine\n"))
                   (should (equal (drgnx-projects-sync-plans) '(:ticked 0 :done 0)))
                   (with-current-buffer buf (set-buffer-modified-p nil)))
          (kill-buffer buf)))
      (should (equal (drgnx-projects-sync-plans) '(:ticked 1 :done 0)))
      (should (equal (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally plan) (buffer-string))
                     "- [x] Step A\r\n")))))

;; the cap: 200 TODOs per project and import, the rest said
(ert-deftest drgnx-plans/an-import-takes-at-most-two-hundred-todos-and-says-so ()
  (drgnx-plans-test--with root
    (let ((alpha (drgnx-plans-test--repo root)))
      (write-region (mapconcat (lambda (i) (format "- [ ] item %d" i)) (number-sequence 1 210) "\n") nil (concat alpha "TODO.md") nil 'silent)
      (let ((r (drgnx-projects-import (list alpha))))
        (should (eql (plist-get r :todos) 200))
        (should (equal (plist-get r :capped) '("alpha")))))))

;;; plans-sync-test.el ends here
