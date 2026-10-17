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

(defmacro drgnx-git-edge--with (dir &rest body)
  "BODY with DIR a fresh folder (trailing /) and empty git caches."
  (declare (indent 1))
  `(let ((,dir (file-name-as-directory (make-temp-file "drgnx-git-edge" t)))
         (drgnx-git--roots (make-hash-table :test #'equal))
         (drgnx-git--repos (make-hash-table :test #'equal)))
     (unwind-protect (progn ,@body) (delete-directory ,dir t))))

(defun drgnx-git-edge--commit (dir &rest files)
  "Make DIR a repository with FILES committed."
  (drgnx-git-edge--git dir "init" "-q")
  (dolist (f files)
    (make-directory (file-name-directory (expand-file-name f dir)) t)
    (write-region "x\n" nil (expand-file-name f dir) nil 'silent))
  (drgnx-git-edge--git dir "add" "-A")
  (drgnx-git-edge--git dir "-c" "user.email=t@drgnx" "-c" "user.name=t" "commit" "-qm" "x"))

(ert-deftest drgnx-git/a-later-git-init-is-seen ()
  ;; A folder looked at before `git init' is not "no repository" forever: a refresh looks again.
  (skip-unless (executable-find "git"))
  (drgnx-git-edge--with dir
    (write-region "x\n" nil (expand-file-name "a.txt" dir) nil 'silent)
    (should-not (drgnx-git-status (expand-file-name "a.txt" dir)))   ; painted: no repository yet
    (drgnx-git-edge--git dir "init" "-q")
    (drgnx-git-refresh dir t)
    (should (eq (drgnx-git-status (expand-file-name "a.txt" dir)) 'untracked))))

(ert-deftest drgnx-git/nested-repositories-are-refreshed ()
  ;; A repository inside the tree's root (seen when its rows were painted) is read with the root's.
  (skip-unless (executable-find "git"))
  (drgnx-git-edge--with dir
    (drgnx-git-edge--commit dir "a.txt")
    (let ((inner (file-name-as-directory (expand-file-name "vendor/lib" dir))))
      (make-directory inner t)
      (drgnx-git-edge--commit inner "b.txt")
      (write-region "changed\n" nil (expand-file-name "b.txt" inner) nil 'silent)
      (should-not (drgnx-git-status (expand-file-name "b.txt" inner)))   ; painted before any status
      (drgnx-git-refresh-tree (list dir) t)
      (should (eq (drgnx-git-status (expand-file-name "b.txt" inner)) 'modified)))))

(ert-deftest drgnx-git/a-root-row-is-tinted ()
  ;; The Explorer names a root without a trailing slash; it gets the strongest status in the repository.
  (skip-unless (executable-find "git"))
  (drgnx-git-edge--with dir
    (drgnx-git-edge--commit dir "a.txt")
    (write-region "changed\n" nil (expand-file-name "a.txt" dir) nil 'silent)
    (drgnx-git-refresh dir t)
    (should (eq (drgnx-git-status (directory-file-name dir)) 'modified))
    (should (eq (drgnx-git-status dir) 'modified))))

(ert-deftest drgnx-git/a-folder-with-only-new-files-is-not-untracked ()
  ;; A tracked folder whose only change is a new file holds new files (●); it is not itself untracked (U).
  (skip-unless (executable-find "git"))
  (drgnx-git-edge--with dir
    (drgnx-git-edge--commit dir "src/a.txt")
    (write-region "x\n" nil (expand-file-name "src/new.txt" dir) nil 'silent)
    (make-directory (expand-file-name "fresh" dir))
    (write-region "x\n" nil (expand-file-name "fresh/f.txt" dir) nil 'silent)
    (drgnx-git-refresh dir t)
    (should (eq (drgnx-git-status (expand-file-name "src/new.txt" dir)) 'untracked))
    (should (eq (drgnx-git-status (expand-file-name "src" dir)) 'added))
    (should (eq (drgnx-git-status (expand-file-name "fresh" dir)) 'untracked))))   ; a new folder: U

(provide 'wb-git-edge-test)
;;; wb-git-edge-test.el ends here
