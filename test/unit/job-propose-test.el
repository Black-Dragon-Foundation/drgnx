;;; job-propose-test.el --- batch tests: a plan read into a job proposal -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/support/work-db-gate" drgnx-dir) nil t)   ; the tests below are of the `local' writer
(require 'drgnx-job)
(require 'drgnx-ai)

(defconst drgnx-job-test--plan
  "# Build the parser

**Repo:** ../../code
**Won't build:** the XML export

### Task 1: The lexer

- [ ] Step 1: tokens

### Task 2: The grammar

- [ ] Step 1: rules
- [ ] Step 2: errors

### Task 3: The tests
**Depends:** Task 1, Task 2
**Role:** test

- [ ] Step 1: cases

### Task 4: The docs
**Depends:** Task 3
**Role:** docs

- [ ] Step 1: write it
")

(defmacro drgnx-job-test--with (&rest body)
  "BODY with drgnx's dirs in ROOT and PLAN the fixture plan (docs/plans/p.md; its repo ROOT/code)."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-job" t)))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" root "data") (concat "DRGNX_CONFIG_DIR=" root "config")
                                             (concat "XDG_STATE_HOME=" root "state"))
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-job-routes nil) (drgnx-ai--keys (make-hash-table :test #'eq))
          (drgnx-ai-providers nil) (drgnx-ai-roles nil)
          (plan (concat root "docs/plans/p.md")))
     (unwind-protect
         (progn (make-directory (concat root "docs/plans") t) (make-directory (concat root "code") t)
                (make-directory (concat root "config") t)
                (write-region drgnx-job-test--plan nil plan nil 'silent)
                ,@body)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(drgnx-work-db-writer-deftest drgnx-job/a-plan-reads-into-tasks-dependencies-and-roles ()
  (drgnx-job-test--with
    (let ((p (drgnx-job-read-plan plan)))
      (should (equal (plist-get p :title) "Build the parser"))
      (should (equal (plist-get p :repo) (concat root "code/")))
      (should (equal (mapcar (lambda (task) (list (plist-get task :n) (plist-get task :role) (plist-get task :deps))) (plist-get p :tasks))
                     '((1 "implement" nil) (2 "implement" nil) (3 "test" (1 2)) (4 "docs" (3)))))
      (should (string-search "Step 2: errors" (plist-get (nth 1 (plist-get p :tasks)) :body)))
      (should-not (string-search "Task 3" (plist-get (nth 1 (plist-get p :tasks)) :body)))
      (should (equal (plist-get p :decisions) '((:kind "wont-build" :subject "the XML export"))))
      (should (stringp (plist-get p :sha))))))

(drgnx-work-db-writer-deftest drgnx-job/a-proposal-is-stored-with-routes-and-an-estimate ()
  (drgnx-job-test--with
    (setq drgnx-ai-providers '((openrouter :name "OR" :kind openai :url "https://openrouter.ai/api/v1"
                                           :key-env "OPENROUTER_API_KEY" :caps (chat) :messages t :price (3.0 . 15.0)))
          drgnx-ai-roles '((agent (openrouter))))
    (let* ((drgnx-job-routes '((implement . "claude (OpenRouter)") (test . "claude (OpenRouter)")))
           (id (drgnx-job-propose plan))
           (job (drgnx-job-get id)) (prop (plist-get job :proposal)))
      (should (string-prefix-p "job-" id))
      (should (equal (plist-get job :status) "proposed"))
      (should (equal (cdr (assq 'docs (plist-get prop :routes))) "claude"))           ; the default
      (let ((est (plist-get prop :estimate)))
        (should (< (abs (- (plist-get est :usd) (* 3 (/ (+ (* 150000 3.0) (* 15000 15.0)) 1e6)))) 1e-9))
        (should (equal (plist-get est :unpriced) '("claude"))))
      (should (equal (mapcar (lambda (task) (plist-get task :status)) (drgnx-coord-tasks id)) '("ready" "ready" "pending" "pending"))))))

(drgnx-work-db-writer-deftest drgnx-job/a-budget-with-an-unpriced-provider-is-warned-about ()
  ;; the gateway counts only what it can price: a budget set over a provider without :price does not stop it
  (drgnx-job-test--with
    (setq drgnx-ai-providers '((openrouter :name "OR" :kind openai :url "https://openrouter.ai/api/v1"
                                           :key-env "OPENROUTER_API_KEY" :caps (chat) :messages t))
          drgnx-ai-roles '((agent (openrouter))))
    (let* ((drgnx-job-routes '((implement . "claude (OpenRouter)") (test "claude" "claude (OpenRouter)")))
           (warned (drgnx-job-get (drgnx-job-propose plan :budget 5)))
           (quiet (drgnx-job-get (drgnx-job-propose plan)))
           (cards (lambda (id) (mapcar (lambda (c) (plist-get c :title)) (drgnx-coord-cards id)))))
      (should (equal (plist-get (plist-get warned :proposal) :unpriced-budget) '("claude (OpenRouter)")))
      (should (seq-some (lambda (title) (string-search "claude (OpenRouter)" title)) (funcall cards (plist-get warned :id))))
      (should (plist-get (drgnx-job-summary (plist-get warned :id)) :warnings))
      (should-not (plist-get (plist-get quiet :proposal) :unpriced-budget))         ; no budget: nothing to warn about
      (should-not (seq-some (lambda (title) (string-search "budget" title)) (funcall cards (plist-get quiet :id)))))
    (let* ((drgnx-job-routes '((implement . "claude")))
           (id (drgnx-job-propose plan :budget 5)))                                ; a subscription profile: not counted at all
      (should-not (plist-get (plist-get (drgnx-job-get id) :proposal) :unpriced-budget)))))

(drgnx-work-db-writer-deftest drgnx-job/won-t-build-lines-become-the-user-s-decisions ()
  (drgnx-job-test--with
    (let* ((id (drgnx-job-propose plan)) (ds (drgnx-coord-decisions-since 0 id)))
      (should (= (length ds) 1))
      (should (equal (plist-get (car ds) :kind) "wont-build"))
      (should (equal (plist-get (car ds) :author) "user"))
      (should (equal (plist-get (car ds) :status) "current")))))

(drgnx-work-db-writer-deftest drgnx-job/a-cycle-or-an-unknown-dependency-is-refused ()
  (drgnx-job-test--with
    (write-region "# P\n\n### Task 1: a\n**Depends:** Task 2\n\n### Task 2: b\n**Depends:** Task 1\n" nil plan nil 'silent)
    (should (string-search "cycle" (cadr (should-error (drgnx-job-propose plan) :type 'user-error))))
    (write-region "# P\n\n### Task 1: a\n**Depends:** Task 9\n" nil plan nil 'silent)
    (should (string-search "Task 9" (cadr (should-error (drgnx-job-propose plan) :type 'user-error))))))

(drgnx-work-db-writer-deftest drgnx-job/a-duplicate-task-number-is-refused ()
  (drgnx-job-test--with
    (write-region "# P\n\n### Task 1: a\n\n### Task 2: b\n\n### Task 1: again\n" nil plan nil 'silent)
    (should (string-search "Task 1 appears twice" (cadr (should-error (drgnx-job-propose plan) :type 'user-error))))))

(drgnx-work-db-writer-deftest drgnx-job/a-changed-plan-is-noticed-never-applied ()
  (drgnx-job-test--with
    (let ((id (drgnx-job-propose plan)))
      (should-not (drgnx-job-plan-changed-p id))
      (write-region (concat drgnx-job-test--plan "\n### Task 5: More\n") nil plan nil 'silent)
      (should (drgnx-job-plan-changed-p id))
      (should (= (length (drgnx-coord-tasks id)) 4)))))

;;; job-propose-test.el ends here
