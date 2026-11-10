;;; drgnx-look.el --- Module ui/look: colour theme, zen mode -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Color Theme picks one of the installed themes (one at a time) and remembers it in modules.eld;
;; Zen mode hides the sidebar, the panel and the right dock and centres the text, and gives every
;; one of them back as it was.  See docs/guide/modules.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'face-remap)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-wb)
(require 'drgnx-state)                  ; the cards follow the windows and the frame's scale through the store
;; the decorations module sits beside this file (modules are not on the load path)
(unless (featurep 'drgnx-decor)
  (load (expand-file-name "drgnx-decor" (file-name-directory (or load-file-name buffer-file-name))) nil t))
;; so does the font roles' (their settings are declared when it loads)
(unless (featurep 'drgnx-look-fonts)
  (load (expand-file-name "drgnx-look-fonts" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-look-density)
  (load (expand-file-name "drgnx-look-density" (file-name-directory (or load-file-name buffer-file-name))) nil t))
;; and the colours it derives from other themes
(unless (featurep 'drgnx-look-derive)
  (load (expand-file-name "drgnx-look-derive" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(unless (featurep 'drgnx-look-follow)
  (load (expand-file-name "drgnx-look-follow" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(declare-function drgnx-look-variant "drgnx-theme-gen" (&optional frame))
(declare-function drgnx-look-density-value "drgnx-look-density" (key &optional density))
(defvar drgnx-look-density-changed-hook)
(declare-function drgnx-look-follow-on "drgnx-look-follow" ())
(declare-function drgnx-look-follow-off "drgnx-look-follow" ())
(declare-function drgnx-look-follow-apply "drgnx-look-follow" ())
(defvar drgnx-look-follow--loading)
(declare-function drgnx-look-derive-on "drgnx-look-derive" ())
(declare-function drgnx-look-derive-off "drgnx-look-derive" ())
(declare-function drgnx-look-density-on "drgnx-look-density" ())
(declare-function drgnx-look-density-off "drgnx-look-density" ())
(declare-function drgnx-look-fonts-on "drgnx-look-fonts" ())
(declare-function drgnx-look-fonts-off "drgnx-look-fonts" ())
(declare-function drgnx-decor-faces-on "drgnx-decor" ())
(declare-function drgnx-decor-activate "drgnx-decor" ())

;;;; Chrome (Glitnir, the compositor)

(declare-function drgnx-look-variant "drgnx-theme-gen" (&optional frame))

(drgnx-defsetting drgnx-look-motion 'auto
  "Motion of popups, the palette and notices under Glitnir: `auto' follows the desktop's reduced-motion
preference, `full' always moves, `reduced' never does (no transitions; blur and shadows stay).
A change applies at once."
  :type '(choice (const auto) (const full) (const reduced)) :group 'drgnx-look
  :scope 'global :agents 'never :apply #'drgnx-look--motion-apply
  :schema '(enum auto full reduced))

(defun drgnx-look--float-motion (alist)
  "ALIST without its `transition' when motion is `reduced'."
  (if (eq drgnx-look-motion 'reduced) (assq-delete-all 'transition (copy-sequence alist)) alist))

(defun drgnx-look-chrome-for (variant)
  "The chrome of popups (child frames) under Glitnir in VARIANT (`dark', `light' or `hc'), in logical pixels.
High contrast has no shadow and a 1 px ring (the `child-frame-border' face, `drgnx-border-strong')."
  (drgnx-look--float-motion
   (pcase variant
     ('hc '((corner-radius . 8) (child-frame-border-width . 1) (transition . pop)))
     (_ `((corner-radius . 8)
          (shadow . (:blur 16 :offset (0 . 6) :spread 0 :opacity ,(if (eq variant 'light) 0.14 0.35)))
          (transition . pop))))))

(defun drgnx-look-palette-for (variant)
  "The floating command palette's child frame parameters in VARIANT, in logical pixels.
High contrast is opaque, with no shadow and no blur, and a 2 px ring."
  (drgnx-look--float-motion
   (pcase variant
     ('hc '((corner-radius . 12) (alpha-background . 1.0) (child-frame-border-width . 2) (transition . pop)))
     (_ `((corner-radius . 12)
          (shadow . (:blur 48 :offset (0 . 16) :spread 0 :opacity ,(if (eq variant 'light) 0.22 0.50)))
          (alpha-background . 0.90) (backdrop-blur . 12) (transition . pop))))))

(defcustom drgnx-look-chrome (drgnx-look-chrome-for 'dark)
  "The chrome of popups (child frames) under Glitnir, in logical pixels: `child-frame-chrome' while ui/look is on.
Left at its standard value, the chrome follows the theme's variant (`drgnx-look-chrome-for'); a value you set stands
in every variant.  No colours: the shadow takes the `child-frame-shadow' face, the border the `child-frame-border' face."
  :type 'sexp :group 'drgnx-face)

(defcustom drgnx-look-palette (drgnx-look-palette-for 'dark)
  "The floating command palette's child frame parameters under Glitnir, in logical pixels.
Left at its standard value, they follow the theme's variant (`drgnx-look-palette-for'); a value you set stands in
every variant.  No colours: the shadow takes the `child-frame-shadow' face."
  :type 'sexp :group 'drgnx-face)

(defun drgnx-look--float-customised-p (symbol)
  "Non-nil when SYMBOL's value is not its standard value (the user, Customize or a settings file set it)."
  (not (equal (symbol-value symbol) (eval (car (get symbol 'standard-value)) t))))

(defun drgnx-look-chrome-current (&optional _frame)
  "The popup chrome now: the user's `drgnx-look-chrome' when customised, else the table for the variant.
Also the function `child-frame-chrome' holds while ui/look is on, so a theme change needs only a refresh."
  (if (drgnx-look--float-customised-p 'drgnx-look-chrome)
      drgnx-look-chrome
    (drgnx-look-chrome-for (drgnx-look-variant))))

(defun drgnx-look-palette-current ()
  "The palette's frame parameters now: the user's `drgnx-look-palette' when customised, else the table."
  (if (drgnx-look--float-customised-p 'drgnx-look-palette)
      drgnx-look-palette
    (drgnx-look-palette-for (drgnx-look-variant))))

(defvar child-frame-chrome)
(defvar glitnir-reduced-motion)
(declare-function glitnir-refresh "glitnir")
(declare-function drgnx-palette-frame-restyle "drgnx-palette-frame" ())

(defun drgnx-look--float-refresh ()
  "Popups and the palette take the values for the variant now on, at once (one refresh)."
  (when (featurep 'glitnir)
    (when (fboundp 'drgnx-palette-frame-restyle) (drgnx-palette-frame-restyle))
    (glitnir-refresh)))

(defun drgnx-look--motion-value ()
  "`glitnir-reduced-motion' for `drgnx-look-motion': `auto' (the desktop says), nil for `full', t for `reduced'."
  (pcase drgnx-look-motion ('auto 'auto) ('full nil) (_ t)))

(defun drgnx-look--motion-set ()
  "Set `glitnir-reduced-motion' as ui/look (`drgnx-module-set': a value you gave it stays, and the module's teardown
gives the option back)."
  (drgnx-module-set 'glitnir-reduced-motion (drgnx-look--motion-value)))

(defvar drgnx-look--motion-door nil
  "While ui/look runs under Glitnir: `drgnx-look--motion-set' run as the module, so a later change of
`drgnx-look-motion' is undone with the module too.  nil otherwise.")

(defun drgnx-look--motion-apply ()
  "The `:apply' of `drgnx-look-motion': `glitnir-reduced-motion' follows it while ui/look runs under Glitnir, then
the popups and the palette are styled again."
  (when drgnx-look--motion-door (funcall drgnx-look--motion-door))
  (when (drgnx-module-running-p 'ui/look) (drgnx-look--float-refresh)))

(defun drgnx-look--motion-on ()
  "In ui/look's setup: `glitnir-reduced-motion' follows `drgnx-look-motion' now and on every change, as the module."
  (drgnx-look--motion-set)
  (setq drgnx-look--motion-door (drgnx-modules-with-owner (drgnx-look--motion-set)))
  (drgnx-modules-push-undo "motion door" (lambda () (setq drgnx-look--motion-door nil))))

(defun drgnx-look--float-on-theme (&rest _)
  "`enable-theme-functions' and `disable-theme-functions': the variant may have changed."
  (drgnx-look--float-refresh))

(defun drgnx-look--chrome-on ()
  "With Glitnir: popups rounded and shadowed, at once (`child-frame-chrome' set through the module; its undo
restores the old value, and the refresh recorded before it runs after that).  Without it, nothing.  The chrome
follows the theme's variant: the option holds a function until the module is off."
  (when (featurep 'glitnir)
    (drgnx-modules-push-undo "glitnir chrome refresh" (lambda () (glitnir-refresh)))
    (drgnx-module-set 'child-frame-chrome #'drgnx-look-chrome-current)
    (add-hook 'enable-theme-functions #'drgnx-look--float-on-theme)
    (add-hook 'disable-theme-functions #'drgnx-look--float-on-theme)
    (drgnx-modules-push-undo "popup variant hooks"
                             (lambda () (remove-hook 'enable-theme-functions #'drgnx-look--float-on-theme)
                               (remove-hook 'disable-theme-functions #'drgnx-look--float-on-theme)))
    (drgnx-decor-faces-on)
    (drgnx-look--motion-on)
    (glitnir-refresh)))

;;;; Cards (Glitnir, the compositor)

(defcustom drgnx-look-card
  '((corner-radius . 10) (shadow . (:blur 3 :offset (0 . 1) :spread 0 :opacity 0.45))
    (ring . (drgnx-border . 0.6)))
  "The card look of the docked panes (Explorer, panel, right dock) and the editor groups under Glitnir, in logical pixels.
`corner-radius', `shadow' and `ring' become the window parameters Glitnir reads, with the opacities of the active
variant (`drgnx-look--card-value': ring 0.6 dark, 0.8 light, 1.0 high contrast; shadow 0.45, 0.08, none) and the
selected window's ring the accent at 1.0.  The gap between cards, the room the ring and shadow are drawn in, is the
density's (`drgnx-look-density-value' `gap') in the frame's pixels, set as the dividers and the frame's edge, and
again when the scale or the density changes.  The ring is a face (its foreground) and an opacity: no colour is
named here."
  :type 'sexp :group 'drgnx-face)

(defun drgnx-look--cards-p ()
  "Non-nil when Glitnir draws the frames, so windows can be cards."
  (and (featurep 'glitnir) (fboundp 'glitnir-active-p) (glitnir-active-p) t))

(defun drgnx-look--card-window-p (window)
  "Non-nil when WINDOW is a card: a docked pane (the Explorer, the panel, the right dock) or an editor group.
An editor group is an ordinary window: not the minibuffer, a package's side window or a popup lane."
  (let ((role (window-parameter window 'drgnx-role)))
    (if role
        (and (memq role '(dock panel right)) t)
      (not (or (window-minibuffer-p window) (window-parameter window 'window-side)
               (window-parameter window 'drgnx-popup))))))

(defconst drgnx-look--card-parameters '(corner-radius shadow ring)
  "The window parameters of `drgnx-look-card' that make a card.")

(defconst drgnx-look--sidebar-group '(drgnx-sidebar . drgnx-surface-panel)
  "The left dock's card group (window parameter `card-group'): its sections are one island (window-dark.html
`.card.ex'), Glitnir drawing one card around them while they tile a rectangle, the dividers between them in the
panel surface.")

(defun drgnx-look--card-frames ()
  "The graphical root frames."
  (seq-filter (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list)))

(defun drgnx-look--card-value (key)
  "Card parameter KEY (`corner-radius', `shadow' or `ring') for the active variant: `drgnx-look-card' with the
variant's opacities, or nil when it has none (no shadow in high contrast)."
  (let ((base (alist-get key drgnx-look-card)) (variant (drgnx-look-variant)))
    (pcase key
      ('ring (and base (cons 'drgnx-border (pcase variant ('light 0.8) ('hc 1.0) (_ 0.6)))))
      ('shadow (and base (not (eq variant 'hc))
                    (plist-put (copy-sequence base) :opacity (if (eq variant 'light) 0.08 0.45))))
      (_ base))))

(defun drgnx-look--card-focused-p (window)
  "Non-nil when WINDOW is its frame's selected window (the one under the minibuffer while it is used)."
  (let ((sel (frame-selected-window (window-frame window))))
    (eq window (if (window-minibuffer-p sel) (minibuffer-selected-window) sel))))

(defun drgnx-look--card-tiled-p (window)
  "Non-nil when WINDOW is an editor group and its frame has another (tiling.html: the focused card is ringed; with
one editor group, window-dark.html, no card is)."
  (and (eq (drgnx-state-window-role window) 'editor)
       (let ((n 0))
         (dolist (w (window-list (window-frame window) 'nomini) (> n 1))
           (when (eq (drgnx-state-window-role w) 'editor) (setq n (1+ n)))))))

(defun drgnx-look--card-set (window)
  "Give WINDOW the card parameters, only those that differ (a setting of one reruns the hooks).  The selected
window's ring is the accent when it is one of several editor groups (`drgnx-look--card-tiled-p')."
  (dolist (p drgnx-look--card-parameters)
    (let ((v (if (and (eq p 'ring) (drgnx-look--card-value 'ring) (drgnx-look--card-focused-p window)
                      (drgnx-look--card-tiled-p window))
                 '(drgnx-accent . 1.0)
               (drgnx-look--card-value p))))
      (unless (equal (window-parameter window p) v) (set-window-parameter window p v))))
  (let ((group (and (eq (window-parameter window 'drgnx-role) 'dock) drgnx-look--sidebar-group)))
    (unless (equal (window-parameter window 'card-group) group) (set-window-parameter window 'card-group group)))
  (unless (window-parameter window 'drgnx-look-card) (set-window-parameter window 'drgnx-look-card t)))

(defun drgnx-look--card-unset (window)
  "Take the card parameters off WINDOW, when this module put them on."
  (when (window-parameter window 'drgnx-look-card)
    (dolist (p (cons 'drgnx-look-card (cons 'card-group drgnx-look--card-parameters))) (set-window-parameter window p nil))))

(defun drgnx-look--card-gap-px (frame)
  "The gap in FRAME's own pixels: the density's `gap' logical pixels times the frame's scale (a frame pixel is a
device pixel on the native shell)."
  (round (* (drgnx-look-density-value 'gap) (frame-scale-factor frame))))

(defun drgnx-look--card-follow-scale (frame)
  "Give FRAME's dividers the gap again when its scale changed under it (a frame that is a card frame only)."
  (when (and (frame-live-p frame) (frame-parameter frame 'drgnx-look-card-saved))
    (drgnx-look--card-frame frame)))

(defun drgnx-look--cards-windows-changed (_data)
  "The store's `windows-changed': the windows that came or changed role become cards (or stop being ones)."
  (drgnx-look-cards-apply))

(defun drgnx-look--cards-frame-resized (data)
  "The store's `frame-resized': a scale change resizes the frame, so the gap is given again in its pixels."
  (drgnx-look--card-follow-scale (plist-get data :frame)))

(defconst drgnx-look--island-faces
  '((window-divider . :foreground) (window-divider-first-pixel . :foreground)
    (window-divider-last-pixel . :foreground) (internal-border . :background))
  "The faces that paint the gap between cards and at the frame's edge, with the attribute that carries the colour.")

(defun drgnx-look--island-faces-set (frame)
  "On FRAME alone, paint the gap faces in `drgnx-surface-gap's background (a theme's own divider colour, such as
modus's grey, would stripe the gap).  Non-nil when a face changed."
  (let ((gap (face-background 'drgnx-surface-gap frame t)) (changed nil))
    (when (and (stringp gap) (not (string-prefix-p "unspecified" gap)))
      (pcase-dolist (`(,face . ,attr) drgnx-look--island-faces)
        (unless (equal (face-attribute face attr frame) gap)
          (set-face-attribute face frame attr gap)
          (setq changed t))))
    changed))

(defun drgnx-look--island-faces-restore (frame)
  "Give FRAME's gap faces back to the enabled themes."
  (pcase-dolist (`(,face . ,_) drgnx-look--island-faces) (face-spec-recalc face frame)))

(defun drgnx-look--islands-refresh (&rest _)
  "A theme, a density or a frame changed: every card frame has the gap, its faces and its cards again."
  (dolist (f (frame-list))
    (when (frame-parameter f 'drgnx-look-card-saved) (drgnx-look--card-frame f))))

(defun drgnx-look--islands-new-frame (&rest _)
  "`after-make-frame-functions': a new graphical frame gets cards while Glitnir draws them."
  (drgnx-look-cards-apply))

(defun drgnx-look--islands-on ()
  "The gap faces and the gap follow themes, new frames and the density, until `drgnx-look--islands-off'."
  (add-hook 'enable-theme-functions #'drgnx-look--islands-refresh 90)
  (add-hook 'disable-theme-functions #'drgnx-look--islands-refresh 90)
  (add-hook 'after-make-frame-functions #'drgnx-look--islands-new-frame)
  (add-hook 'drgnx-look-density-changed-hook #'drgnx-look--islands-refresh)
  (add-hook 'drgnx-look-density-changed-hook #'drgnx-look--edge-follow))

(defun drgnx-look-edge-drag (event)
  "A press on a card's side edge (the fringe beside the gap between two cards) drags that gap, as a press on the gap
(the divider) does.  A fringe with no window beyond it is left alone, and so is the inner half of a fringe whose click
a mode binds (diff-hl's hunk, a breakpoint): its click still comes."
  (interactive "e")
  (let* ((posn (event-start event)) (w (posn-window posn)) (area (posn-area posn))
         (edges (and (window-live-p w) (window-pixel-edges w)))
         (fx (and edges (+ (car edges) (car (posn-x-y posn)))))
         (fy (and edges (+ (cadr edges) (cdr (posn-x-y posn)))))
         (right (eq area 'right-fringe))
         (half (and edges (/ (if right (cadr (window-fringes w)) (car (window-fringes w))) 2)))
         (outer (and edges (if right (>= fx (- (nth 2 edges) (window-right-divider-width w) half))
                             (< fx (+ (car edges) half)))))
         ;; the window whose right edge is the gap: W itself, or the one left of W's left edge
         (target (and edges (or outer (not (key-binding (vector area 'mouse-1) nil nil posn)))
                      (if right
                          (and (window-at-x-y (nth 2 edges) fy (window-frame w)) w)
                        (window-at-x-y (- (car edges) 1) fy (window-frame w))))))
    (when (and (window-live-p target) (not (window-minibuffer-p target)))
      (mouse-drag-line (list (car event) (cons target (cdr posn))) 'vertical))))

(defun drgnx-look--islands-off ()
  "Undo `drgnx-look--islands-on'."
  (remove-hook 'enable-theme-functions #'drgnx-look--islands-refresh)
  (remove-hook 'disable-theme-functions #'drgnx-look--islands-refresh)
  (remove-hook 'after-make-frame-functions #'drgnx-look--islands-new-frame)
  (remove-hook 'drgnx-look-density-changed-hook #'drgnx-look--islands-refresh)
  (remove-hook 'drgnx-look-density-changed-hook #'drgnx-look--edge-follow))

(defun drgnx-look--cards-selected-changed (data)
  "The store's `selected-changed' (now lane): the focused tile's ring is the accent, the others' the variant's."
  (when-let* ((frame (plist-get data :frame)) ((frame-live-p frame)))
    (dolist (w (window-list frame 'nomini))
      (when (window-parameter w 'drgnx-look-card) (drgnx-look--card-set w)))))

(defvar drgnx-look--edge-before nil
  "While ui/look is on under Glitnir: `default-frame-alist's `internal-border-width' before the setup put the cards'
edge there, the edge a frame made since would have had without the module.")

(defvar drgnx-look--edge-door nil
  "While ui/look runs under Glitnir: `drgnx-look--edge-put' run as the module, so the edge a density change puts in
`default-frame-alist' is undone with the module too.  nil otherwise.")

(defun drgnx-look--edge-put ()
  "`default-frame-alist's edge: the density's gap at scale 1."
  (drgnx-module-alist-put 'default-frame-alist 'internal-border-width (drgnx-look-density-value 'gap)))

(defun drgnx-look--edge-at-birth ()
  "Under Glitnir, in the setup: windows are made with the cards' edge (`internal-border-width', the density's gap at
scale 1) from `default-frame-alist', and marked `drgnx-look-edge-born'.  A window is then born at its size: the edge
set on a shown window made it ask the window manager for a bigger size, and the answer to the size it was made with
could come after that and put it back, squeezing what was laid out in between (a daemon's restored split, 8 px short).
A density change puts its gap there too (`drgnx-look--edge-follow')."
  (when (and (featurep 'glitnir) (bound-and-true-p glitnir-enable))
    (setq drgnx-look--edge-before (alist-get 'internal-border-width default-frame-alist))
    (drgnx-look--edge-put)
    (drgnx-module-alist-put 'default-frame-alist 'drgnx-look-edge-born t)
    (setq drgnx-look--edge-door (drgnx-modules-with-owner (drgnx-look--edge-put)))
    (drgnx-modules-push-undo "edge door" (lambda () (setq drgnx-look--edge-door nil)))))

(defun drgnx-look--edge-follow ()
  "`drgnx-look-density-changed-hook': a window made from now on is born with the new gap, as the shown ones get it."
  (when drgnx-look--edge-door (funcall drgnx-look--edge-door)))

(defun drgnx-look--edge-without (frame)
  "The `internal-border-width' FRAME would have without the cards: the module's default's for a window born with it."
  (if (frame-parameter frame 'drgnx-look-edge-born) (or drgnx-look--edge-before 0)
    (frame-parameter frame 'internal-border-width)))

(defun drgnx-look--card-frame (frame)
  "Make the docked panes of FRAME cards and widen the dividers to the gap; the frame's own widths are kept.  The
frame's edge gets the same gap (`internal-border-width'): a window made since the setup has it already
(`drgnx-look--edge-at-birth'), so it does not change size here.  The dividers and the edge are painted in the gap's
colour on this frame (`drgnx-look--island-faces-set'), whatever the theme says."
  (let ((gap (drgnx-look--card-gap-px frame)) (recolour nil))
    (unless (frame-parameter frame 'drgnx-look-card-saved)
      (set-frame-parameter frame 'drgnx-look-card-saved
                           (list (frame-parameter frame 'right-divider-width)
                                 (frame-parameter frame 'bottom-divider-width)
                                 (drgnx-look--edge-without frame))))
    (dolist (p '(right-divider-width bottom-divider-width internal-border-width))
      (unless (eql (frame-parameter frame p) gap) (set-frame-parameter frame p gap)))
    (setq recolour (drgnx-look--island-faces-set frame))
    (dolist (w (window-list frame 'nomini))
      (if (drgnx-look--card-window-p w) (drgnx-look--card-set w) (drgnx-look--card-unset w)))
    ;; Glitnir reads a card's colours (what its corners show: the gap's colour) when it resolves the card: a
    ;; colour set on the frame outside a theme shows after a refresh
    (when (and recolour (fboundp 'glitnir-refresh)) (glitnir-refresh))))

(defun drgnx-look--card-restore (frame)
  "Take the cards off FRAME and give its divider widths and edge gap back (a window born with the edge that never
became a card frame gets the edge it would have had too; a child frame keeps its own)."
  (dolist (w (window-list frame 'nomini)) (drgnx-look--card-unset w))
  (if-let* ((saved (frame-parameter frame 'drgnx-look-card-saved)))
      (progn
        (set-frame-parameter frame 'right-divider-width (car saved))
        (set-frame-parameter frame 'bottom-divider-width (cadr saved))
        (set-frame-parameter frame 'internal-border-width (or (nth 2 saved) 0))
        (drgnx-look--island-faces-restore frame)
        (set-frame-parameter frame 'drgnx-look-card-saved nil))
    (when (and (frame-parameter frame 'drgnx-look-edge-born) (not (frame-parent frame)))
      (set-frame-parameter frame 'internal-border-width (drgnx-look--edge-without frame))))
  (set-frame-parameter frame 'drgnx-look-edge-born nil))

(defun drgnx-look-cards-apply ()
  "Docked panes as cards on every graphical frame, while Glitnir draws them."
  (when (drgnx-look--cards-p)
    (dolist (f (drgnx-look--card-frames)) (drgnx-look--card-frame f))))

(defun drgnx-look-cards-clear ()
  "Every card off, the dividers as they were."
  (dolist (f (frame-list)) (drgnx-look--card-restore f)))

;;;; Theme

(drgnx-defsetting drgnx-look-theme 'auto
  "The colour theme ui/look loads at start (Color Theme picks it); `auto': drgnx Dark, Light or High Contrast as
the desktop says, until a theme of yours is loaded; nil: the theme Emacs starts with.  A change switches the theme
at once while the module runs."
  :type '(choice (const :tag "Follow the desktop" auto) (const :tag "Emacs's own" nil) symbol) :group 'drgnx
  :scope 'global :workspace 'never :agents 'never :apply #'drgnx-look--settings-apply
  :schema '(or null symbol))

(defun drgnx-look--saved-theme () (plist-get (drgnx-modules-read-state) :theme))

(defvar drgnx-look--taken nil
  "While the module is on: (:previous THEMES :ours THEMES), the themes enabled when its setup began and those it
loaded since.  Its teardown gives the previous ones back.")

(defun drgnx-look--load (theme)
  "Make THEME the only enabled theme, noting that the module loaded it."
  (mapc #'disable-theme custom-enabled-themes)
  (when drgnx-look--taken (cl-pushnew theme (plist-get drgnx-look--taken :ours)))
  (load-theme theme t))

(defun drgnx-look--teardown ()
  "Zen mode off; the themes the module loaded off, the ones enabled before its setup on again (a theme someone
else enabled since stays)."
  (when (frame-parameter nil 'drgnx-look-zen) (drgnx-look-zen))
  (drgnx-look-follow-off)
  (drgnx-look-echo-area-off)
  (drgnx-look-density-off)
  (drgnx-look-fonts-off)
  (drgnx-look-derive-off)
  (when drgnx-look--taken
    (dolist (theme (plist-get drgnx-look--taken :ours))
      (when (memq theme custom-enabled-themes) (disable-theme theme)))
    (dolist (theme (reverse (plist-get drgnx-look--taken :previous)))
      (unless (memq theme custom-enabled-themes)
        (if (custom-theme-p theme) (enable-theme theme) (load-theme theme t))))
    (setq drgnx-look--taken nil)))

(defun drgnx-look--settings-apply ()
  "The `:apply' of `drgnx-look-theme': switch to it, while the module runs and the theme is installed.  A theme
that does not load is said, and the colours stay.  `auto' hands over to the follower."
  (when (and drgnx-look-theme (drgnx-module-running-p 'ui/look))
    (if (eq drgnx-look-theme 'auto)
        (drgnx-look-follow-apply)
      (drgnx-look--settings-apply-theme))))

(defun drgnx-look--settings-apply-theme ()
  "Switch to the theme `drgnx-look-theme' names, when it is installed."
  (when (and (not (equal custom-enabled-themes (list drgnx-look-theme)))
             (memq drgnx-look-theme (custom-available-themes)))
    (condition-case e (let ((drgnx-look-follow--loading t)) (drgnx-look--load drgnx-look-theme))
      (error (require 'drgnx-notice)
             (drgnx-notify 'config 'warn (format "the colour theme %s does not load (%s); Color Theme picks another"
                                                 drgnx-look-theme (error-message-string e))
                           :id 'look-theme :command 'preferences-theme)))))

(defun drgnx-look-load-theme (theme)
  "Make THEME the only theme and remember it (`drgnx-look-theme', in settings.el).  A settings.el with a mistake
refuses (`drgnx-settings-refused') before the theme changes.  THEME is your choice, one of drgnx's own included:
under `auto' the follower pauses, as for a `load-theme' in config.el."
  (drgnx-settings-area-ensure-writable)
  (drgnx-look--load theme)
  (drgnx-modules-update-state (lambda (state) (plist-put (copy-sequence state) :theme theme))))

(defun drgnx-look-choose-theme (theme)
  "Pick the colour theme (remembered for the next start)."
  (interactive (list (intern (completing-read "Color theme: " (mapcar #'symbol-name (custom-available-themes)) nil t))))
  (drgnx-look-load-theme theme))

;;;; The echo area on the gap

(defconst drgnx-look--echo-buffers '(" *Echo Area 0*" " *Echo Area 1*" " *Minibuf-0*")
  "The echo area's buffers: the two Emacs shows messages in, and the minibuffer window's own while no prompt is open.")

(defvar-local drgnx-look--gap-cookie nil "The cookie of the remap that puts this buffer on the gap surface.")

(defun drgnx-look--gap-on ()
  "Draw `default' as the gap surface in the current buffer (once)."
  (unless drgnx-look--gap-cookie
    (setq drgnx-look--gap-cookie (face-remap-add-relative 'default 'drgnx-surface-gap))))

(defun drgnx-look--gap-off ()
  "Take the gap surface off the current buffer."
  (when drgnx-look--gap-cookie
    (face-remap-remove-relative drgnx-look--gap-cookie)
    (setq drgnx-look--gap-cookie nil)
    (when (member (assq 'default face-remapping-alist) '((default) (default default)))
      (setq face-remapping-alist (assq-delete-all 'default face-remapping-alist)))))

(defun drgnx-look--minibuffer-gap ()
  "On `minibuffer-setup-hook': the minibuffer is on the gap surface, like the echo area."
  (drgnx-look--gap-on))

(defun drgnx-look--minibuffer-inactive-gap ()
  "On `minibuffer-inactive-mode-hook': put the gap surface back.
A prompt that ends puts its minibuffer in `minibuffer-inactive-mode', which clears the buffer's
remap (and the cookie with it), so the empty echo area would be drawn on the editor colour;
only the one remap is reapplied."
  (drgnx-look--gap-on))

(defun drgnx-look-echo-area-on ()
  "The echo area and every minibuffer on the gap surface."
  (add-hook 'minibuffer-setup-hook #'drgnx-look--minibuffer-gap)
  (add-hook 'minibuffer-inactive-mode-hook #'drgnx-look--minibuffer-inactive-gap)
  (dolist (name drgnx-look--echo-buffers)
    (when-let* ((b (get-buffer name))) (with-current-buffer b (drgnx-look--gap-on)))))

(defun drgnx-look-echo-area-off ()
  "Undo `drgnx-look-echo-area-on'."
  (remove-hook 'minibuffer-setup-hook #'drgnx-look--minibuffer-gap)
  (remove-hook 'minibuffer-inactive-mode-hook #'drgnx-look--minibuffer-inactive-gap)
  (dolist (b (buffer-list))
    (when (buffer-local-value 'drgnx-look--gap-cookie b) (with-current-buffer b (drgnx-look--gap-off)))))

;;;; Zoom

(defun drgnx-look--zoom (key)
  "Zoom every frame's text as the key KEY (+, - or 0) of global-text-scale-adjust; then +, - or 0 repeat."
  (let ((last-command-event key)) (global-text-scale-adjust 1)))

(defun drgnx-look-zoom-in () "Bigger text everywhere; then +, - or 0." (interactive) (drgnx-look--zoom ?=))
(defun drgnx-look-zoom-out () "Smaller text everywhere; then +, - or 0." (interactive) (drgnx-look--zoom ?-))
(defun drgnx-look-zoom-reset () "The text size back to normal." (interactive) (drgnx-look--zoom ?0))

;;;; Zen

(defvar drgnx-look-zen-width 100 "Text width in zen mode, in columns.")
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-wb-area-window "drgnx-area")
(declare-function drgnx-wb-area-hide "drgnx-area")
(declare-function drgnx-wb-area-show "drgnx-area")

(defun drgnx-look--margins (on)
  (dolist (w (seq-filter #'drgnx-signal-editor-window-p (window-list nil 'nomini)))
    (let ((m (if on (max 0 (/ (- (window-total-width w) drgnx-look-zen-width) 2)) 0)))
      (set-window-margins w m m))))

(defun drgnx-look-zen ()
  "Only the text: hide the sidebar, panel and right dock, centre the text; again to give them back."
  (interactive)
  (if-let* ((was (frame-parameter nil 'drgnx-look-zen)))
      (progn
        (set-frame-parameter nil 'drgnx-look-zen nil)
        (drgnx-look--margins nil)
        (when (plist-get was :sidebar) (drgnx-wb-show-sidebar))
        (when (fboundp 'drgnx-wb-area-show)
          (pcase-dolist (`(,key . ,area) '((:panel . panel) (:right . right)))
            (when (plist-get was key) (drgnx-wb-area-show area)))))
    (set-frame-parameter nil 'drgnx-look-zen
                         (list :on t :sidebar (drgnx-wb-sidebar-showing-p)
                               :panel (and (fboundp 'drgnx-wb-area-window) (drgnx-wb-area-window 'panel) t)
                               :right (and (fboundp 'drgnx-wb-area-window) (drgnx-wb-area-window 'right) t)))
    (drgnx-wb-hide-sidebar)
    (when (fboundp 'drgnx-wb-area-hide) (drgnx-wb-area-hide 'panel) (drgnx-wb-area-hide 'right))
    (drgnx-look--margins t)))

(drgnx-module-define 'ui/look
                     :doc "Colour theme (remembered), zen mode, rounded shadowed popups under Glitnir."
                     :stage 'startup
                     :teardown #'drgnx-look--teardown
                     :setup
                     (lambda ()
                       (setq drgnx-look--taken (list :previous (copy-sequence custom-enabled-themes) :ours nil))
                       (drgnx-look--chrome-on)
                       (drgnx-modules-push-undo "docked panes as cards" #'drgnx-look-cards-clear)
                       (drgnx-look--edge-at-birth)     ; windows made from now on: born with the edge
                       ;; window parameters only, at once (before the frame is drawn); the gap's frame parameters
                       ;; change only with the scale, which comes idle
                       (drgnx-state-subscribe 'windows-changed #'drgnx-look--cards-windows-changed :lane 'now)
                       (drgnx-state-subscribe 'frame-resized #'drgnx-look--cards-frame-resized)
                       (drgnx-state-subscribe 'selected-changed #'drgnx-look--cards-selected-changed :lane 'now)
                       (drgnx-modules-push-undo "island faces" #'drgnx-look--islands-off)
                       (drgnx-look--islands-on)
                       ;; a card's side edge is a fringe beside the gap: pressing it drags the gap too
                       (drgnx-module-define-key 'global-map [right-fringe down-mouse-1] #'drgnx-look-edge-drag)
                       (drgnx-module-define-key 'global-map [left-fringe down-mouse-1] #'drgnx-look-edge-drag)
                       (drgnx-look-cards-apply)
                       (drgnx-look-derive-on)
                       (drgnx-look-fonts-on)
                       (drgnx-look-density-on)
                       (drgnx-look-echo-area-on)
                       (drgnx-command-define 'preferences-theme :category "Preferences" :title "Color Theme"
                                             :command #'drgnx-look-choose-theme :menu '("Options") :doc "Pick the colour theme (remembered)")
                       (drgnx-command-define 'view-zen :category "View" :title "Zen Mode" :scope 'window
                                             :command #'drgnx-look-zen :doc "Only the text; again to give the sidebar and panel back")
                       (pcase-dolist (`(,id ,title ,fn) '((view-zoom-in "Zoom In" drgnx-look-zoom-in) (view-zoom-out "Zoom Out" drgnx-look-zoom-out)
                                                          (view-zoom-reset "Reset Zoom" drgnx-look-zoom-reset)))
                         (drgnx-command-define id :category "View" :title title :command fn :doc "The text size in every window; then +, - or 0"))
                       (drgnx-command-define 'decor-activate :category "View" :title "Activate Button" :command #'drgnx-decor-activate
                                             :map 'drgnx-decor-button-map :when (lambda () (get-text-property (point) 'drgnx-decor-action))
                                             :doc "Run the decoration button at point")
                       ;; last, and guarded: a theme that errors leaves the commands (Color Theme picks another)
                       (drgnx-look-follow-on)
                       ;; Color Theme's pick of an earlier session: your choice, so the follower pauses for it
                       (when-let* ((theme (drgnx-look--saved-theme)))
                         (when (memq theme (custom-available-themes))      ; `auto' is not one: the follower chose
                           (condition-case e (drgnx-look--load theme)
                             (error (message "drgnx: the colour theme %s does not load (%s); Color Theme picks another"
                                             theme (error-message-string e))))))))

(provide 'drgnx-look)
;;; drgnx-look.el ends here
