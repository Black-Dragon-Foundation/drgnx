;;; drgnx-tty-clipboard.el --- Module ui/terminal: copy in a terminal window reaches the local clipboard (OSC 52) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Emacs's own xterm.el sends a copy to the terminal as OSC 52 when the terminal's version answer is 203 or
;; more; it leaves the rest off.  `drgnx-tty-clip-setup' (called per terminal frame by drgnx-tty-frames.el)
;; turns it on where that test misses: tmux (always) and a kitty whose answer was under 203.  A terminal that
;; takes no OSC 52 (VTE) stays off.  The sequence travels over SSH unchanged.
;;
;; - A copy whose OSC 52 text would pass `xterm-max-cut-length' is not sent: xterm.el would warn and
;;   `sit-for' 2 seconds, which freezes a daemon.  drgnx says so once per terminal in the echo area (the text
;;   stays in the kill ring) and sends nothing.
;; - Reading the terminal's clipboard (OSC 52 `?') is off: `drgnx-tty-clipboard-read'.  A terminal that refuses
;;   it makes every yank wait; paste from other programs comes through the terminal's paste key (bracketed
;;   paste, which Emacs already reads), and `yank' brings drgnx's own last copy.
;;
;; Nothing here prompts, waits or signals.  See docs/guide/terminal.md.

;;; Code:
(require 'seq)
(require 'term/xterm)
(declare-function drgnx-tty-frame-caps "drgnx-tty-frames")
(declare-function drgnx-tty-frames-refresh-report "drgnx-tty-frames")
(declare-function drgnx-tty-frames--tty-frames "drgnx-tty-frames")
(defvar xterm-max-cut-length)

(defcustom drgnx-tty-clipboard-read nil
  "Non-nil: drgnx asks the terminal for its clipboard (OSC 52 read) when it yanks in a terminal window.
Nil: it never asks.  Most terminals refuse a read (kitty asks you every time), and a refused one makes the
yank wait 2 seconds.  Paste from other programs with the terminal's own paste key; the profile's paste
key pastes the last copy made in drgnx."
  :type 'boolean :group 'drgnx :initialize #'custom-initialize-default
  :set (lambda (sym val) (set-default sym val) (drgnx-tty-clip-read-apply)))

(defun drgnx-tty-clip--too-long-p (data)
  "Non-nil when copying DATA (a string) by OSC 52 is past `xterm-max-cut-length': the length xterm.el tests
is that of the base64 text (with the line breaks it makes for screen)."
  (let* ((screen (eq (terminal-parameter nil 'terminal-initted) 'terminal-init-screen))
         (bytes (encode-coding-string data 'utf-8-unix))
         (base-64 (if screen
                      (string-replace "\n" "\e\\\eP" (base64-encode-string bytes))
                    (base64-encode-string bytes :no-line-break))))
    (> (length base-64) xterm-max-cut-length)))

(defun drgnx-tty-clip--guard (orig type data)
  "Around `gui-backend-set-selection': a copy xterm.el would refuse (and wait 2 s about) is not handed to it.
The message comes once per terminal."
  (if (and (terminal-parameter nil 'xterm--set-selection) (not (display-graphic-p))
           (stringp data) (drgnx-tty-clip--too-long-p data))
      (unless (terminal-parameter nil 'drgnx-tty-clip-warned)
        (set-terminal-parameter nil 'drgnx-tty-clip-warned t)
        (message "too long for the terminal's clipboard (%d characters); kept in drgnx" (length data)))
    (funcall orig type data)))

(defun drgnx-tty-clip--install ()
  "Put the too-long guard on `gui-backend-set-selection' (once)."
  (advice-add 'gui-backend-set-selection :around #'drgnx-tty-clip--guard))

(defun drgnx-tty-clip--apply-read (term)
  "Make TERM's reads of the terminal's clipboard follow `drgnx-tty-clipboard-read'."
  (set-terminal-parameter term 'xterm--get-selection (and drgnx-tty-clipboard-read t)))

(defun drgnx-tty-clip-read-apply ()
  "Make the terminals already open follow `drgnx-tty-clipboard-read'."
  (when (fboundp 'drgnx-tty-frames--tty-frames)
    (dolist (f (drgnx-tty-frames--tty-frames))
      (drgnx-tty-clip--apply-read (frame-terminal f)))))

(defun drgnx-tty-clip-setup (&optional frame)
  "Set up copy and read for FRAME's terminal (default: the selected frame).  Copy: on in tmux and in a kitty
Emacs left it off for, unless it is on already; off in VTE.  The terminal's capabilities (and the terminal
report, when the answer changed) follow.  Reads follow `drgnx-tty-clipboard-read'."
  (let ((frame (or frame (selected-frame))))
    (when (frame-live-p frame)      ; the terminal can go while it is asked
      (let* ((term (frame-terminal frame))
             (caps (and (terminal-live-p term) (drgnx-tty-frame-caps frame))))
        (when (and caps (terminal-live-p term))
          (drgnx-tty-clip--install)
          (drgnx-tty-clip--apply-read term)
          (when (and (memq (plist-get caps :id) '(tmux kitty))
                     (not (terminal-parameter term 'xterm--set-selection)))
            (set-terminal-parameter term 'xterm--set-selection t)
            (if (fboundp 'drgnx-tty-frames-refresh-report)
                (drgnx-tty-frames-refresh-report frame)
              (drgnx-tty-frame-caps frame))))))))

(provide 'drgnx-tty-clipboard)
;;; drgnx-tty-clipboard.el ends here
