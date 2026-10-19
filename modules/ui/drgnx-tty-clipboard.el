;;; drgnx-tty-clipboard.el --- Module ui/terminal: copy in a terminal window reaches the local clipboard (OSC 52) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Emacs's own xterm.el sends a copy to the terminal as OSC 52 when the terminal's version answer is 203 or
;; more; it leaves the rest off.  `drgnx-tty-clip-setup' (called per terminal frame by drgnx-tty-frames.el)
;; turns it on where that test misses: tmux (as below) and a kitty whose answer was under 203.  A terminal that
;; takes no OSC 52 (VTE) stays off.  The sequence travels over SSH unchanged.
;;
;; - Inside tmux (Task 10) a copy goes out one of two ways, whichever tmux allows.  `set-clipboard on`: the plain
;;   OSC 52.  Else, with `allow-passthrough on`: the same sequence in tmux's DCS passthrough (`ESC P tmux ;`, every
;;   ESC doubled, `ESC \'), which tmux hands to the terminal as it is.  With neither, nothing is sent and the copy
;;   stays in drgnx (the terminal's capabilities say so).  tmux's options are read when a terminal window opens.
;;   Either way drgnx builds the sequence itself: under TERM=screen, tmux's old default, xterm.el would wrap it in
;;   GNU screen's DCS, which tmux throws away.  A tmux drgnx cannot ask (TERM=tmux-* over SSH) gets the plain one.
;; - A copy whose OSC 52 text would pass `xterm-max-cut-length' is not sent: xterm.el would warn and
;;   `sit-for' 2 seconds, which freezes a daemon.  drgnx says so once per terminal in the echo area (the text
;;   stays in the kill ring) and sends nothing.
;; - Reading the terminal's clipboard (OSC 52 `?') is off: `drgnx-tty-clipboard-read'.  A terminal that refuses
;;   it makes every yank wait; paste from other programs comes through the terminal's paste key (bracketed
;;   paste, which Emacs already reads), and `yank' brings drgnx's own last copy.
;;
;; Nothing here prompts or signals (tmux is asked for its options, 1 s at most).  See docs/guide/terminal.md.

;;; Code:
(require 'seq)
(require 'term/xterm)
(declare-function drgnx-tty-frame-caps "drgnx-tty-frames")
(declare-function drgnx-tty-frames-refresh-report "drgnx-tty-frames")
(declare-function drgnx-tty-frames--tty-frames "drgnx-tty-frames")
(declare-function drgnx-tty-frames--tmux-options "drgnx-tty-frames")
(declare-function xterm--selection-char "term/xterm")
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
  (let* ((screen (and (not (terminal-parameter nil 'drgnx-tty-clip-tmux))   ; tmux gets the plain sequence
                      (eq (terminal-parameter nil 'terminal-initted) 'terminal-init-screen)))
         (bytes (encode-coding-string data 'utf-8-unix))
         (base-64 (if screen
                      (string-replace "\n" "\e\\\eP" (base64-encode-string bytes))
                    (base64-encode-string bytes :no-line-break))))
    (> (length base-64) xterm-max-cut-length)))

(defun drgnx-tty-clip--send-to-tmux (type data)
  "Send DATA to the terminal around tmux as OSC 52: plain, or in tmux's DCS passthrough when the terminal
parameter `drgnx-tty-clip-tmux' is `wrap' (every ESC of the sequence doubled)."
  (let ((osc (concat "\e]52;" (xterm--selection-char type) ";"
                     (base64-encode-string (encode-coding-string data 'utf-8-unix) :no-line-break) "\a")))
    (send-string-to-terminal
     (if (eq (terminal-parameter nil 'drgnx-tty-clip-tmux) 'wrap)
         (concat "\ePtmux;" (string-replace "\e" "\e\e" osc) "\e\\")
       osc))))

(defun drgnx-tty-clip--guard (orig type data)
  "Around `gui-backend-set-selection': a copy xterm.el would refuse (and wait 2 s about) is not handed to it.
The message comes once per terminal.  In tmux the sequence is built here (`drgnx-tty-clip--send-to-tmux')."
  (if (and (terminal-parameter nil 'xterm--set-selection) (not (display-graphic-p)) (stringp data))
      (cond ((drgnx-tty-clip--too-long-p data)
             (unless (terminal-parameter nil 'drgnx-tty-clip-warned)
               (set-terminal-parameter nil 'drgnx-tty-clip-warned t)
               (message "too long for the terminal's clipboard (%d characters); kept in drgnx" (length data))))
            ((terminal-parameter nil 'drgnx-tty-clip-tmux) (drgnx-tty-clip--send-to-tmux type data))
            (t (funcall orig type data)))
    (funcall orig type data)))

(defun drgnx-tty-clip--install ()
  "Put the too-long guard on `gui-backend-set-selection' (once)."
  (advice-add 'gui-backend-set-selection :around #'drgnx-tty-clip--guard))

(defun drgnx-tty-clip-off ()
  "Copy and reads as Emacs had them, in every terminal (only what drgnx turned on goes), and the guard off:
ui/terminal's teardown.  The guard was put on from a frame's setup, which nothing records."
  (advice-remove 'gui-backend-set-selection #'drgnx-tty-clip--guard)
  (dolist (term (terminal-list))
    (when (terminal-live-p term)
      (when (terminal-parameter term 'drgnx-tty-clip-set)
        (set-terminal-parameter term 'drgnx-tty-clip-set nil)
        (set-terminal-parameter term 'xterm--set-selection nil))
      (when (terminal-parameter term 'drgnx-tty-clip-read)
        (set-terminal-parameter term 'drgnx-tty-clip-read nil)
        (set-terminal-parameter term 'xterm--get-selection nil))
      (dolist (param '(drgnx-tty-clip-tmux drgnx-tty-clip-warned))
        (when (terminal-parameter term param) (set-terminal-parameter term param nil))))))

(defun drgnx-tty-clip--apply-read (term)
  "Make TERM's reads of the terminal's clipboard follow `drgnx-tty-clipboard-read': on while it is non-nil,
and off again only when drgnx turned them on (terminal parameter `drgnx-tty-clip-read'), so a getSelection
the user turned on through `xterm-extra-capabilities' stays."
  (cond (drgnx-tty-clipboard-read
         (unless (terminal-parameter term 'xterm--get-selection)
           (set-terminal-parameter term 'drgnx-tty-clip-read t)
           (set-terminal-parameter term 'xterm--get-selection t)))
        ((terminal-parameter term 'drgnx-tty-clip-read)
         (set-terminal-parameter term 'drgnx-tty-clip-read nil)
         (set-terminal-parameter term 'xterm--get-selection nil))))

(defun drgnx-tty-clip-read-apply ()
  "Make the terminals already open follow `drgnx-tty-clipboard-read'."
  (when (fboundp 'drgnx-tty-frames--tty-frames)
    (dolist (f (drgnx-tty-frames--tty-frames))
      (drgnx-tty-clip--apply-read (frame-terminal f)))))

(defun drgnx-tty-clip--tmux-mode (options)
  "How a copy leaves tmux, from OPTIONS (`drgnx-tty-tmux-options'): `plain' (set-clipboard on, or a tmux that
cannot be asked), `wrap' (allow-passthrough on or all), else nil: tmux lets no program's copy through."
  (cond ((null options) 'plain)
        ((equal (plist-get options :set-clipboard) "on") 'plain)
        ((member (plist-get options :allow-passthrough) '("on" "all")) 'wrap)))

(defun drgnx-tty-clip--set-copy (term id options)
  "Turn copy on or off for TERM of kind ID.  tmux follows OPTIONS (`drgnx-tty-clip--tmux-mode'); kitty is
turned on when Emacs left it off.  What Emacs or the user turned on stays; what drgnx turned on (terminal
parameter `drgnx-tty-clip-set') goes again when tmux stops allowing it.  Non-nil when copy changed."
  (let ((mode (and (eq id 'tmux) (drgnx-tty-clip--tmux-mode options)))
        (on (terminal-parameter term 'xterm--set-selection)))
    (set-terminal-parameter term 'drgnx-tty-clip-tmux mode)
    (cond ((and (memq id '(tmux kitty)) (not on) (or mode (eq id 'kitty)))
           (set-terminal-parameter term 'drgnx-tty-clip-set t)
           (set-terminal-parameter term 'xterm--set-selection t)
           t)
          ((and (eq id 'tmux) on (not mode) (terminal-parameter term 'drgnx-tty-clip-set))
           (set-terminal-parameter term 'drgnx-tty-clip-set nil)
           (set-terminal-parameter term 'xterm--set-selection nil)
           t))))

(defun drgnx-tty-clip-setup (&optional frame)
  "Set up copy and read for FRAME's terminal (default: the selected frame).  Copy: on in a kitty Emacs left it
off for, unless it is on already; off in VTE; in tmux as its options allow (see the Commentary).  The terminal's
capabilities (and the terminal report, when the answer changed) follow.  Reads follow
`drgnx-tty-clipboard-read'."
  (let ((frame (or frame (selected-frame))))
    (when (frame-live-p frame)      ; the terminal can go while it is asked
      (let* ((term (frame-terminal frame))
             (caps (and (terminal-live-p term) (drgnx-tty-frame-caps frame))))
        (when (and caps (terminal-live-p term))
          (drgnx-tty-clip--install)
          (drgnx-tty-clip--apply-read term)
          (when (drgnx-tty-clip--set-copy
                 term (plist-get caps :id)
                 (and (eq (plist-get caps :id) 'tmux) (drgnx-tty-frames--tmux-options frame 'tmux)))
            (if (fboundp 'drgnx-tty-frames-refresh-report)
                (drgnx-tty-frames-refresh-report frame)
              (drgnx-tty-frame-caps frame))))))))

(provide 'drgnx-tty-clipboard)
;;; drgnx-tty-clipboard.el ends here
