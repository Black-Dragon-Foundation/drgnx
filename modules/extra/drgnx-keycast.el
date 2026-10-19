;;; drgnx-keycast.el --- Module extra/keycast: show keys as you type -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function keycast-mode-line-mode "keycast")
(defvar keycast-mode-line-mode)

(defun drgnx-keycast--teardown ()
  "The keys leave the mode line with the module (the user turned them on, not the setup)."
  (when (bound-and-true-p keycast-mode-line-mode) (keycast-mode-line-mode -1)))

(drgnx-module-define 'extra/keycast
                     :doc "Show Keys As I Type, in the mode line (keycast)."
                     :stage 'idle :packages '(keycast)
                     :teardown #'drgnx-keycast--teardown
                     :setup (lambda ()
                              (require 'keycast)
                              (drgnx-command-define 'view-keycast :category "View" :title "Show Keys As I Type"
                                                    :command 'keycast-mode-line-mode :doc "The keys and commands you use, in the mode line")))

(provide 'drgnx-keycast)
;;; drgnx-keycast.el ends here
