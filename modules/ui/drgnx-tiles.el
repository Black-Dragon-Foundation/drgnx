;;; drgnx-tiles.el --- Module ui/tiles: the tile switcher -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Module ui/tiles: Switch Tile (`tile-switcher', wb/drgnx-switcher.el), a letter on every tile of every window.  Its
;; setup defines the command; its timers are owned by the module; its teardown closes the switcher and deletes the pooled
;; card frames.  See docs/guide/workbench.md, "Switching tiles".

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-switcher)

(defun drgnx-tiles--setup ()
  (drgnx-command-define 'tile-switcher :category "View" :title "Switch Tile…"
                        :command #'drgnx-switcher-open
                        :doc "A letter on every tile of every window: type one to go there, Shift and one to swap with it"))

(defun drgnx-tiles--teardown ()
  (drgnx-switcher-close)
  (drgnx-switcher-delete-pool))

(drgnx-module-define 'ui/tiles
                     :doc "Switch Tile: a letter on every tile of every window, on every monitor; a letter goes there, Shift and a letter swaps."
                     :stage 'startup :requires '(core/workbench)
                     :setup #'drgnx-tiles--setup
                     :teardown #'drgnx-tiles--teardown)

(provide 'drgnx-tiles)
;;; drgnx-tiles.el ends here
