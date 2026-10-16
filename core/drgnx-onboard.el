;;; drgnx-onboard.el --- Onboarding: the steps from a fresh machine to a working drgnx -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Onboarding is a list of steps — environment, look and keys, projects, AI, search, agents, daemon,
;; portability, finish — each a registry command ("Onboarding: Import Projects"), re-runnable,
;; idempotent, its progress kept in onboarding.eld (state dir) so a run resumes where it stopped.  A
;; step returns (STATUS MESSAGE); an error is a failed step, never fatal.  `drgnx onboard' runs them
;; from the command line (--non-interactive never reads input); "Welcome" lists them in Emacs.
;; Nothing is installed outside drgnx's own directories unless the user, running a step
;; interactively, says yes.  See docs/onboarding.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'drgnx-paths)
(require 'drgnx-modules)

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
    (with-temp-file (drgnx-onboard-state-file) (let ((print-length nil)) (prin1 state (current-buffer))))))

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

(defun drgnx-onboard--look-step (ctx)
  (require 'drgnx-keys)
  (let* ((o (plist-get ctx :options)) (ask (plist-get ctx :interactive))
         (preset (or (plist-get o :preset)
                     (if ask (intern (completing-read "Modules (minimal, ide, full-ai): " (mapcar #'car drgnx-onboard-presets) nil t nil nil "ide"))
                       'ide)))
         (keys (or (plist-get o :keys)
                   (if ask (completing-read "Keys: " drgnx-keys-presets nil t nil nil "VS Code") "VS Code")))
         (theme (or (plist-get o :theme)
                    (and ask (let ((s (completing-read "Color theme (empty: keep): " (mapcar #'symbol-name (custom-available-themes)))))
                               (unless (string-empty-p s) (intern s))))))
         (layers (or (cdr (assoc keys drgnx-keys-presets)) (user-error "Unknown key profile %s" keys))))
    (drgnx-onboard-apply-preset preset)
    (if (and (not noninteractive) (fboundp 'drgnx-keys-apply)) (drgnx-keys-use layers t) (drgnx-keys--save-layers layers))
    (when theme
      (if (and (not noninteractive) (fboundp 'drgnx-look-load-theme)) (drgnx-look-load-theme theme)
        (drgnx-modules-write-state (plist-put (copy-sequence (drgnx-modules-read-state)) :theme theme))))
    (list 'ok (format "modules: %s; keys: %s%s" preset keys (if theme (format "; theme: %s" theme) "")))))

;;;; Step 3: projects

(declare-function drgnx-projects-scan "drgnx-projects")
(declare-function drgnx-projects-gryphn-roots "drgnx-projects")
(declare-function drgnx-projects-import "drgnx-projects")
(declare-function drgnx-projects-board-file "drgnx-projects")

(defconst drgnx-onboard-default-roots '("~/workspace" "~/code" "~/src" "~/projects" "~/git"))

(defun drgnx-onboard--projects-step (ctx)
  (require 'drgnx-projects)
  (let* ((o (plist-get ctx :options))
         (roots (or (plist-get o :roots) (seq-filter #'file-directory-p (mapcar #'expand-file-name drgnx-onboard-default-roots))))
         (found (delete-dups (mapcar #'directory-file-name
                                     (append (drgnx-projects-scan roots)
                                             (seq-filter #'file-directory-p (drgnx-projects-gryphn-roots))))))
         (picked (if (and (plist-get ctx :interactive) found)
                     (completing-read-multiple (format "Projects to import (%d found; comma-separated, empty: all): " (length found))
                                               found)
                   found))
         (picked (or picked found)))
    (if (null picked)
        (list 'info (format "no git repositories under %s" (string-join roots ", ")))
      (let ((r (drgnx-projects-import picked)))
        (list 'ok (format "%d projects on the board (%d new), %d TODOs added — %s"
                          (length picked) (length (plist-get r :added)) (plist-get r :todos) (drgnx-projects-board-file)))))))

;;;; Steps 4–6, 8: what is there (completed by later milestones)

(defun drgnx-onboard--detect (programs then)
  (lambda (_ctx)
    (let ((found (seq-filter #'executable-find programs)))
      (list 'info (format "%s; %s" (if found (concat "found: " (string-join found ", ")) "nothing found") then)))))

;;;; Step 7: daemon and desktop

(declare-function drgnx-pkg-service-unit "drgnx-pkg")

(defconst drgnx-onboard-desktop-entry
  "[Desktop Entry]\nName=drgnx\nGenericName=Text Editor\nComment=Edit text (drgnx, an Emacs workbench)\nExec=emacsclient -s drgnx -c -a \"\" %F\nIcon=emacs\nType=Application\nTerminal=false\nCategories=Development;TextEditor;\nMimeType=text/plain;\n")

(defun drgnx-onboard--daemon-step (ctx)
  (require 'drgnx-pkg)
  (let* ((dir (drgnx-user-dir))
         (unit (expand-file-name "systemd/drgnx.service" dir))
         (desktop (expand-file-name "applications/drgnx.desktop" dir))
         (unit-target (expand-file-name "~/.config/systemd/user/drgnx.service"))
         (desktop-target (expand-file-name "~/.local/share/applications/drgnx.desktop"))
         (how (format "cp %s %s && systemctl --user daemon-reload && systemctl --user enable --now drgnx; cp %s %s; export EDITOR='emacsclient -s drgnx -t' VISUAL='emacsclient -s drgnx -c'"
                      unit unit-target desktop desktop-target)))
    (drgnx-pkg-service-unit (file-name-directory unit))
    (make-directory (file-name-directory desktop) t)
    (write-region drgnx-onboard-desktop-entry nil desktop nil 'silent)
    (if (and (plist-get ctx :interactive)
             (y-or-n-p (format "Install the drgnx service and desktop entry into %s and %s? "
                               (file-name-directory unit-target) (file-name-directory desktop-target))))
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
          (format "doctor: %d ok, %d warnings, %d failed%s — the key sheet: C-k C-s (VS Code keys); docs/onboarding.md"
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
  (let (non-interactive only options)
    (catch 'usage
      (while args
        (pcase (pop args)
          ("--non-interactive" (setq non-interactive t))
          ("--preset" (setq options (plist-put options :preset (intern (or (pop args) "")))))
          ("--keys" (setq options (plist-put options :keys (pop args))))
          ("--theme" (setq options (plist-put options :theme (intern (or (pop args) "")))))
          ("--step" (setq only (append only (list (intern (or (pop args) ""))))))
          ("--roots" (let (roots)
                       (while (and args (not (string-prefix-p "--" (car args)))) (push (pop args) roots))
                       (setq options (plist-put options :roots (nreverse roots)))))
          (a (princ (format "drgnx onboard: unknown argument %s\nusage: drgnx onboard [--non-interactive] [--preset minimal|ide|full-ai] [--keys NAME] [--theme THEME] [--roots DIR…] [--step ID]…\n" a))
             (throw 'usage 2))))
      (let ((r (drgnx-onboard-run :only only :non-interactive non-interactive :options options)))
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
