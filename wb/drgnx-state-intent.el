;;; drgnx-state-intent.el --- Intent: what was asked for a frame's panes, and by whom -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Intent is what was asked for a frame's panes — the size a pane comes back at, the front tab of an area, the
;; sidebar's view — and who asked: `user', `auto', `layout', `restore', `teardown' or `other'.  The store's
;; snapshot says what *is* on screen; intent says what was *asked*, so a size you chose is not replaced by the
;; size a popup squeezed the panel to.
;;
;; Until the grid (B3) intent has no storage of its own: `drgnx-state-intent' and `drgnx-state-note-intent'
;; read and write today's frame parameters (`drgnx-wb-dock-px', `drgnx-wb-areas', `drgnx-wb-view', …), so
;; nothing is stored twice and the saved workbench does not change.  Who asked lives in one readable frame
;; parameter, `drgnx-intent-by'.  See docs/develop/core.md, "Intent".

;;; Code:
(require 'drgnx-state)

(defconst drgnx-state-intent-bys '(user auto layout restore teardown other)
  "Who may ask for a write: you (`user', the default inside a command), drgnx on its own (`auto', the default
outside one), a layout, a restore, a module being turned off, or anything else.")

(defconst drgnx-state-intent--sizes
  '((left . drgnx-wb-dock-px) (bottom . drgnx-wb-panel-px) (right . drgnx-wb-right-px))
  "Home → the frame parameter that holds the size its pane comes back at, until B3.")

(defconst drgnx-state-intent--layouts
  '((:layout . drgnx-layouts-current) (:previous . drgnx-layouts-previous) (:zen-return . drgnx-layouts-zen-return))
  "Intent keys that layouts keep in their own frame parameters: read-only until B10.")

(defconst drgnx-state-intent--cap 64
  "At most this many entries in `drgnx-intent-by' per frame; the oldest goes first.")

(defun drgnx-state-intent--home (subkey)
  "SUBKEY of `:sizes' as a home: the area `panel' is the home `bottom'."
  (if (eq subkey 'panel) 'bottom subkey))

(defun drgnx-state-intent--by (frame key subkey)
  "Who asked for FRAME's KEY SUBKEY (from `drgnx-intent-by'), or nil."
  (cdr (assoc (cons key subkey) (frame-parameter frame 'drgnx-intent-by))))

(defun drgnx-state-intent--size (frame home)
  (let* ((param (alist-get home drgnx-state-intent--sizes)) (px (and param (frame-parameter frame param))))
    (and (integerp px) (list :px px :by (drgnx-state-intent--by frame :sizes home)))))

(defun drgnx-state-intent (frame key &optional subkey)
  "FRAME's intent KEY (FRAME nil: the selected frame), for SUBKEY; nil when nothing was asked.
KEY and SUBKEY, and where the answer comes from until the grid:
  `:sizes' HOME — `left', `bottom' (also `panel') or `right': (:px N :by BY), the size its pane comes back at
                  (`drgnx-wb-dock-px', `-panel-px', `-right-px'); no HOME: an alist HOME → that plist;
  `:front' AREA — the tab AREA shows in front (its `:tab' in `drgnx-wb-areas'); no AREA: an alist AREA → tab;
  `:view'       — the sidebar's view (`drgnx-wb-view'), also one no module defines now;
  `:layout', `:previous', `:zen-return' — the layout applied, the one before, Zen's return (layouts' own
                  parameters; read-only until B10);
  `:places', `:arrangement' — nil until the grid.
BY is who asked (`drgnx-state-intent-bys'), nil when nobody said."
  (let ((frame (or frame (selected-frame))))
    (when (frame-live-p frame)
      (pcase key
        (:sizes
         (if subkey
             (drgnx-state-intent--size frame (drgnx-state-intent--home subkey))
           (let (out)
             (pcase-dolist (`(,home . ,_) drgnx-state-intent--sizes)
               (when-let* ((size (drgnx-state-intent--size frame home))) (push (cons home size) out)))
             (nreverse out))))
        (:front
         (let ((areas (frame-parameter frame 'drgnx-wb-areas)))
           (if subkey
               (plist-get (alist-get subkey areas) :tab)
             (let (out)
               (pcase-dolist (`(,area . ,state) areas)
                 (when-let* ((tab (plist-get state :tab))) (push (cons area tab) out)))
               (nreverse out)))))
        (:view (frame-parameter frame 'drgnx-wb-view))
        ((or :layout :previous :zen-return) (frame-parameter frame (alist-get key drgnx-state-intent--layouts)))
        ((or :places :arrangement) nil)
        (_ (error "drgnx-state-intent: no intent %S" key))))))

(defun drgnx-state-intent--record (frame key subkey by)
  "Note in FRAME's `drgnx-intent-by' that BY asked for KEY SUBKEY: newest first, at most
`drgnx-state-intent--cap' entries.  Entries of kinds and areas nobody defines now are kept."
  (let ((entry (cons key subkey)))
    (set-frame-parameter
     frame 'drgnx-intent-by
     (take drgnx-state-intent--cap
           (cons (cons entry by) (assoc-delete-all entry (copy-alist (frame-parameter frame 'drgnx-intent-by))))))))

(cl-defun drgnx-state-note-intent (frame key subkey value &key by)
  "Note that BY asked for VALUE as FRAME's KEY SUBKEY (FRAME nil: the selected frame); non-nil when written.
KEY and SUBKEY as `drgnx-state-intent'.  VALUE: for `:sizes' the pixels (N, or (:px N)); for `:front' the
tab; for `:view' the view (SUBKEY nil).  The value goes to today's parameter (no copy) and BY to
`drgnx-intent-by'.  BY: nil means the running write's (`drgnx-state-with-write'), else
`drgnx-state-default-by'.
A size you chose (`user') is not replaced by `auto', `layout', `teardown' or `other' — a squeezed panel being
hidden, a layout's size — only by `user' or `restore'.  A `restore' replaces anything and counts as `user'
afterwards.  The front tab and the view are what shows until the grid, so every write of them lands.
`:layout', `:previous' and `:zen-return' are read-only until B10, and `:places' and `:arrangement' wait for
the grid: nil."
  (let ((frame (or frame (selected-frame)))
        (by (or by (plist-get drgnx-state--writing :by) (drgnx-state-default-by)))
        (subkey (if (eq key :sizes) (drgnx-state-intent--home subkey) subkey)))
    (unless (memq by drgnx-state-intent-bys)
      (error "drgnx-state-note-intent: :by must be one of %S, not %S" drgnx-state-intent-bys by))
    (when (and (frame-live-p frame)
               (pcase key
                 (:sizes
                  (let ((param (alist-get subkey drgnx-state-intent--sizes))
                        (px (if (integerp value) value (plist-get value :px))))
                    (when (and param (natnump px)
                               (or (memq by '(user restore))
                                   (not (eq 'user (drgnx-state-intent--by frame key subkey)))))
                      (set-frame-parameter frame param px)
                      t)))
                 (:front
                  (when (and subkey (symbolp subkey) (symbolp value))
                    (let ((areas (copy-alist (frame-parameter frame 'drgnx-wb-areas))))
                      (setf (alist-get subkey areas) (plist-put (copy-sequence (alist-get subkey areas)) :tab value))
                      (set-frame-parameter frame 'drgnx-wb-areas areas)
                      t)))
                 (:view
                  (when (symbolp value)
                    (set-frame-parameter frame 'drgnx-wb-view value)
                    t))
                 ((or :layout :previous :zen-return :places :arrangement) nil)
                 (_ (error "drgnx-state-note-intent: no intent %S" key))))
      (drgnx-state-intent--record frame key subkey (if (eq by 'restore) 'user by))
      t)))

(provide 'drgnx-state-intent)
;;; drgnx-state-intent.el ends here
