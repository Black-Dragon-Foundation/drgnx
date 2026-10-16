;;; drgnx-search.el --- Module tools/search: quick open, search in project, go to symbol -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Quick Open (a project file by name), Search in Project (results in the panel's Results tab),
;; Go to Symbol in the file.  Built on project.el, xref and imenu.  See docs/modules.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function project-find-regexp "project")

(defun drgnx-search-project (regexp)
  "Search the project for REGEXP; the results go to the panel."
  (interactive (list (read-regexp "Search in project: " (thing-at-point 'symbol t))))
  (require 'project)
  (project-find-regexp regexp))

(drgnx-module-define 'tools/search
  :doc "Quick Open, Search in Project, Go to Symbol."
  :stage 'startup
  :setup
  (lambda ()
    (pcase-dolist (`(,id ,title ,fn ,doc)
                   '((go-quick-open "Quick Open" project-find-file "Open a file of the project by name")
                     (search-project "Search in Project" drgnx-search-project "Every match in the project (in the panel)")
                     (go-symbol "Go to Symbol" imenu "Jump to a definition of this file")))
      (drgnx-command-define id :category "Go" :title title :command fn :doc doc))))

(provide 'drgnx-search)
;;; drgnx-search.el ends here
