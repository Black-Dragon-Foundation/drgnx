;;; drgnx-tty-frames.el --- Module ui/terminal: terminal windows — what each terminal can do, EDITOR frames -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A terminal frame (`emacsclient -t', `emacs -nw') is a workbench window like a graphical one
;; (`drgnx-frames--workbench-p').  This module looks after each one, from `tty-setup-hook' and
;; `server-after-make-frame-hook':
;;
;; - `drgnx-tty-frame-caps': what the terminal can do — which terminal it is (from the client's own
;;   environment, never the daemon's, and its answer to XTVERSION), how its keys arrive (kkp, modifyOtherKeys
;;   or legacy), OSC 52 copy, colours, the mouse.  The terminal is asked once, for at most
;;   `drgnx-tty-frames-query-timeout' seconds, and never again for another client of the same terminal
;;   (`drgnx-tty-frames--cache').  Kept in the terminal parameter `drgnx-tty-caps'.
;; - The mouse: `xterm-mouse-mode' (SGR reports) on while `drgnx-tty-mouse' is t, started from a terminal frame's
;;   setup, never for a graphical frame; Toggle Mouse in Terminal Windows.  The terminal's own selection is then
;;   Shift+drag.
;; - `drgnx-tty-frames-write-report': terminal-report.eld in the state dir — each terminal's capabilities and
;;   the active profile's keys it cannot send — for the doctor and the key sheet.
;; - EDITOR frames: `emacsclient -t FILE' (git's editor) shows the editor only; closing the file's tab, or
;;   C-x #, ends the edit and the client returns, as `code --wait' does.
;;
;; Nothing here prompts or signals: it runs in the daemon's hooks; errors go to `drgnx-hooks-problems'.
;; See docs/guide/terminal.md.

;;; Code:
(require 'seq)
(require 'drgnx-hooks)
(require 'drgnx-modules)
(require 'drgnx-paths)
(require 'drgnx-registry)
(require 'drgnx-tty)
(require 'drgnx-wb)
(declare-function drgnx-wb-area-hide "drgnx-area")
(declare-function drgnx-chrome-apply "drgnx-chrome")
(declare-function server-buffer-done "server")
(declare-function xterm--query "term/xterm")
(declare-function xterm--read-event-for-query "term/xterm")
(defvar xterm-query-timeout)
(defvar server-buffer-clients)
(defvar drgnx-keys-last)
(defvar xterm-mouse-mode)
(declare-function xterm-mouse-mode "xt-mouse")
(declare-function turn-on-xterm-mouse-tracking-on-terminal "xt-mouse")
(declare-function turn-off-xterm-mouse-tracking-on-terminal "xt-mouse")

(defvar drgnx-tty-frames-query-timeout 0.2
  "Seconds to wait for a terminal's answer to XTVERSION (a late answer is still taken off the input).")

(defvar drgnx-tty-frames--cache (make-hash-table :test #'equal)
  "Capabilities by terminal (`drgnx-tty-frames--cache-key'): a terminal is asked once, not once per client.")

;;;; What a terminal can do

(defun drgnx-tty-frames--env (frame)
  "FRAME's client environment (`drgnx-tty-env'): a client frame's own, this Emacs's for a frame without
one (`emacs -nw'; `getenv' of such a frame finds nothing)."
  (drgnx-tty-env (and (frame-parameter frame 'environment) frame)))

(defun drgnx-tty-frames--cache-key (env)
  "The cache key of a terminal with ENV: its id, the terminal around it and its version as the environment
names them, and TERM; nil when the environment does not name the terminal (two of those cannot be told apart
without asking)."
  (let ((id (drgnx-tty-identify env)))
    (unless (eq (plist-get id :id) 'unknown)
      (list (plist-get id :id) (plist-get id :outer) (plist-get id :version) (cdr (assoc "TERM" env))))))

(defun drgnx-tty-frames--xtversion-handler ()
  "Read the rest of an XTVERSION answer (`ESC P > | TEXT ESC \\') into the terminal parameter
`drgnx-tty-xtversion'."
  (let ((text "") chr)
    (while (and (setq chr (xterm--read-event-for-query)) (not (eq chr ?\e)))
      (setq text (concat text (string chr))))
    (when (eq chr ?\e) (xterm--read-event-for-query))   ; the final backslash
    (set-terminal-parameter nil 'drgnx-tty-xtversion (concat "\eP>|" text "\e\\"))))

(defun drgnx-tty-frames--ask (frame)
  "FRAME's terminal's answer to XTVERSION, or nil: asked once, waiting `drgnx-tty-frames-query-timeout'
seconds at most; a later answer is taken off the input by Emacs's xterm.el.  Not on the Linux console."
  (unless (member (tty-type (frame-terminal frame)) '("linux" "dumb"))
    (require 'term/xterm)
    (with-selected-frame frame
      (let ((xterm-query-timeout drgnx-tty-frames-query-timeout))
        (xterm--query "\e[>0q" '(("\eP>|" . drgnx-tty-frames--xtversion-handler))))
      (terminal-parameter nil 'drgnx-tty-xtversion))))

(defun drgnx-tty-frames--keys (term)
  "How TERM's keys arrive: `kkp' when the ui/terminal-keys module turned it on (terminal parameter
`drgnx-tty-kkp'), `mok' when Emacs's xterm.el turned modifyOtherKeys on, else `legacy'."
  (cond ((terminal-parameter term 'drgnx-tty-kkp) 'kkp)
        ((member "\e[>4;1m" (terminal-parameter term 'tty-mode-set-strings)) 'mok)
        (t 'legacy)))

(defun drgnx-tty-frames--compute (frame env answer)
  (let* ((term (frame-terminal frame))
         (id (drgnx-tty-identify env answer))
         (row (drgnx-tty-terminal (plist-get id :id))))
    (list :id (plist-get id :id) :outer (plist-get id :outer) :version (plist-get id :version)
          :keys (drgnx-tty-frames--keys term)
          :osc52 (and (or (terminal-parameter term 'xterm--set-selection) (plist-get row :osc52)) t)
          :colors (display-color-cells frame)
          :mouse (if row (and (plist-get row :mouse) t) t))))

(defun drgnx-tty-frame-caps (&optional frame)
  "What FRAME's terminal can do: (:id :outer :version :keys kkp|mok|legacy :osc52 BOOL :colors N :mouse BOOL).
Kept in the terminal parameter `drgnx-tty-caps'; a terminal another client already asked is not asked again."
  (let* ((frame (or frame (selected-frame)))
         (term (frame-terminal frame)))
    (or (terminal-parameter term 'drgnx-tty-caps)
        (let* ((env (drgnx-tty-frames--env frame))
               (key (drgnx-tty-frames--cache-key env))
               (caps (or (and key (gethash key drgnx-tty-frames--cache))
                         (drgnx-tty-frames--compute frame env (drgnx-tty-frames--ask frame)))))
          (when key (puthash key caps drgnx-tty-frames--cache))
          (set-terminal-parameter term 'drgnx-tty-caps caps)
          caps))))

;;;; The report

(defun drgnx-tty-frames--report-file () (expand-file-name "terminal-report.eld" (drgnx-state-dir)))

(defun drgnx-tty-frames-write-report (frame)
  "Add FRAME's terminal to terminal-report.eld in the state dir: (:terminals ((TTY . (:caps CAPS :unsendable
KEYS :seen TIME)) …)), newest first, one entry per terminal device (two clients never replace each other's);
:unsendable the active key profile's keys this terminal cannot send."
  (let* ((caps (drgnx-tty-frame-caps frame))
         (file (drgnx-tty-frames--report-file))
         (key (terminal-name (frame-terminal frame)))
         (keys (seq-uniq (delq nil (mapcar (lambda (b) (plist-get b :key))
                                           (plist-get (bound-and-true-p drgnx-keys-last) :bindings)))))
         (old (plist-get (ignore-errors (with-temp-buffer (insert-file-contents file) (read (current-buffer))))
                         :terminals))
         (entry (list :caps caps :unsendable (drgnx-tty-unsendable keys (plist-get caps :keys))
                      :seen (format-time-string "%FT%T%z"))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (let ((print-length nil) (print-level nil))
        (prin1 (list :terminals (cons (cons key entry) (assoc-delete-all key (copy-sequence old))))
               (current-buffer))
        (insert "\n")))))

;;;; The mouse

(defcustom drgnx-tty-mouse t
  "Non-nil: the mouse works in terminal windows (clicks, wheel, dragging dividers, the Explorer, tabs, menus).
The terminal's own selection and paste are then Shift+drag (Option+drag in iTerm2).  Nil: the terminal keeps the
mouse.  Toggle Mouse in Terminal Windows changes it."
  :type 'boolean :group 'drgnx :initialize #'custom-initialize-default
  :set (lambda (sym val) (set-default sym val) (drgnx-tty-frames-mouse-apply)))

(defun drgnx-tty-frames--tty-frames ()
  "The live terminal frames of terminals Emacs set up (not the daemon's initial terminal)."
  (seq-filter (lambda (f) (and (frame-live-p f) (not (display-graphic-p f))
                               (not (equal (terminal-name (frame-terminal f)) "initial_terminal"))))
              (frame-list)))

(defun drgnx-tty-frames-mouse-apply ()
  "Make the terminals follow `drgnx-tty-mouse': mouse reports on in the terminals that can send them while it
is t, off in all of them when it is nil (Emacs 31 turns the mode on by itself).  A session without a terminal
frame is left alone: a graphical frame never gets `xterm-mouse-mode'.  Never asks a terminal anything."
  (when-let* ((frames (drgnx-tty-frames--tty-frames)))
    (let ((wanted (and drgnx-tty-mouse
                       (seq-filter (lambda (f) (let ((caps (terminal-parameter (frame-terminal f) 'drgnx-tty-caps)))
                                                 (or (null caps) (plist-get caps :mouse))))
                                   frames))))
      (require 'xt-mouse)
      (if wanted
          (unless xterm-mouse-mode (xterm-mouse-mode 1))
        (when xterm-mouse-mode (xterm-mouse-mode -1)))
      (dolist (f frames)
        (if (memq f wanted)
            (turn-on-xterm-mouse-tracking-on-terminal (frame-terminal f))
          (turn-off-xterm-mouse-tracking-on-terminal (frame-terminal f)))))))

(defun drgnx-tty-frames-toggle-mouse ()
  "Turn the mouse in terminal windows on or off; run interactively, the choice is saved."
  (interactive)
  (let ((val (not drgnx-tty-mouse)))
    (if (called-interactively-p 'any)
        (customize-save-variable 'drgnx-tty-mouse val)
      (customize-set-variable 'drgnx-tty-mouse val))
    (message "Mouse in terminal windows: %s" (if val "on" "off"))))

;;;; EDITOR frames

(defun drgnx-tty-frames--visit ()
  "`server-visit-hook': a new terminal client that asked for files (`emacsclient -t FILE') is an editor
frame.  A frame that already showed (one reused by a later `emacsclient FILE') stays as it is."
  (let ((frame (selected-frame)))
    (when (and (not (display-graphic-p frame)) (processp (frame-parameter frame 'client))
               (not (frame-parameter frame 'drgnx-tty-shown)))
      (set-frame-parameter frame 'drgnx-tty-editor-only t))))

(defun drgnx-tty-frames--editor-only (frame)
  "FRAME shows the editor only: no sidebar, panel or right dock."
  (with-selected-frame frame
    (drgnx-wb-hide-sidebar)
    (when (fboundp 'drgnx-wb-area-hide)
      (drgnx-wb-area-hide 'panel)
      (drgnx-wb-area-hide 'right))))

(defun drgnx-tty-frames--tab-closed (window buffer)
  "After a tab closes: in an editor frame, closing the tab of a file its client waits for ends the edit
(`server-buffer-done'); the client returns once it has no file left."
  (when (and (window-live-p window) (buffer-live-p buffer)
             (frame-parameter (window-frame window) 'drgnx-tty-editor-only)
             (memq (frame-parameter (window-frame window) 'client)
                   (buffer-local-value 'server-buffer-clients buffer)))
    (server-buffer-done buffer)))

;;;; Each terminal frame

(defun drgnx-tty-frames-setup (&optional frame)
  "Look after FRAME (default: the selected frame) when it is a terminal frame: its capabilities and the
report, asked once per terminal; an editor frame shows the editor only.  Never prompts or signals."
  (let ((frame (or frame (selected-frame))))
    (condition-case err
        (when (and (frame-live-p frame) (not (display-graphic-p frame))
                   (not (equal (terminal-name (frame-terminal frame)) "initial_terminal")))
          (unless (terminal-parameter (frame-terminal frame) 'drgnx-tty-caps)
            (drgnx-tty-frame-caps frame)
            (drgnx-tty-frames-write-report frame))
          (drgnx-tty-frames-mouse-apply)
          (when (frame-parameter frame 'drgnx-tty-editor-only)
            (drgnx-tty-frames--editor-only frame)))
      (error (push (format "ui/terminal: %s" (error-message-string err)) drgnx-hooks-problems)))))

(defun drgnx-tty-frames--after-make-frame ()
  "`server-after-make-frame-hook' (the client's frame is selected): set it up and give its windows their tabs
now — a client showing the buffer the daemon's editor already showed (*scratch*) is no change the workbench's
bus would see, and its tab line would stay empty.  The frame has shown now."
  (let ((frame (selected-frame)))
    (drgnx-tty-frames-setup frame)
    (unless (display-graphic-p frame)
      (set-frame-parameter frame 'drgnx-tty-shown t)
      (condition-case err
          (when (fboundp 'drgnx-chrome-apply) (drgnx-chrome-apply frame t))
        (error (push (format "ui/terminal: %s" (error-message-string err)) drgnx-hooks-problems))))))

(drgnx-module-define 'ui/terminal
                     :doc "Terminal windows: what each terminal can do, asked once; the mouse; editor-only EDITOR frames."
                     :stage 'startup
                     :setup (lambda ()
                              (drgnx-command-define 'terminal-toggle-mouse :category "Terminal"
                                                    :title "Toggle Mouse in Terminal Windows" :scope 'window
                                                    :command #'drgnx-tty-frames-toggle-mouse
                                                    :doc "Mouse clicks, wheel and drags in terminal windows on or off")
                              (add-hook 'tty-setup-hook #'drgnx-tty-frames-setup)
                              (add-hook 'server-visit-hook #'drgnx-tty-frames--visit)
                              (add-hook 'server-after-make-frame-hook #'drgnx-tty-frames--after-make-frame)
                              (advice-add 'drgnx-chrome--close :after #'drgnx-tty-frames--tab-closed)
                              ;; a terminal Emacs set up before this module ran (`emacs -nw' sets its own up after init)
                              (when (terminal-parameter nil 'terminal-initted)
                                (drgnx-tty-frames-setup))))

(provide 'drgnx-tty-frames)
;;; drgnx-tty-frames.el ends here
