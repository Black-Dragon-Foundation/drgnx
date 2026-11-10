;;; drgnx-org.el --- Module org/org: capture and agenda -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Org's capture and agenda, on the keys people know (C-c c, C-c a), and Org in the look (magit.html): headings in the
;; UI font, 17 px and 14.5 px at levels 1 and 2, weight 600, on Org's own `org-level-*' faces (so headings of
;; `outline-minor-mode' in code stay at the text's height); TODO keywords as chips (TODO attention, DONE ok); source
;; blocks as flat panels; tables in the code font, muted; links in the accent.  Only default specs change: a theme that
;; styles Org wins.  See docs/guide/modules.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)

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

(drgnx-module-define 'org/org
                     :doc "Org capture and agenda; Org in the look."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (if (featurep 'org) (drgnx-org--faces)
                         (eval-after-load 'org (drgnx-modules-with-owner (drgnx-org--faces))))
                       (drgnx-command-define 'org-capture :category "Org" :title "Capture" :command #'org-capture
                                             :doc "Capture a note or task")
                       (drgnx-command-define 'org-agenda :category "Org" :title "Agenda Menu" :command #'org-agenda
                                             :doc "The agenda views")))

(provide 'drgnx-org)
;;; drgnx-org.el ends here
