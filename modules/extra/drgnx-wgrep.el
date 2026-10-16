;;; drgnx-wgrep.el --- Module extra/wgrep: edit search results in place -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)

(drgnx-module-define 'extra/wgrep
  :doc "Edit Results: change search results in place and apply them to the files (wgrep)."
  :stage 'idle :packages '(wgrep)
  :setup (lambda ()
           (require 'wgrep)
           (drgnx-command-define 'search-edit-results :category "Search" :title "Edit Results"
             :command 'wgrep-change-to-wgrep-mode :doc "Make the search results editable")
           (drgnx-command-define 'search-apply-edits :category "Search" :title "Apply Edited Results"
             :command 'wgrep-finish-edit :doc "Write the edited results to their files")))

(provide 'drgnx-wgrep)
;;; drgnx-wgrep.el ends here
