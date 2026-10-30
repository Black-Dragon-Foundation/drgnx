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
(require 'drgnx-guard)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-tty-recommend)   ; the terminal table, tmux, the fallback keys and the recommendation (all read-only)
(require 'drgnx-platform)        ; the window manager (the Desktop row)

(defvar nidhogg-version)   ; bound by Nidhogg, drgnx's own Emacs build

(declare-function package-built-in-p "package")
(declare-function drgnx-portable-config-problems "drgnx-portable")
(declare-function drgnx-user-lisp-bootstraps "drgnx-user-lisp" (&optional files))
(declare-function drgnx-notice-save-dir "drgnx-notice-save")
(declare-function drgnx-notice-save-last-file "drgnx-notice-save")
(declare-function drgnx-notice-save-pid-live-p "drgnx-notice-save")

(defconst drgnx-doctor-install-hint
  "run the installer: curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash  (see docs/guide/install.md)"
  "How to get a suitable Emacs.")

(defconst drgnx-doctor-nidhogg-hint
  "run the installer again: it builds Nidhogg (see docs/guide/install.md, \"Nidhogg\")"
  "How to get Nidhogg, drgnx's own Emacs build.")

(defconst drgnx-doctor-security-issues
  '(("CVE-2026-108976" "TRAMP: the first fix left user names with ! # & , and control characters" "31.2")
    ("CVE-2026-96442" "Flymake backends run code from the file being edited" "31.2")
    ("CVE-2026-96269" "read-symbol-shorthands in a file's local variables redirect symbol lookup" "31.2" "31.1"))
  "The Emacs issues the `security' check names: (ID WHAT FIXED-IN [PARTLY-FROM]).
An issue applies below FIXED-IN; from PARTLY-FROM on, only some of its ways in are closed.  The elisp Flymake
backend (CVE-2024-53920) is not here: every supported Emacs (31.1 and later) closes it with `trusted-content'.")

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
(declare-function drgnx-pkg-service-unit-file "drgnx-pkg")
(declare-function drgnx-pkg--unit-exec-start "drgnx-pkg")
(declare-function drgnx-file-read-bounded "drgnx-file")

(defun drgnx-doctor--service-unit ()
  "The facts of the `service-unit' check: nil (no unit file), (:file F :emacs E :drgnx BOOL) or (:error MESSAGE)."
  (condition-case err
      (progn
        (require 'drgnx-pkg)
        (let* ((file (drgnx-pkg-service-unit-file))
               (text (drgnx-file-read-bounded file)))
          (when text
            (pcase (drgnx-pkg--unit-exec-start text)
              (`(,_ ,emacs ,drgnx) (list :file file :emacs emacs :drgnx (and drgnx t)))
              (_ (list :file file :emacs nil :drgnx nil))))))
    (error (list :error (error-message-string err)))))

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
(declare-function drgnx-ai-providers "drgnx-ai")

(defun drgnx-doctor--ai-up ()
  "The providers the last probe found running."
  (ignore-errors
    (require 'drgnx-ai-probe)
    (mapcar #'car (seq-filter (lambda (e) (plist-get (cdr e) :up)) (drgnx-ai-detected-cached)))))

(defun drgnx-doctor--ai-env-keys ()
  "The names of the providers' key variables (`:key-env') set in this Emacs's environment, in provider order: names
only, never a value."
  (ignore-errors
    (require 'drgnx-ai)
    (delete-dups (cl-loop for (_ . p) in (drgnx-ai-providers)
                          for env = (plist-get p :key-env)
                          when (and (stringp env) (let ((v (getenv env))) (and v (not (string-empty-p v)))))
                          collect env))))

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

(declare-function drgnx-sandbox-check "drgnx-sandbox")
(defvar drgnx-sandbox-memory-max)

(defun drgnx-doctor--sandbox ()
  "The fact of the `job-sandbox' check: `drgnx-sandbox-check' (its probes take at most a few seconds) with
:memory-max, `drgnx-sandbox-memory-max', and :memory-max-default t when no init file was loaded (`drgnx doctor'
runs with -Q, so it sees the default, not the user's setting); or (:error MESSAGE)."
  (condition-case err
      (progn (require 'drgnx-sandbox)
             (append (drgnx-sandbox-check)
                     (list :memory-max drgnx-sandbox-memory-max :memory-max-default (null user-init-file))))
    (error (list :error (error-message-string err)))))

(defun drgnx-doctor--job-sandbox-check (s)
  "The `job-sandbox' check of the fact S (`drgnx-doctor--sandbox')."
  (let ((program (if (eq (plist-get s :backend) 'seatbelt) "sandbox-exec" "bwrap")))
    (cond ((null s) (list 'info "not checked" nil))
          ((plist-get s :error) (list 'warn (format "could not check: %s" (plist-get s :error)) "run drgnx doctor again"))
          ((plist-get s :ok)
           (list 'ok (concat program (if (plist-get s :version) (concat " " (plist-get s :version)) "") " ok"
                             (cond ((not (eq (plist-get s :backend) 'bwrap)) "")
                                   ((null (plist-get s :memory-max)) "; no memory cap (drgnx-sandbox-memory-max is nil)")
                                   ((plist-get s :scope)
                                    (format "; memory cap %s per agent%s" (plist-get s :memory-max)
                                            (if (plist-get s :memory-max-default) " by default (drgnx-sandbox-memory-max)" "")))
                                   (t "; no memory cap (no systemd user manager answers)")))
                 nil))
          (t (list 'warn (format "jobs' agents cannot be sandboxed, so jobs do not start: %s" (plist-get s :reason))
                   (plist-get s :fix))))))

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
(declare-function drgnx-commands-get "drgnx-registry")
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
    drgnx-modules
    drgnx-keys
    drgnx-ai
    drgnx-pkg
    drgnx-session
    drgnx-search-chunk
    drgnx-onboard
    drgnx-face-state
    drgnx-gc-census
    )
  "The core features whose loading defines config files, for the `config-files' check.")

(declare-function drgnx-config-read "drgnx-config")
(declare-function drgnx-config-names "drgnx-config")

(defun drgnx-doctor--config-files ()
  "The fact of the `config-files' check: (NAME :status :problem :unknown-keys :file) for every defined file that is
not a project's, from a fresh `drgnx-config-read' (it applies nothing and writes nothing), by name; or (:error MESSAGE)."
  (condition-case err
      (progn
        (require 'drgnx-config)
        (dolist (feature drgnx-doctor-config-features) (require feature))
        (mapcar (lambda (name)
                  (let ((r (drgnx-config-read name)))
                    (list name :status (plist-get r :status) :problem (plist-get r :problem)
                          :unknown-keys (plist-get r :unknown-keys) :file (plist-get r :file))))
                (drgnx-config-names '(config state))))
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

(declare-function drgnx-settings-migrate-leftovers "drgnx-settings-migrate" ())
(declare-function drgnx-settings-migrate-stayed "drgnx-settings-migrate" ())

(defun drgnx-doctor--settings-leftovers ()
  "The fact of the `settings-migrated' check: the old settings files left beside settings.el after the move into it
\(`drgnx-settings-migrate-leftovers'), or (:error MESSAGE)."
  (condition-case err (progn (require 'drgnx-settings-migrate) (drgnx-settings-migrate-leftovers))
    (error (list :error (error-message-string err)))))

(defun drgnx-doctor--settings-stayed ()
  "The fact of the `settings-migrated' check's second half: the old settings files no longer read whose values
settings.el does not hold, ((FILE WHY)…) (`drgnx-settings-migrate-stayed'), or (:error MESSAGE)."
  (condition-case err (progn (require 'drgnx-settings-migrate) (drgnx-settings-migrate-stayed))
    (error (list :error (error-message-string err)))))

(defun drgnx-doctor--settings-leftovers-check (files &optional stayed)
  "The `settings-migrated' check of the facts FILES (`drgnx-doctor--settings-leftovers') and STAYED
\(`drgnx-doctor--settings-stayed'): nil (no row) when there are none."
  (let ((err (cl-find-if (lambda (f) (eq (car-safe f) :error)) (list files stayed))))
    (cond (err (list 'warn (format "could not check: %s" (cadr err)) "run drgnx doctor again"))
          (stayed (list 'warn (format "no longer read: %s"
                                      (mapconcat (lambda (s) (format "%s (%s)" (file-name-nondirectory (car s)) (cadr s)))
                                                 stayed "; "))
                        "fix the file (Open Config File), then Settings: Migrate Old Files adds its values to settings.el"))
          (files (list 'warn (format "already migrated: %s (settings.el holds their values)"
                                     (mapconcat #'file-name-nondirectory files ", "))
                       "Settings: Move Old Files Away moves them into migrated-DATE/ (a copy is kept)")))))

(declare-function drgnx-settings-trust-doctor-roots "drgnx-settings-trust" ())

(defun drgnx-doctor--dir-locals-trusted ()
  "The fact of the `dir-locals-trusted' check: the folders of `safe-local-variable-directories' that are not folders
you trusted (`drgnx-settings-trust-doctor-roots'), or (:error MESSAGE)."
  (condition-case err (progn (require 'drgnx-settings-trust) (drgnx-settings-trust-doctor-roots))
    (error (list :error (error-message-string err)))))

(defun drgnx-doctor--dir-locals-trusted-check (dirs)
  "The `dir-locals-trusted' check of the fact DIRS (`drgnx-doctor--dir-locals-trusted'): nil (no row) when there
are none."
  (cond ((eq (car-safe dirs) :error) (list 'warn (format "could not check: %s" (cadr dirs)) "run drgnx doctor again"))
        (dirs (list 'warn (format "every directory-local value applies there, risky ones included: %s"
                                  (mapconcat #'abbreviate-file-name dirs ", "))
                    "take them out of safe-local-variable-directories (custom.el) and use Trust This Folder: its code waits for review"))))

(declare-function drgnx-settings-tidy-facts "drgnx-settings-tidy" (&optional file))

(defun drgnx-doctor--custom-file (&optional file)
  "The fact of the `custom-file' check: custom.el's size, entries and dormant entries (`drgnx-settings-tidy-facts'
of FILE, default custom.el), nil when it is missing, or (:error MESSAGE)."
  (condition-case err (progn (require 'drgnx-settings-tidy) (drgnx-settings-tidy-facts file))
    (error (list :error (error-message-string err)))))

(defun drgnx-doctor--custom-file-check (c)
  "The `custom-file' check of the fact C (`drgnx-doctor--custom-file'): information only; nil (no row) when
custom.el is missing."
  (cond ((null c) nil)
        ((plist-get c :error) (list 'info (format "could not check: %s" (plist-get c :error)) nil))
        (t (let ((dormant (plist-get c :dormant)) (n (plist-get c :entries)))
             (list 'info
                   (concat (format "%s: %s, %d entr%s, %d dormant" (file-name-nondirectory (plist-get c :file))
                                   (file-size-human-readable (plist-get c :bytes) 'iec " ") n (if (= n 1) "y" "ies")
                                   (length dormant))
                           (if dormant (format " (nothing in this Emacs defines %s)"
                                               (mapconcat #'symbol-name dormant ", "))
                             "")
                           (if (plist-get c :problem) (format "\n%s" (plist-get c :problem)) ""))
                   (and (or dormant (plist-get c :problem))
                        "Settings: Tidy custom.el (it lists the dormant entries, with Remove)"))))))

(defun drgnx-doctor--config-dir ()
  "The fact of the `config-dir' check: (:dir THE-CONFIG-DIR :moved WHERE-IT-BELONGS-OR-NIL :ignored IGNORED),
IGNORED being `drgnx-paths-ignored'."
  (list :dir (drgnx-user-dir) :moved (drgnx-paths-config-moved-p) :ignored (drgnx-paths-ignored)))

(defun drgnx-doctor--state-in-temp ()
  "The state directory when it lies inside the temporary directory (TRAMP then asks about autosave on a local
temporary directory, and a daemon's state would go with the next cleanup), else nil."
  (let ((state (file-name-as-directory (file-truename (drgnx-state-dir))))
        (tmp (file-name-as-directory (file-truename temporary-file-directory))))
    (and (string-prefix-p tmp state) state)))

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
                                   ;; done once Emacs has read all of git's output (`process-live-p' turns nil
                                   ;; before that); the default sentinel would write "Process … finished" into BUF
                                   :sentinel (drgnx-guard-wrap
                                              (lambda (p _event) (unless (process-live-p p) (process-put p :done t)))
                                              "doctor git")
                                   :command (list "git" "-C" (directory-file-name default-directory)
                                                  "status" "--porcelain" "--" "init/")))
               (deadline (+ (float-time) 5)))
          (unwind-protect
              (progn
                (while (and (not (process-get proc :done)) (< (float-time) deadline)) (accept-process-output proc 0.05))
                (cond ((not (process-get proc :done)) (delete-process proc) (list :error "git status took more than 5 s"))
                      ((not (eql (process-exit-status proc) 0)) (list :error "git status failed"))
                      (t (list :dir dir :changed (split-string (with-current-buffer buf (buffer-string)) "\n" t)))))
            (kill-buffer buf)))
      (error (list :error (error-message-string err))))))

(defun drgnx-doctor-facts ()
  "Facts about the running Emacs and this machine."
  (let ((native (and (fboundp 'native-comp-available-p) (native-comp-available-p))))
    (append
     (list :version emacs-version
           :nidhogg (bound-and-true-p nidhogg-version)
           :running-emacs (expand-file-name invocation-name invocation-directory)
           :service-unit (drgnx-doctor--service-unit)
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
           :ai-env-keys (drgnx-doctor--ai-env-keys)
           :ai-complete (ignore-errors (require 'drgnx-ai) (cdr (car (drgnx-ai-role 'complete))))
           :claude-adapter (drgnx-doctor--claude-adapter)
           :sandbox (drgnx-doctor--sandbox)
           :ratatoskr (drgnx-doctor--ratatoskr)
           :vram (ignore-errors (require 'drgnx-ai-probe) (drgnx-ai-vram))
           :trust-guards (drgnx-doctor--trust-guards)
           :config-dir (drgnx-doctor--config-dir)
           :state-in-temp (drgnx-doctor--state-in-temp)
           :config-files (drgnx-doctor--config-files)
           :settings-leftovers (drgnx-doctor--settings-leftovers)
           :settings-stayed (drgnx-doctor--settings-stayed)
           :dir-locals-trusted (drgnx-doctor--dir-locals-trusted)
           :user-lisp-bootstraps (condition-case nil (progn (require 'drgnx-user-lisp) (drgnx-user-lisp-bootstraps)) (error nil))
           :custom-file (drgnx-doctor--custom-file)
           :checkout-init (drgnx-doctor--checkout-init drgnx-dir)
           :timers-report (drgnx-doctor--timers-report)
           :notices (drgnx-doctor--notices)
           :statusbar-slow (drgnx-doctor--state-file "statusbar-slow.eld")   ; the status bar's slow entries
           :statusbar-slow-time (drgnx-doctor--state-file-time "statusbar-slow.eld")
           ;; file names only: a key found in the config dir is never part of the facts
           :portable (condition-case err (progn (require 'drgnx-portable) (drgnx-portable-config-problems))
                       (error (list :error (error-message-string err)))))
     (and (eq (drgnx-platform) 'macos) (drgnx-doctor--macos-facts)))))

(defun drgnx-doctor--state-path (name)
  "The file NAME in the state dir."
  (expand-file-name name (drgnx-state-dir)))

(defun drgnx-doctor--state-file (name)
  "The .eld file NAME the last drgnx session wrote in the state dir, read, or nil."
  (let ((r (drgnx-file-read (drgnx-doctor--state-path name))))
    (and (eq (plist-get r :status) 'ok) (plist-get r :data))))

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

(defun drgnx-doctor--notices ()
  "The notice session files (`drgnx-notice-save'), read, never written: (:live DATAS :last DATA :crashed DATAS).
A file is live when its pid is a running Emacs; `last.eld' is the last session; the file of a dead pid is crashed,
and ignored when older than 7 days."
  (require 'drgnx-notice-save)
  (let ((dir (drgnx-notice-save-dir)) (limit (- (float-time) (* 7 86400))) (live nil) (crashed nil))
    (dolist (file (and (file-directory-p dir) (directory-files dir t "\\`[0-9]+\\.eld\\'")))
      (let* ((alive (drgnx-notice-save-pid-live-p (string-to-number (file-name-base file))))
             (mtime (float-time (file-attribute-modification-time (file-attributes file)))))
        (when (or alive (>= mtime limit))
          (let ((r (drgnx-file-read file)))
            (when (eq (plist-get r :status) 'ok)
              (if alive (push (plist-get r :data) live) (push (plist-get r :data) crashed)))))))
    (let ((r (drgnx-file-read (drgnx-notice-save-last-file))))
      (list :live (nreverse live) :crashed (nreverse crashed)
            :last (and (eq (plist-get r :status) 'ok) (plist-get r :data))))))

(defun drgnx-doctor--notices-found (source datas)
  "SOURCE's notices in the session DATAS merged by key, the later :at winning: a list of (NOTICE . PID)."
  (let ((found nil))
    (dolist (data datas)
      (dolist (n (plist-get data :notices))
        (when (eq (plist-get n :source) source)
          (let* ((key (plist-get n :id)) (old (assoc key found)))
            (cond ((null old) (push (cons key (cons n (plist-get data :pid))) found))
                  ((> (or (plist-get n :at) 0) (or (plist-get (cadr old) :at) 0))
                   (setcdr old (cons n (plist-get data :pid)))))))))
    (mapcar #'cdr (nreverse found))))

(defun drgnx-doctor--notices-datas (notices)
  "The session files of NOTICES (the `:notices' fact) that count: the live ones, else the crashed and the last."
  (or (plist-get notices :live)
      (append (plist-get notices :crashed) (and (plist-get notices :last) (list (plist-get notices :last))))))

(defun drgnx-doctor--with-terminal-notices (result facts)
  "RESULT, a check result (STATUS DETAIL FIX), with the `terminal' notices of FACTS' sessions after its detail
\(the `drgnx-keys-tty-fallback' lines that could not apply); a clean RESULT becomes `warn'."
  (let ((texts (mapcar (lambda (f) (plist-get (car f) :text))
                       (drgnx-doctor--notices-found 'terminal (drgnx-doctor--notices-datas (plist-get facts :notices))))))
    (if (or (null result) (null texts))
        result
      (list (if (memq (car result) '(ok info)) 'warn (car result))
            (concat (nth 1 result) "\n" (string-join texts "\n"))
            (nth 2 result)))))

(defun drgnx-doctor--notices-check (source notices)
  "The check result (STATUS DETAIL FIX) of SOURCE's notices in NOTICES, the `:notices' fact."
  (let* ((live (plist-get notices :live))
         (datas (drgnx-doctor--notices-datas notices)))
    (if (null datas)
        (list 'info "no session recorded yet — start drgnx once" nil)
      (let ((found (drgnx-doctor--notices-found source datas)))
        (if (null found)
            (list 'ok "no problems" nil)
          (let* ((texts (mapcar (lambda (f) (plist-get (car f) :text)) found))
                 (shown (append (seq-take texts 5)
                                (and (nthcdr 5 texts) (list (format "and %d more" (- (length texts) 5))))))
                 (rank '((info . 0) (warn . 1) (fail . 2)))
                 (worst (car (sort (mapcar (lambda (f) (plist-get (car f) :severity)) found)
                                   (lambda (a b) (> (alist-get a rank 0) (alist-get b rank 0))))))
                 (where (cond ((null live)
                               (format " (from the last session, %s)"
                                       (drgnx-doctor--age (apply #'max (mapcar (lambda (d) (or (plist-get d :written) 0))
                                                                               datas)))))
                              ((cdr live)
                               (format " (this session, pid %s)"
                                       (mapconcat #'number-to-string (seq-uniq (mapcar #'cdr found)) ", ")))
                              (t " (this session)"))))
            (list worst (concat (string-join shown "; ") where)
                  (seq-some (lambda (f) (plist-get (car f) :fix)) found))))))))

(cl-defun drgnx-doctor-define-notices (source &key group doc name)
  "Define the check NAME (default SOURCE) in GROUP: what notice source SOURCE says in the session files.
It reads the live sessions (merged by key), else the last session and the crashed ones; the status is the worst
severity, the fix the first `:fix'."
  (drgnx-doctor-define (or name source) :group group :doc doc
                       :check (lambda (f) (drgnx-doctor--notices-check source (plist-get f :notices)))))

(defun drgnx-doctor--keys-report ()
  "The key report the last drgnx session wrote (keys-report.eld in the state dir), or nil."
  (drgnx-doctor--state-file "keys-report.eld"))

;;;; Checks

(defun drgnx-doctor--version< (a b) (version< a b))

(drgnx-doctor-define 'emacs-version :group "Emacs" :doc "Nidhogg, drgnx's own Emacs build (stock GNU Emacs fails)"
                     :check (lambda (f)
                              (let ((v (plist-get f :version)) (n (plist-get f :nidhogg)))
                                (cond ((drgnx-doctor--version< v "31.1")
                                       (list 'fail (format "Emacs %s is too old (31.1 or newer needed)" v) drgnx-doctor-install-hint))
                                      (n (list 'ok (format "Nidhogg %s (GNU Emacs %s)" n v) nil))
                                      (t (list 'fail (format "GNU Emacs %s is not Nidhogg, drgnx's own Emacs build" v)
                                               drgnx-doctor-nidhogg-hint))))))

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
                                (list 'ok "terminal-only Emacs: drgnx runs in terminals (no images, one font size)" nil))))

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

(drgnx-doctor-define 'config-dir :group "drgnx" :doc "The config folder is where XDG_CONFIG_HOME says (docs/guide/files.md)"
                     :check (lambda (f)
                              (let* ((c (plist-get f :config-dir))
                                     (ignored (mapcar (lambda (i)
                                                        (format "ignored: not an absolute path: %s=%s; drgnx uses %s"
                                                                (nth 0 i) (nth 1 i)
                                                                (abbreviate-file-name (directory-file-name (nth 2 i)))))
                                                      (plist-get c :ignored))))
                                (cond ((null c) nil)
                                      ((plist-get c :moved)
                                       (list 'warn (string-join
                                                    (cons (format "%s is used: $XDG_CONFIG_HOME/drgnx does not exist"
                                                                  (abbreviate-file-name (plist-get c :dir)))
                                                          ignored)
                                                    "\n")
                                             (format "move ~/.config/drgnx to %s ($XDG_CONFIG_HOME/drgnx)"
                                                     (abbreviate-file-name (directory-file-name (plist-get c :moved))))))
                                      (ignored (list 'warn (string-join ignored "\n")
                                                     "set it to an absolute path (one that begins with /), or unset it"))
                                      (t (list 'ok (abbreviate-file-name (plist-get c :dir)) nil))))))

(drgnx-doctor-define 'state-dir :group "drgnx" :doc "The state folder is not inside the temporary directory"
                     :check (lambda (f)
                              (if-let* ((dir (plist-get f :state-in-temp)))
                                  (list 'warn (format "state is kept in %s, inside the temporary directory" (abbreviate-file-name dir))
                                        "set XDG_STATE_HOME to a folder outside the temporary directory")
                                (list 'ok "outside the temporary directory" nil))))

(drgnx-doctor-define 'config-files :group "drgnx" :doc "drgnx's config files read, with no mistakes"
                     :check (lambda (f) (drgnx-doctor--config-files-check (plist-get f :config-files))))

(drgnx-doctor-define 'settings-migrated :group "drgnx"
                     :doc "No old settings file (keys.eld, agents.eld …) is left beside settings.el after the move into it"
                     :check (lambda (f) (drgnx-doctor--settings-leftovers-check (plist-get f :settings-leftovers)
                                                                                (plist-get f :settings-stayed))))

(drgnx-doctor-define 'dir-locals-trusted :group "drgnx"
                     :doc "No folder in safe-local-variable-directories that you did not trust with Trust This Folder"
                     :check (lambda (f) (drgnx-doctor--dir-locals-trusted-check (plist-get f :dir-locals-trusted))))

(drgnx-doctor-define 'user-lisp-bootstrap :group "drgnx"
                     :doc "A package-initialize, straight.el or elpaca bootstrap in a Lisp file you added (not drgnx's package manager)"
                     :check (lambda (f)
                              (when-let* ((bs (plist-get f :user-lisp-bootstraps)))
                                (list 'info
                                      (mapconcat (lambda (b) (format "%s:%s is a %s bootstrap"
                                                                     (abbreviate-file-name (plist-get b :file))
                                                                     (plist-get b :line) (plist-get b :kind)))
                                                 bs "\n")
                                      "drgnx manages packages itself (drgnx sync); nothing is blocked, but the bootstrap may install a second set"))))

(drgnx-doctor-define 'custom-file :group "drgnx"
                     :doc "custom.el's size and its entries nothing defines (information)"
                     :check (lambda (f) (drgnx-doctor--custom-file-check (plist-get f :custom-file))))

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

(drgnx-doctor-define 'service-unit :group "drgnx" :platform 'linux
                     :doc "The systemd unit starts the Emacs drgnx uses"
                     :check (lambda (f)
                              (let ((u (plist-get f :service-unit)) (running (plist-get f :running-emacs)))
                                (cond ((null u) nil)
                                      ((plist-get u :error) (list 'info (format "could not check: %s" (plist-get u :error)) nil))
                                      ((not (plist-get u :drgnx))
                                       (list 'info (format "%s is not drgnx's daemon unit: left alone" (abbreviate-file-name (plist-get u :file))) nil))
                                      ((equal (file-truename (plist-get u :emacs)) (file-truename running))
                                       (list 'ok (format "drgnx.service runs %s" (plist-get u :emacs)) nil))
                                      (t (list 'warn (format "drgnx.service starts %s, but drgnx uses %s" (plist-get u :emacs) running)
                                               "drgnx service-unit --refresh, then: systemctl --user restart drgnx"))))))

(drgnx-doctor-define 'job-sandbox :group "Agents"
                     :doc "Jobs' agents run in a sandbox: bubblewrap (bwrap) on Linux, sandbox-exec on macOS"
                     :check (lambda (f) (drgnx-doctor--job-sandbox-check (plist-get f :sandbox))))

(drgnx-doctor-define-notices 'modules :group "drgnx" :doc "Modules that failed, wait or are off (this session, or the last one)")

;; Ratatoskr, the agent runtime (runtime/): its binary's own report (`ratatoskr doctor --json', 2 s), the checkout's HEAD,
;; the last update's record and this Emacs's SQLite.  Nothing here starts a hub or prompts.
(declare-function drgnx-hub-client-binary "drgnx-hub-client")
(declare-function drgnx-state-dir "drgnx-paths")
(declare-function drgnx-data-dir "drgnx-paths")

(defun drgnx-doctor--ratatoskr-report (binary)
  "BINARY's `doctor --json' parsed (plists, false and null as nil), or nil when it does not answer within 2 s."
  (let* ((buf (generate-new-buffer " *ratatoskr doctor*" t))
         (p (make-process :name "ratatoskr-doctor" :buffer buf :noquery t :connection-type 'pipe
                          ;; no default sentinel: it would append "Process … finished" to the JSON
                          :command (list binary "doctor" "--json") :sentinel #'ignore))
         (limit (+ (float-time) 2)))
    (unwind-protect
        (progn
          (while (and (process-live-p p) (< (float-time) limit)) (accept-process-output p 0.05))
          ;; a fast binary counts as exited before its output is read (Emacs's SIGCHLD handler records the exit): read
          ;; what it left
          (unless (process-live-p p) (while (accept-process-output p 0)))
          (when (and (eq (process-status p) 'exit) (eql (process-exit-status p) 0))
            (with-current-buffer buf
              (ignore-errors (json-parse-string (buffer-string) :object-type 'plist :false-object nil :null-object nil)))))
      (when (process-live-p p) (delete-process p))
      (kill-buffer buf))))

(defun drgnx-doctor--ratatoskr ()
  "The facts of the `ratatoskr' check:
\(:binary FILE-or-nil :report PLIST-or-nil :head SHA :update-run LINE :emacs-sqlite V)."
  (condition-case err
      (let* ((bin (progn (require 'drgnx-hub-client) (drgnx-hub-client-binary)))
             (head (ignore-errors
                     (car (process-lines "git" "-C" (expand-file-name drgnx-dir) "rev-parse" "HEAD"))))
             (run (ignore-errors
                    (drgnx-file-read-bounded (expand-file-name "update/last-run" (drgnx-state-dir)) :max-bytes 4096))))
        (list :binary bin :report (and bin (drgnx-doctor--ratatoskr-report bin)) :head head
              :update-run (and run (string-trim run))
              :emacs-sqlite (and (fboundp 'sqlite-version) (ignore-errors (sqlite-version)))))
    (error (list :error (error-message-string err)))))

(defun drgnx-doctor--sqlite-wal-bug-p (v)
  "Whether the SQLite version string V is in 3.7.0 to 3.51.2, which has the WAL-reset bug (storage design, section 2)."
  (and (stringp v) (version<= "3.7.0" v) (version<= v "3.51.2")))

(defun drgnx-doctor--ratatoskr-sandbox-line (s)
  "The detail line for the job sandbox section S of `ratatoskr doctor --json' (nil without one).
It only informs: nothing runs in the sandbox yet (phase 6), so the check's status never depends on it.  The
section's `pins_note' (the reduced tier cannot pin your settings files in a job's folders) ends the line."
  (when s
    (concat
     (if (plist-get s :ok)
         (format "job sandbox backend: %s%s works here (%s); job agents do not use it yet (phase 6)"
                 (plist-get s :backend)
                 (if-let* ((v (plist-get s :version))) (concat " " v) "")
                 (if (equal (plist-get s :backend) "seatbelt")
                     "Seatbelt"
                   (format "Landlock ABI %s, seccomp" (plist-get s :landlock_abi))))
       (format "job sandbox backend: not available here: %s%s"
               (or (plist-get s :reason) "unknown")
               (if-let* ((fix (plist-get s :fix))) (concat " — " fix) "")))
     (if-let* ((note (plist-get s :pins_note)) ((stringp note))) (concat "; " note) ""))))

(defun drgnx-doctor--ratatoskr-check (f)
  "The `ratatoskr' check of the fact F (`drgnx-doctor--ratatoskr'): failures first, then warnings."
  (let* ((report (plist-get f :report))
         (bin (plist-get report :binary))
         (running (plist-get report :running))
         (sock (plist-get report :socket_dir))
         (commit (plist-get bin :commit))
         (head (plist-get f :head))
         (run (plist-get f :update-run))
         (esql (plist-get f :emacs-sqlite)))
    (cond
     ((plist-get f :error) (list 'warn (format "could not check: %s" (plist-get f :error)) "run drgnx doctor again"))
     ((null (plist-get f :binary))
      (list 'fail "no Ratatoskr binary: agents cannot start" "drgnx runtime build --install (install.sh builds it)"))
     ((null report)
      (list 'fail (format "%s gave no answer to doctor --json within 2 s" (abbreviate-file-name (plist-get f :binary)))
            "drgnx runtime build --install"))
     ((plist-get bin :test_hooks)
      (list 'fail "the binary was built with test hooks (a debug surface)" "drgnx runtime build --install"))
     ((not (plist-get sock :ok))
      (list 'fail (format "the socket directory %s is mode %s, not private (0700) or not yours" (plist-get sock :path) (plist-get sock :mode))
            (format "chmod 700 %s (and check who owns it)" (plist-get sock :path))))
     ((and run (string-search "failed: runtime build failed" run))
      (list 'warn (substring run (string-search "failed: runtime build failed" run))
            "the update was rolled back; fix the toolchain, then drgnx update"))
     ((and head commit (not (equal (string-remove-suffix "-dirty" commit) head)))
      (list 'warn (format "the binary is from %s, the checkout is at %s" (substring commit 0 (min 7 (length commit))) (substring head 0 (min 7 (length head))))
            "run drgnx runtime build --install"))
     ((and running (plist-get running :commit) commit (not (equal (plist-get running :commit) commit)))
      (list 'warn (format "the running hub is %s, the binary %s" (plist-get running :commit) commit) "Hub: Restart Now"))
     ((drgnx-doctor--sqlite-wal-bug-p esql)
      (list 'warn (format "this Emacs's SQLite %s has a bug in its write-ahead log (3.7.0 to 3.51.2)" esql)
            "use an Emacs built with SQLite 3.51.3 or newer (Nidhogg); Ratatoskr's own SQLite is not affected"))
     (t (list 'ok (format "Ratatoskr %s; job agents: %s%s" (or commit "?") (or (plist-get report :job_agents) "unknown")
                          (if-let* ((line (drgnx-doctor--ratatoskr-sandbox-line (plist-get report :sandbox))))
                              (concat "; " line)
                            ""))
              nil)))))

(drgnx-doctor-define 'ratatoskr :group "Agents"
                     :doc "Ratatoskr, the agent runtime: built, current, no test hooks, a private socket directory"
                     :check (lambda (f) (drgnx-doctor--ratatoskr-check (plist-get f :ratatoskr))))

;; The work store (work.db, Urdr): the `store' section of `ratatoskr doctor --json' (schema, a failed migration, the
;; WAL, the backups, the personal-notes opt-in file, the copies a deny-list kept text out of).
(defun drgnx-doctor--store-check (f)
  "The `store' check of the fact F (`drgnx-doctor--ratatoskr'): a failed migration fails, any warning warns."
  (let* ((store (plist-get (plist-get (plist-get f :ratatoskr) :report) :store))
         (failed (plist-get store :failed))
         (warnings (append (plist-get store :warnings) nil))
         (denied (append (plist-get store :denied_in) nil))
         (age (plist-get store :backup_age_s)))
    (cond
     ((null store) (list 'ok "no work.db yet, or no answer from the hub" nil))
     (failed
      (list 'fail (format "the move of work.db to schema 7 failed: %s" failed)
            "`ratatoskr store restore-pre7' (hub stopped) puts the pre-migration copy back; install the previous drgnx"))
     (warnings
      (list 'warn (string-join warnings "; ")
            (if denied
                (format "remove the copies once you no longer need them: %s" (string-join denied ", "))
              "see docs/guide/work.md, \"The graph from the command line\"")))
     (denied
      (list 'warn (format "the migration kept personal notes out; these copies still hold them: %s" (string-join denied ", "))
            "remove them once you no longer need them"))
     (t (list 'ok (format "schema %s%s%s; %d personal-notes opt-in%s"
                          (or (plist-get store :schema) "?")
                          (if-let* ((w (plist-get store :wal_bytes)))
                              (format ", WAL %d KiB" (/ w 1024))
                            "")
                          (if age (format ", last backup %d h ago" (/ age 3600)) ", no backup yet")
                          (or (plist-get (plist-get store :deny_list) :opted_in) 0)
                          (if (eql (or (plist-get (plist-get store :deny_list) :opted_in) 0) 1) "" "s"))
              nil)))))

(drgnx-doctor-define 'store :group "Agents"
                     :doc "The work store (work.db): its schema, WAL size, nightly backups, opt-in file and old copies"
                     :check (lambda (f) (drgnx-doctor--store-check f)))

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

(defun drgnx-doctor--ai-env-keys-check (names)
  "The `ai-env-keys' check of NAMES (`drgnx-doctor--ai-env-keys'): an information line when some are set — the key
stays in this Emacs's environment, its children inherit it, agents use the hub's copy — else ok."
  (if (null names)
      (list 'ok "no provider key in this Emacs's environment; the hub holds the keys AI: Load Keys gave it" nil)
    (let ((one (null (cdr names))))
      (list 'info
            (format "%s %s set in this Emacs's environment; children inherit %s; agents use the %s the hub holds"
                    (string-join names ", ") (if one "is" "are") (if one "it" "them") (if one "copy" "copies"))
            "to keep a key out of shells and compile commands too, keep it in your Keychain or keyring instead (AI: Load Keys hands it to the hub; docs/guide/security.md)"))))

(drgnx-doctor-define 'ai-env-keys :group "drgnx" :doc "Provider keys in this Emacs's environment (they stay there; the hub holds its own copy)"
                     :check (lambda (f) (drgnx-doctor--ai-env-keys-check (plist-get f :ai-env-keys))))

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

(drgnx-doctor-define-notices 'keys :name 'key-problems :group "drgnx" :doc "keys.eld and profile problems")

(drgnx-doctor-define 'key-conflicts :group "drgnx" :doc "Key profile conflicts (from the last session)"
                     :check (lambda (f)
                              (let* ((r (plist-get f :keys-report)) (conflicts (plist-get r :conflicts)))
                                (cond ((null r) (list 'info "no key report yet — start drgnx once" nil))
                                      (conflicts (list 'info (format "%d key conflicts, resolved by layer order (%s): %s" (length conflicts)
                                                                     (mapconcat (lambda (l) (symbol-name (car l))) (plist-get r :layers) " < ")
                                                                     (string-join (seq-take conflicts 3) "; "))
                                                       "see Keyboard Shortcuts › Key conflicts; change them in settings.el (docs/guide/keys.md)"))
                                      (t (list 'ok (format "no key conflicts (%s)"
                                                           (mapconcat (lambda (l) (symbol-name (car l))) (plist-get r :layers) " < "))
                                               nil))))))

(drgnx-doctor-define-notices 'wb :name 'display-rules :group "drgnx" :doc "Buffers are placed by drgnx's rules")

(drgnx-doctor-define 'portable-config :group "drgnx"
                     :doc "The config dir travels as it is: no key in plain text, no machine-local file (docs/guide/second-machine.md)"
                     :check (lambda (f)
                              ;; never ok unless everything was checked: a scan that failed, or skipped files, is info
                              (let* ((p (plist-get f :portable)) (keys (plist-get p :keys)) (local (plist-get p :machine-local))
                                     (both (plist-get p :in-both)) (unchecked (plist-get p :unchecked))
                                     (err (plist-get p :error)) (roots (plist-get p :missing-roots))
                                     (parts (delq nil (list (and keys (format "a key in plain text in %s" (string-join keys ", ")))
                                                            (and local (format "machine-local files in the config dir: %s" (string-join local ", ")))
                                                            (and err (format "could not check the config dir: %s" err))
                                                            (and unchecked (format "could not check %d file%s: %s" (length unchecked)
                                                                                   (if (cdr unchecked) "s" "") (string-join unchecked ", ")))
                                                            (and roots (format "not cloned on this machine: %s" (string-join roots ", "))))))
                                     (fixes (delq nil (append (list (and keys "move it to your keyring (docs/guide/ai.md#keys)")
                                                                    (and (cl-set-difference local both :test #'equal)
                                                                         "drgnx bootstrap --step config moves them"))
                                                              (mapcar (lambda (i) (format "%s has its own copy in the data dir, which drgnx uses: compare them, then delete the config dir's"
                                                                                          (directory-file-name i)))
                                                                      both)
                                                              (list (and (or err unchecked) "make them readable, then run drgnx doctor again")
                                                                    (and roots "clone them to work on them here (docs/guide/second-machine.md)"))))))
                                (cond ((or keys local) (list 'warn (string-join parts "; ") (string-join fixes "; ")))
                                      (parts (list 'info (string-join parts "; ") (string-join fixes "; ")))
                                      (t (list 'ok "the config dir can travel as it is" nil))))))

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
                                     (module-status (plist-get modal :module-status))   ; the session's, in the key report
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
 (lambda (tf f)
   (drgnx-doctor--with-terminal-notices   ; the fallback's problems are the session's `terminal' notices
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
                 nil))))
    f)))

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

(defun drgnx-doctor--timers-report ()
  "The stopped timers the last session and the last hub wrote (timers-report.eld, hub-timers-report.eld in the
state dir): a list of (:file NAME :stopped PLISTS :time WRITTEN), one per file there."
  (let ((out nil))
    (dolist (name '("timers-report.eld" "hub-timers-report.eld"))
      (when-let* ((report (drgnx-doctor--state-file name)))
        (push (list :file name :stopped (plist-get report :stopped) :time (drgnx-doctor--state-file-time name)) out)))
    (nreverse out)))

(drgnx-doctor-define 'timers :group "drgnx" :doc "Timers that stopped after failing 3 times in a row (from the last session)"
                     :check (lambda (f)
                              (let ((stopped nil) (time nil))
                                (dolist (r (plist-get f :timers-report))
                                  (when (plist-get r :stopped)
                                    (setq stopped (append stopped (plist-get r :stopped)))
                                    (when (plist-get r :time) (setq time (max (or time 0) (plist-get r :time))))))
                                (if (null stopped)
                                    (list 'ok "no timer stopped" nil)
                                  (list 'warn
                                        (concat (mapconcat (lambda (s) (format "%s (%s): %s" (plist-get s :key) (plist-get s :fn)
                                                                               (plist-get s :error)))
                                                           stopped "; ")
                                                (if time (format " (from the last session, %s)" (drgnx-doctor--age time)) ""))
                                        "report the error; drgnx starts the timer again at the next start")))))

(drgnx-doctor-define 'statusbar-misc :group "drgnx"
                     :doc "Mode-line entries of other packages too slow to format on every redisplay (from the last session)"
                     :check (lambda (f)
                              (let ((slow (plist-get f :statusbar-slow)))
                                (if (null slow)
                                    (list 'ok "every entry is formatted in real time" nil)
                                  (list 'warn
                                        (concat (mapconcat (lambda (r) (format "%s takes %.1f ms per redisplay: refreshed once a second"
                                                                               (plist-get r :entry) (or (plist-get r :avg-ms) 0)))
                                                           slow "; ")
                                                (when-let* ((time (plist-get f :statusbar-slow-time)))
                                                  (format " (reported %s)" (drgnx-doctor--age time))))
                                        "ask its package for a cheaper `:eval', or remove it from `mode-line-misc-info'")))))

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
