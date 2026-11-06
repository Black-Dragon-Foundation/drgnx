;;; drgnx-chrome.el --- Chrome by role: tab lines, breadcrumbs, mode lines -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every window's chrome is decided by its role, never by its buffer (invariant I3): an editor
;; window has a tab line (the buffers shown in it, in the order they were opened — switching
;; never reorders them), a breadcrumb header (project › folders › file, ● when unsaved) and a
;; mode line; a dock section has its title only; the panel and the right dock have their tab row
;; only.  The chrome lives in window parameters, which win over any mode's own
;; `header-line-format', `tab-line-format' or `mode-line-format', so no buffer can make a
;; window's text jump.  New windows get their chrome before they are first drawn (the state store's
;; `windows-changed', `now' lane); tabs and breadcrumbs follow its `editor-changed' and the bus's buffer edges.  A frame whose parameter
;; `drgnx-chrome-breadcrumb' is `off' (a terminal frame below 30 lines) has no breadcrumb row.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'project)
(require 'tab-line)                     ; the tab faces we inherit
(require 'drgnx-area)
(require 'drgnx-faces)                  ; `drgnx-look-hover-control', `drgnx-hover-row'
(require 'drgnx-pixels)                 ; rows of an exact height, `drgnx-look-pixel-width'
(require 'drgnx-icons)                  ; `drgnx-look-icon'
(declare-function drgnx-face-glyph "drgnx-face")
(declare-function glitnir-active-p "glitnir")
(declare-function drgnx-look-density-value "drgnx-look-density" (key &optional density))
(declare-function drgnx-groups-split-right "drgnx-groups")

;; No `:height' in the tab faces: a relative 1.0 scales by one, and costs a font spec copy at every run of the tab line.
(defface drgnx-chrome-tab '((t :inherit (shadow tab-line-tab-inactive) :box nil))
  "A tab in an editor's tab line: dimmed." :group 'drgnx)
(defface drgnx-chrome-tab-current '((t :inherit tab-line-tab-current :box nil :weight bold))
  "The shown tab of an editor group that is not the active one." :group 'drgnx)
(defface drgnx-chrome-tab-active '((t :inherit (link tab-line-tab-current) :box nil :weight bold
                                      :underline nil :overline t))
  "The shown tab of the active editor group: the theme's link colour, overlined." :group 'drgnx)
(defface drgnx-chrome-tab-hover '((t :inherit tab-line-highlight))
  "The tab (or its ×) under the pointer; only that one." :group 'drgnx)
(defface drgnx-chrome-tab-preview '((t :slant italic))
  "A tab that is only there while it is shown (the scratch buffer, the start page): italic." :group 'drgnx)
(defface drgnx-chrome-crumb '((t :inherit (drgnx-text-subtle shadow))) "The folders of a breadcrumb." :group 'drgnx)

(defun drgnx-chrome--role (w)
  "W's chrome role: `editor', `dock', `area', `lane', or nil (left alone).
From W's role in the state store (`drgnx-state-window-role'): an editor window is `editor', a role of the
role table has its `:chrome' (`drgnx-state-define-role'), anything else is left alone."
  (unless (frame-parent (window-frame w))   ; child frames: posframe, corfu, eldoc-box keep theirs
    (let ((role (drgnx-state-window-role w)))
      (if (eq role 'editor) 'editor (drgnx-state-role-chrome role)))))

;;;; Tabs

(defun drgnx-chrome--tab-buffer-p (b)
  (and (buffer-live-p b) (not (string-prefix-p " " (buffer-name b)))))

(defun drgnx-chrome-tabs (w)
  "The buffers W has shown, in the order they were opened (live ones)."
  (seq-filter #'buffer-live-p (window-parameter w 'drgnx-tabs)))

(defcustom drgnx-chrome-transient-tabs "\\`\\*scratch\\*\\'\\|\\*drgnx start\\*"
  "Buffers that are a tab only while shown (like VS Code's welcome tab): `*scratch*' and the start page."
  :type 'regexp :group 'drgnx)

(defun drgnx-chrome--note-history (w b tabs)
  "Put B first in W's `drgnx-tab-history' (most recently shown first); keep only TABS, live."
  (let ((new (seq-filter (lambda (x) (and (buffer-live-p x) (memq x tabs)))
                         (if (drgnx-chrome--tab-buffer-p b)
                             (cons b (remq b (window-parameter w 'drgnx-tab-history)))
                           (window-parameter w 'drgnx-tab-history)))))
    (unless (equal new (window-parameter w 'drgnx-tab-history))
      (set-window-parameter w 'drgnx-tab-history new))))

(defun drgnx-chrome--note (w)
  "Add W's buffer to its tabs (at the end; never reordered); drop transient tabs not shown.
Also records it as W's most recently shown tab (`drgnx-tab-history', per window).
Called on the bus's edges and by commands — never while drawing, so a buffer shown for a moment
(a preview) does not become a tab."
  (let* ((b (window-buffer w)) (before (drgnx-chrome-tabs w))
         (after (let ((tabs (seq-remove (lambda (x) (and (not (eq x b)) (string-match-p drgnx-chrome-transient-tabs (buffer-name x))))
                                        before)))
                  (if (and (drgnx-chrome--tab-buffer-p b) (not (memq b tabs))) (append tabs (list b)) tabs))))
    (unless (equal before after)
      (set-window-parameter w 'drgnx-tabs after)
      (drgnx-signal-post 'tabs-changed))
    (drgnx-chrome--note-history w b after)))

(defun drgnx-chrome--text (s)
  "S shown as is in a tab or header line (% would be a format directive)."
  (string-replace "%" "%%" (drgnx-wb-display-name s)))

(defun drgnx-chrome--select-tab (event)
  "Show the tab clicked in a tab line."
  (interactive "e")
  (when-let* ((posn (event-start event)) (s (posn-string posn))
              (b (get-text-property (cdr s) 'drgnx-buffer (car s))) (w (posn-window posn)))
    (when (buffer-live-p b) (set-window-buffer w b) (drgnx-chrome-apply (window-frame w) t))))

(defun drgnx-chrome--close-clicked (event)
  "Close the tab whose × was clicked."
  (interactive "e")
  (when-let* ((posn (event-start event)) (s (posn-string posn))
              (b (get-text-property (cdr s) 'drgnx-buffer (car s))) (w (posn-window posn)))
    (drgnx-chrome--record-closed-position w b)
    (drgnx-chrome--close w b)))

(defvar drgnx-chrome--tab-map
  (let ((m (make-sparse-keymap)))
    (define-key m [tab-line mouse-1] #'drgnx-chrome--select-tab)
    (define-key m [tab-line mouse-2] #'drgnx-chrome--close-clicked)
    m))

(defvar drgnx-chrome--close-map
  (let ((m (make-sparse-keymap))) (define-key m [tab-line mouse-1] #'drgnx-chrome--close-clicked) m))

(defun drgnx-chrome--close-glyph (w)
  "The close mark of W's tabs: the glyph `close' of the table every close button uses (`drgnx-face-glyphs'), in its
ASCII form on a terminal that is not UTF-8; × without ui/face."
  (or (and (fboundp 'drgnx-face-glyph) (drgnx-face-glyph 'close (window-frame w))) "×"))

(defconst drgnx-chrome--breadcrumb-row 26 "The breadcrumb row's height in logical pixels on a graphical frame.")
(defconst drgnx-chrome--tab-gap 2 "Logical pixels between two tabs of a graphical frame (a space on a terminal).")
(defconst drgnx-chrome--tab-top-radius 7 "The radius of a tab's top corners where the compositor can round them.")

(defun drgnx-chrome--tab-rows (w)
  "(ROW BOX FRAME) for W's tab line on a graphical frame, else nil: ROW is the `tab-row' height in device pixels,
BOX the width of the flat box above and below a tab's text that makes the tab four logical pixels shorter than the row."
  (let ((frame (window-frame w)))
    (when (display-graphic-p frame)
      (let* ((scale (drgnx-pixels-scale frame))
             (row (round (* scale (if (fboundp 'drgnx-look-density-value) (drgnx-look-density-value 'tab-row) 34))))
             (tab (- row (round (* scale 4)))))
        (list row (drgnx-pixels-box-height 'drgnx-chrome-tab tab frame) frame)))))

(defun drgnx-chrome--tab-box (box)
  "The anonymous face of a tab's box: BOX pixels above and below, in the face's own background; its top corners
rounded and its bottom open where the compositor draws such boxes."
  (list :box `(:line-width (0 . ,box) :style flat-button
                           ,@(when (and (fboundp 'glitnir-active-p) (glitnir-active-p))   ; drawing, not just loaded
                               `(:corner-radius ,drgnx-chrome--tab-top-radius :open (bottom))))))

(defun drgnx-chrome--tab (w b shown active rows)
  "The text of B's tab in W's tab line.  SHOWN: B is the window's buffer; ACTIVE: W is the active editor group;
ROWS: `drgnx-chrome--tab-rows'.  The whole tab carries one `mouse-face' value of its own (a fresh list, not `eq' to
another tab's: Emacs lights the run of text whose value is `eq') unless it is shown, and its close mark is drawn in
the row's colour until the pointer is on the tab (`drgnx-look-hover-control', decided by W's frame: a terminal's
tabs always show it, whichever frame is selected when the tab lines are made)."
  (let* ((face (cond ((not shown) 'drgnx-chrome-tab) (active 'drgnx-chrome-tab-active) (t 'drgnx-chrome-tab-current)))
         (face (if (string-match-p drgnx-chrome-transient-tabs (buffer-name b))
                   (list 'drgnx-chrome-tab-preview face)
                 face))
         (box (and rows (drgnx-chrome--tab-box (nth 1 rows))))
         (mouse (unless shown (list 'drgnx-hover-row)))
         (icon (when (and rows shown)
                 (let ((i (drgnx-look-icon (drgnx-look-file-icon-name (or (buffer-file-name b) (buffer-name b))) face 14)))
                   (unless (string-empty-p i) (concat i " ")))))
         (s (concat
             (propertize (format "  %s%s" (or icon "") (drgnx-chrome--text (buffer-name b)))
                         'face face 'help-echo "Show; middle-click closes" 'local-map drgnx-chrome--tab-map)
             (when (and (buffer-file-name b) (buffer-modified-p b))
               (propertize " ●" 'face (cons 'drgnx-text-muted (ensure-list face))
                           'help-echo "Show; middle-click closes" 'local-map drgnx-chrome--tab-map))
             (propertize " " 'face face 'help-echo "Show; middle-click closes" 'local-map drgnx-chrome--tab-map)
             (propertize (drgnx-look-hover-control (drgnx-chrome--close-glyph w) shown (window-frame w))
                         'help-echo "Close this tab" 'local-map drgnx-chrome--close-map)
             (propertize "  " 'face face 'help-echo "Close this tab" 'local-map drgnx-chrome--close-map))))
    (add-text-properties 0 (length s) (list 'drgnx-buffer b) s)
    (when mouse (add-text-properties 0 (length s) (list 'mouse-face mouse) s))
    (when box (add-face-text-property 0 (length s) box nil s))
    s))

(defvar drgnx-chrome--buttons (make-hash-table :test #'eq :weakness 'key)
  "FRAME → [BOX GENERATION CHAR-WIDTH CHAR-HEIGHT ROUNDED ICONS BUTTONS WIDTH]: the tab lines' buttons on FRAME and
their measured width, made for a box of BOX pixels, the fonts of `drgnx-pixels-generation', the frame's character
cell (a zoom or a scale moves it), rounded corners or not and the `drgnx-look-icons' setting.  A tab line is made
again at every tab switch, and the buttons' keymaps and pixel measure cost more than all its tabs.  Weak on the
frame.")

(defun drgnx-chrome--tab-buttons (w rows)
  "The overflow and split buttons at the right end of W's tab line on a graphical frame (ROWS: `drgnx-chrome--tab-rows'),
made once per frame and size (`drgnx-chrome--buttons')."
  (let* ((frame (nth 2 rows)) (box (nth 1 rows))
         (rounded (and (fboundp 'glitnir-active-p) (glitnir-active-p) t))
         (kept (gethash frame drgnx-chrome--buttons))
         (made (if (and kept (eql (aref kept 0) box) (eql (aref kept 1) drgnx-pixels-generation)
                        (eql (aref kept 2) (frame-char-width frame)) (eql (aref kept 3) (frame-char-height frame))
                        (eq (aref kept 4) rounded) (eq (aref kept 5) (bound-and-true-p drgnx-look-icons)))
                   kept
                 (puthash frame (drgnx-chrome--tab-buttons-make frame box rounded) drgnx-chrome--buttons)))
         (fringe (or (nth 1 (window-fringes w)) 0)))
    (concat (propertize " " 'face 'drgnx-chrome-tab 'display `(space :align-to (- right (,(max 0 (- (aref made 7) fringe))))))
            (aref made 6))))

(defun drgnx-chrome--tab-buttons-make (frame box rounded)
  "The entry of `drgnx-chrome--buttons' for FRAME: the buttons in a box of BOX pixels (ROUNDED: its top corners) and
their width with the gap before them."
  (let* ((box-face (drgnx-chrome--tab-box box))
         (button (lambda (icon fallback help command)
                   (let ((s (let ((i (drgnx-look-icon icon 'drgnx-chrome-tab 14)))
                              (if (string-empty-p i) (propertize fallback 'face 'drgnx-chrome-tab) i))))
                     (setq s (concat " " s " "))
                     (add-text-properties 0 (length s) (list 'help-echo help 'mouse-face (list 'drgnx-hover-row)
                                                             'local-map (let ((m (make-sparse-keymap)))
                                                                          (define-key m [tab-line mouse-1] command)
                                                                          m))
                                          s)
                     (add-face-text-property 0 (length s) 'drgnx-chrome-tab t s)
                     (add-face-text-property 0 (length s) box-face nil s)
                     s)))
         (buttons (concat (funcall button 'ellipsis "..." "Tabs of this group" #'drgnx-chrome-switch-tab-click)
                          (funcall button 'square "[]" "Split the editor right" #'drgnx-chrome-split-click)))
         (width (+ (drgnx-look-pixel-width buttons 'drgnx-chrome-tab) (round (* (drgnx-pixels-scale frame) 8)))))
    (vector box drgnx-pixels-generation (frame-char-width frame) (frame-char-height frame) rounded
            (bound-and-true-p drgnx-look-icons) buttons width)))

(defun drgnx-chrome-switch-tab-click (event)
  "A click on the overflow button: choose one of the group's tabs."
  (interactive "e")
  (with-selected-window (posn-window (event-start event)) (call-interactively #'drgnx-chrome-switch-tab)))

(defun drgnx-chrome-split-click (event)
  "A click on the split button: a new editor group to the right, same file."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (when (fboundp 'drgnx-groups-split-right) (call-interactively #'drgnx-groups-split-right))))

(defun drgnx-chrome-switch-tab ()
  "Show one of this editor group's tabs, chosen by name."
  (interactive)
  (let* ((tabs (drgnx-chrome-tabs (selected-window)))
         (names (mapcar (lambda (b) (cons (buffer-name b) b)) tabs))
         (pick (and names (completing-read "Tab: " names nil t))))
    (when pick
      (set-window-buffer (selected-window) (cdr (assoc pick names)))
      (drgnx-chrome-apply nil t))))

(defun drgnx-chrome--tab-line (w)
  "W's tab line, tab by tab (`drgnx-chrome--tab').  On a graphical frame the row is `tab-row' high on the panel, two
pixels separate the tabs (a space on a terminal), and the overflow and split buttons are at the right."
  (let* ((shown (window-buffer w)) (active (eq w (drgnx-signal-editor-window))) (rows (drgnx-chrome--tab-rows w))
         (extent (and rows (drgnx-pixels-font-extent 'drgnx-chrome-tab (nth 2 rows)))))
    (concat (and rows extent (drgnx-pixels-spacer 'drgnx-chrome-tab (nth 0 rows) (+ (cdr extent) (nth 1 rows)) (nth 2 rows)))
            (mapconcat (lambda (b) (drgnx-chrome--tab w b (eq b shown) active rows))
                       (drgnx-chrome-tabs w)
                       (if rows
                           (propertize " " 'face 'drgnx-chrome-tab
                                       'display `(space :width (,(round (* (drgnx-pixels-scale (nth 2 rows)) drgnx-chrome--tab-gap)))))
                         " "))
            (and rows (drgnx-chrome--tab-buttons w rows)))))

(defcustom drgnx-chrome-closed-positions-max 30
  "How many closed tabs' positions are remembered (`drgnx-chrome-closed-positions')."
  :type 'integer :group 'drgnx)

(defvar drgnx-chrome-closed-positions nil
  "Where closed tabs were, most recent first: (FILE GROUP INDEX POINT), one entry per file.
GROUP is the editor window's index in its frame, INDEX the tab's place in its tab line, POINT where the
cursor was.  Recorded when a tab is really closed (not when it moves to another group).  Capped at
`drgnx-chrome-closed-positions-max'.  Reopen Closed Tab uses it to put a tab back.")

(defun drgnx-chrome--group-index (w)
  "W's index among its frame's editor windows (its editor group)."
  (let ((frame (window-frame w)))
    (or (seq-position (seq-filter (lambda (x) (eq (drgnx-chrome--role x) 'editor))
                                  (window-list-1 (frame-first-window frame) 'nomini frame))
                      w)
        0)))

(defun drgnx-chrome--record-closed-position (w b)
  "Remember where B, a file's tab in W, is (its group, tab index and point); call before really closing it."
  (when-let* ((file (buffer-file-name b)) (i (seq-position (drgnx-chrome-tabs w) b)))
    (setq drgnx-chrome-closed-positions
          (seq-take (cons (list file (drgnx-chrome--group-index w) i
                                (if (eq (window-buffer w) b) (window-point w) (with-current-buffer b (point))))
                          (seq-remove (lambda (e) (equal (car e) file)) drgnx-chrome-closed-positions))
                    drgnx-chrome-closed-positions-max))))

(defun drgnx-chrome--close (w b)
  "Take B out of W's tabs; if W shows it, show the tab used before it, else the tab to its right,
else its left, else *scratch*.  Moving a tab to another group uses this too, so it records nothing:
callers that really close a tab call `drgnx-chrome--record-closed-position' first."
  (let* ((tabs (drgnx-chrome-tabs w)) (rest (cdr (memq b tabs))) (before (seq-take-while (lambda (x) (not (eq x b))) tabs))
         (used (seq-find (lambda (x) (and (not (eq x b)) (memq x tabs))) (window-parameter w 'drgnx-tab-history))))
    (set-window-parameter w 'drgnx-tabs (remq b tabs))
    (set-window-parameter w 'drgnx-tab-history (remq b (window-parameter w 'drgnx-tab-history)))
    (drgnx-signal-post 'tabs-changed)
    (when (eq (window-buffer w) b)
      (set-window-buffer w (or used (car rest) (car (last before)) (get-scratch-buffer-create))))
    (drgnx-chrome-apply (window-frame w) t)))

(defun drgnx-chrome--killed ()
  "From `kill-buffer-hook': the buffer leaves every editor window's tabs at once, and a window that
shows it shows the tab used before it, else its neighbour (not whatever Emacs picks: after a restore it has no history).
An error here must never stop the kill."
  (let ((b (current-buffer)))
    (when (drgnx-chrome--tab-buffer-p b)          ; temp buffers: no work
      (with-demoted-errors "drgnx chrome: %S"
        (dolist (w (seq-filter (lambda (w) (and (eq (drgnx-chrome--role w) 'editor)
                                                (or (eq (window-buffer w) b) (memq b (window-parameter w 'drgnx-tabs)))))
                               (window-list-1 nil 'nomini t)))
          (drgnx-chrome--record-closed-position w b)
          (drgnx-chrome--close w b))))))

(defun drgnx-chrome-close-tab ()
  "Close the shown tab (the buffer stays open; Close in the Buffers panel closes it)."
  (interactive)
  (drgnx-chrome--record-closed-position (selected-window) (window-buffer))
  (drgnx-chrome--close (selected-window) (window-buffer)))

(defun drgnx-chrome--step (n)
  (let* ((tabs (drgnx-chrome-tabs (selected-window))) (i (seq-position tabs (window-buffer))))
    (when (and tabs i)
      (set-window-buffer (selected-window) (nth (mod (+ i n) (length tabs)) tabs))
      (drgnx-chrome-apply nil t))))

(defun drgnx-chrome-next-tab () "Show the next tab (wraps)." (interactive) (drgnx-chrome--step 1))
(defun drgnx-chrome-previous-tab () "Show the previous tab (wraps)." (interactive) (drgnx-chrome--step -1))

;;;; Breadcrumbs

(defvar-local drgnx-chrome--root nil "(DEFAULT-DIRECTORY . PROJECT-ROOT-or-nil), looked up once.")

(defun drgnx-chrome--project-root (file)
  "The project root of the current buffer (FILE), cached: outside a repository the lookup walks the tree."
  (unless (equal (car drgnx-chrome--root) default-directory)
    (setq drgnx-chrome--root
          (cons default-directory
                (unless (file-remote-p file)
                  (when-let* ((p (let ((non-essential t)) (project-current)))) (project-root p))))))
  (cdr drgnx-chrome--root))

(defvar drgnx-chrome-short-breadcrumb-functions nil
  "Functions of a window: when one returns non-nil the breadcrumb shows only the file name (the header's tail has
something to say: the agent line).  Re-apply the chrome after the answer changes.")

(defun drgnx-chrome-breadcrumb (w)
  "W's breadcrumb: project › folders › file (● when unsaved).  A buffer without a file has no path to show and its tab
already names it: the row stays (a window's rows never change with its buffer, I3) but is empty."
  (let* ((b (window-buffer w)) (file (buffer-file-name b))
         (frame (window-frame w))
         (height (and (display-graphic-p frame)
                      (round (* (drgnx-pixels-scale frame) drgnx-chrome--breadcrumb-row))))
         (extent (and height (drgnx-pixels-font-extent 'drgnx-ui-caption frame)))
         (s (concat
             (or (and extent (drgnx-pixels-spacer 'drgnx-ui-caption height
                                                  (+ (cdr extent) (/ (- height (car extent) (cdr extent)) 2)) frame))
                 "")
             " "
             (if (not file)
                 ""
               (let* ((short (run-hook-with-args-until-success 'drgnx-chrome-short-breadcrumb-functions w))
                      (root (and (not short) (with-current-buffer b (drgnx-chrome--project-root file))))
                      (rel (cond (short (file-name-nondirectory file))
                                 (root (file-relative-name file root))
                                 (t (abbreviate-file-name file))))
                      (parts (split-string rel "/" t)))
                 (concat (if root (propertize (concat (drgnx-chrome--text (file-name-nondirectory (directory-file-name root))) " › ")
                                              'face 'drgnx-chrome-crumb)
                           "")
                         (propertize (mapconcat #'drgnx-chrome--text (butlast parts) " › ") 'face 'drgnx-chrome-crumb)
                         (if (cdr parts) (propertize " › " 'face 'drgnx-chrome-crumb) "")
                         (propertize (drgnx-chrome--text (car (last parts))) 'face 'drgnx-text-muted))))
             (if (and file (buffer-modified-p b)) " ●" ""))))
    (add-face-text-property 0 (length s) 'drgnx-ui-caption t s)
    s))

;;;; Applying

(defconst drgnx-chrome--mode-line '(:eval (or mode-line-format (default-value 'mode-line-format)))
  "An editor window's mode line: its buffer's, or the default when the buffer has none.")

(defvar drgnx-chrome-editor-mode-line drgnx-chrome--mode-line
  "The mode line of an editor window: the buffer's own by default; the status bar (modules/ui/drgnx-statusbar.el)
sets it to its own construct while it is on.  Re-apply the chrome after changing it.")

(defvar drgnx-chrome-header-tail nil
  "A mode-line construct an editor window's header shows after its breadcrumb — set buffer-locally (sticky scroll's
scopes: modules/editor/drgnx-sticky.el); re-apply the chrome after changing it.")

(defvar drgnx-chrome-tail-providers nil
  "Functions of a window, in depth order (lowest first), each returning a string the header shows after the breadcrumb,
or nil.  A string must be safe for the mode line (a `%' doubled).  Add and remove with
`drgnx-chrome-add-tail-provider' and `drgnx-chrome-remove-tail-provider'.  A provider answers from cached state: it
runs in redisplay.")

(defconst drgnx-chrome--providers-tail '(:eval (drgnx-chrome--tail-string (selected-window)))
  "The header's tail while there are providers: what they return, in order.")

(defun drgnx-chrome--tail-string (w)
  "The providers' strings for window W, joined."
  (let (out)
    (dolist (fn drgnx-chrome-tail-providers)
      (let ((s (condition-case nil (funcall fn w) (error nil))))
        (when (and (stringp s) (not (string-empty-p s))) (push s out))))
    (apply #'concat (nreverse out))))

(defun drgnx-chrome--reapply ()
  (when (bound-and-true-p drgnx-chrome-mode)
    (dolist (f (frame-list)) (drgnx-chrome-apply f))))

(defun drgnx-chrome-add-tail-provider (fn depth)
  "Show FN's string after the breadcrumb; lower DEPTH comes first (the large-files header 10, sticky scroll 20, the
agent line 30).  Adding FN again moves it to its new depth."
  (put fn 'drgnx-chrome-tail-depth depth)
  (setq drgnx-chrome-tail-providers
        (sort (cons fn (delq fn (copy-sequence drgnx-chrome-tail-providers)))
              (lambda (a b) (< (get a 'drgnx-chrome-tail-depth) (get b 'drgnx-chrome-tail-depth)))))
  (drgnx-chrome--reapply))

(defun drgnx-chrome-remove-tail-provider (fn)
  "Stop showing FN's string."
  (setq drgnx-chrome-tail-providers (delq fn (copy-sequence drgnx-chrome-tail-providers)))
  (put fn 'drgnx-chrome-tail-depth nil)
  (drgnx-chrome--reapply))

(defconst drgnx-chrome--own-header '(:eval header-line-format)
  "The header of a buffer that has its own (tabulated-list column headings, clicked to sort).")

(defun drgnx-chrome--set (w param value)
  "Set W's line format PARAM (`tab-line-format', `header-line-format', `mode-line-format') to VALUE only if it
changed, and then have W's lines drawn again: Emacs redraws a window for a new parameter only when a face filter names
it, so without this the next redisplay may keep the old line (the window's text unchanged)."
  (unless (equal-including-properties (window-parameter w param) value)
    (set-window-parameter w param value)
    (with-current-buffer (window-buffer w) (force-mode-line-update))))

(defun drgnx-chrome--apply-window (w note)
  (pcase (drgnx-chrome--role w)
    ('editor
     (when note (drgnx-chrome--note w))
     (drgnx-chrome--set w 'tab-line-format (let ((s (drgnx-chrome--tab-line w))) (if (equal s "") " " s)))
     (drgnx-chrome--set w 'header-line-format
                        (with-current-buffer (window-buffer w)
                          (cond ((and (local-variable-p 'header-line-format) header-line-format)
                                 drgnx-chrome--own-header)
                                ;; a short terminal frame has no row to spare (ui/terminal-layout sets this)
                                ((eq (frame-parameter (window-frame w) 'drgnx-chrome-breadcrumb) 'off) 'none)
                                (t (let ((tail (buffer-local-value 'drgnx-chrome-header-tail (window-buffer w)))
                                         (providers (and drgnx-chrome-tail-providers drgnx-chrome--providers-tail)))
                                     (if (or tail providers)
                                         (delq nil (list (drgnx-wb-bar (drgnx-chrome-breadcrumb w) t) providers tail
                                                         (propertize " " 'display '(space :align-to right) 'face 'drgnx-wb-bar)))
                                       (drgnx-wb-bar (drgnx-chrome-breadcrumb w))))))))
     (drgnx-chrome--set w 'mode-line-format drgnx-chrome-editor-mode-line))
    ((or 'dock 'area)
     (drgnx-chrome--set w 'tab-line-format 'none)
     (drgnx-chrome--set w 'mode-line-format 'none))
    ('lane
     (dolist (p '(tab-line-format mode-line-format)) (drgnx-chrome--set w p 'none)))))

(defun drgnx-chrome-apply (&optional frame note)
  "Set every window's chrome on FRAME (default: the selected one) by its role; NOTE: also add the
shown buffers to their windows' tabs."
  (unless (frame-parent frame)
    (dolist (w (window-list frame 'nomini)) (drgnx-chrome--apply-window w note))))

(defun drgnx-chrome--refresh (&rest _)
  "On a bus edge: tabs and breadcrumbs of every frame (no new tabs while the minibuffer is active:
those are previews)."
  (let ((note (not (active-minibuffer-window))))
    (dolist (f (frame-list)) (drgnx-chrome-apply f note))))

(defvar drgnx-chrome--memo (make-hash-table :test 'eq :weakness 'key)
  "Editor window -> [BUFFER TABS BREADCRUMB-PARAM TAB-LINE HEADER MODE-LINE NOTED ROWS]: what the store's subscribers
last set on it (weak on the window), ROWS the frame's `drgnx-chrome--rows-key'.  They skip a window whose inputs and
parameters are still those objects, so a change that touches no editor costs a few `eq' tests per window, not two
strings built.  The bus's edges and `drgnx-chrome-apply' always rebuild.")

(defun drgnx-chrome--rows-key (frame)
  "An integer that moves when FRAME's rows change size: the tab row in its pixels (the density at its scale) and its
line height.  0 on a terminal.  Allocates nothing."
  (if (display-graphic-p frame)
      (+ (round (* (drgnx-pixels-scale frame) (if (fboundp 'drgnx-look-density-value) (drgnx-look-density-value 'tab-row) 34)))
         (* 1000 (frame-char-height frame)))
    0))

(defun drgnx-chrome--memo-current-p (w note breadcrumb rows)
  "Non-nil when editor window W still shows what the store's subscribers last set on it (with its buffer noted
as a tab, if NOTE; BREADCRUMB is its frame's parameter `drgnx-chrome-breadcrumb', ROWS its `drgnx-chrome--rows-key')."
  (let ((m (gethash w drgnx-chrome--memo)))
    (and m
         (or (not note) (aref m 6))
         (eq (aref m 0) (window-buffer w))
         (eq (aref m 1) (window-parameter w 'drgnx-tabs))
         (eq (aref m 2) breadcrumb)
         (eq (aref m 3) (window-parameter w 'tab-line-format))
         (eq (aref m 4) (window-parameter w 'header-line-format))
         (eq (aref m 5) (window-parameter w 'mode-line-format))
         (eq (aref m 5) drgnx-chrome-editor-mode-line)
         (eql (aref m 7) rows))))

(defun drgnx-chrome--memo-set (w note breadcrumb rows)
  (puthash w (vector (window-buffer w) (window-parameter w 'drgnx-tabs) breadcrumb
                     (window-parameter w 'tab-line-format) (window-parameter w 'header-line-format)
                     (window-parameter w 'mode-line-format) (and note t) rows)
           drgnx-chrome--memo))

(defun drgnx-chrome--apply-changed (frame note)
  "Set the chrome of FRAME's windows that need it (`drgnx-chrome-apply' for the ones whose inputs changed).
The store lists the editor windows; the other roles are set as `drgnx-chrome-apply' does."
  (unless (frame-parent frame)
    (let ((editors (drgnx-state-windows frame 'editor))
          (breadcrumb (frame-parameter frame 'drgnx-chrome-breadcrumb))
          (rows (drgnx-chrome--rows-key frame)))
      (dolist (w (window-list frame 'nomini))
        (if (not (memq w editors))
            (drgnx-chrome--apply-window w note)
          (unless (drgnx-chrome--memo-current-p w note breadcrumb rows)
            (drgnx-chrome--apply-window w note)
            (drgnx-chrome--memo-set w note breadcrumb rows)))))))

(defun drgnx-chrome--rows-changed ()
  "On `drgnx-look-density-changed-hook': every frame's tab rows at the new height, at once."
  (dolist (f (frame-list)) (when (frame-live-p f) (drgnx-chrome--apply-changed f nil))))

(defun drgnx-chrome--frame-resized (data)
  "The store's `frame-resized': a scale change resizes the frame, so its tab rows are made again in its pixels (only
the editors whose rows key moved)."
  (when-let* ((frame (plist-get data :frame)) ((frame-live-p frame)))
    (drgnx-chrome--apply-changed frame nil)))

(defun drgnx-chrome--windows-changed (data)
  "The store's `windows-changed' (`now' lane: inside the observation, before the frame is drawn): set the
chrome of the frame's windows, so a new window is never drawn once without it."
  (drgnx-chrome--apply-changed (plist-get data :frame) nil))

(defun drgnx-chrome--editor-changed (data)
  "The store's `editor-changed' (`now' lane): the tab lines and breadcrumbs of the frame whose editor window
or buffer changed (no new tabs while the minibuffer is active: those are previews)."
  (drgnx-chrome--apply-changed (plist-get data :frame) (not (active-minibuffer-window))))

(define-minor-mode drgnx-chrome-mode
  "Chrome by role: tab lines and breadcrumbs in editor windows, titles only elsewhere."
  :global t :group 'drgnx
  (if drgnx-chrome-mode
      (progn
        (drgnx-state-subscribe 'windows-changed #'drgnx-chrome--windows-changed :lane 'now)
        (drgnx-state-subscribe 'editor-changed #'drgnx-chrome--editor-changed :lane 'now)
        (drgnx-state-subscribe 'frame-resized #'drgnx-chrome--frame-resized)
        (add-hook 'drgnx-look-density-changed-hook #'drgnx-chrome--rows-changed)
        (add-hook 'kill-buffer-hook #'drgnx-chrome--killed)
        (dolist (e '(buffer-set-changed modified-changed))
          (drgnx-signal-subscribe e #'drgnx-chrome--refresh))
        (drgnx-chrome--refresh))
    (drgnx-state-unsubscribe 'windows-changed #'drgnx-chrome--windows-changed)
    (drgnx-state-unsubscribe 'editor-changed #'drgnx-chrome--editor-changed)
    (drgnx-state-unsubscribe 'frame-resized #'drgnx-chrome--frame-resized)
    (remove-hook 'drgnx-look-density-changed-hook #'drgnx-chrome--rows-changed)
    (clrhash drgnx-chrome--memo)
    (remove-hook 'kill-buffer-hook #'drgnx-chrome--killed)
    (dolist (e '(buffer-set-changed modified-changed))
      (drgnx-signal-unsubscribe e #'drgnx-chrome--refresh))
    (dolist (f (frame-list))
      (dolist (w (window-list f 'nomini))
        (pcase (drgnx-chrome--role w)
          ('editor (dolist (p '(tab-line-format header-line-format mode-line-format)) (set-window-parameter w p nil)))
          ((or 'dock 'area 'lane) (dolist (p '(tab-line-format mode-line-format)) (set-window-parameter w p nil))))))))

(provide 'drgnx-chrome)
;;; drgnx-chrome.el ends here
