;;; projects-eld-test.el --- batch tests: projects.eld and projects-imported.eld on the config layer -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-config' (config and state folders in a fresh temp root).  Fixture
;; repositories and boards live in that root, never in ~/workspace or ~/org.  The concurrency tests start child
;; `emacs --batch' processes (the runner's environment) and wait for them under a 30 s bound.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-projects)
(require 'drgnx-work)

(defmacro drgnx-projects-eld-test--with (&rest body)
  "BODY under `drgnx-test-with-config', with the board and gryphn's list inside its root."
  (declare (indent 0))
  `(drgnx-test-with-config
     (let ((drgnx-projects-board-file (concat drgnx-test-config-root "org/board.org"))
           (drgnx-projects-gryphn-file (concat drgnx-test-config-root "gryphn/projects.tsv")))
       ,@body)))

(defun drgnx-projects-eld-test--repo (name &optional todo)
  "A git repository NAME under the test root (with TODO.md holding TODO), as a directory name."
  (let ((dir (concat drgnx-test-config-root "ws/" name "/")))
    (make-directory dir t)
    (let ((default-directory dir))
      (call-process "git" nil nil nil "init" "-q"))
    (when todo (write-region todo nil (concat dir "TODO.md") nil 'silent))
    dir))

(defun drgnx-projects-eld-test--bytes (file)
  "FILE's bytes as a unibyte string, nil when missing."
  (when (file-exists-p file)
    (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string))))

(defun drgnx-projects-eld-test--roots ()
  "The roots `drgnx-projects-read' lists."
  (mapcar (lambda (p) (plist-get p :root)) (plist-get (drgnx-projects-read) :projects)))

(defun drgnx-projects-eld-test--imported-file ()
  (expand-file-name "projects-imported.eld" (drgnx-state-dir)))

(defun drgnx-projects-eld-test--children (forms)
  "Run each of FORMS (strings) in a child `emacs --batch' with this run's environment and load path; wait for all.
Fails the test unless every child exits 0."
  (let* ((at (+ (float-time) 2)) (bufs nil)
         (procs (mapcar
                 (lambda (form)
                   (let ((b (generate-new-buffer " *projects-eld-child*" t)))
                     (push b bufs)
                     (make-process
                      :name "projects-eld-child" :buffer b :noquery t
                      :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                     "--eval" (format "(setq load-path '%S load-prefer-newer t)" load-path)
                                     "--eval" "(require 'drgnx-projects)"
                                     "--eval" (format "(progn (sleep-for (max 0 (- %f (float-time)))) %s)" at form)))))
                 forms))
         (deadline (+ (float-time) 30)))
    (unwind-protect
        (progn
          (while (and (cl-some #'process-live-p procs) (< (float-time) deadline)) (accept-process-output nil 0.05))
          (dolist (p procs) (should (not (process-live-p p))))
          (cl-loop for p in procs for b in (reverse bufs)
                   do (should (equal (list (process-exit-status p) (with-current-buffer b (buffer-string)))
                                     (list 0 (with-current-buffer b (buffer-string)))))))
      (mapc #'delete-process procs)
      (mapc #'kill-buffer bufs))))

;;;; The definition

(ert-deftest drgnx-projects-eld/the-definition-and-the-read-shape ()
  (drgnx-projects-eld-test--with
    (let ((def (gethash 'projects drgnx-config--defs)))
      (should (equal (plist-get def :file) "projects.eld"))
      (should (eq (plist-get def :last-good) t))
      (should (eq (plist-get def :reload) 'mtime))
      (should (equal (plist-get def :default) '(:projects nil))))
    (should (equal (drgnx-projects-read) '(:version 1 :projects nil)))
    (drgnx-test-config-put 'projects "(:version 1 :projects ((:name \"a\" :root \"~/a-project\" :url nil)))\n")
    (let ((p (car (plist-get (drgnx-projects-read) :projects))))
      (should (equal (plist-get (drgnx-projects-read) :version) 1))
      (should (equal (plist-get p :root) (expand-file-name "~/a-project")))   ; roots are expanded on the way out
      (should (equal (plist-get p :name) "a")))
    (should (equal (plist-get (car (plist-get (drgnx-config-get 'projects) :projects)) :root)
                   "~/a-project"))))                                           ; the applied value is not changed

;;;; A file with a mistake

(ert-deftest drgnx-projects-eld/an-unreadable-file-is-never-overwritten-by-import ()
  ;; The spec's wipe: a truncated file used to read as empty and be rewritten with only the new projects.
  (drgnx-projects-eld-test--with
    (let* ((alpha (drgnx-projects-eld-test--repo "alpha" "- [ ] one\n"))
           (file (drgnx-test-config-put 'projects "(:version 1 :projects ((:name \"a\""))
           (bytes (drgnx-projects-eld-test--bytes file))
           (board "* mine\n"))
      (make-directory (file-name-directory (drgnx-projects-board-file)) t)
      (write-region board nil (drgnx-projects-board-file) nil 'silent)
      (let ((err (should-error (drgnx-projects-import (list alpha)) :type 'user-error)))
        (should (eq (car err) 'drgnx-config-refused))
        (should (string-match-p "projects\\.eld" (error-message-string err))))
      (should (equal (drgnx-projects-eld-test--bytes file) bytes))
      (should (equal (drgnx-projects-eld-test--bytes (drgnx-projects-board-file)) board))   ; the board is untouched
      (should-not (file-exists-p (drgnx-projects-eld-test--imported-file)))
      (should-error (drgnx-projects--remember (list (list :name "alpha" :root (directory-file-name alpha) :url nil)))
                    :type 'drgnx-config-refused)
      (should (equal (drgnx-projects-eld-test--bytes file) bytes)))))

(ert-deftest drgnx-projects-eld/a-newer-file-is-never-overwritten-by-import ()
  (drgnx-projects-eld-test--with
    (let* ((alpha (drgnx-projects-eld-test--repo "alpha"))
           (file (drgnx-test-config-put 'projects "(:version 9 :projects nil)\n"))
           (bytes (drgnx-projects-eld-test--bytes file)))
      (should-error (drgnx-projects-import (list alpha)) :type 'drgnx-config-refused)
      (should (equal (drgnx-projects-eld-test--bytes file) bytes))
      (should-not (file-exists-p (drgnx-projects-board-file))))))

(ert-deftest drgnx-projects-eld/a-mistake-uses-the-last-good-copy-for-readers ()
  (drgnx-projects-eld-test--with
    (let ((alpha (drgnx-projects-eld-test--repo "alpha")))
      (drgnx-projects-import (list alpha) :todos nil)
      (should (equal (drgnx-projects-eld-test--roots) (list (directory-file-name alpha))))
      (should (equal (drgnx-work-default-roots) (list (directory-file-name alpha))))
      ;; an edit with a mistake: readers (the work tracker, search) keep the roots
      (let ((file (drgnx-test-config-put 'projects "(:version 1 :projects ((:name \"a\" :root ")))
        (should (equal (drgnx-projects-eld-test--roots) (list (directory-file-name alpha))))
        (should (equal (drgnx-work-default-roots) (list (directory-file-name alpha))))
        (should (eq (plist-get (drgnx-config-read 'projects) :status) 'problem))
        (should (equal (drgnx-projects-eld-test--bytes file) "(:version 1 :projects ((:name \"a\" :root "))))))

;;;; Writing

(ert-deftest drgnx-projects-eld/a-user-print-length-of-2-keeps-every-project ()
  (drgnx-projects-eld-test--with
    (let ((repos (mapcar (lambda (n) (drgnx-projects-eld-test--repo n)) '("a" "b" "c" "d" "e"))))
      (drgnx-projects-import (seq-take repos 3) :todos nil)
      (let ((print-length 2) (print-level 2))
        (drgnx-projects-import repos :todos nil))
      (should (equal (drgnx-projects-eld-test--roots) (mapcar #'directory-file-name repos)))
      (should (equal (drgnx-projects-eld-test--roots)
                     (mapcar (lambda (p) (plist-get p :root))
                             (plist-get (plist-get (drgnx-file-read (drgnx-config-file 'projects)) :data) :projects)))))))

(ert-deftest drgnx-projects-eld/import-appends-and-keeps-comments ()
  (drgnx-projects-eld-test--with
    (let* ((alpha (drgnx-projects-eld-test--repo "alpha"))
           (beta (drgnx-projects-eld-test--repo "beta"))
           (head ";; my projects, by hand\n(:version 1\n :note \"mine\"   ; an unknown key\n :projects\n")
           (entry " ((:name \"alpha\" :root \"%s\" :url nil))")
           (tail ")\n"))
      (drgnx-test-config-put 'projects (concat head (format entry (directory-file-name alpha)) tail))
      (drgnx-projects-import (list alpha beta) :todos nil)
      (let ((text (drgnx-test-config-text 'projects)))
        (should (string-prefix-p ";; my projects, by hand\n(:version 1\n :note \"mine\"   ; an unknown key\n" text))
        (should (string-match-p (regexp-quote (directory-file-name beta)) text)))
      (should (equal (drgnx-projects-eld-test--roots) (mapcar #'directory-file-name (list alpha beta))))
      ;; nothing new: no write at all
      (let ((before (drgnx-projects-eld-test--bytes (drgnx-config-file 'projects)))
            (entries (list (list :name "beta" :root (directory-file-name beta) :url nil))))
        (drgnx-projects--remember entries)
        (should (equal (drgnx-projects-eld-test--bytes (drgnx-config-file 'projects)) before))))))

(ert-deftest drgnx-projects-eld/remember-knows-a-root-through-a-symlink ()
  (drgnx-projects-eld-test--with
    (let* ((alpha (drgnx-projects-eld-test--repo "alpha"))
           (link (concat drgnx-test-config-root "link")))
      (make-symbolic-link (directory-file-name alpha) link)
      (drgnx-projects-import (list alpha) :todos nil)
      (let ((before (drgnx-projects-eld-test--bytes (drgnx-config-file 'projects))))
        (drgnx-projects--remember (list (list :name "link" :root link :url nil)))
        (should (equal (drgnx-projects-eld-test--bytes (drgnx-config-file 'projects)) before))))))

;;;; projects-imported.eld

(ert-deftest drgnx-projects-eld/an-unreadable-imported-file-is-backed-up ()
  (drgnx-projects-eld-test--with
    (let* ((alpha (drgnx-projects-eld-test--repo "alpha" "- [ ] one\n"))
           (file (drgnx-projects-eld-test--imported-file)))
      (make-directory (file-name-directory file) t)
      (write-region "(\"half" nil file nil 'silent)
      (should (= (hash-table-count (drgnx-projects--imported)) 0))            ; unreadable: an empty table
      (should (eql (plist-get (drgnx-projects-import (list alpha)) :todos) 1))
      (should (= (hash-table-count (drgnx-projects--imported)) 1))
      (let ((backups (directory-files (file-name-directory file) nil "\\`projects-imported\\.eld\\.bak-")))
        (should (= (length backups) 1))
        (should (equal (drgnx-projects-eld-test--bytes (expand-file-name (car backups) (file-name-directory file)))
                       "(\"half"))))))

(ert-deftest drgnx-projects-eld/two-imports-at-once-both-land ()
  (drgnx-projects-eld-test--with
    (let* ((a (drgnx-projects-eld-test--repo "alpha" "- [ ] one\n"))
           (b (drgnx-projects-eld-test--repo "beta" "- [ ] two\n"))
           (form (lambda (repo board)
                   (format "(let ((drgnx-projects-board-file %S)) (dotimes (_ 5) (drgnx-projects-import (list %S))))"
                           (concat drgnx-test-config-root board) repo))))
      (drgnx-projects-eld-test--children
       (list (funcall form a "org/a.org") (funcall form b "org/b.org")))
      (should (equal (sort (drgnx-projects-eld-test--roots) #'string<)
                     (mapcar #'directory-file-name (list a b))))
      (should (= (hash-table-count (drgnx-projects--imported)) 2))
      (should (eq (plist-get (drgnx-config-read 'projects) :status) 'ok)))))

(ert-deftest drgnx-projects-eld/project-el-list-is-changed-under-its-lock-and-replaced-whole ()
  ;; project.el writes its list in place (truncate, then write) with no lock: a second import reading it meanwhile
  ;; read a cut-off file and failed (CI, Nidhogg 31.1).  drgnx changes it the way it changes its own files.
  (drgnx-projects-eld-test--with
    (let* ((alpha (drgnx-projects-eld-test--repo "alpha"))
           (beta (drgnx-projects-eld-test--repo "beta"))
           (gamma (drgnx-projects-eld-test--repo "gamma"))
           (list-file (expand-file-name "projects" (drgnx-state-dir)))
           (entry (lambda (dir) (list (list :name "x" :root (directory-file-name dir) :url nil))))
           (dirs (lambda () (mapcar #'car (plist-get (drgnx-file-read list-file) :data))))
           (inode (lambda () (file-attribute-inode-number (file-attributes list-file)))))
      (drgnx-projects--remember (funcall entry alpha))
      (should (equal (funcall dirs) (list alpha)))
      (let ((before (funcall inode)))
        (drgnx-projects--remember (funcall entry beta))
        (should (equal (funcall dirs) (list beta alpha)))
        (should-not (equal (funcall inode) before)))                         ; a new file renamed over the old one
      (let ((bytes (drgnx-projects-eld-test--bytes list-file))
            (held (drgnx-file--lock (file-truename list-file) 0)))
        (unwind-protect
            (should-error (drgnx-projects--remember (funcall entry gamma)) :type 'drgnx-file-busy)
          (drgnx-file--unlock held))
        (should (equal (drgnx-projects-eld-test--bytes list-file) bytes))))))

(ert-deftest drgnx-projects-eld/imported-keys-merge-across-processes ()
  (drgnx-projects-eld-test--with
    (let ((form (lambda (tag)
                  (format "(dotimes (i 40) (let ((h (make-hash-table :test #'equal)))
                                             (puthash (format \"%s-%%d\" i) t h)
                                             (drgnx-projects--save-imported h)))" tag))))
      (drgnx-projects-eld-test--children (list (funcall form "a") (funcall form "b")))
      (let ((keys (read (drgnx-projects-eld-test--bytes (drgnx-projects-eld-test--imported-file)))))
        (should (= (length keys) 80))
        (should (equal keys (sort (copy-sequence keys) #'string<)))))))

;;; projects-eld-test.el ends here
