;;; drgnx-smooth.el --- Module ui/smooth: smooth scrolling on graphical frames -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Pixel-precise scrolling with a touchpad or a wheel: ultra-scroll when it is installed (faster; add `ultra-scroll'
;; to packages.eld), else Emacs's own `pixel-scroll-precision-mode'.  Terminal frames scroll by lines as always.
;; See docs/guide/editing.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(declare-function ultra-scroll-mode "ultra-scroll")
(defvar ultra-scroll-mode)
(defvar pixel-scroll-precision-mode)

(defun drgnx-smooth--ultra-p () (and (require 'ultra-scroll nil t) (fboundp 'ultra-scroll-mode)))

(defun drgnx-smooth--setup ()
  "Smooth scrolling, on a graphical display only."
  (when (display-graphic-p)
    (if (drgnx-smooth--ultra-p) (ultra-scroll-mode 1) (pixel-scroll-precision-mode 1))))

(defun drgnx-smooth-toggle ()
  "Smooth scrolling off or on."
  (interactive)
  (if (drgnx-smooth--ultra-p)
      (ultra-scroll-mode (if (bound-and-true-p ultra-scroll-mode) -1 1))
    (pixel-scroll-precision-mode (if (bound-and-true-p pixel-scroll-precision-mode) -1 1))))

(drgnx-module-define 'ui/smooth
                     :doc "Smooth, pixel-precise scrolling on graphical frames (ultra-scroll when installed, else Emacs's own)."
                     :stage 'first-frame
                     :setup (lambda ()
                              (drgnx-smooth--setup)
                              (drgnx-command-define 'toggle-smooth-scrolling :category "View" :title "Toggle Smooth Scrolling"
                                                    :command #'drgnx-smooth-toggle :doc "Pixel-precise scrolling off or on")))

(provide 'drgnx-smooth)
;;; drgnx-smooth.el ends here
