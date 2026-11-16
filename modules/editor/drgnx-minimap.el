;;; drgnx-minimap.el --- Module editor/minimap: the scroll bar with marks on every surface -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The module of the scroll bar and, as its later stages land, the minimap that widens out of it (docs/guide/
;; minimap.md).  Its setup turns on the scroll bar on every scrollable surface (`drgnx-scrollbar-mode',
;; core/drgnx-ruler.el) and the marks' producers (core/drgnx-marks.el), and redraws the strips when the UI
;; scale or the density changes; its teardown undoes both.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-ruler)
(require 'drgnx-marks)

(defvar drgnx-look-density-changed-hook)

(defun drgnx-minimap--teardown ()
  "The scroll bar and the marks' producers off; every window's strip gone."
  (drgnx-marks-off)
  (remove-hook 'drgnx-look-density-changed-hook #'drgnx-scrollbar-refresh-all)
  (drgnx-scrollbar-mode -1))

(drgnx-module-define 'editor/minimap
                     :doc "The scroll bar on every scrollable surface: the thumb and the file's marks (changes, problems, search hits)."
                     :stage 'startup
                     :teardown #'drgnx-minimap--teardown
                     :setup (lambda ()
                              (drgnx-scrollbar-mode 1)
                              (add-hook 'drgnx-look-density-changed-hook #'drgnx-scrollbar-refresh-all)
                              (drgnx-marks-on)))

(provide 'drgnx-minimap)
;;; drgnx-minimap.el ends here
