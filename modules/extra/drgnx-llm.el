;;; drgnx-llm.el --- Module extra/llm: chat with a language model (gptel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; gptel's menu and send.  gptel's backend comes from drgnx's provider registry — the `chat' role's first
;; provider that can be asked (docs/guide/ai.md) — unless you set a backend of your own; its key is a
;; function asked when gptel sends, never stored.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function drgnx-ai-usable-p "drgnx-ai-probe")
(declare-function drgnx-ai-gptel-maybe-configure "drgnx-ai")

(drgnx-module-define 'extra/llm
                     :doc "LLM Menu and Send to LLM (gptel)."
                     :stage 'idle :packages '(gptel)
                     :setup (lambda ()
                              (require 'gptel)
                              ;; gptel's backend from the registry's `chat' role (a backend of the user's own stays),
                              ;; and again once the providers running here are known
                              (require 'drgnx-ai-probe)
                              (let ((configure (lambda () (drgnx-ai-gptel-maybe-configure (lambda (id) (drgnx-ai-usable-p id 'chat))))))
                                (funcall configure)
                                (add-hook 'drgnx-ai-probe-done-hook configure))
                              (drgnx-command-define 'llm-menu :category "AI" :title "LLM Menu" :command 'gptel-menu
                                                    :doc "Model, context and options (gptel)")
                              (drgnx-command-define 'llm-send :category "AI" :title "Send to LLM" :command 'gptel-send
                                                    :doc "Send the buffer up to point, or the selection")))

(provide 'drgnx-llm)
;;; drgnx-llm.el ends here
