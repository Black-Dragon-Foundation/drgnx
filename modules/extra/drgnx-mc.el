;;; drgnx-mc.el --- Module extra/mc: several cursors (multiple-cursors) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)

(drgnx-module-define 'extra/mc
                     :doc "Add Next Occurrence, Select All Occurrences: a cursor on each match (multiple-cursors)."
                     :stage 'idle :packages '(multiple-cursors)
                     :setup (lambda ()
                              (require 'multiple-cursors)
                              (drgnx-command-define 'edit-next-occurrence :category "Edit" :title "Add Next Occurrence"
                                                    :command 'mc/mark-next-like-this :scope 'editing :doc "A cursor on the next match of the selection")
                              (drgnx-command-define 'edit-all-occurrences :category "Edit" :title "Select All Occurrences"
                                                    :command 'mc/mark-all-like-this :scope 'editing :doc "A cursor on every match of the selection")))

(provide 'drgnx-mc)
;;; drgnx-mc.el ends here
