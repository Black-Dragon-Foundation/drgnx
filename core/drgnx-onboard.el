;;; drgnx-onboard.el --- Onboarding: the steps from a fresh machine to a working drgnx -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Onboarding is a list of steps — environment, look and keys, projects, AI, search, agents, daemon,
;; portability, finish — each a registry command ("Onboarding: Import Projects"), re-runnable,
;; idempotent, its progress kept in onboarding.eld (state dir) so a run resumes where it stopped.  A
;; step returns (STATUS MESSAGE); an error is a failed step, never fatal.  `drgnx onboard' runs them
;; from the command line (--non-interactive never reads input); "Welcome" lists them in Emacs.
;; Nothing is installed outside drgnx's own directories unless the user, running a step
;; interactively, says yes.  See docs/guide/onboarding.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-session)
(require 'drgnx-tty)
(require 'drgnx-tty-recommend)

(defvar drgnx-onboard--steps nil "Alist ID → plist (:title :doc :order :run :check).")
(defvar drgnx-onboard--current nil "The id of the step running now.")
(defvar drgnx-onboard--progress nil "(STEP . TEXT): what a step waiting on a job is doing, shown in the Welcome.")

(defun drgnx-onboard-define-step (id &rest spec)
  "Define onboarding step ID: SPEC has :title :doc :order, :run (CONTEXT → (STATUS MESSAGE)) and an
optional :check (CONTEXT → (STATUS MESSAGE), which replaces the result unless it is ok).  CONTEXT is
a plist (:interactive BOOL :options PLIST).  STATUS: ok, info, warn or fail."
  (setf (alist-get id drgnx-onboard--steps) spec)
  id)

(defun drgnx-onboard-steps ()
  "Step ids in order."
  (mapcar #'car (sort (copy-sequence drgnx-onboard--steps)
                      (lambda (a b) (< (or (plist-get (cdr a) :order) 0) (or (plist-get (cdr b) :order) 0))))))

;;;; Progress

(defun drgnx-onboard-state-file () (expand-file-name "onboarding.eld" (drgnx-state-dir)))

(defun drgnx-onboard-state ()
  "Alist ID → (:status :message :time) of the steps run so far."
  (and (file-readable-p (drgnx-onboard-state-file))
       (ignore-errors (with-temp-buffer (insert-file-contents (drgnx-onboard-state-file)) (read (current-buffer))))))

(defun drgnx-onboard--write-state (state)
  (make-directory (file-name-directory (drgnx-onboard-state-file)) t)
  (let ((tmp (make-temp-file (expand-file-name ".onboarding-" (file-name-directory (drgnx-onboard-state-file))))))
    (with-temp-file tmp (let ((print-length nil)) (prin1 state (current-buffer))))
    (rename-file tmp (drgnx-onboard-state-file) t)))

(defun drgnx-onboard--record (id status message)
  (let ((state (drgnx-onboard-state)))
    (setf (alist-get id state) (list :status status :message message :time (format-time-string "%FT%T%z")))
    (drgnx-onboard--write-state state)))

(cl-defun drgnx-onboard-run (&key only non-interactive resume options)
  "Run the steps (ONLY: a list of ids) in order; RESUME skips steps done (ok or info) before.
NON-INTERACTIVE: never read input (`inhibit-interaction').  OPTIONS: plist for the steps (:preset
:keys :theme :roots …).  Returns ((ID STATUS MESSAGE)…)."
  (let ((ctx (list :interactive (not non-interactive) :options options))
        (done (drgnx-onboard-state))
        (out nil))
    (dolist (id (drgnx-onboard-steps))
      (when (and (or (null only) (memq id only))
                 (not (and resume (memq (plist-get (alist-get id done) :status) '(ok info)))))
        (let* ((spec (alist-get id drgnx-onboard--steps))
               (inhibit-interaction non-interactive)
               (drgnx-onboard--current id)
               (r (condition-case err (funcall (plist-get spec :run) ctx)
                    (error (list 'fail (error-message-string err)))))
               (r (or (and (not (eq (car r) 'fail)) (plist-get spec :check)
                           (let ((c (condition-case err (funcall (plist-get spec :check) ctx)
                                      (error (list 'fail (error-message-string err))))))
                             (and (not (eq (car c) 'ok)) c)))
                      r)))
          (drgnx-onboard--record id (car r) (cadr r))
          (push (list id (car r) (cadr r)) out))))
    (nreverse out)))

;;;; Questions

(defconst drgnx-onboard--listed-choices 6 "A question with at most this many choices lists them in its prompt.")

(defun drgnx-onboard--choose (question choices default)
  "Ask QUESTION: one of CHOICES (strings), DEFAULT on Return alone.  A first start has no completion UI, so the
prompt lists the choices when they are few, and the default (`format-prompt').  An answer that is not a choice is a
`user-error', never taken for one."
  (let ((answer (completing-read (format-prompt (if (<= (length choices) drgnx-onboard--listed-choices)
                                                    (format "%s (%s)" question (string-join choices ", "))
                                                  question)
                                                default)
                                 choices nil t nil nil default)))
    (or (car (member answer choices))
        (user-error "%s: %S is not one of %s" question answer (string-join choices ", ")))))

;;;; Step 1: environment

(defconst drgnx-onboard-tools
  '((git ("git") t (:linux "install git with your package manager (e.g. dnf install git)"
                           :macos "xcode-select --install (git comes with the Command Line Tools)"))
    (ripgrep ("rg") nil (:linux "fast project search: install ripgrep (dnf install ripgrep)"
                                :macos "brew install ripgrep (fast project search)"))
    (fd ("fd" "fdfind") nil (:linux "fast file listing: install fd (dnf install fd-find)"
                                    :macos "brew install fd (fast file listing)"))
    (podman ("podman") nil (:linux "containers for tests and local AI servers: install podman"
                                   :macos "brew install podman, then podman machine init (containers for tests and local AI servers)"))
    (mise ("mise") nil (:linux "language servers and tools per project: https://mise.jdx.dev"
                               :macos "brew install mise (language servers and tools per project)"))
    (gpu ("nvidia-smi" "rocm-smi") nil (:linux "no GPU tool found: local AI models will run on the CPU"
                                               :macos "Apple silicon: models use the shared memory")))
  "(ID PROGRAMS REQUIRED FIX): what drgnx looks for.  FIX is a plist (:linux TEXT :macos TEXT): how to get it.
On macOS the GPU row is always ok (no nvidia-smi or rocm-smi is expected).")

(defun drgnx-onboard--font-p (family)
  "Is the font FAMILY installed?  t or nil; `unknown' when this cannot be told (no graphical frame to ask
Emacs, and no fc-list to ask fontconfig): never nil then, so a missing tool is not read as a missing font."
  (cond ((display-graphic-p) (and (member family (font-family-list)) t))
        ((executable-find "fc-list")
         (with-temp-buffer
           (and (eql 0 (ignore-errors (call-process "fc-list" nil t nil (concat ":family=" family))))
                (> (buffer-size) 0))))
        (t 'unknown)))

(defun drgnx-onboard--command-line-tools-p ()
  "Are the Xcode Command Line Tools installed (`xcode-select -p' succeeds)?"
  (and (executable-find "xcode-select")
       (eql 0 (ignore-errors (call-process "xcode-select" nil nil nil "-p")))))

(defun drgnx-onboard-environment ()
  "Alist ID → (:status ok|missing|unknown :required :fix) for the tools and the icon font; on macOS also
the Xcode Command Line Tools.  :fix is the one for this platform."
  (let ((platform (drgnx-platform)))
    (append
     (mapcar (lambda (tool)
               (pcase-let ((`(,id ,programs ,required ,fix) tool))
                 (cons id (list :status (if (or (and (eq id 'gpu) (eq platform 'macos)) (seq-some #'executable-find programs)) 'ok 'missing)
                                :required required :fix (plist-get fix (if (eq platform 'macos) :macos :linux))))))
             drgnx-onboard-tools)
     (and (eq platform 'macos)
          (list (cons 'xcode-clt (list :status (if (drgnx-onboard--command-line-tools-p) 'ok 'missing) :required nil
                                       :fix "xcode-select --install (git, and the C compiler that builds tree-sitter grammars)"))))
     (list (cons 'icon-font (list :status (pcase (drgnx-onboard--font-p "Symbols Nerd Font") ('unknown 'unknown) ('nil 'missing) (_ 'ok))
                                  :required nil
                                  :fix (if (eq platform 'macos)
                                           "brew install --cask font-symbols-only-nerd-font (icons in the Explorer)"
                                         "icons in the Explorer: install the Symbols Nerd Font (https://www.nerdfonts.com)")))))))

(defun drgnx-onboard--environment-step (_ctx)
  (let* ((env (drgnx-onboard-environment))
         (missing (seq-filter (lambda (e) (eq (plist-get (cdr e) :status) 'missing)) env))
         (unknown (seq-filter (lambda (e) (eq (plist-get (cdr e) :status) 'unknown)) env))
         (unchecked (and unknown (format "%s: could not check" (mapconcat (lambda (e) (symbol-name (car e))) unknown ", ")))))
    (list (cond ((seq-some (lambda (e) (plist-get (cdr e) :required)) missing) 'fail) (missing 'warn) (t 'ok))
          (string-join
           (delq nil (list (if missing
                               (mapconcat (lambda (e) (format "%s missing — %s" (car e) (plist-get (cdr e) :fix))) missing "; ")
                             "every tool drgnx uses is here")
                           unchecked))
           "; "))))

;;;; Step 2: look and keys

(defconst drgnx-onboard-presets
  '((minimal . "the workbench and the built-in modules only")
    (ide . "plus the package-backed editing modules (no AI)")
    (full-ai . "everything, AI included"))
  "Module presets: which extra/ modules run.")

(defun drgnx-onboard--extras ()
  (require 'drgnx-pkg)
  (seq-filter (lambda (m) (string-prefix-p "extra/" (symbol-name m)))
              (mapcar #'car (drgnx-pkg--module-packages (expand-file-name "modules" drgnx-dir)))))

(declare-function drgnx-pkg--module-packages "drgnx-pkg")

(defun drgnx-onboard-apply-preset (preset)
  "Turn the extra/ modules on or off for PRESET (minimal, ide, full-ai); other choices stay."
  (let* ((extras (drgnx-onboard--extras))
         (off (pcase preset
                ('minimal extras)
                ('ide (seq-filter (lambda (m) (memq m '(extra/llm))) extras))
                ('full-ai nil)
                (_ (user-error "Unknown preset %s (minimal, ide, full-ai)" preset))))
         (state (drgnx-modules-read-state)))
    (drgnx-modules-write-state
     (plist-put (copy-sequence state) :disabled
                (append (seq-remove (lambda (m) (memq m extras)) (plist-get state :disabled)) off)))))

(defvar drgnx-keys-presets)
(declare-function drgnx-keys--save-layers "drgnx-keys")
(declare-function drgnx-keys-use "drgnx-keys")
(declare-function drgnx-look-load-theme "drgnx-look")

(defvar drgnx-keys-file)
(defvar drgnx-keys-layers)
(declare-function drgnx-keys-file "drgnx-keys")
(declare-function drgnx-keys-read-user "drgnx-keys")
(declare-function drgnx-keys-set-mac-option "drgnx-keys")
(declare-function drgnx-keys--save-key "drgnx-keys")
(declare-function drgnx-keys--user "drgnx-keys")
(declare-function drgnx-modal-prepare "drgnx-modal-choose")
(declare-function drgnx-modal-wait-text "drgnx-modal-choose")

(defun drgnx-onboard--current-keys ()
  "The name of the key preset keys.eld uses now, or nil."
  (let ((layers (ignore-errors
                  (plist-get (with-temp-buffer (insert-file-contents (drgnx-keys-file)) (read (current-buffer))) :layers))))
    (car (rassoc layers drgnx-keys-presets))))

(defun drgnx-onboard--current-preset ()
  "The preset the extra/ modules match now (none off — a fresh install too — is full-ai), or nil: a mix of your own."
  (let* ((extras (drgnx-onboard--extras))
         (off (seq-filter (lambda (m) (memq m extras)) (plist-get (drgnx-modules-read-state) :disabled))))
    (cond ((null off) 'full-ai)
          ((seq-set-equal-p off extras) 'minimal)
          ((equal off '(extra/llm)) 'ide))))

(defvar drgnx-onboard--restart-needed nil
  "Non-nil once a step in this Emacs turned modules on or installed packages: they load at the next start, and
the Finish step offers the restart.")

(defun drgnx-onboard--sync-job ()
  "`drgnx sync' as a drgnx job (\"Installing the packages\"), in this Emacs: `ok' or (fail REASON LOG)."
  (drgnx-onboard--job "Installing the packages"
                      (list "env" (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory))
                            (expand-file-name "bin/drgnx" drgnx-dir) "sync")
                      :none))

(defun drgnx-onboard--installed-p (name)
  "Is package NAME in drgnx's packages directory (what drgnx sync installs)?  Not the load path: a package
somewhere else does not count, and one installed since this Emacs started counts before it loads."
  (and (file-directory-p (drgnx-elpa-dir))
       (directory-files (drgnx-elpa-dir) nil (format "\\`%s-[0-9]" (regexp-quote (symbol-name name))))
       t))

(defun drgnx-onboard--look-step (ctx)
  "Key profile, theme and module preset: the options given, else (asking, when interactive, with the
current choice as the default) — with no option and no question, the current choices stay."
  (require 'drgnx-keys)
  (let* ((o (plist-get ctx :options)) (ask (plist-get ctx :interactive))
         (cur-preset (drgnx-onboard--current-preset)) (cur-keys (drgnx-onboard--current-keys))
         (preset (or (plist-get o :preset)
                     (and ask (let ((s (drgnx-onboard--choose "Modules" (append (mapcar (lambda (p) (symbol-name (car p))) drgnx-onboard-presets)
                                                                                (and (not cur-preset) '("keep")))
                                                              (if cur-preset (symbol-name cur-preset) "keep"))))
                                (unless (equal s "keep") (intern s))))))
         ;; a stack waiting for its engine (drgnx sync) is the answer Return keeps
         (pending (car (rassoc (plist-get (drgnx-keys-read-user) :pending-layers) drgnx-keys-presets)))
         (keys (or (plist-get o :keys)
                   (and ask (drgnx-onboard--choose (if (eq (drgnx-platform) 'macos)
                                                       "With VS Code app keys on a Mac, Vim keeps Ctrl and VS Code uses Cmd: no clashes\nKeys"
                                                     "Keys")
                                                   (mapcar #'car drgnx-keys-presets) (or pending cur-keys "VS Code")))))
         (theme (or (plist-get o :theme)
                    (and ask (let ((s (drgnx-onboard--choose "Color theme" (append (mapcar #'symbol-name (custom-available-themes)) '("keep"))
                                                             "keep")))
                               (unless (equal s "keep") (intern s))))))
         (layers (and keys (or (cdr (assoc keys drgnx-keys-presets)) (user-error "Unknown key profile %s" keys))))
         ;; on a Mac with VS Code's keys drgnx sets the modifiers: the left Option is Meta unless it types characters
         (option (and ask (eq (drgnx-platform) 'macos)
                      (assq 'vscode (or layers (plist-get (drgnx-keys-read-user) :layers) drgnx-keys-layers))
                      (if (equal (drgnx-onboard--choose "Left Option key (types characters: @ # { [ on German, French, … keyboards)"
                                                        '("types characters" "Meta")
                                                        (if (eq (plist-get (drgnx-keys-read-user) :mac-option) 'characters) "types characters" "Meta"))
                                 "types characters")
                          'characters 'meta)))
         (modal nil))
    (when (and preset (not (eq preset cur-preset))) (drgnx-onboard-apply-preset preset))
    ;; A Vim stack switches only once its engine is loaded: asked to install it when interactive, else it waits
    (when (and layers (or (not (equal keys cur-keys)) pending))
      (require 'drgnx-modal-choose)
      (setq modal (drgnx-modal-prepare layers ask))
      (when (memq modal '(ready started installed))
        (if (and (not noninteractive) (fboundp 'drgnx-keys-apply))
            (progn (drgnx-keys-use layers) (drgnx-keys--save-layers layers))
          (drgnx-keys--save-layers layers))))
    (when option
      (if (and (not noninteractive) (fboundp 'drgnx-keys-apply)) (drgnx-keys-set-mac-option option) (drgnx-keys--save-key :mac-option option)))
    (when theme
      (if (and (not noninteractive) (fboundp 'drgnx-look-load-theme)) (drgnx-look-load-theme theme)
        (drgnx-modules-write-state (plist-put (copy-sequence (drgnx-modules-read-state)) :theme theme))))
    (let* ((pkgs (drgnx-onboard--packages-to-install))
           (bytes (plist-get pkgs :bytes))
           (done (cond ((null pkgs) 'none)
                       ((and ask (y-or-n-p (format "Install the packages for %s now%s? " (or preset cur-preset "your modules")
                                                   (if bytes (format " (about %d MB)" (max 1 (round bytes 1048576.0))) ""))))
                        (drgnx-onboard--sync-job))
                       (t 'later)))
           ;; a running drgnx loads modules and packages at its start only
           (restart (or (eq done 'ok) (and preset (not (eq preset cur-preset))))))
      (when restart (setq drgnx-onboard--restart-needed t))
      (list (if (or (consp done) (consp modal)) 'warn 'ok)
            (format "modules: %s; keys: %s%s%s; %s%s"
                    (or preset cur-preset "as they are")
                    (cond ((memq modal '(nil ready started installed)) (or keys cur-keys "as they are"))
                          ((and (eq modal 'pending) (eq done 'ok)) (format "%s from the next start" keys))
                          (t (drgnx-modal-wait-text keys modal)))
                    (pcase option
                      ('characters "; Option types characters (Option+←/→ still move by word)")
                      ('meta "; Option is Meta (Option+←/→ move by word)")
                      (_ ""))
                    (if theme (format "; theme: %s" theme) "")
                    (pcase done
                      ('none "packages: all installed")
                      ('ok "packages installed (drgnx sync)")
                      ('later "packages: not installed yet — run drgnx sync")
                      (`(fail ,why ,log) (format "packages: %s — run drgnx sync in a terminal to retry%s" why
                                                 (if log (format " (log: %s)" log) ""))))
                    (if restart " — restart drgnx to load the new modules (the Finish step offers it)"
                      " (modules take effect at the next start)"))))))

(declare-function drgnx-pkg-manifest "drgnx-pkg")
(declare-function drgnx-pkg-read-lock "drgnx-pkg")
(declare-function drgnx-pkg--read-lock-file "drgnx-pkg")
(declare-function drgnx-pkg-shipped-lock-file "drgnx-pkg")
(declare-function drgnx-pkg--lock-closure "drgnx-pkg")
(declare-function drgnx-pkg--beyond-lock "drgnx-pkg")
(declare-function drgnx-pkg-git-source "drgnx-pkg")
(declare-function package-built-in-p "package")

(defun drgnx-onboard--packages-to-install ()
  "What `drgnx sync' would install for the modules on now, or nil when nothing: (:names NAMES :bytes BYTES) — the
manifest's packages, with what their lock entries need (the user's lock, else the one drgnx ships), not installed at the
locked version.  BYTES: the downloads' size from the lock, nil when it does not know one (Git clones are not counted)."
  (require 'drgnx-pkg)
  (let* ((lock (or (ignore-errors (drgnx-pkg-read-lock)) (ignore-errors (drgnx-pkg--read-lock-file (drgnx-pkg-shipped-lock-file)))))
         (manifest (drgnx-pkg-manifest))
         (installed-p (lambda (re) (and (file-directory-p (drgnx-elpa-dir)) (directory-files (drgnx-elpa-dir) nil re))))
         (closure (drgnx-pkg--lock-closure manifest lock))
         (locked (seq-remove (lambda (n) (let ((e (alist-get n lock)))
                                           (funcall installed-p (format "\\`%s\\'" (regexp-quote (format "%s-%s" n (plist-get e :version)))))))
                             closure))
         (other (seq-remove (lambda (n) (or (assq n lock) (package-built-in-p n)
                                            (funcall installed-p (format "\\`%s-[0-9]" (regexp-quote (symbol-name n))))))
                            (delete-dups (append manifest (mapcar #'car (drgnx-pkg--beyond-lock closure lock))))))
         (archive (seq-remove (lambda (n) (eq (plist-get (alist-get n lock) :kind) 'git)) locked)))
    (when (or locked other)
      (list :names (append locked other)
            :bytes (and archive (not (seq-remove #'drgnx-pkg-git-source other))
                        (seq-every-p (lambda (n) (plist-get (alist-get n lock) :size)) archive)
                        (apply #'+ (mapcar (lambda (n) (plist-get (alist-get n lock) :size)) archive)))))))

;;;; Step 3: projects

(declare-function drgnx-projects-scan "drgnx-projects")
(declare-function drgnx-projects-gryphn-roots "drgnx-projects")
(declare-function drgnx-projects-import "drgnx-projects")
(declare-function drgnx-projects-board-file "drgnx-projects")
(autoload 'drgnx-projects-sync-plans "drgnx-projects" nil t)
(defvar drgnx-projects-scan-truncated)
(defvar drgnx-projects-scan-budget)
(defvar drgnx-projects-todo-cap)

(defconst drgnx-onboard-default-roots '("~/workspace" "~/code" "~/src" "~/projects" "~/git"))

(defconst drgnx-onboard--none "(none)" "The project picker's choice of no project.")
(defvar crm-separator)

(defun drgnx-onboard--separator (choices)
  "What separates several CHOICES in `completing-read-multiple': the first of , ; | that none contains."
  (or (seq-find (lambda (s) (not (seq-some (lambda (c) (string-search s c)) choices))) '("," ";" "|")) ","))

(defun drgnx-onboard--projects-step (ctx)
  (require 'drgnx-projects)
  (require 'crm)
  (let* ((o (plist-get ctx :options))
         (roots (or (plist-get o :roots) (seq-filter #'file-directory-p (mapcar #'expand-file-name drgnx-onboard-default-roots))))
         (found (delete-dups (mapcar #'directory-file-name
                                     (append (drgnx-projects-scan roots)
                                             (seq-filter #'file-directory-p (drgnx-projects-gryphn-roots))))))
         (truncated drgnx-projects-scan-truncated)
         (ask (and (plist-get ctx :interactive) found))
         (sep (drgnx-onboard--separator found))
         (crm-separator (concat "[ \t]*" (regexp-quote sep) "[ \t]*"))   ; never splits a path
         (picked (if ask
                     (let ((answer (completing-read-multiple
                                    (format "Projects to import (%d found; several: separate with %s; empty: all; %s: none): "
                                            (length found) sep drgnx-onboard--none)
                                    (cons drgnx-onboard--none found))))
                       (cond ((member drgnx-onboard--none answer) nil) (answer) (t found)))
                   found))
         (todos (cond ((plist-member o :todos) (plist-get o :todos))
                      ((and ask picked)
                       (completing-read-multiple "Import TODOs (TODO.md, TODO.org, plan checklists) from (empty: none): " picked))))
         (stopped (and truncated (format " — the scan stopped after %ss at %s; pass the directories with --roots"
                                         drgnx-projects-scan-budget truncated))))
    (if (null picked)
        (list (if truncated 'warn 'info)
              (concat (if found "no projects imported (none picked)"
                        (format "no git repositories found under %s" (string-join roots ", ")))
                      stopped))
      (let ((r (drgnx-projects-import picked :todos todos)))
        (list (if truncated 'warn 'ok)
              (concat (format "%d projects on the board (%d new), %d TODOs added%s — %s"
                              (length picked) (length (plist-get r :added)) (plist-get r :todos)
                              (if (plist-get r :capped) (format " (first %d only for %s)" drgnx-projects-todo-cap
                                                                (string-join (plist-get r :capped) ", "))
                                "")
                              (drgnx-projects-board-file))
                      stopped))))))

;;;; Steps 4–6, 8: what is there (completed by later milestones)

(defun drgnx-onboard--detect (programs then)
  (lambda (_ctx)
    (let ((found (seq-filter #'executable-find programs)))
      (list 'info (format "%s; %s" (if found (concat "found: " (string-join found ", ")) "nothing found") then)))))

;;;; Step 4: AI providers

(defvar drgnx-ai-detected)
(declare-function drgnx-ai-probe "drgnx-ai-probe")
(declare-function drgnx-ai-usable-p "drgnx-ai-probe")
(declare-function drgnx-ai-vram "drgnx-ai-probe")
(declare-function drgnx-ai-model-vram "drgnx-ai-probe")
(declare-function drgnx-ai-role "drgnx-ai")
(declare-function drgnx-ai-user-role "drgnx-ai")
(declare-function drgnx-ai-set-role "drgnx-ai")
(declare-function drgnx-ai-key "drgnx-ai")
(declare-function drgnx-ai-provider "drgnx-ai")
(declare-function drgnx-ai-request "drgnx-ai-client")

(defun drgnx-onboard--wait (pred secs)
  (let ((deadline (+ (float-time) secs)))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05))
    (funcall pred)))

(defun drgnx-onboard--ai-pick (role cap &optional interactive)
  "A (PROVIDER . MODEL) for ROLE among the providers that can do CAP, or nil: OpenRouter for edit and chat when
its key is set; else a provider running here — for `complete' a coder model when it has one.  INTERACTIVE: keys
may come from sources that ask."
  (if (and (memq role '(edit chat)) (drgnx-ai-usable-p 'openrouter cap interactive))
      (cons 'openrouter "openrouter/auto")
    (seq-some (lambda (e)
                (let ((models (plist-get (cdr e) :models)))
                  (when (and models (drgnx-ai-usable-p (car e) cap interactive))
                    (cons (car e) (or (and (eq role 'complete) (seq-find (lambda (m) (string-match-p "code" m)) models))
                                      (car models))))))
              drgnx-ai-detected)))

(defvar drgnx-onboard-ai-test-budget 8
  "Seconds the AI step's probe and its three test calls share, when it looks at what runs here.")

(defun drgnx-onboard--ai-test (role step ctx &optional timeout)
  "One call to STEP (PROVIDER . MODEL) of the kind ROLE makes — fill in the middle, chat or an embedding: t when it
answered within TIMEOUT seconds (default 15)."
  (let ((interactive (plist-get ctx :interactive)) (timeout (or timeout 15)))
    (if (eq role 'embed)
        (condition-case nil
            (and (drgnx-ai-embed-sync (vector "hello") :timeout timeout :chain (list step) :interactive interactive) t)
          (drgnx-ai-embed-error nil))
      (let ((cell (drgnx-onboard--ai-test-start role step ctx timeout)))
        (drgnx-onboard--wait (lambda () (car cell)) (1+ timeout))
        (eq (car cell) 'yes)))))

(defun drgnx-onboard--ai-test-start (role step ctx timeout)
  "Start one call to STEP of the kind ROLE (complete, edit or chat) makes, without waiting: a cell whose car becomes
`yes' (it answered), `no' (the provider refused or failed at once) or `slow' (TIMEOUT seconds went by)."
  (let ((fim (eq role 'complete)) (cell (list nil)) (t0 (float-time)))
    (drgnx-ai-request role (if fim 'fim 'chat)
                      (if fim (list :prefix "(defun hello ()\n  " :suffix ")\n" :max-tokens 8)
                        (list :messages (vector (list :role "user" :content "Say OK."))))
                      (lambda (text _info)
                        (setcar cell (cond (text 'yes) ((>= (- (float-time) t0) (- timeout 0.5)) 'slow) (t 'no))))
                      :chain (list step) :timeout timeout :interactive (plist-get ctx :interactive))
    cell))

(defun drgnx-onboard--ai-found (ctx)
  "Find the providers running here, test each role with one call, and give a role without a working provider the
one found once its call answered: (STATUS MESSAGE ANSWERED UNTESTED), ANSWERED how many of the three roles
answered, UNTESTED how many could not be tried in time.  The three calls start together after the probe and are waited
for once, within `drgnx-onboard-ai-test-budget' seconds for all; a call that has not answered by then (a model that
is still loading) reads \"not tested\" and counts as neither asked nor failed."
  (require 'drgnx-ai-probe)
  (let* ((deadline (+ (float-time) drgnx-onboard-ai-test-budget))
         (_ (let ((done nil))
              (drgnx-ai-probe (lambda () (setq done t)))
              (drgnx-onboard--wait (lambda () done) 3)))
         (key (drgnx-ai-key 'openrouter (plist-get ctx :interactive))) (lines nil) (answered 0) (asked 0) (untested 0)
         (plan (mapcar (lambda (role)
                         (let* ((cap (if (eq role 'complete) 'fim 'chat))
                                (usable (seq-find (lambda (s) (drgnx-ai-usable-p (car s) cap (plist-get ctx :interactive))) (drgnx-ai-role role)))
                                (step (or usable (drgnx-onboard--ai-pick role cap (plist-get ctx :interactive)))))
                           (list role usable step)))
                       '(complete edit chat)))
         (left (- deadline (float-time)))
         ;; every call gets the whole of what is left, not a third: they run side by side
         (cells (mapcar (lambda (p) (and (nth 2 p) (>= left 1) (drgnx-onboard--ai-test-start (car p) (nth 2 p) ctx (ceiling left)))) plan)))
    (when (seq-some #'identity cells)
      (drgnx-onboard--wait (lambda () (seq-every-p (lambda (c) (or (null c) (car c))) cells)) (1+ (ceiling left))))
    (cl-mapc (lambda (p cell)
               (pcase-let ((`(,role ,usable ,step) p))
                 (if (not step) (push (format "%s: no provider" role) lines)
                   (pcase (car cell)
                     ('yes (cl-incf asked) (cl-incf answered)
                           (unless usable (drgnx-ai-set-role role (cons step (drgnx-ai-user-role role)))))
                     ('no (cl-incf asked))
                     (_ (cl-incf untested)))
                   (push (format "%s: %s/%s %s" role (car step) (cdr step)
                                 (pcase (car cell) ('yes "answered") ('no "did not answer") (_ "not tested (out of time)")))
                         lines))))
             plan cells)
    (unless key
      (push "OpenRouter: run this step again → Change → openrouter (keeps the key in your Keychain or keyring); for the command line: OPENROUTER_API_KEY" lines))
    (let* ((vram (drgnx-ai-vram)) (model (cdr (car (drgnx-ai-role 'complete))))
           (need (if model (drgnx-ai-model-vram model) 0))
           (free (and vram (- (plist-get vram :total) (plist-get vram :used)))))
      (when free
        (push (format (if (plist-get vram :unified) "memory for models: %d MiB (two thirds of the RAM), the completion model needs about %d"
                        "GPU: %d MiB free, the completion model needs about %d")
                      free need)
              lines))
      (list (cond ((zerop (+ asked untested)) 'info) ((or (> untested 0) (and free (> need free)) (< answered asked)) 'warn) (t 'ok))
            (if (zerop (+ asked untested))
                (concat "no provider is running here and no OpenRouter key is set — start Ollama, LM Studio or llama.cpp, "
                        "or set the key; then AI: Choose Provider/Model; " (string-join (nreverse lines) "; "))
              (concat (string-join (nreverse lines) "; ") " — change any: AI: Choose Provider/Model (docs/guide/ai.md)"))
            answered untested))))

;;;; Step 4: setting AI up — Ollama, LM Studio or OpenRouter

(defconst drgnx-onboard-claude-package "@agentclientprotocol/claude-agent-acp"
  "The npm package of the Claude Code adapter (binary `claude-agent-acp') drgnx's `claude' agent profile runs: the
maintained one (`drgnx-agents-claude-package'), not the deprecated @zed-industries package.  Not pinned: npm installs
the latest; the doctor checks the version.")

(defconst drgnx-onboard-install-recipes
  `((ollama :name "Ollama" :provider ollama
            :check (:program "ollama" :provider ollama)
            :macos (:install ("brew" "install" "ollama"))
            :linux (:shell "curl -fsSL https://ollama.com/install.sh | sh" :sudo t)
            :start ("ollama" "serve")
            :pull ("ollama" "pull"))
    (lmstudio :name "LM Studio" :provider lmstudio
              :check (:program "lms" :provider lmstudio)
              :macos (:install ("brew" "install" "--cask" "lm-studio") :launch ("open" "-a" "LM Studio"))
              :linux (:page "https://lmstudio.ai/download")
              :start ("lms" "server" "start")
              :pull ("lms" "get" "-y"))
    (claude :name "Claude Code" :check (:program "claude" :dirs ("~/.local/bin"))
            :macos (:install ("brew" "install" "--cask" "claude-code"))
            :linux (:job ("bash" "-c" "curl -fsSL https://claude.ai/install.sh | bash")))
    (node :name "Node.js" :check (:program "npm")
          :macos (:install ("brew" "install" "node"))
          :linux (:by-program (("dnf" . "sudo dnf install nodejs npm") ("apt-get" . "sudo apt-get install nodejs npm")
                               ("pacman" . "sudo pacman -S nodejs npm"))
                              :page "https://nodejs.org/en/download"))
    (claude-agent-acp :name "the Claude Code adapter" :check (:program "claude-agent-acp" :dirs ("~/.local/bin"))
                      :macos (:job ("npm" "install" "-g" ,drgnx-onboard-claude-package))
                      :linux (:job ("npm" "install" "-g" "--prefix" "~/.local" ,drgnx-onboard-claude-package))))
  "How onboarding sets up a local model runner: ID → plist.  :check — it is there when its :program is found (lms
also in ~/.lmstudio/bin, where LM Studio puts it; :dirs: more directories) or its :provider's address answers.
:macos :install — the Homebrew command, a drgnx job; :launch — LM Studio's first start, which puts lms in place.
:linux :shell — Ollama's official installer, which uses sudo: shown, for you to run in a terminal (a job has no
terminal to ask your password in); :by-program — the same for the first package manager found; :page — LM Studio's
download page.  :job (either platform) — a command that needs no sudo, a drgnx job.  :start — the server, a drgnx
job (never at login); :pull — the download, the model's name after it.  claude, node and claude-agent-acp are
Claude Code's parts (`drgnx-onboard--agents-step').")

(defconst drgnx-onboard-embed-model "nomic-embed-text"
  "The embedding model a local runner set up here downloads (Ollama's name; LM Studio's: `drgnx-ai-lmstudio-models').")

(defconst drgnx-onboard-openrouter-models
  '((complete . "qwen/qwen-2.5-coder-32b-instruct") (edit . "openrouter/auto") (chat . "openrouter/auto"))
  "The OpenRouter model onboarding gives each role.")

(defconst drgnx-onboard-ai-choices
  '(("ollama" . ollama) ("lmstudio" . lmstudio) ("openrouter" . openrouter) ("skip" . skip))
  "The answers to \"Set up AI with\": Ollama and LM Studio run models here, OpenRouter in the cloud (a key).")

(defconst drgnx-onboard-ai-local-room 10000
  "MiB of room for models (`drgnx-ai-vram' total) from which \"Set up AI with\" defaults to Ollama, not OpenRouter.")

(defun drgnx-onboard--ai-default ()
  "The answer Return gives \"Set up AI with\": ollama on a Mac or Linux machine with room for the models
\(`drgnx-onboard-ai-local-room'), else openrouter."
  (let ((v (drgnx-ai-vram)))
    (if (and (memq (drgnx-platform) '(macos linux)) v (>= (or (plist-get v :total) 0) drgnx-onboard-ai-local-room))
        "ollama" "openrouter")))

(defun drgnx-onboard--ai-ask ()
  "Ask \"Set up AI with\": `ollama', `lmstudio', `openrouter' or `skip' (only when typed: never the default)."
  (cdr (assoc (drgnx-onboard--choose "Set up AI with" (mapcar #'car drgnx-onboard-ai-choices) (drgnx-onboard--ai-default))
              drgnx-onboard-ai-choices)))

(defvar drgnx-onboard-lms-wait 120 "Seconds LM Studio's first start may take to put lms in place.")
(defvar drgnx-onboard-server-wait 60 "Seconds a model server started here may take to answer.")
(defvar drgnx-onboard-app-wait 600 "Seconds onboarding waits for a runner you install yourself (Linux) to answer.")

(declare-function drgnx-jobs-start "drgnx-jobs")
(declare-function drgnx-jobs-get "drgnx-jobs")
(declare-function drgnx-jobs-log "drgnx-jobs")
(declare-function drgnx-jobs-stop "drgnx-jobs")
(declare-function drgnx-jobs--dir "drgnx-jobs")
(declare-function drgnx-ai-default-models "drgnx-ai")
(declare-function drgnx-ai-store-key "drgnx-ai")
(declare-function drgnx-ai-embed-sync "drgnx-ai-client")
(declare-function drgnx-ai-ask-request "drgnx-ai-ui")
(declare-function drgnx-ai-set-managed "drgnx-ai-probe")
(defvar drgnx-ai-lmstudio-models)

(defconst drgnx-onboard--brew-programs '("/opt/homebrew/bin/brew" "/usr/local/bin/brew")
  "Where Homebrew lives on Apple silicon and on Intel, when the app's PATH lacks it.")

(defun drgnx-onboard--brew ()
  (or (executable-find "brew") (seq-find #'file-executable-p drgnx-onboard--brew-programs)))

(defun drgnx-onboard--program (tool)
  "TOOL's program, a path — on the path, in ~/.lmstudio/bin or beside brew — or nil."
  (let* ((check (plist-get (alist-get tool drgnx-onboard-install-recipes) :check))
         (name (plist-get check :program))
         (brew (drgnx-onboard--brew)))
    (or (executable-find name)
        (seq-find #'file-executable-p
                  (delq nil (append (list (and (eq tool 'lmstudio) (expand-file-name name "~/.lmstudio/bin"))
                                          (and brew (expand-file-name name (file-name-directory brew))))
                                    (mapcar (lambda (d) (expand-file-name name d)) (plist-get check :dirs))))))))

(defun drgnx-onboard--npm-outside-brew-p ()
  "Is the npm found a Node that is not Homebrew's (not beside brew)?  No npm yet: nil — Homebrew's Node comes first."
  (when-let* ((npm (executable-find "npm")))
    (not (equal (file-name-directory npm) (and-let* ((brew (drgnx-onboard--brew))) (file-name-directory brew))))))

(defun drgnx-onboard--platform-job (tool)
  "TOOL's :job command on this platform (nil when it has none).  The adapter on macOS goes to ~/.local when the npm
is not Homebrew's: a system Node's global directory is not yours (EACCES)."
  (let ((job (plist-get (plist-get (alist-get tool drgnx-onboard-install-recipes) (if (eq (drgnx-platform) 'macos) :macos :linux)) :job)))
    (if (and job (eq tool 'claude-agent-acp) (eq (drgnx-platform) 'macos) (drgnx-onboard--npm-outside-brew-p))
        (append (seq-take job 3) '("--prefix" "~/.local") (nthcdr 3 job))
      job)))

(defun drgnx-onboard--up-p (provider)
  "Does PROVIDER's address answer now?  One probe of it (a second at most); `drgnx-ai-detected' has what it found."
  (let ((done nil))
    (drgnx-ai-probe (lambda () (setq done t)) (list provider))
    (drgnx-onboard--wait (lambda () done) 3)
    (plist-get (alist-get provider drgnx-ai-detected) :up)))

(defun drgnx-onboard--until (pred secs)
  "Wait until PRED, asked four times a second, at most SECS (nil: as long as it takes): its last value.  For the
step (a command): C-g quits."
  (let ((deadline (and secs (+ (float-time) secs))) (v nil))
    (while (and (not (setq v (funcall pred))) (or (null deadline) (< (float-time) deadline)))
      (unless noninteractive (redisplay))
      (accept-process-output nil 0.25))
    v))

(defun drgnx-onboard--refresh-welcome ()
  (when-let* ((b (get-buffer "*drgnx Welcome*"))) (with-current-buffer b (tabulated-list-print t))))

(defun drgnx-onboard--last-line (id)
  "The last line job ID wrote (a progress bar's last state, without ANSI escapes), or nil.  Reads only the end of
the log (4 KB): it is called twice a second."
  (let* ((file (expand-file-name "log" (drgnx-jobs--dir id)))
         (size (file-attribute-size (file-attributes file)))
         (tail (if (not size) ""
                 (with-temp-buffer
                   (insert-file-contents file nil (max 0 (- size 4096)) size)
                   (buffer-string)))))
    (car (last (split-string (replace-regexp-in-string "\e\\[[0-9;?]*[ -/]*[@-~]" "" tail) "[\r\n]+" t "[ \t]+")))))

(defun drgnx-onboard--say (text &optional step)
  "TEXT, with \" — C-g stops\", as what STEP (default: the running step) is doing now: its Welcome row and the echo
area.  Never asks anything (the progress timer calls it too)."
  (let ((text (concat text " — C-g stops")))
    (unless (equal text (cdr drgnx-onboard--progress))
      (setq drgnx-onboard--progress (cons (or step drgnx-onboard--current) text))
      (drgnx-onboard--refresh-welcome)
      (message "%s" text))))

(defun drgnx-onboard--show-progress (step what id)
  "The progress timer: WHAT and job ID's last log line, in STEP's row of the Welcome and the echo area.  Reads only."
  (drgnx-onboard--say (string-trim-right (format "%s… %s" what (or (drgnx-onboard--last-line id) ""))) step))

(defun drgnx-onboard--job (what command &optional secs)
  "Run COMMAND (a list) as a drgnx job for WHAT and wait for it to end, at most SECS (default an hour; `:none': as
long as it takes — a model download or a package sync, which C-g still stops); meanwhile the Welcome shows its last
log line.  `ok', or (fail REASON LOG): REASON ends with the log's last line.  C-g stops the
job, then quits."
  (require 'drgnx-jobs)
  (make-directory (drgnx-state-dir) t)
  (let* ((id (drgnx-jobs-start (concat "Onboarding: " what) command :cwd (drgnx-state-dir)))
         (log (expand-file-name "log" (drgnx-jobs--dir id)))
         (t0 (float-time)) (job nil)
         ;; the CLI (batch) ends on Ctrl-C without unwinding: the exit stops the job
         (stop (lambda () (drgnx-jobs-stop id)))
         (timer (run-at-time 0.5 0.5 #'drgnx-onboard--show-progress drgnx-onboard--current what id)))
    (when noninteractive (add-hook 'kill-emacs-hook stop))
    (unwind-protect
        (condition-case nil
            (progn
              (drgnx-onboard--until (lambda ()
                                      (setq job (drgnx-jobs-get id))
                                      ;; gone: it ended without writing its exit (killed); not while it starts
                                      (or (plist-get job :exit) (and (eq (plist-get job :status) 'gone) (> (- (float-time) t0) 3))))
                                    (if (eq secs :none) nil (or secs 3600)))
              (if (eql (plist-get job :exit) 0) 'ok
                (when (eq (plist-get job :status) 'running) (drgnx-jobs-stop id))
                (list 'fail (format "%s failed (%s)%s" what
                                    (cond ((plist-get job :exit) (format "exit %d" (plist-get job :exit)))
                                          ((eq (plist-get job :status) 'running) "it took too long and was stopped")
                                          (t "it ended without an exit status"))
                                    (if-let* ((line (drgnx-onboard--last-line id))) (concat ": " line) ""))
                      log)))
          (quit (drgnx-jobs-stop id) (signal 'quit nil)))
      (remove-hook 'kill-emacs-hook stop)
      (cancel-timer timer))))

(declare-function browse-url "browse-url")

(defun drgnx-onboard--install (tool ctx)
  "Install TOOL (an id of `drgnx-onboard-install-recipes') for this platform: `ok' once its program is there or its
server answers, else (fail REASON LOG), LOG nil when nothing ran.  Only when CTX is interactive (the step asked
first).  macOS: the Homebrew command as a drgnx job — LM Studio: then its first start, which puts lms in place.
Linux: Ollama's installer for you to run in a terminal (it uses sudo), or LM Studio's download page; then a wait
for its server (C-g stops it).  A recipe with a :job (Claude Code's installer, the npm package) runs it as a drgnx
job on either platform.  Every run starts from the top: nothing is resumed from a run that failed."
  (let* ((r (alist-get tool drgnx-onboard-install-recipes))
         (name (plist-get r :name))
         (there (lambda () (or (drgnx-onboard--program tool)
                               (and (plist-get r :provider) (drgnx-onboard--up-p (plist-get r :provider))))))
         (job (drgnx-onboard--platform-job tool)))
    (cond
     ((not (plist-get ctx :interactive)) (list 'fail (format "%s is not installed (nothing is installed without asking)" name) nil))
     ((funcall there) 'ok)
     (job (drgnx-onboard--install-job tool job))
     ((eq (drgnx-platform) 'macos)
      (let ((m (plist-get r :macos)) (brew (drgnx-onboard--brew)))
        (if (not brew)
            (list 'fail (format "Homebrew is needed to install %s: install it (https://brew.sh), then run this step again" name) nil)
          (let ((done (drgnx-onboard--job (format "Installing %s" name) (cons brew (cdr (plist-get m :install))))))
            (cond ((not (eq done 'ok)) done)
                  ((drgnx-onboard--program tool) 'ok)
                  ((plist-get m :launch)
                   (let ((launch (plist-get m :launch)))
                     (drgnx-onboard--job (format "Opening %s once" name) (cons (or (executable-find (car launch)) (car launch)) (cdr launch)) 30))
                   (if (drgnx-onboard--until (lambda () (drgnx-onboard--program tool)) drgnx-onboard-lms-wait) 'ok
                     (list 'fail (format "%s is installed, but its lms command is not there yet: Open LM Studio once (Applications), wait for its window, then run this step again" name) nil)))
                  (t (list 'fail (format "%s was installed, but %s cannot be found: check brew doctor, then run this step again"
                                         name (plist-get (plist-get r :check) :program))
                           nil)))))))
     (t
      (let* ((l (plist-get r :linux)) (shell (drgnx-onboard--linux-shell l))
             (open (if (eq tool 'lmstudio) " and open it" "")))
        (if shell
            (progn (kill-new shell)
                   (drgnx-onboard--say (format "Run in a terminal (copied): %s — it asks for your password (sudo); waiting for %s…" shell name)))
          (browse-url (plist-get l :page))
          (drgnx-onboard--say (format "Install %s from %s%s%s; waiting for it…" name (plist-get l :page) open
                                      (if (eq tool 'lmstudio) " (Developer → Start Server)" ""))))
        (if (drgnx-onboard--until there drgnx-onboard-app-wait) 'ok
          (list 'fail (format "%s did not show up within %d minutes: %s, then run this step again" name (/ drgnx-onboard-app-wait 60)
                              (if shell (format "run %s in a terminal" shell) (format "install it from %s%s" (plist-get l :page) open)))
                nil)))))))

(defun drgnx-onboard--linux-shell (l)
  "The shell command a Linux recipe plist L asks the user to run in a terminal: its :shell, else the :by-program
entry of the first package manager found; nil when it has neither."
  (or (plist-get l :shell)
      (cdr (seq-find (lambda (e) (executable-find (car e))) (plist-get l :by-program)))))

(defun drgnx-onboard--beside-brew (name)
  "NAME's path beside brew (where an app's PATH lacks it), or nil."
  (when-let* ((brew (drgnx-onboard--brew))) (let ((f (expand-file-name name (file-name-directory brew)))) (and (file-executable-p f) f))))

(defun drgnx-onboard--install-job (tool job)
  "Run JOB (a command list: no sudo, no terminal) as a drgnx job to install TOOL: `ok' when TOOL's program is
there after it, else (fail REASON LOG).  JOB's program is found on the path or beside brew (then its directory goes
first on the job's PATH: npm's `node' is there); a `~/' argument is the home directory."
  (let* ((name (plist-get (alist-get tool drgnx-onboard-install-recipes) :name))
         (program (or (executable-find (car job)) (drgnx-onboard--beside-brew (car job)))))
    (if (not program)
        (list 'fail (format "%s is needed to install %s: install it first, then run this step again" (car job) name) nil)
      (let* ((args (mapcar (lambda (a) (if (string-prefix-p "~/" a) (expand-file-name a) a)) (cdr job)))
             (command (if (executable-find (car job)) (cons program args)
                        (append (list "env" (concat "PATH=" (file-name-directory program) ":" (getenv "PATH"))) (list program) args)))
             (done (drgnx-onboard--job (format "Installing %s" name) command)))
        (cond ((not (eq done 'ok)) done)
              ((drgnx-onboard--program tool) 'ok)
              (t (list 'fail (format "%s was installed, but %s cannot be found: check your PATH, then run this step again"
                                     name (plist-get (plist-get (alist-get tool drgnx-onboard-install-recipes) :check) :program))
                       nil)))))))

(defun drgnx-onboard--start (tool)
  "TOOL's server: `ok' when its address answers — at once, or after its :start command as a drgnx job (`ollama
serve' keeps running as one; `lms server start' starts LM Studio's and ends) — else (fail REASON LOG)."
  (require 'drgnx-jobs)
  (let* ((r (alist-get tool drgnx-onboard-install-recipes)) (provider (plist-get r :provider)) (name (plist-get r :name))
         (program (drgnx-onboard--program tool)))
    (cond
     ((drgnx-onboard--up-p provider) 'ok)
     ((not program) (list 'fail (format "%s is not installed" name) nil))
     (t
      (make-directory (drgnx-state-dir) t)
      (drgnx-onboard--say (format "Starting %s…" name))
      (let* ((id (drgnx-jobs-start (format "%s server" name) (cons program (cdr (plist-get r :start))) :cwd (drgnx-state-dir)))
             (log (expand-file-name "log" (drgnx-jobs--dir id)))
             (up (condition-case nil
                     (drgnx-onboard--until (lambda ()
                                             (or (drgnx-onboard--up-p provider)
                                                 (let ((exit (plist-get (drgnx-jobs-get id) :exit))) (and exit (/= exit 0) 'failed))))
                                           drgnx-onboard-server-wait)
                   (quit (drgnx-jobs-stop id) (signal 'quit nil)))))
        (if (eq up t) 'ok
          (drgnx-jobs-stop id)
          (list 'fail (format "%s did not answer at %s%s" name (plist-get (drgnx-ai-provider provider) :url)
                              (if-let* ((line (drgnx-onboard--last-line id))) (concat ": " line) ""))
                log)))))))

(defun drgnx-onboard--pull-name (tool model)
  "The name TOOL downloads Ollama's MODEL by."
  (if (eq tool 'lmstudio) (nth 2 (assoc model drgnx-ai-lmstudio-models)) model))

(defun drgnx-onboard--served-name (tool model)
  "The name TOOL serves Ollama's MODEL by: for LM Studio the one it lists that holds the expected name, else that."
  (if (not (eq tool 'lmstudio)) model
    (let ((want (nth 1 (assoc model drgnx-ai-lmstudio-models)))
          (listed (plist-get (alist-get 'lmstudio drgnx-ai-detected) :models)))
      (or (car (member want listed)) (seq-find (lambda (m) (string-search want (downcase m))) listed) want))))

(defun drgnx-onboard--local-models ()
  "((ROLE . MODEL)…), Ollama's names: the defaults for the room models get here (`drgnx-ai-vram'), and the embedding model."
  (append (drgnx-ai-default-models (let ((v (drgnx-ai-vram))) (and v (- (plist-get v :total) (plist-get v :used)))))
          (list (cons 'embed drgnx-onboard-embed-model))))

(defun drgnx-onboard--setup-commands (tool models)
  "What sets TOOL up here with MODELS, as text: its install (unless it is there), its server, the downloads."
  (let* ((r (alist-get tool drgnx-onboard-install-recipes))
         (mac (eq (drgnx-platform) 'macos))
         (p (plist-get r (if mac :macos :linux)))
         (cmd (lambda (l) (mapconcat (lambda (a) (if (string-search " " a) (format "\"%s\"" a) a)) l " "))))
    (append (unless (or (drgnx-onboard--program tool) (plist-get (alist-get (plist-get r :provider) drgnx-ai-detected) :up))
              (cond (mac (cons (funcall cmd (plist-get p :install))
                               (and (plist-get p :launch) (list (concat (funcall cmd (plist-get p :launch)) " (once)")))))
                    ((plist-get p :shell) (list (format "%s (in a terminal: it uses sudo, your password)" (plist-get p :shell))))
                    (t (list (format "install %s from %s and open it" (plist-get r :name) (plist-get p :page))))))
            (list (funcall cmd (plist-get r :start)))
            (mapcar (lambda (m) (funcall cmd (append (plist-get r :pull) (list (drgnx-onboard--pull-name tool m)))))
                    (delete-dups (mapcar #'cdr models))))))

(defun drgnx-onboard--download-gb (models)
  "About how many GB MODELS (Ollama's names) take to download, as text."
  (format "%.1f" (/ (apply #'+ (mapcar (lambda (m) (if (equal m drgnx-onboard-embed-model) 280 (max 0 (- (drgnx-ai-model-vram m) 500))))
                                       models))
                    1024.0)))

(defun drgnx-onboard--not-listed (tool models)
  "The Ollama names in MODELS that TOOL's server does not list yet (what a re-run still has to download)."
  (let ((listed (plist-get (alist-get (plist-get (alist-get tool drgnx-onboard-install-recipes) :provider) drgnx-ai-detected)
                           :models)))
    (seq-remove (lambda (m) (let ((name (drgnx-onboard--served-name tool m)))
                              (or (member name listed) (member (concat name ":latest") listed))))
                models)))

(defun drgnx-onboard--put-first (role step)
  "STEP (PROVIDER . MODEL) first in ROLE's chain in ai.eld; the role's other providers stay behind it."
  (drgnx-ai-set-role role (cons step (seq-remove (lambda (s) (eq (car s) (car step))) (drgnx-ai-user-role role)))))

(defconst drgnx-onboard--ask-question "Where is the onboarding greeting defined?"
  "What onboarding asks Ask the Codebase about its test project.")

(defun drgnx-onboard--ask-test (step ctx)
  "Ask the Codebase — its retrievers, then the `chat' model STEP — over a temp project of one file: t when an answer
came for the snippets found."
  (unless (featurep 'drgnx-ai-ui) (load (expand-file-name "modules/tools/drgnx-ai-ui" drgnx-dir) nil t))
  (let ((root (make-temp-file "drgnx-onboard-ask" t)) (result nil))
    (unwind-protect
        (progn
          (write-region "(defun drgnx-onboarding-greeting ()\n  \"Hello from onboarding.\")\n" nil
                        (expand-file-name "greeting.el" root) nil 'silent)
          (drgnx-ai-ask-request drgnx-onboard--ask-question root
                                (lambda (answer _info snippets) (setq result (list (and answer snippets t))))
                                :chain (and step (list step)) :interactive (plist-get ctx :interactive))
          (drgnx-onboard--wait (lambda () result) 20)
          (car result))
      (delete-directory root t))))

(defun drgnx-onboard--chat-module (ctx)
  "Chat (gptel) is module extra/llm, off in the minimal and ide presets: (ON . TEXT), ON nil also when installing its
package failed.  Whether gptel is installed: drgnx's packages.  Interactive, when it is off: asked whether to turn it
on, and gptel installed (drgnx sync, as Look and Keys does) when it is missing.  Either loads at the next start: the
text says so — with the Finish step's restart offer only when this run changed something and drgnx runs with windows
\(Finish never offers it in batch); a restart is needed (`drgnx-onboard--restart-needed') only then."
  (let ((next (if noninteractive "; it loads at drgnx's next start"
                " from the next start: restart drgnx to load it (the Finish step offers it)"))
        (later "; it loads at drgnx's next start"))
    (cond ((not (drgnx-module-disabled-p 'extra/llm))
           (cond ((featurep 'gptel) (cons t "Chat (module extra/llm) is on"))
                 ((drgnx-onboard--installed-p 'gptel)
                  (cons t (concat "Chat (module extra/llm) is on" later)))
                 (t (cons t "Chat (module extra/llm) is on; its package is not installed yet: run drgnx sync (or the Look and Keys step)"))))
          ((and (plist-get ctx :interactive) (y-or-n-p "Turn on Chat (module extra/llm)? "))
           (drgnx-modules-toggle 'extra/llm)
           (setq drgnx-onboard--restart-needed t)
           (let ((done (if (drgnx-onboard--installed-p 'gptel) 'ok (drgnx-onboard--sync-job))))
             (if (eq done 'ok)
                 (cons t (concat "Chat (module extra/llm) turned on" next))
               (pcase-let ((`(,_ ,why ,log) done))
                 (cons nil (format "Chat (module extra/llm) turned on, but its package was not installed: %s — run drgnx sync in a terminal to retry%s"
                                   why (if log (format " (log: %s)" log) "")))))))
          (t (cons nil "Chat needs module extra/llm (Preferences: Modules)")))))

(defun drgnx-onboard--ai-verify (head steps ctx &optional tail)
  "Test each of STEPS ((ROLE PROVIDER . MODEL)…) with one call, then Ask the Codebase with the chat step, then
whether Chat's module is on: (STATUS MESSAGE), the message HEAD, the results, TAIL."
  (drgnx-onboard--say "Testing every feature…")
  (let* ((results (mapcar (lambda (s) (cons s (drgnx-onboard--ai-test (car s) (cdr s) ctx))) steps))
         (ask (drgnx-onboard--ask-test (cdr (assq 'chat steps)) ctx))
         (chat (drgnx-onboard--chat-module ctx)))
    (list (if (and ask (car chat) (seq-every-p #'cdr results)) 'ok 'warn)
          (concat head "; "
                  (mapconcat (lambda (r) (format "%s: %s/%s %s" (caar r) (cadar r) (cddar r) (if (cdr r) "answered" "did not answer")))
                             results "; ")
                  "; Ask the Codebase " (if ask "answered" "did not answer")
                  "; " (cdr chat)
                  (if tail (concat "; " tail) "")
                  " — change any: AI: Choose Provider/Model (docs/guide/ai.md)"))))

(defun drgnx-onboard--failed (result)
  "(STATUS MESSAGE) of a failed RESULT (fail REASON LOG): REASON, how to retry, where the log is."
  (pcase-let ((`(,_ ,reason ,log) result))
    (list 'fail (concat reason (if (string-search "step again" reason) "" " — run the step again to retry (downloads already done stay)")
                        (if log (format " (log: %s)" (abbreviate-file-name log)) "")))))

(defun drgnx-onboard--local-setup (tool ctx)
  "Set up TOOL (`ollama', `lmstudio') after asking: install it if missing, start it, download the models for the
room here and the embedding model, put them first in the roles, test every feature.  Asked nothing (CTX not
interactive): only says what it would run."
  (let* ((r (alist-get tool drgnx-onboard-install-recipes)) (name (plist-get r :name)) (provider (plist-get r :provider))
         (models (drgnx-onboard--local-models))
         (pulls (delete-dups (mapcar #'cdr models)))
         (commands (string-join (drgnx-onboard--setup-commands tool models) "; ")))
    (if (not (and (plist-get ctx :interactive)
                  (y-or-n-p (format "Set up %s: %s (about %s GB to download)? " name commands (drgnx-onboard--download-gb (drgnx-onboard--not-listed tool pulls))))))
        (list 'info (format "%s is not set up%s — to set it up: %s" name
                            (if (plist-get ctx :interactive) "" " (nothing is installed or downloaded without asking)") commands))
      (catch 'stop
        (cl-flet ((must (result) (unless (eq result 'ok) (throw 'stop (drgnx-onboard--failed result)))))
          (must (drgnx-onboard--install tool ctx))
          (must (drgnx-onboard--start tool))
          (dolist (m pulls)
            (must (drgnx-onboard--job (format "Downloading %s" m)
                                      (append (list (drgnx-onboard--program tool)) (cdr (plist-get r :pull))
                                              (list (drgnx-onboard--pull-name tool m)))
                                      :none)))
          (drgnx-onboard--up-p provider)                ; what it lists now: the names it serves them by
          (let ((steps (mapcar (lambda (rm) (cons (car rm) (cons provider (drgnx-onboard--served-name tool (cdr rm))))) models))
                (v (drgnx-ai-vram)))
            (pcase-dolist (`(,role . ,step) steps) (drgnx-onboard--put-first role step))
            ;; started again when it is down (after a restart): `drgnx-ai-ensure-local'
            (drgnx-ai-set-managed provider (cons (drgnx-onboard--program tool) (cdr (plist-get r :start))) name)
            (drgnx-onboard--ai-verify
             (format "%s set up (models for %s)" name
                     (if v (format "%d MiB of %s" (- (plist-get v :total) (plist-get v :used)) (if (plist-get v :unified) "memory" "GPU memory"))
                       "a machine without a GPU tool"))
             steps ctx)))))))

(defun drgnx-onboard--openrouter-setup (ctx)
  "OpenRouter: the key — asked in the drgnx app (`read-passwd') and kept in the Keychain or keyring; from the
environment in the CLI, which never reads those stores — then its model for complete, edit and chat, every
feature tested.  The embed role stays: OpenRouter has no embedding model here."
  (let* ((interactive (plist-get ctx :interactive))
         (app (and interactive (not noninteractive)))
         (key (drgnx-ai-key 'openrouter interactive))
         (new (and app (read-passwd (if key "OpenRouter API key (openrouter.ai/keys; empty: keep the one you have): "
                                      "OpenRouter API key (from openrouter.ai/keys): ")))))
    (when (equal new "") (setq new nil))
    (cond
     ((and (not key) (not app))
      (list 'info "OpenRouter: set OPENROUTER_API_KEY for the CLI, or run this step in the drgnx app (Help → Welcome), which keeps the key in your Keychain or keyring"))
     ((and (not key) (not new))
      (list 'info "no OpenRouter key given — run this step again with one (openrouter.ai/keys)"))
     (t
      (let ((stored (and new (unwind-protect
                                 ;; a copy goes in (drgnx keeps it in memory); the typed string is zeroed either way
                                 (condition-case err (drgnx-ai-store-key 'openrouter (copy-sequence new)) (user-error (cadr err)))
                               (clear-string new))))
            (env (plist-get (drgnx-ai-provider 'openrouter) :key-env)))
        (if (stringp stored) (list 'fail (concat "OpenRouter: " stored))
          (let ((steps (mapcar (lambda (rm) (cons (car rm) (cons 'openrouter (cdr rm)))) drgnx-onboard-openrouter-models)))
            (pcase-dolist (`(,role . ,step) steps) (drgnx-onboard--put-first role step))
            (drgnx-onboard--ai-verify
             (format "OpenRouter set up (key %s%s)"
                     (pcase stored ('keychain "in your Keychain") ('keyring "in your keyring") (_ "found"))
                     (if (and stored (getenv env) (not (string-empty-p (getenv env))))
                         (format "; %s is set in the environment, which wins over the stored key" env)
                       ""))
             steps ctx
             "semantic search needs a local model or TEI: the next step, Semantic Search, says how"))))))))

(defun drgnx-onboard--ai-setup (choice ctx)
  "Set up AI with CHOICE — `ollama', `lmstudio', `openrouter' or `skip' — and test every feature: (STATUS MESSAGE).
Local: install if missing, start, download the models for the room and the embedding model, set the roles.
OpenRouter: the key into the Keychain or keyring, the roles.  Then one call per role and Ask the Codebase over a
temp project.  Without interaction nothing is installed, downloaded or asked: the message says what would run.
C-g stops it (and any job it waits on)."
  (require 'drgnx-ai-probe)
  (unwind-protect
      (condition-case nil
          (pcase choice
            ('skip (list 'info "AI is not set up (skipped) — run this step again, or AI: Choose Provider/Model"))
            ('openrouter (drgnx-onboard--openrouter-setup ctx))
            (_ (drgnx-onboard--local-setup choice ctx)))
        (quit (list 'fail "stopped (C-g) — run this step again to go on")))
    (setq drgnx-onboard--progress nil)
    (drgnx-onboard--refresh-welcome)))

(defun drgnx-onboard--ai-how ()
  "What would set AI up here, for the step's answer without interaction."
  (let ((models (drgnx-onboard--local-models)))
    (format "to set AI up, run this step in the drgnx app (Help → Welcome) and choose — Ollama: %s; LM Studio: %s; OpenRouter: a key (OPENROUTER_API_KEY)"
            (string-join (drgnx-onboard--setup-commands 'ollama models) ", ")
            (string-join (drgnx-onboard--setup-commands 'lmstudio models) ", "))))

(defun drgnx-onboard--ai-step (ctx)
  "Find what runs here and test each role (`drgnx-onboard--ai-found').  Interactive, when no role answered: ask
\"Set up AI with\" — Ollama, LM Studio, OpenRouter or Skip (`drgnx-onboard--ai-setup'); when some did not, or the
step ran before: keep it or change it.  Without interaction: what was found, and what would set it up."
  (let* ((again (alist-get 'ai (drgnx-onboard-state)))
         (found (drgnx-onboard--ai-found ctx))
         (working (nth 2 found))
         (untested (nth 3 found))
         (choice (and (plist-get ctx :interactive)
                      ;; calls that ran out of time say nothing about the provider: no \"Set up AI with\" for them
                      (if (zerop working) (and (zerop untested) (drgnx-onboard--ai-ask))
                        (and (or again (< working 3))
                             (equal (drgnx-onboard--choose (format "AI answers for %d of 3 roles (complete, edit, chat): keep it or change it" working)
                                                           '("Keep" "Change") (if (< working 3) "Change" "Keep"))
                                    "Change")
                             (drgnx-onboard--ai-ask))))))
    (cond ((and choice (not (and (eq choice 'skip) (> working 0)))) (drgnx-onboard--ai-setup choice ctx))
          ((and (zerop working) (> untested 0)) (list (car found) (cadr found)))
          ((zerop working)
           (if (plist-get ctx :interactive) (list (car found) (cadr found))
             (list (car found) (concat (cadr found) "; " (drgnx-onboard--ai-how)))))
          ;; what works stays: Chat still needs its module (offered when interactive)
          (t (let ((chat (drgnx-onboard--chat-module ctx)))
               (list (if (and (not (car chat)) (eq (car found) 'ok)) 'warn (car found))
                     (concat (cadr found) "; " (cdr chat))))))))

;;;; Step 5: Semantic Search

(declare-function drgnx-search-setup "drgnx-search-setup")
(declare-function drgnx-search-setup-detect "drgnx-search-setup")
(declare-function drgnx-search-setup--current-root "drgnx-search-setup")

(defun drgnx-onboard--search-step (ctx)
  "Without interaction: report whether an embedding provider runs and whether the known projects have an index
\(nothing is changed or started).  Interactive: the Set Up Semantic Search wizard for the current project."
  (require 'drgnx-search-setup)
  (if (plist-get ctx :interactive)
      (drgnx-search-setup (drgnx-search-setup--current-root) :interactive t)
    (drgnx-search-setup-detect)))

;;;; Step 6: Agents — Claude Code

(defvar drgnx-onboard-agent-wait 10 "Seconds the claude profile's agent has to answer the ACP initialize.")
(defvar drgnx-onboard-login-wait 15 "Seconds `claude auth status' has to answer.")

(defconst drgnx-onboard-login-header "Type /login, finish in the browser, then press Return on the Agents row in the Welcome (Done)"
  "The header line of the terminal Claude Code's login happens in.")

(declare-function drgnx-agents-profile "drgnx-agents")
(declare-function drgnx-agents-command "drgnx-agents")
(declare-function drgnx-agents-claude-adapter "drgnx-agents")
(declare-function drgnx-agents-adapter-problem "drgnx-agents")
(declare-function drgnx-acp-start "drgnx-acp")
(declare-function drgnx-acp-request "drgnx-acp")
(declare-function drgnx-acp-stop "drgnx-acp")
(declare-function make-term "term")
(declare-function term-char-mode "term")

(defun drgnx-onboard--claude-missing ()
  "What of Claude Code is not here, in the order to install it: `claude' (on the path or in ~/.local/bin — a VS
Code extension's own copy does not count), Node (only when the adapter is missing too) and the adapter."
  (let ((adapter (drgnx-onboard--program 'claude-agent-acp)))
    (delq nil (list (and (not (drgnx-onboard--program 'claude)) 'claude)
                    (and (not adapter) (not (drgnx-onboard--program 'node)) 'node)
                    (and (not adapter) 'claude-agent-acp)))))

(defun drgnx-onboard--install-text (tool)
  "The command that installs TOOL here, as text: Homebrew's, the installer's, npm's, the one to run in a terminal."
  (let* ((r (alist-get tool drgnx-onboard-install-recipes))
         (p (plist-get r (if (eq (drgnx-platform) 'macos) :macos :linux)))
         (job (drgnx-onboard--platform-job tool)))
    (cond ((plist-get p :install) (string-join (plist-get p :install) " "))
          ((equal (seq-take job 2) '("bash" "-c")) (nth 2 job))
          (job (string-join job " "))
          ((drgnx-onboard--linux-shell p))
          (t (format "install %s from %s" (plist-get r :name) (plist-get p :page))))))

(defun drgnx-onboard--on-path (tool)
  "When TOOL is installed where this Emacs's PATH does not reach (~/.local/bin, beside brew), put its directory on
the PATH of this Emacs (the agent's `#!/usr/bin/env node' needs it): the directory added, else nil.  It goes at the
end: a program you chose earlier on the PATH keeps winning."
  (when-let* ((program (drgnx-onboard--program tool))
              (dir (directory-file-name (file-name-directory program)))
              ((not (executable-find (file-name-nondirectory program)))))
    (add-to-list 'exec-path dir t)
    (setenv "PATH" (concat (getenv "PATH") path-separator dir))
    dir))

(declare-function drgnx-hub-running-p "drgnx-hub")

(defun drgnx-onboard--hub-running-p ()
  "Does a hub run (one quiet look at its socket, a second at most)?  It keeps the PATH it started with."
  (require 'drgnx-hub)
  (drgnx-hub-running-p))

(defun drgnx-onboard--claude-login-state (claude)
  "Is CLAUDE logged in: `yes', `no' or `unknown' (a CLI without `auth status', or one that does not answer)?  Asks
`claude auth status' and reads only its loggedIn answer — never Claude's credentials."
  (let* ((out "") (p nil) (done nil))
    ;; the process is made inside the unwind-protect: a C-g at any point ends it
    (unwind-protect
        (progn
          (setq p (make-process :name "drgnx-claude-auth" :command (list claude "auth" "status") :connection-type 'pipe :noquery t
                                :filter (lambda (_p s) (setq out (concat out s)))))
          (unless (drgnx-onboard--wait (lambda () (not (process-live-p p))) drgnx-onboard-login-wait)
            (delete-process p))
          (setq done t))
      (when (and (not done) p (process-live-p p)) (delete-process p)))
    (cond ((string-match "\"loggedIn\"[ \t]*:[ \t]*\\(true\\|false\\)" out)
           (if (equal (match-string 1 out) "true") 'yes 'no))
          ((and (not (process-live-p p)) (eql (process-exit-status p) 0)) 'yes)
          (t 'unknown))))

(defun drgnx-onboard--claude-login-terminal (claude)
  "A terminal (`term') running CLAUDE, with the header telling what to do: its own login happens there."
  (require 'term)
  (let ((buf (make-term "Claude login" claude)))
    (with-current-buffer buf
      (term-char-mode)
      (setq header-line-format drgnx-onboard-login-header))
    (pop-to-buffer buf)
    buf))

(defun drgnx-onboard--claude-profile ()
  "Start the `claude' agent profile's program, ask it ACP initialize and stop it: (t . TEXT) when it answers within
`drgnx-onboard-agent-wait' seconds, else (nil . WHY)."
  (require 'drgnx-agents)
  (make-directory (drgnx-state-dir) t)
  (let* ((command (plist-get (cdr (drgnx-agents-profile "claude")) :command))
         (answer nil) (ended nil) (conn nil))
    (drgnx-onboard--say "Starting the claude profile's agent…")
    (condition-case err
        (setq conn (drgnx-acp-start (drgnx-agents-command command) :cwd (drgnx-state-dir)
                                    :on-exit (lambda (_c status stderr) (setq ended (cons status stderr)))))
      (error (setq answer (cons nil (list :message (error-message-string err))))))
    (unwind-protect
        (progn
          (when conn
            (drgnx-acp-request conn "initialize"
                               '(:protocolVersion 1 :clientCapabilities (:fs (:readTextFile t :writeTextFile t) :terminal :false))
                               (lambda (r) (setq answer r)))
            (drgnx-onboard--wait (lambda () answer) drgnx-onboard-agent-wait)
            (when answer (drgnx-onboard--wait (lambda () (or ended (not (cdr answer)))) 1)))
          (cond ((null answer)
                 (cons nil (format "%s did not answer within %d second%s" (string-join command " ") drgnx-onboard-agent-wait
                                   (if (= drgnx-onboard-agent-wait 1) "" "s"))))
                ((cdr answer)
                 (cons nil (if ended
                               (format "%s ended at once (exit %s)%s" (string-join command " ") (car ended)
                                       (if-let* ((line (car (last (split-string (or (cdr ended) "") "[\r\n]+" t "[ \t]+")))))
                                           (concat ": " line) ""))
                             (format "%s: %s" (string-join command " ") (plist-get (cdr answer) :message)))))
                (t (let ((info (plist-get (car answer) :agentInfo)))
                     (cons t (format "the claude profile answered%s"
                                     (if (plist-get info :name)
                                         (format " (%s)" (string-trim (format "%s %s" (plist-get info :name) (or (plist-get info :version) ""))))
                                       "")))))))
      (when conn (drgnx-acp-stop conn)))))

(defun drgnx-onboard--agents-failed (tool result)
  "(fail MESSAGE) of TOOL's failed install RESULT (fail REASON LOG): why, how to retry, where the log is."
  (pcase-let ((`(,_ ,reason ,log) result))
    (list 'fail (concat reason
                        (unless (string-search "step again" reason) " — run this step again to retry (what is installed stays)")
                        (when (drgnx-onboard--platform-job tool) (format ", or in a terminal: %s" (drgnx-onboard--install-text tool)))
                        (if log (format " (log: %s)" (abbreviate-file-name log)) "")))))

(declare-function drgnx-agents-default-profile "drgnx-agents")
(declare-function drgnx-agents-profile-names "drgnx-agents")
(declare-function drgnx-agents-mcp-names "drgnx-agents")
(declare-function drgnx-agents-set-setting "drgnx-agents")

(defun drgnx-onboard--agents-offers ()
  "Ask (interactive only) which profile New Agent Session offers on Return and which MCP servers the agents drgnx
starts get — the coordination tools and the search tool — and save both in agents.eld.  The sentence for the step's
result."
  (require 'drgnx-agents)
  (let* ((now (drgnx-agents-mcp-names))
         (profile (drgnx-onboard--choose "Default agent profile" (drgnx-agents-profile-names) (drgnx-agents-default-profile)))
         (mcp (delq nil (list (and (y-or-n-p (format "Give the agents drgnx starts its coordination tools (tasks, messages, the decision log)%s? "
                                                     (if (memq 'coordination now) " — now on" " — now off")))
                                   'coordination)
                              (and (y-or-n-p (format "Give them its search tool too (they can read the indexed code of all your projects)%s? "
                                                     (if (memq 'search now) " — now on" " — now off")))
                                   'search)))))
    (condition-case err
        (progn (drgnx-agents-set-setting :default profile)
               (drgnx-agents-set-setting :mcp mcp)
               (format "default agent profile: %s; tools for agents: %s" profile
                       (if mcp (mapconcat #'symbol-name mcp ", ") "none")))
      (user-error (format "not saved (%s)" (cadr err))))))

(defun drgnx-onboard--claude-check (ctx)
  "Claude Code is installed: its login (`claude auth status'), then the claude profile's agent (ACP initialize).  A
login that is missing — or that the CLI cannot tell — is offered a terminal running `claude' (interactive); the step
then ends `info', waiting for you to run it again (Done).  A login that cannot be told never fails the step."
  (let* ((interactive (plist-get ctx :interactive))
         (added (delq nil (list (drgnx-onboard--on-path 'node) (drgnx-onboard--on-path 'claude-agent-acp))))
         (claude (drgnx-onboard--program 'claude))
         (login (progn (drgnx-onboard--say "Checking Claude Code's login…") (drgnx-onboard--claude-login-state claude)))
         (unknown (eq login 'unknown))
         (open (and interactive (not (eq login 'yes))
                    (y-or-n-p (if unknown
                                  "drgnx could not tell whether Claude Code is logged in (this claude has no `auth status'): open a terminal to log in with claude? "
                                "Claude Code is not logged in: open a terminal to log in with claude? ")))))
    (cond
     (open
      (drgnx-onboard--claude-login-terminal claude)
      (list 'info "Claude Code is installed; a terminal with claude is open — type /login, finish in the browser, then press RET on this row in the Welcome (Done) or run this step again"))
     ((eq login 'no)
      (list 'info "Claude Code is installed but not logged in — run claude in a terminal and type /login (or run this step in the drgnx app, which opens that terminal), then this step again"))
     (t
      (pcase-let ((`(,ok . ,text) (drgnx-onboard--claude-profile)))
        (if (not ok)
            (list 'fail (format "Claude Code is installed, but %s — run claude-agent-acp in a terminal to see why, then this step again" text))
          ;; the deprecated adapter (or one too old) works, but says nothing of MCP servers: the command that moves it
          (let ((problem (drgnx-agents-adapter-problem (drgnx-agents-claude-adapter))))
            (list (cond (problem 'warn) (unknown 'info) (t 'ok))
                  (format "Claude Code is installed%s; %s%s — Agents: New Agent Session… starts it%s%s"
                          (if unknown ", but drgnx could not tell whether it is logged in (run claude and type /login if it is not)" ", logged in")
                          text
                          (if problem (format "; but %s — to move to the maintained adapter: %s" (car problem) (cdr problem)) "")
                          (if added (format " (added %s to this Emacs's PATH: add it to your shell's PATH too%s)" (string-join added ", ")
                                            (if (drgnx-onboard--hub-running-p) "; the hub keeps its old PATH: drgnx hub stop, then start a durable session again" ""))
                            "")
                          (if (and interactive (not unknown)) (concat "; " (drgnx-onboard--agents-offers)) ""))))))))))

(defun drgnx-onboard--agents-step (ctx)
  "Claude Code for the agent panel: `claude' (a VS Code extension's bundled copy does not count), Node and the
adapter `claude-agent-acp' that drgnx's `claude' profile runs, installed after asking (Homebrew on macOS; Claude's
installer, your distro's Node in a terminal and npm on Linux); its login (a terminal running `claude'); the profile
started and asked ACP initialize.  Without interaction nothing is installed: the step says what would."
  (unwind-protect
      (condition-case nil
          (let ((missing (drgnx-onboard--claude-missing)))
            (if (not missing) (drgnx-onboard--claude-check ctx)
              (let* ((commands (string-join (mapcar #'drgnx-onboard--install-text missing) "; "))
                     (sudo (if (seq-some (lambda (tool) (string-prefix-p "sudo " (drgnx-onboard--install-text tool))) missing)
                               " (the sudo one is for you to run in a terminal: it asks for your password)" "")))
                (if (not (and (plist-get ctx :interactive)
                              (y-or-n-p (format "Set up Claude Code: %s%s%s? " commands sudo
                                                (if (memq 'claude missing)
                                                    " (a claude inside a VS Code extension does not count: drgnx needs its own on your PATH)"
                                                  "")))))
                    (list 'info (format "Claude Code is not set up%s — to set it up: %s%s%s"
                                        (if (plist-get ctx :interactive) "" " (nothing is installed without asking)") commands sudo
                                        (if (memq 'claude missing) "; then log in: run claude and type /login" "")))
                  (catch 'stop
                    (dolist (tool missing)
                      (let ((result (drgnx-onboard--install tool ctx)))
                        (unless (eq result 'ok) (throw 'stop (drgnx-onboard--agents-failed tool result)))))
                    (drgnx-onboard--claude-check ctx))))))
        (quit (list 'fail "stopped (C-g) — run this step again to go on")))
    (setq drgnx-onboard--progress nil)
    (drgnx-onboard--refresh-welcome)))

;;;; Step 7: daemon and desktop

(declare-function drgnx-pkg-service-unit "drgnx-pkg")

(defconst drgnx-onboard-desktop-entry
  "[Desktop Entry]\nName=drgnx\nGenericName=Text Editor\nComment=Edit text (drgnx, an Emacs workbench)\nExec=emacsclient -s drgnx -c %F\nIcon=emacs\nType=Application\nTerminal=false\nCategories=Development;TextEditor;\nMimeType=text/plain;\n")

(defconst drgnx-onboard-keep-running-question
  "Keep drgnx running in the background when you close its last window? (recommended, like VS Code) ")

(defun drgnx-onboard--keep-running (ctx)
  "Keep running or quit when the last window closes: asked when interactive; else the choice made before, or
keep running.  Saved (session.eld); returns the sentence for the step's result."
  (let ((keep (if (plist-get ctx :interactive)
                  (y-or-n-p drgnx-onboard-keep-running-question)
                (drgnx-session-load)
                drgnx-keep-running)))
    (drgnx-session-set-keep-running keep)
    (format "%s when its last window closes (change it: Preferences: Keep drgnx Running in the Background)"
            (if keep "drgnx keeps running in the background" "drgnx quits"))))

(defvar drgnx-macos-app-dir)
(declare-function drgnx-macos-install-app "drgnx-macos")

(defconst drgnx-onboard-macos-open-text
  "open drgnx with Spotlight (⌘Space, type \"drgnx\") or Launchpad; to keep it in the Dock, drag ~/Applications/drgnx.app there, not the running Emacs icon (the Dock shows Emacs while drgnx runs)"
  "How to open the drgnx app on a Mac: it is in ~/Applications, not the Applications folder Finder's sidebar shows.")

(defun drgnx-onboard--macos-app (ctx)
  "The drgnx app in ~/Applications: there already, or installed when the user says yes.  Nothing at login."
  (require 'drgnx-macos)
  (let* ((app (expand-file-name "drgnx.app" drgnx-macos-app-dir))
         (where (abbreviate-file-name (file-name-directory app))))
    (cond ((file-directory-p app) (list 'ok (format "the drgnx app is in %s — %s" where drgnx-onboard-macos-open-text)))
          ((and (plist-get ctx :interactive)
                (y-or-n-p (format "Install the drgnx app into %s (Finder, Spotlight, the Dock, Open With)? " where)))
           (list 'ok (format "installed the drgnx app: %s — %s; open folders and code files with it from Open With"
                             (abbreviate-file-name (drgnx-macos-install-app)) drgnx-onboard-macos-open-text)))
          (t (list 'info (format "the drgnx app is not installed — to install it into %s: drgnx macos-app" where))))))

(defun drgnx-onboard--terminal-note ()
  "The terminals drgnx works best in and, in a terminal frame, that terminal's row (`drgnx-tty-onboard-note'); for a
terminal that cannot send every key, also what to install (`drgnx-tty-recommendation': it only says, nothing is
installed).  Reads what drgnx found when the terminal opened (the terminal parameter `drgnx-tty-caps'); asks the
terminal nothing."
  (let* ((caps (and (not (display-graphic-p)) (terminal-parameter nil 'drgnx-tty-caps)))
         (rec (and caps (ignore-errors (drgnx-tty-recommendation caps (drgnx-tty-os))))))
    (concat (drgnx-tty-onboard-note (plist-get caps :id)) (if rec (concat " " (plist-get rec :text)) ""))))

(declare-function drgnx-doctor-check "drgnx-doctor")
(declare-function drgnx-platform-doctor-facts "drgnx-platform")

(defun drgnx-onboard--desktop-note ()
  "The doctor's Desktop row for the selected frame (`drgnx-platform-doctor-facts'): its detail, and its fix in
parentheses when it is not ok.  Never prompts, never installs."
  (require 'drgnx-doctor)
  (condition-case err
      (pcase-let ((`(,status ,detail ,fix)
                   (drgnx-doctor-check 'window-manager
                                       (list :window-manager (drgnx-platform-doctor-facts (selected-frame))))))
        (concat detail (if (and fix (not (eq status 'ok))) (format " (%s)" fix) "")))
    (error (format "not checked (%s)" (error-message-string err)))))

(defun drgnx-onboard--daemon-step (ctx)
  "Keep running or quit (asked once), then macOS: the drgnx app; Linux: the systemd unit and desktop entry.  The
result reads: keep running; that platform part; the terminal note (`drgnx-onboard--terminal-note'); the desktop
\(`drgnx-onboard--desktop-note')."
  (let ((keep (drgnx-onboard--keep-running ctx)))
    (pcase-let ((`(,status ,message) (if (eq (drgnx-platform) 'macos) (drgnx-onboard--macos-app ctx)
                                       (drgnx-onboard--linux-desktop ctx))))
      (list status (concat keep "; " message ". " (drgnx-onboard--terminal-note)
                           "; desktop: " (drgnx-onboard--desktop-note))))))

(defun drgnx-onboard--linux-desktop (ctx)
  (require 'drgnx-pkg)
  (let* ((dir (drgnx-user-dir))
         (unit (expand-file-name "systemd/drgnx.service" dir))
         (desktop (expand-file-name "applications/drgnx.desktop" dir))
         (unit-target (expand-file-name "~/.config/systemd/user/drgnx.service"))
         (desktop-target (expand-file-name "~/.local/share/applications/drgnx.desktop"))
         (how (format "mkdir -p %s %s && cp %s %s && cp %s %s && systemctl --user daemon-reload && systemctl --user enable --now drgnx; and in your shell's rc file: export EDITOR='emacsclient -s drgnx -t' VISUAL='emacsclient -s drgnx -c'"
                      (shell-quote-argument (file-name-directory unit-target)) (shell-quote-argument (file-name-directory desktop-target))
                      (shell-quote-argument unit) (shell-quote-argument unit-target)
                      (shell-quote-argument desktop) (shell-quote-argument desktop-target))))
    (drgnx-pkg-service-unit (file-name-directory unit))
    (make-directory (file-name-directory desktop) t)
    (write-region drgnx-onboard-desktop-entry nil desktop nil 'silent)
    (if (and (plist-get ctx :interactive)
             (y-or-n-p (format "Install the drgnx service and desktop entry into %s and %s%s? "
                               (file-name-directory unit-target) (file-name-directory desktop-target)
                               (if (or (file-exists-p unit-target) (file-exists-p desktop-target)) " (replacing the ones there)" ""))))
        (progn
          (dolist (p (list (cons unit unit-target) (cons desktop desktop-target)))
            (make-directory (file-name-directory (cdr p)) t)
            (copy-file (car p) (cdr p) t))
          (call-process "systemctl" nil nil nil "--user" "daemon-reload")
          (list 'ok (format "installed; start it with: systemctl --user enable --now drgnx")))
      (list 'info (format "written (not installed): %s and %s. To install: %s" unit desktop how)))))

;;;; Step 9: finish

(declare-function drgnx-doctor-run "drgnx-doctor")
(declare-function drgnx-doctor-facts "drgnx-doctor")

(declare-function drgnx-jobs--detach "drgnx-jobs")

(defun drgnx-onboard--under-systemd-p ()
  "Non-nil when this Emacs is a process of a systemd unit (INVOCATION_ID) and a user manager can start another."
  (and (getenv "INVOCATION_ID") (getenv "XDG_RUNTIME_DIR") (executable-find "systemd-run") t))

(defun drgnx-onboard--restart-spawn (line)
  "Start the restart waiter LINE (a shell line) so that it outlives this Emacs.  Normally detached in its own
session.  As a systemd service (drgnx.service) this Emacs shares a cgroup with it, and systemd kills what is left
in the cgroup when the main process ends — the detached waiter too — so there it runs as its own transient unit
\(`KillMode=process': a daemon `drgnx open' starts stays); the detached way is also the fallback."
  (require 'drgnx-jobs)
  (unless (and (drgnx-onboard--under-systemd-p)
               (eql 0 (call-process "systemd-run" nil nil nil "--user" "--quiet" "--collect"
                                    (format "--unit=drgnx-restart-%d" (emacs-pid)) "-p" "KillMode=process"
                                    "sh" "-c" (replace-regexp-in-string "[$%]" "\\&\\&" line))))   ; ExecStart reads $ and %
    (drgnx-jobs--detach line)))

(defun drgnx-onboard--restart ()
  "Restart drgnx: ask the quit questions first (`drgnx-session-quit-confirm': save, lose changes?), then — only
on a yes — start `drgnx open' to run once this Emacs has ended (`drgnx-onboard--restart-spawn'; a minute at
most: kept running, it opens nothing), and quit.  A no or C-g leaves drgnx running and nothing waiting.  The
layout comes back with drgnx open."
  (when (drgnx-session-quit-confirm)
    (drgnx-onboard--restart-spawn
     (format "sleep 1; i=0; while kill -0 %d 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done; kill -0 %d 2>/dev/null || exec %s open"
             (emacs-pid) (emacs-pid) (shell-quote-argument (expand-file-name "bin/drgnx" drgnx-dir))))
    (kill-emacs)))

(defun drgnx-onboard--finish-step (ctx)
  "The doctor's results; on macOS with the drgnx app installed, how to open drgnx next time.  When a step turned
modules on or installed packages here, in the drgnx app (CTX interactive): asked whether to restart drgnx now
\(the result is recorded first)."
  (require 'drgnx-doctor)
  (let* ((results (drgnx-doctor-run (drgnx-doctor-facts)))
         (count (lambda (s) (seq-count (lambda (r) (eq (plist-get r :status) s)) results)))
         (fails (seq-filter (lambda (r) (eq (plist-get r :status) 'fail)) results))
         (result (list (if fails 'fail 'ok)
                       (format "doctor: %d ok, %d warnings, %d failed%s — every command and its key: Keyboard Shortcuts (in the palette)%s; docs/guide/onboarding.md"
                               (funcall count 'ok) (funcall count 'warn) (length fails)
                               (if fails (concat " (" (mapconcat (lambda (r) (symbol-name (plist-get r :name))) fails ", ") ")") "")
                               (if (and (eq (drgnx-platform) 'macos)
                                        (progn (require 'drgnx-macos) (file-directory-p (expand-file-name "drgnx.app" drgnx-macos-app-dir))))
                                   (concat "; next time " drgnx-onboard-macos-open-text) "")))))
    (cond ((not (and drgnx-onboard--restart-needed (plist-get ctx :interactive) (not noninteractive))) result)
          ((y-or-n-p "Restart drgnx now? Your windows come back. ")
           (drgnx-onboard--record 'finish (car result) (cadr result))
           (drgnx-onboard--restart)
           result)                      ; still running: a change was kept unsaved
          (t (list (car result) (concat (cadr result) "; Quit drgnx (⌘Q on a Mac) and open it again to load your modules"))))))

;;;; The steps

(drgnx-onboard-define-step 'environment :order 10 :title "Check the Environment"
                           :doc "Emacs, git, ripgrep, fd, podman, mise, GPU, the icon font: what is there and how to get the rest"
                           :run #'drgnx-onboard--environment-step)
(drgnx-onboard-define-step 'look-and-keys :order 20 :title "Look and Keys"
                           :doc "Key profile, colour theme and module preset (minimal, IDE, full AI)"
                           :run #'drgnx-onboard--look-step)
(drgnx-onboard-define-step 'projects :order 30 :title "Import Projects"
                           :doc "Find your git repositories and put them, with their TODOs, on the org board"
                           :run #'drgnx-onboard--projects-step)
(drgnx-onboard-define-step 'ai :order 40 :title "AI Providers"
                           :doc "Model providers found (OpenRouter, Ollama, LM Studio, llama.cpp …), a provider and model per role, each tested; with none, sets up Ollama, LM Studio or OpenRouter (asked), models sized to the machine, every feature tested"
                           :run #'drgnx-onboard--ai-step)
(drgnx-onboard-define-step 'search :order 50 :title "Semantic Search"
                           :doc "An embedding model found and tested, the current project indexed in the background (the same as Set Up Semantic Search); without interaction it only reports what is there"
                           :run #'drgnx-onboard--search-step)
(drgnx-onboard-define-step 'agents :order 60 :title "Agents"
                           :doc "Claude Code for the agent panel: installed if missing (asked), your own login in a terminal, the claude profile started and checked; without interaction it only says what would set it up"
                           :run #'drgnx-onboard--agents-step)
(drgnx-onboard-define-step 'daemon :order 70 :title "Daemon and Desktop"
                           :doc "Keep running in the background or quit when the last window closes; macOS: the drgnx app; Linux: the systemd user service, the desktop entry and EDITOR — installed only if you say so"
                           :run #'drgnx-onboard--daemon-step)
(drgnx-onboard-define-step 'portability :order 80 :title "Portability"
                           :doc "chezmoi and age for your configuration and secrets on a second machine"
                           :run (drgnx-onboard--detect '("chezmoi" "age") "setting up a second machine is documented with the platforms milestone (M12)"))
(drgnx-onboard-define-step 'finish :order 90 :title "Finish"
                           :doc "drgnx doctor: what is left to fix"
                           :run #'drgnx-onboard--finish-step)

;;;; Welcome (the steps in Emacs)

(defvar drgnx-onboard-mode-map
  (let ((m (make-sparse-keymap)))
    (keymap-set m "RET" #'drgnx-onboard-run-step-at-point)
    (keymap-set m "n" #'drgnx-onboard-next-step)
    m))

(defconst drgnx-onboard-welcome-header "Return runs the step under the cursor — start at the top"
  "The Welcome's header line (its column names are the buffer's first line).")

(define-derived-mode drgnx-onboard-mode tabulated-list-mode "Welcome"
  "The onboarding steps: RET runs the step on the line, then the cursor moves to the next one; n moves to the
next step not done (a finished step's row ends with a Next button that does the same)."
  (setq tabulated-list-format [("Step" 22 nil) ("Status" 7 nil) ("" 0 nil)]
        tabulated-list-use-header-line nil)   ; the column names in the buffer: the header line says what to do
  (tabulated-list-init-header)
  (setq header-line-format drgnx-onboard-welcome-header))

(defun drgnx-onboard--next-undone (id state)
  "The next step after ID that is not done in STATE (`drgnx-onboard-state'): ok and info are done.  After the
last step it goes on from the first; nil when no step but ID is left."
  (let* ((ids (drgnx-onboard-steps))
         (tail (cdr (memq id ids))))
    (seq-find (lambda (i) (not (memq (plist-get (alist-get i state) :status) '(ok info))))
              (append tail (seq-take-while (lambda (i) (not (eq i id))) ids)))))

(defun drgnx-onboard--next-button (id state)
  "A \"Next: STEP\" button to the next step not done after ID, or nil when there is none.  It moves the cursor
there; it runs nothing (each step keeps its own consent)."
  (when-let* ((next (drgnx-onboard--next-undone id state)))
    (buttonize (format "Next: %s" (plist-get (alist-get next drgnx-onboard--steps) :title))
               #'drgnx-onboard--goto-step next)))

(defun drgnx-onboard--entries ()
  (let ((state (drgnx-onboard-state)))
    (mapcar (lambda (id)
              (let* ((spec (alist-get id drgnx-onboard--steps)) (s (alist-get id state))
                     (busy (and (eq id (car drgnx-onboard--progress)) (cdr drgnx-onboard--progress)))
                     (next (and s (not busy) (drgnx-onboard--next-button id state))))
                (list id (vector (plist-get spec :title)
                                 (cond (busy "…") (s (symbol-name (plist-get s :status))) (t "—"))
                                 (if next
                                     (concat (plist-get s :message) "  " next)
                                   (or busy (plist-get s :message) (plist-get spec :doc)))))))
            (drgnx-onboard-steps))))

(defun drgnx-onboard-welcome ()
  "The onboarding steps, their status; RET runs one."
  (interactive)
  (with-current-buffer (get-buffer-create "*drgnx Welcome*")
    (drgnx-onboard-mode)
    (setq tabulated-list-entries #'drgnx-onboard--entries)
    (tabulated-list-print)
    (unless (tabulated-list-get-id) (drgnx-onboard--goto-step (car (drgnx-onboard-steps))))   ; on the first step
    (pop-to-buffer-same-window (current-buffer))))

(defun drgnx-onboard--welcome-due-p ()
  "Non-nil when the Welcome should open by itself: onboarding never ran here (no onboarding.eld), in a drgnx
with windows (not batch, not a harness session)."
  (not (or noninteractive (getenv "DRGNX_UI_RUN") (file-exists-p (drgnx-onboard-state-file)))))

(defun drgnx-onboard-maybe-welcome ()
  "Open the Welcome in the graphical window when onboarding never ran here — once: the state file it leaves
\(no step done) keeps it from opening by itself again.  Asks nothing.  From a timer: see
`drgnx-onboard--on-first-window'."
  (when (drgnx-onboard--welcome-due-p)
    (drgnx-onboard--write-state nil)
    (with-demoted-errors "drgnx: the Welcome did not open: %S"
      (with-selected-frame (or (and (display-graphic-p) (selected-frame))
                               (seq-find #'display-graphic-p (frame-list))
                               (selected-frame))
        (drgnx-onboard-welcome)))))

(defun drgnx-onboard--on-first-window ()
  "`drgnx-first-gui-frame-hook': the Welcome a moment after the first window shows, from an idle timer —
never inside the hook (the window and the restored layout come first)."
  (when (drgnx-onboard--welcome-due-p)
    (run-with-idle-timer 0.5 nil #'drgnx-onboard-maybe-welcome)))

(defun drgnx-onboard-run-step (id)
  "Run onboarding step ID now (it may ask), then show the steps."
  (let ((r (car (drgnx-onboard-run :only (list id)))))
    (message "%s: %s — %s" (plist-get (alist-get id drgnx-onboard--steps) :title) (nth 1 r) (nth 2 r))
    (drgnx-onboard--refresh-welcome)
    r))

(defun drgnx-onboard--goto-step (id)
  "Point (and the Welcome's window's) on step ID's row of the Welcome, when it has one."
  (when-let* ((b (get-buffer "*drgnx Welcome*")))
    (with-current-buffer b
      (let ((pos (save-excursion
                   (goto-char (point-min))
                   (while (and (not (eq (tabulated-list-get-id) id)) (zerop (forward-line 1))))
                   (and (eq (tabulated-list-get-id) id) (point)))))
        (when pos
          (goto-char pos)
          (when-let* ((w (get-buffer-window b t))) (set-window-point w pos)))))))

(defun drgnx-onboard-run-step-at-point ()
  "Run the step on this line, then move to the next step."
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (drgnx-onboard-run-step id)
    (when-let* ((next (cadr (memq id (drgnx-onboard-steps))))) (drgnx-onboard--goto-step next))))

(defun drgnx-onboard-next-step ()
  "Move to the next step not done (after this one, then from the top); runs nothing."
  (interactive)
  (let ((state (drgnx-onboard-state)))
    (if-let* ((id (tabulated-list-get-id))
              (next (drgnx-onboard--next-undone id state)))
        (drgnx-onboard--goto-step next)
      (message (if (seq-every-p (lambda (i) (memq (plist-get (alist-get i state) :status) '(ok info)))
                                (drgnx-onboard-steps))
                   "All done: every step is done"
                 "This is the only step left")))))

(declare-function drgnx-command-define "drgnx-registry")

(defun drgnx-onboard-register-commands ()
  "Welcome and one command per step (Onboarding: …), in the registry."
  (drgnx-command-define 'projects-sync-plans :category "Projects" :title "Sync Plans and Board TODOs"
                        :command #'drgnx-projects-sync-plans
                        :doc "A DONE TODO ticks its plan checkbox; a ticked checkbox makes its TODO DONE")
  (drgnx-command-define 'onboarding :category "Help" :title "Welcome (Onboarding)" :command #'drgnx-onboard-welcome
                        :menu '("Help") :doc "The onboarding steps: environment, keys, projects, daemon …; run any of them again")
  (dolist (id (drgnx-onboard-steps))
    (let ((spec (alist-get id drgnx-onboard--steps)))
      (drgnx-command-define (intern (format "onboarding-%s" id)) :category "Onboarding" :title (plist-get spec :title)
                            :command (let ((id id)) (lambda () (interactive) (drgnx-onboard-run-step id)))
                            :doc (plist-get spec :doc)))))

(with-eval-after-load 'drgnx-rules
  (when (fboundp 'drgnx-wb-place) (drgnx-wb-place 'drgnx-onboard-mode 'editor)))

;;;; CLI: drgnx onboard

(defun drgnx-onboard-cli-run (args)
  "Run `drgnx onboard' with ARGS (strings); the exit code."
  (let (non-interactive only options (resume t))
    (catch 'usage
      (while args
        (pcase (pop args)
          ("--non-interactive" (setq non-interactive t))
          ("--again" (setq resume nil))
          ("--todos" (setq options (plist-put options :todos t)))
          ("--preset" (setq options (plist-put options :preset (intern (or (pop args) "")))))
          ("--keys" (setq options (plist-put options :keys (pop args))))
          ("--theme" (setq options (plist-put options :theme (intern (or (pop args) "")))))
          ("--step" (let ((id (intern (or (pop args) ""))))
                      (unless (memq id (drgnx-onboard-steps))
                        (princ (format "drgnx onboard: no step %s (steps: %s)\n" id (mapconcat #'symbol-name (drgnx-onboard-steps) " ")))
                        (throw 'usage 2))
                      (setq only (append only (list id)) resume nil)))
          ("--roots" (let (roots)
                       (while (and args (not (string-prefix-p "--" (car args)))) (push (pop args) roots))
                       (unless roots (princ "drgnx onboard: --roots needs at least one directory\n") (throw 'usage 2))
                       (setq options (plist-put options :roots (nreverse roots)))))
          (a (princ (format "drgnx onboard: unknown argument %s\nusage: drgnx onboard [--non-interactive] [--again] [--preset minimal|ide|full-ai] [--keys NAME] [--theme THEME] [--roots DIR…] [--todos] [--step ID]…\n" a))
             (throw 'usage 2))))
      (let ((r (drgnx-onboard-run :only only :non-interactive non-interactive :options options :resume resume)))
        (pcase-dolist (`(,id ,status ,msg) r)
          (princ (format "%-5s %-14s %s\n" (upcase (symbol-name status)) id msg)))
        (if (seq-some (lambda (s) (eq (cadr s) 'fail)) r) 1 0)))))

(defun drgnx-onboard-cli ()
  "bin/drgnx onboard: the arguments after --."
  (let ((args (cdr (member "--" command-line-args-left))))
    (setq command-line-args-left nil)
    (kill-emacs (drgnx-onboard-cli-run args))))

(provide 'drgnx-onboard)
;;; drgnx-onboard.el ends here
