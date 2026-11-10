;;; drgnx-look-bridge.el --- ui/look: the theme bridge, package faces onto the look's faces -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Packages draw with their own faces, and their own default specs (Magit's gold headings, diff-hl's tints) know
;; nothing of the look.  The bridge gives those faces default specs that inherit the look's semantic faces (design
;; §3.3, PUI-B): Magit's headings in the UI heading role, its refs as chips (local in the accent, remote in ok, tags
;; in warn), its hunks on the quiet selection, its diff lines on the diff tints; diff-hl's gutter in the status
;; colours.  Only default specs change, through the module's face-spec door: a theme that styles the package itself
;; wins, and the old specs come back when ui/look is turned off.  A package not loaded yet gets its specs when it
;; loads.  No colour is named here.  See docs/guide/look.md, "Packages".

;;; Code:
(require 'drgnx-modules)

(defconst drgnx-look-bridge--chip-box '(:line-width (3 . -1) :style flat-button)
  "A chip's room inside text: 3 px either side in its own background, none above or below, so a chip is as tall as
the text and never grows the line (look.css `.mg .ref').")

(defconst drgnx-look-bridge-faces
  `((magit-section
     (magit-section-heading (drgnx-ui-heading))
     ;; the hover colour only: an overlay face, it must not take the heading's UI font away (`drgnx-hover-row' does)
     (magit-section-highlight (drgnx-hover) :extend t)
     (magit-section-heading-selection (drgnx-accent)))
    (magit-diff
     (magit-diff-file-heading (default) :weight normal)
     (magit-diff-file-heading-highlight (drgnx-hover-row) :weight normal)
     (magit-diff-hunk-heading (drgnx-text-muted drgnx-selected-quiet) :extend t)
     (magit-diff-hunk-heading-highlight (drgnx-text-muted drgnx-selected-quiet) :extend t)
     (magit-diff-added (diff-added) :extend t)
     (magit-diff-added-highlight (diff-added) :extend t)
     (magit-diff-removed (diff-removed) :extend t)
     (magit-diff-removed-highlight (diff-removed) :extend t)
     (magit-diff-context (drgnx-text-muted) :extend t)
     (magit-diff-context-highlight (drgnx-text-muted) :extend t)
     (magit-diffstat-added (drgnx-status-ok))
     (magit-diffstat-removed (drgnx-status-fail)))
    (magit
     (magit-hash (drgnx-text-subtle))
     (magit-dimmed (drgnx-text-subtle))
     (magit-filename (default) :weight normal)
     (magit-header-line (drgnx-ui-heading))
     (magit-log-author (drgnx-text-muted))
     (magit-log-date (drgnx-text-subtle))
     (magit-branch-local (drgnx-ui-caption drgnx-chip-accent) :box ,drgnx-look-bridge--chip-box)
     (magit-branch-current (drgnx-ui-caption drgnx-chip-accent) :box ,drgnx-look-bridge--chip-box)
     (magit-branch-remote (drgnx-ui-caption drgnx-chip-ok) :box ,drgnx-look-bridge--chip-box)
     (magit-branch-remote-head (drgnx-ui-caption drgnx-chip-ok) :box ,drgnx-look-bridge--chip-box)
     (magit-tag (drgnx-ui-caption drgnx-chip-warn) :box ,drgnx-look-bridge--chip-box))
    (diff-hl
     (diff-hl-insert (drgnx-status-ok))
     (diff-hl-change (drgnx-status-info))
     (diff-hl-delete (drgnx-status-fail))))
  "Per feature: (FACE INHERITS . MORE): FACE's default spec inherits the faces INHERITS, with the attributes MORE.")

(defun drgnx-look-bridge--apply (feature)
  "Give FEATURE's faces of `drgnx-look-bridge-faces' their specs (the ones that exist)."
  (pcase-dolist (`(,face ,inherits . ,more) (cdr (assq feature drgnx-look-bridge-faces)))
    (when (facep face)
      (drgnx-module-face-spec face `((t :inherit ,inherits ,@more))))))

(defun drgnx-look-bridge-on ()
  "In ui/look's setup: bridge every package of `drgnx-look-bridge-faces', now when it is loaded, else when it loads."
  (dolist (entry drgnx-look-bridge-faces)
    (let ((feature (car entry)))
      (if (featurep feature) (drgnx-look-bridge--apply feature)
        (eval-after-load feature (drgnx-modules-with-owner (drgnx-look-bridge--apply feature)))))))

(provide 'drgnx-look-bridge)
;;; drgnx-look-bridge.el ends here
