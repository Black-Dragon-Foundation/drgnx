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
(declare-function drgnx-keys-file "drgnx-keys")
(declare-function drgnx-keys--user "drgnx-keys")

(defun drgnx-onboard--current-keys ()
  "The name of the key preset keys.eld uses now, or nil."
  (let ((layers (ignore-errors
                  (plist-get (with-temp-buffer (insert-file-contents (drgnx-keys-file)) (read (current-buffer))) :layers))))
    (car (rassoc layers drgnx-keys-presets))))

(defun drgnx-onboard--current-preset ()
  "The preset the extra/ modules match now, or nil."
  (let* ((extras (drgnx-onboard--extras))
         (off (seq-filter (lambda (m) (memq m extras)) (plist-get (drgnx-modules-read-state) :disabled))))
    (cond ((null off) (and (plist-member (drgnx-modules-read-state) :disabled) 'full-ai))
          ((seq-set-equal-p off extras) 'minimal)
          ((equal off '(extra/llm)) 'ide))))

(defun drgnx-onboard--look-step (ctx)
  "Key profile, theme and module preset: the options given, else (asking, when interactive, with the
current choice as the default) — with no option and no question, the current choices stay."
  (require 'drgnx-keys)
  (let* ((o (plist-get ctx :options)) (ask (plist-get ctx :interactive))
         (cur-preset (drgnx-onboard--current-preset)) (cur-keys (drgnx-onboard--current-keys))
         (preset (or (plist-get o :preset)
                     (and ask (intern (completing-read "Modules (minimal, ide, full-ai): " (mapcar #'car drgnx-onboard-presets)
                                                       nil t nil nil (symbol-name (or cur-preset 'ide)))))))
         (keys (or (plist-get o :keys)
                   (and ask (completing-read "Keys: " drgnx-keys-presets nil t nil nil (or cur-keys "VS Code")))))
         (theme (or (plist-get o :theme)
                    (and ask (let ((s (completing-read "Color theme (empty: keep): " (mapcar #'symbol-name (custom-available-themes)))))
                               (unless (string-empty-p s) (intern s))))))
         (layers (and keys (or (cdr (assoc keys drgnx-keys-presets)) (user-error "Unknown key profile %s" keys)))))
    (when (and preset (not (eq preset cur-preset))) (drgnx-onboard-apply-preset preset))
    (when (and layers (not (equal keys cur-keys)))
      (if (and (not noninteractive) (fboundp 'drgnx-keys-apply)) (drgnx-keys-use layers t) (drgnx-keys--save-layers layers)))
    (when theme
      (if (and (not noninteractive) (fboundp 'drgnx-look-load-theme)) (drgnx-look-load-theme theme)
        (drgnx-modules-write-state (plist-put (copy-sequence (drgnx-modules-read-state)) :theme theme))))
    (list 'ok (format "modules: %s; keys: %s%s (modules take effect at the next start)"
                      (or preset cur-preset "as they are") (or keys cur-keys "as they are")
                      (if theme (format "; theme: %s" theme) "")))))

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

(defun drgnx-onboard--ai-test (role step ctx)
  "One call to STEP (PROVIDER . MODEL) of the kind ROLE makes — fill in the middle, chat or an embedding: t when it
answered."
  (let ((interactive (plist-get ctx :interactive)))
    (if (eq role 'embed)
        (condition-case nil
            (and (drgnx-ai-embed-sync (vector "hello") :timeout 15 :chain (list step) :interactive interactive) t)
          (drgnx-ai-embed-error nil))
      (let ((fim (eq role 'complete)) (result nil))
        (drgnx-ai-request role (if fim 'fim 'chat)
                          (if fim (list :prefix "(defun hello ()\n  " :suffix ")\n" :max-tokens 8)
                            (list :messages (vector (list :role "user" :content "Say OK."))))
                          (lambda (text _info) (setq result (if text 'yes 'no)))
                          :chain (list step) :timeout 15 :interactive interactive)
        (drgnx-onboard--wait (lambda () result) 16)
        (eq result 'yes)))))

(defun drgnx-onboard--ai-found (ctx)
  "Find the providers running here, give each role without a working one a provider found, test each role with
one call: (STATUS MESSAGE ANSWERED), ANSWERED how many of the three roles answered."
  (require 'drgnx-ai-probe)
  (let ((done nil))
    (drgnx-ai-probe (lambda () (setq done t)))
    (drgnx-onboard--wait (lambda () done) 3))
  (let ((key (drgnx-ai-key 'openrouter (plist-get ctx :interactive))) (lines nil) (answered 0) (asked 0))
    (dolist (role '(complete edit chat))
      (let* ((cap (if (eq role 'complete) 'fim 'chat))
             (usable (seq-find (lambda (s) (drgnx-ai-usable-p (car s) cap (plist-get ctx :interactive))) (drgnx-ai-role role)))
             (step (or usable (drgnx-onboard--ai-pick role cap (plist-get ctx :interactive)))))
        (if (not step) (push (format "%s: no provider" role) lines)
          (unless usable (drgnx-ai-set-role role (cons step (drgnx-ai-role role))))
          (cl-incf asked)
          (let ((yes (drgnx-onboard--ai-test role step ctx)))
            (when yes (cl-incf answered))
            (push (format "%s: %s/%s %s" role (car step) (cdr step) (if yes "answered" "did not answer")) lines)))))
    (unless key
      (push "OpenRouter: set OPENROUTER_API_KEY in your shell profile, or add \"machine openrouter.ai password <key>\" to ~/.authinfo.gpg" lines))
    (let* ((vram (drgnx-ai-vram)) (model (cdr (car (drgnx-ai-role 'complete))))
           (need (if model (drgnx-ai-model-vram model) 0))
           (free (and vram (- (plist-get vram :total) (plist-get vram :used)))))
      (when free
        (push (format (if (plist-get vram :unified) "memory for models: %d MiB (two thirds of the RAM), the completion model needs about %d"
                        "GPU: %d MiB free, the completion model needs about %d")
                      free need)
              lines))
      (list (cond ((zerop asked) 'info) ((and free (> need free)) 'warn) ((< answered asked) 'warn) (t 'ok))
            (if (zerop asked)
                (concat "no provider is running here and no OpenRouter key is set — start Ollama, LM Studio or llama.cpp, "
                        "or set the key; then AI: Choose Provider/Model; " (string-join (nreverse lines) "; "))
              (concat (string-join (nreverse lines) "; ") " — change any: AI: Choose Provider/Model (docs/guide/ai.md)"))
            answered))))

;;;; Step 4: setting AI up — Ollama, LM Studio or OpenRouter

(defconst drgnx-onboard-install-recipes
  '((ollama :name "Ollama" :provider ollama
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
              :pull ("lms" "get" "-y")))
  "How onboarding sets up a local model runner: ID → plist.  :check — it is there when its :program is found (lms
also in ~/.lmstudio/bin, where LM Studio puts it) or its :provider's address answers.  :macos :install — the
Homebrew command, a drgnx job; :launch — LM Studio's first start, which puts lms in place.  :linux :shell — Ollama's
official installer, which uses sudo: shown, for you to run in a terminal (a job has no terminal to ask your
password in); :page — LM Studio's download page.  :start — the server, a drgnx job (never at login); :pull — the
download, the model's name after it.")

(defconst drgnx-onboard-embed-model "nomic-embed-text"
  "The embedding model a local runner set up here downloads (Ollama's name; LM Studio's: `drgnx-ai-lmstudio-models').")

(defconst drgnx-onboard-openrouter-models
  '((complete . "qwen/qwen-2.5-coder-32b-instruct") (edit . "openrouter/auto") (chat . "openrouter/auto"))
  "The OpenRouter model onboarding gives each role.")

(defconst drgnx-onboard-ai-choices
  '(("Ollama (local)" . ollama) ("LM Studio (local)" . lmstudio) ("OpenRouter (cloud key)" . openrouter) ("Skip" . skip))
  "The answers to \"Set up AI with\".")

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
(defvar drgnx-ai-lmstudio-models)

(defconst drgnx-onboard--brew-programs '("/opt/homebrew/bin/brew" "/usr/local/bin/brew")
  "Where Homebrew lives on Apple silicon and on Intel, when the app's PATH lacks it.")

(defun drgnx-onboard--brew ()
  (or (executable-find "brew") (seq-find #'file-executable-p drgnx-onboard--brew-programs)))

(defun drgnx-onboard--program (tool)
  "TOOL's program, a path — on the path, in ~/.lmstudio/bin or beside brew — or nil."
  (let ((name (plist-get (plist-get (alist-get tool drgnx-onboard-install-recipes) :check) :program))
        (brew (drgnx-onboard--brew)))
    (or (executable-find name)
        (seq-find #'file-executable-p
                  (delq nil (list (and (eq tool 'lmstudio) (expand-file-name name "~/.lmstudio/bin"))
                                  (and brew (expand-file-name name (file-name-directory brew)))))))))

(defun drgnx-onboard--up-p (provider)
  "Does PROVIDER's address answer now?  One probe of it (a second at most); `drgnx-ai-detected' has what it found."
  (let ((done nil))
    (drgnx-ai-probe (lambda () (setq done t)) (list provider))
    (drgnx-onboard--wait (lambda () done) 3)
    (plist-get (alist-get provider drgnx-ai-detected) :up)))

(defun drgnx-onboard--until (pred secs)
  "Wait until PRED, asked four times a second, at most SECS: its last value.  For the step (a command): C-g quits."
  (let ((deadline (+ (float-time) secs)) (v nil))
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline))
      (unless noninteractive (redisplay))
      (accept-process-output nil 0.25))
    v))

(defun drgnx-onboard--refresh-welcome ()
  (when-let* ((b (get-buffer "*drgnx Welcome*"))) (with-current-buffer b (tabulated-list-print t))))

(defun drgnx-onboard--last-line (id)
  "The last line job ID wrote (a progress bar's last state), or nil."
  (car (last (split-string (drgnx-jobs-log id 2000) "[\r\n]+" t "[ \t]+"))))

(defun drgnx-onboard--show-progress (step what id)
  "The progress timer: WHAT and job ID's last log line, in STEP's row of the Welcome and the echo area.  Reads only."
  (let ((text (format "%s… %s" what (or (drgnx-onboard--last-line id) ""))))
    (unless (equal text (cdr drgnx-onboard--progress))
      (setq drgnx-onboard--progress (cons step text))
      (drgnx-onboard--refresh-welcome)
      (message "%s" text))))

(defun drgnx-onboard--job (what command &optional secs)
  "Run COMMAND (a list) as a drgnx job for WHAT and wait for it to end, at most SECS (default an hour); meanwhile the
Welcome shows its last log line.  `ok', or (fail REASON LOG): REASON ends with the log's last line.  C-g stops the
job, then quits."
  (require 'drgnx-jobs)
  (make-directory (drgnx-state-dir) t)
  (let* ((id (drgnx-jobs-start (concat "Onboarding: " what) command :cwd (drgnx-state-dir)))
         (log (expand-file-name "log" (drgnx-jobs--dir id)))
         (t0 (float-time)) (job nil)
         (timer (run-at-time 0.5 0.5 #'drgnx-onboard--show-progress drgnx-onboard--current what id)))
    (unwind-protect
        (condition-case nil
            (progn
              (drgnx-onboard--until (lambda ()
                                      (setq job (drgnx-jobs-get id))
                                      ;; gone: it ended without writing its exit (killed); not while it starts
                                      (or (plist-get job :exit) (and (eq (plist-get job :status) 'gone) (> (- (float-time) t0) 3))))
                                    (or secs 3600))
              (if (eql (plist-get job :exit) 0) 'ok
                (when (eq (plist-get job :status) 'running) (drgnx-jobs-stop id))
                (list 'fail (format "%s failed (%s)%s" what
                                    (cond ((plist-get job :exit) (format "exit %d" (plist-get job :exit)))
                                          ((eq (plist-get job :status) 'running) "it took too long and was stopped")
                                          (t "it ended without an exit status"))
                                    (if-let* ((line (drgnx-onboard--last-line id))) (concat ": " line) ""))
                      log)))
          (quit (drgnx-jobs-stop id) (signal 'quit nil)))
      (cancel-timer timer)
      (setq drgnx-onboard--progress nil)
      (drgnx-onboard--refresh-welcome))))

(declare-function browse-url "browse-url")

(defun drgnx-onboard--install (tool ctx)
  "Install TOOL (an id of `drgnx-onboard-install-recipes') for this platform: `ok' once its program is there or its
server answers, else (fail REASON LOG), LOG nil when nothing ran.  Only when CTX is interactive (the step asked
first).  macOS: the Homebrew command as a drgnx job — LM Studio: then its first start, which puts lms in place.
Linux: Ollama's installer for you to run in a terminal (it uses sudo), or LM Studio's download page; then a wait
for its server (C-g stops it).  Every run starts from the top: nothing is resumed from a run that failed."
  (let* ((r (alist-get tool drgnx-onboard-install-recipes))
         (name (plist-get r :name))
         (there (lambda () (or (drgnx-onboard--program tool) (drgnx-onboard--up-p (plist-get r :provider))))))
    (cond
     ((not (plist-get ctx :interactive)) (list 'fail (format "%s is not installed (nothing is installed without asking)" name) nil))
     ((funcall there) 'ok)
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
      (let ((l (plist-get r :linux)))
        (if (plist-get l :page)
            (progn (browse-url (plist-get l :page))
                   (message "Install %s from %s and open it (Developer → Start Server); waiting for it… (C-g stops)" name (plist-get l :page)))
          (kill-new (plist-get l :shell))
          (message "Run in a terminal (copied): %s — it asks for your password (sudo); waiting for %s… (C-g stops)" (plist-get l :shell) name))
        (if (drgnx-onboard--until there drgnx-onboard-app-wait) 'ok
          (list 'fail (format "%s did not show up within %d minutes: %s, then run this step again" name (/ drgnx-onboard-app-wait 60)
                              (if (plist-get l :page) (format "install it from %s and open it" (plist-get l :page))
                                (format "run %s in a terminal" (plist-get l :shell))))
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

(defun drgnx-onboard--put-first (role step)
  "STEP (PROVIDER . MODEL) first in ROLE's chain in ai.eld; the role's other providers stay behind it."
  (drgnx-ai-set-role role (cons step (seq-remove (lambda (s) (eq (car s) (car step))) (drgnx-ai-role role)))))

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

(defun drgnx-onboard--ai-verify (head steps ctx &optional tail)
  "Test each of STEPS ((ROLE PROVIDER . MODEL)…) with one call, then Ask the Codebase with the chat step:
\(STATUS MESSAGE), the message HEAD, the results, TAIL."
  (let* ((results (mapcar (lambda (s) (cons s (drgnx-onboard--ai-test (car s) (cdr s) ctx))) steps))
         (ask (drgnx-onboard--ask-test (cdr (assq 'chat steps)) ctx)))
    (list (if (and ask (seq-every-p #'cdr results)) 'ok 'warn)
          (concat head "; "
                  (mapconcat (lambda (r) (format "%s: %s/%s %s" (caar r) (cadar r) (cddar r) (if (cdr r) "answered" "did not answer")))
                             results "; ")
                  "; Ask the Codebase " (if ask "answered" "did not answer")
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
                  (y-or-n-p (format "Set up %s: %s (about %s GB to download)? " name commands (drgnx-onboard--download-gb pulls)))))
        (list 'info (format "%s is not set up%s — to set it up: %s" name
                            (if (plist-get ctx :interactive) "" " (nothing is installed or downloaded without asking)") commands))
      (catch 'stop
        (cl-flet ((must (result) (unless (eq result 'ok) (throw 'stop (drgnx-onboard--failed result)))))
          (must (drgnx-onboard--install tool ctx))
          (must (drgnx-onboard--start tool))
          (dolist (m pulls)
            (must (drgnx-onboard--job (format "Downloading %s" m)
                                      (append (list (drgnx-onboard--program tool)) (cdr (plist-get r :pull))
                                              (list (drgnx-onboard--pull-name tool m))))))
          (drgnx-onboard--up-p provider)                ; what it lists now: the names it serves them by
          (let ((steps (mapcar (lambda (rm) (cons (car rm) (cons provider (drgnx-onboard--served-name tool (cdr rm))))) models))
                (v (drgnx-ai-vram)))
            (pcase-dolist (`(,role . ,step) steps) (drgnx-onboard--put-first role step))
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
      (let ((stored (and new (condition-case err (drgnx-ai-store-key 'openrouter new) (user-error (cadr err))))))
        (if (stringp stored) (list 'fail (concat "OpenRouter: " stored))
          (let ((steps (mapcar (lambda (rm) (cons (car rm) (cons 'openrouter (cdr rm)))) drgnx-onboard-openrouter-models)))
            (pcase-dolist (`(,role . ,step) steps) (drgnx-onboard--put-first role step))
            (drgnx-onboard--ai-verify
             (format "OpenRouter set up (key %s)" (pcase stored ('keychain "in your Keychain") ('keyring "in your keyring") (_ "found")))
             steps ctx
             "semantic search needs a local model or TEI: the next step, Semantic Search, says how"))))))))

(defun drgnx-onboard--ai-setup (choice ctx)
  "Set up AI with CHOICE — `ollama', `lmstudio', `openrouter' or `skip' — and test every feature: (STATUS MESSAGE).
Local: install if missing, start, download the models for the room and the embedding model, set the roles.
OpenRouter: the key into the Keychain or keyring, the roles.  Then one call per role and Ask the Codebase over a
temp project.  Without interaction nothing is installed, downloaded or asked: the message says what would run.
C-g stops it (and any job it waits on)."
  (require 'drgnx-ai-probe)
  (condition-case nil
      (pcase choice
        ('skip (list 'info "AI is not set up (skipped) — run this step again, or AI: Choose Provider/Model"))
        ('openrouter (drgnx-onboard--openrouter-setup ctx))
        (_ (drgnx-onboard--local-setup choice ctx)))
    (quit (list 'fail "stopped (C-g) — run this step again to go on"))))

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
         (ask (lambda () (cdr (assoc (completing-read "Set up AI with: " drgnx-onboard-ai-choices nil t) drgnx-onboard-ai-choices))))
         (choice (and (plist-get ctx :interactive)
                      (if (zerop working) (funcall ask)
                        (and (or again (< working 3))
                             (equal (completing-read (format "AI answers for %d of 3 roles (complete, edit, chat): keep it or change it? " working)
                                                     '("Keep" "Change") nil t nil nil (if (< working 3) "Change" "Keep"))
                                    "Change")
                             (funcall ask))))))
    (cond ((and choice (not (and (eq choice 'skip) (> working 0)))) (drgnx-onboard--ai-setup choice ctx))
          ((and (not (plist-get ctx :interactive)) (zerop working))
           (list (car found) (concat (cadr found) "; " (drgnx-onboard--ai-how))))
          (t (list (car found) (cadr found))))))

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

(defun drgnx-onboard--macos-app (ctx)
  "The drgnx app in ~/Applications: there already, or installed when the user says yes.  Nothing at login."
  (require 'drgnx-macos)
  (let* ((app (expand-file-name "drgnx.app" drgnx-macos-app-dir))
         (where (abbreviate-file-name (file-name-directory app))))
    (cond ((file-directory-p app) (list 'ok (format "the drgnx app is in %s" where)))
          ((and (plist-get ctx :interactive)
                (y-or-n-p (format "Install the drgnx app into %s (Finder, Spotlight, the Dock, Open With)? " where)))
           (list 'ok (format "installed the drgnx app: %s — open drgnx from Applications or Spotlight, and folders and code files with Open With"
                             (abbreviate-file-name (drgnx-macos-install-app)))))
          (t (list 'info (format "the drgnx app is not installed — to install it into %s: drgnx macos-app" where))))))

(defun drgnx-onboard--daemon-step (ctx)
  "Keep running or quit (asked once), then macOS: the drgnx app; Linux: the systemd unit and desktop entry."
  (let ((keep (drgnx-onboard--keep-running ctx)))
    (pcase-let ((`(,status ,message) (if (eq (drgnx-platform) 'macos) (drgnx-onboard--macos-app ctx)
                                       (drgnx-onboard--linux-desktop ctx))))
      (list status (concat message "; " keep)))))

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

(defun drgnx-onboard--finish-step (_ctx)
  (require 'drgnx-doctor)
  (let* ((results (drgnx-doctor-run (drgnx-doctor-facts)))
         (count (lambda (s) (seq-count (lambda (r) (eq (plist-get r :status) s)) results)))
         (fails (seq-filter (lambda (r) (eq (plist-get r :status) 'fail)) results)))
    (list (if fails 'fail 'ok)
          (format "doctor: %d ok, %d warnings, %d failed%s — every command and its key: Keyboard Shortcuts (in the palette); docs/guide/onboarding.md"
                  (funcall count 'ok) (funcall count 'warn) (length fails)
                  (if fails (concat " (" (mapconcat (lambda (r) (symbol-name (plist-get r :name))) fails ", ") ")") "")))))

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
                           :doc "Agent CLIs found (Claude, gryphn); profiles and MCP servers come with the agents milestone"
                           :run (drgnx-onboard--detect '("claude" "gry") "agent profiles and MCP servers are set up by the agents step (M7)"))
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
  (let ((m (make-sparse-keymap))) (keymap-set m "RET" #'drgnx-onboard-run-step-at-point) m))

(define-derived-mode drgnx-onboard-mode tabulated-list-mode "Welcome"
  "The onboarding steps: RET runs the step on the line."
  (setq tabulated-list-format [("Step" 22 nil) ("Status" 7 nil) ("" 0 nil)])
  (tabulated-list-init-header))

(defun drgnx-onboard--entries ()
  (let ((state (drgnx-onboard-state)))
    (mapcar (lambda (id)
              (let ((spec (alist-get id drgnx-onboard--steps)) (s (alist-get id state))
                    (busy (and (eq id (car drgnx-onboard--progress)) (cdr drgnx-onboard--progress))))
                (list id (vector (plist-get spec :title)
                                 (cond (busy "…") (s (symbol-name (plist-get s :status))) (t "—"))
                                 (or busy (plist-get s :message) (plist-get spec :doc))))))
            (drgnx-onboard-steps))))

(defun drgnx-onboard-welcome ()
  "The onboarding steps, their status; RET runs one."
  (interactive)
  (with-current-buffer (get-buffer-create "*drgnx Welcome*")
    (drgnx-onboard-mode)
    (setq tabulated-list-entries #'drgnx-onboard--entries)
    (tabulated-list-print)
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

(defun drgnx-onboard-run-step-at-point ()
  "Run the step on this line."
  (interactive)
  (when-let* ((id (tabulated-list-get-id))) (drgnx-onboard-run-step id)))

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
