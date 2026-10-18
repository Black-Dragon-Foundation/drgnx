;;; wb-git-test.el --- batch tests: git decorations -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-git)
(require 'drgnx-explorer)
(require 'drgnx-buffers)

(ert-deftest drgnx-git/parse-porcelain-v2 ()
  (let ((h (drgnx-git-parse
            (concat "1 .M N... 100644 100644 100644 aaa bbb src/app/main.py\0"
                    "1 A. N... 000000 100644 100644 000 ccc new.py\0"
                    "2 R. N... 100644 100644 100644 ddd eee R100 lib/renamed.py\0lib/old.py\0"
                    "u UU N... 100644 100644 100644 100644 f g h conflict.txt\0"
                    "? notes.txt\0"
                    "? scratch/\0"
                    "! build/\0"))))
    (should (eq (gethash "src/app/main.py" h) 'modified))
    (should (eq (gethash "new.py" h) 'added))
    (should (eq (gethash "lib/renamed.py" h) 'renamed))
    (should (eq (gethash "conflict.txt" h) 'conflict))
    (should (eq (gethash "notes.txt" h) 'untracked))
    (should (eq (gethash "scratch" h) 'untracked))
    (should (eq (gethash "build" h) 'ignored))
    (should-not (gethash "lib/old.py" h))))

(defmacro drgnx-git-test--repo (root &rest body)
  "BODY with ROOT a git repo: committed a.txt and src/b.txt; then b.txt modified, c.txt untracked,
build/ ignored (with build/out.o)."
  (declare (indent 1))
  `(let ((,root (file-name-as-directory (make-temp-file "drgnx-git" t))))
     (unwind-protect
         (let ((default-directory ,root))
           (write-region "a\n" nil "a.txt" nil 'silent)
           (make-directory "src")
           (write-region "b\n" nil "src/b.txt" nil 'silent)
           (write-region "build/\n" nil ".gitignore" nil 'silent)
           (call-process "git" nil nil nil "init" "-q")
           (call-process "git" nil nil nil "add" "-A")
           (call-process "git" nil nil nil "-c" "user.email=t@drgnx" "-c" "user.name=t" "commit" "-qm" "x")
           (write-region "changed\n" nil "src/b.txt" nil 'silent)
           (write-region "c\n" nil "c.txt" nil 'silent)
           (make-directory "build")
           (write-region "o\n" nil "build/out.o" nil 'silent)
           ,@body)
       (delete-directory ,root t))))

(ert-deftest drgnx-git/status-of-files-and-folders ()
  (skip-unless (executable-find "git"))
  (drgnx-git-test--repo root
    (drgnx-git-refresh root t)                       ; t: wait (tests); normally async
    (should (eq (drgnx-git-status (expand-file-name "src/b.txt" root)) 'modified))
    (should (eq (drgnx-git-status (expand-file-name "c.txt" root)) 'untracked))
    (should (eq (drgnx-git-status (expand-file-name "build/out.o" root)) 'ignored))  ; inside an ignored folder
    (should (null (drgnx-git-status (expand-file-name "a.txt" root))))
    (should (eq (drgnx-git-status (expand-file-name "src" root)) 'modified))        ; a folder: its strongest child
    (should (null (drgnx-git-status "/tmp/not-a-repo/x")))))

(ert-deftest drgnx-git/no-git-is-silent ()
  (let ((dir (make-temp-file "drgnx-nogit" t)))
    (unwind-protect
        (progn (drgnx-git-refresh dir t)
               (should (null (drgnx-git-status (expand-file-name "x" dir)))))
      (delete-directory dir t))))

(ert-deftest drgnx-git/the-explorer-shows-letters ()
  (skip-unless (executable-find "git"))
  (drgnx-git-test--repo root
    (let ((drgnx-wb--sections nil) (drgnx-signal--editor-window nil))
      (unwind-protect
          (progn
            (delete-other-windows)
            (drgnx-explorer-setup)
            (drgnx-explorer-set-roots (list root))
            (drgnx-git-refresh root t)
            (with-current-buffer drgnx-explorer-buffer-name
              (drgnx-explorer--fontify (point-min) (point-max))
              (cl-flet ((deco (name) (goto-char (point-min)) (search-forward name)
                          (mapconcat (lambda (o) (or (overlay-get o 'after-string) ""))
                                     (overlays-in (pos-bol) (1+ (pos-eol))) "")))
                (should (string-search "U" (deco "c.txt")))
                (should (string-search "●" (deco "src")))     ; a folder with changes inside
                (should (string= "" (deco "a.txt"))))))
        (drgnx-wb-hide-sidebar)
        (drgnx-explorer-set-roots nil)                ; its watches go: no events from the folder's removal
        (kill-buffer drgnx-explorer-buffer-name)))))

(ert-deftest drgnx-git/the-buffers-panel-shows-letters ()
  (skip-unless (executable-find "git"))
  (drgnx-git-test--repo root
    (let ((drgnx-signal--subscribers nil) (drgnx-signal--state nil) (drgnx-wb--sections nil)
          (drgnx-buffers--order nil) (drgnx-buffers--signature nil) (drgnx-signal--editor-window nil)
          (b (find-file-noselect (expand-file-name "src/b.txt" root))))
      (unwind-protect
          (progn
            (delete-other-windows)
            (drgnx-buffers-setup)
            (drgnx-git-refresh root t)
            (drgnx-signal--flush)
            (drgnx-wb-show-sidebar)
            (with-current-buffer drgnx-buffers-buffer-name
              (drgnx-buffers--fontify (point-min) (point-max))
              (goto-char (drgnx-buffers--row-pos b))
              (should (string-search "M" (mapconcat (lambda (o) (or (overlay-get o 'after-string) ""))
                                                    (overlays-in (pos-bol) (1+ (pos-eol))) "")))))
        (drgnx-wb-hide-sidebar)
        (kill-buffer b)
        (when (get-buffer drgnx-buffers-buffer-name) (kill-buffer drgnx-buffers-buffer-name))))))

(ert-deftest drgnx-git/huge-ignored-lists-are-skipped ()
  ;; Ignored files only dim rows; past the limit they are not parsed (a build tree inside tracked folders).
  (let ((drgnx-git-ignored-limit 3))
    (let ((h (drgnx-git-parse "? a\0! b.o\0! c.o\0! d.o\0! e.o\0")))
      (should (eq (gethash "a" h) 'untracked))
      (should-not (gethash "b.o" h))))
  (let ((h (drgnx-git-parse "? a\0! b.o\0")))
    (should (eq (gethash "b.o" h) 'ignored))))

(defun drgnx-git-test--entries (hash)
  "HASH as a sorted alist, to compare two parses."
  (let (l) (maphash (lambda (k v) (push (cons k v) l)) hash) (sort l (lambda (a b) (string< (car a) (car b))))))

(ert-deftest drgnx-git/parses-the-branch-line ()
  (let* ((body (concat "1 .M N... 100644 100644 100644 aaa bbb src/main.py\0" "? notes.txt\0" "! build/\0"))
         (head (concat "# branch.oid 1234567890abcdef\0# branch.head main\0# branch.upstream origin/main\0"
                       "# branch.ab +2 -1\0")))
    (let ((b (drgnx-git-parse-branch (concat head body))))
      (should (equal (plist-get b :head) "main"))
      (should (= (plist-get b :ahead) 2))
      (should (= (plist-get b :behind) 1))
      (should-not (plist-get b :detached)))
    ;; the files are what they were without the branch lines
    (should (equal (drgnx-git-test--entries (drgnx-git-parse (concat head body)))
                   (drgnx-git-test--entries (drgnx-git-parse body))))
    ;; no upstream: no counts; a name with a slash and spaces survives
    (let ((b (drgnx-git-parse-branch "# branch.oid abc\0# branch.head feature/a b\0? x\0")))
      (should (equal (plist-get b :head) "feature/a b"))
      (should-not (plist-get b :ahead)))
    ;; an unborn branch (no commit yet)
    (let ((b (drgnx-git-parse-branch "# branch.oid (initial)\0# branch.head master\0? x\0")))
      (should (equal (plist-get b :head) "master"))
      (should-not (plist-get b :ahead)))
    ;; a branch whose upstream is gone: an upstream line, no counts
    (let ((b (drgnx-git-parse-branch "# branch.oid abc\0# branch.head main\0# branch.upstream origin/gone\0? x\0")))
      (should (equal (plist-get b :head) "main"))
      (should-not (plist-get b :ahead))
      (should-not (plist-get b :behind)))
    ;; a detached HEAD
    (let ((b (drgnx-git-parse-branch "# branch.oid abc\0# branch.head (detached)\0? x\0")))
      (should (plist-get b :detached))
      (should-not (plist-get b :head)))
    ;; an output without branch lines (and an empty one)
    (should-not (drgnx-git-parse-branch body))
    (should-not (drgnx-git-parse-branch ""))))

(ert-deftest drgnx-git/the-status-run-reads-the-branch-from-the-cache ()
  (skip-unless (executable-find "git"))
  (drgnx-git-test--repo root
    (should-not (drgnx-git-branch root))             ; nothing read yet
    (drgnx-git-refresh root t)
    (let ((b (drgnx-git-branch root)))
      (should (stringp (plist-get b :head)))
      (should-not (plist-get b :ahead)))              ; no upstream
    (should (eq (drgnx-git-status (expand-file-name "src/b.txt" root)) 'modified))   ; the files are unchanged
    ;; a detached HEAD
    (let ((default-directory root))
      (call-process "git" nil nil nil "checkout" "-q" "--detach")
      (drgnx-git-refresh root t)
      (should (plist-get (drgnx-git-branch root) :detached)))))

(ert-deftest drgnx-git/cached-root-reads-only-the-cache ()
  (let ((drgnx-git--roots (make-hash-table :test #'equal)) (fail (lambda (&rest a) (ert-fail (format "looked: %S" a)))))
    (cl-letf (((symbol-function 'locate-dominating-file) fail))
      (should-not (drgnx-git-cached-root "/tmp/repo/src/a.el"))        ; not looked up yet: nothing, and no disk
      (puthash "/tmp/repo/src/" "/tmp/repo/" drgnx-git--roots)
      (should (equal (drgnx-git-cached-root "/tmp/repo/src/a.el") "/tmp/repo/"))
      (should (equal (drgnx-git-cached-root "/tmp/repo/src/") "/tmp/repo/"))
      (puthash "/tmp/other/" 'none drgnx-git--roots)
      (should-not (drgnx-git-cached-root "/tmp/other/a.el"))
      (should-not (drgnx-git-cached-root "/ssh:host:/tmp/repo/src/a.el")))))
