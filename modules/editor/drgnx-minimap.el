;;; drgnx-minimap.el --- Module editor/minimap: the scroll bar with marks on every surface -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The module of the scroll bar and, as its later stages land, the minimap that widens out of it (docs/guide/
;; minimap.md).  Its setup turns on the scroll bar on every scrollable surface (`drgnx-scrollbar-mode',
;; core/drgnx-ruler.el) and the marks' producers (core/drgnx-marks.el), and redraws the strips when the UI
;; scale or the density changes; its teardown undoes both.  It registers the next-mark commands (`mark-next', by kind
;; `change-next', `bookmark-next', `agent-edit-next', each with a previous).

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-ruler)
(require 'drgnx-marks)
(require 'drgnx-registry)

(defvar drgnx-look-density-changed-hook)

(defconst drgnx-minimap--commands
  '((mark-next "Next Mark" drgnx-marks-next "Go to the next mark of any kind on the scroll bar")
    (mark-previous "Previous Mark" drgnx-marks-previous "Go to the previous mark of any kind on the scroll bar")
    (change-next "Next Change" drgnx-marks-next-change "Go to the next change against the last commit")
    (change-previous "Previous Change" drgnx-marks-previous-change "Go to the previous change against the last commit")
    (bookmark-next "Next Bookmark" drgnx-marks-next-bookmark "Go to the next bookmark in this file")
    (bookmark-previous "Previous Bookmark" drgnx-marks-previous-bookmark "Go to the previous bookmark in this file")
    (agent-edit-next "Next Agent Edit" drgnx-marks-next-agent-edit "Go to the next place an agent edited in this file")
    (agent-edit-previous "Previous Agent Edit" drgnx-marks-previous-agent-edit
                         "Go to the previous place an agent edited in this file"))
  "The module's commands: (ID TITLE FUNCTION DOC) each.")

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
                              (pcase-dolist (`(,id ,title ,fn ,doc) drgnx-minimap--commands)
                                (drgnx-command-define id :category "Go" :title title :command fn :scope 'editing
                                                      :doc doc))
                              (drgnx-scrollbar-mode 1)
                              (add-hook 'drgnx-look-density-changed-hook #'drgnx-scrollbar-refresh-all)
                              (drgnx-marks-on)))

(provide 'drgnx-minimap)
;;; drgnx-minimap.el ends here
