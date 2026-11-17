;;; components.eld --- the UI kit's components: one definition, two renderers  -*- mode: lisp-data -*-
;; The one definition of drgnx's components.  The hub expands it in Rust (drgnx-rows, from generated tables) and
;; core/drgnx-ui-kit.el in Lisp, for Lisp-drawn chrome only; a conformance test keeps the two equal.  See
;; docs/develop/core.md ("The UI kit") and docs/develop/design-system.md.
;;
;; ((state-table . STATES) (components . ENTRIES))
;;
;; STATES: (STATE . PLIST), in order: :fill a token (the state's fill), :radius logical px, :ring (TOKEN . PX) an inset
;; ring, :fg a token (the text), :face the semantic face that draws it, :tty its terminal form (`none', `inverse',
;; `underline', `dim').  Rows have no box edges in hover or selection.
;;
;; ENTRY: (ID :variants ((AXIS VALUE...)...) :defaults (AXIS VALUE...) :geometry GEOM :tty TTY :label LABEL
;;         :bind BINDINGS :replaces ((OLD-FACE . KIT-FACE)...) :helpers (OLD-FN...) :lint BOOL)
;;   GEOM, all logical px: :height :pad (START . END) :gap :box :radius :line-height :hit (action-carrying padding each
;;   side) :indent.  A value may be (:by AXIS (VALUE X)...) where variants differ, or (density KEY): the size
;;   `drgnx-look-density-value' gives KEY at the user's density.
;;   TTY: :glyph GLYPH-NAME (of `drgnx-face-glyphs'), :twisty (CLOSED OPEN) glyph names, :glyphs (NAME...) the other
;;   glyphs the component draws, :pad CHARS, :indent CHARS a level (tree rows); :indent may be a (:by AXIS ...) case.
;;   LABEL: the word a screen reader speaks, a string or (:by AXIS (VALUE "word")...).
;;   BINDINGS: (((VARIANT-VALUE...) :bg TOKEN :fg TOKEN :edge TOKEN :inherit (STANDARD-FACE...) :font (FACE...)
;;   :inverse BOOL)...); :font names the inherited faces that carry no colours (the UI or code font): a drgnx theme's
;;   spec keeps only those; the binding of () is the component's own face `drgnx-kit-ID', another one
;;   `drgnx-kit-ID-VALUE...', made only where its colours differ from the component's own.  A binding may name a part
;;   instead of variant values (the progress bar's `fill').  :inverse swaps the colours of the faces drawn with it (an
;;   agent mark: its agent's colour as the fill).
;;   :hc-ring t: in the high-contrast theme the face has no tint, a 1 px ring in its :fg colour instead.
((state-table
  (rest)
  (hover :fill hover :face drgnx-hover :tty none)
  (pressed :fill sel-quiet :face drgnx-selected-quiet)
  (selected :fill sel :radius 6 :face drgnx-selected :tty inverse)
  (selected-inactive :fill sel-inactive :radius 6 :face drgnx-selected-inactive :tty underline)
  (focus-visible :ring (focus . 2) :face drgnx-focus :tty inverse)
  (disabled :fg disabled :face drgnx-text-disabled :tty dim))
 (components
  ;; a row of a list, a tree (depth and twisty) or a map; its states are the state table's
  (row :variants ((kind list tree map)) :defaults (kind list)
       :geometry (:height (density tree-row) :pad (6 . 6) :gap 6 :box nil :radius 6 :hit 0
                          :indent (:by kind (list 0) (tree (density tree-indent)) (map 0)))
       :tty (:pad 1 :indent (:by kind (list 0) (tree 2) (map 0)) :twisty (chevron-right chevron-down))
       :label nil
       ;; the UI font (the mockups' lists and trees), no colours of its own: the surface's and the state's
       :bind ((() :inherit (drgnx-ui-text)))
       ;; every row selection reads the state table (the inactive selection, the full one while focused)
       :replaces ((drgnx-view-selected . drgnx-row-selected) (drgnx-explorer-selected . drgnx-row-selected)
                  (drgnx-work-selected . drgnx-row-selected) (drgnx-notebook-current-row . drgnx-row-selected))
       :helpers nil :lint t)
  ;; a button: a label in a rounded box (the 1 px ring is inside the padding), its key hint after the label; 26 px, 22 small
  (button :variants ((style primary secondary quiet danger) (size md sm)) :defaults (style secondary size md)
          :geometry (:height (:by size (md 26) (sm 22)) :pad (:by size (md (12 . 12)) (sm (8 . 8))) :gap 6 :box t :radius 6 :hit 4)
          :tty (:pad 1) :label nil
          :bind (((primary) :bg button-primary-bg :fg button-primary-fg :inherit (drgnx-control-primary) :font (drgnx-ui-text))
                 ((secondary) :bg sel-quiet :edge button-edge :inherit (drgnx-control) :font (drgnx-ui-text))
                 ((quiet) :inherit (drgnx-ui-text drgnx-text-muted))
                 ((danger) :bg error-tint :fg error :inherit (drgnx-chip-error) :font (drgnx-ui-text)))
          :replaces ((drgnx-ui-button . drgnx-kit-button-secondary) (drgnx-ui-button-primary . drgnx-kit-button-primary)
                     (drgnx-button . drgnx-kit-button-secondary) (drgnx-work-flow-button . drgnx-kit-button-secondary)
                     (drgnx-work-flow-button-primary . drgnx-kit-button-primary))
          :helpers nil :lint t)
  ;; a key hint: the keys in the code font in a 4 px box; `menu' is the text alone (a menu's shortcut column)
  (key-hint :variants ((variant cap menu)) :defaults (variant cap)
            :geometry (:height 0 :pad (:by variant (cap (5 . 5)) (menu (0 . 0))) :gap 0 :box (:by variant (cap t) (menu nil)) :radius 4)
            :tty (:pad 0) :label "key"
            :bind (((cap) :edge key-hint-edge :inherit (drgnx-code-small drgnx-control) :font (drgnx-code-small))
                   ((menu) :inherit (drgnx-code-small drgnx-text-subtle)))
            :replaces ((drgnx-keycap . drgnx-kit-key-hint-cap) (drgnx-work-flow-button-key . drgnx-kit-key-hint-cap)
                       (drgnx-work-flow-key-primary . drgnx-kit-key-hint-cap))
            :helpers nil :lint t)
  ;; an agent's mark: its handle (one or two letters) on its colour (the colour's face `drgnx-agent-N' drawn
  ;; inverse), about 18 px square (the caption's line, 5 px each side of a letter), radius 4 where Glitnir rounds; a
  ;; terminal draws [H] in the colour.  Inline: no line height of its own
  (agent-mark :variants nil :defaults nil
              :geometry (:height 0 :pad (5 . 5) :gap 0 :box nil :radius 4 :hit 0)
              :tty (:pad 0) :label "agent"
              :bind ((() :inherit (drgnx-ui-caption) :inverse t))
              :replaces nil :helpers nil :lint t)
  ;; progress: a bar (4 px tall, `drgnx-ui-kit-progress-bar-px', on the caption's centre line: the fill, rounded at
  ;; its start, then the track, rounded at its end; each an SVG in `currentColor', so its face's text colour, as the
  ;; icons are) or a ring (one of five glyphs); its word is "N percent".  A terminal draws the bar as a cell per 8 px
  ;; of its width (`drgnx-ui-kit-progress-cell-px'): the filled cells `bar-full' and a partial block (`bar-1'..`bar-7',
  ;; eighths) in the fill's colour, the rest `bar-empty' in the track's; ASCII adds edges (`bar-left', `bar-right').
  ;; A meter (kind `meter', the hub's `{"c": "meter"}') is a bar against a limit, its text and state word beside it
  ;; (docs/design/components/chips-and-keys.md, "Meters"): the fill in its state's colour (`meter-fill', `meter-near',
  ;; `meter-reached'), the forecast's p50 a tick (`meter-tick', `meter-tick-near' when p90 is over; its slot's other
  ;; half the track's colour, from the binding's background), on a `wide' meter a span to p90 (`meter-span'), an
  ;; inherited limit's track an outline (`meter-outline'); high contrast outlines the span and widens the tick
  (progress :variants ((kind bar ring meter)) :defaults (kind bar)
            :geometry (:height 0 :pad (0 . 0) :gap 0 :box nil
                               :radius (:by kind (bar 2) (ring 0)) :hit 0)
            :tty (:pad 0 :glyphs (bar-left bar-full bar-1 bar-2 bar-3 bar-4 bar-5 bar-6 bar-7 bar-empty bar-right
                                           progress-0 progress-1 progress-2 progress-3 progress-4))
            :label "percent"
            ;; text colours only (the bar's images and glyphs are drawn in them; the ring is in the fill's face); under
            ;; a theme that knows nothing of drgnx: the track the shadow's colour, the fill a link's
            :bind ((() :fg progress-track :inherit (drgnx-ui-caption shadow) :font (drgnx-ui-caption))
                   ((fill) :fg progress-fill :inherit (drgnx-ui-caption link) :font (drgnx-ui-caption))
                   ((meter-fill) :fg meter-fill :inherit (drgnx-ui-caption link) :font (drgnx-ui-caption))
                   ((meter-near) :fg meter-near :inherit (drgnx-ui-caption warning error)
                    :font (drgnx-ui-caption))
                   ((meter-reached) :fg meter-reached :inherit (drgnx-ui-caption error) :font (drgnx-ui-caption))
                   ((meter-tick) :fg meter-tick :bg progress-track
                    :inherit (drgnx-ui-caption shadow secondary-selection) :font (drgnx-ui-caption))
                   ((meter-tick-near) :fg meter-near :bg progress-track
                    :inherit (drgnx-ui-caption warning error secondary-selection)
                    :font (drgnx-ui-caption))
                   ((meter-span) :fg meter-span :inherit (drgnx-ui-caption shadow) :font (drgnx-ui-caption))
                   ((meter-outline) :fg meter-tick :inherit (drgnx-ui-caption shadow) :font (drgnx-ui-caption)))
            :replaces nil :helpers nil :lint t)
  ;; a chip: a short label in a tinted rounded box, optionally led by an icon; `agent' takes its colour from the agent slot
  ;; (drgnx-agent-N); high contrast has no tint, a 1 px ring in the tone's colour
  (chip :variants ((tone neutral accent warn ok error agent) (fill soft solid)) :defaults (tone neutral fill soft)
        :geometry (:height 20 :pad (7 . 7) :gap 5 :box t :radius 4)
        :tty (:pad 1) :label nil
        :bind (((neutral soft) :hc-ring t :bg sel-quiet :fg muted :inherit (drgnx-ui-caption drgnx-text-muted drgnx-selected-quiet) :font (drgnx-ui-caption))
               ((accent soft) :hc-ring t :bg accent-tint :fg accent :inherit (drgnx-ui-caption drgnx-accent drgnx-selected-quiet) :font (drgnx-ui-caption))
               ((warn soft) :hc-ring t :bg warn-tint :fg warn :inherit (drgnx-ui-caption warning drgnx-selected-quiet) :font (drgnx-ui-caption))
               ((ok soft) :hc-ring t :bg ok-tint :fg ok :inherit (drgnx-ui-caption success drgnx-selected-quiet) :font (drgnx-ui-caption))
               ((error soft) :hc-ring t :bg error-tint :fg error :inherit (drgnx-ui-caption error drgnx-selected-quiet) :font (drgnx-ui-caption))
               ((neutral solid) :bg sel :fg on-accent :inherit (drgnx-ui-caption highlight) :font (drgnx-ui-caption))
               ((accent solid) :bg accent-fill :fg on-accent :inherit (drgnx-ui-caption highlight) :font (drgnx-ui-caption))
               ((warn solid) :bg warn :fg on-accent :inherit (drgnx-ui-caption highlight) :font (drgnx-ui-caption))
               ((ok solid) :bg ok :fg on-accent :inherit (drgnx-ui-caption highlight) :font (drgnx-ui-caption))
               ((error solid) :bg error :fg on-accent :inherit (drgnx-ui-caption highlight) :font (drgnx-ui-caption)))
        :replaces ((drgnx-chip-quiet . drgnx-kit-chip-neutral-soft) (drgnx-chip-accent . drgnx-kit-chip-accent-soft)
                   (drgnx-chip-ok . drgnx-kit-chip-ok-soft) (drgnx-chip-warn . drgnx-kit-chip-warn-soft)
                   (drgnx-chip-error . drgnx-kit-chip-error-soft) (drgnx-chip-solid . drgnx-kit-chip-accent-solid))
        :helpers (drgnx-decor-chip) :lint t)
  ;; a status dot: the status's glyph in its face, with its word after it when `word' is on (the terminal always has one)
  (status-dot :variants ((status done running needs-you idle error)) :defaults (status idle)
              :geometry (:height 0 :pad (0 . 0) :gap 4 :box nil :radius 0)
              :tty (:glyph (:by status (done ok) (running busy) (needs-you dot) (idle circle) (error fail)) :pad 0)
              :label (:by status (done "done") (running "running") (needs-you "needs you") (idle "not started") (error "error"))
              :bind (((done) :fg ok :inherit (drgnx-status-ok))
                     ((running) :fg info :inherit (drgnx-status-info))
                     ((needs-you) :fg attention :inherit (drgnx-status-needs-you))
                     ((idle) :fg subtle :inherit (drgnx-text-subtle))
                     ((error) :fg error :inherit (drgnx-status-fail)))
              :replaces nil :helpers (drgnx-ui-status) :lint t)))
