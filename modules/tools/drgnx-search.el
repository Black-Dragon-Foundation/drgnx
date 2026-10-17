;;; drgnx-search.el --- Module tools/search: quick open, search in project, go to symbol -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Quick Open (a project file by name), Search in Project (results in the panel's Results tab),
;; Go to Symbol in the file and in the project, Find in File, Replace in Project, Recent Buffers.
;; Built on project.el, xref and imenu (consult when installed).  See docs/guide/modules.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function project-find-regexp "project")

(defun drgnx-search-project (regexp)
  "Search the project for REGEXP; the results go to the panel."
  (interactive (list (read-regexp "Search in project: " (thing-at-point 'symbol t))))
  (require 'project)
  (project-find-regexp regexp))

(defun drgnx-search-file ()
  "Find in this file: consult-line when it is installed, else incremental search."
  (interactive)
  (call-interactively (if (fboundp 'consult-line) #'consult-line #'isearch-forward)))

(defun drgnx-search-recent ()
  "Switch to a buffer or a recent file: consult-buffer when it is installed, else switch-to-buffer."
  (interactive)
  (call-interactively (if (fboundp 'consult-buffer) #'consult-buffer #'switch-to-buffer)))

(drgnx-module-define 'tools/search
                     :doc "Quick Open, Search in Project, Go to Symbol."
                     :stage 'startup
                     :setup
                     (lambda ()
                       (pcase-dolist (`(,id ,title ,fn ,doc)
                                      '((go-quick-open "Quick Open" project-find-file "Open a file of the project by name")
                                        (search-project "Search in Project" drgnx-search-project "Every match in the project (in the panel)")
                                        (go-symbol "Go to Symbol" imenu "Jump to a definition of this file")
                                        (go-symbol-project "Go to Symbol in Project" xref-find-apropos "Search symbols across the project")
                                        (go-recent "Recent Buffers" drgnx-search-recent "Switch buffer or recent file")
                                        (search-file "Find in File" drgnx-search-file "Search this buffer")
                                        (search-replace "Replace in Project" project-query-replace-regexp "Replace a regexp in the project's files")))
                         (drgnx-command-define id :category "Go" :title title :command fn :doc doc))))

(provide 'drgnx-search)
;;; drgnx-search.el ends here
