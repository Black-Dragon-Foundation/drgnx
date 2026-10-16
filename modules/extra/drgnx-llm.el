;;; drgnx-llm.el --- Module extra/llm: chat with a language model (gptel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; gptel's menu and send.  Which model and key it uses is gptel's configuration (M9 brings the
;; provider registry); this module never reads a key itself.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)

(drgnx-module-define 'extra/llm
  :doc "LLM Menu and Send to LLM (gptel)."
  :stage 'idle :packages '(gptel)
  :setup (lambda ()
           (require 'gptel)
           (drgnx-command-define 'llm-menu :category "AI" :title "LLM Menu" :command 'gptel-menu
             :doc "Model, context and options (gptel)")
           (drgnx-command-define 'llm-send :category "AI" :title "Send to LLM" :command 'gptel-send
             :doc "Send the buffer up to point, or the selection")))

(provide 'drgnx-llm)
;;; drgnx-llm.el ends here
