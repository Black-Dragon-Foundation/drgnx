;;; drgnx-frame-kind.el --- What a frame is: graphical, terminal, child, the daemon's initial one -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The one frame classifier.  `drgnx-state-frame-kind' answers for any frame; the workbench state
;; store (wb/drgnx-state.el) keeps a record only for workbench frames, `gui' and `tty'
;; (`drgnx-state-workbench-frame-p').  Safe in batch and in a daemon: it reads, never writes.
;; See docs/develop/core.md, "The workbench state store".

;;; Code:

(defun drgnx-state-frame-kind (frame)
  "What FRAME is: `gui', `tty', `child', `initial' or `other'; nil for a dead frame (or not a frame).
In this order: a frame with a parent is `child' (posframes, quick help's card, Emacs 31's terminal child
frames); the frame of the initial terminal (a daemon's, or a GUI Emacs's before its first frame) is
`initial' — but `tty' in batch Emacs, so batch tests have a workbench frame; a minibuffer-only frame is
`other'; a graphical frame is `gui'; anything else is `tty'.
It allocates only the terminal's name (`terminal-name' makes a string), so the observer asks it only for a
frame it has no record of; `frame-parameter' would copy all of the frame's parameters."
  (when (and (framep frame) (frame-live-p frame))
    (cond ((frame-parent frame) 'child)
          ((equal (terminal-name (frame-terminal frame)) "initial_terminal") (if noninteractive 'tty 'initial))
          ((eq (frame-root-window frame) (minibuffer-window frame)) 'other)  ; a minibuffer-only frame
          ((display-graphic-p frame) 'gui)
          (t 'tty))))

(defun drgnx-state-workbench-frame-p (frame)
  "Non-nil if FRAME is a workbench frame: a live `gui' or `tty' frame (`drgnx-state-frame-kind')."
  (memq (drgnx-state-frame-kind frame) '(gui tty)))

(provide 'drgnx-frame-kind)
;;; drgnx-frame-kind.el ends here
