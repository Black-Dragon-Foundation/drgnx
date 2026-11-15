;;; drgnx-agent-panel-header.el --- The agent panel's header window (library of tools/agent-panel) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Above the transcript: the hub's view `agent-panel-top/SESSION' (the header row with the lens and the pin, the chips
;; and the strip of step types) in a buffer of its own, `*drgnx agent: SESSION* header', held in Sjá like the
;; transcript.  The right area shows it as the panel's companion above (`drgnx-agent-panel--companions'), fitted to its
;; rows (`drgnx-wb-area-fit-companions', again after each draw), with the area's tab row as its header line; it never
;; scrolls, so the transcript scrolls under it.  Its keys are the panel's (its mode map's parent), and a click on the
;; lens, the pin or a pill runs the panel's dispatcher (`drgnx-agent-panel-act') on the session's state: the header is
;; a companion of the panel's buffer (`drgnx-agent-panel--companion-sync'), which owns the state.
;; Loaded by tools/agent-panel (drgnx-agent-panel.el); defines no module.  See docs/guide/agent-panel.md.

;;; Code:
(require 'drgnx-view)

(defvar drgnx-agent-panel--session)
(defvar drgnx-agent-panel-mode-map)
(defvar drgnx-agent-companion--main)
(defvar drgnx-view-patch-twin-of)
(declare-function drgnx-agent-panel--main-of "drgnx-agent-panel-composer" (buffer))
(declare-function drgnx-agent-panel--companion-sync "drgnx-agent-panel-composer" (main))
(declare-function drgnx-view-env-register "drgnx-view-env" (view buffer &optional resubscribe headless))
(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))
(declare-function drgnx-wb-area-fit-companions "drgnx-area" (area &optional frame))

(defvar-local drgnx-agent-companion--header nil "In a panel's buffer: its header, once made.")

(defvar drgnx-agent-panel-header-mode-map (make-sparse-keymap)
  "Keys of the panel's header: the panel's own (its parent, set when a header is made: this file loads before the
panel's mode is defined).")

(define-derived-mode drgnx-agent-panel-header-mode special-mode "Agent header"
  "The agent panel's header: the hub's header row, chips and strip, above the transcript."
  (set-keymap-parent drgnx-agent-panel-header-mode-map drgnx-agent-panel-mode-map)
  (setq-local truncate-lines t cursor-type nil scroll-margin 0)
  (face-remap-add-relative 'default 'drgnx-ui-text)
  (add-hook 'drgnx-view-sja-drawn-functions #'drgnx-agent-panel-header--refit nil t))

(defun drgnx-agent-panel-header--refit (&rest _)
  "The header's rows changed: each area window that shows it above a panel is fitted to them again."
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (when-let* (((window-parameter w 'drgnx-area-part)) (area (window-parameter w 'drgnx-role)))
      (drgnx-wb-area-fit-companions area (window-frame w)))))

(defun drgnx-agent-panel-header--twin-setup ()
  "In the header's buffer for another display class: a companion of the same panel."
  (when-let* ((main (and (buffer-live-p drgnx-view-patch-twin-of)
                         (buffer-local-value 'drgnx-agent-companion--main drgnx-view-patch-twin-of))))
    (drgnx-agent-panel--companion-sync main)))

(defun drgnx-agent-panel-header--twin (class)
  "The header's buffer in display CLASS (`drgnx-view-patch-twin-function'): the generic twin of its rows."
  (require 'drgnx-view-env)
  (drgnx-view-env-twin class '("drgnx-agent-panel-") #'drgnx-agent-panel-header--twin-setup))

(defun drgnx-agent-panel-header--main-killed ()
  "`kill-buffer-hook' of a panel's buffer: its header goes with it."
  (when (buffer-live-p drgnx-agent-companion--header) (kill-buffer drgnx-agent-companion--header)))

(defun drgnx-agent-panel--header-of (buffer)
  "The header of BUFFER's panel (BUFFER a panel, a companion or a twin), made when there is none; nil when BUFFER
belongs to no panel.  What the area shows above the transcript."
  (when-let* ((main (drgnx-agent-panel--main-of buffer)))
    (with-current-buffer main
      (if (buffer-live-p drgnx-agent-companion--header) drgnx-agent-companion--header
        (let ((h (get-buffer-create (format "%s header" (buffer-name main))))
              (view (concat "agent-panel-top/" drgnx-agent-panel--session)))
          (setq drgnx-agent-companion--header h)
          (add-hook 'kill-buffer-hook #'drgnx-agent-panel-header--main-killed nil t)
          (with-current-buffer h
            (drgnx-agent-panel-header-mode)
            (drgnx-agent-panel--companion-sync main)
            (drgnx-view-patch-attach view "unshown" :sja t)
            (setq-local drgnx-view-patch-twin-function #'drgnx-agent-panel-header--twin)
            (require 'drgnx-view-env)
            ;; the look is the transcript's (the hub reads a top view's look as its transcript view's): nothing to send
            ;; again here on a reconnect
            (drgnx-view-env-register view h))
          h)))))

(provide 'drgnx-agent-panel-header)
;;; drgnx-agent-panel-header.el ends here
