;;; drgnx-esc.el --- Esc Esc opens the tile switcher -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-esc-mode' (module ui/tiles): a second Esc within `drgnx-esc-double-tap' of a first one that cancelled
;; something opens Switch Tile (wb/drgnx-switcher.el); a single Esc does what it did, at once.  Three parts:
;; - `drgnx-esc--note' (post-command-hook) records the command and the time of every Esc, whoever ran it: Close Pane's
;;   and quick help's maps sit in front of this one (`drgnx-modal-front-alists'), so their runs are seen only there,
;;   and a second Esc that such a map ran as a cancel opens the switcher there.
;; - `drgnx-esc--map', an emulation map at the front (before the modal engine's), binds `<escape>' to `drgnx-esc': it
;;   runs what `<escape>' means without this map at once, or opens the switcher when the last Esc was a cancel
;;   (`drgnx-esc-cancel-commands') within the window.  A buffer that sends keys to a process
;;   (`drgnx-esc-process-modes') gets its own binding of `<escape>' every time, ahead of evil's.
;; - An `input-decode-map' filter for a lone Esc where it is the bare Meta prefix (the Emacs profile; the VS Code one
;;   in terminal frames): it never reads an event.  Where `<escape>' is bound and in a process buffer it decides at
;;   once.  (F6 then Esc is `C-<escape>' through the fallback layer's F6 prefix, which reads its key itself.)
;;   Else it waits up to the window (`sit-for'): a second Esc decodes as `drgnx-esc-double' (bound here to the
;;   switcher), any other key stays ESC and that key (`Esc x' is M-x), and no key leaves the ESC alone.  In a terminal
;;   the decoder goes on with the terminal's sequences, and Alt+Esc (ESC ESC with no gap) is a double.
;; A third Esc within the window after the double tap opened the switcher closes it and runs `keyboard-escape-quit'.
;; See docs/develop/core.md, "The Esc double tap".

;;; Code:
(require 'cl-lib)
(require 'drgnx-timer)
(require 'drgnx-modal)
(require 'drgnx-switcher)

(defcustom drgnx-esc-double-tap 0.3
  "Seconds within which a second Esc after a cancel opens Switch Tile; nil turns the double tap off (`C-<escape>'
and the profile keys still open it)."
  :type '(choice (const :tag "Off" nil) number) :group 'drgnx)

(defcustom drgnx-esc-cancel-commands
  '(keyboard-escape-quit keyboard-quit evil-force-normal-state evil-normal-state drgnx-work-map-escape drgnx-close-pane)
  "Commands that make an Esc a cancel: a second Esc after one opens Switch Tile.  `drgnx-close-pane' counts only
when it closed nothing."
  :type '(repeat symbol) :group 'drgnx)

(defcustom drgnx-esc-process-modes '(drgnx-term-mode term-mode eat-mode vterm-mode comint-mode)
  "Modes (and those derived from them) whose buffers send keys to a process: Esc there is always theirs."
  :type '(repeat symbol) :group 'drgnx)

(defvar drgnx-esc--last nil "(TIME . COMMAND): the command the last Esc ran and when it ended, or nil.")

(defvar drgnx-esc--on nil
  "Non-nil while `drgnx-esc-mode' is: the front map and the decode filter are on.  Bound to nil, the decode map is
the terminal's own (the fallback layer's F6 reads its key through it).")

(defvar drgnx-esc--waiting nil
  "Non-nil while the decode filter waits for a second Esc (what a test waits for before it sends one).")

(defvar drgnx-close--closed)

;;;; Which Esc was a cancel

(defun drgnx-esc--note ()
  "On `post-command-hook': record the command and the time of an Esc, whoever ran it.  An Esc a front map ran
\(Close Pane with nothing to close) that is a cancel and the second of a double tap opens the switcher here."
  (when (memq last-command-event '(escape ?\e))
    (if (and (drgnx-esc--cancel-p this-command) (drgnx-esc--double-p) (not (drgnx-esc--process-buffer-p))
             (not (drgnx-switcher-open-p)))
        (drgnx-esc-open)
      (setq drgnx-esc--last (cons (drgnx-timer-now) this-command)))))

(defun drgnx-esc--cancel-p (cmd)
  "Non-nil when CMD, the command of an Esc, cancelled something."
  (and (memq cmd drgnx-esc-cancel-commands)
       (not (and (eq cmd 'drgnx-close-pane) (bound-and-true-p drgnx-close--closed)))))

(defun drgnx-esc--double-p ()
  "Non-nil when an Esc now is the second of a double tap: the last Esc was a cancel, within the window.  An Esc a
keyboard macro replays is never one: its keys are not taps (Vim's `A ! Esc j' replayed right after it was recorded
left insert state, it did not open the switcher)."
  (and drgnx-esc-double-tap drgnx-esc--last (not executing-kbd-macro)
       (< (- (drgnx-timer-now) (car drgnx-esc--last)) drgnx-esc-double-tap)
       (drgnx-esc--cancel-p (cdr drgnx-esc--last))))

(defun drgnx-esc--process-buffer-p ()
  "Non-nil in a buffer that sends keys to a process."
  (and (apply #'derived-mode-p drgnx-esc-process-modes) t))

;;;; The switcher

(defun drgnx-esc-open ()
  "Open Switch Tile from a double tap: a third Esc within the window closes it and runs `keyboard-escape-quit'."
  (setq drgnx-esc--last nil)
  (drgnx-switcher-open)
  (when (and drgnx-esc-double-tap (drgnx-switcher-open-p))
    (drgnx-switcher-quit-until (+ (drgnx-timer-now) drgnx-esc-double-tap))))

(defun drgnx-esc-double ()
  "The event `drgnx-esc-double' (Esc Esc where Esc is the Meta prefix): open Switch Tile."
  (interactive)
  (if drgnx-esc-double-tap (drgnx-esc-open) (keyboard-escape-quit)))

;;;; The front map (every profile where `<escape>' arrives as itself)

(defun drgnx-esc--underneath ()
  "What `<escape>' runs here without the front map: in a process buffer, the buffer's own binding."
  (let ((drgnx-esc--on nil))
    (if (drgnx-esc--process-buffer-p)
        (or (lookup-key (current-local-map) [escape]) (key-binding [escape] t))
      (key-binding [escape] t))))

(defun drgnx-esc ()
  "Esc: what it does without this map, at once; the second of a double tap after a cancel opens Switch Tile."
  (interactive)
  (let ((cmd (drgnx-esc--underneath)))
    (cond ((and (not (drgnx-esc--process-buffer-p)) (not (minibufferp)) (drgnx-esc--double-p))
           (setq this-command 'drgnx-esc-double)
           (drgnx-esc-open))
          ((commandp cmd) (setq this-command cmd) (call-interactively cmd))
          ;; unbound: what Emacs does with an unbound `<escape>', the Meta prefix
          (t (push (cons 'no-record ?\e) unread-command-events)))))

(defvar drgnx-esc--map (list 'keymap (cons 'escape #'drgnx-esc) (cons 'drgnx-esc-double #'drgnx-esc-double))
  "The front map: `<escape>' and the decoded double tap.")

(defvar drgnx-esc--emulation (list (cons 'drgnx-esc--on drgnx-esc--map))
  "The `emulation-mode-map-alists' entry of `drgnx-esc--map'.")

;;;; The decode filter (where Esc is the bare Meta prefix)

(defun drgnx-esc--bound-p ()
  "Non-nil when `<escape>' has a binding in the active maps, the front map left out."
  (let ((b (let ((drgnx-esc--on nil)) (key-binding [escape] t))))
    (and b (not (numberp b)) t)))

(defun drgnx-esc--double-map (map)
  "MAP (the decode map that was there, or nil) with a second Esc decoding as `drgnx-esc-double'."
  (let ((m (list 'keymap (cons ?\e [drgnx-esc-double]) (cons 'escape [drgnx-esc-double]))))
    (if (keymapp map) (make-composed-keymap m map) m)))

(defun drgnx-esc--reading-p ()
  "Non-nil while a key sequence is being read and its last key is the Esc being decoded.  A lookup that goes through
the decode map otherwise (a `define-key' or `lookup-key' of a sequence that starts with ESC) gets the map as it was."
  (let ((keys (this-single-command-keys)))
    (and (> (length keys) 0) (memq (aref keys (1- (length keys))) '(?\e escape)) t)))

(defun drgnx-esc--decode (map lone tty)
  "The decoding of an Esc: LONE (`[escape]' or MAP itself) when Esc stays what it is, else the double map.
TTY: in a terminal, where bytes already waiting (an escape sequence, Alt+key, Alt+Esc) go on through MAP first."
  (cond ((or (not drgnx-esc--on) (not drgnx-esc-double-tap) (not (drgnx-esc--reading-p))
             (bound-and-true-p evil-local-mode) (minibufferp) (drgnx-esc--process-buffer-p))
         lone)
        ((and tty (input-pending-p)) (drgnx-esc--double-map map))
        ((drgnx-esc--bound-p) [escape])
        ((let ((drgnx-esc--waiting t)) (sit-for drgnx-esc-double-tap t)) lone)
        (t (drgnx-esc--double-map map))))

(defun drgnx-esc--gui-filter (_prompt)
  "`input-decode-map''s `<escape>' in a graphical frame."
  (drgnx-esc--decode nil [escape] nil))

(defun drgnx-esc--tty-filter (map)
  "The filter of `input-decode-map''s ESC in a terminal: MAP is the terminal's escape-sequence map that was there."
  (drgnx-esc--decode map map t))

(defvar drgnx-esc--terminals (make-hash-table :test #'eq :weakness 'key)
  "Terminal → (KEY . OLD): the decode map's key the filter took and what was there (nil: nothing).")

(defun drgnx-esc--install (&optional frame)
  "Put the decode filter in FRAME's terminal (default the selected frame's), once."
  (with-selected-frame (or frame (selected-frame))
    (unless (gethash (frame-terminal) drgnx-esc--terminals)
      (let* ((key (if (display-graphic-p) [escape] [?\e])) (old (lookup-key input-decode-map key)))
        (puthash (frame-terminal) (cons key old) drgnx-esc--terminals)
        (define-key input-decode-map key (if (display-graphic-p) #'drgnx-esc--gui-filter
                                           `(menu-item "" ,old :filter drgnx-esc--tty-filter)))))))

(defun drgnx-esc--uninstall (frame)
  "Give FRAME's terminal its decode map's Esc back (no entry at all when there was none)."
  (with-selected-frame frame
    (when-let* ((saved (gethash (frame-terminal) drgnx-esc--terminals)))
      (if (cdr saved) (define-key input-decode-map (car saved) (cdr saved))
        (define-key input-decode-map (car saved) nil t))
      (remhash (frame-terminal) drgnx-esc--terminals))))

;;;; The mode

(define-minor-mode drgnx-esc-mode
  "Esc Esc after a cancel opens Switch Tile (see the Commentary)."
  :global t :group 'drgnx
  (if drgnx-esc-mode
      (progn
        ;; its place (after Close Pane's and quick help's maps, before the engine's) is `drgnx-modal-order-alists''s
        (add-to-list 'emulation-mode-map-alists 'drgnx-esc--emulation)
        (drgnx-modal-order-alists)
        (setq drgnx-esc--on t drgnx-esc--last nil)
        (add-hook 'post-command-hook #'drgnx-esc--note)
        (add-hook 'after-make-frame-functions #'drgnx-esc--install)
        (dolist (f (frame-list)) (unless (frame-parent f) (drgnx-esc--install f))))
    (setq emulation-mode-map-alists (delq 'drgnx-esc--emulation emulation-mode-map-alists)
          drgnx-esc--on nil drgnx-esc--last nil)
    (remove-hook 'post-command-hook #'drgnx-esc--note)
    (remove-hook 'after-make-frame-functions #'drgnx-esc--install)
    (dolist (f (frame-list)) (drgnx-esc--uninstall f))))

(provide 'drgnx-esc)
;;; drgnx-esc.el ends here
