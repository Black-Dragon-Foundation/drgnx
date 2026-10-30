;;; wb-git-test.el --- batch tests: git decorations -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
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
    (drgnx-test-with-state
      (let ((drgnx-wb--sections nil))
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
          (kill-buffer drgnx-explorer-buffer-name))))))

(ert-deftest drgnx-git/the-buffers-panel-shows-letters ()
  (skip-unless (executable-find "git"))
  (drgnx-git-test--repo root
    (drgnx-test-with-state
      (let ((drgnx-wb--sections nil)
            (drgnx-buffers--order nil) (drgnx-buffers--signature nil)
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
          (when (get-buffer drgnx-buffers-buffer-name) (kill-buffer drgnx-buffers-buffer-name)))))))

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

;;;; The status cache is capped (PERF-M5)

(defmacro drgnx-git-test--many-repos (roots n &rest body)
  "BODY with ROOTS the N repositories (each with an untracked u.txt) of a temp folder, and empty git caches."
  (declare (indent 2))
  `(let* ((parent (file-name-as-directory (make-temp-file "drgnx-git-many" t)))
          (drgnx-git--roots (make-hash-table :test #'equal))
          (,roots (cl-loop for i below ,n
                           collect (let ((d (file-name-as-directory (expand-file-name (format "r%02d" i) parent))))
                                     (make-directory d t)
                                     (let ((default-directory d)) (call-process "git" nil nil nil "init" "-q"))
                                     (write-region "u\n" nil (expand-file-name "u.txt" d) nil 'silent)
                                     d))))
     (drgnx-cache--clear 'git-status)
     (unwind-protect (progn ,@body)
       (drgnx-cache--clear 'git-status)
       (delete-directory parent t))))

(ert-deftest drgnx-git/status-of-at-most-16-roots-is-kept ()
  (skip-unless (executable-find "git"))
  (drgnx-git-test--many-repos roots 20
    (dolist (r roots) (drgnx-git-refresh r t))
    (should (= (drgnx-cache-size 'git-status) 16))
    (should (equal (seq-find (lambda (row) (eq (car row) 'git-status)) (drgnx-memo-census)) '(git-status cache 16 16)))
    (should-not (drgnx-git-status (expand-file-name "u.txt" (car roots))))           ; the four oldest went
    (should-not (drgnx-git-status (expand-file-name "u.txt" (nth 3 roots))))
    (should (eq (drgnx-git-status (expand-file-name "u.txt" (nth 4 roots))) 'untracked))
    (should (eq (drgnx-git-status (expand-file-name "u.txt" (car (last roots)))) 'untracked))))

(ert-deftest drgnx-git/an-evicted-root-is-read-again-on-demand ()
  (skip-unless (executable-find "git"))
  (drgnx-git-test--many-repos roots 18
    (dolist (r roots) (drgnx-git-refresh r t))
    (let ((first (expand-file-name "u.txt" (car roots))))
      (should-not (drgnx-git-status first))                                          ; evicted
      (drgnx-git-refresh (car roots) t)                                              ; asked for again
      (should (eq (drgnx-git-status first) 'untracked))
      (should (= (drgnx-cache-size 'git-status) 16)))))

(ert-deftest drgnx-git/a-late-sentinel-keeps-the-eviction-order ()
  ;; A run read before its sentinel ran (the wait reads a git that is gone) gets that sentinel later, during other
  ;; roots' runs: its look at the cache is no use of the root, so the root stays the oldest (macOS CI: the late look
  ;; stamped r00 and r01 was evicted in its place).
  (skip-unless (executable-find "git"))
  (drgnx-git-test--many-repos roots 17
    (let ((first (car roots)) proc)
      (drgnx-git-refresh first)
      (setq proc (plist-get (drgnx-cache-get 'git-status first) :proc))
      (drgnx-git-refresh first t)                                                    ; read: :proc is cleared
      (dolist (r (butlast (cdr roots))) (drgnx-git-refresh r t))                     ; 16 roots, the first the oldest
      (drgnx-git--done proc first)                                                   ; its sentinel, late
      (drgnx-git-refresh (car (last roots)) t)                                       ; the 17th evicts the oldest
      (should-not (drgnx-git-status (expand-file-name "u.txt" first)))
      (should (eq (drgnx-git-status (expand-file-name "u.txt" (nth 1 roots))) 'untracked)))))

(ert-deftest drgnx-git/an-evicted-root-comes-back-when-its-run-finishes ()
  ;; A root pushed out while its git runs is not killed: its result puts the root back.
  (skip-unless (executable-find "git"))
  (drgnx-git-test--many-repos roots 1
    (let ((root (car roots)) proc)
      (drgnx-git-refresh root)                                                       ; in the background
      (setq proc (plist-get (drgnx-cache-get 'git-status root) :proc))
      (should proc)
      (dotimes (i 16) (drgnx-cache-put 'git-status (format "/tmp/drgnx-fill-%d/" i) (list :branch nil)))
      (should-not (drgnx-cache-get 'git-status root))                                ; evicted while running
      (let ((n 0))
        (while (and (not (plist-get (drgnx-cache-get 'git-status root) :files)) (< (cl-incf n) 200))
          (accept-process-output nil 0.05)))
      (should-not (eq (process-status proc) 'signal))                                ; never killed
      (should (= (process-exit-status proc) 0))
      (should (eq (drgnx-git-status (expand-file-name "u.txt" root)) 'untracked))
      (should (= (drgnx-cache-size 'git-status) 16)))))

(ert-deftest drgnx-git/a-refresh-of-a-root-pushed-out-mid-run-starts-no-second-git ()
  ;; The root's entry, and with it its run, is gone from the cache; the run still goes, so a refresh now is done once
  ;; after it, not by a second git beside it.
  (skip-unless (executable-find "git"))
  (drgnx-git-test--many-repos roots 1
    (let ((root (car roots)) proc)
      (drgnx-git-refresh root)
      (setq proc (plist-get (drgnx-cache-get 'git-status root) :proc))
      (dotimes (i 16) (drgnx-cache-put 'git-status (format "/tmp/drgnx-fill-%d/" i) (list :branch nil)))
      (should-not (drgnx-cache-get 'git-status root))
      (should (process-live-p proc))
      (drgnx-git-refresh root)
      (should (eq (plist-get (drgnx-cache-peek 'git-status root) :proc) proc))     ; the same run
      (should (plist-get (drgnx-cache-peek 'git-status root) :again))              ; asked again after it
      (drgnx-git-refresh root t)
      (should (eq (drgnx-git-status (expand-file-name "u.txt" root)) 'untracked)))))

(ert-deftest drgnx-git/a-pushed-out-repository-s-own-row-stays-its-own ()
  ;; The Explorer names a repository's folder without a trailing slash: pushed out of the cache, it must not fall to
  ;; the folder around it.
  (skip-unless (executable-find "git"))
  (drgnx-git-test--many-repos roots 17
    (dolist (r roots) (drgnx-git-refresh r t))
    (should-not (drgnx-cache-peek 'git-status (car roots)))
    (should (equal (drgnx-git-root (directory-file-name (car roots))) (car roots)))))

(defun drgnx-git-test--explorer-lines (w)
  "The row indexes window W of the Explorer shows: (FIRST . END)."
  (with-current-buffer drgnx-explorer-buffer-name
    (let ((first (drgnx-explorer--index (window-start w))))
      (cons first (min (length drgnx-explorer--rows) (+ first (window-body-height w)))))))

(defun drgnx-git-test--shown (roots w)
  "Those of ROOTS whose folder row or u.txt row window W of the Explorer shows."
  (let ((lines (drgnx-git-test--explorer-lines w)))
    (with-current-buffer drgnx-explorer-buffer-name
      (cl-flet ((in (path) (let ((i (drgnx-explorer--index (drgnx-explorer--row-pos path))))
                             (and (<= (car lines) i) (< i (cdr lines))))))
        (seq-filter (lambda (r) (or (in (directory-file-name r)) (in (expand-file-name "u.txt" r)))) roots)))))

(ert-deftest drgnx-git/the-explorer-reads-only-the-repositories-on-screen ()
  ;; Twenty repositories open in one tree, more than the cache keeps: reading every one of them pushed out those on
  ;; screen, which lost their letters until the next read.  Only the repositories on screen are read, each once; a
  ;; scroll reads the ones that came into view.
  (skip-unless (executable-find "git"))
  (drgnx-git-test--many-repos roots 20
    (drgnx-test-with-state
      (let ((drgnx-wb--sections nil) (drgnx-explorer-compact-folders nil) (drgnx-explorer-git t)
            (drgnx-explorer--expanded (make-hash-table :test #'equal)) (read nil))
        (unwind-protect
            (progn
              (delete-other-windows)
              (drgnx-explorer-setup)
              (dolist (r roots) (puthash (directory-file-name r) t drgnx-explorer--expanded))
              (drgnx-explorer-set-roots (list parent))
              (drgnx-wb-show-sidebar)
              (let* ((w (get-buffer-window drgnx-explorer-buffer-name t)) (shown (drgnx-git-test--shown roots w))
                     (orig (symbol-function 'drgnx-git-refresh)))
                (should w)
                (should (< 0 (length shown) 17))
                (cl-letf (((symbol-function 'drgnx-git-refresh)
                           (lambda (path &optional wait) (push (drgnx-git-root path) read) (funcall orig path wait))))
                  (drgnx-explorer--git-run nil t)
                  (should (equal (sort (copy-sequence read) #'string<) shown))      ; each on screen once, no other
                  (dolist (r shown) (should (eq (drgnx-git-status (expand-file-name "u.txt" r)) 'untracked)))
                  ;; scrolled to the last repository read: the rows that came into view ask for their repositories,
                  ;; and only those are read
                  (setq read nil)
                  (with-current-buffer drgnx-explorer-buffer-name
                    (set-window-start w (drgnx-explorer--row-pos (directory-file-name (car (last shown)))) t)
                    (let ((now (drgnx-git-test--shown roots w)))
                      (should now)
                      (drgnx-explorer--fontify (window-start w) (point-max))
                      (should (drgnx-timer-active-p 'explorer-git-unread))
                      (drgnx-explorer--git-run t t)
                      (should (equal (sort (copy-sequence read) #'string<) (seq-difference now shown)))
                      (dolist (r now) (should (eq (drgnx-git-status (expand-file-name "u.txt" r)) 'untracked))))))))
          (drgnx-timer-cancel 'explorer-git-unread)
          (drgnx-wb-hide-sidebar)
          (drgnx-explorer-set-roots nil)
          (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name)))))))
