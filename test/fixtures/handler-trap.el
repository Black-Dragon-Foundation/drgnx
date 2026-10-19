;;; handler-trap.el --- file name handlers that only record their calls, and the links an agent could plant -*- lexical-binding: t -*-
;;
;; (drgnx-test-with-handler-trap BODY...)  BODY with the file name handlers of Tramp, tramp-archive, jka-compr and
;;                                         EasyPG names replaced by one that records each call in
;;                                         `drgnx-test-handler-calls', then does the operation without it
;; (drgnx-test-hostile-paths TREE)         links planted in the worktree TREE, and the paths an agent would send
;;                                         through them: (:outside PATHS :inside PATHS)
;;
;; An agent's path is resolved with no file name handler (docs/develop/core.md, "Names an agent gave"): a test asserts
;; `drgnx-test-handler-calls' stays nil.  Everything is made under TREE and its parent (a temp dir).
(require 'cl-lib)

(defvar drgnx-test-handler-calls nil "The calls (OPERATION ARGS...) the trap handler saw, newest first.")

(defun drgnx-test--handler-trap (operation &rest args)
  "A file name handler that records (OPERATION . ARGS), then runs OPERATION without itself."
  (push (cons operation args) drgnx-test-handler-calls)
  (let ((inhibit-file-name-handlers (cons #'drgnx-test--handler-trap
                                          (and (eq inhibit-file-name-operation operation) inhibit-file-name-handlers)))
        (inhibit-file-name-operation operation))
    (apply operation args)))

(defmacro drgnx-test-with-handler-trap (&rest body)
  "BODY with the trap handler on remote (Tramp), archive, compressed and `.gpg' names, and no other handler."
  (declare (indent 0) (debug t))
  `(let ((drgnx-test-handler-calls nil)
         (file-name-handler-alist
          (mapcar (lambda (re) (cons re #'drgnx-test--handler-trap))
                  '("\\`/[^/|:]+:" "\\.zip\\(?:/\\|\\'\\)" "\\.g?z\\'" "\\.gpg\\'"))))
     ,@body))

(defun drgnx-test-hostile-paths (tree)
  "Make the links an agent could plant in the worktree TREE (a directory name) and return the paths it would send.
:outside — through a link to `/ssh:…:/' or `/sudo::/' (absolute; Emacs quotes those), through one climbing `../' to
the root and on to `ssh:…:' or `sudo::' (Emacs follows that into Tramp), and through one to a `.gz' or `.gpg' name
beside TREE.  :inside — names in TREE that only look special: `n.gz', `n.gpg', `a.zip/y' (nothing is made there)."
  (let* ((up (apply #'concat (make-list (+ 2 (length (split-string tree "/" t))) "../")))
         (beside (file-name-directory (directory-file-name tree)))
         ;; the climbing ones first: in Emacs 30 a quoted name (`/:/ssh:…', what an absolute link gives) drops Tramp's
         ;; autoloading handlers, after which nothing in that Emacs reaches Tramp — a later case would prove nothing
         (links `(("up-ssh" . ,(concat up "ssh:drgnx-test.invalid:")) ("up-sudo" . ,(concat up "sudo::"))
                  ("abs-ssh" . "/ssh:drgnx-test.invalid:/") ("abs-sudo" . "/sudo::/")
                  ("gz" . ,(concat beside "x.gz")) ("gpg" . ,(concat beside "x.gpg")))))
    (let ((file-name-handler-alist nil))            ; a remote-looking target is only text to the link
      (dolist (l links) (make-symbolic-link (cdr l) (concat tree (car l)) t)))
    (list :outside (mapcar (lambda (l) (concat tree (car l) "/y")) links)
          :inside (list (concat tree "n.gz") (concat tree "n.gpg") (concat tree "a.zip/y")))))

(provide 'handler-trap)
;;; handler-trap.el ends here
