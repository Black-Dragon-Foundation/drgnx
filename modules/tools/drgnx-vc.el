;;; drgnx-vc.el --- Module tools/vc: source control on Emacs' VC -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Source Control (the project's changes, in the editor), Diff with File (unsaved changes), Blame
;; (who changed each line).  Built on Emacs' VC — any backend it knows.  See docs/guide/modules.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function vc-dir "vc-dir")
(declare-function project-root "project")

(defun drgnx-vc-status ()
  "The changes of the project (or this folder), in the editor."
  (interactive)
  (vc-dir (or (when-let* ((p (project-current))) (project-root p)) default-directory)))

(defun drgnx-vc-diff-with-file ()
  "This buffer's unsaved changes against its file."
  (interactive)
  (diff-buffer-with-file (current-buffer)))

(drgnx-module-define 'tools/vc
  :doc "Source Control, Diff with File, Blame — on Emacs' VC."
  :stage 'startup
  :setup
  (lambda ()
    (pcase-dolist (`(,id ,title ,fn ,doc)
                   '((scm-view "Source Control" drgnx-vc-status "The project's changes")
                     (buffers-diff "Diff with File" drgnx-vc-diff-with-file "Unsaved changes against the file")
                     (scm-blame "Blame" vc-annotate "Who changed each line")))
      (drgnx-command-define id :category "Source Control" :title title :command fn :doc doc))))

(provide 'drgnx-vc)
;;; drgnx-vc.el ends here
