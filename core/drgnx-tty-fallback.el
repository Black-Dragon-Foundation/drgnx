;;; drgnx-tty-fallback.el --- Terminals: the keys a legacy terminal cannot send, and how to type them -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A legacy terminal (GNOME Terminal, Ptyxis, Terminal.app, the Linux console; tmux at modifyOtherKeys level 1 for
;; the chords it folds) cannot send C-S-p, C-. and the like.  The fallback layer gives each such chord two other
;; ways in, and this file decides them; it is safe in batch (the doctor reads it).  The layer itself (input
;; decoding, the prefix key, the hint) is modules/ui/drgnx-tty-fallback.el.
;;
;; - ALT: Alt+Shift with the key (`C-S-f' → `M-F'), decided once per profile by `drgnx-tty-fallback-table' and
;;   used at key time only while the Alt+Shift key is unbound in the buffer: a mode that binds `M-F' keeps it.
;;   Keys Emacs or the profile use, and the bytes a terminal starts a reply with, are never an ALT
;;   (`drgnx-tty-fallback-never'): those chords have the prefix only.
;; - PREFIX: `drgnx-tty-chord-prefix' (F6) then the key (`<f6> p' → C-S-p), which always works.
;; - `drgnx-tty-sendable-key': the key as a frame's terminal can send it, the one answer for every surface.
;; See docs/guide/terminal.md, "Legacy terminals: Alt+Shift and F6".

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-tty)
(defvar drgnx-keys-last)
(defvar drgnx-keys--defaults)
(defvar drgnx-keys-problems)
(declare-function drgnx-keys-read-user "drgnx-keys")
(declare-function drgnx-tty-fallback-apply "drgnx-tty-fallback-layer")

(defcustom drgnx-tty-fallback t
  "Non-nil: a terminal that cannot send C-S- chords and the like gets the fallback layer (Alt+Shift with the key
where it is free, `drgnx-tty-chord-prefix' then the key always).  Nil removes the layer from every terminal."
  :type 'boolean :group 'drgnx :initialize #'custom-initialize-default
  :set (lambda (sym val) (set-default sym val) (when (fboundp 'drgnx-tty-fallback-apply) (drgnx-tty-fallback-apply))))

(defcustom drgnx-tty-chord-prefix "<f6>"
  "The key that, in a terminal with the fallback layer, makes the next key a Ctrl chord: F6 then p is C-S-p, F6
then . is C-., F6 twice is F6.  F6 is free in Emacs and in every drgnx profile, and every terminal sends it."
  :type 'key :group 'drgnx :initialize #'custom-initialize-default
  :set (lambda (sym val) (set-default sym val) (when (fboundp 'drgnx-tty-fallback-apply) (drgnx-tty-fallback-apply))))

(defcustom drgnx-tty-fallback-hint t
  "Non-nil: the first time a kind of terminal with the fallback layer connects, one message says how to type the
keys it cannot send (never a prompt; remembered in terminal-report.eld)."
  :type 'boolean :group 'drgnx)

(defconst drgnx-tty-fallback-never
  '("M-." "M->" "M-<" "M-x" "M-:" "M-%" "M-!" "M-&" "M-;" "M-/" "M-$" "M-^" "M-w" "M-y" "M-q"
    ;; what a terminal starts a sequence with: CSI, SS3 (F1–F4), OSC, ST, APC, SOS, PM, and DCS — the reply to
    ;; XTVERSION (`ESC P > |'), which Emacs (xterm.el) and drgnx read through `input-decode-map'
    ;; when it comes late, so M-P there would turn a late reply into a key
    "M-[" "M-O" "M-]" "M-\\" "M-_" "M-X" "M-P")
  "Keys that are never an ALT, whatever the maps say: Emacs's own keys every user knows, and the bytes a terminal
begins an escape sequence or a reply with.")

(defconst drgnx-tty-fallback--us-shift
  '((?` . ?~) (?1 . ?!) (?2 . ?@) (?3 . ?#) (?4 . ?$) (?5 . ?%) (?6 . ?^) (?7 . ?&) (?8 . ?*) (?9 . ?\() (?0 . ?\))
    (?- . ?_) (?= . ?+) (?\[ . ?{) (?\] . ?}) (?\\ . ?|) (?\; . ?:) (?' . ?\") (?, . ?<) (?. . ?>) (?/ . ??))
  "What Shift makes of a key on a US layout.")

;;;; One chord

(defun drgnx-tty-fallback--parts (event)
  "EVENT as (MODS . BASE), with a macOS profile's s- read as C- (Cmd+Shift+P, s-P, is C-S-p); nil when it has
other modifiers (H-, A-)."
  (let ((mods (event-modifiers event)) (base (event-basic-type event)))
    (when (memq 'super mods) (setq mods (cons 'control (remq 'control (remq 'super mods)))))
    (unless (seq-difference mods '(control shift meta))
      (cons mods base))))

(defun drgnx-tty-fallback--alt-of (event)
  "The Alt+Shift key for chord EVENT (a string), before any check: `M-' and the key with Shift on a US layout
\(C-S-p → M-P, C-. → M->, C-{ → M-{); nil for a chord with Meta, a named key, or a Ctrl+letter."
  (pcase-let ((`(,mods . ,base) (drgnx-tty-fallback--parts event)))
    (when (and (memq 'control mods) (not (memq 'meta mods)) (integerp base))
      (let ((shifted (cond ((<= ?a base ?z) (and (memq 'shift mods) (upcase base)))
                           ((memq 'shift mods) (alist-get base drgnx-tty-fallback--us-shift))
                           (t (or (alist-get base drgnx-tty-fallback--us-shift) base)))))
        (and shifted (key-description (vector (event-convert-list (list 'meta shifted)))))))))

(defun drgnx-tty-fallback--prefix-of (event prefix)
  "PREFIX then the key that stands for chord EVENT, as a key string: the key without Ctrl (and without Shift for a
letter: C-S-p is PREFIX p); a shifted punctuation key as the character Shift makes (C-S-` is PREFIX ~); Shift on a
key a terminal sends no Shift with (Enter, Backspace) as Alt (C-S-<return> is PREFIX M-RET); C-SPC as PREFIX C-SPC
\(Ctrl+Space after the prefix), C-S-SPC as PREFIX SPC; a Cmd+letter of a macOS profile whose Ctrl form is a plain
key as PREFIX C-<letter>.  Nil when EVENT has no such form."
  (pcase-let ((`(,mods . ,base) (drgnx-tty-fallback--parts event)))
    (when (memq 'control mods)
      (let* ((shift (memq 'shift mods)) (meta (memq 'meta mods))
             (key (cond
                   ((and (integerp base) (<= ?a base ?z))
                    (if shift base (event-convert-list (list 'control base))))
                   ((eq base ?\s) (if shift ?\s 0))   ; Ctrl+Space, as a terminal sends it: C-@
                   ((integerp base) (if shift (alist-get base drgnx-tty-fallback--us-shift) base))
                   ;; Alt stands for Shift here, so a chord with a real Alt as well (C-M-<return>) has no form
                   ((memq base '(return backspace)) (cond (meta nil)
                                                          (shift (setq meta t) (if (eq base 'return) 13 127))
                                                          (t (if (eq base 'return) 13 127))))
                   ((eq base 'tab) (if shift 'backtab 9))
                   (shift (event-convert-list (list 'shift base)))
                   (t base))))
        (when key
          (concat prefix " " (key-description (vector (if meta (event-convert-list (list 'meta key)) key)))))))))

;;;; The table

(defun drgnx-tty-fallback--bound-p (map key)
  "Non-nil when KEY (a string) does something in keymap MAP (a command or a prefix)."
  (let ((def (and (keymapp map) (ignore-errors (keymap-lookup map key nil t)))))
    (and def (not (numberp def)))))

(defun drgnx-tty-fallback--why-not (alt &optional global profile takes taken)
  "Why ALT (a key string) cannot be an Alt+Shift fallback, or nil when it can.  GLOBAL is Emacs's own global map,
PROFILE the active profile's keys (strings; a key that starts with ALT counts), TAKES the keys the terminal keeps,
TAKEN the ALTs already given to other chords."
  (let ((ev (ignore-errors (aref (key-parse alt) 0))))
    (cond ((not (and (key-valid-p alt) (= (length (key-parse alt)) 1))) (format "%s is not one key" alt))
          ;; ESC and one character is what the layer decodes: no function key, named key or other modifier
          ((not (and (integerp ev) (/= 0 (logand ev ?\M-\0)) (<= 32 (logand ev (lognot ?\M-\0)) 126)))
           (format "%s is not Alt with a character key" alt))
          ((not (drgnx-tty-key-sendable-p alt 'legacy)) (format "%s cannot be sent by a legacy terminal either" alt))
          ((member alt drgnx-tty-fallback-never) (format "%s is reserved (an Emacs key or the start of a terminal reply)" alt))
          ((drgnx-tty-fallback--bound-p global alt)
           (format "%s is Emacs's %s" alt (keymap-lookup global alt nil t)))
          ((seq-find (lambda (k) (equal (ignore-errors (aref (key-parse k) 0)) ev)) profile)
           (format "%s is bound in the key profile" alt))
          ((seq-find (lambda (k) (equal (key-parse k) (vector ev))) takes) (format "%s is kept by the terminal" alt))
          ((rassoc alt taken) (format "%s is already the fallback of %s" alt (car (rassoc alt taken)))))))

(defun drgnx-tty-fallback-chords (keys &optional caps folded)
  "The chords (key strings of one event) of KEYS (key strings) that a terminal with CAPS (default `legacy') and
FOLDED cannot send and the prefix can type, each once, in order.  (The prefix adds Ctrl: S-<return> and
C-M-<return> have no form.)"
  (let (out seen)
    (dolist (key keys (nreverse out))
      (let* ((events (append (ignore-errors (key-parse key)) nil))
             (words (split-string key " " t))
             ;; each chord as the profile spells it (C-S-m, not S-RET), when the words are the events
             (names (if (= (length words) (length events)) words
                      (mapcar (lambda (ev) (key-description (vector ev))) events))))
        (cl-mapc (lambda (ev name)
                   (when (and (not (memq ev seen)) (drgnx-tty-unsendable (list (vector ev)) (or caps 'legacy) folded)
                              (drgnx-tty-fallback--prefix-of ev "<f6>"))   ; the prefix adds Ctrl: no Ctrl, no form (S-<return>)
                     (push ev seen)
                     (push name out)))
                 events names)))))

(defun drgnx-tty-fallback--row (table event)
  "TABLE's row (CHORD . PLIST) for EVENT, the chords compared as keys (TAB and C-i are one)."
  (seq-find (lambda (row) (equal (key-parse (car row)) (vector event))) table))

(cl-defun drgnx-tty-fallback-table (keys &key global profile takes overrides prefix)
  "The fallbacks for every key of KEYS (key strings; each event of a sequence on its own) that a `legacy'
terminal cannot send: an alist (CHORD . (:alt ALT :prefix PREFIX-KEY)), in KEYS's order.
ALT is the Alt+Shift key (`drgnx-tty-fallback--alt-of'), nil when it is in `drgnx-tty-fallback-never', does
something in GLOBAL (Emacs's own global map) or in PROFILE (the active stack's keys), is in TAKES (kept by the
terminal), or is the ALT of an earlier chord: no second guess is made, the prefix covers it.
PREFIX-KEY is PREFIX (default `drgnx-tty-chord-prefix') then the key (`drgnx-tty-fallback--prefix-of').
OVERRIDES (keys.eld's :tty-fallback, an alist (CHORD . KEY)) replace ALT per chord, under the same checks; one that
fails keeps the computed ALT and is listed as `:rejected (KEY . WHY)' in the chord's entry."
  (let* ((prefix (or prefix drgnx-tty-chord-prefix))
         (chords (drgnx-tty-fallback-chords keys))
         (taken nil)
         (rows nil))
    ;; overrides claim their keys first
    (let ((wanted (and (proper-list-p overrides) overrides)))
      (dolist (chord chords)
        (let* ((ov (seq-find (lambda (o) (and (consp o) (stringp (car o)) (key-valid-p (car o))
                                              (equal (key-parse (car o)) (key-parse chord))))
                             wanted))
               (why (and ov (if (stringp (cdr ov)) (drgnx-tty-fallback--why-not (cdr ov) global profile takes taken)
                              (format "%S is not a key" (cdr ov))))))
          (cond ((and ov (not why)) (push (cons chord (cdr ov)) taken) (push (list chord :override (cdr ov)) rows))
                (ov (push (list chord :rejected (cons (cdr ov) why)) rows))))))
    (mapcar (lambda (chord)
              (let* ((ev (aref (key-parse chord) 0))
                     (row (cdr (assoc chord rows)))
                     (alt (or (plist-get row :override)
                              (let ((a (drgnx-tty-fallback--alt-of ev)))
                                (and a (not (drgnx-tty-fallback--why-not a global profile takes taken))
                                     (progn (push (cons chord a) taken) a))))))
                (cons chord (append (list :alt alt :prefix (drgnx-tty-fallback--prefix-of ev prefix))
                                    (and (plist-get row :rejected) (list :rejected (plist-get row :rejected)))))))
            chords)))

(cl-defun drgnx-tty-fallback-clashes (table &key global profile takes)
  "The ALTs of TABLE that would take a key in use: (CHORD ALT WHY) for each ALT in `drgnx-tty-fallback-never',
bound in GLOBAL or PROFILE, kept by the terminal (TAKES), not sendable by a legacy terminal, or given to two
chords.  Empty when TABLE is clean."
  (let (taken out)
    (pcase-dolist (`(,chord . ,row) table)
      (when-let* ((alt (plist-get row :alt)))
        (when-let* ((why (drgnx-tty-fallback--why-not alt global profile takes taken)))
          (push (list chord alt why) out))
        (push (cons chord alt) taken)))
    (nreverse out)))

(defun drgnx-tty-fallback-problems (table &optional overrides)
  "The keys.eld :tty-fallback entries TABLE could not apply, as lines (terminal-report.eld's :fallback-problems).
With OVERRIDES (the :tty-fallback value TABLE was made with), also each entry that is not (CHORD . KEY) or names a
chord the profile needs no fallback for (one a plain terminal sends, or no key of the profile)."
  (append
   (delq nil (mapcar (pcase-lambda (`(,chord . ,row))
                       (when-let* ((r (plist-get row :rejected)))
                         (format "keys.eld :tty-fallback %s → %s not used: %s" chord (car r) (cdr r))))
                     table))
   (if (and overrides (not (proper-list-p overrides)))
       (list (format "keys.eld :tty-fallback %S is not a list of (CHORD . KEY)" overrides))
     (delq nil (mapcar (lambda (o)
                         (cond ((not (and (consp o) (stringp (car o)) (key-valid-p (car o))))
                                (format "keys.eld :tty-fallback %S is not (CHORD . KEY)" o))
                               ((not (seq-find (lambda (r) (equal (key-parse (car r)) (key-parse (car o)))) table))
                                (format "keys.eld :tty-fallback %s: the profile needs no fallback for it" (car o)))))
                       overrides)))))

;;;; The active profile's table

(defvar drgnx-tty-fallback--cache nil "(KEYS-LAST . TABLE): the table of the `drgnx-keys-last' it was made from.")

(defun drgnx-tty-fallback--profile-keys ()
  "The active profile's keys (strings), from `drgnx-keys-last'."
  (seq-uniq (delq nil (mapcar (lambda (b) (plist-get b :key)) (plist-get (bound-and-true-p drgnx-keys-last) :bindings)))))

(defun drgnx-tty-fallback--overrides ()
  "keys.eld's :tty-fallback, read without adding to the key problems (the apply that read it said those)."
  (when (fboundp 'drgnx-keys-read-user)
    (let ((drgnx-keys-problems nil)) (plist-get (drgnx-keys-read-user) :tty-fallback))))

(defun drgnx-tty-fallback-active-table ()
  "The table (`drgnx-tty-fallback-table') of the active key profile and keys.eld, made once per key apply."
  (let ((last (bound-and-true-p drgnx-keys-last)))
    (if (and drgnx-tty-fallback--cache (eq (car drgnx-tty-fallback--cache) last) last)
        (cdr drgnx-tty-fallback--cache)
      (let* ((keys (drgnx-tty-fallback--profile-keys))
             (table (drgnx-tty-fallback-table keys :global (or (bound-and-true-p drgnx-keys--defaults) global-map)
                                              :profile keys :overrides (drgnx-tty-fallback--overrides))))
        (setq drgnx-tty-fallback--cache (cons last table))
        table))))

(defun drgnx-tty-fallback-for-terminal (table caps)
  "TABLE's rows for a terminal with CAPS (`drgnx-tty-frame-caps'): the chords it cannot send (`:folded' too),
an ALT it keeps for itself (its row's :takes) dropped."
  (let* ((mode (or (plist-get caps :keys) 'legacy))
         (folded (plist-get caps :folded))
         (takes (mapcar (lambda (k) (ignore-errors (key-parse k)))
                        (plist-get (drgnx-tty-terminal (plist-get caps :id)) :takes))))
    (delq nil (mapcar (pcase-lambda (`(,chord . ,row))
                        (when (drgnx-tty-unsendable (list chord) mode folded)
                          (cons chord (if (member (ignore-errors (key-parse (plist-get row :alt))) takes)
                                          (plist-put (copy-sequence row) :alt nil)
                                        row))))
                      table))))

;;;; At key time

(defun drgnx-tty-fallback--free-p (alt)
  "Non-nil when ALT (a key string) does nothing in the current buffer's active maps: overriding and minibuffer
maps, minor modes, the local map, the global map, default bindings included (no shift translation; input decoding
is not a keymap)."
  (not (drgnx-tty-fallback--bound-here-p alt)))

(defun drgnx-tty-fallback--bound-here-p (key)
  "Non-nil when KEY (a key string) does something in the current buffer's active maps (a default binding counts)."
  (let ((def (key-binding (key-parse key) t)))
    (and def (not (numberp def)))))

(defun drgnx-tty-fallback--decode (alt chord)
  "What ALT (the Alt+Shift key a terminal sent) stands for now: CHORD's event while ALT is free in the current
buffer (`drgnx-tty-fallback--free-p') and CHORD does something there; else ALT itself, for the mode that binds it
or for what Emacs makes of it.  The current buffer is the one Emacs then looks the key up in (the selected
window's, as of the last command)."
  (key-parse (if (and (drgnx-tty-fallback--free-p alt) (drgnx-tty-fallback--bound-here-p chord)) chord alt)))

(defun drgnx-tty-sendable-key (frame key)
  "KEY (a key string) as FRAME's terminal can send it, for every surface (palette, key sheet, Shortcuts editor):
KEY on a graphical frame or where the terminal sends it; else, with the fallback layer on that terminal, each
chord it cannot send as its Alt+Shift key while that is free in the current buffer, else its prefix form
\(\"M-F\", \"<f6> p\"); without the layer, KEY unchanged (the surface marks it as not sendable here,
`drgnx-tty-frame-sends-p')."
  (let* ((frame (or frame (selected-frame)))
         (term (frame-terminal frame))
         (caps (and (not (display-graphic-p frame)) (terminal-parameter term 'drgnx-tty-caps))))
    (if (or (null caps) (drgnx-tty-frame-sends-p frame key)) key
      (let ((table (and drgnx-tty-fallback (terminal-parameter term 'drgnx-tty-fallback-table))))
        (if (null table) key
          (mapconcat (lambda (ev)
                       (let* ((chord (key-description (vector ev)))
                              (row (cdr (drgnx-tty-fallback--row table ev)))
                              (alt (plist-get row :alt)))
                         (cond ((null row) chord)
                               ((and alt (drgnx-tty-fallback--free-p alt)) alt)
                               ((plist-get row :prefix))
                               (t chord))))
                     (key-parse key) " "))))))

(defun drgnx-tty-frame-sends-p (frame key)
  "Non-nil when FRAME's terminal sends KEY (a key string) as it is: a graphical frame, or a terminal whose caps
\(the terminal parameter `drgnx-tty-caps') allow every event of it.  A terminal not set up yet counts as sending it."
  (let ((caps (and (not (display-graphic-p frame)) (terminal-parameter (frame-terminal frame) 'drgnx-tty-caps))))
    (or (null caps) (null (drgnx-tty-unsendable (list key) (plist-get caps :keys) (plist-get caps :folded))))))

;;;; Reports and words

(defun drgnx-tty-fallback-report-rows (table caps layer)
  "For terminal-report.eld: TABLE's chords (the profile's chords a legacy terminal cannot send) as
\(CHORD NATIVE-P ALT PREFIX) for a terminal with CAPS: NATIVE-P when it sends CHORD itself; ALT and PREFIX from
LAYER, the rows installed on it (nil without the layer)."
  (mapcar (pcase-lambda (`(,chord . ,_))
            (let ((row (cdr (assoc chord layer))))
              (list chord (null (drgnx-tty-unsendable (list chord) (or (plist-get caps :keys) 'legacy) (plist-get caps :folded)))
                    (plist-get row :alt) (plist-get row :prefix))))
          table))

(defun drgnx-tty-fallback-label (key)
  "KEY (a key string) in words: \"M-P\" → \"Alt+Shift+P\", \"M-#\" → \"Alt+Shift+3\", \"<f6> p\" → \"F6 p\",
\"C-S-p\" → \"Ctrl+Shift+P\", \"C-<return>\" → \"Ctrl+Enter\"."
  (mapconcat
   (lambda (word)
     (if (or (equal word "C-@")       ; Ctrl+Space, as a terminal sends it
             (not (let ((case-fold-search nil)) (string-match "\\`\\(\\(?:[ACHMSs]-\\)*\\)\\(.+\\)\\'" word))))
         (if (equal word "C-@") "Ctrl+Space" word)
       (let* ((base (match-string 2 word))
              (mods (split-string (match-string 1 word) "-" t))
              (named '(("RET" . "Enter") ("<return>" . "Enter") ("TAB" . "Tab") ("<tab>" . "Tab") ("DEL" . "Backspace")
                       ("<backspace>" . "Backspace") ("ESC" . "Esc") ("<escape>" . "Esc") ("SPC" . "Space")
                       ("<backtab>" . "Shift+Tab")))
              (unshifted (car (rassoc (and (= (length base) 1) (aref base 0)) drgnx-tty-fallback--us-shift)))
              (name (let ((case-fold-search nil)) (cond ((cdr (assoc base named)))
                                                        ((string-match "\\`<\\(.+\\)>\\'" base) (capitalize (match-string 1 base)))
                                                        ;; a capital letter, or what Shift makes of a key, is Shift with the key, unless typed alone
                                                        ((and mods (string-match-p "\\`[A-Z]\\'" base)) (push "S" mods) base)
                                                        ((and mods unshifted) (push "S" mods) (string unshifted))
                                                        ((and mods (string-match-p "\\`[a-z]\\'" base)) (upcase base))
                                                        (t base)))))
         (concat (mapconcat (lambda (m) (if (member m mods)
                                            (concat (cdr (assoc m '(("C" . "Ctrl") ("M" . "Alt") ("s" . "Cmd") ("H" . "Hyper")
                                                                    ("A" . "Alt") ("S" . "Shift"))))
                                                    "+")
                                          ""))
                            '("C" "M" "A" "s" "H" "S") "")
                 name))))
   (split-string key " " t) " "))

(defun drgnx-tty-fallback-hint-text ()
  "The one hint a legacy terminal gets, with the prefix key of `drgnx-tty-chord-prefix'."
  (format "This terminal can't send Ctrl+Shift keys: use Alt+Shift (or %s then the key). drgnx doctor has details."
          (drgnx-tty-fallback-label drgnx-tty-chord-prefix)))

(defun drgnx-tty-fallback-facts (&optional report)
  "What the doctor shows for the fallback layer, from REPORT (default terminal-report.eld): one plist per terminal,
\(:tty TTY :id ID :keys MODE :layer BOOL :rows ((CHORD NATIVE-P ALT PREFIX)…) :problems LINES), newest first.
The doctor prints :rows as three columns: native, fallback (ALT, \"Alt+Shift+F\"), prefix (\"F6 p\"); a row with
none of them cannot be typed in that terminal."
  (let ((report (or report (drgnx-tty--read-report))))
    (mapcar (pcase-lambda (`(,tty . ,entry))
              (let ((caps (plist-get entry :caps)))
                (list :tty tty :id (plist-get caps :id) :keys (plist-get caps :keys)
                      :layer (and (plist-get entry :fallback) t)
                      :rows (plist-get entry :fallbacks)
                      :problems (plist-get entry :fallback-problems))))
            (seq-filter #'consp (plist-get report :terminals)))))

(provide 'drgnx-tty-fallback)
;;; drgnx-tty-fallback.el ends here
