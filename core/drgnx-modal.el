;;; drgnx-modal.el --- Engine-neutral modal core: leader and panel maps, state, indicator -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What drgnx's modal editing needs whichever engine (evil today, meow later) provides the modes: the
;; leader map (`SPC …', `C-w …') and the panel map (panel-only keys), a state switch that turns them on
;; and off per buffer, the lists of panel, form and input modes, the state indicator for the mode line,
;; the selection helper, and the engine registry.  An engine calls `drgnx-modal-set-state' whenever its
;; state changes and `drgnx-modal-order-alists' after it has put its own keymaps in
;; `emulation-mode-map-alists'.  Nothing here needs evil.  See docs/develop/core.md ("Modal core").

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-registry)
(require 'drgnx-keys)

;;;; Maps and the state switch

(defvar drgnx-modal-leader-map (make-sparse-keymap)
  "Leader keys (`SPC …', `C-w …'), active in the engine's normal-like states and in panels.
Filled from the key profiles (keys/vim.eld, `:modal').")

(defvar drgnx-modal-panel-map (make-sparse-keymap)
  "Keys that exist only in panels (lists, tables, transcripts), active in their emacs state.")

(defvar-local drgnx-modal-state nil
  "The modal state of this buffer: normal insert visual visual-line visual-block replace motion
operator emacs; nil when no modal engine runs here.")

(defvar-local drgnx-modal--leader-on nil "Non-nil while `drgnx-modal-leader-map' is active in this buffer.")
(defvar-local drgnx-modal--panel-on nil "Non-nil while `drgnx-modal-panel-map' is active in this buffer.")

(defvar drgnx-modal--leader-alist `((drgnx-modal--leader-on . ,drgnx-modal-leader-map))
  "Emulation entry for the leader map.")
(defvar drgnx-modal--panel-alist `((drgnx-modal--panel-on . ,drgnx-modal-panel-map))
  "Emulation entry for the panel map.")

(defvar drgnx-modal-panel-modes
  '(drgnx-explorer-mode drgnx-buffers-mode drgnx-outline-mode drgnx-work-mode drgnx-agents-list-mode
                        drgnx-agents-transcript-mode drgnx-job-ui-mode drgnx-diff-mode drgnx-review-mode
                        drgnx-prs-mode drgnx-onboard-mode drgnx-modules-list-mode drgnx-shortcuts-mode
                        drgnx-live-mode)
  "Major modes of panels: read-only views that keep drgnx's own keys and get the leader and panel maps.")

(defvar drgnx-modal-form-modes '(drgnx-replace-mode drgnx-replace-bar-mode)
  "Major modes of forms: fields you type in, so no modal keys.")

(defvar drgnx-modal-input-modes '(eshell-mode comint-mode term-mode eat-mode log-edit-mode)
  "Major modes that take typed input (shells, message buffers): an engine starts them in insert or emacs state.")

(defun drgnx-modal-panel-p (&optional buffer)
  "Non-nil if BUFFER (default the current one) is in one of `drgnx-modal-panel-modes'."
  (with-current-buffer (or buffer (current-buffer)) (and (derived-mode-p drgnx-modal-panel-modes) t)))

(defun drgnx-modal-form-p (&optional buffer)
  "Non-nil if BUFFER (default the current one) is in one of `drgnx-modal-form-modes'."
  (with-current-buffer (or buffer (current-buffer)) (and (derived-mode-p drgnx-modal-form-modes) t)))

(defun drgnx-modal-input-p (&optional buffer)
  "Non-nil if BUFFER (default the current one) is in one of `drgnx-modal-input-modes'."
  (with-current-buffer (or buffer (current-buffer)) (and (derived-mode-p drgnx-modal-input-modes) t)))

(defconst drgnx-modal--leader-states '(normal motion visual visual-line visual-block)
  "States in which the leader map is active in an ordinary buffer.")

(defun drgnx-modal-set-state (state)
  "Make STATE the modal state of this buffer and switch the leader and panel maps to match.
The leader map is on in the normal-like and visual states, and in a panel's emacs state; the panel map
only in a panel's emacs state.  Returns STATE."
  (let ((panel (and (eq state 'emacs) (drgnx-modal-panel-p))))
    (setq drgnx-modal-state state
          drgnx-modal--leader-on (and (or panel (memq state drgnx-modal--leader-states)) t)
          drgnx-modal--panel-on panel)
    (force-mode-line-update)
    state))

(defun drgnx-modal-initial-state ()
  "The state this buffer starts in: emacs in a form or a panel (no modal keys), insert in an input buffer,
else normal.  Engines share it so they agree."
  (cond ((drgnx-modal-form-p) 'emacs)
        ((drgnx-modal-input-p) 'insert)
        ((drgnx-modal-panel-p) 'emacs)
        (t 'normal)))

(defun drgnx-modal-init-buffer ()
  "Put this buffer in its `drgnx-modal-initial-state'.  The switches are buffer-local and are dropped with
the major mode, so an engine calls this for each buffer when it starts and after every major-mode change
\(`after-change-major-mode-hook').  Returns the state."
  (drgnx-modal-set-state (drgnx-modal-initial-state)))

(defun drgnx-modal-where (mapsym)
  "How a key bound in MAPSYM is described next to its command: \"\" for the leader map (the keys are
shown plain), \"panels\" for the panel map, \"normal state\" and so on for the engine's state maps, nil for
any other keymap.  MAPSYM is a keymap symbol or (FEATURE . KEYMAP-SYMBOL)."
  (pcase (if (consp mapsym) (cdr mapsym) mapsym)
    ('drgnx-modal-leader-map "")
    ('drgnx-modal-panel-map "panels")
    ('evil-normal-state-map "normal state")
    ('evil-visual-state-map "visual state")
    ('evil-motion-state-map "motion state")
    ('evil-insert-state-map "insert state")))

;;;; Order of the emulation maps

(defun drgnx-modal-order-alists ()
  "Put drgnx's emulation keymaps in front of the engine's in `emulation-mode-map-alists'.
The order: `drgnx-keys--everywhere-alist' (keys that work in every state beat the engine's), the leader
alist, the panel alist, `drgnx-ai-ghost--emulation', then the rest as it was.  All four always have their
place, bound or not: Emacs skips an unbound symbol in the list, and a later `add-to-list' of the ghost's
finds it already there.  Safe to call again; `drgnx-modal-sync-engine' calls it after an engine starts."
  (let ((front '(drgnx-keys--everywhere-alist drgnx-modal--leader-alist drgnx-modal--panel-alist
                                              drgnx-ai-ghost--emulation)))
    (setq emulation-mode-map-alists
          (append front (seq-remove (lambda (e) (memq e front)) emulation-mode-map-alists)))))

;;;; The state indicator

(defface drgnx-modal-normal '((t :inherit mode-line-emphasis))
  "Mode-line state indicator in normal and motion state."
  :group 'drgnx)
(defface drgnx-modal-insert '((t :inherit success))
  "Mode-line state indicator in insert state."
  :group 'drgnx)
(defface drgnx-modal-visual '((t :inherit warning))
  "Mode-line state indicator in the visual states and replace state."
  :group 'drgnx)
(defface drgnx-modal-emacs '((t :inherit shadow))
  "Mode-line state indicator in emacs state."
  :group 'drgnx)

(defun drgnx-modal-mode-line ()
  "The state indicator as a string with the state's face (\"\" when no modal engine runs in this buffer).
Self-contained: place `(:eval (drgnx-modal-mode-line))' anywhere in a mode-line layout."
  (pcase-let ((`(,text . ,face)
               (pcase drgnx-modal-state
                 ((or 'normal 'operator) '(" NORMAL " . drgnx-modal-normal))
                 ('motion '(" MOTION " . drgnx-modal-normal))
                 ('insert '(" INSERT " . drgnx-modal-insert))
                 ('visual '(" VISUAL " . drgnx-modal-visual))
                 ('visual-line '(" V-LINE " . drgnx-modal-visual))
                 ('visual-block '(" V-BLOCK " . drgnx-modal-visual))
                 ('replace '(" REPLACE " . drgnx-modal-visual))
                 ('emacs '(" EMACS " . drgnx-modal-emacs)))))
    (if text (propertize text 'face face) "")))

(defconst drgnx-modal--indicator '(:eval (drgnx-modal-mode-line)) "The mode-line construct of the indicator.")

(defun drgnx-modal-indicator-on ()
  "Show the state indicator at the front of the default `mode-line-format' (once)."
  (unless (or (not (listp (default-value 'mode-line-format)))
              (member drgnx-modal--indicator (default-value 'mode-line-format)))
    (setq-default mode-line-format (cons drgnx-modal--indicator (default-value 'mode-line-format)))))

(defun drgnx-modal-indicator-off ()
  "Take the state indicator out of the default `mode-line-format'."
  (when (and (listp (default-value 'mode-line-format))
             (member drgnx-modal--indicator (default-value 'mode-line-format)))
    (setq-default mode-line-format (remove drgnx-modal--indicator (default-value 'mode-line-format)))))

;;;; The selection

(defvar drgnx-modal-selection-function nil
  "An engine's function returning the selection as (BEG . END), or nil when there is none.")

(defun drgnx-modal-selection ()
  "The selection as (BEG . END): the engine's, else the active region, else nil."
  (or (and drgnx-modal-selection-function (funcall drgnx-modal-selection-function))
      (and (use-region-p) (cons (region-beginning) (region-end)))))

;;;; Engines

(defvar drgnx-modal-engines nil
  "Alist ENGINE → plist (:module :start :stop), the modal engines that are installed.")

(defvar drgnx-modal-running nil "The engine running now, or nil.")

(cl-defun drgnx-modal-define-engine (name &key module start stop)
  "Register modal engine NAME.  MODULE names the drgnx module that provides it; START and STOP are
functions of no arguments that turn the engine on and off.  Returns NAME."
  (setf (alist-get name drgnx-modal-engines) (list :module module :start start :stop stop))
  name)

(defun drgnx-modal-engine-for (layers &optional profiles)
  "The `:engine' of the first of LAYERS whose profile (in PROFILES, default the loaded ones) has `:modal'."
  (unless profiles
    (drgnx-keys--ensure-profiles)
    (setq profiles drgnx-keys-profiles))
  (cl-some (lambda (layer) (plist-get (plist-get (alist-get (car layer) profiles) :modal) :engine)) layers))

(defun drgnx-modal-current-layers ()
  "The key layers in force: this session's, else keys.eld's `:layers', else `drgnx-keys-layers'."
  (or drgnx-keys--session-layers
      (let ((drgnx-keys-problems nil)) (plist-get (drgnx-keys-read-user) :layers))
      drgnx-keys-layers))

(defun drgnx-modal--reset-buffers ()
  "Take the modal state out of every buffer and the indicator out of the mode line."
  (dolist (buf (buffer-list))
    (with-current-buffer buf (drgnx-modal-set-state nil)))
  (drgnx-modal-indicator-off))

(defun drgnx-modal-sync-engine (&optional layers)
  "Start the registered engine LAYERS (default `drgnx-modal-current-layers') need, once, and stop any other.
After a stop every buffer's state is cleared and the indicator removed (SPC types a space again); after a
start the emulation maps are put in order.  An engine's start function turns the indicator on and calls
`drgnx-modal-init-buffer' in each buffer.  Returns the engine running, or nil.  An engine whose module is
not installed is not started."
  (let* ((want (drgnx-modal-engine-for (or layers (drgnx-modal-current-layers))))
         (want (and want (assq want drgnx-modal-engines) want)))
    (unless (eq want drgnx-modal-running)
      (when drgnx-modal-running
        (let ((stop (plist-get (alist-get drgnx-modal-running drgnx-modal-engines) :stop)))
          (condition-case err
              (progn (when stop (funcall stop))
                     (drgnx-modal--reset-buffers)
                     (setq drgnx-modal-running nil))
            (error (message "drgnx: stopping %s failed: %s" drgnx-modal-running (error-message-string err))
                   (setq drgnx-modal-running nil)))))
      (when want
        (condition-case err
            (progn (when-let* ((start (plist-get (alist-get want drgnx-modal-engines) :start)))
                     (funcall start))
                   (setq drgnx-modal-running want)
                   (drgnx-modal-order-alists))
          (error (message "drgnx: starting %s failed: %s" want (error-message-string err))))))
    drgnx-modal-running))

;;;; Commands

(defun drgnx-modal-leader-menu ()
  "Read the leader keys (`SPC …' in normal state) wherever you are, then run the command they name."
  (interactive)
  (let ((map (keymap-lookup drgnx-modal-leader-map "SPC")))
    (if (keymapp map)
        (set-transient-map map)
      (message "The leader menu has no keys: choose Vim keys (Keyboard Profile…)"))))

(defun drgnx-modal--panel-move (key fallback)
  "Run what the panel binds KEY to (its own row movement), else FALLBACK; `this-command' names it."
  (let* ((cmd (local-key-binding (key-parse key)))
         (cmd (if (and (commandp cmd) (not (memq cmd '(drgnx-modal-panel-next drgnx-modal-panel-previous))))
                  cmd
                fallback)))
    (setq this-command cmd)
    (call-interactively cmd)))

(defun drgnx-modal-panel-next ()
  "Move to the next row of a panel: what the panel binds to <down>, else `next-line'."
  (interactive)
  (drgnx-modal--panel-move "<down>" #'next-line))

(defun drgnx-modal-panel-previous ()
  "Move to the previous row of a panel: what the panel binds to <up>, else `previous-line'."
  (interactive)
  (drgnx-modal--panel-move "<up>" #'previous-line))

(defun drgnx-modal-register-commands ()
  "Register the modal core's commands."
  (drgnx-command-define 'modal-leader :category "Edit" :title "Leader Menu"
                        :command #'drgnx-modal-leader-menu :scope 'app
                        :doc "The leader keys (SPC … in Vim's normal state), from any state; in the Vim profile M-SPC replaces Emacs' cycle-spacing")
  (drgnx-command-define 'panel-next :category "Edit" :title "Next Row"
                        :command #'drgnx-modal-panel-next :map 'drgnx-modal-panel-map :scope 'app
                        :when #'drgnx-modal-panel-p
                        :doc "The next row of a panel, as its own Down key does")
  (drgnx-command-define 'panel-previous :category "Edit" :title "Previous Row"
                        :command #'drgnx-modal-panel-previous :map 'drgnx-modal-panel-map :scope 'app
                        :when #'drgnx-modal-panel-p
                        :doc "The previous row of a panel, as its own Up key does"))

(drgnx-modal-order-alists)

(provide 'drgnx-modal)
;;; drgnx-modal.el ends here
