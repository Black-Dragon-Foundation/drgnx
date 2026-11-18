;;; drgnx-menu-look.el --- The look of Nidhogg's native menus: the ☰ list and the context menus -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Nidhogg's menus (lisp/term/nhwl-menu.el) are child frames showing one text row per item, sized by Nidhogg's options
;; (group `nhwl-menu': a least width, the rows' height and padding, the menu frames' parameters).  The kit feeds them
;; (`drgnx-ui-kit-menu-values'): 220 px wide at least, rows the density's tree row high with 12 px at either end,
;; separators a thin rule in a 9 px row, the selected row a rounded fill 4 px in from the sides, the popups' radius and shadow (none in high contrast); the faces put the text in the UI sans on the overlay surface, the
;; selected row in the state table's selection and the key hints in the subtle code font.  The values follow a change of
;; density or theme; Nidhogg scales them by the frame's scale when a menu opens.
;; Part of the module ui/face: set up by its setup, undone by its teardown.  docs/guide/face.md, "The menu bar".

;;; Code:
(require 'cl-lib)
(require 'drgnx-modules)
(require 'drgnx-ui-kit)

(defvar nhwl-menu-min-width)
(defvar nhwl-menu-row-height)
(defvar nhwl-menu-row-padding)
(defvar nhwl-menu-separator-height)
(defvar nhwl-menu-selection-inset)
(defvar nhwl-menu-selection-radius)
(defvar nhwl-menu-frame-parameters)
(defvar drgnx-look-density-changed-hook)
(declare-function drgnx-look-chrome-for "drgnx-look" (variant))
(declare-function drgnx-look-variant "drgnx-theme-gen" (&optional frame))

(defvar drgnx-menu-look--door nil
  "While ui/face runs: `drgnx-menu-look--feed' run as the module, so a later feed is undone with it too.")

(defun drgnx-menu-look--frame-parameters (values)
  "The menu frames' parameters for the kit's VALUES: the radius, the look's popup shadow or none, and no scroll bar
\(`drgnx-minimap-exclude': its strip would narrow a frame Nidhogg sized to the rows)."
  (let ((shadow (and (plist-get values :shadow) (fboundp 'drgnx-look-chrome-for)
                     (alist-get 'shadow (drgnx-look-chrome-for (if (fboundp 'drgnx-look-variant) (drgnx-look-variant) 'dark))))))
    `((corner-radius . ,(plist-get values :radius)) (shadow . ,shadow) (drgnx-minimap-exclude . t))))

(defvar drgnx-menu-look--fed nil
  "The menu options last set, (VALUES . FRAME-PARAMETERS): a change of density or theme that leaves them sets nothing.")

(defun drgnx-menu-look--feed ()
  "Set Nidhogg's menu options from the kit's values (`drgnx-module-set'), unless they are what was last set."
  (let* ((values (drgnx-ui-kit-menu-values))
         (params (drgnx-menu-look--frame-parameters values)))
    (unless (equal drgnx-menu-look--fed (cons values params))
      (setq drgnx-menu-look--fed (cons values params))
      (drgnx-module-set 'nhwl-menu-min-width (plist-get values :min-width))
      (drgnx-module-set 'nhwl-menu-row-height (plist-get values :row-height))
      (drgnx-module-set 'nhwl-menu-row-padding (plist-get values :row-padding))
      (drgnx-module-set 'nhwl-menu-separator-height (plist-get values :separator-height))
      (drgnx-module-set 'nhwl-menu-selection-inset (plist-get values :selection-inset))
      (drgnx-module-set 'nhwl-menu-selection-radius (plist-get values :selection-radius))
      (drgnx-module-set 'nhwl-menu-frame-parameters params))))

(defun drgnx-menu-look--refeed (&rest _)
  "On a change of density or theme: feed the menus again, as the module."
  (when drgnx-menu-look--door (funcall drgnx-menu-look--door)))

(defun drgnx-menu-look-setup ()
  "Make Nidhogg's menus follow the look: their options and faces, the options again on a change of density or theme
\(called by the module ui/face)."
  (drgnx-module-face-spec 'nhwl-menu '((t :inherit (drgnx-ui-text drgnx-surface-overlay))))
  (drgnx-module-face-spec 'nhwl-menu-selected `((t :inherit ,(or (drgnx-ui-kit-state-face 'selected) 'drgnx-selected))))
  (drgnx-module-face-spec 'nhwl-menu-key '((t :inherit (drgnx-text-subtle drgnx-code-small))))
  (setq drgnx-menu-look--fed nil)
  (drgnx-menu-look--feed)
  (setq drgnx-menu-look--door (drgnx-modules-with-owner (drgnx-menu-look--feed)))
  (drgnx-modules-push-undo "menu look door" (lambda () (setq drgnx-menu-look--door nil drgnx-menu-look--fed nil)))
  (dolist (hook '(drgnx-look-density-changed-hook enable-theme-functions))
    (add-hook hook #'drgnx-menu-look--refeed)
    (drgnx-modules-push-undo (format "menu look %s" hook) (lambda () (remove-hook hook #'drgnx-menu-look--refeed)))))

(provide 'drgnx-menu-look)
;;; drgnx-menu-look.el ends here
