;;; drgnx-completion.el --- Module extra/completion: vertical lists, fuzzy matching, popups -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Minibuffer choices in a vertical list (vertico) with annotations (marginalia), matched by any
;; words in any order (orderless), and completion in code as you type (corfu, a child-frame popup
;; that the workbench leaves alone).

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-palette-frame)
(defvar corfu-auto)
(defvar corfu-auto-delay)
(defvar corfu-auto-prefix)
(defvar vertico-multiform-categories)
(defvar drgnx-palette-frame-multiform)
(declare-function vertico-multiform-mode "vertico-multiform")
(declare-function drgnx-palette-frame-delete "drgnx-palette-frame")
(declare-function drgnx-palette-frame-hide "drgnx-palette-frame")
(declare-function vertico-mode "vertico")
(declare-function marginalia-mode "marginalia")
(declare-function global-corfu-mode "corfu")

(drgnx-module-define 'extra/completion
                     :doc "Vertical minibuffer lists, any-order matching, completion popups as you type."
                     :stage 'idle :packages '(vertico orderless marginalia corfu)
                     :teardown #'drgnx-palette-frame-delete
                     :setup (lambda ()
                              (require 'vertico) (require 'orderless) (require 'marginalia) (require 'corfu)
                              (require 'vertico-multiform) (require 'vertico-buffer) (require 'drgnx-palette-frame)
                              (pcase-dolist (`(,var ,value) '((completion-styles (orderless basic))
                                                              (completion-category-overrides ((file (styles partial-completion))))
                                                              (corfu-auto t) (corfu-auto-delay 0.2) (corfu-auto-prefix 2)))
                                (drgnx-module-set var value))
                              ;; the palette (category drgnx-command) floats in its own child frame under Glitnir
                              (drgnx-module-alist-put 'vertico-multiform-categories 'drgnx-command
                                                      drgnx-palette-frame-multiform)
                              (drgnx-module-hook 'minibuffer-exit-hook palette-frame-hide ()
                                (drgnx-palette-frame-hide))
                              (vertico-mode 1)
                              (vertico-multiform-mode 1)
                              (marginalia-mode 1)
                              (global-corfu-mode 1)))

(provide 'drgnx-completion)
;;; drgnx-completion.el ends here
