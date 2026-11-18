;;; drgnx-topline.el --- The top line: where you are, and the three keys that open everything -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part A of M12f, redone for the title-bar design (docs/specs/drgnx/2026-11-16-title-bar-inbox-design.md, option B).  A
;; quiet line at the top of the frame, built on `tab-bar-mode' with no tabs (drgnx has no workspaces): the logo, the ☰
;; button (every menu as one list), the project switcher (the project of the most recently used editor, a chevron), the
;; search box in the middle (Quick Open), the `N need you' pill (it opens the inbox, drgnx-inbox.el), the three layout
;; toggles (primary side bar, panel, secondary side bar: the icon is filled while its part shows) and, only when drgnx
;; draws the title itself (`drgnx-face-drawn-title-p'), `– ▢ ✕' with the empty area dragging the frame.  A terminal's
;; row is the same in text (`☰  name ▾  [Ctrl P search]  ● 2 need you  ◧ ▬ ◨').  In a narrow window the search box shrinks
;; first, then the project's name is cut with an ellipsis; the rest never hides.
;;
;; The tab bar calls the format on its redisplay, so `drgnx-topline--line' reads cached state only: the project root in
;; the buffer-local cache the breadcrumb keeps (`drgnx-chrome--root'; no file or process access, a miss shows `drgnx'), the keys the registry already resolved.
;; The cache is filled off redisplay, from the change bus's `editor-changed' edge (never for a remote directory).
;; The editor is the workbench state store's (`drgnx-state-editor-window'); a frame resize reaches the line as the
;; store's `frame-resized' event (a redraw request, on the `now' lane), and a new or resized frame gets its number of
;; lines decided on the `idle' lane (that may resize windows).
;; What the line makes is memoized per frame (the memo `topline', docs/develop/core.md "Memo clients") on what it
;; shows: the editor buffer, its directory, file and cached project, the frame's width, the keys, the glyph forms and which
;; layout toggles are on, so a redisplay that changes nothing costs a few comparisons and reads no cache.  An error while making it never
;; escapes: the line shows its mark alone for a few seconds (an empty tab bar is taken away by Emacs, which resizes
;; every window), and nothing here then touches the frames.  A timer (`topline-retry') then ends the failure and
;; redraws every tab bar, so an idle frame needs no command.
;; Only terminal frames get their number of lines decided here (a graphical frame has one, from `tab-bar-mode'),
;; and a decision is made once, never repeated against what redisplay has done since.  A tab-bar format of your
;; own, or a tab bar that was on before this module, is never replaced.  See docs/guide/face.md ("The top line").

;;; Code:
(require 'subr-x)
(require 'tab-bar)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-state)
(require 'drgnx-memo)
(require 'drgnx-pixels)
(require 'drgnx-faces)                  ; the chip faces, `drgnx-face-color'
(require 'drgnx-type-faces)
(require 'drgnx-icons)
(declare-function drgnx-palette-keycap-names "drgnx-palette")
(declare-function nidhogg-view-bar "nidhogg-views" (spec))   ; loaded by drgnx-statusbar.el
(declare-function glitnir-active-p "glitnir")
(declare-function drgnx-menubar-title-items "drgnx-menubar" (room &optional measure))
(declare-function drgnx-menubar-note-click "drgnx-menubar" (key x frame))
(declare-function drgnx-face-glyph "drgnx-face")
(declare-function drgnx-menubar-pick "drgnx-menubar")
(declare-function drgnx-session-recent-folders "drgnx-session")
(declare-function drgnx-session-open-folder "drgnx-session" (dir))
(declare-function drgnx-explorer-roots "drgnx-explorer")
(declare-function drgnx-explorer-set-roots "drgnx-explorer" (roots))
(declare-function drgnx-look-pixel-width "drgnx-look-fonts" (text face))
(declare-function drgnx-face-drawn-title-p "drgnx-face")
(declare-function drgnx-surfaces-key-label "drgnx-surfaces")
(defvar drgnx-surfaces-starter-commands)
(declare-function drgnx-signal-editor-window "drgnx-signal")
(declare-function drgnx-chrome--project-root "drgnx-chrome")
(declare-function drgnx-signal-subscribe "drgnx-signal")
(declare-function drgnx-state-frame-kind "drgnx-frame-kind")
(declare-function drgnx-signal-unsubscribe "drgnx-signal")
(defvar drgnx-notice--needs-you)
(declare-function drgnx-statusbar--measure-fn "drgnx-statusbar")
(declare-function drgnx-statusbar--layout-key "drgnx-statusbar")
(defvar drgnx-look-bars-measure-function)
(defvar vc-mode)
(defvar drgnx-chrome--root)
(defvar drgnx-face-glyphs)

(defgroup drgnx-topline nil
  "The top line: project and branch, the keys that open everything, window controls."
  :group 'drgnx-face :prefix "drgnx-topline-")

(defface drgnx-topline '((t :inherit (shadow tab-bar) :height 1.0 :box nil))
  "The title row's quiet text (labels, separators, the empty area), on the tab bar's background: the gap (§4)."
  :group 'drgnx-topline)

(defface drgnx-topline-hover '((t :inherit drgnx-hover :box nil))
  "A window control under the mouse: the hover colour, seen only through the control's round hole (no box)."
  :group 'drgnx-topline)

(defface drgnx-topline-strong '((t :inherit (bold tab-bar) :height 1.0 :box nil))
  "The project and the keys on the title row: the text colour of the theme (not the tab bar's dim one); drgnx's
themes give it the heading role."
  :group 'drgnx-topline)

(defvar drgnx-topline--active nil
  "Non-nil once the module has run: from then on a setting applies to the open frames when it changes.")

(defun drgnx-topline--set (symbol value)
  "Set SYMBOL to VALUE; when the module is running, apply it to every open frame."
  (set-default symbol value)
  (when drgnx-topline--active (drgnx-topline--apply)))

(defcustom drgnx-topline t
  "Show the top line (project and branch, the keys that open everything).
A tab-bar format you set yourself is never replaced: then the line stays off."
  :type 'boolean :set #'drgnx-topline--set :group 'drgnx-topline)

(defcustom drgnx-topline-min-lines 20
  "A terminal frame with fewer lines than this shows no top line (windows always show it)."
  :type 'natnum :set #'drgnx-topline--set :group 'drgnx-topline)

;;;; What the line shows

(defun drgnx-topline--glyph (name ascii)
  "The glyph NAME for the selected frame (see `drgnx-face-glyph'); ASCII when it is not known."
  (or (and (fboundp 'drgnx-face-glyph) (drgnx-face-glyph name)) ascii))

(defun drgnx-topline--project (buffer)
  "The name of BUFFER's project (the folder of its root), or nil.  Reads the breadcrumb's buffer-local cache
\(`drgnx-chrome--root') and nothing else: no project lookup, so no file access, from redisplay."
  (when (boundp 'drgnx-chrome--root)
    (let ((cache (buffer-local-value 'drgnx-chrome--root buffer)))
      (when (and (consp cache) (stringp (cdr cache))
                 (equal (car cache) (buffer-local-value 'default-directory buffer)))
        (file-name-nondirectory (directory-file-name (cdr cache)))))))

(defun drgnx-topline--note-editor (&optional buffer)
  "Fill BUFFER's (default: the editor's) project cache, so the line can show its project.
On the change bus's `editor-changed' edge (idle, never redisplay); never for a remote directory.  Redraws the line
when the cache changed."
  (let ((buffer (or buffer (and (fboundp 'drgnx-signal-editor-window)
                                (let ((w (drgnx-signal-editor-window))) (and (window-live-p w) (window-buffer w)))))))
    (when (and (buffer-live-p buffer) (fboundp 'drgnx-chrome--project-root))
      (with-current-buffer buffer
        (unless (file-remote-p default-directory)
          (let ((before (and (boundp 'drgnx-chrome--root) drgnx-chrome--root)))
            (drgnx-chrome--project-root (or (buffer-file-name) default-directory))
            (unless (equal before drgnx-chrome--root) (force-mode-line-update t))))))))

(defun drgnx-topline--drawn-title-p (frame)
  "Non-nil when drgnx draws FRAME's title itself (A2's `drgnx-face-drawn-title-p'; until it exists, never)."
  (and (fboundp 'drgnx-face-drawn-title-p) (drgnx-face-drawn-title-p frame)))

(defun drgnx-topline--text (text face)
  "TEXT in FACE."
  (propertize text 'face face))

(defun drgnx-topline--item (key text &optional command help)
  "A tab-bar item named KEY showing TEXT; a click runs COMMAND (a symbol) and rests on HELP."
  `(,key menu-item ,text ,(if (and command (symbolp command)) command 'ignore) :help ,(or help "")))

(defun drgnx-topline--gap (key columns drag)
  "An item of COLUMNS spaces; with DRAG, pressing it drags the frame (a drawn title).
Real spaces, not an `:align-to' display property on one: the tab bar redraws only when its items are not `equal',
and `equal' ignores text properties, so a new width would have left the old gap on the screen."
  (drgnx-topline--item key (propertize (make-string (max 0 columns) ?\s) 'face 'drgnx-topline)
                       (and drag 'drgnx-topline-drag-window) (and drag "Drag to move the window")))

(defvar drgnx-topline-agents-function nil
  "A function with no arguments that gives the number of agents at work, or nil: the title row's agents chip shows
that number when it is positive.  The agents module sets it; the row reads it on redisplay, so it must be cheap.")

(defun drgnx-topline--attention-count ()
  "How many things wait on you (the notice model's count).  A memo key: reads a variable."
  (if (boundp 'drgnx-notice--needs-you) drgnx-notice--needs-you 0))

(defun drgnx-topline--attention-command ()
  "What a click on the `N need you' pill runs: the inbox (drgnx-inbox.el); the old newest-item click without it."
  (cond ((fboundp 'drgnx-inbox-open) 'drgnx-inbox-open)
        ((fboundp 'drgnx-notice-needs-you-click) 'drgnx-notice-needs-you-click)))

(defun drgnx-topline--agents-count ()
  "How many agents work (`drgnx-topline-agents-function'), 0 without one.  A memo key."
  (if drgnx-topline-agents-function (or (funcall drgnx-topline-agents-function) 0) 0))

(defvar drgnx-topline-paused-function nil
  "A function with no arguments, non-nil while a debug session is paused: the title row shows its Paused chip (a click
goes to the stopped line).  The debug module sets it; the row reads it on redisplay, so it must be cheap.")

(defun drgnx-topline--paused-p ()
  "Non-nil while `drgnx-topline-paused-function' says a debug session is paused.  A memo key."
  (and drgnx-topline-paused-function (funcall drgnx-topline-paused-function) t))

(defconst drgnx-topline--paused-help "A debug session is paused: click for the stopped line")

(defun drgnx-topline--chips ()
  "The chips at the right of the row: Paused (a debug session stopped; it goes to the line), `N needs you' (it opens
what waits) and the agents at work, each only while its count is positive."
  (let ((need (drgnx-topline--attention-count)) (agents (drgnx-topline--agents-count)))
    (append
     (when (drgnx-topline--paused-p)
       (list (drgnx-topline--item 'drgnx-topline-paused (propertize " Paused " 'face 'drgnx-status-warn)
                                  (and (fboundp 'drgnx-debug-toolbar-show-stop) 'drgnx-debug-toolbar-show-stop)
                                  drgnx-topline--paused-help)))
     (when (> need 0)
       (list (drgnx-topline--item 'drgnx-topline-attention
                                  (propertize (format " %d %s you " need (if (= need 1) "needs" "need")) 'face 'drgnx-status-needs-you)
                                  (drgnx-topline--attention-command)
                                  "Waiting on you: click for the inbox")))
     (when (> agents 0)
       (list (drgnx-topline--item 'drgnx-topline-agents
                                  (drgnx-topline--text (format " %d %s " agents (if (= agents 1) "agent" "agents"))
                                                       'drgnx-topline-strong)
                                  (and (fboundp 'drgnx-agent-panel-list-show) 'drgnx-agent-panel-list-show)
                                  "Agents at work"))))))

(defun drgnx-topline--item-at-column (column)
  "The title row's item whose columns hold COLUMN on a terminal, or nil."
  (let ((at 0) hit)
    (dolist (item (drgnx-topline--line))
      (let ((w (string-width (nth 2 item))))
        (when (and (not hit) (>= column at) (< column (+ at w))) (setq hit item))
        (setq at (+ at w))))
    hit))

(defun drgnx-topline--event-item (event)
  "The title row's item under mouse EVENT: the one its position's caption names (the `menu-item' Emacs's tab bar, and
Nidhogg's native shell, attach to a tab-bar click), or nil.  A terminal's tab-bar click carries no caption: its item is
the one whose columns hold the click's column."
  (let* ((posn (event-start event))
         (key (car-safe (and (car-safe (posn-string posn))
                             (get-text-property (or (cdr (posn-string posn)) 0) 'menu-item (car (posn-string posn)))))))
    (cond (key (assq key (drgnx-topline--line)))
          ((and (not (display-graphic-p)) (eq (posn-area posn) 'tab-bar) (integerp (car (posn-x-y posn))))
           (drgnx-topline--item-at-column (car (posn-x-y posn)))))))

(defun drgnx-topline-mouse-down (event)
  "A press on the title row (EVENT): on its empty part it drags the window; on an item the release decides."
  (interactive "e")
  (when (eq (nth 3 (drgnx-topline--event-item event)) 'drgnx-topline-drag-window)
    (drgnx-topline-drag-window event)))

(defun drgnx-topline-drag-window (event)
  "Move the window by dragging the title row's empty part from the press EVENT (`title-row-drag').
`mouse-drag-frame-move' is a function, not a command: the tab bar calls an item's binding interactively."
  (interactive "e")
  (when (fboundp 'mouse-drag-frame-move) (mouse-drag-frame-move event)))

(defun drgnx-topline-mouse-up (event)
  "A release on the title row (EVENT): run the command of the item under it, as a button does."
  (interactive "e")
  (let* ((item (drgnx-topline--event-item event)) (cmd (nth 3 item)))
    (when (and item (fboundp 'drgnx-menubar-note-click))   ; a menu's title: its menu opens under its left edge
      (let* ((posn (event-start event)) (str (posn-string posn)))
        (drgnx-menubar-note-click (car item)
                                  (max 0 (- (or (car (posn-x-y posn)) 0)
                                            (if (and (consp str) (stringp (car str)) (integerp (cdr str)))
                                                (string-pixel-width (substring (car str) 0 (cdr str)))
                                              0)))
                                  (let ((w (posn-window posn)))   ; a tab-bar click's is the frame
                                    (cond ((framep w) w) ((windowp w) (window-frame w)) (t (selected-frame)))))))
    (unless (memq cmd '(nil ignore drgnx-topline-drag-window))
      (call-interactively cmd))))

(defconst drgnx-topline--project-actions
  '(("Open Folder…" . open-folder) ("Add Folder to Workspace…" . explorer-add-folder) ("Close Folder" . title-row-close-folder))
  "The project switcher's rows after the recent folders: (TITLE . REGISTRY-ID).")

(defun drgnx-topline-project-candidates ()
  "The project switcher's rows: the recent folders (`drgnx-session-recent-folders'), then the three actions."
  (append (and (fboundp 'drgnx-session-recent-folders) (drgnx-session-recent-folders))
          (mapcar #'car drgnx-topline--project-actions)))

(defun drgnx-topline-project-switch ()
  "Choose a recent folder to open, or Open Folder…, Add Folder to Workspace…, Close Folder, in the palette's frame."
  (interactive)
  (let* ((cands (drgnx-topline-project-candidates)) (recent (seq-remove (lambda (c) (assoc c drgnx-topline--project-actions)) cands))
         (choice (completing-read
                  "Project: "
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        '(metadata (category . drgnx-folder) (display-sort-function . identity) (cycle-sort-function . identity))
                      (complete-with-action action cands string pred))))))
    (if-let* ((act (assoc choice drgnx-topline--project-actions)))
        (call-interactively (drgnx-cmd-command (drgnx-commands-get (cdr act))))
      (when (member choice recent) (drgnx-session-open-folder choice)))))

(defun drgnx-topline-close-folder ()
  "Remove the project's folder from the Explorer (Close Folder): the Explorer's root of the editor's project, else its
last folder.  Nothing on disk changes."
  (interactive)
  (unless (fboundp 'drgnx-explorer-set-roots) (user-error "No Explorer"))
  (let* ((roots (drgnx-explorer-roots)) (buffer (current-buffer))
         (dir (and (boundp 'drgnx-chrome--root) (consp (buffer-local-value 'drgnx-chrome--root buffer))
                   (cdr (buffer-local-value 'drgnx-chrome--root buffer))))
         (root (or (and (stringp dir) (car (member (file-name-as-directory dir) roots))) (car (last roots)))))
    (unless root (user-error "No folder is open"))
    (drgnx-explorer-set-roots (remove root roots))))

(defun drgnx-topline-toggle-maximized ()
  "Maximise the selected frame, or restore it (a double click on the title row's empty space)."
  (interactive)
  (toggle-frame-maximized))

(defun drgnx-topline--controls ()
  "The window controls' items: minimise, maximise, close."
  (list (drgnx-topline--item 'drgnx-topline-minimize
                             (drgnx-topline--text (concat " " (drgnx-topline--glyph 'minimize "-") " ") 'drgnx-topline-strong)
                             'iconify-frame "Minimise")
        (drgnx-topline--item 'drgnx-topline-maximize
                             (drgnx-topline--text (concat (drgnx-topline--glyph 'maximize "[]") " ") 'drgnx-topline-strong)
                             'toggle-frame-maximized "Maximise or restore")
        (drgnx-topline--item 'drgnx-topline-close
                             (drgnx-topline--text (concat (drgnx-topline--glyph 'close "x") " ") 'drgnx-topline-strong)
                             'delete-frame "Close the window")))

(defun drgnx-topline--width (items &optional measure)
  "The columns the tab-bar ITEMS take (their strings); with MEASURE, a function of a string, the units it gives."
  (let ((n 0))
    (dolist (i items)
      (setq n (+ n (cond ((and measure (plist-get (nthcdr 4 i) :drgnx-px)))   ; a gap knows its width
                         ((and measure (drgnx-topline--known-px (nth 2 i))))   ; so do images
                         (measure (funcall measure (nth 2 i)))
                         (t (string-width (nth 2 i)))))))
    n))

(defun drgnx-topline--pixel-gap (key pixels drag)
  "An item of PIXELS width.  Its PIXELS are also in the item (`:drgnx-px'): the tab bar redraws only when its items
are not `equal', and `equal' ignores the text properties the width is in."
  (append (drgnx-topline--item key (propertize " " 'face 'drgnx-topline 'display `(space :width (,(max 0 pixels))))
                               (and drag 'drgnx-topline-drag-window) (and drag "Drag to move the window"))
          (list :drgnx-px (max 0 pixels))))

;;;; The title row of a graphical frame (design §4, "The window frame"; mockup window-dark.png)
;; 38 px on the gap: the project's mark and name, the branch chip, the search box in the middle (it opens Quick Open,
;; `>' for commands; its key as a keycap), the attention and agents chips, the window controls.  Sizes are logical
;; pixels times the frame's scale.  The mark and the search box are SVG images made from the theme's faces (a gradient, and a field
;; with a hairline and a keycap inside, which text runs cannot draw); without SVG they are text.

(defconst drgnx-topline--search-size '(440 . 26) "The search box's width and height, logical pixels.")
(defconst drgnx-topline--search-least 120 "The least width the search box shrinks to before the project name is cut, logical pixels.")
(defvar drgnx-topline--search-width nil
  "The search box's width in logical pixels for the row being built (`drgnx-topline--fit-row'), nil for its full width,
0 for no box.  Bound by `drgnx-topline--build-pixels'.")
(defvar drgnx-topline--project-room nil
  "The device pixels the project switcher's name may take in the row being built, nil for all it needs.")
(defconst drgnx-topline--search-text "Search files, commands, symbols" "The search box's placeholder.")

(defun drgnx-topline--px (n)
  "N logical pixels on the selected frame, in its pixels (`drgnx-px': half up)."
  (drgnx-px n))

(defun drgnx-topline--space (n &optional face)
  "A space N logical pixels wide, in FACE."
  (let ((px (drgnx-topline--px n)))
    (propertize " " 'face (or face 'drgnx-topline) 'display `(space :width (,px)) 'drgnx-topline-px px)))

(defun drgnx-topline--svg-p ()
  "Non-nil when the selected frame shows SVG images."
  (and (display-graphic-p) (image-type-available-p 'svg)))

(defun drgnx-topline--color (face attr)
  "FACE's ATTR (`:foreground' or `:background') on the selected frame, or the SVG keyword \"currentColor\"."
  (or (drgnx-face-color face attr (selected-frame)) "currentColor"))

(defun drgnx-topline--image (svg text)
  "TEXT shown as the SVG image SVG (a string, logical pixels, with a `viewBox') on a frame that can, else as itself.
The image is sized in the frame's pixels by the pixel rule (`drgnx-px' of its width and height: a whole number, so
the row counts what is drawn; at 1.25 a 26 px control is 33, where an image scale would draw 32.5), and that width
is on it (`drgnx-topline-px'), for `drgnx-topline--known-px'."
  (if (and (drgnx-topline--svg-p) (string-match "width=\"\\([0-9]+\\)\" height=\"\\([0-9]+\\)\"" svg))
      (let ((w (drgnx-topline--px (string-to-number (match-string 1 svg))))
            (h (drgnx-topline--px (string-to-number (match-string 2 svg)))))
        ;; sized already: `:scale' 1, or Emacs takes `image-scaling-factor' (a guess from the font: 1.6 at scale 2)
        (propertize text 'display (create-image (replace-match (format "width=\"%d\" height=\"%d\"" w h) t t svg)
                                                'svg t :ascent 'center :scale 1)
                    'drgnx-topline-px w))
    text))

(defun drgnx-topline--known-px (string)
  "STRING's width in pixels when every part of it is an image or a space of known width (`drgnx-topline-px'), else nil.
A measure of an image is off by the text's slack; these widths are exact."
  (let ((pos 0) (n 0) (len (length string)))
    (while (and n (< pos len))
      (let ((px (get-text-property pos 'drgnx-topline-px string))
            (next (next-single-property-change pos 'drgnx-topline-px string len)))
        (setq n (and px (+ n px)) pos next)))
    n))

(defun drgnx-topline--mark-svg ()
  "The project mark: an 18 px square, radius 5, its colour running from the accent to the fifth agent colour."
  (format (concat "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"18\" height=\"18\" viewBox=\"0 0 18 18\">"
                  "<defs><linearGradient id=\"m\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\">"
                  "<stop offset=\"0\" stop-color=\"%s\"/><stop offset=\"1\" stop-color=\"%s\"/></linearGradient></defs>"
                  "<rect width=\"18\" height=\"18\" rx=\"5\" fill=\"url(#m)\"/></svg>")
          (drgnx-topline--color 'drgnx-accent :foreground) (drgnx-topline--color 'drgnx-agent-5 :foreground)))

(defun drgnx-topline--keycap (id)
  "The key of registry command ID as one keycap's text (\"Ctrl Shift P\"), or nil."
  (when-let* ((key (drgnx-surfaces-key-label id :short t)))
    (if (fboundp 'drgnx-palette-keycap-names) (string-join (drgnx-palette-keycap-names key) " ") key)))

(defun drgnx-topline--xml (s) (replace-regexp-in-string "[&<>\"]" (lambda (c) (format "&#%d;" (aref c 0))) s t t))

(defun drgnx-topline--search-svg (key)
  "The search box as SVG: the field (panel, a hairline, radius 6), the search icon, the placeholder and KEY (or nil)
as a keycap at the right (a hairline in the strong border, two pixels at the bottom, radius 4)."
  (let* ((w (or drgnx-topline--search-width (car drgnx-topline--search-size))) (h (cdr drgnx-topline--search-size))
         (text (drgnx-topline--color 'drgnx-text-subtle :foreground))
         (family (let ((f (face-attribute 'drgnx-ui-text :family nil t))) (if (stringp f) f "sans-serif")))
         (key (and key (>= w 240) key))   ; a narrow box has no room for its keycap
         (cap-w (and key (+ 10 (ceiling (* (/ 11.0 12) (/ (drgnx-look-pixel-width key 'drgnx-ui-caption)
                                                          (drgnx-pixels-scale)))))))
         (cap-x (and key (- w 10 cap-w))))
    (concat
     (format "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">" w h w h)
     (format "<rect x=\"0.5\" y=\"0.5\" width=\"%d\" height=\"%d\" rx=\"6\" fill=\"%s\" stroke=\"%s\"/>" (1- w) (1- h)
             (drgnx-topline--color 'drgnx-surface-panel :background) (drgnx-topline--color 'drgnx-border :foreground))
     (drgnx-topline--icon-svg 'search 10 5 16 text)
     ;; the placeholder in a box of its own, so a narrow field clips it instead of running over the border
     (format "<svg x=\"34\" y=\"0\" width=\"%d\" height=\"%d\"><text x=\"0\" y=\"17.5\" font-family=\"%s\" font-size=\"13\" fill=\"%s\">%s</text></svg>"
             (max 0 (- (or cap-x (- w 8)) 34 8)) h
             (drgnx-topline--xml family) text (drgnx-topline--xml drgnx-topline--search-text))
     (when key
       (let ((edge (drgnx-topline--color 'drgnx-border-strong :foreground)))
         (concat
          (format "<rect x=\"%.1f\" y=\"4.5\" width=\"%d\" height=\"16\" rx=\"4\" fill=\"none\" stroke=\"%s\"/>"
                  (+ cap-x 0.5) (1- cap-w) edge)
          (format "<path d=\"M%.1f 21h%d\" stroke=\"%s\"/>" (+ cap-x 3.5) (- cap-w 7) edge)
          (format "<text x=\"%d\" y=\"16\" font-family=\"%s\" font-size=\"11\" fill=\"%s\">%s</text>"
                  (+ cap-x 5) (drgnx-topline--xml family) text (drgnx-topline--xml key)))))
     "</svg>")))

(defun drgnx-topline--search-box ()
  "The search box's item: it opens Quick Open (files; `>' for commands, as in VS Code), its keycap Quick Open's key
in the key profile; nil without the command."
  (when-let* ((cmd (drgnx-commands-get 'go-quick-open))
              ((not (eql drgnx-topline--search-width 0))))
    (let* ((key (drgnx-topline--keycap 'go-quick-open))
           (text (concat "  " drgnx-topline--search-text "  " (or key "") "  ")))
      (drgnx-topline--item 'drgnx-topline-search
                           (drgnx-topline--image (drgnx-topline--search-svg key)
                                                 ;; the image's corners show the face's background: the row's
                                                 (propertize text 'face 'drgnx-topline))
                           (drgnx-cmd-command cmd)
                           (if key (format "Search: Quick Open (%s); > for commands" key) "Search: Quick Open; > for commands")))))

(defun drgnx-topline--icon-svg (name x y size color)
  "Icon NAME (etc/icons) as an SVG element at X, Y, SIZE logical pixels, stroked in COLOR; \"\" without the file."
  (let ((file (expand-file-name (format "%s.svg" name) drgnx-icons-dir)))
    (if (not (file-readable-p file))
        ""
      (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (setq text (replace-regexp-in-string "<!--.*?-->\n?" "" text t t))
        (setq text (replace-regexp-in-string "width=\"24\" height=\"24\""
                                             (format "x=\"%s\" y=\"%s\" width=\"%d\" height=\"%d\"" x y size size)
                                             text t t))
        (setq text (replace-regexp-in-string "stroke-width=\"2\""
                                             (format "stroke-width=\"%s\"" drgnx-icons-stroke) text t t))
        (replace-regexp-in-string "currentColor" color text t t)))))

(defun drgnx-topline--text-px (text face)
  "TEXT's width in FACE, logical pixels."
  (/ (drgnx-look-pixel-width text face) (drgnx-pixels-scale)))

(defun drgnx-topline--chip (parts face height radius &optional icon)
  "A chip: PARTS (a string, or a list of strings and (STRING . FACE) pairs, a face for a dimmer part) after ICON (an
icon name) in FACE's colours, HEIGHT logical pixels high, 7 either side, 5 after the icon, its corners RADIUS; in the
caption role.  A face with a box (high contrast's ring) is ringed in its foreground.  SVG where the frame shows it,
because text in a row taller than itself is painted the row's full height; else the text."
  (let* ((parts (if (stringp parts) (list parts) parts))
         (plain (mapconcat (lambda (p) (if (consp p) (car p) p)) parts "")))
    (if (not (drgnx-topline--svg-p))
        (propertize (concat " " plain " ") 'face face)
      (let* ((fg (drgnx-topline--color face :foreground)) (bg (drgnx-topline--color face :background))
             (flat (memq (face-attribute face :box nil t) '(nil unspecified)))   ; no ring
             (family (let ((f (face-attribute 'drgnx-ui-caption :family nil t))) (if (stringp f) f "sans-serif")))
             (x (+ 7 (if icon 19 0)))
             (spans (mapconcat (lambda (p)
                                 (let ((str (if (consp p) (car p) p))
                                       (col (if (consp p) (drgnx-topline--color (cdr p) :foreground) fg)))
                                   (format "<tspan fill=\"%s\">%s</tspan>" col (drgnx-topline--xml str))))
                               parts ""))
             (w (ceiling (+ x (drgnx-topline--text-px plain 'drgnx-ui-caption) 7))))
        (drgnx-topline--image
         (concat (format "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">"
                         w height w height)
                 (format "<rect x=\"0.5\" y=\"0.5\" width=\"%d\" height=\"%d\" rx=\"%d\" fill=\"%s\"%s/>"
                         (1- w) (1- height) radius bg (if flat "" (format " stroke=\"%s\"" fg)))
                 (if icon (drgnx-topline--icon-svg icon 7 (/ (- height 14) 2.0) 14 fg) "")
                 (format "<text x=\"%d\" y=\"%.1f\" font-family=\"%s\" font-size=\"12\" xml:space=\"preserve\">%s</text>"
                         x (+ (/ height 2.0) 4) (drgnx-topline--xml family) spans)
                 "</svg>")
         plain)))))

(defun drgnx-topline--edge-px (n)
  "N logical pixels from the window's side, in the frame's pixels, less the frame's edge the tab bar sits inside (the
cards' gap, `internal-border-width')."
  (max 0 (- (drgnx-topline--px n) (frame-internal-border-width))))

(defun drgnx-topline--edge-space (n)
  "A space that puts what follows N logical pixels from the window's left side (`drgnx-topline--edge-px')."
  (let ((px (drgnx-topline--edge-px n)))
    (propertize " " 'face 'drgnx-topline 'display `(space :width (,px)) 'drgnx-topline-px px)))

(defun drgnx-topline--mark-pixels (_buffer)
  "The mark item of a graphical row: the row's height (`title-row'), 14 px, the mark."
  (let* ((height (drgnx-topline--px (if (fboundp 'drgnx-look-density-value) (drgnx-look-density-value 'title-row) 38)))
         (extent (drgnx-pixels-font-extent 'drgnx-topline-strong))
         (descent (if extent (+ (cdr extent) (/ (- height (car extent) (cdr extent)) 2)) 0)))
    (drgnx-topline--item
     'drgnx-topline-mark
     (concat (or (drgnx-pixels-spacer 'drgnx-topline height descent) "")
             (drgnx-topline--edge-space 14)
             (drgnx-topline--image (drgnx-topline--mark-svg) (drgnx-topline--text (drgnx-topline--glyph 'diamond "<>")
                                                                                  'drgnx-topline)))
     nil "drgnx")))

(defun drgnx-topline--menus-p ()
  "Non-nil when the title row carries the menu button: the menu bar's mode is on, it is not macOS (the system menu bar
has the menus), Emacs's own menu bar is not shown and `drgnx-menubar-visibility' does not hide it."
  (and (bound-and-true-p drgnx-menubar-mode)
       (not (eq system-type 'darwin))
       (zerop (or (frame-parameter nil 'menu-bar-lines) 0))
       (not (memq (bound-and-true-p drgnx-menubar-visibility) '(hidden toggle)))))

(defun drgnx-topline--menu-button ()
  "The menu button of a graphical row (☰, a 26 px button after 6 px): it opens every menu as one list."
  (when (drgnx-topline--menus-p)
    (drgnx-topline--item
     'drgnx-topline-menu
     (concat (drgnx-topline--space 6)
             (propertize (if (drgnx-topline--svg-p)
                             (drgnx-topline--image (drgnx-topline--control-svg 'menu) "≡")
                           " ≡ ")
                         'mouse-face 'drgnx-topline-hover))
     'drgnx-menubar-pick
     (if-let* ((key (and (drgnx-commands-get 'face-menu) (drgnx-surfaces-key-label 'face-menu :short t)))) (format "The menus (%s)" key) "The menus"))))

(defconst drgnx-topline--chevron-svg
  "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"12\" viewBox=\"0 0 12 12\">%s</svg>"
  "The project switcher's chevron: a 12 px box the icon's element is put in.")

(defun drgnx-topline--strong-px (text)
  "TEXT's width in pixels in the row's semibold face; a text frame's columns where the width cannot be measured."
  (if (display-graphic-p) (drgnx-look-pixel-width text 'drgnx-topline-strong) (string-width text)))

(defun drgnx-topline--project-item (buffer)
  "The project switcher of a graphical row: 6 px, the project's name in semibold (cut with … to
`drgnx-topline--project-room' device pixels), a chevron.  A click opens the list of recent folders."
  (let* ((name (or (drgnx-topline--project buffer) "drgnx"))
         (chevron (drgnx-topline--image
                   (format drgnx-topline--chevron-svg
                           (drgnx-topline--icon-svg 'chevron-down 0 0 12 (drgnx-topline--color 'drgnx-text-subtle :foreground)))
                   "v"))
         (fixed (+ (drgnx-topline--px 6) (drgnx-topline--px 4)
                   (or (drgnx-topline--known-px chevron) (drgnx-topline--strong-px chevron))))
         (room (and drgnx-topline--project-room (max 0 (- drgnx-topline--project-room fixed)))))
    (when (and room (> (drgnx-topline--strong-px name) room))
      (while (and (> (length name) 1)
                  (> (drgnx-topline--strong-px (concat name "…")) room))
        (setq name (substring name 0 -1)))
      (setq name (concat name "…")))
    (drgnx-topline--item
     'drgnx-topline-project
     (concat (drgnx-topline--space 6)
             (propertize (concat (propertize name 'face 'drgnx-topline-strong) (drgnx-topline--space 4) chevron)
                         'mouse-face 'drgnx-topline-hover))
     'drgnx-topline-project-switch "The project: recent folders, Open Folder…")))

(defun drgnx-topline--paused-pill ()
  "The Paused chip of a graphical row (the warn pill with the bug) after 10 px, while a debug session is paused."
  (when (drgnx-topline--paused-p)
    (list (drgnx-topline--item 'drgnx-topline-paused
                               (concat (drgnx-topline--space 10) (drgnx-topline--chip "Paused" 'drgnx-kit-chip-warn-soft 20 10 'bug))
                               (and (fboundp 'drgnx-debug-toolbar-show-stop) 'drgnx-debug-toolbar-show-stop)
                               drgnx-topline--paused-help))))

(defun drgnx-topline--pills (&optional need agents)
  "The attention and agents chips of a graphical row (pills on their tints), each after 10 px, each only while its
count is positive.  NEED and AGENTS stand for the counts (the room the row keeps for them: the design's 1 and 2)."
  (let ((need (or need (drgnx-topline--attention-count))) (agents (or agents (drgnx-topline--agents-count))))
    (append
     (when (> need 0)
       (list (drgnx-topline--item 'drgnx-topline-attention
                                  (concat (drgnx-topline--space 10)
                                          (drgnx-topline--chip (format "● %d %s you" need (if (= need 1) "needs" "need")) 'drgnx-chip-attention 20 10))
                                  (drgnx-topline--attention-command)
                                  "Waiting on you: click for the inbox")))
     (when (> agents 0)
       (list (drgnx-topline--item 'drgnx-topline-agents
                                  (concat (drgnx-topline--space 10)
                                          (drgnx-topline--chip (format "%d %s" agents (if (= agents 1) "agent" "agents"))
                                                               'drgnx-kit-chip-accent-soft 20 10 'bot))
                                  (and (fboundp 'drgnx-agent-panel-list-show) 'drgnx-agent-panel-list-show)
                                  "Agents at work"))))))

(defconst drgnx-topline--control-commands
  '((drgnx-topline-minimize title-row-minimize minus minimize "Minimise")
    (drgnx-topline-maximize title-row-maximize square maximize "Maximise or restore")
    (drgnx-topline-close title-row-close x close "Close the window"))
  "The window controls: (ITEM REGISTRY-ID ICON GLYPH HELP); GLYPH where there is no SVG.")

(defun drgnx-topline--control-svg (icon &optional fill)
  "A window control's SVG: ICON, 16 px in the muted colour, centred in 26 px; the square 12 px (the design's maximise
is a 14-unit square, Lucide's an 18-unit one).  FILL, a rectangle (X Y WIDTH HEIGHT) in the icon's 24 units, is painted
solid in the icon's colour over it, marked `shown' (the layout toggles' part that is on)."
  (let* ((size (if (eq icon 'square) 12 16)) (at (/ (- 26 size) 2))
         ;; the row's height in the gap colour with a round hole: a `mouse-face' paints the glyph's whole box, the
         ;; row's height, and only the hole shows it, so the hover is the design's 26 px circle
         (h (if (fboundp 'drgnx-look-density-value) (drgnx-look-density-value 'title-row) 38))
         (top (/ (- h 26) 2)))
    (concat (format "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"26\" height=\"%d\" viewBox=\"0 0 26 %d\">" h h)
            (format "<path fill-rule=\"evenodd\" fill=\"%s\" d=\"M0 0h26v%dH0z M0 %da13 13 0 1 0 26 0a13 13 0 1 0 -26 0z\"/>"
                    (drgnx-topline--color 'drgnx-topline :background) h (+ top 13))
            (drgnx-topline--icon-svg icon at (+ top at) size (drgnx-topline--color 'drgnx-topline :foreground))
            (if fill
                (format "<g class=\"shown\" transform=\"translate(%s %s) scale(%s)\"><rect x=\"%s\" y=\"%s\" width=\"%s\" height=\"%s\" fill=\"%s\"/></g>"
                        at (+ top at) (/ size 24.0) (nth 0 fill) (nth 1 fill) (nth 2 fill) (nth 3 fill)
                        (drgnx-topline--color 'drgnx-topline :foreground))
              "")
            "</svg>")))

(defun drgnx-topline--control-buttons ()
  "The window controls of a graphical row: each a 26 px button, 4 px apart, running its registry command (the hover
colour under the pointer where the row draws a `mouse-face')."
  (mapcar (pcase-lambda (`(,item ,id ,icon ,glyph ,help))
            (drgnx-topline--item
             item
             (concat (drgnx-topline--space 4)
                     ;; one character under the image: the tab bar finds a hover's extent in characters, the
                     ;; row's in glyphs, so an image over three would light two glyphs past it
                     (propertize (if (drgnx-topline--svg-p)
                                     (drgnx-topline--image (drgnx-topline--control-svg icon)
                                                           (let ((g (drgnx-topline--glyph glyph "x")))
                                                             (if (> (length g) 0) (substring g 0 1) "x")))
                                   (concat " " (drgnx-topline--glyph glyph "x") " "))
                                 'mouse-face 'drgnx-topline-hover))
             (when-let* ((cmd (drgnx-commands-get id))) (drgnx-cmd-command cmd))
             help))
          drgnx-topline--control-commands))

;;;; The layout toggles: show or hide the primary side bar, the panel and the secondary side bar

(defun drgnx-topline-item-span (key)
  "The pixels (LEFT . RIGHT) the title row's item KEY spans on the selected frame, or nil when the row has none."
  (let* ((items (drgnx-topline--line)) (pos (cl-position key (mapcar #'car items)))
         (measure (drgnx-statusbar--measure-fn nil 'tab-bar)))
    (when pos
      (let ((left (drgnx-topline--width (seq-take items pos) measure)))
        (cons left (+ left (drgnx-topline--width (list (nth pos items)) measure)))))))

(defconst drgnx-topline--toggles
  '((drgnx-topline-toggle-sidebar toggle-sidebar panel-left 1 (4 4 5 16) "Toggle Primary Side Bar")
    (drgnx-topline-toggle-panel toggle-panel panel-bottom 2 (4 15 16 5) "Toggle Panel")
    (drgnx-topline-toggle-right toggle-right-dock panel-right 4 (15 4 5 16) "Toggle Secondary Side Bar"))
  "The layout toggles: (ITEM REGISTRY-ID ICON BIT FILL HELP).  BIT is the toggle's bit in `drgnx-topline--shown';
FILL the rectangle (in the icon's 24 units) drawn solid while the part shows.")

(defun drgnx-topline--shown (&optional frame)
  "The parts of FRAME (default: the selected frame) that show, as bits: 1 the primary side bar (the left dock), 2 the
panel, 4 the secondary side bar (the right dock).  Reads the windows' parameters and allocates nothing: a memo key."
  (let* ((frame (or frame (selected-frame))) (start (and (frame-live-p frame) (frame-first-window frame))) (w start) (bits 0))
    (when start
      (while (progn
               (let ((role (window-parameter w 'drgnx-role)))
                 (cond ((eq role 'dock) (setq bits (logior bits 1)))
                       ((window-parameter w 'drgnx-area-part))
                       ((eq role 'panel) (setq bits (logior bits 2)))
                       ((eq role 'right) (setq bits (logior bits 4)))))
               (setq w (next-window w 'nomini frame))
               (not (eq w start)))))
    bits))

(defun drgnx-topline--toggle-buttons ()
  "The layout toggles of a graphical row: each a 26 px button, 4 px apart, running its registry command; the icon is
filled while its part shows.  The tooltip names the key."
  (let ((shown (drgnx-topline--shown)))
    (mapcar (pcase-lambda (`(,item ,id ,icon ,bit ,fill ,help))
              (drgnx-topline--item
               item
               (concat (drgnx-topline--space 4)
                       (propertize (if (drgnx-topline--svg-p)
                                       (drgnx-topline--image
                                        (drgnx-topline--control-svg icon (and (/= 0 (logand shown bit)) fill)) "=")
                                     (concat " " (if (/= 0 (logand shown bit)) "■" "□") " "))
                                   'mouse-face 'drgnx-topline-hover))
               (when-let* ((cmd (drgnx-commands-get id))) (drgnx-cmd-command cmd))
               (if-let* ((key (and (drgnx-commands-get id) (drgnx-topline--keycap id)))) (format "%s (%s)" help key) help)))
            drgnx-topline--toggles)))

(defun drgnx-topline--left-items (buffer)
  "The left of a graphical row: the logo, the menu button, the project switcher."
  (delq nil (list (drgnx-topline--mark-pixels buffer) (drgnx-topline--menu-button) (drgnx-topline--project-item buffer))))

(defun drgnx-topline--right-room (drawn)
  "The right end of a graphical row as the design reserves it (the Paused chip while a session is, both pills, the
toggles, the controls, the edge): the room a chip that comes or goes never changes."
  (append (drgnx-topline--paused-pill) (drgnx-topline--pills 1 2) (drgnx-topline--toggle-buttons)
          (and drawn (drgnx-topline--control-buttons))
          (list (drgnx-topline--pixel-gap 'drgnx-topline-end (drgnx-topline--edge-px 8) nil))))

(defun drgnx-topline--fit-row (buffer pixels measure drawn)
  "How a row PIXELS wide shares what is left between the search box and the project name: (SEARCH . ROOM), SEARCH the
box's width in logical pixels (nil: all 440; 0: no box) and ROOM the device pixels the name may take (nil: all).  The
search box shrinks first, to `drgnx-topline--search-least'; then the name is cut; a box that would not fit even then
goes.  The menu button, the pills, the toggles and the controls are never cut."
  (let* ((gap (drgnx-topline--px 10))
         (left (drgnx-topline--width (list (drgnx-topline--mark-pixels buffer) (drgnx-topline--menu-button)) measure))
         (right (drgnx-topline--width (drgnx-topline--right-room drawn) measure))
         (project (drgnx-topline--width (list (let ((drgnx-topline--project-room nil)) (drgnx-topline--project-item buffer))) measure))
         (search (drgnx-topline--px (car drgnx-topline--search-size)))
         (least (drgnx-topline--px drgnx-topline--search-least))
         (free (- pixels left right (* 2 gap))))
    (cond ((>= free (+ project search)) (cons nil nil))
          ((>= (- free project) least)
           (cons (max 1 (floor (/ (- free project) (drgnx-pixels-scale)))) nil))
          ((>= (- free least) (drgnx-topline--px 60)) (cons drgnx-topline--search-least (- free least)))
          (t (cons 0 (max (drgnx-topline--px 40) (- pixels left right gap)))))))

(defun drgnx-topline--build-pixels (buffer pixels drawn)
  "The items for BUFFER on a graphical frame PIXELS wide: the design's title row (docs/specs/drgnx/2026-11-16-title-bar-
inbox-design.md, option B): the logo, the menu button, the project switcher; the search box centred between those and
the right end; the pills (`N need you', the agents), the layout toggles, the window controls.  The right end is laid out
for both pills whether or not they show: a chip that comes or goes never moves the search box.  A paused debug
session's chip adds its width to that room.  The room is shared by `drgnx-topline--fit-row'; the controls sit 8 px from
the right edge."
  (let* ((fit (drgnx-topline--fit-row buffer pixels (drgnx-statusbar--measure-fn nil 'tab-bar) drawn))
         (drgnx-topline--search-width (car fit))
         (drgnx-topline--project-room (cdr fit)))
    (if (fboundp 'nidhogg-view-bar)
        (drgnx-topline--build-sja buffer pixels drawn)
      (drgnx-topline--build-pixels-lisp buffer pixels drawn))))

(defun drgnx-topline--build-sja (buffer pixels drawn)
  "`drgnx-topline--build-pixels' laid out by Sjá (`nidhogg-view-bar'): Lisp measures each item once and joins the
items Sjá keeps with the gaps it answers.  No search box is sent as one whose gap is wider than the row, so the one
gap fills the row."
  (let* ((measure (drgnx-statusbar--measure-fn nil 'tab-bar))
         (left (drgnx-topline--left-items buffer))
         (paused (drgnx-topline--paused-pill))
         (right (append paused (drgnx-topline--pills) (drgnx-topline--toggle-buttons)
                        (and drawn (drgnx-topline--control-buttons))
                        (list (drgnx-topline--pixel-gap 'drgnx-topline-end (drgnx-topline--edge-px 8) nil))))
         (search (drgnx-topline--search-box))
         (room (drgnx-topline--right-room drawn))
         (fit (nidhogg-view-bar
               (format "2 %d 0 0 0 0 0 0 0 %d %d %s %d %d %d" pixels (length left) (length right)
                       (mapconcat (lambda (item) (format "-1 %d 0" (drgnx-topline--width (list item) measure)))
                                  (append left right) " ")
                       (if search (funcall measure (nth 2 search)) 0)
                       (if search (drgnx-topline--px 10) (1+ pixels))
                       (drgnx-topline--width room measure))))
         (left (mapcar (lambda (i) (nth i left)) (nth 0 fit)))
         (right (mapcar (lambda (i) (nth i right)) (nth 1 fit)))
         (place (nth 4 fit)))
    (if (eql (nth 0 place) 1)
        (append left (list (drgnx-topline--pixel-gap 'drgnx-topline-gap-1 (nth 1 place) drawn) search
                           (drgnx-topline--pixel-gap 'drgnx-topline-gap-2 (nth 2 place) drawn))
                right)
      (append left (list (drgnx-topline--pixel-gap 'drgnx-topline-gap-2 (nth 1 place) drawn)) right))))

(defun drgnx-topline--build-pixels-lisp (buffer pixels drawn)
  "`drgnx-topline--build-pixels' laid out here, for an Emacs without Sjá's bar.  Frozen."
  (let* ((measure (drgnx-statusbar--measure-fn nil 'tab-bar))
         (left (drgnx-topline--left-items buffer))
         (paused (drgnx-topline--paused-pill))
         (right (append paused (drgnx-topline--pills) (drgnx-topline--toggle-buttons)
                        (and drawn (drgnx-topline--control-buttons))
                        (list (drgnx-topline--pixel-gap 'drgnx-topline-end (drgnx-topline--edge-px 8) nil))))
         (left-px (drgnx-topline--width left measure))
         (right-px (drgnx-topline--width right measure))
         (search (drgnx-topline--search-box))
         (search-px (if search (funcall measure (nth 2 search)) 0))
         (room-px (drgnx-topline--width (drgnx-topline--right-room drawn) measure))
         (gap (drgnx-topline--px 10))
         (start (+ left-px gap (/ (- pixels left-px gap search-px gap room-px) 2)))
         (search (and search (>= start (+ left-px (drgnx-topline--px 10)))
                      (<= (+ start search-px (drgnx-topline--px 10) right-px) pixels)
                      search)))
    (if search
        (append left (list (drgnx-topline--pixel-gap 'drgnx-topline-gap-1 (- start left-px) drawn) search
                           (drgnx-topline--pixel-gap 'drgnx-topline-gap-2 (- pixels start search-px right-px) drawn))
                right)
      (append left (list (drgnx-topline--pixel-gap 'drgnx-topline-gap-2 (- pixels left-px right-px) drawn)) right))))

(defun drgnx-topline--build (buffer width drawn &optional pixels)
  "The items for BUFFER on a frame WIDTH columns wide; DRAWN: drgnx draws the title, so the controls show.
PIXELS, the frame's width in pixels: lay out in pixels instead (`drgnx-topline--build-pixels')."
  (if pixels
      (drgnx-topline--build-pixels buffer pixels drawn)
    (drgnx-topline--build-columns buffer width drawn)))

;;;; The row of a terminal frame: text, each part a click target (`☰  name ▾  [Ctrl P search]  ● 2 need you  ◧ ▬ ◨')

(defun drgnx-topline--menu-cell ()
  "The menu button of a terminal row (☰), or nil where the row has no menu button."
  (when (drgnx-topline--menus-p)
    (drgnx-topline--item 'drgnx-topline-menu
                         (drgnx-topline--text (concat " " (drgnx-topline--glyph 'menu "=") " ") 'drgnx-topline-strong)
                         'drgnx-menubar-pick "The menus")))

(defun drgnx-topline--project-cell (buffer room)
  "The project switcher of a terminal row: the project's name (cut with … to fit ROOM columns) and ▾."
  (let ((name (truncate-string-to-width (or (drgnx-topline--project buffer) "drgnx") (max 1 (- room 4)) nil nil t)))
    (drgnx-topline--item 'drgnx-topline-project
                         (concat (drgnx-topline--text (concat " " name) 'drgnx-topline-strong)
                                 (drgnx-topline--text (concat " " (drgnx-topline--glyph 'chevron-down "v") " ") 'drgnx-topline))
                         'drgnx-topline-project-switch "The project: recent folders, Open Folder…")))

(defun drgnx-topline--search-cell ()
  "The search box of a terminal row, `[Ctrl P search]': Quick Open (the key the profile gives it); nil without it."
  (when-let* ((cmd (drgnx-commands-get 'go-quick-open)))
    (let ((key (drgnx-topline--keycap 'go-quick-open)))
      (drgnx-topline--item 'drgnx-topline-search
                           (drgnx-topline--text (format "[%ssearch]" (if key (concat key " ") "")) 'drgnx-topline)
                           (drgnx-cmd-command cmd) "Search: Quick Open; > for commands"))))

(defun drgnx-topline--toggle-cells ()
  "The layout toggles of a terminal row: ◧ the primary side bar, ▬ the panel, ◨ the secondary side bar; bold while shown."
  (let ((shown (drgnx-topline--shown)))
    (mapcar (pcase-lambda (`(,item ,id ,icon ,bit ,_fill ,help))
              (drgnx-topline--item
               item
               (drgnx-topline--text (concat " " (drgnx-topline--glyph icon "#") " ")
                                    (if (/= 0 (logand shown bit)) 'drgnx-topline-strong 'drgnx-topline))
               (when-let* ((cmd (drgnx-commands-get id))) (drgnx-cmd-command cmd))
               help))
            drgnx-topline--toggles)))

(defun drgnx-topline--build-columns (buffer width drawn)
  "The items for BUFFER on a terminal WIDTH columns wide: ` ◆ ☰  name ▾ ', the search `[Ctrl P search]' centred, the
pills, the three toggles and, when DRAWN, the controls.  The project's name is cut with … first; the search box goes
when it does not fit; nothing else is left out."
  (let* ((right (append (drgnx-topline--chips) (drgnx-topline--toggle-cells) (and drawn (drgnx-topline--controls))))
         (right-w (drgnx-topline--width right))
         (mark (drgnx-topline--item 'drgnx-topline-mark
                                    (drgnx-topline--text (concat " " (drgnx-topline--glyph 'diamond "<>")) 'drgnx-topline)
                                    nil "drgnx"))
         (menu (drgnx-topline--menu-cell))
         (fixed (drgnx-topline--width (delq nil (list mark menu))))
         (project (drgnx-topline--project-cell buffer (max 5 (- width right-w fixed 2))))
         (left (delq nil (list mark menu project)))
         (left-w (drgnx-topline--width left))
         (search (drgnx-topline--search-cell))
         (search-w (if search (string-width (nth 2 search)) 0))
         (search (and search (<= (+ left-w search-w right-w 4) width) search)))
    (if search
        (let ((gap (max 2 (- (/ (- width search-w) 2) left-w))))   ; centred, never touching the left items
          (append left (list (drgnx-topline--gap 'drgnx-topline-gap-1 gap drawn) search
                             (drgnx-topline--gap 'drgnx-topline-gap-2 (- width left-w gap search-w right-w) drawn))
                  right))
      (append left (list (drgnx-topline--gap 'drgnx-topline-gap-2 (- width left-w right-w) drawn)) right))))

;;;; The memo: a redisplay that changes nothing reuses the line

(defsubst drgnx-topline--hint-command (id)
  "The command of hint command ID, or nil.  A memo key: allocates nothing."
  (let ((cmd (drgnx-commands-get id))) (and cmd (drgnx-cmd-command cmd))))

(defsubst drgnx-topline--hint-bound (id)
  "The keys of hint command ID, or nil.  A memo key: allocates nothing."
  (let ((cmd (drgnx-commands-get id))) (and cmd (drgnx-cmd-bound cmd))))

;; One stored line per frame (the tab bar of each frame is drawn with that frame selected, so one for all would make
;; the line again at every redisplay), weak on the frame.  It holds the editor's buffer strongly: a killed buffer is
;; kept until that frame's next redisplay replaces it (it never accumulates).  BUFFER, WIDTH and DRAWN are
;; `drgnx-topline--line''s.  The branch is not read from the git cache here: the epoch `git' moves when a status run
;; read a new branch, and the count of folders whose repository is known moves when the cache may answer for this
;; buffer's folder (a status run of a root it already knew moves no epoch).
(drgnx-memo-define topline :on frame
                   :keys (buffer
                          (buffer-local-value 'default-directory buffer)
                          (and (boundp 'drgnx-chrome--root) (buffer-local-value 'drgnx-chrome--root buffer))
                          (buffer-local-value 'buffer-file-name buffer)
                          width drawn pixels drgnx-face-glyphs
                          custom-enabled-themes drgnx-pixels-generation   ; the images' colours, the fonts measured
                          (drgnx-topline--attention-count) (drgnx-topline--agents-count) (drgnx-topline--paused-p)
                          (and (framep object) (drgnx-statusbar--layout-key (frame-selected-window object)))
                          (and (framep object) (drgnx-topline--shown object))   ; which toggles are filled
                          (and (framep object) (drgnx-topline--menus-p))
                          ;; the search box's command and key
                          (drgnx-topline--hint-command 'go-quick-open) (drgnx-topline--hint-bound 'go-quick-open)
                          ;; the menu bar: shown or not, how, and whether Alt opens it (its titles' underlines)
                          (bound-and-true-p drgnx-menubar-mode) (bound-and-true-p drgnx-menubar-visibility)
                          (drgnx-topline--hint-bound 'menu-bar-open-file))
                   :doc "Frame → the top line's items.")

(defconst drgnx-topline--declared '(topline)
  "The memo `drgnx-topline-setup' activates.")

(defvar drgnx-topline--error nil
  "The message of the error the line last failed with, or nil while it works.  Never shown as a message.
While it is set the line shows its mark alone (for `drgnx-topline-retry-seconds') and `drgnx-topline--fit' leaves
the frames alone.")

(defvar drgnx-topline--error-at nil "When `drgnx-topline--error' was recorded (`drgnx-topline--now'), or nil.")

(defvar drgnx-topline-retry-seconds 10
  "Seconds the line shows its mark alone after an error, before it is made again.")

(defun drgnx-topline--now () (float-time))

(defconst drgnx-topline--fallback '((drgnx-topline-mark menu-item " drgnx" ignore :help ""))
  "What the line shows while it is failing: not empty, because Emacs takes away a tab bar with no items.")

(defun drgnx-topline--failing-p ()
  "Non-nil while the line shows its fallback: it failed less than `drgnx-topline-retry-seconds' ago (a clock that
went back counts as long ago)."
  (and drgnx-topline--error-at
       (let ((d (- (drgnx-topline--now) drgnx-topline--error-at)))
         (<= 0 d drgnx-topline-retry-seconds))))

(defun drgnx-topline--line ()
  "The top line's tab-bar items, from cached state only (see the Commentary); memoized on what they show.
Everything runs under an error guard: a failure is recorded in `drgnx-topline--error' and the line shows its mark
alone for `drgnx-topline-retry-seconds'.  A memo hit allocates nothing."
  (if (drgnx-topline--failing-p)
      drgnx-topline--fallback
    (condition-case err
        (let* ((frame (selected-frame))
               (window (drgnx-state-editor-window))
               (buffer (if (window-live-p window) (window-buffer window) (current-buffer)))
               (width (frame-text-cols frame))   ; `frame-width' conses ~140 cells and 14 strings per call
               (drawn (and (drgnx-topline--drawn-title-p frame) t))
               (pixels (and (or drgnx-look-bars-measure-function (and (framep frame) (display-graphic-p frame)))
                            (frame-inner-width frame))))
          (prog1 (drgnx-memo topline frame (drgnx-topline--build buffer width drawn pixels))
            (setq drgnx-topline--error nil drgnx-topline--error-at nil)))
      ;; An error would leave the tab bar without items, which Emacs answers by taking the line away; and then
      ;; every redisplay would give it back and take it away again.
      (error (setq drgnx-topline--error (error-message-string err) drgnx-topline--error-at (drgnx-topline--now))
             (drgnx-timer-start 'topline-retry drgnx-topline-retry-seconds #'drgnx-topline--retry :owner 'ui/face)
             drgnx-topline--fallback))))

(defun drgnx-topline--retry ()
  "The timer `topline-retry': end the failure, redraw every frame's tab bar, and fit the frames made meanwhile.
Without it the line came back only with the next command (an idle frame stayed on its fallback)."
  (setq drgnx-topline--error nil drgnx-topline--error-at nil)
  (force-mode-line-update t)
  (drgnx-topline--fit-all))

(defun drgnx-topline--frame-of (arg)
  "The frame ARG names: a frame, or the data plist of a store event (`:frame')."
  (if (consp arg) (plist-get arg :frame) arg))

(defun drgnx-topline--resized (data)
  "On the store's `frame-resized' (`now' lane): redraw the tab bar when the frame in DATA changed its number of
columns (`:cols' of DATA's `:old' and `:new'); a change of height alone redraws nothing.  Only asks for a redraw;
never touches `tab-bar-lines'.  Does nothing while the line is failing."
  (let ((frame (drgnx-topline--frame-of data)))
    (when (and (not drgnx-topline--error) (frame-live-p frame) (not (eq (drgnx-state-frame-kind frame) 'child))
               (not (eql (plist-get (plist-get data :old) :cols) (plist-get (plist-get data :new) :cols))))
      (force-mode-line-update t))))

(defun drgnx-topline-format ()
  "The `tab-bar-format' list that draws the top line (one function, `drgnx-topline--line')."
  (list #'drgnx-topline--line))

;;;; Turning it on and off

(defvar drgnx-topline--saved nil
  "What this module changed to turn the line on, to put back when it goes off: (:mode WAS-ON :format F :show S).
nil while it is off.")

(defvar drgnx-topline--format nil "The `tab-bar-format' value this module set, to tell it from a user's own.")

(defun drgnx-topline--users-format-p ()
  "Non-nil when `tab-bar-format' is the user's own: neither Emacs's default nor what this module set."
  (let ((now (default-value 'tab-bar-format)))
    (not (or (equal now (eval (car (get 'tab-bar-format 'standard-value)) t))
             (and drgnx-topline--format (equal now drgnx-topline--format))))))

(defun drgnx-topline--lines (frame)
  "1 when FRAME shows the top line, else 0: a terminal with fewer than `drgnx-topline-min-lines' lines shows none.
The terminal's lines are the frame's height plus the tab bar's own: `frame-height' is one less while the line shows,
so counting it alone made a terminal of exactly the minimum show the line, then lose it, then show it again, for
as long as it stayed that size."
  (if (or (display-graphic-p frame)
          (>= (+ (frame-height frame) (or (frame-parameter frame 'tab-bar-lines) 0)) drgnx-topline-min-lines))
      1 0))

(defun drgnx-topline--fit (&optional frame)
  "Give FRAME (default: the selected one; or the data plist of a store event) its top line, or none when it is a
short terminal.  On the store's `frame-added' and `frame-resized', `idle' lane (it may set `tab-bar-lines', which
resizes windows); the frame keeps the state this sets
\(`tab-bar-lines-keep-state'), so the tab bar's own updates leave it alone.  A child frame is left alone.
While the line is failing (`drgnx-topline--error') this does nothing at all, so a terminal frame made in that time
gets its decision only after the line works again (`drgnx-topline--retry' runs `drgnx-topline--fit-all')."
  (let ((frame (or (drgnx-topline--frame-of frame) (selected-frame))))
    (when (and (frame-live-p frame) (not (eq (drgnx-state-frame-kind frame) 'child))
               (not drgnx-topline--error))                  ; while the line is failing, nothing here touches a frame
      (cond
       ((not (equal (default-value 'tab-bar-format) drgnx-topline--format))   ; the user took the tab bar over
        (set-frame-parameter frame 'tab-bar-lines-keep-state nil))
       ((display-graphic-p frame)
        ;; A graphical frame has its one line from `tab-bar-mode'; it is never set here.  Only what a text frame's
        ;; parameters left on it (the frame made after init takes over the initial one's) is undone, once.
        (when (frame-parameter frame 'tab-bar-lines-keep-state)
          (set-frame-parameter frame 'tab-bar-lines-keep-state nil)
          (set-frame-parameter frame 'drgnx-topline-lines nil)
          (tab-bar--update-tab-bar-lines (list frame))))
       (t
        ;; A terminal frame: decide once per change of the answer.  What redisplay did to `tab-bar-lines' since is
        ;; not undone, or the two would resize every window against each other on every redisplay.
        (let ((want (drgnx-topline--lines frame)))
          (unless (eq (frame-parameter frame 'tab-bar-lines-keep-state) t)
            (set-frame-parameter frame 'tab-bar-lines-keep-state t))
          (unless (eql (frame-parameter frame 'drgnx-topline-lines) want)
            (set-frame-parameter frame 'drgnx-topline-lines want)
            (set-frame-parameter frame 'tab-bar-lines want))))))))

(defun drgnx-topline--fit-all ()
  "Fit every frame.  On `emacs-startup-hook' and `window-setup-hook': while init runs the frame is still the initial
text frame, whose size and parameters (the top line's among them) the window's frame then takes over."
  (mapc #'drgnx-topline--fit (frame-list)))

(defun drgnx-topline--first-note ()
  "Fill the open editor's project cache once (the editor-changed edge only tells of changes).  The idle timer
`topline-first-note' calls it."
  (drgnx-topline--note-editor))

(defun drgnx-topline--on ()
  "Turn the line on (idempotent): `tab-bar-mode' with the format of `drgnx-topline-format' and no tabs."
  (unless drgnx-topline--saved
    (setq drgnx-topline--saved (list :mode tab-bar-mode :format (default-value 'tab-bar-format)
                                     :show (default-value 'tab-bar-show)
                                     :face (get 'tab-bar 'face-defface-spec)
                                     ;; `tab-bar-mode' writes this key of `default-frame-alist'
                                     :lines (let ((c (assq 'tab-bar-lines default-frame-alist)))
                                              (and c (cons (car c) (cdr c)))))))
  (setq drgnx-topline--format (drgnx-topline-format))
  ;; No tabs to size: auto-width walks the items and makes strings on every redisplay.  A value of the user's stays.
  (when (and (not (plist-member drgnx-topline--saved :auto-width))
             (eq (default-value 'tab-bar-auto-width) (eval (car (get 'tab-bar-auto-width 'standard-value)) t)))
    (setq drgnx-topline--saved (plist-put drgnx-topline--saved :auto-width (default-value 'tab-bar-auto-width)))
    (setq-default tab-bar-auto-width nil))
  (setq-default tab-bar-format drgnx-topline--format
                tab-bar-show t)                          ; 1 would hide the bar: it has one tab
  (face-spec-set 'tab-bar '((t :inherit (drgnx-ui-text drgnx-text-muted drgnx-surface-gap) :box nil))
                 'face-defface-spec)                     ; the title row on the gap (§4), for a theme that sets none
  (drgnx-state-subscribe 'frame-resized #'drgnx-topline--resized :lane 'now)
  (drgnx-state-subscribe 'frame-added #'drgnx-topline--fit :lane 'idle)
  (drgnx-state-subscribe 'frame-resized #'drgnx-topline--fit :lane 'idle)
  (add-hook 'emacs-startup-hook #'drgnx-topline--fit-all)
  (add-hook 'window-setup-hook #'drgnx-topline--fit-all)
  (when (fboundp 'drgnx-signal-subscribe) (drgnx-signal-subscribe 'editor-changed #'drgnx-topline--note-editor))
  (unless (drgnx-timer-active-p 'topline-first-note)     ; the project of the editor that is open now, once, when idle
    (drgnx-timer-start 'topline-first-note 0.5 #'drgnx-topline--first-note :idle t :owner 'ui/face))
  (tab-bar-mode 1)
  (drgnx-module-define-key 'tab-bar-map [double-mouse-1] #'drgnx-topline-toggle-maximized)
  (unless (plist-member drgnx-topline--saved :clicks)   ; the tab bar's own, put back when the row goes
    (setq drgnx-topline--saved (plist-put drgnx-topline--saved :clicks
                                          (list (lookup-key tab-bar-map [down-mouse-1]) (lookup-key tab-bar-map [mouse-1])))))
  (drgnx-module-define-key 'tab-bar-map [down-mouse-1] #'drgnx-topline-mouse-down)
  (drgnx-module-define-key 'tab-bar-map [mouse-1] #'drgnx-topline-mouse-up)
  (drgnx-topline--fit-all))

(defun drgnx-topline--off ()
  "Turn the line off (idempotent), putting back what it changed."
  (when (eq (lookup-key tab-bar-map [double-mouse-1]) #'drgnx-topline-toggle-maximized)
    (define-key tab-bar-map [double-mouse-1] nil))
  (pcase-let ((`(,down ,up) (plist-get drgnx-topline--saved :clicks)))
    (when (eq (lookup-key tab-bar-map [down-mouse-1]) #'drgnx-topline-mouse-down) (define-key tab-bar-map [down-mouse-1] down))
    (when (eq (lookup-key tab-bar-map [mouse-1]) #'drgnx-topline-mouse-up) (define-key tab-bar-map [mouse-1] up)))
  (drgnx-state-unsubscribe 'frame-resized #'drgnx-topline--resized)
  (drgnx-state-unsubscribe 'frame-added #'drgnx-topline--fit)
  (drgnx-state-unsubscribe 'frame-resized #'drgnx-topline--fit)
  (drgnx-timer-cancel 'topline-first-note)
  (drgnx-timer-cancel 'topline-retry)
  (remove-hook 'emacs-startup-hook #'drgnx-topline--fit-all)
  (remove-hook 'window-setup-hook #'drgnx-topline--fit-all)
  (when (fboundp 'drgnx-signal-unsubscribe) (drgnx-signal-unsubscribe 'editor-changed #'drgnx-topline--note-editor))
  (when drgnx-topline--saved
    (let ((saved drgnx-topline--saved) (format drgnx-topline--format))
      (setq drgnx-topline--saved nil drgnx-topline--format nil
            drgnx-topline--error nil drgnx-topline--error-at nil)
      (drgnx-memo-forget 'topline)
      (when-let* ((spec (plist-get saved :face))) (face-spec-set 'tab-bar spec 'face-defface-spec))
      (dolist (f (frame-list))
        (set-frame-parameter f 'tab-bar-lines-keep-state nil)
        (set-frame-parameter f 'drgnx-topline-lines nil))
      (when (equal (default-value 'tab-bar-format) format)   ; a format the user set since stays
        (setq-default tab-bar-format (plist-get saved :format) tab-bar-show (plist-get saved :show)))
      (when (and (plist-member saved :auto-width) (null (default-value 'tab-bar-auto-width)))   ; still ours
        (setq-default tab-bar-auto-width (plist-get saved :auto-width)))
      (unless (plist-get saved :mode) (tab-bar-mode -1))
      (tab-bar--update-tab-bar-lines t)
      (unless tab-bar-mode            ; the key `tab-bar-mode' wrote into `default-frame-alist' goes back as it was
        (setq default-frame-alist (assq-delete-all 'tab-bar-lines (copy-sequence default-frame-alist)))
        (when-let* ((cell (plist-get saved :lines))) (push cell default-frame-alist))))))

(defun drgnx-topline--apply ()
  "Make the line match `drgnx-topline': on unless it is off, the user has a tab-bar format of their own, or the
tab bar was already on before this module (then it is theirs)."
  (if (and drgnx-topline (not (drgnx-topline--users-format-p))
           (or drgnx-topline--saved (not tab-bar-mode)))
      (drgnx-topline--on)
    (drgnx-topline--off)))

(defun drgnx-topline-setup ()
  "Turn the top line on (called by the module ui/face), with its memo active (`drgnx-topline--declared':
it empties when `ui/face' is turned off)."
  (apply #'drgnx-memo-activate drgnx-topline--declared)
  (drgnx-command-define 'title-row-minimize :category "Window" :title "Minimize Window" :command #'iconify-frame
                        :doc "Minimise the window (the title row's first window control)")
  (drgnx-command-define 'title-row-maximize :category "Window" :title "Maximize or Restore Window"
                        :command #'drgnx-topline-toggle-maximized
                        :doc "Maximise the window, or restore it (also a double click on the empty part of the title row)")
  (drgnx-command-define 'title-row-close :category "Window" :title "Close Window" :command #'delete-frame
                        :doc "Close the window (the title row's last window control)")
  (drgnx-command-define 'title-row-close-folder :category "File" :title "Close Folder" :command #'drgnx-topline-close-folder
                        :doc "Remove the project's folder from the Explorer (nothing on disk changes)")
  (drgnx-command-define 'title-row-project :category "File" :title "Switch Project…" :command #'drgnx-topline-project-switch
                        :doc "Open a recent folder, or Open Folder…, Add Folder to Workspace…, Close Folder (the title row's project name)")
  (drgnx-command-define 'title-row-drag :category "Window" :title "Move Window by the Title Row"
                        :command #'drgnx-topline-drag-window :when #'ignore   ; a press runs it, never the palette
                        :doc "Move the window: a press on the empty part of the title row, dragged")
  (setq drgnx-topline--active t)
  (drgnx-topline--apply))

(provide 'drgnx-topline)
;;; drgnx-topline.el ends here
