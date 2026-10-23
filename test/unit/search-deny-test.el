;;; search-deny-test.el --- batch tests: the search indexer never reads ~/org (personal notes) -*- lexical-binding: t -*-
;; Storage §5.6, door 3: a project root inside ~/org is refused, and every path into ~/org is skipped (the board
;; excepted, opt-ins ignored).  Everything lives under a temp HOME; the canaries are random bytes made here.  A stub
;; embedder records what would have been sent; nothing reaches the network or the real ~.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-deny)
(require 'drgnx-search-index)

(defvar drgnx-search-deny-test--sent nil "Every text the stub embedder was given.")

(defun drgnx-search-deny-test--canary ()
  "32 random bytes as hex."
  (random t)
  (mapconcat (lambda (_) (format "%02x" (random 256))) (make-list 32 0) ""))

(defun drgnx-search-deny-test--embed (inputs &rest _)
  "The stub embedder: records INPUTS, answers a fixed unit vector per text."
  (setq drgnx-search-deny-test--sent (append drgnx-search-deny-test--sent (append inputs nil)))
  (setq drgnx-ai-embed-last-info (list :provider 'stub :model "stub"))
  (vconcat (mapcar (lambda (_) [1.0 0.0 0.0 0.0]) inputs)))

(defmacro drgnx-search-deny-test--with (home &rest body)
  "BODY with HOME (no trailing slash) a fresh temp HOME, its config and state directories beside it."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-search-deny" t))))
          (,home (concat root "home"))
          (process-environment (append (list (concat "HOME=" ,home) (concat "DRGNX_CONFIG_DIR=" root "config")
                                             (concat "XDG_STATE_HOME=" root "state")
                                             "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
                                       (cl-remove-if (lambda (e) (string-match-p "\\`GIT_\\(DIR\\|WORK_TREE\\|INDEX_FILE\\)=" e))
                                                     process-environment)))
          (drgnx-deny--cache nil)
          (drgnx-search-deny-test--sent nil)
          (drgnx-ai-embed-last-info nil))
     (skip-unless (sqlite-available-p))
     (unwind-protect
         (progn (make-directory ,home t) (make-directory (concat root "config") t) ,@body)
       (delete-directory root t))))

(defun drgnx-search-deny-test--write (file text &optional mode)
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'no-conversion)) (write-region text nil file nil 'silent))
  (set-file-modes file (or mode #o600)))

(defun drgnx-search-deny-test--link (at target)
  (make-directory (file-name-directory at) t)
  (make-symbolic-link target at))

(defun drgnx-search-deny-test--git-init (dir)
  (make-directory dir t)
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (zerop (call-process "git" nil t nil "init" "-q"))
        (error "git init failed: %s" (buffer-string))))))

(defun drgnx-search-deny-test--allow (home &rest files)
  "Opt FILES (HOME-relative) in: the config dir's personal-notes-allow.json."
  (drgnx-search-deny-test--write
   (expand-file-name drgnx-deny-allow-file (drgnx-paths-dir 'config))
   (json-serialize `((version . 1) (paths . ,(vconcat (mapcar (lambda (f) (concat home "/" f)) files)))))))

(defun drgnx-search-deny-test--index (root)
  "Index ROOT with the stub; its result."
  (drgnx-search-index root :embed #'drgnx-search-deny-test--embed))

(defun drgnx-search-deny-test--indexed (root)
  "The sorted paths ROOT's index holds."
  (let ((db (drgnx-search-store-open root)))
    (unwind-protect (sort (hash-table-keys (drgnx-search-store-files db)) #'string<)
      (sqlite-close db))))

(defun drgnx-search-deny-test--leaks (canaries)
  "Where any of CANARIES is: (WHERE . CANARY) for the texts sent and every file of the state dir (stores, WALs)."
  (let ((state (drgnx-state-dir)) out)
    (dolist (c canaries)
      (when (seq-some (lambda (text) (string-search c text)) drgnx-search-deny-test--sent)
        (push (cons 'sent c) out))
      (when (file-directory-p state)
        (dolist (f (directory-files-recursively state ""))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally f)
            (when (search-forward c nil t) (push (cons f c) out))))))
    out))

(ert-deftest drgnx-search-deny/org-root-refused ()
  (drgnx-search-deny-test--with home
    (let ((notes (drgnx-search-deny-test--canary)) (code (drgnx-search-deny-test--canary)))
      (drgnx-search-deny-test--write (concat home "/org/notes.org") (format "* %s\n" notes))
      (drgnx-search-deny-test--git-init (concat home "/org"))
      (drgnx-search-deny-test--git-init (concat home "/org/proj"))
      (drgnx-search-deny-test--write (concat home "/org/proj/main.el") (format ";; %s\n" code))
      (drgnx-search-deny-test--write (concat home "/org/proj/.drgnx/search.eld") "(:include (\"*\"))\n")
      (drgnx-search-deny-test--link (concat home "/proj-link") (concat home "/org/proj"))
      (dolist (root (list (concat home "/org") (concat home "/org/proj") (concat home "/org/proj/")
                          (concat home "/proj-link") (concat home "/org/proj/../proj")))
        (should (equal (list root (plist-get (drgnx-search-deny-test--index root) :error))
                       (list root drgnx-search-personal-notes-refusal)))
        (should (equal (should-error (drgnx-search-files root) :type 'drgnx-search-files-error)
                       (list 'drgnx-search-files-error drgnx-search-personal-notes-refusal)))
        (should-not (file-exists-p (drgnx-search-store-file root))))
      (should-not drgnx-search-deny-test--sent)
      (should-not (drgnx-search-deny-test--leaks (list notes code))))))

(ert-deftest drgnx-search-deny/links-into-org-skipped ()
  (drgnx-search-deny-test--with home
    (let ((notes (drgnx-search-deny-test--canary)) (other (drgnx-search-deny-test--canary)))
      (drgnx-search-deny-test--write (concat home "/org/notes.org") (format "* %s\n" notes))
      (drgnx-search-deny-test--write (concat home "/org/sub/x.md") (format "# %s\n" other))
      ;; a project with links into org: to a file, to the folder, through dot-dot
      (drgnx-search-deny-test--git-init (concat home "/proj"))
      (drgnx-search-deny-test--write (concat home "/proj/main.el") ";; the project's code\n")
      (drgnx-search-deny-test--link (concat home "/proj/n.org") (concat home "/org/notes.org"))
      (drgnx-search-deny-test--link (concat home "/proj/o") "../org")
      (drgnx-search-deny-test--link (concat home "/proj/up") "..")
      (should (equal (plist-get (drgnx-search-deny-test--index (concat home "/proj")) :error) nil))
      (should (equal (drgnx-search-deny-test--indexed (concat home "/proj")) '("main.el")))
      ;; HOME as a project: org/ is a folder of it, and links at HOME's top lead there too
      (drgnx-search-deny-test--git-init home)
      (drgnx-search-deny-test--write (concat home "/readme.md") "# the home project\n")
      (drgnx-search-deny-test--link (concat home "/n.org") (concat home "/org/notes.org"))
      (drgnx-search-deny-test--link (concat home "/linkdir") (concat home "/org/sub"))
      (should (equal (plist-get (drgnx-search-deny-test--index home) :error) nil))
      (should (equal (drgnx-search-deny-test--indexed home) '("readme.md")))
      (should (equal (mapcar #'car (drgnx-search-files home)) '("readme.md")))
      (should (seq-some (lambda (text) (string-search "the home project" text)) drgnx-search-deny-test--sent))
      (should-not (drgnx-search-deny-test--leaks (list notes other))))))

(ert-deftest drgnx-search-deny/board-is-read ()
  (drgnx-search-deny-test--with home
    (let ((notes (drgnx-search-deny-test--canary)) (bak (drgnx-search-deny-test--canary)))
      (drgnx-search-deny-test--git-init home)
      (drgnx-search-deny-test--write (concat home "/readme.md") "# the home project\n")
      (drgnx-search-deny-test--write (concat home "/org/board.org") "* TODO the board's task\n")
      (drgnx-search-deny-test--write (concat home "/org/board.org.bak") (format "* %s\n" bak))
      (drgnx-search-deny-test--write (concat home "/org/notes.org") (format "* %s\n" notes))
      (should-not (drgnx-search-denied-p (concat home "/org/board.org")))
      (should (equal (plist-get (drgnx-search-deny-test--index home) :error) nil))
      (should (equal (drgnx-search-deny-test--indexed home) '("org/board.org" "readme.md")))
      (should (seq-some (lambda (text) (string-search "the board's task" text)) drgnx-search-deny-test--sent))
      (should-not (drgnx-search-deny-test--leaks (list notes bak))))))

(ert-deftest drgnx-search-deny/opt-ins-are-ignored ()
  (drgnx-search-deny-test--with home
    (let ((notes (drgnx-search-deny-test--canary)) (reading (drgnx-search-deny-test--canary)))
      (drgnx-search-deny-test--git-init home)
      (drgnx-search-deny-test--write (concat home "/readme.md") "# the home project\n")
      (drgnx-search-deny-test--write (concat home "/org/notes.org") (format "* %s\n" notes))
      (drgnx-search-deny-test--write (concat home "/org/reading.org") (format "* %s\n" reading))
      (drgnx-search-deny-test--allow home "org/notes.org" "org/reading.org")
      ;; the work graph may read reading.org now (notes.org never); the code index reads neither
      (should-not (drgnx-deny-path-p (concat home "/org/reading.org")))
      (should (drgnx-deny-path-p (concat home "/org/notes.org")))
      (should (drgnx-search-denied-p (concat home "/org/reading.org")))
      (should (equal (plist-get (drgnx-search-deny-test--index home) :error) nil))
      (should (equal (drgnx-search-deny-test--indexed home) '("readme.md")))
      (should-not (drgnx-search-deny-test--leaks (list notes reading))))))

(defun drgnx-search-deny-test--config (name spec home)
  "Write the config file NAME from the table's SPEC (an alist: json, raw, mode)."
  (drgnx-search-deny-test--write
   (expand-file-name name (drgnx-paths-dir 'config))
   (string-replace "$HOME" home (or (alist-get 'raw spec) (json-serialize (alist-get 'json spec))))
   (if (alist-get 'mode spec) (string-to-number (alist-get 'mode spec) 8) #o600)))

(defun drgnx-search-deny-test--refusal (root)
  "The refusal `drgnx-search-files' signals for ROOT, or nil (another failure, or none)."
  (condition-case e (progn (drgnx-search-files root) nil)
    (drgnx-search-files-error (and (equal (cadr e) drgnx-search-personal-notes-refusal) (cadr e)))
    (error nil)))

(ert-deftest drgnx-search-deny/the-shared-table ()
  ;; test/fixtures/deny-cases.json, norn::deny's and drgnx-deny's table: the indexer's door against each check (denied
  ;; or opted in: skipped) and each project root (denied: refused; one that contains org: its org paths skipped)
  (let* ((json (with-temp-buffer
                 (insert-file-contents (expand-file-name "test/fixtures/deny-cases.json" drgnx-dir))
                 (json-parse-buffer :object-type 'alist)))
         (os (if (eq system-type 'darwin) "macos" "linux"))
         (checks 0) (roots 0))
    (seq-doseq (c (alist-get 'cases json))
      (when (and (or (alist-get 'check c) (alist-get 'root c)) (member (alist-get 'os c) (list nil os)))
        (drgnx-search-deny-test--with home
          (dolist (d (append (alist-get 'dirs c) nil)) (make-directory (concat home "/" d) t))
          (dolist (f (append (alist-get 'files c) nil)) (drgnx-search-deny-test--write (concat home "/" f) "fixture\n"))
          (dolist (l (append (alist-get 'links c) nil))
            (drgnx-search-deny-test--link (concat home "/" (aref l 0)) (string-replace "$HOME" home (aref l 1))))
          (when (alist-get 'deny c) (drgnx-search-deny-test--config drgnx-deny-deny-file (alist-get 'deny c) home))
          (when (alist-get 'allow c) (drgnx-search-deny-test--config drgnx-deny-allow-file (alist-get 'allow c) home))
          (let ((name (alist-get 'name c)) (verdict (alist-get 'verdict c)))
            (if-let* ((check (alist-get 'check c)))
                (let ((path (string-replace "$HOME" home check)))
                  (should (equal (list name (and (drgnx-search-denied-p path) t))
                                 (list name (and (member verdict '("denied" "opted-in")) t))))
                  (cl-incf checks))
              (let ((root (string-replace "$HOME" home (alist-get 'root c))))
                (should (equal (list name (drgnx-search-deny-test--refusal root))
                               (list name (and (equal verdict "denied") drgnx-search-personal-notes-refusal))))
                (dolist (inside (append (alist-get 'contains c) nil))
                  (should (equal (list name (and (drgnx-search-denied-p (string-replace "$HOME" home inside)) t))
                                 (list name t))))
                (cl-incf roots)))))))
    (should (> checks 35))
    (should (> roots 3))))

(provide 'search-deny-test)
;;; search-deny-test.el ends here
