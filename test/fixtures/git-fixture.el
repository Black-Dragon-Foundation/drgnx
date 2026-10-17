;;; git-fixture.el --- for git tests: a temp repository, git with a fixed identity, nothing of the user's -*- lexical-binding: t -*-
(require 'subr-x)

(defun drgnx-git-test (dir &rest args)
  "Run git ARGS in DIR; its output, trimmed (an error when git fails)."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun drgnx-git-test-write (repo file text)
  "Write TEXT to FILE (relative) in REPO, making its directory."
  (let ((f (expand-file-name file repo)))
    (make-directory (file-name-directory f) t)
    (write-region text nil f nil 'silent)))

(defmacro drgnx-git-test-with-repo (&rest body)
  "BODY with REPO a fresh repository (branch main, no commit yet) in a temp dir; HOME there too, the user's git
config never read, the author \"Ada\" unless a commit sets another."
  (declare (indent 0))
  `(let* ((tmp (file-name-as-directory (make-temp-file "drgnx-git" t)))
          (repo (file-name-as-directory (concat tmp "repo")))
          (process-environment (append (list (concat "HOME=" tmp) "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1"
                                             "GIT_AUTHOR_NAME=Ada" "GIT_AUTHOR_EMAIL=ada@t.invalid"
                                             "GIT_COMMITTER_NAME=Ada" "GIT_COMMITTER_EMAIL=ada@t.invalid")
                                       process-environment)))
     (unwind-protect
         (progn
           (make-directory repo t)
           (drgnx-git-test repo "init" "-q" "-b" "main")
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p tmp (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil))
           (kill-buffer b)))
       (delete-directory tmp t))))

(provide 'git-fixture)
;;; git-fixture.el ends here
