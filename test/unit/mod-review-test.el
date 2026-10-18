;;; mod-review-test.el --- batch tests: Review Branch — the review route on the branch's diff, findings in a tab -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-agents)
(require 'drgnx-job)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-diff" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-review" drgnx-dir) nil t)

(defconst drgnx-review-test--answer
  "I read the diff.\nFINDING: src/b.el:4: minor: a long name\nFINDING: src/a.el:12: critical: the loop never ends\nFINDING: src/a.el:3: major: unchecked nil\nVERDICT: fail")

(defmacro drgnx-review-test--branch (&rest body)
  "BODY in REPO: main with one commit, branch feature checked out with one more; a fake reviewer session S."
  (declare (indent 0))
  `(drgnx-git-test-with-repo
     (drgnx-git-test-write repo "src/a.el" (mapconcat (lambda (i) (format "(line %d)\n" i)) (number-sequence 1 20) ""))
     (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Start")
     (drgnx-git-test repo "checkout" "-q" "-b" "feature")
     (drgnx-git-test-write repo "src/b.el" "(b)\n")
     (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "Add b")
     (let* ((default-directory repo) (delivered nil) (drgnx-review--runs (make-hash-table :test #'equal))
            (drgnx-review--current nil)
            (s (drgnx-agents--make :id "rev-1" :name "reviewer" :status 'idle :conn 'fake :cwd repo)))
       (cl-letf (((symbol-function 'drgnx-agents-start) (lambda (_profile _cwd &rest _) s))
                 ((symbol-function 'drgnx-agents-deliver) (lambda (_s text) (push text delivered) t))
                 ((symbol-function 'drgnx-agents-kill) #'ignore))
         (unwind-protect (progn ,@body)
           (when (get-buffer "*drgnx review*") (kill-buffer "*drgnx review*")))))))

(defun drgnx-review-test--answer (s text)
  "S's turn ends with TEXT."
  (setf (drgnx-agent-session-entries s)
        (append (drgnx-agent-session-entries s)
                (list (list :type 'user :text "[drgnx review] …") (list :type 'agent :text text :done t) (list :type 'stop :stop "end_turn" :done t))))
  (drgnx-review--changed s))

(defun drgnx-review-test--wait-head ()
  "Wait for the background check of HEAD the tab starts."
  (let ((deadline (+ (float-time) 10)) (run (gethash drgnx-review--current drgnx-review--runs)))
    (while (and (process-live-p (plist-get run :checking)) (< (float-time) deadline)) (accept-process-output nil 0.05))
    (accept-process-output nil 0.05)))

(defun drgnx-review-test--tab () (with-current-buffer "*drgnx review*" (buffer-string)))

(ert-deftest drgnx-review/parse-findings-and-verdict ()
  (let ((r (drgnx-review-parse drgnx-review-test--answer)))
    (should (eq (plist-get r :verdict) 'fail))
    (should (equal (mapcar (lambda (f) (list (plist-get f :severity) (plist-get f :path) (plist-get f :line))) (plist-get r :findings))
                   '(("critical" "src/a.el" 12) ("minor" "src/a.el" 3) ("minor" "src/b.el" 4))))
    (should (equal (plist-get (car (plist-get r :findings)) :text) "the loop never ends")))
  (should (eq (plist-get (drgnx-review-parse "fine\nVERDICT: pass") :verdict) 'pass))
  (should-not (plist-get (drgnx-review-parse "nothing to say") :verdict)))

(ert-deftest drgnx-review/the-prompt-goes-once-then-the-answer-is-read ()
  (drgnx-review-test--branch
    (drgnx-review-branch)
    (should (string-search "Reviewing" (drgnx-review-test--tab)))
    (drgnx-review--changed s)
    (drgnx-review--changed s)                               ; free again before its turn ran: no second prompt
    (should (= 1 (length delivered)))
    (should (string-search "git diff main...HEAD" (car delivered)))
    (should (string-search "FINDING: <path>:<line>" (car delivered)))
    (should (string-search "Reviewing" (drgnx-review-test--tab)))
    (drgnx-review-test--answer s drgnx-review-test--answer)
    (let ((tab (drgnx-review-test--tab)))
      (should (string-search "feature vs main · 3 findings · fail" tab))
      (should (string-search "src/a.el:12" tab))
      (should (< (string-search "the loop never ends" tab) (string-search "a long name" tab))))))

(ert-deftest drgnx-review/the-review-policy-answers-permissions ()
  (drgnx-review-test--branch
    (drgnx-review-branch)
    (let ((opts (vector '(:optionId "o1" :kind "allow_once") '(:optionId "o2" :kind "reject_once"))))
      (should (equal (drgnx-review--request s "session/request_permission"
                                            (list :toolCall (list :kind "read" :title "Read a.el" :locations (vector (list :path (concat repo "src/a.el"))))
                                                  :options opts)
                                            7)
                     '(:result (:outcome (:outcome "selected" :optionId "o1")))))
      (should-not (drgnx-review--request s "session/request_permission"
                                         (list :toolCall (list :kind "edit" :title "Edit a.el" :locations (vector (list :path (concat repo "src/a.el")))) :options opts) 8))
      (should (equal (drgnx-review--request s "fs/write_text_file" (list :path (concat repo "x") :content "x") 9)
                     '(:error (:code -32000 :message "a review only reads"))))
      (should-not (drgnx-review--request (drgnx-agents--make :id "other") "fs/write_text_file" (list :path "/x" :content "x") 10)))))

(ert-deftest drgnx-review/edge-cases ()
  (drgnx-review-test--branch
    (drgnx-git-test repo "checkout" "-q" "main")
    (should (string-match-p "Nothing to review against main" (cadr (should-error (drgnx-review-branch) :type 'user-error))))
    (drgnx-git-test repo "checkout" "-q" "feature")
    (drgnx-git-test repo "branch" "-q" "-m" "main" "trunk")
    (should (string-match-p "No base branch" (cadr (should-error (drgnx-review-branch) :type 'user-error))))
    (drgnx-git-test repo "branch" "-q" "-m" "trunk" "main")
    ;; an answer with neither findings nor a verdict
    (drgnx-review-branch)
    (drgnx-review--changed s)
    (drgnx-review-test--answer s "Looks fine to me.")
    (should (string-search "no verdict" (drgnx-review-test--tab)))
    ;; HEAD moved since the review began
    (drgnx-git-test-write repo "c.el" "c\n")
    (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "c")
    (drgnx-review-refresh)
    (drgnx-review-test--wait-head)
    (should (string-search "HEAD has moved" (drgnx-review-test--tab)))))

(ert-deftest drgnx-review/ret-opens-the-finding ()
  (drgnx-review-test--branch
    (drgnx-review-branch)
    (drgnx-review--changed s)
    (drgnx-review-test--answer s drgnx-review-test--answer)
    (with-current-buffer "*drgnx review*"
      (goto-char (point-min))
      (search-forward "src/a.el:12")
      (drgnx-review-visit)
      (should (equal (buffer-file-name) (expand-file-name "src/a.el" repo)))
      (should (= (line-number-at-pos) 12)))))

;; review fixes (M11b final review)
(ert-deftest drgnx-review/findings-in-model-formatting ()
  ;; I5: list markers, bold, backticks, capitals, line ranges
  (let ((r (drgnx-review-parse "- FINDING: a.el:3: important: one\n1. FINDING: b.el:4: minor: two\n**FINDING:** c.el:5: Critical: three\n`FINDING: d.el:6-9: minor: four`\n**VERDICT: fail**")))
    (should (equal (mapcar (lambda (f) (list (plist-get f :path) (plist-get f :line) (plist-get f :severity))) (plist-get r :findings))
                   '(("c.el" 5 "critical") ("a.el" 3 "important") ("b.el" 4 "minor") ("d.el" 6 "minor"))))
    (should (equal (plist-get (nth 3 (plist-get r :findings)) :text) "four"))
    (should (eq (plist-get r :verdict) 'fail))))

(ert-deftest drgnx-review/a-reviewer-that-stops-says-so ()
  ;; I4: the agent exited (or was stopped) before answering: the tab says so instead of Reviewing… forever
  (drgnx-review-test--branch
    (drgnx-review-branch)
    (drgnx-review--changed s)
    (setf (drgnx-agent-session-status s) 'exited)
    (drgnx-review--changed s)
    (should (string-search "the reviewer stopped" (drgnx-review-test--tab)))))

(ert-deftest drgnx-review/the-reviewer-goes-once-it-has-answered ()
  ;; I6: no idle agent left behind per review
  (drgnx-review-test--branch
    (let ((killed nil))
      (cl-letf (((symbol-function 'drgnx-agents-kill) (lambda (x) (push x killed))))
        (drgnx-review-branch)
        (drgnx-review--changed s)
        (drgnx-review-test--answer s drgnx-review-test--answer)
        (should (equal killed (list s)))))))

(ert-deftest drgnx-review/revert-buffer-redraws ()
  ;; M11b-4: g (revert-buffer) in the tab draws it again
  (drgnx-review-test--branch
    (drgnx-review-branch)
    (drgnx-review--changed s)
    (drgnx-review-test--answer s drgnx-review-test--answer)
    (with-current-buffer "*drgnx review*"
      (let ((inhibit-read-only t)) (erase-buffer))
      (should (string-empty-p (buffer-string)))
      (revert-buffer nil t)
      (should (string-search "feature vs main · 3 findings · fail" (buffer-string))))))

(ert-deftest drgnx-review/show-diff-uses-reviewed-sha ()
  ;; M11b-5: the branch diff is the one the reviewer saw, not wherever HEAD is now
  (drgnx-review-test--branch
    (drgnx-review-branch)
    (drgnx-review--changed s)
    (drgnx-review-test--answer s drgnx-review-test--answer)
    (let ((reviewed (drgnx-git-test repo "rev-parse" "HEAD")) (source nil))
      (drgnx-git-test-write repo "c.el" "c\n")
      (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "c")
      (cl-letf (((symbol-function 'drgnx-diff-show) (lambda (src &rest _) (setq source src))))
        (with-current-buffer "*drgnx review*" (drgnx-review-show-diff)))
      (should (equal source (list 'range "main" (string-trim reviewed)))))))

(ert-deftest drgnx-review/summary-never-runs-git-itself ()
  ;; M11b-5: drawing the tab starts no synchronous git
  (drgnx-review-test--branch
    (drgnx-review-branch)
    (drgnx-review--changed s)
    (drgnx-review-test--answer s drgnx-review-test--answer)
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) (error "synchronous process"))))
      (drgnx-review-refresh))
    (drgnx-review-test--wait-head)
    (should-not (string-search "HEAD has moved" (drgnx-review-test--tab)))))

(ert-deftest drgnx-review/visit-refuses-outside-root ()
  ;; M11b-6: a finding's path is the model's: it never opens a file outside the repository
  (drgnx-review-test--branch
    (drgnx-review-branch)
    (drgnx-review--changed s)
    (let ((outside (make-temp-file "drgnx-outside")))
      (unwind-protect
          (progn
            (drgnx-review-test--answer
             s (format "FINDING: ../%s:1: minor: up\nFINDING: %s:1: minor: absolute\nVERDICT: fail"
                       (file-relative-name outside (concat (directory-file-name repo) "/..")) outside))
            (with-current-buffer "*drgnx review*"
              (goto-char (point-min))
              (dolist (what '("up" "absolute"))
                (goto-char (point-min))
                (search-forward what)
                (should (string-match-p "outside" (cadr (should-error (drgnx-review-visit) :type 'user-error))))
                (should-not (find-buffer-visiting outside)))))
        (delete-file outside)))))

;;; mod-review-test.el ends here
