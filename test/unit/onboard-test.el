;;; onboard-test.el --- batch tests: onboarding steps, projects onto the board -*- lexical-binding: t -*-
;; Fixture git repos, boards and configs live in temp dirs: never ~/workspace, ~/org or ~/.config.
(require 'ert)
(require 'drgnx-onboard)
(require 'drgnx-projects)
(require 'drgnx-macos)

(defmacro drgnx-onboard-test--with (root &rest body)
  "BODY with ROOT a temp dir holding config, state, data and org dirs."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-onboard" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" ,root "config")
                                             (concat "XDG_STATE_HOME=" ,root "state")
                                             (concat "DRGNX_DATA_DIR=" ,root "data"))
                                       process-environment))
          ;; the board path itself — never through `org-directory' (not special unless org is loaded)
          (drgnx-projects-board-file (concat ,root "org/board.org"))
          (drgnx-projects-gryphn-file (concat ,root "gryphn/projects.tsv"))
          (drgnx-modules--state nil))
     (make-directory (concat ,root "config") t)
     (unwind-protect (progn ,@body) (delete-directory ,root t))))

(defun drgnx-onboard-test--repo (dir &rest files)
  "A git repo at DIR with FILES: (NAME . TEXT)…"
  (make-directory dir t)
  (let ((default-directory (file-name-as-directory dir)))
    (call-process "git" nil nil nil "init" "-q")
    (call-process "git" nil nil nil "remote" "add" "origin" (concat "https://example.invalid/" (file-name-nondirectory (directory-file-name dir)) ".git"))
    (pcase-dolist (`(,name . ,text) files)
      (make-directory (file-name-directory (expand-file-name name)) t)
      (write-region text nil (expand-file-name name) nil 'silent)))
  (file-name-as-directory dir))

(defun drgnx-onboard-test--board () (with-temp-buffer (insert-file-contents (drgnx-projects-board-file)) (buffer-string)))

(defun drgnx-onboard-test--read (file) (with-temp-buffer (insert-file-contents file) (read (current-buffer))))

;;;; Task 1: steps, progress, runner

(ert-deftest drgnx-onboard/steps-run-in-order-and-record-progress ()
  (drgnx-onboard-test--with root
    (let ((drgnx-onboard--steps nil) (ran nil))
      (drgnx-onboard-define-step 'b :title "B" :order 20 :run (lambda (_) (push 'b ran) '(ok "b done")))
      (drgnx-onboard-define-step 'a :title "A" :order 10 :run (lambda (_) (push 'a ran) '(ok "a done")))
      (drgnx-onboard-define-step 'c :title "C" :order 30 :run (lambda (_) (push 'c ran) (error "boom")))
      (should (equal (drgnx-onboard-steps) '(a b c)))
      (let ((r (drgnx-onboard-run :non-interactive t)))
        (should (equal (reverse ran) '(a b c)))
        (should (equal (mapcar #'cadr r) '(ok ok fail)))
        (should (string-match-p "boom" (nth 2 (nth 2 r)))))                ; an error is a failed step, not fatal
      (should (eq (plist-get (alist-get 'a (drgnx-onboard-state)) :status) 'ok))
      (should (eq (plist-get (alist-get 'c (drgnx-onboard-state)) :status) 'fail))
      ;; resume: only what is not done yet
      (setq ran nil)
      (drgnx-onboard-run :non-interactive t :resume t)
      (should (equal ran '(c))))))

(ert-deftest drgnx-onboard/a-check-follows-every-step ()
  (drgnx-onboard-test--with root
    (let ((drgnx-onboard--steps nil))
      (drgnx-onboard-define-step 'a :title "A" :order 1 :run (lambda (_) '(ok "ran"))
                                 :check (lambda (_) '(warn "but the doctor says no")))
      (should (equal (cdr (car (drgnx-onboard-run :non-interactive t))) '(warn "but the doctor says no"))))))

(ert-deftest drgnx-onboard/non-interactive-never-asks ()
  (drgnx-onboard-test--with root
    (let ((drgnx-onboard--steps nil))
      (drgnx-onboard-define-step 'asks :title "Asks" :order 1
                                 :run (lambda (_) (list 'ok (read-string "Name? "))))
      (should (eq (cadr (car (drgnx-onboard-run :non-interactive t))) 'fail)))))

;;;; Task 2: environment, look and keys, presets

(ert-deftest drgnx-onboard/presets-choose-the-extra-modules ()
  (drgnx-onboard-test--with root
    (drgnx-modules-write-state '(:version 1 :disabled (ui/look) :theme tango))
    (drgnx-onboard-apply-preset 'minimal)
    (let ((s (drgnx-modules-read-state)))
      (should (memq 'ui/look (plist-get s :disabled)))             ; the user's own choice stays
      (should (memq 'extra/magit (plist-get s :disabled)))
      (should (memq 'extra/llm (plist-get s :disabled)))
      (should (eq (plist-get s :theme) 'tango)))
    (drgnx-onboard-apply-preset 'ide)
    (should (equal (seq-filter (lambda (m) (string-prefix-p "extra/" (symbol-name m)))
                               (plist-get (drgnx-modules-read-state) :disabled))
                   '(extra/llm)))
    (drgnx-onboard-apply-preset 'full-ai)
    (should-not (seq-filter (lambda (m) (string-prefix-p "extra/" (symbol-name m)))
                            (plist-get (drgnx-modules-read-state) :disabled)))))

(ert-deftest drgnx-onboard/the-environment-says-what-is-missing-and-how-to-fix-it ()
  (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (and (member p '("git" "rg")) (concat "/usr/bin/" p)))))
    (let ((env (drgnx-onboard-environment)))
      (should (eq (plist-get (alist-get 'git env) :status) 'ok))
      (should (eq (plist-get (alist-get 'fd env) :status) 'missing))
      (should (plist-get (alist-get 'fd env) :fix)))))

(ert-deftest drgnx-onboard/macos-fixes-say-brew ()
  ;; Nothing is installed: every tool and the Command Line Tools are missing, and each fix is a Homebrew
  ;; or xcode-select command (the GPU row is ok on a Mac: Apple silicon shares its memory).
  (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos))
            ((symbol-function 'executable-find) (lambda (&rest _) nil))
            ((symbol-function 'call-process) (lambda (&rest _) 2))
            ((symbol-function 'drgnx-onboard--font-p) (lambda (_) nil)))
    (let ((env (drgnx-onboard-environment)))
      (should (alist-get 'xcode-clt env))
      (should (eq (plist-get (alist-get 'xcode-clt env) :status) 'missing))
      (should (eq (plist-get (alist-get 'gpu env) :status) 'ok))
      (should (string-search "shared memory" (plist-get (alist-get 'gpu env) :fix)))
      (dolist (id '(git ripgrep fd podman mise xcode-clt icon-font))
        (let ((fix (plist-get (alist-get id env) :fix)))
          (should (eq (plist-get (alist-get id env) :status) 'missing))
          (should (or (string-prefix-p "brew install" fix) (string-prefix-p "xcode-select" fix))))))
    (should (string-search "xcode-select --install" (plist-get (alist-get 'git (drgnx-onboard-environment)) :fix)))
    (should (string-search "podman machine init" (plist-get (alist-get 'podman (drgnx-onboard-environment)) :fix)))))

(ert-deftest drgnx-onboard/linux-has-no-command-line-tools-row-and-keeps-its-fixes ()
  (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux))
            ((symbol-function 'executable-find) (lambda (&rest _) nil))
            ((symbol-function 'drgnx-onboard--font-p) (lambda (_) t)))
    (let ((env (drgnx-onboard-environment)))
      (should-not (assq 'xcode-clt env))
      (should (eq (plist-get (alist-get 'gpu env) :status) 'missing))
      (should (string-search "dnf install ripgrep" (plist-get (alist-get 'ripgrep env) :fix))))))

(ert-deftest drgnx-onboard/no-fc-list-is-not-a-missing-font ()
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
            ((symbol-function 'executable-find) (lambda (p &rest _) (and (not (equal p "fc-list")) (concat "/usr/bin/" p)))))
    (should (eq (drgnx-onboard--font-p "Symbols Nerd Font") 'unknown))
    (let ((env (drgnx-onboard-environment)))
      (should (eq (plist-get (alist-get 'icon-font env) :status) 'unknown))
      (let ((r (drgnx-onboard--environment-step nil)))
        (should-not (eq (car r) 'warn))
        (should (string-search "could not check" (cadr r)))
        (should-not (string-search "missing" (cadr r)))))))

(ert-deftest drgnx-onboard/the-font-is-asked-of-emacs-in-a-graphical-session ()
  (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
            ((symbol-function 'font-family-list) (lambda (&rest _) '("Menlo" "Symbols Nerd Font"))))
    (should (drgnx-onboard--font-p "Symbols Nerd Font"))
    (should-not (drgnx-onboard--font-p "Nope Font"))))

(ert-deftest drgnx-onboard/look-and-keys-writes-the-choices ()
  (drgnx-onboard-test--with root
    (let ((r (drgnx-onboard-run :only '(look-and-keys) :non-interactive t
                                :options '(:preset ide :keys "Emacs" :theme modus-vivendi))))
      (should (eq (cadr (car r)) 'ok))
      (should (string-match-p "(emacs app editing window)"
                              (with-temp-buffer (insert-file-contents (expand-file-name "keys.eld" (drgnx-user-dir))) (buffer-string))))
      (should (eq (plist-get (drgnx-modules-read-state) :theme) 'modus-vivendi))
      (should (memq 'extra/llm (plist-get (drgnx-modules-read-state) :disabled))))))

;;;; Task 3: projects onto the board

(ert-deftest drgnx-projects/the-scan-finds-repos-and-stays-bounded ()
  (drgnx-onboard-test--with root
    (let ((ws (concat root "ws/")))
      (drgnx-onboard-test--repo (concat ws "alpha"))
      (drgnx-onboard-test--repo (concat ws "group/beta"))
      (drgnx-onboard-test--repo (concat ws "alpha/vendor/inner"))           ; inside a repo: not separate
      (drgnx-onboard-test--repo (concat ws "a/b/c/d/too-deep"))
      (make-directory (concat ws "node_modules/x/.git") t)
      (make-symbolic-link (concat ws "group") (concat ws "loop"))
      (should (equal (mapcar (lambda (d) (file-name-nondirectory (directory-file-name d))) (drgnx-projects-scan (list ws)))
                     '("alpha" "beta"))))))

(ert-deftest drgnx-projects/import-puts-projects-and-todos-on-the-board-once ()
  (drgnx-onboard-test--with root
    (let* ((alpha (drgnx-onboard-test--repo (concat root "ws/alpha")
                                            '("TODO.md" . "# Todo\n- [ ] write the parser\n- [x] done already\n")
                                            '("docs/plans/p.md" . "### Task 1\n- [ ] **Step 1: test first**\n")))
           (beta (drgnx-onboard-test--repo (concat root "ws/beta") '("TODO.org" . "* TODO ship it\n* DONE old\n"))))
      (let ((r (drgnx-projects-import (list alpha beta))))
        (should (equal (plist-get r :added) '("alpha" "beta")))
        (should (eql (plist-get r :todos) 3)))
      (let ((board (drgnx-onboard-test--board)))
        (should (string-match-p (concat ":PROJECT_ROOT: +" (regexp-quote (directory-file-name alpha))) board))
        (should (string-match-p ":REPO_URL: +https://example.invalid/alpha.git" board))
        (should (string-match-p "^\\*\\* TODO write the parser" board))
        (should (string-match-p "^\\*\\* TODO \\*\\*Step 1: test first\\*\\*" board))
        (should (string-match-p "^\\*\\* TODO ship it" board))
        (should-not (string-match-p "done already\\|old" board))
        ;; again: nothing changes
        (let ((r2 (drgnx-projects-import (list alpha beta))))
          (should-not (plist-get r2 :added))
          (should (eql (plist-get r2 :todos) 0)))
        (should (equal (drgnx-onboard-test--board) board)))
      (should (equal (mapcar (lambda (p) (plist-get p :name)) (plist-get (drgnx-projects-read) :projects)) '("alpha" "beta"))))))

(ert-deftest drgnx-projects/an-existing-board-only-gets-additions ()
  ;; gryphn's board, with its own projects and tasks, stays as it is around what is added.
  (drgnx-onboard-test--with root
    (let ((alpha (drgnx-onboard-test--repo (concat root "ws/alpha") '("TODO.md" . "- [ ] new task\n")))
          (existing "#+TITLE: Board\n\n* gryphn\n:PROPERTIES:\n:PROJECT_ROOT: /somewhere/gryphn\n:END:\n** NEXT a task :agent:\n   some notes\n"))
      (make-directory (file-name-directory (drgnx-projects-board-file)) t)
      (write-region existing nil (drgnx-projects-board-file) nil 'silent)
      (drgnx-projects-import (list alpha))
      (let ((board (drgnx-onboard-test--board)))
        (should (string-prefix-p existing board))
        (should (string-match-p "^\\* alpha" board)))
      ;; a project already on the board (same root) gets its new TODOs under its own heading
      ;; (a fresh machine: nothing imported before)
      (delete-file (expand-file-name "projects-imported.eld" (drgnx-state-dir)))
      (write-region (concat existing "* alpha\n:PROPERTIES:\n:PROJECT_ROOT: " (directory-file-name alpha) "\n:END:\n** TODO mine\n")
                    nil (drgnx-projects-board-file) nil 'silent)
      (let ((r (drgnx-projects-import (list alpha))))
        (should-not (plist-get r :added))
        (should (eql (plist-get r :todos) 1)))
      (should (string-match-p "\\*\\* TODO mine\n\\*\\* TODO new task" (drgnx-onboard-test--board))))))

(ert-deftest drgnx-projects/gryphn-projects-are-offered ()
  (drgnx-onboard-test--with root
    (make-directory (concat root "gryphn") t)
    (write-region (format "one\t%sws/one\nbad line\n" root) nil drgnx-projects-gryphn-file nil 'silent)
    (should (equal (drgnx-projects-gryphn-roots) (list (concat root "ws/one"))))))

(ert-deftest drgnx-projects/an-unsaved-board-is-never-overwritten ()
  (drgnx-onboard-test--with root
    (let ((alpha (drgnx-onboard-test--repo (concat root "ws/alpha"))))
      (make-directory (file-name-directory (drgnx-projects-board-file)) t)
      (write-region "* x\n" nil (drgnx-projects-board-file) nil 'silent)
      (let ((buf (find-file-noselect (drgnx-projects-board-file))))
        (unwind-protect
            (progn (with-current-buffer buf (goto-char (point-max)) (insert "unsaved\n"))
                   (should-error (drgnx-projects-import (list alpha)) :type 'user-error)
                   (should (equal (drgnx-onboard-test--board) "* x\n")))
          (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf))))))

;;;; Task 4: daemon, detection, finish; the whole flow

(ert-deftest drgnx-onboard/the-daemon-step-writes-files-and-installs-nothing ()
  (drgnx-onboard-test--with root
    (let ((r (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
               (car (drgnx-onboard-run :only '(daemon) :non-interactive t)))))
      (should (eq (cadr r) 'info))
      (should (file-exists-p (expand-file-name "systemd/drgnx.service" (drgnx-user-dir))))
      (should (file-exists-p (expand-file-name "applications/drgnx.desktop" (drgnx-user-dir))))
      (should (string-match-p "systemctl --user" (nth 2 r))))))

(defun drgnx-onboard-test--step-7 (platform keep install)
  "Run step 7 interactively on PLATFORM, answering KEEP to the keep-running question and INSTALL to the install
one.  Returns (RESULT PROMPTS PROGRAMS INSTALLED): the questions asked, the programs run, the app installs."
  (let (prompts programs installed (call-process (symbol-function 'call-process)))
    (cl-letf (((symbol-function 'drgnx-platform) (lambda () platform))
              ((symbol-function 'y-or-n-p)
               (lambda (p) (push p prompts) (if (string-match-p "\\`Keep drgnx running" p) keep install)))
              ((symbol-function 'call-process)
               (lambda (program &rest args) (push program programs) (apply call-process program args)))
              ((symbol-function 'drgnx-macos-install-app)
               (lambda (&optional _) (push t installed) (expand-file-name "drgnx.app" drgnx-macos-app-dir))))
      (list (car (drgnx-onboard-run :only '(daemon))) (nreverse prompts) programs installed))))

(ert-deftest drgnx-onboard/step-7-on-macos-asks-once-and-installs-the-app ()
  (drgnx-onboard-test--with root
    (let ((drgnx-macos-app-dir (concat root "Applications/")) (drgnx-keep-running t))
      (pcase-let ((`(,r ,prompts ,programs ,installed) (drgnx-onboard-test--step-7 'macos nil t)))
        (should (eq (cadr r) 'ok))
        (should (equal (car prompts)
                       "Keep drgnx running in the background when you close its last window? (recommended, like VS Code) "))
        (should (= 1 (seq-count (lambda (p) (string-match-p "\\`Keep drgnx running" p)) prompts)))
        (should (equal installed '(t)))
        (should-not (member "systemctl" programs))
        (should (equal (drgnx-onboard-test--read (drgnx-session-file)) '(:keep-running nil)))
        (should-not drgnx-keep-running)
        (should (string-search "drgnx quits when its last window closes" (nth 2 r)))
        (should (string-search "Preferences: Keep drgnx Running in the Background" (nth 2 r)))
        ;; no systemd unit, no desktop entry, nothing at login
        (should-not (file-exists-p (expand-file-name "systemd" (drgnx-user-dir))))
        (should-not (file-exists-p (expand-file-name "applications" (drgnx-user-dir)))))
      ;; the app is there: not asked again, not installed again
      (make-directory (concat root "Applications/drgnx.app") t)
      (pcase-let ((`(,r ,prompts ,_ ,installed) (drgnx-onboard-test--step-7 'macos t t)))
        (should (eq (cadr r) 'ok))
        (should (= 1 (length prompts)))
        (should-not installed)
        (should (equal (drgnx-onboard-test--read (drgnx-session-file)) '(:keep-running t)))))))

(ert-deftest drgnx-onboard/step-7-on-macos-without-interaction-installs-nothing ()
  (drgnx-onboard-test--with root
    (let ((drgnx-macos-app-dir (concat root "Applications/")) (drgnx-keep-running t) (installed nil))
      (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos))
                ((symbol-function 'drgnx-macos-install-app) (lambda (&rest _) (setq installed t))))
        (let ((r (car (drgnx-onboard-run :only '(daemon) :non-interactive t))))
          (should (eq (cadr r) 'info))
          (should (string-search "drgnx macos-app" (nth 2 r)))
          (should (string-search "keeps running in the background" (nth 2 r))))
        (should-not installed)
        (should-not (file-exists-p (concat root "Applications")))
        (should (equal (drgnx-onboard-test--read (drgnx-session-file)) '(:keep-running t)))
        ;; a choice made before stays
        (drgnx-session-set-keep-running nil)
        (drgnx-onboard-run :only '(daemon) :non-interactive t)
        (should (equal (drgnx-onboard-test--read (drgnx-session-file)) '(:keep-running nil)))))))

(ert-deftest drgnx-onboard/step-7-on-linux-is-unchanged-plus-the-question ()
  (drgnx-onboard-test--with root
    (let ((drgnx-keep-running t))
      (pcase-let ((`(,r ,prompts ,programs ,installed) (drgnx-onboard-test--step-7 'linux t nil)))
        (should (eq (cadr r) 'info))
        (should (string-match-p "\\`Keep drgnx running" (car prompts)))
        (should (string-match-p "\\`Install the drgnx service and desktop entry" (cadr prompts)))
        (should (= 2 (length prompts)))
        (should-not installed)
        (should-not (member "systemctl" programs))                       ; said no: nothing installed
        (should (file-exists-p (expand-file-name "systemd/drgnx.service" (drgnx-user-dir))))
        (should (file-exists-p (expand-file-name "applications/drgnx.desktop" (drgnx-user-dir))))
        (should (string-match-p "systemctl --user" (nth 2 r)))
        (should (string-search "drgnx keeps running in the background" (nth 2 r)))
        (should (equal (drgnx-onboard-test--read (drgnx-session-file)) '(:keep-running t)))))))

(ert-deftest drgnx-onboard/the-first-window-opens-the-welcome-once ()
  ;; The first graphical frame schedules the Welcome (a timer: never inside the hook); it opens when onboarding
  ;; never ran here, and marks it so it never opens by itself again.
  (drgnx-onboard-test--with root
    (let ((timers nil) (opened 0) (noninteractive nil)
          (process-environment (cons "DRGNX_UI_RUN" process-environment)))
      (cl-letf (((symbol-function 'run-with-idle-timer) (lambda (_secs _repeat fn &rest _) (push fn timers)))
                ((symbol-function 'drgnx-onboard-welcome) (lambda () (cl-incf opened))))
        (drgnx-onboard--on-first-window)
        (should (equal timers '(drgnx-onboard-maybe-welcome)))
        (should (= opened 0))                                            ; nothing inside the hook
        (funcall (car timers))
        (should (= opened 1))
        (should (file-exists-p (drgnx-onboard-state-file)))
        (should-not (drgnx-onboard-state))                               ; no step is marked done
        (setq timers nil)
        (drgnx-onboard--on-first-window)
        (should-not timers)
        (drgnx-onboard-maybe-welcome)
        (should (= opened 1))
        ;; never in batch, never in a harness session
        (delete-file (drgnx-onboard-state-file))
        (let ((noninteractive t)) (drgnx-onboard--on-first-window) (drgnx-onboard-maybe-welcome))
        (let ((process-environment (cons "DRGNX_UI_RUN=/tmp/x" process-environment)))
          (drgnx-onboard--on-first-window) (drgnx-onboard-maybe-welcome))
        (should-not timers)
        (should (= opened 1))))))

(ert-deftest drgnx-onboard/the-whole-flow-twice ()
  ;; The M6 exit, in batch: a fresh config onboarded non-interactively with fixture repos; the board
  ;; has the projects and their TODOs; the doctor has no failure; the second run changes nothing.
  (drgnx-onboard-test--with root
    (let ((ws (concat root "ws/")))
      (drgnx-onboard-test--repo (concat ws "alpha") '("TODO.md" . "- [ ] one\n- [ ] two\n"))
      (drgnx-onboard-test--repo (concat ws "beta"))
      (let ((r (drgnx-onboard-run :non-interactive t :options `(:preset ide :roots (,ws) :todos t))))
        (should-not (seq-find (lambda (s) (eq (cadr s) 'fail)) r))
        (should (equal (mapcar #'car r) (drgnx-onboard-steps))))
      (let ((board (drgnx-onboard-test--board)))
        (should (string-match-p "^\\* alpha" board))
        (should (string-match-p "^\\* beta" board))
        (should (string-match-p "^\\*\\* TODO two" board))
        (drgnx-onboard-run :non-interactive t :options `(:preset ide :roots (,ws) :todos t))
        (should (equal (drgnx-onboard-test--board) board))))))

(ert-deftest drgnx-onboard/the-cli ()
  (let (got)
    (cl-letf (((symbol-function 'drgnx-onboard-run) (lambda (&rest a) (setq got a) '((a ok "fine")))))
      (should (eql (drgnx-onboard-cli-run '("--non-interactive" "--preset" "minimal" "--roots" "/x" "/y" "--step" "projects")) 0))
      (should (plist-get got :non-interactive))
      (should (equal (plist-get (plist-get got :options) :preset) 'minimal))
      (should (equal (plist-get (plist-get got :options) :roots) '("/x" "/y")))
      (should (equal (plist-get got :only) '(projects)))
      (should-not (plist-get got :resume))                            ; a step named runs again
      (drgnx-onboard-cli-run '("--non-interactive"))
      (should (plist-get got :resume))                                ; a stopped run resumes by default
      (drgnx-onboard-cli-run '("--non-interactive" "--again" "--todos"))
      (should-not (plist-get got :resume))
      (should (plist-get (plist-get got :options) :todos)))
    (cl-letf (((symbol-function 'drgnx-onboard-run) (lambda (&rest _) '((a fail "no")))))
      (should (eql (drgnx-onboard-cli-run '("--non-interactive")) 1)))
    (should (eql (drgnx-onboard-cli-run '("--frob")) 2))
    (should (eql (drgnx-onboard-cli-run '("--step" "bogus")) 2))          ; never silently nothing
    (should (eql (drgnx-onboard-cli-run '("--roots")) 2))))                ; never the default roots by accident

;;;; The doctor and the registry

(require 'drgnx-doctor)

(ert-deftest drgnx-onboard/the-doctor-reports-onboarding ()
  (let ((check (lambda (s) (drgnx-doctor-check 'onboarding (list :onboarding s)))))
    (should (eq (car (funcall check nil)) 'info))
    (should (eq (car (funcall check '((environment :status ok) (projects :status fail)))) 'warn))
    (should (eq (car (funcall check '((environment :status ok) (projects :status info)))) 'ok))))

(ert-deftest drgnx-onboard/every-step-is-a-command ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-onboard-register-commands)
    (should (drgnx-commands-get 'onboarding))
    (should (drgnx-commands-get 'projects-sync-plans))
    (dolist (id (drgnx-onboard-steps))
      (should (drgnx-commands-get (intern (format "onboarding-%s" id)))))))

;;;; Review fixes (M6 final review)

(ert-deftest drgnx-projects/the-same-todo-text-in-two-projects-and-twice-in-a-plan ()
  ;; I1: ids are per project, and a repeated line in one file is a TODO each time.
  (drgnx-onboard-test--with root
    (let ((alpha (drgnx-onboard-test--repo (concat root "ws/alpha") '("TODO.md" . "- [ ] write the README\n")))
          (beta (drgnx-onboard-test--repo (concat root "ws/beta")
                                          '("TODO.md" . "- [ ] write the README\n")
                                          '("docs/plans/p.md" . "### Task 1\n- [ ] Step 1: test\n### Task 2\n- [ ] Step 1: test\n"))))
      (should (eql (plist-get (drgnx-projects-import (list alpha beta)) :todos) 4))
      (should (eql (plist-get (drgnx-projects-import (list alpha beta)) :todos) 0)))))

(ert-deftest drgnx-onboard/running-look-and-keys-again-keeps-the-users-choices ()
  ;; I2: with no option given, the current keys and modules stay.
  (drgnx-onboard-test--with root
    (drgnx-onboard-run :only '(look-and-keys) :non-interactive t :options '(:preset minimal :keys "Emacs"))
    (let ((keys (with-temp-buffer (insert-file-contents (expand-file-name "keys.eld" (drgnx-user-dir))) (buffer-string)))
          (mods (drgnx-modules-read-state)))
      (should (eq (cadr (car (drgnx-onboard-run :only '(look-and-keys) :non-interactive t))) 'ok))
      (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "keys.eld" (drgnx-user-dir))) (buffer-string)) keys))
      (setq drgnx-modules--state nil)
      (should (equal (drgnx-modules-read-state) mods)))))

(ert-deftest drgnx-projects/imported-projects-stay-in-the-sessions-project-list ()
  ;; I4: the session's own project.el list (already pointing at drgnx's file) learns them too.
  (drgnx-onboard-test--with root
    (let* ((alpha (drgnx-onboard-test--repo (concat root "ws/alpha")))
           (project-list-file (expand-file-name "projects" (drgnx-state-dir)))
           (project--list 'unset))
      (drgnx-projects-import (list alpha) :todos nil)
      (should (member (abbreviate-file-name alpha) (project-known-project-roots))))))

(ert-deftest drgnx-projects/the-board-keeps-its-modes-link-and-line-endings ()
  ;; I5
  (drgnx-onboard-test--with root
    (let ((alpha (drgnx-onboard-test--repo (concat root "ws/alpha")))
          (real (concat root "dotfiles/board.org")))
      (make-directory (file-name-directory real) t)
      (make-directory (file-name-directory (drgnx-projects-board-file)) t)
      (let ((coding-system-for-write 'utf-8-dos)) (write-region "* x\n" nil real nil 'silent))
      (set-file-modes real #o644)
      (make-symbolic-link real (drgnx-projects-board-file))
      (drgnx-projects-import (list alpha) :todos nil)
      (should (file-symlink-p (drgnx-projects-board-file)))
      (should (eql (file-modes real) #o644))
      (let ((bytes (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally real) (buffer-string))))
        (should (string-match-p "\\* alpha\r\n" bytes))
        (should-not (string-match-p "[^\r]\n" bytes))))))

(ert-deftest drgnx-projects/a-board-another-emacs-is-editing-is-left-alone ()
  ;; I6: its lock file names another Emacs.
  (drgnx-onboard-test--with root
    (let ((alpha (drgnx-onboard-test--repo (concat root "ws/alpha"))))
      (make-directory (file-name-directory (drgnx-projects-board-file)) t)
      (write-region "* x\n" nil (drgnx-projects-board-file) nil 'silent)
      (make-symbolic-link "someone@elsewhere.invalid.4242:1" (expand-file-name ".#board.org" (file-name-directory (drgnx-projects-board-file))))
      (should-error (drgnx-projects-import (list alpha)) :type 'user-error)
      (should (equal (drgnx-onboard-test--board) "* x\n")))))

(ert-deftest drgnx-onboard/a-scan-that-runs-out-of-time-says-so ()
  ;; I7
  (drgnx-onboard-test--with root
    (drgnx-onboard-test--repo (concat root "ws/alpha"))
    (let ((drgnx-projects-scan-budget 0))
      (let ((r (car (drgnx-onboard-run :only '(projects) :non-interactive t :options `(:roots (,(concat root "ws/")))))))
        (should (eq (cadr r) 'warn))
        (should (string-match-p "stopped" (nth 2 r)))))))

(ert-deftest drgnx-onboard/todos-are-imported-only-when-asked ()
  ;; I8
  (drgnx-onboard-test--with root
    (drgnx-onboard-test--repo (concat root "ws/alpha") '("TODO.md" . "- [ ] a thing\n"))
    (drgnx-onboard-run :only '(projects) :non-interactive t :options `(:roots (,(concat root "ws/"))))
    (should-not (string-match-p "TODO a thing" (drgnx-onboard-test--board)))
    (drgnx-onboard-run :only '(projects) :non-interactive t :options `(:roots (,(concat root "ws/")) :todos t))
    (should (string-match-p "TODO a thing" (drgnx-onboard-test--board)))))

(ert-deftest drgnx-projects/a-todo-removed-from-the-board-stays-removed ()
  ;; I9: archived or deleted, it is not imported again.
  (drgnx-onboard-test--with root
    (let ((alpha (drgnx-onboard-test--repo (concat root "ws/alpha") '("TODO.md" . "- [ ] once\n"))))
      (drgnx-projects-import (list alpha))
      (let ((b (drgnx-onboard-test--board)))
        (write-region (replace-regexp-in-string "\\*\\* TODO once\n:PROPERTIES:\n\\(:[A-Z_]+: .*\n\\)*:END:\n" "" b)
                      nil (drgnx-projects-board-file) nil 'silent))
      (should-not (string-match-p "once" (drgnx-onboard-test--board)))
      (should (eql (plist-get (drgnx-projects-import (list alpha)) :todos) 0)))))

(ert-deftest drgnx-projects/projects-nested-or-through-a-link-are-found ()
  ;; M3
  (drgnx-onboard-test--with root
    (let* ((alpha (drgnx-onboard-test--repo (concat root "ws/alpha")))
           (link (concat root "link-to-ws")))
      (make-symbolic-link (concat root "ws") link)
      (make-directory (file-name-directory (drgnx-projects-board-file)) t)
      (write-region (format "* Projects\n** alpha\n:PROPERTIES:\n:PROJECT_ROOT: %s\n:END:\n" (concat link "/alpha")) nil (drgnx-projects-board-file) nil 'silent)
      (should-not (plist-get (drgnx-projects-import (list alpha) :todos nil) :added)))))

(ert-deftest drgnx-projects/todo-text-never-becomes-org-syntax ()
  ;; M5
  (drgnx-onboard-test--with root
    (let ((alpha (drgnx-onboard-test--repo (concat root "ws/alpha") '("TODO.md" . "- [ ] fix this :urgent:\n- [ ] :PROPERTIES:\n- [ ] COMMENT out\n"))))
      (drgnx-projects-import (list alpha))
      (let ((board (drgnx-onboard-test--board)))
        (should-not (string-match-p "^\\*\\* TODO .*:urgent:$" board))
        (should-not (string-match-p "^\\*\\* TODO :PROPERTIES:" board))
        (should-not (string-match-p "^\\*\\* TODO COMMENT" board))
        (should (string-match-p "urgent" board))))))

(ert-deftest drgnx-onboard/the-desktop-entry-never-starts-another-config ()
  ;; M1: emacsclient -a "" would start a daemon with the default init (not drgnx's) on drgnx's socket.
  (should-not (string-match-p " -a " drgnx-onboard-desktop-entry)))

(defun drgnx-onboard-test--pick (root answers)
  "Run the projects step on ROOT's ws/, the user answering ANSWERS (what they type, split as crm splits it).
Returns (RESULT PROMPTS)."
  (let (prompts)
    (cl-letf (((symbol-function 'completing-read-multiple)
               (lambda (prompt table &rest _)
                 (push prompt prompts)
                 (let ((picked (split-string (pop answers) crm-separator t)))
                   (should (seq-every-p (lambda (s) (member s (all-completions "" table))) picked))   ; real choices
                   picked))))
      (list (car (drgnx-onboard-run :only '(projects) :options `(:roots (,(concat root "ws/"))))) (nreverse prompts)))))

(ert-deftest drgnx-onboard/the-project-picker-can-pick-none-and-paths-with-commas ()
  (drgnx-onboard-test--with root
    (let ((odd (directory-file-name (drgnx-onboard-test--repo (concat root "ws/al,pha")))))
      (drgnx-onboard-test--repo (concat root "ws/beta"))
      ;; (none): nothing imported, no question about TODOs
      (pcase-let ((`(,r ,prompts) (drgnx-onboard-test--pick root (list "(none)"))))
        (should (eq (cadr r) 'info))
        (should (string-match-p "none" (nth 2 r)))
        (should (= (length prompts) 1))
        (should-not (file-exists-p (drgnx-projects-board-file))))
      ;; a path with a comma is one choice
      (pcase-let ((`(,r ,_) (drgnx-onboard-test--pick root (list odd ""))))
        (should (eq (cadr r) 'ok))
        (should (string-match-p "\\`1 projects on the board" (nth 2 r)))
        (should (string-search (concat ":PROJECT_ROOT: " odd) (drgnx-onboard-test--board)))))))

;;; onboard-test.el ends here
