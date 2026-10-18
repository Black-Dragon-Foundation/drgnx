;;; drgnx-doctor.el --- Is this machine ready for drgnx? -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx doctor' runs these checks in batch, inside the Emacs drgnx will use, so every
;; answer is about that Emacs.  A check is a function of a facts plist (gathered once by
;; `drgnx-doctor-facts', injected in tests) returning (STATUS DETAIL FIX), STATUS one of
;; `ok', `warn', `fail' or `info'.  Any `fail' makes the doctor exit 1.  Modules will add
;; their own checks with `drgnx-doctor-define' (M4).  A check may be for one platform (:platform `linux' or
;; `macos'): on the other it is absent from the results.  See docs/guide/install.md.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(declare-function package-built-in-p "package")
(declare-function drgnx-portable-config-problems "drgnx-portable")

(defconst drgnx-doctor-install-hint
  "run the installer: curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash  (see docs/guide/install.md)"
  "How to get a suitable Emacs.")

(defconst drgnx-doctor-cves-fixed-in-31.2
  "TRAMP command injection via crafted file names, Flymake running code from edited files, read-symbol-shorthands code execution on opening a file"
  "Known security issues in Emacs up to 31.1, fixed in 31.2 (not released as of 2026-10-16).")

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
           ;; whether a key is set, from the environment only: the doctor never opens auth-source (it may prompt)
           :ai-keys (let ((k (getenv "OPENROUTER_API_KEY"))) (and k (not (string-empty-p k)) '(openrouter)))
           :ai-complete (ignore-errors (require 'drgnx-ai) (cdr (car (drgnx-ai-role 'complete))))
           :vram (ignore-errors (require 'drgnx-ai-probe) (drgnx-ai-vram))
           ;; file names only: a key found in the config dir is never part of the facts
           :portable (condition-case err (progn (require 'drgnx-portable) (drgnx-portable-config-problems))
                       (error (list :error (error-message-string err)))))
     (and (eq (drgnx-platform) 'macos) (drgnx-doctor--macos-facts)))))

(defun drgnx-doctor--state-path (name)
  "The file NAME in the state dir."
  (expand-file-name (concat "drgnx/" name) (or (getenv "XDG_STATE_HOME") "~/.local/state")))

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
  (let ((file (expand-file-name "drgnx/keys-report.eld" (or (getenv "XDG_STATE_HOME") "~/.local/state"))))
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

(drgnx-doctor-define 'gui :group "Emacs" :doc "A graphical build (pgtk on Wayland, X11 or macOS)"
                     :check (lambda (f)
                              (if-let* ((g (plist-get f :gui))) (list 'ok (format "graphical build (%s)" g) nil)
                                (list 'warn "terminal-only Emacs: drgnx's workbench needs a graphical build" drgnx-doctor-install-hint))))

(drgnx-doctor-define 'security :group "Emacs" :doc "Known security issues of this Emacs version"
                     :check (lambda (f)
                              (if (drgnx-doctor--version< (plist-get f :version) "31.2")
                                  (list 'warn (format "Emacs up to 31.1 has known issues fixed in 31.2: %s" drgnx-doctor-cves-fixed-in-31.2)
                                        "update to 31.2 when it is released; until then avoid opening untrusted files and remote paths")
                                (list 'ok "no known issues for this version" nil))))

(drgnx-doctor-define 'git :group "Tools" :doc "git (installing and updating drgnx)"
                     :check (lambda (f)
                              (if (plist-get f :git) (list 'ok "git found" nil)
                                (list 'warn "git not found" "install git with your package manager"))))

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

(dolist (tool '((ui-mutter :mutter "mutter" "the headless compositor of drgnx test --ui" linux)
                (ui-dbus :dbus-run-session "dbus-run-session" "a private D-Bus per test session" linux)
                (ui-magick :magick "magick" "ImageMagick 7: screenshot compositing" nil)
                (ui-pgtk :pgtk-emacs "a pgtk Emacs (emacs-pgtk)" "the GUI Emacs of harness sessions" linux)))
  (pcase-let ((`(,name ,key ,bin ,why ,platform) tool))
    (drgnx-doctor-define name :group "Development" :dev t :platform platform :doc (format "%s (%s)" bin why)
                         :check (lambda (f)
                                  (if (plist-get f key) (list 'ok (format "%s found" bin) nil)
                                    (list 'warn (format "%s not found (%s)" bin why) (format "install %s" bin)))))))

;;;; Running and reporting

(defun drgnx-doctor-run (facts &optional dev)
  "Results (plists :name :group :status :detail :fix) of every check on FACTS; DEV adds dev checks."
  (cl-loop for (name . spec) in drgnx-doctor--checks
           when (and (or dev (not (plist-get spec :dev)))
                     (memq (plist-get spec :platform) (list nil (drgnx-platform))))
           collect (pcase-let ((`(,status ,detail ,fix)
                                (condition-case err (funcall (plist-get spec :check) facts)
                                  (error (list 'fail (format "the check itself failed: %s" (error-message-string err)) nil)))))
                     (list :name name :group (plist-get spec :group) :status status :detail detail :fix fix))))

(defun drgnx-doctor-format (results)
  "RESULTS as text: one line per check, the fix indented below anything not ok."
  (mapconcat (lambda (r)
               (concat (format "%-5s %-20s %s" (upcase (if (eq (plist-get r :status) 'ok) "ok" (symbol-name (plist-get r :status))))
                               (plist-get r :name) (plist-get r :detail))
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
