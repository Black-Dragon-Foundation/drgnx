;;; shell-rc-test.el --- batch tests: the rc line, `drgnx shell install', onboarding step 7 -*- lexical-binding: t -*-
;; Every test runs with a temp HOME (and ZDOTDIR, XDG_CONFIG_HOME): never the user's rc files.  The zsh test runs
;; `zsh -f' with that HOME; it skips when zsh is not installed.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx)
(require 'drgnx-shell)
(require 'drgnx-onboard)

(defmacro drgnx-shell-rc-test--with (home &rest body)
  "BODY with HOME a temp directory that is HOME; ZDOTDIR and XDG_CONFIG_HOME are unset, SHELL is zsh."
  (declare (indent 1))
  `(let* ((,home (file-name-as-directory (make-temp-file "drgnx-shell-rc" t)))
          (process-environment
           (append (list (concat "HOME=" ,home) "SHELL=/usr/bin/zsh"
                         (concat "DRGNX_CONFIG_DIR=" ,home "config")
                         (concat "XDG_STATE_HOME=" ,home "state")
                         (concat "DRGNX_DATA_DIR=" ,home "data"))
                   (seq-remove (lambda (e) (string-match-p "\\`\\(HOME\\|SHELL\\|ZDOTDIR\\|XDG_CONFIG_HOME\\|DRGNX_CONFIG_DIR\\|XDG_STATE_HOME\\|DRGNX_DATA_DIR\\)=" e))
                               process-environment)))
          (drgnx-modules--state nil))
     (unwind-protect (progn ,@body) (delete-directory ,home t))))

(defun drgnx-shell-rc-test--read (file)
  "The text of FILE, or nil when it is not there."
  (when (file-exists-p file)
    (with-temp-buffer (insert-file-contents file) (buffer-string))))

(defun drgnx-shell-rc-test--write (file text)
  "Write TEXT to FILE (its directory is made)."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text)))

(defun drgnx-shell-rc-test--yes ()
  "An ASK function that says yes."
  (lambda (_q) t))

;;;; The pieces

(ert-deftest drgnx-shell-rc/name-and-rc-file-and-line ()
  (drgnx-shell-rc-test--with home
    (should (eq (drgnx-shell-name "/usr/bin/zsh") 'zsh))
    (should (eq (drgnx-shell-name "/bin/bash") 'bash))
    (should (eq (drgnx-shell-name "/opt/homebrew/bin/fish") 'fish))
    (should-not (drgnx-shell-name "/bin/sh"))
    (should-not (drgnx-shell-name ""))
    (should (eq (drgnx-shell-name) 'zsh))   ; $SHELL
    (should (equal (drgnx-shell-rc-file 'zsh) (concat home ".zshrc")))
    (should (equal (drgnx-shell-rc-file 'bash) (concat home ".bashrc")))
    (should (equal (drgnx-shell-rc-file 'fish) (concat home ".config/fish/config.fish")))
    ;; the checkout under HOME is written ~/-relative
    (let ((drgnx-dir (concat home "ws/drgnx/")))
      (should (equal (drgnx-shell-line 'zsh) "[ -r ~/ws/drgnx/etc/shell/drgnx.zsh ] && source ~/ws/drgnx/etc/shell/drgnx.zsh || true"))
      (should (equal (drgnx-shell-line 'bash) "[ -r ~/ws/drgnx/etc/shell/drgnx.bash ] && source ~/ws/drgnx/etc/shell/drgnx.bash || true")))
    ;; elsewhere, absolute; a space is quoted
    (let ((drgnx-dir "/opt/my drgnx/"))
      (should (string-search "/opt/my\\ drgnx/etc/shell/drgnx.zsh" (drgnx-shell-line 'zsh)))
      (should-not (string-search "~" (drgnx-shell-line 'zsh))))))

(ert-deftest drgnx-shell-rc/zdotdir-and-xdg-are-honoured ()
  (drgnx-shell-rc-test--with home
    (let ((process-environment (append (list (concat "ZDOTDIR=" home "zd") (concat "XDG_CONFIG_HOME=" home "xdg")) process-environment)))
      (should (equal (drgnx-shell-rc-file 'zsh) (concat home "zd/.zshrc")))
      (should (equal (drgnx-shell-rc-file 'fish) (concat home "xdg/fish/config.fish")))
      (should (equal (drgnx-shell-rc-file 'bash) (concat home ".bashrc")))   ; bash ignores both
      ;; the line goes where the shell reads it, and the directory is made
      (should (eq (drgnx-shell-install 'fish :ask (drgnx-shell-rc-test--yes)) 'added))
      (should (string-search "source" (drgnx-shell-rc-test--read (concat home "xdg/fish/config.fish"))))
      (should-not (file-exists-p (concat home ".config")))
      (should (eq (drgnx-shell-install 'zsh :ask (drgnx-shell-rc-test--yes)) 'added))
      (should (file-exists-p (concat home "zd/.zshrc")))
      (should-not (file-exists-p (concat home ".zshrc"))))))

(ert-deftest drgnx-shell-rc/fish-line-is-fish ()
  (drgnx-shell-rc-test--with home
    (let ((drgnx-dir (concat home "ws/drgnx/")))
      (should (equal (drgnx-shell-line 'fish)
                     "test -r ~/ws/drgnx/etc/shell/drgnx.fish; and source ~/ws/drgnx/etc/shell/drgnx.fish; or true"))
      (should-not (string-search "&&" (drgnx-shell-line 'fish))))))

(ert-deftest drgnx-shell-rc/present-means-an-uncommented-line-naming-the-file ()
  (drgnx-shell-rc-test--with home
    (let ((rc (drgnx-shell-rc-file 'zsh)))
      (should-not (drgnx-shell-line-present-p 'zsh))            ; no file
      (drgnx-shell-rc-test--write rc "export A=1\n")
      (should-not (drgnx-shell-line-present-p 'zsh))
      (drgnx-shell-rc-test--write rc "# source ~/x/drgnx/etc/shell/drgnx.zsh\n  # [ -r y/etc/shell/drgnx.zsh ] && source y\n")
      (should-not (drgnx-shell-line-present-p 'zsh))            ; only comments
      (drgnx-shell-rc-test--write rc "source ~/old/drgnx/etc/shell/drgnx.zsh\n")
      (should (drgnx-shell-line-present-p 'zsh))                ; another path of the same file counts
      (should-not (drgnx-shell-line-present-p 'bash)))))

;;;; Install

(ert-deftest drgnx-shell-rc/adds-the-line-once-when-asked ()
  (drgnx-shell-rc-test--with home
    (let ((rc (drgnx-shell-rc-file 'zsh)) (questions nil))
      (drgnx-shell-rc-test--write rc "export A=1\n")
      (should (eq (drgnx-shell-install 'zsh :ask (lambda (q) (push q questions) t)) 'added))
      (should (equal (drgnx-shell-rc-test--read rc)
                     (concat "export A=1\n\n# added by drgnx (docs/guide/shell.md)\n" (drgnx-shell-line 'zsh) "\n")))
      (should (= 1 (length questions)))
      (should (string-prefix-p "Add this line to " (car questions)))
      (should (string-search (drgnx-shell-line 'zsh) (car questions)))
      (should (drgnx-shell-line-present-p 'zsh))
      ;; again: nothing asked, nothing changed
      (let ((before (drgnx-shell-rc-test--read rc)))
        (should (eq (drgnx-shell-install 'zsh :ask (lambda (_) (error "asked again"))) 'present))
        (should (equal (drgnx-shell-rc-test--read rc) before))))))

(ert-deftest drgnx-shell-rc/no-answer-no-change ()
  (drgnx-shell-rc-test--with home
    (let ((rc (drgnx-shell-rc-file 'zsh)))
      (drgnx-shell-rc-test--write rc "export A=1\n")
      (should (eq (drgnx-shell-install 'zsh :ask (lambda (_) nil)) 'declined))
      (should (equal (drgnx-shell-rc-test--read rc) "export A=1\n"))
      ;; no ASK at all (--yes, no terminal): the line on stdout, the file untouched
      (let* ((result nil)
             (out (with-output-to-string (setq result (drgnx-shell-install 'zsh)))))
        (should (eq result 'printed))
        (should (string-search (drgnx-shell-line 'zsh) out))
        (should (string-search "~/.zshrc" out)))
      (should (equal (drgnx-shell-rc-test--read rc) "export A=1\n"))
      ;; and with no rc file at all: still not created
      (delete-file rc)
      (with-output-to-string (drgnx-shell-install 'zsh))
      (should-not (file-exists-p rc)))))

(ert-deftest drgnx-shell-rc/a-symlinked-rc-is-named-before-it-is-changed ()
  (drgnx-shell-rc-test--with home
    (let ((rc (drgnx-shell-rc-file 'zsh)) (target (concat home "dotfiles/zshrc")) (questions nil))
      (drgnx-shell-rc-test--write target "export A=1\n")
      (make-symbolic-link "dotfiles/zshrc" rc)
      (should (eq (drgnx-shell-install 'zsh :ask (lambda (q) (push q questions) t)) 'added))
      (should (= 1 (length questions)))
      (should (string-search ".zshrc" (car questions)))
      (should (string-search "dotfiles/zshrc" (car questions)))
      (should (string-search "→" (car questions)))
      (should (file-symlink-p rc))                              ; still a link
      (should (string-search (drgnx-shell-line 'zsh) (drgnx-shell-rc-test--read target)))
      (should (drgnx-shell-line-present-p 'zsh))
      ;; a plain file is named alone
      (delete-file rc)
      (setq questions nil)
      (drgnx-shell-install 'zsh :ask (lambda (q) (push q questions) t))
      (should-not (string-search "→" (car questions))))))

(ert-deftest drgnx-shell-rc/the-line-sources-cleanly ()
  (skip-unless (executable-find "zsh"))
  (drgnx-shell-rc-test--with home
    (let* ((real-file (expand-file-name "etc/shell/drgnx.zsh" drgnx-dir))
           (checkout (concat home "ws/drgnx/"))
           (drgnx-dir checkout)
           (rc (drgnx-shell-rc-file 'zsh))
           (run (lambda ()
                  (with-temp-buffer
                    (let ((exit (call-process "zsh" nil t nil "-f" "-c" (concat "source " (shell-quote-argument rc)))))
                      (list exit (buffer-string)))))))
      ;; a copy of the real file stands for the checkout
      (make-directory (concat checkout "etc/shell") t)
      (copy-file real-file (concat checkout "etc/shell/drgnx.zsh"))
      (should (eq (drgnx-shell-install 'zsh :ask (drgnx-shell-rc-test--yes)) 'added))
      (should (equal (funcall run) '(0 "")))
      ;; the checkout moved away: the -r guard keeps the shell quiet and the status 0
      (rename-file (concat home "ws") (concat home "ws-gone"))
      (should (equal (funcall run) '(0 ""))))))

;;;; The command line

(ert-deftest drgnx-shell-rc/cli-yes-prints-never-writes ()
  (drgnx-shell-rc-test--with home
    (let ((rc (drgnx-shell-rc-file 'zsh)) code)
      (let ((out (with-output-to-string (setq code (drgnx-shell-cli-run '("install" "--shell" "zsh" "--yes"))))))
        (should (eql code 0))
        (should (string-search (drgnx-shell-line 'zsh) out)))
      (should-not (file-exists-p rc))
      ;; $SHELL is the default shell
      (let ((out (with-output-to-string (setq code (drgnx-shell-cli-run '("install" "--yes"))))))
        (should (eql code 0))
        (should (string-search "drgnx.zsh" out)))
      (should-not (file-exists-p rc))
      ;; the other shells
      (let ((out (with-output-to-string (setq code (drgnx-shell-cli-run '("install" "--shell" "fish" "--yes"))))))
        (should (eql code 0))
        (should (string-search "drgnx.fish" out)))
      (should-not (file-exists-p (drgnx-shell-rc-file 'fish)))
      ;; already there: said so, exit 0
      (drgnx-shell-install 'zsh :ask (drgnx-shell-rc-test--yes))
      (let ((out (with-output-to-string (setq code (drgnx-shell-cli-run '("install" "--yes"))))))
        (should (eql code 0))
        (should (string-search "already" out))))))

(ert-deftest drgnx-shell-rc/cli-line-prints-only-the-line ()
  (drgnx-shell-rc-test--with home
    (let (code)
      (let ((out (with-output-to-string (setq code (drgnx-shell-cli-run '("line" "--shell" "bash"))))))
        (should (eql code 0))
        (should (equal out (concat (drgnx-shell-line 'bash) "\n"))))
      (should-not (file-exists-p (drgnx-shell-rc-file 'bash))))))

(ert-deftest drgnx-shell-rc/cli-usage-errors-and-unknown-shells ()
  (drgnx-shell-rc-test--with home
    (dolist (args '(nil ("bogus") ("install" "--nope") ("install" "--shell") ("line" "extra")))
      (let (code)
        (with-output-to-string (setq code (drgnx-shell-cli-run args)))
        (should (equal (list args code) (list args 2)))))
    (let (code)
      (with-output-to-string (setq code (drgnx-shell-cli-run '("install" "--shell" "tcsh" "--yes"))))
      (should (eql code 1))
      (let ((process-environment (cons "SHELL=/bin/sh" process-environment)))
        (with-output-to-string (setq code (drgnx-shell-cli-run '("install" "--yes"))))
        (should (eql code 1)))
      (should-not (file-exists-p (drgnx-shell-rc-file 'zsh))))))

;;;; Onboarding step 7

(ert-deftest drgnx-shell-rc/step-7-says-the-shell-part ()
  (drgnx-shell-rc-test--with home
    (let ((rc (drgnx-shell-rc-file 'zsh)) (questions nil))
      ;; the part itself, without interaction: the line to add
      (let ((msg (drgnx-onboard--shell-part nil)))
        (should (string-search (drgnx-shell-line 'zsh) msg))
        (should (string-search "~/.zshrc" msg)))
      (should-not (file-exists-p rc))
      ;; step 7 as a whole, non-interactive: the message ends with it, the file stays unwritten
      (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
        (let ((r (car (drgnx-onboard-run :only '(daemon) :non-interactive t))))
          (should (string-search "; shell integration: " (nth 2 r)))
          (should (string-search (drgnx-shell-line 'zsh) (nth 2 r)))
          ;; after the keep-running part and the platform part
          (should (< (string-search "keeps running" (nth 2 r)) (string-search "shell integration" (nth 2 r))))
          (should (< (string-search "systemctl" (nth 2 r)) (string-search "shell integration" (nth 2 r)))))
        (should-not (file-exists-p rc))
        ;; interactive, yes to every question
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (push q questions) t))
                  ((symbol-function 'call-process) (lambda (&rest _) 0)))
          (let ((r (car (drgnx-onboard-run :only '(daemon)))))
            (should (string-search "shell integration: added to " (nth 2 r)))))
        (should (seq-some (lambda (q) (string-prefix-p "Add this line to " q)) questions))
        (should (drgnx-shell-line-present-p 'zsh))
        ;; once the line is there: said so, no question
        (setq questions nil)
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (q) (push q questions) t))
                  ((symbol-function 'call-process) (lambda (&rest _) 0)))
          (let ((r (car (drgnx-onboard-run :only '(daemon)))))
            (should (string-search "shell integration: " (nth 2 r)))
            (should (string-search "already" (nth 2 r)))))
        (should-not (seq-some (lambda (q) (string-prefix-p "Add this line to " q)) questions))))))

(ert-deftest drgnx-shell-rc/step-7-without-a-known-shell-says-so ()
  (drgnx-shell-rc-test--with home
    (let ((process-environment (cons "SHELL=/bin/sh" process-environment)))
      (let ((msg (drgnx-onboard--shell-part nil)))
        (should (string-search "zsh, bash and fish" msg))))))

(provide 'shell-rc-test)
;;; shell-rc-test.el ends here
