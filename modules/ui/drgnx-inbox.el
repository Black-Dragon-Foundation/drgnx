;;; drgnx-inbox.el --- The needs-you inbox: a drop-down under the title row's pill, or a tab in the right side bar -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Design: docs/specs/drgnx/2026-11-16-title-bar-inbox-design.md (the org folder), "The inbox" (mockup option C).
;; The pill in the title row, `N need you', opens a card under it: one row per thing that waits on you (the notice
;; model's attention items, `drgnx-needs-you-items': no new source), newest first, each with the buttons of its kind.
;; A permission ask has Allow once, Always for this session and Deny: the answers the agent panel's permission card
;; sends, through the same call (`drgnx-agents-answer-permission'), so the row leaves at once and the pill follows.
;; Any other item has Show, which does what the pill's click did (the item's own command).  A kind is one entry of
;; `drgnx-inbox-kinds'.  "Pin as side bar" moves the same rows into an Inbox tab of the right side bar (pane kind
;; `inbox'); the choice is kept in state/inbox.eld, so the pill then shows the tab.  In the tab an answered row stays
;; for the session, faded, until "Clear answered".  The buffer is one (`drgnx-inbox-buffer-name'): the card's frame
;; or the tab's window shows it.  Every button runs a registry command; the row it answers is the one it was drawn on
;; (`drgnx-inbox--target'), else the selected row.  Never waits on the hub: it reads the notice model.
;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-registry)
(require 'drgnx-notice)
(require 'drgnx-ui-kit)
(require 'drgnx-pixels)
(require 'drgnx-file)
(require 'drgnx-paths)
(require 'drgnx-surfaces)
(require 'drgnx-palette-frame)

(defvar drgnx-notice-functions)
(declare-function drgnx-agents-get "drgnx-agents" (id))
(declare-function drgnx-agents-answer-permission "drgnx-agents" (s item option-id))
(declare-function drgnx-agent-session-permissions "drgnx-agents" (s))
(declare-function drgnx-notices-show "drgnx-notices")
(declare-function drgnx-pane-show "drgnx-panes")
(declare-function drgnx-pane-hide "drgnx-panes")
(declare-function drgnx-pane-window "drgnx-panes")
(declare-function drgnx-pane-define-kind "drgnx-panes")
(declare-function drgnx-pane-undefine-kind "drgnx-panes")
(declare-function drgnx-topline-item-span "drgnx-topline")
(declare-function drgnx-palette-frame-modal-chrome "drgnx-palette-frame")
(declare-function drgnx-face-glyph "drgnx-face")

(defconst drgnx-inbox-buffer-name "*drgnx inbox*" "The inbox's buffer, in the card's frame or the side bar's tab.")

(defconst drgnx-inbox-width 360 "The drop-down's width, logical pixels.")
(defconst drgnx-inbox-max-height 420 "The drop-down's height at most, logical pixels; its rows scroll past it.")

(defconst drgnx-inbox-kinds
  '((permission ("inbox-allow-once" "Allow once") ("inbox-allow-session" "Always for this session") ("inbox-deny" "Deny"))
    (other ("inbox-show" "Show")))
  "The buttons of each kind of item: (KIND (REGISTRY-ID LABEL)...).  The first button is what Enter presses.")

;;;; State

(defvar drgnx-inbox--answered nil "Answered rows of this session, newest first: (ITEM . LABEL).  Shown in the tab only.")
(defvar drgnx-inbox--read nil "Ids of the items `Mark all read' faded.")
(defvar drgnx-inbox--frame nil "The drop-down's child frame while it shows.")
(defvar drgnx-inbox--target nil "The item key a button was pressed on, while its command runs.")
(defvar-local drgnx-inbox--selected nil "The key of the selected row.")
(defvar drgnx-inbox--pinned :unread "Whether the inbox is pinned as a side bar: t, nil, or :unread before the state file is read.")

(defun drgnx-inbox--state-file () (expand-file-name "inbox.eld" (drgnx-state-dir)))

(defun drgnx-inbox-pinned-p ()
  "Non-nil when the inbox was last pinned as a side bar (state/inbox.eld)."
  (when (eq drgnx-inbox--pinned :unread)
    (setq drgnx-inbox--pinned (and (plist-get (plist-get (drgnx-file-read (drgnx-inbox--state-file)) :data) :pinned) t)))
  drgnx-inbox--pinned)

(defun drgnx-inbox--set-pinned (value)
  "Remember VALUE (pinned or not).  A state folder that cannot be written loses the choice, never the pin."
  (setq drgnx-inbox--pinned (and value t))
  (condition-case nil (drgnx-file-write (drgnx-inbox--state-file) (list :pinned drgnx-inbox--pinned))
    (file-error nil)))

;;;; The rows

(defun drgnx-inbox--kind (item)
  "The kind of notice ITEM: `permission' (its id is (permission SESSION . REQUEST)), else `other'."
  (if (eq (car-safe (plist-get item :id)) 'permission) 'permission 'other))

(defun drgnx-inbox--rows ()
  "The rows: ((ITEM . ANSWER)...), what waits newest first, then (in the tab) the answered ones, ANSWER a label or nil."
  (append (mapcar #'list (drgnx-needs-you-items))
          (and (drgnx-inbox-pinned-p) (mapcar (lambda (a) (cons (car a) (cdr a))) drgnx-inbox--answered))))

(defun drgnx-inbox--key (item) (plist-get item :id))

(defun drgnx-inbox--waiting-item (key)
  "The waiting item whose id is KEY, or nil."
  (seq-find (lambda (i) (equal (plist-get i :id) key)) (drgnx-needs-you-items)))

(defun drgnx-inbox--item-now ()
  "The item a command acts on: the one a button was pressed on, else the selected row's, else the first waiting."
  (or (and drgnx-inbox--target (drgnx-inbox--waiting-item drgnx-inbox--target))
      (and drgnx-inbox--selected (drgnx-inbox--waiting-item drgnx-inbox--selected))
      (car (drgnx-needs-you-items))
      (user-error "Nothing needs you")))

;;;; Drawing

(defun drgnx-inbox--press (id key)
  "Run registry command ID for the row KEY (what that row's button is)."
  (let ((drgnx-inbox--target key)) (drgnx-surfaces-run (intern id))))

(defun drgnx-inbox--button (id label key &optional primary)
  "The button LABEL of row KEY running registry command ID."
  (drgnx-ui-button label (lambda () (drgnx-inbox--press id key)) :face (and primary 'drgnx-ui-button-primary)))

(defun drgnx-inbox--header ()
  "The header: `Needs you' at the left, the buttons at the right end of the line."
  (let* ((buttons (if (drgnx-inbox-pinned-p)
                      (concat (drgnx-ui-button "Clear answered" (lambda () (drgnx-inbox--press "inbox-clear-answered" nil)))
                              " " (drgnx-ui-button "Unpin" (lambda () (drgnx-inbox--press "inbox-unpin" nil))))
                    (concat (drgnx-ui-button "Mark all read" (lambda () (drgnx-inbox--press "inbox-mark-all-read" nil)))
                            " " (drgnx-ui-button "⇱ Pin as side bar" (lambda () (drgnx-inbox--press "inbox-pin" nil))))))
         (room (+ (string-pixel-width buttons) (drgnx-px 8))))
    (concat (propertize " Needs you" 'face 'bold)
            (propertize " " 'display `(space :align-to (- right (,room))))
            buttons)))

(defun drgnx-inbox--row (item answer)
  "The text of the row for ITEM: dot, title and its source (muted, after a ·), the detail lines (the command or file, in
the code font) and its kind's buttons, the first one primary; ANSWER, a label, when it was answered."
  (let* ((key (drgnx-inbox--key item)) (lines (split-string (or (plist-get item :text) "") "\n"))
         (faded (or answer (member key drgnx-inbox--read)))
         (title (propertize (truncate-string-to-width (car lines) 44 nil nil "…") 'face (if faded 'drgnx-text-muted 'drgnx-ui-text)))
         (source (propertize (format " · %s" (or (plist-get item :source) (car-safe key) "")) 'face 'drgnx-text-subtle))
         (more (or (plist-get item :detail) (and (cdr lines) (string-join (cdr lines) " "))))
         (detail (and more (propertize (truncate-string-to-width more 52 nil nil "…")
                                       'face '(drgnx-code-small drgnx-text-subtle))))
         (buttons (if answer
                      (propertize (format "%s" answer) 'face 'drgnx-text-subtle)
                    (string-join (cl-loop for (id label) in (cdr (assq (drgnx-inbox--kind item) drgnx-inbox-kinds))
                                          for first = t then nil
                                          collect (drgnx-inbox--button id label key first))
                                 " "))))
    (propertize (concat (propertize "● " 'face (if faded 'drgnx-text-subtle 'drgnx-status-needs-you)) title source "\n"
                        (and detail (concat "  " detail "\n"))
                        "  " buttons "\n")
                'drgnx-inbox-key key)))

(defun drgnx-inbox--render ()
  "Draw the inbox in its buffer, keeping the selected row (else the first)."
  (with-current-buffer (get-buffer-create drgnx-inbox-buffer-name)
    (unless (derived-mode-p 'drgnx-inbox-mode) (drgnx-inbox-mode))
    (let* ((inhibit-read-only t) (rows (drgnx-inbox--rows))
           (waiting (seq-remove #'cdr rows)))
      (unless (seq-find (lambda (r) (equal (drgnx-inbox--key (car r)) drgnx-inbox--selected)) waiting)
        (setq drgnx-inbox--selected (and waiting (drgnx-inbox--key (car (car waiting))))))
      (erase-buffer)
      (insert (drgnx-inbox--header) "\n\n")
      (if (null rows)
          (insert (propertize "  Nothing needs you.\n" 'face 'drgnx-text-muted))
        (dolist (r rows) (insert (drgnx-inbox--row (car r) (cdr r)) "\n")))
      (insert (drgnx-ui-button "All notices →" (lambda () (drgnx-inbox--press "inbox-all-notices" nil))) "\n")
      (drgnx-inbox--mark-selection)
      (goto-char (point-min)))
    (current-buffer)))

(defvar-local drgnx-inbox--overlay nil)

(defun drgnx-inbox--mark-selection ()
  "Tint the selected row (an inset soft tint: the selection's own face)."
  (when (overlayp drgnx-inbox--overlay) (delete-overlay drgnx-inbox--overlay))
  (when drgnx-inbox--selected
    (let ((at (point-min)) found)
      (while (and (not found) at (< at (point-max)))   ; the key is a list: `equal', not `eq'
        (let ((end (or (next-single-property-change at 'drgnx-inbox-key) (point-max))))
          (if (equal (get-text-property at 'drgnx-inbox-key) drgnx-inbox--selected)
              (setq found (cons at end))
            (setq at end))))
      (when found
        ;; the title and detail lines only: the tint under the buttons would hide the primary one's fill
        (setq drgnx-inbox--overlay
              (make-overlay (car found) (save-excursion (goto-char (cdr found)) (forward-line -1) (point))))
        (overlay-put drgnx-inbox--overlay 'face 'drgnx-selected-quiet)))))

(defun drgnx-inbox--buffer ()
  "The pane kind `inbox''s buffer: the inbox drawn now."
  (drgnx-inbox--render))

(defun drgnx-inbox--changed (&rest _)
  "On `drgnx-notice-functions': draw the inbox again while it shows (a card or the tab); fit the card."
  (when (and (get-buffer drgnx-inbox-buffer-name)
             (or (frame-live-p drgnx-inbox--frame) (and (fboundp 'drgnx-pane-window) (drgnx-pane-window 'inbox))))
    (drgnx-inbox--render)
    (drgnx-inbox--fit)))

;;;; The drop-down

(defun drgnx-inbox--params (parent)
  "The card's frame parameters under PARENT: the modal chrome, no focus taken by the window manager's rules."
  `((parent-frame . ,parent) (minibuffer . nil) (name . "drgnx-inbox")
    (undecorated . t) (no-other-frame . t) (skip-taskbar . t) (unsplittable . t) (no-special-glyphs . t)
    (desktop-dont-save . t) (border-width . 0) (internal-border-width . ,(drgnx-px 8 parent))
    (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
    (left-fringe . 0) (right-fringe . 0) (vertical-scroll-bars) (horizontal-scroll-bars) (visibility . nil)
    ,@(seq-remove (lambda (p) (eq (car p) 'transition)) (drgnx-palette-frame-modal-chrome parent))))

(defun drgnx-inbox--fit ()
  "Size the card to its rows (to `drgnx-inbox-max-height'), its right edge under the pill's right edge."
  (when-let* ((frame drgnx-inbox--frame) ((frame-live-p frame)) (win (frame-root-window frame))
              (parent (frame-parent frame)))
    (let* ((width (drgnx-px drgnx-inbox-width parent)) (frame-resize-pixelwise t) (window-min-height 1) (window-min-width 1)
           (text (cdr (window-text-pixel-size win nil nil width 10000)))
           (height (min (+ text (frame-char-height frame) (* 2 (frame-internal-border-width frame))) (drgnx-px drgnx-inbox-max-height parent)))
           (span (and (fboundp 'drgnx-topline-item-span) (with-selected-frame parent (drgnx-topline-item-span 'drgnx-topline-attention))))
           (right (if span (cdr span) (frame-pixel-width parent)))
           (x (max 0 (min (- right width) (- (frame-pixel-width parent) width)))))
      (set-frame-size frame width height t)
      (set-frame-position frame x (+ (tab-bar-height parent t) (frame-internal-border-width parent) (drgnx-px 4 parent))))))

(defun drgnx-inbox--close-on-outside (_frame)
  "On `window-selection-change-functions': a click outside the card closes it."
  (when (and (frame-live-p drgnx-inbox--frame) (not (eq (selected-frame) drgnx-inbox--frame))
             (not (eq (window-frame (minibuffer-selected-window)) drgnx-inbox--frame)))
    (drgnx-inbox-close)))

(defun drgnx-inbox-close ()
  "Close the drop-down."
  (interactive)
  (remove-hook 'window-selection-change-functions #'drgnx-inbox--close-on-outside)
  (when (frame-live-p drgnx-inbox--frame)
    (let ((frame drgnx-inbox--frame) (parent (frame-parent drgnx-inbox--frame)))
      (setq drgnx-inbox--frame nil)
      (delete-frame frame t)
      (when (frame-live-p parent) (select-frame-set-input-focus parent)))))

(defun drgnx-inbox--show-card ()
  "Show the drop-down under the pill and give it the keys."
  (let* ((parent (selected-frame)) (buffer (drgnx-inbox--render))
         (frame (let ((after-make-frame-functions nil) (before-make-frame-hook nil))
                  (make-frame (drgnx-inbox--params parent)))))
    (setq drgnx-inbox--frame frame)
    (set-face-attribute 'fringe frame :background (face-background 'drgnx-surface-raised nil t))
    (with-current-buffer buffer
      (setq-local mode-line-format nil header-line-format nil tab-line-format nil truncate-lines t cursor-type nil)
      (face-remap-add-relative 'default 'drgnx-ui-text 'drgnx-surface-raised))
    (set-window-buffer (frame-root-window frame) buffer)
    (set-window-dedicated-p (frame-root-window frame) t)
    (drgnx-inbox--fit)
    (make-frame-visible frame)
    (select-frame-set-input-focus frame)
    (add-hook 'window-selection-change-functions #'drgnx-inbox--close-on-outside)))

;;;; The mode and its commands

(defvar drgnx-inbox-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [down-mouse-1] #'ignore)   ; a press selects no text: only a button's release (mouse-1) does anything
    m)
  "The inbox's keys, from the key profiles (`inbox-next', `inbox-previous', `inbox-press', `inbox-escape'): Up and Down
move, Enter presses the row's first button, Esc closes the card.")

(define-derived-mode drgnx-inbox-mode special-mode "Inbox"
  "The needs-you inbox (`drgnx-inbox-open')."
  (setq-local buffer-undo-list t cursor-type nil))

(defun drgnx-inbox--move (n)
  "Select the waiting row N places on."
  (let* ((keys (mapcar (lambda (i) (drgnx-inbox--key i)) (drgnx-needs-you-items)))
         (at (or (cl-position drgnx-inbox--selected keys :test #'equal) -1)))
    (when keys
      (setq drgnx-inbox--selected (nth (mod (+ at n) (length keys)) keys))
      (drgnx-inbox--mark-selection))))

(defun drgnx-inbox-next () "Select the next row." (interactive) (drgnx-inbox--move 1))
(defun drgnx-inbox-previous () "Select the previous row." (interactive) (drgnx-inbox--move -1))

(defun drgnx-inbox-press ()
  "Press the selected row's first button."
  (interactive)
  (let* ((item (or (and drgnx-inbox--selected (drgnx-inbox--waiting-item drgnx-inbox--selected)) (user-error "Nothing needs you")))
         (id (car (cadr (assq (drgnx-inbox--kind item) drgnx-inbox-kinds)))))
    (drgnx-inbox--press id (drgnx-inbox--key item))))

(defun drgnx-inbox-escape ()
  "Close the drop-down; in the tab, give the focus back to the editor."
  (interactive)
  (if (frame-live-p drgnx-inbox--frame) (drgnx-inbox-close)
    (when (fboundp 'drgnx-state-editor-window) (when-let* ((w (drgnx-state-editor-window))) (select-window w)))))

(defun drgnx-inbox--option (permission kinds)
  "The option id of PERMISSION (a session's pending request) whose kind is one of KINDS, or nil."
  (seq-some (lambda (o) (and (member (format "%s" (plist-get o :kind)) kinds) (plist-get o :optionId)))
            (append (plist-get permission :options) nil)))

(defun drgnx-inbox--answer (kinds fallback label)
  "Answer the permission ask of the row with the option of one of KINDS (else of FALLBACK), as the agent panel's card
does (`drgnx-agents-answer-permission'); the row goes at once, and stays faded with LABEL in the tab."
  (let* ((item (drgnx-inbox--item-now)) (id (plist-get item :id)))
    (unless (eq (drgnx-inbox--kind item) 'permission) (user-error "That is not a permission ask"))
    (let* ((s (or (drgnx-agents-get (cadr id)) (user-error "The agent is gone")))
           (p (or (seq-find (lambda (p) (equal (plist-get p :id) (cddr id))) (drgnx-agent-session-permissions s))
                  (user-error "The ask was answered already"))))
      (drgnx-agents-answer-permission s p (or (drgnx-inbox--option p kinds) (and fallback (drgnx-inbox--option p fallback))))
      (push (cons item label) drgnx-inbox--answered)
      (drgnx-inbox--changed))))

(defun drgnx-inbox-allow-once () "Allow what the agent asks, this once." (interactive)
       (drgnx-inbox--answer '("allow_once" "allow") nil "Allowed once"))
(defun drgnx-inbox-allow-session () "Allow what the agent asks, and requests like it for this session." (interactive)
       (drgnx-inbox--answer '("allow_always") '("allow_once" "allow") "Allowed for this session"))
(defun drgnx-inbox-deny () "Refuse what the agent asks." (interactive)
       (drgnx-inbox--answer '("reject_once" "reject_always") nil "Denied"))

(defun drgnx-inbox-show ()
  "Do what the pill's click did for the row: run the item's own command; the card closes."
  (interactive)
  (let ((item (drgnx-inbox--item-now)))
    (drgnx-inbox-close)
    (when-let* ((cmd (plist-get item :command)))
      (drgnx-ui-kit-run (if (consp cmd) (lambda () (apply (car cmd) (cdr cmd))) cmd)))))

(defun drgnx-inbox-mark-all-read () "Fade every item now waiting." (interactive)
       (setq drgnx-inbox--read (mapcar #'drgnx-inbox--key (drgnx-needs-you-items)))
       (drgnx-inbox--changed))

(defun drgnx-inbox-clear-answered () "Forget the answered rows of the tab." (interactive)
       (setq drgnx-inbox--answered nil)
       (drgnx-inbox--changed))

(defun drgnx-inbox-all-notices () "Open the Notices list." (interactive)
       (drgnx-inbox-close)
       (drgnx-notices-show))

(defun drgnx-inbox-pin ()
  "Pin the inbox as a tab of the right side bar: the drop-down closes, the tab opens, and the pill shows the tab."
  (interactive)
  (drgnx-inbox--set-pinned t)
  (drgnx-inbox-close)
  (drgnx-pane-show 'inbox :select t))

(defun drgnx-inbox-unpin ()
  "Unpin the inbox: the tab goes and the pill opens the drop-down again."
  (interactive)
  (drgnx-inbox--set-pinned nil)
  (setq drgnx-inbox--answered nil)
  (drgnx-pane-hide 'inbox)
  (drgnx-inbox-open))

(defun drgnx-inbox-open ()
  "Show what needs you: the tab in the right side bar when it is pinned (and always on a terminal), else the drop-down
under the title row's pill; with the drop-down open, close it."
  (interactive)
  (cond ((frame-live-p drgnx-inbox--frame) (drgnx-inbox-close))
        ((or (drgnx-inbox-pinned-p) (not (display-graphic-p)))
         (drgnx-inbox--render)
         (drgnx-pane-show 'inbox :select t))
        (t (drgnx-inbox--show-card))))

;;;; Setup

(defconst drgnx-inbox--commands
  '((inbox-open "Show What Needs You" drgnx-inbox-open "Open the inbox: a drop-down under the pill, or its tab in the right side bar once pinned" nil)
    (inbox-pin "Pin the Inbox as a Side Bar" drgnx-inbox-pin "Move the inbox into a tab of the right side bar" nil)
    (inbox-unpin "Unpin the Inbox" drgnx-inbox-unpin "Back to the drop-down" nil)
    (inbox-allow-once "Inbox: Allow Once" drgnx-inbox-allow-once "Allow what the agent asks, this once" t)
    (inbox-allow-session "Inbox: Always for This Session" drgnx-inbox-allow-session "Allow what the agent asks, and requests like it, for this session" t)
    (inbox-deny "Inbox: Deny" drgnx-inbox-deny "Refuse what the agent asks" t)
    (inbox-show "Inbox: Show" drgnx-inbox-show "Go to what the item is about" t)
    (inbox-mark-all-read "Inbox: Mark All Read" drgnx-inbox-mark-all-read "Fade the items now waiting" t)
    (inbox-clear-answered "Inbox: Clear Answered" drgnx-inbox-clear-answered "Forget the answered rows of the tab" t)
    (inbox-all-notices "Inbox: All Notices" drgnx-inbox-all-notices "Open the Notices list" t))
  "The inbox's registry commands: (ID TITLE FUNCTION DOC IN-MODE).")

(defun drgnx-inbox-setup ()
  "The inbox's commands, pane kind and hook (called by the module ui/face; `drgnx-inbox-off' undoes them)."
  (pcase-dolist (`(,id ,title ,fn ,doc ,in-mode) drgnx-inbox--commands)
    (apply #'drgnx-command-define id :category "Inbox" :title title :command fn :doc doc
           (and in-mode (list :map 'drgnx-inbox-mode-map))))
  (when (fboundp 'drgnx-pane-define-kind)
    (drgnx-pane-define-kind 'inbox :title " INBOX" :home 'right :buffer #'drgnx-inbox--buffer))
  (add-hook 'drgnx-notice-functions #'drgnx-inbox--changed))

(defun drgnx-inbox-off ()
  "The module's teardown: the card goes, the hook goes; the state stays."
  (drgnx-inbox-close)
  (remove-hook 'drgnx-notice-functions #'drgnx-inbox--changed)
  (setq drgnx-inbox--pinned :unread drgnx-inbox--answered nil drgnx-inbox--read nil)
  (when (get-buffer drgnx-inbox-buffer-name) (kill-buffer drgnx-inbox-buffer-name)))

(provide 'drgnx-inbox)
;;; drgnx-inbox.el ends here
