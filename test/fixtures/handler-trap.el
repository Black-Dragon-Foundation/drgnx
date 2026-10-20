;;; handler-trap.el --- file name handlers that only record their calls, and the links an agent could plant -*- lexical-binding: t -*-
;;
;; (drgnx-test-with-handler-trap BODY...)  BODY with the file name handlers of Tramp, tramp-archive, jka-compr,
;;                                         EasyPG and quoted (`/:') names replaced by one that records each call in
;;                                         `drgnx-test-handler-calls', then does the operation without it (names in
;;                                         a `load-path' directory — Emacs loading a library — keep the real ones)
;; (drgnx-test-hostile-paths TREE)         links planted in the worktree TREE, and the paths an agent would send
;;                                         through them: (:outside PATHS :inside PATHS :back PATH :real FILE)
;; (drgnx-test-visit HOW NAME ROOT)        open NAME (relative to ROOT, as an agent or a model names it) the way a
;;                                         command does: Review's RET, the cockpit's RET, the diff's visit, Work's
;;                                         row and graph box, the cockpit graph's node; the buffer visiting it
;;
;; An agent's path is resolved with no file name handler, and the file is opened by that resolved name
;; (docs/develop/core.md, "Names an agent gave"): a test asserts `drgnx-test-handler-calls' stays nil.  Everything is
;; made under TREE and its parent (a temp dir).
(require 'cl-lib)

(defvar drgnx-test-handler-calls nil "The calls (OPERATION ARGS...) the trap handler saw, newest first.")
(defvar drgnx-test--handlers-outside nil "The file name handlers outside the trap, for Emacs's own libraries.")
(defvar drgnx-review--runs)
(defvar drgnx-review--current)
(defvar drgnx-cockpit-edits--source)
(defvar drgnx-diff--root)
(declare-function drgnx-review-visit "drgnx-review")
(declare-function drgnx-cockpit-edits-visit "drgnx-cockpit-edits")
(declare-function drgnx-diff-visit "drgnx-diff")
(declare-function drgnx-work-ui-open "drgnx-work-ui")
(declare-function drgnx-work-ui--graph-open "drgnx-work-ui")
(declare-function drgnx-cockpit--open-file "drgnx-cockpit")

(defun drgnx-test--library-name-p (name)
  "Non-nil if NAME is an absolute file name in a `load-path' directory (a test's temp tree never is)."
  (and (stringp name)
       (let* ((file-name-handler-alist nil) (dir (and (file-name-absolute-p name) (file-name-directory name))))
         (and dir (cl-some (lambda (d) (and (stringp d) (string= (file-name-as-directory d) dir))) load-path)))))

(defun drgnx-test--handler-trap (operation &rest args)
  "A file name handler that records (OPERATION . ARGS), then runs OPERATION without itself.
A name in a `load-path' directory is Emacs looking for or loading a library (Homebrew, Debian/Ubuntu and Fedora ship
Emacs's as `.el.gz'; a visit autoloads image.el, a warning warnings.el): never an agent's, it goes to the handlers
outside the trap, unrecorded."
  (if (drgnx-test--library-name-p (car args))
      (let ((file-name-handler-alist drgnx-test--handlers-outside)) (apply operation args))
    (push (cons operation args) drgnx-test-handler-calls)
    (let ((inhibit-file-name-handlers (cons #'drgnx-test--handler-trap
                                            (and (eq inhibit-file-name-operation operation) inhibit-file-name-handlers)))
          (inhibit-file-name-operation operation))
      (apply operation args))))

(defmacro drgnx-test-with-handler-trap (&rest body)
  "BODY with the trap handler on remote (Tramp), archive, compressed, `.gpg' and quoted (`/:', which
`file-name-non-special' unquotes) names, and no other handler."
  (declare (indent 0) (debug t))
  `(let ((drgnx-test-handler-calls nil)
         (drgnx-test--handlers-outside file-name-handler-alist)
         (file-name-handler-alist
          (mapcar (lambda (re) (cons re #'drgnx-test--handler-trap))
                  '("\\`/[^/|:]+:" "\\.zip\\(?:/\\|\\'\\)" "\\.g?z\\'" "\\.gpg\\'" "\\`/:"))))
     ,@body))

(defun drgnx-test-hostile-paths (tree)
  "Make the links an agent could plant in the worktree TREE (a directory name) and return the paths it would send.
:outside — through a link to `/ssh:…:/' or `/sudo::/' (absolute; Emacs quotes those), through one climbing `../' to
the root and on to `ssh:…:' or `sudo::' (Emacs follows that into Tramp), and through one to a `.gz' or `.gpg' name
beside TREE.  :inside — `back', a link that climbs to the root, goes out through `ssh:…:' and comes back with `..'
to the file `real' in TREE (resolved with no handler it is inside; with handlers on, following it reaches Tramp), and
names in TREE that only look special: `n.gz', `n.gpg', `a.zip/y' (nothing is made there).  :back is that link,
:real the file it leads to."
  (let* ((up (apply #'concat (make-list (+ 2 (length (split-string tree "/" t))) "../")))
         (beside (file-name-directory (directory-file-name tree)))
         ;; the climbing ones first: in Emacs 30 a quoted name (`/:/ssh:…', what an absolute link gives) drops Tramp's
         ;; autoloading handlers, after which nothing in that Emacs reaches Tramp — a later case would prove nothing
         (links `(("up-ssh" . ,(concat up "ssh:drgnx-test.invalid:")) ("up-sudo" . ,(concat up "sudo::"))
                  ("abs-ssh" . "/ssh:drgnx-test.invalid:/") ("abs-sudo" . "/sudo::/")
                  ("gz" . ,(concat beside "x.gz")) ("gpg" . ,(concat beside "x.gpg")))))
    (let ((file-name-handler-alist nil))            ; a remote-looking target is only text to the link
      (dolist (l links) (make-symbolic-link (cdr l) (concat tree (car l)) t))
      (write-region "real\n" nil (concat tree "real") nil 'silent)
      (make-symbolic-link (concat up "ssh:drgnx-test.invalid:/.." tree "real") (concat tree "back") t))
    (list :outside (mapcar (lambda (l) (concat tree (car l) "/y")) links)
          :inside (list (concat tree "back") (concat tree "n.gz") (concat tree "n.gpg") (concat tree "a.zip/y"))
          :back (concat tree "back") :real (concat tree "real"))))

(defun drgnx-test-visit (how name root)
  "Open NAME (relative to the folder ROOT) the way HOW does: `review' (RET on a finding), `cockpit' (RET in an agent's
edits), `diff' (Open File at Line), `work' (Work: open a row), `work-graph' (a box of the Work graph),
`cockpit-graph' (a node of the cockpit's Work graph: a spec, plan or task).  The buffer visiting the file; the caller
kills it."
  (save-window-excursion
    (pcase how
      ('review
       (require 'drgnx-review)
       (let ((drgnx-review--runs (make-hash-table :test #'equal)) (drgnx-review--current "visit"))
         (puthash "visit" (list :root root) drgnx-review--runs)
         (with-temp-buffer
           (insert (propertize "finding" 'drgnx-review-finding (list :path name :line 1)))
           (goto-char (point-min))
           (drgnx-review-visit)
           (current-buffer))))
      ('cockpit
       (require 'drgnx-cockpit-edits)
       (with-temp-buffer
         (setq drgnx-cockpit-edits--source (list :dir root))
         (cl-letf (((symbol-function 'drgnx-cockpit-edits--file-here) (lambda () name))
                   ((symbol-function 'drgnx-cockpit-edits--line-here) (lambda () 1)))
           (drgnx-cockpit-edits-visit))))
      ('diff
       (require 'drgnx-diff)
       (with-temp-buffer
         (insert (propertize "line" 'drgnx-diff-loc (list 0 name 1)))
         (goto-char (point-min))
         (setq drgnx-diff--root root)
         (cl-letf (((symbol-function 'drgnx-diff--in-view) #'ignore))
           (drgnx-diff-visit)
           (current-buffer))))
      ('work
       (require 'drgnx-work-ui)
       (cl-letf (((symbol-function 'drgnx-work-ui--node) (lambda () (list :kind 'task :path (concat root name) :line 1))))
         (drgnx-work-ui-open)))
      ('work-graph
       (require 'drgnx-work-ui)
       (drgnx-work-ui--graph-open (list :kind 'plan :node (list :path (concat root name)))))
      ('cockpit-graph
       (require 'drgnx-cockpit)
       (drgnx-cockpit--open-file (list :path (concat root name) :line 1))))))

(provide 'handler-trap)
;;; handler-trap.el ends here
