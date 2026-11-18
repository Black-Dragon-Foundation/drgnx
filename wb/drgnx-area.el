;;; drgnx-area.el --- Tabbed areas: the bottom panel and the right dock -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; An area is one side window whose buffer is swapped in place: the bottom **panel** (tabs
;; Terminal, Problems, Output, Results, Help) and the **right dock** (agents, chat, … — tabs come
;; with their modules).  Showing a tab never selects the area, keeps the window (so nothing
;; around it moves) and puts back the tab's buffer, start and point as they were left.  The tab
;; row lives in the `header-line-format' window parameter, so no mode can erase it; the area's
;; pixel size is kept across hiding and showing.  Killing the buffer an area shows puts the tab's
;; placeholder there — another buffer never slips into the area.  See docs/guide/workbench.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-rules)
(require 'drgnx-modules-helpers)
(require 'drgnx-wb)
(require 'drgnx-state-intent)
(require 'tab-line)                     ; the tab faces we inherit
(require 'drgnx-ui-kit)                 ; the tabs: `drgnx-ui-kit-tab'

(defvar drgnx-wb--areas nil "Alist AREA → plist (:side SIDE :size N :lone LONE :tabs ((TAB . PLIST) …)).")

(cl-defun drgnx-wb-define-area (area &key side size lone)
  "Define AREA on SIDE (`bottom' or `right'), SIZE lines or columns the first time it shows.  LONE non-nil: no tab
row while the shown tab is the only one with content (`drgnx-area--lone-p')."
  (setf (alist-get area drgnx-wb--areas)
        (list :side side :size size :lone lone :tabs (plist-get (alist-get area drgnx-wb--areas) :tabs)))
  area)

(cl-defun drgnx-wb-define-tab (area tab &key title icon placeholder start actions companions empty contextual content)
  "Add TAB to AREA, titled TITLE; ICON (an icon name, `drgnx-look-icon') shows before the title; PLACEHOLDER returns
the buffer shown while the tab has none.  START, a function of no arguments, makes the tab's buffer when a click on
the tab finds none (VS Code's Terminal tab opens a terminal); the rules show what it makes in the tab.
ACTIONS, a function of no arguments, returns the tab's own pieces (a string, or nil for none), drawn at the right of
the tab row before its ✕ while the tab is shown; the tab's module calls `drgnx-wb-area-redraw' when they change.
COMPANIONS, a function of the tab's buffer, returns (ABOVE BELOW): the buffers shown in windows of their own above
and below it, each nil for none (an area on the left or right only; see \"Companions\" below).
EMPTY, a string, is what the default placeholder says while the tab has no buffer (what appears here and how); the
placeholder is never blank.  CONTEXTUAL non-nil: the tab is in the tab row only while it is the shown tab or has a
buffer of its own, so the row is the same whenever the modules that define such tabs were set up.
CONTENT, a function of no arguments, returns the buffer the tab shows when it has none saved (Problems lists the
problems, Output shows Messages, the Debug Console its console): the tab is never an empty page; nil from it falls
back to the placeholder.
Called from a module's setup, the definition claims the tab and records its undo: the tab it
replaced put back in the same place, or `drgnx-wb-undefine-tab' — only while the tab is still the one
defined here.  Two modules defining the same tab may be torn down in either order."
  (let* ((rec (drgnx-modules--recording-p))
         (spec (alist-get area drgnx-wb--areas)) (tabs (copy-alist (plist-get spec :tabs)))
         (previous (cdr (assq tab tabs)))
         (props (list :title (or title (capitalize (symbol-name tab))) :icon icon :placeholder placeholder
                      :start start :actions actions :companions companions
                      :empty empty :contextual contextual :content content)))
    (if (assq tab tabs) (setf (alist-get tab tabs) props)
      (setq tabs (append tabs (list (cons tab props)))))         ; in the order they are defined
    (setf (alist-get area drgnx-wb--areas) (plist-put spec :tabs tabs))
    (when rec
      (let* ((target (list 'tab area tab)) (box (drgnx-module--claim target previous)))
        (drgnx-modules-push-undo
         (format "tab %s/%s" area tab)
         (lambda ()
           (drgnx-module--release
            target box
            (lambda () (eq (cdr (assq tab (plist-get (alist-get area drgnx-wb--areas) :tabs))) props))
            (lambda (prev)
              (if prev (drgnx-area--restore-tab area tab prev) (drgnx-wb-undefine-tab area tab))))))))
    tab))

(defun drgnx-area--restore-tab (area tab props)
  "Put TAB's PROPS back in AREA, keeping its place in the row, and redraw the row.
A window that shows the tab's current placeholder (the module's) shows the restored tab's instead."
  (let (swap)
    (dolist (frame (frame-list))
      (with-selected-frame frame
        (when-let* ((w (drgnx-wb-area-window area)) ((eq (drgnx-wb-area-tab area) tab))
                    ((eq (window-buffer w) (drgnx-area--placeholder area tab))))
          (let ((state (copy-sequence (drgnx-area--state area))))
            (drgnx-area--set-state
             area (plist-put state :tabs (assq-delete-all tab (copy-alist (plist-get state :tabs))))))
          (push (cons frame w) swap))))
    (let* ((spec (alist-get area drgnx-wb--areas)) (tabs (copy-alist (plist-get spec :tabs))))
      (setf (alist-get tab tabs) props)
      (setf (alist-get area drgnx-wb--areas) (plist-put spec :tabs tabs)))
    (pcase-dolist (`(,frame . ,w) swap)
      (with-selected-frame frame
        (let ((placeholder (drgnx-area--placeholder area tab)))
          (drgnx-wb-set-area-buffer w placeholder)
          (drgnx-area--companions area w placeholder))))
    (drgnx-area--redraw-rows area)))

(defun drgnx-area--redraw-rows (area)
  "Redraw AREA's tab row in every frame that shows it."
  (dolist (frame (frame-list))
    (when-let* ((w (drgnx-wb-area-window area frame)))
      (with-selected-frame frame (drgnx-area--put-row area w)))))

(defun drgnx-wb-area-redraw (area)
  "Draw AREA's tab row again in every frame that shows it: its shown tab's actions changed."
  (drgnx-area--redraw-rows area))

(defun drgnx-wb-undefine-tab (area tab)
  "Remove TAB from AREA.  Where the area shows TAB it shows the next tab instead (the one before,
for the last), or hides when TAB was its only one; the frame's saved buffer for TAB is dropped.
Returns non-nil when TAB was defined."
  (let* ((tabs (plist-get (alist-get area drgnx-wb--areas) :tabs))
         (names (mapcar #'car tabs)) (pos (seq-position names tab))
         (next (and pos (or (nth (1+ pos) names) (and (> pos 0) (nth (1- pos) names))))))
    (when pos
      (setf (alist-get area drgnx-wb--areas)
            (plist-put (alist-get area drgnx-wb--areas) :tabs (assq-delete-all tab (copy-alist tabs))))
      (dolist (frame (frame-list))
        (with-selected-frame frame
          (let ((shown (or (plist-get (drgnx-area--state area) :tab) (car names))))
            ;; Show the next tab (or hide) first: the area remembers the buffer it leaves under the shown tab.
            (when (and (eq shown tab) (drgnx-wb-area-window area))
              (if next (drgnx-wb-area-show area next) (drgnx-wb-area-hide area)))
            (when-let* ((state (drgnx-area--state area)))
              (drgnx-area--set-state
               area (plist-put (plist-put (copy-sequence state) :tabs (assq-delete-all tab (copy-alist (plist-get state :tabs))))
                               :tab (if (eq (plist-get state :tab) tab) next (plist-get state :tab))))))))
      (drgnx-area--redraw-rows area))
    (and pos t)))

(defun drgnx-wb-area-window (area &optional frame)
  "The window showing AREA on FRAME (default: `drgnx-wb-frame'), or nil: its tab's buffer, never a companion."
  (seq-find (lambda (w) (and (eq (window-parameter w 'drgnx-role) area) (not (window-parameter w 'drgnx-area-part))))
            (window-list (or frame (drgnx-wb-frame)) 'nomini)))

;;;; Per-frame state: the shown tab, and each tab's buffer, start and point

(defun drgnx-area--state (area)
  (alist-get area (frame-parameter nil 'drgnx-wb-areas)))

(defun drgnx-area--set-state (area state)
  (let ((all (copy-alist (frame-parameter nil 'drgnx-wb-areas))))
    (setf (alist-get area all) state)
    (set-frame-parameter nil 'drgnx-wb-areas all)))

(defun drgnx-wb-area-tab (area)
  "The tab AREA shows (or showed last), or its first tab."
  (or (plist-get (drgnx-area--state area) :tab)
      (car (car (plist-get (alist-get area drgnx-wb--areas) :tabs)))))

(defun drgnx-area--remember (area window)
  "Remember the buffer, start and point WINDOW shows, for AREA's shown tab, and, when that buffer is a hub view's twin
in another display class (`drgnx-view-patch-twin-of'), the view's own buffer: the twin goes when no window shows its
class, and the tab then comes back with the view's buffer (the env's routing makes the twin again where it is needed).
A view that opens at its tail (`drgnx-view-sja-tail') left with point at its end is remembered at `end': it comes
back at the end it has then, so it follows again."
  (when (window-live-p window)
    (let* ((state (drgnx-area--state area)) (tabs (copy-alist (plist-get state :tabs)))
           (buffer (window-buffer window)))
      (setf (alist-get (drgnx-wb-area-tab area) tabs)
            (list buffer (window-start window)
                  (if (with-current-buffer buffer
                        (and (bound-and-true-p drgnx-view-sja-tail) (= (window-point window) (point-max))))
                      'end
                    (window-point window))
                  (and (local-variable-p 'drgnx-view-patch-twin-of buffer)
                       (buffer-local-value 'drgnx-view-patch-twin-of buffer))))
      (drgnx-area--set-state area (plist-put (copy-sequence state) :tabs tabs)))))

(defvar-local drgnx-area--placeholder-p nil "Non-nil in a buffer an area shows for a tab that has none of its own.")
(put 'drgnx-area--placeholder-p 'permanent-local t)

(defun drgnx-area--placeholder (area tab)
  (let* ((fn (plist-get (alist-get tab (plist-get (alist-get area drgnx-wb--areas) :tabs)) :placeholder))
         (buf (if fn (funcall fn)
                (or (get-buffer (format " *drgnx %s*" (or tab area)))
                    (with-current-buffer (get-buffer-create (format " *drgnx %s*" (or tab area)) t)
                      (special-mode)
                      (current-buffer))))))
    (drgnx-area--say-empty buf (plist-get (alist-get tab (plist-get (alist-get area drgnx-wb--areas) :tabs)) :empty))
    (with-current-buffer buf (setq drgnx-area--placeholder-p t))
    buf))

(defun drgnx-area--content (area tab)
  "TAB's `:content' buffer (`drgnx-wb-define-tab'), or nil: none defined, its module not loaded, or it gave no buffer."
  (when-let* ((fn (plist-get (alist-get tab (plist-get (alist-get area drgnx-wb--areas) :tabs)) :content))
              ((functionp fn)))
    (let ((b (ignore-errors (funcall fn)))) (and (buffer-live-p b) b))))

(defun drgnx-area--say-empty (buffer text)
  "Put TEXT (a tab's :empty line) in BUFFER when it is a blank placeholder of ours, and draw no cursor in it."
  (with-current-buffer buffer
    (when (and (stringp text) (zerop (buffer-size)) (derived-mode-p 'special-mode))
      (let ((inhibit-read-only t))
        (insert (propertize text 'face 'shadow) "\n")))
    (when (derived-mode-p 'special-mode) (setq-local cursor-type nil))))

(defun drgnx-area--content-p (buffer)
  (and (buffer-live-p buffer) (not (buffer-local-value 'drgnx-area--placeholder-p buffer))))

(defun drgnx-area--lone-p (area)
  "Whether AREA's shown tab is the only one with content: its window shows a buffer of its own (not a placeholder)
and no other tab left one."
  (let ((shown (drgnx-wb-area-tab area)) (w (drgnx-wb-area-window area)))
    (and w (drgnx-area--content-p (window-buffer w))
         (not (seq-some (lambda (saved) (and (not (eq (car saved) shown))
                                             (drgnx-area--content-p (drgnx-area--saved-buffer (cdr saved)))))
                        (plist-get (drgnx-area--state area) :tabs))))))

(defun drgnx-area--saved-buffer (saved)
  "The buffer a tab's SAVED place (BUFFER START POINT VIEW-BUFFER, `drgnx-area--remember') shows again: BUFFER while
it lives, else the view's buffer of the twin it was, else nil."
  (cond ((buffer-live-p (car saved)) (car saved))
        ((buffer-live-p (nth 3 saved)) (nth 3 saved))))

;;;; The tab row

(defun drgnx-area--tab-listed-p (area tab shown)
  "Whether TAB is in AREA's tab row: always, but for a contextual tab (`drgnx-wb-define-tab'), which is there while it
is SHOWN or has a buffer of its own."
  (or (not (plist-get (alist-get tab (plist-get (alist-get area drgnx-wb--areas) :tabs)) :contextual))
      (eq tab shown)
      (drgnx-area--content-p
       (drgnx-area--saved-buffer (alist-get tab (plist-get (drgnx-area--state area) :tabs))))))

(defun drgnx-area--tab-click (event)
  "Show the tab clicked in an area's tab row; a tab with no buffer of its own and a START (`drgnx-wb-define-tab')
makes one."
  (interactive "e")
  (let* ((posn (event-start event)) (s (posn-string posn)))
    (when-let* ((s) (spec (get-text-property (cdr s) 'drgnx-tab (car s))))
      (let ((w (drgnx-wb-area-show (car spec) (cdr spec)))
            (start (plist-get (alist-get (cdr spec) (plist-get (alist-get (car spec) drgnx-wb--areas) :tabs)) :start)))
        (when (and start (window-live-p w) (not (drgnx-area--content-p (window-buffer w))))
          (funcall start))))))

(declare-function drgnx-grid-tab-menu-click "drgnx-grid-frames" (event))
(defvar drgnx-area--tab-map
  (let ((m (make-sparse-keymap)))
    (define-key m [header-line mouse-1] #'drgnx-area--tab-click)
    (define-key m [header-line mouse-3] #'drgnx-grid-tab-menu-click) ; its menu: Move to New Window
    m))

(defun drgnx-area--close-click (event)
  "A click on an area's ✕: hide the area (its size and tabs are kept)."
  (interactive "e")
  (when-let* ((s (posn-string (event-start event)))
              (area (get-text-property (cdr s) 'drgnx-area (car s))))
    (drgnx-wb-area-hide area)))

(defvar-local drgnx-area-own-title nil
  "Non-nil in a buffer that draws its own title row (the Work space's tiles): an area shows no tab row over it.  A
string is the title the area draws itself, in its row with the area's close, in place of the tabs.")

(defconst drgnx-area--tab-row-px 32 "An area's tab row height in logical pixels (debugging.html `.ptabs').")
(defconst drgnx-area--pill-px 24 "The shown panel tab's pill height in logical pixels (debugging.html `.pt').")

(declare-function drgnx-theme--box-fit-pad-p "drgnx-theme-gen")

(defun drgnx-area--tab-row-parts (frame)
  "(SPACER PILL RULE) for a tab row on a graphical FRAME, else nil.  SPACER is the one-pixel character that makes the
row `drgnx-area--tab-row-px' tall with the tabs' text in its middle (the kit gives that text its own size once,
`drgnx-ui-kit--line-sizes').  PILL, where boxes fit their text with a pad (Glitnir), the face that fits the shown
tab's box and fill to `drgnx-area--pill-px' round its text: the kit face's box (its width and radius) drawn in the
face's own background (the kit's ring is in that colour), else nil.  RULE, laid over the whole row, the hairline
under it (debugging.html `.ptabs' border-bottom): an underline in `drgnx-border-subtle' on the row's last pixels, or
nil when the theme gives that face no colour."
  (when-let* (((display-graphic-p frame))
              (face 'drgnx-kit-tab-panel-current)
              (extent (drgnx-pixels-font-extent face frame)))
    (let* ((row (drgnx-px drgnx-area--tab-row-px frame))
           (box (face-attribute face :box frame t))
           (rule (face-foreground 'drgnx-border-subtle frame t)))
      (list (drgnx-pixels-spacer 'drgnx-wb-bar row (+ (cdr extent) (drgnx-pixels-box-height face row frame)) frame)
            (and (consp box) (fboundp 'drgnx-theme--box-fit-pad-p) (drgnx-theme--box-fit-pad-p)
                 (list :box (append (cl-loop for (k v) on box by #'cddr unless (memq k '(:color :style :fit))
                                             append (list k v))
                                    (list :style 'flat-button
                                          :fit (cons 'text (drgnx-pixels-box-height
                                                            face (drgnx-px drgnx-area--pill-px frame) frame))))))
            ;; `:position' 0: on the row's last pixels (as the editor's tab row, `drgnx-chrome--tab-paint')
            (and (stringp rule) (list :underline `(:color ,rule :position 0)))))))

(defun drgnx-area--tab-row (area &optional frame)
  "AREA's tab row, ending in the ✕ that hides it; set as a window parameter, so it is built when the tab changes.
Its pads are in the pixels of FRAME (default the workbench's), the frame the row is drawn in.
`none' (no row) in an area defined with LONE while its shown tab is the only one with content, and over a buffer with
its own title (`drgnx-area-own-title')."
  (let* ((shown (drgnx-wb-area-tab area)) (tabs (plist-get (alist-get area drgnx-wb--areas) :tabs))
         (fn (plist-get (alist-get shown tabs) :actions))
         (actions (and fn (funcall fn)))
         (w (drgnx-wb-area-window area)))
    (if (or (and w (buffer-local-value 'drgnx-area-own-title (window-buffer w)))
            (and (plist-get (alist-get area drgnx-wb--areas) :lone) (drgnx-area--lone-p area)))
        (let ((own (and w (buffer-local-value 'drgnx-area-own-title (window-buffer w)))))
          (if (stringp own) (drgnx-area--row-with-close own area frame) 'none))
      (let ((parts (drgnx-area--tab-row-parts (or frame (drgnx-wb-frame)))))
        (drgnx-area--row-with-close
         (concat
          ;; the row's height (32 px, the tabs' text in its middle)
          (or (car parts) "")
          ;; under the grid the area is a docked tile: its grip drags it (`drgnx-grid-drag')
          (if (and (bound-and-true-p drgnx-grid-mode) (fboundp 'drgnx-grid--grip)) (drgnx-grid--grip (and w (window-frame w))) "")
          (mapconcat (lambda (tab)
                       ;; the kit's panel tab (debugging.html `.pt'): the icon at 14 px, coloured as the title, the shown
                       ;; one a 24 px pill on the quiet selection in the 32 px row
                       (let ((s (drgnx-ui-kit-tab (plist-get (cdr tab) :title) 'panel (if (eq (car tab) shown) 'selected 'rest)
                                                  (plist-get (cdr tab) :icon) nil 'header-line nil (or frame (drgnx-wb-frame)))))
                         (add-text-properties 0 (length s) (list 'drgnx-tab (cons area (car tab)) 'mouse-face 'drgnx-hover
                                                                 'local-map drgnx-area--tab-map 'help-echo "Show this tab")
                                              s)
                         (when (and (eq (car tab) shown) (nth 1 parts)) (add-face-text-property 0 (length s) (nth 1 parts) nil s))
                         s))
                     (seq-filter (lambda (tab) (drgnx-area--tab-listed-p area (car tab) shown)) tabs) " ")
          (drgnx-area--actions actions area frame))
         area frame (nth 2 parts))))))

(defun drgnx-area--close (area)
  "AREA's close on its tab row: the kit's close button (face, click, help), drawn as the Lucide x at 16 px
\(debugging.html `.ptabs .ib') where icons are images."
  (let ((b (drgnx-wb-close-button #'drgnx-area--close-click "Close (Esc, q)" 'drgnx-area area))
        (icon (drgnx-look-icon 'x 'drgnx-ui-close 16)))
    (if-let* ((img (get-text-property 0 'display icon))) (propertize b 'display img) b)))

(defun drgnx-area--row-with-close (title area &optional frame rule)
  "TITLE, then AREA's close at the right edge, 8 px in (`.ptabs' padding), on the bar.  The pads are FRAME's pixels.
RULE, a face or nil, is laid over the whole row, the close and the filler too (the tab row's hairline)."
  (let* ((close (drgnx-area--close area))
         (row (drgnx-wb-bar (concat title (propertize " " 'display `(space :align-to (- right (,(drgnx-area--close-px close frame)))))
                                    ;; the pad is the button's too: a click at the row's edge closes
                                    close (apply #'propertize " " 'display `(space :width (,(drgnx-area--pad 8 frame)))
                                                 (cl-loop for (k v) on (text-properties-at 0 close) by #'cddr
                                                          unless (eq k 'display) append (list k v))))
                            t)))
    (when rule (add-face-text-property 0 (length row) rule nil row))
    row))

(defun drgnx-area--pad (px &optional frame)
  "PX logical pixels in FRAME's pixels (default the workbench's frame) on a graphical frame, else one column."
  (let ((frame (or frame (drgnx-wb-frame))))
    (if (display-graphic-p frame) (drgnx-px px frame) (frame-char-width frame))))

(defun drgnx-area--bar-px (string)
  "STRING's width in pixels as the bar draws it: under `drgnx-wb-bar' (the UI font), not the buffer's default."
  (let ((s (copy-sequence string)))
    (add-face-text-property 0 (length s) 'drgnx-wb-bar t s)
    (string-pixel-width s)))

(defun drgnx-area--close-px (close &optional frame)
  "The pixels CLOSE and the row's right pad take, the pad in FRAME's."
  (+ (drgnx-area--bar-px close) (drgnx-area--pad 8 frame)))

(defun drgnx-area--actions (actions area &optional frame)
  "ACTIONS (a string, or nil) right-aligned before AREA's close: a space to the right edge less their pixel width and
the close's, then the pieces."
  (if (or (null actions) (string-empty-p actions)) ""
    (let ((close (drgnx-area--close area)))
      (concat (propertize " " 'display `(space :align-to (- right (,(+ (drgnx-area--bar-px actions) (drgnx-area--close-px close frame)
                                                                       (drgnx-area--pad 4 frame))))))
              actions))))

;;;; Show, hide

(defun drgnx-area--px-param (area) (intern (format "drgnx-wb-%s-px" area)))

(defun drgnx-area--horizontal-p (area) (memq (plist-get (alist-get area drgnx-wb--areas) :side) '(left right)))

(declare-function drgnx-grid-delete-part "drgnx-grid" (part))
(declare-function drgnx-grid--grip "drgnx-grid" (&optional frame))
(defvar drgnx-grid-mode)
(declare-function drgnx-grid-split-dock "drgnx-grid" (dock &optional px frame kinds))
(declare-function drgnx-grid-add-part "drgnx-grid" (window side &optional px))
(declare-function drgnx-grid-remove-dock "drgnx-grid" (window))

(defun drgnx-area--parameters (area)
  "The window parameters of AREA's window: no mode line from birth, as the chrome gives an area (the size Emacs
preserves is the body without one, else the bar's own root-level window takes the difference)."
  `((drgnx-role . ,area) (no-delete-other-windows . t) (no-other-window . t) (mode-line-format . none)
    (delete-window . drgnx-area--delete-window)))

(defun drgnx-area--create-tile (area buffer)
  "AREA's window as its dock's tile of the grid (`drgnx-grid-split-dock'): at the size it had, else its `:size' in
lines or columns; showing BUFFER, dedicated."
  (let* ((spec (alist-get area drgnx-wb--areas))
         (w (drgnx-grid-split-dock (plist-get spec :side)
                                   (or (frame-parameter nil (drgnx-area--px-param area))
                                       (* (plist-get spec :size)
                                          (if (drgnx-area--horizontal-p area) (frame-char-width) (frame-char-height)))))))
    (pcase-dolist (`(,k . ,v) (drgnx-area--parameters area)) (set-window-parameter w k v))
    (set-window-buffer w buffer)
    (set-window-dedicated-p w 'drgnx)
    w))

(defun drgnx-area--create (area buffer)
  (let* ((spec (alist-get area drgnx-wb--areas)) (side (plist-get spec :side))
         (horizontal (drgnx-area--horizontal-p area))
         (grid (drgnx-wb-grid-p))
         (w (if grid (drgnx-area--create-tile area buffer)
              (let ((drgnx-rules--placing t))           ; ours: not redirected by the rules
                (display-buffer-in-side-window
                 buffer `((side . ,side) (slot . 0)
                          (,(if horizontal 'window-width 'window-height) . ,(plist-get spec :size))
                          (dedicated . drgnx)
                          (window-parameters . ,(drgnx-area--parameters area))))))))
    (when-let* (((not grid))                            ; a tile is split at its size
                (px (frame-parameter nil (drgnx-area--px-param area))))
      (let ((window-resize-pixelwise t))             ; or the size is rounded to whole lines
        (ignore-errors (window-resize w (- px (if horizontal (window-pixel-width w) (window-pixel-height w)))
                                      horizontal nil t))))
    (set-window-parameter w 'quit-restore nil)  ; `q' there must not go back to the window of its birth
    (set-window-scroll-bars w nil nil nil nil t)
    ;; After the scroll bars: Emacs keeps the size only while it equals the body size it recorded (I11)
    (window-preserve-size w horizontal t)
    w))

(declare-function drgnx-popup--end "drgnx-popup")

(defun drgnx-area--end-popup (w)
  "A popup borrowing W ends before the area changes (the tab must not remember the popup)."
  (when (and w (window-parameter w 'drgnx-popup)) (drgnx-popup--end w)))

(defun drgnx-wb-set-area-buffer (window buffer)
  "Show BUFFER in the area or lane WINDOW, which stays dedicated (`set-window-buffer' would undo it)."
  (unless (eq (window-buffer window) buffer)
    (set-window-buffer window buffer)
    ;; Emacs preserves a size only for the buffer it was set with: set it again for this one (I11)
    (when-let* ((area (window-parameter window 'drgnx-role)) ((alist-get area drgnx-wb--areas)))
      (window-preserve-size window (drgnx-area--horizontal-p area) t)))
  (set-window-dedicated-p window 'drgnx))

(defun drgnx-wb-area-put-buffer (window buffer)
  "Show BUFFER in WINDOW, an area's window, keeping the shown tab: its tab row follows the buffer (one with its own
title has none)."
  (drgnx-wb-set-area-buffer window buffer)
  (when-let* ((area (window-parameter window 'drgnx-role)) ((alist-get area drgnx-wb--areas))
              ((not (window-parameter window 'drgnx-area-part))))
    (drgnx-area--companions area window buffer)
    (drgnx-area--put-row area window)))

(defun drgnx-wb-area-show (area &optional tab buffer)
  "Show AREA's TAB (default: the shown one) with BUFFER (default: the tab's last); never select it.
Returns the window — the same one across tab switches."
  (drgnx-area--end-popup (drgnx-wb-area-window area))
  (let* ((w (drgnx-wb-area-window area)) (tab (or tab (drgnx-wb-area-tab area))))
    (when w (drgnx-area--remember area w))
    (let* ((saved (alist-get tab (plist-get (drgnx-area--state area) :tabs)))
           (buffer (or buffer (drgnx-area--saved-buffer saved) (drgnx-area--content area tab)
                       (drgnx-area--placeholder area tab))))
      (if w (drgnx-wb-set-area-buffer w buffer)
        (setq w (drgnx-area--create area buffer)))
      (when (eq (car saved) buffer)
        (set-window-start w (nth 1 saved) t)
        (set-window-point w (if (eq (nth 2 saved) 'end) (with-current-buffer buffer (point-max)) (nth 2 saved))))
      (drgnx-area--set-state area (plist-put (copy-sequence (drgnx-area--state area)) :tab tab))
      (drgnx-area--companions area w buffer)
      (drgnx-area--put-row area w)
      ;; After the tab row: Emacs keeps the size only while it equals the body size it recorded (I11)
      (window-preserve-size w (drgnx-area--horizontal-p area) t)
      (with-current-buffer buffer (add-hook 'kill-buffer-hook #'drgnx-area--killed nil t))
      w)))

(defun drgnx-area--killed ()
  "The current buffer is being killed: areas showing it show their tab's placeholder instead."
  (let ((dying (current-buffer)))
    (dolist (f (frame-list))
      (dolist (w (window-list f 'nomini))
        (when-let* (((window-live-p w))          ; a companion deleted on this walk
                    (area (window-parameter w 'drgnx-role))
                    ((alist-get area drgnx-wb--areas))
                    ((eq (window-buffer w) dying)))
          (with-selected-frame f
            (if (window-parameter w 'drgnx-area-part)
                (drgnx-area--delete-companion w)  ; a companion's buffer: only its window goes
              (let ((tab (drgnx-wb-area-tab area)) (placeholder nil))
                (drgnx-wb-set-area-buffer w (setq placeholder (drgnx-area--placeholder area tab)))
                (drgnx-area--remember area w)
                (drgnx-area--companions area w placeholder)
                (drgnx-area--put-row area w)))))))))

(defun drgnx-wb-area-hide (area)
  "Hide AREA, remembering its pixel size and its tabs.
The panel's and the right dock's size is noted `:by auto' (`drgnx-state-note-intent'): a size you chose is
kept instead of the one a popup squeezed the area to."
  (when-let* ((w (drgnx-wb-area-window area)))
    (drgnx-area--end-popup w)
    (drgnx-area--remember area w)
    (let ((px (if (drgnx-area--horizontal-p area) (window-pixel-width w) (window-pixel-height w))))
      (if (memq area '(panel right))                  ; the areas intent knows (homes `bottom' and `right')
          (drgnx-state-note-intent nil :sizes area px :by 'auto)
        (set-frame-parameter nil (drgnx-area--px-param area) px)))
    (when (memq (selected-window) (cons w (drgnx-area--companion-windows area))) (drgnx-wb-focus-editor))
    (mapc #'drgnx-area--delete-companion (drgnx-area--companion-windows area))
    (set-window-parameter w 'delete-window nil)
    (if (drgnx-wb-grid-p) (drgnx-grid-remove-dock w) (delete-window w))))

(defun drgnx-area--delete-window (window)
  "`delete-window' on an area's window (C-x 0, or a package deleting a window it once had): hide the
area, so its size and tabs are kept."
  (with-selected-frame (window-frame window)     ; the frame it is on, not the selected one
    (drgnx-wb-area-hide (window-parameter window 'drgnx-role))))

;;;; Companions: windows above and below a tab's buffer

;; A tab defined with :companions shows up to two more buffers with the one it shows, in side windows of the same
;; side at slots -1 (above) and +1 (below): the agent panel's header and composer around its transcript.  They are
;; dedicated, of the area's role, with the window parameter `drgnx-area-part' `above' or `below' (the main window has
;; none, so `drgnx-wb-area-window' is still the tab's), no mode line, and fitted to their lines.  The tab row goes on
;; the topmost window.  A tab switch, a hide or the main buffer's kill takes them away; a placeholder has none.

(defconst drgnx-area--companion-most 0.45 "The most of its area's height a companion window is fitted to.")

(defun drgnx-area--companion-windows (area &optional frame)
  "AREA's companion windows on FRAME (default: `drgnx-wb-frame'), top to bottom."
  (let ((frame (or frame (drgnx-wb-frame))))
    (seq-filter (lambda (w) (and (eq (window-parameter w 'drgnx-role) area) (window-parameter w 'drgnx-area-part)))
                (window-list frame 'nomini (frame-first-window frame)))))

(defun drgnx-area--companion (area part &optional frame)
  "AREA's companion window PART (`above' or `below') on FRAME, or nil."
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-area-part) part)) (drgnx-area--companion-windows area frame)))

(defun drgnx-area--top-window (area &optional frame)
  "AREA's topmost window on FRAME, which carries its tab row: the companion above its tab's buffer when there is one,
else its window; nil while it is hidden."
  (or (drgnx-area--companion area 'above frame) (drgnx-wb-area-window area frame)))

(defun drgnx-area--put-row (area w)
  "Set AREA's tab row on its topmost window; W, its main window, has none when a companion is above it."
  (let ((top (or (drgnx-area--companion area 'above (window-frame w)) w)))
    (set-window-parameter top 'header-line-format (drgnx-area--tab-row area))
    (unless (eq top w)
      (set-window-parameter w 'header-line-format 'none)
      ;; the companion was fitted before it had the row (`drgnx-area--companions'): fitted again with it
      (drgnx-area--fit-companion top))))

(defun drgnx-area--delete-companion (w)
  "Delete companion window W itself: not through the area's `delete-window', which hides the whole area."
  (when (window-live-p w)
    (set-window-parameter w 'delete-window nil)
    (if (drgnx-wb-grid-p) (drgnx-grid-delete-part w) (delete-window w))))

(defun drgnx-area--make-companion (area part buffer)
  "A new companion window PART of AREA showing BUFFER, split from the area's side, dedicated as the area's window is.
With the grid on it is a part of the area's tile (`drgnx-grid-add-part'), so the tile moves and hides as one."
  (let* ((params `((drgnx-role . ,area) (drgnx-area-part . ,part) (no-delete-other-windows . t) (no-other-window . t)
                   (mode-line-format . none) (header-line-format . none) (delete-window . drgnx-area--delete-window)))
         (w (if (drgnx-wb-grid-p)
                (let ((w (drgnx-grid-add-part (drgnx-wb-area-window area) part)))
                  (pcase-dolist (`(,k . ,v) params) (set-window-parameter w k v))
                  (set-window-buffer w buffer)
                  (set-window-dedicated-p w 'drgnx)
                  w)
              (let ((drgnx-rules--placing t))           ; ours: not redirected by the rules
                (display-buffer-in-side-window
                 buffer `((side . ,(plist-get (alist-get area drgnx-wb--areas) :side)) (slot . ,(if (eq part 'above) -1 1))
                          (dedicated . drgnx) (window-parameters . ,params)))))))
    (set-window-parameter w 'quit-restore nil)
    (set-window-scroll-bars w nil nil nil nil t)
    (window-preserve-size w t t)                       ; the width, as the area's window keeps it
    w))

(defun drgnx-area--companions (area w buffer)
  "Show the companions AREA's shown tab gives BUFFER, which its main window W shows, and fit them; delete those it has
none for.  A placeholder has none, nor has an area at the top or bottom."
  (let* ((fn (and (drgnx-area--horizontal-p area) (drgnx-area--content-p buffer)
                  (plist-get (alist-get (drgnx-wb-area-tab area) (plist-get (alist-get area drgnx-wb--areas) :tabs))
                             :companions)))
         (parts (and fn (funcall fn buffer)))
         (frame (window-frame w)))
    (cl-loop for part in '(above below) for want in (list (nth 0 parts) (nth 1 parts))
             for have = (drgnx-area--companion area part frame)
             do (cond ((not (buffer-live-p want)) (drgnx-area--delete-companion have))
                      (t (if have (drgnx-wb-set-area-buffer have want) (drgnx-area--make-companion area part want))
                         (with-current-buffer want
                           (add-hook 'kill-buffer-hook #'drgnx-area--killed nil t)
                           (add-hook 'window-size-change-functions #'drgnx-area--companion-resized nil t)))))
    (drgnx-wb-area-fit-companions area frame)))

(defun drgnx-area--fit-companion (w)
  "Fit companion window W to its buffer's lines and its header line, pixelwise, at most `drgnx-area--companion-most'
of its area's height (its main window and companions together), in whole lines; the main window gives or takes the
difference.  The height is then preserved, so a frame resize goes to the main window.  A second call changes nothing."
  (when-let* (((window-live-p w)) ((window-parameter w 'drgnx-area-part))
              (area (window-parameter w 'drgnx-role)) (frame (window-frame w))
              (main (drgnx-wb-area-window area frame)))
    (let* ((total (apply #'+ (mapcar #'window-pixel-height (cons main (drgnx-area--companion-windows area frame)))))
           (line (window-default-line-height w))
           (window-resize-pixelwise t))
      ;; `fit-window-to-buffer' reads a preserved width as a fixed size (it asks `window-size-fixed-p' with
      ;; `preserved' as HORIZONTAL) and fits nothing: the width is let go for the fit and kept again after it
      (window-preserve-size w t nil)
      (let ((most (max 1 (floor (* drgnx-area--companion-most total) line)))
            ;; never under the window's least height (its header line and a line): a resize under it is refused whole,
            ;; and an empty companion (a header before its rows) would keep its split height
            (least (max 1 (ceiling (window-min-size w nil w t) line)))
            (was (window-pixel-height w)))
        (unwind-protect
            (progn
              (fit-window-to-buffer w most least nil nil t)
              ;; Emacs draws a header line only in a window with room for it and a line, and `window-min-size' of a
              ;; window too small for it counts none: one that wants a row it cannot draw grows a line at a time
              (while (and (< least most) (drgnx-area--header-wanted-p w) (= 0 (window-header-line-height w)))
                (setq least (1+ least))
                (fit-window-to-buffer w most least nil nil t)))
          (window-preserve-size w t t))
        (drgnx-area--fit-report w was most least))
      (window-preserve-size w nil t))))                ; also when the fit changed nothing

(defun drgnx-area--header-wanted-p (w)
  "Non-nil when window W has a header line to draw: its `header-line-format' parameter, unless `none', else its
buffer's."
  (let ((f (window-parameter w 'header-line-format)))
    (and (not (eq f 'none)) (or f (buffer-local-value 'header-line-format (window-buffer w))))))

(defun drgnx-area--fit-report (w was most least)
  "Record on companion window W whether the fit to MOST and LEAST lines took: the window parameter
`drgnx-area-unfitted' is (:height H :want WANT) when W's height is still WAS though its lines want another, else
nil.  A window a popup borrows keeps its size (`drgnx-popup--fit'): nothing to report."
  (set-window-parameter
   w 'drgnx-area-unfitted
   (and (= was (window-pixel-height w))
        (not (plist-get (window-parameter w 'drgnx-popup) :borrowed))
        (let* ((line (window-default-line-height w))
               (text (+ (cdr (window-text-pixel-size w nil t nil (frame-pixel-height (window-frame w)) t))
                        (window-scroll-bar-height w) (window-bottom-divider-width w)))
               (want (max (* least line) (min (* most line) text))))
          (and (> (abs (- want was)) 1) (list :height was :want want))))))

(defun drgnx-area--companion-resized (w)
  "`window-size-change-functions' in a companion's buffer: a companion window whose size changed (a frame resize, a
header line measured after the first redisplay) is fitted again."
  (when (window-parameter w 'drgnx-area-part) (drgnx-area--fit-companion w)))

(defun drgnx-wb-area-fit-companions (area &optional frame)
  "Fit AREA's companion windows to their lines on FRAME, or on every frame when FRAME is nil.  A companion's owner
calls it when the companion's lines change (its rows were drawn, a draft grew); never from redisplay."
  (dolist (f (if frame (list frame) (frame-list)))
    (mapc #'drgnx-area--fit-companion (drgnx-area--companion-windows area f))))

(defun drgnx-wb-area-toggle (area)
  "Show or hide AREA."
  (if (drgnx-wb-area-window area) (drgnx-wb-area-hide area) (drgnx-wb-area-show area)))

(defun drgnx-wb-area-focus (area)
  "Show AREA and move focus to it."
  (select-window (drgnx-wb-area-show area)))

(defun drgnx-wb-area-toggle-tab (area tab &optional start)
  "Hide AREA when it shows TAB; else show TAB and select it.  When TAB has no buffer of its own, call START (if
given) instead of selecting the placeholder: it makes one, which the rules show in TAB."
  (if (and (drgnx-wb-area-window area) (eq (drgnx-wb-area-tab area) tab))
      (drgnx-wb-area-hide area)
    (let ((w (drgnx-wb-area-show area tab)))
      (if (and start (not (drgnx-area--content-p (window-buffer w))))
          (funcall start)
        (select-window w)))))

(defun drgnx-wb-toggle-panel () "Show or hide the bottom panel." (interactive) (drgnx-wb-area-toggle 'panel))
(defun drgnx-wb-focus-panel () "Show the bottom panel and move focus to it." (interactive) (drgnx-wb-area-focus 'panel))
(defun drgnx-wb-toggle-right-dock () "Show or hide the right dock." (interactive) (drgnx-wb-area-toggle 'right))

;;;; Places and the default areas

(defun drgnx-area--place (area)
  (lambda (buffer alist props)
    (let ((w (drgnx-wb-area-show area (plist-get props :tab) buffer)))
      (drgnx-wb-run-body-function w alist)
      w)))

(drgnx-wb-define-place 'panel (drgnx-area--place 'panel))
(drgnx-wb-define-place 'right (drgnx-area--place 'right))

(drgnx-wb-define-area 'panel :side 'bottom :size 12)
(drgnx-wb-define-area 'right :side 'right :size 50 :lone t)
(defconst drgnx-area--output-modes '(messages-buffer-mode debugger-mode ert-results-mode process-menu-mode timer-list-mode)
  "Major modes of the buffers the Output tab shows: its channels.")
(defconst drgnx-area--output-names "\\`\\*\\(Warnings\\|Backtrace\\|Messages\\|timer-list\\|Process List\\)\\*\\'"
  "Names of the buffers the Output tab shows: its channels.")

(defun drgnx-wb-output-channels ()
  "The live buffers the Output tab shows, by name: its channels."
  (seq-filter (lambda (b) (and (buffer-live-p b)
                               (or (string-match-p drgnx-area--output-names (buffer-name b))
                                   (apply #'provided-mode-derived-p (buffer-local-value 'major-mode b)
                                          drgnx-area--output-modes))))
              (buffer-list)))

(defun drgnx-wb-view-output ()
  "Show the panel's Output tab (Messages, Warnings, …) and move focus to it, as VS Code's View: Output."
  (interactive)
  (select-window (drgnx-wb-area-show 'panel 'output))
  (drgnx-wb-area-redraw 'panel))

(defun drgnx-wb-output-select-channel ()
  "Show one of the Output tab's channels (Messages, Warnings, Backtrace, …) in the panel, chosen by name."
  (interactive)
  (let* ((names (mapcar (lambda (b) (cons (string-trim (buffer-name b) "[ *]+" "[ *]+") b)) (drgnx-wb-output-channels)))
         (pick (if names (completing-read "Output channel: " (mapcar #'car names) nil t)
                 (user-error "Nothing has been logged yet")))
         (buf (cdr (assoc pick names))))
    (drgnx-wb-area-show 'panel 'output buf)
    (drgnx-wb-area-redraw 'panel)))

(defvar drgnx-area--channel-map
  (let ((m (make-sparse-keymap))) (define-key m [header-line mouse-1] #'drgnx-wb-output-select-channel) m)
  "The Output tab's channel chip's click.")

(defun drgnx-area--output-actions ()
  "The Output tab's own piece: the channel it shows, a click picks another."
  (when-let* ((w (drgnx-wb-area-window 'panel)) (buf (window-buffer w))
              ((memq buf (drgnx-wb-output-channels))))
    (propertize (concat " " (string-trim (buffer-name buf) "[ *]+" "[ *]+") " " (drgnx-look-icon 'chevron-down nil 14) " ")
                'face 'drgnx-kit-chip-neutral-soft 'mouse-face 'highlight
                'help-echo "The Output channel shown: click for another" 'local-map drgnx-area--channel-map)))

(defun drgnx-area--problems-content ()
  "The Problems tab's buffer: the view listing the project's problems, drawn now."
  (when (fboundp 'drgnx-problems-buffer) (drgnx-problems-buffer)))

(defun drgnx-area--output-content ()
  "The Output tab's first channel: the one logged most recently of those that exist, else Messages."
  (or (car (drgnx-wb-output-channels)) (get-buffer-create "*Messages*")))

(drgnx-wb-define-tab 'panel 'problems :content #'drgnx-area--problems-content
                     :empty "No problems have been detected in the workspace.")
(drgnx-wb-define-tab 'panel 'output :actions #'drgnx-area--output-actions :content #'drgnx-area--output-content
                     :empty "Nothing has been logged yet. Messages, warnings and backtraces appear here; Output: Select Channel picks one.")
(drgnx-wb-define-tab 'panel 'results :empty "No results yet. The results of a search, a compile or a find-usages appear here.")
(drgnx-wb-define-tab 'panel 'terminal)
(drgnx-wb-define-tab 'panel 'help :empty "No help is open. Describe a command or a key, or press F1, and it appears here.")

(pcase-dolist (`(,matcher ,tab)
               `(((help-mode apropos-mode Info-mode Man-mode shortdoc-mode finder-mode) help)
                 ("\\`\\*\\(Help\\|info\\|eldoc.*\\|Apropos\\|Shortdoc .*\\|Finder.*\\|Holidays\\)\\*\\'" help)
                 ((compilation-mode occur-mode xref--xref-buffer-mode) results)
                 ((drgnx-problems-mode flymake-diagnostics-buffer-mode flymake-project-diagnostics-mode) problems)
                 ("\\`\\*Flycheck errors\\*\\'" problems)
                 (,drgnx-area--output-modes output)
                 (,drgnx-area--output-names output)
                 ((shell-mode eshell-mode drgnx-term-mode term-mode vterm-mode inferior-emacs-lisp-mode comint-mode) terminal)
                 ;; shell and eshell show their buffer before setting its mode.
                 ("\\`\\*\\(shell\\|eshell\\|ielm\\|terminal\\|ansi-term\\|vterm\\)\\*\\(<[0-9]+>\\)?\\'" terminal)))
  (drgnx-wb-place matcher 'panel :tab tab))

(provide 'drgnx-area)
;;; drgnx-area.el ends here
