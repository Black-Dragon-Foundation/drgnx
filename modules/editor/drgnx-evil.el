;;; drgnx-evil.el --- Module editor/evil: evil as drgnx's Vim engine -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Vim editing engine, plugged into the engine-neutral modal core (core/drgnx-modal.el).  Off until the
;; user picks a Vim key stack (it is `:default off'): nothing installs or loads before that.  It sets evil's
;; defaults, registers the engine `evil' and lets `drgnx-modal-sync-engine' start it when the key layers need
;; it.  While it runs: panels and forms are in emacs state and inputs (shells, commit messages) in insert
;; state; every state change goes to `drgnx-modal-set-state' (leader and panel maps, the mode-line indicator);
;; the cursor has a shape per state, and in a panel stays what the panel set (none, mostly); in a terminal
;; Emacs follows the shape (`xterm-update-cursor'); the built-in which-key shows the leader's keys; AI ghost
;; text is asked for only in insert state, and the visual selection is what Edit with AI rewrites.
;; Toggle Modal Editing turns the engine off and on for this session.  See docs/guide/keys.md ("Vim keys").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-keys)
(require 'drgnx-modal)
(require 'drgnx-surfaces)

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
(defvar evil-disable-insert-state-bindings)
(defvar evil-collection-want-unimpaired-p)
(defvar global-evil-collection-unimpaired-mode)
(defvar multiple-cursors-mode-enabled-hook)
(defvar multiple-cursors-mode-disabled-hook)
(declare-function evil-mode "evil-core")
(declare-function evil-change-state "evil-core")
(declare-function evil-update-insert-state-bindings "evil-maps")
(declare-function evil-emacs-state "evil-states")
(declare-function evil-collection-init "evil-collection")
(declare-function global-evil-collection-unimpaired-mode "evil-collection-unimpaired")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-insert-state "evil-states")
(declare-function which-key-mode "which-key")
(declare-function xterm--init-update-cursor "term/xterm")
(declare-function xterm--update-cursor-type "term/xterm")

;;;; Settings

(defun drgnx-evil--settings ()
  "Set evil's defaults after it loaded, through their custom setters (as `setopt' does) so evil's own setters run
\(C-u binding, undo functions, search keys): Emacs' `undo-redo', C-u scrolls, evil's own search, no evil in the
minibuffer, no evil mode-line tag (drgnx's indicator replaces it).  Users override these in config.el with
`setopt', which runs later.  The module turned off gives each its old value back (`drgnx-module-set'), one the user
set since stays.  `evil-want-keybinding' (nil: evil-collection brings the keys) is read when evil loads, so it is
set before."
  (drgnx-module-set 'evil-undo-system 'undo-redo)
  (drgnx-module-set 'evil-want-C-u-scroll t)
  (drgnx-module-set 'evil-search-module 'evil-search)
  (drgnx-module-set 'evil-want-minibuffer nil)
  (drgnx-module-set 'evil-mode-line-format nil))

;;;; evil-collection

(defvar drgnx-evil--active nil "Non-nil while the engine runs (the after-load forms check it).")

(defvar drgnx-evil-collection-modes '(magit with-editor dired xref compile help info vundo eglot ediff)
  "The third-party and built-in modes that get evil-collection's Vim keys.  Each loads its keys when the mode's
library loads, not before.  drgnx's own modes (panels, forms, inputs) are never in it: they keep their own keys.
The flag `no-collection' of editor/evil (modules.eld :flags) leaves them all out.")

(defvar drgnx-evil--collection-done nil "The modes of `drgnx-evil-collection-modes' evil-collection was told about.")

(defun drgnx-evil--collection ()
  "Register evil-collection's keys for the modes of `drgnx-evil-collection-modes' not registered yet, unless the
flag `no-collection' is on.  Only the registration happens now: each mode's keys load with the mode's library."
  (unless (drgnx-module-flag-p 'editor/evil 'no-collection)
    (let ((todo (seq-remove (lambda (m) (memq m drgnx-evil--collection-done)) drgnx-evil-collection-modes)))
      (when todo
        (if (require 'evil-collection nil t)
            (progn (evil-collection-init todo)
                   (setq drgnx-evil--collection-done (append todo drgnx-evil--collection-done)))
          (message "drgnx: evil-collection is not installed: third-party modes keep their own keys"))))))

(defun drgnx-evil--unimpaired (on)
  "evil-collection's unimpaired keys (`[b' `]b' `[e' `]e' `[q' `]q' `[ SPC' …) are a global minor mode its init turns
on.  They belong to Vim editing: off with the engine (SPC and the brackets are Emacs' own again), back on when it
restarts, unless `evil-collection-want-unimpaired-p' is nil."
  (when (fboundp 'global-evil-collection-unimpaired-mode)
    (cond ((and on (bound-and-true-p evil-collection-want-unimpaired-p)
                (not (bound-and-true-p global-evil-collection-unimpaired-mode)))
           (global-evil-collection-unimpaired-mode 1))
          ((and (not on) (bound-and-true-p global-evil-collection-unimpaired-mode))
           (global-evil-collection-unimpaired-mode -1)))))

;;;; Insert-state keys

(defun drgnx-evil--insert-bindings (on)
  "ON: evil's `evil-insert-state-bindings' are in `evil-insert-state-map', as evil made them (a key bound to
something else by now is left alone).  Nil: they are taken out, so the other editor's keys (C-w, C-r, C-v …) are
the Emacs ones in insert state; only a binding still evil's own goes, a key you rebound stays.  Evil's function does
both, and does nothing when you set `evil-disable-insert-state-bindings'."
  (unless evil-disable-insert-state-bindings
    (if on (evil-update-insert-state-bindings) (evil-update-insert-state-bindings nil t))))

(defun drgnx-evil--insert-for-layers (layers)
  "`drgnx-modal-sync-functions': Vim's insert-state keys only in the pure Vim stack."
  (when drgnx-evil--active
    (drgnx-evil--insert-bindings (not (drgnx-modal-mixed-p layers)))))

;;;; Multiple cursors

(defvar-local drgnx-evil--mc-state nil
  "The evil state a buffer was in when multiple cursors started, as (STATE).")

(defun drgnx-evil--mc-enter ()
  "Multiple cursors run in emacs state: Vim's keys would act on the cursors one by one."
  (when (and drgnx-evil--active (bound-and-true-p evil-local-mode) (not drgnx-evil--mc-state))
    (setq drgnx-evil--mc-state (list evil-state))
    (evil-emacs-state)))

(defun drgnx-evil--mc-leave ()
  "Back to the state before multiple cursors (normal when it was a visual or operator one).  The hook also runs
when the mode is not on: then nothing was noted and nothing changes."
  (when drgnx-evil--mc-state
    (let ((state (car drgnx-evil--mc-state)))
      (setq drgnx-evil--mc-state nil)
      (when (bound-and-true-p evil-local-mode)
        (evil-change-state (if (memq state '(insert replace emacs motion)) state 'normal))))))

(defun drgnx-evil--mc-hooks (on)
  (dolist (cell '((multiple-cursors-mode-enabled-hook . drgnx-evil--mc-enter)
                  (multiple-cursors-mode-disabled-hook . drgnx-evil--mc-leave)))
    (if on (add-hook (car cell) (cdr cell)) (remove-hook (car cell) (cdr cell)))))

(defun drgnx-evil--mc-hooks-on () (when drgnx-evil--active (drgnx-evil--mc-hooks t)))

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

(defvar drgnx-evil--cursor-defaults nil
  "Alist of evil's cursor variables → the value evil gave them, noted when it loaded (before any user setting).")

(defun drgnx-evil--note-cursor-defaults ()
  (pcase-dolist (`(,var . ,_) drgnx-evil--cursor-vars)
    (unless (assq var drgnx-evil--cursor-defaults)
      (push (cons var (symbol-value var)) drgnx-evil--cursor-defaults))))

(defun drgnx-evil--cursors-on ()
  "Put drgnx's cursor function in each of evil's cursor variables that still holds evil's own value: one the
user set (`setopt' in config.el) is theirs."
  (drgnx-evil--note-cursor-defaults)
  (pcase-dolist (`(,var . ,fn) drgnx-evil--cursor-vars)
    (when (equal (symbol-value var) (alist-get var drgnx-evil--cursor-defaults))
      (set var fn))))

(defun drgnx-evil--cursor-vars-back ()
  "Give evil's own value back to the variables drgnx set (not to one the user changed meanwhile)."
  (pcase-dolist (`(,var . ,fn) drgnx-evil--cursor-vars)
    (when (and (boundp var) (eq (symbol-value var) fn))
      (set var (alist-get var drgnx-evil--cursor-defaults)))))

(defun drgnx-evil--cursors-back ()
  "Give every buffer the cursor it had before evil."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when drgnx-evil--own-cursor
        (setq cursor-type (car drgnx-evil--own-cursor))
        (kill-local-variable 'drgnx-evil--own-cursor)))))

;;;; Terminal cursor

(defun drgnx-evil--xterm-frames ()
  "The live terminal frames whose terminal ran Emacs' xterm initialisation (it ran before the option was set,
so it did not install the cursor hook)."
  (seq-filter (lambda (f)
                (let ((init (terminal-parameter (frame-terminal f) 'terminal-initted)))
                  (and (not (display-graphic-p f)) (symbolp init) init
                       (string-match-p "\\`terminal-init-\\(xterm\\|tmux\\|screen\\|rxvt\\|alacritty\\|foot\\|kitty\\|st\\|vte\\|iterm\\)"
                                       (symbol-name init)))))
              (frame-list)))

(defun drgnx-evil--xterm ()
  "Let Emacs draw the cursor shape (`type': the shape only, no colour sequences) in Xterm-compatible
terminals.  A terminal that initialised
before the option was set is set up now, unless the cursor hook is installed already."
  (when (and drgnx-evil--active (boundp 'xterm-update-cursor))
    (drgnx-evil--save 'xterm-update-cursor 'type)
    (when (and (fboundp 'xterm--init-update-cursor) (not (memq 'xterm--post-command-hook (default-value 'post-command-hook))))
      (dolist (f (drgnx-evil--xterm-frames))
        (with-selected-frame f (ignore-errors (xterm--init-update-cursor)))))))

(defun drgnx-evil--xterm-reset ()
  "Show the default cursor shape in the terminals again (the option is still set here)."
  (when (and (boundp 'xterm-update-cursor) xterm-update-cursor (fboundp 'xterm--update-cursor-type))
    (dolist (f (drgnx-evil--xterm-frames))
      (with-selected-frame f (ignore-errors (xterm--update-cursor-type))))))

;;;; Ex commands and Vim's window keys run drgnx's commands

(defvar drgnx-evil-ex-routes
  '(("w[rite]" . drgnx-evil-ex-write) ("wa[ll]" . drgnx-evil-ex-save-all) ("e[dit]" . drgnx-evil-ex-edit))
  "Ex commands drgnx answers, as (NAME . COMMAND): NAME in evil's syntax (\"w[rite]\" is w, wr … write), COMMAND a
command that takes evil's place (it carries evil's argument properties, so `!', `%' and file completion work).
Installed with `evil-ex-define-cmd' when the engine starts and taken out when it stops.  `:q', `:wq', `:x', `:qa',
`:wqa', `:cq', `:sp', `:vs', ZZ and the `C-w' keys are not here: they reach drgnx through `drgnx-evil--advice-pairs'.")

(defconst drgnx-evil--advice-pairs
  '((evil-quit . drgnx-evil-ex-quit)
    (evil-quit-all . drgnx-evil-ex-close-window)
    (evil-quit-all-with-error-code . drgnx-evil-ex-close-window)
    (evil-save-and-quit . drgnx-evil-ex-save-all-close-window)
    (evil-save-and-close . drgnx-evil-ex-write-quit)
    (evil-save-modified-and-close . drgnx-evil-ex-write-quit)
    (evil-window-split . drgnx-evil-ex-split-down)
    (evil-window-vsplit . drgnx-evil-ex-split-right)
    (evil-window-delete . drgnx-evil-ex-close-group))
  "evil's window and quit commands and drgnx's replacement for each: `:around' advice while the engine runs.  Evil's
own would act on its windows and could quit Emacs; the workbench keeps its groups, tabs and layout.  Each replacement
calls evil's own command when the workbench is not on (`drgnx-evil-ex--workbench-p').")

(defvar drgnx-evil--ex-saved nil
  "Alist of ex names drgnx redefined, NAME → (OLD OURS): what evil had (its function or string, or `none') and what
drgnx put there.")

(defvar evil-ex-commands)
(defvar evil-ex-argument)
(defvar evil-ex-range)
(defvar evil-ex-bang)
(declare-function evil-ex-define-cmd "evil-ex")
(declare-function evil-ex-file-arg "evil-ex")
(declare-function evil-add-command-properties "evil-common")
(declare-function evil-edit "evil-commands")
(declare-function evil-write "evil-commands")
(declare-function evil-write-all "evil-commands")
(declare-function drgnx-chrome-tabs "drgnx-chrome")
(declare-function drgnx-groups-list "drgnx-groups")

(defun drgnx-evil-ex--workbench-p ()
  "Non-nil when the workbench's editor groups and tabs are there (module core/workbench is on)."
  (and (fboundp 'drgnx-groups-list) (fboundp 'drgnx-chrome-tabs) (drgnx-commands-get 'close-group) t))

(defun drgnx-evil-ex--in-dock-p ()
  "Non-nil when the selected window is not an editor group (the sidebar, the panel, a popup)."
  (not (memq (selected-window) (drgnx-groups-list))))

(defun drgnx-evil-ex--run (id &rest args)
  "Run registry command ID the way the palette does (this-command, the key tip).  With ARGS the command's
function is called with them instead of interactively (:w FILE, :e FILE), and the tip still shows."
  (let ((cmd (or (drgnx-commands-get id) (user-error "No command %s" id))))
    (if args
        (progn (apply (drgnx-cmd-command cmd) args) (drgnx-surfaces-tip cmd))
      (drgnx-surfaces-run id))))

(defun drgnx-evil-ex--file ()
  "The file argument of the ex command being run, `%' and `#' expanded as evil does; nil when there is none."
  (evil-ex-file-arg))

(defun drgnx-evil-ex--evils-p ()
  "Non-nil when the ex command has something drgnx's commands do not do and evil's own does: a bang, a range,
a shell command (`:w !cmd') or an append (`:w >> file')."
  (or evil-ex-bang evil-ex-range
      (and (stringp evil-ex-argument) (string-match-p "\\`\\s-*\\(!\\|>>\\)" evil-ex-argument))))

(defun drgnx-evil-ex-write ()
  "`:w' is Save, `:w FILE' is Save As FILE.  `:w!', a range, `:w !cmd' and `:w >> FILE' are evil's own."
  (interactive)
  (if (drgnx-evil-ex--evils-p)
      (call-interactively #'evil-write)
    (if-let* ((file (drgnx-evil-ex--file)))
        (drgnx-evil-ex--run 'file-save-as file)
      (drgnx-evil-ex--run 'save-file))))

(defun drgnx-evil-ex-edit ()
  "`:e FILE' is Open File; `:e' alone (Vim re-reads the file) and `:e!' are evil's own."
  (interactive)
  (if-let* ((file (and (not evil-ex-bang) (drgnx-evil-ex--file))))
      (drgnx-evil-ex--run 'open-file file)
    (call-interactively #'evil-edit)))

(defun drgnx-evil-ex-save-all ()
  "`:wa' is Save All (`:wa!' is evil's own, which also saves read-only buffers)."
  (interactive)
  (if (and (not evil-ex-bang) (drgnx-commands-get 'save-all))
      (drgnx-evil-ex--run 'save-all)
    (call-interactively #'evil-write-all)))

(defun drgnx-evil-ex--quit ()
  "`:q' in the workbench.  In a dock (the sidebar, the panel): back to the editor you used last, never closing a
group.  In an editor group: Close Tab when it has other tabs, else Close Editor Group when there is another group,
else Close Window (which keeps a background drgnx running, and otherwise asks before quitting)."
  (drgnx-evil-ex--run (cond ((drgnx-evil-ex--in-dock-p) 'focus-editor)
                            ((cdr (drgnx-chrome-tabs (selected-window))) 'close-tab)
                            ((cdr (drgnx-groups-list)) 'close-group)
                            (t 'file-close-window))))

(defvar with-editor-mode)
(defvar server-buffer-clients)
(declare-function with-editor-finish "with-editor")
(declare-function with-editor-cancel "with-editor")
(declare-function server-edit "server")
(declare-function server-buffer-done "server")

(defun drgnx-evil-ex--end-edit (how)
  "In a buffer another program waits for, end the edit and return non-nil; elsewhere nil.  A magit commit or rebase
message (`with-editor-mode'): HOW `finish' is `with-editor-finish' (git goes on), `cancel' or `drop' is
`with-editor-cancel'.  An emacsclient buffer (`server-buffer-clients'): `finish' saves a changed buffer, then
`server-edit'; `cancel' is `server-edit' (C-x #, which asks before saving changes); `drop' is `server-buffer-done',
unsaved."
  (cond ((bound-and-true-p with-editor-mode)
         (if (eq how 'finish) (with-editor-finish nil) (with-editor-cancel nil))
         t)
        ((bound-and-true-p server-buffer-clients)
         (pcase how
           ('finish (when (buffer-modified-p) (save-buffer)) (server-edit))
           ('cancel (server-edit))
           ('drop (server-buffer-done (current-buffer))))
         t)))

(defun drgnx-evil-ex-quit (orig &rest args)
  "Advice around `evil-quit' (`:q', `ZQ'): in a commit message or an emacsclient buffer the edit is cancelled
\(`drgnx-evil-ex--end-edit'; `:q!' drops a client's buffer), else `drgnx-evil-ex--quit'; evil's own without the
workbench."
  (cond ((drgnx-evil-ex--end-edit (if (car args) 'drop 'cancel)))
        ((drgnx-evil-ex--workbench-p) (drgnx-evil-ex--quit))
        (t (apply orig args))))

(defun drgnx-evil-ex-write-quit (orig &rest args)
  "Advice around `evil-save-and-close' and `evil-save-modified-and-close' (`:wq', `:x', ZZ): in a commit message or
an emacsclient buffer the edit is finished (`drgnx-evil-ex--end-edit'), so git or the client stops waiting; else
save when the buffer has changes, then `drgnx-evil-ex--quit'; evil's own without the workbench."
  (cond ((drgnx-evil-ex--end-edit 'finish))
        ((drgnx-evil-ex--workbench-p) (when (buffer-modified-p) (drgnx-evil-ex-write)) (drgnx-evil-ex--quit))
        (t (apply orig args))))

(defun drgnx-evil-ex-close-window (_orig &rest _)
  "Advice around `evil-quit-all' and `evil-quit-all-with-error-code' (`:qa', `:cq'): Close Window."
  (drgnx-evil-ex--run 'file-close-window))

(defun drgnx-evil-ex-save-all-close-window (_orig &rest _)
  "Advice around `evil-save-and-quit' (`:wqa', `:xa'): Save All, then Close Window."
  (drgnx-evil-ex-save-all)
  (drgnx-evil-ex--run 'file-close-window))

(defun drgnx-evil-ex--split (id args)
  "Run split command ID; ARGS are evil's (COUNT FILE READ-ONLY): a FILE opens in the new group."
  (drgnx-evil-ex--run id)
  (when-let* ((file (nth 1 args))) (drgnx-evil-ex--run 'open-file file)))

(defun drgnx-evil-ex-split-down (orig &rest args)
  "Advice around `evil-window-split' (`:sp', `C-w s'): Split Editor Down."
  (if (drgnx-evil-ex--workbench-p) (drgnx-evil-ex--split 'split-editor-down args) (apply orig args)))

(defun drgnx-evil-ex-split-right (orig &rest args)
  "Advice around `evil-window-vsplit' (`:vs', `C-w v'): Split Editor Right."
  (if (drgnx-evil-ex--workbench-p) (drgnx-evil-ex--split 'split-editor-right args) (apply orig args)))

(defun drgnx-evil-ex-close-group (orig &rest args)
  "Advice around `evil-window-delete' (`C-w c', `:clo'): Close Editor Group.  In a dock it goes back to the editor
instead; an editor group is never closed from there."
  (cond ((not (drgnx-evil-ex--workbench-p)) (apply orig args))
        ((drgnx-evil-ex--in-dock-p) (drgnx-evil-ex--run 'focus-editor))
        (t (drgnx-evil-ex--run 'close-group))))

(defun drgnx-evil--ex-names (spec)
  "The names `evil-ex-define-cmd' defines for SPEC: \"w[rite]\" is w, wr, wri, writ, write."
  (if (string-match "\\`\\(.*\\)\\[\\(.*\\)\\]\\'" spec)
      (let ((mandatory (match-string 1 spec)) (optional (match-string 2 spec)))
        (cl-loop for n from 0 to (length optional) collect (concat mandatory (substring optional 0 n))))
    (list spec)))

(defun drgnx-evil--ex-routes (on)
  "ON: define the ex commands of `drgnx-evil-ex-routes', noting what evil had, and give them evil's argument
properties (bang, file and shell completion).  Nil: give evil's definitions back, except for a name that holds
something else by now (the user's own `evil-ex-define-cmd')."
  (if on
      (progn
        (evil-add-command-properties 'drgnx-evil-ex-write :ex-arg 'file-or-shell :ex-bang t)
        (evil-add-command-properties 'drgnx-evil-ex-edit :ex-arg 'file :ex-bang t)
        (evil-add-command-properties 'drgnx-evil-ex-save-all :ex-bang t)
        (pcase-dolist (`(,spec . ,fn) drgnx-evil-ex-routes)
          (dolist (name (drgnx-evil--ex-names spec))
            (unless (assoc name drgnx-evil--ex-saved)
              (push (list name (if-let* ((old (assoc name evil-ex-commands))) (cdr old) 'none) fn) drgnx-evil--ex-saved))
            (evil-ex-define-cmd name fn))))
    (pcase-dolist (`(,name ,old ,ours) drgnx-evil--ex-saved)
      (when (eq (cdr (assoc name evil-ex-commands)) ours)
        (if (eq old 'none)
            (setq evil-ex-commands (assoc-delete-all name evil-ex-commands))
          (evil-ex-define-cmd name old))))
    (setq drgnx-evil--ex-saved nil)))

(defun drgnx-evil--advice (on)
  "ON: evil's window and quit commands are `drgnx-evil--advice-pairs'.  Nil: evil's own again."
  (pcase-dolist (`(,evil . ,ours) drgnx-evil--advice-pairs)
    (if on (advice-add evil :around ours) (advice-remove evil ours))))

;;;; AI ghost text and the selection

(defvar drgnx-ai-ghost-inhibit-functions)
(declare-function evil-visual-state-p "evil-states")
(declare-function evil-visual-range "evil-states")

(defun drgnx-evil--ghost-inhibit ()
  "`drgnx-ai-ghost-inhibit-functions': no suggestion is asked for in a buffer evil drives unless it types (insert
state, or emacs state where Emacs' keys type).  Called once per pause; reads only the buffer's state."
  (and (bound-and-true-p evil-local-mode) (not (memq evil-state '(insert emacs)))))

(defun drgnx-evil--selection ()
  "`drgnx-modal-selection-function': in visual state, the selection as evil's operators take it, (BEG . END):
whole lines with the last newline in visual line, the characters under both ends in visual.  A block (C-v) is a
rectangle, which one region cannot be: it gives the whole lines it touches, as visual line does.  Nil outside visual
state and for an empty selection (`v' in an empty buffer), so the caller falls back."
  (when (and (bound-and-true-p evil-local-mode) (evil-visual-state-p))
    (pcase-let ((`(,beg ,end ,type) (evil-visual-range)))
      (when (eq type 'block)
        (save-excursion
          (setq beg (progn (goto-char beg) (line-beginning-position))
                end (progn (goto-char end) (line-beginning-position 2)))))
      (and (< beg end) (cons beg end)))))

(defun drgnx-evil--ai (on)
  "ON: ghost text asks only while typing, and \"the selection\" (Edit with AI) is the visual one.  Nil: as before."
  (if on
      (progn (add-hook 'drgnx-ai-ghost-inhibit-functions #'drgnx-evil--ghost-inhibit)
             (drgnx-evil--save 'drgnx-modal-selection-function #'drgnx-evil--selection))
    (remove-hook 'drgnx-ai-ghost-inhibit-functions #'drgnx-evil--ghost-inhibit)))

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

(defconst drgnx-evil--mode-lists
  '((drgnx-modal-panel-modes . emacs) (drgnx-modal-form-modes . emacs) (drgnx-modal-input-modes . insert))
  "The core's lists of modes and the evil state each starts in: panels and forms keep their own keys (emacs
state), inputs take typing (insert state).")

(defun drgnx-evil--initial-states ()
  "Set the initial state of every mode in the core's lists."
  (pcase-dolist (`(,var . ,state) drgnx-evil--mode-lists)
    (dolist (m (symbol-value var)) (drgnx-evil--initial m state))))

(defun drgnx-evil--watch (symbol newval operation _where)
  "Variable watcher of the core's mode lists: a mode added later (a module that loads after the engine
started) gets its initial state too."
  (when (and drgnx-evil--active (eq operation 'set) (fboundp 'evil-set-initial-state))
    (let ((state (alist-get symbol drgnx-evil--mode-lists)))
      (dolist (m newval) (drgnx-evil--initial m state)))))

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
which-key and the terminal cursor; then every live buffer gets its state.  If a step fails everything done so
far is undone and the error is signalled again."
  (condition-case err
      (drgnx-evil--start)
    (error (ignore-errors (drgnx-evil-stop))
           (signal (car err) (cdr err)))))

(defun drgnx-evil--start ()
  (setq drgnx-evil--active t)
  (drgnx-evil--cursors-on)
  (drgnx-evil--initial-states)
  (drgnx-evil--collection)
  (drgnx-evil--unimpaired t)
  (drgnx-evil--ex-routes t)
  (drgnx-evil--advice t)
  (drgnx-evil--ai t)
  (drgnx-evil--insert-bindings (not (drgnx-modal-mixed-p (drgnx-modal-current-layers))))
  (add-hook 'drgnx-modal-sync-functions #'drgnx-evil--insert-for-layers)
  (eval-after-load 'multiple-cursors-core #'drgnx-evil--mc-hooks-on)
  (dolist (cell drgnx-evil--mode-lists) (add-variable-watcher (car cell) #'drgnx-evil--watch))
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
  (remove-hook 'drgnx-modal-sync-functions #'drgnx-evil--insert-for-layers)
  (when (fboundp 'evil-update-insert-state-bindings) (drgnx-evil--insert-bindings t))
  (drgnx-evil--mc-hooks nil)
  (drgnx-evil--unimpaired nil)
  (drgnx-evil--advice nil)
  (drgnx-evil--ai nil)                  ; the selection function goes back with the other variables (restore)
  (when (boundp 'evil-ex-commands) (drgnx-evil--ex-routes nil))
  (dolist (cell drgnx-evil--mode-lists) (remove-variable-watcher (car cell) #'drgnx-evil--watch))
  (dolist (hook drgnx-evil--entry-hooks) (remove-hook hook #'drgnx-evil--sync))
  (remove-hook 'git-commit-setup-hook #'drgnx-evil--insert)
  (remove-hook 'evil-local-mode-hook #'drgnx-modal-order-alists)
  (remove-hook 'after-change-major-mode-hook #'drgnx-evil--init-buffer)
  (dolist (fn drgnx-evil--selection-functions) (advice-remove fn #'drgnx-evil--after-selection))
  (dolist (buf (buffer-list))
    (with-current-buffer buf (drgnx-modal-set-state nil)))
  (drgnx-evil--cursors-back)
  (drgnx-evil--cursor-vars-back)
  (drgnx-evil--xterm-reset)
  (drgnx-evil--restore)
  (drgnx-modal-indicator-off)
  (drgnx-evil--which-key-back))

;;;; Command

(defun drgnx-evil-toggle ()
  "Turn Vim editing off, or back on, for this session.  The key stack is not changed.  Off holds through every
later application of the keys (`drgnx-modal-suspended'); another stack ends it."
  (interactive)
  (if (eq drgnx-modal-running 'evil)
      (progn (setq drgnx-modal-suspended (list (drgnx-modal-current-layers)))
             (drgnx-modal-sync-engine)                  ; the core stops evil and clears every buffer
             (message "Modal editing is off for this session (the key stack is unchanged); M-SPC u m turns it on"))
    (setq drgnx-modal-suspended nil)
    (cond ((drgnx-modal-sync-engine) (message "Modal editing is on"))
          ((drgnx-modal-engine-for (drgnx-modal-current-layers))
           (message "Modal editing did not start: see the *Messages* buffer"))
          (t (message "The key stack has no Vim keys: choose Vim keys (Keyboard Profile…)")))))

(defun drgnx-evil-doctor ()
  "Problem strings: the key stack wants evil and evil is not running."
  (let ((want (ignore-errors (drgnx-modal-engine-for (drgnx-modal-current-layers)))))
    (when (and (eq want 'evil) (not (eq drgnx-modal-running 'evil)) (not drgnx-modal-suspended))
      (list "the key stack needs Vim editing (evil) but evil is not running: turn on Modal Editing, or see `drgnx doctor'"))))

;;;; Module

(defun drgnx-evil-setup ()
  "Set evil's defaults, load it, register the engine, and start it when the key layers need it."
  (setq evil-want-keybinding nil
        evil-want-C-u-scroll t)    ; also before: evil binds C-u as it loads, so the snapshot of its maps has it
  (require 'evil)
  (drgnx-evil--note-cursor-defaults)
  (drgnx-evil--settings)
  (drgnx-modal-define-engine 'evil :module 'editor/evil :start #'drgnx-evil-start :stop #'drgnx-evil-stop)
  (drgnx-command-define 'modal-toggle :category "Edit" :title "Toggle Modal Editing"
                        :command #'drgnx-evil-toggle :scope 'app
                        :when (lambda () (and (assq 'evil drgnx-modal-engines) t))
                        :doc "Vim editing off or on for this session; the key stack stays as it is")
  (drgnx-modal-sync-engine)
  (when drgnx-keys-last (drgnx-keys-apply)))

(defun drgnx-evil--teardown ()
  "The module's teardown: Vim editing stops now, as the core stops an engine (`drgnx-evil-stop', then every
buffer's state cleared), and the engine is no longer registered.  The engine may have started after the setup (a
key stack chosen later), so what its start did is no setup's record: the stop undoes it.  Evil itself stays
loaded (it cannot be unloaded); its options go back with the module's record, except the two flags the setup sets
before `require' (`evil-want-keybinding' nil, `evil-want-C-u-scroll' t): evil reads them as it loads, and they
stay as evil does (with `evil-mode' off they change nothing)."
  (drgnx-modal-undefine-engine 'evil))

(drgnx-module-define 'editor/evil
                     :doc "Vim editing (evil); on when you choose a Vim key stack"
                     :stage 'startup
                     :default 'off
                     :packages '(evil evil-collection)
                     :flags '(no-collection)
                     :setup #'drgnx-evil-setup
                     :teardown #'drgnx-evil--teardown
                     :doctor #'drgnx-evil-doctor)

(provide 'drgnx-evil)
;;; drgnx-evil.el ends here
