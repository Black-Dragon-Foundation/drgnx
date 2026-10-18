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
(defvar flymake-show-diagnostics-at-end-of-line)
(defvar display-line-numbers-width-start)
(defvar display-line-numbers-grow-only)
(declare-function window-divider-mode "frame")
(declare-function drgnx-statusbar-setup "drgnx-statusbar")
(declare-function drgnx-tty-popups-ascii-p "drgnx-tty-popups")

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
      ('drgnx-face-line-spacing (drgnx-face--apply-line-spacing)))))

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

(defcustom drgnx-face-glyphs
  '((handle "⠿" . "::") (close "✕" . "x") (branch "⑂" . "Y") (warning "⚠" . "!") (ok "✓" . "+")
    (busy "◎" . "@") (waiting "◐" . "?") (paused "⏸" . "||") (ahead "↑" . "^") (behind "↓" . "v")
    (dot "●" . "*") (circle "○" . "o") (sep " · " . " | "))
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
  "Give FRAME (default: the selected one) the menu bar and scroll bars the settings ask for.
On `after-make-frame-functions'; a child frame (a popup) is left alone."
  (let ((frame (or frame (selected-frame))))
    (when (and (frame-live-p frame) (not (frame-parent frame)))
      (modify-frame-parameters frame (drgnx-face--frame-params)))))

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

;;;; Buffers

(defun drgnx-face--numbers-wanted-p ()
  "Non-nil when this buffer is code or configuration that visits a file."
  (and buffer-file-name drgnx-face-line-numbers-modes
       (apply #'derived-mode-p drgnx-face-line-numbers-modes)))

(defun drgnx-face-line-numbers-maybe ()
  "Line numbers in this buffer when it is code visiting a file; the number column never changes width while typing.
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

(defun drgnx-face--setup ()
  (drgnx-command-define 'face-toggle-menu-bar :category "View" :title "Toggle Menu Bar" :menu '("View")
                        :command #'drgnx-face-toggle-menu-bar
                        :doc "Show or hide Emacs's menu bar for this session (hidden, F10 opens the menu as text)")
  (drgnx-command-define 'face-menu :category "View" :title "Open the Menu" :command #'drgnx-face-menu
                        :doc "Open the menu: the menu bar when it is shown, else the same menu as text in the minibuffer (F10)")
  (define-key global-map [remap menu-bar-open] #'drgnx-face-menu)   ; F10 opens the menu as text while the bar is hidden
  (when (fboundp 'drgnx-statusbar-setup) (drgnx-statusbar-setup))   ; the status bar (drgnx-statusbar.el)
  (add-hook 'after-make-frame-functions #'drgnx-face-apply-frame)
  (add-hook 'after-change-major-mode-hook #'drgnx-face-line-numbers-maybe)
  (setq drgnx-face--active t)
  (drgnx-face--apply-frames)
  (drgnx-face--apply-dividers)
  (drgnx-face--apply-line-numbers)
  (drgnx-face--apply-inline-problems)
  (drgnx-face--apply-line-spacing))

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
                                 (drgnx-face-glyphs . "the glyphs drgnx draws, each with an ASCII form")
                                 (drgnx-statusbar-left . "status bar segments on the left, in order")
                                 (drgnx-statusbar-right . "status bar segments on the right, in order")
                                 (drgnx-statusbar-drop-order . "segments dropped first when the window is narrow")
                                 (drgnx-statusbar-compact . "segments the other editor groups show")
                                 (drgnx-statusbar-place . "editors (default) or frame: where the status bar is")
                                 (drgnx-statusbar-indent-vars . "variables the indentation segment reads")
                                 (drgnx-statusbar-modes . "modes (besides file buffers) that get the status bar")))

(provide 'drgnx-face)
;;; drgnx-face.el ends here
