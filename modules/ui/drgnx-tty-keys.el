;;; drgnx-tty-keys.el --- Module ui/terminal-keys: C-S- chords in terminals — kkp, modifyOtherKeys; C-g still interrupts -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A plain terminal cannot send C-S-p, C-` or C-.: they need a key protocol, and this module turns one on in each
;; terminal window that has one.
;;
;; - The kitty keyboard protocol (kkp: kitty, foot, Ghostty, Alacritty; WezTerm and iTerm2 after a setting),
;;   through MELPA's `kkp' (`global-kkp-mode').  kkp asks each terminal once when it opens (CSI ? u), and drgnx
;;   bounds its wait to `drgnx-tty-frames-query-timeout'.  Once a terminal answers, `drgnx-tty-keys--kkp-on' sets
;;   the terminal parameter `drgnx-tty-kkp' and writes its report again (`drgnx-tty-frames-refresh-report').
;; - C-g: under kkp a terminal sends C-g as an escape sequence, which Emacs blocked in `call-process' never reads.
;;   kkp's `kkp-restore-legacy-keys-around-subprocesses' gives a kkp terminal its plain keys back for each call
;;   (and so for `process-file', which runs `call-process' for local files): C-g interrupts a hanging git.
;; - modifyOtherKeys (xterm; tmux with `extended-keys'): Emacs asks xterm and TERM=tmux-* for it but decodes only
;;   a few of its keys (C-tab, C-. …); `drgnx-tty-keys--decode-mok' decodes all of them (CSI 27 ; M ; K ~).
;;   Under tmux it is asked for when tmux's extended-keys is on or always, and withdrawn when it is off (tmux
;;   then sends none: the terminal is legacy, and its report says so).
;;
;; Terminals that send neither (GNOME Terminal, Ptyxis, Terminal.app, the Linux console): F1 and the palette
;; reach every command, and the report lists the keys they cannot send.  Nothing here prompts or signals in a
;; hook: errors go to `drgnx-hooks-problems'.  See docs/guide/terminal.md.

;;; Code:
(require 'drgnx-hooks)
(require 'drgnx-modules)
(require 'drgnx-tty)
(declare-function drgnx-tty-frame-caps "drgnx-tty-frames")
(declare-function drgnx-tty-frames-refresh-report "drgnx-tty-frames")
(declare-function xterm--init-modify-other-keys "term/xterm")
(declare-function global-kkp-mode "kkp")
(defvar drgnx-tty-frames-query-timeout)
(defvar kkp-restore-legacy-keys-around-subprocesses)
(defvar kkp-terminal-query-timeout)
(defvar kkp-terminal-setup-complete-hook)
(defvar kkp-terminal-teardown-complete-hook)

;;;; modifyOtherKeys

(defconst drgnx-tty-keys--mok-on "\e[>4;1m" "The request for modifyOtherKeys (xterm.el's).")
(defconst drgnx-tty-keys--mok-off "\e[>4m" "Its reset.")

(defun drgnx-tty-keys--mok-key (m k)
  "The key a terminal sends as CSI 27 ; M ; K ~: K a character code (9 TAB, 13 RET, 27 ESC, 127 DEL), M 1 plus
shift 1, meta 2, control 4.  An upper-case letter is its lower-case one with Shift (C-S-p, however it came)."
  (let ((mods (delq nil (list (and (/= 0 (logand (1- m) 1)) 'shift)
                              (and (/= 0 (logand (1- m) 2)) 'meta)
                              (and (/= 0 (logand (1- m) 4)) 'control))))
        (base (pcase k (9 'tab) (13 'return) (27 'escape) (127 'backspace) (_ k))))
    (when (and (integerp base) (<= ?A base ?Z))
      (setq base (downcase base))
      (unless (memq 'shift mods) (push 'shift mods)))
    (vector (event-convert-list (append mods (list base))))))

(defvar drgnx-tty-keys--mok-map nil "The keymap the function `drgnx-tty-keys--mok-map' returns, made once.")

(defun drgnx-tty-keys--mok-map ()
  "A keymap for `input-decode-map': every modifyOtherKeys key with Shift, Meta or Control."
  (or drgnx-tty-keys--mok-map
      (setq drgnx-tty-keys--mok-map
            (let ((map (make-sparse-keymap)))
              (dolist (m (number-sequence 2 8) map)
                (dolist (k (append '(9 13 27 127) (number-sequence 32 126)))
                  (define-key map (format "\e[27;%d;%d~" m k) (drgnx-tty-keys--mok-key m k))))))))

(defun drgnx-tty-keys--decode-mok ()
  "The selected frame's terminal decodes every modifyOtherKeys key: drgnx's map after Emacs's own (xterm.el's
decodings come first), once per terminal.  A terminal that never sends them is not changed by it."
  (unless (terminal-parameter nil 'drgnx-tty-keys-mok)
    (set-keymap-parent input-decode-map
                       (make-composed-keymap (delq nil (list (keymap-parent input-decode-map) (drgnx-tty-keys--mok-map)))))
    (set-terminal-parameter nil 'drgnx-tty-keys-mok t)))

(defun drgnx-tty-keys--tmux (frame)
  "FRAME's terminal is tmux: ask it for modifyOtherKeys when its extended-keys is on or always, withdraw the
request when it is off (tmux then sends no modifyOtherKeys: legacy keys).  When tmux's options cannot be read (a
tmux on the other side of SSH, or one that does not answer), Emacs's own choice stays."
  (let* ((term (frame-terminal frame))
         (asked (member drgnx-tty-keys--mok-on (terminal-parameter term 'tty-mode-set-strings)))
         (extended (plist-get (drgnx-tty-tmux-options (drgnx-tty-env frame)) :extended-keys)))
    (cond ((and (member extended '("on" "always")) (not asked))
           (require 'term/xterm)
           (with-selected-frame frame (xterm--init-modify-other-keys)))
          ((and (equal extended "off") asked)
           (send-string-to-terminal drgnx-tty-keys--mok-off term)
           (set-terminal-parameter term 'tty-mode-set-strings
                                   (remove drgnx-tty-keys--mok-on (terminal-parameter term 'tty-mode-set-strings)))
           (set-terminal-parameter term 'tty-mode-reset-strings
                                   (remove drgnx-tty-keys--mok-off (terminal-parameter term 'tty-mode-reset-strings)))))))

;;;; Each terminal

(defun drgnx-tty-keys-setup (&optional frame)
  "FRAME's terminal (default: the selected frame's) decodes modifyOtherKeys; under tmux, it is asked for as
tmux's extended-keys says; the terminal's report is written again.  From `tty-setup-hook', after ui/terminal's
setup.  Never prompts or signals: an error goes to `drgnx-hooks-problems'."
  (let ((frame (or frame (selected-frame))))
    (when (and (frame-live-p frame) (not (display-graphic-p frame))
               (not (equal (terminal-name (frame-terminal frame)) "initial_terminal")))
      (condition-case err
          (progn
            (with-selected-frame frame (drgnx-tty-keys--decode-mok))
            (when (eq (plist-get (drgnx-tty-frame-caps frame) :id) 'tmux)
              (drgnx-tty-keys--tmux frame))
            (drgnx-tty-frames-refresh-report frame))
        (error (push (format "ui/terminal-keys: %s" (error-message-string err)) drgnx-hooks-problems))))))

(defun drgnx-tty-keys--kkp-on ()
  "`kkp-terminal-setup-complete-hook' (a frame of that terminal selected): the terminal speaks kkp now; its
capabilities and report say so."
  (set-terminal-parameter nil 'drgnx-tty-kkp t)
  (drgnx-tty-frames-refresh-report (selected-frame)))

(defun drgnx-tty-keys--kkp-off ()
  "`kkp-terminal-teardown-complete-hook' (suspend, the terminal's last frame closed): no kkp there now."
  (set-terminal-parameter nil 'drgnx-tty-kkp nil))

(defun drgnx-tty-keys--start ()
  "The module's setup: kkp on, its question bounded, C-g covered; each terminal's keys set up."
  (require 'kkp)
  ;; both are read when the mode turns on
  (setq kkp-terminal-query-timeout drgnx-tty-frames-query-timeout
        kkp-restore-legacy-keys-around-subprocesses t)
  (add-hook 'kkp-terminal-setup-complete-hook #'drgnx-tty-keys--kkp-on)
  (add-hook 'kkp-terminal-teardown-complete-hook #'drgnx-tty-keys--kkp-off)
  (add-hook 'tty-setup-hook #'drgnx-tty-keys-setup 90)
  (global-kkp-mode 1)
  ;; a terminal Emacs set up before this module ran (`emacs -nw')
  (when (terminal-parameter nil 'terminal-initted)
    (drgnx-tty-keys-setup)))

(drgnx-module-define 'ui/terminal-keys
                     :doc "C-S- chords in terminals: the kitty keyboard protocol (kkp) or modifyOtherKeys; C-g still interrupts."
                     :stage 'startup :packages '(kkp) :requires '(ui/terminal)
                     :setup #'drgnx-tty-keys--start)

(provide 'drgnx-tty-keys)
;;; drgnx-tty-keys.el ends here
