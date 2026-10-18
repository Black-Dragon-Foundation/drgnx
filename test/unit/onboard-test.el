;;; onboard-test.el --- batch tests: onboarding steps, projects onto the board -*- lexical-binding: t -*-
;; Fixture git repos, boards and configs live in temp dirs: never ~/workspace, ~/org or ~/.config.
(require 'ert)
(require 'drgnx-file)
(require 'drgnx-onboard)
(require 'drgnx-projects)
(require 'drgnx-macos)
(require 'drgnx-doctor)
(require 'drgnx-config-doc)

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
        (should-not (string-match-p "^\\*.*\\b\\(done already\\|old\\)\\b" board))   ; headings: paths may say "folders"
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
        ;; how to open it: the app is in ~/Applications, and the Dock shows Emacs while it runs
        (should (string-search "Spotlight (⌘Space, type \"drgnx\") or Launchpad" (nth 2 r)))
        (should (string-search "drag ~/Applications/drgnx.app there, not the running Emacs icon" (nth 2 r)))
        (should-not (string-search "from Applications" (nth 2 r)))
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
        (should-not (seq-find (lambda (s) (and (eq (cadr s) 'fail)
                                               ;; an Emacs built without native compilation (Homebrew's) fails
                                               ;; that doctor check, and nothing else
                                               (not (and (not (native-comp-available-p)) (eq (car s) 'finish)
                                                         (string-search "1 failed (native-compilation)" (nth 2 s))))))
                              r))
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

(ert-deftest drgnx-onboard/the-linux-desktop-files-are-written-in-the-config-folder-only ()
  (drgnx-onboard-test--with root
    (let ((calls nil) (orig (symbol-function 'drgnx-file-write-text)))
      (cl-letf (((symbol-function 'drgnx-file-write-text)
                 (lambda (f text &rest args) (push f calls) (apply orig f text args))))
        (let ((result (drgnx-onboard--linux-desktop nil))
              (unit (expand-file-name "systemd/drgnx.service" (drgnx-user-dir)))
              (desktop (expand-file-name "applications/drgnx.desktop" (drgnx-user-dir))))
          (should (eq (car result) 'info))
          (should (equal (sort (copy-sequence calls) #'string<) (sort (list unit desktop) #'string<)))
          (should (equal (with-temp-buffer (insert-file-contents desktop) (buffer-string)) drgnx-onboard-desktop-entry))
          (should (file-exists-p unit))
          (should-not (file-exists-p (expand-file-name "~/.local/share/applications/drgnx.desktop"))))))))


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

;;;; Step 6: Claude Code — installed with permission, its own login, the agent checked

(require 'drgnx-jobs)
(require 'drgnx-acp)
(require 'drgnx-agents)

(defun drgnx-onboard-test--script (file text)
  (make-directory (file-name-directory file) t)
  (write-region (concat "#!/bin/sh\n" text) nil file nil 'silent)
  (set-file-modes file #o755))

(defun drgnx-onboard-test--slurp (file)
  (if (file-exists-p file) (with-temp-buffer (insert-file-contents file) (buffer-string)) ""))

;; Kept at load time: the macro below stubs it, the tests of the offers put it back.
(defconst drgnx-onboard-test--offers (symbol-function 'drgnx-onboard--agents-offers))

(defmacro drgnx-onboard-test--claude (platform &rest body)
  "BODY on PLATFORM (`macos' or `linux') with a temp HOME and a PATH of fakes only (the basic tools linked in): nothing
is installed — `brew install --cask claude-code', `curl … | bash' (the Linux installer: a fake script), `brew install
node' and `npm install -g PKG' put the fakes in TPL into BIN (`npm … --prefix P' into P/bin).  `claude auth status'
says logged in when HOME has .logged-in (FAKE_OLD_CLAUDE: an old CLI that has no auth); `claude' alone waits.
`claude-agent-acp' is the mock ACP agent (FAKE_ACP: a script for it).  Every call is logged to CALLS."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-claude" t)))
          (bin (concat root "bin/")) (tpl (concat root "tpl/")) (home (concat root "home/")) (calls (concat root "calls"))
          (real-path (getenv "PATH"))
          ;; the ones this system has (macOS: no setsid; detached jobs use perl there)
          (basics (delq nil (mapcar #'executable-find '("sh" "bash" "env" "cat" "cp" "mkdir" "sleep" "setsid" "perl" "date"))))
          (log-line (lambda (name) (format "printf '%%s\\n' \"%s $*\" >> %s\n" name calls)))
          (process-environment (append (list (concat "HOME=" home) (concat "DRGNX_CONFIG_DIR=" root "config")
                                             (concat "XDG_STATE_HOME=" root "state") "DRGNX_JOBS_LAUNCHER=detached"
                                             (concat "PATH=" bin))
                                       process-environment))
          (exec-path (list bin))
          (drgnx-onboard--progress nil) (drgnx-agents-profiles nil) (drgnx-onboard--current nil))
     (unwind-protect
         (progn
           (make-directory bin t) (make-directory home t) (make-directory (concat root "config") t)
           (dolist (tool basics) (make-symbolic-link tool (concat bin (file-name-nondirectory tool))))
           (drgnx-onboard-test--script
            (concat tpl "claude")
            (concat (funcall log-line "claude")
                    "case \"$1 $2\" in\n"
                    " 'auth status') [ -n \"$FAKE_OLD_CLAUDE\" ] && { echo \"error: unknown command 'auth'\"; exit 1; }\n"
                    "   if [ -e \"$HOME/.logged-in\" ]; then echo '{\"loggedIn\": true}'; exit 0; fi; echo '{\"loggedIn\": false}'; exit 1;;\n"
                    " *) exec sleep 30;;\nesac\n"))
           (drgnx-onboard-test--script
            (concat tpl "claude-agent-acp")
            (format "if [ -n \"$FAKE_ACP\" ]; then eval \"$FAKE_ACP\"; fi\nPATH=%s; exec sh %s %s --batch -Q -l %s\n"
                    (shell-quote-argument real-path)     ; the emacs launcher script needs the real one
                    (shell-quote-argument (expand-file-name "test/fixtures/mock-acp-stdin.sh" drgnx-dir))
                    (shell-quote-argument (expand-file-name invocation-name invocation-directory))
                    (shell-quote-argument (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))))
           (drgnx-onboard-test--script (concat tpl "node") "exit 0\n")
           (drgnx-onboard-test--script
            (concat bin "brew")
            (concat (funcall log-line "brew")
                    "case \"$*\" in\n 'install --cask claude-code') echo Pouring claude-code; cp " tpl "claude " bin "claude;;\n"
                    " 'install node') cp " tpl "node " bin "node; cp " tpl "npm " bin "npm;;\nesac\n"))
           (drgnx-onboard-test--script
            (concat tpl "npm")
            (concat (funcall log-line "npm")
                    "[ \"$1 $2\" = 'install -g' ] || exit 0\nshift 2; d=" bin "\n"
                    "if [ \"$1\" = --prefix ]; then d=\"$2/bin\"; mkdir -p \"$d\"; shift 2; fi\n"
                    "[ -n \"$FAKE_NPM_FAIL\" ] && { echo 'npm ERR! code EACCES'; exit 243; }\n"
                    "cp " tpl "claude-agent-acp \"$d/claude-agent-acp\"\n"
                    ;; the package it was asked for, where npm puts it: PREFIX/lib/node_modules/PKG
                    "p=\"$d/../lib/node_modules/$1\"; mkdir -p \"$p\"\n"
                    "printf '{\"name\": \"%s\", \"version\": \"0.93.0\"}' \"$1\" > \"$p/package.json\"\n"))
           (drgnx-onboard-test--script
            (concat bin "curl")
            (concat (funcall log-line "curl")
                    "echo 'mkdir -p $HOME/.local/bin; cp " tpl "claude $HOME/.local/bin/claude; echo Installed'\n"))
           (drgnx-onboard-test--script (concat bin "dnf") "exit 0\n")
           ;; the agent defaults are asked after a good check (their own tests below turn the question back on)
           (cl-letf (((symbol-function 'drgnx-platform) (lambda () ,platform))
                     ((symbol-function 'drgnx-onboard--agents-offers) #'ignore))
             ,@body))
       (dolist (j (drgnx-jobs-list)) (drgnx-jobs-stop (plist-get j :id)))
       (when-let* ((b (get-buffer "*Claude login*")))
         (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
       (delete-directory root t))))

(defun drgnx-onboard-test--have (bin &rest tools)
  "Put the fakes TOOLS (names under BIN's sibling tpl/) in place, as an installation would."
  (dolist (tool tools)
    (copy-file (concat (file-name-directory (directory-file-name bin)) "tpl/" tool) (concat bin tool) t)))

(defun drgnx-onboard-test--asked (answers)
  "A `y-or-n-p' answering from ANSWERS ((REGEXP . ANSWER)…) and recording the prompts in the variable it returns
as the second element: (FUNCTION . PROMPTS-CELL).  An unexpected question is an error."
  (let ((cell (list nil)))
    (cons (lambda (prompt)
            (push prompt (car cell))
            (let ((a (seq-find (lambda (p) (string-match-p (car p) prompt)) answers)))
              (unless a (error "Unexpected question: %s" prompt))
              (cdr a)))
          cell)))

(ert-deftest drgnx-onboard/claude-missing-is-installed-with-permission ()
  (drgnx-onboard-test--claude 'macos
    (let ((asked (drgnx-onboard-test--asked '(("\\`Set up Claude Code" . t)))))
      ;; without interaction: nothing installed, the commands said, no job
      (let ((r (drgnx-onboard--agents-step '(:interactive nil))))
        (should (eq (car r) 'info))
        (should (string-match-p "brew install --cask claude-code; brew install node; npm install -g @agentclientprotocol/claude-agent-acp"
                                (cadr r)))
        (should-not (string-match-p "gry" (cadr r))))
      (should (equal (split-string (drgnx-onboard-test--slurp calls) "\n" t) nil))
      (should-not (drgnx-jobs-list))
      ;; interactive: asked once with the commands, then installed in order, logged in, the agent checked
      (write-region "" nil (concat home ".logged-in"))
      (let ((r (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))))
        (should (equal (length (car (cdr asked))) 1))
        (should (string-match-p "brew install --cask claude-code; brew install node; npm install -g @agentclientprotocol/claude-agent-acp"
                                (car (car (cdr asked)))))
        (should (equal r (list 'ok (cadr r))))
        (should (string-match-p "claude profile" (cadr r))))
      (should (equal (seq-take (split-string (drgnx-onboard-test--slurp calls) "\n" t) 3)
                     '("brew install --cask claude-code" "brew install node"
                       "npm install -g @agentclientprotocol/claude-agent-acp")))
      ;; C2-3: what was installed is the maintained package, and it is what the profiles run
      (should (equal (plist-get (drgnx-agents-claude-adapter) :name) "@agentclientprotocol/claude-agent-acp")))))

(ert-deftest drgnx-onboard/the-onboarding-package-is-the-maintained-adapter ()
  (should (equal drgnx-onboard-claude-package drgnx-agents-claude-package)))

(ert-deftest drgnx-onboard/a-deprecated-adapter-keeps-working-and-the-step-says-how-to-move ()
  ;; C2-3: the deprecated @zed-industries package installed earlier: the profile is checked with it, the step warns
  ;; with the command — and nothing is installed or removed without that command
  (drgnx-onboard-test--claude 'linux
    (drgnx-onboard-test--installed
     (let ((pkg (concat root "lib/node_modules/@zed-industries/claude-agent-acp/")))
       (make-directory pkg t)
       (write-region "{\"name\": \"@zed-industries/claude-agent-acp\", \"version\": \"0.23.1\"}" nil (concat pkg "package.json"))
       (write-region "" nil (concat home ".logged-in"))
       (dolist (ctx '((:interactive nil) (:interactive t)))
         (let ((r (cl-letf (((symbol-function 'y-or-n-p) (lambda (p) (error "Unexpected question: %s" p))))
                    (drgnx-onboard--agents-step ctx))))
           (should (eq (car r) 'warn))
           (should (string-match-p "claude profile answered" (cadr r)))                 ; it still works
           (should (string-search "@zed-industries/claude-agent-acp" (cadr r)))
           (should (string-search "npm uninstall -g --prefix" (cadr r)))
           (should (string-search "&& npm install -g --prefix" (cadr r)))))
       (should-not (string-match-p "^npm" (drgnx-onboard-test--slurp calls)))   ; npm never ran
       (should (file-executable-p (concat bin "claude-agent-acp")))
       (should (file-exists-p (concat pkg "package.json")))))))

(ert-deftest drgnx-onboard/claude-missing-says-no-and-nothing-is-installed ()
  (drgnx-onboard-test--claude 'macos
    (let ((asked (drgnx-onboard-test--asked '(("\\`Set up Claude Code" . nil)))))
      (let ((r (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))))
        (should (eq (car r) 'info))
        (should (string-match-p "brew install --cask claude-code" (cadr r))))
      (should (equal (drgnx-onboard-test--slurp calls) "")))))

(ert-deftest drgnx-onboard/claude-on-linux-uses-its-installer-and-your-terminal-for-sudo ()
  (drgnx-onboard-test--claude 'linux
    (let* ((asked (drgnx-onboard-test--asked '(("\\`Set up Claude Code" . t))))
           (drgnx-onboard-app-wait 10)
           (r0 (drgnx-onboard--agents-step '(:interactive nil))))
      (should (string-match-p "curl -fsSL https://claude.ai/install.sh | bash; sudo dnf install nodejs npm; npm install -g --prefix ~/.local @agentclientprotocol/claude-agent-acp"
                              (cadr r0)))
      (write-region "" nil (concat home ".logged-in"))
      ;; Node needs sudo: shown and copied, then the step waits for npm to appear — here a moment later
      (run-at-time 0.6 nil (lambda () (drgnx-onboard-test--have bin "npm")))
      (let ((r (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))))
        (should (equal (car kill-ring) "sudo dnf install nodejs npm"))
        (should (equal r (list 'ok (cadr r)))))
      (should (file-executable-p (concat home ".local/bin/claude")))           ; the official installer's place
      (should (file-executable-p (concat home ".local/bin/claude-agent-acp")))  ; npm --prefix ~/.local: no sudo
      (should (string-match-p (format "npm install -g --prefix %s.local @agentclientprotocol/claude-agent-acp" home)
                              (drgnx-onboard-test--slurp calls))))))

(ert-deftest drgnx-onboard/a-vs-code-extensions-claude-does-not-count ()
  (drgnx-onboard-test--claude 'macos
    (drgnx-onboard-test--script (concat home ".vscode/extensions/anthropic.claude-code-2/resources/native-binary/claude") "exit 0\n")
    (drgnx-onboard-test--have bin "npm" "claude-agent-acp")
    (let ((r (drgnx-onboard--agents-step '(:interactive nil))))
      (should (eq (car r) 'info))
      (should (string-match-p "brew install --cask claude-code" (cadr r)))
      (should-not (string-match-p "brew install node" (cadr r))))))

(defmacro drgnx-onboard-test--installed (&rest body)
  "BODY with Claude Code, npm and the adapter in place (inside `drgnx-onboard-test--claude')."
  `(progn (drgnx-onboard-test--have bin "claude" "claude-agent-acp" "npm") ,@body))

(ert-deftest drgnx-onboard/claude-not-logged-in-opens-its-login ()
  (drgnx-onboard-test--claude 'macos
    (drgnx-onboard-test--installed
     (let ((asked (drgnx-onboard-test--asked '(("log in" . t)))))
       ;; without interaction: no terminal, only what to do
       (let ((r (drgnx-onboard--agents-step '(:interactive nil))))
         (should (eq (car r) 'info))
         (should (string-match-p "/login" (cadr r)))
         (should-not (get-buffer "*Claude login*")))
       (let ((r (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))))
         (should (eq (car r) 'info))
         (should (string-match-p "Done" (cadr r)))
         (should (string-match-p "/login" (cadr r))))
       (let ((b (get-buffer "*Claude login*")))
         (should b)
         (should (process-live-p (get-buffer-process b)))
         (should (equal (car (last (process-command (get-buffer-process b)))) (concat bin "claude")))   ; term runs it through a shell
         (should (equal (buffer-local-value 'header-line-format b)
                        "Type /login, finish in the browser, then press Return on the Agents row in the Welcome (Done)")))
       ;; the user logged in and presses Done (runs the step again): the agent is checked, no second terminal
       (write-region "" nil (concat home ".logged-in"))
       (let ((r (drgnx-onboard--agents-step '(:interactive t))))
         (should (equal r (list 'ok (cadr r)))))
       (should (= 1 (length (car (cdr asked)))))))))

(ert-deftest drgnx-onboard/a-claude-that-cannot-say-is-offered-the-login-and-never-fails-the-step ()
  (drgnx-onboard-test--claude 'macos
    (drgnx-onboard-test--installed
     (let ((process-environment (cons "FAKE_OLD_CLAUDE=1" process-environment))
           (asked (drgnx-onboard-test--asked '(("log in" . nil)))))
       (let ((r (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))))
         (should (= 1 (length (car (cdr asked)))))                   ; the login was offered
         (should (eq (car r) 'info))                                 ; not a failure
         (should (string-match-p "could not tell" (cadr r)))
         (should (string-match-p "claude profile" (cadr r))))))))    ; and the agent was still checked

(ert-deftest drgnx-onboard/the-claude-profile-is-checked ()
  (drgnx-onboard-test--claude 'macos
    (drgnx-onboard-test--installed
     (write-region "" nil (concat home ".logged-in"))
     ;; the mock agent answers initialize: ok (without interaction too), and nothing is left running
     (let ((r (drgnx-onboard--agents-step '(:interactive nil))))
       (should (equal r (list 'ok (cadr r))))
       (should (string-match-p "claude profile answered" (cadr r))))
     (should-not (seq-find (lambda (p) (string-prefix-p "drgnx-acp" (process-name p))) (process-list)))
     ;; an agent that dies at once: a failure that says why
     (let* ((process-environment (cons "FAKE_ACP=echo 'cannot find module' >&2; exit 1" process-environment))
            (r (drgnx-onboard--agents-step '(:interactive nil))))
       (should (eq (car r) 'fail))
       (should (string-match-p "claude-agent-acp" (cadr r))))
     ;; one that never answers: after the wait
     (let* ((process-environment (cons "FAKE_ACP=exec sleep 30" process-environment))
            (drgnx-onboard-agent-wait 1)
            (r (drgnx-onboard--agents-step '(:interactive nil))))
       (should (eq (car r) 'fail))
       (should (string-match-p "did not answer within 1 second" (cadr r)))))))

(ert-deftest drgnx-onboard/an-npm-failure-says-how-to-retry ()
  (drgnx-onboard-test--claude 'macos
    (let ((asked (drgnx-onboard-test--asked '(("\\`Set up Claude Code" . t))))
          (process-environment (cons "FAKE_NPM_FAIL=1" process-environment)))
      (let ((r (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))))
        (should (eq (car r) 'fail))
        (should (string-match-p "EACCES" (cadr r)))                  ; why: the log's last line
        (should (string-match-p "run this step again" (cadr r)))      ; how to retry
        (should (string-match-p "in a terminal: npm install -g @agentclientprotocol/claude-agent-acp" (cadr r)))
        (should (string-match-p "log: " (cadr r))))
      ;; Claude Code and Node were installed; the retry installs only the adapter
      (should (file-executable-p (concat bin "claude")))
      (let* ((process-environment (cons "FAKE_NPM_FAIL=" process-environment))
             (asked (drgnx-onboard-test--asked '(("\\`Set up Claude Code: npm install -g" . t)))))
        (write-region "" nil (concat home ".logged-in"))
        (let ((r (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))))
          (should (equal r (list 'ok (cadr r)))))))))

(ert-deftest drgnx-onboard/the-preset-step-offers-the-packages ()
  ;; After the preset: its packages (the lock's, with what they need), asked once with their size, then `drgnx sync'
  ;; as a job; never without interaction; not again once they are installed.
  (drgnx-onboard-test--with root
    (require 'drgnx-pkg)
    (let* ((jobs nil) (asked nil) (answer t) (done 'ok)
           (opts '(:preset full-ai :keys "Emacs" :theme modus-vivendi))
           (lock (lambda (fa-size)
                   (drgnx-pkg-write-lock
                    `((fa :version "1.0" :archive "gnu" :file "fa-1.0.tar" :sha256 "x" :size ,fa-size :requires ((fb "1.0")))
                      (fb :version "1.0" :archive "gnu" :file "fb-1.0.tar" :sha256 "y" :size 600000)
                      (gp :kind git :url "https://example.invalid/gp" :commit "abc" :version "0.1")
                      (zz :version "2.0" :archive "gnu" :file "zz-2.0.tar" :sha256 "z" :size 99000000))))))   ; not needed
      (funcall lock 1500000)
      (cl-letf (((symbol-function 'drgnx-pkg-manifest) (lambda (&rest _) '(fa gp)))
                ((symbol-function 'drgnx-onboard--job) (lambda (what command &rest _) (push (cons what command) jobs) done))
                ((symbol-function 'y-or-n-p) (lambda (p) (push p asked) answer)))
        ;; without interaction: nothing asked or run; the step says how
        (let ((r (car (drgnx-onboard-run :only '(look-and-keys) :non-interactive t :options opts))))
          (should (eq (nth 1 r) 'ok))
          (should (string-match-p "drgnx sync" (nth 2 r))))
        (should-not asked)
        (should-not jobs)
        ;; interactive: one question with the preset and the size, then drgnx sync as a drgnx job
        (let ((r (drgnx-onboard--look-step `(:interactive t :options ,opts))))
          (should (equal asked '("Install the packages for full-ai now (about 2 MB)? ")))
          (should (equal (last (cdr (car jobs)) 2) (list (expand-file-name "bin/drgnx" drgnx-dir) "sync")))
          (should (eq (car r) 'ok))
          (should (string-match-p "packages installed" (cadr r))))
        ;; no: nothing runs, the step says drgnx sync
        (setq asked nil jobs nil answer nil)
        (let ((r (drgnx-onboard--look-step `(:interactive t :options ,opts))))
          (should (= 1 (length asked)))
          (should-not jobs)
          (should (string-match-p "drgnx sync" (cadr r))))
        ;; a size the lock does not know: left out, never guessed
        (setq asked nil answer t)
        (funcall lock nil)
        (drgnx-onboard--look-step `(:interactive t :options ,opts))
        (should (equal asked '("Install the packages for full-ai now? ")))
        ;; a sync that fails: a warning that says why and how to retry
        (setq done '(fail "Installing the packages failed (exit 1): MISSING fa" "/tmp/log"))
        (let ((r (drgnx-onboard--look-step `(:interactive t :options ,opts))))
          (should (eq (car r) 'warn))
          (should (string-match-p "MISSING fa" (cadr r)))
          (should (string-match-p "drgnx sync" (cadr r))))
        ;; installed: not asked again
        (dolist (d '("fa-1.0" "fb-1.0" "gp-0.1")) (make-directory (expand-file-name d (drgnx-elpa-dir)) t))
        (setq asked nil jobs nil)
        (let ((r (drgnx-onboard--look-step `(:interactive t :options ,opts))))
          (should-not asked)
          (should-not jobs)
          (should (eq (car r) 'ok)))))))

(ert-deftest drgnx-onboard/a-fresh-install-is-full-ai ()
  ;; Nothing turned off is the full-ai preset — the Modules question's default — so Return keeps Chat on.
  (drgnx-onboard-test--with root
    (should (eq (drgnx-onboard--current-preset) 'full-ai))
    (let ((asked nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt _c &optional _p _r _i _h def &rest _) (push (cons prompt def) asked) (or (car (ensure-list def)) "")))
                ((symbol-function 'drgnx-onboard--packages-to-install) #'ignore))
        (drgnx-onboard--look-step '(:interactive t :options (:keys "Emacs" :theme modus-vivendi))))
      (should (string-prefix-p "Modules" (car (car (last asked)))))
      (should (equal (cdr (car (last asked))) "full-ai"))
      (should-not (drgnx-module-disabled-p 'extra/llm)))
    ;; a mix of your own: Return keeps it
    (drgnx-modules-write-state '(:version 1 :disabled (extra/magit)))
    (should-not (drgnx-onboard--current-preset))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _c &optional _p _r _i _h def &rest _) (or (car (ensure-list def)) "")))
              ((symbol-function 'drgnx-onboard--packages-to-install) #'ignore))
      (drgnx-onboard--look-step '(:interactive t :options (:keys "Emacs" :theme modus-vivendi))))
    (should (equal (plist-get (drgnx-modules-read-state) :disabled) '(extra/magit)))))

(defun drgnx-onboard-test--return (asked)
  "A `completing-read' that pushes its prompt on the list in symbol ASKED and answers Return alone (the default)."
  (lambda (prompt _c &optional _p _r _i _h def &rest _) (set asked (cons prompt (symbol-value asked))) (or (car (ensure-list def)) "")))

(defvar drgnx-onboard-test--asked nil)

(ert-deftest drgnx-onboard/every-question-shows-its-choices-and-default ()
  ;; A first start has no completion UI: the prompt itself lists the few choices and the default Return takes.
  (drgnx-onboard-test--with root
    (setq drgnx-onboard-test--asked nil)
    (cl-letf (((symbol-function 'completing-read) (drgnx-onboard-test--return 'drgnx-onboard-test--asked))
              ((symbol-function 'drgnx-onboard--packages-to-install) #'ignore)
              ((symbol-function 'custom-available-themes) (lambda () '(modus-vivendi tango)))
              ((symbol-function 'drgnx-platform) (lambda () 'linux)))  ; a Mac also asks about Option (y-or-n-p)
      (drgnx-onboard--look-step '(:interactive t)))
    (pcase-let ((`(,theme ,keys ,modules) drgnx-onboard-test--asked))
      (should (equal modules (format-prompt "Modules (minimal, ide, full-ai)" "full-ai")))
      (should (equal keys (format-prompt (concat "Keys (" (mapconcat #'car drgnx-keys-presets ", ") ")") "VS Code")))
      (should (equal theme (format-prompt "Color theme (modus-vivendi, tango, keep)" "keep"))))
    (should (eq (drgnx-onboard--current-preset) 'full-ai))
    ;; an answer that is not a choice is an error, never taken as one
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "nonsense")))
      (should-error (drgnx-onboard--choose "Pick" '("a" "b") "a") :type 'user-error))))

(ert-deftest drgnx-onboard/set-up-ai-with-defaults-to-the-machine ()
  ;; Return alone: Ollama when models get 10 GB of room here, else OpenRouter; never Skip.
  (require 'drgnx-ai-probe)
  (dolist (c '((16000 macos "ollama") (10000 linux "ollama") (8000 macos "openrouter") (nil linux "openrouter")))
    (pcase-let ((`(,total ,platform ,want) c))
      (cl-letf (((symbol-function 'drgnx-ai-vram) (lambda () (and total (list :total total :used 0))))
                ((symbol-function 'drgnx-platform) (lambda () platform)))
        (should (equal (drgnx-onboard--ai-default) want)))))
  (setq drgnx-onboard-test--asked nil)
  (cl-letf (((symbol-function 'drgnx-ai-vram) (lambda () '(:total 16000 :used 0)))
            ((symbol-function 'completing-read) (drgnx-onboard-test--return 'drgnx-onboard-test--asked)))
    (should (eq (drgnx-onboard--ai-ask) 'ollama))
    (should (equal (car drgnx-onboard-test--asked)
                   (format-prompt "Set up AI with (ollama, lmstudio, openrouter, skip)" "ollama")))))

(ert-deftest drgnx-onboard/the-welcome-says-where-to-start-and-moves-on ()
  (drgnx-onboard-test--with root
    (let ((drgnx-onboard--steps nil) (ran nil))
      (drgnx-onboard-define-step 'a :title "A" :order 10 :doc "a" :run (lambda (_) (push 'a ran) '(ok "a done")))
      (drgnx-onboard-define-step 'b :title "B" :order 20 :doc "b" :run (lambda (_) (push 'b ran) '(ok "b done")))
      (save-window-excursion
        (drgnx-onboard-welcome)
        (with-current-buffer "*drgnx Welcome*"
          (should (equal header-line-format "Return runs the step under the cursor — start at the top"))
          (should (eq (tabulated-list-get-id) 'a))       ; it opens on the first step
          (drgnx-onboard-run-step-at-point)
          (should (equal ran '(a)))
          (should (eq (tabulated-list-get-id) 'b))       ; on to the next step
          (drgnx-onboard-run-step-at-point)
          (should (equal ran '(b a)))
          (should (eq (tabulated-list-get-id) 'b))))     ; the last one: point stays
      (kill-buffer "*drgnx Welcome*"))))

(ert-deftest drgnx-onboard/on-a-mac-look-and-keys-asks-about-option-once ()
  (drgnx-onboard-test--with root
    (let ((asked nil) (answer t) (opts '(:preset full-ai :keys "VS Code" :theme modus-vivendi)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (p &rest _) (push p asked) (if answer "types characters" "Meta")))
                ((symbol-function 'drgnx-onboard--packages-to-install) #'ignore)
                ((symbol-function 'drgnx-platform) (lambda () 'macos)))
        (let ((r (drgnx-onboard--look-step `(:interactive t :options ,opts))))
          (should (= 1 (length asked)))
          (should (string-match-p "@ # { \\[" (car asked)))
          (should (eq (plist-get (drgnx-keys-read-user) :mac-option) 'characters))
          (should (string-match-p "Option types characters" (cadr r))))
        (setq asked nil answer nil)
        (let ((r (drgnx-onboard--look-step `(:interactive t :options ,opts))))
          (should (= 1 (length asked)))
          (should (eq (plist-get (drgnx-keys-read-user) :mac-option) 'meta))
          (should (string-match-p "Option is Meta" (cadr r))))
        ;; without interaction: nothing asked, the setting stays
        (setq asked nil)
        (drgnx-onboard-run :only '(look-and-keys) :non-interactive t :options opts)
        (should-not asked)
        (should (eq (plist-get (drgnx-keys-read-user) :mac-option) 'meta))
        ;; Emacs keys: drgnx leaves Option alone, so it does not ask
        (drgnx-onboard--look-step '(:interactive t :options (:preset full-ai :keys "Emacs" :theme modus-vivendi)))
        (should-not asked))
      ;; Linux: never asked
      (cl-letf (((symbol-function 'completing-read) (lambda (p &rest _) (push p asked) "Meta"))
                ((symbol-function 'drgnx-onboard--packages-to-install) #'ignore)
                ((symbol-function 'drgnx-platform) (lambda () 'linux)))
        (drgnx-onboard--look-step `(:interactive t :options ,opts))
        (should-not asked)))))

(ert-deftest drgnx-onboard/option-question-shows-the-current-choice ()
  ;; M12a-80: the question names both answers and offers the saved one on Return (Meta before anything is saved)
  (drgnx-onboard-test--with root
    (let ((seen nil) (answer "Meta") (opts '(:preset full-ai :keys "VS Code" :theme modus-vivendi)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt choices &optional _p _r _i _h def &rest _) (push (list prompt choices def) seen) answer))
                ((symbol-function 'drgnx-onboard--packages-to-install) #'ignore)
                ((symbol-function 'drgnx-platform) (lambda () 'macos)))
        (drgnx-onboard--look-step `(:interactive t :options ,opts))
        (should (equal (nth 1 (car seen)) '("types characters" "Meta")))
        (should (equal (nth 2 (car seen)) "Meta"))
        (should (string-match-p "types characters, Meta" (nth 0 (car seen))))
        (should (eq (plist-get (drgnx-keys-read-user) :mac-option) 'meta))
        ;; saved as characters: the next run offers that on Return
        (setq answer "types characters")
        (drgnx-onboard--look-step `(:interactive t :options ,opts))
        (should (eq (plist-get (drgnx-keys-read-user) :mac-option) 'characters))
        (drgnx-onboard--look-step `(:interactive t :options ,opts))
        (should (equal (nth 2 (car seen)) "types characters"))))))

(ert-deftest drgnx-onboard/chat-check-in-batch-offers-no-restart ()
  ;; gptel installed, module extra/llm on, gptel not loaded yet: in batch the Finish step never offers a restart, so
  ;; the result says it loads at the next start; a restart is needed only when this run turned the module on or
  ;; installed the package.
  (drgnx-onboard-test--with root
    (let ((drgnx-onboard--restart-needed nil))
      (should-not (featurep 'gptel))
      (make-directory (expand-file-name "gptel-0.9.9" (drgnx-elpa-dir)) t)
      (drgnx-modules-write-state (list :disabled nil))
      ;; batch, module already on
      (should noninteractive)
      (let ((r (drgnx-onboard--chat-module '(:interactive nil))))
        (should (car r))
        (should (string-search "loads at drgnx's next start" (cdr r)))
        (should-not (string-search "Finish" (cdr r)))
        (should-not drgnx-onboard--restart-needed))
      ;; the app, module already on: nothing changed by this run, nothing to restart for
      (let ((noninteractive nil) (r nil))
        (setq r (drgnx-onboard--chat-module '(:interactive t)))
        (should (string-search "loads at drgnx's next start" (cdr r)))
        (should-not (string-search "Finish" (cdr r)))
        (should-not drgnx-onboard--restart-needed))
      ;; the app, this run turns the module on: the restart is offered
      (drgnx-modules-write-state (list :disabled '(extra/llm)))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
        (let ((noninteractive nil) (r nil))
          (setq r (drgnx-onboard--chat-module '(:interactive t)))
          (should (string-search "the Finish step offers it" (cdr r)))
          (should drgnx-onboard--restart-needed)))
      ;; batch, this run turns it on: no Finish offer is promised
      (setq drgnx-onboard--restart-needed nil)
      (drgnx-modules-write-state (list :disabled '(extra/llm)))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
        (let ((r (drgnx-onboard--chat-module '(:interactive t))))
          (should (string-search "loads at drgnx's next start" (cdr r)))
          (should-not (string-search "Finish" (cdr r))))))))

;; M12a-74: the restart asks its save questions first, detaches the waiter only after they are answered, then quits.
(ert-deftest drgnx-onboard/restart-detaches-after-the-questions ()
  (let ((events nil))
    (cl-letf (((symbol-function 'drgnx-onboard--restart-spawn) (lambda (_line) (push 'detach events)))
              ((symbol-function 'kill-emacs) (lambda (&rest _) (push 'kill events))))
      ;; a "no": nothing detached, nothing killed
      (cl-letf (((symbol-function 'drgnx-session-quit-confirm) (lambda () (push 'confirm events) nil)))
        (drgnx-onboard--restart)
        (should (equal (reverse events) '(confirm))))
      ;; C-g in a question: it leaves through the signal, nothing detached, nothing killed
      (setq events nil)
      (cl-letf (((symbol-function 'drgnx-session-quit-confirm) (lambda () (push 'confirm events) (signal 'quit nil))))
        (should (eq 'quit (condition-case nil (progn (drgnx-onboard--restart) 'ran) (quit 'quit))))
        (should (equal (reverse events) '(confirm))))
      ;; a "yes": confirm, then detach, then kill-emacs
      (setq events nil)
      (cl-letf (((symbol-function 'drgnx-session-quit-confirm) (lambda () (push 'confirm events) t)))
        (drgnx-onboard--restart)
        (should (equal (reverse events) '(confirm detach kill)))))))

;; A drgnx running as a systemd service dies with its whole cgroup (KillMode=control-group): a `setsid' waiter
;; started from it is killed with it and never reopens drgnx.  There the waiter runs as its own transient unit.
(ert-deftest drgnx-onboard/restart-waiter-outlives-a-systemd-service ()
  (let ((detached nil) (calls nil) (rc 0))
    (cl-letf (((symbol-function 'drgnx-jobs--detach) (lambda (line) (push line detached)))
              ((symbol-function 'executable-find) (lambda (p &rest _) (and (equal p "systemd-run") "/usr/bin/systemd-run")))
              ((symbol-function 'call-process)
               (lambda (program _in _out _display &rest args) (push (cons program args) calls) rc)))
      (let ((line "i=$((i+1)); echo 100%; exec '/x y/bin/drgnx' open"))
        ;; not under systemd (no INVOCATION_ID): the detached waiter, no systemd-run
        (let ((process-environment (cons "XDG_RUNTIME_DIR=/run/user/1" (cons "INVOCATION_ID" process-environment))))
          (drgnx-onboard--restart-spawn line)
          (should (equal detached (list line)))
          (should-not calls))
        ;; under a unit: its own transient unit, killing only the waiter's main process; $ and % escaped for ExecStart
        (setq detached nil)
        (let ((process-environment (append '("INVOCATION_ID=abc" "XDG_RUNTIME_DIR=/run/user/1") process-environment)))
          (drgnx-onboard--restart-spawn line)
          (should-not detached)
          (let ((c (car calls)))
            (should (equal (car c) "systemd-run"))
            (should (member "--user" c))
            (should (member "--collect" c))
            (should (member "KillMode=process" c))
            (should (string-prefix-p (format "--unit=drgnx-restart-%d" (emacs-pid)) (seq-find (lambda (a) (string-prefix-p "--unit=" a)) c)))
            (should (equal (last c 3) (list "sh" "-c" "i=$$((i+1)); echo 100%%; exec '/x y/bin/drgnx' open"))))
          ;; systemd-run failing: falls back to the detached waiter
          (setq calls nil rc 1)
          (drgnx-onboard--restart-spawn line)
          (should (equal detached (list line))))))))

(ert-deftest drgnx-onboard/new-modules-need-a-restart-and-finish-offers-it ()
  ;; Packages installed into a running drgnx load at its next start: Look and Keys says so, and Finish (in the
  ;; app) offers the restart — drgnx open, detached, then quit — or says how to do it yourself.
  (drgnx-onboard-test--with root
    (let ((drgnx-onboard--restart-needed nil) (asked nil) (lines nil) (quit 0) (answer t))
      (cl-letf (((symbol-function 'drgnx-onboard--packages-to-install) (lambda () '(:names (gptel))))
                ((symbol-function 'drgnx-onboard--job) (lambda (&rest _) 'ok))
                ((symbol-function 'y-or-n-p) (lambda (p) (push p asked) answer))
                ((symbol-function 'drgnx-doctor-run) (lambda (&rest _) nil))
                ((symbol-function 'drgnx-doctor-facts) #'ignore)
                ((symbol-function 'drgnx-jobs--detach) (lambda (line) (push line lines)))
                ((symbol-function 'drgnx-session-quit-confirm) (lambda () t))
                ((symbol-function 'drgnx-onboard--under-systemd-p) #'ignore)
                ((symbol-function 'kill-emacs) (lambda (&rest _) (cl-incf quit)))
                ((symbol-function 'drgnx-platform) (lambda () 'linux)))  ; a Mac's finish names Spotlight
        (let ((r (drgnx-onboard--look-step '(:interactive t :options (:preset full-ai :keys "Emacs" :theme modus-vivendi)))))
          (should (string-match-p "restart drgnx to load the new modules" (cadr r))))
        (should drgnx-onboard--restart-needed)
        ;; Finish, in the app: asked; yes — drgnx open after this Emacs is gone, then quit
        (setq asked nil)
        (let ((noninteractive nil)) (drgnx-onboard--finish-step '(:interactive t)))
        (should (equal asked '("Restart drgnx now? Your windows come back. ")))
        (should (= quit 1))
        (should (string-prefix-p "sleep 1;" (car lines)))
        (should (string-search (concat "kill -0 " (number-to-string (emacs-pid))) (car lines)))
        (should (string-suffix-p (concat "exec " (shell-quote-argument (expand-file-name "bin/drgnx" drgnx-dir)) " open") (car lines)))
        (should (eq (plist-get (alist-get 'finish (drgnx-onboard-state)) :status) 'ok))   ; recorded before it quits
        ;; no: nothing runs; the result says how
        (setq asked nil answer nil lines nil quit 0)
        (let ((r (let ((noninteractive nil)) (drgnx-onboard--finish-step '(:interactive t)))))
          (should (= 1 (length asked)))
          (should-not lines)
          (should (= quit 0))
          (should (string-search "Quit drgnx (⌘Q on a Mac) and open it again to load your modules" (cadr r))))
        ;; batch (drgnx onboard) or without interaction: never asked
        (setq asked nil)
        (drgnx-onboard--finish-step '(:interactive t))
        (drgnx-onboard--finish-step '(:interactive nil))
        (should-not asked)
        ;; nothing new to load: not asked
        (setq drgnx-onboard--restart-needed nil)
        (let ((noninteractive nil)) (drgnx-onboard--finish-step '(:interactive t)))
        (should-not asked)
        (should-not lines)
        ;; on a Mac it says how to open drgnx next time (Linux: not)
        (should-not (string-search "Spotlight" (cadr (drgnx-onboard--finish-step '(:interactive nil)))))
        (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
          (let ((drgnx-macos-app-dir (file-name-as-directory (make-temp-file "drgnx-apps" t))))
            (unwind-protect
                (progn
                  (make-directory (expand-file-name "drgnx.app" drgnx-macos-app-dir))
                  (should (string-search "next time open drgnx with Spotlight (⌘Space, type \"drgnx\") or Launchpad"
                                         (cadr (drgnx-onboard--finish-step '(:interactive nil))))))
              (delete-directory drgnx-macos-app-dir t))))))))

(ert-deftest drgnx-onboard/finish-names-spotlight-only-with-the-app ()
  ;; M12a-76: Spotlight finds drgnx.app; without the app the sentence would send you to a search that finds nothing
  (let ((drgnx-macos-app-dir (file-name-as-directory (make-temp-file "drgnx-apps" t))) (drgnx-onboard--restart-needed nil))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
          (should-not (string-search "Spotlight" (cadr (drgnx-onboard--finish-step '(:interactive nil)))))
          (make-directory (expand-file-name "drgnx.app" drgnx-macos-app-dir))
          (should (string-search "Spotlight" (cadr (drgnx-onboard--finish-step '(:interactive nil))))))
      (delete-directory drgnx-macos-app-dir t))))

(ert-deftest drgnx-onboard/the-agents-step-and-its-docs ()
  (should (string-match-p "Claude" (plist-get (alist-get 'agents drgnx-onboard--steps) :doc)))
  (should (eq (plist-get (alist-get 'agents drgnx-onboard--steps) :run) #'drgnx-onboard--agents-step)))

(defun drgnx-onboard-test--adapter-in-local-bin (root home)
  "Put the adapter where this Emacs's PATH does not reach: ROOT's tpl copy into HOME/.local/bin."
  (make-directory (concat home ".local/bin") t)
  (copy-file (concat root "tpl/claude-agent-acp") (concat home ".local/bin/claude-agent-acp") t)
  (set-file-modes (concat home ".local/bin/claude-agent-acp") #o755)
  (concat home ".local/bin"))

(ert-deftest drgnx-ai-onboard/brew-dir-is-appended-to-path ()
  ;; A directory onboarding finds a tool in goes behind the PATH you have, never in front of a program you chose.
  (drgnx-onboard-test--claude 'macos
    (let ((dir (drgnx-onboard-test--adapter-in-local-bin root home)))
      (should (equal (drgnx-onboard--on-path 'claude-agent-acp) dir))
      (should (equal (car exec-path) bin))
      (should (equal (car (last exec-path)) dir))
      (should (equal (getenv "PATH") (concat bin path-separator dir))))))

(require 'drgnx-hub)                    ; so a stub of `drgnx-hub-running-p' is not replaced by the load

(ert-deftest drgnx-ai-onboard/path-added-with-a-hub-says-hub-stop ()
  ;; The hub keeps the PATH it started with: when the step added a directory and a hub runs, the result says so.
  (drgnx-onboard-test--claude 'macos
    (drgnx-onboard-test--have bin "claude")
    (write-region "" nil (concat home ".logged-in"))
    (drgnx-onboard-test--adapter-in-local-bin root home)
    (cl-letf (((symbol-function 'drgnx-hub-running-p) (lambda () t)))
      (let ((r (drgnx-onboard--agents-step '(:interactive nil))))
        (should (eq (car r) 'ok))
        (should (string-match-p "the hub keeps its old PATH: drgnx hub stop" (cadr r)))))
    ;; no hub: no word of it; nothing added (the directory is on the PATH now): no word either
    (setq exec-path (list bin) process-environment (cons (concat "PATH=" bin) process-environment))
    (cl-letf (((symbol-function 'drgnx-hub-running-p) (lambda () nil)))
      (should-not (string-match-p "hub" (cadr (drgnx-onboard--agents-step '(:interactive nil))))))
    (cl-letf (((symbol-function 'drgnx-hub-running-p) (lambda () t)))
      (setq exec-path (list bin (concat home ".local/bin")))
      (setenv "PATH" (concat bin path-separator home ".local/bin"))
      (should-not (string-match-p "hub" (cadr (drgnx-onboard--agents-step '(:interactive nil))))))))

(ert-deftest drgnx-ai-onboard/the-install-question-explains-the-vs-code-claude ()
  ;; The install question says why a claude inside a VS Code extension does not count, only when claude is missing.
  (drgnx-onboard-test--claude 'macos
    (let ((asked (drgnx-onboard-test--asked '(("\\`Set up Claude Code" . nil)))))
      (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))
      (should (string-match-p "VS Code extension.*does not count" (car (car (cdr asked)))))
      (should (string-match-p "brew install --cask claude-code" (car (car (cdr asked))))))
    ;; claude there, the adapter missing: no word of VS Code
    (drgnx-onboard-test--have bin "claude" "npm")
    (let ((asked (drgnx-onboard-test--asked '(("\\`Set up Claude Code" . nil)))))
      (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))
      (should-not (string-match-p "VS Code" (car (car (cdr asked))))))))

;; M12a-48, -49, -50: the Agents step's smaller corners

(ert-deftest drgnx-ai-onboard/quit-during-auth-status-kills-it ()
  ;; C-g while `claude auth status' is being waited for leaves nothing running, and quits on
  (drgnx-onboard-test--claude 'macos
    (drgnx-onboard-test--script (concat bin "slow-claude") "exec sleep 30\n")
    (cl-letf (((symbol-function 'drgnx-onboard--wait) (lambda (&rest _) (signal 'quit nil))))
      (should (eq 'quit (condition-case nil (drgnx-onboard--claude-login-state (concat bin "slow-claude")) (quit 'quit)))))
    (should-not (seq-some (lambda (p) (and (string-prefix-p "drgnx-claude-auth" (process-name p)) (process-live-p p))) (process-list)))))

(ert-deftest drgnx-ai-onboard/non-homebrew-npm-on-macos-uses-local-prefix ()
  ;; A Node that is not Homebrew's has a global directory that is not yours (EACCES): the adapter goes to ~/.local
  (drgnx-onboard-test--claude 'macos
    (let ((other (concat root "other/")))
      (drgnx-onboard-test--have bin "claude")
      (write-region "" nil (concat home ".logged-in"))
      (make-directory other t)
      (copy-file (concat tpl "npm") (concat other "npm") t)
      (setq exec-path (list bin other))
      (setenv "PATH" (concat bin path-separator other))
      (let* ((asked (drgnx-onboard-test--asked '(("\\`Set up Claude Code" . t))))
             (r (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))))
        (should (string-match-p "npm install -g --prefix ~/.local @agentclientprotocol/claude-agent-acp" (car (car (cdr asked)))))
        (should (eq (car r) 'ok)))
      (should (string-match-p (format "npm install -g --prefix %s.local @agentclientprotocol/claude-agent-acp" home)
                              (drgnx-onboard-test--slurp calls)))
      (should (file-executable-p (concat home ".local/bin/claude-agent-acp"))))))

(ert-deftest drgnx-ai-onboard/failed-claude-installer-names-the-command ()
  ;; A failed Linux installer run ends with the command to try in a terminal, as the adapter's does
  (drgnx-onboard-test--claude 'linux
    (drgnx-onboard-test--script (concat bin "curl") "echo 'echo installer broke; exit 7'\n")
    (let* ((asked (drgnx-onboard-test--asked '(("\\`Set up Claude Code" . t))))
           (r (cl-letf (((symbol-function 'y-or-n-p) (car asked))) (drgnx-onboard--agents-step '(:interactive t)))))
      (should (eq (car r) 'fail))
      (should (string-match-p "or in a terminal: curl -fsSL https://claude.ai/install.sh | bash" (cadr r))))))

;; M6-1: the Agents step offers the MCP servers agents get and a default profile

(defun drgnx-onboard-test--offers-answers (profile coordination search)
  "Stubs for the questions: (COMPLETING-READ-STUB . Y-OR-N-STUB) answering PROFILE, COORDINATION and SEARCH; they
record the prompts and the default in the lists they return as the cars of (PROMPTS . DEFAULTS)."
  (let ((prompts (list nil)) (defaults (list nil)))
    (list (lambda (prompt _choices &optional _p _r _i _h def &rest _) (push prompt (car prompts)) (push def (car defaults)) profile)
          (lambda (prompt) (push prompt (car prompts)) (if (string-match-p "search" prompt) search coordination))
          prompts defaults)))

(ert-deftest drgnx-ai-onboard/agents-offer-mcp-servers-and-a-default-profile ()
  (drgnx-onboard-test--claude 'macos
    (drgnx-onboard-test--installed
     (write-region "" nil (concat home ".logged-in"))
     (let* ((a (drgnx-onboard-test--offers-answers "claude (Ollama)" t t))
            (file (expand-file-name "agents.eld" (drgnx-user-dir)))
            (r (cl-letf (((symbol-function 'drgnx-onboard--agents-offers) drgnx-onboard-test--offers)
                         ((symbol-function 'completing-read) (nth 0 a)) ((symbol-function 'y-or-n-p) (nth 1 a)))
                 (drgnx-onboard--agents-step '(:interactive t)))))
       (should (eq (car r) 'ok))
       (should (string-match-p "default agent profile: claude (Ollama)" (cadr r)))
       (should (string-match-p "coordination, search" (cadr r)))
       (should (equal (car (car (nth 3 a))) "claude"))        ; Return alone: the built-in claude profile
       (let ((saved (drgnx-onboard-test--read file)))
         (should (equal (plist-get saved :default) "claude (Ollama)"))
         (should (equal (plist-get saved :mcp) '(coordination search))))
       (should (equal (drgnx-agents-default-profile) "claude (Ollama)"))
       ;; the next run offers what was chosen
       (let ((b (drgnx-onboard-test--offers-answers "claude (Ollama)" t nil)))
         (cl-letf (((symbol-function 'drgnx-onboard--agents-offers) drgnx-onboard-test--offers)
                   ((symbol-function 'completing-read) (nth 0 b)) ((symbol-function 'y-or-n-p) (nth 1 b)))
           (should (string-match-p "tools for agents: coordination\\'" (cadr (drgnx-onboard--agents-step '(:interactive t))))))
         (should (equal (car (car (nth 3 b))) "claude (Ollama)")))
       ;; the sessions started now get both servers; one agent, one search server for its own project
       (let ((s (drgnx-agents--make :id "s1" :name "s1" :cwd root)))
         (should (equal (mapcar (lambda (e) (plist-get e :name)) (drgnx-agents--mcp-servers s)) '("drgnx")))
         (drgnx-agents-set-setting :mcp '(coordination search))
         (let ((servers (drgnx-agents--mcp-servers s)))
           (should (equal (mapcar (lambda (e) (plist-get e :name)) servers) '("drgnx" "drgnx-search")))
           (should (equal (aref (plist-get (aref servers 1) :args) (1- (length (plist-get (aref servers 1) :args))))
                          (directory-file-name root)))))))))

(ert-deftest drgnx-ai-onboard/agent-defaults-are-never-asked-without-interaction ()
  (drgnx-onboard-test--claude 'macos
    (drgnx-onboard-test--installed
     (write-region "" nil (concat home ".logged-in"))
     (cl-letf (((symbol-function 'drgnx-onboard--agents-offers) drgnx-onboard-test--offers)
               ((symbol-function 'completing-read) (lambda (&rest _) (error "asked")))
               ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "asked"))))
       (let ((r (drgnx-onboard--agents-step '(:interactive nil))))
         (should (eq (car r) 'ok))
         (should-not (string-match-p "default agent profile" (cadr r)))))
     (should-not (file-exists-p (expand-file-name "agents.eld" (drgnx-user-dir))))
     ;; and the servers stay as before: the coordination tools only
     (should (equal (drgnx-agents-mcp-names) '(coordination)))
     (should (equal (drgnx-agents-default-profile) "claude")))))

(ert-deftest drgnx-ai-onboard/agent-defaults-keep-the-rest-of-agents-eld ()
  (drgnx-onboard-test--claude 'macos
    (let ((file (expand-file-name "agents.eld" (drgnx-user-dir))) (a (drgnx-onboard-test--offers-answers "mine" nil nil)))
      (write-region ";; my agents\n(:profiles ((\"mine\" :command (\"x\"))) :routes nil)\n" nil file nil 'silent)
      (cl-letf (((symbol-function 'completing-read) (nth 0 a)) ((symbol-function 'y-or-n-p) (nth 1 a)))
        (should (string-match-p "tools for agents: none" (funcall drgnx-onboard-test--offers))))
      (let ((text (drgnx-onboard-test--slurp file)))
        (should (string-prefix-p ";; my agents" text))
        (let ((saved (drgnx-onboard-test--read file)))
          (should (equal (plist-get saved :default) "mine"))
          (should (plist-member saved :mcp))
          (should-not (plist-get saved :mcp))
          (should (equal (plist-get saved :profiles) '(("mine" :command ("x")))))
          (should (plist-member saved :routes))))
      (should (equal (drgnx-agents--mcp-servers (drgnx-agents--make :id "s1" :name "s1" :cwd root)) []))
      ;; a file that cannot be read is not touched; the result says so
      (write-region "(:profiles" nil file nil 'silent)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "claude")) ((symbol-function 'y-or-n-p) (nth 1 a)))
        (should (string-match-p "agents.eld has a mistake" (funcall drgnx-onboard-test--offers))))
      (should (equal (drgnx-onboard-test--slurp file) "(:profiles")))))

;;;; Task 19: onboarding.eld on the config layer

(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)

(defun drgnx-onboard-test--bytes (file)
  "FILE's bytes as a unibyte string, nil when missing."
  (when (file-exists-p file)
    (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string))))

(defun drgnx-onboard-test--baks ()
  "The backups of onboarding.eld."
  (directory-files (drgnx-state-dir) t "\\`onboarding\\.eld\\.bak-"))

(defun drgnx-onboard-test--children (forms)
  "Run each of FORMS (strings) in a child `emacs --batch' with this run's environment; wait for all (30 s bound)."
  (let* ((at (+ (float-time) 2)) (bufs nil)
         (procs (mapcar
                 (lambda (form)
                   (let ((b (generate-new-buffer " *onboard-child*" t)))
                     (push b bufs)
                     (make-process
                      :name "onboard-child" :buffer b :noquery t
                      :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                     "--eval" (format "(setq load-path '%S load-prefer-newer t)" load-path)
                                     "--eval" "(require 'drgnx-onboard)"
                                     "--eval" (format "(progn (sleep-for (max 0 (- %f (float-time)))) %s)" at form)))))
                 forms))
         (deadline (+ (float-time) 30)))
    (unwind-protect
        (progn
          (while (and (cl-some #'process-live-p procs) (< (float-time) deadline)) (accept-process-output nil 0.05))
          (dolist (p procs) (should (not (process-live-p p))))
          (cl-loop for p in procs for b in (reverse bufs)
                   do (should (equal (list (process-exit-status p) (with-current-buffer b (buffer-string)))
                                     (list 0 (with-current-buffer b (buffer-string)))))))
      (mapc #'delete-process procs)
      (mapc #'kill-buffer bufs))))

(ert-deftest drgnx-onboard/the-definition ()
  (drgnx-test-with-config
    (should (drgnx-config-defined-p 'onboarding))
    (let ((def (drgnx-config-definition 'onboarding)))
      (should (equal (plist-get def :file) "onboarding.eld"))
      (should (eq (plist-get def :dir) 'state))
      (should (eq (plist-get def :shape) 'alist)))
    (should (equal (drgnx-onboard-state-file) (drgnx-config-file 'onboarding)))
    (should-not (drgnx-onboard-state))))

(ert-deftest drgnx-onboard/an-older-file-keeps-working-and-keeps-its-steps ()
  ;; The form every earlier drgnx wrote: one line of `prin1', no header, a step with a nil message.
  (drgnx-test-with-config
    (drgnx-test-config-put 'onboarding
                           "((environment :status ok :message \"fine\" :time \"2026-10-01T10:00:00+0000\") (ai :status warn :message nil :time \"2026-10-01T10:01:00+0000\"))")
    (should (eq (plist-get (alist-get 'environment (drgnx-onboard-state)) :status) 'ok))
    (should-not (drgnx-config-problem 'onboarding))
    (drgnx-onboard--record 'projects 'info "none")
    (let ((state (drgnx-onboard-state)))
      (should (equal (mapcar #'car state) '(environment ai projects)))
      (should (equal (plist-get (alist-get 'environment state) :message) "fine"))
      (should (eq (plist-get (alist-get 'ai state) :status) 'warn))
      (should (equal (plist-get (alist-get 'projects state) :message) "none")))
    (should-not (drgnx-onboard-test--baks))))

(ert-deftest drgnx-onboard/record-replaces-its-step-and-keeps-other-entries-and-keys ()
  (drgnx-test-with-config
    (drgnx-test-config-put 'onboarding
                           "((a :status ok :message \"x\" :time \"t\" :extra 7) (b :status fail :message \"y\" :time \"t\"))")
    (drgnx-onboard--record 'b 'ok "fixed")
    (let ((state (drgnx-onboard-state)))
      (should (equal (mapcar #'car state) '(a b)))
      (should (equal (plist-get (alist-get 'a state) :extra) 7))
      (should (eq (plist-get (alist-get 'b state) :status) 'ok))
      (should (equal (plist-get (alist-get 'b state) :message) "fixed"))
      (should (stringp (plist-get (alist-get 'b state) :time))))
    (should-not (drgnx-config-problem 'onboarding))))

(ert-deftest drgnx-onboard/a-new-file-has-the-header-and-reads-back ()
  (drgnx-test-with-config
    (drgnx-onboard--record 'a 'ok "one")
    (should (string-prefix-p ";;" (drgnx-test-config-text 'onboarding)))
    (should (equal (mapcar #'car (drgnx-config-reread 'onboarding)) '(a)))))

(ert-deftest drgnx-onboard/two-processes-record-different-steps-both-kept ()
  (drgnx-test-with-config
    (drgnx-onboard--record 'seed 'ok "seed")
    (drgnx-onboard-test--children
     (list "(drgnx-onboard--record 'one 'ok \"from one\")"
           "(drgnx-onboard--record 'two 'warn \"from two\")"
           "(drgnx-onboard--record 'three 'info \"from three\")"))
    (let ((state (drgnx-config-reread 'onboarding)))
      (should (equal (sort (mapcar #'car state) (lambda (a b) (string< a b))) '(one seed three two)))
      (should (equal (plist-get (alist-get 'two state) :message) "from two"))
      (should (eq (plist-get (alist-get 'three state) :status) 'info)))
    (should-not (drgnx-onboard-test--baks))))

(ert-deftest drgnx-onboard/an-unreadable-state-is-backed-up ()
  (drgnx-test-with-config
    (let* ((bad "((environment :status ok :message \"half")
           (file (drgnx-test-config-put 'onboarding bad)))
      (should (drgnx-config-problem 'onboarding))
      (should-not (drgnx-onboard-state))                    ; reading tolerates it: nothing is done
      (drgnx-onboard--record 'environment 'ok "again")
      (let ((baks (drgnx-onboard-test--baks)))
        (should (= (length baks) 1))
        (should (equal (drgnx-onboard-test--bytes (car baks)) bad)))   ; the user's bytes, kept
      (should (eq (plist-get (alist-get 'environment (drgnx-onboard-state)) :status) 'ok))
      (should-not (drgnx-config-problem 'onboarding))
      (should (file-exists-p file)))))

(ert-deftest drgnx-onboard/write-state-writes-the-state-whole-and-nil-leaves-an-empty-file ()
  (drgnx-test-with-config
    (drgnx-onboard--write-state nil)
    (should (file-exists-p (drgnx-onboard-state-file)))
    (should-not (drgnx-onboard-state))
    (should-not (drgnx-config-problem 'onboarding))
    (drgnx-onboard--write-state '((a :status ok :message "m" :time "t")))
    (should (equal (drgnx-config-reread 'onboarding) '((a :status ok :message "m" :time "t"))))))

(ert-deftest drgnx-onboard/an-unreadable-file-is-never-written-by-a-read ()
  ;; Reading (the Welcome, the doctor, resume) writes nothing, whatever the file holds.
  (drgnx-test-with-config
    (let* ((bad "(this is not an alist")
           (file (drgnx-test-config-put 'onboarding bad)))
      (drgnx-onboard-state) (drgnx-onboard--welcome-due-p) (drgnx-onboard-run :only '(no-such-step) :non-interactive t)
      (should (equal (drgnx-onboard-test--bytes file) bad))
      (should-not (drgnx-onboard-test--baks)))))

(ert-deftest drgnx-onboard/the-doctor-and-the-reference-know-onboarding ()
  (should (memq 'drgnx-onboard drgnx-doctor-config-features))
  (should (member '(require drgnx-onboard) drgnx-config-doc-sources)))

;;; onboard-test.el ends here
