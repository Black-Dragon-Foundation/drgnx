;;; drgnx-keycast.el --- Module extra/keycast: show keys as you type -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)

(drgnx-module-define 'extra/keycast
                     :doc "Show Keys As I Type, in the mode line (keycast)."
                     :stage 'idle :packages '(keycast)
                     :setup (lambda ()
                              (require 'keycast)
                              (drgnx-command-define 'view-keycast :category "View" :title "Show Keys As I Type"
                                                    :command 'keycast-mode-line-mode :doc "The keys and commands you use, in the mode line")))

(provide 'drgnx-keycast)
;;; drgnx-keycast.el ends here
