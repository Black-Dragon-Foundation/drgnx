;;; drgnx-layouts.el --- Module tools/layouts: Agent, Editor, Zen, Browser and your own; one key cycles -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A layout says which areas show and how the editor area is shaped: the left dock's view, the right
;; dock's tab, the bottom panel's tab and an editor shape (`drgnx-layouts-shapes').  Agent is the
;; main workday (Zed's arrangement): the Explorer, the editor beside the current agent's chat, the
;; Agents list narrow on the right, the panel when you open it.  Editor: the Explorer, the editor
;; groups, the panel as it was.  Zen: one window, its text centred.  Browser: the editor and a web
;; page beside it (the page comes with the browser pane; until then the editor alone).
;; Leaving a layout remembers its arrangement for this frame; coming back restores it, not a fresh
;; one.  A layout only moves, shows and hides: it never kills a buffer or a process, and touches
;; only the selected frame.  Save Layout As… keeps one of your own in layouts.eld.
;; See docs/guide/layouts.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-paths)
(require 'drgnx-wb)

(declare-function drgnx-wb-area-window "drgnx-area")
(declare-function drgnx-wb-area-show "drgnx-area")
(declare-function drgnx-wb-area-hide "drgnx-area")
(declare-function drgnx-wb-area-tab "drgnx-area")
(declare-function drgnx-groups-list "drgnx-groups")
(declare-function drgnx-groups--split "drgnx-groups")
(declare-function drgnx-chrome-apply "drgnx-chrome")
(declare-function drgnx-persist--strip "drgnx-persist")
(declare-function drgnx-persist--clamp "drgnx-persist")
(declare-function drgnx-persist--visit "drgnx-persist")
(declare-function drgnx-persist--set-tabs "drgnx-persist")
(declare-function drgnx-replace--bar-clear "drgnx-replace")
(declare-function drgnx-agents-sessions "drgnx-agents")
(declare-function drgnx-agent-session-status "drgnx-agents")
(declare-function drgnx-agents-ui-last-active "drgnx-agents-ui")
(declare-function drgnx-agents-ui-transcript-buffer "drgnx-agents-ui")
(defvar drgnx-wb--areas)

(defcustom drgnx-layouts-zen-width 100
  "Text width in the Zen layout, in columns."
  :type 'integer :group 'drgnx)

(defvar drgnx-layouts
  '((agent :left explorer :right agents :panel nil :editor editor+agent)
    (editor :left explorer :right nil :panel keep :editor one)
    (zen :left nil :right nil :panel nil :editor zen)
    (browser :left nil :right nil :panel nil :editor editor+browser))
  "The built-in layouts, in the order Next Layout cycles them: NAME → (:left VIEW :right TAB :panel TAB
:editor SHAPE).  An area's value nil hides it and `keep' leaves it as it was; SHAPE is a key of
`drgnx-layouts-shapes'.  Your own layouts (layouts.eld) follow them.")

(defvar drgnx-layouts-shapes
  '((one . drgnx-layouts--one) (editor+agent . drgnx-layouts--editor+agent) (zen . drgnx-layouts--zen))
  "Editor shapes: SHAPE → a function of the editor window that arranges the editor area.
A shape not registered here (the Browser layout's `editor+browser' until the browser pane adds it)
arranges as `one'.")

(defconst drgnx-layouts--kept-parameters '(drgnx-tabs drgnx-tab-history drgnx-layouts-pane)
  "Editor-window parameters a remembered arrangement keeps: each group's tabs, and the chat pane's mark.")

;;;; Layouts: built in and your own

(defun drgnx-layouts-current (&optional frame)
  "The layout FRAME shows: the last one applied, or nil before any (that arrangement has no name)."
  (frame-parameter frame 'drgnx-layouts-current))

(defun drgnx-layouts--file () (expand-file-name "layouts.eld" (drgnx-user-dir)))

(defun drgnx-layouts--user ()
  "Your layouts from layouts.eld: NAME → plist (an unreadable file holds none; built-in names are skipped)."
  (let* ((f (drgnx-layouts--file))
         (data (and (file-readable-p f)
                    (ignore-errors (with-temp-buffer (insert-file-contents f) (read (current-buffer)))))))
    (and (proper-list-p data)
         (seq-filter (lambda (e) (and (consp e) (symbolp (car e)) (proper-list-p (cdr e)) (not (assq (car e) drgnx-layouts))))
                     data))))

(defun drgnx-layouts--all () (append drgnx-layouts (drgnx-layouts--user)))

(defun drgnx-layouts-names ()
  "Every layout's name, the built-in ones first: the order Next Layout cycles."
  (mapcar #'car (drgnx-layouts--all)))

;;;; An arrangement: the editor area's window state and the three areas

(defmacro drgnx-layouts--with-kept-parameters (&rest body)
  "BODY with `drgnx-layouts--kept-parameters' in the window states it gets and puts (in this session only)."
  `(let ((window-persistent-parameters
          (append (mapcar (lambda (p) (cons p t)) drgnx-layouts--kept-parameters) window-persistent-parameters)))
     ,@body))

(defun drgnx-layouts--area-snapshot (area)
  (let ((w (drgnx-wb-area-window area)))
    (list :shown (and w t) :tab (drgnx-wb-area-tab area)
          :px (if w (if (eq area 'right) (window-pixel-width w) (window-pixel-height w))
                (frame-parameter nil (intern (format "drgnx-wb-%s-px" area)))))))

(defun drgnx-layouts--pane-specs ()
  "The selected frame's layout panes as a list of (INDEX . KIND): INDEX is a pane's place among the editor
groups, KIND `agent' or `browser'."
  (let ((i 0) specs)
    (dolist (g (drgnx-groups-list))
      (when-let* ((kind (window-parameter g 'drgnx-layouts-pane))) (push (cons i kind) specs))
      (cl-incf i))
    (nreverse specs)))

(defun drgnx-layouts--group-specs ()
  "Each editor group's tab files and shown file, in order: what a restart needs to open them again."
  (mapcar (lambda (g)
            (list :tabs (and (fboundp 'drgnx-chrome-tabs) (delq nil (mapcar #'buffer-file-name (drgnx-chrome-tabs g))))
                  :shown (buffer-file-name (window-buffer g))))
          (drgnx-groups-list)))

(defun drgnx-layouts--snapshot ()
  "The selected frame's arrangement: the editor area (groups, tabs, points) and each area shown, tab and size.
:writable is the editor area again as a state that can be written to a file (no window parameters, so
:panes says which groups are the chat or browser pane, :groups their files): what a restart keeps."
  (let ((dock (car (drgnx-wb--dock-windows))))
    (list :main (drgnx-layouts--with-kept-parameters (window-state-get (window-main-window)))
          :writable (window-state-get (window-main-window) t)
          :panes (drgnx-layouts--pane-specs)
          :groups (drgnx-layouts--group-specs)
          :left (list :shown (and dock t) :view (drgnx-wb-sidebar-view)
                      :px (if dock (window-pixel-width dock) (frame-parameter nil 'drgnx-wb-dock-px)))
          :panel (drgnx-layouts--area-snapshot 'panel)
          :right (drgnx-layouts--area-snapshot 'right))))

(defun drgnx-layouts--close-bars ()
  "Close this frame's find bars: an arrangement must not keep their windows."
  (dolist (w (window-list nil 'nomini))
    (when (and (window-live-p w) (eq (window-parameter w 'drgnx-role) 'bar))
      (when (fboundp 'drgnx-replace--bar-clear) (with-current-buffer (window-buffer w) (drgnx-replace--bar-clear)))
      (ignore-errors (delete-window w)))))

(defun drgnx-layouts--hide-all ()
  "Hide the left dock, the panel and the right dock (each keeps its size and tabs)."
  (drgnx-wb-hide-sidebar)
  (drgnx-wb-area-hide 'panel)
  (drgnx-wb-area-hide 'right))

(defun drgnx-layouts--show-left (spec)
  "Show the left dock as SPEC says (:shown :view :px)."
  (when (integerp (plist-get spec :px)) (set-frame-parameter nil 'drgnx-wb-dock-px (plist-get spec :px)))
  (when (plist-get spec :shown)
    (let ((view (plist-get spec :view)))
      (if (and view (drgnx-wb--view-defined-p view)) (drgnx-wb-show-view view) (drgnx-wb-show-sidebar)))))

(defun drgnx-layouts--show-area (area spec)
  "Show AREA as SPEC says (:shown :tab :px); a tab no module defines is not shown."
  (when (integerp (plist-get spec :px))
    (set-frame-parameter nil (intern (format "drgnx-wb-%s-px" area)) (plist-get spec :px)))
  (let ((tab (plist-get spec :tab)))
    (when (and (plist-get spec :shown) tab (assq tab (plist-get (alist-get area drgnx-wb--areas) :tabs)))
      (drgnx-wb-area-show area tab))))

(defun drgnx-layouts--target (def snap)
  "The areas layout DEF asks for, as a snapshot's: `keep' takes them from SNAP."
  (cl-flet ((area (key prop)
              (let ((v (plist-get def key)) (px (plist-get (plist-get def :px) key)))
                (cond ((eq v 'keep) (plist-get snap key))
                      ((null v) (list :shown nil :px px))
                      (t (list :shown t prop v :px px))))))
    (list :left (area :left :view) :panel (area :panel :tab) :right (area :right :tab))))

;;;; Editor shapes

(defun drgnx-layouts--one (_editor)
  "The editor groups as they are."
  nil)

(defun drgnx-layouts--registry-put (registry key value)
  "Set REGISTRY (a symbol whose value is an alist) so KEY maps to VALUE, or has no entry when VALUE is nil.
The alist is rebuilt, never changed in place: the built-ins are quoted constants, and a test's
`copy-sequence' of the registry shares its cells."
  (set registry (let ((rest (seq-remove (lambda (e) (eq (car-safe e) key)) (symbol-value registry))))
                  (if value (cons (cons key value) rest) rest))))

(defun drgnx-layouts-define-shape (shape fn)
  "Teach the layouts the editor SHAPE: FN, a function of the editor window, arranges the editor area.
Returns SHAPE.  A layout whose `:editor' is SHAPE uses it.  In a module's setup the registration is
undone with the module (the entry that was there before comes back, unless someone has set another
since); the layouts that name SHAPE keep it and arrange as `one' while it is gone."
  (let ((previous (alist-get shape drgnx-layouts-shapes)))
    (drgnx-layouts--registry-put 'drgnx-layouts-shapes shape fn)
    (drgnx-modules-push-undo
     (format "layout shape %s" shape)
     (lambda ()
       (when (eq (alist-get shape drgnx-layouts-shapes) fn)
         (drgnx-layouts--registry-put 'drgnx-layouts-shapes shape previous)))))
  shape)

(defun drgnx-layouts-undefine-shape (shape)
  "Remove the editor SHAPE; a layout that names it arranges as `one' from now on.  Layouts are not touched."
  (drgnx-layouts--registry-put 'drgnx-layouts-shapes shape nil)
  nil)

(defun drgnx-layouts--current-agent ()
  "The running agent session that acted last (the newest on a tie), or nil."
  (when (fboundp 'drgnx-agents-sessions)
    (let ((at (lambda (s) (or (and (fboundp 'drgnx-agents-ui-last-active) (drgnx-agents-ui-last-active s)) 0))))
      (car (sort (seq-remove (lambda (s) (eq (drgnx-agent-session-status s) 'exited)) (drgnx-agents-sessions))
                 (lambda (a b) (> (funcall at a) (funcall at b))))))))

(defun drgnx-layouts--agent-buffer ()
  "The current agent's transcript, else a buffer that says how to start one."
  (if-let* ((s (drgnx-layouts--current-agent)) ((fboundp 'drgnx-agents-ui-transcript-buffer)))
      (drgnx-agents-ui-transcript-buffer s)
    (with-current-buffer (get-buffer-create "*drgnx: no agent*")
      (unless (derived-mode-p 'special-mode) (special-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "No agent yet — Agents: New Agent Session… starts one here.\n"))
      (current-buffer))))

(defvar drgnx-layouts-pane-fillers '((agent . drgnx-layouts--fill-agent))
  "Pane KIND → a function of the pane window that puts that kind's content in it.  A pane found again
after a restart (`drgnx-layouts--mark-pane') is filled this way; the browser module adds `browser'.")

(defun drgnx-layouts--fill-agent (pane)
  "Show the current agent's chat (else the hint) in PANE."
  (set-window-buffer pane (drgnx-layouts--agent-buffer)))

(defun drgnx-layouts--mark-pane (spec &optional fill)
  "Mark the editor group SPEC = (INDEX . KIND) names (INDEX may be a window) as the layout's pane of that
kind (a restart leaves no window parameters), so the next layout removes it.  FILL it with the kind's
content when the kind has a filler (the kind's module may set up later: `drgnx-layouts-define-pane').
Nothing happens for a SPEC that names no group.  Returns the pane."
  (when-let* (((consp spec)) (kind (cdr spec)) ((symbolp kind))
              (pane (if (windowp (car spec)) (car spec) (and (natnump (car spec)) (nth (car spec) (drgnx-groups-list)))))
              ((window-live-p pane)))
    (set-window-parameter pane 'drgnx-layouts-pane kind)
    (set-window-parameter pane 'drgnx-tabs nil)
    (set-window-parameter pane 'drgnx-tab-history nil)
    (when-let* ((fill) (filler (alist-get kind drgnx-layouts-pane-fillers))) (funcall filler pane))
    pane))

(defun drgnx-layouts-define-pane (kind filler)
  "Teach the layouts a pane of KIND: FILLER (a function of the pane window) fills it.  Panes of KIND already
marked in a live frame (found again after a restart before this module set up) are filled now.  In a
module's setup the registration is undone with the module (`drgnx-layouts-undefine-pane'; the previous
filler comes back, unless someone has set another since)."
  (let ((previous (alist-get kind drgnx-layouts-pane-fillers)))
    (drgnx-layouts--registry-put 'drgnx-layouts-pane-fillers kind filler)
    (drgnx-modules-push-undo
     (format "layout pane %s" kind)
     (lambda ()
       (when (eq (alist-get kind drgnx-layouts-pane-fillers) filler)
         (drgnx-layouts--registry-put 'drgnx-layouts-pane-fillers kind previous)))))
  (dolist (f (frame-list))
    (dolist (w (window-list f 'nomini))
      (when (eq (window-parameter w 'drgnx-layouts-pane) kind) (ignore-errors (funcall filler w))))))

(defun drgnx-layouts-undefine-pane (kind)
  "Forget how to fill panes of KIND.  Panes of KIND already shown keep their window and mark until the next
layout removes them (their intent, the saved arrangements, is untouched); defining the kind again fills them."
  (drgnx-layouts--registry-put 'drgnx-layouts-pane-fillers kind nil)
  nil)

(defun drgnx-layouts--panes-of (value)
  "VALUE (a list of (INDEX . KIND), or one such pair as older workbenches saved) as a clean list of pairs."
  (let ((l (if (and (consp value) (natnump (car value))) (list value) value)))
    (and (proper-list-p l)
         (seq-filter (lambda (s) (and (consp s) (natnump (car s)) (cdr s) (symbolp (cdr s)))) l))))

(defun drgnx-layouts--groups-of (value)
  "VALUE (a saved `:groups') as a clean list of (:tabs FILES :shown FILE) plists, one per group."
  (and (proper-list-p value)
       (mapcar (lambda (s)
                 (let ((tabs (and (proper-list-p s) (cl-evenp (length s)) (plist-get s :tabs)))
                       (shown (and (proper-list-p s) (cl-evenp (length s)) (plist-get s :shown))))
                   (list :tabs (and (proper-list-p tabs) (seq-filter #'stringp tabs)) :shown (and (stringp shown) shown))))
               value)))

(defun drgnx-layouts--reopen-groups (specs)
  "Open the files of the saved group SPECS that are not open and put each group's shown file and tabs back
(the window state names buffers, which a new Emacs does not have).  Never asks anything."
  (cl-loop for g in (drgnx-groups-list) for spec in specs
           do (let ((files (seq-take (plist-get spec :tabs) 50)))
                (dolist (f files) (drgnx-persist--visit f))
                (when-let* ((b (drgnx-persist--visit (plist-get spec :shown))) ((not (eq b (window-buffer g)))))
                  (set-window-buffer g b))
                (drgnx-persist--set-tabs g files))))

(defun drgnx-layouts--editor+agent (editor)
  "EDITOR with the current agent's chat to its right, in a group of its own (marked as the layout's pane)."
  (select-window editor)
  (let ((pane (drgnx-groups--split 'right)))
    (drgnx-layouts--mark-pane (cons pane 'agent))
    (set-window-buffer pane (drgnx-layouts--agent-buffer))
    (select-window editor)
    pane))

(defun drgnx-layouts--zen (editor)
  "EDITOR alone (its margins come from `drgnx-layouts--zen-margins')."
  (delete-other-windows editor)
  (select-window editor))

(defun drgnx-layouts--remove-panes ()
  "Delete the layouts' panes (the chat beside the editor), never the last group."
  (dolist (w (window-list nil 'nomini))
    (when (and (window-live-p w) (window-parameter w 'drgnx-layouts-pane) (cdr (drgnx-groups-list)))
      (delete-window w))))

(defun drgnx-layouts--build-editor (def)
  "Arrange the editor area as layout DEF says: your saved windows, else its shape."
  (require 'drgnx-persist)                ; its parameter stripper: a layouts file must not set any
  (unless (and (plist-get def :windows)
               (condition-case err
                   (progn (window-state-put (drgnx-persist--strip (plist-get def :windows)) (window-main-window) 'safe) t)
                 (error (message "drgnx: the layout's windows were not restored: %s" (error-message-string err)) nil)))
    (drgnx-layouts--remove-panes)
    (funcall (or (alist-get (plist-get def :editor) drgnx-layouts-shapes) #'drgnx-layouts--one)
             (drgnx-wb-editor-window))))

;;;; Zen: the text centred

(defun drgnx-layouts--centre (frame)
  "Margins on FRAME's editor windows that leave `drgnx-layouts-zen-width' columns of text in the middle."
  (dolist (w (window-list frame 'nomini))
    (when (drgnx-signal-editor-window-p w)
      (let* ((m (window-margins w))
             (width (+ (window-body-width w) (or (car m) 0) (or (cdr m) 0)))
             (side (max 0 (/ (- width drgnx-layouts-zen-width) 2))))
        (set-window-margins w side side)))))

(defun drgnx-layouts--zen-resize (frame)
  "While FRAME shows Zen, centre its text again (on `window-size-change-functions')."
  (when (eq (frame-parameter frame 'drgnx-layouts-current) 'zen)
    (drgnx-layouts--centre frame)))

(defun drgnx-layouts--zen-margins (from to)
  "Going FROM a layout TO another: centre the text entering Zen, clear the margins leaving it."
  (cond ((eq to 'zen)
         (drgnx-layouts--centre nil)
         (add-hook 'window-size-change-functions #'drgnx-layouts--zen-resize))
        ((eq from 'zen)
         (dolist (w (window-list nil 'nomini))
           (when (drgnx-signal-editor-window-p w) (set-window-margins w 0 0)))
         (unless (seq-some (lambda (f) (eq (frame-parameter f 'drgnx-layouts-current) 'zen)) (frame-list))
           (remove-hook 'window-size-change-functions #'drgnx-layouts--zen-resize)))))

;;;; Apply

(defun drgnx-layouts--remember (name snap)
  (let ((states (copy-alist (frame-parameter nil 'drgnx-layouts-state))))
    (setf (alist-get name states) snap)
    (set-frame-parameter nil 'drgnx-layouts-state states)))

(defun drgnx-layouts--put-main (snap)
  "Put the remembered arrangement SNAP's editor area back (groups, tabs, points); non-nil on success.
One read from the saved workbench (`:fill') comes from a file, so it may be damaged: that one puts
without asking or visiting anything unsafe, marks and fills its pane, and returns nil on an error."
  (if (not (plist-get snap :fill))
      (progn (drgnx-layouts--with-kept-parameters (window-state-put (plist-get snap :main) (window-main-window) 'safe)) t)
    (condition-case err
        (let ((window-restore-killed-buffer-windows #'ignore) (non-essential t)
              (enable-local-variables :safe) (large-file-warning-threshold nil))
          (window-state-put (plist-get snap :main) (window-main-window) 'safe)
          (drgnx-layouts--reopen-groups (plist-get snap :groups))
          (dolist (p (plist-get snap :panes)) (drgnx-layouts--mark-pane p t))
          t)
      (error (message "drgnx: a saved layout arrangement was not restored: %s" (error-message-string err)) nil))))

(defun drgnx-layouts-apply (name)
  "Arrange the selected frame as layout NAME.
The arrangement being left is remembered for its layout (frame parameter `drgnx-layouts-state'); NAME's
remembered arrangement comes back, or NAME's definition builds one.  No buffer or process is killed.
Entering Zen also keeps the arrangement it came from (frame parameter `drgnx-layouts-zen-return'):
leaving Zen for a layout not used yet builds that layout from it, not from Zen's one window, and
NAME nil (leaving Zen when no layout was picked before) puts it back as it was."
  (let* ((from (drgnx-layouts-current))
         (back (and (eq from 'zen) (not (eq name 'zen)) (frame-parameter nil 'drgnx-layouts-zen-return)))
         (def (cond (name (or (alist-get name (drgnx-layouts--all)) (user-error "No layout named %s" name)))
                    (back nil)
                    (t (user-error "No layout named")))))
    (drgnx-layouts--close-bars)
    (let ((snap (drgnx-layouts--snapshot)))
      (when from (drgnx-layouts--remember from snap))
      (when (and (eq name 'zen) (not (eq from 'zen))) (set-frame-parameter nil 'drgnx-layouts-zen-return snap))
      (let ((memory (if name (alist-get name (frame-parameter nil 'drgnx-layouts-state)) back)))
        (drgnx-layouts--hide-all)
        (when (and memory (not (drgnx-layouts--put-main memory)))   ; damaged: build it as if never left
          (when (eq memory back) (setq back nil))
          (setq memory nil))
        (unless memory
          (when (and back (not (drgnx-layouts--put-main back))) (setq back nil))
          (drgnx-layouts--build-editor def))
        (let ((target (or memory (drgnx-layouts--target def (or back snap)))))
          (drgnx-layouts--show-left (plist-get target :left))
          (drgnx-layouts--show-area 'panel (plist-get target :panel))
          (drgnx-layouts--show-area 'right (plist-get target :right)))))
    (when (and (eq from 'zen) (not (eq name 'zen))) (set-frame-parameter nil 'drgnx-layouts-zen-return nil))
    (unless (or (null from) (eq from name)) (set-frame-parameter nil 'drgnx-layouts-previous from))
    (set-frame-parameter nil 'drgnx-layouts-current name)
    (drgnx-layouts--zen-margins from name)
    (unless (drgnx-signal-editor-window-p (selected-window)) (select-window (drgnx-wb-editor-window)))
    (setq drgnx-signal--editor-window (selected-window))
    (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply nil t))
    name))

;;;; Commands

(defun drgnx-layouts-agent ()
  "Layout Agent: the Explorer, the editor beside the current agent's chat, the Agents list on the right."
  (interactive)
  (drgnx-layouts-apply 'agent))

(defun drgnx-layouts-editor ()
  "Layout Editor: the Explorer, the editor groups and the panel as it was; the agent docks hidden."
  (interactive)
  (drgnx-layouts-apply 'editor))

(defun drgnx-layouts-zen ()
  "Layout Zen: only the file, its text centred; again to go back to the layout before (or, when none
was picked yet, to the arrangement you had)."
  (interactive)
  (if (eq (drgnx-layouts-current) 'zen)
      (let ((back (frame-parameter nil 'drgnx-layouts-previous)))
        (drgnx-layouts-apply (cond ((and back (not (eq back 'zen)) (memq back (drgnx-layouts-names))) back)
                                   ((frame-parameter nil 'drgnx-layouts-zen-return) nil)
                                   (t 'editor))))
    (drgnx-layouts-apply 'zen)))

(defun drgnx-layouts-browser ()
  "Layout Browser: the editor and a web page beside it (the page pane comes with the browser module)."
  (interactive)
  (drgnx-layouts-apply 'browser))

(defun drgnx-layouts-next ()
  "The next layout: Agent, Editor, Zen, Browser, yours, and around."
  (interactive)
  (let* ((names (drgnx-layouts-names))
         (name (or (cadr (memq (drgnx-layouts-current) names)) (car names))))
    (drgnx-layouts-apply name)
    (message "Layout: %s" (capitalize (symbol-name name)))))

(defun drgnx-layouts-pick (name)
  "Switch to the layout NAME (asked, with completion)."
  (interactive (list (intern (completing-read "Layout: " (mapcar #'symbol-name (drgnx-layouts-names)) nil t))))
  (drgnx-layouts-apply name))

(defun drgnx-layouts--write-user (alist)
  (let ((f (drgnx-layouts--file)))
    (make-directory (file-name-directory f) t)
    (with-temp-file f
      (insert ";; drgnx: your layouts, written by View: Save Layout As… (docs/guide/layouts.md)\n")
      (let ((print-length nil) (print-level nil)) (pp alist (current-buffer))))))

(defun drgnx-layouts-save (name)
  "Save the selected frame's arrangement as your layout NAME (in layouts.eld); you are then in it."
  (interactive (list (read-string "Save layout as: ")))
  (let ((sym (intern (string-trim name))))
    (when (string-empty-p (string-trim name)) (user-error "A layout needs a name"))
    (when (assq sym drgnx-layouts) (user-error "%s is a built-in layout: choose another name" sym))
    (drgnx-layouts--close-bars)
    (let* ((snap (drgnx-layouts--snapshot))
           (shown (lambda (key prop) (let ((s (plist-get snap key))) (and (plist-get s :shown) (plist-get s prop)))))
           (def (list :left (funcall shown :left :view) :right (funcall shown :right :tab) :panel (funcall shown :panel :tab)
                      :editor (or (plist-get (alist-get (drgnx-layouts-current) (drgnx-layouts--all)) :editor) 'one)
                      :windows (window-state-get (window-main-window) t)
                      :px (list :left (plist-get (plist-get snap :left) :px) :panel (plist-get (plist-get snap :panel) :px)
                                :right (plist-get (plist-get snap :right) :px))))
           (user (drgnx-layouts--user)))
      (setf (alist-get sym user) def)
      (drgnx-layouts--write-user user)
      (when-let* ((from (drgnx-layouts-current)))
        (drgnx-layouts--remember from snap)
        (unless (eq from sym) (set-frame-parameter nil 'drgnx-layouts-previous from)))
      (drgnx-layouts--remember sym snap)
      (set-frame-parameter nil 'drgnx-layouts-current sym)
      (message "Saved layout %s" sym)
      sym)))

(defun drgnx-layouts--define-commands ()
  (pcase-dolist (`(,id ,title ,fn ,doc)
                 '((layout-agent "Layout Agent" drgnx-layouts-agent
                                 "The Explorer, the editor beside the current agent's chat, the Agents list on the right")
                   (layout-editor "Layout Editor" drgnx-layouts-editor "The Explorer, the editor groups and the panel; the agent docks hidden")
                   (layout-zen "Layout Zen" drgnx-layouts-zen "Only the file, centred; again to go back")
                   (layout-browser "Layout Browser" drgnx-layouts-browser "The editor and a web page beside it")
                   (layout-next "Next Layout" drgnx-layouts-next "Agent, Editor, Zen, Browser, yours, and around")
                   (layout-save "Save Layout As…" drgnx-layouts-save "This arrangement as a layout of your own")
                   (layout-pick "Layout…" drgnx-layouts-pick "Switch to a layout by name")))
    (drgnx-command-define id :category "View" :title title :command fn :doc doc :scope 'window)))

;;;; Survive a restart

(defvar drgnx-persist-state-functions)
(defvar drgnx-persist-after-restore-functions)

(defun drgnx-layouts--arrangement-state (snap)
  "SNAP as the saved workbench keeps it: the editor area as the state that can be written, no buffers."
  (let ((out (list :main (if (plist-member snap :writable) (plist-get snap :writable) (plist-get snap :main)))))
    (dolist (k '(:left :panel :right :panes :groups) out)
      (setq out (append out (list k (plist-get snap k)))))))

(defun drgnx-layouts--persist-state ()
  "The selected frame's layout for `drgnx-persist-state-functions': (:layout NAME :panes SPECS
:arrangements ALIST :previous NAME :zen-return ARRANGEMENT) — the current layout, which group is its pane
and each layout's last arrangement — or nothing before any layout was applied."
  (when-let* ((name (drgnx-layouts-current)))
    (list :layout name :panes (drgnx-layouts--pane-specs)
          :arrangements (mapcar (lambda (e) (cons (car e) (drgnx-layouts--arrangement-state (cdr e))))
                                (frame-parameter nil 'drgnx-layouts-state))
          :previous (frame-parameter nil 'drgnx-layouts-previous)
          :zen-return (when-let* ((z (frame-parameter nil 'drgnx-layouts-zen-return)))
                        (drgnx-layouts--arrangement-state z)))))

(defun drgnx-layouts--read-arrangement (snap)
  "A saved arrangement SNAP made safe to use (the file may be crafted): its window state without
parameters, its sizes clamped, marked `:fill' (read from a file); nil when it is not one."
  (when (and (proper-list-p snap) (cl-evenp (length snap)) (consp (plist-get snap :main)))
    (let ((out (list :fill t :main (drgnx-persist--strip (plist-get snap :main)) :panes (drgnx-layouts--panes-of (or (plist-get snap :panes) (plist-get snap :pane)))
                     :groups (drgnx-layouts--groups-of (plist-get snap :groups)))))
      (catch 'bad
        (dolist (area '((:left 0.5 . width) (:panel 0.7 . height) (:right 0.5 . width)) out)
          (let ((spec (plist-get snap (car area))))
            (unless (and (proper-list-p spec) (cl-evenp (length spec))) (throw 'bad nil))
            (let ((limit (* (cadr area) (if (eq (cddr area) 'width) (frame-pixel-width) (frame-pixel-height)))))
              (setq out (append out (list (car area)
                                          (append (list :px (drgnx-persist--clamp (plist-get spec :px) limit)) spec)))))))))))

(defun drgnx-layouts--adopt (frame)
  "Make the layout saved with FRAME's restored workbench its current one, without arranging anything
(the windows came back as they were): mark its chat or browser pane again and keep each layout's last
arrangement.  A layout that no longer exists is ignored.  Never prompts."
  (when (and (frame-live-p frame) (null (frame-parameter frame 'drgnx-layouts-current)))
    (let* ((extra (frame-parameter frame 'drgnx-persist-extra))
           (name (plist-get extra :layout)) (arrangements (plist-get extra :arrangements)))
      (with-selected-frame frame
        (when (and name (symbolp name) (alist-get name (drgnx-layouts--all)))
          (set-frame-parameter frame 'drgnx-layouts-current name)
          (drgnx-layouts--zen-margins nil name)
          (dolist (p (drgnx-layouts--panes-of (or (plist-get extra :panes) (plist-get extra :pane))))
            (drgnx-layouts--mark-pane p t))
          (set-frame-parameter frame 'drgnx-layouts-state
                               (and (proper-list-p arrangements)
                                    (delq nil (mapcar (lambda (e)
                                                        (when-let* (((consp e)) ((symbolp (car e)))
                                                                    ((alist-get (car e) (drgnx-layouts--all)))
                                                                    (snap (drgnx-layouts--read-arrangement (cdr e))))
                                                          (cons (car e) snap)))
                                                      arrangements))))
          (when-let* ((prev (plist-get extra :previous)) ((symbolp prev)) ((alist-get prev (drgnx-layouts--all))))
            (set-frame-parameter frame 'drgnx-layouts-previous prev))
          (set-frame-parameter frame 'drgnx-layouts-zen-return (drgnx-layouts--read-arrangement (plist-get extra :zen-return)))
          (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply frame)))))))

(defun drgnx-layouts--wire-persist ()
  "Keep the current layout in the saved workbench and take it back after a restart.  A frame restored
before this ran (the module sets up at idle) is adopted now."
  (require 'drgnx-persist)
  (add-hook 'drgnx-persist-state-functions #'drgnx-layouts--persist-state)
  (add-hook 'drgnx-persist-after-restore-functions #'drgnx-layouts--adopt)
  (mapc #'drgnx-layouts--adopt (frame-list)))

(defun drgnx-layouts--teardown ()
  "Forget the layouts in every frame: Zen's margins and its resize hook go, and the frame parameters of the
current layout, the remembered arrangements, the previous layout and Zen's way back."
  (dolist (f (frame-list))
    (when (eq (frame-parameter f 'drgnx-layouts-current) 'zen)
      (with-selected-frame f (drgnx-layouts--zen-margins 'zen nil)))
    (dolist (p '(drgnx-layouts-current drgnx-layouts-state drgnx-layouts-previous drgnx-layouts-zen-return))
      (set-frame-parameter f p nil)))
  (remove-hook 'window-size-change-functions #'drgnx-layouts--zen-resize))

(drgnx-module-define 'tools/layouts
                     :doc "Layouts: Agent, Editor, Zen, Browser and your own; one key cycles."
                     :stage 'idle :requires '(core/workbench)
                     :teardown #'drgnx-layouts--teardown
                     :setup
                     (lambda ()
                       (require 'drgnx-area)
                       (require 'drgnx-groups)
                       (require 'drgnx-persist)
                       (drgnx-layouts--wire-persist)
                       (drgnx-layouts--define-commands)))

(provide 'drgnx-layouts)
;;; drgnx-layouts.el ends here
