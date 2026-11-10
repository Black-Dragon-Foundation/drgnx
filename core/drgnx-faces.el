;;; drgnx-faces.el --- Semantic faces: surfaces, text, lines, interaction, attention, agents -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The faces drgnx's chrome reads instead of colours.  A third-party theme that knows nothing of them gets the
;; defaults here, which inherit standard faces; drgnx's own themes (themes/) and `drgnx-look-derive' write the
;; colours.  No colour literal lives in this file.  `drgnx-look-hover-control' draws the hover-revealed × and ⋯ of a
;; row; `drgnx-face-color' reads a face's colour for a display that has no frame (batch, the lint).
;; See docs/guide/face.md ("Faces for theme authors").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-frame-kind)

(defgroup drgnx-look nil "The look: faces, fonts and chrome." :group 'drgnx :prefix "drgnx-")

;;;; Surfaces: no standard face, so `default' until derive or a theme writes them

(defface drgnx-surface-gap '((t :inherit default)) "The gap between cards, and the bars." :group 'drgnx-look)
(defface drgnx-surface-panel '((t :inherit default)) "A side panel's surface." :group 'drgnx-look)
(defface drgnx-surface-raised '((t :inherit default)) "A raised surface: chips, hovered rows, the current tab." :group 'drgnx-look)
(defface drgnx-surface-overlay '((t :inherit default)) "A popup's or palette's surface." :group 'drgnx-look)

;;;; Text

(defface drgnx-text-muted '((t :inherit shadow)) "Secondary text." :group 'drgnx-look)
(defface drgnx-text-subtle '((t :inherit shadow)) "Tertiary text: hints and counts." :group 'drgnx-look)
(defface drgnx-text-disabled '((t :inherit shadow)) "Text of something that cannot be used now." :group 'drgnx-look)

;;;; Lines

(defface drgnx-border '((t :inherit window-divider)) "A hairline: a card's edge, a divider." :group 'drgnx-look)
(defface drgnx-border-strong '((t :inherit vertical-border)) "A stronger line: an input's edge, a popup ring." :group 'drgnx-look)
(defface drgnx-border-subtle '((t :inherit drgnx-border))
  "A fainter hairline: under a tab row, under a pane's header." :group 'drgnx-look)

;;;; Interaction

(defface drgnx-accent '((t :inherit link :underline nil)) "The accent: the focus, links, the current thing." :group 'drgnx-look)
(defface drgnx-hover '((t :inherit highlight :box (:line-width (-2 . -2) :style flat-button)))
  "A hovered row.  Its box has the widths of `drgnx-focus', so a hovered focused row keeps the ring's box."
  :group 'drgnx-look)
(defface drgnx-selected '((t :inherit region)) "The selection." :group 'drgnx-look)
(defface drgnx-selected-quiet '((t :inherit drgnx-surface-raised)) "The selection in a pane that has not the focus."
  :group 'drgnx-look)
(defface drgnx-selected-inactive '((t :inherit drgnx-selected-quiet))
  "The selected row of a list whose window has not the focus (Explorer, Open, Outline), as VS Code's inactive
selection: at least 1.25:1 against the panel, above the hover."
  :group 'drgnx-look)
(defface drgnx-focus '((t :box (:line-width (-2 . -2)))) "The keyboard focus ring.  Themes and derive set its colour."
  :group 'drgnx-look)

;;;; Attention

(defface drgnx-status-attention '((t :inherit error)) "Something waits for you." :group 'drgnx-look)

;;;; Chips: a label on a tint (design §3.8); high contrast rings them in their own colour

(defface drgnx-chip-quiet '((t :inherit (drgnx-text-muted drgnx-selected-quiet)))
  "A quiet chip: the branch, a model, a count." :group 'drgnx-look)
(defface drgnx-chip-attention '((t :inherit (drgnx-status-attention drgnx-selected-quiet)))
  "A chip of what waits for you, on the attention tint." :group 'drgnx-look)
(defface drgnx-chip-accent '((t :inherit (drgnx-accent drgnx-selected-quiet)))
  "A chip in the accent, on its tint: the agents at work, a mode." :group 'drgnx-look)

;;;; Controls (design §3.5): a button and a keycap.  Their rings take colours, so the themes give them (a box's
;;;; colour is not inherited); here they are the standard faces' fill and a ring in the text colour.

(defface drgnx-control '((t :inherit secondary-selection :box (:line-width (1 . 1))))
  "A button: the quiet selection's fill in a 1 px hairline of the border colour, radius 6 where the compositor rounds."
  :group 'drgnx-look)
(defface drgnx-control-primary '((t :inherit region :box (:line-width (1 . 1))))
  "The primary button of a group: on-accent text on the accent's fill." :group 'drgnx-look)

;;;; Agents

(defface drgnx-agent-1 '((t :inherit default)) "The first agent's colour." :group 'drgnx-look)
(defface drgnx-agent-2 '((t :inherit default)) "The second agent's colour." :group 'drgnx-look)
(defface drgnx-agent-3 '((t :inherit default)) "The third agent's colour." :group 'drgnx-look)
(defface drgnx-agent-4 '((t :inherit default)) "The fourth agent's colour." :group 'drgnx-look)
(defface drgnx-agent-5 '((t :inherit default)) "The fifth agent's colour." :group 'drgnx-look)
(defface drgnx-agent-6 '((t :inherit default)) "The sixth agent's colour." :group 'drgnx-look)

;; Ring 2: a tonal variant of each of the six, derived at theme load (`drgnx-look-derive'); a slot the theme gives no
;; variant for is its ring-1 colour and is not in the display's ring.
(defface drgnx-agent-7 '((t :inherit drgnx-agent-1)) "The first agent colour's lighter or darker variant." :group 'drgnx-look)
(defface drgnx-agent-8 '((t :inherit drgnx-agent-2)) "The second agent colour's variant." :group 'drgnx-look)
(defface drgnx-agent-9 '((t :inherit drgnx-agent-3)) "The third agent colour's variant." :group 'drgnx-look)
(defface drgnx-agent-10 '((t :inherit drgnx-agent-4)) "The fourth agent colour's variant." :group 'drgnx-look)
(defface drgnx-agent-11 '((t :inherit drgnx-agent-5)) "The fifth agent colour's variant." :group 'drgnx-look)
(defface drgnx-agent-12 '((t :inherit drgnx-agent-6)) "The sixth agent colour's variant." :group 'drgnx-look)

;;;; The hover-revealed control

(defface drgnx-control-hidden '((t :inherit shadow))
  "A row's × or ⋯ while the row is not hovered.  Themes and derive give it the row's background as its foreground
\(derive only on a graphical display: a terminal never hides the control); a theme that does not leaves it dim but
visible."
  :group 'drgnx-look)
(defface drgnx-hover-row '((t :inherit (drgnx-hover default)))
  "The `mouse-face' of a row with a hidden control: the hover colour and the body foreground, which shows the control."
  :group 'drgnx-look)

(defun drgnx-look-hover-control (string &optional selected frame)
  "STRING as a row's control: hidden in `drgnx-control-hidden' on a graphical FRAME (default: the selected one), in
its real face when SELECTED is non-nil or FRAME is a terminal.  A caller that knows the row's frame passes it: a
terminal frame's controls stay shown when a graphical frame is selected.  The caller puts `mouse-face'
`drgnx-hover-row' on the whole row."
  (propertize string 'face (if (or selected (not (memq (drgnx-state-frame-kind (or frame (selected-frame))) '(gui child))))
                               'drgnx-ui-close
                             'drgnx-control-hidden)))

;;;; Reading a face's colour without a frame

(defvar drgnx-faces--reading-background nil
  "Non-nil while `drgnx-faces--background-mode' reads `default's background (a clause of it is not judged by it).")

(defun drgnx-faces--background-mode (kind)
  "`dark' or `light' for a `(background …)' clause on a KIND display, from no frame: `frame-background-mode' when you
set it, else how dark the enabled themes' `default' background is (as Emacs judges a frame's, `color-dark-p').  Only
when neither tells (no theme names a colour Emacs can read here) the selected frame's mode, as before."
  (or frame-background-mode
      (unless drgnx-faces--reading-background
        (let* ((drgnx-faces--reading-background t)
               (bg (drgnx-faces--attribute 'default :background kind 0))
               (v (and (stringp bg) (color-values-from-color-spec bg))))
          (and v (if (color-dark-p (mapcar (lambda (c) (/ c 65535.0)) v)) 'dark 'light))))
      (frame-parameter nil 'background-mode)))

(defun drgnx-faces--condition-p (condition kind)
  "Non-nil when the display CONDITION, (KEY VALUE…), holds on a KIND display (`gui': true colour, graphic;
`tty256': a 256-colour terminal).  A `(background …)' clause is judged by the themes, not the selected frame
\(`drgnx-faces--background-mode')."
  (let ((vals (cdr condition)))
    (pcase (car condition)
      ('class (memq 'color vals))
      ('type (if (eq kind 'gui) (cl-some (lambda (v) (not (eq v 'tty))) vals) (memq 'tty vals)))
      ('min-colors (<= (car vals) (if (eq kind 'gui) 16777216 256)))
      ('background (memq (drgnx-faces--background-mode kind) vals))
      (_ t))))

(defun drgnx-faces--clause-plist (face kind)
  "The attributes of the first clause of FACE's effective spec that holds on a KIND display.
The effective spec is the first enabled theme's that names FACE, else the defface's."
  (let ((spec (or (cl-some (lambda (theme) (cadr (assq theme (get face 'theme-face)))) custom-enabled-themes)
                  (get face 'face-defface-spec))))
    ;; a display of `t' or `default' (a standard face's fallback spec) holds on every display
    (when-let* ((clause (cl-find-if (lambda (c) (or (memq (car c) '(t default))
                                                    (cl-every (lambda (x) (drgnx-faces--condition-p x kind)) (car c))))
                                    spec)))
      (if (consp (cadr clause)) (cadr clause) (cdr clause)))))

(defun drgnx-faces--attribute (face attr kind depth)
  (when (and (symbolp face) face (< depth 8))
    (let* ((plist (drgnx-faces--clause-plist face kind))
           (v (plist-get plist attr)))
      (if (and v (not (memq v '(unspecified reset))))
          v
        (cl-some (lambda (parent) (drgnx-faces--attribute parent attr kind (1+ depth)))
                 (ensure-list (plist-get plist :inherit)))))))

(defun drgnx-face-color (face attr display)
  "FACE's ATTR (`:foreground' or `:background') as a colour string, or nil when nothing gives one.
Resolved through `:inherit' over the enabled themes' and the defface specs, for DISPLAY: a frame, the symbol `gui'
\(true colour, graphic) or `tty256'.  For the last two no frame is needed, so the lint and derive can ask in batch."
  (if (framep display)
      (let ((v (face-attribute face attr display t))) (and (stringp v) v))
    (let ((v (drgnx-faces--attribute face attr display 0))) (and (stringp v) v))))

(provide 'drgnx-faces)
;;; drgnx-faces.el ends here
