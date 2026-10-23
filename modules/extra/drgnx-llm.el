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
(defvar drgnx-ai--gptel-ours)
(defvar gptel-backend)
(defvar gptel-model)

(defvar drgnx-llm--before nil "(BACKEND . MODEL) gptel had before the module's setup; nil while the module is off.")

(defun drgnx-llm--configure ()
  "gptel's backend from the registry's `chat' role (a backend of the user's own stays)."
  (drgnx-ai-gptel-maybe-configure (lambda (id) (drgnx-ai-usable-p id 'chat))))

(defun drgnx-llm--teardown ()
  "gptel has the backend and model it had, unless the user chose another since."
  (when (and drgnx-llm--before (boundp 'drgnx-ai--gptel-ours) (eq gptel-backend drgnx-ai--gptel-ours))
    (setq gptel-backend (car drgnx-llm--before) gptel-model (cdr drgnx-llm--before)))
  (setq drgnx-llm--before nil))

(drgnx-module-define 'extra/llm
                     :doc "LLM Menu and Send to LLM (gptel)."
                     :stage 'idle :packages '(gptel)
                     :teardown #'drgnx-llm--teardown
                     :setup (lambda ()
                              (require 'gptel)
                              ;; gptel's backend from the registry's `chat' role (a backend of the user's own stays),
                              ;; and again once the providers running here are known
                              (require 'drgnx-ai-probe)
                              (setq drgnx-llm--before (cons gptel-backend gptel-model))
                              (drgnx-llm--configure)
                              (add-hook 'drgnx-ai-probe-done-hook #'drgnx-llm--configure)
                              ;; the gateway's address comes with the hub's token
                              (add-hook 'drgnx-hub-editor-token-hook #'drgnx-llm--configure)
                              (drgnx-command-define 'llm-menu :category "AI" :title "LLM Menu" :command 'gptel-menu
                                                    :doc "Model, context and options (gptel)")
                              (drgnx-command-define 'llm-send :category "AI" :title "Send to LLM" :command 'gptel-send
                                                    :doc "Send the buffer up to point, or the selection")))

(provide 'drgnx-llm)
;;; drgnx-llm.el ends here
