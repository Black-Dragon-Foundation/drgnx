;;; search-index-test.el --- batch tests: the background indexer (semantic search) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-search-index)

;; No network, no real HOME: a stub embedder (vectors from a hash of the text), temp git repos, a temp
;; XDG_STATE_HOME.  Nothing here starts a job.

(defvar drgnx-search-index-test--calls nil "The inputs (lists of texts) the stub embedder was asked for.")

(defun drgnx-search-index-test--stub (&optional dims model)
  "An embedder: unit vectors of DIMS (8) numbers derived from the text; records its calls; says MODEL."
  (let ((dims (or dims 8)))
    (lambda (inputs &rest _)
      (push (append inputs nil) drgnx-search-index-test--calls)
      (setq drgnx-ai-embed-last-info (list :provider 'stub :model (or model "stub-model")))
      (vconcat
       (mapcar (lambda (text)
                 (let* ((bytes (append (secure-hash 'sha256 text nil nil t) nil))
                        (v (cl-loop for i below dims
                                    collect (/ (- (nth (mod i 32) bytes) 127.5) 127.5)))
                        (norm (sqrt (apply #'+ (mapcar (lambda (x) (* x x)) v)))))
                   (vconcat (mapcar (lambda (x) (/ x norm)) v))))
               inputs)))))

(defun drgnx-search-index-test--stub-failing-from (n)
  "A stub that answers its first N-1 calls and signals `drgnx-ai-embed-error' from the Nth on."
  (let ((ok (drgnx-search-index-test--stub)) (calls 0))
    (lambda (inputs &rest r)
      (if (>= (cl-incf calls) n) (signal 'drgnx-ai-embed-error (list "tei: HTTP 500"))
        (apply ok inputs r)))))

(defun drgnx-search-index-test--git (dir &rest args)
  (let ((default-directory (file-name-as-directory dir))
        (process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
                                     (cl-remove-if (lambda (e) (string-match-p "\\`GIT_\\(DIR\\|WORK_TREE\\|INDEX_FILE\\)=" e))
                                                   process-environment))))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %S failed: %s" args (buffer-string))))))

(defun drgnx-search-index-test--write (dir rel content)
  (let ((file (concat (file-name-as-directory dir) rel)))
    (make-directory (file-name-directory file) t)
    (let ((coding-system-for-write 'no-conversion) (file-name-handler-alist nil)) (write-region content nil file nil 'silent))))

(defun drgnx-search-index-test--text (name)
  "A few lines of text that differ per NAME."
  (mapconcat (lambda (n) (format "%s line %d" name n)) (number-sequence 1 5) "\n"))

(defmacro drgnx-search-index-test--with (files &rest body)
  "BODY with ROOT a git repo holding FILES (alist REL . CONTENT), a temp state dir, DB-FILE its index file."
  (declare (indent 1))
  `(let* ((state (make-temp-file "drgnx-search-state" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
          (root (file-name-as-directory (make-temp-file "drgnx-search-repo" t)))
          (drgnx-search-index-test--calls nil)
          (drgnx-ai-embed-last-info nil))
     (skip-unless (sqlite-available-p))
     (unwind-protect
         (progn
           (drgnx-search-index-test--git root "init" "-q")
           (drgnx-search-index-test--git root "config" "user.name" "Test")
           (drgnx-search-index-test--git root "config" "user.email" "test@example.com")
           (dolist (f ,files) (drgnx-search-index-test--write root (car f) (cdr f)))
           (drgnx-search-index-test--git root "add" "-A" "-f")
           ,@body)
       (delete-directory root t)
       (delete-directory state t))))

(defun drgnx-search-index-test--named (n)
  (mapcar (lambda (i) (cons (format "f%d.txt" i) (drgnx-search-index-test--text (format "file%d" i))))
          (number-sequence 1 n)))

(defun drgnx-search-index-test--peek (root fn)
  "FN called with ROOT's store, opened and closed around it."
  (let ((db (drgnx-search-store-open root)))
    (unwind-protect (funcall fn db) (sqlite-close db))))

(defun drgnx-search-index-test--paths (root)
  (drgnx-search-index-test--peek
   root (lambda (db) (sort (hash-table-keys (drgnx-search-store-files db)) #'string<))))

(defun drgnx-search-index-test--chunk-count (root &optional path)
  (drgnx-search-index-test--peek
   root (lambda (db) (caar (if path (sqlite-select db "select count(*) from chunk where path = ?" (list path))
                             (sqlite-select db "select count(*) from chunk"))))))

(defun drgnx-search-index-test--lock (root) (concat (drgnx-search-store-file root) ".lock"))

;;;; Indexing

(ert-deftest drgnx-search-index/first-run-indexes-every-file ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 3)
    (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub))))
      (should-not (plist-get r :error))
      (should (equal (list (plist-get r :added) (plist-get r :changed) (plist-get r :removed)) '(3 0 0)))
      (should (= (plist-get r :chunks) 3))
      (should (numberp (plist-get r :seconds)))
      (should (equal (drgnx-search-index-test--paths root) '("f1.txt" "f2.txt" "f3.txt")))
      (should (= (drgnx-search-index-test--chunk-count root) 3))
      (let ((meta (drgnx-search-index-test--peek root #'drgnx-search-store-meta)))
        (should (eq (plist-get meta :provider) 'stub))
        (should (equal (plist-get meta :model) "stub-model"))
        (should (= (plist-get meta :dims) 8))
        (should (floatp (plist-get meta :indexed-at))))
      (should-not (file-exists-p (drgnx-search-index-test--lock root))))))

(ert-deftest drgnx-search-index/second-run-touches-only-changed ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 3)
    (drgnx-search-index root :embed (drgnx-search-index-test--stub))
    ;; unchanged: nothing is embedded
    (setq drgnx-search-index-test--calls nil)
    (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub))))
      (should (equal (list (plist-get r :added) (plist-get r :changed) (plist-get r :removed) (plist-get r :chunks))
                     '(0 0 0 0)))
      (should-not drgnx-search-index-test--calls))
    ;; edit one, delete one
    (drgnx-search-index-test--write root "f2.txt" "edited\nfor real\n")
    (delete-file (expand-file-name "f3.txt" root))
    (setq drgnx-search-index-test--calls nil)
    (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub))))
      (should-not (plist-get r :error))
      (should (equal (list (plist-get r :added) (plist-get r :changed) (plist-get r :removed)) '(0 1 1)))
      (should (equal (apply #'append drgnx-search-index-test--calls) '("edited\nfor real"))))
    (should (equal (drgnx-search-index-test--paths root) '("f1.txt" "f2.txt")))
    (should (= (drgnx-search-index-test--chunk-count root "f3.txt") 0))
    (should (= (drgnx-search-index-test--chunk-count root) 2))))

(ert-deftest drgnx-search-index/batches-share-requests-and-progress-reports-files ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 5)
    (let (seen)
      (drgnx-search-index root :embed (drgnx-search-index-test--stub) :batch 2
                          :progress (lambda (done total) (push (cons done total) seen)))
      ;; 5 one-chunk files, 2 chunks per request: 2 + 2 + 1
      (should (equal (mapcar #'length (reverse drgnx-search-index-test--calls)) '(2 2 1)))
      (should (equal (car seen) '(5 . 5)))
      (should (equal (reverse (mapcar #'car seen)) '(1 2 3 4 5))))))

(ert-deftest drgnx-search-index/the-default-batch-is-tei-max-client-batch-size ()
  "100 one-chunk files go out in requests of 32 (TEI's default max-client-batch-size): 32 + 32 + 32 + 4."
  (should (= drgnx-search-index-default-batch 32))
  (drgnx-search-index-test--with (drgnx-search-index-test--named 100)
    (drgnx-search-index root :embed (drgnx-search-index-test--stub))
    (should (equal (mapcar #'length (reverse drgnx-search-index-test--calls)) '(32 32 32 4)))))

(ert-deftest drgnx-search-index/a-file-with-many-chunks-is-written-whole ()
  (let ((big (mapconcat (lambda (n) (format "row %d" n)) (number-sequence 1 400) "\n")))
    (drgnx-search-index-test--with `(("big.txt" . ,big) ("small.txt" . "tiny\n"))
      (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub) :batch 4)))
        (should-not (plist-get r :error))
        (should (> (plist-get r :chunks) 4))
        (should (cl-every (lambda (c) (<= (length c) 4)) drgnx-search-index-test--calls))
        (should (= (drgnx-search-index-test--chunk-count root "big.txt")
                   (length (drgnx-search-chunks big))))))))

(ert-deftest drgnx-search-index/a-provider-error-keeps-what-is-written ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 6)
    ;; one chunk per request; the 3rd request and its retry fail
    (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub-failing-from 3) :batch 1)))
      (should (string-match-p "HTTP 500" (plist-get r :error)))
      (should (= (plist-get r :added) 2))
      (should (equal (drgnx-search-index-test--paths root) '("f1.txt" "f2.txt")))
      ;; the index is not fresh: indexed-at was not advanced
      (should-not (plist-get (drgnx-search-index-test--peek root #'drgnx-search-store-meta) :indexed-at))
      (should-not (file-exists-p (drgnx-search-index-test--lock root))))
    ;; the next run finishes the job
    (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub) :batch 1)))
      (should-not (plist-get r :error))
      (should (= (plist-get r :added) 4))
      (should (= (length (drgnx-search-index-test--paths root)) 6))
      (should (floatp (plist-get (drgnx-search-index-test--peek root #'drgnx-search-store-meta) :indexed-at))))))

(ert-deftest drgnx-search-index/a-failing-run-after-a-complete-one-leaves-indexed-at-and-rows ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 4)
    (should-not (plist-get (drgnx-search-index root :embed (drgnx-search-index-test--stub)) :error))
    (let ((stamp (plist-get (drgnx-search-index-test--peek root #'drgnx-search-store-meta) :indexed-at)))
      (should (floatp stamp))
      (sleep-for 0.02)
      (dolist (n '("f1.txt" "f2.txt" "f3.txt")) (drgnx-search-index-test--write root n (format "new %s\n" n)))
      (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub-failing-from 2) :batch 1)))
        (should (string-match-p "HTTP 500" (plist-get r :error)))
        (should (= (plist-get r :changed) 1)))
      (should (eql (plist-get (drgnx-search-index-test--peek root #'drgnx-search-store-meta) :indexed-at) stamp))
      ;; every earlier file still has its rows (the changed one rewritten, the rest as before)
      (should (equal (drgnx-search-index-test--paths root) '("f1.txt" "f2.txt" "f3.txt" "f4.txt")))
      (dolist (n '("f1.txt" "f2.txt" "f3.txt" "f4.txt"))
        (should (= (drgnx-search-index-test--chunk-count root n) 1))))))

(ert-deftest drgnx-search-index/a-provider-error-retries-once-with-half-the-batch ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 6)
    (let* ((ok (drgnx-search-index-test--stub)) (sizes nil)
           (embed (lambda (inputs &rest r)
                    (push (length inputs) sizes)
                    (if (> (length inputs) 2) (signal 'drgnx-ai-embed-error (list "too many"))
                      (apply ok inputs r))))
           (r (drgnx-search-index root :embed embed :batch 4)))
      (should-not (plist-get r :error))
      (should (= (plist-get r :added) 6))
      ;; 4 fails, then 2 + 2 (the halved batch stays for the rest of the run): 6 files in 3 requests of 2
      (should (equal (reverse sizes) '(4 2 2 2))))))

(ert-deftest drgnx-search-index/dims-change-needs-a-rebuild ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 3)
    (drgnx-search-index root :embed (drgnx-search-index-test--stub 8))
    (drgnx-search-index-test--write root "f1.txt" "changed\n")
    (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub 4))))
      (should (string-match-p "the index was built with stub-model (8); re-index" (plist-get r :error))))
    ;; nothing changed in the index
    (should (= (drgnx-search-index-test--chunk-count root) 3))
    (should (= (plist-get (drgnx-search-index-test--peek root #'drgnx-search-store-meta) :dims) 8))
    ;; another model with the same dims is a fallback that answered: said so, not a re-index
    (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub 8 "other-model"))))
      (should (string-match-p "answered by fallback other-model; the index was built with stub-model"
                              (plist-get r :error))))
    ;; a rebuild starts over
    (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub 4) :rebuild t)))
      (should-not (plist-get r :error))
      (should (= (plist-get r :added) 3))
      (should (= (plist-get r :removed) 0))
      (should (= (plist-get (drgnx-search-index-test--peek root #'drgnx-search-store-meta) :dims) 4))
      (should (= (drgnx-search-index-test--chunk-count root) 3)))))

(ert-deftest drgnx-search-index/one-indexer-per-project ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 2)
    (let (inner)
      (drgnx-search-index root :embed (let ((ok (drgnx-search-index-test--stub)))
                                        (lambda (inputs &rest r)
                                          (setq inner (drgnx-search-index root :embed ok))
                                          (apply ok inputs r))))
      (should (equal (plist-get inner :error) "indexing"))
      (should-not (file-exists-p (drgnx-search-index-test--lock root))))
    ;; a lock left by a process that is gone is taken over
    (make-directory (file-name-directory (drgnx-search-index-test--lock root)) t)
    (write-region "999999999 12345.0" nil (drgnx-search-index-test--lock root) nil 'silent)
    (should-not (plist-get (drgnx-search-index root :embed (drgnx-search-index-test--stub) :rebuild t) :error))
    (should-not (file-exists-p (drgnx-search-index-test--lock root)))
    ;; a live pid with another start time is a recycled pid: also stale
    (write-region (format "%d 12345.0" (emacs-pid)) nil (drgnx-search-index-test--lock root) nil 'silent)
    (should-not (plist-get (drgnx-search-index root :embed (drgnx-search-index-test--stub)) :error))
    (should-not (file-exists-p (drgnx-search-index-test--lock root)))))

;;;; Listing trouble and unreadable files

(ert-deftest drgnx-search-index/a-git-failure-changes-nothing ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 3)
    (drgnx-search-index root :embed (drgnx-search-index-test--stub))
    (let ((before (drgnx-search-index-test--peek root #'drgnx-search-store-meta)))
      (cl-letf (((symbol-function 'drgnx-search-files)
                 (lambda (_) (signal 'drgnx-search-files-error (list "git ls-files failed: boom")))))
        (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub))))
          (should (string-match-p "boom" (plist-get r :error)))
          (should (= (or (plist-get r :removed) 0) 0))))
      (should (equal (drgnx-search-index-test--paths root) '("f1.txt" "f2.txt" "f3.txt")))
      (should (equal (drgnx-search-index-test--peek root #'drgnx-search-store-meta) before))
      (should-not (file-exists-p (drgnx-search-index-test--lock root))))))

(ert-deftest drgnx-search-index/not-a-project-or-off-is-an-error-and-changes-nothing ()
  (let* ((state (make-temp-file "drgnx-search-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (plain (make-temp-file "drgnx-search-plain" t)))
    (skip-unless (sqlite-available-p))
    (unwind-protect
        (let ((r (drgnx-search-index plain :embed (drgnx-search-index-test--stub))))
          (should (equal (plist-get r :error) "not a git project"))
          (should-not (file-exists-p (drgnx-search-store-file plain))))
      (delete-directory plain t) (delete-directory state t)))
  (drgnx-search-index-test--with (drgnx-search-index-test--named 2)
    (drgnx-search-index root :embed (drgnx-search-index-test--stub))
    (drgnx-search-index-test--write root ".drgnx/search.eld" "(:off t)")
    (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub))))
      (should (equal (plist-get r :error) "search is off for this project")))
    (should (equal (drgnx-search-index-test--paths root) '("f1.txt" "f2.txt")))))

(ert-deftest drgnx-search-index/unreadable-files-are-skipped-not-errors ()
  (drgnx-search-index-test--with `(("ok.txt" . "fine\n") ("latin1.txt" . ,(concat "caf" (unibyte-string #xe9) " au lait\n")))
    (cl-letf* ((orig (symbol-function 'drgnx-search-files))
               ((symbol-function 'drgnx-search-files)
                (lambda (r) (append (funcall orig r) (list (cons "ghost.txt" "0123456789abcdef"))))))
      (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub))))
        (should-not (plist-get r :error))
        (should (= (plist-get r :added) 1))
        (should (= (plist-get r :skipped) 2))
        (should (equal (drgnx-search-index-test--paths root) '("ok.txt")))
        (should-not (plist-get (drgnx-search-index-test--peek root #'drgnx-search-store-meta) :error))))))

;;;; Files that stop being indexable

(ert-deftest drgnx-search-index/a-changed-file-that-became-unreadable-loses-its-rows ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 3)
    (drgnx-search-index root :embed (drgnx-search-index-test--stub))
    ;; f1 becomes non-UTF-8, f2 vanishes from disk but is still listed
    (drgnx-search-index-test--write root "f1.txt" (concat "caf" (unibyte-string #xe9) " now\n"))
    (drgnx-search-index-test--write root "f2.txt" "edited\n")
    (cl-letf* ((orig (symbol-function 'drgnx-search-files))
               ((symbol-function 'drgnx-search-files)
                (lambda (r) (prog1 (funcall orig r) (delete-file (expand-file-name "f2.txt" r))))))
      (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub))))
        (should-not (plist-get r :error))
        (should (= (plist-get r :skipped) 2))
        (should (= (plist-get r :changed) 0))))
    (should (equal (drgnx-search-index-test--paths root) '("f3.txt")))
    (should (= (drgnx-search-index-test--chunk-count root "f1.txt") 0))
    (should (= (drgnx-search-index-test--chunk-count root "f2.txt") 0))))

(ert-deftest drgnx-search-index/a-file-grown-past-the-limit-is-never-read-whole ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 2)
    (drgnx-search-index root :embed (drgnx-search-index-test--stub))
    (drgnx-search-index-test--write root "f1.txt" "small edit\n")
    (let (ends)
      (cl-letf* ((orig (symbol-function 'drgnx-search-files))
                 ((symbol-function 'drgnx-search-files)
                  ;; listed small, then grown before it is read
                  (lambda (r) (prog1 (funcall orig r)
                                (drgnx-search-index-test--write
                                 r "f1.txt" (make-string (+ drgnx-search-chunk-max-file-bytes 5000) ?x)))))
                 (orig-insert (symbol-function 'insert-file-contents-literally))
                 ((symbol-function 'insert-file-contents-literally)
                  (lambda (file &optional visit beg end replace)
                    (push end ends) (funcall orig-insert file visit beg end replace))))
        (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub))))
          (should (= (plist-get r :skipped) 1))))
      (should ends)
      (should (cl-every (lambda (e) (and e (<= e (1+ drgnx-search-chunk-max-file-bytes)))) ends)))
    (should (= (drgnx-search-index-test--chunk-count root "f1.txt") 0))
    (should (equal (drgnx-search-index-test--paths root) '("f2.txt")))))

(ert-deftest drgnx-search-index/the-lock-of-another-process-is-not-removed ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 2)
    (let ((ok (drgnx-search-index-test--stub)) (lock (drgnx-search-index-test--lock root)))
      ;; while we index, the lock is replaced (as if taken over after being judged stale)
      (drgnx-search-index root :embed (lambda (inputs &rest r)
                                        (write-region "4242 1.0" nil lock nil 'silent)
                                        (apply ok inputs r)))
      (should (equal (with-temp-buffer (insert-file-contents lock) (buffer-string)) "4242 1.0"))
      (delete-file lock)
      (drgnx-search-index root :embed ok :rebuild t)
      (should-not (file-exists-p lock)))))

;;;; Starting it

(ert-deftest drgnx-jobs/memory-max-reaches-systemd-run ()
  (let ((with (drgnx-jobs--systemd-args "id1" "/tmp" "true" nil nil "1G"))
        (without (drgnx-jobs--systemd-args "id1" "/tmp" "true" nil nil)))
    (should (equal (cl-subseq (member "-p" with) 0 4) '("-p" "MemoryMax=1G" "-p" "MemorySwapMax=0")))
    ;; before the command, which stays last
    (should (< (cl-position "MemoryMax=1G" with :test #'equal) (cl-position "sh" with :test #'equal)))
    (should (equal (last with 3) '("sh" "-c" "true")))
    (should-not (member "-p" without))))

(ert-deftest drgnx-jobs/nice-reaches-systemd-run ()
  (let ((with (drgnx-jobs--systemd-args "id1" "/tmp" "true" nil nil "1G" 10))
        (only (drgnx-jobs--systemd-args "id1" "/tmp" "true" nil nil nil 10))
        (without (drgnx-jobs--systemd-args "id1" "/tmp" "true" nil nil "1G")))
    (should (member "Nice=10" with))
    (should (equal (cl-subseq (member "-p" only) 0 2) '("-p" "Nice=10")))
    (should (< (cl-position "Nice=10" with :test #'equal) (cl-position "sh" with :test #'equal)))
    (should (equal (last with 3) '("sh" "-c" "true")))
    (should-not (cl-find-if (lambda (a) (string-prefix-p "Nice=" a)) without))))

(ert-deftest drgnx-search-index/start-runs-the-cli-memory-capped-once-per-project ()
  (let* ((state (make-temp-file "drgnx-search-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (lock (drgnx-search-index--lock-file "/tmp/some-project"))
         started)
    (unwind-protect
        ;; the start never lists the jobs (a timer starts it): the lock says whether an indexer runs
        (cl-letf (((symbol-function 'drgnx-jobs-start)
                   (lambda (name command &rest keys) (push (list name command keys) started) "job-1"))
                  ((symbol-function 'drgnx-jobs-list) (lambda () (error "the jobs were listed"))))
          (let ((id (drgnx-search-index-start "/tmp/some-project/")))
            (should (equal id "job-1"))
            (pcase-let ((`(,name ,command ,keys) (car started)))
              (should (equal name "search-index: some-project"))
              (should (equal (car command) (expand-file-name invocation-name invocation-directory)))
              (should (member "--batch" command))
              ;; newer sources win over stale .elc files, as in bin/drgnx
              (should (equal (cl-subseq (member "--eval" command) 0 2) '("--eval" "(setq load-prefer-newer t)")))
              (should (member "drgnx-search-index-cli" command))
              (should (equal (car (last command)) "/tmp/some-project"))
              (should (file-exists-p (expand-file-name "drgnx-search-index.el"
                                                       (cadr (member "-L" command)))))
              (should (equal (plist-get keys :memory-max) "1G"))))
          (drgnx-search-index-start "/tmp/some-project" t)
          (should (equal (cl-subseq (reverse (nth 1 (car started))) 0 2) '("--rebuild" "/tmp/some-project")))
          ;; a live process holds the project's lock: nothing new starts
          (setq started nil)
          (make-directory (file-name-directory lock) t)
          (write-region (format "%d %s" (emacs-pid) (drgnx-search-index--start-time (emacs-pid))) nil lock nil 'silent)
          (should (drgnx-search-index-running-p "/tmp/some-project"))
          (should-not (drgnx-search-index-start "/tmp/some-project"))
          (should-not started)
          ;; a stale lock (its process is gone) does not count
          (write-region "999999999 12345.0" nil lock nil 'silent)
          (should-not (drgnx-search-index-running-p "/tmp/some-project"))
          (should (equal (drgnx-search-index-start "/tmp/some-project") "job-1")))
      (delete-directory state t))))

(defun drgnx-search-index-test--fake-job (id name root &optional exit)
  "A job directory ID as drgnx-jobs writes it: NAME, indexing ROOT; EXIT (a string) when it has finished."
  (let ((dir (drgnx-jobs--dir id)))
    (make-directory dir t)
    (with-temp-file (expand-file-name "job.eld" dir)
      (prin1 (list :id id :name name :command (list "emacs" "-f" "drgnx-search-index-cli" root)) (current-buffer)))
    (when exit (write-region exit nil (expand-file-name "exit" dir) nil 'silent))
    dir))

(ert-deftest drgnx-search-index/start-reaps-the-finished-jobs-of-the-project-but-the-last ()
  (let* ((state (make-temp-file "drgnx-search-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
    (unwind-protect
        (let ((old (drgnx-search-index-test--fake-job "20260101-000001-1" "search-index: p" "/tmp/p" "0"))
              (stopped (drgnx-search-index-test--fake-job "20260101-000002-1" "search-index: p" "/tmp/p" "143"))
              (last (drgnx-search-index-test--fake-job "20260101-000003-1" "search-index: p" "/tmp/p" "1"))
              (running (drgnx-search-index-test--fake-job "20260101-000004-1" "search-index: p" "/tmp/p"))
              (other (drgnx-search-index-test--fake-job "20260101-000000-1" "search-index: q" "/tmp/q" "0"))
              (agent (drgnx-search-index-test--fake-job "20260101-000000-2" "agent: p" "/tmp/p" "0")))
          (set-file-times running (time-subtract nil 3600))   ; not a job that is just starting
          (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest _) "job-new"))
                    ((symbol-function 'drgnx-jobs-list) (lambda () (error "the jobs were listed"))))
            (should (equal (drgnx-search-index-start "/tmp/p") "job-new")))
          (should-not (file-exists-p old))
          (should-not (file-exists-p stopped))
          (should (file-exists-p last))          ; the newest finished one stays (its log)
          (should (file-exists-p running))       ; never one without an exit
          (should (file-exists-p other))         ; another project's
          (should (file-exists-p agent)))        ; not an index job
      (delete-directory state t))))

(ert-deftest drgnx-search-index/reap-removes-gone-jobs ()
  "A job whose process died without an exit file (status gone) is finished too; one still running, or not yet
started, stays."
  (let* ((state (make-temp-file "drgnx-search-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
    (unwind-protect
        (let ((gone-old (drgnx-search-index-test--fake-job "20260101-000001-1" "search-index: p" "/tmp/p"))
              (gone-new (drgnx-search-index-test--fake-job "20260101-000002-1" "search-index: p" "/tmp/p"))
              (live (drgnx-search-index-test--fake-job "20260101-000003-1" "search-index: p" "/tmp/p"))
              (starting (drgnx-search-index-test--fake-job "20260101-000004-1" "search-index: p" "/tmp/p")))
          (dolist (d (list gone-old gone-new)) (write-region "999999999\n" nil (expand-file-name "pid" d) nil 'silent))
          (write-region (format "%d\n" (emacs-pid)) nil (expand-file-name "pid" live) nil 'silent)
          (dolist (d (list gone-old gone-new)) (set-file-times d (time-subtract nil 3600)))
          (dolist (d (list live starting)) (set-file-times d (time-subtract nil 3600)))   ; not just starting
          (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest _) "job-new")))
            (should (equal (drgnx-search-index-start "/tmp/p") "job-new")))
          (should-not (file-exists-p gone-old))
          (should (file-exists-p gone-new))     ; the newest finished one stays (its log)
          (should (file-exists-p live))
          (should (file-exists-p starting)))
      (delete-directory state t))))

(ert-deftest drgnx-search-index/the-job-env-is-the-projects ()
  "The embed role (and so the keys the job gets) is resolved for ROOT — its .drgnx/ai.eld — not the current buffer."
  (let* ((conf (make-temp-file "drgnx-search-conf" t))
         (proj (make-temp-file "drgnx-search-proj" t))
         (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" conf) "ROLE_A_KEY=sk-a" "ROLE_B_KEY=sk-b")
                                      process-environment))
         (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq)) (drgnx-ai--read-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "ai.eld" conf)
            (prin1 '(:version 1
                              :providers ((ka :name "A" :kind openai :url "http://127.0.0.1:1/v1" :key-env "ROLE_A_KEY" :caps (embed))
                                          (kb :name "B" :kind openai :url "http://127.0.0.1:2/v1" :key-env "ROLE_B_KEY" :caps (embed)))
                              :roles ((embed (ka . "m"))))
                   (current-buffer)))
          (make-directory (expand-file-name ".drgnx" proj))
          (with-temp-file (expand-file-name ".drgnx/ai.eld" proj) (prin1 '(:roles ((embed (kb . "m")))) (current-buffer)))
          (let* ((default-directory (file-name-as-directory conf))
                 (env (drgnx-search-index--job-env proj)))
            (should (member "ROLE_B_KEY=sk-b" env))
            (should-not (member "ROLE_A_KEY=sk-a" env))))
      (delete-directory conf t)
      (delete-directory proj t))))

(ert-deftest drgnx-search-index/a-broken-config-changes-nothing ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 2)
    (drgnx-search-index root :embed (drgnx-search-index-test--stub))
    (let ((before (drgnx-search-index-test--peek root #'drgnx-search-store-meta)))
      (drgnx-search-index-test--write root ".drgnx/search.eld" "(:exclude \"f1.txt\")")
      (setq drgnx-search-index-test--calls nil)
      (drgnx-search-index-test--write root "f3.txt" "a new file")
      (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub))))
        (should (string-match-p "\\.drgnx/search\\.eld cannot be read" (plist-get r :error))))
      (should-not drgnx-search-index-test--calls)      ; nothing went to the provider
      (should (equal (drgnx-search-index-test--paths root) '("f1.txt" "f2.txt")))
      (should (equal (drgnx-search-index-test--peek root #'drgnx-search-store-meta) before)))))

(ert-deftest drgnx-search-index/start-gives-the-job-the-keys-and-dirs-it-needs ()
  (let* ((conf (make-temp-file "drgnx-search-conf" t))
         (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" conf) "XDG_STATE_HOME=/tmp/xs" "XDG_CONFIG_HOME=/tmp/xc"
                                            "XDG_CACHE_HOME=/tmp/xk" "XDG_DATA_HOME=/tmp/xd" "DRGNX_DATA_DIR=/tmp/dd"
                                            "SEARCH_TEST_KEY=sk-secret-1" "DRGNX_TASK=nope")
                                      process-environment))
         (auth-sources nil) (drgnx-ai--keys (make-hash-table :test #'eq)) (drgnx-ai--read-cache (make-hash-table :test #'equal))
         started)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "ai.eld" conf)
            (prin1 '(:version 1
                              :providers ((kz :name "K" :kind openai :url "http://127.0.0.1:1/v1" :key-env "SEARCH_TEST_KEY" :caps (embed))
                                          (nokey :name "N" :kind openai :url "http://127.0.0.1:2/v1" :key-env "SEARCH_TEST_NOKEY" :caps (embed)))
                              :roles ((embed (kz . "m") (nokey . "m") (tei))))
                   (current-buffer)))
          (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest args) (setq started args) "job-1"))
                    ((symbol-function 'drgnx-jobs-list) (lambda () nil)))
            (drgnx-search-index-start "/tmp/some-project"))
          (let ((env (plist-get (cddr started) :env)))
            (dolist (e '("SEARCH_TEST_KEY=sk-secret-1" "XDG_STATE_HOME=/tmp/xs" "XDG_CONFIG_HOME=/tmp/xc"
                         "XDG_CACHE_HOME=/tmp/xk" "XDG_DATA_HOME=/tmp/xd" "DRGNX_DATA_DIR=/tmp/dd"))
              (should (member e env)))
            (should (member (concat "DRGNX_CONFIG_DIR=" conf) env))
            (should-not (cl-find-if (lambda (e) (string-prefix-p "SEARCH_TEST_NOKEY" e)) env))
            (should-not (member "DRGNX_TASK=nope" env)))
          ;; nothing key-like in the command line, and the job is niced
          (should-not (cl-find-if (lambda (a) (string-match-p "sk-secret\\|KEY" a)) (cadr started)))
          (should (eql (plist-get (cddr started) :nice) 10)))
      (delete-directory conf t))))

(ert-deftest drgnx-search-index/cli-prints-one-line-and-exits-1-on-error ()
  (let* ((state (make-temp-file "drgnx-search-state" t))
         (plain (make-temp-file "drgnx-search-plain" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (core (file-name-directory (locate-library "drgnx-search-index"))))
    (unwind-protect
        (with-temp-buffer
          (let ((code (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                                    "--batch" "-Q" "--eval" "(setq load-prefer-newer t)" "-L" core "-l" "drgnx-search-index"
                                    "-f" "drgnx-search-index-cli" plain "--rebuild")))
            (should (= code 1))
            (should (= (length (split-string (string-trim (buffer-string)) "\n")) 1))
            (should (string-match-p "not a git project" (buffer-string)))))
      (delete-directory plain t) (delete-directory state t))))

(ert-deftest drgnx-search-index/summary-line ()
  (should (string-match-p "added 2, changed 1, removed 3"
                          (drgnx-search-index--summary '(:added 2 :changed 1 :removed 3 :chunks 9 :seconds 1.5 :skipped 0))))
  (should (string-match-p "boom" (drgnx-search-index--summary '(:added 2 :error "boom")))))


;;;; Minors (M10-11)

(ert-deftest drgnx-search-index/a-same-dims-fallback-is-named-not-a-reindex ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 2)
    (should-not (plist-get (drgnx-search-index root :embed (drgnx-search-index-test--stub 8 "main-model")) :error))
    (drgnx-search-index-test--write root "f3.txt" "a third file\n")
    (drgnx-search-index-test--git root "add" "-A" "-f")
    (let ((err (plist-get (drgnx-search-index root :embed (drgnx-search-index-test--stub 8 "backup-model")) :error)))
      (should (string-match-p "answered by fallback backup-model" err))
      (should (string-match-p "main-model" err))
      (should-not (string-match-p "re-index" err)))
    ;; other dimensions still say the index must be rebuilt
    (should (string-match-p "re-index"
                            (plist-get (drgnx-search-index root :embed (drgnx-search-index-test--stub 4 "other")) :error)))))

(ert-deftest drgnx-search-index/one-poisoned-chunk-skips-its-file ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 4)
    (let* ((ok (drgnx-search-index-test--stub))
           (embed (lambda (inputs &rest r)
                    (if (cl-some (lambda (x) (string-match-p "file2 " x)) inputs)
                        (signal 'drgnx-ai-embed-error (list "tei: HTTP 413 input too long"))
                      (apply ok inputs r))))
           (r (drgnx-search-index root :embed embed :batch 1)))
      (should-not (plist-get r :error))
      (should (= (plist-get r :skipped) 1))
      (should (= (plist-get r :added) 3))
      (should (equal (drgnx-search-index-test--paths root) '("f1.txt" "f3.txt" "f4.txt")))
      (should (floatp (plist-get (drgnx-search-index-test--peek root #'drgnx-search-store-meta) :indexed-at))))))

(ert-deftest drgnx-search-index/one-poisoned-chunk-skips-its-file-at-the-default-batch ()
  "With the default batch (32), a refused request is narrowed down to the one chunk the provider refuses."
  (drgnx-search-index-test--with (drgnx-search-index-test--named 40)
    (let* ((ok (drgnx-search-index-test--stub))
           (embed (lambda (inputs &rest r)
                    (if (cl-some (lambda (x) (string-match-p "file7 " x)) inputs)
                        (signal 'drgnx-ai-embed-error (list "tei: HTTP 413 input too long"))
                      (apply ok inputs r))))
           (r (drgnx-search-index root :embed embed)))
      (should-not (plist-get r :error))
      (should (= (plist-get r :skipped) 1))
      (should (= (plist-get r :added) 39))
      (should-not (member "f7.txt" (drgnx-search-index-test--paths root)))
      (should (member "f8.txt" (drgnx-search-index-test--paths root))))))

(ert-deftest drgnx-search-index/a-poisoned-file-with-several-chunks-is-skipped-whole ()
  (drgnx-search-index-test--with
      (list (cons "big.txt" (mapconcat (lambda (n) (format "poison line %d with some text" n)) (number-sequence 1 400) "\n"))
            (cons "ok.txt" "fine\n"))
    (let* ((ok (drgnx-search-index-test--stub))
           (embed (lambda (inputs &rest r)
                    (if (cl-some (lambda (x) (string-match-p "poison line 1 " x)) inputs)
                        (signal 'drgnx-ai-embed-error (list "tei: HTTP 413"))
                      (apply ok inputs r))))
           (r (drgnx-search-index root :embed embed)))
      (should-not (plist-get r :error))
      (should (= (plist-get r :skipped) 1))
      (should (equal (drgnx-search-index-test--paths root) '("ok.txt"))))))

(ert-deftest drgnx-search-index/a-provider-that-fails-every-chunk-still-stops-the-run ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 8)
    (let ((r (drgnx-search-index root :embed (lambda (&rest _) (signal 'drgnx-ai-embed-error (list "tei: down")))
                                 :batch 1)))
      (should (string-match-p "down" (plist-get r :error)))
      (should (<= (plist-get r :skipped) 3)))))

(ert-deftest drgnx-search-index/a-failing-repo-check-is-an-error-result ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 2)
    (cl-letf* ((orig (symbol-function 'drgnx-search--repo-p)) (calls 0)   ; the file listing asks too: only the later ask fails
               ((symbol-function 'drgnx-search--repo-p)
                (lambda (r) (if (> (cl-incf calls) 1) (signal 'drgnx-search-files-error (list "git rev-parse: boom")) (funcall orig r)))))
      (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub))))
        (should (string-match-p "boom" (plist-get r :error)))))
    (should-not (file-exists-p (drgnx-search-index-test--lock root)))))

(ert-deftest drgnx-search-index/crlf-and-a-bom-are-not-indexed ()
  (drgnx-search-index-test--with (list (cons "w.txt" (concat (unibyte-string #xEF #xBB #xBF) "one\r\ntwo\r\nthree\r\n")))
    (should-not (plist-get (drgnx-search-index root :embed (drgnx-search-index-test--stub)) :error))
    (let ((text (drgnx-search-index-test--peek root (lambda (db) (caar (sqlite-select db "select text from chunk"))))))
      (should (equal (string-trim-right text) "one\ntwo\nthree")))))   ; no BOM, no CR

(ert-deftest drgnx-search-index/a-lock-overwritten-right-after-taking-it-is-lost ()
  (drgnx-search-index-test--with (drgnx-search-index-test--named 1)
    (let ((lock (drgnx-search-index-test--lock root)))
      (make-directory (file-name-directory lock) t)
      (advice-add 'write-region :around
                  (lambda (orig start end file &rest more)   ; another process takes over at the same moment
                    (apply orig start end file more)
                    (when (equal file lock) (funcall orig "4242 1.0" nil file)))
                  '((name . steal)))
      (unwind-protect
          (should-not (drgnx-search-index--lock root))
        (advice-remove 'write-region 'steal)))))

(ert-deftest drgnx-search-index/a-start-right-after-another-start-backs-off ()
  (let* ((state (make-temp-file "drgnx-search-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
    (unwind-protect
        (let ((job (drgnx-search-index-test--fake-job "20260101-000001-1" "search-index: p" "/tmp/p")) (started nil))
          (cl-letf (((symbol-function 'drgnx-jobs-start) (lambda (&rest _) (setq started t) "job-new")))
            ;; a job dir without an exit file, just made: that job has not taken the lock yet
            (should-not (drgnx-search-index-start "/tmp/p"))
            (should-not started)
            ;; another project's is no reason to wait
            (should (equal (drgnx-search-index-start "/tmp/q") "job-new"))
            ;; an old one without an exit file is a job that died
            (set-file-times job (time-subtract nil 3600))
            (should (equal (drgnx-search-index-start "/tmp/p") "job-new"))))
      (delete-directory state t))))

(provide 'search-index-test)
;;; search-index-test.el ends here
