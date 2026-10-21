;;; mod-prs-test.el --- batch tests: the Pull Requests tab — forge's PRs, stacks, Changes in the diff view -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/measure-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-diff" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-prs" drgnx-dir) nil t)

(defun drgnx-prs-test--pr (n base head &optional state)
  (list :number n :title (format "PR %d" n) :author "ada" :state (or state 'open) :base base :head head :updated "2026-10-17T10:00:00Z"))

(defmacro drgnx-prs-test--with (prs &rest body)
  "BODY in a repo whose forge PRs are PRS (`drgnx-prs--pullreqs' stubbed)."
  (declare (indent 1))
  `(drgnx-notice-test-with-model
     (drgnx-notice-define-source 'prs :title "Pull requests" :command 'prs-fetch)
     (drgnx-git-test-with-repo
       (drgnx-git-test-write repo "a" "a\n")
       (drgnx-git-test repo "add" "-A") (drgnx-git-test repo "commit" "-q" "-m" "a")
       (let ((default-directory repo))
         (cl-letf (((symbol-function 'drgnx-prs--pullreqs) (lambda (_root) ,prs)))
           (unwind-protect (progn ,@body)
             (when (get-buffer "*drgnx pull requests*") (kill-buffer "*drgnx pull requests*"))))))))

(defun drgnx-prs-test--rows ()
  (with-current-buffer "*drgnx pull requests*"
    (mapcar (lambda (e) (aref (cadr e) 1)) tabulated-list-entries)))

(ert-deftest drgnx-prs/stacks-nest-under-their-base ()
  (let ((s (drgnx-prs-stacks (list (drgnx-prs-test--pr 3 "main" "a") (drgnx-prs-test--pr 5 "a" "b")
                                   (drgnx-prs-test--pr 7 "b" "c") (drgnx-prs-test--pr 4 "main" "d")))))
    (should (equal (mapcar (lambda (e) (cons (plist-get (car e) :number) (cdr e))) s) '((4 . 0) (3 . 0) (5 . 1) (7 . 2))))))

(ert-deftest drgnx-prs/stacks-survive-cycles ()
  (let ((s (drgnx-prs-stacks (list (drgnx-prs-test--pr 1 "y" "x") (drgnx-prs-test--pr 2 "x" "y") (drgnx-prs-test--pr 9 "main" "main")))))
    (should (equal (sort (mapcar (lambda (e) (plist-get (car e) :number)) s) #'<) '(1 2 9)))))

(ert-deftest drgnx-prs/the-tab-lists-open-prs ()
  (drgnx-prs-test--with (list (drgnx-prs-test--pr 3 "main" "a") (drgnx-prs-test--pr 5 "a" "b" 'draft)
                              (drgnx-prs-test--pr 6 "main" "e") (drgnx-prs-test--pr 2 "main" "f" 'merged))
    (drgnx-prs-view)
    (let ((rows (drgnx-prs-test--rows)))
      (should (= 3 (length rows)))
      (should (member "└ PR 5" rows)))
    (with-current-buffer "*drgnx pull requests*" (drgnx-prs-toggle-closed))
    (should (= 4 (length (drgnx-prs-test--rows))))
    (with-current-buffer "*drgnx pull requests*"
      (should (seq-some (lambda (e) (equal (aref (cadr e) 3) "draft")) tabulated-list-entries)))))

(ert-deftest drgnx-prs/no-forge-no-error ()
  (drgnx-prs-test--with :untracked
    (drgnx-prs-view)
    (should (string-search "No pull requests here yet" (with-current-buffer "*drgnx pull requests*" (buffer-string)))))
  ;; the real reader without forge: untracked, never an error
  (unless (featurep 'forge)
    (drgnx-git-test-with-repo
      (should (eq (drgnx-prs--pullreqs repo) :untracked)))))

(ert-deftest drgnx-prs/changes-fetch-then-diff ()
  (drgnx-prs-test--with (list (drgnx-prs-test--pr 5 "feature-a" "b"))
    (let ((cmd nil) (sentinel nil) (shown nil))
      (cl-letf (((symbol-function 'make-process) (lambda (&rest args) (setq cmd (plist-get args :command) sentinel (plist-get args :sentinel)) 'fake))
                ((symbol-function 'drgnx-diff-show) (lambda (&rest args) (setq shown args))))
        (drgnx-prs-view)
        (with-current-buffer "*drgnx pull requests*"
          (goto-char (point-min))
          (search-forward "PR 5")
          (drgnx-prs-changes))
        (should (equal cmd '("git" "fetch" "origin" "+refs/pull/5/head:refs/pullreqs/5")))
        (should-not shown)                                   ; not before the fetch ends
        (funcall sentinel 'fake "finished\n")
        (should (equal (car shown) '(range "origin/feature-a" "refs/pullreqs/5")))
        (setq shown nil)
        (funcall sentinel 'fake "exited abnormally with code 128\n")
        (should-not shown)))))

(ert-deftest drgnx-prs/adapter-reads-forge ()
  (skip-unless (require 'forge nil t))                     ; DEFERRED: a live forge check
  (drgnx-git-test-with-repo
    (should (memq (drgnx-prs--pullreqs repo) '(:untracked nil)))))

;; review fixes (M11b final review)
(ert-deftest drgnx-prs/a-fork-s-main-is-no-stack ()
  ;; I3: #10 comes from a fork's main; PRs into main stay at the top
  (let ((s (drgnx-prs-stacks (list (append (drgnx-prs-test--pr 10 "main" "main") '(:cross t))
                                   (drgnx-prs-test--pr 9 "main" "x") (drgnx-prs-test--pr 11 "main" "y") (drgnx-prs-test--pr 12 "main" "z")))))
    (should (equal (mapcar #'cdr s) '(0 0 0 0)))))

(ert-deftest drgnx-prs/show-closed-only-in-its-tab ()
  ;; C1: run from another buffer it acts on the tab, never on that buffer
  (drgnx-prs-test--with (list (drgnx-prs-test--pr 3 "main" "a") (drgnx-prs-test--pr 2 "main" "f" 'merged))
    (drgnx-prs-view)
    (with-temp-buffer
      (insert "(keep me)")
      (drgnx-prs-toggle-closed)
      (should (equal (buffer-string) "(keep me)")))
    (should (= 2 (length (drgnx-prs-test--rows)))))
  (when (get-buffer "*drgnx pull requests*") (kill-buffer "*drgnx pull requests*"))
  (with-temp-buffer (insert "x") (should-error (drgnx-prs-toggle-closed) :type 'user-error) (should (equal (buffer-string) "x"))))

(ert-deftest drgnx-prs/fetch-sets-no-prompt-env ()
  ;; M11b-7: git never asks for a password in the background; its complaint reaches the user
  (drgnx-prs-test--with (list (drgnx-prs-test--pr 5 "feature-a" "b"))
    (let ((env nil) (err nil) (sentinel nil) (messages nil))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq env process-environment err (plist-get args :stderr) sentinel (plist-get args :sentinel))
                   'fake))
                ((symbol-function 'message) (lambda (fmt &rest a) (push (apply #'format fmt a) messages))))
        (drgnx-prs-view)
        (with-current-buffer "*drgnx pull requests*" (goto-char (point-min)) (search-forward "PR 5") (drgnx-prs-changes))
        (should (member "GIT_TERMINAL_PROMPT=0" env))
        (should (bufferp err))
        (with-current-buffer err (insert "fatal: could not read Username for 'https://example.org'\n"))
        (funcall sentinel 'fake "exited abnormally with code 128\n")
        (should-not (seq-some (lambda (m) (string-prefix-p "drgnx: fetching pull request #5 failed" m)) messages))
        (should (seq-some (lambda (n) (string-search "could not read Username" (plist-get n :text)))
                          (drgnx-notices :source 'prs)))
        (should-not (buffer-live-p err))))))

(ert-deftest drgnx-prs/a-fetch-failure-is-a-condition-and-the-placeholder-says-why ()
  ;; M11b-8 / A-32: a forge whose classes differ from what we read is a warn condition, and the tab says why
  (let ((messages nil))
    (drgnx-prs-test--with (error "Invalid slot name: draft-p")
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest a) (push (apply #'format fmt a) messages))))
        (drgnx-prs-view))
      (let ((text (with-current-buffer "*drgnx pull requests*" (buffer-string)))
            (n (car (drgnx-notices :source 'prs))))
        (should (string-search "the forge did not answer: Invalid slot name" text))
        (should-not (string-search "Fetch (forge) gets them" text))
        (should (eq (plist-get n :severity) 'warn))
        (should (eq (plist-get n :life) 'condition))
        (should (equal (plist-get n :id) 'fetch))
        (should (eq (plist-get n :command) 'prs-fetch))
        (should (string-prefix-p "Pull requests: the forge did not answer: Invalid slot name" (plist-get n :text))))
      (should-not messages))))

(ert-deftest drgnx-prs/a-good-read-clears-the-condition ()
  (drgnx-prs-test--with (error "Invalid slot name: draft-p")
    (drgnx-prs-view)
    (should (drgnx-notices :source 'prs))
    (cl-letf (((symbol-function 'drgnx-prs--pullreqs) (lambda (_root) nil)))
      (drgnx-prs-view))
    (should-not (drgnx-notices :source 'prs))
    (should (string-search "Fetch (forge) gets them" (with-current-buffer "*drgnx pull requests*" (buffer-string))))))

(defun drgnx-prs-test--stacks-reference (prs)
  "The quadratic first version of `drgnx-prs-stacks', kept to compare the order against."
  (let ((seen (make-hash-table)) (out nil)
        (newest (lambda (l) (sort (copy-sequence l) (lambda (a b) (> (plist-get a :number) (plist-get b :number)))))))
    (cl-labels ((children (p) (and (not (plist-get p :cross))
                                   (seq-filter (lambda (q) (and (not (eq q p)) (equal (plist-get q :base) (plist-get p :head)))) prs)))
                (walk (p depth)
                  (unless (gethash (plist-get p :number) seen)
                    (puthash (plist-get p :number) t seen)
                    (push (cons p depth) out)
                    (dolist (c (funcall newest (children p))) (walk c (1+ depth))))))
      (dolist (r (funcall newest (seq-remove (lambda (p) (seq-some (lambda (q) (and (not (eq q p)) (not (plist-get q :cross)) (equal (plist-get p :base) (plist-get q :head))))
                                                                   prs))
                                             prs)))
        (walk r 0))
      (dolist (p (funcall newest prs)) (walk p 0)))
    (nreverse out)))

(ert-deftest drgnx-prs/stacks-same-order ()
  ;; M11b-9: hashing the heads changes the cost, not the order (cycles, forks, shared heads and bases included)
  (let ((names ["main" "a" "b" "c" "d" "e" "f" "g"]) (state 7))
    (dotimes (_ 40)
      (let ((prs (cl-loop for n from 1 to 30
                          collect (progn (setq state (mod (+ (* state 1103515245) 12345) 2147483648))
                                         (let ((b (aref names (mod (ash state -8) 8))) (h (aref names (mod (ash state -14) 8))))
                                           (append (drgnx-prs-test--pr n b h) (and (zerop (mod (ash state -20) 5)) '(:cross t))))))))
        (should (equal (mapcar (lambda (e) (cons (plist-get (car e) :number) (cdr e))) (drgnx-prs-stacks prs))
                       (mapcar (lambda (e) (cons (plist-get (car e) :number) (cdr e))) (drgnx-prs-test--stacks-reference prs))))))))

(ert-deftest drgnx-prs/2000-prs-stack-in-linear-allocation ()
  ;; Four times the PRs allocate about four times as much (a scan per PR, sixteen); the wall-clock form (0.25 s)
  ;; missed under load.
  (drgnx-test-compile "drgnx-prs-")
  (cl-flet ((prs (count) (cl-loop for n from 1 to count
                                  collect (drgnx-prs-test--pr n (if (zerop (mod n 3)) (format "h%d" (1- n)) "main") (format "h%d" n)))))
    (should (= 2000 (length (drgnx-prs-stacks (prs 2000)))))
    (let* ((small (prs 500)) (big (prs 2000))
           (a (drgnx-test-alloc (drgnx-prs-stacks small))) (b (drgnx-test-alloc (drgnx-prs-stacks big))))
      (should (<= b (* 5 a))))))

(ert-deftest drgnx-prs/only-closed-message ()
  ;; M11b-10: only merged and closed pull requests: the tab says how many are hidden, not that there are none
  (drgnx-prs-test--with (list (drgnx-prs-test--pr 2 "main" "f" 'merged) (drgnx-prs-test--pr 3 "main" "g" 'closed))
    (drgnx-prs-view)
    (let ((text (with-current-buffer "*drgnx pull requests*" (buffer-string))))
      (should (string-search "No open pull requests — 2 merged or closed" text))
      (should (string-search "Pull Requests: Show Closed" text))
      (should-not (string-search "No pull requests here yet" text)))
    (with-current-buffer "*drgnx pull requests*" (drgnx-prs-toggle-closed))
    (should (= 2 (length (drgnx-prs-test--rows))))
    (should-not (string-search "No open pull requests" (with-current-buffer "*drgnx pull requests*" (buffer-string)))))
  (drgnx-prs-test--with nil
    (drgnx-prs-view)
    (should (string-search "No pull requests here yet" (with-current-buffer "*drgnx pull requests*" (buffer-string))))))

(ert-deftest drgnx-prs/turning-it-off-closes-the-tab-and-takes-the-hook ()
  ;; forge is not installed everywhere: the library is faked, so the module sets up and tears down as shipped.
  (let ((locate (symbol-function 'locate-library)) buf)
    (cl-letf (((symbol-function 'locate-library)
               (lambda (name &rest args) (if (equal name "forge") "forge.el" (apply locate name args)))))
      (drgnx-test-with-modules '(tools/prs) :strict t
                               (should (memq 'drgnx-prs--commit-setup (and (boundp 'git-commit-setup-hook) (symbol-value 'git-commit-setup-hook))))
                               (should (drgnx-commands-get 'prs-view))
                               (setq buf (with-current-buffer (generate-new-buffer "*drgnx pull requests*") (drgnx-prs-mode) (current-buffer)))))
    (should-not (buffer-live-p buf))
    (should-not (memq 'drgnx-prs--commit-setup (and (boundp 'git-commit-setup-hook) (symbol-value 'git-commit-setup-hook))))))

;;; mod-prs-test.el ends here
