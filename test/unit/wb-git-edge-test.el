;;; wb-git-edge-test.el --- batch tests: git decorations, edge cases -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-git)

(defun drgnx-git-edge--git (dir &rest args)
  "Run git ARGS in DIR, quietly."
  (let ((default-directory dir)) (apply #'call-process "git" nil nil nil args)))

(defun drgnx-git-edge--drain ()
  "Let pending process output (git's stderr pipe) arrive."
  (let ((n 0))
    (while (and (< (setq n (1+ n)) 100)
                (seq-some (lambda (p) (string-prefix-p "drgnx-git" (process-name p))) (process-list)))
      (accept-process-output nil 0.01))))

(ert-deftest drgnx-git/errors-buffer-stays-bounded ()
  ;; No "stderr finished" line per run, and git's complaints are kept to a bounded tail.
  (skip-unless (executable-find "git"))
  (let ((dir (file-name-as-directory (make-temp-file "drgnx-git-err" t)))
        (drgnx-git--roots (make-hash-table :test #'equal))
        (drgnx-git--repos (make-hash-table :test #'equal))
        (drgnx-git-errors-max 200))
    (unwind-protect
        (progn
          (when (get-buffer " *drgnx git errors*") (kill-buffer " *drgnx git errors*"))
          (make-directory (expand-file-name ".git" dir))   ; not a repository: git fails, on stderr
          (dotimes (_ 3) (drgnx-git-refresh dir t) (drgnx-git-edge--drain))
          (with-current-buffer " *drgnx git errors*"
            (should (string-search "fatal" (buffer-string)))
            (should-not (string-search "finished" (buffer-string)))
            (dotimes (_ 6) (drgnx-git-refresh dir t) (drgnx-git-edge--drain))
            (should (<= (buffer-size) 200)))
          (should-not (seq-filter (lambda (p) (string-prefix-p "drgnx-git" (process-name p))) (process-list))))
      (delete-directory dir t))))

(provide 'wb-git-edge-test)
;;; wb-git-edge-test.el ends here
