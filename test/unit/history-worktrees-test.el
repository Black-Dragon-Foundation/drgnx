;;; history-worktrees-test.el --- batch tests: the edit history across git worktrees, on the real hub -*- lexical-binding: t -*-
;; The hub runs as its own process (Ratatoskr from DRGNX_RATATOSKR_BIN, a test-hooks build, with `ratatoskr-mock'
;; beside it) inside the delivery gate.  The user's checkout is tracked through the hub's editor methods (no Nidhogg
;; hook is needed); two worker agents, each in a git worktree of the same project, write the same file through their own
;; `fs/write_text_file'; real git makes and removes the worktrees.  What the hub holds is read through its own answers
;; (`history/blame', `history/compare') and the report its sweep leaves for the doctor, never through a deadline.
;; test-class: cond
;; test-pattern: gated
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)  ; ask and settle against the gated hub (it loads
                                        ; the hub client test's Ratatoskr helpers)

(defconst drgnx-history-worktrees-test--base "one\ntwo\nthree\n" "a.txt as the project commits it.")

(defun drgnx-history-worktrees-test--git (dir &rest args)
  "git ARGS in DIR; it must succeed."
  (let ((default-directory dir)
        (process-environment (append (list "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null") process-environment)))
    (should (zerop (apply #'process-file "git" nil nil nil
                          "-c" "user.name=t" "-c" "user.email=t@example.invalid" "-c" "commit.gpgsign=false" args)))))

(defun drgnx-history-worktrees-test--project ()
  "The user's checkout under this test's HOME, a.txt committed, and its two worktrees `wt1' and `wt2' beside it.
Their directories: (MAIN WT1 WT2)."
  (let* ((home (file-name-as-directory (getenv "HOME")))
         (main (file-name-as-directory (expand-file-name "proj" home)))
         (wt1 (file-name-as-directory (expand-file-name "wt1" home)))
         (wt2 (file-name-as-directory (expand-file-name "wt2" home))))
    (make-directory main t)
    (with-temp-file (concat main "a.txt") (insert drgnx-history-worktrees-test--base))
    (drgnx-history-worktrees-test--git main "init" "-q" "-b" "main")
    (drgnx-history-worktrees-test--git main "add" "a.txt")
    (drgnx-history-worktrees-test--git main "commit" "-q" "-m" "seed")
    (drgnx-history-worktrees-test--git main "worktree" "add" "-q" "-b" "agent1" (directory-file-name wt1))
    (drgnx-history-worktrees-test--git main "worktree" "add" "-q" "-b" "agent2" (directory-file-name wt2))
    (list main wt1 wt2)))

(defmacro drgnx-history-worktrees-test--with (&rest body)
  "BODY inside the gate with a hub that knows the profile \"wt-mock\" (`ratatoskr-mock acp'), the project made
\(MAIN, WT1, WT2); skipped without the hub."
  (declare (indent 0))
  `(drgnx-agents-mirror-test--with '()
     (drgnx-test-write-settings
      (concat root "config/settings.el")
      'drgnx-agents-profiles
      (list (list "wt-mock" :provider 'claude
                  :command (list (expand-file-name "ratatoskr-mock" (file-name-directory (drgnx-hub-client-test--bin)))
                                 "acp" "--as" "claude"))))
     (cl-destructuring-bind (main wt1 wt2) (drgnx-history-worktrees-test--project)
       (ignore main wt1 wt2)
       ,@body)))

(defun drgnx-history-worktrees-test--ask (method &rest params)
  "The hub's answer to METHOD with PARAMS (a plist)."
  (drgnx-agents-mirror-test--ask method params))

(defun drgnx-history-worktrees-test--read (file)
  "FILE's text, or the empty string."
  (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))

(defun drgnx-history-worktrees-test--agent-writes (dir text)
  "A worker in DIR writes TEXT over a.txt through the hub; the session's id once the file holds TEXT."
  (let ((id (plist-get (drgnx-history-worktrees-test--ask "agents/start" :profile "wt-mock" :role "worker"
                                                          :cwd (directory-file-name dir))
                       :id)))
    (drgnx-history-worktrees-test--ask "agents/send" :id id
                                       :text (concat "fs:write a.txt " (string-replace "\n" "\\n" text)))
    (drgnx-agents-mirror-test--settle
     (lambda () (equal (drgnx-history-worktrees-test--read (concat dir "a.txt")) text))
     (format "the worker in %s wrote a.txt" (file-name-nondirectory (directory-file-name dir))))
    id))

(defun drgnx-history-worktrees-test--authors (answer)
  "The sessions the spans of a blame ANSWER name, sorted."
  (sort (delete-dups (mapcar (lambda (s) (plist-get (plist-get s :author) :session))
                             (append (plist-get answer :spans) nil)))
        #'string<))

(defun drgnx-history-worktrees-test--blame (dir)
  "Who wrote a.txt in the worktree DIR."
  (drgnx-history-worktrees-test--ask "history/blame" :path "a.txt" :worktree_root (directory-file-name dir)
                                     :start 0 :end 1000))

(ert-deftest drgnx-history/three-worktrees-keep-their-own-authors ()
  ;; B: the user's unsaved edit in the checkout, and two workers writing the same file in their worktrees: each tree's
  ;; history names its own writer, the user's text is nobody's deletion, and one worker's text is not the other's
  (drgnx-history-worktrees-test--with
    (let* ((typed (concat "USER " drgnx-history-worktrees-test--base))
           (r (drgnx-history-worktrees-test--ask "history/register" :path "a.txt"
                                                 :worktree_root (directory-file-name main) :buffer_id "main-a")))
      (should (eq (plist-get r :tracked) t))
      (should (equal (drgnx-history-worktrees-test--ask
                      "history/batch" :buffer_id "main-a" :region_hash (secure-hash 'sha256 typed) :version 1
                      :changes (vector (list :start 0 :old_len 0 :inserted "USER " :origin "user")))
                     '(:ok t)))
      (let* ((one (concat "ONE\n" (substring drgnx-history-worktrees-test--base 4)))
             (two (concat drgnx-history-worktrees-test--base "TWO\n"))
             (s1 (drgnx-history-worktrees-test--agent-writes wt1 one))
             (s2 (drgnx-history-worktrees-test--agent-writes wt2 two)))
        ;; each worktree's text is its writer's, and only its writer's
        (should (equal (drgnx-history-worktrees-test--authors (drgnx-history-worktrees-test--blame wt1)) (list s1)))
        (should (equal (drgnx-history-worktrees-test--authors (drgnx-history-worktrees-test--blame wt2)) (list s2)))
        ;; the checkout's unsaved typing is the user's: no agent wrote any of it, and the files of the others are untouched
        (should-not (drgnx-history-worktrees-test--authors (drgnx-history-worktrees-test--blame main)))
        (should (equal (drgnx-history-worktrees-test--read (concat main "a.txt")) drgnx-history-worktrees-test--base))
        (should (equal (drgnx-history-worktrees-test--read (concat wt1 "a.txt")) one))
        (should (equal (drgnx-history-worktrees-test--read (concat wt2 "a.txt")) two))))))

(ert-deftest drgnx-history/a-removed-worktree-is-frozen-and-still-comparable ()
  ;; B: git removes both worktrees; the hub's next sweep (its clock moved) freezes their branches, which the report for
  ;; the doctor names, and compare still says who wrote what in each
  (drgnx-history-worktrees-test--with
    (let* ((s1 (drgnx-history-worktrees-test--agent-writes wt1 "one\ntwo\nthree\nFROM ONE\n"))
           (s2 (drgnx-history-worktrees-test--agent-writes wt2 "one\ntwo\nthree\nFROM TWO\n")))
      (drgnx-history-worktrees-test--git main "worktree" "remove" "--force" (directory-file-name wt1))
      (drgnx-history-worktrees-test--git main "worktree" "remove" "--force" (directory-file-name wt2))
      (let (frozen)
        ;; past the sweep's first look (a minute after the history opens) and its hourly one
        (drgnx-test-hub-advance (* 3601 1000))
        (drgnx-agents-mirror-test--settle
         (lambda ()
           (let ((file (car (directory-files-recursively root "size-report\\.json\\'"))))
             (setq frozen
                   (and file
                        (let ((report (json-parse-string (drgnx-history-worktrees-test--read file)
                                                         :object-type 'plist :array-type 'list)))
                          (cl-loop for pin in (plist-get report :pins)
                                   when (equal (plist-get pin :kind) "frozen") collect (plist-get pin :name)))))
             (= (length frozen) 2)))
         "both worktree branches frozen in the sweep's report")
        (let ((cmp (drgnx-history-worktrees-test--ask "history/compare" :a (car frozen) :b (cadr frozen))))
          (should (plist-get cmp :files))
          (let ((who (delete-dups
                      (cl-loop for f in (append (plist-get cmp :files) nil)
                               append (cl-loop for h in (append (plist-get f :hunks) nil)
                                               collect (plist-get (plist-get h :author) :session))))))
            (should (cl-subsetp who (list s1 s2) :test #'equal))
            (should who)))))))

(provide 'history-worktrees-test)
;;; history-worktrees-test.el ends here
