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
;;   BINDINGS: (((VARIANT-VALUE...) :bg TOKEN :fg TOKEN :edge TOKEN :inherit (STANDARD-FACE...) :inverse BOOL)...);
;;   the binding of () is the component's own face `drgnx-kit-ID', another one `drgnx-kit-ID-VALUE...', made only
;;   where its colours differ from the component's own.  A binding may name a part instead of variant values (the
;;   progress bar's `fill').  :inverse swaps the colours of the faces drawn with it (an agent mark: its agent's colour
;;   as the fill).
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
  ;; an agent's mark: its handle (one or two letters) on its colour (the colour's face `drgnx-agent-N' drawn
  ;; inverse), about 18 px square (the caption's line, 5 px each side of a letter), radius 4 where Glitnir rounds; a
  ;; terminal draws [H] in the colour.  Inline: no line height of its own
  (agent-mark :variants nil :defaults nil
              :geometry (:height 0 :pad (5 . 5) :gap 0 :box nil :radius 4 :hit 0)
              :tty (:pad 0) :label "agent"
              :bind ((() :inherit (drgnx-ui-caption) :inverse t))
              :replaces nil :helpers nil :lint t)
  ;; progress: a bar (4 px tall, `drgnx-ui-kit-progress-bar-px': the fill, then the track) or a ring (one of five
  ;; glyphs, in the fill's colour); its word is "N percent".  A terminal draws the bar as a cell per 8 px of its width
  ;; (`drgnx-ui-kit-progress-cell-px') between edges, the filled ones `bar-full' in the fill's colour
  (progress :variants ((kind bar ring)) :defaults (kind bar)
            :geometry (:height 0 :pad (0 . 0) :gap 0 :box nil
                               :radius (:by kind (bar 2) (ring 0)) :hit 0)
            :tty (:pad 0 :glyphs (bar-left bar-full bar-right progress-0 progress-1 progress-2 progress-3 progress-4))
            :label "percent"
            :bind ((() :bg progress-track :inherit (drgnx-ui-caption))
                   ((ring) :fg progress-fill :inherit (drgnx-ui-caption))
                   ((fill) :bg progress-fill :fg progress-fill :inherit (drgnx-ui-caption)))
            :replaces nil :helpers nil :lint t)))
