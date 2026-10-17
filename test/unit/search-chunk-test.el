;;; search-chunk-test.el --- batch tests: the files of a project and their chunks (semantic search) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-search-chunk)

(defun drgnx-search-chunk-test--lines (from to &optional blank)
  "Lines \"line FROM\" .. \"line TO\" joined by newlines, each BLANK line number replaced by an empty line."
  (mapconcat (lambda (n) (if (memq n blank) "" (format "line %d" n)))
             (number-sequence from to) "\n"))

(ert-deftest drgnx-search-chunk/windows-break-at-blank-lines ()
  ;; 100 lines, blank at 45 and 52: the first window (60 lines) breaks at the last blank after line 40.
  (let* ((text (drgnx-search-chunk-test--lines 1 100 '(45 52)))
         (chunks (drgnx-search-chunks text)))
    (should (= (plist-get (nth 0 chunks) :start) 1))
    (should (= (plist-get (nth 0 chunks) :end) 52))
    (should (string-suffix-p "line 51\n" (plist-get (nth 0 chunks) :text)))
    (should (= (plist-get (car (last chunks)) :end) 100)))
  ;; No blank after line 40: the window is cut at 60 lines.
  (let ((chunks (drgnx-search-chunks (drgnx-search-chunk-test--lines 1 100 '(10 30)))))
    (should (= (plist-get (nth 0 chunks) :end) 60)))
  ;; A short file is one chunk, whatever its blank lines.
  (let ((chunks (drgnx-search-chunks (drgnx-search-chunk-test--lines 1 50 '(45)))))
    (should (= (length chunks) 1))
    (should (equal (list (plist-get (car chunks) :start) (plist-get (car chunks) :end)) '(1 50)))))

(ert-deftest drgnx-search-chunk/overlap-is-ten-lines ()
  (let ((chunks (drgnx-search-chunks (drgnx-search-chunk-test--lines 1 200))))
    (should (equal (mapcar (lambda (c) (list (plist-get c :start) (plist-get c :end))) chunks)
                   '((1 60) (51 110) (101 160) (151 200))))
    (should (string-prefix-p "line 51\n" (plist-get (nth 1 chunks) :text)))
    ;; The text of a chunk is exactly its lines, and a missing final newline loses nothing.
    (should (string-suffix-p "line 200" (plist-get (car (last chunks)) :text)))
    (should (string-suffix-p "line 200" (plist-get (car (last (drgnx-search-chunks
                                                               (concat (drgnx-search-chunk-test--lines 1 200) "\n"))))
                                                   :text)))))

(ert-deftest drgnx-search-chunk/a-minified-line-is-cut ()
  (let* ((long (make-string 6000 ?x))
         (chunks (drgnx-search-chunks (concat "head\n" long "\ntail\n"))))
    (should (cl-every (lambda (c) (<= (length (plist-get c :text)) 2500)) chunks))
    (let ((pieces (cl-remove-if-not (lambda (c) (string-prefix-p "xxx" (plist-get c :text))) chunks)))
      (should (= (length pieces) 3))
      (should (cl-every (lambda (c) (and (= (plist-get c :start) 2) (= (plist-get c :end) 2))) pieces))
      (should (equal (apply #'concat (mapcar (lambda (c) (plist-get c :text)) pieces)) long)))
    (should (equal (plist-get (car chunks) :text) "head"))
    (should (equal (plist-get (car (last chunks)) :text) "tail"))
    (should (= (plist-get (car (last chunks)) :start) 3)))
  ;; Ordinary long-ish lines: a window never exceeds 2500 characters either, and no line is lost.
  (let* ((line (make-string 99 ?y))
         (text (mapconcat #'identity (make-list 120 line) "\n"))
         (chunks (drgnx-search-chunks text)))
    (should (cl-every (lambda (c) (<= (length (plist-get c :text)) 2500)) chunks))
    (should (= (plist-get (car chunks) :start) 1))
    (should (= (plist-get (car (last chunks)) :end) 120))
    (cl-loop for (a b) on chunks while b
             do (should (<= (plist-get b :start) (1+ (plist-get a :end))))
             do (should (> (plist-get b :start) (plist-get a :start))))))

(ert-deftest drgnx-search-chunk/empty-text-has-no-chunks ()
  (should-not (drgnx-search-chunks ""))
  (should-not (drgnx-search-chunks "\n\n  \n"))
  (should (= (length (drgnx-search-chunks "x")) 1)))

(ert-deftest drgnx-search-chunk/a-big-file-is-cheap ()
  (let* ((text (mapconcat (lambda (n) (format "(defun f%d () (message \"hello %d\"))" n n))
                          (number-sequence 1 25000) "\n"))
         (t0 (float-time))
         (chunks (drgnx-search-chunks text)))
    (should (> (length text) 800000))
    (should (> (length chunks) 300))
    (should (= (plist-get (car (last chunks)) :end) 25000))
    (should (< (- (float-time) t0) 5.0))))

;;;; Files

(defun drgnx-search-chunk-test--git (dir &rest args)
  "Run git ARGS in DIR with a clean git environment; error unless it succeeds."
  (let ((default-directory (file-name-as-directory dir))
        (process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
                                     (cl-remove-if (lambda (e) (string-match-p "\\`GIT_\\(DIR\\|WORK_TREE\\|INDEX_FILE\\)=" e))
                                                   process-environment))))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %S failed: %s" args (buffer-string))))))

(defun drgnx-search-chunk-test--write (dir rel content)
  (let ((file (expand-file-name rel dir)))
    (make-directory (file-name-directory file) t)
    (let ((coding-system-for-write 'no-conversion)) (write-region content nil file nil 'silent))))

(defmacro drgnx-search-chunk-test--repo (files &rest body)
  "BODY with ROOT a fresh git repo holding FILES, an alist (REL . CONTENT), all committed."
  (declare (indent 1))
  `(let ((root (file-name-as-directory (make-temp-file "drgnx-search-files" t))))
     (unwind-protect
         (progn
           (drgnx-search-chunk-test--git root "init" "-q")
           (drgnx-search-chunk-test--git root "config" "user.name" "Test")
           (drgnx-search-chunk-test--git root "config" "user.email" "test@example.com")
           (dolist (f ,files) (drgnx-search-chunk-test--write root (car f) (cdr f)))
           (drgnx-search-chunk-test--git root "add" "-A" "-f")
           ,@body)
       (delete-directory root t))))

(defun drgnx-search-chunk-test--paths (root)
  (sort (mapcar #'car (drgnx-search-files root)) #'string<))

(ert-deftest drgnx-search-files/never-dot-files-binaries-or-big-files ()
  (drgnx-search-chunk-test--repo
      `((".env" . "SECRET=1\n") (".github/x.yml" . "on: push\n") ("a/.secret/b.txt" . "hidden\n")
        ("a/.hidden" . "hidden\n") ("big.txt" . ,(make-string 2097152 ?a))
        ("edge.txt" . ,(make-string 1048576 ?e)) ("over.txt" . ,(make-string 1048577 ?e))
        ("pic.png" . ,(concat "\x89PNG\r\n\x1a\n\0\0\0\rIHDR" (make-string 40 ?z)))
        ("src/a.el" . "(message \"hi\")\n"))
    (should (equal (drgnx-search-chunk-test--paths root) '("edge.txt" "src/a.el")))
    ;; Config cannot override any of it.
    (drgnx-search-chunk-test--write root ".drgnx/search.eld"
                                    "(:include (\"**\" \".env\" \".github/*\" \"big.txt\" \"pic.png\" \"a/**\"))")
    (should (equal (drgnx-search-chunk-test--paths root) '("edge.txt" "src/a.el")))))

(ert-deftest drgnx-search-files/hashes-are-git-blob-shas ()
  (drgnx-search-chunk-test--repo '(("src/a.el" . "hello\n") ("é ü.txt" . "x\n"))
    (let ((files (drgnx-search-files root)))
      (should (equal (cdr (assoc "src/a.el" files)) "ce013625030ba8dba906f756967f9e9ca394464a"))
      (should (assoc "é ü.txt" files))
      (should (= (length (cdr (assoc "src/a.el" files))) 40)))))

(ert-deftest drgnx-search-files/skips-symlinks-and-submodules ()
  (let ((outside (make-temp-file "drgnx-search-outside" nil ".txt" "outside\n")))
    (unwind-protect
        (drgnx-search-chunk-test--repo '(("real.txt" . "real\n"))
          (make-symbolic-link outside (expand-file-name "link.txt" root))
          (make-symbolic-link "real.txt" (expand-file-name "link2.txt" root))
          (drgnx-search-chunk-test--git root "add" "-A")
          (should (equal (drgnx-search-chunk-test--paths root) '("real.txt")))
          ;; A deleted-but-still-indexed file is skipped, not an error.
          (drgnx-search-chunk-test--write root "gone.txt" "x\n")
          (drgnx-search-chunk-test--git root "add" "gone.txt")
          (delete-file (expand-file-name "gone.txt" root))
          (should (equal (drgnx-search-chunk-test--paths root) '("real.txt"))))
      (delete-file outside))))

(ert-deftest drgnx-search-files/config-excludes ()
  (drgnx-search-chunk-test--repo
      '(("src/a.el" . "a\n") ("src/deep/b.el" . "b\n") ("docs/x.md" . "x\n") ("vendor/v.js" . "v\n") ("top.md" . "t\n"))
    (should (equal (drgnx-search-chunk-test--paths root)
                   '("docs/x.md" "src/a.el" "src/deep/b.el" "top.md" "vendor/v.js")))
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:exclude (\"vendor/\" \"*.md\"))")
    (should (equal (drgnx-search-chunk-test--paths root) '("src/a.el" "src/deep/b.el")))
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:include (\"src/**/*.el\"))")
    (should (equal (drgnx-search-chunk-test--paths root) '("src/a.el" "src/deep/b.el")))
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:include (\"src/*.el\") :exclude (\"src/a.el\"))")
    (should-not (drgnx-search-chunk-test--paths root))
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:off t)")
    (should-not (drgnx-search-files root))
    (should (plist-get (drgnx-search-config root) :off))))

(defvar drgnx-search-chunk-test--pwned nil)

(ert-deftest drgnx-search-files/config-never-errors ()
  (drgnx-search-chunk-test--repo '(("a.el" . "a\n"))
    (dolist (bad '("(:include " "(:include #.(setq drgnx-search-chunk-test--pwned t))" "42" "(:include 5 :exclude \"x\")" "" "\0\0"))
      (drgnx-search-chunk-test--write root ".drgnx/search.eld" bad)
      (let ((config (drgnx-search-config root)))
        (should-not (plist-get config :off))
        (should-not (plist-get config :include))
        (should-not (plist-get config :exclude)))
      (should (equal (drgnx-search-chunk-test--paths root) '("a.el"))))
    (should-not drgnx-search-chunk-test--pwned)
    ;; No file at all: defaults.
    (delete-file (expand-file-name ".drgnx/search.eld" root))
    (should-not (plist-get (drgnx-search-config root) :off))))

(ert-deftest drgnx-search-files/not-a-git-repo ()
  (let ((dir (make-temp-file "drgnx-search-plain" t)))
    (unwind-protect
        (progn (drgnx-search-chunk-test--write dir "a.el" "a\n")
               (should-not (drgnx-search-files dir))
               (should-not (drgnx-search-files (expand-file-name "nonexistent" dir))))
      (delete-directory dir t))))

;;; search-chunk-test.el ends here
