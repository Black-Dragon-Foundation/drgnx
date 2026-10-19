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

(defvar-local drgnx-modal-keys-off nil
  "Non-nil in a buffer whose keys go somewhere else (the Live view while you drive the page): neither the leader
map nor the panel map is active here, whatever the state.  Whoever sets it calls
`(drgnx-modal-set-state drgnx-modal-state)' after, so the switch takes effect at once; the same after clearing it.")

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
only in a panel's emacs state; neither while `drgnx-modal-keys-off' is set here.  Returns STATE."
  (let ((panel (and (eq state 'emacs) (not drgnx-modal-keys-off) (drgnx-modal-panel-p))))
    (setq drgnx-modal-state state
          drgnx-modal--leader-on (and (not drgnx-modal-keys-off) (or panel (memq state drgnx-modal--leader-states)) t)
          drgnx-modal--panel-on panel)
    (force-mode-line-update)
    state))

(defun drgnx-modal-typing-p ()
  "Non-nil when a printable key types in this buffer as far as the modal engine goes: no engine runs here, or the
state is insert, replace or emacs.  Engine-neutral, for code that must know whether a key it passes on would type
\(a closing key re-queued to the buffer) or run the engine's command (`q' records a macro in normal state)."
  (or (null drgnx-modal-state) (and (memq drgnx-modal-state '(insert replace emacs)) t)))

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
\(`after-change-major-mode-hook').  A minibuffer is never modal: nothing is set there and the value is nil.
Returns the state."
  (unless (minibufferp)
    (drgnx-modal-set-state (drgnx-modal-initial-state))))

(defun drgnx-modal-where (mapsym &optional verbose)
  "How a key bound in MAPSYM is described next to its command: \"\" for the leader map (the keys are
shown plain), \"panels\" for the panel map, \"normal state\" and so on for the engine's state maps, nil for
any other keymap.  MAPSYM is a keymap symbol or (FEATURE . KEYMAP-SYMBOL).  With VERBOSE the leader map is
described by where it works, as the profile's `:modal' `:maps' says: \"normal, visual, motion state and panels\"."
  (pcase (if (consp mapsym) (cdr mapsym) mapsym)
    ('drgnx-modal-leader-map (if verbose (drgnx-modal--places 'drgnx-modal-leader-map) ""))
    ('drgnx-modal-panel-map "panels")
    ('evil-normal-state-map "normal state")
    ('evil-visual-state-map "visual state")
    ('evil-motion-state-map "motion state")
    ('evil-insert-state-map "insert state")))

(defun drgnx-modal--places (mapsym)
  "The places MAPSYM works in as words (\"normal, visual, motion state and panels\"), from the first loaded
profile's `:modal' `:maps' that lists it; \"\" when none does."
  (drgnx-keys--ensure-profiles)
  (or (cl-some (lambda (profile)
                 (cl-some (lambda (m)
                            (and (eq (cdr (drgnx-commands--keymap-spec (car m))) mapsym)
                                 (drgnx-keys--states-text (cdr m))))
                          (plist-get (plist-get (cdr profile) :modal) :maps)))
               drgnx-keys-profiles)
      ""))

(defun drgnx-modal-default-notes ()
  "Lines for the key sheet's and the report's conflicts: what the modal keys take from Emacs that the resolver does
not report (it knows Emacs' defaults only with an Emacs layer).  Today the Leader Menu on M-SPC over cycle-spacing;
nil when the Leader Menu is on another key, or the resolver reported that key already."
  (when-let* ((cmd (drgnx-commands-get 'modal-leader))
              ((seq-some (lambda (b) (and (equal (car b) "M-SPC")
                                          (eq (cdr (drgnx-commands--keymap-spec (cdr b))) 'global-map)))
                         (drgnx-cmd-bound cmd)))
              ((not (seq-some (lambda (c) (equal (plist-get c :key) "M-SPC"))
                              (plist-get drgnx-keys-last :conflicts)))))
    (list (format "M-SPC %s over cycle-spacing (Emacs) [default]" (drgnx-cmd-title cmd)))))

;;;; Order of the emulation maps

(defvar drgnx-modal-front-alists nil
  "Emulation alists (symbols) of modules whose keys must beat the modal engine's, like Esc and q closing a pane or
the quick-help card's keys: `drgnx-modal-order-alists' puts them right after the panel alist, in this order.  A
module adds its symbol here when it turns its map on and calls `drgnx-modal-order-alists'; it takes it out again
when it turns the map off.")

(defun drgnx-modal-order-alists ()
  "Put drgnx's emulation keymaps in front of the engine's in `emulation-mode-map-alists'.
The order: `drgnx-keys--everywhere-alist' (keys that work in every state beat the engine's), the leader
alist, the panel alist, the modules' `drgnx-modal-front-alists', `drgnx-ai-ghost--emulation', then the rest as
it was.  The leader, panel and ghost alists always have their place, bound or not: Emacs skips an unbound symbol in
the list, and a later `add-to-list' of the ghost's finds it already there.  The everywhere alist is put first on every
call, whatever it holds; it is off (`drgnx-keys--everywhere-on' nil) while there are no `:everywhere' keys, and
`drgnx-keys--set-everywhere' then also takes it out until the next call here.  Safe to call again;
`drgnx-modal-sync-engine' calls it after an engine starts, and the engine when it pushed its maps in front again."
  (let ((front `(drgnx-keys--everywhere-alist drgnx-modal--leader-alist drgnx-modal--panel-alist
                                              ,@drgnx-modal-front-alists drgnx-ai-ghost--emulation)))
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

(defconst drgnx-modal--indicator-texts
  (mapcar (lambda (e) (cons (car e) (propertize (nth 1 e) 'face (nth 2 e))))
          '((normal " NORMAL " drgnx-modal-normal) (operator " NORMAL " drgnx-modal-normal)
            (motion " MOTION " drgnx-modal-normal) (insert " INSERT " drgnx-modal-insert)
            (visual " VISUAL " drgnx-modal-visual) (visual-line " V-LINE " drgnx-modal-visual)
            (visual-block " V-BLOCK " drgnx-modal-visual) (replace " REPLACE " drgnx-modal-visual)
            (emacs " EMACS " drgnx-modal-emacs)))
  "Alist state → the indicator's string with the state's face, made once (redisplay only looks it up).")

(defun drgnx-modal-mode-line ()
  "The state indicator as a string with the state's face (\"\" when no modal engine runs in this buffer).
Self-contained: place `(:eval (drgnx-modal-mode-line))' anywhere in a mode-line layout."
  (or (alist-get drgnx-modal-state drgnx-modal--indicator-texts) ""))

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
functions of no arguments that turn the engine on and off.  Returns NAME.
Called from a module's setup, the definition records its undo, `drgnx-modal-undefine-engine' while the
definition is still this one: the engine stops first if it runs."
  (let ((spec (list :module module :start start :stop stop)))
    (setf (alist-get name drgnx-modal-engines) spec)
    (drgnx-modules-push-undo (format "modal engine %s" name) (lambda () (drgnx-modal-undefine-engine name spec))))
  name)

(defun drgnx-modal--stop-running ()
  "Stop the engine that runs (its stop function, under an error guard), then clear every buffer's state and the
indicator, whether or not the stop worked: no buffer keeps the modal keys of an engine that is not running."
  (when drgnx-modal-running
    (let ((stop (plist-get (alist-get drgnx-modal-running drgnx-modal-engines) :stop)))
      (condition-case err
          (when stop (funcall stop))
        (error (message "drgnx: stopping %s failed: %s" drgnx-modal-running (error-message-string err))))
      (drgnx-modal--reset-buffers)
      (setq drgnx-modal-running nil))))

(defun drgnx-modal-undefine-engine (name &optional spec)
  "Remove modal engine NAME, when SPEC is nil or still its definition; it is stopped first if it runs (as
`drgnx-modal-sync-engine' stops one).  Returns non-nil when it was removed.  Never prompts."
  (let ((cell (assq name drgnx-modal-engines)))
    (when (and cell (or (null spec) (eq (cdr cell) spec)))
      (when (eq drgnx-modal-running name) (drgnx-modal--stop-running))
      (setq drgnx-modal-engines (assq-delete-all name drgnx-modal-engines))
      t)))

(defun drgnx-modal-engine-for (layers &optional profiles)
  "The `:engine' of the first of LAYERS whose profile (in PROFILES, default the loaded ones) has `:modal'."
  (unless profiles
    (drgnx-keys--ensure-profiles)
    (setq profiles drgnx-keys-profiles))
  (cl-some (lambda (layer) (plist-get (plist-get (alist-get (car layer) profiles) :modal) :engine)) layers))

(defun drgnx-modal-mixed-p (layers &optional profiles)
  "Non-nil when LAYERS has a layer of a known profile (in PROFILES, default the loaded ones) without `:modal':
a Vim stack mixed with another editor's keys."
  (unless profiles
    (drgnx-keys--ensure-profiles)
    (setq profiles drgnx-keys-profiles))
  (drgnx-keys-modal-mixed-p layers profiles))

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

(defvar drgnx-modal-sync-functions nil
  "Functions called with the key layers at the end of every `drgnx-modal-sync-engine', whether or not an engine
started or stopped: the engine's keys that depend on the layers (insert-state keys in a mixed stack).")

(defvar drgnx-modal-suspended nil
  "Non-nil while the user has turned modal editing off for this session (Toggle Modal Editing): a list of one
element, the key layers in force at that moment.  `drgnx-modal-sync-engine' starts no engine for those same
layers; other layers clear it.")

(defun drgnx-modal-sync-engine (&optional layers)
  "Start the registered engine LAYERS (default `drgnx-modal-current-layers') need, once, and stop any other.
After a stop every buffer's state is cleared and the indicator removed (SPC types a space again); after a
start the emulation maps are put in order.  An engine's start function turns the indicator on and puts each
buffer in its state: by `drgnx-modal-init-buffer', or by mirroring its own state through `drgnx-modal-set-state'.
While `drgnx-modal-suspended' holds these same layers no engine is wanted; with other layers the suspension
ends.  Returns the engine running, or nil.  An engine whose module is not installed is not started.
At the end `drgnx-modal-sync-functions' are called with LAYERS, and, when the running engine changed, the key report
is written again (it said what ran before the after-apply functions started it) and which-key's labels follow
(the leader's go while modal editing is off)."
  (let* ((was drgnx-modal-running)
         (layers (or layers (drgnx-modal-current-layers)))
         (_ (when (and drgnx-modal-suspended (not (equal (car drgnx-modal-suspended) layers)))
              (setq drgnx-modal-suspended nil)))
         (want (and (not drgnx-modal-suspended) (drgnx-modal-engine-for layers)))
         (want (and want (assq want drgnx-modal-engines) want)))
    (unless (eq want drgnx-modal-running)
      (drgnx-modal--stop-running)
      (when want
        (condition-case err
            (progn (when-let* ((start (plist-get (alist-get want drgnx-modal-engines) :start)))
                     (funcall start))
                   (setq drgnx-modal-running want)
                   (drgnx-modal-order-alists))
          (error (message "drgnx: starting %s failed: %s" want (error-message-string err))))))
    (dolist (fn drgnx-modal-sync-functions)
      (condition-case err (funcall fn layers)
        (error (message "drgnx: %S failed: %s" fn (error-message-string err)))))
    (when (and drgnx-keys-last (not (eq was drgnx-modal-running)))
      (drgnx-keys--write-report)
      (when (fboundp 'drgnx-surfaces-apply-which-key) (drgnx-surfaces-apply-which-key)))
    drgnx-modal-running))

;;;; Commands

(defun drgnx-modal-leader-menu ()
  "Read the leader keys (`SPC …' in normal state) wherever you are, then run the command they name.
It goes on as if SPC had been typed (a transient map holding the leader's SPC, and SPC read again), so which-key's
popup is the one SPC shows, with the leader's labels.  The SPC read again is `no-record': it starts the key sequence,
so it is in the command keys which-key reads, but a keyboard macro recorded through the menu does not hold it (on
replay the menu reads its own SPC again; a recorded one would make it SPC SPC, the palette)."
  (interactive)
  (let ((map (keymap-lookup drgnx-modal-leader-map "SPC")))
    (if (keymapp map)
        (let ((transient (make-sparse-keymap)))
          (keymap-set transient "SPC" map)
          (set-transient-map transient)
          (push '(no-record . 32) unread-command-events))
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

;; A runtime switch of the key stack starts or stops the engine it needs (once; a second add is a no-op).
(add-hook 'drgnx-keys-after-apply-functions #'drgnx-modal-sync-engine)

(provide 'drgnx-modal)
;;; drgnx-modal.el ends here
