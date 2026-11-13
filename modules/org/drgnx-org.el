;;; drgnx-org.el --- Module org/org: capture and agenda -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Org's capture and agenda, on the keys people know (C-c c, C-c a), and Org in the look (magit.html): headings in the
;; UI font, 17 px and 14.5 px at levels 1 and 2, weight 600, on Org's own `org-level-*' faces (so headings of
;; `outline-minor-mode' in code stay at the text's height); TODO keywords as chips (TODO attention, DONE ok); source
;; blocks as flat panels; tables in the code font, muted; links in the accent; tags right-aligned by pixel.  Only default specs change: a theme that
;; styles Org wins.  See docs/guide/modules.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-pixels)

(defconst drgnx-org-faces
  `((org-level-1 (drgnx-ui-text) :height ,(/ 17 13.5) :weight semibold)
    (org-level-2 (drgnx-ui-text) :height ,(/ 14.5 13.5) :weight semibold)
    ,@(mapcar (lambda (n) (list (intern (format "org-level-%d" n)) '(drgnx-ui-text) :weight 'semibold))
              '(3 4 5 6 7 8))
    (org-todo (drgnx-ui-caption drgnx-chip-attention) :weight semibold :box (:line-width (6 . -1) :style flat-button))
    (org-done (drgnx-ui-caption drgnx-chip-ok) :weight semibold :box (:line-width (6 . -1) :style flat-button))
    (org-headline-done (drgnx-text-muted))
    (org-tag (drgnx-text-subtle) :weight normal)
    (org-block (drgnx-surface-panel) :extend t)
    (org-block-begin-line (drgnx-text-subtle drgnx-surface-panel) :extend t)
    (org-block-end-line (drgnx-text-subtle drgnx-surface-panel) :extend t)
    (org-meta-line (drgnx-text-subtle))
    (org-table (drgnx-text-muted))
    (org-link (drgnx-accent) :underline t))
  "(FACE INHERITS . MORE): Org's FACE gets a default spec that inherits INHERITS, with the attributes MORE.  The sizes
are the mockup's pixels over the editor's 13.5 px.")

(defun drgnx-org--faces ()
  "Give Org's faces their look (`drgnx-org-faces')."
  (pcase-dolist (`(,face ,inherits . ,more) drgnx-org-faces)
    (when (facep face) (drgnx-module-face-spec face `((t :inherit ,inherits ,@more))))))

(defconst drgnx-org--tags-re
  "^\\(\\*+\\) .*?\\([ \t]+\\)\\(:\\(?:[[:alnum:]_@#%]+:\\)+\\)[ \t]*$"
  "A headline with tags: its stars (group 1), the blank before the tags (2) and the tags (3).")

(defun drgnx-org--align-tags (limit)
  "Font-lock matcher: the blank before a headline's tags becomes a space that ends where the tags end at the window's
right edge, 8 logical pixels in, by pixel (Org counts columns, which proportional headings break; look design §4).
Graphical frames only; always returns nil, the keyword has nothing to fontify."
  (when (display-graphic-p)
    (while (re-search-forward drgnx-org--tags-re limit t)
      (let* ((face (intern (format "org-level-%d" (1+ (mod (1- (length (match-string 1))) 8)))))
             (px (string-pixel-width (propertize (match-string 3) 'face (list 'org-tag face)))))
        (put-text-property (match-beginning 2) (match-end 2) 'display
                           `(space :align-to (- right (,(+ px (drgnx-px 8)))))))))
  nil)

(defun drgnx-org--tags-keyword ()
  "In an Org buffer: align the tags by pixel (`drgnx-org--align-tags'), and let font-lock take the spaces back when
a headline stops having tags."
  (font-lock-add-keywords nil '((drgnx-org--align-tags)) 'append)
  (setq-local font-lock-extra-managed-props (cons 'display font-lock-extra-managed-props)))

(drgnx-module-define 'org/org
                     :doc "Org capture and agenda; Org in the look."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (if (featurep 'org) (drgnx-org--faces)
                         (eval-after-load 'org (drgnx-modules-with-owner (drgnx-org--faces))))
                       (drgnx-module-hook 'org-mode-hook tags () (drgnx-org--tags-keyword))
                       (drgnx-command-define 'org-capture :category "Org" :title "Capture" :command #'org-capture
                                             :doc "Capture a note or task")
                       (drgnx-command-define 'org-agenda :category "Org" :title "Agenda Menu" :command #'org-agenda
                                             :doc "The agenda views")))

(provide 'drgnx-org)
;;; drgnx-org.el ends here
