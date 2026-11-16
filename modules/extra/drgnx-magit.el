;;; drgnx-magit.el --- Module extra/magit: Source Control is magit when installed -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)

(drgnx-module-define 'extra/magit
                     :doc "Source Control opens magit (instead of Emacs' VC) when magit is installed and the side bar's
Source Control (tools/scm) is off; with it on, \"Git: Open in Magit\" opens magit."
                     :stage 'idle :packages '(magit)
                     :setup (lambda ()
                              (unless (drgnx-module-chosen-p 'tools/scm)
                                (drgnx-command-define 'scm-view :category "Source Control" :title "Source Control"
                                                      :command 'magit-status :doc "The repository's status (magit)"))))

(provide 'drgnx-magit)
;;; drgnx-magit.el ends here
