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
(declare-function drgnx-palette-frame-minibuffer-rows "drgnx-palette-frame")
(declare-function vertico-mode "vertico")
(declare-function marginalia-mode "marginalia")
(declare-function global-corfu-mode "corfu")
(declare-function drgnx-wb-row-box "drgnx-wb")
(defvar vertico--index)

(defconst drgnx-completion-row-inset 6
  "Logical pixels between a candidate row's fill and the list's sides (palette.html `.row', the sidebar's rows).")

(defvar drgnx-completion--lead nil "(PX . STRING): the left inset of a candidate row at PX pixels, made once per size.")

(defun drgnx-completion--row (cand current)
  "CAND, a candidate line as vertico formats it (ending in a newline; CURRENT: it is the current one, in
`vertico-current'), drawn as a row: on a graphical frame an inset of `drgnx-completion-row-inset' before it, outside
the fill; when CURRENT, the text and a stretch to the inset on the right in the current face with the row's rounded
inside box (`drgnx-wb-row-box': one box run, which the stretch ends), and a plain newline, so nothing fills past the
row.  A terminal shows the text as it was."
  (let* ((px (drgnx-px drgnx-completion-row-inset))
         (lead (cdr (if (eql px (car drgnx-completion--lead)) drgnx-completion--lead
                      (setq drgnx-completion--lead
                            (cons px (propertize " " 'display `(when (display-graphic-p) space :width (,px))
                                                 'invisible t)))))))
    (if (not current)
        (concat lead cand)
      (let* ((body (substring cand 0 -1))
             (box (list :box (drgnx-wb-row-box)))
             (end (propertize " " 'display `(when (display-graphic-p) space :align-to (- right (,px))) 'invisible t)))
        (add-face-text-property 0 (length end) 'vertico-current t end)
        (add-face-text-property 0 (length body) box t body)
        (add-face-text-property 0 (length end) box t end)
        (concat lead body end "\n")))))

(defun drgnx-completion--format-candidate (orig cand prefix suffix index start)
  "`vertico--format-candidate' (ORIG with CAND PREFIX SUFFIX INDEX START) drawn as a row (`drgnx-completion--row')."
  (drgnx-completion--row (funcall orig cand prefix suffix index start) (= index vertico--index)))

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
                              ;; the rows: UI font, 24 px in the echo area (the palette's own are 32 px)
                              (drgnx-module-hook 'minibuffer-setup-hook minibuffer-rows ()
                                (drgnx-palette-frame-minibuffer-rows))
                              ;; the prompt and the matches in the accent; the current row is the selection
                              (drgnx-module-face-spec 'minibuffer-prompt '((t :inherit drgnx-accent)))
                              (drgnx-module-face-spec 'vertico-current '((t :inherit drgnx-selected)))
                              ;; the current row as one rounded inset run (the sidebar's rows); every row inset alike
                              (advice-add 'vertico--format-candidate :around #'drgnx-completion--format-candidate)
                              (dolist (face '(orderless-match-face-0 orderless-match-face-1 orderless-match-face-2
                                                                     orderless-match-face-3))
                                (drgnx-module-face-spec face '((t :inherit drgnx-accent :weight semibold))))
                              (vertico-mode 1)
                              (vertico-multiform-mode 1)
                              (marginalia-mode 1)
                              (global-corfu-mode 1)))

(provide 'drgnx-completion)
;;; drgnx-completion.el ends here
