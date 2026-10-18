;;; drgnx-tty-keys.el --- Module ui/terminal-keys: the kitty keyboard protocol (kkp) where modifyOtherKeys is missing -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A plain terminal cannot send C-S-p, C-` or C-.: they need a key protocol.  modifyOtherKeys (xterm, WezTerm;
;; tmux with extended-keys) is ui/terminal's (drgnx-tty-frames.el) and needs no package.  This module adds the
;; kitty keyboard protocol (kkp), through MELPA's `kkp', for terminals that have kkp but no confirmed
;; modifyOtherKeys (`drgnx-tty-mok-confirmed-p'): kitty, foot, Alacritty, Ghostty.
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
(declare-function drgnx-tty-frames-mok-trusted-p "drgnx-tty-frames")
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
  "Non-nil: terminals that have the kitty keyboard protocol but no confirmed modifyOtherKeys (kitty, foot,
Alacritty, Ghostty) get kkp, so C-S- chords arrive; C-g there interrupts a program Emacs waits for, but not busy Lisp.
Nil: kkp is never turned on; those terminals send plain keys (C-S-p arrives as C-p) and C-g always works.
Takes effect for terminal windows opened afterwards."
  :type 'boolean :group 'drgnx)

(defun drgnx-tty-keys--problem (fmt &rest args)
  (push (concat "ui/terminal-keys: " (apply #'format fmt args)) drgnx-hooks-problems))

(defun drgnx-tty-keys--kkp-wanted-p (terminal)
  "Non-nil when kkp may be turned on in TERMINAL: `drgnx-tty-use-kkp' is t, the terminal is not tmux (which does
not pass kkp), and modifyOtherKeys is not how it gets its chords.  A terminal drgnx knows is decided by its table
row (`drgnx-tty-frames-mok-trusted-p': WezTerm, xterm have it; Alacritty, Ghostty, foot, kitty do not, whatever
Emacs's DA2 test asked for); one it does not know, by whether modifyOtherKeys is asked for there."
  (and drgnx-tty-use-kkp
       (when-let* ((frame (car (frames-on-display-list terminal)))
                   (caps (drgnx-tty-frame-caps frame)))
         (let ((id (plist-get caps :id)))
           (not (or (eq id 'tmux)
                    (if (drgnx-tty-terminal id)
                        (drgnx-tty-frames-mok-trusted-p id)
                      (drgnx-tty-frames-mok-asked-p terminal))))))))

(defun drgnx-tty-keys--enable-guard (enable &rest args)
  "Around `kkp-enable-in-terminal': ask the terminal (ARGS: the terminal) only where kkp is wanted.  kkp calls
this again at every focus-in of a terminal that did not set up; a terminal declined once (terminal parameter
`drgnx-tty-kkp-declined') stays declined, so `drgnx-tty-use-kkp' changed later applies to terminal windows opened
afterwards, as its docstring says."
  (let ((terminal (or (car args) (frame-terminal))))
    (unless (terminal-parameter terminal 'drgnx-tty-kkp-declined)
      (if (condition-case err (drgnx-tty-keys--kkp-wanted-p terminal)
            (error (drgnx-tty-keys--problem "%s" (error-message-string err)) nil))
          (apply enable args)
        ;; for good only when the user's setting is the reason; transient facts (a late XTVERSION naming the
        ;; terminal) are checked again at the next focus-in
        (unless drgnx-tty-use-kkp
          (when (frames-on-display-list terminal)
            (set-terminal-parameter terminal 'drgnx-tty-kkp-declined t)))))))

(defun drgnx-tty-keys--swallow-replies ()
  "The selected frame's terminal ignores kkp's replies (CSI ? FLAGS u): after a setup drgnx popped, a late
confirmation would else type M-[ ? 5 u.  The entries go into the terminal's `input-decode-map' itself: kkp's reply
handler unregisters itself with an explicit nil on \"ESC [ ?\" before it calls the setup, which hides anything on
the map's parent.  kkp reads its own replies with `read-event', which the decode map does not touch.  Once per
terminal."
  (unless (terminal-parameter nil 'drgnx-tty-kkp-swallow)
    (dotimes (n 32)
      (define-key input-decode-map (format "\e[?%du" n) (lambda (_prompt) [])))
    (set-terminal-parameter nil 'drgnx-tty-kkp-swallow t)))

(defun drgnx-tty-keys--kkp-setup-guard (setup &rest args)
  "Around `kkp--terminal-setup' (the terminal answered kkp's question): when it fails half way — kkp 20260706.858
signals when its confirmation (CSI ? u) does not come within the wait, after it already pushed its flags — the
terminal's flags are popped (CSI < u), its keys stay plain, and the problem is recorded."
  (let ((terminal (frame-terminal)))
    (condition-case err
        (apply setup args)
      (error
       (ignore-errors
         (if (and (fboundp 'kkp--active-p) (kkp--active-p terminal))
             (kkp--terminal-teardown terminal)
           (send-string-to-terminal "\e[<u" terminal)
           (drgnx-tty-keys--swallow-replies)))
       (set-terminal-parameter terminal 'drgnx-tty-kkp nil)
       (drgnx-tty-keys--problem "kkp did not finish in %s (%s); its keys stay plain"
                                (terminal-name terminal) (error-message-string err))
       (ignore-errors (drgnx-tty-frames-refresh-report (selected-frame)))
       nil))))

(defun drgnx-tty-keys--kkp-on ()
  "`kkp-terminal-setup-complete-hook' (a frame of that terminal selected): the terminal speaks kkp now; its
capabilities and report say so."
  (set-terminal-parameter nil 'drgnx-tty-kkp t)
  ;; a failed report must not reach kkp's setup, whose guard would tear a working kkp down
  (condition-case err
      (drgnx-tty-frames-refresh-report (selected-frame))
    (error (drgnx-tty-keys--problem "report: %s" (error-message-string err)))))

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
  ;; kkp--terminal-setup is private to kkp: guarded where the pinned version has it
  (if (fboundp 'kkp--terminal-setup)
      (advice-add 'kkp--terminal-setup :around #'drgnx-tty-keys--kkp-setup-guard)
    (drgnx-tty-keys--problem "kkp--terminal-setup is missing in this kkp: a setup that cannot finish is not undone"))
  (global-kkp-mode 1))

(drgnx-module-define 'ui/terminal-keys
                     :doc "The kitty keyboard protocol (kkp) in terminals without confirmed modifyOtherKeys (kitty, Ghostty): C-S- chords."
                     :stage 'startup :packages '(kkp) :requires '(ui/terminal)
                     :setup #'drgnx-tty-keys--start)

(provide 'drgnx-tty-keys)
;;; drgnx-tty-keys.el ends here
