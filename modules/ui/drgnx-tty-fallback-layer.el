;;; drgnx-tty-fallback-layer.el --- Module ui/terminal: the fallback layer for terminals that cannot send C-S- chords -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of ui/terminal (modules/ui/drgnx-tty-frames.el calls it once a terminal's caps are known).  A legacy
;; terminal (GNOME Terminal, Ptyxis, Terminal.app, the Linux console), and tmux at modifyOtherKeys level 1 for the
;; chords it folds, gets three things; a kkp or modifyOtherKeys terminal and a graphical frame get none:
;;
;; - Alt+Shift with the key: each chord's ALT (core/drgnx-tty-fallback.el) is decoded in that terminal's own
;;   `input-decode-map', and at key time it becomes the chord only while the Alt+Shift key does nothing in the
;;   buffer (`drgnx-tty-fallback--decode'): a mode that binds M-F keeps it.
;; - `drgnx-tty-chord-prefix' (F6) then the key, always: a `key-translation-map' entry that reads the next key
;;   (showing Ctrl+Shift+… while it waits) and returns its chord; elsewhere it returns F6 unchanged.
;; - One hint per kind of terminal, ever (remembered in terminal-report.eld), never a prompt.
;; Nothing here prompts or signals in a hook; see docs/guide/terminal.md, "Legacy terminals: Alt+Shift and F6".

;;; Code:
(require 'seq)
(require 'drgnx-hooks)
(require 'drgnx-tty)
(require 'drgnx-tty-fallback)
(declare-function drgnx-tty-frames-refresh-report "drgnx-tty-frames")
(declare-function drgnx-tty-frames--tty-frames "drgnx-tty-frames")
(declare-function drgnx-tty-frames--update-report "drgnx-tty-frames")

;;;; Alt+Shift: per terminal

(defun drgnx-tty-fallback--bytes (alt)
  "The bytes a legacy terminal sends for ALT (\"M-F\"): ESC and the character.  Signals for anything but Alt with
a character key."
  (let ((ev (aref (key-parse alt) 0)))
    (unless (and (integerp ev) (/= 0 (logand ev ?\M-\0)) (<= 32 (logand ev (lognot ?\M-\0)) 126))
      (error "%s is not Alt with a character key" alt))
    (string ?\e (logand ev (lognot ?\M-\0)))))

(defun drgnx-tty-fallback--frame-of (term)
  "A live frame on terminal TERM, or nil."
  (seq-find (lambda (f) (eq (frame-terminal f) term)) (frame-list)))

(defun drgnx-tty-fallback-remove (term)
  "Take the fallback layer off terminal TERM: its Alt+Shift keys come out of its `input-decode-map' (an entry
someone else changed since stays), and the prefix key passes there again."
  (when-let* ((installed (terminal-parameter term 'drgnx-tty-fallback-installed))
              (frame (drgnx-tty-fallback--frame-of term)))
    (with-selected-frame frame
      (pcase-dolist (`(,bytes . ,ours) installed)
        (when (eq (lookup-key input-decode-map bytes) ours)
          (define-key input-decode-map bytes nil t)))))
  (set-terminal-parameter term 'drgnx-tty-fallback-installed nil)
  (set-terminal-parameter term 'drgnx-tty-fallback-table nil)
  (set-terminal-parameter term 'drgnx-tty-fallback nil))

(defun drgnx-tty-fallback--wanted-p (frame caps)
  "Non-nil when FRAME (with CAPS) gets the layer: the setting is on, it is a terminal frame, and its keys are
legacy or modifyOtherKeys with folded chords (tmux at level 1).  Never kkp, plain modifyOtherKeys, or a graphical
frame."
  (and drgnx-tty-fallback caps (frame-live-p frame) (not (display-graphic-p frame))
       (not (equal (terminal-name (frame-terminal frame)) "initial_terminal"))   ; a daemon's, or batch Emacs's
       (or (eq (plist-get caps :keys) 'legacy)
           (and (eq (plist-get caps :keys) 'mok) (plist-get caps :folded)))))

(defun drgnx-tty-fallback-install (frame &optional caps)
  "Give FRAME's terminal the fallback layer when it needs it (`drgnx-tty-fallback--wanted-p'), from CAPS (default
its terminal parameter `drgnx-tty-caps'); take it off otherwise (kkp turned on later).  Rebuilt from the active
profile each time.  Returns non-nil when the layer is on.  Never prompts: the hint is a message."
  (let* ((term (frame-terminal frame))
         (caps (or caps (terminal-parameter term 'drgnx-tty-caps))))
    (drgnx-tty-fallback-remove term)
    (when (drgnx-tty-fallback--wanted-p frame caps)
      (let ((table (drgnx-tty-fallback-for-terminal (drgnx-tty-fallback-active-table) caps))
            installed)
        ;; the prefix and the terminal's state first: whatever happens below, F6 works and what was installed
        ;; can be taken off
        (drgnx-tty-fallback--bind-prefix)
        (set-terminal-parameter term 'drgnx-tty-fallback-table table)
        (set-terminal-parameter term 'drgnx-tty-fallback t)
        (unwind-protect
            (with-selected-frame frame
              (pcase-dolist (`(,chord . ,row) table)
                (when-let* ((alt (plist-get row :alt))
                            (bytes (ignore-errors (drgnx-tty-fallback--bytes alt)))   ; Alt+character only
                            ((let ((d (lookup-key input-decode-map bytes))) (or (null d) (numberp d)))))   ; never over another decoding
                  (let ((ours (lambda (_prompt) (drgnx-tty-fallback--decode alt chord))))
                    (define-key input-decode-map bytes ours)
                    (push (cons bytes ours) installed)))))
          (set-terminal-parameter term 'drgnx-tty-fallback-installed installed))
        (when table (drgnx-tty-fallback--hint frame caps))   ; nothing to say where every chord arrives
        t))))

;;;; The prefix: global, active on terminals with the layer

(defvar drgnx-tty-fallback--prefix-bound nil
  "(KEY . PREVIOUS): the prefix key bound in `key-translation-map' and what was there before.")

(defun drgnx-tty-fallback--unbind-prefix ()
  (pcase drgnx-tty-fallback--prefix-bound
    (`(,key . ,prev)
     (when (eq (lookup-key key-translation-map key) #'drgnx-tty-fallback--prefix)
       (if prev (define-key key-translation-map key prev) (define-key key-translation-map key nil t)))))
  (setq drgnx-tty-fallback--prefix-bound nil))

(defun drgnx-tty-fallback--bind-prefix ()
  "Bind `drgnx-tty-chord-prefix' in `key-translation-map' (once; again when the setting changed)."
  (let ((key (key-parse drgnx-tty-chord-prefix)))
    (unless (equal (car drgnx-tty-fallback--prefix-bound) key)
      (drgnx-tty-fallback--unbind-prefix)
      (let ((prev (lookup-key key-translation-map key)))
        (setq drgnx-tty-fallback--prefix-bound (cons key (and (not (numberp prev)) prev)))
        (define-key key-translation-map key #'drgnx-tty-fallback--prefix)))))

(defun drgnx-tty-fallback--decoded (seq)
  "What this terminal decodes SEQ (raw events) to: a key vector, a keymap while SEQ is the start of one, or nil."
  (let ((d (lookup-key input-decode-map seq)))
    (if (or (vectorp d) (keymapp d)) d
      (let ((f (lookup-key local-function-key-map seq)))
        (and (or (vectorp f) (keymapp f)) f)))))

(defun drgnx-tty-fallback--read (prompt)
  "The next key, read with PROMPT in the echo area, decoded as the terminal sent it: an escape sequence (F6,
Shift+Tab) through `input-decode-map' and `local-function-key-map', ESC and a key as Alt with it.  `quit' for C-g;
nil for ESC alone, and for anything that is not one key — a mouse report, a paste, a focus report: what was read
of it goes back to the input, in order, for Emacs to decode whole with the rest."
  (let* ((ev (let ((inhibit-quit t)) (prog1 (read-event prompt) (setq quit-flag nil)))))
    (cond ((eq ev ?\C-g) 'quit)
          ((eq ev ?\e)
           (let ((seq (vector ev)) next)
             (while (and (keymapp (drgnx-tty-fallback--decoded seq)) (setq next (read-event nil nil 0.1)))
               (setq seq (vconcat seq (vector next))))
             (let ((d (drgnx-tty-fallback--decoded seq)))
               (cond ((and (vectorp d) (= (length d) 1)) (aref d 0))
                     ((and (= (length seq) 2) (integerp (aref seq 1))) (event-convert-list (list 'meta (aref seq 1))))
                     ((> (length seq) 1)
                      (setq unread-command-events (append seq unread-command-events))
                      nil)))))
          ((or (integerp ev) (symbolp ev)) ev)
          (t (push ev unread-command-events) nil))))

(defun drgnx-tty-fallback--chord (event table)
  "The chord for EVENT, the key after the prefix: the TABLE row whose prefix form ends in it, else Ctrl with it
\(Ctrl+Shift for a letter or Space, whose Ctrl alone a terminal sends; Alt on Enter or Backspace is Shift;
Shift+Tab is Ctrl+Shift+Tab)."
  (let ((row (seq-find (lambda (r) (let ((p (key-parse (or (plist-get (cdr r) :prefix) ""))))
                                     (and (= (length p) 2) (equal (aref p 1) event))))
                       table)))
    (if row (aref (key-parse (car row)) 0)
      (let* ((mods (event-modifiers event)) (base (event-basic-type event))
             (meta (and (memq 'meta mods) '(meta)))
             (char (and (integerp event) (logand event (lognot ?\M-\0)))))   ; RET, TAB, DEL, C-@ before Emacs names them
        (cond ((eq base 'backtab) (event-convert-list '(control shift tab)))
              ((memq char '(13 127))
               (event-convert-list (append (if meta '(control shift) '(control)) (list (if (= char 13) 'return 'backspace)))))
              ((eq char 9) (event-convert-list (append meta '(control tab))))
              ((eq char 0) (event-convert-list (append meta '(control ?\s))))   ; Ctrl+Space arrives as C-@
              ((and (integerp base) (or (<= ?a base ?z) (eq base ?\s)) (not (memq 'control mods)))
               (event-convert-list (append meta (list 'control 'shift base))))
              ((memq 'control mods) event)
              (t (event-convert-list (append mods (list 'control base)))))))))

(defun drgnx-tty-fallback--prefix (_prompt)
  "`key-translation-map' for the prefix key: on a terminal with the layer, read the next key and return its chord
\(F6 p → C-S-p, F6 . → C-., F6 RET → C-<return>; the prefix twice → the prefix; C-g → C-g, which quits a pending
prefix too; ESC, or no key → nothing); elsewhere the prefix key unchanged."
  (let ((term (frame-terminal (selected-frame)))
        (key (key-parse drgnx-tty-chord-prefix)))
    (if (not (and drgnx-tty-fallback (terminal-parameter term 'drgnx-tty-fallback)))
        key
      (let ((ev (drgnx-tty-fallback--read "Ctrl+Shift+…")))
        (message nil)
        (cond ((eq ev 'quit) [?\C-g])
              ((null ev) [])
              ((equal (vector ev) key) key)
              (t (vector (drgnx-tty-fallback--chord ev (terminal-parameter term 'drgnx-tty-fallback-table)))))))))

;;;; The hint

(defun drgnx-tty-fallback--show-hint (frame id)
  "The hint for FRAME, a terminal of kind ID, when it is due: said and remembered in terminal-report.eld
\(:hinted) unless a terminal of that kind was told before, or FRAME's terminal lost the layer meanwhile — kkp's
answer comes after the frame is set up, so a kitty is legacy for that moment."
  (when (and (frame-live-p frame) (terminal-parameter (frame-terminal frame) 'drgnx-tty-fallback))
    (let (fresh)
      (condition-case err   ; a report that cannot be written costs the hint, never the layer
          (drgnx-tty-frames--update-report
           (lambda (data)
             (let ((hinted (and (proper-list-p (plist-get data :hinted)) (plist-get data :hinted))))
               (unless (memq id hinted)
                 (setq fresh t)
                 (plist-put data :hinted (append hinted (list id)))))))
        (error (setq fresh nil)
               (push (format "ui/terminal: fallback hint: %s" (error-message-string err)) drgnx-hooks-problems)))
      (when fresh
        (with-selected-frame frame (message "%s" (drgnx-tty-fallback-hint-text)))))))

(defun drgnx-tty-fallback--hint (frame caps)
  "Once per kind of terminal (CAPS's :id), ever: say how to type the keys it cannot send.  Remembered in
terminal-report.eld (:hinted); `drgnx-tty-fallback-hint' nil says nothing.  Shown a moment after the frame
appears (the server's own message would cover it, and kkp's answer may still turn the layer off), as a message:
never a prompt (`drgnx-tty-fallback--show-hint')."
  (when (and drgnx-tty-fallback-hint (fboundp 'drgnx-tty-frames--update-report))
    (run-with-timer 0.5 nil #'drgnx-tty-fallback--show-hint frame (or (plist-get caps :id) 'unknown))))

;;;; Rebuilding

(defun drgnx-tty-fallback-apply (&rest _)
  "Rebuild the layer on every terminal drgnx set up, from the active profile and the settings (after a profile
switch, keys.eld, `drgnx-tty-fallback' or `drgnx-tty-chord-prefix' changed); their reports follow.  Asks no
terminal anything."
  (setq drgnx-tty-fallback--cache nil)
  (unless drgnx-tty-fallback (drgnx-tty-fallback--unbind-prefix))
  (when (and drgnx-tty-fallback drgnx-tty-fallback--prefix-bound) (drgnx-tty-fallback--bind-prefix))
  (when (fboundp 'drgnx-tty-frames--tty-frames)
    (let (seen)
      (dolist (f (drgnx-tty-frames--tty-frames))
        (let ((term (frame-terminal f)))
          (unless (memq term seen)
            (push term seen)
            (when (terminal-parameter term 'drgnx-tty-set-up)
              (condition-case err
                  (drgnx-tty-frames-refresh-report f)   ; installs or removes, then writes the report
                (error (push (format "ui/terminal: fallback: %s" (error-message-string err)) drgnx-hooks-problems))))))))))

(defun drgnx-tty-fallback-setup ()
  "From ui/terminal's setup: rebuild the layer after every key apply (a profile switch, `drgnx-keys-use')."
  (advice-add 'drgnx-keys-apply :after #'drgnx-tty-fallback-apply))

(provide 'drgnx-tty-fallback-layer)
;;; drgnx-tty-fallback-layer.el ends here
