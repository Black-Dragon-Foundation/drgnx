;;; search-chunk-test.el --- batch tests: the files of a project and their chunks (semantic search) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-search-chunk)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/measure-fixture" drgnx-dir) nil t)

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
  (drgnx-test-compile "drgnx-search-chunk")
  (let* ((lines (lambda (n) (mapconcat (lambda (n) (format "(defun f%d () (message \"hello %d\"))" n n)) (number-sequence 1 n) "\n")))
         (text (funcall lines 25000))
         (chunks (drgnx-search-chunks text)))
    (should (> (length text) 800000))
    (should (> (length chunks) 300))
    (should (= (plist-get (car (last chunks)) :end) 25000))
    ;; linear: 5× the lines allocate about 5× (a rescan per chunk would be far more)
    (let ((small (drgnx-test-alloc (drgnx-search-chunks (funcall lines 5000))))
          (big (drgnx-test-alloc (drgnx-search-chunks text))))
      (should (<= big (* 1.25 5 small))))))

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
  (let ((file (concat (file-name-as-directory dir) rel)))
    (make-directory (file-name-directory file) t)
    (let ((coding-system-for-write 'no-conversion) (file-name-handler-alist nil)) (write-region content nil file nil 'silent))))

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

(ert-deftest drgnx-search-files/hashes-follow-the-working-tree ()
  (drgnx-search-chunk-test--repo '(("a.txt" . "hello\n") ("b.txt" . "bee\n") ("gone.txt" . "x\n"))
    (drgnx-search-chunk-test--git root "commit" "-q" "-m" "init")
    (let ((before (drgnx-search-files root)))
      ;; An unstaged edit changes the hash, to the blob SHA of the new content.
      (drgnx-search-chunk-test--write root "a.txt" "hello again\n")
      (let ((after (drgnx-search-files root)))
        (should-not (equal (cdr (assoc "a.txt" after)) (cdr (assoc "a.txt" before))))
        (should (equal (cdr (assoc "a.txt" after))
                       (with-temp-buffer
                         (call-process "git" nil t nil "hash-object" (expand-file-name "a.txt" root))
                         (string-trim (buffer-string)))))
        (should (equal (cdr (assoc "b.txt" after)) (cdr (assoc "b.txt" before)))))
      ;; An untracked file is listed with a hash; an ignored one is not.
      (drgnx-search-chunk-test--write root ".gitignore" "ignored.txt\nbuild/\n")
      (drgnx-search-chunk-test--write root "new.txt" "hello\n")
      (drgnx-search-chunk-test--write root "ignored.txt" "secret\n")
      (drgnx-search-chunk-test--write root "build/out.txt" "out\n")
      (let ((files (drgnx-search-files root)))
        (should (equal (cdr (assoc "new.txt" files)) "ce013625030ba8dba906f756967f9e9ca394464a"))
        (should-not (assoc "ignored.txt" files))
        (should-not (assoc "build/out.txt" files))
        (should-not (assoc ".gitignore" files)))
      ;; A tracked file deleted on disk is not listed.
      (delete-file (expand-file-name "gone.txt" root))
      (should-not (member "gone.txt" (drgnx-search-chunk-test--paths root)))
      (should (equal (drgnx-search-chunk-test--paths root) '("a.txt" "b.txt" "new.txt"))))))

(ert-deftest drgnx-search-files/an-empty-repo-with-untracked-files ()
  (let ((root (file-name-as-directory (make-temp-file "drgnx-search-files" t))))
    (unwind-protect
        (progn (drgnx-search-chunk-test--git root "init" "-q")
               (drgnx-search-chunk-test--write root "a.el" "a\n")
               (should (equal (drgnx-search-chunk-test--paths root) '("a.el"))))
      (delete-directory root t))))

(defmacro drgnx-search-chunk-test--git-fails-on (word &rest body)
  "BODY with the git runner made to fail (really, with a bad option) for commands containing WORD."
  (declare (indent 1))
  `(let ((orig (symbol-function 'drgnx-search--git)))
     (cl-letf (((symbol-function 'drgnx-search--git)
                (lambda (root input &rest args)
                  (apply orig root input (if (member ,word args) (list (car args) "--no-such-option-xyz") args)))))
       ,@body)))

(ert-deftest drgnx-search-files/a-failing-git-signals-never-a-partial-list ()
  (drgnx-search-chunk-test--repo '(("a.txt" . "a\n") ("b.txt" . "b\n"))
    (drgnx-search-chunk-test--git root "commit" "-q" "-m" "init")
    (drgnx-search-chunk-test--write root "a.txt" "changed\n")
    (drgnx-search-chunk-test--write root "new.txt" "new\n")
    (should (equal (drgnx-search-chunk-test--paths root) '("a.txt" "b.txt" "new.txt")))
    (dolist (word '("hash-object" "-m" "--others"))
      (let ((err (should-error (drgnx-search-chunk-test--git-fails-on word (drgnx-search-files root))
                               :type 'drgnx-search-files-error)))
        (should (string-match-p (if (equal word "hash-object") "hash-object" "ls-files") (cadr err)))
        (should (string-match-p "no-such-option" (cadr err)))))
    (should-error (drgnx-search-chunk-test--git-fails-on "-s" (drgnx-search-files root))
                  :type 'drgnx-search-files-error)))

(ert-deftest drgnx-search-files/a-file-deleted-before-hashing-is-absent ()
  (drgnx-search-chunk-test--repo '(("a.txt" . "a\n"))
    (drgnx-search-chunk-test--git root "commit" "-q" "-m" "init")
    (drgnx-search-chunk-test--write root "new.txt" "new\n")
    (drgnx-search-chunk-test--write root "other.txt" "other\n")
    ;; new.txt vanishes after it passed the filters, before the hash call.
    (cl-letf* ((orig (symbol-function 'drgnx-search--binary-p))
               ((symbol-function 'drgnx-search--binary-p)
                (lambda (file)
                  (prog1 (funcall orig file)
                    (when (string-suffix-p "new.txt" file) (delete-file file))))))
      (should (equal (drgnx-search-chunk-test--paths root) '("a.txt" "other.txt"))))))

(ert-deftest drgnx-search-files/unhashable-names-are-skipped ()
  (drgnx-search-chunk-test--repo '(("a.txt" . "a\n"))
    (drgnx-search-chunk-test--git root "commit" "-q" "-m" "init")
    (drgnx-search-chunk-test--write root "\"quoted.txt" "q\n")
    (drgnx-search-chunk-test--write root "new\nline.txt" "n\n")
    (drgnx-search-chunk-test--write root "plain.txt" "p\n")
    (should (equal (drgnx-search-chunk-test--paths root) '("a.txt" "plain.txt")))))

(ert-deftest drgnx-search-files/paths-stay-under-root ()
  (let* ((home (file-name-as-directory (make-temp-file "drgnx-search-home" t)))
         (process-environment (cons (concat "HOME=" home) process-environment)))
    (unwind-protect
        (drgnx-search-chunk-test--repo '(("~/a.txt" . "tilde\n") ("b.txt" . "b\n"))
          (should (equal (drgnx-search-chunk-test--paths root) '("b.txt" "~/a.txt")))
          (drgnx-search-chunk-test--write root "~/a.txt" "edited\n")
          (should (assoc "~/a.txt" (drgnx-search-files root))))
      (delete-directory home t))))

(ert-deftest drgnx-search-files/sensitive-names-are-never-listed ()
  (let ((bad '("server.pem" "x.key" "a.p12" "b.pfx" "c.kdbx" "d.keystore" "e.jks" "f.asc" "g.gpg" "UP.PEM"
               "id_rsa" "id_rsa.pub" "id_dsa" "id_ecdsa" "id_ed25519" "k/id_ed25519.bak"
               "secrets.env" "prod.env" "my-Secret-notes.txt" "AWS_CREDENTIALS.json" "credentials"
               "authinfo" "netrc" "authinfo.gpg")))
    (drgnx-search-chunk-test--repo (append '(("ok.txt" . "ok\n") ("src/keyboard.el" . "k\n") ("monkey.el" . "m\n"))
                                           (mapcar (lambda (f) (cons f "x\n")) (cl-subseq bad 0 12)))
      ;; The rest untracked.
      (dolist (f (nthcdr 12 bad)) (drgnx-search-chunk-test--write root f "x\n"))
      (should (equal (drgnx-search-chunk-test--paths root) '("monkey.el" "ok.txt" "src/keyboard.el")))
      (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:include (\"**\" \"*.pem\" \"id_rsa*\" \"*secret*\"))")
      (should (equal (drgnx-search-chunk-test--paths root) '("monkey.el" "ok.txt" "src/keyboard.el"))))))

(ert-deftest drgnx-search-files/netrc-and-authinfo-are-whole-names ()
  "The credential files are excluded; code that merely has netrc or authinfo in its name is not."
  (dolist (bad '("netrc" ".netrc" "_netrc" "NETRC" "authinfo" ".authinfo" "authinfo.gpg" ".authinfo.gpg" "d/netrc.bak"
                 "work.netrc" "github.netrc" "prod.authinfo" "netrc~" "authinfo.gpg.bak" "my_netrc" "work-authinfo.txt"))
    (should (drgnx-search--sensitive-name-p bad)))
  (dolist (ok '("netrc-parser.el" "netrc.el" "my-netrc.el" "authinfo-helper.py" "auth-source-authinfo.el" "authinfo.py" "netrc/readme.md"))
    (should-not (drgnx-search--sensitive-name-p ok))))

(ert-deftest drgnx-search-files/only-regular-files ()
  "A tracked file replaced by a FIFO is never opened (it would block)."
  (skip-unless (executable-find "mkfifo"))
  (drgnx-search-chunk-test--repo '(("a.txt" . "a\n") ("b.txt" . "b\n"))
    (delete-file (expand-file-name "a.txt" root))
    (should (zerop (call-process "mkfifo" nil nil nil (expand-file-name "a.txt" root))))
    (should (equal (drgnx-search-chunk-test--paths root) '("b.txt")))))

(ert-deftest drgnx-search-files/globs-are-case-sensitive ()
  (drgnx-search-chunk-test--repo '(("x.md" . "x\n") ("y.MD" . "y\n"))
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:exclude (\"*.MD\"))")
    (let ((case-fold-search t))
      (should (equal (drgnx-search-chunk-test--paths root) '("x.md"))))))

(ert-deftest drgnx-search-files/a-submodule-is-not-listed-nor-its-files ()
  (skip-unless (executable-find "git"))
  (let ((inner (make-temp-file "drgnx-search-inner" t)))
    (unwind-protect
        (progn
          (drgnx-search-chunk-test--git inner "init" "-q")
          (drgnx-search-chunk-test--git inner "config" "user.name" "Test")
          (drgnx-search-chunk-test--git inner "config" "user.email" "test@example.com")
          (drgnx-search-chunk-test--write inner "in.txt" "inner\n")
          (drgnx-search-chunk-test--git inner "add" "-A")
          (drgnx-search-chunk-test--git inner "commit" "-q" "-m" "inner")
          (drgnx-search-chunk-test--repo '(("real.txt" . "real\n"))
            (drgnx-search-chunk-test--git root "commit" "-q" "-m" "init")
            (drgnx-search-chunk-test--git root "-c" "protocol.file.allow=always" "submodule" "add" "-q" inner "sub")
            (should (file-exists-p (expand-file-name "sub/in.txt" root)))   ; it is checked out
            (should (string-match-p "160000" (with-temp-buffer (call-process "git" nil t nil "-C" root "ls-files" "-s") (buffer-string))))
            (should (equal (drgnx-search-chunk-test--paths root) '("real.txt")))))
      (delete-directory inner t))))

(ert-deftest drgnx-search-files/a-path-with-a-newline-is-out-clean-or-modified ()
  (drgnx-search-chunk-test--repo '(("a.txt" . "a\n") ("two\nlines.txt" . "x\n"))
    (should (equal (drgnx-search-chunk-test--paths root) '("a.txt")))              ; clean (tracked)
    (drgnx-search-chunk-test--git root "commit" "-q" "-m" "init")
    (should (equal (drgnx-search-chunk-test--paths root) '("a.txt")))
    (drgnx-search-chunk-test--write root "two\nlines.txt" "edited\n")                ; modified
    (should (equal (drgnx-search-chunk-test--paths root) '("a.txt")))))

(ert-deftest drgnx-search-files/timed-git-gets-all-of-a-big-input ()
  "The input goes to a timed git in pieces and arrives whole: the same hash as the untimed call."
  (skip-unless (executable-find "git"))
  (let* ((input (mapconcat (lambda (n) (format "line %d of a long input\n" n)) (number-sequence 1 30000) ""))
         (plain (drgnx-search--git-run default-directory input '("hash-object" "--stdin"))))
    (should (> (length input) 500000))
    (should (= (car plain) 0))
    (let ((drgnx-search--git-deadline (+ (float-time) 20)))
      (should (equal (drgnx-search--git-run default-directory input '("hash-object" "--stdin")) plain)))))

(ert-deftest drgnx-search-files/git-input-has-a-deadline ()
  "A git that never reads its input cannot hold a timed listing past its deadline."
  (skip-unless (executable-find "sleep"))
  (let* ((bin (make-temp-file "drgnx-slow-git" t))
         (exec-path (cons bin exec-path))
         (process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment))
         (drgnx-search--git-deadline (+ (float-time) 0.5)) (t0 (float-time)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "git" bin) (insert "#!/bin/sh\nexec sleep 20\n"))
          (set-file-modes (expand-file-name "git" bin) #o755)
          (should-error (with-timeout (10 (error "blocked"))
                          (drgnx-search--git-run-timed (make-string 4000000 ?x) '("hash-object" "--stdin-paths")))
                        :type 'drgnx-search-files-error)
          (should (< (- (float-time) t0) 5)))
      (delete-directory bin t))))

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

(ert-deftest drgnx-search-files/a-broken-config-stops-the-listing ()
  "A .drgnx/search.eld that is there but cannot be read, is malformed or has a key of the wrong type never fails
open: the config is an error and the listing signals it (nothing is indexed).  Absent: the defaults."
  (drgnx-search-chunk-test--repo '(("a.el" . "a\n") ("vendor/v.js" . "v\n"))
    (dolist (bad '("(:include " "(:include #.(setq drgnx-search-chunk-test--pwned t))" "42" "(:include)" "" "\0\0"
                   "(:exclude \"vendor/\")" "(:include (\"src/\" 5))" "(:off yes)" "(:off 1)"))
      (drgnx-search-chunk-test--write root ".drgnx/search.eld" bad)
      (let ((config (drgnx-search-config root)))
        (should (string-match-p "\\`\\.drgnx/search\\.eld cannot be read: ." (plist-get config :error)))
        (should-not (plist-get config :off)))
      (let ((err (should-error (drgnx-search-files root) :type 'drgnx-search-files-error)))
        (should (string-match-p "\\.drgnx/search\\.eld cannot be read" (cadr err)))))
    (should-not drgnx-search-chunk-test--pwned)
    ;; the wrong type is named
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:exclude \"vendor/\")")
    (should (string-match-p ":exclude" (plist-get (drgnx-search-config root) :error)))
    ;; an unreadable file (not when running as root: root reads it anyway)
    (let ((file (expand-file-name ".drgnx/search.eld" root)))
      (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:off nil)")
      (set-file-modes file 0)
      (unwind-protect
          (unless (file-readable-p file)
            (should (plist-get (drgnx-search-config root) :error))
            (should-error (drgnx-search-files root) :type 'drgnx-search-files-error))
        (set-file-modes file #o644)))
    ;; well-formed: no error
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:exclude (\"vendor/\") :off nil)")
    (should-not (plist-get (drgnx-search-config root) :error))
    (should (equal (drgnx-search-chunk-test--paths root) '("a.el")))
    ;; No file at all: defaults.
    (delete-file (expand-file-name ".drgnx/search.eld" root))
    (should (equal (drgnx-search-config root) '(:include nil :exclude nil :off nil)))
    (should (equal (drgnx-search-chunk-test--paths root) '("a.el" "vendor/v.js")))))

(ert-deftest drgnx-search-files/config-fails-closed-dangling-symlink ()
  "A search.eld that is a symlink to nothing is a config that cannot be read, not the defaults."
  (drgnx-search-chunk-test--repo '(("a.el" . "a\n"))
    (make-directory (expand-file-name ".drgnx" root) t)
    (make-symbolic-link "nowhere.eld" (expand-file-name ".drgnx/search.eld" root))
    (should (string-match-p "\\`\\.drgnx/search\\.eld cannot be read: ." (plist-get (drgnx-search-config root) :error)))
    (should-error (drgnx-search-files root) :type 'drgnx-search-files-error)))

(ert-deftest drgnx-search-files/config-fails-closed-unreadable-dir ()
  "A .drgnx directory that cannot be searched hides search.eld: that is an error, not the defaults."
  (drgnx-search-chunk-test--repo '(("a.el" . "a\n"))
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:off t)")
    (let ((dir (expand-file-name ".drgnx" root)))
      (set-file-modes dir 0)
      (unwind-protect
          (progn
            (skip-unless (not (file-accessible-directory-p dir))) ; root reads it anyway
            (should (string-match-p "\\`\\.drgnx/search\\.eld cannot be read: ." (plist-get (drgnx-search-config root) :error)))
            (should-error (drgnx-search-files root) :type 'drgnx-search-files-error))
        (set-file-modes dir #o755)))))

(ert-deftest drgnx-search-files/config-fails-closed-fifo ()
  "A search.eld that is a FIFO would block every reader: it is an error."
  (skip-unless (executable-find "mkfifo"))
  (drgnx-search-chunk-test--repo '(("a.el" . "a\n"))
    (make-directory (expand-file-name ".drgnx" root))
    (should (zerop (call-process "mkfifo" nil nil nil (expand-file-name ".drgnx/search.eld" root))))
    (should (string-match-p "not a regular file" (plist-get (drgnx-search-config root) :error)))
    (should-error (drgnx-search-files root) :type 'drgnx-search-files-error)))

(ert-deftest drgnx-search-files/a-symlink-to-a-valid-config-is-applied ()
  "A search.eld (or .drgnx) that is a symlink to a readable config works, as dotfile managers need."
  (let ((outside (file-name-as-directory (make-temp-file "drgnx-search-outside" t))))
    (unwind-protect
        (drgnx-search-chunk-test--repo '(("a.el" . "a\n") ("vendor/v.js" . "v\n"))
          (drgnx-search-chunk-test--write outside "search.eld" "(:exclude (\"vendor/\"))")
          (make-directory (expand-file-name ".drgnx" root))
          (make-symbolic-link (concat outside "search.eld") (expand-file-name ".drgnx/search.eld" root))
          (should-not (plist-get (drgnx-search-config root) :error))
          (should (equal (drgnx-search-chunk-test--paths root) '("a.el")))
          ;; the whole directory a link
          (delete-directory (expand-file-name ".drgnx" root) t)
          (make-directory (concat outside "cfg"))
          (drgnx-search-chunk-test--write outside "cfg/search.eld" "(:exclude (\"vendor/\"))")
          (make-symbolic-link (concat outside "cfg") (expand-file-name ".drgnx" root))
          (should-not (plist-get (drgnx-search-config root) :error))
          (should (equal (drgnx-search-chunk-test--paths root) '("a.el"))))
      (delete-directory outside t))))

(ert-deftest drgnx-search-files/a-symlinked-directory-out-of-the-project-is-never-followed ()
  "A tracked file under a directory that was replaced by a symlink to elsewhere is not listed: its text is not the
project's."
  (let ((outside (file-name-as-directory (make-temp-file "drgnx-search-outside" t))))
    (unwind-protect
        (drgnx-search-chunk-test--repo '(("real.txt" . "real\n") ("sub/f.txt" . "inside\n"))
          (drgnx-search-chunk-test--git root "commit" "-q" "-m" "init")
          (drgnx-search-chunk-test--write outside "f.txt" "private outside text\n")
          (delete-directory (expand-file-name "sub" root) t)
          (make-symbolic-link (directory-file-name outside) (expand-file-name "sub" root))
          (should (equal (drgnx-search-chunk-test--paths root) '("real.txt"))))
      (delete-directory outside t))))

(ert-deftest drgnx-search-files/a-git-that-ends-before-its-input-does-is-no-error ()
  "A git that reads nothing (`rev-parse', `--version') can be gone before the last piece or the end of the input is
sent; sending to a finished process signals, which showed as a failed listing (a flake under load).  Made certain
here: the end of input is sent only after git has ended."
  (let ((drgnx-search--git-deadline (+ (float-time) 10)) (eof (symbol-function 'process-send-eof)))
    (cl-letf (((symbol-function 'process-send-eof)
               (lambda (p) (while (process-live-p p) (accept-process-output p 0.05)) (funcall eof p))))
      (let ((r (drgnx-search--git-run-timed "" '("--version"))))
        (should (eql 0 (car r)))
        (should (string-prefix-p "git version" (nth 1 r)))))))

(ert-deftest drgnx-search-files/does-not-depend-on-the-locale ()
  "Every git call runs with LC_ALL=C and no LANGUAGE (git's messages are translated otherwise, and the code reads
them): checked on the environment each call gets — a machine without the German locale would pass anyway."
  (let ((process-environment (append '("LANGUAGE=de" "LANG=de_DE.UTF-8" "LC_ALL=de_DE.UTF-8") process-environment))
        (dir (make-temp-file "drgnx-search-plain" t)) (seen nil))
    (cl-flet ((spy (orig &rest args) (push (list (getenv "LC_ALL") (getenv "LANGUAGE")) seen) (apply orig args)))
      (advice-add 'call-process :around #'spy)
      (advice-add 'call-process-region :around #'spy)
      (advice-add 'make-process :around #'spy)
      (unwind-protect
          (progn
            (unwind-protect
                (progn (drgnx-search-chunk-test--write dir "a.el" "a\n")
                       (should-not (drgnx-search-files dir)))
              (delete-directory dir t))
            (drgnx-search-chunk-test--repo '(("a.el" . "a\n"))
              (setq seen nil)
              (should (equal (drgnx-search-chunk-test--paths root) '("a.el")))
              (should seen)
              (should (cl-every (lambda (e) (equal e '("C" ""))) seen))
              ;; the same under a deadline (the doctor's path starts git as an asynchronous process)
              (setq seen nil)
              (let ((drgnx-search-git-timeout 30)) (should (equal (drgnx-search-chunk-test--paths root) '("a.el"))))
              (should seen)
              (should (cl-every (lambda (e) (equal e '("C" ""))) seen))))
        (advice-remove 'call-process #'spy)
        (advice-remove 'call-process-region #'spy)
        (advice-remove 'make-process #'spy)))))

(ert-deftest drgnx-search-files/not-a-git-repo ()
  (let ((dir (make-temp-file "drgnx-search-plain" t)))
    (unwind-protect
        (progn (drgnx-search-chunk-test--write dir "a.el" "a\n")
               (should-not (drgnx-search-files dir))
               (should-not (drgnx-search-files (expand-file-name "nonexistent" dir))))
      (delete-directory dir t))))

(defmacro drgnx-search-chunk-test--slow-git (&rest body)
  "BODY with a `git' first on PATH that does nothing but sleep for five seconds."
  (declare (indent 0))
  `(let* ((bin (make-temp-file "drgnx-slow-git" t))
          (exec-path (cons bin exec-path))
          (process-environment (cons (concat "PATH=" bin ":" (getenv "PATH")) process-environment)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "git" bin) (insert "#!/bin/sh\nexec sleep 5\n"))
           (set-file-modes (expand-file-name "git" bin) #o755)
           ,@body)
       (delete-directory bin t))))

(ert-deftest drgnx-search-files/a-git-timeout-cuts-a-slow-git-off ()
  (skip-unless (executable-find "sleep"))
  (let ((root (make-temp-file "drgnx-search-slow" t)))
    (unwind-protect
        (drgnx-search-chunk-test--slow-git
          (let* ((t0 (float-time))
                 (err (let ((drgnx-search-git-timeout 0.5))
                        (should-error (drgnx-search-files root) :type 'drgnx-search-files-error))))
            (should (< (- (float-time) t0) 2.5))
            (should (string-match-p "timed out" (cadr err)))))
      (delete-directory root t))))

(ert-deftest drgnx-search-files/no-timeout-by-default ()
  (should-not drgnx-search-git-timeout)
  (drgnx-search-chunk-test--repo '(("a.txt" . "a\n"))
    (let ((drgnx-search-git-timeout 30))              ; plenty: the timed path lists the same files
      (should (equal (mapcar #'car (drgnx-search-files root)) '("a.txt"))))))

(ert-deftest drgnx-search-files/a-git-gone-before-its-stderr-ends-is-not-waited-for ()
  ;; git's exit can be seen before the end of its stderr pipe (macOS: often); here a child holds that pipe
  ;; a little longer.  Once git is gone, the timed path still reads that end instead of spinning to the deadline.
  (skip-unless (and (executable-find "git") (executable-find "sleep")))
  (drgnx-search-chunk-test--repo '(("a.txt" . "a\n"))
    (let* ((git (executable-find "git")) (bin (make-temp-file "drgnx-late-stderr" t))
           (exec-path (cons bin exec-path)))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "git" bin)
              (insert "#!/bin/sh\nsleep 0.3 </dev/null >/dev/null &\nexec " (shell-quote-argument git) " \"$@\"\n"))
            (set-file-modes (expand-file-name "git" bin) #o755)
            (let ((t0 (float-time)) (drgnx-search-git-timeout 10))
              (should (equal (mapcar #'car (drgnx-search-files root)) '("a.txt")))
              (should (< (- (float-time) t0) 5))))
        (delete-directory bin t)))))

(ert-deftest drgnx-search-files/a-git-gone-before-its-input-ends-is-no-error ()
  ;; git need not read its input: it may exit before the end of it is sent (A-44)
  (drgnx-search-chunk-test--repo '(("a.txt" . "a\n"))
    (cl-flet ((late (orig &optional p)
                (let ((end (+ (float-time) 2)))
                  (while (and (process-live-p p) (< (float-time) end)) (accept-process-output p 0.05)))
                (funcall orig p)))
      (advice-add 'process-send-eof :around #'late)
      (unwind-protect
          (let ((drgnx-search-git-timeout 30))
            (should (equal (mapcar #'car (drgnx-search-files root)) '("a.txt"))))
        (advice-remove 'process-send-eof #'late)))))

(ert-deftest drgnx-search-toplevel/through-a-symlink-below-the-top ()
  "The top keeps DIR's spelling and is right when DIR is reached through a symlink to a directory deeper down."
  (drgnx-search-chunk-test--repo '(("sub/deep/a.el" . "a\n"))
    (let* ((root (directory-file-name (file-truename root)))
           (outside (directory-file-name (file-truename (make-temp-file "drgnx-search-outside" t)))))
      (unwind-protect
          (progn
            (make-symbolic-link "sub/deep" (expand-file-name "link" root))
            (make-symbolic-link root (expand-file-name "proj" outside))
            (should (equal (drgnx-search-toplevel (concat root "/sub/deep")) root))
            ;; through a link below the top: the top is the lexical ancestor ROOT, not ROOT/link/../..
            (should (equal (drgnx-search-toplevel (concat root "/link")) root))
            ;; through a link to the whole project: the user's spelling
            (should (equal (drgnx-search-toplevel (concat outside "/proj/sub/deep")) (concat outside "/proj")))
            ;; a link from outside to a directory below the top: no lexical ancestor is the top; its real path
            (make-symbolic-link (concat root "/sub") (expand-file-name "below" outside))
            (should (equal (drgnx-search-toplevel (concat outside "/below")) root)))
        (delete-directory outside t)))))

;;;; search.eld through the config layer

(defmacro drgnx-search-chunk-test--project (&rest body)
  "BODY with ROOT a fresh folder (no git needed: only the configuration is read) under `drgnx-test-with-config'."
  (declare (indent 0))
  `(drgnx-test-with-config
     (let ((root (file-name-as-directory (make-temp-file "drgnx-search-cfg" t))))
       (unwind-protect (progn ,@body) (delete-directory root t)))))

(ert-deftest drgnx-search-config/search-project-is-a-project-file ()
  (let ((def (drgnx-config-definition 'search-project)))
    (should def)
    (should (eq (plist-get def :dir) 'project))
    (should (equal (plist-get def :file) "search.eld"))
    (should (= (plist-get def :max-bytes) 65536))
    (should (equal (plist-get def :schema)
                   '(plist (:include (list-of string)) (:exclude (list-of string)) (:off boolean))))))

(ert-deftest drgnx-search-config/a-65-kib-file-is-refused-not-truncated ()
  "The first 64 KiB of this file are a valid configuration; the file is over the limit, so it is an error."
  (drgnx-search-chunk-test--project
    (drgnx-search-chunk-test--write root ".drgnx/search.eld"
                                    (concat "(:off t)" (make-string (- (* 65 1024) 8) ?\s)))
    (let ((config (drgnx-search-config root)))
      (should (string-match-p "\\`\\.drgnx/search\\.eld cannot be read: ." (plist-get config :error)))
      (should-not (plist-get config :off)))
    ;; exactly 64 KiB still reads
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" (concat "(:off t)" (make-string (- 65536 8) ?\s)))
    (should (equal (drgnx-search-config root) '(:include nil :exclude nil :off t)))))

(ert-deftest drgnx-search-config/a-fifo-is-refused ()
  "A FIFO is refused by the layer before it is opened, so the read never blocks."
  (skip-unless (executable-find "mkfifo"))
  (drgnx-search-chunk-test--project
    (make-directory (expand-file-name ".drgnx" root))
    (should (zerop (call-process "mkfifo" nil nil nil (expand-file-name ".drgnx/search.eld" root))))
    (should (string-match-p "not a regular file" (plist-get (drgnx-search-config root) :error)))
    (should (string-match-p "not a regular file" (plist-get (drgnx-config-problem 'search-project root) :text)))))

(ert-deftest drgnx-search-config/an-existing-file-keeps-working ()
  "Comments, a key this drgnx does not know and a `:version' do not make a file that older code read a problem."
  (drgnx-search-chunk-test--project
    (drgnx-search-chunk-test--write root ".drgnx/search.eld"
                                    ";; my search settings\n(:include (\"src/\" \"*.md\") ; only these\n :exclude (\"vendor/\")\n :future \"x\")\n")
    (should (equal (drgnx-search-config root) '(:include ("src/" "*.md") :exclude ("vendor/") :off nil)))
    (should (equal (drgnx-config-get 'search-project :include root) '("src/" "*.md")))
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:version 1 :off t)")
    (should (equal (drgnx-search-config root) '(:include nil :exclude nil :off t)))
    ;; absent: the defaults
    (delete-file (expand-file-name ".drgnx/search.eld" root))
    (should (equal (drgnx-search-config root) '(:include nil :exclude nil :off nil)))))

(ert-deftest drgnx-search-config/a-read-eval-form-is-never-evaluated ()
  "The project file comes from a repository the user may not trust: even with `read-eval' t it is only read."
  (drgnx-search-chunk-test--project
    (setq drgnx-search-chunk-test--pwned nil)
    (drgnx-search-chunk-test--write root ".drgnx/search.eld"
                                    "(:include #.(setq drgnx-search-chunk-test--pwned t))")
    (let ((read-eval t))
      (should (plist-get (drgnx-search-config root) :error)))
    (should-not drgnx-search-chunk-test--pwned)))

(ert-deftest drgnx-search-config/an-unreadable-dir-is-still-an-error ()
  "The `.drgnx' accessibility check stays: the layer is not asked about a file it cannot see."
  (skip-unless (not (zerop (user-uid))))
  (drgnx-search-chunk-test--project
    (drgnx-search-chunk-test--write root ".drgnx/search.eld" "(:off t)")
    (let ((dir (expand-file-name ".drgnx" root)))
      (set-file-modes dir 0)
      (unwind-protect
          (should (string-match-p "not an accessible directory" (plist-get (drgnx-search-config root) :error)))
        (set-file-modes dir #o755)))))

;;; search-chunk-test.el ends here
