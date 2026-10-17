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

(defun drgnx-layouts--snapshot ()
  "The selected frame's arrangement: the editor area (groups, tabs, points) and each area shown, tab and size."
  (let ((dock (car (drgnx-wb--dock-windows))))
    (list :main (drgnx-layouts--with-kept-parameters (window-state-get (window-main-window)))
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

(defun drgnx-layouts--editor+agent (editor)
  "EDITOR with the current agent's chat to its right, in a group of its own (marked as the layout's pane)."
  (select-window editor)
  (let ((pane (drgnx-groups--split 'right)))
    (set-window-parameter pane 'drgnx-layouts-pane 'agent)
    (set-window-parameter pane 'drgnx-tabs nil)
    (set-window-parameter pane 'drgnx-tab-history nil)
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

(defun drgnx-layouts--put-main (state)
  "Put the remembered editor-area STATE back (groups, tabs, points)."
  (drgnx-layouts--with-kept-parameters (window-state-put state (window-main-window) 'safe)))

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
        (cond (memory (drgnx-layouts--put-main (plist-get memory :main)))
              (t (when back (drgnx-layouts--put-main (plist-get back :main)))
                 (drgnx-layouts--build-editor def)))
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

(drgnx-module-define 'tools/layouts
                     :doc "Layouts: Agent, Editor, Zen, Browser and your own; one key cycles."
                     :stage 'idle :requires '(core/workbench)
                     :setup
                     (lambda ()
                       (require 'drgnx-area)
                       (require 'drgnx-groups)
                       (require 'drgnx-persist)
                       (drgnx-layouts--define-commands)))

(provide 'drgnx-layouts)
;;; drgnx-layouts.el ends here
