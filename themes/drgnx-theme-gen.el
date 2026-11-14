;;; drgnx-theme-gen.el --- One token table, three themes: the generator behind drgnx-dark, -light and -high-contrast -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `themes/drgnx-tokens.eld' holds every colour drgnx has.  `drgnx-theme-define' turns one variant of it into a
;; `deftheme': the semantic faces (core/drgnx-faces.el) and the standard faces the design lists, so that every package
;; that inherits standard faces looks right.  Each face has a true-colour clause and a clause for terminals, in which
;; the gap and the panel collapse to the editor's colour (there the cards are the vertical border, not tints).
;; `drgnx-look-token' reads a token (tints composited over the editor); `drgnx-look-variant' says which variant is on.
;; No colour literal lives in this file.  See docs/guide/look.md.

;;; Code:
(require 'cl-lib)
(require 'drgnx-color)

(defconst drgnx-theme--tokens-file
  (expand-file-name "drgnx-tokens.eld" (file-name-directory (or load-file-name buffer-file-name)))
  "The token table.")

(defvar drgnx-theme--table nil "The token table once read: ((dark . ALIST) (light . ALIST) (hc . ALIST)).")

(defun drgnx-theme--read ()
  "The token table, read once."
  (or drgnx-theme--table
      (setq drgnx-theme--table
            (with-temp-buffer
              (insert-file-contents drgnx-theme--tokens-file)
              (read (current-buffer))))))

(defun drgnx-look-variant (&optional frame)
  "The look's variant on FRAME: `dark', `light' or `hc'.
From the active drgnx theme; with none, from the frame's background mode (`hc' only for drgnx-high-contrast)."
  (cond ((memq 'drgnx-high-contrast custom-enabled-themes) 'hc)
        ((memq 'drgnx-dark custom-enabled-themes) 'dark)
        ((memq 'drgnx-light custom-enabled-themes) 'light)
        ((eq (frame-parameter frame 'background-mode) 'light) 'light)
        (t 'dark)))

(defun drgnx-look-token (name &optional variant)
  "The colour of token NAME as \"#rrggbb\", in VARIANT (`dark', `light' or `hc'; default the active one).
A tint is composited over the variant's `editor', an `over' over its BASE token; a symbol is another token's colour."
  (let* ((variant (or variant (drgnx-look-variant)))
         (v (alist-get name (alist-get variant (drgnx-theme--read)))))
    (cl-flet ((colour (c) (if (stringp c) c (drgnx-look-token c variant))))
      (cond ((stringp v) v)
            ((and v (symbolp v)) (drgnx-look-token v variant))
            ((eq (car-safe v) 'tint)
             (drgnx-color-over (colour (cadr v)) (drgnx-look-token 'editor variant) (cddr v)))
            ((eq (car-safe v) 'over)                ; (over BASE COLOUR . ALPHA)
             (drgnx-color-over (colour (nth 2 v)) (drgnx-look-token (nth 1 v) variant) (nthcdr 3 v)))
            (t (error "drgnx: no colour token `%s' in the %s variant" name variant))))))

(defvar drgnx-theme--box-fit :unknown "Whether this Emacs's boxes take `:fit text' (`drgnx-theme--box-fit-p').")

(defun drgnx-theme--box-fit-p ()
  "Non-nil when this Emacs draws a box `:fit text': as tall as its text, not as its row, which `line-spacing' makes
taller (Nidhogg's compositor).  Asked once: a face that sets it is refused where the key is unknown."
  (when (eq drgnx-theme--box-fit :unknown)
    (setq drgnx-theme--box-fit
          (and (featurep 'glitnir)
               (let ((face (make-symbol "drgnx-theme-box-fit")))
                 (custom-declare-face face nil "Probe.")
                 (condition-case nil
                     (progn (set-face-attribute face nil :box '(:line-width 1 :fit text)) t)
                   (error nil))))))
  drgnx-theme--box-fit)

(defvar drgnx-theme--box-fit-pad :unknown
  "Whether this Emacs's boxes take `:fit (text . PAD)' (`drgnx-theme--box-fit-pad-p').")

(defun drgnx-theme--box-fit-pad-p ()
  "Non-nil when this Emacs's boxes fit their text with a pad, `:fit (text . PAD)': a ring PAD px clear of its text
above and below, the face's background between (Nidhogg's compositor).  Asked once, as `drgnx-theme--box-fit-p'."
  (when (eq drgnx-theme--box-fit-pad :unknown)
    (setq drgnx-theme--box-fit-pad
          (and (drgnx-theme--box-fit-p)
               (let ((face (make-symbol "drgnx-theme-box-fit-pad")))
                 (custom-declare-face face nil "Probe.")
                 (condition-case nil
                     (progn (set-face-attribute face nil :box '(:line-width 1 :fit (text . 1))) t)
                   (error nil))))))
  drgnx-theme--box-fit-pad)

(defconst drgnx-theme--ansi
  '((black . gap) (red . error) (green . ok) (yellow . warn) (blue . info) (magenta . kw) (cyan . ty) (white . fg))
  "Terminal colour → token.")

(defun drgnx-theme--faces (variant tok)
  "Every face the themes style, as ((FACE . ATTRIBUTES)…), for VARIANT; TOK maps a token name to a colour."
  (let ((hc (eq variant 'hc)))
    (cl-flet ((c (name) (funcall tok name)))
      (append
       ;; the semantic faces
       `((drgnx-surface-gap :background ,(c 'gap))
         (drgnx-surface-panel :background ,(c 'panel))
         (drgnx-surface-raised :background ,(c 'raised))
         (drgnx-surface-overlay :background ,(c 'overlay))
         (drgnx-text-muted :foreground ,(c 'muted))
         (drgnx-text-subtle :foreground ,(c 'subtle))
         (drgnx-text-disabled :foreground ,(c 'disabled))
         (drgnx-border :foreground ,(c 'border) :background ,(c 'border))
         ;; the palette's footer of keys: a hairline along its top (palette.html `.foot')
         (drgnx-palette-footer :inherit (drgnx-ui-caption default) :box nil :underline nil :overline ,(c 'border))
         (drgnx-border-strong :foreground ,(c 'border-strong) :background ,(c 'border-strong))
         (drgnx-border-subtle :foreground ,(c 'border-subtle) :background ,(c 'border-subtle))
         (drgnx-accent :foreground ,(c 'accent) :underline nil)
         (drgnx-hover :background ,(c 'hover) :box (:line-width (-2 . -2) :style flat-button))
         (drgnx-selected :background ,(c 'sel) ,@(and hc `(:foreground ,(c 'sel-fg))))
         (drgnx-selected-quiet :background ,(c 'sel-quiet))
         (drgnx-selected-inactive :background ,(c 'sel-inactive))
         ,@(and hc `((drgnx-selected-secondary :inherit drgnx-text-muted :foreground ,(c 'sel-fg))))
         (drgnx-focus :box (:line-width (-2 . -2) :color ,(c 'focus)))
         (drgnx-focus-line :foreground ,(c 'focus))
         (drgnx-status-attention :foreground ,(c 'attention))
         (drgnx-status-ok :foreground ,(c 'ok))
         (drgnx-status-warn :foreground ,(c 'warn))
         (drgnx-status-fail :foreground ,(c 'error))
         (drgnx-status-info :foreground ,(c 'info))
         (drgnx-agent-1 :foreground ,(c 'a1)) (drgnx-agent-2 :foreground ,(c 'a2)) (drgnx-agent-3 :foreground ,(c 'a3))
         (drgnx-agent-4 :foreground ,(c 'a4)) (drgnx-agent-5 :foreground ,(c 'a5)) (drgnx-agent-6 :foreground ,(c 'a6))
         (drgnx-control-hidden :foreground ,(c 'panel))
         ;; chips on their tints; high contrast has no tints, so a ring in the chip's own colour (a box with no colour)
         (drgnx-chip-quiet :foreground ,(c 'muted) :background ,(c 'sel-quiet) ,@(and hc '(:box (:line-width (-1 . -1)))))
         (drgnx-chip-attention :foreground ,(c 'attention) :background ,(c 'attention-tint)
                               ,@(and hc '(:box (:line-width (-1 . -1)))))
         (drgnx-chip-accent :foreground ,(c 'accent) :background ,(c 'accent-tint) ,@(and hc '(:box (:line-width (-1 . -1)))))
         ;; the solid chip: the accent's fill with its text colour (design: a step's number in the trail's circle)
         (drgnx-chip-solid :foreground ,(c 'on-accent) :background ,(c 'accent-fill))
         ;; an agent's initial: its colour filled, the editor's colour for the letter (work-space-dark.html `.who')
         (drgnx-work-who-1 :inherit drgnx-badge :foreground ,(c 'editor) :background ,(c 'a1))
         (drgnx-work-who-2 :inherit drgnx-badge :foreground ,(c 'editor) :background ,(c 'a2))
         (drgnx-work-who-3 :inherit drgnx-badge :foreground ,(c 'editor) :background ,(c 'a3))
         (drgnx-work-who-4 :inherit drgnx-badge :foreground ,(c 'editor) :background ,(c 'a4))
         (drgnx-work-who-5 :inherit drgnx-badge :foreground ,(c 'editor) :background ,(c 'a5))
         (drgnx-work-who-6 :inherit drgnx-badge :foreground ,(c 'editor) :background ,(c 'a6))
         (drgnx-chip-ok :foreground ,(c 'ok) :background ,(c 'ok-tint) ,@(and hc '(:box (:line-width (-1 . -1)))))
         (drgnx-chip-warn :foreground ,(c 'warn) :background ,(c 'warn-tint) ,@(and hc '(:box (:line-width (-1 . -1)))))
         (drgnx-tint-warn :background ,(c 'warn-tint) ,@(and hc `(:box (:line-width (-1 . -1) :color ,(c 'warn)))))
         (drgnx-chip-error :foreground ,(c 'error) :background ,(c 'error-tint) ,@(and hc '(:box (:line-width (-1 . -1)))))
         ;; the in-text chips (modules/ui/drgnx-decor.el) carry their own box, the room inside them: high contrast
         ;; makes it the 1 px ring instead (look.css `.t-hc .chip'; the room is the chip's stretches)
         ,@(and hc `((drgnx-chip :inherit (drgnx-ui-caption drgnx-chip-quiet)
                                 :box (:line-width (1 . 1) ,@(and (featurep 'glitnir) '(:corner-radius 4))))
                     (drgnx-badge :inherit (drgnx-ui-caption drgnx-chip-accent)
                                  :box (:line-width (1 . 1) ,@(and (featurep 'glitnir) '(:corner-radius 99))))))
         ;; controls (design §3.5 `.btn', `.btn.pri', `kbd'): a 1 px ring in a colour, so the theme gives it; rounded
         ;; where the compositor rounds a box (Glitnir)
         (drgnx-control :foreground ,(c 'fg) :background ,(c 'sel-quiet)
                        :box (:line-width (1 . 1) :color ,(c 'border) ,@(and (featurep 'glitnir) '(:corner-radius 6))))
         (drgnx-control-primary :foreground ,(c 'on-accent) :background ,(c 'accent-fill)
                                :box (:line-width (1 . 1) :color ,(c 'accent-fill)
                                                  ,@(and (featurep 'glitnir) '(:corner-radius 6))))
         ;; a toggle pill (agent-panel.html `.disc .t', 18 px: radius 9): ringed; on: on the quiet selection.  Not radius
         ;; 99: a radius past half the row's height erodes the text at the pill's ends
         (drgnx-pill :inherit drgnx-ui-caption :foreground ,(c 'subtle)
                     :box (:line-width (1 . 1) :color ,(c 'border) ,@(and (featurep 'glitnir) '(:corner-radius 6))))
         (drgnx-pill-on :inherit drgnx-ui-caption :foreground ,(c 'fg) :background ,(c 'sel-quiet)
                        :box (:line-width (1 . 1) :color ,(c 'border) ,@(and (featurep 'glitnir) '(:corner-radius 6))))
         (drgnx-pill-accent :inherit drgnx-ui-caption :foreground ,(c 'accent) :background ,(c 'accent-tint)
                            :box (:line-width (1 . 1) :color ,(c 'accent) ,@(and (featurep 'glitnir) '(:corner-radius 6))))
         (drgnx-pill-agent :inherit drgnx-ui-caption
                           :box (:line-width (1 . 1) ,@(and (featurep 'glitnir) '(:corner-radius 9))))
         ;; a keycap is as tall as its text, also on a list row made taller by `line-spacing' (the palette's)
         (drgnx-keycap :inherit drgnx-ui-caption :foreground ,(c 'subtle)
                       :box (:line-width (1 . 1) :color ,(c 'border-strong) ,@(and (featurep 'glitnir) '(:corner-radius 4))
                                         ,@(and (drgnx-theme--box-fit-p) '(:fit text))))
         ;; the Flow's gate pills (hub-orchestration.html `.g', 20 px, radius 10) and buttons (`.acts .btn', `.btn.pri'
         ;; and its key): text-height on its 30 px rows where boxes fit their text, the fill then confined to the box;
         ;; a pill is padded in its own colour (a flat button), the buttons keep the controls' rings.  Where boxes
         ;; cannot fit, a pill has no box (one would make its row taller) and the buttons are the controls
         ,@(mapcar (lambda (chip)
                     `(,(intern (format "drgnx-work-flow-chip-%s" (car chip)))
                       :inherit (drgnx-ui-caption ,(cdr chip)) :height 0.9167
                       ,@(and (drgnx-theme--box-fit-p)
                              `(:box (,@(if hc '(:line-width (1 . 1)) '(:line-width (6 . 3) :style flat-button))
                                      ,@(and (featurep 'glitnir) '(:corner-radius 10)) :fit text)))))
                   '((ok . drgnx-chip-ok) (run . drgnx-chip-accent) (held . drgnx-chip-attention)
                     (err . drgnx-chip-error) (wait . drgnx-chip-quiet)))
         (drgnx-work-flow-button :inherit (drgnx-ui-caption drgnx-control)
                                 ,@(and (drgnx-theme--box-fit-p)
                                        `(:box (:line-width (1 . 1) :color ,(c 'border)
                                                            ,@(and (featurep 'glitnir) '(:corner-radius 6))
                                                            :fit ,(if (drgnx-theme--box-fit-pad-p)
                                                                      '(text . 4)
                                                                    'text)))))
         (drgnx-work-flow-button-primary :inherit (drgnx-ui-caption drgnx-control-primary)
                                         ,@(and (drgnx-theme--box-fit-p)
                                                `(:box (:line-width (1 . 1) :color ,(c 'accent-fill)
                                                                    ,@(and (featurep 'glitnir) '(:corner-radius 6))
                                                                    :fit ,(if (drgnx-theme--box-fit-pad-p)
                                                                              '(text . 4)
                                                                            'text)))))
         ;; a key inside a button (`.btn .k'): 11 px on the button's own background, ringed in its text's colour
         (drgnx-work-flow-button-key :inherit drgnx-work-flow-button :height 0.9167 :foreground ,(c 'muted)
                                     :box (:line-width (1 . 1) :color ,(c 'muted)
                                                       ,@(and (featurep 'glitnir) '(:corner-radius 4))
                                                       ,@(and (drgnx-theme--box-fit-p)
                                                              `(:fit ,(if (drgnx-theme--box-fit-pad-p)
                                                                          '(text . 2)
                                                                        'text)))))
         (drgnx-work-flow-key-primary :inherit drgnx-work-flow-button-primary :height 0.9167
                                      :foreground ,(c 'on-accent)
                                      :box (:line-width (1 . 1) :color ,(c 'on-accent)
                                                        ,@(and (featurep 'glitnir) '(:corner-radius 4))
                                                        ,@(and (drgnx-theme--box-fit-p)
                                                               `(:fit ,(if (drgnx-theme--box-fit-pad-p)
                                                                           '(text . 2)
                                                                         'text))))))
       ;; the editor and the standard faces
       `((default :foreground ,(c 'fg) :background ,(c 'editor))
         (cursor :background ,(c 'accent))
         ;; the selection is a rounded run over the text (window-dark.html `.ln .sel'), stopping at the line's end;
         ;; its box is drawn inside the glyphs (negative widths), so text never moves; drgnx-decor scales it per frame.
         ;; `:extend nil' is said: a theme spec inherits `:extend' from the defface, and region's is t
         (region :background ,(c 'sel) ,@(and hc `(:foreground ,(c 'sel-fg))) :extend nil
                 :box (:line-width (-1 . -1) :style flat-button ,@(and (featurep 'glitnir) '(:corner-radius 3))))
         (secondary-selection :background ,(c 'sel-quiet))
         ;; a card's rows (work-space-dark.html `.card'): a 1 px ring in the strong border.  A ring with no colour takes
         ;; each text run's own foreground, so a card whose runs differ (a state dot, an overlap mark) breaks into boxes
         ,@(mapcar (lambda (row)
                     `(,(car row) :inherit secondary-selection
                       :box (:line-width 1 :color ,(c 'border-strong)
                                         ,@(and (featurep 'glitnir) `(:corner-radius 8 ,@(cdr row))))))
                   '((drgnx-card-top :open (bottom)) (drgnx-card-mid :open (top bottom))
                     (drgnx-card-bottom :open (top)) (drgnx-card-single)))
         ;; the selected card (`.card.sel'): the hub draws it in these, a 2 px ring in the accent
         ,@(mapcar (lambda (row)
                     `(,(car row) :inherit secondary-selection
                       :box (:line-width 2 :color ,(c 'accent)
                                         ,@(and (featurep 'glitnir) `(:corner-radius 8 ,@(cdr row))))))
                   '((drgnx-card-sel-top :open (bottom)) (drgnx-card-sel-mid :open (top bottom))
                     (drgnx-card-sel-bottom :open (top)) (drgnx-card-sel-single)))
         ;; agent-panel.html: the permission card is ringed in the attention colour (a ring with no colour took the head's
         ;; foreground, which the card faces' own explicit colour above now hides)
         (drgnx-agent-panel-perm-head :inherit (drgnx-ui-text drgnx-chip-attention) :weight bold
                                      :box (:line-width 1 :color ,(c 'attention)
                                                        ,@(and (featurep 'glitnir) '(:corner-radius 8))))
         ;; work-space-dark.html `.lens .on': the lens shown is a raised pill in a 1 px ring in the strong border
         (drgnx-work-lens-current :inherit (bold drgnx-pill-on)
                                  :box (:line-width 1 :color ,(c 'border-strong)
                                                    ,@(and (featurep 'glitnir) '(:corner-radius 6))))
         (highlight :background ,(c 'hover))
         (hl-line :background ,(c 'current-line) :extend t)
         (fringe :foreground ,(c 'subtle) :background ,(c 'editor))
         (line-number :foreground ,(c 'subtle))
         ;; the current line's band runs under its number too (window-dark.html `.ln.cur')
         (line-number-current-line :foreground ,(c 'fg) :background ,(c 'current-line))
         (shadow :foreground ,(c 'muted))
         (link :foreground ,(c 'accent) :underline t)
         (link-visited :foreground ,(c 'accent) :underline t)
         (error :foreground ,(c 'error))
         (warning :foreground ,(c 'warn))
         (success :foreground ,(c 'ok)))
       ;; syntax
       `((font-lock-keyword-face :foreground ,(c 'kw))
         (font-lock-builtin-face :foreground ,(c 'kw))
         (font-lock-preprocessor-face :foreground ,(c 'kw))
         (font-lock-function-name-face :foreground ,(c 'fn))
         (font-lock-function-call-face :foreground ,(c 'fn))
         (font-lock-string-face :foreground ,(c 'str))
         (font-lock-doc-face :foreground ,(c 'str))
         (font-lock-type-face :foreground ,(c 'ty))
         (font-lock-doc-markup-face :foreground ,(c 'ty))
         (font-lock-constant-face :foreground ,(c 'const))
         (font-lock-number-face :foreground ,(c 'const))
         (font-lock-escape-face :foreground ,(c 'const))
         (font-lock-regexp-grouping-backslash :foreground ,(c 'const))
         (font-lock-regexp-grouping-construct :foreground ,(c 'const))
         (font-lock-comment-face :foreground ,(c 'comment))
         (font-lock-comment-delimiter-face :foreground ,(c 'comment))
         (font-lock-punctuation-face :foreground ,(c 'punct))
         (font-lock-bracket-face :foreground ,(c 'punct))
         (font-lock-delimiter-face :foreground ,(c 'punct))
         (font-lock-operator-face :foreground ,(c 'punct))
         (font-lock-misc-punctuation-face :foreground ,(c 'punct))
         (font-lock-negation-char-face :foreground ,(c 'punct))
         (font-lock-variable-name-face :foreground ,(c 'fg))
         (font-lock-variable-use-face :foreground ,(c 'fg))
         (font-lock-property-name-face :foreground ,(c 'fg))
         (font-lock-property-use-face :foreground ,(c 'fg))
         (font-lock-warning-face :foreground ,(c 'warn)))
       ;; bars, tabs, dividers
       ;; the chrome's text is in the UI roles (design §3.1, "Where the UI font goes"); a theme spec replaces a
       ;; defface's `:inherit', so the tabs' own faces name theirs again
       `((mode-line :inherit drgnx-ui-caption :foreground ,(c 'fg) :background ,(c 'gap))
         (mode-line-active :inherit drgnx-ui-caption :foreground ,(c 'fg) :background ,(c 'gap))
         (mode-line-inactive :inherit drgnx-ui-caption :foreground ,(c 'muted) :background ,(c 'gap))
         (mode-line-emphasis :foreground ,(c 'accent))
         (mode-line-highlight :background ,(c 'hover))
         (mode-line-buffer-id :foreground ,(c 'fg))
         (header-line :inherit drgnx-ui-text :foreground ,(c 'muted) :background ,(c 'editor))   ; part of its card
         (header-line-highlight :background ,(c 'hover))
         (tab-bar :inherit drgnx-ui-text :foreground ,(c 'muted) :background ,(c 'gap))   ; the title row (§4)
         (drgnx-topline-strong :inherit drgnx-ui-heading :foreground ,(c 'fg) :background ,(c 'gap))
         (tab-bar-tab :inherit drgnx-ui-text :foreground ,(c 'fg) :background ,(c 'editor))
         (tab-bar-tab-inactive :inherit drgnx-ui-text :foreground ,(c 'muted) :background ,(c 'panel))
         (tab-line :inherit drgnx-ui-text :foreground ,(c 'muted) :background ,(c 'panel))
         (tab-line-tab :inherit drgnx-ui-text :foreground ,(c 'fg) :background ,(c 'editor))
         (tab-line-tab-current :inherit drgnx-ui-text :foreground ,(c 'fg) :background ,(c 'editor))
         (tab-line-tab-inactive :inherit drgnx-ui-text :foreground ,(c 'muted) :background ,(c 'panel))
         (tab-line-tab-special :inherit drgnx-ui-text :foreground ,(c 'muted) :background ,(c 'panel))
         (tab-line-highlight :background ,(c 'hover))
         ;; an area's tab row (the bottom panel's): muted text, the shown tab a pill on the quiet selection
         ;; (debugging.html `.pt', `.pt.on': radius 6, 24 px in the 32 px row)
         ;; (a space each side plus a 5 px box: the 9 px pad; drgnx-decor scales the boxes per frame)
         (drgnx-wb-tab :inherit tab-line-tab-inactive :foreground ,(c 'muted) :background ,(c 'panel)
                       :box (:line-width (5 . 3) :color ,(c 'panel)))
         (drgnx-wb-tab-current :inherit tab-line-tab-current :foreground ,(c 'fg) :background ,(c 'sel-quiet)
                               :box (:line-width (5 . 3) :color ,(c 'sel-quiet)
                                                 ,@(and (featurep 'glitnir) '(:corner-radius 6))))
         (tab-line-close-highlight :foreground ,(c 'accent))
         (window-divider :foreground ,(c 'gap))
         (window-divider-first-pixel :foreground ,(c 'gap))
         (window-divider-last-pixel :foreground ,(c 'gap))
         (vertical-border :foreground ,(c 'border))
         (internal-border :background ,(c 'gap))
         (child-frame-border :background ,(c 'border-strong))
         ,@(and (not hc) `((child-frame-shadow :foreground ,(c 'gap) :background ,(c 'gap))))
         (tooltip :foreground ,(c 'fg) :background ,(c 'raised))
         (minibuffer-prompt :foreground ,(c 'accent))
         (nidhogg-title-bar :foreground ,(c 'fg) :background ,(c 'gap))
         (nidhogg-title-bar-inactive :foreground ,(c 'muted) :background ,(c 'gap)))
       ;; search, matches, completion
       ;; matches are the accent's `match' tint over the text, which keeps its colours; the current one is ringed in
       ;; the accent (design "Matches"), the others edged in `match-edge'; boxes inside the glyphs, as the region's
       `((isearch :background ,(c 'match) :extend nil
                  :box (:line-width (-1 . -1) :color ,(c 'accent) ,@(and (featurep 'glitnir) '(:corner-radius 3))))
         (lazy-highlight :background ,(c 'match) :extend nil
                         :box (:line-width (-1 . -1) :color ,(c 'match-edge) ,@(and (featurep 'glitnir) '(:corner-radius 3))))
         (match :background ,(c 'accent-tint))
         (show-paren-match :background ,(c 'accent-tint) :weight bold)
         (show-paren-mismatch :foreground ,(c 'error) :background ,(c 'error-tint))
         (completions-common-part :foreground ,(c 'accent))
         (completions-first-difference :foreground ,(c 'fg) :weight bold)
         (completions-highlight :background ,(c 'sel))
         (completions-annotations :foreground ,(c 'subtle)))
       ;; diffs and version control
       `((diff-added :foreground ,(c 'add-fg) :background ,(c 'add-bg))
         (diff-removed :foreground ,(c 'del-fg) :background ,(c 'del-bg))
         ;; the Search preview's hunk band, a card (search-view.html `.hk'), and the Replace All sheet's selected file in
         ;; the focus ring (`.sheet .fl.sel'): rounded where the compositor rounds a box
         (drgnx-replace-preview-head :inherit drgnx-ui-text :foreground ,(c 'muted) :background ,(c 'sel-quiet)
                                     :box (:line-width (1 . 6) :color ,(c 'sel-quiet)
                                                       ,@(and (featurep 'glitnir) '(:corner-radius 6))))
         ;; a ticked box's mark (its image carries the fill) and the Replace button's key chip, ringed in its text
         (drgnx-replace-tick-mark :foreground ,(c 'on-accent))
         (drgnx-replace-sheet-key :inherit drgnx-ui-caption :foreground ,(c 'on-accent)
                                  :box (:line-width (1 . 1) :color ,(c 'on-accent)
                                                    ,@(and (featurep 'glitnir) '(:corner-radius 4))
                                                    ,@(and (drgnx-theme--box-fit-p) '(:fit text))))
         ;; the +/− counts in their colours, untinted; the foot's hairline
         (drgnx-replace-plus :inherit success :foreground ,(c 'add-fg))
         (drgnx-replace-minus :inherit error :foreground ,(c 'del-fg))
         (drgnx-replace-sheet-rule :inherit shadow :foreground ,(c 'border) :overline t)
         ;; a diff line's tint, rounded (the mockup's `.dl', radius 3) as the region: a box drawn inside the glyphs
         (drgnx-replace-preview-del :inherit diff-removed :extend nil
                                    :box (:line-width (-1 . -1) :style flat-button
                                                      ,@(and (featurep 'glitnir) '(:corner-radius 3))))
         (drgnx-replace-preview-add :inherit diff-added :extend nil
                                    :box (:line-width (-1 . -1) :style flat-button
                                                      ,@(and (featurep 'glitnir) '(:corner-radius 3))))
         ;; a 1 px ring all round: the row's height is its newline's `line-height'
         (drgnx-replace-sheet-selected :background ,(c 'sel)
                                       :box (:line-width (1 . 1) :color ,(c 'focus)
                                                         ,@(and (featurep 'glitnir) '(:corner-radius 6))))
         (diff-changed :background ,(c 'warn-tint))
         ;; the debugger's stopped line, a caller frame's and an exception's: bands to the window's edge (debugging.html)
         (drgnx-debug-stopped-line :background ,(c 'stop-band) :extend t)
         (drgnx-debug-frame-line :background ,(c 'ok-tint) :extend t)
         (drgnx-debug-exception-line :background ,(c 'error-tint) :extend t)
         ;; the overview ruler (debugging-extras.html): the shown lines a soft band, marks in their role colours
         (drgnx-ruler-view :inherit shadow :foreground ,(c 'hover))
         (drgnx-debug-ruler-breakpoint :inherit drgnx-debug-breakpoint :foreground ,(c 'error))
         (drgnx-debug-ruler-unverified :inherit drgnx-debug-unverified :foreground ,(c 'disabled))
         (drgnx-debug-ruler-stop :inherit drgnx-debug-stopped :foreground ,(c 'warn))
         ;; the exception card: the raised surface ringed in the error colour (`.exw')
         (drgnx-debug-exception-card :inherit (drgnx-ui-text drgnx-surface-raised) :background ,(c 'raised)
                                     :box (:line-width (-1 . -1) :color ,(c 'error)
                                                       ,@(and (featurep 'glitnir) '(:corner-radius 6))))
         ;; refined words: rounded in-text runs, as the region (boxes inside the glyphs)
         (diff-refine-added :background ,(c 'refine-add) :extend nil
                            :box (:line-width (-1 . -1) :color ,(c 'refine-add-edge)
                                              ,@(and (featurep 'glitnir) '(:corner-radius 3))))
         (diff-refine-removed :background ,(c 'refine-del) :extend nil
                              :box (:line-width (-1 . -1) :color ,(c 'refine-del-edge)
                                                ,@(and (featurep 'glitnir) '(:corner-radius 3))))
         (diff-refine-changed :background ,(c 'refine-chg) :extend nil
                              :box (:line-width (-1 . -1) :color ,(c 'refine-chg-edge)
                                                ,@(and (featurep 'glitnir) '(:corner-radius 3))))
         (diff-header :foreground ,(c 'muted) :background ,(c 'raised))
         (diff-file-header :foreground ,(c 'fg) :weight bold)
         (diff-hunk-header :foreground ,(c 'info))
         (diff-indicator-added :foreground ,(c 'add-fg))
         (diff-indicator-removed :foreground ,(c 'del-fg))
         (diff-context :foreground ,(c 'muted))
         (vc-up-to-date-state :foreground ,(c 'ok))
         (vc-edited-state :foreground ,(c 'warn))
         (vc-locally-added-state :foreground ,(c 'ok))
         (vc-conflict-state :foreground ,(c 'error))
         (vc-missing-state :foreground ,(c 'error))
         (vc-removed-state :foreground ,(c 'error))
         (vc-needs-update-state :foreground ,(c 'info))
         (vc-state-base :foreground ,(c 'muted)))
       ;; shell scripts: a here-document is a string, a command substitution runs a command (sh-script's own are
       ;; bold yellow and red)
       `((sh-heredoc :foreground ,(c 'str) :weight normal)
         (sh-quoted-exec :foreground ,(c 'fn)))
       ;; diagnostics and the language server
       `((flymake-error :underline (:style wave :color ,(c 'error)))
         (flymake-warning :underline (:style wave :color ,(c 'warn)))
         (flymake-note :underline (:style wave :color ,(c 'info)))
         (flymake-error-echo :foreground ,(c 'error))
         (flymake-warning-echo :foreground ,(c 'warn))
         (flymake-note-echo :foreground ,(c 'info))
         (flymake-end-of-line-diagnostics-face :foreground ,(c 'subtle))
         ;; a problem at the line's end is a chip of its kind (window-dark.html `.diag'): text-high, never growing
         ;; the line; high contrast rings it instead of the tint.  Emacs's own Flymake's faces and Flymake 1.4's (ELPA,
         ;; what drgnx installs), whose old names are only aliases
         ,@(cl-loop for (face . kind) in '((flymake-error-echo-at-eol . error) (flymake-warning-echo-at-eol . warn)
                                           (flymake-note-echo-at-eol . info) (flymake-error-inline . error)
                                           (flymake-warning-inline . warn) (flymake-note-inline . info))
                    collect `(,face :inherit drgnx-ui-caption :foreground ,(c kind)
                                    ,@(if hc '(:box (:line-width (-1 . -1)))
                                        `(:background ,(c (intern (format "%s-tint" kind)))
                                                      :box (:line-width (7 . -1) :style flat-button)))))
         (eglot-highlight-symbol-face :background ,(c 'hover) :weight bold)
         (eglot-mode-line :foreground ,(c 'accent))
         (eglot-inlay-hint-face :foreground ,(c 'subtle))
         (eglot-diagnostic-tag-unnecessary-face :foreground ,(c 'subtle))
         (eglot-diagnostic-tag-deprecated-face :strike-through t))
       ;; outlines: colour only, the height stays 1.0
       (cl-loop for face in '(outline-1 outline-2 outline-3 outline-4 outline-5 outline-6 outline-7 outline-8)
                for token in '(kw fn str ty const accent ok info)
                collect `(,face :foreground ,(c token) :height 1.0))
       ;; the terminal's sixteen colours
       (cl-loop for (name . token) in drgnx-theme--ansi
                append (list `(,(intern (format "ansi-color-%s" name)) :foreground ,(c token) :background ,(c token))
                             `(,(intern (format "ansi-color-bright-%s" name))
                               :foreground ,(drgnx-color-mix (c token) (c 'fg) 0.15)
                               :background ,(drgnx-color-mix (c token) (c 'fg) 0.15))))))))

(defun drgnx-theme--tty-token (tok)
  "TOK for a terminal: the gap and the panel are the editor's colour."
  (lambda (name) (funcall tok (if (memq name '(gap panel)) 'editor name))))

(defconst drgnx-theme--terminal-faces
  '((region :inverse-video t :extend t))
  "Faces drawn without a colour on a terminal frame: the selection's tint is too close to the editor's colour for a
terminal to tell apart (Emacs then blinks a copy, as for an unhighlighted region), so there it is inverse video.")

(defun drgnx-theme--specs (variant)
  "The arguments of `custom-theme-set-faces' for VARIANT: (FACE SPEC)…
A true-colour clause first, then one for every other display with the terminal tier; one clause when they agree.
A face of `drgnx-theme--terminal-faces' gets its terminal attributes in a first clause for every terminal."
  (let ((full (drgnx-theme--faces variant (lambda (name) (drgnx-look-token name variant))))
        (tty (drgnx-theme--faces variant (drgnx-theme--tty-token (lambda (name) (drgnx-look-token name variant))))))
    (cl-mapcar (lambda (f g)
                 (list (car f)
                       (append (when-let* ((term (cdr (assq (car f) drgnx-theme--terminal-faces))))
                                 `((((type tty)) ,@term)))
                               (if (equal f g)
                                   `((t ,@(cdr f)))
                                 `((((class color) (min-colors 16777216)) ,@(cdr f)) (t ,@(cdr g)))))))
               full tty)))

(defmacro drgnx-theme-define (name variant)
  "Define the theme NAME from the token table's VARIANT (`dark', `light' or `hc'), and provide it."
  `(progn
     (deftheme ,name ,(format "drgnx's %s theme, generated from themes/drgnx-tokens.eld." variant))
     (apply #'custom-theme-set-faces ',name (drgnx-theme--specs ',variant))
     (provide-theme ',name)))

(provide 'drgnx-theme-gen)
;;; drgnx-theme-gen.el ends here
