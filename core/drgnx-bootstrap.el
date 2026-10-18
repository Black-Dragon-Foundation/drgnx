;;; drgnx-bootstrap.el --- drgnx bootstrap: this machine set up from your configuration -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx bootstrap' sets a second machine up from the user's configuration (docs/guide/second-machine.md, "One
;; command"): preflight → config (cloned into an empty config dir, never over another one) → keys (secrets.age into
;; the keyring) → sync (the config's lock) → onboard (non-interactive: it records) → desktop (asked) → shell (asked)
;; → doctor (green).  Each step ends `ok' (nothing to do), `changed', `skipped' or `failed'; a second run changes
;; nothing.  A failed preflight, config or sync stops the steps after it; --dry-run changes nothing at all.
;;
;; It is batch Emacs on the user's terminal: questions are asked there, and only what --yes confirms (the announced
;; age/chezmoi install, the key import, chezmoi init) goes ahead without one; the rc line, the desktop entry and
;; chezmoi apply never do.  A program Emacs starts has no terminal (Emacs gives every child a session of its own),
;; so what needs one — sudo's password for the announced install, age's passphrase — is handed back to bin/drgnx
;; (`drgnx-bootstrap--on-terminal'): the run stops with exit 10, the command in DIR/argv and the run's answers in
;; DIR/state.eld (DIR is DRGNX_BOOTSTRAP_HANDBACK); bin/drgnx runs the command, if it is one of the few it knows,
;; writes DIR/rc (and DIR/out), and runs bootstrap again, which goes on from that step with the same answers.
;; Nothing here runs by itself: no timer, no hook.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-portable)
(require 'drgnx-secrets)
(require 'drgnx-onboard)
(require 'drgnx-pkg)
(require 'drgnx-doctor)
(require 'drgnx-shell)

(defvar drgnx-macos-app-dir)

(defconst drgnx-bootstrap-steps '(preflight config keys sync onboard desktop shell doctor)
  "The steps of `drgnx bootstrap', in the order they run.")

(defconst drgnx-bootstrap--stopping '(preflight config sync)
  "The steps the ones after them depend on: when one fails, the rest are not run.")

(defvar drgnx-bootstrap-call-timeout 120
  "Seconds a program bootstrap runs (git, chezmoi) may take before it is stopped.")

(defvar drgnx-bootstrap-install-timeout 900
  "Seconds an install bootstrap runs from Emacs (Homebrew, chezmoi's own installer) may take.")

(defconst drgnx-bootstrap-diff-lines 200 "The most lines of `chezmoi diff' bootstrap shows.")

(defconst drgnx-bootstrap--git-env '("GIT_ALLOW_PROTOCOL=https:file" "GIT_TERMINAL_PROMPT=0")
  "The environment of every git (and chezmoi) bootstrap runs: https and local paths only, no password prompt.")

;;;; What the user passed

(defun drgnx-bootstrap--url-problem (value)
  "Why VALUE is not a configuration source bootstrap takes, or nil.  It takes an https URL with a host and no user
name or password, or an absolute path that exists.  The reason never shows VALUE (it may hold a password)."
  (cond ((not (stringp value)) "it is missing")
        ((string-match-p "[[:cntrl:]]" value) "it holds a control character")
        ((string-prefix-p "https://" value)
         (let ((authority (car (split-string (substring value 8) "/"))))
           (cond ((string-match-p "[[:space:]]" value) "a URL with a blank in it")
                 ((string-empty-p authority) "a URL with no host")
                 ((string-match-p "[@\\]" authority) "a URL with a user name or a password (use a git credential helper)"))))
        ((string-prefix-p "/" value) (unless (file-exists-p value) "a path that does not exist"))
        (t "not an https URL or an absolute path (not http, ssh, git@host:, file://, ext:: or a relative path)")))

(defun drgnx-bootstrap--identity-problem (file)
  "Why FILE is not an age identity file bootstrap passes to age, or nil: a readable regular file that only its
owner can read.  The file is never read."
  (cond ((string-match-p "[[:cntrl:]]" file) "--identity: the file name holds a control character")
        ((not (file-regular-p file)) (format "--identity: %s is not a file" (shell-quote-argument file)))
        ((not (file-readable-p file)) (format "--identity: %s cannot be read" (shell-quote-argument file)))
        ((/= 0 (logand (file-modes file) #o077))
         (format "--identity: %s can be read by other users: chmod 600 %s, then run this again"
                 (shell-quote-argument file) (shell-quote-argument file)))))

(defun drgnx-bootstrap--label (url)
  "URL as shown: a path as ~/…, a URL without its query and fragment."
  (if (string-prefix-p "/" url) (drgnx-portable-path url) (replace-regexp-in-string "[?#].*\\'" "" url)))

(defun drgnx-bootstrap--word (file)
  "FILE as one shell word: ~/ unquoted (the shell expands it), the rest quoted."
  (let ((f (drgnx-portable-path file)))
    (if (string-prefix-p "~/" f) (concat "~/" (shell-quote-argument (substring f 2))) (shell-quote-argument f))))

;;;; Running programs

(defun drgnx-bootstrap--call (program args &optional timeout env)
  "Run PROGRAM with ARGS — stdin empty, no terminal — for at most TIMEOUT seconds (default
`drgnx-bootstrap-call-timeout'); ENV: more \"VAR=VALUE\" strings.  (EXIT . OUTPUT), stdout and stderr trimmed;
\(timeout . TEXT) when it was stopped; nil when PROGRAM cannot run."
  (let ((limit (or timeout drgnx-bootstrap-call-timeout)))
    (with-temp-buffer
      (let* ((process-environment (append env process-environment))
             (proc (condition-case nil
                       (make-process :name "drgnx-bootstrap" :buffer (current-buffer) :command (cons program args)
                                     :connection-type 'pipe :noquery t :sentinel #'ignore)
                     (file-error nil)))
             (deadline (+ (float-time) limit)))
        (when proc
          (process-send-eof proc)
          (while (and (process-live-p proc) (< (float-time) deadline))
            (accept-process-output proc 0.05))
          (if (process-live-p proc)
              (progn (delete-process proc) (cons 'timeout (format "did not finish within %s s" limit)))
            (while (accept-process-output proc 0.01))
            (cons (process-exit-status proc) (string-trim (buffer-string)))))))))

(defun drgnx-bootstrap--git (&rest args)
  "git ARGS without the user's hooks, templates, fsmonitor or signing, over https or a local path only, bounded."
  (drgnx-bootstrap--call "git" (append '("-c" "protocol.ext.allow=never" "-c" "core.hooksPath=/dev/null"
                                         "-c" "core.fsmonitor=false" "-c" "commit.gpgsign=false")
                                       args)
                         nil drgnx-bootstrap--git-env))

(defun drgnx-bootstrap--why (r what)
  "What went wrong with call result R of WHAT, in one line."
  (cond ((null r) (format "%s cannot run" what))
        ((eq (car r) 'timeout) (format "%s %s" what (cdr r)))
        (t (format "%s failed: %s" what
                   (let ((line (car (last (split-string (cdr r) "\n" t)))))
                     (if line (truncate-string-to-width line 200) (format "exit %s" (car r))))))))

(defun drgnx-bootstrap--say (fmt &rest args)
  "Print FMT with ARGS and a newline."
  (princ (concat (apply #'format fmt args) "\n")))

;;;; Questions, and what needs the terminal

(defvar drgnx-bootstrap--answers nil "This run's answers, ((QUESTION . ANSWER)…): kept across a hand-back.")
(defvar drgnx-bootstrap--done nil "Commands run on the terminal, ((ARGV RC . OUTPUT)…): kept across a hand-back.")
(defvar drgnx-bootstrap--handback nil
  "Non-nil (the CLI, from DRGNX_BOOTSTRAP_HANDBACK): a command that needs the terminal stops the run, for bin/drgnx.")
(defvar drgnx-bootstrap--report nil "A function of each (STEP STATUS MESSAGE) as it is done (the CLI prints it).")

(define-error 'drgnx-bootstrap-handback "Needs the terminal")

(defun drgnx-bootstrap--ask (ask question)
  "ASK QUESTION (ASK a function of a question, or nil: no), once in a run: an answer given before a hand-back is
given again, not asked again."
  (let ((known (assoc question drgnx-bootstrap--answers)))
    (if known (cdr known)
      (let ((a (and ask (funcall ask question) t)))
        (push (cons question a) drgnx-bootstrap--answers)
        a))))

(defun drgnx-bootstrap--run-here (argv)
  "(RC . OUTPUT) of ARGV run from this Emacs (no terminal: sudo works only without a password); \"secrets …\" is
bin/drgnx secrets."
  (let* ((cmd (if (equal (car argv) "secrets") (cons (expand-file-name "bin/drgnx" drgnx-dir) argv) argv))
         (r (drgnx-bootstrap--call (car cmd) (cdr cmd) drgnx-bootstrap-install-timeout)))
    (cond ((null r) (cons 127 (format "%s cannot run" (car cmd))))
          ((eq (car r) 'timeout) (cons 124 (cdr r)))
          (t r))))

(defun drgnx-bootstrap--on-terminal (argv)
  "Run ARGV where the user's terminal is: (RC . OUTPUT).  In the CLI a command not run yet stops the run
\(`drgnx-bootstrap-handback'): bin/drgnx runs it and runs bootstrap again, which finds the result here.  Else it
runs from this Emacs (`drgnx-bootstrap--run-here')."
  (let ((done (assoc argv drgnx-bootstrap--done)))
    (cond (done (cdr done))
          (drgnx-bootstrap--handback (signal 'drgnx-bootstrap-handback (list argv)))
          (t (let ((r (drgnx-bootstrap--run-here argv)))
               (push (cons argv r) drgnx-bootstrap--done)
               r)))))

(cl-defun drgnx-bootstrap--install-tool (tool &key yes ask)
  "Install TOOL (`age' or `chezmoi', from `drgnx-onboard-install-recipes'), announced and confirmed: `ok' when its
program is there (already, or now), else (failed . HOW-OR-WHY).  Linux: the recipe's line for the package manager
found, printed \"As root: sudo dnf install -y age\" and run on the terminal, where sudo asks for the password; a
line without sudo (chezmoi's installer where Debian has no package) runs from here.  macOS: brew install.  YES
confirms; else ASK is asked; with neither nothing runs.  Never anything else as root."
  (let* ((r (alist-get tool drgnx-onboard-install-recipes))
         (name (plist-get r :name)))
    (if (drgnx-onboard--program tool) 'ok
      (let* ((macos (eq (drgnx-platform) 'macos))
             (brew (and macos (drgnx-onboard--brew)))
             (words (if macos (and brew (cons brew (cdr (plist-get (plist-get r :macos) :install))))
                      (let ((line (drgnx-onboard--linux-shell (plist-get r :linux))))
                        (and line (if (string-prefix-p "sudo " line) (split-string-and-unquote line) (list "sh" "-c" line))))))
             (root (equal (car words) "sudo"))
             (line (cond ((not words) nil)
                         (macos (string-join (cons "brew" (cdr words)) " "))
                         (root (string-join words " "))
                         (t (nth 2 words))))
             (shown (and line (format "%s %s" (if root "As root:" "Runs:") line))))
        (cond
         ((not words)
          (cons 'failed (if macos (format "install Homebrew (https://brew.sh), then: brew install %s" name)
                          (format "install %s with your package manager" name))))
         (t
          (unless (assoc words drgnx-bootstrap--done) (drgnx-bootstrap--say "%s" shown))
          (if (not (or yes (drgnx-bootstrap--ask ask (format "Install %s now (the line above%s)? " name
                                                             (if root "; sudo asks for your password" "")))))
              (cons 'failed shown)
            (let ((res (if root (drgnx-bootstrap--on-terminal words)
                         (drgnx-bootstrap--call (car words) (cdr words) drgnx-bootstrap-install-timeout))))
              (if (drgnx-onboard--program tool) 'ok
                (cons 'failed (format "%s did not install it (%s)" line
                                      (drgnx-bootstrap--why res (car words)))))))))))))

;;;; The steps — each a function of the run's context: (STATUS MESSAGE)

(defun drgnx-bootstrap--machine-local ()
  "The machine-local items the config dir holds (names)."
  (cl-remove-if-not (lambda (i) (file-exists-p (expand-file-name i (drgnx-user-dir)))) drgnx-portable-machine-local))

(defun drgnx-bootstrap--move ()
  "Move the config dir's machine-local items to the data dir: (MOVED KEPT), item names."
  (let ((moves (drgnx-portable-move-machine-local)))
    (list (mapcar (lambda (m) (directory-file-name (car m))) (cl-remove-if-not (lambda (m) (memq (cdr m) '(moved dropped))) moves))
          (mapcar (lambda (m) (directory-file-name (car m))) (cl-remove-if-not (lambda (m) (eq (cdr m) 'kept)) moves)))))

(defun drgnx-bootstrap--move-text (moved kept)
  (string-join (delq nil (list (and moved (format "moved to the data dir: %s" (string-join moved ", ")))
                               (and kept (format "%s stays in the config dir: the data dir has a different copy (compare them, then delete one)"
                                                 (string-join kept ", ")))))
               "; "))

(defun drgnx-bootstrap--preflight (ctx)
  "OS, git, age (when secrets.age is or may be part of the config), the keyring; the machine-local items moved."
  (let* ((secrets (or (plist-get ctx :config) (plist-get ctx :chezmoi) (file-exists-p (drgnx-secrets-file))))
         (local (mapcar #'directory-file-name (drgnx-bootstrap--machine-local)))
         (git (executable-find "git")))
    (cond
     ((plist-get ctx :dry-run)
      (list 'skipped (format "would: check %s, git%s and the keyring%s" (drgnx-platform) (if secrets ", age" "")
                             (if local (format "; move %s to the data dir" (string-join local ", ")) ""))))
     ((eq system-type 'windows-nt) (list 'failed "drgnx bootstrap runs on Linux and macOS"))
     ((not git) (list 'failed "git is not installed: install it with your package manager, then run this again"))
     (t
      (pcase-let ((`(,moved ,kept) (drgnx-bootstrap--move)))
        (list (if moved 'changed 'ok)
              (string-join (delq nil (list (symbol-name (drgnx-platform)) "git found"
                                           (and secrets (if (executable-find "age") "age found"
                                                          "no age yet (the keys step offers it if secrets.age needs it)"))
                                           (if (drgnx-secrets-keyring-p) "a keyring" "no keyring (keys stay in the environment)")
                                           (let ((m (drgnx-bootstrap--move-text moved kept))) (and (not (string-empty-p m)) m))))
                           "; ")))))))

(defun drgnx-bootstrap--entries (dir &optional ignore)
  "The names in DIR (none when it is missing or empty), without IGNORE's.  A file or a link where DIR should be is
an entry."
  (cond ((file-directory-p dir)
         (cl-set-difference (directory-files dir nil directory-files-no-dot-files-regexp) ignore :test #'equal))
        ((or (file-exists-p dir) (file-symlink-p dir)) (list (file-name-nondirectory dir)))))

(defun drgnx-bootstrap--norm-url (u) (string-remove-suffix ".git" (string-remove-suffix "/" u)))

(defun drgnx-bootstrap--same-repo-p (dir url)
  "Non-nil when DIR is the top of a git work tree whose origin is URL."
  (let ((top (drgnx-bootstrap--git "-C" dir "rev-parse" "--show-toplevel"))
        (origin (drgnx-bootstrap--git "-C" dir "config" "--get" "remote.origin.url")))
    (and (eql (car top) 0) (equal (file-truename (cdr top)) (file-truename dir))
         (eql (car origin) 0) (equal (drgnx-bootstrap--norm-url (cdr origin)) (drgnx-bootstrap--norm-url url)))))

(defun drgnx-bootstrap--git-clone (url dir)
  "Clone URL into DIR (missing or empty): into a new directory beside it, then renamed into place, so a failed or
stopped clone leaves nothing."
  (let* ((parent (file-name-directory dir)) tmp)
    (make-directory parent t)
    (setq tmp (make-temp-file (expand-file-name ".drgnx-clone-" parent) t))
    (unwind-protect
        (let* ((into (expand-file-name "config" tmp))
               (r (drgnx-bootstrap--git "clone" "-q" "--template=" "--" url into)))
          (if (not (eql (car r) 0))
              (list 'failed (format "%s; nothing was changed" (drgnx-bootstrap--why r "git clone")))
            (when (file-directory-p dir) (delete-directory dir)) ; empty: anything else fails here, and nothing moves
            (rename-file into dir)
            (list 'changed (format "cloned %s into %s" (drgnx-bootstrap--label url) (drgnx-portable-path dir)))))
      (delete-directory tmp t))))

(defun drgnx-bootstrap--clone (ctx)
  "--config URL: clone it into a missing or empty config dir; the same clone there is ok; anything else stops."
  (let* ((url (plist-get ctx :config))
         (dry (plist-get ctx :dry-run))
         (dir (directory-file-name (drgnx-user-dir)))
         (shown (drgnx-portable-path dir))
         (problem (drgnx-bootstrap--url-problem url))
         (entries (drgnx-bootstrap--entries dir (and dry (mapcar #'directory-file-name drgnx-portable-machine-local)))))
    (cond
     (problem (list 'failed (format "--config: %s; nothing was changed" problem)))
     ((null entries)
      (if dry (list 'skipped (format "would: git clone %s into %s" (drgnx-bootstrap--label url) shown))
        (drgnx-bootstrap--git-clone url dir)))
     ((drgnx-bootstrap--same-repo-p dir url)
      (list (if dry 'skipped 'ok) (format "%s%s is a clone of %s already (update it with: git -C %s pull)"
                                          (if dry "would: nothing, " "") shown (drgnx-bootstrap--label url)
                                          (drgnx-bootstrap--word dir))))
     (t (let ((names (string-join (append (seq-take (sort entries #'string<) 5) (and (nthcdr 5 entries) '("…"))) ", ")))
          (list (if dry 'skipped 'failed)
                (format "%s%s already holds a configuration (%s): move it aside (mv %s %s.before) and run this again"
                        (if dry "would: stop, " "") shown names (drgnx-bootstrap--word dir) (drgnx-bootstrap--word dir))))))))

(defun drgnx-bootstrap--chezmoi (ctx)
  "--chezmoi URL: chezmoi installed (announced, confirmed), `chezmoi init URL' (asked; --yes confirms), `chezmoi diff'
shown, then `chezmoi apply' only after a second yes, never under --yes."
  (let* ((url (plist-get ctx :chezmoi)) (yes (plist-get ctx :yes)) (ask (plist-get ctx :ask))
         (label (drgnx-bootstrap--label url))
         (problem (drgnx-bootstrap--url-problem url)))
    (cond
     (problem (list 'failed (format "--chezmoi: %s; nothing was changed" problem)))
     ((plist-get ctx :dry-run)
      (list 'skipped (format "would: chezmoi init %s (asks first), show chezmoi diff, then chezmoi apply after a second yes" label)))
     (t
      (let ((have (drgnx-bootstrap--install-tool 'chezmoi :yes yes :ask ask)))
        (if (not (eq have 'ok)) (list 'failed (format "chezmoi is needed for --chezmoi: %s" (cdr have)))
          (let* ((cz (drgnx-onboard--program 'chezmoi))
                 (call (lambda (&rest args) (drgnx-bootstrap--call cz (cons "--no-tty" args) nil drgnx-bootstrap--git-env)))
                 (source (funcall call "source-path"))
                 (src (and (eql (car source) 0) (not (string-empty-p (cdr source))) (cdr source)))
                 (state (cond ((not (and src (drgnx-bootstrap--entries src))) 'none)
                              ((drgnx-bootstrap--same-repo-p src url) 'same)
                              (t 'other)))
                 (init nil))
            (cond
             ((eq state 'other)
              (list 'failed (format "chezmoi's source dir %s holds another repository, which chezmoi init does not replace: move it aside and run this again"
                                    (drgnx-portable-path src))))
             ((and (eq state 'none)
                   (not (or yes (drgnx-bootstrap--ask ask (format "Run chezmoi init %s (it clones your dotfiles into chezmoi's source dir; nothing is applied yet)? " label)))))
              (list 'skipped (format "to set it up: chezmoi init %s, then chezmoi diff and chezmoi apply" label)))
             ((and (eq state 'none) (not (eql (car (setq init (funcall call "init" "--" url))) 0)))
              (list 'failed (format "%s; run chezmoi init %s yourself (it may ask questions)" (drgnx-bootstrap--why init "chezmoi init") label)))
             (t
              (let ((diff (funcall call "--no-pager" "--color=false" "diff"))
                    (done (if init "chezmoi init done; " "")))
                (cond
                 ((not (eql (car diff) 0)) (list 'failed (format "%s%s" done (drgnx-bootstrap--why diff "chezmoi diff"))))
                 ((string-empty-p (cdr diff))
                  (list (if init 'changed 'ok) (format "%snothing to apply: your dotfiles match chezmoi's" done)))
                 (t
                  (let ((lines (split-string (cdr diff) "\n")))
                    (drgnx-bootstrap--say "%s" (string-join (seq-take lines drgnx-bootstrap-diff-lines) "\n"))
                    (when (nthcdr drgnx-bootstrap-diff-lines lines)
                      (drgnx-bootstrap--say "… %d more lines (chezmoi diff shows them all)" (- (length lines) drgnx-bootstrap-diff-lines))))
                  (if (not (and ask (not yes) (drgnx-bootstrap--ask ask "Apply these changes to your files (chezmoi apply)? ")))
                      (list 'skipped (format "%sto apply the changes above: chezmoi apply" done))
                    (let ((applied (funcall call "apply")))
                      (if (eql (car applied) 0) (list 'changed (format "%sapplied chezmoi's files" done))
                        (list 'failed (format "%s%s; run chezmoi apply yourself (it may ask questions)" done
                                              (drgnx-bootstrap--why applied "chezmoi apply"))))))))))))))))))

(defun drgnx-bootstrap--config-here ()
  "What the config dir is, when neither --config nor --chezmoi was given."
  (let ((shown (drgnx-portable-path (directory-file-name (drgnx-user-dir)))))
    (pcase (drgnx-onboard--config-source)
      (`(git . ,remote) (format "%s is a git repository%s" shown
                                (if remote (format " (origin %s)" (drgnx-onboard--remote-label remote)) " without a remote")))
      (`(chezmoi . ,source) (format "chezmoi manages %s (source %s)" shown (drgnx-portable-path source)))
      (`(inside . ,top) (format "%s is inside the git repository %s" shown (drgnx-portable-path top)))
      (_ (if (drgnx-bootstrap--entries (drgnx-user-dir)) (format "%s is not a repository (onboarding's Portability step makes one)" shown)
           "no configuration yet: drgnx starts with its defaults (--config URL clones yours)")))))

(defun drgnx-bootstrap--config (ctx)
  "The configuration: --config's clone, --chezmoi's dotfiles, or what is there.  Without preflight in the run the
machine-local items are moved first (the doctor's fix names `drgnx bootstrap --step config')."
  (let ((moved nil) (kept nil))
    (when (and (not (plist-get ctx :dry-run)) (not (memq 'preflight (plist-get ctx :steps))))
      (pcase-setq `(,moved ,kept) (drgnx-bootstrap--move)))
    (let ((r (cond ((plist-get ctx :chezmoi) (drgnx-bootstrap--chezmoi ctx))
                   ((plist-get ctx :config) (drgnx-bootstrap--clone ctx))
                   ((plist-get ctx :dry-run) (list 'skipped "would: leave the config dir as it is (no --config or --chezmoi)"))
                   (t (list 'ok (drgnx-bootstrap--config-here)))))
          (note (drgnx-bootstrap--move-text moved kept)))
      (if (string-empty-p note) r
        (list (if (and moved (eq (car r) 'ok)) 'changed (car r)) (concat note "; " (cadr r)))))))

(defun drgnx-bootstrap--import-result (r)
  "(STATUS MESSAGE) of `drgnx-secrets-import''s result R: hosts only, never a key."
  (let ((stored (plist-get r :stored)) (differs (plist-get r :differs)) (failed (plist-get r :failed))
        (unknown (plist-get r :unknown)))
    (cond
     ((eq (car r) :skipped) (list 'skipped (cadr r)))
     ((or failed differs)
      (list 'failed (string-join (append (and stored (list (format "stored %s" (string-join stored ", "))))
                                         (mapcar (lambda (f) (format "%s: %s" (car f) (cdr f))) failed)
                                         (mapcar (lambda (h) (format "%s: your keyring's key differs and is kept (to overwrite it: drgnx bootstrap --step keys --replace)" h))
                                                 differs))
                                 "; ")))
     (t (list (if stored 'changed 'ok)
              (concat (if stored (format "stored the keys of %s" (string-join stored ", ")) "your keyring has these keys already")
                      (if unknown (format "; not stored, no provider with this address here: %s" (string-join unknown ", ")) "")))))))

(defun drgnx-bootstrap--import-lines (r)
  "(STATUS MESSAGE) of `drgnx secrets import' run on the terminal: R is (RC . OUTPUT), OUTPUT its lines (hosts and
what happened to them, never a key)."
  (let* ((lines (seq-take (mapcar (lambda (l) (truncate-string-to-width l 200)) (split-string (or (cdr r) "") "\n" t "[ \t]+")) 10))
         (stored (delq nil (mapcar (lambda (l) (and (string-match "\\`stored +\\([A-Za-z0-9.-]+\\)" l) (match-string 1 l))) lines))))
    (cond ((not (eql (car r) 0))
           (list 'failed (format "drgnx secrets import: %s" (if lines (string-join lines "; ") (format "exit %s" (car r))))))
          (stored (list 'changed (format "stored the keys of %s" (string-join stored ", "))))
          (t (list 'ok "your keyring has these keys already")))))

(defun drgnx-bootstrap--keys (ctx)
  "secrets.age's keys into the keyring: asked (or --yes), on a terminal or with --identity; age installed first if
needed (announced, confirmed).  A key the keyring holds differently is kept unless --replace."
  (let* ((file (drgnx-secrets-file))
         (identity (plist-get ctx :identity)) (yes (plist-get ctx :yes)) (ask (plist-get ctx :ask))
         (replace (plist-get ctx :replace))
         (command (if replace "drgnx secrets import --replace" "drgnx secrets import")))
    (cond
     ((plist-get ctx :dry-run)
      (list 'skipped (cond ((file-exists-p file) "would: import the keys of secrets.age into the keyring (asks first)")
                           ((or (plist-get ctx :config) (plist-get ctx :chezmoi))
                            "would: import the keys of the configuration's secrets.age, if it has one (asks first)")
                           (t "would: nothing (no secrets.age)"))))
     ((not (file-exists-p file)) (list 'ok "no secrets.age: no keys to import"))
     ((drgnx-secrets--import-ready) (list 'skipped (cadr (drgnx-secrets--import-ready))))
     ((not (or identity (plist-get ctx :tty)))
      (list 'skipped (format "on a terminal: %s (age asks for the passphrase), or --identity FILE" command)))
     ((not (or yes (drgnx-bootstrap--ask ask (format "Import the provider keys of secrets.age into this machine's keyring%s? "
                                                     (if identity " (with your age identity)" " (age asks for its passphrase)")))))
      (list 'skipped (format "not imported; to import them: %s" command)))
     (t
      (let ((age (drgnx-bootstrap--install-tool 'age :yes yes :ask ask)))
        (cond
         ((not (eq age 'ok)) (list 'failed (format "age is needed to import the keys of secrets.age: %s" (cdr age))))
         (identity
          (condition-case err (drgnx-bootstrap--import-result (drgnx-secrets-import :identity identity :replace replace))
            (user-error (list 'failed (error-message-string err)))
            ;; another error's message could hold what age gave: its name only
            (error (list 'failed (format "the import failed (%s); nothing more was done" (car err))))))
         (t (drgnx-bootstrap--import-lines
             (drgnx-bootstrap--on-terminal (append '("secrets" "import") (and replace '("--replace"))))))))))))

(defun drgnx-bootstrap--sync (ctx)
  "The packages of the config's lock (`drgnx-pkg-sync'): a pin that cannot be had fails, naming it."
  (if (plist-get ctx :dry-run) (list 'skipped "would: install the packages of your lock (drgnx sync)")
    (let ((r (condition-case err (drgnx-pkg-sync) (error (list :error (error-message-string err))))))
      (cond ((plist-get r :error) (list 'failed (format "drgnx sync failed: %s" (plist-get r :error))))
            ((plist-get r :missing)
             (list 'failed (format "your lock pins packages that cannot be had: %s (drgnx sync says more)"
                                   (mapconcat (lambda (m) (format "%s (%s)" (car m) (cdr m))) (plist-get r :missing) "; "))))
            ((plist-get r :installed)
             (let ((n (length (plist-get r :installed))))
               (list 'changed (format "installed %d package%s: %s" n (if (= n 1) "" "s")
                                      (mapconcat #'symbol-name (seq-take (plist-get r :installed) 20) " ")))))
            (t (list 'ok "the packages of your lock are installed"))))))

(defun drgnx-bootstrap--onboard (ctx)
  "Onboarding, non-interactive: it records what is set up and asks nothing."
  (if (plist-get ctx :dry-run) (list 'skipped "would: drgnx onboard --non-interactive (records what is set up; asks nothing)")
    (let* ((r (drgnx-onboard-run :non-interactive t))
           (failed (seq-filter (lambda (x) (eq (nth 1 x) 'fail)) r)))
      (if failed (list 'failed (format "onboarding: %s" (mapconcat (lambda (x) (format "%s: %s" (car x) (nth 2 x))) failed "; ")))
        (list 'ok (format "%d onboarding steps recorded (drgnx onboard, or Help → Welcome, goes through them)" (length r)))))))

(defun drgnx-bootstrap--desktop-installed-p ()
  "Non-nil when onboarding's step 7 has installed drgnx here: macOS the app, Linux the service and desktop entry."
  (if (eq (drgnx-platform) 'macos)
      (progn (require 'drgnx-macos) (file-directory-p (expand-file-name "drgnx.app" drgnx-macos-app-dir)))
    (and (file-exists-p (expand-file-name "~/.config/systemd/user/drgnx.service"))
         (file-exists-p (expand-file-name "~/.local/share/applications/drgnx.desktop")))))

(defun drgnx-bootstrap--desktop (ctx)
  "Onboarding's step 7 (the app, or the service and desktop entry), interactive only when a question can be asked
and not under --yes; else how to do it."
  (let ((how (if (eq (drgnx-platform) 'macos) "to install the drgnx app: drgnx macos-app"
               "to install drgnx's service and desktop entry: drgnx onboard --step daemon (it asks first)"))
        (interactive (and (plist-get ctx :ask) (not (plist-get ctx :yes))))
        (dry (plist-get ctx :dry-run)))
    (cond
     ((drgnx-bootstrap--desktop-installed-p) (list (if dry 'skipped 'ok) (format "%sinstalled already" (if dry "would: nothing, " ""))))
     (dry (list 'skipped (if interactive "would: ask to install it (onboarding's Daemon and Desktop step)" (format "would: skip it (%s)" how))))
     ((not interactive) (list 'skipped how))
     (t (plist-put ctx :desktop-asked t)
        (let ((r (car (drgnx-onboard-run :only '(daemon)))))
          (cond ((eq (nth 1 r) 'fail) (list 'failed (nth 2 r)))
                ((drgnx-bootstrap--desktop-installed-p) (list 'changed (nth 2 r)))
                (t (list 'skipped (nth 2 r)))))))))

(defun drgnx-bootstrap--shell (ctx)
  "The rc line (`drgnx-shell-install'), asked; never under --yes or without a terminal: then the line is shown."
  (let ((name (drgnx-shell-name))
        (ask (plist-get ctx :ask))
        (interactive (and (plist-get ctx :ask) (not (plist-get ctx :yes))))
        (dry (plist-get ctx :dry-run)))
    (if (null name)
        (list 'skipped "no integration for your shell: zsh, bash and fish have one (drgnx shell install --shell NAME)")
      (let ((rc (drgnx-portable-path (drgnx-shell-rc-file name)))
            (line (drgnx-shell-line name)))
        (cond
         ((drgnx-shell-line-present-p name)
          (list (if dry 'skipped 'ok) (format "%sthe line is in %s already" (if dry "would: nothing, " "") rc)))
         (dry (list 'skipped (if interactive (format "would: ask to add this line to %s: %s" rc line)
                               (format "would: skip it (to add it: drgnx shell install, or add this to %s: %s)" rc line))))
         ((not interactive) (list 'skipped (format "to add it: drgnx shell install, or add this to %s: %s" rc line)))
         ((plist-get ctx :desktop-asked) (list 'skipped "not added (you said no above); to add it: drgnx shell install"))
         (t (pcase (drgnx-shell-install name :ask (lambda (q) (drgnx-bootstrap--ask ask q)))
              ('added (list 'changed (format "added to %s (open a new terminal)" rc)))
              ('present (list 'ok (format "the line is in %s already" rc)))
              ('failed (list 'skipped (format "%s cannot be written; add this by hand: %s" rc line)))
              (_ (list 'skipped "not added; to add it: drgnx shell install")))))))))

(defun drgnx-bootstrap--doctor (ctx)
  "The doctor: green (`drgnx-doctor-green-p'), else the rows that are not."
  (if (plist-get ctx :dry-run) (list 'skipped "would: run drgnx doctor (green: no FAIL, a WARN only for security)")
    (let ((results (drgnx-doctor-run (drgnx-doctor-facts))))
      (if (drgnx-doctor-green-p results) (list 'ok "green")
        (list 'failed
              (format "not green: %s (drgnx doctor says how to fix them)"
                      (mapconcat (lambda (r) (format "%s %s: %s" (plist-get r :name) (plist-get r :status) (plist-get r :detail)))
                                 (seq-remove (lambda (r) (or (memq (plist-get r :status) '(ok info))
                                                             (and (eq (plist-get r :status) 'warn)
                                                                  (memq (plist-get r :name) drgnx-doctor-green-warnings))))
                                             results)
                                 "; ")))))))

(defconst drgnx-bootstrap--functions
  '((preflight . drgnx-bootstrap--preflight) (config . drgnx-bootstrap--config) (keys . drgnx-bootstrap--keys)
    (sync . drgnx-bootstrap--sync) (onboard . drgnx-bootstrap--onboard) (desktop . drgnx-bootstrap--desktop)
    (shell . drgnx-bootstrap--shell) (doctor . drgnx-bootstrap--doctor))
  "Each step's function.")

;;;; The run

(cl-defun drgnx-bootstrap-run (&key config chezmoi identity only dry-run yes ask replace resume)
  "Set this machine up: the steps of `drgnx-bootstrap-steps' (ONLY: a list of them) in order.
CONFIG: a git URL (https) or an absolute path to clone into the config dir; CHEZMOI: a chezmoi source repository
instead; IDENTITY: an age identity file for secrets.age.  DRY-RUN: say what each step would do, change nothing.
YES confirms the announced age/chezmoi install, the key import and chezmoi init, never the rc line, the desktop
entry, chezmoi apply or REPLACE (a key the keyring holds differently is kept unless REPLACE).  ASK: a function of a
question (`y-or-n-p' on a terminal), or nil: nothing is asked, and what would be asked is skipped with its command.
RESUME: (:from STEP :answers A :done D), the run handed back to bin/drgnx going on (`drgnx-bootstrap-cli-run').
Returns ((STEP STATUS MESSAGE)…), STATUS `ok', `changed', `skipped' or `failed'; a failed preflight, config or sync
stops the steps after it (`skipped').  In the CLI a step may end the list with (STEP handback STATE)."
  (let* ((steps (seq-filter (lambda (s) (or (null only) (memq s only))) drgnx-bootstrap-steps))
         (steps (if (plist-get resume :from) (memq (plist-get resume :from) steps) steps))
         (drgnx-bootstrap--answers (plist-get resume :answers))
         (drgnx-bootstrap--done (plist-get resume :done))
         (ctx (list :config config :chezmoi chezmoi :identity identity :dry-run dry-run :yes yes :ask ask :replace replace
                    :tty (equal (getenv "DRGNX_STDIN_TTY") "1") :steps steps :desktop-asked nil))
         (stopped nil) (out nil))
    (catch 'handback
      (dolist (step steps)
        (let ((row (if stopped (list step 'skipped (format "not run: the %s step failed" stopped))
                     (condition-case err
                         (cons step (funcall (alist-get step drgnx-bootstrap--functions) ctx))
                       (drgnx-bootstrap-handback
                        (push (list step 'handback (list :argv (cadr err) :answers drgnx-bootstrap--answers
                                                         :done drgnx-bootstrap--done))
                              out)
                        (throw 'handback nil))
                       (error (list step 'failed (error-message-string err)))))))
          (when (and (eq (nth 1 row) 'failed) (memq step drgnx-bootstrap--stopping) (not stopped)) (setq stopped step))
          (when drgnx-bootstrap--report (funcall drgnx-bootstrap--report row))
          (push row out))))
    (nreverse out)))

;;;; Command line: drgnx bootstrap

(defconst drgnx-bootstrap-usage
  "usage: drgnx bootstrap [--config URL | --chezmoi URL] [--identity FILE] [--step NAME]… [--dry-run] [--yes] [--replace]"
  "How `drgnx bootstrap' is called.")

(defun drgnx-bootstrap--parse (args)
  "ARGS as a plist (:config :chezmoi :identity :only :dry-run :yes :replace), or (:error WHY).  Values are checked
again here (bootstrap can be called directly): WHY never shows a URL."
  (let (o bad)
    (while (and args (not bad))
      (let ((a (pop args)))
        (pcase a
          ((or "--config" "--chezmoi" "--identity" "--step")
           (cond ((null args) (setq bad (format "%s needs a value" a)))
                 ((equal a "--step")
                  (let ((s (intern-soft (pop args))))
                    (if (memq s drgnx-bootstrap-steps) (setq o (plist-put o :only (append (plist-get o :only) (list s))))
                      (setq bad (format "--step takes one of: %s" (mapconcat #'symbol-name drgnx-bootstrap-steps " "))))))
                 (t (let ((key (intern (concat ":" (substring a 2)))) (v (pop args)))
                      (if (plist-get o key) (setq bad (format "%s once" a)) (setq o (plist-put o key v)))))))
          ("--dry-run" (setq o (plist-put o :dry-run t)))
          ("--yes" (setq o (plist-put o :yes t)))
          ("--replace" (setq o (plist-put o :replace t)))
          (_ (setq bad "unknown argument")))))
    (cond (bad (list :error bad))
          ((and (plist-get o :config) (plist-get o :chezmoi)) (list :error "--config and --chezmoi cannot be used together"))
          (t (let ((url (or (plist-get o :config) (plist-get o :chezmoi)))
                   (id (plist-get o :identity)))
               (cond ((and url (drgnx-bootstrap--url-problem url))
                      (list :error (format "%s takes an https URL or an absolute path: %s"
                                           (if (plist-get o :config) "--config" "--chezmoi") (drgnx-bootstrap--url-problem url))))
                     ((and id (drgnx-bootstrap--identity-problem (expand-file-name id)))
                      (list :error (drgnx-bootstrap--identity-problem (expand-file-name id))))
                     (t (if id (plist-put o :identity (expand-file-name id)) o))))))))

(defun drgnx-bootstrap--print-row (row)
  "Print ROW (STEP STATUS MESSAGE) as one line."
  (unless (eq (nth 1 row) 'handback)
    (princ (format "%-8s %-10s %s\n" (nth 0 row) (nth 1 row) (nth 2 row)))))

(defun drgnx-bootstrap--y-or-n-p (question)
  "`y-or-n-p' QUESTION on the terminal; no input (end of file) is a no."
  (condition-case nil (y-or-n-p question) (error nil)))

(defun drgnx-bootstrap--file (dir name) (expand-file-name name dir))

(defun drgnx-bootstrap--read-handback (dir)
  "The run handed back in DIR going on: (:from :answers :done :failed), with the result bin/drgnx wrote; nil when
there is none.  The files are removed.  A hand-back bin/drgnx did not finish is an `error'."
  (let ((state-file (drgnx-bootstrap--file dir "state.eld")))
    (when (file-exists-p state-file)
      (unwind-protect
          (let* ((state (with-temp-buffer (insert-file-contents state-file) (read (current-buffer))))
                 (rc (and (file-exists-p (drgnx-bootstrap--file dir "rc"))
                          (with-temp-buffer (insert-file-contents (drgnx-bootstrap--file dir "rc"))
                                            (string-to-number (string-trim (buffer-string))))))
                 (out (if (file-exists-p (drgnx-bootstrap--file dir "out"))
                          (with-temp-buffer (insert-file-contents (drgnx-bootstrap--file dir "out") nil 0 65536) (buffer-string))
                        "")))
            (unless (and (plist-get state :from) (memq (plist-get state :from) drgnx-bootstrap-steps) (plist-get state :argv) rc)
              (error "drgnx bootstrap: the command handed to bin/drgnx did not finish"))
            (list :from (plist-get state :from) :answers (plist-get state :answers) :failed (plist-get state :failed)
                  :done (cons (cons (plist-get state :argv) (cons rc out)) (plist-get state :done))))
        (dolist (f '("state.eld" "argv" "rc" "out"))
          (let ((file (drgnx-bootstrap--file dir f))) (when (file-exists-p file) (delete-file file))))))))

(defun drgnx-bootstrap--write-handback (dir step state failed)
  "Hand STEP's command (STATE's :argv) to bin/drgnx: DIR/argv, one word a line, and DIR/state.eld."
  (let ((argv (plist-get state :argv)))
    (when (seq-some (lambda (w) (or (not (stringp w)) (string-match-p "[\n\r]" w))) argv)
      (error "drgnx bootstrap: a command that cannot be handed on"))
    (with-temp-file (drgnx-bootstrap--file dir "argv") (insert (mapconcat (lambda (w) (concat w "\n")) argv "")))
    (with-temp-file (drgnx-bootstrap--file dir "state.eld")
      (let ((print-length nil) (print-level nil))
        (prin1 (list :from step :argv argv :answers (plist-get state :answers) :done (plist-get state :done) :failed failed)
               (current-buffer))))))

(defun drgnx-bootstrap-cli-run (args)
  "Run `drgnx bootstrap' ARGS; the exit code: 0 done, 1 a step failed, 2 a usage error, 10 a command for bin/drgnx
to run on the terminal (DRGNX_BOOTSTRAP_HANDBACK holds it; see the Commentary).  Questions are asked only when
stdin is a terminal (DRGNX_STDIN_TTY=1) and --yes is absent."
  (let ((o (drgnx-bootstrap--parse args)))
    (if (plist-get o :error)
        (progn (princ (format "drgnx bootstrap: %s\n%s\n" (plist-get o :error) drgnx-bootstrap-usage)) 2)
      (let* ((env (getenv "DRGNX_BOOTSTRAP_HANDBACK"))
             (dir (and env (not (string-empty-p env)) (file-directory-p env) (file-name-as-directory env)))
             (resume (and dir (drgnx-bootstrap--read-handback dir)))
             (tty (equal (getenv "DRGNX_STDIN_TTY") "1"))
             (drgnx-bootstrap--handback dir)
             (drgnx-bootstrap--report #'drgnx-bootstrap--print-row)
             (results (drgnx-bootstrap-run :config (plist-get o :config) :chezmoi (plist-get o :chezmoi)
                                           :identity (plist-get o :identity) :only (plist-get o :only)
                                           :dry-run (plist-get o :dry-run) :yes (plist-get o :yes)
                                           :replace (plist-get o :replace)
                                           :ask (and tty (not (plist-get o :yes)) #'drgnx-bootstrap--y-or-n-p)
                                           :resume resume))
             (last (car (last results)))
             (failed (or (plist-get resume :failed) (and (seq-some (lambda (r) (eq (nth 1 r) 'failed)) results) t))))
        (if (eq (nth 1 last) 'handback)
            (progn (drgnx-bootstrap--write-handback dir (car last) (nth 2 last) failed) 10)
          (if failed 1 0))))))

(defun drgnx-bootstrap-cli ()
  "bin/drgnx bootstrap: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (condition-case err (drgnx-bootstrap-cli-run args)
                  ;; never a backtrace: its arguments could show what a step read
                  (error (princ (format "drgnx bootstrap: failed (%s)\n" (if (stringp (cadr err)) (cadr err) (car err)))) 1)))))

(provide 'drgnx-bootstrap)
;;; drgnx-bootstrap.el ends here
