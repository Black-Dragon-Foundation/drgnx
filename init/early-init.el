;;; early-init.el --- drgnx: early startup -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Used with `emacs --init-directory <checkout>/init' (and by the harness's config=drgnx).
;; Packages are not activated: drgnx manages them itself (M5).

;;; Code:
(setq load-prefer-newer t              ; a stale .elc (drgnx build) never shadows newer source
      package-enable-at-startup nil
      inhibit-startup-screen t
      frame-resize-pixelwise t)
(push '(tool-bar-lines . 0) default-frame-alist)

;;; early-init.el ends here
