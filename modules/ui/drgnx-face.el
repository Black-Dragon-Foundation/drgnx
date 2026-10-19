;;; drgnx-face.el --- Module ui/face: the frame and the buffers — calm, themed, informed -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The first part of M12f ("the face"): no light menu bar or GTK scroll bar, thin dividers in the theme's colours,
;; line numbers in code that never shift sideways while typing, problems at the end of their line, and the glyphs
;; drgnx draws (`drgnx-face-glyph', with an ASCII form for terminals that are not UTF-8).  Every choice is a
;; `defcustom' of group `drgnx-face' whose setter applies it to the frames and buffers that are open, so `setopt'
;; in config.el works without a restart.  Faces only inherit theme faces.  See docs/guide/face.md.

;;; Code:
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-face-state)
(require 'drgnx-frame-kind)
(defvar flymake-show-diagnostics-at-end-of-line)
(defvar display-line-numbers-width-start)
(defvar display-line-numbers-grow-only)
(declare-function window-divider-mode "frame")
(declare-function drgnx-close-setup "drgnx-close")
(declare-function drgnx-statusbar-setup "drgnx-statusbar")
(declare-function drgnx-quickhelp-setup "drgnx-quickhelp")
(declare-function drgnx-topline-setup "drgnx-topline")
(declare-function drgnx-start-setup "drgnx-start")
(declare-function drgnx-tty-popups-ascii-p "drgnx-tty-popups")
(declare-function drgnx-platform-wm "drgnx-platform-wm")
(declare-function x-change-window-property "xfns.c")
(declare-function x-delete-window-property "xfns.c")

(defgroup drgnx-face nil
  "How drgnx looks: the frame, the buffers, the glyphs."
  :group 'drgnx :prefix "drgnx-face-")

(defvar drgnx-face--active nil
  "Non-nil once the module has run: from then on a setting applies to the open frames and buffers when it changes.")

(defvar-local drgnx-face--numbers-p nil
  "Non-nil in a buffer where this module turned line numbers on (so it can turn them off again).")

;;;; Settings

(defun drgnx-face--set (symbol value)
  "Set SYMBOL to VALUE; when the module is running, apply it to every open frame and buffer."
  (set-default symbol value)
  (when drgnx-face--active
    (pcase symbol
      ((or 'drgnx-face-menu-bar 'drgnx-face-scroll-bars) (drgnx-face--apply-frames))
      ((or 'drgnx-face-dividers 'drgnx-face-divider-width) (drgnx-face--apply-dividers))
      ('drgnx-face-line-numbers-modes (drgnx-face--apply-line-numbers))
      ('drgnx-face-inline-problems (drgnx-face--apply-inline-problems))
      ('drgnx-face-line-spacing (drgnx-face--apply-line-spacing))
      ('drgnx-face-line-wrap (drgnx-face--apply-line-wrap))
      ('drgnx-face-frame-title (drgnx-face--apply-frame-title))
      ((or 'drgnx-face-title-bar 'drgnx-face-gtk-theme) (drgnx-face--apply-title-all)))))

(defcustom drgnx-face-menu-bar nil
  "Non-nil: show Emacs's menu bar (hidden, the commands are in the palette,
and F10 opens the menu as text in the minibuffer).
Toggle for this session with the command Toggle Menu Bar."
  :type 'boolean :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-scroll-bars 'none
  "Vertical scroll bars: `none' (the position is in the status bar) or `native' (the toolkit's, on the right)."
  :type '(choice (const :tag "None" none) (const :tag "Native, on the right" native))
  :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-dividers t
  "Non-nil: a thin line, in the theme's colour, between windows (graphical frames; terminals draw their own border)."
  :type 'boolean :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-divider-width 1
  "Width in pixels of the lines between windows (graphical frames), when `drgnx-face-dividers' is on."
  :type 'natnum :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-line-numbers-modes '(prog-mode conf-mode yaml-mode yaml-ts-mode)
  "Major modes (or the modes derived from them) whose file buffers show line numbers."
  :type '(repeat symbol) :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-inline-problems 'short
  "Problems (flymake) at the end of their line: nil (only underlined), `short' (the first one, shortened) or t (all)."
  :type '(choice (const :tag "Only underlined" nil) (const :tag "Short" short) (const :tag "In full" t))
  :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-line-spacing nil
  "Extra pixels between lines (nil: the default).  A number such as 2 or 3 is calmer for reading code."
  :type '(choice (const :tag "Default" nil) (natnum :tag "Pixels"))
  :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-line-wrap 'word
  "What a line longer than its window does: `word' (continue on the next row, breaking at a space, never in the middle
of a word; narrow windows too), `truncate' (one row, the rest is off the edge) or nil (leave Emacs's own setting).
The command Toggle Word Wrap flips it for one buffer.  Buffers that set their own (the Explorer, tables) keep it."
  :type '(choice (const :tag "Word wrap" word) (const :tag "Truncate" truncate) (const :tag "Emacs's own" nil))
  :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-frame-title t
  "Non-nil: a frame's title is `FILE — PROJECT — drgnx' (the buffer's name when it has no file;
with no project: `FILE — drgnx').  A `frame-title-format' of your own is left alone."
  :type 'boolean :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-title-bar 'dark
  "The window's title bar (graphical frames): `dark' (the system's own title bar in its dark variant while the theme
is dark, light while it is light), `system' (leave it as the desktop has it), or `drgnx' (drgnx draws it in the top
line; only under a window manager known to be a stacking one, never under a tiling one or one drgnx does not know).
GTK reads its theme variant once, at launch: on GTK without X11 (Wayland), a change here shows after a restart of
drgnx (`systemctl --user restart drgnx'); on X11 and on a Mac it applies at once."
  :type '(choice (const :tag "System title bar, dark variant" dark) (const :tag "System title bar, untouched" system)
                 (const :tag "Drawn by drgnx" drgnx))
  :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-gtk-theme "Adwaita"
  "The GTK theme whose dark (or light) variant the title bar uses: GTK_THEME becomes NAME:dark when drgnx starts."
  :type 'string :set #'drgnx-face--set :group 'drgnx-face)

(defcustom drgnx-face-glyphs
  '((handle "⠿" . "::") (close "×" . "x") (branch "⑂" . "Y") (warning "⚠" . "!") (ok "✓" . "+")
    (busy "◎" . "@") (waiting "◐" . "?") (paused "⏸" . "||") (ahead "↑" . "^") (behind "↓" . "v")
    (dot "●" . "*") (circle "○" . "o") (sep " · " . " | ") (flag "⚑" . "#")
    (diamond "◆" . "<>") (search "⌕" . "/") (bullet "•" . ">") (minimize "–" . "-") (maximize "▢" . "[]"))
  "The glyphs drgnx draws: NAME → (UNICODE . ASCII).  The ASCII form is used on a terminal frame that is not UTF-8.
Change one to suit your font; `drgnx-face-glyph' reads this."
  :type '(alist :key-type symbol :value-type (cons (string :tag "Unicode") (string :tag "ASCII")))
  :group 'drgnx-face)

;;;; Glyphs

(defun drgnx-face--ascii-frame-p (frame)
  "Non-nil when FRAME is a terminal frame whose terminal does not write UTF-8."
  (if (fboundp 'drgnx-tty-popups-ascii-p)
      (drgnx-tty-popups-ascii-p frame)
    (and (not (display-graphic-p frame))
         (let ((coding (terminal-coding-system (frame-terminal frame))))
           (not (and coding (string-prefix-p "utf-8" (symbol-name (coding-system-base coding)))))))))

(defun drgnx-face-glyph (name &optional frame)
  "The glyph NAME (see `drgnx-face-glyphs') as a string: its ASCII form on a terminal frame that is not UTF-8.
FRAME defaults to the selected one.  nil when NAME is unknown."
  (when-let* ((g (alist-get name drgnx-face-glyphs)))
    (if (drgnx-face--ascii-frame-p (or frame (selected-frame))) (cdr g) (car g))))

;;;; Frames

(defun drgnx-face--frame-params ()
  "The frame parameters the settings ask for (no menu bar parameter on a Mac: the system menu bar is shared)."
  `(,@(unless (eq system-type 'darwin) `((menu-bar-lines . ,(if drgnx-face-menu-bar 1 0))))
    (vertical-scroll-bars . ,(if (eq drgnx-face-scroll-bars 'native) 'right nil))))

(defun drgnx-face-apply-frame (&optional frame)
  "Give FRAME (default: the selected one) the menu bar, scroll bars and title bar the settings ask for.
On `after-make-frame-functions'; a child frame (a popup) is left alone."
  (let ((frame (or frame (selected-frame))))
    (when (and (frame-live-p frame) (not (eq (drgnx-state-frame-kind frame) 'child)))
      (modify-frame-parameters frame (drgnx-face--frame-params))
      (drgnx-face--apply-title frame)
      (drgnx-face--sync-state))))   ; the first graphical frame of a daemon is where the variant first becomes known

(defun drgnx-face--apply-frames ()
  "The settings on every open frame, and on the frames made later (`default-frame-alist')."
  (dolist (p (drgnx-face--frame-params))
    (setq default-frame-alist (cons (cons (car p) (cdr p)) (assq-delete-all (car p) default-frame-alist))))
  (mapc #'drgnx-face-apply-frame (frame-list)))

(defvar drgnx-face--dividers-owned nil
  "Non-nil when this module turned `window-divider-mode' on (so only then does it turn it off).")

(defun drgnx-face--apply-dividers ()
  "Thin dividers on or off; their faces inherit the theme's (a theme's own choice still wins).
Turning them off leaves `window-divider-mode' alone unless this module turned it on."
  (if drgnx-face-dividers
      (progn
        (setq-default window-divider-default-places t
                      window-divider-default-right-width drgnx-face-divider-width
                      window-divider-default-bottom-width drgnx-face-divider-width)
        (dolist (f '(window-divider window-divider-first-pixel window-divider-last-pixel vertical-border))
          (face-spec-set f '((t :inherit shadow)) 'face-defface-spec))
        (unless (bound-and-true-p window-divider-mode) (setq drgnx-face--dividers-owned t))
        (window-divider-mode 1))
    (when drgnx-face--dividers-owned
      (setq drgnx-face--dividers-owned nil)
      (window-divider-mode -1))))

;;;; Title bar

(defconst drgnx-face--stacking-wms '(gnome kwin)
  "The window managers known to be stacking (they draw title bars of their own), the only ones under which drgnx
draws the title bar.  Tiling ones (sway, i3, Hyprland, niri) have none to replace, and `nil', `none', `tty', `x11',
`other-wayland' or any name not listed are not known: the title bar stays the system's.")

(defvar drgnx-face--wm-noted nil
  "Non-nil once the message that the window manager is unknown (so no drawn title bar) has been shown.")

(defun drgnx-face--gui-system (frame)
  "The window system of FRAME (`x', `pgtk', `ns', `w32') when it is graphical; nil for a terminal or a non-frame."
  (and (framep frame) (display-graphic-p frame) (window-system frame)))

(defun drgnx-face-title-variant (&optional frame)
  "The title bar's GTK or macOS variant for FRAME (default: the selected one): `dark' or `light' as the frame's
background is, or nil when `drgnx-face-title-bar' is `system' (the desktop's own choice) or the background is unknown.
`drgnx' uses the same variant: it is the title bar when drgnx does not draw it."
  (when (memq drgnx-face-title-bar '(dark drgnx))
    (let ((mode (frame-parameter (or frame (selected-frame)) 'background-mode)))
      (and (memq mode '(dark light)) mode))))

(defun drgnx-face--drawn-wanted-p (frame)
  "Non-nil when FRAME's title bar is to be drawn by drgnx: the setting is `drgnx', FRAME is graphical and
`drgnx-platform-wm' names a stacking window manager (`drgnx-face--stacking-wms').  A tiling, unknown or unrecognised
one, or no `drgnx-platform-wm' at all, says so once and gives nil: the title bar stays the system's, dark."
  (and (eq drgnx-face-title-bar 'drgnx) (drgnx-face--gui-system frame)
       (or (and (fboundp 'drgnx-platform-wm) (memq (drgnx-platform-wm frame) drgnx-face--stacking-wms) t)
           (progn
             (unless drgnx-face--wm-noted
               (setq drgnx-face--wm-noted t)
               (message "drgnx: the window manager is not known to have title bars of its own, so the title bar stays the system's, in its dark variant"))
             nil))))

(defvar drgnx-face--drawn (make-hash-table :test #'eq :weakness 'key)
  "Frame -> t for the frames whose title bar drgnx draws.  Weak on the frame, so a closed frame leaves nothing behind.
A hash table, not a frame parameter: `frame-parameter' builds the whole parameter list to answer, and the top line asks
on every redisplay.")

(defun drgnx-face-drawn-title-p (&optional frame)
  "Non-nil when drgnx draws FRAME's title bar (default: the selected frame): the frame is undecorated by this setting.
Reads what `drgnx-face--apply-title' decided when the frame was made or the setting changed, and allocates nothing,
so the top line may ask on every redisplay."
  (gethash (or frame (selected-frame)) drgnx-face--drawn))

(defun drgnx-face--x-variant (frame variant)
  "On X11, give FRAME the GTK window property _GTK_THEME_VARIANT VARIANT; nil takes back what this module set."
  (cond (variant
         (when (fboundp 'x-change-window-property)
           (x-change-window-property "_GTK_THEME_VARIANT" (symbol-name variant) frame 'UTF8_STRING 8 t))
         (set-frame-parameter frame 'drgnx-face-gtk-variant t))
        ((frame-parameter frame 'drgnx-face-gtk-variant)
         (when (fboundp 'x-delete-window-property) (x-delete-window-property "_GTK_THEME_VARIANT" frame))
         (set-frame-parameter frame 'drgnx-face-gtk-variant nil))))

(defun drgnx-face--ns-variant (frame variant)
  "On macOS, give FRAME `ns-appearance' VARIANT and a transparent title bar; nil takes back only what this module set."
  (cond (variant
         (modify-frame-parameters frame `((ns-appearance . ,variant) (ns-transparent-titlebar . t)
                                          (drgnx-face-ns-variant . t))))
        ((frame-parameter frame 'drgnx-face-ns-variant)
         (modify-frame-parameters frame '((ns-appearance) (ns-transparent-titlebar) (drgnx-face-ns-variant))))))

(defun drgnx-face--apply-title (frame)
  "FRAME's title bar as `drgnx-face-title-bar' asks, on a graphical frame.
X11: the window property GTK reads.  macOS: `ns-appearance'.  GTK without X11 (pgtk): nothing now, GTK reads
GTK_THEME once, when drgnx starts (bin/drgnx and the systemd unit set it from face.eld).  A drawn title bar makes
the frame undecorated."
  (when-let* ((system (drgnx-face--gui-system frame)))
    (let ((variant (drgnx-face-title-variant frame)) (drawn (drgnx-face--drawn-wanted-p frame)))
      (pcase system
        ('x (drgnx-face--x-variant frame variant))
        ('ns (drgnx-face--ns-variant frame variant)))
      (when (or drawn (gethash frame drgnx-face--drawn))
        (if drawn (puthash frame t drgnx-face--drawn) (remhash frame drgnx-face--drawn))
        (modify-frame-parameters frame `((undecorated . ,drawn)))))))

(defun drgnx-face--sync-state ()
  "Keep `:variant' and `:gtk-theme' in face.eld as the launchers need them (bin/drgnx, the systemd unit), written only
when they changed.  The variant is that of a graphical frame; with none, or a background not known, nothing is written."
  (when-let* ((frame (seq-find (lambda (f) (and (not (eq (drgnx-state-frame-kind f) 'child)) (drgnx-face--gui-system f))) (frame-list))))
    (let ((variant (drgnx-face-title-variant frame)) (state (drgnx-face-state-read)))
      (when (or variant (eq drgnx-face-title-bar 'system))
        (unless (and (eq (plist-get state :variant) variant) (equal (plist-get state :gtk-theme) drgnx-face-gtk-theme))
          ;; an automatic path: no wait for the lock; when another drgnx holds it, the next theme change writes
          (condition-case err
              (drgnx-face-state-put (list :variant variant :gtk-theme drgnx-face-gtk-theme) 0)
            (drgnx-file-busy nil)
            (error (message "drgnx: face.eld not written: %s" (error-message-string err)))))))))

(defun drgnx-face--apply-title-all ()
  "The title bar on every open frame, and the state the launchers read."
  (dolist (f (frame-list)) (unless (eq (drgnx-state-frame-kind f) 'child) (drgnx-face--apply-title f)))
  (drgnx-face--sync-state)
  (force-mode-line-update t))   ; the top line shows its window controls only on a drawn title bar

(defun drgnx-face--on-theme (&optional _theme)
  "On `enable-theme-functions': the new theme may have changed the background, so the variant."
  (drgnx-face--apply-title-all))

;;;; Buffers

(defun drgnx-face--numbers-wanted-p ()
  "Non-nil when this buffer is code or configuration that visits a file, or an Untitled editor (any mode)."
  (or (bound-and-true-p drgnx-untitled-p)
      (and buffer-file-name drgnx-face-line-numbers-modes
           (apply #'derived-mode-p drgnx-face-line-numbers-modes))))

(defun drgnx-face-line-numbers-maybe ()
  "Line numbers in this buffer when it is code visiting a file or an Untitled editor; the number column never changes
width while typing.
On `after-change-major-mode-hook'."
  (when (drgnx-face--numbers-wanted-p)
    (setq-local display-line-numbers-width-start t
                display-line-numbers-grow-only t
                drgnx-face--numbers-p t)
    (display-line-numbers-mode 1)))

(defun drgnx-face--apply-line-numbers ()
  "The modes setting on every open buffer: numbers on where wanted, off where this module put them and they no longer are."
  (dolist (b (buffer-list))
    (with-current-buffer b
      (cond ((drgnx-face--numbers-wanted-p) (drgnx-face-line-numbers-maybe))
            (drgnx-face--numbers-p
             (setq drgnx-face--numbers-p nil)
             (display-line-numbers-mode -1))))))

(defvar drgnx-face--flymake-waiting nil
  "Non-nil while one after-load hook waits for flymake (so a setting changed often adds only one).")

(defun drgnx-face--flymake-ready-p ()
  "Non-nil when flymake is loaded and this Emacs has its end-of-line variable (30.1 and later)."
  (boundp 'flymake-show-diagnostics-at-end-of-line))

(defun drgnx-face--apply-inline-problems ()
  "`drgnx-face-inline-problems' into flymake's variable: now when flymake is loaded, else once it loads."
  (cond ((drgnx-face--flymake-ready-p)
         (funcall (or (get 'flymake-show-diagnostics-at-end-of-line 'custom-set) #'set-default)
                  'flymake-show-diagnostics-at-end-of-line drgnx-face-inline-problems))
        ((not drgnx-face--flymake-waiting)
         (setq drgnx-face--flymake-waiting t)
         (with-eval-after-load 'flymake
           (setq drgnx-face--flymake-waiting nil)
           (when (drgnx-face--flymake-ready-p) (drgnx-face--apply-inline-problems))))))

(defvar drgnx-face--line-spacing-saved nil
  "(VALUE) the default `line-spacing' this module replaced, to give back when the setting returns to nil.")

(defun drgnx-face--apply-line-spacing ()
  "The setting into the default `line-spacing'; nil gives back what it replaced (a user's own value stays)."
  (cond (drgnx-face-line-spacing
         (unless drgnx-face--line-spacing-saved
           (setq drgnx-face--line-spacing-saved (list (default-value 'line-spacing))))
         (setq-default line-spacing drgnx-face-line-spacing))
        (drgnx-face--line-spacing-saved
         (setq-default line-spacing (car drgnx-face--line-spacing-saved))
         (setq drgnx-face--line-spacing-saved nil))))

;;;; Line wrap

(defvar drgnx-face--wrap-saved nil
  "(WORD-WRAP TRUNCATE-LINES TRUNCATE-PARTIAL-WIDTH-WINDOWS) the defaults this module replaced, to give back.")

(defun drgnx-face--apply-line-wrap ()
  "The setting into the default values of `word-wrap', `truncate-lines' and `truncate-partial-width-windows': one
policy for every window, narrow ones included (Emacs cuts below 50 columns, and wraps in the middle of a word above).
nil gives back what it replaced."
  (when (and drgnx-face-line-wrap (not drgnx-face--wrap-saved))
    (setq drgnx-face--wrap-saved (list (default-value 'word-wrap) (default-value 'truncate-lines)
                                       (default-value 'truncate-partial-width-windows))))
  (pcase drgnx-face-line-wrap
    ('word (setq-default word-wrap t truncate-lines nil truncate-partial-width-windows nil))
    ('truncate (setq-default truncate-lines t truncate-partial-width-windows nil))
    (_ (when drgnx-face--wrap-saved
         (setq-default word-wrap (nth 0 drgnx-face--wrap-saved) truncate-lines (nth 1 drgnx-face--wrap-saved)
                       truncate-partial-width-windows (nth 2 drgnx-face--wrap-saved))
         (setq drgnx-face--wrap-saved nil)))))

(defun drgnx-face-toggle-wrap ()
  "Wrap long lines at a word or cut them at the window's edge, in this buffer only."
  (interactive)
  (setq-local truncate-lines (not truncate-lines))
  (unless truncate-lines (setq-local word-wrap t))
  (force-mode-line-update)
  (message "Word wrap %s" (if truncate-lines "off" "on")))

;;;; The frame's title

(defun drgnx-face-frame-title ()
  "`FILE — PROJECT — drgnx' for the selected window's buffer: the file's name (else the buffer's), the project from the
breadcrumb's cache (no lookup: this runs in redisplay), then the framework's name.  The start page is just `drgnx'."
  (let* ((b (current-buffer))
         (name (cond ((derived-mode-p 'drgnx-start-mode) nil)
                     (buffer-file-name (file-name-nondirectory buffer-file-name))
                     (t (string-trim (buffer-name b)))))
         (cache (and (boundp 'drgnx-chrome--root) drgnx-chrome--root))
         (project (and name (consp cache) (stringp (cdr cache)) (equal (car cache) default-directory)
                       (file-name-nondirectory (directory-file-name (cdr cache))))))
    (string-join (delq nil (list (and name (not (string-empty-p name)) name) project "drgnx")) " — ")))

(defconst drgnx-face--frame-title-construct '(:eval (drgnx-face-frame-title)) "Our value of `frame-title-format'.")

(defun drgnx-face--stock-title-p (format)
  "Non-nil when FORMAT is Emacs's own `frame-title-format': the `multiple-frames' conditional it starts with."
  (and (consp format) (eq (car format) 'multiple-frames)))

(defconst drgnx-face--stock-title '(multiple-frames "%b" ("" "%b - GNU Emacs at " system-name))
  "What `frame-title-format' goes back to when the setting is turned off.")

(defun drgnx-face--apply-frame-title ()
  "`frame-title-format' to drgnx's title when the setting is on and Emacs's own format is still there; back to Emacs's
when it is off and ours is there.  A format of your own stays."
  (let ((now (default-value 'frame-title-format)))
    (cond ((and drgnx-face-frame-title (drgnx-face--stock-title-p now))
           (setq-default frame-title-format drgnx-face--frame-title-construct))
          ((and (not drgnx-face-frame-title) (equal now drgnx-face--frame-title-construct))
           (setq-default frame-title-format drgnx-face--stock-title)))))

;;;; Commands

(defun drgnx-face-toggle-menu-bar ()
  "Show or hide the menu bar, for this session (`drgnx-face-menu-bar' keeps the default)."
  (interactive)
  (customize-set-variable 'drgnx-face-menu-bar (not drgnx-face-menu-bar))
  (message "Menu bar %s" (if drgnx-face-menu-bar "shown" "hidden")))

(defun drgnx-face-menu ()
  "Open the menu: Emacs's menu bar when it is shown, else the same menu as text in the minibuffer (`tmm-menubar').
F10's `menu-bar-open' has no menu to open on a toolkit frame whose bar is hidden, and can freeze the window."
  (interactive)
  (if (zerop (or (frame-parameter nil 'menu-bar-lines) 0))
      (tmm-menubar)
    (call-interactively #'menu-bar-open)))

(defun drgnx-face-preferences ()
  "Open Customize on the `drgnx-face' group: every setting of how drgnx looks, applied live."
  (interactive)
  (customize-group 'drgnx-face))

(defun drgnx-face--setup ()
  (drgnx-command-define 'face-toggle-menu-bar :category "View" :title "Toggle Menu Bar" :menu '("View")
                        :command #'drgnx-face-toggle-menu-bar
                        :doc "Show or hide Emacs's menu bar for this session (hidden, F10 opens the menu as text)")
  (drgnx-command-define 'face-toggle-wrap :category "View" :title "Toggle Word Wrap" :menu '("View")
                        :command #'drgnx-face-toggle-wrap
                        :doc "Wrap long lines at a word, or cut them at the window's edge, in this buffer")
  (drgnx-command-define 'face-menu :category "View" :title "Open the Menu" :command #'drgnx-face-menu
                        :doc "Open the menu: the menu bar when it is shown, else the same menu as text in the minibuffer (F10)")
  (drgnx-command-define 'face-preferences :category "Preferences" :title "Look and Layout Settings…" :menu '("Options")
                        :command #'drgnx-face-preferences
                        :doc "How drgnx looks: the frame, status bar, top line, quick help, start page (Customize)")
  (define-key global-map [remap menu-bar-open] #'drgnx-face-menu)   ; F10 opens the menu as text while the bar is hidden
  (when (fboundp 'drgnx-close-setup) (drgnx-close-setup))   ; Esc and q close panes (drgnx-close.el)
  (when (fboundp 'drgnx-statusbar-setup) (drgnx-statusbar-setup))   ; the status bar (drgnx-statusbar.el)
  (when (fboundp 'drgnx-quickhelp-setup) (drgnx-quickhelp-setup))   ; quick help (drgnx-quickhelp.el)
  (when (fboundp 'drgnx-topline-setup) (drgnx-topline-setup))   ; the top line (drgnx-topline.el)
  (when (fboundp 'drgnx-start-setup) (drgnx-start-setup))   ; the start page (drgnx-start.el)
  (add-hook 'after-make-frame-functions #'drgnx-face-apply-frame)
  (add-hook 'enable-theme-functions #'drgnx-face--on-theme)
  (add-hook 'after-change-major-mode-hook #'drgnx-face-line-numbers-maybe)
  (setq drgnx-face--active t)
  (drgnx-face--apply-frames)
  (drgnx-face--sync-state)
  (drgnx-face--apply-dividers)
  (drgnx-face--apply-line-numbers)
  (drgnx-face--apply-inline-problems)
  (drgnx-face--apply-line-spacing)
  (drgnx-face--apply-line-wrap)
  (drgnx-face--apply-frame-title))

(drgnx-module-define 'ui/face
                     :doc "The frame and the buffers: no menu bar or scroll bar, thin themed dividers, line numbers in code, problems at the end of the line."
                     :stage 'startup :requires '(core/workbench)
                     :setup #'drgnx-face--setup
                     :settings '((drgnx-face-menu-bar . "show Emacs's menu bar (default: hidden)")
                                 (drgnx-face-scroll-bars . "none (default) or native")
                                 (drgnx-face-dividers . "thin themed lines between windows")
                                 (drgnx-face-line-numbers-modes . "modes whose files show line numbers")
                                 (drgnx-face-inline-problems . "nil, short (default) or t: problems at the end of the line")
                                 (drgnx-face-line-spacing . "extra pixels between lines")
                                 (drgnx-face-line-wrap . "word (default), truncate or nil: what a long line does")
                                 (drgnx-face-frame-title . "the frame's title: FILE — PROJECT — drgnx")
                                 (drgnx-face-title-bar . "dark (default), system or drgnx: the window's title bar")
                                 (drgnx-face-gtk-theme . "the GTK theme whose dark variant the title bar uses")
                                 (drgnx-face-glyphs . "the glyphs drgnx draws, each with an ASCII form")
                                 (drgnx-close-input-modes . "modes whose buffers you type into: Esc and q never close their pane")
                                 (drgnx-statusbar-left . "status bar segments on the left, in order")
                                 (drgnx-statusbar-right . "status bar segments on the right, in order")
                                 (drgnx-statusbar-drop-order . "segments dropped first when the window is narrow")
                                 (drgnx-statusbar-compact . "segments the other editor groups show")
                                 (drgnx-statusbar-place . "editors (default) or frame: where the status bar is")
                                 (drgnx-statusbar-indent-vars . "variables the indentation segment reads")
                                 (drgnx-statusbar-modes . "modes (besides file buffers) that get the status bar")
                                 (drgnx-statusbar-quiet-modes . "modes that get the quiet bar (the start page)")
                                 (drgnx-statusbar-quiet . "the quiet bar's segments, on the left")
                                 (drgnx-quickhelp-hover . "quick help when the mouse rests on a symbol")
                                 (drgnx-quickhelp-delay . "seconds the mouse rests before quick help shows")
                                 (drgnx-quickhelp-max-lines . "most lines of docs on the card")
                                 (drgnx-quickhelp-strip-lines . "height of the quick help strip in a terminal")
                                 (drgnx-topline . "the top line: project, branch, the keys that open everything")
                                 (drgnx-topline-min-lines . "fewest lines a terminal needs to show the top line")))

(provide 'drgnx-face)
;;; drgnx-face.el ends here
