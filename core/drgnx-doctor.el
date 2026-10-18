;;; drgnx-doctor.el --- Is this machine ready for drgnx? -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx doctor' runs these checks in batch, inside the Emacs drgnx will use, so every
;; answer is about that Emacs.  A check is a function of a facts plist (gathered once by
;; `drgnx-doctor-facts', injected in tests) returning (STATUS DETAIL FIX), STATUS one of
;; `ok', `warn', `fail' or `info'.  Any `fail' makes the doctor exit 1.  Modules will add
;; their own checks with `drgnx-doctor-define' (M4).  A check may be for one platform (:platform `linux' or
;; `macos'): on the other it is absent from the results; so is a check that returns nil (the Terminal checks
;; outside a terminal).  See docs/guide/install.md.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-tty-recommend)   ; the terminal table, tmux, the fallback keys and the recommendation (all read-only)
(require 'drgnx-platform)        ; the window manager (the Desktop row)

(declare-function package-built-in-p "package")

(defconst drgnx-doctor-install-hint
  "run the installer: curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash  (see docs/guide/install.md)"
  "How to get a suitable Emacs.")

(defconst drgnx-doctor-security-issues
  '(("CVE-2026-79992" "TRAMP command injection through crafted file names" "31.1")
    ("CVE-2026-108976" "TRAMP: the first fix left user names with ! # & , and control characters" "31.2")
    ("CVE-2026-96442" "Flymake backends run code from the file being edited" "31.2")
    ("CVE-2026-96269" "read-symbol-shorthands in a file's local variables redirect symbol lookup" "31.2" "31.1"))
  "The Emacs issues the `security' check names: (ID WHAT FIXED-IN [PARTLY-FROM]).
An issue applies below FIXED-IN; from PARTLY-FROM on, only some of its ways in are closed.  The elisp Flymake
backend (CVE-2024-53920) is not here: every supported Emacs (30.2 and later) closes it with `trusted-content'.")

(defvar drgnx-doctor--checks nil "Alist NAME → plist (:group :doc :check :dev :platform), in definition order.")

(cl-defun drgnx-doctor-define (name &key group doc check dev platform)
  "Define check NAME in GROUP with DOC; CHECK maps facts to (STATUS DETAIL FIX).
DEV non-nil: only run for `drgnx doctor --dev' (tools for developing drgnx).
PLATFORM (`linux' or `macos'): only run on that platform, as `drgnx-platform' says."
  (let ((entry (list :group group :doc doc :check check :dev dev :platform platform)))
    (if (assq name drgnx-doctor--checks)
        (setf (alist-get name drgnx-doctor--checks) entry)
      (setq drgnx-doctor--checks (append drgnx-doctor--checks (list (cons name entry))))))
  name)

(defun drgnx-doctor-check (name facts)
  "Run check NAME on FACTS; return (STATUS DETAIL FIX)."
  (funcall (plist-get (alist-get name drgnx-doctor--checks) :check) facts))

;;;; Facts

(defun drgnx-doctor--native-compiles ()
  "t if this Emacs can natively compile a function, else the error as a string."
  (condition-case err
      (progn (native-compile '(lambda () 1)) t)
    (error (error-message-string err))))

(declare-function drgnx-pkg-status "drgnx-pkg")

(declare-function drgnx-work-db-file "drgnx-work-db")
(declare-function drgnx-work-nodes "drgnx-work-db")

(defun drgnx-doctor--work-plans ()
  "How many plans the work tracker knows (nil: it has not scanned yet)."
  (ignore-errors
    (require 'drgnx-work-db)
    (when (file-exists-p (drgnx-work-db-file)) (length (drgnx-work-nodes 'plan)))))

(declare-function drgnx-ai-detected-cached "drgnx-ai-probe")
(declare-function drgnx-ai-model-vram "drgnx-ai-probe")
(declare-function drgnx-ai-vram "drgnx-ai-probe")
(declare-function drgnx-ai-role "drgnx-ai")

(defun drgnx-doctor--ai-up ()
  "The providers the last probe found running."
  (ignore-errors
    (require 'drgnx-ai-probe)
    (mapcar #'car (seq-filter (lambda (e) (plist-get (cdr e) :up)) (drgnx-ai-detected-cached)))))

;; Semantic search: SQLite with FTS5, the embedding provider the last probe found, the known projects' indexes.
;; A failure becomes a fact (:error), never a crash; nothing here prompts, and the network is asked at most once, for a second.
(declare-function drgnx-search-doctor-facts "drgnx-search-setup")
(declare-function drgnx-search-setup--roots "drgnx-search-setup")

(defun drgnx-doctor--search ()
  "The facts of the `search' check (see `drgnx-search-doctor-facts'), or (:error MESSAGE)."
  (condition-case err
      (progn (require 'drgnx-search-setup) (drgnx-search-doctor-facts (drgnx-search-setup--roots)))
    (error (list :error (error-message-string err)))))

;; The terminal the doctor runs in (see `drgnx-tty-facts'): from the environment of this process, never from a
;; terminal.  Inside tmux, the one process is `tmux show' (1 s).  A failure becomes a fact (:error), never a crash.
(cl-defun drgnx-doctor-terminal-facts (&optional frame &key caps (fallbacks nil fallbacks-p))
  "The facts of the Terminal checks: `drgnx-tty-facts' of FRAME's client (this process's own when FRAME is nil)
with :caps (what the terminal can do) and :os (`drgnx-tty-os'); :fallbacks, rows (CHORD NATIVE-P ALT PREFIX),
only when known.  CAPS and FALLBACKS are the live frame's (Check This Terminal); without CAPS they are those of
the newest entry of terminal-report.eld for this kind of terminal (inside tmux, preferably one with the same terminal
around it), which drgnx wrote when a window of it opened.
A failure is (:error MESSAGE)."
  (condition-case err
      (let* ((facts (drgnx-tty-facts frame))
             (id (plist-get (plist-get facts :identity) :id))
             (outer (plist-get (plist-get facts :identity) :outer))
             (same (and (not caps) (plist-get facts :in-terminal)
                        (seq-filter (lambda (e) (and (consp e) (eq (plist-get (plist-get (cdr e) :caps) :id) id)))
                                    (let ((all (plist-get (plist-get facts :report) :terminals))) (and (proper-list-p all) all)))))
             ;; tmux in kitty is not tmux in Ptyxis: the entry with the same terminal around it first, else the newest
             (entry (or (and outer (seq-find (lambda (e) (eq (plist-get (plist-get (cdr e) :caps) :outer) outer)) same))
                        (car same))))
        (append facts
                (list :caps (or caps (plist-get (cdr entry) :caps)) :os (and (plist-get facts :in-terminal) (drgnx-tty-os)))
                (cond (fallbacks-p (list :fallbacks fallbacks))
                      ((and entry (plist-member (cdr entry) :fallbacks)) (list :fallbacks (plist-get (cdr entry) :fallbacks))))))
    (error (list :error (error-message-string err)))))

(declare-function drgnx-agents-claude-adapter "drgnx-agents")
(declare-function drgnx-agents-adapter-problem "drgnx-agents")
(declare-function drgnx-agents-adapter-advice "drgnx-agents")
(defvar drgnx-agents-claude-package)

(defun drgnx-doctor--claude-adapter ()
  "The fact of the `claude-adapter' check: the adapter the claude profiles would run (`drgnx-agents-claude-adapter':
its package read from its package.json, never run), nil when none is installed, or (:error MESSAGE)."
  (condition-case err
      (progn (require 'drgnx-agents) (drgnx-agents-claude-adapter))
    (error (list :error (error-message-string err)))))

(defun drgnx-doctor--claude-adapter-check (a)
  "The `claude-adapter' check of the fact A (`drgnx-doctor--claude-adapter')."
  (require 'drgnx-agents)
  (let ((problem (and (plist-get a :name) (drgnx-agents-adapter-problem a))))
    (cond ((plist-get a :error) (list 'warn (format "could not check: %s" (plist-get a :error)) "run drgnx doctor again"))
          ((null a) (list 'info "not installed: the claude agent profiles need it"
                          "drgnx onboard --step agents (or Help → Welcome → Agents) installs it"))
          (problem (list 'warn (car problem) (cdr problem)))
          ((not (plist-get a :name))
           (list 'warn (format "%s belongs to no npm package drgnx knows: it cannot tell whether it is %s"
                               (abbreviate-file-name (plist-get a :program)) drgnx-agents-claude-package)
                 (drgnx-agents-adapter-advice a)))
          (t (list 'ok (format "%s %s (%s)" (plist-get a :name) (plist-get a :version) (abbreviate-file-name (plist-get a :program)))
                   nil)))))

(defvar drgnx-macos-app-dir)

(defconst drgnx-doctor--brew-programs '("/opt/homebrew/bin/brew" "/usr/local/bin/brew")
  "Where Homebrew lives on Apple silicon and on Intel, for a doctor that runs without it on PATH.")

(defun drgnx-doctor--macos-facts ()
  "The facts of the macOS checks: the drgnx app, Homebrew, drgnx on PATH."
  (require 'drgnx-macos)
  (list :macos-app (file-directory-p (expand-file-name "drgnx.app" drgnx-macos-app-dir))
        :brew (and (or (executable-find "brew") (seq-some #'file-executable-p drgnx-doctor--brew-programs)) t)
        :drgnx-on-path (drgnx-doctor--drgnx-on-path)
        :shell-profile (drgnx-doctor--shell-profile)))

(defun drgnx-doctor--shell-profile ()
  "The login profile the user's shell reads and install.sh writes the PATH line to: ~/.zprofile for zsh (macOS's
default; it never reads ~/.profile), else ~/.profile.  With SHELL unset or empty (a daemon the app started):
~/.zprofile when it exists, then ~/.profile."
  (let ((shell (or (getenv "SHELL") "")))
    (cond ((string-suffix-p "/zsh" shell) "~/.zprofile")
          ((and (string-empty-p shell) (file-exists-p (expand-file-name "~/.zprofile"))) "~/.zprofile")
          (t "~/.profile"))))

(defun drgnx-doctor--drgnx-on-path ()
  "Does Terminal find the drgnx command?  It is on this Emacs's PATH; or — a daemon the app started lacks
~/.local/bin on its PATH — ~/.local/bin/drgnx is there and a line of the shell's profile
(`drgnx-doctor--shell-profile', not a comment) puts ~/.local/bin on PATH: `PATH=…' or, in zsh, `path=(…)' / `path+=(…)'."
  (or (and (executable-find "drgnx") t)
      (let ((profile (expand-file-name (drgnx-doctor--shell-profile))) (case-fold-search nil))
        (and (file-exists-p (expand-file-name "~/.local/bin/drgnx"))
             (file-regular-p profile) (file-readable-p profile)
             ;; a profile that cannot be read is skipped quietly (the facts are gathered outside any condition-case)
             (ignore-errors
               (with-temp-buffer
                 (insert-file-contents profile)
                 (re-search-forward (rx bol (* (not (any "#\n"))) (or "PATH=" (seq "path" (? "+") "=(")) (* nonl)
                                        (or "$HOME" "${HOME}" "~" (literal (directory-file-name (expand-file-name "~"))))
                                        "/.local/bin")
                                    nil t)))
             t))))

(defun drgnx-doctor--gui-from-features (features)
  "The graphical toolkit (`pgtk', `x11' or `ns') named in the build FEATURES string, or nil."
  (when (string-match "\\(PGTK\\|X11\\|NS\\)" features)
    (intern (downcase (match-string 1 features)))))

(declare-function drgnx-trust-mode "drgnx-trust")
(declare-function drgnx-trust-guards-status "drgnx-trust")
(defvar drgnx-trust-mode)

(defun drgnx-doctor--trust-guards ()
  "The facts of the `security' check: `drgnx-trust-guards-status', or (:error MESSAGE).
A batch doctor runs in a bare Emacs where drgnx's startup has not run (its commands are not registered): it
switches `drgnx-trust-mode' on to see which guards drgnx installs on this Emacs, and puts the mode back.
`drgnx-trust-mode' -1 does not undo everything the mode did (the `trusted-content' entries it added stay), which
only matters in this throwaway process.  When the mode is on, when startup ran (so a mode that is off was turned
off), or inside a session, the mode is read as it is and never switched: an off mode is reported off."
  (condition-case err
      (progn
        (require 'drgnx-trust)
        (if (or drgnx-trust-mode (not noninteractive) (drgnx-commands-get 'trust-folder))
            (drgnx-trust-guards-status)
          (unwind-protect (progn (drgnx-trust-mode 1) (drgnx-trust-guards-status))
            (drgnx-trust-mode -1))))
    (error (list :error (error-message-string err)))))

;; The config files (docs/guide/files.md): read fresh, applying nothing.  The core features whose loading defines config
;; files are listed here, one line each; a module's file is loaded by `drgnx-config-doc' for its reference, not here.
(defvar drgnx-doctor-config-features
  '(
    ;; one feature per line, appended below by each port
    drgnx-projects
    drgnx-agents
    )
  "The core features whose loading defines config files, for the `config-files' check.")

(declare-function drgnx-config-read "drgnx-config")
(defvar drgnx-config--defs)

(defun drgnx-doctor--config-files ()
  "The fact of the `config-files' check: (NAME :status :problem :unknown-keys :file) for every defined file that is
not a project's, from a fresh `drgnx-config-read' (it applies nothing and writes nothing), by name; or (:error MESSAGE)."
  (condition-case err
      (progn
        (require 'drgnx-config)
        (dolist (feature drgnx-doctor-config-features) (require feature))
        (let (names)
          (maphash (lambda (name def) (unless (eq (plist-get def :dir) 'project) (push name names))) drgnx-config--defs)
          (mapcar (lambda (name)
                    (let ((r (drgnx-config-read name)))
                      (list name :status (plist-get r :status) :problem (plist-get r :problem)
                            :unknown-keys (plist-get r :unknown-keys) :file (plist-get r :file))))
                  (sort names (lambda (a b) (string< (symbol-name a) (symbol-name b)))))))
    (error (list :error (error-message-string err)))))

(defun drgnx-doctor--config-files-check (rows)
  "The `config-files' check of the fact ROWS (`drgnx-doctor--config-files')."
  (if (eq (car-safe rows) :error)
      (list 'warn (format "could not check: %s" (cadr rows)) "run drgnx doctor again")
    (let (fail warn info)
      (dolist (row rows)
        (let* ((r (cdr row)) (file (file-name-nondirectory (or (plist-get r :file) (symbol-name (car row))))))
          (pcase (plist-get r :status)
            ('problem (push (format "%s line %s: %s" file (plist-get (plist-get r :problem) :line)
                                    (plist-get (plist-get r :problem) :text))
                            fail))
            ('newer (push (format "%s: written by a newer drgnx: update drgnx here" file) warn))
            ('migrated (push (format "%s: an older format, read as the current one; Migrate Config File… writes it" file)
                             info)))
          (dolist (key (plist-get r :unknown-keys))
            (push (format "%s: %s — a newer drgnx, or a typo?" file (mapconcat (lambda (k) (format "%s" k)) key " "))
                  info))))
      (cond (fail (list 'fail (string-join (append (nreverse fail) (nreverse warn) (nreverse info)) "\n")
                        (concat "Preferences: Open Config File… or edit it; "
                                "its last good copy is in use until then")))
            (warn (list 'warn (string-join (append (nreverse warn) (nreverse info)) "\n") "update drgnx here"))
            (info (list 'info (string-join (nreverse info) "\n") nil))
            (t (list 'ok (format "%d file%s read" (length rows) (if (= (length rows) 1) "" "s")) nil))))))

(defun drgnx-doctor--checkout-init (dir)
  "The fact of the `checkout-clean' check: (:dir DIR :changed LINES), LINES being `git status --porcelain -- init/'
of the checkout DIR, run with GIT_OPTIONAL_LOCKS=0 and bounded at 5 s; nil without DIR/.git (an installed copy
that is not a checkout); (:error MESSAGE) when git cannot say."
  (when (file-exists-p (expand-file-name ".git" dir))
    (condition-case err
        (let* ((process-environment (cons "GIT_OPTIONAL_LOCKS=0" process-environment))
               (default-directory (file-name-as-directory (expand-file-name dir)))
               (buf (generate-new-buffer " *drgnx-doctor-git*" t))
               (proc (make-process :name "drgnx-doctor-git" :buffer buf :noquery t :connection-type 'pipe
                                   :sentinel #'ignore   ; the default one writes "Process … finished" into the buffer
                                   :command (list "git" "-C" (directory-file-name default-directory)
                                                  "status" "--porcelain" "--" "init/")))
               (deadline (+ (float-time) 5)))
          (unwind-protect
              (progn
                (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output proc 0.05))
                (cond ((process-live-p proc) (delete-process proc) (list :error "git status took more than 5 s"))
                      ((not (eql (process-exit-status proc) 0)) (list :error "git status failed"))
                      (t (list :dir dir :changed (split-string (with-current-buffer buf (buffer-string)) "\n" t)))))
            (kill-buffer buf)))
      (error (list :error (error-message-string err))))))

(defun drgnx-doctor-facts ()
  "Facts about the running Emacs and this machine."
  (let ((native (and (fboundp 'native-comp-available-p) (native-comp-available-p))))
    (append
     (list :version emacs-version
           :native-available native
           :native-compiles (if native (drgnx-doctor--native-compiles) "not built with native compilation")
           :treesit (and (fboundp 'treesit-available-p) (treesit-available-p))
           :gui (cond ((featurep 'pgtk) 'pgtk) ((featurep 'ns) 'ns) ((featurep 'x) 'x)
                      (t (drgnx-doctor--gui-from-features system-configuration-features)))
           :git (and (executable-find "git") t)
           :mutter (and (executable-find "mutter") t)
           :dbus-run-session (and (executable-find "dbus-run-session") t)
           :magick (and (executable-find "magick") t)
           :pgtk-emacs (or (featurep 'pgtk) (and (executable-find "emacs-pgtk") t))
           :keys-report (drgnx-doctor--keys-report)
           :desktop (getenv "XDG_CURRENT_DESKTOP")
           :wb-report (drgnx-doctor--state-file "wb-report.eld")
           :modules-report (drgnx-doctor--state-file "modules-report.eld")
           :modules-report-time (drgnx-doctor--state-file-time "modules-report.eld")
           :onboarding (drgnx-doctor--state-file "onboarding.eld")
           :packages (condition-case err (progn (require 'drgnx-pkg) (drgnx-pkg-status))
                       (error (list :error (error-message-string err))))
           :sqlite (and (fboundp 'sqlite-available-p) (sqlite-available-p))
           :svg (image-type-available-p 'svg)
           :work-plans (drgnx-doctor--work-plans)
           :ai-up (drgnx-doctor--ai-up)
           :search (drgnx-doctor--search)
           :terminal (drgnx-doctor-terminal-facts)
           :window-manager (drgnx-platform-doctor-facts)
           ;; whether a key is set, from the environment only: the doctor never opens auth-source (it may prompt)
           :ai-keys (let ((k (getenv "OPENROUTER_API_KEY"))) (and k (not (string-empty-p k)) '(openrouter)))
           :ai-complete (ignore-errors (require 'drgnx-ai) (cdr (car (drgnx-ai-role 'complete))))
           :claude-adapter (drgnx-doctor--claude-adapter)
           :vram (ignore-errors (require 'drgnx-ai-probe) (drgnx-ai-vram))
           :trust-guards (drgnx-doctor--trust-guards)
           :config-files (drgnx-doctor--config-files)
           :checkout-init (drgnx-doctor--checkout-init drgnx-dir))
     (and (eq (drgnx-platform) 'macos) (drgnx-doctor--macos-facts)))))

(defun drgnx-doctor--state-path (name)
  "The file NAME in the state dir."
  (expand-file-name name (drgnx-state-dir)))

(defun drgnx-doctor--state-file (name)
  "The .eld file NAME the last drgnx session wrote in the state dir, read, or nil."
  (let ((file (drgnx-doctor--state-path name)))
    (when (file-readable-p file)
      (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer)))))))

(defun drgnx-doctor--state-file-time (name)
  "When the state file NAME was last written (seconds since the epoch), or nil."
  (when-let* ((attrs (file-attributes (drgnx-doctor--state-path name))))
    (float-time (file-attribute-modification-time attrs))))

(defun drgnx-doctor--age (time)
  "TIME (seconds since the epoch) as how long ago: \"N min ago\", \"N h ago\" or \"N d ago\"."
  (let ((s (max 0 (- (float-time) time))))
    (cond ((< s 3600) (format "%d min ago" (floor s 60)))
          ((< s 172800) (format "%d h ago" (floor s 3600)))
          (t (format "%d d ago" (floor s 86400))))))

(defun drgnx-doctor--keys-report ()
  "The key report the last drgnx session wrote (keys-report.eld in the state dir), or nil."
  (let ((file (expand-file-name "keys-report.eld" (drgnx-state-dir))))
    (when (file-readable-p file)
      (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer)))))))

;;;; Checks

(defun drgnx-doctor--version< (a b) (version< a b))

(drgnx-doctor-define 'emacs-version :group "Emacs" :doc "GNU Emacs 31.1 or newer (30.2 still works)"
                     :check (lambda (f)
                              (let ((v (plist-get f :version)))
                                (cond ((not (drgnx-doctor--version< v "31.1")) (list 'ok (format "Emacs %s" v) nil))
                                      ((not (drgnx-doctor--version< v "30.2"))
                                       (list 'warn (format "Emacs %s works, 31.1 is recommended" v) drgnx-doctor-install-hint))
                                      (t (list 'fail (format "Emacs %s is too old (30.2 or newer needed)" v) drgnx-doctor-install-hint))))))

(drgnx-doctor-define 'native-compilation :group "Emacs" :doc "Native compilation works (drgnx's speed depends on it)"
                     :check (lambda (f)
                              (let ((c (plist-get f :native-compiles)))
                                (cond ((not (plist-get f :native-available))
                                       (list 'fail "this Emacs was built without native compilation" drgnx-doctor-install-hint))
                                      ((eq c t) (list 'ok "native compilation works" nil))
                                      (t (list 'fail (format "native compilation is built in but fails: %s" c)
                                               (concat "install your distribution's libgccjit, or " drgnx-doctor-install-hint)))))))

(drgnx-doctor-define 'tree-sitter :group "Emacs" :doc "Tree-sitter support (syntax-aware editing)"
                     :check (lambda (f)
                              (if (plist-get f :treesit) (list 'ok "tree-sitter available" nil)
                                (list 'warn "this Emacs has no tree-sitter support" drgnx-doctor-install-hint))))

(drgnx-doctor-define 'gui :group "Emacs" :doc "A graphical build (pgtk on Wayland, X11 or macOS), or a terminal-only one"
                     :check (lambda (f)
                              (if-let* ((g (plist-get f :gui))) (list 'ok (format "graphical build (%s)" g) nil)
                                (list 'ok "terminal-only Emacs: drgnx runs in terminals (no images, one font size; popups in the bottom lane on 30.2)" nil))))

(defun drgnx-doctor--security-issues (version)
  "The `drgnx-doctor-security-issues' that apply to Emacs VERSION, as \"ID\" or \"ID (partly fixed here)\" strings."
  (cl-loop for (id _what fixed partly) in drgnx-doctor-security-issues
           when (drgnx-doctor--version< version fixed)
           collect (if (and partly (not (drgnx-doctor--version< version partly))) (format "%s (partly fixed here)" id) id)))

(defun drgnx-doctor--guards-off (g)
  "What is off in the guards status G (`drgnx-trust-guards-status'), as a list of phrases."
  (if (not (plist-get g :mode)) (list "drgnx-trust-mode is off")
    (delq nil
          (list (unless (plist-get g :tramp) "TRAMP name guard")
                (unless (plist-get g :flymake) "Flymake trust check")
                (unless (plist-get g :eglot-safe) "eglot is not marked safe")
                (unless (plist-get g :shorthands) "shorthands guard")
                (unless (plist-get g :compile) "compile-output guard")
                (unless (plist-get g :ffap) "ffap guard")
                (unless (eq (plist-get g :remote-file-name-inhibit-auto-save-visited) t) "auto-save guard")
                (when (plist-get g :enable-remote-dir-locals) "enable-remote-dir-locals is on")
                (when (plist-get g :auto-revert-remote-files) "auto-revert-remote-files is on")))))

(drgnx-doctor-define 'security :group "Emacs" :doc "Known security issues of this Emacs version, and whether drgnx's guards are on"
                     :check (lambda (f)
                              (let* ((v (plist-get f :version))
                                     (issues (drgnx-doctor--security-issues v))
                                     (known (if issues (format "Emacs %s has %d known issue%s, fixed in 31.2: %s (docs/guide/security.md)"
                                                               v (length issues) (if (cdr issues) "s" "") (string-join issues ", "))
                                              "no known issues for this version"))
                                     (g (plist-get f :trust-guards))
                                     (until "until then avoid opening untrusted files and remote paths"))
                                (cond ((plist-get g :error)
                                       (list 'warn (format "drgnx's guards could not be read: %s" (plist-get g :error))
                                             "see docs/guide/security.md"))
                                      ((not (plist-member f :trust-guards))
                                       (if issues (list 'warn known (concat "update to 31.2 when it is released; " until))
                                         (list 'ok known nil)))
                                      ((drgnx-doctor--guards-off g)
                                       (list 'warn (format "drgnx's guards are off (%s); %s" (string-join (drgnx-doctor--guards-off g) ", ") known)
                                             (concat "restart drgnx so that its startup turns the guards on (docs/guide/security.md)"
                                                     (and issues (concat ", and update to 31.2 when it is released; " until)))))
                                      (t (list 'ok (format "%s; drgnx's guards are on%s" known
                                                           (if (eq (plist-get g :flymake) 'on-load)
                                                               " (Flymake's trust check is added when Flymake loads: not verified in a batch check)"
                                                             ""))
                                               nil))))))

(drgnx-doctor-define 'git :group "Tools" :doc "git (installing and updating drgnx)"
                     :check (lambda (f)
                              (if (plist-get f :git) (list 'ok "git found" nil)
                                (list 'warn "git not found" "install git with your package manager"))))

(drgnx-doctor-define 'claude-adapter :group "Tools"
                     :doc "The Claude Code adapter the claude agent profiles run: @agentclientprotocol/claude-agent-acp 0.93.0 or newer"
                     :check (lambda (f) (drgnx-doctor--claude-adapter-check (plist-get f :claude-adapter))))

(drgnx-doctor-define 'config-files :group "drgnx" :doc "drgnx's config files read, with no mistakes"
                     :check (lambda (f) (drgnx-doctor--config-files-check (plist-get f :config-files))))

(drgnx-doctor-define 'checkout-clean :group "drgnx"
                     :doc "The checkout's init/ has no local changes (install.sh's update needs that)"
                     :check (lambda (f)
                              (let ((c (plist-get f :checkout-init)))
                                (cond ((null c) nil)
                                      ((plist-get c :error)
                                       (list 'warn (format "could not check: %s" (plist-get c :error)) "run drgnx doctor again"))
                                      ((plist-get c :changed)
                                       (list 'warn (format "init/ has local changes: %s"
                                                           (mapconcat (lambda (l) (string-trim l)) (plist-get c :changed) ", "))
                                             (format "move what you changed to config.el or custom.el in %s, then: git -C %s checkout -- init/"
                                                     (abbreviate-file-name (drgnx-user-dir))
                                                     (directory-file-name (plist-get c :dir)))))
                                      (t (list 'ok "init/ has no local changes" nil))))))

(drgnx-doctor-define 'modules :group "drgnx" :doc "Modules that failed or wait for packages (from the last session)"
                     :check (lambda (f)
                              (let* ((r (plist-get f :modules-report))
                                     (failed (seq-filter (lambda (m) (eq (plist-get (cdr m) :status) 'failed)) r))
                                     (waiting (seq-filter (lambda (m) (eq (plist-get (cdr m) :status) 'missing-packages)) r))
                                     (problems (seq-filter (lambda (m) (plist-get (cdr m) :problems)) r))
                                     (off (seq-count (lambda (m) (eq (plist-get (cdr m) :status) 'disabled)) r))
                                     (time (plist-get f :modules-report-time))
                                     (res
                                      (cond ((null r) (list 'info "no module report yet — start drgnx once" nil))
                                            (failed (list 'fail (mapconcat (lambda (m) (format "%s: %s" (car m) (plist-get (cdr m) :error))) failed "; ")
                                                          "see Preferences: Modules; turn the module off there or report the error"))
                                            (waiting (list 'warn (format "waiting for packages: %s"
                                                                         (mapconcat (lambda (m) (format "%s (%s)" (car m)
                                                                                                        (mapconcat #'symbol-name (plist-get (cdr m) :missing) " ")))
                                                                                    waiting ", "))
                                                           "drgnx sync installs them (M5); until then these modules stay off"))
                                            (problems (list 'warn (mapconcat (lambda (m) (format "%s: %s" (car m) (string-join (plist-get (cdr m) :problems) "; ")))
                                                                             problems "; ")
                                                            "see the module's documentation"))
                                            (t (list 'ok (format "%d ok, %d off" (- (length r) off) off) nil)))))
                                ;; the report is from the last session: say how old it is
                                (if (and time (not (eq (car res) 'info)))
                                    (list (car res) (format "%s (from the last session, %s)" (nth 1 res) (drgnx-doctor--age time))
                                          (nth 2 res))
                                  res))))

(drgnx-doctor-define 'packages :group "drgnx" :doc "The packages drgnx needs are installed (drgnx sync), with a lock"
                     :check (lambda (f)
                              (let* ((p (plist-get f :packages))
                                     ;; a package this Emacs ships (eglot, …) needs no install, as `drgnx sync' knows
                                     (missing (progn (require 'package)
                                                     (seq-remove #'package-built-in-p
                                                                 (seq-difference (plist-get p :manifest) (plist-get p :installed))))))
                                (cond ((plist-get p :error) (list 'fail (plist-get p :error) "fix or remove the file named; drgnx sync rewrites the lock"))
                                      (missing (list 'warn (format "not installed: %s" (mapconcat #'symbol-name missing " "))
                                                     "drgnx sync installs them (their modules wait until then)"))
                                      ((and (plist-get p :manifest) (not (plist-get p :lock)))
                                       (list 'warn "no lock (drgnx.lock.eld)" "drgnx sync writes it; commit it with your configuration"))
                                      ((null (plist-get p :manifest)) (list 'ok "no packages needed" nil))
                                      (t (list 'ok (format "%d packages installed, locked; %d generations"
                                                           (length (plist-get p :installed)) (or (plist-get p :generations) 0))
                                               nil))))))

(drgnx-doctor-define 'onboarding :group "drgnx" :doc "The onboarding steps (drgnx onboard, Help → Welcome)"
                     :check (lambda (f)
                              (let* ((s (plist-get f :onboarding))
                                     (failed (seq-filter (lambda (e) (eq (plist-get (cdr e) :status) 'fail)) s)))
                                (cond ((null s) (list 'info "not run yet" "drgnx onboard (or Help → Welcome in drgnx)"))
                                      (failed (list 'warn (format "steps that failed: %s" (mapconcat (lambda (e) (symbol-name (car e))) failed " "))
                                                    "run them again from Help → Welcome, or drgnx onboard --step ID"))
                                      (t (list 'ok (format "%d steps done" (length s)) nil))))))

(drgnx-doctor-define 'ai :group "drgnx" :doc "AI providers (local runners, OpenRouter) and room on the GPU for the completion model"
                     :check (lambda (f)
                              (let* ((v (plist-get f :vram)) (model (plist-get f :ai-complete))
                                     (need (if model (progn (require 'drgnx-ai-probe) (drgnx-ai-model-vram model)) 0))
                                     (free (and v (- (plist-get v :total) (plist-get v :used)))))
                                (cond ((and (null (plist-get f :ai-up)) (null (plist-get f :ai-keys)))
                                       (list 'info "no AI provider found yet"
                                             "start a local runner (Ollama, LM Studio, llama.cpp …) or set OPENROUTER_API_KEY; then AI: Choose Provider/Model"))
                                      ((and free (> need free))
                                       (list 'warn (format "the completion model %s needs about %d MiB of GPU memory; %d MiB are free" model need free)
                                             "choose a smaller completion model (AI: Choose Provider/Model), or stop what holds the GPU"))
                                      (t (list 'ok (format "providers: %s%s" (mapconcat #'symbol-name (append (plist-get f :ai-up) (plist-get f :ai-keys)) ", ")
                                                           (if free (format "; %d MiB GPU free" free) ""))
                                               nil))))))

(declare-function drgnx-search-setup-mismatch "drgnx-search-setup")

(defun drgnx-doctor--search-problem (indexes dims provider model)
  "The first index of INDEXES ((ROOT . INFO)…) that does not fit the vectors the provider gives (DIMS, PROVIDER,
MODEL), as a sentence, or nil."
  (when indexes
    (require 'drgnx-search-setup)
    (cl-loop for (root . info) in indexes
             for why = (drgnx-search-setup-mismatch info dims provider model)
             when why return (format "the index of %s was %s — Search: Index Project with rebuild" (file-name-nondirectory (directory-file-name root)) why))))

(drgnx-doctor-define 'search :group "drgnx" :doc "Semantic search: SQLite with FTS5, an embedding provider, the project indexes"
                     :check (lambda (f)
                              (if (not (plist-member f :search)) (list 'info "not checked" nil)
                                (let* ((s (plist-get f :search)) (indexes (plist-get s :indexes))
                                       (stale (seq-filter (lambda (e) (> (or (plist-get (cdr e) :stale) 0) 20)) indexes))
                                       (broken (seq-filter (lambda (e) (plist-get (cdr e) :error)) indexes))
                                       (config (car (plist-get s :config-errors)))
                                       (problem (drgnx-doctor--search-problem indexes (plist-get s :embed-dims) (plist-get s :embed-provider) (plist-get s :embed-model)))
                                       (unindexed (or (plist-get s :unindexed) 0))
                                       (chunks (apply #'+ (mapcar (lambda (e) (or (plist-get (cdr e) :chunks) 0)) indexes))))
                                  (cond ((plist-get s :error) (list 'warn (format "could not check: %s" (plist-get s :error)) "run drgnx doctor again; Set Up Semantic Search"))
                                        ((not (plist-get s :sqlite)) (list 'fail "this Emacs has no SQLite: semantic search is off" "use an Emacs built with SQLite (the installer's does)"))
                                        ((not (plist-get s :fts5)) (list 'fail "this Emacs' SQLite has no FTS5: semantic search is off" "use an Emacs built with SQLite and FTS5 (the installer's does)"))
                                        (problem (list 'warn problem "Search: Index Project with C-u (rebuild), or choose the model the index was built with (AI: Choose Provider/Model)"))
                                        (broken (list 'warn (format "the index of %s cannot be read: %s"
                                                                    (file-name-nondirectory (directory-file-name (car (car broken))))
                                                                    (plist-get (cdr (car broken)) :error))
                                                      "Search: Index Project with C-u rebuilds it"))
                                        (config (list 'warn (format "%s: %s (nothing is indexed there)"
                                                                    (file-name-nondirectory (directory-file-name (car config))) (cdr config))
                                                      "fix or delete that project's .drgnx/search.eld (docs/guide/search.md)"))
                                        (stale (list 'warn (format "stale index (more than 20 files changed since): %s"
                                                                   (mapconcat (lambda (e) (format "%s %d files" (file-name-nondirectory (directory-file-name (car e)))
                                                                                                  (plist-get (cdr e) :stale)))
                                                                              stale ", "))
                                                     "Search: Index Project in that project"))
                                        ((not (plist-get s :embed-up))
                                         (list 'info (format "no embedding provider is reachable: searches use keywords only (%d indexes, %d chunks)" (length indexes) chunks)
                                               "Set Up Semantic Search (it says how to start TEI or Ollama)"))
                                        (t (list 'ok (format "%d index%s, %d chunks%s" (length indexes) (if (= (length indexes) 1) "" "es") chunks
                                                             (if (> unindexed 0) (format "; %d project%s not indexed" unindexed (if (= unindexed 1) "" "s")) ""))
                                                 (when (zerop (length indexes)) "Set Up Semantic Search in a project"))))))))

(drgnx-doctor-define 'work :group "drgnx" :doc "The work tracker (SQLite in Emacs; SVG for its graph)"
                     :check (lambda (f)
                              (cond ((not (plist-get f :sqlite)) (list 'fail "this Emacs has no SQLite: the work tracker is off" "use an Emacs built with SQLite (the installer's does)"))
                                    ((null (plist-get f :work-plans)) (list 'info "nothing scanned yet" "drgnx work scan (or Show Work)"))
                                    ((not (plist-get f :svg)) (list 'warn (format "%d plans tracked; this Emacs cannot show SVG: no Work graph" (plist-get f :work-plans))
                                                                    drgnx-doctor-install-hint))
                                    (t (list 'ok (format "%d plans tracked" (plist-get f :work-plans)) nil)))))

(drgnx-doctor-define 'key-conflicts :group "drgnx" :doc "Key profile conflicts and keys.eld problems (from the last session)"
                     :check (lambda (f)
                              (let* ((r (plist-get f :keys-report)) (conflicts (plist-get r :conflicts)) (problems (plist-get r :problems)))
                                (cond ((null r) (list 'info "no key report yet — start drgnx once" nil))
                                      (problems (list 'warn (format "%d key problem%s: %s" (length problems) (if (cdr problems) "s" "")
                                                                    (string-join problems "; "))
                                                      "fix ~/.config/drgnx/keys.eld (docs/guide/keys.md)"))
                                      (conflicts (list 'info (format "%d key conflicts, resolved by layer order (%s): %s" (length conflicts)
                                                                     (mapconcat (lambda (l) (symbol-name (car l))) (plist-get r :layers) " < ")
                                                                     (string-join (seq-take conflicts 3) "; "))
                                                       "see Keyboard Shortcuts › Key conflicts; change them in keys.eld (docs/guide/keys.md)"))
                                      (t (list 'ok (format "no key conflicts (%s)"
                                                           (mapconcat (lambda (l) (symbol-name (car l))) (plist-get r :layers) " < "))
                                               nil))))))

(drgnx-doctor-define 'display-rules :group "drgnx" :doc "drgnx's entry in display-buffer-alist is still there (from the last session)"
                     :check (lambda (f)
                              (let ((r (plist-get f :wb-report)))
                                (cond ((null r) (list 'info "no workbench report yet — start drgnx once" nil))
                                      ((plist-get r :display-buffer-entry) (list 'ok "buffers are placed by drgnx's rules" nil))
                                      (t (list 'warn "drgnx's entry in display-buffer-alist is gone: something set the variable after startup, so buffers are no longer placed by the rules"
                                               "use (add-to-list 'display-buffer-alist …) instead of setq in your configuration, or restart drgnx"))))))

(drgnx-doctor-define 'macos-app :group "drgnx" :platform 'macos :doc "The drgnx app in ~/Applications (Finder, Spotlight, the Dock)"
                     :check (lambda (f)
                              (if (plist-get f :macos-app) (list 'ok "the drgnx app is installed" nil)
                                (list 'warn "the drgnx app is not installed: no drgnx in Finder, Spotlight or the Dock" "drgnx macos-app"))))

(drgnx-doctor-define 'brew :group "Tools" :platform 'macos :doc "Homebrew (ripgrep, fd, podman and mise come from it)"
                     :check (lambda (f)
                              (if (plist-get f :brew) (list 'ok "Homebrew found" nil)
                                (list 'warn "Homebrew not found" "install Homebrew (https://brew.sh), or run the installer again"))))

(drgnx-doctor-define 'drgnx-on-path :group "drgnx" :platform 'macos
                     :doc "The drgnx command is on PATH (for Terminal): on this PATH, or ~/.local/bin/drgnx with the PATH line of your shell's profile (~/.zprofile for zsh, else ~/.profile)"
                     :check (lambda (f)
                              (if (plist-get f :drgnx-on-path) (list 'ok "drgnx is on PATH" nil)
                                (list 'warn "drgnx is not on PATH: Terminal does not find the command"
                                      (format "add ~/.local/bin to PATH: echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> %s  (then open a new Terminal)"
                                              (or (plist-get f :shell-profile) "~/.zprofile"))))))

(drgnx-doctor-define 'modal :group "drgnx" :doc "Vim keys: the modal engine (evil) is installed and running (from the last session)"
                     :check (lambda (f)
                              (let* ((r (plist-get f :keys-report)) (modal (plist-get r :modal))
                                     (engine (plist-get modal :engine))
                                     (module-status (plist-get (alist-get (or (plist-get modal :module) ; a report before :module: evil's
                                                                              (and engine (intern (format "editor/%s" engine))))
                                                                          (plist-get f :modules-report))
                                                               :status))
                                     (m-spc (and (equal (plist-get r :leader-menu-key) "M-SPC")
                                                 "M-SPC replaces Emacs' cycle-spacing"))
                                     (say (lambda (detail) (if m-spc (format "%s; %s" detail m-spc) detail))))
                                (cond ((null r) (list 'info "no key report yet — start drgnx once" nil))
                                      ((and engine (not (plist-get modal :running)))
                                       (list 'warn (funcall say (format "Vim keys need %s (%s)" engine
                                                                        (if (eq module-status 'missing-packages) "not installed"
                                                                          "installed, not running: restart drgnx")))
                                             "drgnx sync, then restart — or Keyboard Profile… to choose another"))
                                      ((plist-get modal :pending) (list 'info (funcall say "Vim waits for drgnx sync") "drgnx sync"))
                                      ((plist-get modal :suspended) (list 'ok "modal editing is off for this session" nil))
                                      ((null engine) (list 'ok "no modal engine needed" nil))
                                      ((and m-spc (string-search "GNOME" (or (plist-get f :desktop) "")))
                                       (list 'info (funcall say "Alt+Space opens GNOME's window menu before drgnx sees it: Settings → Keyboard → Keyboard Shortcuts → Windows")
                                             nil))
                                      (t (list 'ok (funcall say (format "Vim keys: %s running" engine)) nil))))))

(dolist (tool '((ui-mutter :mutter "mutter" "the headless compositor of drgnx test --ui" linux)
                (ui-dbus :dbus-run-session "dbus-run-session" "a private D-Bus per test session" linux)
                (ui-magick :magick "magick" "ImageMagick 7: screenshot compositing" nil)
                (ui-pgtk :pgtk-emacs "a pgtk Emacs (emacs-pgtk)" "the GUI Emacs of harness sessions" linux)))
  (pcase-let ((`(,name ,key ,bin ,why ,platform) tool))
    (drgnx-doctor-define name :group "Development" :dev t :platform platform :doc (format "%s (%s)" bin why)
                         :check (lambda (f)
                                  (if (plist-get f key) (list 'ok (format "%s found" bin) nil)
                                    (list 'warn (format "%s not found (%s)" bin why) (format "install %s" bin)))))))

;;;; The Terminal group
;; Each check reads (plist-get FACTS :terminal) (`drgnx-doctor-terminal-facts') and is absent (nil) outside a
;; terminal, except `terminal', which says so.  Read-only: no prompt, nothing installed, tmux asked once (1 s).

(defun drgnx-doctor--tty-row (tf)
  "The row of `drgnx-tty-terminals' for the terminal of the terminal facts TF, nil for an unknown one."
  (drgnx-tty-terminal (plist-get (plist-get tf :identity) :id)))

(defun drgnx-doctor--tty-fix (row key)
  "ROW's fix line for the missing capability KEY (:kkp is `kkp'), or nil."
  (cdr (assq key (plist-get row :fixes))))

(defun drgnx-doctor--tty-define (name doc fn)
  "Define the Terminal check NAME: FN (called with the terminal facts and all facts) runs only in a terminal."
  (drgnx-doctor-define name :group "Terminal" :doc doc
                       :check (lambda (f)
                                (let ((tf (plist-get f :terminal)))
                                  (when (plist-get tf :in-terminal) (funcall fn tf f))))))

(defun drgnx-doctor--tty-name (id)
  "ID's name as the terminal table has it."
  (or (plist-get (drgnx-tty-terminal id) :name) (and id (symbol-name id))))

(defun drgnx-doctor--terminfo-fix (term)
  "The ways to get a terminfo entry for TERM onto this machine (the terminal runs somewhere else)."
  (string-join
   (delq nil (list (format "from the machine your terminal runs on: infocmp -x | ssh HOST tic -x -   (installs the entry for %s)" term)
                   (when (member term '("xterm-kitty" "xterm-ghostty"))
                     "or use kitten ssh HOST in kitty, or Ghostty's ssh-terminfo shell integration (shell-integration-features)")
                   "or connect with TERM=xterm-256color"))
   "; "))

(defun drgnx-doctor--key-table (rows)
  "ROWS, (CHORD NATIVE-P ALT PREFIX) as `drgnx-tty-fallback-report-rows' gives them, as aligned text: the chord,
whether the terminal sends it itself, the Alt+Shift key that stands for it (— where it is in use or reserved) and
the F6 form."
  (let* ((cells (mapcar (pcase-lambda (`(,chord ,native ,alt ,prefix))
                          (list chord (if native "yes" "no")
                                (if alt (drgnx-tty-fallback-label alt) "—")
                                (if prefix (drgnx-tty-fallback-label prefix) "—")))
                        rows))
         (all (cons '("chord" "native" "fallback" "prefix") cells))
         (widths (apply #'cl-mapcar #'max (mapcar (lambda (r) (mapcar #'string-width r)) all))))
    (mapconcat (lambda (r)
                 (string-trim-right
                  (string-join (cl-mapcar (lambda (c w) (concat c (make-string (- w (string-width c)) ?\s))) r widths) "  ")))
               all "\n")))

(defun drgnx-doctor--tty-keys-mode (tf)
  "How TF's terminal sends keys: `kkp', `mok' or `legacy' (measured when a window of it has been open, else from
what its table row or tmux's extended-keys say), nil when that cannot be told."
  (let ((row (drgnx-doctor--tty-row tf)) (id (plist-get (plist-get tf :identity) :id)))
    (or (plist-get (plist-get tf :caps) :keys)
        (cond ((eq id 'tmux)
               (when (plist-get tf :tmux)
                 (if (member (plist-get (plist-get tf :tmux) :extended-keys) '("on" "always")) 'mok 'legacy)))
              ((and row (not (plist-get row :kkp)) (not (plist-get row :mok))) 'legacy)))))

(defun drgnx-doctor--tty-colours (tf)
  "The number of colours TF's terminal shows (measured, else guessed from TERM), or nil."
  (or (plist-get (plist-get tf :caps) :colors)
      (let ((term (or (plist-get tf :term) "")))
        (cond ((equal term "linux") 16)
              ((string-match-p "direct\\'" term) 16777216)
              ((string-match-p "256" term) 256)))))

(defun drgnx-doctor--tty-true-colour-p (tf)
  (let ((colors (plist-get (plist-get tf :caps) :colors)))
    (if colors (>= colors 16777216)
      (or (member (downcase (or (plist-get tf :colorterm) "")) '("truecolor" "24bit"))
          (plist-get (plist-get tf :tmux) :rgb)
          (string-suffix-p "-direct" (or (plist-get tf :term) ""))))))

(defun drgnx-doctor--tty-osc52-p (tf)
  "Whether copy reaches the clipboard from TF's terminal: measured, else tmux's options, else its table row."
  (let ((caps (plist-get tf :caps)) (tmux (plist-get tf :tmux)))
    (cond (caps (plist-get caps :osc52))
          (tmux (or (equal (plist-get tmux :set-clipboard) "on") (member (plist-get tmux :allow-passthrough) '("on" "all"))))
          (t (plist-get (drgnx-doctor--tty-row tf) :osc52)))))

(drgnx-doctor-define 'terminal :group "Terminal" :doc "Which terminal this is, its TERM and terminfo"
                     :check (lambda (f)
                              (let* ((tf (plist-get f :terminal)) (id (plist-get (plist-get tf :identity) :id))
                                     (row (drgnx-doctor--tty-row tf)) (term (plist-get tf :term))
                                     (outer (plist-get (plist-get tf :identity) :outer)))
                                (cond ((plist-get tf :error) (list 'warn (format "could not check: %s" (plist-get tf :error))
                                                                   "run drgnx doctor again from a terminal"))
                                      ((not (plist-get tf :in-terminal)) (list 'info "not run from a terminal" nil))
                                      (t (let* ((name (cond ((eq id 'tmux)
                                                             (concat "tmux" (when-let* ((v (or (plist-get (plist-get tf :tmux) :version)
                                                                                               (plist-get (plist-get tf :identity) :version))))
                                                                              (concat " " v))
                                                                     (when outer (format " in %s" (drgnx-doctor--tty-name outer)))))
                                                            (row (plist-get row :name))
                                                            (t "a terminal drgnx does not know")))
                                                (detail (format "%s (TERM=%s), terminfo %s" name term
                                                                (cond ((plist-get tf :terminfo) "found")
                                                                      ((plist-get tf :ssh) "missing (terminal-ssh has the fixes)")
                                                                      (t "missing")))))
                                           (cond ((and (not (plist-get tf :terminfo)) (plist-get tf :ssh)) (list 'info detail nil))
                                                 ((not (plist-get tf :terminfo)) (list 'warn detail (drgnx-doctor--terminfo-fix term)))
                                                 ((null row) (list 'info detail "F1 (VS Code keys) and the palette, or M-x, reach every command"))
                                                 (t (list 'ok detail nil)))))))))

(drgnx-doctor--tty-define
 'terminal-colours "Colours: true colour where the terminal has it"
 (lambda (tf _f)
   (let* ((n (drgnx-doctor--tty-colours tf)) (row (drgnx-doctor--tty-row tf))
          (shown (if n (format "%d colours" n) "an unknown number of colours")))
     (cond ((drgnx-doctor--tty-true-colour-p tf) (list 'ok "true colour (24-bit)" nil))
           ((eq (plist-get (plist-get tf :identity) :id) 'tmux)
            (list 'info (format "%s (terminal-tmux says what tmux needs for true colour)" shown) nil))
           ((null row) (list 'info (format "%s; true colour was not detected" shown) nil))
           ((plist-get row :truecolor)
            (list 'warn (format "%s, although %s has true colour" shown (plist-get row :name))
                  "export COLORTERM=truecolor where the terminal starts your shell (over SSH the variable must be sent as well); drgnx then opens true-colour windows"))
           (t (list 'warn (format "%s: %s has no true colour" shown (plist-get row :name))
                    (drgnx-doctor--tty-fix row 'truecolor)))))))

(drgnx-doctor--tty-define
 'terminal-mouse "The mouse reaches drgnx"
 (lambda (tf _f)
   (let ((row (drgnx-doctor--tty-row tf)) (caps (plist-get tf :caps)))
     (if (if caps (plist-get caps :mouse) (or (null row) (plist-get row :mouse)))
         (list 'ok "mouse reports are on: clicks, the wheel and drags work" nil)
       (list 'warn "this terminal sends no mouse reports" (drgnx-doctor--tty-fix row 'mouse))))))

(drgnx-doctor--tty-define
 'terminal-keys "Keys: the kitty keyboard protocol or modifyOtherKeys, else the Alt+Shift and F6 fallbacks"
 (lambda (tf _f)
   (let* ((mode (drgnx-doctor--tty-keys-mode tf)) (caps (plist-get tf :caps)) (row (drgnx-doctor--tty-row tf))
          (id (plist-get (plist-get tf :identity) :id)))
     (pcase mode
       ('kkp (list 'ok (concat "the kitty keyboard protocol: every shortcut works"
                               (when (eq (plist-get caps :c-g) 'waits) " (C-g stops only programs Emacs waits for)"))
                   nil))
       ('mok (if-let* ((folded (plist-get caps :folded)))
                 (list 'info (format "modifyOtherKeys, but tmux sends %d chords as other keys (C-S-<letter> …): Alt+Shift or F6 then the key" (length folded))
                       "type those chords as Alt+Shift or F6 then the key; or customize drgnx-tty-tmux-mok-level to 2 (then C-g cannot stop busy Lisp)")
               (list 'ok "modifyOtherKeys: C-S- chords and the like work (Super keys need the kitty keyboard protocol)" nil)))
       ('legacy
        (let* ((rows (plist-get tf :fallbacks))
               (own (when-let* ((x (drgnx-doctor--tty-fix row 'kkp))) (and (not (string-prefix-p "none" x)) x)))
               (recommendation (plist-get (drgnx-tty-recommendation (list :keys 'legacy) (plist-get tf :os)) :text)))
          (list 'warn
                (concat "neither the kitty keyboard protocol nor modifyOtherKeys: this terminal cannot send C-S- chords and the like\n"
                        (if rows (drgnx-doctor--key-table rows) "open drgnx in this terminal once to list them"))
                ;; tmux with extended-keys already on: the terminal around it is what cannot send the keys
                (if (and (eq id 'tmux) (not (member (plist-get (plist-get tf :tmux) :extended-keys) '("on" "always"))))
                    (drgnx-doctor--tty-fix row 'mok)
                  (concat recommendation (when own (format " In %s: %s." (plist-get row :name) own)))))))
       (_ (list 'info (if row
                          (format "not measured yet; %s %s (open drgnx in this terminal once to check)" (plist-get row :name)
                                  (cond ((eq id 'tmux) "passes modifyOtherKeys only with extended-keys on")
                                        ((plist-get row :kkp) "speaks the kitty keyboard protocol")
                                        ((plist-get row :mok) "speaks modifyOtherKeys")
                                        (t "sends only the basic keys")))
                        "this terminal is not known to drgnx: open drgnx in it once to measure its keys")
                nil))))))

(drgnx-doctor--tty-define
 'terminal-clipboard "Copy reaches your clipboard (OSC 52)"
 (lambda (tf _f)
   (let ((row (drgnx-doctor--tty-row tf)))
     (cond ((drgnx-doctor--tty-osc52-p tf) (list 'ok "copy reaches your clipboard (OSC 52)" nil))
           ((null row) (list 'info "drgnx does not know whether this terminal takes OSC 52: copy stays in drgnx" nil))
           (t (list 'warn "copy stays in drgnx: nothing carries OSC 52 to your clipboard" (drgnx-doctor--tty-fix row 'osc52)))))))

(defconst drgnx-doctor--tmux-line-names
  '(("set-clipboard" . "copy") ("allow-passthrough" . "copy") ("extended-keys" . "keys") ("focus-events" . "focus")
    ("terminal-features" . "true colour"))
  "The option each line of `drgnx-tty-tmux-conf-lines' sets → what it is for.")

(drgnx-doctor-define 'terminal-tmux :group "Terminal" :doc "tmux passes copy, keys, focus and true colour on"
                     :check (lambda (f)
                              (let* ((tf (plist-get f :terminal)) (tmux (plist-get tf :tmux)))
                                (when (and (plist-get tf :in-terminal)
                                           (or tmux (eq (plist-get (plist-get tf :identity) :id) 'tmux)))
                                  (if tmux
                                      (if-let* ((lines (drgnx-tty-tmux-conf-lines tmux)))
                                          (list 'warn
                                                (format "tmux lacks: %s"
                                                        (string-join (delete-dups
                                                                      (mapcar (lambda (line)
                                                                                (cdr (seq-find (lambda (n) (string-search (car n) line))
                                                                                               drgnx-doctor--tmux-line-names)))
                                                                              lines))
                                                                     ", "))
                                                (format "add to ~/.tmux.conf: %s, then run tmux source ~/.tmux.conf" (string-join lines "; ")))
                                        (list 'ok (format "tmux %s: copy, keys, focus and true colour are set" (or (plist-get tmux :version) ""))
                                              nil))
                                    ;; tmux on the other side of SSH, or one that did not answer
                                    (list 'info "tmux, but drgnx cannot ask it (the other side of SSH, or no answer within 1 s)"
                                          (format "check ~/.tmux.conf there for: %s; then run tmux source ~/.tmux.conf"
                                                  (string-join (drgnx-tty-tmux-conf-lines
                                                                (list :version "3.3" :outer-term "TERM-OF-YOUR-TERMINAL"))
                                                               "; "))))))))

(drgnx-doctor--tty-define
 'terminal-ssh "Over SSH: this machine has the terminfo entry of the terminal's TERM"
 (lambda (tf _f)
   (when (plist-get tf :ssh)
     (let ((term (plist-get tf :term)))
       (if (plist-get tf :terminfo)
           (list 'ok (format "over SSH: terminfo for %s found here; keys, mouse and OSC 52 travel unchanged" term) nil)
         (list 'warn (format "over SSH: this machine has no terminfo entry for TERM=%s (Emacs falls back to 8 colours or refuses the terminal)" term)
               (drgnx-doctor--terminfo-fix term)))))))

(drgnx-doctor--tty-define
 'terminal-popups "Popups: floating on Emacs 31.1, in the bottom lane on 30.2"
 (lambda (_tf f)
   (if (version< (plist-get f :version) "31.1")
       (list 'info "popups in the bottom lane; 31.1 has floating ones" nil)
     (list 'ok "popups float over the text (child frames)" nil))))

;;;; Desktop: the window manager (core/drgnx-platform.el)

(defconst drgnx-doctor--wm-packages
  '((sway :pkg "sway") (i3 :pkg "i3" :arch "i3-wm") (hyprland :pkg "hyprland" :fedora nil) (niri :pkg "niri"))
  "Adapter → plist: :pkg, the package with the adapter's tool (Fedora 45's names, the m12c facts); a family's key
(:fedora, :debian, :arch) names that family's package instead, nil when its repositories lack it (Fedora has no
Hyprland; on Arch `i3' is a group and `i3-wm' has i3-msg).")

(defun drgnx-doctor--wm-install (wm os)
  "The command that installs the tool of WM on OS (`drgnx-tty-os'), or how to get it; never runs it."
  (when-let* ((entry (alist-get wm drgnx-doctor--wm-packages)))
    (let* ((family (drgnx-tty--family os))
           (key (and (memq family '(fedora debian arch)) (intern (format ":%s" family))))
           (pkg (if (and key (plist-member entry key)) (plist-get entry key) (plist-get entry :pkg))))
      (unless pkg (setq pkg (plist-get entry :pkg) family nil))
      (pcase family
        ('fedora (concat (if (plist-get os :ostree) "rpm-ostree install " "sudo dnf install ") pkg))
        ('debian (concat "sudo apt install " pkg))
        ('arch (concat "sudo pacman -S " pkg))
        (_ (format "install %s with your package manager" pkg))))))

(defun drgnx-doctor--window-manager (wf)
  "The Desktop row (STATUS DETAIL FIX) from WF, `drgnx-platform-doctor-facts'."
  (let* ((title (plist-get wf :title)) (n (plist-get wf :monitors)) (tool (plist-get wf :tool))
         (can (plist-get wf :can-move)))
    (pcase (plist-get wf :wm)
      ((or 'none 'tty)
       (list 'info "no graphical session here: run drgnx doctor in your desktop's terminal to check its window manager" nil))
      ('other-wayland
       (list 'info (format "%s (Wayland): no adapter; drgnx leaves window placement to it"
                           (or (plist-get wf :desktop) "this compositor"))
             nil))
      ('gnome (list 'ok "GNOME (Wayland): apps cannot move windows; use Super+Shift+←/→" nil))
      (wm (cond ((and tool (not (plist-get wf :tool-found)))
                 (list 'warn (format "%s: %s not found: Move to Monitor and restore need it" title tool)
                       (drgnx-doctor--wm-install wm (drgnx-tty-os))))
                ((and tool (not (plist-get wf :answers)))
                 (list 'warn (format "%s did not answer within %g s" title drgnx-platform-doctor-timeout)
                       (format "run drgnx doctor from a terminal inside your %s session" title)))
                ((not (eq can t)) (list 'warn (format "%s: %s" title (car can)) (cdr can)))
                (t (list 'ok (format "%s%s%s: Move to Monitor and restore work%s" title
                                     (if-let* ((v (plist-get wf :version))) (concat " " v) "")
                                     (if n (format ", %d monitor%s" n (if (= n 1) "" "s")) "")
                                     (if (plist-get wf :frame-positions) " (frame positions)" ""))
                         nil)))))))

(drgnx-doctor-define 'window-manager :group "Desktop"
                     :doc "The window manager, its monitors, and whether Move to Monitor and restore work there"
                     :check (lambda (f) (when-let* ((wf (plist-get f :window-manager))) (drgnx-doctor--window-manager wf))))

;;;; Running and reporting

(defun drgnx-doctor-run (facts &optional dev group)
  "Results (plists :name :group :status :detail :fix) of every check on FACTS; DEV adds dev checks; GROUP (a
string) keeps only that group's.  A check that returns nil is absent from the results."
  (cl-loop for (name . spec) in drgnx-doctor--checks
           when (and (or dev (not (plist-get spec :dev)))
                     (or (null group) (equal group (plist-get spec :group)))
                     (memq (plist-get spec :platform) (list nil (drgnx-platform))))
           nconc (let ((result (condition-case err (funcall (plist-get spec :check) facts)
                                 (error (list 'fail (format "the check itself failed: %s" (error-message-string err)) nil)))))
                   (when result
                     (pcase-let ((`(,status ,detail ,fix) result))
                       (list (list :name name :group (plist-get spec :group) :status status :detail detail :fix fix)))))))

(defun drgnx-doctor-format (results)
  "RESULTS as text: one line per check, the fix indented below anything not ok.  A detail of several lines (a
table) continues indented by the same six spaces."
  (mapconcat (lambda (r)
               (concat (format "%-5s %-20s %s" (upcase (if (eq (plist-get r :status) 'ok) "ok" (symbol-name (plist-get r :status))))
                               (plist-get r :name) (string-replace "\n" "\n      " (format "%s" (plist-get r :detail))))
                       (if (and (plist-get r :fix) (not (eq (plist-get r :status) 'ok)))
                           (format "\n      fix: %s" (plist-get r :fix)) "")))
             results "\n"))

(defun drgnx-doctor-json (results)
  (decode-coding-string
   (json-serialize (vconcat (mapcar (lambda (r) (list :name (symbol-name (plist-get r :name)) :group (plist-get r :group)
                                                      :status (symbol-name (plist-get r :status))
                                                      :detail (plist-get r :detail) :fix (or (plist-get r :fix) :null)))
                                    results)))
   'utf-8))

(defun drgnx-doctor-exit-code (results)
  (if (seq-some (lambda (r) (eq (plist-get r :status) 'fail)) results) 1 0))

(defun drgnx-doctor-cli ()
  "Batch entry: `drgnx doctor [--json] [--dev]'."
  (let* ((args (prog1 command-line-args-left (setq command-line-args-left nil)))
         (results (drgnx-doctor-run (drgnx-doctor-facts) (member "--dev" args))))
    (princ (if (member "--json" args) (drgnx-doctor-json results) (drgnx-doctor-format results)))
    (terpri)
    (kill-emacs (drgnx-doctor-exit-code results))))

(provide 'drgnx-doctor)
;;; drgnx-doctor.el ends here
