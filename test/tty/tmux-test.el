;;; tmux-test.el --- tty tier: drgnx inside tmux — keys, copy, focus, colour, what is reported -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs).  Every test has two private tmux servers: the outer
;; one the harness always has (the terminal) and an inner one (`:nested' LINES = its config) with Emacs in it,
;; as in real use.  Keys, copies and the screen go through the outer one.  The inner tmux's defaults are tmux's
;; own (set-clipboard external, extended-keys off, focus-events off), so every test says what it turns on.
(require 'ert)
(require 'drgnx-tty-session)

(defconst drgnx-tty-tmux-test--log
  '(progn
     (defvar kx-commands nil)
     (setq kx-commands nil)
     (add-hook 'pre-command-hook (lambda () (push this-command kx-commands)))
     t)
  "A form, in the inner Emacs: log every command about to run in `kx-commands', newest first.")

(defun drgnx-tty-tmux-test--ready (sess)
  "Wait until SESS's Emacs shows the workbench; log its commands."
  (drgnx-tty-session-wait-screen sess "\\*scratch\\* ×" 20)
  (drgnx-tty-session-eval sess drgnx-tty-tmux-test--log))

(defun drgnx-tty-tmux-test--copy (sess text)
  "Copy TEXT in SESS's Emacs with `kill-ring-save', the profile's copy command."
  (drgnx-tty-session-eval
   sess `(with-temp-buffer
           (insert ,text)
           (kill-ring-save (point-min) (point-max))
           t)))

(defun drgnx-tty-tmux-test--clipboard (sess)
  "The outer tmux's paste buffer once something is in it (5 s), else nil."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (drgnx-tty-session-clipboard sess)) (< (float-time) deadline)) (sleep-for 0.05))
    (drgnx-tty-session-clipboard sess)))

(ert-deftest drgnx-tty-tmux/identified-inside-tmux ()
  (drgnx-tty-session-with (s :keys "vscode" :nested '("# tmux's own defaults"))
    (drgnx-tty-tmux-test--ready s)
    (should (eq (drgnx-tty-session-eval s '(plist-get (terminal-parameter nil 'drgnx-tty-caps) :id)) 'tmux))
    ;; this is the inner tmux: Emacs has its TMUX, and drgnx can ask it
    (should (string-match-p "inner" (drgnx-tty-session-eval s '(getenv "TMUX"))))
    (should (stringp (drgnx-tty-session-eval s '(plist-get (drgnx-tty-tmux-options) :version))))))

(defconst drgnx-tty-tmux-test--busy
  '(progn
     (defvar kx-returned nil)
     (defun kx-busy ()
       (interactive)
       (let ((t0 (float-time)))
         (unwind-protect (while (< (- (float-time) t0) 30))
           (setq kx-returned (float-time)))))
     (push (list (cons t (let ((m (make-sparse-keymap))) (define-key m [f12] #'kx-busy) m))) emulation-mode-map-alists)
     t)
  "A form, in the inner Emacs: F12 runs `kx-busy', 30 s of busy Lisp that sets `kx-returned' when it ends.")

(defun drgnx-tty-tmux-test--caps (sess)
  (drgnx-tty-session-eval sess '(terminal-parameter nil 'drgnx-tty-caps)))

(ert-deftest drgnx-tty-tmux/nested-keys-arrive ()
  ;; extended-keys on, modifyOtherKeys level 1 (the default): C-. arrives, C-g stays one byte and stops busy Lisp,
  ;; and the chords tmux folds (C-S-p arrives as C-p) are reported as not sendable
  (drgnx-tty-session-with (s :keys "vscode" :nested '("set -s extended-keys on"))
    (drgnx-tty-tmux-test--ready s)
    (let ((caps (drgnx-tty-tmux-test--caps s)))
      (should (eq (plist-get caps :keys) 'mok))
      (should (eq (plist-get caps :c-g) 'always))
      (should (member "C-S-p" (plist-get caps :folded)))
      (should (member "C-S-p" (plist-get (cdr (car (plist-get (drgnx-tty-session-eval s '(drgnx-tty--read-report)) :terminals)))
                                         :unsendable))))
    (drgnx-tty-session-key s "C-." 'mok)
    (drgnx-tty-session-wait s '(memq 'drgnx-lang-quick-fix kx-commands))
    ;; what tmux folds: C-S-p reaches Emacs as C-p
    (drgnx-tty-session-key s "C-S-p" 'mok)
    (drgnx-tty-session-wait s '(memq 'project-find-file kx-commands))
    (should-not (drgnx-tty-session-eval s '(memq 'drgnx-palette kx-commands)))
    (drgnx-tty-session-key s "C-g")
    (drgnx-tty-session-wait s '(null (active-minibuffer-window)))
    ;; ordinary keys still arrive
    (drgnx-tty-session-send s "a")
    (drgnx-tty-session-wait s '(memq 'self-insert-command kx-commands))
    ;; C-g stops busy Lisp
    (drgnx-tty-session-eval s drgnx-tty-tmux-test--busy)
    (drgnx-tty-session-key s "<f12>" 'mok)
    (sleep-for 0.5)
    (let ((sent (float-time)))
      (drgnx-tty-session-key s "C-g")
      (should (< (- (drgnx-tty-session-wait s 'kx-returned 10) sent) 2)))))

(ert-deftest drgnx-tty-tmux/nested-keys-arrive-at-level-2 ()
  ;; `drgnx-tty-tmux-mok-level' 2: C-S-p arrives and is sendable, C-g waits (caps say so)
  (drgnx-tty-session-with (s :keys "vscode" :nested '("set -s extended-keys on"))
    (drgnx-tty-tmux-test--ready s)
    (drgnx-tty-session-eval s '(progn (setq drgnx-tty-tmux-mok-level 2) (drgnx-tty-frames--tmux-setup (selected-frame)) t))
    (let ((caps (drgnx-tty-tmux-test--caps s)))
      (should (eq (plist-get caps :keys) 'mok))
      (should (eq (plist-get caps :c-g) 'waits))
      (should-not (plist-get caps :folded)))
    (should-not (member "C-S-p" (plist-get (cdr (car (plist-get (drgnx-tty-session-eval s '(drgnx-tty--read-report)) :terminals)))
                                           :unsendable)))
    (drgnx-tty-session-key s "C-S-p" 'mok)
    (drgnx-tty-session-wait s '(memq 'drgnx-palette kx-commands))
    ;; C-g still closes a prompt (it reaches Emacs as an escape sequence, decoded)
    (drgnx-tty-session-key s "C-g")
    (drgnx-tty-session-wait s '(null (active-minibuffer-window)))
    (drgnx-tty-session-key s "C-." 'mok)
    (drgnx-tty-session-wait s '(memq 'drgnx-lang-quick-fix kx-commands))
    (drgnx-tty-session-send s "a")
    (drgnx-tty-session-wait s '(memq 'self-insert-command kx-commands))))

(ert-deftest drgnx-tty-tmux/nested-keys-arrive-in-csi-u-format ()
  ;; extended-keys-format csi-u: tmux sends the chords as CSI u, and Emacs reads them (level 1: C-.; level 2: C-S-p)
  (drgnx-tty-session-with (s :keys "vscode" :nested '("set -s extended-keys on" "set -s extended-keys-format csi-u"))
    (drgnx-tty-tmux-test--ready s)
    (drgnx-tty-session-send s "\e[46;5u")
    (drgnx-tty-session-wait s '(memq 'drgnx-lang-quick-fix kx-commands))
    (drgnx-tty-session-eval s '(progn (setq drgnx-tty-tmux-mok-level 2) (drgnx-tty-frames--tmux-setup (selected-frame)) t))
    (drgnx-tty-session-send s "\e[112;6u")
    (drgnx-tty-session-wait s '(memq 'drgnx-palette kx-commands))))

(ert-deftest drgnx-tty-tmux/nested-copy-arrives ()
  (drgnx-tty-session-with (s :keys "vscode" :nested '("set -s set-clipboard on" "set -as terminal-features ',tmux*:clipboard'"))
    (drgnx-tty-tmux-test--ready s)
    (should (drgnx-tty-session-eval s '(plist-get (terminal-parameter nil 'drgnx-tty-caps) :osc52)))
    (drgnx-tty-tmux-test--copy s "hello through tmux")
    (should (equal (drgnx-tty-tmux-test--clipboard s) "hello through tmux"))))

(ert-deftest drgnx-tty-tmux/nested-copy-through-passthrough ()
  (drgnx-tty-session-with (s :keys "vscode" :nested '("set -s set-clipboard off" "set -g allow-passthrough on"))
    (drgnx-tty-tmux-test--ready s)
    (drgnx-tty-tmux-test--copy s "hello through passthrough")
    (should (equal (drgnx-tty-tmux-test--clipboard s) "hello through passthrough"))))

(ert-deftest drgnx-tty-tmux/nested-copy-without-a-way-stays-in-drgnx ()
  (drgnx-tty-session-with (s :keys "vscode" :nested '("set -s set-clipboard external"))
    (drgnx-tty-tmux-test--ready s)
    (should-not (drgnx-tty-session-eval s '(plist-get (terminal-parameter nil 'drgnx-tty-caps) :osc52)))
    (drgnx-tty-tmux-test--copy s "stays here")
    (should (equal (drgnx-tty-session-eval s '(car kill-ring)) "stays here"))
    (sleep-for 0.5)
    (should-not (drgnx-tty-session-clipboard s))))

(ert-deftest drgnx-tty-tmux/focus-events-reach-drgnx ()
  (drgnx-tty-session-with (s :keys "vscode" :nested '("set -g focus-events on"))
    (drgnx-tty-tmux-test--ready s)
    (drgnx-tty-session-eval s '(progn (defvar kx-focus-runs 0)
                                      (add-function :after after-focus-change-function
                                                    (lambda () (setq kx-focus-runs (1+ kx-focus-runs))))
                                      t))
    (drgnx-tty-session-send s "\e[O")
    (drgnx-tty-session-wait s '(eq (terminal-parameter nil 'tty-focus-state) 'defocused))
    (should-not (drgnx-tty-session-eval s '(eq (frame-focus-state) t)))
    (let ((runs (drgnx-tty-session-eval s 'kx-focus-runs)))
      (should (>= runs 1))
      (drgnx-tty-session-send s "\e[I")
      (drgnx-tty-session-wait s '(eq (terminal-parameter nil 'tty-focus-state) 'focused))
      (should (> (drgnx-tty-session-eval s 'kx-focus-runs) runs)))
    (should (drgnx-tty-session-eval s '(eq (frame-focus-state) t)))))

(ert-deftest drgnx-tty-tmux/true-colour-with-rgb ()
  (drgnx-tty-session-with (s :keys "vscode" :nested '("set -as terminal-features ',tmux*:RGB'")
                             :env '("COLORTERM=truecolor"))
    (drgnx-tty-tmux-test--ready s)
    (should (= (drgnx-tty-session-eval s '(display-color-cells)) 16777216))
    (should (drgnx-tty-session-eval s '(plist-get (drgnx-tty-tmux-options) :rgb)))))

(ert-deftest drgnx-tty-tmux/missing-settings-are-reported-never-written ()
  (drgnx-tty-session-with (s :keys "vscode" :nested '("set -s set-clipboard external"))
    (drgnx-tty-tmux-test--ready s)
    (let* ((conf (expand-file-name "inner.conf" (plist-get s :run)))
           (before (with-temp-buffer (insert-file-contents-literally conf) (buffer-string)))
           (lines (drgnx-tty-session-eval
                   s '(plist-get (cdr (car (plist-get (drgnx-tty--read-report) :terminals))) :tmux-conf))))
      (should (member "set -s set-clipboard on" lines))
      (should (member "set -s extended-keys on" lines))
      (should (member "set -g focus-events on" lines))
      ;; the lines are what `drgnx-tty-tmux-conf-lines' gives for the options tmux reports
      (should (equal lines (drgnx-tty-session-eval s '(drgnx-tty-tmux-conf-lines (drgnx-tty-tmux-options)))))
      ;; nothing was written: the inner config is as the session made it, and the temp HOME has no .tmux.conf
      (should (equal before (with-temp-buffer (insert-file-contents-literally conf) (buffer-string))))
      (should-not (file-exists-p (expand-file-name "home/.tmux.conf" (plist-get s :run))))
      (should-not (file-exists-p (expand-file-name "home/.config/tmux/tmux.conf" (plist-get s :run)))))))

;;; tmux-test.el ends here
