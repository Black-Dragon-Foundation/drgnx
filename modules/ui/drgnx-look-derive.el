;;; drgnx-look-derive.el --- ui/look: surfaces, text and agent colours derived from any theme -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A theme that knows nothing of drgnx's semantic faces gets colours for the ones that have no standard face to
;; inherit: the surfaces (gap, panel, raised, overlay, the quiet selection), subtle and muted text, the focus ring and
;; accent, the hidden control and the agents.  `drgnx-look-derive' computes them from the theme's `default', `shadow',
;; `link', `cursor' and `font-lock-*' faces by solving for the contrast bars (core/drgnx-color.el), reading the
;; theme's specs for a graphical display and for a 256-colour terminal (never the selected frame's colours, which in a
;; daemon are often a terminal's `unspecified-bg').  A face some enabled theme or a Customize entry sets is left
;; alone.  The result is written as the face's defface spec, with a `(type tty)' clause when the terminal differs; the
;; original spec of every face derive wrote is recorded once, and `drgnx-look-derive-off' puts it back.  A colour the
;; theme leaves unspecified never signals: derive falls back to the theme's `default' colours, or leaves the face, and
;; `drgnx-look-derive-gaps' says which.  See docs/guide/look.md ("Under another theme").

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-color)
(require 'drgnx-faces)
(unless (featurep 'drgnx-theme-gen)
  (load (expand-file-name "themes/drgnx-theme-gen" drgnx-dir) nil t))

(declare-function drgnx-look-token "drgnx-theme-gen" (name &optional variant))

(defconst drgnx-look-derive--faces
  '(drgnx-surface-panel drgnx-surface-gap drgnx-surface-raised drgnx-surface-overlay drgnx-selected-quiet
                        drgnx-text-muted drgnx-text-subtle drgnx-focus drgnx-accent drgnx-control-hidden
                        drgnx-agent-1 drgnx-agent-2 drgnx-agent-3 drgnx-agent-4 drgnx-agent-5 drgnx-agent-6)
  "The semantic faces derive writes.")

(defconst drgnx-look-derive--agent-sources
  '(font-lock-function-name-face font-lock-keyword-face font-lock-string-face font-lock-type-face
                                 font-lock-constant-face font-lock-builtin-face)
  "The faces whose foregrounds become agents 1 to 6, in that order.")

(defvar drgnx-look-derive--saved nil
  "((FACE . SPEC)...): the defface spec of each face derive has written, as it was before the first write.")

(defvar drgnx-look-derive-gaps nil
  "((FACE . REASON)...) from the last run: faces derive could not derive, or derived from `default' alone.")

;;;; Reading the theme

(defun drgnx-look-derive--colour (face attr kind)
  "FACE's ATTR on a KIND display (`gui' or `tty256') as \"#rrggbb\", or nil when the theme gives none."
  (when-let* ((rgb (drgnx-color-rgb (drgnx-face-color face attr kind))))
    (drgnx-color-hex rgb)))

(defun drgnx-look-derive--achromatic-p (colour)
  (pcase-let ((`(,_ ,a ,b) (drgnx-color--to-oklab (drgnx-color-rgb colour))))
    (< (sqrt (+ (* a a) (* b b))) 0.02)))

(defun drgnx-look-derive--apart-p (a b)
  "Non-nil when colours A and B are 15 delta E apart, and 30 degrees of hue (a grey has no hue to compare)."
  (and (>= (drgnx-color-delta-e a b) 15.0)
       (or (drgnx-look-derive--achromatic-p a) (drgnx-look-derive--achromatic-p b)
           (>= (drgnx-color-hue-distance a b) 30.0))))

(defun drgnx-look-derive--agents (kind dark)
  "((drgnx-agent-N :foreground COLOUR)...) for KIND: the font-lock foregrounds that stand apart, else the tokens."
  (let ((kept (when-let* ((c (drgnx-look-derive--colour 'cursor :background kind))) (list c)))
        (i 0) out)
    (dolist (face drgnx-look-derive--agent-sources)
      (cl-incf i)
      (let ((c (drgnx-look-derive--colour face :foreground kind)))
        (push (list (intern (format "drgnx-agent-%d" i)) :foreground
                    (if (and c (cl-every (lambda (o) (drgnx-look-derive--apart-p c o)) kept))
                        (progn (push c kept) c)
                      (drgnx-look-token (intern (format "a%d" i)) (if dark 'dark 'light))))
              out)))
    (nreverse out)))

(defun drgnx-look-derive--values (kind)
  "((FACE . ATTRIBUTES)...) computed from the theme for a KIND display, or nil when `default' gives no colours."
  (let ((e (drgnx-look-derive--colour 'default :background kind))
        (f (drgnx-look-derive--colour 'default :foreground kind)))
    (when (and e f)
      (let* ((black (drgnx-color-hex drgnx-color-black))
             (dark (< (drgnx-color-contrast e black) (drgnx-color-contrast f black)))
             (bar (if dark 1.10 1.20))
             (panel (drgnx-color-mix e f 0.03 'srgb))
             ;; dark: the gap goes toward black, light: toward the text colour, until panel / gap meets the bar
             (gap (drgnx-color-solve e (if dark black f) panel bar 'srgb))
             ;; a gap that cannot get darker (E is black) leaves the panel to move on toward F
             (panel (drgnx-color-solve panel f gap bar 'srgb))
             (raised (drgnx-color-mix panel f 0.03 'srgb))
             (shadow (drgnx-look-derive--colour 'shadow :foreground kind))
             (link (drgnx-look-derive--colour 'link :foreground kind))
             (text (let ((c (or shadow f)))
                     (dolist (surface (list e panel raised) c)
                       (setq c (or (drgnx-color-solve c f surface 4.5) c))))))
        (unless shadow (push (cons 'drgnx-text-muted "no `shadow' colour: derived from `default'") drgnx-look-derive-gaps))
        (unless link (push (cons 'drgnx-accent "no `link' colour: the body text's") drgnx-look-derive-gaps))
        `((drgnx-surface-panel :background ,panel) (drgnx-surface-gap :background ,gap)
          (drgnx-surface-raised :background ,raised) (drgnx-surface-overlay :background ,raised)
          (drgnx-selected-quiet :background ,raised)
          (drgnx-text-muted :foreground ,text) (drgnx-text-subtle :foreground ,text)
          (drgnx-focus :box (:line-width (-2 . -2) :color ,(or link f)))
          (drgnx-accent :foreground ,(or link f) :underline nil)
          ;; a terminal never hides a row's control (`drgnx-look-hover-control'): there it stays dim, not invisible
          (drgnx-control-hidden ,@(if (eq kind 'gui) `(:foreground ,panel) '(:inherit shadow)))
          ,@(drgnx-look-derive--agents kind dark))))))

(defun drgnx-look-derive--mentioned-p (face)
  "Non-nil when an enabled theme, or a Customize entry (the `user' theme), sets FACE."
  (cl-some (lambda (entry) (or (eq (car entry) 'user) (custom-theme-enabled-p (car entry))))
           (get face 'theme-face)))

(defun drgnx-look-derive--spec (gui tty)
  "The defface spec for a face whose graphical attributes are GUI and terminal ones TTY (either may be nil)."
  (if (and gui tty (not (equal gui tty)))
      `((((type tty)) ,@tty) (t ,@gui))
    `((t ,@(or gui tty)))))

(defun drgnx-look-derive--put (face spec)
  "Make SPEC FACE's defface spec, recording the original the first time."
  (unless (assq face drgnx-look-derive--saved)
    (push (cons face (get face 'face-defface-spec)) drgnx-look-derive--saved))
  (unless (equal spec (get face 'face-defface-spec))
    (face-spec-set face spec 'face-defface-spec)))

(defun drgnx-look-derive--restore (face)
  "Give FACE the defface spec it had before derive wrote one, when it wrote one."
  (when-let* ((saved (assq face drgnx-look-derive--saved)))
    (setq drgnx-look-derive--saved (delq saved drgnx-look-derive--saved))
    (face-spec-set face (cdr saved) 'face-defface-spec)))

;;;; The run

(defun drgnx-look-derive ()
  "Derive the panel, text and agent colours of the semantic faces no enabled theme sets, from the theme's own.
A run that finds nothing to derive changes nothing, and nothing here signals on a colour the theme leaves unspecified."
  (setq drgnx-look-derive-gaps nil)
  (let ((gui (drgnx-look-derive--values 'gui))
        (tty (drgnx-look-derive--values 'tty256)))
    (dolist (face drgnx-look-derive--faces)
      (let ((g (cdr (assq face gui))) (ty (cdr (assq face tty))))
        (cond ((drgnx-look-derive--mentioned-p face) (drgnx-look-derive--restore face))
              ((not (or g ty))
               (push (cons face "the theme's `default' gives no colours") drgnx-look-derive-gaps)
               (drgnx-look-derive--restore face))
              (t (drgnx-look-derive--put face (drgnx-look-derive--spec g ty)))))))
  (setq drgnx-look-derive-gaps (delete-dups drgnx-look-derive-gaps)))

(defun drgnx-look-accent-text (rgb variant)
  "The portal's accent RGB, (R G B) floats in 0..1, as text for VARIANT (`dark', `light' or `hc'): lighter on dark,
darker on light, as libadwaita does, then moved until it reaches its bar on the variant's `editor': 4.5:1, and 7:1
in High Contrast (every text pair there is 7:1)."
  (let* ((dark (memq variant '(dark hc)))
         (toward (drgnx-color-hex (if dark drgnx-color-white drgnx-color-black))))
    (drgnx-color-solve (drgnx-color-mix (drgnx-color-hex rgb) toward (if dark 0.25 0.15))
                       toward (drgnx-look-token 'editor variant) (if (eq variant 'hc) 7.0 4.5))))

;;;; On and off

(defun drgnx-look-derive--on-theme (&rest _)
  "`enable-theme-functions' and `disable-theme-functions': derive again."
  (drgnx-look-derive))

(defun drgnx-look-derive--on-frame ()
  "`server-after-make-frame-hook': a graphical frame may be the first of its display; derive again."
  (drgnx-look-derive))

(defun drgnx-look-derive-on ()
  "Derive now, and again whenever a theme is enabled or disabled or a frame is made by the server."
  (add-hook 'enable-theme-functions #'drgnx-look-derive--on-theme)
  (add-hook 'disable-theme-functions #'drgnx-look-derive--on-theme)
  (add-hook 'server-after-make-frame-hook #'drgnx-look-derive--on-frame)
  (drgnx-look-derive))

(defun drgnx-look-derive-off ()
  "Undo `drgnx-look-derive-on': the hooks off, every derived face back to its defface spec."
  (remove-hook 'enable-theme-functions #'drgnx-look-derive--on-theme)
  (remove-hook 'disable-theme-functions #'drgnx-look-derive--on-theme)
  (remove-hook 'server-after-make-frame-hook #'drgnx-look-derive--on-frame)
  (dolist (saved (copy-sequence drgnx-look-derive--saved))
    (drgnx-look-derive--restore (car saved)))
  (setq drgnx-look-derive-gaps nil))

(provide 'drgnx-look-derive)
;;; drgnx-look-derive.el ends here
