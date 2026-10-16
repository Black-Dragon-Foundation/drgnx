;;; drgnx-jump.el --- Module extra/jump: jump to visible text (avy) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)

(drgnx-module-define 'extra/jump
  :doc "Jump to Text: type a few characters, pick the place (avy)."
  :stage 'idle :packages '(avy)
  :setup (lambda ()
           (require 'avy)
           (drgnx-command-define 'go-jump :category "Go" :title "Jump to Text" :command 'avy-goto-char-timer
             :scope 'editing :doc "Type characters, then the letter of the place to jump to")))

(provide 'drgnx-jump)
;;; drgnx-jump.el ends here
