;;; drgnx-type-faces.el --- the look's type faces and their defaults -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The faces that carry the font roles of the look (docs/guide/look.md, "Fonts"): UI text, heading, caption, title,
;; small code, agent prose and the terminal.  Their `defface' specs hold drgnx's defaults, and `drgnx-type-defaults'
;; is the one table of those defaults, read by the font settings (modules/ui/drgnx-look-fonts.el) as their default
;; values.  A face spec holds `:family', `:height' (relative to the default face) and `:weight' only, never `:font'
;; (a font is tied to one display).  Sizes are ratios to the code size, so zooming scales every role together.
;; No colours here: these faces only choose letters.

;;; Code:

(defgroup drgnx-look nil "drgnx's look: colours, type, density and icons." :group 'drgnx)

(defconst drgnx-type-code-px 13.5
  "The code size in logical pixels.  One point is 4/3 of a logical pixel.")

(defconst drgnx-type-defaults
  '((code :family "JetBrains Mono" :fallback ("Adwaita Mono" "monospace") :size 1.0 :weight regular
          :line-height 21 :ligatures nil)
    (ui :family "Adwaita Sans" :fallback ("Inter" "sans-serif") :size 0.963 :weight regular)
    (ui-heading :family ui :size 0.963 :weight semibold)
    (ui-caption :family ui :size 0.889)
    (title :family ui :size 1.259 :weight semibold)
    (code-small :family code :size 0.889 :line-height 19)
    (agent :family ui)
    (terminal :family code))
  "The default value of each font role's setting: (ROLE . PLIST).  `:family' is a family name or `ui' or `code'
\(the same as that role); `:size' is a ratio to the code size; what a role leaves out it takes from the role its
family names, else from the next layer.")

(defface drgnx-ui-text '((t :family "Adwaita Sans" :height 0.963 :weight regular))
  "The user interface's text: tab bar, status bar, lists, palette candidates and notices."
  :group 'drgnx-look)

(defface drgnx-ui-heading '((t :family "Adwaita Sans" :height 0.963 :weight semibold))
  "Panel titles and section heads."
  :group 'drgnx-look)

(defface drgnx-ui-caption '((t :family "Adwaita Sans" :height 0.889 :weight regular))
  "The status bar, meta text and the tree's end column."
  :group 'drgnx-look)

(defface drgnx-ui-title '((t :family "Adwaita Sans" :height 1.259 :weight semibold))
  "The start page's and the reviews' headings."
  :group 'drgnx-look)

(defface drgnx-code-small '((t :family "JetBrains Mono" :height 0.889 :weight regular))
  "Diffs and output inside cards."
  :group 'drgnx-look)

(defface drgnx-agent-prose '((t :family "Adwaita Sans" :height 0.963 :weight regular))
  "The agent panel's prose."
  :group 'drgnx-look)

(defface drgnx-terminal '((t :family "JetBrains Mono" :weight regular))
  "The terminal's text."
  :group 'drgnx-look)

(provide 'drgnx-type-faces)
;;; drgnx-type-faces.el ends here
