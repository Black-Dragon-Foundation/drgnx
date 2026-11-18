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
;;         :bind BINDINGS :replaces ((OLD-FACE . KIT-FACE)...) :helpers (OLD-FN...) :lint BOOL :sheet nil)
;;   :sheet nil: the hub draws the component alone (no Lisp expansion): it has no sheet and its page no pictures
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
                 ((danger) :bg error-tint :fg error :inherit (drgnx-ui-caption error drgnx-selected-quiet) :font (drgnx-ui-text)))
          :replaces ((drgnx-ui-button . drgnx-kit-button-secondary) (drgnx-ui-button-primary . drgnx-kit-button-primary)
                     (drgnx-button . drgnx-kit-button-secondary))
          :helpers nil :lint t)
  ;; a key hint: the keys in the code font in a 4 px box; `menu' is the text alone (a menu's shortcut column)
  (key-hint :variants ((variant cap menu)) :defaults (variant cap)
            :geometry (:height 0 :pad (:by variant (cap (5 . 5)) (menu (0 . 0))) :gap 0 :box (:by variant (cap t) (menu nil)) :radius 4)
            :tty (:pad 0) :label "key"
            :bind (((cap) :edge key-hint-edge :inherit (drgnx-code-small drgnx-control) :font (drgnx-code-small))
                   ((menu) :inherit (drgnx-code-small drgnx-text-subtle)))
            :replaces ((drgnx-keycap . drgnx-kit-key-hint-cap))
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
  ;; a section's header: the twisty (when collapsible) and the title in the UI font at 12 px, semibold, muted, with an
  ;; optional count; a click on a collapsible one folds it
  (section-header :variants ((collapsible no yes)) :defaults (collapsible no)
                  :geometry (:height 26 :pad (6 . 6) :gap 4 :box nil :radius 0 :hit 0)
                  :tty (:pad 1 :twisty (chevron-right chevron-down))
                  :label (:by collapsible (no "section") (yes "section, collapsible"))
                  :bind ((() :inherit (drgnx-text-muted drgnx-ui-caption) :attrs (:weight semibold)))
                  :replaces ((drgnx-wb-section . drgnx-kit-section-header)) :helpers nil :lint t)
  ;; a card: an 8 px ring inside the line (1 px, 2 px when selected; the attention colour when it needs you), the panel's
  ;; fill; a card of several rows is its top, mid and bottom shapes, whose ring is open where the next row goes on
  (card :variants ((kind plain needs-you selected) (shape single top mid bottom)) :defaults (kind plain shape single)
        :geometry (:height 0 :pad (8 . 8) :gap 0 :box t :radius 8 :hit 0)
        :tty (:pad 1) :label nil
        :bind (
((plain single) :bg panel :edge border-strong :ring (1 8 ) :inherit (secondary-selection))               ((plain top) :bg panel :edge border-strong :ring (1 8 bottom) :inherit (secondary-selection))               ((plain mid) :bg panel :edge border-strong :ring (1 8 top bottom) :inherit (secondary-selection))               ((plain bottom) :bg panel :edge border-strong :ring (1 8 top) :inherit (secondary-selection))               ((needs-you single) :bg panel :edge card-needs-you-edge :ring (1 8) :inherit (secondary-selection))               ((needs-you top) :bg panel :edge card-needs-you-edge :ring (1 8 bottom) :inherit (secondary-selection))               ((needs-you mid) :bg panel :edge card-needs-you-edge :ring (1 8 top bottom) :inherit (secondary-selection))               ((needs-you bottom) :bg panel :edge card-needs-you-edge :ring (1 8 top) :inherit (secondary-selection))               ((selected single) :bg panel :edge focus :ring (2 8) :inherit (secondary-selection))               ((selected top) :bg panel :edge focus :ring (2 8 bottom) :inherit (secondary-selection))               ((selected mid) :bg panel :edge focus :ring (2 8 top bottom) :inherit (secondary-selection))               ((selected bottom) :bg panel :edge focus :ring (2 8 top) :inherit (secondary-selection)))
        :replaces ((drgnx-card-single . drgnx-kit-card-plain-single) (drgnx-card-top . drgnx-kit-card-plain-top)
                   (drgnx-card-mid . drgnx-kit-card-plain-mid) (drgnx-card-bottom . drgnx-kit-card-plain-bottom)
                   (drgnx-card-sel-single . drgnx-kit-card-selected-single) (drgnx-card-sel-top . drgnx-kit-card-selected-top)
                   (drgnx-card-sel-mid . drgnx-kit-card-selected-mid) (drgnx-card-sel-bottom . drgnx-kit-card-selected-bottom))
        :helpers nil :lint t)
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
        :replaces nil
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
              :replaces nil :helpers nil :lint t)
  ;; a range bar: a span of time or money on an axis, in the row's own width (`width' logical px).  `schedule': done
  ;; solid, to p50 light, p50 to p90 the tail, a baseline tick, the target's mark; `cost': p50 solid, p50 to p90 the
  ;; tail, the limit a rule; `segment': one span in its kind's colour, its letter inside on a terminal.  The bar is
  ;; 10 px tall (8 compact, 12 roomy), never under 2 device px wide; a terminal draws a cell per 8 px as `█' `▓' `░'
  ;; (ASCII `#' `=' `-'), the forecast alone `┄' (`.'), a late cap `▌' and the word late (`!').  Each part is a binding
  ;; named by its part, a text colour (the editor draws the part's space as an image in it)
  (range-bar :variants ((variant schedule cost segment)) :defaults (variant schedule)
             :geometry (:height 0 :pad (0 . 0) :gap 0 :box nil :radius 2 :hit 0)
             :tty (:pad 0 :glyphs (bar-full range-light bar-empty range-late range-forecast seg-think))
             :label "range"
             :bind ((() :fg range-done :inherit (drgnx-ui-caption link) :font (drgnx-ui-caption))
                    ((forecast) :fg range-forecast :inherit (drgnx-ui-caption shadow) :font (drgnx-ui-caption))
                    ((tail) :fg range-tail :inherit (drgnx-ui-caption shadow) :font (drgnx-ui-caption))
                    ((late) :fg range-late :inherit (drgnx-ui-caption error) :font (drgnx-ui-caption))
                    ((wait) :fg range-wait :inherit (drgnx-ui-caption warning) :font (drgnx-ui-caption))
                    ((seg-read) :fg seg-read :inherit (drgnx-ui-caption ansi-color-blue) :font (drgnx-ui-caption))
                    ((seg-search) :fg seg-search :inherit (drgnx-ui-caption link) :font (drgnx-ui-caption))
                    ((seg-web) :fg seg-web :inherit (drgnx-ui-caption ansi-color-cyan) :font (drgnx-ui-caption))
                    ((seg-think) :fg seg-think :inherit (drgnx-ui-caption shadow) :font (drgnx-ui-caption))
                    ((seg-edit) :fg seg-edit :inherit (drgnx-ui-caption ansi-color-green) :font (drgnx-ui-caption))
                    ((seg-test) :fg seg-test :inherit (drgnx-ui-caption ansi-color-yellow) :font (drgnx-ui-caption))
                    ((seg-job) :fg seg-job :inherit (drgnx-ui-caption ansi-color-magenta) :font (drgnx-ui-caption))
                    ((seg-wait) :fg seg-wait :inherit (drgnx-ui-caption warning) :font (drgnx-ui-caption)))
             :replaces ((drgnx-work-seg-read . drgnx-kit-range-bar-seg-read) (drgnx-work-seg-edit . drgnx-kit-range-bar-seg-edit)
                        (drgnx-work-seg-tool . drgnx-kit-range-bar-seg-test) (drgnx-work-seg-think . drgnx-kit-range-bar-seg-think)
                        (drgnx-work-seg-job . drgnx-kit-range-bar-seg-job) (drgnx-work-seg-wait . drgnx-kit-range-bar-seg-wait))
             :helpers nil :lint t)
  ;; a time axis: ticks every STEP with their labels in the zone, a now marker; a terminal's marker is `│' (`|').  The
  ;; now line through the rows is `now-stop': one 1 px stop in the focus colour per row
  (time-axis :variants nil :defaults nil :sheet nil
             :geometry (:height 0 :pad (0 . 0) :gap 0 :box nil :radius 0 :hit 0)
             :tty (:pad 0 :glyphs (axis-now))
             :label "time axis"
             :bind ((() :inherit (drgnx-ui-caption shadow) :font (drgnx-ui-caption))
                    ((now) :fg range-done :inherit (drgnx-ui-caption link) :font (drgnx-ui-caption)))
             :replaces nil :helpers nil :lint t)
  ;; a tab: its icon (14 px, the shown tab's), its title and, when it has one, its close mark in an 18 px slot (the
  ;; Lucide x at 14 px, or a modified file's dot), the mark hidden in the row's colour unless the tab is shown or
  ;; hovered (a terminal always shows it).  An editor tab is window-dark.html's `.tab': muted on the row, the shown tab
  ;; on the editor's colour (`current'; in a group that is not the active one, still muted: `current-inactive'); a
  ;; panel tab is debugging.html's `.pt': the shown one a rounded pill on the quiet selection (`panel-current').  Its
  ;; label is its title, with "modified" after it when its file is.  A tab that is only there while it is shown (a
  ;; preview, the scratch buffer) is italic: the part `preview', laid over the tab's own face
  (tab :variants ((size editor panel)) :defaults (size editor)
       :geometry (:height (:by size (editor 34) (panel 30)) :pad (:by size (editor (10 . 8)) (panel (9 . 9)))
                          :gap (:by size (editor 7) (panel 6)) :box nil :radius (:by size (editor 7) (panel 6)) :hit 0)
       :tty (:pad 2 :glyphs (close dot)) :label "modified"
       :bind ((() :bg panel :fg muted :inherit (drgnx-ui-text tab-line-tab-inactive tab-line) :font (drgnx-ui-text))
              ((current) :bg editor :fg fg :inherit (drgnx-ui-text tab-line-tab-current tab-line) :font (drgnx-ui-text))
              ((current-inactive) :bg editor :fg muted :inherit (drgnx-ui-text drgnx-text-muted tab-line-tab-current tab-line)
               :font (drgnx-ui-text))
              ((panel-current) :bg sel-quiet :fg fg :edge sel-quiet :ring (1 6)
               :inherit (drgnx-ui-text drgnx-selected-quiet tab-line-tab-current) :font (drgnx-ui-text))
              ((preview) :attrs (:slant italic)))
       :replaces ((drgnx-chrome-tab . drgnx-kit-tab) (drgnx-chrome-tab-active . drgnx-kit-tab-current)
                  (drgnx-chrome-tab-current . drgnx-kit-tab-current-inactive) (drgnx-wb-tab . drgnx-kit-tab)
                  (drgnx-wb-tab-current . drgnx-kit-tab-panel-current) (drgnx-work-lens-title . drgnx-kit-tab-current)
                  (drgnx-chrome-tab-preview . drgnx-kit-tab-preview))
       :helpers nil :lint t)
  ;; a segmented switch: its items in one track (a 1 px ring in the border's colour, radius 6), the current one on the
  ;; quiet selection in the body text's colour, the others muted; each item an action.  The current item's label is
  ;; "LABEL, selected"
  (segmented :variants nil :defaults nil
             :geometry (:height 24 :pad (10 . 10) :gap 0 :box t :radius 6 :hit 0)
             :tty (:pad 1) :label "selected"
             :bind ((() :fg muted :edge border :ring (1 6) :inherit (drgnx-ui-text drgnx-text-muted tab-line)
                     :font (drgnx-ui-text))
                    ((current) :bg sel-quiet :fg fg :inherit (drgnx-ui-text drgnx-selected-quiet) :font (drgnx-ui-text)))
             :replaces ((drgnx-work-lens-rail . drgnx-kit-segmented) (drgnx-work-lens-seg . drgnx-kit-segmented)
                        (drgnx-work-lens-current . drgnx-kit-segmented-current))
             :helpers nil :lint t)
  ;; a diff block: a file's head row (path in the code font, +N -M, kit buttons), then each hunk's `@@' row and its lines
  ;; (a gutter number, the sign, the text) in the code font, in the card's ring; the part names the row's face
  (diff-block :variants ((part head hunk ctx add del)) :defaults (part ctx)
              :geometry (:height 0 :pad (10 . 10) :gap 8 :box t :radius 8 :hit 0)
              :tty (:pad 1) :label "diff"
              :bind (((head) :bg panel :fg fg :inherit (drgnx-code-small) :font (drgnx-code-small))
                     ((hunk) :bg panel :fg subtle :inherit (drgnx-code-small drgnx-text-subtle) :font (drgnx-code-small))
                     ((ctx) :bg panel :fg muted :inherit (drgnx-code-small drgnx-text-muted) :font (drgnx-code-small))
                     ((add) :bg add-bg :fg add-fg :inherit (drgnx-code-small diff-added) :font (drgnx-code-small))
                     ((del) :bg del-bg :fg del-fg :inherit (drgnx-code-small diff-removed) :font (drgnx-code-small)))
              :replaces ((drgnx-agent-panel-added . drgnx-kit-diff-block-add) (drgnx-agent-panel-removed . drgnx-kit-diff-block-del)
                         (drgnx-agent-panel-context . drgnx-kit-diff-block-ctx))
              :helpers nil :lint t)))
