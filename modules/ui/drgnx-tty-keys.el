;;; drgnx-tty-keys.el --- Module ui/terminal-keys: the kitty keyboard protocol (kkp) where modifyOtherKeys is missing -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A plain terminal cannot send C-S-p, C-` or C-.: they need a key protocol.  modifyOtherKeys (xterm, WezTerm,
;; Ghostty; tmux with extended-keys) is ui/terminal's (drgnx-tty-frames.el) and needs no package.  This module
;; adds the kitty keyboard protocol (kkp), through MELPA's `kkp', for terminals that have kkp but not
;; modifyOtherKeys: kitty, foot, Alacritty.
;;
;; - modifyOtherKeys is preferred wherever it works (`drgnx-tty-keys--kkp-wanted-p'): with it C-g stays a plain
;;   byte, so it interrupts busy Lisp too.  Under kkp C-g is an escape sequence: it interrupts only while Emacs
;;   waits for a program, thanks to kkp's `kkp-restore-legacy-keys-around-subprocesses' (set here), which gives
;;   the terminal its plain keys back for each `call-process' (and `process-file', which runs it).  The caps say
;;   :c-g waits for such a terminal.  `drgnx-tty-use-kkp' nil gives kkp up: those terminals are legacy then.
;; - kkp asks each terminal once when it opens (CSI ? u); drgnx bounds its wait to
;;   `drgnx-tty-frames-query-timeout'.  Once a terminal answers, `drgnx-tty-keys--kkp-on' sets the terminal
;;   parameter `drgnx-tty-kkp' and writes its report again (`drgnx-tty-frames-refresh-report').
;; - A setup kkp cannot finish (its confirmation does not come in time on a slow link) is undone
;;   (`drgnx-tty-keys--kkp-setup-guard'): the terminal's flags are popped, its keys stay plain, the problem is
;;   recorded.
;;
;; Nothing here prompts or signals in a hook: errors go to `drgnx-hooks-problems'.  See docs/guide/terminal.md.

;;; Code:
(require 'drgnx-hooks)
(require 'drgnx-modules)
(require 'drgnx-tty)
(declare-function drgnx-tty-frame-caps "drgnx-tty-frames")
(declare-function drgnx-tty-frames-mok-asked-p "drgnx-tty-frames")
(declare-function drgnx-tty-frames-refresh-report "drgnx-tty-frames")
(declare-function global-kkp-mode "kkp")
(declare-function kkp--active-p "kkp")
(declare-function kkp--terminal-teardown "kkp")
(defvar drgnx-tty-frames-query-timeout)
(defvar kkp-restore-legacy-keys-around-subprocesses)
(defvar kkp-terminal-query-timeout)
(defvar kkp-terminal-setup-complete-hook)
(defvar kkp-terminal-teardown-complete-hook)

(defcustom drgnx-tty-use-kkp t
  "Non-nil: terminals that have the kitty keyboard protocol but not modifyOtherKeys (kitty, foot, Alacritty)
get kkp, so C-S- chords arrive; C-g there interrupts a program Emacs waits for, but not busy Lisp.
Nil: kkp is never turned on; those terminals send plain keys (C-S-p arrives as C-p) and C-g always works.
Takes effect for terminal windows opened afterwards."
  :type 'boolean :group 'drgnx)

(defun drgnx-tty-keys--problem (fmt &rest args)
  (push (concat "ui/terminal-keys: " (apply #'format fmt args)) drgnx-hooks-problems))

(defun drgnx-tty-keys--kkp-wanted-p (terminal)
  "Non-nil when kkp may be turned on in TERMINAL: `drgnx-tty-use-kkp' is t, the terminal is not tmux (which does
not pass kkp), modifyOtherKeys is not asked for there (by Emacs's xterm.el), and the terminal's row does not
list modifyOtherKeys (WezTerm, Ghostty, xterm: ui/terminal asks for it)."
  (and drgnx-tty-use-kkp
       (when-let* ((frame (car (frames-on-display-list terminal)))
                   (caps (drgnx-tty-frame-caps frame)))
         (not (or (eq (plist-get caps :id) 'tmux)
                  (drgnx-tty-frames-mok-asked-p terminal)
                  (plist-get (drgnx-tty-terminal (plist-get caps :id)) :mok))))))

(defun drgnx-tty-keys--enable-guard (enable &rest args)
  "Around `kkp-enable-in-terminal': ask the terminal (ARGS: the terminal) only where kkp is wanted."
  (let ((terminal (or (car args) (frame-terminal))))
    (when (condition-case err (drgnx-tty-keys--kkp-wanted-p terminal)
            (error (drgnx-tty-keys--problem "%s" (error-message-string err)) nil))
      (apply enable args))))

(defun drgnx-tty-keys--kkp-setup-guard (setup &rest args)
  "Around `kkp--terminal-setup' (the terminal answered kkp's question): when it fails half way — kkp 20260706.858
signals when its confirmation (CSI ? u) does not come within the wait, after it already pushed its flags — the
terminal's flags are popped (CSI < u), its keys stay plain, and the problem is recorded."
  (let ((terminal (frame-terminal)))
    (condition-case err
        (apply setup args)
      (error
       (ignore-errors
         (if (kkp--active-p terminal)
             (kkp--terminal-teardown terminal)
           (send-string-to-terminal "\e[<u" terminal)))
       (set-terminal-parameter terminal 'drgnx-tty-kkp nil)
       (drgnx-tty-keys--problem "kkp did not finish in %s (%s); its keys stay plain"
                                (terminal-name terminal) (error-message-string err))
       (ignore-errors (drgnx-tty-frames-refresh-report (selected-frame)))
       nil))))

(defun drgnx-tty-keys--kkp-on ()
  "`kkp-terminal-setup-complete-hook' (a frame of that terminal selected): the terminal speaks kkp now; its
capabilities and report say so."
  (set-terminal-parameter nil 'drgnx-tty-kkp t)
  (drgnx-tty-frames-refresh-report (selected-frame)))

(defun drgnx-tty-keys--kkp-off ()
  "`kkp-terminal-teardown-complete-hook' (suspend, the terminal's last frame closed): no kkp there now."
  (set-terminal-parameter nil 'drgnx-tty-kkp nil))

(defun drgnx-tty-keys--start ()
  "The module's setup: kkp on where it is wanted, its question bounded, C-g covered for programs."
  (require 'kkp)
  ;; both are read when the mode turns on
  (setq kkp-terminal-query-timeout drgnx-tty-frames-query-timeout
        kkp-restore-legacy-keys-around-subprocesses t)
  (add-hook 'kkp-terminal-setup-complete-hook #'drgnx-tty-keys--kkp-on)
  (add-hook 'kkp-terminal-teardown-complete-hook #'drgnx-tty-keys--kkp-off)
  (advice-add 'kkp-enable-in-terminal :around #'drgnx-tty-keys--enable-guard)
  (advice-add 'kkp--terminal-setup :around #'drgnx-tty-keys--kkp-setup-guard)
  (global-kkp-mode 1))

(drgnx-module-define 'ui/terminal-keys
                     :doc "The kitty keyboard protocol (kkp) in terminals without modifyOtherKeys (kitty): C-S- chords."
                     :stage 'startup :packages '(kkp) :requires '(ui/terminal)
                     :setup #'drgnx-tty-keys--start)

(provide 'drgnx-tty-keys)
;;; drgnx-tty-keys.el ends here
