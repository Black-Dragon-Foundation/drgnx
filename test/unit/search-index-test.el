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
    ;; another model with the same dims is the same story
    (let ((r (drgnx-search-index root :embed (drgnx-search-index-test--stub 8 "other-model"))))
      (should (string-match-p "built with stub-model (8)" (plist-get r :error))))
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

;;;; Starting it

(ert-deftest drgnx-jobs/memory-max-reaches-systemd-run ()
  (let ((with (drgnx-jobs--systemd-args "id1" "/tmp" "true" nil nil "1G"))
        (without (drgnx-jobs--systemd-args "id1" "/tmp" "true" nil nil)))
    (should (equal (cl-subseq (member "-p" with) 0 4) '("-p" "MemoryMax=1G" "-p" "MemorySwapMax=0")))
    ;; before the command, which stays last
    (should (< (cl-position "MemoryMax=1G" with :test #'equal) (cl-position "sh" with :test #'equal)))
    (should (equal (last with 3) '("sh" "-c" "true")))
    (should-not (member "-p" without))))

(ert-deftest drgnx-search-index/start-runs-the-cli-memory-capped-once-per-project ()
  (let (started (running nil))
    (cl-letf (((symbol-function 'drgnx-jobs-start)
               (lambda (name command &rest keys) (push (list name command keys) started) "job-1"))
              ((symbol-function 'drgnx-jobs-list)
               (lambda () running)))
      (let ((id (drgnx-search-index-start "/tmp/some-project/")))
        (should (equal id "job-1"))
        (pcase-let ((`(,name ,command ,keys) (car started)))
          (should (equal name "search-index: some-project"))
          (should (equal (car command) (expand-file-name invocation-name invocation-directory)))
          (should (member "--batch" command))
          (should (member "drgnx-search-index-cli" command))
          (should (equal (car (last command)) "/tmp/some-project"))
          (should (file-exists-p (expand-file-name "drgnx-search-index.el"
                                                   (cadr (member "-L" command)))))
          (should (equal (plist-get keys :memory-max) "1G"))))
      (drgnx-search-index-start "/tmp/some-project" t)
      (should (equal (cl-subseq (reverse (nth 1 (car started))) 0 2) '("--rebuild" "/tmp/some-project")))
      ;; a running job for the project: nothing new starts, its id comes back
      (setq started nil
            running (list (list :id "job-0" :status 'running :name "search-index: some-project"
                                :command '("emacs" "-f" "drgnx-search-index-cli" "/tmp/some-project"))))
      (should (equal (drgnx-search-index-start "/tmp/some-project") "job-0"))
      (should-not started)
      ;; an exited one does not count, nor does another project's
      (setq running (list (list :id "job-0" :status 'exited :name "search-index: some-project"
                                :command '("emacs" "/tmp/some-project"))
                          (list :id "job-9" :status 'running :name "search-index: other"
                                :command '("emacs" "/tmp/other"))))
      (should (equal (drgnx-search-index-start "/tmp/some-project") "job-1")))))

(ert-deftest drgnx-search-index/cli-prints-one-line-and-exits-1-on-error ()
  (let* ((state (make-temp-file "drgnx-search-state" t))
         (plain (make-temp-file "drgnx-search-plain" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (core (file-name-directory (locate-library "drgnx-search-index"))))
    (unwind-protect
        (with-temp-buffer
          (let ((code (call-process (expand-file-name invocation-name invocation-directory) nil t nil
                                    "--batch" "-Q" "-L" core "-l" "drgnx-search-index"
                                    "-f" "drgnx-search-index-cli" plain "--rebuild")))
            (should (= code 1))
            (should (= (length (split-string (string-trim (buffer-string)) "\n")) 1))
            (should (string-match-p "not a git project" (buffer-string)))))
      (delete-directory plain t) (delete-directory state t))))

(ert-deftest drgnx-search-index/summary-line ()
  (should (string-match-p "added 2, changed 1, removed 3"
                          (drgnx-search-index--summary '(:added 2 :changed 1 :removed 3 :chunks 9 :seconds 1.5 :skipped 0))))
  (should (string-match-p "boom" (drgnx-search-index--summary '(:added 2 :error "boom")))))

(provide 'search-index-test)
;;; search-index-test.el ends here
