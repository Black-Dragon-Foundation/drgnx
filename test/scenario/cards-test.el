;;; cards-test.el --- Scenarios: resizing the cards by their edges -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; SPDX-License-Identifier: GPL-3.0-or-later
;; The reference is VS Code's sash: dragging the gap between two panes, or the pane's edge beside it, resizes them.
;; With the cards on, the gap is the right divider and each card's side edge next to it is a fringe.  Runs at the
;; session's scale (`DRGNX_UI_SCALE'); see docs/develop/scenarios.md.

(require 'ert)
(require 'drgnx-scenario)
(require 'drgnx-uitest)

(defun drgnx-scn--cards-drag (where)
  "Drag 60 logical pixels to the right from WHERE (`dock-edge', `gap' or `editor-edge') beside the dock's right side;
the scenario check."
  (drgnx-scenario-settling
   (drgnx-scenario-load-driver)
   (drgnx-scenario-with-fixture (root 'basic)
     (drgnx-driver-reset)
     (drgnx-driver-open-file (expand-file-name "src/app/main.py" root))
     (drgnx-driver-show-sidebar)
     (drgnx-uitest-run nil)
     (let* ((f (selected-frame)) (dock (drgnx-driver-explorer-window))
            (_ (drgnx-scenario-require (window-live-p dock) "the Explorer showing in the dock"))
            (edges (window-pixel-edges dock)) (r (nth 2 edges))
            (gap (window-right-divider-width dock))
            (y (/ (+ (nth 1 edges) (nth 3 edges)) 2))
            (x (pcase where ('dock-edge (- r gap 2)) ('gap (- r (/ (max gap 1) 2) 1)) ('editor-edge (+ r 2))))
            (from (posn-at-x-y x y f))
            (want (pcase where ('dock-edge 'right-fringe) ('gap 'right-divider) ('editor-edge 'left-fringe)))
            (_ (drgnx-scenario-require (eq (posn-area from) want)
                                       (format "a %s at x %d (got %s; gap %d)" want x (posn-area from) gap)))
            (before (window-pixel-width dock))
            (m0 (with-current-buffer "*Messages*" (point-max)))
            (report (drgnx-uitest-run (drgnx-uitest-drag-events from (posn-at-x-y (+ x 60) y f) :lazy t :steps 8)))
            (after (window-pixel-width dock))
            (msgs (with-current-buffer "*Messages*" (buffer-substring-no-properties (min m0 (point-max)) (point-max)))))
       (drgnx-scenario-check
        (and (> after (+ before 40)) (not (string-search "is undefined" msgs)))
        (format "dragging the %s 60 px to the right must widen the dock: %d px became %d px; messages: %S"
                where before after (string-trim msgs))
        report)))))

(ert-deftest drgnx-scenario/cards-drag-the-gap ()
  "Dragging the gap between the dock's card and the editor's resizes them."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/cards-drag-the-gap)
  (drgnx-scn--cards-drag 'gap))

(ert-deftest drgnx-scenario/cards-drag-the-dock-edge ()
  "Dragging the dock card's side edge beside the gap resizes it, as the gap does."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/cards-drag-the-dock-edge)
  (drgnx-scn--cards-drag 'dock-edge))

(ert-deftest drgnx-scenario/cards-drag-the-editor-edge ()
  "Dragging the editor card's side edge beside the gap resizes the dock, as the gap does."
  :expected-result (drgnx-scenario-expected 'drgnx-scenario/cards-drag-the-editor-edge)
  (drgnx-scn--cards-drag 'editor-edge))

;;; cards-test.el ends here
