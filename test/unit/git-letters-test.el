;;; git-letters-test.el --- batch tests: git status and look answer from the hub's letters -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call') for the hub-fed view; skipped elsewhere.  No hub: its calls are
;; recorded and its patches handed in by hand (the real status is the row `git/letters').  Pattern D: pure.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-git)
(require 'drgnx-view)
(require 'drgnx-view-env)

(defvar drgnx-hub--events)
(defvar drgnx-git-letters-test--calls nil "The hub calls drgnx-git made, newest first: (METHOD . PARAMS).")
(defvar drgnx-git-letters-test--changed nil "The roots `drgnx-git-changed-functions' ran for, newest first.")

(defun drgnx-git-letters-test--row (key text &optional status)
  (list :key key :text text
        :props (and status (list (list 0 (length text) "drgnx-git-status" status)))))

(defun drgnx-git-letters-test--class (view)
  (drgnx-view-patch-class (buffer-local-value 'drgnx-view-patch (drgnx-git--letters-buffer (gethash view drgnx-git--letters-views)))))

(defun drgnx-git-letters-test--patch (view base version ops)
  "A patch for VIEW in the class its buffer has now (the env of the selected window re-paired it)."
  (list :view view :class (drgnx-git-letters-test--class view) :hub 7 :base base :version version :env_epoch 1 :ops ops))

(defun drgnx-git-letters-test--apply (view patch)
  "PATCH arrives as the hub sends it (`view-patch'), for VIEW."
  (drgnx-view-apply-patch patch)
  (drgnx-git--hub-event "view-patch" (list :view view)))

(defmacro drgnx-git-letters-test--with (root &rest body)
  "BODY with ROOT a folder with a .git directory, the hub up (its calls recorded), nothing sent."
  (declare (indent 1))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (let* ((,root (file-name-as-directory (make-temp-file "drgnx-git-letters" t)))
            (drgnx-view-patch--buffers (make-hash-table :test #'equal))
            (drgnx-view-model--views (make-hash-table :test #'equal))
            (drgnx-view-patch--hooked nil)
            (drgnx-view-old-path nil)
            (drgnx-view-patch-send-function #'ignore)
            (drgnx-view-env-send-function #'ignore)
            (drgnx-hub--events nil)
            (drgnx-git--roots (make-hash-table :test #'equal))
            (drgnx-git-changed-functions (list (lambda (r) (push r drgnx-git-letters-test--changed))))
            (drgnx-git-letters-test--calls nil)
            (drgnx-git-letters-test--changed nil))
       (make-directory (expand-file-name ".git" ,root))
       (unwind-protect
           (cl-letf (((symbol-function 'drgnx-git--hub-ready-p) (lambda () t))
                     ((symbol-function 'drgnx-hub--call-on)
                      (lambda (_conn method params &optional _cb &rest _) (push (cons method params) drgnx-git-letters-test--calls) nil)))
             (unwind-protect (progn ,@body)
               (drgnx-git-letters-clear)
               (drgnx-view-patch-teardown)))
         (delete-directory ,root t)))))

(ert-deftest drgnx-git/status-and-look-answer-from-hub-letters ()
  "Pattern D: a refresh is a `git/letters' call naming the view, the root and the folders shown; the rows the hub
sends (a letter per changed path, a mark per shown folder, the branch) answer `drgnx-git-status' (files, folders,
what lies in an ignored or untracked folder), `drgnx-git-look', `drgnx-git-branch' and `drgnx-git-unread-p', and the
changed hook runs after each patch."
  (drgnx-git-letters-test--with root
    (let ((drgnx-git-shown-functions (list (lambda () (list (concat root "src") (concat root "docs"))))))
      (should (drgnx-git-unread-p (concat root "src/a.rs")))
      (drgnx-git-refresh root)
      (let* ((call (car drgnx-git-letters-test--calls)) (params (cdr call)) (view (plist-get params :view)))
        (should (equal "git/letters" (car call)))
        (should (equal (directory-file-name root) (directory-file-name (plist-get params :root))))
        (should (equal ["docs" "src"] (vconcat (sort (append (plist-get params :shown) nil) #'string<))))
        (should-not (drgnx-git-unread-p (concat root "src/a.rs")))
        (should-not (drgnx-git-status (concat root "src/a.rs")))   ; nothing arrived yet
        (drgnx-git-letters-test--apply
         view (drgnx-git-letters-test--patch
               view 0 1
               (list (list :reset (list (drgnx-git-letters-test--row "f:src/a.rs" "M" "modified")
                                        (drgnx-git-letters-test--row "f:docs/c.md" "U" "untracked")
                                        (drgnx-git-letters-test--row "f:build" " " "ignored")
                                        (drgnx-git-letters-test--row "d:src" "●" "modified")
                                        (drgnx-git-letters-test--row "d:." "●" "modified")
                                        (list :key "branch" :text "main"
                                              :props (list (list 0 4 "drgnx-git-branch" (list :head "main" :ahead 1 :behind 0)))))))))
        (should (equal (list root) drgnx-git-letters-test--changed))
        (should (eq 'modified (drgnx-git-status (concat root "src/a.rs"))))
        (should (eq 'untracked (drgnx-git-status (concat root "docs/c.md"))))
        (should (eq 'modified (drgnx-git-status (concat root "src/"))))      ; a folder: its mark row
        (should (eq 'modified (drgnx-git-status root)))
        (should (eq 'ignored (drgnx-git-status (concat root "build/out.o")))) ; inside an ignored folder
        (should-not (drgnx-git-status (concat root "docs/b.md")))
        (should (equal '("M" drgnx-git-modified) (drgnx-git-look (drgnx-git-status (concat root "src/a.rs")))))
        (should (equal '("U" drgnx-git-added) (drgnx-git-look 'untracked)))
        (should (equal '(:head "main" :ahead 1 :behind 0) (drgnx-git-branch root)))
        ;; a later patch: the change is committed
        (drgnx-git-letters-test--apply
         view (drgnx-git-letters-test--patch view 1 2 (list (list :remove (list "f:src/a.rs" "d:src")))))
        (should (equal (list root root) drgnx-git-letters-test--changed))
        (should-not (drgnx-git-status (concat root "src/a.rs")))))))

(ert-deftest drgnx-git/a-letters-error-reaches-the-user ()
  "Pattern D: the hub's `git-letters-error' (git could not read the status) is a warning notice and a line in the errors
buffer, never silence; the status of that root stays what it was."
  (drgnx-git-letters-test--with root
    (let ((notes nil))
      (cl-letf (((symbol-function 'drgnx-notify) (lambda (&rest a) (push a notes) nil)))
        (drgnx-git-refresh root)
        (let ((view (plist-get (cdr (car drgnx-git-letters-test--calls)) :view)))
          (with-current-buffer (get-buffer-create " *drgnx git errors*") (erase-buffer))
          (drgnx-git--hub-event "git-letters-error"
                                (list :view view :root (directory-file-name root) :error "fatal: detected dubious ownership"))
          (should (= 1 (length notes)))
          (should (eq 'warn (nth 1 (car notes))))
          (should (string-match-p "dubious ownership" (nth 2 (car notes))))
          (with-current-buffer " *drgnx git errors*"
            (should (string-match-p "dubious ownership" (buffer-string)))))))))

(ert-deftest drgnx-git/old-path-switch-reads-no-letters ()
  "Pattern D: with `drgnx-view-old-path' the hub is not asked, and a root has no letters (its status is the cache's)."
  (let ((drgnx-view-old-path t))
    (should-not (drgnx-git--hub-ready-p))
    (should-not (drgnx-git-letters-active-p))))

;;; git-letters-test.el ends here
