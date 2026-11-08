;;; themes-test.el --- batch tests: drgnx's three themes and their token table -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure; themes are loaded and read back as face specs, no frame, process or timer is involved.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-color)
(require 'drgnx-faces)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-dir) nil t)

(defconst drgnx-themes-test--themes
  '((dark . drgnx-dark) (light . drgnx-light) (hc . drgnx-high-contrast)))

(defconst drgnx-themes-test--designs
  ;; design section 3.4, as the table prints them (after the review's stronger subtle and comment)
  '((dark (gap . "#0a0b0d") (editor . "#15161a") (panel . "#18191e") (sel . "#243150") (fg . "#e4e5ea")
          (muted . "#a2a5b2") (subtle . "#878b98") (comment . "#858996") (accent . "#7aa5ff") (focus . "#7aa5ff")
          (attention . "#ff9566"))
    (light (gap . "#dfe0e6") (editor . "#ffffff") (panel . "#f6f6f8") (sel . "#dbe5fb") (fg . "#1c1e23")
           (muted . "#545866") (subtle . "#656977") (comment . "#686c7a") (accent . "#2c5fd4") (focus . "#2c5fd4")
           (attention . "#b8461a"))
    (hc (gap . "#000000") (editor . "#000000") (panel . "#000000") (sel . "#1f3a7a") (fg . "#ffffff")
        (muted . "#d6d8de") (subtle . "#bfc2ca") (comment . "#bfc2ca") (accent . "#a8c6ff") (focus . "#ffd36b")
        (attention . "#ffb38a") (sel-fg . "#ffffff"))))

(defconst drgnx-themes-test--faces
  '(drgnx-surface-gap drgnx-surface-panel drgnx-surface-raised drgnx-surface-overlay
                      drgnx-text-muted drgnx-text-subtle drgnx-text-disabled drgnx-border drgnx-border-strong
                      drgnx-accent drgnx-hover drgnx-selected drgnx-selected-quiet drgnx-focus drgnx-status-attention
                      drgnx-agent-1 drgnx-agent-2 drgnx-agent-3 drgnx-agent-4 drgnx-agent-5 drgnx-agent-6 drgnx-control-hidden
                      default cursor region highlight hl-line fringe line-number line-number-current-line shadow link
                      error warning success
                      font-lock-keyword-face font-lock-function-name-face font-lock-function-call-face font-lock-string-face
                      font-lock-type-face font-lock-constant-face font-lock-number-face font-lock-escape-face
                      font-lock-comment-face font-lock-comment-delimiter-face font-lock-punctuation-face font-lock-bracket-face
                      font-lock-delimiter-face font-lock-operator-face font-lock-variable-use-face font-lock-property-use-face
                      mode-line mode-line-active mode-line-inactive header-line tab-bar tab-bar-tab tab-bar-tab-inactive
                      tab-line tab-line-tab tab-line-tab-current tab-line-tab-inactive
                      window-divider window-divider-first-pixel window-divider-last-pixel vertical-border internal-border
                      child-frame-border child-frame-shadow tooltip minibuffer-prompt isearch lazy-highlight match
                      show-paren-match show-paren-mismatch completions-common-part completions-first-difference
                      diff-added diff-removed diff-changed diff-refine-added diff-refine-removed diff-refine-changed
                      vc-up-to-date-state vc-edited-state vc-conflict-state flymake-error flymake-warning flymake-note
                      eglot-highlight-symbol-face outline-1 outline-2 outline-3 outline-4 outline-5 outline-6 outline-7 outline-8
                      ansi-color-red ansi-color-green ansi-color-yellow ansi-color-blue ansi-color-magenta ansi-color-cyan
                      ansi-color-black ansi-color-white ansi-color-bright-red ansi-color-bright-green ansi-color-bright-blue
                      nidhogg-title-bar nidhogg-title-bar-inactive))

(defun drgnx-themes-test--only (theme)
  "Load THEME alone."
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme theme t))

(defmacro drgnx-themes-test--with (theme &rest body)
  (declare (indent 1))
  `(unwind-protect (progn (drgnx-themes-test--only ,theme) ,@body)
     (mapc #'disable-theme custom-enabled-themes)))

(ert-deftest drgnx-themes/tokens-are-the-designs ()
  (pcase-dolist (`(,variant . ,tokens) drgnx-themes-test--designs)
    (pcase-dolist (`(,name . ,hex) tokens)
      (should (equal hex (drgnx-look-token name variant))))))

(ert-deftest drgnx-themes/tints-composite-over-the-editor ()
  (should (equal (drgnx-color-over "#62d394" "#15161a" 0.12) (drgnx-look-token 'ok-tint 'dark)))
  (should (equal (drgnx-color-over "#c48c00" "#ffffff" 0.14) (drgnx-look-token 'warn-tint 'light)))
  (should (equal "#000000" (drgnx-look-token 'ok-tint 'hc))))     ; high contrast has no tints

(ert-deftest drgnx-themes/three-themes-load-and-unload ()
  (pcase-dolist (`(,_ . ,theme) drgnx-themes-test--themes)
    (drgnx-themes-test--with theme
      (should (memq theme custom-enabled-themes))
      (dolist (face drgnx-themes-test--faces)
        (unless (and (eq theme 'drgnx-high-contrast) (eq face 'child-frame-shadow)) ; no shadows in high contrast
          (should (assq theme (get face 'theme-face))))))
    (should-not (memq theme custom-enabled-themes))))

(ert-deftest drgnx-themes/tty-tier-collapses-surfaces ()
  (drgnx-themes-test--with 'drgnx-dark
    (let ((editor (drgnx-face-color 'default :background 'tty256)))
      (should editor)
      (should (equal editor (drgnx-face-color 'drgnx-surface-panel :background 'tty256)))
      (should (equal editor (drgnx-face-color 'drgnx-surface-gap :background 'tty256)))
      (should-not (equal editor (drgnx-face-color 'drgnx-surface-gap :background 'gui)))
      (should (equal (drgnx-look-token 'gap 'dark) (drgnx-face-color 'drgnx-surface-gap :background 'gui))))))

(ert-deftest drgnx-themes/hc-selection-takes-sel-fg ()
  (drgnx-themes-test--with 'drgnx-high-contrast
    (should (equal "#ffffff" (drgnx-face-color 'region :foreground 'gui)))
    (should (equal (drgnx-look-token 'sel 'hc) (drgnx-face-color 'region :background 'gui))))
  (drgnx-themes-test--with 'drgnx-dark
    (should-not (drgnx-face-color 'region :foreground 'gui))))

(ert-deftest drgnx-themes/outline-heights-are-1 ()
  (drgnx-themes-test--with 'drgnx-dark
    (dotimes (i 8)
      (should (eql 1.0 (plist-get (drgnx-faces--clause-plist (intern (format "outline-%d" (1+ i))) 'gui) :height))))))

(ert-deftest drgnx-themes/chrome-text-is-in-the-ui-font ()
  "Design §3.1, 'Where the UI font goes': the tab bar, the tab lines, header lines and the status bar take the UI
roles (the status bar the caption), in every theme, the tabs' own faces included (a theme spec replaces the
defface's `:inherit')."
  (pcase-dolist (`(,_ . ,theme) drgnx-themes-test--themes)
    (drgnx-themes-test--with theme
      (pcase-dolist (`(,role . ,faces)
                     '((drgnx-ui-text tab-bar tab-bar-tab tab-bar-tab-inactive tab-line tab-line-tab
                                      tab-line-tab-current tab-line-tab-inactive tab-line-tab-special header-line)
                       (drgnx-ui-caption mode-line mode-line-active mode-line-inactive drgnx-keycap)))
        (dolist (face faces)
          (should (equal (list face role)
                         (list face (let ((i (plist-get (drgnx-faces--clause-plist face 'gui) :inherit)))
                                      (if (consp i) (car i) i))))))))))

(ert-deftest drgnx-themes/header-lines-are-on-the-editor ()
  "A header line belongs to its card (the breadcrumb under the tabs, a package's own header): the editor's colour."
  (pcase-dolist (`(,variant . ,theme) drgnx-themes-test--themes)
    (drgnx-themes-test--with theme
      (should (equal (drgnx-look-token 'editor variant) (drgnx-face-color 'header-line :background 'gui))))))

(ert-deftest drgnx-themes/title-row-and-chips ()
  "Design §4 \"The window frame\": the title row (the tab bar) is on the gap; the chips are on their tints, and in
high contrast, where tints are black, they are ringed in their own colour."
  (pcase-dolist (`(,variant . ,theme) drgnx-themes-test--themes)
    (drgnx-themes-test--with theme
      (should (equal (drgnx-look-token 'gap variant) (drgnx-face-color 'tab-bar :background 'gui)))
      (pcase-dolist (`(,face ,fg ,bg) '((drgnx-chip-quiet muted sel-quiet) (drgnx-chip-attention attention attention-tint)
                                        (drgnx-chip-accent accent accent-tint)))
        (should (equal (list face (drgnx-look-token fg variant) (drgnx-look-token bg variant))
                       (list face (drgnx-face-color face :foreground 'gui) (drgnx-face-color face :background 'gui))))
        (should (eq (eq variant 'hc) (and (plist-get (drgnx-faces--clause-plist face 'gui) :box) t)))))))

;; Design §3.5: a button is a quiet fill in a 1 px hairline (radius 6), the primary one the accent's fill; a keycap is
;; subtle text in a strong hairline (radius 4)
(ert-deftest drgnx-themes/buttons-and-keycaps ()
  "Design §3.5 (`.btn', `.btn.pri', `kbd'): `drgnx-control' is the text colour on the quiet selection, ringed 1 px in
the border colour; `drgnx-control-primary' is on-accent text on the accent's fill; `drgnx-keycap' is subtle text
ringed in the strong border, with no fill of its own."
  (pcase-dolist (`(,variant . ,theme) drgnx-themes-test--themes)
    (drgnx-themes-test--with theme
      (pcase-dolist (`(,face ,fg ,bg ,ring) '((drgnx-control fg sel-quiet border)
                                              (drgnx-control-primary on-accent accent-fill accent-fill)
                                              (drgnx-keycap subtle nil border-strong)))
        (let ((box (plist-get (drgnx-faces--clause-plist face 'gui) :box)))
          (should (equal (list face (drgnx-look-token fg variant) (and bg (drgnx-look-token bg variant))
                               (drgnx-look-token ring variant) '(1 . 1))
                         (list face (drgnx-face-color face :foreground 'gui) (drgnx-face-color face :background 'gui)
                               (plist-get box :color) (plist-get box :line-width)))))))))

(ert-deftest drgnx-themes/variant-follows-the-theme ()
  (pcase-dolist (`(,variant . ,theme) drgnx-themes-test--themes)
    (drgnx-themes-test--with theme (should (eq variant (drgnx-look-variant)))))
  (mapc #'disable-theme custom-enabled-themes)
  (should (eq 'dark (drgnx-look-variant))))

(provide 'themes-test)
;;; themes-test.el ends here
