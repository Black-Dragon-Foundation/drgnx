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
(require 'drgnx-icons)

(declare-function magit-section-content-p "magit-section")
(declare-function slot-value "eieio-core")
(defvar magit-section-visibility-indicators)
(defvar magit-refresh-buffer-hook)

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
      (drgnx-module-face-spec face `((t :inherit ,inherits ,@more)))))
  (pcase feature
    ('magit-section (drgnx-look-bridge--magit-chevrons))
    ('magit (drgnx-look-bridge--magit-labels-on))))

(defface drgnx-look-bridge-label '((t :inherit drgnx-ui-heading))
  "Magit's own labels (Head:, Merge:, Push:) in the UI font, weight 600 (magit.html `.sec-h')."
  :group 'drgnx-look)

(defface drgnx-look-bridge-file-modified '((t :inherit drgnx-status-warn))
  "The word `modified' before a file in Magit's diffs (magit.html `.mod')."
  :group 'drgnx-look)

(defface drgnx-look-bridge-file-new '((t :inherit drgnx-status-ok))
  "The words `new file' before a file in Magit's diffs (magit.html `.new')."
  :group 'drgnx-look)

(defface drgnx-look-bridge-file-deleted '((t :inherit drgnx-status-fail))
  "The word `deleted' before a file in Magit's diffs."
  :group 'drgnx-look)

(defconst drgnx-look-bridge--magit-labels-re
  "^\\(\\(?:Head\\|Merge\\|Rebase\\|Push\\|Upstream\\|Pull\\|Tag\\|Tags\\|Branch\\):\\)\\|^\\(modified\\|new file\\|deleted\\) "
  "A Magit line's label (group 1) or a file line's status word (group 2).")

(defun drgnx-look-bridge--magit-label-overlays ()
  "Dress the labels Magit inserts with no face of its own in this buffer: `Head:', `Merge:' and the like in the UI
heading face, a file's `modified', `new file' and `deleted' in the warn, ok and fail colours.  Overlays, made again
on every refresh (Magit's own text gives no face to hang this on)."
  (when (display-graphic-p)
    (save-excursion
      (remove-overlays (point-min) (point-max) 'drgnx-look-label t)
      (goto-char (point-min))
      (while (re-search-forward drgnx-look-bridge--magit-labels-re nil t)
        (let ((o (make-overlay (or (match-beginning 1) (match-beginning 2)) (or (match-end 1) (match-end 2)))))
          (overlay-put o 'drgnx-look-label t)
          (overlay-put o 'face (if (match-beginning 1) 'drgnx-look-bridge-label
                                 (pcase (match-string 2)
                                   ("new file" 'drgnx-look-bridge-file-new)
                                   ("deleted" 'drgnx-look-bridge-file-deleted)
                                   (_ 'drgnx-look-bridge-file-modified)))))))))

(defun drgnx-look-bridge--magit-labels ()
  "`magit-refresh-buffer-hook': the labels of a Magit section buffer (`drgnx-look-bridge--magit-label-overlays')."
  (when (derived-mode-p 'magit-section-mode) (drgnx-look-bridge--magit-label-overlays)))

(defun drgnx-look-bridge--magit-labels-on ()
  "Dress the labels of Magit's buffers after each refresh, until ui/look goes."
  (drgnx-module-hook 'magit-refresh-buffer-hook magit-labels () :module 'ui/look
                     (drgnx-look-bridge--magit-labels)))

(defun drgnx-look-bridge--chevron-string (hidden)
  "The chevron before a section heading: right when the section is HIDDEN, down when it shows (magit.html `.sec-h')."
  (concat (drgnx-look-icon (if hidden 'chevron-right 'chevron-down) 'drgnx-text-subtle) " "))

(defun drgnx-look-bridge--chevron (section)
  "After Magit updates SECTION's visibility indicator: put the heading's own chevron, a Lucide icon in the heading's
text (the fringe's bitmaps are clipped by the card's narrow fringe), as an overlay on the heading line."
  (when (and (display-graphic-p) (magit-section-content-p section)
             ;; only a real section heading (Head:, Merge: and Push: lines are sections too, and have no chevron)
             (let ((face (get-text-property (slot-value section 'start) 'font-lock-face)))
               (memq 'magit-section-heading (ensure-list face))))
    (let* ((beg (slot-value section 'start))
           (ov (seq-find (lambda (o) (overlay-get o 'drgnx-look-chevron)) (overlays-at beg))))
      (unless ov
        (setq ov (make-overlay beg (save-excursion (goto-char beg) (line-end-position)) nil t))
        (overlay-put ov 'evaporate t)
        (overlay-put ov 'drgnx-look-chevron t))
      (overlay-put ov 'before-string (drgnx-look-bridge--chevron-string (slot-value section 'hidden))))))

(defun drgnx-look-bridge--magit-chevrons ()
  "Magit's section chevrons are the look's: its fringe indicators off on a graphical frame (a terminal keeps its
ellipsis), the heading's own chevron after each visibility update."
  (drgnx-module-set 'magit-section-visibility-indicators (list nil (cadr magit-section-visibility-indicators)))
  (drgnx-module-advice 'magit-section-maybe-update-visibility-indicator :after chevron (section)
    :module 'ui/look
    (drgnx-look-bridge--chevron section)))

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
        (remove-overlays (point-min) (point-max) 'drgnx-look-chevron t)
        (remove-overlays (point-min) (point-max) 'drgnx-look-label t)
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
