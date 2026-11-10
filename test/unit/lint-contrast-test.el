;;; lint-contrast-test.el --- lints: contrast of the look's themes, inheritance cycles -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure.  Themes are loaded alone and their realised specs read through `drgnx-face-color' (no frame, no
;; process, no timer); every theme the test loaded is disabled again.  A failure names the face pair and the ratio.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx)
(require 'drgnx-paths)
(require 'drgnx-color)
(require 'drgnx-faces)
(load (expand-file-name "modules/ui/drgnx-look-derive" drgnx-dir) nil t)
(add-to-list 'custom-theme-load-path (expand-file-name "test/fixtures/themes" drgnx-dir))

(defconst drgnx-lint-contrast--own '((drgnx-dark . dark) (drgnx-light . light) (drgnx-high-contrast . hc)))
(defconst drgnx-lint-contrast--other '(modus-operandi modus-vivendi leuven doom-one-fixture))

(defun drgnx-lint-contrast--bg (face) (drgnx-face-color face :background 'gui))
(defun drgnx-lint-contrast--fg (face) (drgnx-face-color face :foreground 'gui))

(defmacro drgnx-lint-contrast--with (theme derive &rest body)
  "Enable THEME alone (the derive run on when DERIVE), run BODY, and disable everything again."
  (declare (indent 2))
  `(unwind-protect
       (progn (mapc #'disable-theme custom-enabled-themes)
              (if (get ,theme 'theme-settings) (enable-theme ,theme) (load-theme ,theme t))
              (when ,derive (drgnx-look-derive-on))
              ,@body)
     (drgnx-look-derive-off)
     (mapc #'disable-theme custom-enabled-themes)))

(defun drgnx-lint-contrast--pairs (bar texts surfaces)
  "Failures of TEXTS (faces whose foreground is checked) on SURFACES (faces whose background is) against BAR."
  (let (fails)
    (dolist (text texts)
      (dolist (surface surfaces)
        (let* ((fg (drgnx-lint-contrast--fg text)) (bg (drgnx-lint-contrast--bg surface))
               (ratio (and fg bg (drgnx-color-contrast fg bg))))
          (unless (and ratio (>= ratio bar))
            (push (format "%s (%s) on %s (%s): %s, needs %s" text fg surface bg
                          (if ratio (format "%.2f" ratio) "no colour") bar)
                  fails)))))
    (nreverse fails)))

(defconst drgnx-lint-contrast--surfaces
  '(default hl-line drgnx-surface-gap drgnx-surface-panel drgnx-surface-raised drgnx-surface-overlay
            drgnx-selected drgnx-selected-quiet drgnx-hover)
  "Every surface body and muted text sit on (the selection is `drgnx-selected').")

(defconst drgnx-lint-contrast--syntax
  '(font-lock-keyword-face font-lock-builtin-face font-lock-function-name-face font-lock-function-call-face
                           font-lock-string-face font-lock-type-face font-lock-constant-face font-lock-number-face font-lock-escape-face
                           font-lock-comment-face font-lock-comment-delimiter-face font-lock-punctuation-face font-lock-bracket-face
                           font-lock-delimiter-face font-lock-operator-face font-lock-variable-use-face font-lock-property-use-face))

(defconst drgnx-lint-contrast--status
  '(drgnx-status-ok drgnx-status-warn drgnx-status-fail drgnx-status-info drgnx-status-attention))

(defconst drgnx-lint-contrast--agents
  '(drgnx-agent-1 drgnx-agent-2 drgnx-agent-3 drgnx-agent-4 drgnx-agent-5 drgnx-agent-6))

(defun drgnx-lint-contrast--own-failures (variant)
  "Every pair of the look's contrast bars that fails for the enabled drgnx theme of VARIANT."
  (let* ((hc (eq variant 'hc))
         (text (if hc 7.0 4.5))
         (off-selection (remq 'drgnx-selected drgnx-lint-contrast--surfaces))
         (fails nil))
    (cl-flet ((add (list) (setq fails (append fails list))))
      ;; body 7:1 on every surface; on the selection the high-contrast theme uses its own text colour
      (add (drgnx-lint-contrast--pairs 7.0 '(default) off-selection))
      (add (drgnx-lint-contrast--pairs 7.0 (if hc '(region) '(default)) '(drgnx-selected)))
      (add (drgnx-lint-contrast--pairs text '(drgnx-text-muted) drgnx-lint-contrast--surfaces))
      (add (drgnx-lint-contrast--pairs text '(drgnx-text-subtle)
                                       '(default hl-line drgnx-surface-panel drgnx-surface-raised
                                                 drgnx-surface-overlay)))
      (add (drgnx-lint-contrast--pairs text drgnx-lint-contrast--syntax '(default hl-line)))
      (add (drgnx-lint-contrast--pairs text drgnx-lint-contrast--status
                                       '(default drgnx-surface-panel drgnx-surface-raised)))
      (add (drgnx-lint-contrast--pairs text drgnx-lint-contrast--agents '(default drgnx-surface-raised)))
      ;; text over the tints: code under the selection and the matches keeps its colour and its bar; secondary text
      ;; on a selected row is `drgnx-selected-secondary' (subtle is under the bar there)
      (add (drgnx-lint-contrast--pairs text drgnx-lint-contrast--syntax '(region lazy-highlight isearch)))
      (add (drgnx-lint-contrast--pairs text '(drgnx-selected-secondary) '(drgnx-selected drgnx-selected-quiet)))
      ;; the focus ring is a control's only cue of focus: 3:1 on what it is drawn over
      (let* ((c (face-attribute 'drgnx-focus :box nil t)) (c (and (consp c) (plist-get c :color))))
        (dolist (surface '(default drgnx-surface-panel drgnx-surface-raised))
          (let ((ratio (and (stringp c) (drgnx-color-contrast c (drgnx-lint-contrast--bg surface)))))
            (unless (and ratio (>= ratio 3.0))
              (push (format "drgnx-focus ring (%s) on %s: %s, needs 3" c surface (and ratio (format "%.2f" ratio)))
                    fails)))))
      ;; a diff's text on its line's tint and on the refined words' stronger tint; code in a hunk keeps its
      ;; syntax colours there (`diff-font-lock-syntax')
      (add (drgnx-lint-contrast--pairs text '(diff-added) '(diff-added diff-refine-added)))
      (add (drgnx-lint-contrast--pairs text '(diff-removed) '(diff-removed diff-refine-removed)))
      (add (drgnx-lint-contrast--pairs text '(default) '(diff-changed diff-refine-changed)))
      (add (drgnx-lint-contrast--pairs text drgnx-lint-contrast--syntax
                                       '(diff-added diff-removed diff-refine-added diff-refine-removed)))
      ;; a non-current match's outline, where it has one of its own colour, shows inside a selection: 3:1 on it
      (let ((c (face-attribute 'lazy-highlight :box nil t)))
        (when-let* ((c (and (consp c) (plist-get c :color))) ((stringp c))
                    ((not (equal c (drgnx-lint-contrast--bg 'lazy-highlight))))
                    (ratio (drgnx-color-contrast c (drgnx-lint-contrast--bg 'region))))
          (unless (>= ratio 3.0)
            (push (format "lazy-highlight outline (%s) on region: %.2f, needs 3" c ratio) fails))))
      ;; the documented exceptions: status marks on the selection need 3:1 only; disabled text is exempt, except in
      ;; high contrast where it needs 4.5:1
      (add (drgnx-lint-contrast--pairs 3.0 drgnx-lint-contrast--status '(drgnx-selected)))
      (if hc
          (progn (add (drgnx-lint-contrast--pairs 4.5 '(drgnx-text-disabled) '(default)))
                 (dolist (border '(drgnx-border drgnx-border-strong))
                   (let ((ratio (drgnx-color-contrast (drgnx-lint-contrast--bg border) (drgnx-lint-contrast--bg 'default))))
                     (unless (>= ratio 3.0) (push (format "%s on default: %.2f, needs 3" border ratio) fails)))))
        ;; the card against the gap, and the border against the editor
        (let ((card (drgnx-color-contrast (drgnx-lint-contrast--bg 'drgnx-surface-panel)
                                          (drgnx-lint-contrast--bg 'drgnx-surface-gap)))
              (bar (if (eq variant 'light) 1.20 1.10))
              (edge (drgnx-color-contrast (drgnx-lint-contrast--bg 'drgnx-border) (drgnx-lint-contrast--bg 'default))))
          (unless (>= card bar) (push (format "drgnx-surface-panel on drgnx-surface-gap: %.2f, needs %s" card bar) fails))
          (unless (<= 1.3 edge 1.4) (push (format "drgnx-border on default: %.2f, needs 1.3 to 1.4" edge) fails)))))
    fails))

(ert-deftest drgnx-lint/contrast-own-themes ()
  "Pattern D: drgnx Dark, Light and High Contrast meet every pair of the look's contrast bars.  A failure lists every
failing pair of every theme, not the first theme's alone, one per line (a string: ERT shortens a long list)."
  (let (fails)
    (pcase-dolist (`(,theme . ,variant) drgnx-lint-contrast--own)
      (drgnx-lint-contrast--with theme nil
        (dolist (f (drgnx-lint-contrast--own-failures variant)) (push (format "%s: %s" theme f) fails))))
    (when fails
      (ert-fail (format "%d failing pairs:\n%s" (length fails) (string-join (nreverse fails) "\n"))))))

(ert-deftest drgnx-lint/contrast-third-party-themes ()
  "Pattern D: under modus-operandi, modus-vivendi, leuven and a Doom One stand-in, with derive run, subtle and muted text
reach 4.5:1 on the editor, the panel and raised surfaces, and the panel stands out from the gap by 1.20 (light) or 1.10
\(dark)."
  (dolist (theme drgnx-lint-contrast--other)
    (drgnx-lint-contrast--with theme t
      (let* ((black "#000000")
             (dark (< (drgnx-color-contrast (drgnx-lint-contrast--bg 'default) black)
                      (drgnx-color-contrast (drgnx-lint-contrast--fg 'default) black)))
             (bar (if dark 1.10 1.20))
             (card (drgnx-color-contrast (drgnx-lint-contrast--bg 'drgnx-surface-panel)
                                         (drgnx-lint-contrast--bg 'drgnx-surface-gap))))
        (should-not (when-let* ((fails (drgnx-lint-contrast--pairs
                                        4.5 '(drgnx-text-muted drgnx-text-subtle)
                                        '(default drgnx-surface-panel drgnx-surface-raised))))
                      (cons theme fails)))
        (should (>= card bar))))))

(defun drgnx-lint-contrast--cycle (face kind &optional path)
  "A list of faces ending in FACE's repeat when FACE's `:inherit' chain on a KIND display loops, else nil."
  (cond ((memq face path) (reverse (cons face path)))
        ((not (and face (symbolp face))) nil)
        (t (cl-some (lambda (parent) (drgnx-lint-contrast--cycle parent kind (cons face path)))
                    (ensure-list (plist-get (drgnx-faces--clause-plist face kind) :inherit))))))

(defun drgnx-lint-contrast--drgnx-faces ()
  (let (faces)
    (mapatoms (lambda (s) (when (and (facep s) (string-prefix-p "drgnx-" (symbol-name s))) (push s faces))))
    faces))

(ert-deftest drgnx-lint/contrast-agent-colours-one-to-twelve ()
  "Pattern D: with derive run, agents 1 to 6 of drgnx's themes reach 4.5:1 on the editor and raised surfaces (a third-party theme's own colours are not ours to lint) and the variants 7 to 12 reach
3:1 on the editor, under the three drgnx themes and the third-party ones."
  (dolist (theme (append (mapcar #'car drgnx-lint-contrast--own) drgnx-lint-contrast--other))
    (drgnx-lint-contrast--with theme t
      (should-not (when-let* ((fails (append
                                      (and (assq theme drgnx-lint-contrast--own)
                                           (drgnx-lint-contrast--pairs 4.5 drgnx-lint-contrast--agents
                                                                       '(default drgnx-surface-raised)))
                                      (drgnx-lint-contrast--pairs
                                       3.0 (mapcar (lambda (i) (intern (format "drgnx-agent-%d" i)))
                                                   '(7 8 9 10 11 12))
                                       '(default)))))
                    (cons theme fails))))))

(ert-deftest drgnx-lint/no-face-inheritance-cycles ()
  "Pattern D: every drgnx face's `:inherit' chain ends, on a graphical and a terminal display, under each of the
seven themes."
  (should (drgnx-lint-contrast--drgnx-faces))
  (dolist (theme (append (mapcar #'car drgnx-lint-contrast--own) drgnx-lint-contrast--other))
    (drgnx-lint-contrast--with theme t
      (dolist (kind '(gui tty256))
        (dolist (face (drgnx-lint-contrast--drgnx-faces))
          (should-not (when-let* ((loop (drgnx-lint-contrast--cycle face kind))) (list theme kind loop))))))))

(ert-deftest drgnx-lint/the-cycle-check-finds-a-cycle ()
  "Pattern D: the check is not vacuous: a planted loop is found, an ordinary chain is not."
  (unwind-protect
      (progn (put 'drgnx-lint-contrast-a 'face-defface-spec '((t :inherit drgnx-lint-contrast-b)))
             (put 'drgnx-lint-contrast-b 'face-defface-spec '((t :inherit (default drgnx-lint-contrast-a))))
             (should (equal '(drgnx-lint-contrast-a drgnx-lint-contrast-b drgnx-lint-contrast-a)
                            (drgnx-lint-contrast--cycle 'drgnx-lint-contrast-a 'gui)))
             (should-not (drgnx-lint-contrast--cycle 'drgnx-text-muted 'gui)))
    (put 'drgnx-lint-contrast-a 'face-defface-spec nil)
    (put 'drgnx-lint-contrast-b 'face-defface-spec nil)))

(provide 'lint-contrast-test)
;;; lint-contrast-test.el ends here
