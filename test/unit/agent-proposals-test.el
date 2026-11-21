;;; agent-proposals-test.el --- proposals in the viewed file: accept, revert, pair -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: the calls are caught at `drgnx-hub-call'.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-hub-client)
(load (expand-file-name "modules/tools/drgnx-agent-proposals" drgnx-dir) nil t)

(declare-function drgnx-agent-proposals-set "drgnx-agent-proposals")
(declare-function drgnx-agent-proposals-accept "drgnx-agent-proposals")
(declare-function drgnx-agent-proposals-revert "drgnx-agent-proposals")
(defvar drgnx-agent-proposals--list)
(defvar drgnx-agent-proposals-paired-function)
(defvar drgnx-agent-proposals-mode)

(defmacro drgnx-agent-proposals-test--in-file (&rest body)
  "BODY in a buffer of a file in a temp git project, three lines long."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "agent-proposals" t)))
          (file (expand-file-name "a.txt" root)))
     (make-directory (expand-file-name ".git" root))
     (with-temp-file file (insert "one\ntwo\nthree\n"))
     (unwind-protect
         (with-current-buffer (find-file-noselect file)
           (unwind-protect (progn ,@body) (set-buffer-modified-p nil) (kill-buffer)))
       (delete-directory root t))))

(defconst drgnx-agent-proposals-test--frame
  (list :proposals (vector (list :session "s1" :op 7 :index 0 :start_line 2 :end_line 2 :text "two!"))))

(ert-deftest drgnx-agent-proposals/accept-marks-reviewed ()
  (drgnx-agent-proposals-test--in-file
    (let (calls)
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (m p &rest _) (push (cons m p) calls)))
                ((symbol-function 'project-current) (lambda (&rest _) (cons 'transient root))))
        (cl-letf (((symbol-function 'project-root) (lambda (_) root)))
          (drgnx-agent-proposals-set (current-buffer) drgnx-agent-proposals-test--frame)
          (should drgnx-agent-proposals-mode)
          (goto-char (point-min)) (forward-line 1)
          (drgnx-agent-proposals-accept)
          (should (equal "review/mark" (car (car calls))))
          (let ((p (cdr (car calls))))
            (should (equal "s1" (plist-get p :agent)))
            (should (equal "a.txt" (plist-get p :path)))
            (should (equal "accepted" (plist-get p :state)))))))))

(ert-deftest drgnx-agent-proposals/revert-calls-revert-hunk ()
  (drgnx-agent-proposals-test--in-file
    (let (calls)
      (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (m p &rest _) (push (cons m p) calls)))
                ((symbol-function 'project-current) (lambda (&rest _) (cons 'transient root)))
                ((symbol-function 'project-root) (lambda (_) root))
                ((symbol-function 'drgnx-work-code--worktree) (lambda (_) "/wt/s1")))
        (drgnx-agent-proposals-set (current-buffer) drgnx-agent-proposals-test--frame)
        (goto-char (point-min)) (forward-line 1)
        (drgnx-agent-proposals-revert)
        (should (equal "history/revert/hunk" (car (car calls))))
        (should (equal (list :worktree "/wt/s1" :op 7 :path "a.txt" :hunk 0) (cdr (car calls))))))))

(ert-deftest drgnx-agent-proposals/pair-edits-make-no-proposal ()
  (drgnx-agent-proposals-test--in-file
    (let ((drgnx-agent-proposals-paired-function (lambda (sid) (equal sid "s1"))))
      (drgnx-agent-proposals-set (current-buffer) drgnx-agent-proposals-test--frame)
      (should-not drgnx-agent-proposals--list)
      (should-not drgnx-agent-proposals-mode))
    ;; a frame with none (the hub made none for a paired chat) leaves the mode off
    (drgnx-agent-proposals-set (current-buffer) (list :proposals []))
    (should-not drgnx-agent-proposals-mode)))
