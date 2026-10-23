;;; work-scan-test.el --- batch tests: the work tracker writes through the hub (scan, record, collected jobs) -*- lexical-binding: t -*-
;; The hub's calls are recorded (drgnx-hub-call-sync and drgnx-hub-call stubbed) except in the rows marked "binary",
;; which run the real `bin/drgnx work …' against DRGNX_RATATOSKR_BIN.  The fixture tree is the parity oracle's
;; (test/fixtures/work-scan-parity/gen.el).
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-work)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/work-scan-parity/gen.el" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/work-fixture" drgnx-dir) nil t)

(defvar drgnx-work-scan-test--calls nil "The hub calls made, oldest last: (METHOD . PARAMS).")

(defmacro drgnx-work-scan-test--with-tree (root &rest body)
  "BODY with ROOT the oracle's fixture tree under a temp HOME/data dir, the hub's calls recorded (the answer: nothing
changed, nothing refused; `drgnx-work-scan-test--refused' sets a refusal), no hub ensured."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (file-truename (make-temp-file "drgnx-work-scan" t))))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" ,root "data") (concat "DRGNX_CONFIG_DIR=" ,root "config")
                                             (concat "HOME=" ,root "home"))
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-work-db--read-handles nil) (drgnx-work-scan-test--calls nil))
     (unwind-protect
         (progn
           (make-directory (concat ,root "home") t)
           (drgnx-work-parity-build ,root)
           ,@body)
       (drgnx-work-db-close-all)
       (delete-directory ,root t))))

(defvar drgnx-work-scan-test--answer (list :changed 0 :retired 0 :refused []) "What the recording stub answers.")

(defmacro drgnx-work-scan-test--recording (&rest body)
  "BODY with the hub's calls recorded in `drgnx-work-scan-test--calls' and answered by `drgnx-work-scan-test--answer'."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'drgnx-hub-ensure) (lambda () t))
             ((symbol-function 'drgnx-hub-call-sync)
              (lambda (method params &optional _timeout)
                (setq drgnx-work-scan-test--calls (append drgnx-work-scan-test--calls (list (cons method params))))
                drgnx-work-scan-test--answer))
             ((symbol-function 'drgnx-hub-call)
              (lambda (method params callback &rest _)
                (setq drgnx-work-scan-test--calls (append drgnx-work-scan-test--calls (list (cons method params))))
                (funcall callback drgnx-work-scan-test--answer nil)
                1)))
     ,@body))

(defun drgnx-work-scan-test--board (root) (concat root "org/board.org"))

(defun drgnx-work-scan-test--puts ()
  (seq-filter (lambda (c) (equal (car c) "graph/put-parsed")) drgnx-work-scan-test--calls))

(defun drgnx-work-scan-test--entities (params)
  "Every entity of PARAMS's sources."
  (apply #'append (mapcar (lambda (s) (append (plist-get s :entities) nil)) (plist-get params :sources))))

(defun drgnx-work-scan-test--scan (root)
  (drgnx-work-scan (list root) :board (drgnx-work-scan-test--board root)))

;;;; The scan sends one request

(ert-deftest drgnx-work-scan/one-put-parsed-per-scan ()
  (drgnx-work-scan-test--with-tree root
    (drgnx-work-scan-test--recording (drgnx-work-scan-test--scan root))
    (should (= (length drgnx-work-scan-test--calls) 1))
    (should (= (length (drgnx-work-scan-test--puts)) 1))))

(ert-deftest drgnx-work-scan/a-todo-finds-its-plan-in-the-same-scan ()
  (drgnx-work-scan-test--with-tree root
    (drgnx-work-scan-test--recording (drgnx-work-scan-test--scan root))
    (let* ((params (cdr (car (drgnx-work-scan-test--puts))))
           (todos (seq-filter (lambda (e) (equal (plist-get e :kind) "todo")) (drgnx-work-scan-test--entities params))))
      (should (= (length todos) 2))
      (should (equal (plist-get (plist-get (car todos) :data) :parent) (concat "plan:" root "docs/plans/p.md"))))))

(ert-deftest drgnx-work-scan/sources-are-typed ()
  (drgnx-work-scan-test--with-tree root
    (drgnx-work-scan-test--recording (drgnx-work-scan-test--scan root))
    (let ((kinds nil))
      (seq-doseq (s (plist-get (cdr (car (drgnx-work-scan-test--puts))) :sources))
        (let ((ref (plist-get s :source)))
          (should (listp ref))
          (push (plist-get ref :kind) kinds)
          (if (member (plist-get ref :kind) '("file" "spec"))
              (should (string-prefix-p root (plist-get ref :path)))
            (should-not (plist-get ref :path)))))
      (should (equal (sort (delete-dups kinds) #'string<) '("branch" "commit" "file" "spec"))))))

(ert-deftest drgnx-work-scan/ledger-and-steps-send-status ()
  (drgnx-work-scan-test--with-tree root
    (drgnx-work-scan-test--recording (drgnx-work-scan-test--scan root))
    (let* ((params (cdr (car (drgnx-work-scan-test--puts))))
           (updates (append (plist-get params :updates) nil))
           (status (lambda (id) (plist-get (seq-find (lambda (u) (equal (plist-get u :id) id)) updates) :status)))
           (p (concat root "docs/plans/p.md")))
      (should (equal (funcall status (concat "task:" p "#1")) "done"))   ; the ledger
      (should (equal (funcall status (concat "task:" p "#3")) "done"))   ; every step ticked
      (should-not (funcall status (concat "task:" p "#2")))
      ;; the entity is as parsed: open
      (should (equal (plist-get (seq-find (lambda (e) (equal (plist-get e :id) (concat "task:" p "#1")))
                                          (drgnx-work-scan-test--entities params))
                                :status)
                     "open")))))

(ert-deftest drgnx-work-scan/derived-updates-are-sent ()
  (drgnx-work-scan-test--with-tree root
    (drgnx-work-scan-test--recording (drgnx-work-scan-test--scan root))
    (let* ((updates (append (plist-get (cdr (car (drgnx-work-scan-test--puts))) :updates) nil))
           (q (seq-find (lambda (u) (equal (plist-get u :id) (concat "plan:" root "docs/plans/q.md"))) updates)))
      ;; git facts: the worktree's branch, merged into main
      (should (equal (plist-get (plist-get q :data_patch) :branch) "feat"))
      (should (eq (plist-get (plist-get q :data_patch) :merged) t))
      (should (plist-get (plist-get q :data_patch) :worktree)))))

(ert-deftest drgnx-work-scan/unchanged-files-send-nothing ()
  (drgnx-work-scan-test--with-tree root
    ;; the first scan lands in the rows; a spec a plan names outside specs/ is read once more on the next (its time is
    ;; kept from then on), so the second scan is the one that settles
    (drgnx-work-fixture-with-hub (drgnx-work-scan-test--scan root))
    (drgnx-work-db-close-all)
    (drgnx-work-fixture-with-hub (drgnx-work-scan-test--scan root))
    (drgnx-work-db-close-all)
    (drgnx-work-scan-test--recording (drgnx-work-scan-test--scan root))
    (should-not drgnx-work-scan-test--calls)))

(ert-deftest drgnx-work-scan/gone-files-are-sent-as-gone ()
  (drgnx-work-scan-test--with-tree root
    (drgnx-work-fixture-with-hub (drgnx-work-scan-test--scan root))
    (delete-file (concat root "docs/plans/q.md"))
    (drgnx-work-scan-test--recording (drgnx-work-scan-test--scan root))
    (let* ((params (cdr (car (drgnx-work-scan-test--puts))))
           (gone (append (plist-get params :gone) nil)))
      (should (member (list :kind "file" :path (concat root "docs/plans/q.md")) gone)))))

(ert-deftest drgnx-work-scan/no-hub-says-so-and-exits-non-zero ()
  (drgnx-work-scan-test--with-tree root
    (drgnx-work-scan-test--recording
      (cl-letf (((symbol-function 'drgnx-hub-ensure) (lambda () (error "Ratatoskr is not built: run `drgnx runtime build'"))))
        (let* ((code nil)
               (out (with-output-to-string (setq code (drgnx-work-cli-run (list "scan" "--board" (drgnx-work-scan-test--board root) root))))))
          (should (string-search "the work tracker updates through the drgnx hub" out))
          (should (/= code 0))
          (should-not drgnx-work-scan-test--calls))))))

(ert-deftest drgnx-work-scan/a-refused-source-is-shown ()
  (drgnx-work-scan-test--with-tree root
    (let ((drgnx-work-scan-test--answer
           (list :changed 1 :retired 0
                 :refused (vector (list :source (list :kind "file" :path (concat root "docs/plans/p.md"))
                                        :why "personal notes are never stored")))))
      (drgnx-work-scan-test--recording
        (let* ((code nil)
               (out (with-output-to-string (setq code (drgnx-work-cli-run (list "scan" "--board" (drgnx-work-scan-test--board root) root))))))
          (should (string-search (concat root "docs/plans/p.md") out))
          (should (string-search "personal notes are never stored" out))
          (should (eql code 0)))))))

;;;; The scan's own door

(defmacro drgnx-work-scan-test--with-org (home root &rest body)
  "BODY with HOME a temp home holding org/x.md, ROOT a project in it whose plan names a spec; the hub recorded."
  (declare (indent 2))
  `(let* ((,home (file-name-as-directory (file-truename (make-temp-file "drgnx-work-door" t))))
          (,root (concat ,home "proj/"))
          (process-environment (append (list (concat "HOME=" ,home) (concat "DRGNX_CONFIG_DIR=" ,home "config")
                                             (concat "DRGNX_DATA_DIR=" ,home "data"))
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-work-db--read-handles nil) (drgnx-work-scan-test--calls nil))
     (unwind-protect
         (progn
           (make-directory (concat ,home "org") t) (make-directory (concat ,root "docs/plans") t)
           (write-region "# Secret\n" nil (concat ,home "org/x.md") nil 'silent)
           ,@body)
       (drgnx-work-db-close-all)
       (delete-directory ,home t))))

(ert-deftest drgnx-work-scan/a-spec-into-org-is-not-sent ()
  (drgnx-work-scan-test--with-org home root
    (write-region (format "# Plan\n\n**Spec:** `%sorg/x.md`\n\n### Task 1: one\n- [ ] a\n" home) nil (concat root "docs/plans/p.md") nil 'silent)
    (drgnx-work-scan-test--recording (drgnx-work-scan (list root)))
    (let ((params (cdr (car (drgnx-work-scan-test--puts)))))
      (should (seq-find (lambda (e) (equal (plist-get e :kind) "plan")) (drgnx-work-scan-test--entities params)))
      (should-not (string-search "org/x.md" (format "%S" params))))))

(ert-deftest drgnx-work-scan/a-spec-symlink-into-org-is-not-sent ()
  (drgnx-work-scan-test--with-org home root
    (make-symbolic-link (concat home "org/x.md") (concat root "docs/link.md"))
    (write-region "# Plan\n\n**Spec:** `docs/link.md`\n\n### Task 1: one\n- [ ] a\n" nil (concat root "docs/plans/p.md") nil 'silent)
    (drgnx-work-scan-test--recording (drgnx-work-scan (list root)))
    (let ((params (cdr (car (drgnx-work-scan-test--puts)))))
      (should (seq-find (lambda (e) (equal (plist-get e :kind) "plan")) (drgnx-work-scan-test--entities params)))
      (should-not (string-search "link.md\"" (format "%S" (seq-remove (lambda (e) (equal (plist-get e :kind) "plan"))
                                                                      (drgnx-work-scan-test--entities params)))))
      (should-not (seq-find (lambda (e) (equal (plist-get e :kind) "spec")) (drgnx-work-scan-test--entities params))))))

(ert-deftest drgnx-work-scan/a-root-inside-org-is-refused-before-any-git ()
  ;; ~/org and a project in it (both git repositories, the project's plan opted in): refused as the search indexer
  ;; refuses them (hard tier, opt-ins ignored) before anything under them is read or any git runs there; the other
  ;; root is scanned
  (drgnx-work-scan-test--with-org home root
    (let* ((org (concat home "org/")) (notes (concat org "proj/")) (allow (concat home "config/personal-notes-allow.json"))
           gits reads code out)
      (make-directory (concat notes "docs/plans") t)
      (make-directory (concat notes ".superpowers/sdd/n") t)
      (write-region "# Private plan\n\n### Task 1: one\n- [ ] a\n" nil (concat notes "docs/plans/n.md") nil 'silent)
      (write-region "# SDD ledger — plan: docs/plans/n.md\nTask 1: complete (commits abc1234..def5678)\n" nil
                    (concat notes ".superpowers/sdd/n/progress.md") nil 'silent)
      (write-region "# Plan\n\n### Task 1: one\n- [ ] a\n" nil (concat root "docs/plans/p.md") nil 'silent)
      (dolist (d (list org notes root)) (let ((default-directory d)) (call-process "git" nil nil nil "init" "-q")))
      (make-directory (concat home "config") t)
      (write-region (format "{\"version\": 1, \"paths\": [\"%sdocs/plans/n.md\"]}" notes) nil allow nil 'silent)
      (set-file-modes allow #o600)
      (cl-letf* ((cp (symbol-function 'call-process))
                 ((symbol-function 'call-process)
                  (lambda (program &rest args) (when (equal program "git") (push default-directory gits)) (apply cp program args)))
                 (cpr (symbol-function 'call-process-region))
                 ((symbol-function 'call-process-region)
                  (lambda (start end program &rest args)
                    (when (equal program "git") (push default-directory gits))
                    (apply cpr start end program args)))
                 (df (symbol-function 'directory-files))
                 ((symbol-function 'directory-files) (lambda (dir &rest args) (push dir reads) (apply df dir args)))
                 (ifc (symbol-function 'insert-file-contents))
                 ((symbol-function 'insert-file-contents) (lambda (file &rest args) (push file reads) (apply ifc file args))))
        (drgnx-work-scan-test--recording
          (setq out (with-output-to-string (setq code (drgnx-work-cli-run (list "scan" notes org root)))))))
      (should (eql code 0))
      (dolist (r (list notes org))
        (should (string-search (format "refused: %s (%s)" (directory-file-name r) drgnx-work-scan-personal-notes-refusal) out)))
      (let ((inside (lambda (f) (string-prefix-p org (file-name-as-directory (expand-file-name f))))))
        (should-not (seq-filter inside gits))
        (should-not (seq-filter inside reads)))
      ;; the other root: its plan was sent, and nothing of org
      (let ((params (cdr (car (drgnx-work-scan-test--puts)))))
        (should (seq-find (lambda (e) (equal (plist-get e :id) (concat "plan:" root "docs/plans/p.md")))
                          (drgnx-work-scan-test--entities params)))
        (should-not (string-search org (format "%S" params)))))))

;;;; Recording

(defun drgnx-work-scan-test--repo (root)
  "The oracle tree's code repository and its three commits: (REPO C0 C1 C2) (short SHAs, oldest first)."
  (let ((repo (concat root "code/")))
    (cons repo (reverse (split-string (drgnx-work-parity--git repo "log" "--format=%h") "\n" t)))))

(ert-deftest drgnx-work/record-calls-graph-record ()
  (drgnx-work-scan-test--with-tree root
    (pcase-let ((`(,repo ,_c0 ,_c1 ,c2) (drgnx-work-scan-test--repo root)))
      (drgnx-work-scan-test--recording
        ;; the daemon path: asynchronous
        (drgnx-work-record "task:/p.md#1" repo c2)
        ;; a batch command: it waits, and answers the ids
        (let ((drgnx-work--sync t))
          (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                     (lambda (method params &optional _)
                       (push (cons method params) drgnx-work-scan-test--calls) (list :ids ["commit:abc"]))))
            (should (equal (drgnx-work-record "task:/p.md#2" repo c2) "commit:abc")))))
      (should (= (length drgnx-work-scan-test--calls) 2))
      (dolist (c drgnx-work-scan-test--calls)
        (should (equal (car c) "graph/record"))
        (should (string-prefix-p "task:/p.md#" (plist-get (cdr c) :task)))
        (should (equal (plist-get (aref (plist-get (cdr c) :commits) 0) :subject) "task one, more"))))))

(ert-deftest drgnx-work/collect-jobs-sends-its-key ()
  (drgnx-work-scan-test--with-tree root
    (require 'drgnx-jobs)
    (pcase-let ((`(,repo ,c0 ,_c1 ,c2) (drgnx-work-scan-test--repo root)))
      (let ((jobs (list (list :id "j9" :task "task:/p.md#1" :status 'exited :cwd repo :head c0 :start-time 0)
                        (list :id "j8" :task "task:/p.md#2" :status 'exited :cwd repo :head c2 :start-time 0))))
        (cl-letf (((symbol-function 'drgnx-jobs-list) (lambda () jobs))
                  ((symbol-function 'drgnx-jobs--dir) (lambda (_id) root))
                  ((symbol-function 'drgnx-jobs--text) (lambda (&rest _) c2)))
          (drgnx-work-scan-test--recording (drgnx-work-collect-jobs)))
        ;; j9 made commits: graph/record with its key; j8 made none: the key alone, through put-parsed
        (let ((record (seq-find (lambda (c) (equal (car c) "graph/record")) drgnx-work-scan-test--calls))
              (empty (seq-find (lambda (c) (equal (car c) "graph/put-parsed")) drgnx-work-scan-test--calls)))
          (should (equal (plist-get (cdr record) :collected) "job j9"))
          (should (= (length (plist-get (cdr record) :commits)) 2))
          (should (equal (plist-get (cdr empty) :collected) ["job j8"])))))))

(ert-deftest drgnx-work/task-collect-never-waits ()
  (drgnx-work-scan-test--with-tree root
    (pcase-let ((`(,repo ,_c0 ,_c1 ,_c2) (drgnx-work-scan-test--repo root)))
      (let ((st (drgnx-work-task-begin "task:/p.md#1" repo)) (inhibit-interaction t))
        (drgnx-work-parity--commit repo "c" "3" "a turn's work" 4)
        (drgnx-work-scan-test--recording
          (cl-letf (((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (ert-fail "the turn-end path waited for the hub"))))
            (should (= (length (drgnx-work-task-collect st 0)) 1))))
        (should (equal (mapcar #'car drgnx-work-scan-test--calls) '("graph/record")))))))

;;;; Binary: the real bin/drgnx against Ratatoskr

(defmacro drgnx-work-scan-test--with-hub (root cli &rest body)
  "BODY with ROOT the oracle's tree, CLI a function running `bin/drgnx ARGS…' ((EXIT . OUTPUT)) against a hub that
Ratatoskr (DRGNX_RATATOSKR_BIN) starts for it, and the test's environment in effect; the hub is stopped after."
  (declare (indent 2))
  `(let* ((,root (file-name-as-directory (file-truename (make-temp-file "drgnx-work-hub" t))))
          (bin (expand-file-name "bin/drgnx" drgnx-dir))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" ,root "config") (concat "DRGNX_DATA_DIR=" ,root "data")
                                             (concat "XDG_STATE_HOME=" ,root "state") (concat "HOME=" ,root "home")
                                             "DRGNX_NO_HUB_START" "RATATOSKR_SUPERVISOR=none"
                                             (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid)))
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-work-db--read-handles nil)
          (,cli (lambda (&rest args) (with-temp-buffer (cons (apply #'call-process bin nil t nil args) (buffer-string))))))
     (unwind-protect
         (progn (make-directory (concat ,root "config") t) (make-directory (concat ,root "home") t)
                ,@body)
       (ignore-errors (funcall ,cli "hub" "stop"))
       (let ((deadline (+ (float-time) 5))) (while (and (drgnx-hub-running-p) (< (float-time) deadline)) (sleep-for 0.1)))
       (drgnx-work-db-close-all)
       (delete-directory ,root t))))

(ert-deftest drgnx-bin/work-scan-goes-through-the-hub ()
  (skip-unless (getenv "DRGNX_RATATOSKR_BIN"))
  (drgnx-work-scan-test--with-hub root cli
    (make-directory (concat root "docs/plans") t)
    (write-region "# Plan P\n\n### Task 1: one\n- [ ] a\n" nil (concat root "docs/plans/p.md") nil 'silent)
    (let ((r (funcall cli "work" "scan" root)))
      (should (= (car r) 0))
      ;; the process has exited: the plan is in the store
      (should (equal (plist-get (drgnx-work-node (concat "plan:" root "docs/plans/p.md")) :title) "Plan P"))
      (should (equal (plist-get (drgnx-work-node (concat "task:" root "docs/plans/p.md#1")) :title) "one")))))

(ert-deftest drgnx-bin/work-record-goes-through-the-hub ()
  (skip-unless (getenv "DRGNX_RATATOSKR_BIN"))
  (drgnx-work-scan-test--with-hub root cli
    (should (= (car (funcall cli "work" "scan" "--board" (drgnx-work-parity-build root) root)) 0))
    (let ((default-directory (concat root "code/")))
      (let ((r (funcall cli "work" "record" "--task" (concat "task:" root "docs/plans/p.md#2") "HEAD")))
        (should (= (car r) 0))
        (should (string-search "task:" (cdr r)))
        (let ((sha (drgnx-work-parity--git (concat root "code") "rev-parse" "HEAD")))
          (should (equal (plist-get (drgnx-work-node (concat "commit:" sha)) :title) "task one, more")))))))

(ert-deftest drgnx-work-scan/parity-with-the-schema-6-scan ()
  (skip-unless (getenv "DRGNX_RATATOSKR_BIN"))
  (drgnx-work-scan-test--with-hub root cli
    (let ((board (drgnx-work-parity-build root)))
      (should (= (car (funcall cli "work" "scan" "--board" board root)) 0))
      (let* ((got (drgnx-work-parity-dump (drgnx-work-db-read) root))
             (want (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8))
                       (insert-file-contents (expand-file-name "test/fixtures/work-scan-parity/expected.json" drgnx-dir)))
                     (delq nil (mapcar (lambda (l) (and (string-match "\\`  \\(\\[.*\\]\\),?\\'" l) (match-string 1 l)))
                                       (split-string (buffer-string) "\n"))))))
        (should (> (length want) 20))
        (should (equal got want))))))

(provide 'work-scan-test)
;;; work-scan-test.el ends here
