;;; drgnx-look.el --- Module ui/look: colour theme, zen mode -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Color Theme picks one of the installed themes (one at a time) and remembers it in modules.eld;
;; Zen mode hides the sidebar, the panel and the right dock and centres the text, and gives every
;; one of them back as it was.  See docs/modules.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-wb)

;;;; Theme

(defun drgnx-look--saved-theme () (plist-get (drgnx-modules-read-state) :theme))

(defun drgnx-look-load-theme (theme)
  "Make THEME the only theme and remember it."
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme theme t)
  (drgnx-modules-write-state (plist-put (copy-sequence (drgnx-modules-read-state)) :theme theme)))

(defun drgnx-look-choose-theme (theme)
  "Pick the colour theme (remembered for the next start)."
  (interactive (list (intern (completing-read "Color theme: " (mapcar #'symbol-name (custom-available-themes)) nil t))))
  (drgnx-look-load-theme theme))

;;;; Zen

(defvar drgnx-look-zen-width 100 "Text width in zen mode, in columns.")
(declare-function drgnx-wb-area-window "drgnx-area")
(declare-function drgnx-wb-area-hide "drgnx-area")
(declare-function drgnx-wb-area-show "drgnx-area")

(defun drgnx-look--margins (on)
  (dolist (w (seq-filter #'drgnx-signal-editor-window-p (window-list nil 'nomini)))
    (let ((m (if on (max 0 (/ (- (window-total-width w) drgnx-look-zen-width) 2)) 0)))
      (set-window-margins w m m))))

(defun drgnx-look-zen ()
  "Only the text: hide the sidebar, panel and right dock, centre the text; again to give them back."
  (interactive)
  (if-let* ((was (frame-parameter nil 'drgnx-look-zen)))
      (progn
        (set-frame-parameter nil 'drgnx-look-zen nil)
        (drgnx-look--margins nil)
        (when (plist-get was :sidebar) (drgnx-wb-show-sidebar))
        (when (fboundp 'drgnx-wb-area-show)
          (pcase-dolist (`(,key . ,area) '((:panel . panel) (:right . right)))
            (when (plist-get was key) (drgnx-wb-area-show area)))))
    (set-frame-parameter nil 'drgnx-look-zen
                         (list :on t :sidebar (drgnx-wb-sidebar-showing-p)
                               :panel (and (fboundp 'drgnx-wb-area-window) (drgnx-wb-area-window 'panel) t)
                               :right (and (fboundp 'drgnx-wb-area-window) (drgnx-wb-area-window 'right) t)))
    (drgnx-wb-hide-sidebar)
    (when (fboundp 'drgnx-wb-area-hide) (drgnx-wb-area-hide 'panel) (drgnx-wb-area-hide 'right))
    (drgnx-look--margins t)))

(drgnx-module-define 'ui/look
  :doc "Colour theme (remembered) and zen mode."
  :stage 'startup
  :setup
  (lambda ()
    (when-let* ((theme (drgnx-look--saved-theme)))
      (when (memq theme (custom-available-themes))
        (mapc #'disable-theme custom-enabled-themes)
        (load-theme theme t)))
    (drgnx-command-define 'preferences-theme :category "Preferences" :title "Color Theme"
      :command #'drgnx-look-choose-theme :menu '("Options") :doc "Pick the colour theme (remembered)")
    (drgnx-command-define 'view-zen :category "View" :title "Zen Mode" :scope 'window
      :command #'drgnx-look-zen :doc "Only the text; again to give the sidebar and panel back")))

(provide 'drgnx-look)
;;; drgnx-look.el ends here
