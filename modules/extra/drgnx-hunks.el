;;; drgnx-hunks.el --- Module extra/hunks: changes in the gutter (diff-hl) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function global-diff-hl-mode "diff-hl")

(drgnx-module-define 'extra/hunks
                     :doc "Changed lines in the gutter; show, revert or stage a change (diff-hl)."
                     :stage 'idle :packages '(diff-hl)
                     :setup (lambda ()
                              (require 'diff-hl)
                              (global-diff-hl-mode 1)
                              (pcase-dolist (`(,id ,title ,fn ,doc)
                                             '((git-hunk-show "Show Change" diff-hl-show-hunk "The change at point, against the last commit")
                                               (git-hunk-revert "Revert Change" diff-hl-revert-hunk "Undo the change at point")
                                               (git-hunk-stage "Stage Change" diff-hl-stage-current-hunk "Stage the change at point")))
                                (drgnx-command-define id :category "Source Control" :title title :command fn :doc doc))))

(provide 'drgnx-hunks)
;;; drgnx-hunks.el ends here
