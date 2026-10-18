;;; drgnx-evil.el --- Module editor/evil: evil as drgnx's Vim engine -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Vim editing engine, plugged into the engine-neutral modal core (core/drgnx-modal.el).  Off until the
;; user picks a Vim key stack (it is `:default off'): nothing installs or loads before that.  It sets evil's
;; defaults, registers the engine `evil' and lets `drgnx-modal-sync-engine' start it when the key layers need
;; it.  While it runs: panels and forms are in emacs state and inputs (shells, commit messages) in insert
;; state; every state change goes to `drgnx-modal-set-state' (leader and panel maps, the mode-line indicator);
;; the cursor has a shape per state, and in a panel stays what the panel set (none, mostly); in a terminal
;; Emacs 31.1 follows the shape (`xterm-update-cursor'); the built-in which-key shows the leader's keys.
;; Toggle Modal Editing turns the engine off and on for this session.  See docs/guide/keys.md ("Vim keys").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-keys)
(require 'drgnx-modal)

;; evil's variables and functions, read and called only after `(require 'evil)'.
(defvar evil-want-keybinding)
(defvar evil-undo-system)
(defvar evil-want-C-u-scroll)
(defvar evil-search-module)
(defvar evil-want-minibuffer)
(defvar evil-mode-line-format)
(defvar evil-state)
(defvar evil-local-mode)
(defvar evil-visual-selection)
(defvar evil-default-cursor)
(defvar evil-normal-state-cursor)
(defvar evil-insert-state-cursor)
(defvar evil-visual-state-cursor)
(defvar evil-replace-state-cursor)
(defvar evil-operator-state-cursor)
(defvar evil-motion-state-cursor)
(defvar evil-emacs-state-cursor)
(defvar which-key-show-transient-maps)
(defvar which-key-mode)
(defvar xterm-update-cursor)
(defvar git-commit-setup-hook)
(declare-function evil-mode "evil-core")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-insert-state "evil-states")
(declare-function which-key-mode "which-key")

;;;; Settings

(defun drgnx-evil--settings ()
  "Set evil's defaults (before it loads): no evil-collection auto-keys (`evil-want-keybinding' must be nil
for evil-collection), Emacs' `undo-redo', C-u scrolls, evil's own search, no evil in the minibuffer, no evil
mode-line tag (drgnx's indicator replaces it).  Users override these in config.el with `setopt'."
  (setq evil-want-keybinding nil
        evil-undo-system 'undo-redo
        evil-want-C-u-scroll t
        evil-search-module 'evil-search
        evil-want-minibuffer nil
        evil-mode-line-format nil))

;;;; Cursor

(defvar-local drgnx-evil--own-cursor nil
  "A one-element list holding the `cursor-type' this buffer had before evil, once evil refreshed its cursor.")

(defun drgnx-evil--own ()
  "This buffer's own cursor-type, as (VALUE): taken the first time evil refreshes the cursor here, which is
before evil sets anything (`drgnx-evil--cursor-default' runs first)."
  (or drgnx-evil--own-cursor (setq drgnx-evil--own-cursor (list cursor-type))))

(defun drgnx-evil--shape (shape)
  "Show SHAPE as the cursor, or in a panel the cursor the panel had (most have none)."
  (setq cursor-type (if (drgnx-modal-panel-p) (car (drgnx-evil--own)) shape)))

(defun drgnx-evil--cursor-default ()
  "evil's first step of every cursor refresh (`evil-default-cursor'): note the buffer's own cursor, then show
the default one (a panel's own)."
  (drgnx-evil--own)
  (drgnx-evil--shape t))
(defun drgnx-evil--cursor-box () (drgnx-evil--shape 'box))
(defun drgnx-evil--cursor-bar () (drgnx-evil--shape 'bar))
(defun drgnx-evil--cursor-hollow () (drgnx-evil--shape 'hollow))
(defun drgnx-evil--cursor-hbar () (drgnx-evil--shape 'hbar))

(defconst drgnx-evil--cursor-vars
  '((evil-default-cursor . drgnx-evil--cursor-default)
    (evil-normal-state-cursor . drgnx-evil--cursor-box)
    (evil-motion-state-cursor . drgnx-evil--cursor-box)
    (evil-insert-state-cursor . drgnx-evil--cursor-bar)
    (evil-emacs-state-cursor . drgnx-evil--cursor-bar)
    (evil-visual-state-cursor . drgnx-evil--cursor-hollow)
    (evil-replace-state-cursor . drgnx-evil--cursor-hbar)
    (evil-operator-state-cursor . drgnx-evil--cursor-hbar))
  "evil's cursor variables and the function drgnx puts in each: the shape per state.  Only the shape: the
colour is the theme's `cursor' face.")

(defvar drgnx-evil--saved nil "Alist of what drgnx replaced while the engine runs, VARIABLE → its value before.")

(defun drgnx-evil--save (var value)
  "Set VAR to VALUE, remembering what it was (once) for `drgnx-evil--restore'."
  (unless (assq var drgnx-evil--saved)
    (push (cons var (symbol-value var)) drgnx-evil--saved))
  (set var value))

(defun drgnx-evil--restore ()
  "Put back the variables `drgnx-evil--save' changed."
  (pcase-dolist (`(,var . ,old) drgnx-evil--saved) (set var old))
  (setq drgnx-evil--saved nil))

(defun drgnx-evil--cursors-on ()
  (pcase-dolist (`(,var . ,fn) drgnx-evil--cursor-vars) (drgnx-evil--save var fn)))

(defun drgnx-evil--cursors-back ()
  "Give every buffer the cursor it had before evil."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when drgnx-evil--own-cursor
        (setq cursor-type (car drgnx-evil--own-cursor))
        (kill-local-variable 'drgnx-evil--own-cursor)))))

;;;; Terminal cursor

(defvar drgnx-evil--active nil "Non-nil while the engine runs (the after-load forms check it).")

(defun drgnx-evil--xterm ()
  "Let Emacs 31.1 draw the cursor shape in an Xterm-compatible terminal (30.2 has no such option: there the
cursor stays the terminal's own).  Only the variable is set here: terminals starting later read it."
  (when (and drgnx-evil--active (boundp 'xterm-update-cursor))
    (drgnx-evil--save 'xterm-update-cursor t)))

;;;; State into the core

(defun drgnx-evil--state ()
  "The core's name for evil's state: visual is `visual', `visual-line' or `visual-block' by its selection."
  (pcase evil-state
    ('visual (pcase evil-visual-selection
               ((or 'line 'screen-line) 'visual-line)
               ('block 'visual-block)
               (_ 'visual)))
    (state state)))

(defun drgnx-evil--sync ()
  "Tell the core this buffer's state (nil where evil is not on, like the minibuffer)."
  (drgnx-modal-set-state (and (bound-and-true-p evil-local-mode) (drgnx-evil--state))))

(defconst drgnx-evil--selection-functions '(evil-visual-make-selection evil-visual-make-region)
  "What every visual selection goes through (v, V, C-v, gv, a text object): the type can change inside visual
state, where no state entry runs.")

(defun drgnx-evil--after-selection (&rest _)
  "Advice after evil makes a visual selection: the type (char, line, block) is set after the state is entered."
  (when (bound-and-true-p evil-local-mode) (drgnx-evil--sync)))

(defconst drgnx-evil--entry-hooks
  '(evil-normal-state-entry-hook evil-insert-state-entry-hook evil-visual-state-entry-hook
                                 evil-replace-state-entry-hook evil-operator-state-entry-hook evil-motion-state-entry-hook
                                 evil-emacs-state-entry-hook)
  "evil's hooks run when a state is entered.")

;;;; Initial states

(defconst drgnx-evil--features
  '((drgnx-agents-list-mode . drgnx-agents-ui) (drgnx-agents-transcript-mode . drgnx-agents-ui)
    (drgnx-work-mode . drgnx-work-ui) (drgnx-modules-list-mode . drgnx-modules)
    (drgnx-replace-bar-mode . drgnx-replace))
  "Modes whose library is not the mode's name without \"-mode\".")

(defvar drgnx-evil--waiting nil "Modes whose initial state is set again when their library loads.")

(defun drgnx-evil--initial (mode state)
  "Make STATE the initial state of MODE, and again once MODE's library loads (so a later setting of another
package does not win)."
  (evil-set-initial-state mode state)
  (let ((feature (or (alist-get mode drgnx-evil--features)
                     (intern (string-remove-suffix "-mode" (symbol-name mode))))))
    (unless (or (featurep feature) (memq mode drgnx-evil--waiting))
      (push mode drgnx-evil--waiting)
      (eval-after-load feature
        (lambda ()
          (setq drgnx-evil--waiting (delq mode drgnx-evil--waiting))
          (when (and drgnx-evil--active (fboundp 'evil-set-initial-state))
            (evil-set-initial-state mode state)))))))

(defun drgnx-evil--initial-states ()
  "Panels and forms start in emacs state (they keep their own keys), inputs in insert state."
  (dolist (m (append drgnx-modal-panel-modes drgnx-modal-form-modes)) (drgnx-evil--initial m 'emacs))
  (dolist (m drgnx-modal-input-modes) (drgnx-evil--initial m 'insert)))

(defun drgnx-evil--insert ()
  "Enter insert state (the commit message buffer, where you type at once)."
  (when (bound-and-true-p evil-local-mode) (evil-insert-state)))

;;;; Start and stop

(defvar drgnx-evil--which-key nil
  "What which-key was before the engine started: (MODE-ON . SHOW-TRANSIENT-MAPS), nil when untouched.")

(defun drgnx-evil--which-key-on ()
  "The leader's keys show in a popup: the built-in which-key, with the transient maps (Leader Menu)."
  (unless drgnx-evil--which-key
    (require 'which-key)
    (setq drgnx-evil--which-key (cons (bound-and-true-p which-key-mode) which-key-show-transient-maps)))
  (setq which-key-show-transient-maps t)
  (which-key-mode 1))

(defun drgnx-evil--which-key-back ()
  (when drgnx-evil--which-key
    (setq which-key-show-transient-maps (cdr drgnx-evil--which-key))
    (unless (car drgnx-evil--which-key) (which-key-mode -1))
    (setq drgnx-evil--which-key nil)))

(defun drgnx-evil--init-buffer ()
  "Follow evil's state in this buffer (its initial state came from the core's lists of panels, forms and
inputs, `drgnx-evil--initial-states'): on `after-change-major-mode-hook', after evil re-initialised it."
  (drgnx-evil--sync))

(defun drgnx-evil-start ()
  "Turn Vim editing on: evil's mode, the initial states, the hooks into the core, cursor shapes, the indicator,
which-key and the terminal cursor; then every live buffer gets its state."
  (setq drgnx-evil--active t)
  (drgnx-evil--cursors-on)
  (drgnx-evil--initial-states)
  (dolist (hook drgnx-evil--entry-hooks) (add-hook hook #'drgnx-evil--sync))
  (add-hook 'git-commit-setup-hook #'drgnx-evil--insert)
  (add-hook 'evil-local-mode-hook #'drgnx-modal-order-alists)
  (add-hook 'after-change-major-mode-hook #'drgnx-evil--init-buffer 90)
  (dolist (fn drgnx-evil--selection-functions) (advice-add fn :after #'drgnx-evil--after-selection))
  (evil-mode 1)
  (drgnx-modal-indicator-on)
  (drgnx-modal-order-alists)
  (drgnx-evil--which-key-on)
  (eval-after-load 'term/xterm #'drgnx-evil--xterm)
  (dolist (buf (buffer-list))
    (with-current-buffer buf (drgnx-evil--init-buffer))))

(defun drgnx-evil-stop ()
  "Turn Vim editing off: evil's mode, the hooks, every buffer's state, the cursors, the indicator, which-key."
  (setq drgnx-evil--active nil)
  (when (fboundp 'evil-mode) (evil-mode -1))
  (dolist (hook drgnx-evil--entry-hooks) (remove-hook hook #'drgnx-evil--sync))
  (remove-hook 'git-commit-setup-hook #'drgnx-evil--insert)
  (remove-hook 'evil-local-mode-hook #'drgnx-modal-order-alists)
  (remove-hook 'after-change-major-mode-hook #'drgnx-evil--init-buffer)
  (dolist (fn drgnx-evil--selection-functions) (advice-remove fn #'drgnx-evil--after-selection))
  (dolist (buf (buffer-list))
    (with-current-buffer buf (drgnx-modal-set-state nil)))
  (drgnx-evil--cursors-back)
  (drgnx-evil--restore)
  (drgnx-modal-indicator-off)
  (drgnx-evil--which-key-back))

;;;; Command

(defun drgnx-evil-toggle ()
  "Turn Vim editing off, or back on, for this session.  The key stack is not changed (a later switch of stack
or a restart follows it again)."
  (interactive)
  (cond ((eq drgnx-modal-running 'evil)
         ;; layers whose profile has no modal engine: the core stops evil and clears every buffer
         (drgnx-modal-sync-engine '((emacs)))
         (message "Modal editing is off for this session; the key stack is unchanged"))
        ((drgnx-modal-sync-engine) (message "Modal editing is on"))
        (t (message "The key stack has no Vim keys: choose Vim keys (Keyboard Profile…)"))))

(defun drgnx-evil-doctor ()
  "Problem strings: the key stack wants evil and evil is not running."
  (let ((want (ignore-errors (drgnx-modal-engine-for (drgnx-modal-current-layers)))))
    (when (and (eq want 'evil) (not (eq drgnx-modal-running 'evil)))
      (list "the key stack needs Vim editing (evil) but evil is not running: turn on Modal Editing, or see `drgnx doctor'"))))

;;;; Module

(defun drgnx-evil-setup ()
  "Set evil's defaults, load it, register the engine, and start it when the key layers need it."
  (drgnx-evil--settings)
  (require 'evil)
  (drgnx-modal-define-engine 'evil :module 'editor/evil :start #'drgnx-evil-start :stop #'drgnx-evil-stop)
  (drgnx-command-define 'modal-toggle :category "Edit" :title "Toggle Modal Editing"
                        :command #'drgnx-evil-toggle :scope 'app
                        :when (lambda () (and (assq 'evil drgnx-modal-engines) t))
                        :doc "Vim editing off or on for this session; the key stack stays as it is")
  (drgnx-modal-sync-engine)
  (when drgnx-keys-last (drgnx-keys-apply)))

(drgnx-module-define 'editor/evil
                     :doc "Vim editing (evil); on when you choose a Vim key stack"
                     :stage 'startup
                     :default 'off
                     :packages '(evil evil-collection)
                     :flags '(no-collection)
                     :setup #'drgnx-evil-setup
                     :doctor #'drgnx-evil-doctor)

(provide 'drgnx-evil)
;;; drgnx-evil.el ends here
