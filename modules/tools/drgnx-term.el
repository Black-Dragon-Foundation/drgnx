;;; drgnx-term.el --- Module tools/term: drgnx's own terminal, run by a worker of the hub -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; New Terminal runs your shell in a terminal worker the hub starts (`drgnx-term', on libghostty-vt:
;; docs/develop/terminal.md).  The worker owns the PTY and the screen and sends finished rows; this buffer only inserts
;; them.  It is a hub-fed view of type `drgnx-term-view': no throttle, each patch acknowledged (the worker keeps one in
;; flight), and its faces repaint in place when the theme changes (no reset).  After each draw, point and the cursor
;; go where the worker's cursor is (`cursor-type' from its shape; a cursor past the row's last character is drawn
;; there by an overlay's padding).
;;
;; The buffer holds the screen and up to `drgnx-term-scrollback-lines' rows above it.  The worker removes the oldest
;; rows and, after a flood, fills the rows the buffer missed, newest first; changing the setting trims or fills every
;; terminal at once.  Scrolling to the top of the buffer asks the worker for missing rows above (`term/fetch').  Undo is
;; off.  While the hub is away (or before the terminal has opened), input waits, at most `drgnx-term-queue-max'
;; bytes, and goes once the hub is back.  The terminals of this Emacs survive a hub restart: the hub adopts the
;; workers, and the next subscription draws them again from a reset.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-modules)
(require 'drgnx-setting)
(require 'drgnx-timer)
(require 'drgnx-view)
(require 'drgnx-view-nav)                ; Find's matches move through the replica
(require 'drgnx-hub-client)
(require 'drgnx-registry)
(require 'drgnx-notice)
(require 'drgnx-state)
(require 'url-util)
(require 'drgnx-color)
(require 'drgnx-memo)
(require 'drgnx-pixels)
(require 'drgnx-term-settings (expand-file-name "drgnx-term-settings" (file-name-directory (macroexp-file-name))))
(require 'drgnx-term-remote (expand-file-name "drgnx-term-remote" (file-name-directory (macroexp-file-name))))
(defvar drgnx-keys-last)
(defvar drgnx-term-copy-mode)
(declare-function drgnx-config-file "drgnx-config" (name &optional root))
(declare-function drgnx-settings-file-put "drgnx-settings-file" (file head scope var value &rest args))
(declare-function drgnx-terminal-environment "drgnx-terminal" ())
(declare-function drgnx-terminal-shell "drgnx-terminal" ())

;;;; Faces

(defface drgnx-term-default '((t))
  "The terminal's text in its default colours: remapped over `default' in a terminal's buffer."
  :group 'drgnx)

(defface drgnx-term-selection '((t :inherit region))
  "The terminal's selected text."
  :group 'drgnx)

(defface drgnx-term-search '((t :inherit lazy-highlight))
  "The matches of Find in Terminal."
  :group 'drgnx)

(defface drgnx-term-search-selected '((t :inherit isearch))
  "The match of Find in Terminal that is selected."
  :group 'drgnx)

(defface drgnx-term-cursor '((t :inherit cursor))
  "The terminal's cursor colour, as programs that ask for it are told."
  :group 'drgnx)

(defface drgnx-term-image-alt '((t :inherit shadow))
  "An image's place where it cannot be drawn (a text terminal, no PNG support, a refused or evicted image):
`[image 640×480]'."
  :group 'drgnx)

;;;; State

(defconst drgnx-term-queue-max 4096
  "The most bytes of input a terminal holds while the hub is away; what comes after is dropped (said once).")

(defvar drgnx-term--buffers (make-hash-table :test #'equal)
  "Terminal id → its buffer, for the terminals this Emacs opened.  Pruned with the buffer.")

(defconst drgnx-term-class "term"
  "The display class of every terminal view: the worker builds its rows for cells, not for the window's fonts, so a
text scale or a font change never re-pairs the buffer.")

(defvar-local drgnx-term--id nil "This terminal's id at the hub, once `term/open' answered.")
(defvar-local drgnx-term--state nil "nil (not asked yet), `opening', `open', `failed' or `exited'.")
(defvar-local drgnx-term--program nil "The program and its arguments this terminal runs.")
(defvar-local drgnx-term--shell nil "Non-nil when this terminal runs the user's shell (its buffer goes when it ends).")
(defvar-local drgnx-term--queue nil "Input waiting for the hub, newest first: (METHOD . PARAMS) each.")
(defvar-local drgnx-term--queued 0 "The bytes of input in `drgnx-term--queue'.")
(defvar-local drgnx-term--dropped nil "Non-nil once input was dropped while the hub is away (said once).")
(defvar-local drgnx-term--pad-overlay nil "The overlay that draws the cursor past the end of its row.")
(defvar-local drgnx-term--fetching nil "Non-nil while a `term/fetch' waits for its answer.")
(defvar-local drgnx-term--top-done nil "The first row's key when the worker last said nothing is missing above it.")
(defvar-local drgnx-term--started nil "When this terminal's `term/open' was sent (`float-time').")
(defvar-local drgnx-term--command-start nil "When the running command's output started (OSC 133 C), or nil.")
(defvar drgnx-chrome-tab-icon)
(defvar-local drgnx-term--remote nil
  "A terminal in a remote folder: TRAMP's prefix of that folder (\"/ssh:host:\"); its folders and links are there.")
(defvar-local drgnx-term--remote-host nil
  "The host name the remote shell's first OSC 7 gave: a later one naming another host (an ssh typed inside) is not
followed.")
(defvar-local drgnx-term--host-name nil "A remote terminal's host, as its name shows it (from its TRAMP folder).")
(defvar-local drgnx-term--clipboard nil "The text a remote program last asked to put on the clipboard, while asked.")

(defun drgnx-term--up-p ()
  "Non-nil while this Emacs's subscribed connection to the hub is up."
  (process-live-p drgnx-hub--events))

(defun drgnx-term-buffers ()
  "The live terminal buffers this Emacs opened."
  (let (out)
    (maphash (lambda (_ b) (when (buffer-live-p b) (push b out))) drgnx-term--buffers)
    out))

;;;; Input: sent now, or queued while the hub is away

(defun drgnx-term--bytes (params)
  "The bytes PARAMS of an input message count against `drgnx-term-queue-max'."
  (+ (string-bytes (or (plist-get params :text) "")) (string-bytes (or (plist-get params :key) "")) 1))

(defun drgnx-term--send (method params)
  "METHOD with PARAMS (without the id) for this buffer's terminal: now while the hub is up and the terminal open,
else queued (input only, at most `drgnx-term-queue-max' bytes; `term/config' is not queued: the next open or
subscription reads the setting)."
  (cond ((and drgnx-term--id (eq drgnx-term--state 'open) (drgnx-term--up-p))
         (drgnx-hub--call-on drgnx-hub--events method (append (list :id drgnx-term--id) params) #'ignore))
        ((equal method "term/config") nil)
        ((memq drgnx-term--state '(failed exited)) nil)
        (t (let ((n (drgnx-term--bytes params)))
             (if (> (+ drgnx-term--queued n) drgnx-term-queue-max)
                 (unless drgnx-term--dropped
                   (setq drgnx-term--dropped t)
                   (message "Terminal: the hub is away and %d bytes of input wait already; more is dropped"
                            drgnx-term--queued))
               (push (cons method params) drgnx-term--queue)
               (setq drgnx-term--queued (+ drgnx-term--queued n)))))))

(defun drgnx-term--flush ()
  "Send this terminal's queued input, oldest first."
  (when (and drgnx-term--queue drgnx-term--id (eq drgnx-term--state 'open) (drgnx-term--up-p))
    (let ((q (nreverse drgnx-term--queue)))
      (setq drgnx-term--queue nil drgnx-term--queued 0 drgnx-term--dropped nil)
      (dolist (m q) (drgnx-term--send (car m) (cdr m))))))

(defun drgnx-term-send-string (text)
  "Type TEXT into this buffer's terminal, as it is (`term/text')."
  (drgnx-term--send "term/text" (list :text text)))

(defun drgnx-term-send-key (key &optional mods text action)
  "Press KEY (a name: `return', `tab', `a', `f5') with MODS (a list of `ctrl', `shift', `alt', `super') in this
buffer's terminal; TEXT is what it types.  ACTION `repeat' or `release' sends a repeat or a release instead of a press
\(the program sees them only while it asked for key event types).  The worker encodes it from the terminal's modes
\(`term/key')."
  (drgnx-term--send "term/key" (append (list :key key :mods (vconcat mods)) (and text (list :text text))
                                       (and action (list :action (symbol-name action))))))

(defconst drgnx-term--event-names
  '((13 . "return") (9 . "tab") (127 . "backspace") (return . "return") (tab . "tab") (backspace . "backspace")
    (delete . "delete") (deletechar . "delete") (escape . "escape") (insert . "insert") (insertchar . "insert"))
  "Events whose key name is not their basic type's name.")

(defconst drgnx-term--modifier-names '((control . "ctrl") (meta . "alt") (shift . "shift") (super . "super"))
  "Emacs's event modifiers as the worker names them.")

(defun drgnx-term--event-key (event)
  "EVENT as (KEY MODS TEXT) for `term/key', or nil for an event a terminal does not take."
  (if-let* ((name (alist-get event drgnx-term--event-names)))
      (list name nil nil)
    (let* ((basic (event-basic-type event))
           (mods (delq nil (mapcar (lambda (m) (alist-get m drgnx-term--modifier-names)) (event-modifiers event))))
           (name (cond ((alist-get basic drgnx-term--event-names))
                       ((characterp basic) (string basic))
                       ((symbolp basic) (symbol-name basic)))))
      (when name
        (list name mods (and (characterp event) (>= event 32) (/= event 127) (string event)))))))

(defun drgnx-term-send-event ()
  "Send this key to the terminal's program (`term/key'), encoded by the worker from the terminal's modes.  Typing
deselects (`drgnx-term-selection-clear-on-typing') and goes back to the cursor (`drgnx-term-scroll-to-bottom')."
  (interactive)
  (when drgnx-term-selection-clear-on-typing (deactivate-mark))
  (when (memq 'keystroke drgnx-term-scroll-to-bottom) (drgnx-term--place-cursor t))
  (pcase (drgnx-term--event-key last-command-event)
    (`(,key ,mods ,text)
     (let ((repeat (bound-and-true-p nidhogg-last-key-repeat)))
       (drgnx-term-send-key key mods text (and repeat 'repeat))
       (when (and (not repeat) (drgnx-term--key-events-p))
         (drgnx-term--hold last-command-event key))))))

;;;; Key releases (Nidhogg): a program that asked for key event types gets repeats and releases

(defvar nidhogg-key-events)
(defvar nidhogg-last-key-repeat)

(defconst drgnx-term--held-max 32 "The most held keys `drgnx-term--held' remembers (a keyboard holds fewer).")

(defvar drgnx-term--held nil
  "The keys pressed in a terminal whose program asked for key event types and not released yet, newest first: each
\(BASIC BUFFER KEY), BASIC the press's `event-basic-type', KEY its `term/key' name.  At most `drgnx-term--held-max'.")

(defun drgnx-term--key-events-p (&optional buffer)
  "Non-nil when BUFFER (default: the current one) is a terminal whose program asked for key event types (the kitty
keyboard protocol's flag 2: the patch's `term' says `key_events')."
  (with-current-buffer (or buffer (current-buffer))
    (and (derived-mode-p 'drgnx-term-mode) drgnx-view-patch
         (eq (plist-get (drgnx-view-patch-term drgnx-view-patch) :key_events) t))))

(defun drgnx-term--key-gate ()
  "Ask Nidhogg for key releases (`nidhogg-key-events') while the selected window shows a terminal whose program wants
them, or a key pressed in one is still held; else let it drop them.  No-op on another Emacs."
  (when (boundp 'nidhogg-key-events)
    (setq nidhogg-key-events
          (and (or drgnx-term--held (drgnx-term--key-events-p (window-buffer (selected-window)))) t))))

(defun drgnx-term--hold (event key)
  "Remember that EVENT (sent to this terminal as KEY) is held, for its release."
  (let ((basic (event-basic-type event)))
    (setq drgnx-term--held
          (cons (list basic (current-buffer) key)
                (seq-take (seq-remove (lambda (h) (or (equal (car h) basic) (not (buffer-live-p (nth 1 h)))))
                                      drgnx-term--held)
                          (1- drgnx-term--held-max))))))

(defun drgnx-term--release (held mods)
  "Send the release of HELD (an entry of `drgnx-term--held') with MODS to its terminal, and forget it."
  (setq drgnx-term--held (delq held drgnx-term--held))
  (when (buffer-live-p (nth 1 held))
    (with-current-buffer (nth 1 held) (drgnx-term-send-key (nth 2 held) mods nil 'release))))

(defun drgnx-term-key-release (event)
  "A `key-release' special event from Nidhogg, (key-release KEY-EVENT): the release goes to the terminal that got the
key's press, with the modifiers held at the release; a key no terminal holds is ignored."
  (interactive "e")
  (let ((ev (cadr event)))
    (when-let* ((held (assoc (event-basic-type ev) drgnx-term--held)))
      (drgnx-term--release held (nth 1 (drgnx-term--event-key ev)))))
  (drgnx-term--key-gate))

(defun drgnx-term--release-all (&optional buffer)
  "Release every held key (of BUFFER only, when given): its terminal lost the keyboard, so no release will come."
  (dolist (h drgnx-term--held)
    (when (or (null buffer) (eq (nth 1 h) buffer)) (drgnx-term--release h nil)))
  (drgnx-term--key-gate))

(defun drgnx-term--focus-changed ()
  "`after-focus-change-function': no frame has the focus, so the keys held in terminals are released."
  (unless (seq-some #'frame-focus-state (frame-list)) (drgnx-term--release-all)))

;;;; Which keys reach drgnx, which the program

(defcustom drgnx-terminal-skip-shell-keys '("C-p" "C-b" "C-k" "C-f")
  "First keys that reach drgnx in a terminal even though readline uses them: VS Code's commandsToSkipShell.
Quick Open (C-p), Toggle Sidebar (C-b), every C-k chord, and Find (C-f, which searches the terminal's text).
It only applies to keys the active key stack binds to an app or window command, so the Emacs and Vim profiles,
which bind none of them, leave these keys to the shell.  Every other control or Alt key of such a command goes to
the shell.  Key descriptions of one event, e.g. \"C-p\" or \"M-j\"."
  :type '(repeat string) :group 'drgnx)

(defconst drgnx-terminal--meta-bit #x8000000 "The meta modifier bit of an event.")

(defconst drgnx-term-reserved-keys
  '([?\C-c] [?\C-x] [?\C-g] [?\C-h] [?\C-u] [?\C-q] [?\C-\\] [?\e ?x] [?\e ?:] [?\e ?!] [?\e ?&])
  "Keys a terminal always leaves to Emacs: C-c (a prefix: drgnx's terminal keys), C-x, C-g, C-h, C-u, C-q, C-\\,
M-x, M-:, M-! and M-&.  As key vectors (M-x is [?\\e ?x]).")

(defvar drgnx-surfaces-cheatsheet-sections)
(defvar drgnx-session-running-functions)
(defvar drgnx-session-keepable-functions)

(defun drgnx-terminal--keys-vector (event)
  "EVENT as a key vector: M-x is [?\\e ?x]."
  (if (and (integerp event) (/= 0 (logand event drgnx-terminal--meta-bit)))
      (vector ?\e (logand event (lognot drgnx-terminal--meta-bit)))
    (vector event)))

(defun drgnx-terminal--shell-event-p (event)
  "Non-nil when EVENT is an ASCII character, control or plain, or M- plus one: what readline and zle mean."
  (and (integerp event) (<= 0 (logand event (lognot drgnx-terminal--meta-bit)) 127)))

(defun drgnx-terminal--bindings ()
  "Global bindings (plists of `drgnx-keys-last') of the active stack's app and window commands."
  (seq-filter (lambda (b)
                (and (memq (plist-get b :map) '(nil global-map))
                     (let ((cmd (drgnx-commands-get (plist-get b :id))))
                       (and cmd (memq (drgnx-cmd-scope cmd) '(app window))))))
              (plist-get drgnx-keys-last :bindings)))

(defun drgnx-terminal-key-split (&optional reserved)
  "Where the active key profile's keys go in a terminal: (:to-drgnx KEYS :to-shell KEYS), key strings.
Only global bindings of commands with scope app or window count.  A key whose first event is an ASCII control
or Alt character the terminal sends to the shell goes to the shell (C-a, C-e, C-w, C-k, M-f as readline mean them),
unless its first key is in `drgnx-terminal-skip-shell-keys'; every other key reaches drgnx (as do the RESERVED
keys, by default `drgnx-term-reserved-keys')."
  (let ((reserved (or reserved drgnx-term-reserved-keys)) to-drgnx to-shell)
    (dolist (b (drgnx-terminal--bindings))
      (let* ((key (plist-get b :key)) (event (aref (key-parse key) 0)))
        (if (and (drgnx-terminal--shell-event-p event)
                 (not (member (drgnx-terminal--keys-vector event) reserved))
                 (not (member (key-description (vector event)) drgnx-terminal-skip-shell-keys)))
            (cl-pushnew key to-shell :test #'equal)
          (cl-pushnew key to-drgnx :test #'equal))))
    (list :to-drgnx (nreverse to-drgnx) :to-shell (nreverse to-shell))))

(defun drgnx-terminal--key-title (key)
  "The title of the first command the active stack binds KEY to."
  (when-let* ((b (seq-find (lambda (b) (equal (plist-get b :key) key)) (drgnx-terminal--bindings)))
              (cmd (drgnx-commands-get (plist-get b :id))))
    (drgnx-cmd-title cmd)))

(defun drgnx-terminal--collapse-chords (keys)
  "KEYS with the chords of one first key (two or more, e.g. C-k C-s and C-k C-o) shown once, as \"C-k chords\"."
  (let (seen out)
    (dolist (k keys)
      (let* ((v (key-parse k)) (prefix (key-description (vector (aref v 0)))))
        (if (or (< (length v) 2)
                (= 1 (seq-count (lambda (k2) (let ((v2 (key-parse k2))) (and (> (length v2) 1) (equal (aref v2 0) (aref v 0)))))
                                keys)))
            (push k out)
          (unless (member prefix seen)
            (push prefix seen)
            (push (concat prefix " chords") out)))))
    (nreverse out)))

(defun drgnx-terminal-cheatsheet-section ()
  "The key sheet's \"In the terminal\" section: (TITLE . LINES), or nil without the terminal or keys."
  (when (drgnx-modules--ok-p 'tools/term)
    (let* ((split (drgnx-terminal-key-split))
           (to-drgnx (drgnx-terminal--collapse-chords (plist-get split :to-drgnx)))
           (to-shell (drgnx-terminal--collapse-chords (plist-get split :to-shell))))
      (when (or to-drgnx to-shell)
        (cons "In the terminal"
              (append (when to-drgnx (list (format "Reach drgnx: %s" (string-join to-drgnx ", "))))
                      (mapcar (lambda (k)
                                (let ((title (drgnx-terminal--key-title k)))   ; nil for "C-k chords"
                                  (format "%s goes to the shell (%soutside the terminal, or the palette)"
                                          k (if title (concat title ": ") ""))))
                              to-shell)))))))

;;;; The terminal's keymap: raw input, but for the keys that reach drgnx

(defconst drgnx-term--raw-symbols
  '(return tab backspace delete escape insert left up right down home end prior next
           f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12)
  "The function keys a terminal sends to its program, alone and with C-, M-, S- and C-S-.")

(defun drgnx-term--raw-events ()
  "Every event the terminal's keymap may send to the program: ASCII control characters (not ESC), M- plus any ASCII
character, and `drgnx-term--raw-symbols' with modifiers."
  (append (number-sequence 0 26) (number-sequence 28 31) '(127)
          (mapcar (lambda (c) (logior c drgnx-terminal--meta-bit)) (number-sequence 0 127))
          (mapcan (lambda (sym)
                    (mapcar (lambda (mods) (event-convert-list (append mods (list sym))))
                            '(nil (control) (meta) (shift) (control shift))))
                  drgnx-term--raw-symbols)))

(defun drgnx-term--mouse-filter (cmd)
  "A mouse binding's filter: CMD while the terminal's program tracks the mouse (and `drgnx-term-mouse-reporting'),
else nil (Emacs's own binding)."
  (and drgnx-term-mouse-reporting
       (eq (plist-get (and drgnx-view-patch (drgnx-view-patch-term drgnx-view-patch)) :mouse_tracking) t) cmd))

(defun drgnx-term--mouse-shift-filter (cmd)
  "A Shift-mouse binding's filter: as `drgnx-term--mouse-filter', with `drgnx-term-mouse-shift-capture' on."
  (and drgnx-term-mouse-shift-capture (drgnx-term--mouse-filter cmd)))

(defconst drgnx-term--mouse-events
  '(down-mouse-1 mouse-1 drag-mouse-1 down-mouse-2 mouse-2 down-mouse-3 mouse-3 wheel-up wheel-down mouse-4 mouse-5)
  "The mouse events a program that tracks the mouse is sent (with Shift: `drgnx-term-mouse-shift-capture').")

(defun drgnx-term--fill-map (map drgnx)
  "Bind in MAP every raw event (`drgnx-term--raw-events') to `drgnx-term-send-event', but for the reserved keys, the
events in DRGNX (those reach drgnx: their raw binding goes) and events bound to something else (a terminal key)."
  (dolist (ev (drgnx-term--raw-events))
    (unless (member (drgnx-terminal--keys-vector ev) drgnx-term-reserved-keys)
      (let ((cur (lookup-key map (vector ev))))
        (cond ((memql ev drgnx) (when (eq cur #'drgnx-term-send-event) (define-key map (vector ev) nil t)))
              ((or (null cur) (numberp cur)) (define-key map (vector ev) #'drgnx-term-send-event)))))))

(defvar drgnx-term-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [remap self-insert-command] #'drgnx-term-send-event)
    (dolist (ev drgnx-term--mouse-events)
      (define-key m (vector ev) '(menu-item "" drgnx-term-mouse :filter drgnx-term--mouse-filter))
      (define-key m (vector (event-convert-list (list 'shift ev)))
                  '(menu-item "" drgnx-term-mouse :filter drgnx-term--mouse-shift-filter)))
    (drgnx-term--fill-map m nil)
    m)
  "A terminal's raw input: every key goes to the program, but for `drgnx-term-reserved-keys' and the keys the key
profile has reach drgnx (`drgnx-term-apply-keys'); the mouse goes to it while it tracks the mouse.")

(defun drgnx-term-apply-keys (&rest _)
  "The terminal's keymap follows the key profile: the first events of the keys that reach drgnx
\(`drgnx-terminal-key-split') are no longer sent to the program; the others are again.  Runs at the module's setup
and after `drgnx-keys-apply'."
  (drgnx-term--fill-map drgnx-term-mode-map
                        (mapcar (lambda (k) (aref (key-parse k) 0))
                                (plist-get (drgnx-terminal-key-split) :to-drgnx))))

;;;; Copy, paste, the mouse, focus

(defun drgnx-terminal-copy ()
  "Copy the selected text of the terminal to the kill ring and deselect it (`drgnx-term-selection-clear-on-copy');
with no selection do nothing."
  (interactive)
  (when (use-region-p)
    (copy-region-as-kill (region-beginning) (region-end))
    (when drgnx-term-selection-clear-on-copy (deactivate-mark))))

(defun drgnx-term--filter-substring (beg end delete)
  "`filter-buffer-substring-function' of a terminal buffer: copied text loses its trailing spaces
\(`drgnx-term-clipboard-trim-trailing-spaces') and has `drgnx-term-clipboard-codepoint-map' applied."
  (let ((s (buffer-substring--filter beg end delete)))
    (when drgnx-term-clipboard-trim-trailing-spaces
      (setq s (replace-regexp-in-string "[ \t]+$" "" s)))
    (when drgnx-term-clipboard-codepoint-map
      (setq s (mapconcat (lambda (c)
                           (or (seq-some (lambda (m) (and (<= (nth 0 m) c (nth 1 m)) (nth 2 m)))
                                         drgnx-term-clipboard-codepoint-map)
                               (string c)))
                         s "")))
    s))

(defun drgnx-term--unsafe-paste-p (text)
  "Non-nil when pasting TEXT could run commands (`drgnx-term-clipboard-paste-protection'): it holds the end of a
bracketed paste, or a line break while the program did not ask for bracketed paste (or that is not trusted)."
  (and drgnx-term-clipboard-paste-protection
       (or (string-search "\e[201~" text)
           (and (string-match-p "[\n\r]" text)
                (not (and drgnx-term-clipboard-paste-bracketed-safe
                          (eq (plist-get (and drgnx-view-patch (drgnx-view-patch-term drgnx-view-patch))
                                         :bracketed_paste)
                              t)))))))

(defun drgnx-term-paste ()
  "Paste the kill ring's newest text into the terminal (bracketed when its program asked: `term/paste'); text that
could run commands asks first (`drgnx-term-clipboard-paste-protection')."
  (interactive)
  (when-let* ((text (ignore-errors (current-kill 0)))
              ((or (not (drgnx-term--unsafe-paste-p text))
                   (yes-or-no-p (format "This paste has %d lines and could run commands at once.  Paste it? "
                                        (length (split-string text "[\n\r]+" t)))))))
    (drgnx-term--send "term/paste" (list :text text))))

(defun drgnx-terminal--in-terminal-p () (derived-mode-p 'drgnx-term-mode))

(defvar-local drgnx-term--size nil "The (COLS ROWS) the worker was last told.")

(defun drgnx-term--mouse-cell (posn)
  "The screen's (COL . ROW) of POSN, or nil above the screen."
  (when-let* ((pos (posn-point posn)) (size drgnx-term--size))
    (let* ((last (line-number-at-pos (point-max))) (line (line-number-at-pos pos))
           (row (- line (- last (nth 1 size)) 1)))
      (when (>= row 0)
        (cons (car (posn-col-row posn)) row)))))

(defun drgnx-term-mouse (event)
  "Send the mouse EVENT to the terminal's program (it tracks the mouse: `drgnx-term--mouse-filter')."
  (interactive "e")
  (let* ((type (event-basic-type event)) (mods (event-modifiers event))
         (button (pcase type
                   ((or 'mouse-1 'wheel-up 'mouse-4) (if (memq type '(wheel-up mouse-4)) 4 1))
                   ((or 'mouse-2) 2) ((or 'mouse-3) 3) ((or 'wheel-down 'mouse-5) 5) (_ 0)))
         (kind (cond ((memq type '(wheel-up wheel-down mouse-4 mouse-5)) "press")
                     ((memq 'down mods) "press")
                     ((memq 'drag mods) "release")
                     (t "release")))
         (cell (drgnx-term--mouse-cell (event-start event))))
    (when cell
      (with-current-buffer (window-buffer (posn-window (event-start event)))
        (drgnx-term--send "term/mouse"
                          (list :kind kind :button button :col (car cell) :row (cdr cell)
                                :mods (vconcat (delq nil (mapcar (lambda (m) (alist-get m drgnx-term--modifier-names))
                                                                 mods)))))))))

(defun drgnx-term--selected (window)
  "`window-selection-change-functions' of a terminal buffer: tell its program it gained or lost the focus; one that
lost it gets the releases of the keys still held in it."
  (let ((in (eq window (selected-window))))
    (with-current-buffer (window-buffer window)
      (unless in (drgnx-term--release-all (current-buffer)))
      (drgnx-term--send "term/focus" (list :in (if in t :false))))
    (drgnx-term--key-gate)))

;;;; Settings

(defvar drgnx-term-scrollback-lines)

(defun drgnx-term--apply-scrollback ()
  "`:apply' of `drgnx-term-scrollback-lines': every live terminal's worker trims or fills its buffer at once."
  (maphash (lambda (_ b)
             (when (buffer-live-p b)
               (with-current-buffer b
                 (drgnx-term--send "term/config"
                                   (list :config (vector (vector "scrollback-lines" drgnx-term-scrollback-lines)))))))
           drgnx-term--buffers))

(drgnx-defsetting drgnx-term-scrollback-lines 10000
  "How many rows a terminal's buffer keeps above its screen.  A change trims or fills every terminal at once.  The
terminal itself remembers at least 10,000 lines whatever this says, so Find in Terminal and copy reach further."
  :type 'natnum :group 'drgnx :scope 'global :agents 'never :schema 'natnum :apply #'drgnx-term--apply-scrollback)

;; the setting's variable, read before its definition below
(defvar drgnx-term-clipboard-write)

(defun drgnx-term--clipboard-config ()
  "The `term/config' entry of `drgnx-term-clipboard-write'."
  (vector "clipboard-write" (if drgnx-term-clipboard-write t :false)))

(defun drgnx-term--apply-clipboard ()
  "`:apply' of `drgnx-term-clipboard-write': every live terminal's worker allows or denies writes at once."
  (maphash (lambda (_ b)
             (when (buffer-live-p b)
               (with-current-buffer b
                 (drgnx-term--send "term/config" (list :config (vector (drgnx-term--clipboard-config)))))))
           drgnx-term--buffers))

(drgnx-defsetting drgnx-term-clipboard-write t
  "Whether a program in a terminal may write the clipboard (OSC 52): what it writes goes to the kill ring.  A
program never reads the clipboard: a terminal refuses every read."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean :apply #'drgnx-term--apply-clipboard)

;; Ghostty's options (`drgnx-term-settings-options'): the worker's live ones go as one `term/config'

(defun drgnx-term--face-hex (face attribute)
  "FACE's ATTRIBUTE (`:foreground' or `:background', through its inheritance and `default') as \"#rrggbb\", or \"\"
when it has none (a terminal frame's unspecified colour)."
  (let ((c (if (eq attribute :foreground) (face-foreground face nil 'default) (face-background face nil 'default))))
    (if-let* ((rgb (drgnx-color-rgb c))) (drgnx-color-hex rgb) "")))

(drgnx-epoch-define 'term-theme
                    :doc "Raised when a theme is enabled or disabled, or a colour face of the terminal changes
\(`drgnx-term--theme-changed'): colours are read again.")
(drgnx-memo-define term-colours :on frame :keys ((drgnx-epoch 'term-theme))
                   :doc "The worker's `colours' for a frame (a text terminal's frame has other colours than a graphical
one), read from the faces again only after a theme change or a change of a face they read.  Weak on the frame.")

(defun drgnx-term--colours ()
  "The `colours' entry's value: the faces' foreground, background and cursor, then `drgnx-term-color-0' to 15 when
every one of them has a colour (else the worker keeps its palette).  The memo `term-colours' of the selected frame:
read again only after a theme change.  Shared: never changed in place."
  (drgnx-memo term-colours (selected-frame)
              (let ((ansi (mapcar (lambda (n) (drgnx-term--face-hex (intern (format "drgnx-term-color-%d" n)) :foreground))
                                  (number-sequence 0 15))))
                (vconcat (list (drgnx-term--face-hex 'drgnx-term-default :foreground)
                               (drgnx-term--face-hex 'drgnx-term-default :background)
                               (drgnx-term--face-hex 'drgnx-term-cursor :background))
                         (unless (member "" ansi) ansi)))))

(defun drgnx-term--worker-config ()
  "Every live setting the worker reads, as `term/config' entries `[NAME VALUE]', for the current terminal (a remote
one's images come only as direct data)."
  (vector (drgnx-term--clipboard-config)
          (vector "remote" (if drgnx-term--remote t :false))
          (vector "image-storage-limit" drgnx-term-image-storage-limit)
          (vector "image-file-medium" (if drgnx-term-image-file-medium t :false))
          (vector "image-max-bytes" drgnx-term-image-max-bytes)
          (vector "image-disk-max" drgnx-term-image-disk-max)
          (vector "image-fps" drgnx-term-image-fps)
          (vector "scrollback-bytes" drgnx-term-scrollback-bytes)
          (vector "cursor-style" drgnx-term-cursor-style)
          (vector "enquiry-response" drgnx-term-enquiry-response)
          (vector "title-report" (if drgnx-term-title-report t :false))
          (vector "grapheme-width-method" drgnx-term-grapheme-width-method)
          (vector "detached-keep" drgnx-term-detached-keep)
          (vector "colours" (drgnx-term--colours))))

(defun drgnx-term--apply-config ()
  "`:apply' of the worker's live settings: every live terminal's worker takes them all at once."
  (maphash (lambda (_ b)
             (when (buffer-live-p b)
               (with-current-buffer b (drgnx-term--send "term/config" (list :config (drgnx-term--worker-config))))))
           drgnx-term--buffers))

(defun drgnx-term--word-syntax (chars)
  "A syntax table where CHARS end a word and every other printable ASCII character is part of one."
  (let ((st (make-syntax-table)))
    (dolist (c (number-sequence 33 126))
      (modify-syntax-entry c (if (string-search (string c) chars) "." "w") st))
    (dolist (c (string-to-list chars))
      (modify-syntax-entry c (if (memq c '(?\s ?\t)) " " ".") st))
    st))

(drgnx-memo-define term-word-syntax :keys (drgnx-term-selection-word-chars)
                   :doc "The terminals' word syntax table, one for every terminal buffer, built again when
`drgnx-term-selection-word-chars' changes.")

(defun drgnx-term--set-locals ()
  "This terminal buffer's local state from the settings: copy on select, the word characters (one syntax table every
terminal shares, the memo `term-word-syntax'), the copy filter."
  (setq-local mouse-drag-copy-region (and drgnx-term-copy-on-select t))
  (setq-local filter-buffer-substring-function #'drgnx-term--filter-substring)
  (set-syntax-table (drgnx-memo term-word-syntax nil (drgnx-term--word-syntax drgnx-term-selection-word-chars))))

(defun drgnx-term--apply-local ()
  "`:apply' of the settings a terminal buffer holds locally: every terminal buffer takes them at once."
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'drgnx-term-mode)
      (with-current-buffer b (drgnx-term--set-locals)))))

;;;; The view

(defconst drgnx-term--cursor-types
  '(("block" . box) ("block_hollow" . hollow) ("bar" . (bar . 2)) ("underline" . (hbar . 2)))
  "The worker's cursor shapes as `cursor-type' values.")

(defun drgnx-term--pad (pos n)
  "Draw the cursor N cells past POS, the end of its row (N 0: no padding)."
  (let ((ov drgnx-term--pad-overlay))
    (if (<= n 0)
        (when ov (overlay-put ov 'after-string nil))
      (unless ov (setq ov (setq drgnx-term--pad-overlay (make-overlay pos pos nil t nil))))
      (move-overlay ov pos pos)
      (let ((s (make-string (1+ n) ?\s)))
        (put-text-property n (1+ n) 'cursor t s)
        (overlay-put ov 'after-string s)))))

(defvar-local drgnx-term--cursor-marker nil "Where the cursor was last placed (a window there follows it).")

(defun drgnx-term--place-cursor (&optional all)
  "Point and the cursor where the worker's cursor is (the last patch's `term'), in the current terminal buffer.  A
window scrolled away from the cursor stays where it is unless ALL or `drgnx-term-scroll-to-bottom' has `output'."
  (when-let* ((cur (plist-get (drgnx-view-patch-term drgnx-view-patch) :cursor))
              (beg (drgnx-view-row-start drgnx-view (nth 0 cur))))
    (let* ((eol (save-excursion (goto-char beg) (line-end-position)))
           (want (+ beg (nth 1 cur))) (pos (min want eol))
           (old (and drgnx-term--cursor-marker (marker-position drgnx-term--cursor-marker)))
           (follow (or all (memq 'output drgnx-term-scroll-to-bottom))))
      (setq cursor-type (and (eq (nth 3 cur) t) (or (cdr (assoc (nth 2 cur) drgnx-term--cursor-types)) 'box)))
      (drgnx-term--pad pos (- want pos))
      (goto-char pos)
      (dolist (w (get-buffer-window-list nil nil t))
        (when (or follow (null old) (= (window-point w) old))
          (set-window-point w pos)))
      (set-marker (or drgnx-term--cursor-marker (setq drgnx-term--cursor-marker (make-marker))) pos))))

(defvar drgnx-term-link-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-2] #'drgnx-term-open-link)
    m)
  "The keymap on an OSC 8 link's text: a click opens it.")

(defun drgnx-term--buttons (view keys)
  "The OSC 8 links of VIEW's rows KEYS (their `drgnx-term-link' text) become buttons."
  (dolist (key keys)
    (when-let* ((beg (drgnx-view-row-start view key)))
      (let ((end (save-excursion (goto-char beg) (line-end-position))) (pos beg))
        (while (< pos end)
          (let ((next (next-single-property-change pos 'drgnx-term-link nil end)))
            (when (get-text-property pos 'drgnx-term-link)
              (with-silent-modifications
                (add-text-properties pos next (list 'mouse-face 'highlight 'keymap drgnx-term-link-map 'follow-link t
                                                    'help-echo (get-text-property pos 'drgnx-term-link)))))
            (setq pos next)))))))

(defconst drgnx-term--images-max 64 "The most images a terminal's buffer keeps made (an LRU).")

(defvar-local drgnx-term--images nil
  "The images this terminal's rows show: (FILE . IMAGE), most recent first, at most `drgnx-term--images-max'; the
evicted one is `image-flush'ed.")

(defun drgnx-term--image (file)
  "The image of canvas FILE, from this buffer's LRU."
  (if-let* ((hit (assoc file drgnx-term--images)))
      (progn (unless (eq hit (car drgnx-term--images))
               (setq drgnx-term--images (cons hit (delq hit drgnx-term--images))))
             (cdr hit))
    (let ((image (create-image file 'png nil :scale 1 :ascent 100)))
      (push (cons file image) drgnx-term--images)
      (when (> (length drgnx-term--images) drgnx-term--images-max)
        (let ((tail (nthcdr (1- drgnx-term--images-max) drgnx-term--images)))
          (dolist (old (cdr tail)) (image-flush (cdr old)))
          (setcdr tail nil)))
      image)))

(defun drgnx-term--draw-images (view keys)
  "The image slices of VIEW's rows KEYS (their `drgnx-term-image' text, `[FILE X Y W H ALT]') shown: the cells display
their row's slice of the canvas FILE, exactly one line tall; where PNGs cannot be drawn, or FILE is \"\", the
placement's first row shows ALT."
  (let ((graphic (and (display-images-p) (image-type-available-p 'png))))
    (dolist (key keys)
      (when-let* ((beg (drgnx-view-row-start view key)))
        (let ((end (save-excursion (goto-char beg) (line-end-position))) (pos beg))
          (while (< pos end)
            (let ((next (next-single-property-change pos 'drgnx-term-image nil end))
                  (v (get-text-property pos 'drgnx-term-image)))
              (when v
                (let ((file (elt v 0)) (y (elt v 2)))
                  (with-silent-modifications
                    (cond ((and graphic (not (equal file "")))
                           (put-text-property pos next 'display
                                              (list (list 'slice (elt v 1) y (elt v 3) (elt v 4))
                                                    (drgnx-term--image file))))
                          ((eql y 0)
                           (put-text-property pos next 'display
                                              (propertize (elt v 5) 'face 'drgnx-term-image-alt)))))))
              (setq pos next))))))))

(defun drgnx-term--patched (view keys)
  "PATCHED of `drgnx-term-view': the inserter's overlays back, the images drawn, the links made buttons, then the
cursor; the key release gate follows the program's key event types."
  (drgnx-view-patch--patched view keys)
  (with-current-buffer (drgnx-view--buffer view)
    (drgnx-term--draw-images view keys)
    (unless drgnx-term-copy-mode
      (drgnx-term--buttons view keys)
      (drgnx-term--place-cursor))
    (when (eq (current-buffer) (window-buffer (selected-window))) (drgnx-term--key-gate))))

(defun drgnx-term--link-file (uri)
  "The file URI names (`file://' with no host or this host), or nil.  In a remote terminal the file is on its host (a
TRAMP name): with no host, `localhost' or the host its shell named; never a local file."
  (when (string-match "\\`file://\\([^/]*\\)\\(/.*\\)\\'" uri)
    (let ((host (match-string 1 uri)) (path (url-unhex-string (match-string 2 uri))))
      (if drgnx-term--remote
          (when (or (member host '("" "localhost")) (equal host drgnx-term--remote-host))
            (concat drgnx-term--remote path))
        (when (member host (list "" "localhost" (system-name))) path)))))

(defun drgnx-term-open-link (&optional pos)
  "Open the OSC 8 link at POS (the click's position, or point): a local file is visited, any other URI browsed."
  (interactive (list (when (mouse-event-p last-input-event) (posn-point (event-start last-input-event)))))
  (when-let* ((uri (get-text-property (or pos (point)) 'drgnx-term-link)))
    (if-let* ((file (drgnx-term--link-file uri)))
        (find-file-other-window file)
      (browse-url uri))))

(drgnx-view-define 'drgnx-term-view :render #'drgnx-view-patch-render :patched #'drgnx-term--patched
                   :slice drgnx-view-slice :delay 0 :follow-tail t :ack t :epoch-reset nil)

;;;; Copy mode and Find in Terminal

(defvar drgnx-term-copy-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [remap keyboard-quit] #'drgnx-term-copy-mode)
    m)
  "Copy mode's keymap: Emacs's own keys (isearch, the region, copying); quitting leaves copy mode.")

(defvar-local drgnx-term--find nil
  "The last Find in Terminal: (QUERY . the number of its matches in the view's model).")
(defvar-local drgnx-term--find-overlay nil "The match Find in Terminal shows.")
(defvar-local drgnx-term--find-pending nil
  "A Find answered before its model came: (QUERY HELD VERSION), shown when the view's model reaches VERSION.")

(define-minor-mode drgnx-term-copy-mode
  "Copy mode: the terminal stops drawing and its buffer takes Emacs's keys, so isearch, the region and
`kill-ring-save' work on its text; quitting (or this command again) goes back to the program, which drew on
meanwhile."
  :lighter " Copy"
  (unless (derived-mode-p 'drgnx-term-mode)
    (setq drgnx-term-copy-mode nil)
    (user-error "Not a terminal"))
  (if drgnx-term-copy-mode
      (progn (drgnx-view-patch-pause (current-buffer) t)
             (use-local-map drgnx-term-copy-mode-map))
    (use-local-map drgnx-term-mode-map)
    (deactivate-mark)
    (when drgnx-term--find-overlay (delete-overlay drgnx-term--find-overlay))
    (drgnx-view-patch-pause (current-buffer) nil)
    (when drgnx-view (drgnx-view-draw-now drgnx-view))
    (drgnx-term--place-cursor)))

(defun drgnx-term-find (query)
  "Find QUERY in everything the terminal remembers, newest first: point goes to the match, in copy mode.  Asked again
with the same text in copy mode (the screen still), it goes to the next older match (`drgnx-term-find-next')."
  (interactive (list (read-string "Find in terminal: " (car drgnx-term--find))))
  (unless (string-empty-p query)
    (if (and drgnx-term-copy-mode (equal query (car drgnx-term--find)))
        (drgnx-term-find-next)
      (let ((buffer (current-buffer)))
        (when (and drgnx-term--id (eq drgnx-term--state 'open) (drgnx-term--up-p))
          (drgnx-hub--call-on drgnx-hub--events "term/search" (list :id drgnx-term--id :query query :dir "up")
                              (lambda (r _e) (drgnx-term--found buffer query r))))))))

(defun drgnx-term--found (buffer query result)
  "The worker answered Find for QUERY in BUFFER with RESULT (`{found, held, model}'): the matches go to the view as
its model, a list `matches' newest first, whose first entry is shown once that model is here."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((held (or (plist-get result :held) 0)) (version (plist-get result :model)))
        (setq drgnx-term--find-pending nil)
        (if (or (zerop held) (not version))
            (progn (setq drgnx-term--find nil) (message "Find in terminal: no %s" query))
          (setq drgnx-term--find-pending (list query held version))
          (drgnx-term--find-show-pending))))))

(defun drgnx-term--find-show-pending ()
  "The pending Find's first match, once the view's model stream reached its version (the model and the answer come
on different paths, in either order)."
  (when-let* ((pending drgnx-term--find-pending) (state drgnx-view-patch)
              (at (drgnx-view-model-apply-queued (drgnx-view-patch-view state)))
              ((>= at (nth 2 pending))))
    (setq drgnx-term--find-pending nil drgnx-term--find (cons (nth 0 pending) (nth 1 pending)))
    (drgnx-term--find-step 'walk-to 0)))

(defun drgnx-term--model-queued (view _version)
  "A `drgnx-view-model-functions' handler: a terminal's model came after its Find's answer."
  (when-let* (((string-prefix-p "term:" view))
              (b (gethash (substring view 5) drgnx-term--buffers))
              ((buffer-live-p b)))
    (with-current-buffer b (drgnx-term--find-show-pending))))

(defun drgnx-term-find-next ()
  "Go to the next older match of the last Find in Terminal, wrapping, from the matches the editor holds."
  (interactive)
  (drgnx-term--find-step 'walk 1))

(defun drgnx-term-find-previous ()
  "Go to the next newer match of the last Find in Terminal, wrapping."
  (interactive)
  (drgnx-term--find-step 'walk -1))

(defun drgnx-term--find-step (verb n)
  "Move Find's selection by VERB (`walk' N steps, or `walk-to' N) in the view's model and show it; a match in a row
this buffer no longer draws is passed over in the same direction."
  (if (not drgnx-term--find)
      (user-error "Find in Terminal first")
    (let ((tries (cdr drgnx-term--find)) (id (drgnx-view-nav verb "matches" n)) (beg nil))
      (while (and id (not (setq beg (drgnx-view-row-start drgnx-view (drgnx-view-nav-field "key"))))
                  (> (cl-decf tries) 0))
        (setq id (drgnx-view-nav 'walk "matches" (if (< n 0) -1 1))))
      (if (not beg)
          (message "Find in terminal: no %s on screen" (car drgnx-term--find))
        (let* ((beg (+ beg (drgnx-view-nav-field "col"))) (end (+ beg (drgnx-view-nav-field "len"))))
          (unless drgnx-term-copy-mode (drgnx-term-copy-mode 1))
          (if drgnx-term--find-overlay
              (move-overlay drgnx-term--find-overlay beg end)
            (setq drgnx-term--find-overlay (make-overlay beg end))
            (overlay-put drgnx-term--find-overlay 'face 'drgnx-term-search-selected))
          (goto-char beg)
          (dolist (w (get-buffer-window-list nil nil t)) (set-window-point w beg)))))))

;;;; Rows above the buffer

(defun drgnx-term--fetch (buffer)
  "Ask BUFFER's worker for the rows missing above its first row (`term/fetch'); one ask at a time."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((top (and drgnx-view (drgnx-view-key-at (point-min)))))
        (when (and top (not drgnx-term--fetching) (not (equal top drgnx-term--top-done))
                   drgnx-term--id (eq drgnx-term--state 'open) (drgnx-term--up-p))
          (setq drgnx-term--fetching t)
          (drgnx-hub--call-on drgnx-hub--events "term/fetch" (list :id drgnx-term--id :before_key top)
                              (lambda (r _e)
                                (when (buffer-live-p buffer)
                                  (with-current-buffer buffer
                                    (setq drgnx-term--fetching nil)
                                    (unless (plist-get r :version) (setq drgnx-term--top-done top)))))))))))

(defun drgnx-term--scrolled (window start)
  "`window-scroll-functions' of a terminal buffer: at the buffer's top, ask for the rows above (from a timer)."
  (let ((b (window-buffer window)))
    (when (= start (with-current-buffer b (point-min)))
      (drgnx-timer-soon (cons 'drgnx-term-fetch b) 0 #'drgnx-term--fetch :args (list b) :owner b))))

;;;; Opening

(defun drgnx-term--terminfo ()
  "The folder holding Ghostty's compiled xterm-ghostty entry (`drgnx build' puts it in <data>/terminfo), or nil."
  (let ((dir (expand-file-name "terminfo" (drgnx-paths-dir 'data))))
    (and (file-exists-p (expand-file-name "x/xterm-ghostty" dir)) dir)))

(defun drgnx-term--term-entries ()
  "TERM and TERMINFO from `drgnx-term-term': xterm-ghostty only while its entry is compiled, else xterm-256color."
  (let ((dir (and (equal drgnx-term-term "xterm-ghostty") (drgnx-term--terminfo))))
    (cond (dir (list "TERM=xterm-ghostty" (concat "TERMINFO=" dir)))
          ((equal drgnx-term-term "xterm-ghostty") (list "TERM=xterm-256color" "TERMINFO"))
          (t (list (concat "TERM=" drgnx-term-term) "TERMINFO")))))

(defun drgnx-term--integration-entries ()
  "The shell integration's entries (etc/shell/drgnx.*, docs/guide/terminal.md): DRGNX_TERMINAL, the features
\(`drgnx-term-shell-integration-features'; unset when `drgnx-term-shell-integration' is none), the one shell meant, the
ssh choice; Ghostty's own variables from a Ghostty around this Emacs are unset."
  (append (list "DRGNX_TERMINAL=1" "TERM_PROGRAM=drgnx" (format "DRGNX_TERMINAL_SSH=%s" drgnx-term-ssh-terminfo)
                "GHOSTTY_BIN_DIR" "GHOSTTY_RESOURCES_DIR" "GHOSTTY_SHELL_INTEGRATION_XDG_DIR")
          (if (eq drgnx-term-shell-integration 'none)
              (list "GHOSTTY_SHELL_FEATURES")
            (list (concat "GHOSTTY_SHELL_FEATURES=" (string-join drgnx-term-shell-integration-features ","))))
          (if (memq drgnx-term-shell-integration '(detect none))
              (list "DRGNX_TERMINAL_SHELL")
            (list (concat "DRGNX_TERMINAL_SHELL=" (symbol-name drgnx-term-shell-integration))))))

(defvar server-process)

(drgnx-epoch-define 'term-env-set :watch '(process-environment)
                    :doc "Raised when `process-environment' is set: `setenv' edits it in place, so the list alone does
not show the change.")
(drgnx-memo-define term-env
  :keys ((drgnx-epoch 'term-env-set) process-environment drgnx-term-env drgnx-term-term
         drgnx-term-shell-integration drgnx-term-shell-integration-features drgnx-term-ssh-terminfo
         (and (drgnx-term--terminfo) t)
         (and (boundp 'server-process) (process-live-p server-process) server-process))
  :doc "The terminals' environment (`drgnx-term--env'), built once a session and again when what it is
made of changes: `process-environment' (set, or bound to another list), the terminal's settings, the compiled
terminfo entry, the live server.")

(defun drgnx-term--env ()
  "The program's whole environment, as `[[NAME, VALUE]…]': `drgnx-term-env', then drgnx's terminal entries (TERM
from `drgnx-term-term', `drgnx-term--integration-entries'), then `drgnx-terminal-environment', then this Emacs's; an
entry without `=' unsets its name.  The memo `term-env': shared, never changed in place."
  (drgnx-memo term-env nil
              (let ((seen (make-hash-table :test #'equal)) (out nil))
                (dolist (e (append drgnx-term-env
                                   (drgnx-term--term-entries)
                                   (list "COLORTERM=truecolor" (format "INSIDE_EMACS=%s,drgnx" emacs-version)
                                         "COLUMNS" "LINES")
                                   (drgnx-term--integration-entries)
                                   (drgnx-terminal-environment) process-environment))
                  (let* ((i (string-search "=" e)) (name (if i (substring e 0 i) e)))
                    (unless (gethash name seen)
                      (puthash name t seen)
                      (when i (push (vector name (substring e (1+ i))) out)))))
                (vconcat (nreverse out)))))

(defconst drgnx-term--local-only '("DRGNX_SERVER_NAME" "EDITOR" "VISUAL" "GIT_EDITOR")
  "The environment names a remote terminal's ssh does not get: they name this machine's Emacs.")

(defun drgnx-term--remote-env ()
  "The environment of a remote terminal's local program (ssh): `drgnx-term--env' without the local-only names; TERM
xterm-256color, which every host knows, unless `drgnx-term-ssh-terminfo' is `install' (its script sets TERM, and
infocmp reads the local TERMINFO)."
  (let ((install (eq drgnx-term-ssh-terminfo 'install)))
    (vconcat (delq nil (mapcar (lambda (e)
                                 (let ((name (aref e 0)))
                                   (cond ((member name drgnx-term--local-only) nil)
                                         ((and (equal name "TERMINFO") (not install)) nil)
                                         ((and (equal name "TERM") (not install)) (vector "TERM" "xterm-256color"))
                                         (t e))))
                               (drgnx-term--env))))))

(defun drgnx-term--remote-program (dir)
  "The program of a terminal in remote DIR (`drgnx-term-remote-command'), or nil when its method has none.  With
`drgnx-term-ssh-terminfo' `install', an ssh runs through etc/shell/drgnx-ssh-terminfo.sh, in the terminal's PTY."
  (let ((command (drgnx-term-remote-command dir)))
    (if (and command (equal (car command) "ssh") (eq drgnx-term-ssh-terminfo 'install))
        ;; ssh -t ARGS… HOST SCRIPT → /bin/sh drgnx-ssh-terminfo.sh SCRIPT ARGS… HOST
        (append (list "/bin/sh" (expand-file-name "etc/shell/drgnx-ssh-terminfo.sh" drgnx-dir) (car (last command)))
                (butlast (cddr command)))
      command)))

(defun drgnx-term--window-size (window)
  "WINDOW's body in cells and its frame's cell in px: (COLS ROWS [W H])."
  (let ((f (window-frame window)))
    (list (max 2 (window-body-width window)) (max 1 (window-body-height window))
          (vector (frame-char-width f) (frame-char-height f)))))

(defun drgnx-term--open (buffer)
  "Ask the hub for BUFFER's terminal (`term/open') on the subscribed connection, where its rows come back; while the
hub is not up, connect, and the subscription opens it (`drgnx-term--connected')."
  (with-current-buffer buffer
    (if (not (drgnx-term--up-p))
        (progn (setq drgnx-term--state nil) (drgnx-hub-connect))
      (setq drgnx-term--state 'opening)
      (let* ((window (or (get-buffer-window buffer) (selected-window)))
             (size (drgnx-term--window-size window)))
        (setq drgnx-term--size (list (nth 0 size) (nth 1 size)))
        (setq drgnx-term--started (float-time))
        (drgnx-hub--call-on drgnx-hub--events "term/open"
                            (append
                             ;; a remote terminal's program (ssh) runs locally, in the home folder
                             (list :dir (if drgnx-term--remote (let ((default-directory "/")) (expand-file-name "~"))
                                          (expand-file-name default-directory))
                                   :command (vconcat drgnx-term--program)
                                   :env (if drgnx-term--remote (drgnx-term--remote-env) (drgnx-term--env))
                                   :cols (nth 0 size) :rows (nth 1 size)
                                   :cell_px (nth 2 size) :class drgnx-term-class :window drgnx-term-scrollback-lines
                                   :config (drgnx-term--worker-config)
                                   ;; where a reattach opens it again: the panel is a side window
                                   :place (if (window-parameter window 'window-side) "panel" "editor"))
                             (and drgnx-term--remote (list :remote drgnx-term--remote))
                             (and drgnx-term-linux-cgroup-memory-limit
                                  (list :memory_max drgnx-term-linux-cgroup-memory-limit))
                             (and drgnx-term-linux-cgroup-processes-limit
                                  (list :tasks_max (number-to-string drgnx-term-linux-cgroup-processes-limit))))
                            (lambda (r e) (drgnx-term--opened buffer r e)))))))

(defun drgnx-term--opened (buffer result error)
  "`term/open' answered RESULT (or ERROR) for BUFFER: it becomes the terminal's view; the queued input goes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if error
          (progn
            (setq drgnx-term--state 'failed mode-line-process ":failed")
            (message "The terminal could not start: %s" (or (plist-get error :message) error)))
        (setq drgnx-term--id (plist-get result :id) drgnx-term--state 'open)
        (puthash drgnx-term--id buffer drgnx-term--buffers)
        (drgnx-view-patch-attach (plist-get result :view) drgnx-term-class :type 'drgnx-term-view)
        ;; the first reset may have come before this answer, when no buffer showed the view: ask for another
        (unless (drgnx-view-patch-version drgnx-view-patch)
          (funcall drgnx-view-patch-send-function "view/resync"
                   (list :view (plist-get result :view) :class drgnx-term-class :version 0)))
        (drgnx-term--flush)))))

(defun drgnx-term--connected ()
  "`drgnx-hub-connected-functions': terminals not opened yet open now; the others' queued input goes; the terminals
an earlier drgnx left running are offered (`drgnx-term-reattach')."
  (dolist (b (append (drgnx-term-buffers)
                     (seq-filter (lambda (b) (and (eq (buffer-local-value 'major-mode b) 'drgnx-term-mode)
                                                  (null (buffer-local-value 'drgnx-term--state b))))
                                 (buffer-list))))
    (with-current-buffer b
      (if (null drgnx-term--state) (drgnx-term--open b) (drgnx-term--flush))))
  ;; terminals an earlier drgnx left running
  (drgnx-term--look))

(defvar drgnx-term--notices nil "Terminal id → its last notification (a notice item), newest first.")

(defun drgnx-term--killed ()
  "`kill-buffer-hook' of a terminal buffer: its terminal is closed and forgotten."
  (when drgnx-term--id
    (remhash drgnx-term--id drgnx-term--buffers)
    (let ((keys (list drgnx-term--id (concat "clipboard:" drgnx-term--id))))
      (when (seq-some (lambda (k) (assoc k drgnx-term--notices)) keys)
        (setq drgnx-term--notices (cl-remove-if (lambda (n) (member (car n) keys)) drgnx-term--notices))
        (drgnx-term--post-notices)))
    (when (and (eq drgnx-term--state 'open) (drgnx-term--up-p))
      (drgnx-hub--call-on drgnx-hub--events "term/close" (list :id drgnx-term--id) #'ignore))
    (setq drgnx-term--id nil)))

;;;; Resizing

(defvar-local drgnx-term--resizes 0 "How many `term/resize' this terminal sent (for tests).")

(defun drgnx-term--resize (buffer)
  "Tell BUFFER's worker the size of the window showing it, if that changed (`term/resize')."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((w (get-buffer-window buffer)))
        (let ((size (drgnx-term--window-size w)))
          (unless (equal (list (nth 0 size) (nth 1 size)) drgnx-term--size)
            (setq drgnx-term--size (list (nth 0 size) (nth 1 size)))
            (cl-incf drgnx-term--resizes)
            (drgnx-term--send "term/resize" (list :cols (nth 0 size) :rows (nth 1 size) :cell_px (nth 2 size)))))))))

(defvar-local drgnx-term--visible t "Whether the worker was last told a window shows this terminal (`term/visible').")

(defun drgnx-term--windows-changed (&rest _)
  "The windows changed: each terminal whose window's size changed resizes once the sizes settle (50 ms); one a window
shows now, or no longer, tells its worker (image animations play only while one does)."
  (dolist (b (drgnx-term-buffers))
    (let ((w (get-buffer-window b)))
      (unless (eq (and w t) (buffer-local-value 'drgnx-term--visible b))
        (with-current-buffer b
          (setq drgnx-term--visible (and w t))
          (drgnx-term--send "term/visible" (list :visible (if w t :false)))))
      (when w
        (let ((size (drgnx-term--window-size w)))
          (unless (equal (list (nth 0 size) (nth 1 size)) (buffer-local-value 'drgnx-term--size b))
            (drgnx-timer-debounce (cons 'drgnx-term-resize b) 0.05 #'drgnx-term--resize :args (list b) :owner b)))))))

;;;; Events

(defvar drgnx-term-exit-functions nil
  "Called in a terminal's buffer with the exit DATA (`:code', `:signal') when its program ended, before a shell's
buffer goes.  A caller watching its terminal adds to it buffer-locally (Export Keys forgets the typed keys).")

(defun drgnx-term--abnormal-p (data)
  "Non-nil when the program failed (DATA: a code other than 0, or a signal) within
`drgnx-term-abnormal-command-exit-runtime' of its start."
  (and (or (plist-get data :signal) (not (eql (plist-get data :code) 0)))
       drgnx-term--started
       (< (* 1000 (- (float-time) drgnx-term--started)) drgnx-term-abnormal-command-exit-runtime)))

(defun drgnx-term--exited (data)
  "The terminal's program ended (DATA: its code or signal): a shell's buffer goes, a command's stays to be read; so
does a shell's that failed at once (`drgnx-term-abnormal-command-exit-runtime'), or every one with
`drgnx-term-wait-after-command'."
  (setq drgnx-term--state 'exited)
  (remhash drgnx-term--id drgnx-term--buffers)
  (setq drgnx-term--id nil)
  (run-hook-with-args 'drgnx-term-exit-functions data)
  (cond
   ;; ssh's 255: the connection was lost, or never made; the buffer stays, with Reconnect
   ((and drgnx-term--remote (eql (plist-get data :code) 255))
    (setq mode-line-process ":connection lost"
          header-line-format (list "Connection lost (exit 255)  "
                                   (buttonize "Reconnect" (lambda (_) (drgnx-term-reconnect)) nil
                                              "Run the same command in a new terminal here")))
    (force-mode-line-update))
   ((and drgnx-term--shell (not drgnx-term-wait-after-command) (not (drgnx-term--abnormal-p data)))
    (kill-buffer (current-buffer)))
   (t
    (setq mode-line-process
          (format ":%s" (if (plist-get data :signal) (format "signal %s" (plist-get data :signal))
                          (format "exit %s" (plist-get data :code)))))
    (force-mode-line-update))))

(defun drgnx-term--event (event data)
  "`drgnx-hub-event-functions': a `term/*' event goes to its terminal's buffer; `term/detached' (terminals another
drgnx left running) asks what is offered now."
  (when (equal event "term/detached")
    (drgnx-term--look))
  (when (and (stringp event) (string-prefix-p "term/" event))
    (when-let* ((b (gethash (plist-get data :id) drgnx-term--buffers)) ((buffer-live-p b)))
      (with-current-buffer b
        (pcase event
          ("term/exit" (drgnx-term--exited data))
          ("term/cwd" (drgnx-term--cwd (plist-get data :cwd)))
          ("term/title" (drgnx-term--title (plist-get data :title)))
          ("term/progress" (when drgnx-term-progress-style
                             (drgnx-term--progress (plist-get data :state) (plist-get data :value))))
          ("term/notify" (when drgnx-term-desktop-notifications
                           (drgnx-term--notify (plist-get data :title) (plist-get data :body))))
          ("term/bell" (ding t))
          ("term/prompt" (drgnx-term--prompt (plist-get data :kind)))
          ("term/clipboard-write"
           (when drgnx-term-clipboard-write
             (if drgnx-term--remote
                 (drgnx-term--remote-clipboard (plist-get data :data))
               (kill-new (plist-get data :data))))))))))

;;;; A remote program sets the clipboard

(defun drgnx-term--clipboard-host ()
  "The host a remote terminal's clipboard question names."
  (or drgnx-term--remote-host (drgnx-term-remote-host drgnx-term--remote) drgnx-term--remote))

(defun drgnx-term--remote-clipboard (text)
  "A remote program asked to put TEXT on the clipboard: `drgnx-term-remote-clipboard-write' says what happens; `ask'
keeps TEXT (the last one) and a notice asks, naming the host, never the text."
  (let ((host (drgnx-term--clipboard-host)))
    (cond ((or (eq drgnx-term-remote-clipboard-write 'allow) (member host drgnx-term-remote-clipboard-hosts))
           (kill-new text))
          ((eq drgnx-term-remote-clipboard-write 'ask)
           (setq drgnx-term--clipboard text)
           (setf (alist-get (concat "clipboard:" drgnx-term--id) drgnx-term--notices nil nil #'equal)
                 (list :id (concat "term:clipboard:" drgnx-term--id) :command 'terminal-clipboard-answer
                       :text (format "%s wants to set the clipboard" host)))
           (drgnx-term--post-notices)))))

(defun drgnx-term--clipboard-asking ()
  "The terminal buffers whose remote program waits for a clipboard answer."
  (seq-filter (lambda (b) (buffer-local-value 'drgnx-term--clipboard b)) (drgnx-term-buffers)))

(defun drgnx-term--clipboard-answered (buffer answer)
  "ANSWER (`allow', `always' or `deny') for BUFFER's clipboard question: the text goes on the clipboard or is
dropped; `always' adds the host to `drgnx-term-remote-clipboard-hosts' (written to your settings)."
  (with-current-buffer buffer
    (let ((text drgnx-term--clipboard) (host (drgnx-term--clipboard-host)))
      (setq drgnx-term--clipboard nil)
      (setq drgnx-term--notices (cl-remove (concat "clipboard:" drgnx-term--id) drgnx-term--notices
                                           :key #'car :test #'equal))
      (drgnx-term--post-notices)
      (when (eq answer 'always)
        (let ((hosts (append drgnx-term-remote-clipboard-hosts (list host))))
          (setq drgnx-term-remote-clipboard-hosts hosts)
          (require 'drgnx-settings-file)
          (drgnx-settings-file-put (drgnx-config-file 'settings) 'drgnx-settings nil
                                   'drgnx-term-remote-clipboard-hosts hosts)))
      (when (memq answer '(allow always)) (kill-new text)))))

(defun drgnx-term-clipboard-answer ()
  "Answer a remote program that asked to set the clipboard: Allow, Always for its host, or Deny."
  (interactive)
  (let ((asking (drgnx-term--clipboard-asking)))
    (if (null asking)
        (message "No remote program is waiting to set the clipboard")
      (with-current-buffer (car asking)
        (let* ((host (drgnx-term--clipboard-host)) (use-dialog-box nil)
               (answer (car (read-multiple-choice (format "%s wants to set the clipboard: " host)
                                                  `((?a "allow") (?l ,(format "always for %s" host)) (?d "deny"))))))
          (drgnx-term--clipboard-answered (current-buffer) (pcase answer (?a 'allow) (?l 'always) (_ 'deny))))))))

(defun drgnx-term--remote-cwd (cwd)
  "A remote terminal's CWD (as `drgnx-term--cwd' takes it) as a TRAMP folder on its host, or nil: the first host an
OSC 7 names is learned as the terminal's own; one naming another host (an ssh typed inside) is not followed."
  (let* ((parts (cond ((string-match "\\`file://\\([^/]*\\)\\(/.*\\)\\'" cwd)
                       (cons (match-string 1 cwd) (url-unhex-string (match-string 2 cwd))))
                      ((string-match "\\`kitty-shell-cwd://\\([^/]*\\)\\(/.*\\)\\'" cwd)
                       (cons (match-string 1 cwd) (match-string 2 cwd)))))
         ;; a bare path is the local folder ssh started in (the record's first cwd), never the host's
         (host (car parts)))
    (when parts
      (unless (or drgnx-term--remote-host (member host '("" "localhost")))
        (setq drgnx-term--remote-host host))
      (when (or (member host '("" "localhost")) (equal host drgnx-term--remote-host))
        (file-name-as-directory (concat drgnx-term--remote (cdr parts)))))))

(defun drgnx-term--cwd (cwd)
  "The shell says its directory is CWD (OSC 7: a `file://' URL, Ghostty's bash and zsh's `kitty-shell-cwd://HOST/PATH'
with the path raw, or a path): the buffer's `default-directory' follows, for a local folder; in a remote terminal, to
that folder on its host (`drgnx-term--remote-cwd'; not checked: that would wait on the connection)."
  (if drgnx-term--remote
      (when-let* ((dir (drgnx-term--remote-cwd cwd))) (setq default-directory dir))
    (drgnx-term--local-cwd cwd)))

(defun drgnx-term--local-cwd (cwd)
  "`drgnx-term--cwd' of a local terminal."
  (when-let* ((dir (cond ((string-prefix-p "file://" cwd) (drgnx-term--link-file cwd))
                         ((string-match "\\`kitty-shell-cwd://\\([^/]*\\)\\(/.*\\)\\'" cwd)
                          (and (member (match-string 1 cwd) (list "" "localhost" (system-name))) (match-string 2 cwd)))
                         (t cwd)))
              ((file-directory-p dir)))
    (setq default-directory (file-name-as-directory dir))))

(defvar-local drgnx-term--title nil "The title the program set (OSC 0/2).")

(defun drgnx-term--title (title)
  "The program set TITLE: the buffer, and so its tab, is named after it (or after `drgnx-term-title'); a remote
terminal's name starts with its host."
  (setq drgnx-term--title title)
  (let* ((title (or drgnx-term-title title))
         (host (and drgnx-term--remote
                    (or drgnx-term--host-name (setq drgnx-term--host-name (drgnx-term-remote-host drgnx-term--remote)))))
         (name (cond ((and host (string-empty-p title)) host)
                     (host (format "%s: %s" host title))
                     (t title))))
    (unless (string-empty-p name)
      (rename-buffer (format "*terminal: %s*" name) t))))

(defun drgnx-term--prompt (kind)
  "An OSC 133 mark of KIND: 3 a command's output starts, 4 it ended.  A command that ran at least
`drgnx-term-notify-on-command-finish-after' seconds is told as `drgnx-term-notify-on-command-finish' says."
  (pcase kind
    (3 (setq drgnx-term--command-start (float-time)))
    (4 (when-let* ((start drgnx-term--command-start))
         (setq drgnx-term--command-start nil)
         (let ((took (- (float-time) start)))
           (when (and (>= took drgnx-term-notify-on-command-finish-after)
                      (pcase drgnx-term-notify-on-command-finish
                        ('always t)
                        ('unfocused (not (and (frame-focus-state)
                                              (eq (window-buffer (selected-window)) (current-buffer)))))))
             (when (memq 'bell drgnx-term-notify-on-command-finish-action) (ding t))
             (when (memq 'notify drgnx-term-notify-on-command-finish-action)
               (drgnx-term--notify "Command finished" (format "%s, after %d s" (buffer-name) (round took))))))))))

(defun drgnx-term--progress (state value)
  "OSC 9;4 progress STATE (0 none) and VALUE (0-100, -1 none): shown in the mode line, and so on the tab."
  (setq mode-line-process (cond ((eq state 0) nil)
                                ((eq state 2) ":error")
                                ((and (natnump value) (memq state '(1 4))) (format ":%d%%" value))
                                (t ":busy")))
  (force-mode-line-update))

(defun drgnx-term--notify (title body)
  "The program asked for a desktop notification (TITLE, BODY): it is a drgnx notice until its terminal goes."
  (setf (alist-get drgnx-term--id drgnx-term--notices nil nil #'equal)
        (list :id (concat "term:" drgnx-term--id)
              :text (if (string-empty-p (or title "")) body (format "%s: %s" title body))))
  (drgnx-term--post-notices))

(defconst drgnx-term--colour-faces
  (cons 'drgnx-term-default (cons 'drgnx-term-cursor
                                  (mapcar (lambda (n) (intern (format "drgnx-term-color-%d" n))) (number-sequence 0 15))))
  "The faces `drgnx-term--colours' reads.")

(defun drgnx-term--face-touched (face &rest _)
  "`set-face-attribute' after-advice: a face the terminal's colours read changed with no theme change (Customize, a
`set-face-attribute' in the user's config): the colours are read again once the changes of the moment are in, so the
terminals follow at once, as they do for a theme."
  (when (memq face drgnx-term--colour-faces)
    (drgnx-timer-debounce 'term-face-change 0.1 #'drgnx-term--theme-changed :owner :core)))

(defun drgnx-term--theme-changed (&optional _theme)
  "A theme was enabled or disabled: every terminal repaints from the faces now, without a reset, and its worker
learns the new colours (a program reads them back)."
  (drgnx-epoch-bump 'term-theme)
  (dolist (b (drgnx-term-buffers)) (drgnx-view-patch-repaint b))
  (drgnx-term--apply-config))

;;;; Wide cells: each glyph within its two cells

;; The worker ends each wide character with a stop at its second cell's end (`(space :align-to (PX))'), so the
;; columns after it keep their place whatever width the font gives it.  A glyph wider than its two cells (an emoji
;; at ~19 px over 2 × 8 in a 13 px monospace) would still push the rest of its row right, up to the next stop.  The
;; guard below (the buffer's `drgnx-view-patch-guard-function') measures each wide cluster once per cell width and
;; draws one that overflows at a smaller height (a `(height F)' display over the cluster's characters, so a joined
;; emoji stays one glyph).  The fit guard of other views (an ellipsis) never runs on a terminal's rows: a terminal's
;; text is the program's.

(defvar drgnx-term-cell-width-function #'drgnx-term--cell-width
  "Called with no argument: a cell's width in px, or nil where glyphs are cells (a text terminal).  Tests set it.")

(defvar drgnx-term-cell-measure-function #'drgnx-term--cell-measure
  "Called with a string (with its display properties): its width in px as the terminal draws it.  Tests set it.")

(defvar drgnx-term--cell-scales (make-hash-table :test #'equal)
  "Wide cluster (a character, or a string of several) → (LIMIT . SPEC): the `(height F)' that draws it within LIMIT
px, or nil when it fits as it is.  Emptied when it holds 4,096 entries.")

(defun drgnx-term--cell-width ()
  "The cell's width in px on a graphical frame (its character width, as `term/open' sends it), else nil."
  (and (display-graphic-p) (frame-char-width)))

(defun drgnx-term--cell-measure (s)
  "S's width in px in the terminal's face (`drgnx-look-pixel-width': the glyphs' advances)."
  (drgnx-look-pixel-width s 'drgnx-term-default))

(defsubst drgnx-term--cluster-char-p (c)
  "Non-nil when C belongs to a wide cluster: a wide character, a joiner or selector, a regional indicator or a tag."
  (or (>= (char-width c) 2) (memq c '(#x200d #xfe0f #x20e3)) (<= #x1f1e6 c #x1f1ff) (<= #xe0020 c #xe007f)))

(defun drgnx-term--cluster-start (text lo end)
  "Where the wide cluster that ends before the stop at END starts in TEXT, not before LO (END: none).  A selector
\(❤️, 1️⃣) takes the narrow character before it."
  (let ((s end))
    (while (and (> s lo) (drgnx-term--cluster-char-p (aref text (1- s)))) (setq s (1- s)))
    (when (and (< s end) (> s lo) (memq (aref text s) '(#xfe0f #x20e3))) (setq s (1- s)))
    s))

(defun drgnx-term--cell-scale (cluster limit)
  "The `(height F)' display that draws CLUSTER (a character or a string) within LIMIT px, or nil when it fits.  F
is the ratio rounded down to a hundredth, lowered by 0.05 while the scaled cluster still measures wider (font sizes
round).  Memoised in `drgnx-term--cell-scales'."
  (let ((hit (gethash cluster drgnx-term--cell-scales)))
    (if (eql (car hit) limit)
        (cdr hit)
      (when (>= (hash-table-count drgnx-term--cell-scales) 4096) (clrhash drgnx-term--cell-scales))
      (let* ((s (if (characterp cluster) (string cluster) cluster))
             (w (funcall drgnx-term-cell-measure-function s))
             (spec (when (> w limit)
                     (let* ((f (/ (floor (* 100 limit) w) 100.0)) (sp (list 'height f)))
                       (while (and (> f 0.3) (> (funcall drgnx-term-cell-measure-function (propertize s 'display sp))
                                                limit))
                         (setq f (- f 0.05) sp (list 'height f)))
                       sp))))
        (puthash cluster (cons limit spec) drgnx-term--cell-scales)
        spec))))

(defun drgnx-term--cell-guard (_state text stops)
  "The terminal's guard over a row's STOPS (`drgnx-view-patch-guard-function'): each wide cluster before a stop
that is wider than two cells gets the `(height F)' display that draws it within them.  Returns the new text, or nil
when every cluster fits (or glyphs are cells)."
  (when-let* ((cell (funcall drgnx-term-cell-width-function)))
    (let ((limit (* 2 cell)) (lo 0) out)
      (dolist (stop stops)
        (let* ((end (car stop)) (s (drgnx-term--cluster-start text lo end)))
          (when-let* (((< s end))
                      (spec (drgnx-term--cell-scale (if (= (1+ s) end) (aref text s) (substring-no-properties text s end))
                                                    limit)))
            (unless out (setq out (copy-sequence text)))
            (put-text-property s end 'display spec out))
          (setq lo (1+ end))))
      out)))

;;;; The mode and the start

(define-derived-mode drgnx-term-mode nil "Terminal"
  "A terminal: its program runs in a worker of the hub, and this buffer shows the rows the worker sends.
Typing goes to the program (`drgnx-term-mode-map')."
  (setq buffer-undo-list t truncate-lines t)
  (setq-local scroll-margin 0)
  (setq-local hscroll-margin 0)
  (face-remap-add-relative 'default 'drgnx-term-default)
  (setq-local drgnx-view-patch-guard-function #'drgnx-term--cell-guard)
  (drgnx-term--set-locals)
  (add-hook 'kill-buffer-query-functions #'drgnx-term--confirm-close nil t)
  (add-hook 'window-scroll-functions #'drgnx-term--scrolled nil t)
  (add-hook 'window-selection-change-functions #'drgnx-term--selected nil t)
  (add-hook 'kill-buffer-hook #'drgnx-term--killed nil t))

(defun drgnx-term-start (dir &optional command)
  "A new terminal in DIR running the user's shell, or COMMAND (a program and its arguments) instead, shown by
`pop-to-buffer' (the rules put it in the panel); returns its buffer.  A shell's buffer goes when the shell ends; a
command's stays, so what it printed can be read.  In a remote DIR (a TRAMP name) the shell is the user's login shell on
that host (`drgnx-term-remote-command'); a COMMAND runs in a local folder only."
  (when (and command (file-remote-p dir)) (user-error "A command runs in a local folder only: %s" dir))
  (let* ((remote (and (not command) (file-remote-p dir)))
         (program (cond (command)
                        (remote (or (drgnx-term--remote-program dir)
                                    (user-error "No terminal reaches %s (method %s)" dir (file-remote-p dir 'method))))
                        (t (or drgnx-term-command (list (drgnx-terminal-shell))))))
         (buffer (generate-new-buffer "*terminal*")))
    (with-current-buffer buffer
      (drgnx-term-mode)
      (setq default-directory (file-name-as-directory (if remote dir (expand-file-name dir)))
            drgnx-term--program program
            drgnx-term--remote remote
            drgnx-term--shell (not command))
      (when remote (setq-local drgnx-chrome-tab-icon 'server) (drgnx-term--title "")))
    (pop-to-buffer buffer)
    (drgnx-term--open buffer)
    (when (and drgnx-term-input (not command))
      (with-current-buffer buffer (drgnx-term-send-string drgnx-term-input)))
    buffer))

(defun drgnx-term-start-directory (dir)
  "Where New Terminal starts when asked from DIR: `drgnx-term-working-directory' (`home' or a folder), else DIR."
  (pcase drgnx-term-working-directory
    ('home "~/")
    ((and (pred stringp) d) d)
    (_ dir)))

(defun drgnx-term--confirm-close ()
  "`kill-buffer-query-functions' of a terminal buffer (`drgnx-term-confirm-close-surface'): a command you run asks
before closing a terminal whose program runs (or any, with `always'); nothing else asks."
  (or (null this-command) noninteractive (not (eq drgnx-term--state 'open))
      (pcase drgnx-term-confirm-close-surface
        ('nil t)
        ('always (yes-or-no-p (format "Close the terminal %s? " (buffer-name))))
        (_ (or (not (memq (current-buffer) (drgnx-term--running-buffers)))
               (yes-or-no-p (format "A program still runs in %s.  Close it? " (buffer-name))))))))

;;;; Quitting: what still runs, and the clean exit

(defconst drgnx-term-list-wait 0.2
  "Seconds the quit question waits for the hub's `term/list'; with no answer every terminal counts as running.")

(defun drgnx-term--running-names (rows buffers)
  "The names of BUFFERS (terminal buffers) whose program runs by ROWS (`term/list''s answer): a shell at its prompt
does not; a terminal ROWS does not name counts as running."
  (delq nil (mapcar (lambda (b)
                      (let* ((id (buffer-local-value 'drgnx-term--id b))
                             (row (seq-find (lambda (r) (equal (plist-get r :id) id)) rows)))
                        (and (or (null row) (eq (plist-get row :running) t)) (buffer-name b))))
                    buffers)))

(defun drgnx-term--running-buffers ()
  "This Emacs's open terminals whose program still runs.  Asks the hub (`term/list'), waiting at most
`drgnx-term-list-wait'; with no answer every open terminal counts as running, so nothing stops unasked."
  (when-let* ((buffers (seq-filter (lambda (b) (eq (buffer-local-value 'drgnx-term--state b) 'open))
                                   (drgnx-term-buffers))))
    (let ((rows (condition-case nil (drgnx-hub-call-sync "term/list" nil drgnx-term-list-wait) (error :none))))
      (if (eq rows :none)
          buffers
        (let ((names (drgnx-term--running-names rows buffers)))
          (seq-filter (lambda (b) (member (buffer-name b) names)) buffers))))))


(defun drgnx-term-running ()
  "`drgnx-session-running-functions': with `drgnx-term-on-quit' `close', this Emacs's terminals whose program still
runs, by name (`drgnx-term--running-buffers'); with `ask' they are named by `drgnx-term-keepable' instead, and with
`keep' quitting stops none of them."
  (and (eq drgnx-term-on-quit 'close) (mapcar #'buffer-name (drgnx-term--running-buffers))))

(defvar drgnx-term--quit-keep nil
  "The ids of the terminals the last quit question found running: Keep Running keeps these.")

(defun drgnx-term-keepable ()
  "`drgnx-session-keepable-functions': with `drgnx-term-on-quit' `ask', this Emacs's terminals whose program still
runs, by name; the quit question then offers to keep them running."
  (when (eq drgnx-term-on-quit 'ask)
    (let ((buffers (drgnx-term--running-buffers)))
      (setq drgnx-term--quit-keep (mapcar (lambda (b) (buffer-local-value 'drgnx-term--id b)) buffers))
      (mapcar #'buffer-name buffers))))

(defvar drgnx-session-quit-keep)

(defun drgnx-term--kept-at-quit ()
  "The ids of this Emacs's terminals that keep running after it quits: every one with `drgnx-term-on-quit' `keep',
none with `close'; with `ask', those the question found running when it was answered Keep Running, none when Close
Them, and those whose program runs when it did not ask (a daemon's shutdown, a script's `kill-emacs')."
  (pcase drgnx-term-on-quit
    ('keep (delq nil (mapcar (lambda (b) (and (eq (buffer-local-value 'drgnx-term--state b) 'open)
                                              (buffer-local-value 'drgnx-term--id b)))
                             (drgnx-term-buffers))))
    ('close nil)
    (_ (pcase (bound-and-true-p drgnx-session-quit-keep)
         ('keep drgnx-term--quit-keep)
         ('close nil)
         (_ (mapcar (lambda (b) (buffer-local-value 'drgnx-term--id b)) (drgnx-term--running-buffers)))))))

(defun drgnx-term--session-end ()
  "`kill-emacs-hook': a clean exit ends this Emacs's terminals (`term/session-end') but those that keep running
\(`drgnx-term--kept-at-quit'), which wait detached for the next drgnx; after a crash they all keep running."
  (when (drgnx-term--up-p)
    (ignore-errors
      (drgnx-hub--call-on drgnx-hub--events "term/session-end" (list :keep (vconcat (drgnx-term--kept-at-quit)))
                          #'ignore))))

;;;; Reattach: terminals an earlier drgnx left running


(defvar drgnx-term--offered nil
  "The terminals offered for reattach at the last look: `term/list' rows, orphaned or detached, shown by no Emacs.")

(defun drgnx-term--offered-rows (rows)
  "The rows of ROWS (`term/list''s answer) this Emacs may take: orphaned or detached, not this session's and not
one a buffer here shows.  A terminal another live Emacs shows is never offered."
  (seq-filter (lambda (r) (and (or (eq (plist-get r :orphaned) t) (plist-get r :detached_at))
                               (not (eq (plist-get r :mine) t))
                               (not (gethash (plist-get r :id) drgnx-term--buffers))))
              rows))

(defun drgnx-term--age (ms)
  "How long ago MS (ms since the epoch) was, in words."
  (let ((s (truncate (max 0 (- (float-time) (/ ms 1000.0))))))
    (cond ((< s 120) "just now")
          ((< s 7200) (format "%d min ago" (/ s 60)))
          ((< s 172800) (format "%d h ago" (/ s 3600)))
          (t (format "%d days ago" (/ s 86400))))))

(defun drgnx-term--row-label (row)
  "One line naming terminal ROW (a `term/list' row): its title (else its program), folder and age, and its id."
  (let ((title (plist-get row :title)) (command (append (plist-get row :command) nil)) (at (plist-get row :detached_at)))
    (string-join (delq nil (list (if (string-empty-p (or title "")) (file-name-nondirectory (or (car command) "")) title)
                                 (if (stringp (plist-get row :remote)) (plist-get row :remote)
                                   (abbreviate-file-name (or (plist-get row :cwd) "")))
                                 (if (numberp at) (concat "kept " (drgnx-term--age at)) "its Emacs is gone")
                                 (and (eq (plist-get row :old) t) "from before an update: Close only")
                                 (plist-get row :id)))
                 " · ")))

(defun drgnx-term--offer-item ()
  "The notice offering `drgnx-term--offered' (with `drgnx-term-reattach' `ask'), or nil."
  (let ((n (length drgnx-term--offered)))
    (and (> n 0) (eq drgnx-term-reattach 'ask)
         (list :id "term:reattach" :command 'terminal-reattach
               :text (format "%d terminal%s kept running from your last session" n (if (= n 1) "" "s"))))))

(defun drgnx-term--post-notices ()
  "The terminal notices: the reattach offer, then the programs' notifications."
  (drgnx-notice-set 'term (append (delq nil (list (drgnx-term--offer-item))) (mapcar #'cdr drgnx-term--notices))))

(defun drgnx-term--look ()
  "Ask the hub which terminals are offered (`term/list'), then offer them (`drgnx-term--offer')."
  (when (drgnx-term--up-p)
    (drgnx-hub--call-on drgnx-hub--events "term/list" nil
                        (lambda (rows error) (unless error (drgnx-term--offer rows))))))

(defun drgnx-term--offer (rows)
  "ROWS (`term/list''s answer) offer terminals: with `drgnx-term-reattach' `always' they open here at once (not
those from before an update), with `ask' the notice says how many, with `never' only Reattach Terminal shows them."
  (setq drgnx-term--offered (drgnx-term--offered-rows rows))
  (when (eq drgnx-term-reattach 'always)
    (dolist (r drgnx-term--offered)
      (unless (eq (plist-get r :old) t) (drgnx-term-reattach-one r))))
  (drgnx-term--post-notices))

(defun drgnx-term--forget-offer (id)
  "Terminal ID is no longer offered (reattached here, or closed)."
  (setq drgnx-term--offered (seq-remove (lambda (r) (equal (plist-get r :id) id)) drgnx-term--offered))
  (drgnx-term--post-notices))

(defun drgnx-term--reattached (buffer id result error)
  "`term/attach' answered RESULT (or ERROR) for terminal ID in BUFFER: it draws there, with this Emacs's settings;
a refusal (another Emacs took it first) kills BUFFER."
  (when (buffer-live-p buffer)
    (if error
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buffer)
          (message "The terminal could not be reattached: %s" (or (plist-get error :message) error)))
      (drgnx-term--opened buffer result nil)
      (with-current-buffer buffer (drgnx-term--send "term/config" (list :config (drgnx-term--worker-config))))))
  (drgnx-term--forget-offer id))

(defun drgnx-term-reattach-one (row &optional select)
  "Open terminal ROW (a `term/list' row) here (`term/attach'): a terminal buffer where it was shown (its `place',
else the panel), drawn from a reset at this window's size; SELECT shows it selected.  Returns the buffer."
  (let* ((buffer (generate-new-buffer "*terminal*"))
         (command (append (plist-get row :command) nil))
         (cwd (plist-get row :cwd))
         (remote (plist-get row :remote))
         (id (plist-get row :id)))
    (with-current-buffer buffer
      (drgnx-term-mode)
      (setq default-directory (if (stringp remote) remote (expand-file-name "~/"))
            drgnx-term--program command
            drgnx-term--remote (and (stringp remote) remote)
            drgnx-term--shell (or (stringp remote) (null (cdr command)))
            drgnx-term--state 'opening)
      (when drgnx-term--remote (setq-local drgnx-chrome-tab-icon 'server))
      ;; the folder its shell named last (OSC 7); a remote one on its host, not checked (no connection waits)
      (when (stringp cwd) (drgnx-term--cwd cwd))
      (unless (and (not drgnx-term--remote) (string-empty-p (or (plist-get row :title) "")))
        (drgnx-term--title (or (plist-get row :title) ""))))
    (cond ((not select) (display-buffer buffer))
          ((equal (plist-get row :place) "editor") (pop-to-buffer-same-window buffer))
          (t (pop-to-buffer buffer)))
    (with-current-buffer buffer
      (let ((size (drgnx-term--window-size (or (get-buffer-window buffer) (selected-window)))))
        (setq drgnx-term--size (list (nth 0 size) (nth 1 size)))
        (drgnx-hub--call-on drgnx-hub--events "term/attach"
                            (list :id id :cols (nth 0 size) :rows (nth 1 size) :cell_px (nth 2 size))
                            (lambda (r e) (drgnx-term--reattached buffer id r e)))))
    buffer))

(defun drgnx-term--close-offered (row)
  "End the program of offered terminal ROW (`term/close')."
  (drgnx-hub--call-on drgnx-hub--events "term/close" (list :id (plist-get row :id)) #'ignore)
  (drgnx-term--forget-offer (plist-get row :id)))

(defun drgnx-term--choose (rows)
  "Choose some of ROWS (offered terminals) and reattach or close them."
  (let* ((labels (mapcar (lambda (r) (cons (drgnx-term--row-label r) r)) rows))
         (picked (delq nil (mapcar (lambda (l) (cdr (assoc l labels)))
                                   (completing-read-multiple "Terminals: " labels nil t)))))
    (when picked
      (let ((use-dialog-box nil))
        (pcase (car (read-multiple-choice (format "%d chosen: " (length picked))
                                          '((?r "reattach") (?k "close") (?q "cancel"))))
          (?r (dolist (r picked)
                (if (eq (plist-get r :old) t)
                    (message "%s is from before an update: it can only be closed" (drgnx-term--row-label r))
                  (drgnx-term-reattach-one r t))))
          (?k (mapc #'drgnx-term--close-offered picked)))))))

(defun drgnx-term-reattach ()
  "Reattach Terminal: the terminals an earlier drgnx left running (kept at its quit, or after its crash) — reattach
them all here, choose some, or close them.  A terminal another running drgnx shows is never offered."
  (interactive)
  (let ((rows (drgnx-term--offered-rows (drgnx-hub-call-sync "term/list" nil 5))))
    (setq drgnx-term--offered rows)
    (drgnx-term--post-notices)
    (if (null rows)
        (message "No terminals are left running to reattach")
      (let ((use-dialog-box nil))
        (pcase (car (read-multiple-choice
                     (format "%d terminal%s kept running: " (length rows) (if (cdr rows) "s" ""))
                     '((?a "reattach all") (?c "choose") (?k "close them") (?q "later"))))
          (?a (dolist (r rows) (unless (eq (plist-get r :old) t) (drgnx-term-reattach-one r t))))
          (?c (drgnx-term--choose rows))
          (?k (mapc #'drgnx-term--close-offered rows)))))))

(defun drgnx-term-reconnect ()
  "Run a remote terminal's command again in its buffer, after its connection was lost."
  (interactive)
  (unless (and (derived-mode-p 'drgnx-term-mode) drgnx-term--remote (eq drgnx-term--state 'exited))
    (user-error "Not a remote terminal whose connection was lost"))
  (setq header-line-format nil mode-line-process nil drgnx-term--state nil)
  (drgnx-term--open (current-buffer)))

(defun drgnx-term-usable-p (dir)
  "Non-nil when a terminal in DIR can be drgnx's own: not on Windows, a local DIR or a remote one a command reaches
(`drgnx-term-remote-command'), module tools/term has run."
  (and (not (eq system-type 'windows-nt))
       (or (not (file-remote-p dir)) (drgnx-term-remote-command dir))
       (drgnx-modules--ok-p 'tools/term)))

(defun drgnx-term--teardown ()
  "Turning the module off: every terminal ends (its buffer killed closes it), and its keymap sends every key again."
  (drgnx-term--fill-map drgnx-term-mode-map nil)
  (setq drgnx-term--notices nil drgnx-term--held nil drgnx-term--offered nil drgnx-term--quit-keep nil)
  (when (eq (lookup-key special-event-map [key-release]) #'drgnx-term-key-release)
    (define-key special-event-map [key-release] nil t))
  (remove-function after-focus-change-function #'drgnx-term--focus-changed)
  (when (boundp 'nidhogg-key-events) (setq nidhogg-key-events nil))
  (let ((drgnx-term-confirm-close-surface nil))   ; turning the module off asks nothing
    (dolist (b (drgnx-term-buffers)) (kill-buffer b))
    (dolist (b (buffer-list))
      (when (eq (buffer-local-value 'major-mode b) 'drgnx-term-mode) (kill-buffer b)))))

(drgnx-module-define 'tools/term
                     :doc "New Terminal runs your shell in drgnx's own terminal: a worker of the hub on Ghostty's engine."
                     :stage 'startup :requires '(tools/terminal)
                     :teardown #'drgnx-term--teardown
                     :setup
                     (lambda ()
                       (drgnx-memo-activate 'term-theme 'term-colours 'term-word-syntax 'term-env-set 'term-env)
                       (add-hook 'drgnx-hub-event-functions #'drgnx-term--event)
                       (drgnx-term-apply-keys)
                       (advice-add 'drgnx-keys-apply :after #'drgnx-term-apply-keys)
                       (add-hook 'drgnx-surfaces-cheatsheet-sections #'drgnx-terminal-cheatsheet-section)
                       (add-hook 'drgnx-session-running-functions #'drgnx-term-running)
                       (add-hook 'drgnx-session-keepable-functions #'drgnx-term-keepable)
                       (add-hook 'kill-emacs-hook #'drgnx-term--session-end)
                       (define-key special-event-map [key-release] #'drgnx-term-key-release)
                       (add-function :after after-focus-change-function #'drgnx-term--focus-changed)
                       (drgnx-state-subscribe 'windows-changed #'drgnx-term--windows-changed)
                       (drgnx-notice-define-source 'term :title "Terminal")
                       (drgnx-command-define 'terminal-copy :category "Terminal" :title "Copy" :scope 'editing
                                             :command #'drgnx-terminal-copy :map '(drgnx-term . drgnx-term-mode-map)
                                             :when #'drgnx-terminal--in-terminal-p
                                             :doc "Copy the selected text of the terminal to the kill ring")
                       (drgnx-command-define 'terminal-paste :category "Terminal" :title "Paste" :scope 'editing
                                             :command #'drgnx-term-paste :map '(drgnx-term . drgnx-term-mode-map)
                                             :when #'drgnx-terminal--in-terminal-p
                                             :doc "Paste the kill ring into the terminal")
                       (drgnx-command-define 'terminal-copy-mode :category "Terminal" :title "Copy Mode"
                                             :scope 'editing :command #'drgnx-term-copy-mode
                                             :map '(drgnx-term . drgnx-term-mode-map)
                                             :when #'drgnx-terminal--in-terminal-p
                                             :doc "Stop the terminal drawing and select, search and copy its text")
                       (drgnx-command-define 'terminal-find :category "Terminal" :title "Find in Terminal"
                                             :scope 'editing :command #'drgnx-term-find
                                             :map '(drgnx-term . drgnx-term-mode-map)
                                             :when #'drgnx-terminal--in-terminal-p
                                             :doc "Find text in everything the terminal remembers, newest first")
                       (drgnx-command-define 'terminal-find-next :category "Terminal" :title "Find Next in Terminal"
                                             :scope 'editing :command #'drgnx-term-find-next
                                             :map '(drgnx-term . drgnx-term-copy-mode-map)
                                             :when #'drgnx-terminal--in-terminal-p
                                             :doc "Go to the next older match of the last Find in Terminal")
                       (drgnx-command-define 'terminal-find-previous :category "Terminal"
                                             :title "Find Previous in Terminal"
                                             :scope 'editing :command #'drgnx-term-find-previous
                                             :map '(drgnx-term . drgnx-term-copy-mode-map)
                                             :when #'drgnx-terminal--in-terminal-p
                                             :doc "Go to the next newer match of the last Find in Terminal")
                       (drgnx-command-define 'terminal-reattach :category "Terminal" :title "Reattach Terminal"
                                             :command #'drgnx-term-reattach
                                             :doc "Open the terminals an earlier drgnx left running, or close them")
                       (drgnx-command-define 'terminal-reconnect :category "Terminal" :title "Reconnect Terminal"
                                             :command #'drgnx-term-reconnect :scope 'editing
                                             :doc "Run a remote terminal's command again after its connection was lost")
                       (drgnx-command-define 'terminal-clipboard-answer :category "Terminal"
                                             :title "Answer Clipboard Request" :command #'drgnx-term-clipboard-answer
                                             :doc "Allow or deny a remote program that asked to set the clipboard")
                       (add-hook 'drgnx-hub-connected-functions #'drgnx-term--connected)
                       (add-hook 'drgnx-view-model-functions #'drgnx-term--model-queued)
                       (add-hook 'enable-theme-functions #'drgnx-term--theme-changed)
                       (add-hook 'disable-theme-functions #'drgnx-term--theme-changed)
                       (drgnx-module-advice #'set-face-attribute :after term-face-touched (face &rest _)
                         (drgnx-term--face-touched face))))

(provide 'drgnx-term)
;;; drgnx-term.el ends here
