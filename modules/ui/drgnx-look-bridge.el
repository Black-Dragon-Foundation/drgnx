;;; drgnx-look-bridge.el --- ui/look: the theme bridge, package faces onto the look's faces -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Packages draw with their own faces, and their own default specs (Magit's gold headings) know
;; nothing of the look.  The bridge gives those faces default specs that inherit the look's semantic faces (design
;; §3.3, PUI-B): Magit's headings in the UI heading role, its refs as chips (local in the accent, remote in ok, tags
;; in warn), its hunks on the quiet selection, its diff lines on the diff tints.  Only default specs change, through the module's face-spec door: a theme that styles the package itself
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
     (magit-tag (drgnx-ui-caption drgnx-chip-warn) :box ,drgnx-look-bridge--chip-box)))
  "Per feature: (FACE INHERITS . MORE): FACE's default spec inherits the faces INHERITS, with the attributes MORE.")

(defun drgnx-look-bridge--apply (feature)
  "Give FEATURE's faces of `drgnx-look-bridge-faces' their specs (the ones that exist)."
  (pcase-dolist (`(,face ,inherits . ,more) (cdr (assq feature drgnx-look-bridge-faces)))
    (when (facep face)
      (drgnx-module-face-spec face `((t :inherit ,inherits ,@more))))))

(defconst drgnx-look-bridge--magit-inset
  (propertize " " 'display '(when (display-graphic-p) space :width 1.0) 'invisible t)
  "Magit's `line-prefix' on a graphical frame: a column, so with the fringe its text starts 16 px into the card
\(magit.html); invisible on a terminal.")

(defvar-local drgnx-look-bridge--magit-inset-p nil "Non-nil in a Magit buffer this module gave its inset.")

(defun drgnx-look-bridge-magit-inset ()
  "On `magit-section-mode-hook': Magit's text sits in from the card's edge, past its section chevrons in the fringe."
  (setq-local line-prefix drgnx-look-bridge--magit-inset wrap-prefix drgnx-look-bridge--magit-inset
              drgnx-look-bridge--magit-inset-p t))

(defun drgnx-look-bridge--magit-inset-off ()
  "Take the inset out of the Magit buffers that have it."
  (dolist (b (buffer-list))
    (when (buffer-local-value 'drgnx-look-bridge--magit-inset-p b)
      (with-current-buffer b
        (mapc #'kill-local-variable '(line-prefix wrap-prefix drgnx-look-bridge--magit-inset-p))))))

(defun drgnx-look-bridge-on ()
  "In ui/look's setup: bridge every package of `drgnx-look-bridge-faces', now when it is loaded, else when it loads;
Magit's buffers get their inset (`drgnx-look-bridge-magit-inset')."
  (drgnx-modules-push-undo "Magit's inset" #'drgnx-look-bridge--magit-inset-off)
  (add-hook 'magit-section-mode-hook #'drgnx-look-bridge-magit-inset)
  (dolist (entry drgnx-look-bridge-faces)
    (let ((feature (car entry)))
      (if (featurep feature) (drgnx-look-bridge--apply feature)
        (eval-after-load feature (drgnx-modules-with-owner (drgnx-look-bridge--apply feature)))))))

(provide 'drgnx-look-bridge)
;;; drgnx-look-bridge.el ends here
