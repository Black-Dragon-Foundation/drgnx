;;; drgnx-look.el --- Module ui/look: colour theme, zen mode -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Color Theme picks one of the installed themes (one at a time) and remembers it in modules.eld;
;; Zen mode hides the sidebar, the panel and the right dock and centres the text, and gives every
;; one of them back as it was.  See docs/guide/modules.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
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
(declare-function drgnx-look-derive-on "drgnx-look-derive" ())
(declare-function drgnx-look-derive-off "drgnx-look-derive" ())
(declare-function drgnx-look-density-on "drgnx-look-density" ())
(declare-function drgnx-look-density-off "drgnx-look-density" ())
(declare-function drgnx-look-fonts-on "drgnx-look-fonts" ())
(declare-function drgnx-look-fonts-off "drgnx-look-fonts" ())
(declare-function drgnx-decor-faces-on "drgnx-decor" ())
(declare-function drgnx-decor-activate "drgnx-decor" ())

;;;; Chrome (Glitnir, the compositor)

(defcustom drgnx-look-chrome
  '((corner-radius . 8) (shadow . (:blur 16 :offset (0 . 6) :spread 0 :opacity 0.35)) (transition . pop))
  "The chrome of popups (child frames) under Glitnir, in logical pixels: `child-frame-chrome' while ui/look is on.
No colours: the shadow takes the `child-frame-shadow' face, the border what the toolkit drew."
  :type 'sexp :group 'drgnx-face)

(defcustom drgnx-look-palette
  '((corner-radius . 12) (shadow . (:blur 60 :offset (0 . 24) :spread 0 :opacity 0.6))
    (alpha-background . 0.82) (backdrop-blur . 10) (transition . pop))
  "The floating command palette's child frame parameters under Glitnir, in logical pixels.
The 0.82 is a placeholder the look session tunes.  No colours: the shadow takes the `child-frame-shadow' face."
  :type 'sexp :group 'drgnx-face)

(defvar child-frame-chrome)
(declare-function glitnir-refresh "glitnir")

(defun drgnx-look--chrome-on ()
  "With Glitnir: popups rounded and shadowed, at once (`child-frame-chrome' set through the module; its undo
restores the old value, and the refresh recorded before it runs after that).  Without it, nothing."
  (when (featurep 'glitnir)
    (drgnx-modules-push-undo "glitnir chrome refresh" (lambda () (glitnir-refresh)))
    (drgnx-module-set 'child-frame-chrome drgnx-look-chrome)
    (drgnx-decor-faces-on)
    (glitnir-refresh)))

;;;; Cards (Glitnir, the compositor)

(defcustom drgnx-look-card
  '((corner-radius . 10) (shadow . (:blur 3 :offset (0 . 1) :spread 0 :opacity 0.45))
    (ring . (vertical-border . 0.6)) (gap . 6))
  "The card look of the docked panes (Explorer, panel, right dock) and the editor groups under Glitnir, in logical pixels.
`corner-radius', `shadow' and `ring' become the window parameters Glitnir reads; `gap' is the frame's
`right-divider-width' and `bottom-divider-width', the room the ring and shadow are drawn in (set in device
pixels: the gap times the frame's scale, and again when the scale changes).  The ring is a face
\(its foreground) and an opacity: no colour is named here."
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

(defun drgnx-look--card-frames ()
  "The graphical root frames."
  (seq-filter (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list)))

(defun drgnx-look--card-set (window)
  "Give WINDOW the card parameters, only those that differ (a setting of one reruns the hooks)."
  (dolist (p drgnx-look--card-parameters)
    (let ((v (alist-get p drgnx-look-card)))
      (unless (equal (window-parameter window p) v) (set-window-parameter window p v))))
  (unless (window-parameter window 'drgnx-look-card) (set-window-parameter window 'drgnx-look-card t)))

(defun drgnx-look--card-unset (window)
  "Take the card parameters off WINDOW, when this module put them on."
  (when (window-parameter window 'drgnx-look-card)
    (dolist (p (cons 'drgnx-look-card drgnx-look--card-parameters)) (set-window-parameter window p nil))))

(defun drgnx-look--card-gap-px (frame)
  "The gap in FRAME's own pixels: `gap' logical pixels times the frame's scale (a frame pixel is a device pixel
on the native shell)."
  (round (* (alist-get 'gap drgnx-look-card) (frame-scale-factor frame))))

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

(defun drgnx-look--card-frame (frame)
  "Make the docked panes of FRAME cards and widen the dividers to the gap; the frame's own widths are kept.  The
frame's edge gets the same gap (`internal-border-width'), in the dividers' colour."
  (let ((gap (drgnx-look--card-gap-px frame)) (recolour nil))
    (unless (frame-parameter frame 'drgnx-look-card-saved)
      (set-frame-parameter frame 'drgnx-look-card-saved
                           (list (frame-parameter frame 'right-divider-width)
                                 (frame-parameter frame 'bottom-divider-width)
                                 (frame-parameter frame 'internal-border-width))))
    (dolist (p '(right-divider-width bottom-divider-width internal-border-width))
      (unless (eql (frame-parameter frame p) gap) (set-frame-parameter frame p gap)))
    (let ((colour (face-foreground 'window-divider frame t)))
      (when (and colour (not (equal colour (face-background 'internal-border frame))))
        (set-face-background 'internal-border colour frame)
        (setq recolour t)))
    (dolist (w (window-list frame 'nomini))
      (if (drgnx-look--card-window-p w) (drgnx-look--card-set w) (drgnx-look--card-unset w)))
    ;; Glitnir reads a card's colours (what its corners show: the dividers' colour) when it resolves the card: a
    ;; colour set on the frame outside a theme shows after a refresh
    (when (and recolour (fboundp 'glitnir-refresh)) (glitnir-refresh))))

(defun drgnx-look--card-restore (frame)
  "Take the cards off FRAME and give its divider widths and edge gap back."
  (dolist (w (window-list frame 'nomini)) (drgnx-look--card-unset w))
  (when-let* ((saved (frame-parameter frame 'drgnx-look-card-saved)))
    (set-frame-parameter frame 'right-divider-width (car saved))
    (set-frame-parameter frame 'bottom-divider-width (cadr saved))
    (set-frame-parameter frame 'internal-border-width (or (nth 2 saved) 0))
    (set-face-background 'internal-border nil frame)
    (set-frame-parameter frame 'drgnx-look-card-saved nil)))

(defun drgnx-look-cards-apply ()
  "Docked panes as cards on every graphical frame, while Glitnir draws them."
  (when (drgnx-look--cards-p)
    (dolist (f (drgnx-look--card-frames)) (drgnx-look--card-frame f))))

(defun drgnx-look-cards-clear ()
  "Every card off, the dividers as they were."
  (dolist (f (frame-list)) (drgnx-look--card-restore f)))

;;;; Theme

(drgnx-defsetting drgnx-look-theme nil
  "The colour theme ui/look loads at start (Color Theme picks it); nil: the theme Emacs starts with.  A change
switches the theme at once while the module runs."
  :type '(choice (const :tag "Emacs's own" nil) symbol) :group 'drgnx
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
that does not load is said, and the colours stay."
  (when (and drgnx-look-theme (drgnx-module-running-p 'ui/look)
             (not (equal custom-enabled-themes (list drgnx-look-theme)))
             (memq drgnx-look-theme (custom-available-themes)))
    (condition-case e (drgnx-look--load drgnx-look-theme)
      (error (require 'drgnx-notice)
             (drgnx-notify 'config 'warn (format "the colour theme %s does not load (%s); Color Theme picks another"
                                                 drgnx-look-theme (error-message-string e))
                           :id 'look-theme :command 'preferences-theme)))))

(defun drgnx-look-load-theme (theme)
  "Make THEME the only theme and remember it (`drgnx-look-theme', in settings.el).  A settings.el with a mistake
refuses (`drgnx-settings-refused') before the theme changes."
  (drgnx-settings-area-ensure-writable)
  (drgnx-look--load theme)
  (drgnx-modules-update-state (lambda (state) (plist-put (copy-sequence state) :theme theme))))

(defun drgnx-look-choose-theme (theme)
  "Pick the colour theme (remembered for the next start)."
  (interactive (list (intern (completing-read "Color theme: " (mapcar #'symbol-name (custom-available-themes)) nil t))))
  (drgnx-look-load-theme theme))

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
                       ;; window parameters only, at once (before the frame is drawn); the gap's frame parameters
                       ;; change only with the scale, which comes idle
                       (drgnx-state-subscribe 'windows-changed #'drgnx-look--cards-windows-changed :lane 'now)
                       (drgnx-state-subscribe 'frame-resized #'drgnx-look--cards-frame-resized)
                       (drgnx-look-cards-apply)
                       (drgnx-look-derive-on)
                       (drgnx-look-fonts-on)
                       (drgnx-look-density-on)
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
                       (when-let* ((theme (drgnx-look--saved-theme)))
                         (when (memq theme (custom-available-themes))
                           (condition-case e (drgnx-look--load theme)
                             (error (message "drgnx: the colour theme %s does not load (%s); Color Theme picks another"
                                             theme (error-message-string e))))))))

(provide 'drgnx-look)
;;; drgnx-look.el ends here
