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

(defvar drgnx-onboard--steps nil "Alist ID → plist (:title :doc :order :run :check).")

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

(defun drgnx-onboard--record (id status message)
  (let ((state (drgnx-onboard-state)))
    (setf (alist-get id state) (list :status status :message message :time (format-time-string "%FT%T%z")))
    (make-directory (file-name-directory (drgnx-onboard-state-file)) t)
    (let ((tmp (make-temp-file (expand-file-name ".onboarding-" (file-name-directory (drgnx-onboard-state-file))))))
      (with-temp-file tmp (let ((print-length nil)) (prin1 state (current-buffer))))
      (rename-file tmp (drgnx-onboard-state-file) t))))

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
  '((git ("git") t "install git with your package manager (e.g. dnf install git)")
    (ripgrep ("rg") nil "fast project search: install ripgrep (dnf install ripgrep)")
    (fd ("fd" "fdfind") nil "fast file listing: install fd (dnf install fd-find)")
    (podman ("podman") nil "containers for tests and local AI servers: install podman")
    (mise ("mise") nil "language servers and tools per project: https://mise.jdx.dev")
    (gpu ("nvidia-smi" "rocm-smi") nil "no GPU tool found: local AI models will run on the CPU"))
  "(ID PROGRAMS REQUIRED FIX): what drgnx looks for.")

(defun drgnx-onboard--font-p (family)
  (with-temp-buffer
    (and (eql 0 (ignore-errors (call-process "fc-list" nil t nil (concat ":family=" family))))
         (> (buffer-size) 0))))

(defun drgnx-onboard-environment ()
  "Alist ID → (:status ok|missing :required :fix) for the tools and the icon font."
  (append
   (mapcar (lambda (tool)
             (pcase-let ((`(,id ,programs ,required ,fix) tool))
               (cons id (list :status (if (seq-some #'executable-find programs) 'ok 'missing) :required required :fix fix))))
           drgnx-onboard-tools)
   (list (cons 'icon-font (list :status (if (drgnx-onboard--font-p "Symbols Nerd Font") 'ok 'missing) :required nil
                                :fix "icons in the Explorer: install the Symbols Nerd Font (https://www.nerdfonts.com)")))))

(defun drgnx-onboard--environment-step (_ctx)
  (let* ((env (drgnx-onboard-environment))
         (missing (seq-filter (lambda (e) (eq (plist-get (cdr e) :status) 'missing)) env)))
    (list (cond ((seq-some (lambda (e) (plist-get (cdr e) :required)) missing) 'fail) (missing 'warn) (t 'ok))
          (if missing
              (mapconcat (lambda (e) (format "%s missing — %s" (car e) (plist-get (cdr e) :fix))) missing "; ")
            "every tool drgnx uses is here"))))

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

(defun drgnx-onboard--projects-step (ctx)
  (require 'drgnx-projects)
  (let* ((o (plist-get ctx :options))
         (roots (or (plist-get o :roots) (seq-filter #'file-directory-p (mapcar #'expand-file-name drgnx-onboard-default-roots))))
         (found (delete-dups (mapcar #'directory-file-name
                                     (append (drgnx-projects-scan roots)
                                             (seq-filter #'file-directory-p (drgnx-projects-gryphn-roots))))))
         (truncated drgnx-projects-scan-truncated)
         (ask (and (plist-get ctx :interactive) found))
         (picked (if ask
                     (or (completing-read-multiple (format "Projects to import (%d found; empty: all): " (length found)) found)
                         found)
                   found))
         (todos (cond ((plist-member o :todos) (plist-get o :todos))
                      ((and ask picked)
                       (completing-read-multiple "Import TODOs (TODO.md, TODO.org, plan checklists) from (empty: none): " picked))))
         (stopped (and truncated (format " — the scan stopped after %ss at %s; pass the directories with --roots"
                                         drgnx-projects-scan-budget truncated))))
    (if (null picked)
        (list (if truncated 'warn 'info) (concat (format "no git repositories found under %s" (string-join roots ", ")) stopped))
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

;;;; Step 7: daemon and desktop

(declare-function drgnx-pkg-service-unit "drgnx-pkg")

(defconst drgnx-onboard-desktop-entry
  "[Desktop Entry]\nName=drgnx\nGenericName=Text Editor\nComment=Edit text (drgnx, an Emacs workbench)\nExec=emacsclient -s drgnx -c %F\nIcon=emacs\nType=Application\nTerminal=false\nCategories=Development;TextEditor;\nMimeType=text/plain;\n")

(defun drgnx-onboard--daemon-step (ctx)
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
                           :doc "Local model runners found; providers, keys and models per role come with the AI milestone"
                           :run (drgnx-onboard--detect '("ollama" "llama-server" "lms") "providers and models are set up by the AI step (M9)"))
(drgnx-onboard-define-step 'search :order 50 :title "Semantic Search"
                           :doc "Embedding servers found; indexing your projects comes with the search milestone"
                           :run (drgnx-onboard--detect '("text-embeddings-router" "ollama") "indexing is set up by the search step (M10)"))
(drgnx-onboard-define-step 'agents :order 60 :title "Agents"
                           :doc "Agent CLIs found (Claude, gryphn); profiles and MCP servers come with the agents milestone"
                           :run (drgnx-onboard--detect '("claude" "gry") "agent profiles and MCP servers are set up by the agents step (M7)"))
(drgnx-onboard-define-step 'daemon :order 70 :title "Daemon and Desktop"
                           :doc "The systemd user service, the desktop entry and EDITOR — written, installed only if you say so"
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
              (let ((spec (alist-get id drgnx-onboard--steps)) (s (alist-get id state)))
                (list id (vector (plist-get spec :title)
                                 (if s (symbol-name (plist-get s :status)) "—")
                                 (or (plist-get s :message) (plist-get spec :doc))))))
            (drgnx-onboard-steps))))

(defun drgnx-onboard-welcome ()
  "The onboarding steps, their status; RET runs one."
  (interactive)
  (with-current-buffer (get-buffer-create "*drgnx Welcome*")
    (drgnx-onboard-mode)
    (setq tabulated-list-entries #'drgnx-onboard--entries)
    (tabulated-list-print)
    (pop-to-buffer-same-window (current-buffer))))

(defun drgnx-onboard-run-step (id)
  "Run onboarding step ID now (it may ask), then show the steps."
  (let ((r (car (drgnx-onboard-run :only (list id)))))
    (message "%s: %s — %s" (plist-get (alist-get id drgnx-onboard--steps) :title) (nth 1 r) (nth 2 r))
    (when-let* ((b (get-buffer "*drgnx Welcome*"))) (with-current-buffer b (tabulated-list-print t)))
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
