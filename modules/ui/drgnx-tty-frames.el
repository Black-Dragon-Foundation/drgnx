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
;;   `drgnx-tty-frames-query-timeout' seconds, and never again for another client of the same terminal: only
;;   that identity is kept (`drgnx-tty-frames--cache'); the rest is read from the frame on every call.  The last
;;   result is in the terminal parameter `drgnx-tty-caps'.
;; - Keys: each terminal decodes every modifyOtherKeys key (Emacs decodes only a few, so C-S-p would type text),
;;   and it is asked for where it arrives: xterm, WezTerm; tmux only with its extended-keys on.  The
;;   kitty keyboard protocol is ui/terminal-keys' (it needs the kkp package); this works without it.
;; - The mouse: `xterm-mouse-mode' (SGR reports) on while `drgnx-tty-mouse' is t, started from a terminal frame's
;;   setup, never for a graphical frame; Toggle Mouse in Terminal Windows.  The terminal's own selection is then
;;   Shift+drag.  Each terminal keeps its own enable and disable strings (Emacs 30.2 puts them on the selected one).
;; - `drgnx-tty-frames-write-report': terminal-report.eld in the state dir — each terminal's capabilities and
;;   the active profile's keys it cannot send — for the doctor and the key sheet; written whole, then renamed
;;   into place.  `drgnx-tty-frames-refresh-report' writes it again (ui/terminal-keys, once kkp is on).
;; - The fallback layer (drgnx-tty-fallback-layer.el) follows each report: a terminal that cannot send C-S- chords
;;   gets Alt+Shift with the key and F6 then the key for them; one that can loses it.
;; - EDITOR frames: `emacsclient -t FILE' (git's editor) shows the editor only and is never the main window;
;;   Close Tab (its key or the tab's ×) or C-x # ends the edit and the client returns, as `code --wait' does —
;;   asking to save a changed file first.  Moving the tab elsewhere does not end it.
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
(require 'drgnx-tty-fallback)
(require 'drgnx-frame-kind)
(declare-function drgnx-state-sync "drgnx-state")
(declare-function drgnx-tty-fallback-install "drgnx-tty-fallback-layer")
(declare-function drgnx-tty-fallback-setup "drgnx-tty-fallback-layer")
(declare-function drgnx-wb-area-hide "drgnx-area")
(declare-function drgnx-chrome-apply "drgnx-chrome")
(declare-function server-done "server")
(declare-function drgnx-frames-mark-main "drgnx-frames")
(declare-function xterm--query "term/xterm")
(declare-function xterm--read-event-for-query "term/xterm")
(declare-function xterm--init-modify-other-keys "term/xterm")
(defvar xterm-query-timeout)
(defvar server-buffer-clients)
(defvar drgnx-keys-last)
(defvar xterm-mouse-mode)
(declare-function xterm-mouse-mode "xt-mouse")
(declare-function turn-on-xterm-mouse-tracking-on-terminal "xt-mouse")
(declare-function turn-off-xterm-mouse-tracking-on-terminal "xt-mouse")
(declare-function xterm-mouse-tracking-enable-sequence "xt-mouse")
(declare-function xterm-mouse-tracking-disable-sequence "xt-mouse")
(declare-function drgnx-tty-clip-setup "drgnx-tty-clipboard")
(declare-function drgnx-tty-layout-apply "drgnx-tty-layout")
(declare-function drgnx-tty-popups-setup "drgnx-tty-popups")

(defvar drgnx-tty-frames-query-timeout 0.2
  "Seconds to wait for a terminal's answer to XTVERSION (a late answer is still taken off the input).")

(defvar drgnx-tty-frames--cache (make-hash-table :test #'equal)
  "Identities (:id :outer :version) by kind of terminal (`drgnx-tty-frames--cache-key'): a terminal is asked
once, not once per client.  What can differ between two clients of one kind (keys, colours) is not kept here.
Bounded by its keys, never evicted: one per terminal kind, outer terminal, version and TERM that clients of this
Emacs used (a handful; a terminal the environment does not name is never cached).")

;;;; What a terminal can do

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

(defun drgnx-tty-frames-mok-trusted-p (id)
  "Non-nil when a terminal of kind ID gets its chords by modifyOtherKeys.  tmux (its extended-keys decides) and
a terminal drgnx does not know (Emacs's own request decides): yes.  A known terminal: its table row decides, and
only a confirmed `:mok' counts (`drgnx-tty-mok-confirmed-p', which the ranking and the recommendation use too).
Emacs's DA2 test also asks Alacritty, whose row has none, and Ghostty's is unconfirmed (and probably level 2
only): those get kkp."
  (or (eq id 'tmux) (null (drgnx-tty-terminal id)) (drgnx-tty-mok-confirmed-p id)))

(defun drgnx-tty-frames--keys (term)
  "How TERM's keys arrive: `kkp' when the ui/terminal-keys module turned it on (terminal parameter
`drgnx-tty-kkp'), `mok' when modifyOtherKeys is asked for, drgnx decodes it there
\(`drgnx-tty-frames--keys-setup') and the terminal's row allows it (`drgnx-tty-frames-mok-trusted-p'), else
`legacy'."
  (cond ((terminal-parameter term 'drgnx-tty-kkp) 'kkp)
        ((and (terminal-parameter term 'drgnx-tty-mok-decoded) (drgnx-tty-frames-mok-asked-p term)
              (drgnx-tty-frames-mok-trusted-p (plist-get (cdr (terminal-parameter term 'drgnx-tty-identity)) :id)))
         'mok)
        (t 'legacy)))

(defun drgnx-tty-frames--identity (frame)
  "FRAME's terminal's identity (:id :outer :version): asked once per terminal, never for a terminal of a kind
already asked (the cache); an answer that came after the wait (xterm.el's handler stored it) is read now."
  (let* ((term (frame-terminal frame))
         (answer (terminal-parameter term 'drgnx-tty-xtversion))
         (stored (terminal-parameter term 'drgnx-tty-identity)))
    (if (and stored (equal (car stored) answer))
        (cdr stored)
      (let* ((env (drgnx-tty-env frame))
             (key (drgnx-tty-frames--cache-key env))
             (cached (and (not stored) key (gethash key drgnx-tty-frames--cache)))
             (id (cond (cached)
                       (stored (drgnx-tty-identify env answer))   ; the late answer
                       (t (drgnx-tty-identify env (setq answer (drgnx-tty-frames--ask frame)))))))
        (when (and key (not cached)) (puthash key id drgnx-tty-frames--cache))
        (when (terminal-live-p term)          ; the terminal can go while it is asked
          (set-terminal-parameter term 'drgnx-tty-identity (cons answer id)))
        id))))

(defun drgnx-tty-frame-caps (&optional frame)
  "What FRAME's terminal can do: (:id :outer :version :keys kkp|mok|legacy :c-g always|waits :folded KEYS
:osc52 BOOL :colors N :mouse BOOL).  :c-g `waits' (under kkp, or tmux at modifyOtherKeys level 2): C-g
interrupts only while Emacs waits for a program, not busy Lisp (`drgnx-tty-use-kkp' nil, or
`drgnx-tty-tmux-mok-level' 1, gives that up).  :folded the chords this terminal sends as another key although
`:keys' would allow them: tmux at modifyOtherKeys level 1 sends C-S-p as C-p (`drgnx-tty-tmux-folded-chords');
`drgnx-tty-unsendable' takes the list as its third argument, and the report counts those keys as
unsendable.  The identity is asked once per terminal
\(`drgnx-tty-frames--identity'); keys, OSC 52, colours and the mouse are read from FRAME on every call, so kkp
turned on later shows.  The result is also the terminal parameter `drgnx-tty-caps'.  Nil when the terminal went
away meanwhile (killed while it was asked)."
  (let* ((frame (or frame (selected-frame)))
         (term (frame-terminal frame))
         (id (drgnx-tty-frames--identity frame)))
    (when (and (frame-live-p frame) (terminal-live-p term))
      (let* ((row (drgnx-tty-terminal (plist-get id :id)))
             (keys (drgnx-tty-frames--keys term))
             (caps (list :id (plist-get id :id) :outer (plist-get id :outer) :version (plist-get id :version)
                         :keys keys
                         :c-g (if (or (eq keys 'kkp) (eql (terminal-parameter term 'drgnx-tty-mok-level) 2)) 'waits 'always)
                         :folded (and (eq (plist-get id :id) 'tmux) (eq keys 'mok)
                                      (not (eql (terminal-parameter term 'drgnx-tty-mok-level) 2))
                                      drgnx-tty-tmux-folded-chords)
                         :osc52 (and (or (terminal-parameter term 'xterm--set-selection) (plist-get row :osc52)) t)
                         :colors (display-color-cells frame)
                         :mouse (if row (and (plist-get row :mouse) t) t))))
        (set-terminal-parameter term 'drgnx-tty-caps caps)
        caps))))

;;;; Keys: modifyOtherKeys

(defconst drgnx-tty-frames--mok-on "\e[>4;1m" "The request for modifyOtherKeys (xterm.el's).")
(defconst drgnx-tty-frames--mok-off "\e[>4m" "Its reset.")

(defun drgnx-tty-frames-mok-asked-p (term)
  "Non-nil when modifyOtherKeys is asked for on TERM (by xterm.el or drgnx)."
  (member drgnx-tty-frames--mok-on (terminal-parameter term 'tty-mode-set-strings)))

(defun drgnx-tty-frames--mok-key (m k)
  "The key a terminal sends as CSI 27 ; M ; K ~: K a character code (9 TAB, 13 RET, 27 ESC, 127 DEL), M 1 plus
shift 1, meta 2, control 4.  An upper-case letter is its lower-case one with Shift (C-S-p, however it came).
Ctrl+Shift+` arrives as Ctrl+Shift+~ from a US layout (xterm and tmux send the shifted character): C-S-`."
  (let ((mods (delq nil (list (and (/= 0 (logand (1- m) 1)) 'shift)
                              (and (/= 0 (logand (1- m) 2)) 'meta)
                              (and (/= 0 (logand (1- m) 4)) 'control))))
        (base (pcase k (9 'tab) (13 'return) (27 'escape) (127 'backspace) (_ k))))
    (when (and (integerp base) (<= ?A base ?Z))
      (setq base (downcase base))
      (unless (memq 'shift mods) (push 'shift mods)))
    (when (and (eq base ?~) (memq 'shift mods) (memq 'control mods))
      (setq base ?`))
    (vector (event-convert-list (append mods (list base))))))

(defvar drgnx-tty-frames--mok-map nil "The keymap the function `drgnx-tty-frames--mok-map' returns, made once.")

(defun drgnx-tty-frames--mok-map ()
  "A keymap for `input-decode-map': every modifyOtherKeys key with Shift, Meta or Control."
  (or drgnx-tty-frames--mok-map
      (setq drgnx-tty-frames--mok-map
            (let ((map (make-sparse-keymap)))
              (dolist (m (number-sequence 2 8) map)
                (dolist (k (append '(9 13 27 127) (number-sequence 32 126)))
                  (define-key map (format "\e[27;%d;%d~" m k) (drgnx-tty-frames--mok-key m k))))))))

(defun drgnx-tty-frames--decode-mok ()
  "The selected frame's terminal decodes every modifyOtherKeys key: drgnx's map after Emacs's own (xterm.el
decodes a few: C-tab, C-. …; its decodings come first).  A terminal that never sends them is not changed by it."
  (set-keymap-parent input-decode-map
                     (make-composed-keymap (delq nil (list (keymap-parent input-decode-map) (drgnx-tty-frames--mok-map)))))
  (set-terminal-parameter nil 'drgnx-tty-mok-decoded t))

(defun drgnx-tty-frames--ask-mok (frame)
  (unless (drgnx-tty-frames-mok-asked-p (frame-terminal frame))
    (require 'term/xterm)
    (with-selected-frame frame (xterm--init-modify-other-keys))))

(defun drgnx-tty-frames--withdraw-mok (term)
  (when (drgnx-tty-frames-mok-asked-p term)
    (send-string-to-terminal drgnx-tty-frames--mok-off term)
    (set-terminal-parameter term 'tty-mode-set-strings
                            (remove drgnx-tty-frames--mok-on (terminal-parameter term 'tty-mode-set-strings)))
    (set-terminal-parameter term 'tty-mode-reset-strings
                            (remove drgnx-tty-frames--mok-off (terminal-parameter term 'tty-mode-reset-strings)))))

(defun drgnx-tty-frames--keys-setup (frame)
  "Once per terminal: FRAME's terminal decodes modifyOtherKeys, and it is asked for where it arrives.
- tmux, its TMUX known: asked for when tmux's extended-keys is on or always; else (off, or a tmux too old to
  have the option, or one that does not answer) withdrawn — tmux then sends none, the keys are legacy.
- tmux without TMUX (a tmux on the other side of SSH): Emacs's own choice stays.
- A known terminal: its row decides (`drgnx-tty-frames-mok-trusted-p'): confirmed modifyOtherKeys (xterm,
  WezTerm) is asked for if Emacs did not; otherwise (Alacritty, Ghostty, foot, kitty: kkp, or nothing) a request
  Emacs made is withdrawn.
- A terminal drgnx does not know: Emacs's own choice stays."
  (let ((term (frame-terminal frame)))
    (unless (terminal-parameter term 'drgnx-tty-mok-decoded)
      (with-selected-frame frame (drgnx-tty-frames--decode-mok))
      (let* ((env (drgnx-tty-env frame))
             (id (plist-get (drgnx-tty-frames--identity frame) :id)))
        (cond ((and (eq id 'tmux) (cdr (assoc "TMUX" env)))
               (if (member (plist-get (drgnx-tty-frames--tmux-options frame 'tmux) :extended-keys) '("on" "always"))
                   (drgnx-tty-frames--ask-mok frame)
                 (drgnx-tty-frames--withdraw-mok term)))
              ((eq id 'tmux))
              ((null (drgnx-tty-terminal id)))
              ((drgnx-tty-frames-mok-trusted-p id) (drgnx-tty-frames--ask-mok frame))
              (t (drgnx-tty-frames--withdraw-mok term)))))))

;;;; The report

(defun drgnx-tty-frames--report-file () (expand-file-name "terminal-report.eld" (drgnx-state-dir)))

(defun drgnx-tty-frames--read-report-data ()
  "terminal-report.eld as a plist, nil when missing or broken (a broken report heals on the next write)."
  (let ((data (ignore-errors (with-temp-buffer (insert-file-contents (drgnx-tty-frames--report-file))
                                               (read (current-buffer))))))
    (and (consp data) (plistp data) data)))

(defun drgnx-tty-frames--save-report (data)
  "Write DATA (a plist) as terminal-report.eld."
  (let ((file (drgnx-tty-frames--report-file)))
    (make-directory (file-name-directory file) t)
    ;; written whole under a new name, then renamed: no lock on the report (whose owner would be asked about,
    ;; a prompt in a daemon hook), and a reader sees the old report or the new one, never half of one
    (let* ((create-lockfiles nil)
           (tmp (make-temp-file (expand-file-name ".terminal-report-" (file-name-directory file)))))
      (condition-case err
          (progn
            (with-temp-file tmp
              (let ((print-length nil) (print-level nil))
                (prin1 data (current-buffer))
                (insert "\n")))
            (rename-file tmp file t))
        (error (ignore-errors (delete-file tmp))
               (signal (car err) (cdr err)))))))

(defun drgnx-tty-frames--update-report (fn)
  "Call FN with terminal-report.eld's data (a fresh plist); write what it returns, when that is non-nil."
  (when-let* ((new (funcall fn (copy-sequence (or (drgnx-tty-frames--read-report-data) (list :terminals nil))))))
    (drgnx-tty-frames--save-report new)))

(defconst drgnx-tty-frames-report-terminals 16
  "How many terminals terminal-report.eld keeps: the newest, by when each was last set up or refreshed.")

(defun drgnx-tty-frames-write-report (frame)
  "Add FRAME's terminal to terminal-report.eld in the state dir: (:terminals ((TTY . (:caps CAPS :unsendable
KEYS :seen TIME)) …)), newest first, one entry per terminal device (two clients never replace each other's), the
newest `drgnx-tty-frames-report-terminals' (16) only;
:unsendable the active key profile's keys this terminal cannot send.  The fallback layer follows the caps first
\(`drgnx-tty-fallback-install': on where they need it, off where not); the entry then has :fallback (on or not),
:fallbacks (rows (CHORD NATIVE-P ALT PREFIX) for the doctor) and :fallback-problems.  The report's other keys
\(:hinted) are kept.  Nothing when the terminal is gone."
  (when-let* ((caps (drgnx-tty-frame-caps frame)))
    (let* ((layer (and (fboundp 'drgnx-tty-fallback-install)
                       (drgnx-tty-frames--guard "fallback" #'drgnx-tty-fallback-install frame caps)))
           (data (drgnx-tty-frames--read-report-data))
           (key (terminal-name (frame-terminal frame)))
           (keys (seq-uniq (delq nil (mapcar (lambda (b) (plist-get b :key))
                                             (plist-get (bound-and-true-p drgnx-keys-last) :bindings)))))
           (read (plist-get data :terminals))
           (old (and (proper-list-p read) (seq-every-p #'consp read) read))   ; a broken report heals
           (table (drgnx-tty-fallback-active-table))
           (entry (append (list :caps caps :unsendable (drgnx-tty-unsendable keys (plist-get caps :keys) (plist-get caps :folded))
                                :seen (format-time-string "%FT%T%z"))
                          ;; inside tmux: the lines to add to ~/.tmux.conf for what it lacks (never written)
                          (when-let* ((lines (drgnx-tty-tmux-conf-lines (drgnx-tty-frames--tmux-options frame (plist-get caps :id)))))
                            (list :tmux-conf lines))
                          (list :fallback (and layer t)
                                :fallbacks (drgnx-tty-fallback-report-rows
                                            table caps (terminal-parameter (frame-terminal frame) 'drgnx-tty-fallback-table))
                                :fallback-problems (drgnx-tty-fallback-problems table (drgnx-tty-fallback--overrides))))))
      (drgnx-tty-frames--save-report
       (append (list :terminals (seq-take (cons (cons key entry) (assoc-delete-all key (copy-sequence old)))
                                          drgnx-tty-frames-report-terminals))
               (when-let* ((hinted (plist-get data :hinted))) (and (proper-list-p hinted) (list :hinted hinted))))))))

(defun drgnx-tty-frames-refresh-report (frame)
  "Write FRAME's terminal's entry in terminal-report.eld again, from what it can do now (ui/terminal-keys calls
it once kkp is on).  Never signals: errors go to `drgnx-hooks-problems'."
  (condition-case err
      (drgnx-tty-frames-write-report frame)
    (error (push (format "ui/terminal: %s" (error-message-string err)) drgnx-hooks-problems))))

;;;; The mouse

(defcustom drgnx-tty-mouse t
  "Non-nil: the mouse works in terminal windows (clicks, wheel, dragging dividers, the Explorer, tabs, menus).
The terminal's own selection is then Shift+drag in most terminals (Option+drag in iTerm2; kitty's modifier is a
setting).  Nil: the terminal keeps the mouse.  Toggle Mouse in Terminal Windows changes it."
  :type 'boolean :group 'drgnx :initialize #'custom-initialize-default
  :set (lambda (sym val) (set-default sym val) (drgnx-tty-frames-mouse-apply)))

(defun drgnx-tty-frames--tty-frames ()
  "The live terminal frames of terminals Emacs set up (not the daemon's initial terminal)."
  (seq-filter (lambda (f) (eq (drgnx-state-frame-kind f) 'tty)) (frame-list)))

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
      ;; Emacs 30.2's turn-on and turn-off keep the enable and disable strings on the SELECTED terminal: each
      ;; terminal is handled from a frame of its own
      (dolist (f frames)
        (with-selected-frame f
          (if (memq f wanted)
              (turn-on-xterm-mouse-tracking-on-terminal (frame-terminal f))
            (turn-off-xterm-mouse-tracking-on-terminal (frame-terminal f)))))
      (drgnx-tty-frames--mouse-strings frames))))

(defun drgnx-tty-frames--mouse-strings (frames)
  "Each terminal of FRAMES re-sends the mouse enable string on resume (and the disable string on suspend or
exit) once while its mouse is on, never while it is off.  Emacs 30.2 may have left them on another terminal
\(`xterm-mouse-mode' turns every terminal on from the selected one), and its turn-off removes them with `remq',
which misses them."
  (let ((on (xterm-mouse-tracking-enable-sequence)) (off (xterm-mouse-tracking-disable-sequence)))
    (dolist (term (delete-dups (mapcar #'frame-terminal frames)))
      (when (terminal-live-p term)
        (let ((tracking (terminal-parameter term 'xterm-mouse-mode)))
          (set-terminal-parameter term 'tty-mode-set-strings
                                  (append (and tracking (list on))
                                          (seq-remove (lambda (s) (equal s on))
                                                      (terminal-parameter term 'tty-mode-set-strings))))
          (set-terminal-parameter term 'tty-mode-reset-strings
                                  (append (and tracking (list off))
                                          (seq-remove (lambda (s) (equal s off))
                                                      (terminal-parameter term 'tty-mode-reset-strings)))))))))

(defun drgnx-tty-frames-toggle-mouse ()
  "Turn the mouse in terminal windows on or off; run interactively, the choice is saved."
  (interactive)
  (let ((val (not drgnx-tty-mouse)))
    (if (called-interactively-p 'any)
        (customize-save-variable 'drgnx-tty-mouse val)
      (customize-set-variable 'drgnx-tty-mouse val))
    (message "Mouse in terminal windows: %s" (if val "on" "off"))))

;;;; Check This Terminal

(declare-function drgnx-doctor-terminal-facts "drgnx-doctor")
(declare-function drgnx-doctor-run "drgnx-doctor")
(declare-function drgnx-doctor-format "drgnx-doctor")

(defun drgnx-tty-frames-terminal-check ()
  "Show the doctor's Terminal group for the selected terminal window in `*drgnx terminal*': computed from
that window's capabilities and its client's environment, not from this process's.  A graphical window says to run
it in a terminal window, or `drgnx doctor' in a shell."
  (interactive)
  (let ((frame (selected-frame)))
    (if (display-graphic-p frame)
        (message "This is a graphical window: run Check This Terminal in a terminal window, or `drgnx doctor' in a shell")
      (require 'drgnx-doctor)
      (let* ((caps (drgnx-tty-frame-caps frame))
             ;; the chords this terminal cannot send, with the keys that stand for them (what the fallback layer installs)
             (rows (mapcar (pcase-lambda (`(,chord . ,row)) (list chord nil (plist-get row :alt) (plist-get row :prefix)))
                           (drgnx-tty-fallback-for-terminal (drgnx-tty-fallback-active-table) caps)))
             (facts (list :version emacs-version
                          :terminal (drgnx-doctor-terminal-facts frame :caps caps :fallbacks rows)))
             (text (drgnx-doctor-format (drgnx-doctor-run facts nil "Terminal"))))
        (with-current-buffer (get-buffer-create "*drgnx terminal*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert text "\n"))
          (special-mode)
          (goto-char (point-min))
          (pop-to-buffer (current-buffer)))))))

;;;; EDITOR frames

(defun drgnx-tty-frames--visit ()
  "`server-visit-hook': a new terminal client that asked for files (`emacsclient -t FILE') is an editor
frame, kept for those files: never the main window (role `editor'; the main role moves on).  A frame that
already showed (one reused by a later `emacsclient FILE') stays as it is."
  (let ((frame (selected-frame)))
    (when (and (not (display-graphic-p frame)) (processp (frame-parameter frame 'client))
               (not (frame-parameter frame 'drgnx-tty-shown)))
      (set-frame-parameter frame 'drgnx-tty-editor-only t)
      (set-frame-parameter frame 'drgnx-frame-role 'editor)
      (when (fboundp 'drgnx-frames-mark-main) (drgnx-frames-mark-main))
      (drgnx-state-sync frame))))   ; the role is no window change: only this observation reads it

(defun drgnx-tty-frames--editor-only (frame)
  "FRAME shows the editor only: no sidebar, panel or right dock."
  (with-selected-frame frame
    (drgnx-wb-hide-sidebar)
    (when (fboundp 'drgnx-wb-area-hide)
      (drgnx-wb-area-hide 'panel)
      (drgnx-wb-area-hide 'right))))

(defun drgnx-tty-frames--tab-closed (window buffer)
  "After the user closed BUFFER's tab in WINDOW: in an editor frame, closing the tab of a file its client waits
for ends the edit (`server-done': a changed file is offered to save first, as C-x # does); the client returns
once it has no file left."
  (when (and (window-live-p window) (buffer-live-p buffer)
             (frame-parameter (window-frame window) 'drgnx-tty-editor-only)
             (memq (frame-parameter (window-frame window) 'client)
                   (buffer-local-value 'server-buffer-clients buffer)))
    (with-current-buffer buffer (server-done))))

;; Close Tab and the tab's × are what ends an edit, not every way a tab leaves a group (a move uses the same
;; primitive, `drgnx-chrome--close').  Task 15 replaces these two advices with a hook the chrome runs on a close.
(defun drgnx-tty-frames--close-tab (close &rest args)
  "Around Close Tab: the shown tab of the selected window, then `drgnx-tty-frames--tab-closed'."
  (let ((window (selected-window)) (buffer (window-buffer)))
    (prog1 (apply close args) (drgnx-tty-frames--tab-closed window buffer))))

(defun drgnx-tty-frames--close-clicked (close event &rest args)
  "Around a click on a tab's ×: that tab, then `drgnx-tty-frames--tab-closed'."
  (let* ((posn (event-start event)) (s (posn-string posn))
         (buffer (and s (get-text-property (cdr s) 'drgnx-buffer (car s)))) (window (posn-window posn)))
    (prog1 (apply close event args)
      (when (and (windowp window) (bufferp buffer)) (drgnx-tty-frames--tab-closed window buffer)))))

;;;; tmux

(defvar drgnx-tty-frames-tmux-ttl 2
  "Seconds a terminal's answer from tmux (`drgnx-tty-frames--tmux-options') is reused: the report, the copy and
the focus step of one setup share one call; a window made later asks again, so a `tmux source ~/.tmux.conf'
shows.")

(defun drgnx-tty-frames--tmux-options (frame &optional id)
  "tmux's options (`drgnx-tty-tmux-options') for FRAME's client, when it is inside tmux and tmux answers; else
nil.  ID is the terminal's id when the caller has it (else `drgnx-tty-frames--identity' finds it).  Kept in
the terminal parameter `drgnx-tty-tmux' for `drgnx-tty-frames-tmux-ttl' seconds; a tmux that gave no answer (it
hung for its 1 s, or is too old to say) is remembered as such until the terminal goes away, so a hung server costs
that second once, not once per window or setup step."
  (let* ((term (frame-terminal frame))
         (kept (terminal-parameter term 'drgnx-tty-tmux)))
    (if (and kept (or (null (cdr kept)) (< (- (float-time) (car kept)) drgnx-tty-frames-tmux-ttl)))
        (cdr kept)
      (let ((options (and (eq (or id (plist-get (drgnx-tty-frames--identity frame) :id)) 'tmux)
                          (drgnx-tty-tmux-options (drgnx-tty-env frame)))))
        (when (terminal-live-p term)
          (set-terminal-parameter term 'drgnx-tty-tmux (cons (float-time) options)))
        options))))

(defun drgnx-tty-frames--tmux-focus (frame)
  "Under tmux with `focus-events on', make sure FRAME's terminal asks for focus reports (CSI ? 1004 h): tmux then
passes focus changes on, Emacs's `after-focus-change-function' runs and the Explorer refreshes its git state.
xterm.el asks by itself for every TERM it knows; this covers the one it missed.  Reports stop when Emacs suspends
or exits.  Nothing when tmux keeps the focus events (`off') or this is no tmux."
  (let ((term (frame-terminal frame))
        (on "\e[?1004h") (off "\e[?1004l"))
    (when (and (terminal-live-p term)
               (equal (plist-get (drgnx-tty-frames--tmux-options frame) :focus-events) "on")
               (not (member on (terminal-parameter term 'tty-mode-set-strings))))
      (send-string-to-terminal on term)
      (set-terminal-parameter term 'tty-mode-set-strings (cons on (terminal-parameter term 'tty-mode-set-strings)))
      (set-terminal-parameter term 'tty-mode-reset-strings
                              (cons off (terminal-parameter term 'tty-mode-reset-strings))))))

;; modifyOtherKeys has two levels.  Level 1, which Emacs asks for, sends only the chords a plain terminal cannot
;; tell apart; tmux then folds C-S-<letter> (C-S-p, C-M-S-k), C-S-SPC, C-` and C-S-` into C-<letter>, C-SPC, C-@ and
;; C-^ (checked with tmux 3.7c).  Those are `:folded' in the caps: not sendable there (the fallback keys cover them).
;; Level 2 sends every modified key as CSI 27 ; M ; K ~ (C-g and C-x too), so those chords arrive; the price is that
;; C-g is no longer the plain byte Emacs's quit reads, so a runaway Lisp loop is not stopped by it (`:c-g waits').
(defcustom drgnx-tty-tmux-mok-level 1
  "The modifyOtherKeys level drgnx asks tmux for when tmux's `extended-keys' is on or always.
1 (default): Emacs's own level.  C-g stays one byte and always interrupts, but tmux folds C-S-<letter> chords
into C-<letter>: they are reported as not sendable in tmux and the fallback keys cover them.
2: C-S-letter chords work natively in tmux, but C-g can no longer stop a runaway Lisp loop (the terminal's
capabilities say `:c-g waits', as for kitty's keyboard protocol); prompts and commands still take it."
  :type '(choice (const :tag "1: C-g always works" 1) (const :tag "2: C-S-letter chords, C-g waits" 2))
  :group 'drgnx :initialize #'custom-initialize-default
  :set (lambda (sym val) (set-default sym val) (drgnx-tty-frames-tmux-level-apply)))

(defun drgnx-tty-frames-tmux-level-apply ()
  "Make the tmux terminals already open follow `drgnx-tty-tmux-mok-level': each terminal (not each window) is
asked tmux again, then its keys step runs.  Terminals drgnx has not set up are left alone and no terminal is
asked anything (this runs from Customize), as `drgnx-tty-frames-mouse-apply'."
  (let (seen)
    (dolist (f (drgnx-tty-frames--tty-frames))
      (let ((term (frame-terminal f)))
        (unless (memq term seen)
          (push term seen)
          (when (and (terminal-parameter term 'drgnx-tty-set-up)
                     (eq (plist-get (cdr (terminal-parameter term 'drgnx-tty-identity)) :id) 'tmux))
            (set-terminal-parameter term 'drgnx-tty-tmux nil)
            (drgnx-tty-frames--tmux-setup f)))))))

(defvar drgnx-tty-frames--csi-u-map nil "The keymap `drgnx-tty-frames--csi-u-map' returns, made once.")

(defun drgnx-tty-frames--csi-u-map ()
  "A keymap for `input-decode-map': CSI K ; M u, the form tmux's `extended-keys-format csi-u' sends, for the keys
as CSI 27 ; M ; K ~ (Shift, Meta, Control)."
  (or drgnx-tty-frames--csi-u-map
      (setq drgnx-tty-frames--csi-u-map
            (let ((map (make-sparse-keymap)))
              (dolist (m (number-sequence 2 8) map)
                (dolist (k (append '(9 13 27 127) (number-sequence 32 126)))
                  (define-key map (format "\e[%d;%du" k m) (drgnx-tty-frames--mok-key m k))))))))

(defun drgnx-tty-frames--tmux-keys (frame)
  "Under tmux with `extended-keys' on or always, after modifyOtherKeys was asked for (level 1): ask for
`drgnx-tty-tmux-mok-level' when that is 2 (default 1: nothing to do) so C-S- chords arrive, once per terminal and
kept for a resume; back to 1, level 1 is asked again and level 2's resume string dropped.  The report is written
again either way (C-g waits at level 2).  With `extended-keys-format csi-u', the terminal also decodes that form."
  (let* ((term (frame-terminal frame))
         (options (drgnx-tty-frames--tmux-options frame))
         (level-1 "\e[>4;1m") (level-2 "\e[>4;2m"))
    (when (and (terminal-live-p term) (member (plist-get options :extended-keys) '("on" "always")))
      (let ((set (terminal-parameter term 'tty-mode-set-strings)))
        (cond ((and (eql drgnx-tty-tmux-mok-level 2) (member level-1 set) (not (member level-2 set)))
               (send-string-to-terminal level-2 term)
               ;; last in the list: a resume sends it after level 1
               (set-terminal-parameter term 'tty-mode-set-strings (append set (list level-2)))
               (set-terminal-parameter term 'drgnx-tty-mok-level 2)
               (drgnx-tty-frames-refresh-report frame))
              ((and (not (eql drgnx-tty-tmux-mok-level 2)) (member level-2 set))
               (send-string-to-terminal level-1 term)
               (set-terminal-parameter term 'tty-mode-set-strings (remove level-2 set))
               (set-terminal-parameter term 'drgnx-tty-mok-level nil)
               (drgnx-tty-frames-refresh-report frame))))
      (when-let* (((equal (plist-get options :extended-keys-format) "csi-u"))
                  ((not (terminal-parameter term 'drgnx-tty-csi-u)))
                  (map (drgnx-tty-frames--csi-u-map)))
        (with-selected-frame frame
          (set-keymap-parent input-decode-map (make-composed-keymap (delq nil (list (keymap-parent input-decode-map) map)))))
        (set-terminal-parameter term 'drgnx-tty-csi-u t)))))

(defun drgnx-tty-frames--tmux-setup (frame)
  "The steps of a tmux terminal's setup that follow ui/terminal-keys (which asks for modifyOtherKeys): keys and
focus.  Run by `drgnx-tty-frames-setup' after its keys step has asked for modifyOtherKeys."
  (when (and (frame-live-p frame) (terminal-live-p (frame-terminal frame)))   ; the terminal can go while it is asked
    (drgnx-tty-frames--guard "tmux keys" #'drgnx-tty-frames--tmux-keys frame)
    (drgnx-tty-frames--guard "tmux focus" #'drgnx-tty-frames--tmux-focus frame)))

;;;; Each terminal frame

(defun drgnx-tty-frames--guard (what fn &rest args)
  "Call FN with ARGS; an error goes to `drgnx-hooks-problems' (WHAT names the step)."
  (condition-case err
      (apply fn args)
    (error (push (format "ui/terminal: %s: %s" what (error-message-string err)) drgnx-hooks-problems) nil)))

(defun drgnx-tty-frames-setup (&optional frame)
  "Look after FRAME (default: the selected frame) when it is a terminal frame: its keys (modifyOtherKeys),
capabilities and the report, once per terminal; the mouse.  Never prompts or signals: each step on its own, a
failing one does not stop the next."
  (let ((frame (or frame (selected-frame))))
    (when (eq (drgnx-state-frame-kind frame) 'tty)
      (let ((first (not (terminal-parameter (frame-terminal frame) 'drgnx-tty-set-up))))
        (drgnx-tty-frames--guard "keys" #'drgnx-tty-frames--keys-setup frame)
        (when first
          (set-terminal-parameter (frame-terminal frame) 'drgnx-tty-set-up t)
          (drgnx-tty-frames--guard "capabilities" #'drgnx-tty-frames-write-report frame)))
      (drgnx-tty-frames--guard "mouse" #'drgnx-tty-frames-mouse-apply)
      (drgnx-tty-frames--tmux-setup frame)   ; after keys (it needs modifyOtherKeys asked for), before clipboard
      (when (fboundp 'drgnx-tty-clip-setup)   ; drgnx-tty-clipboard.el: OSC 52 copy
        (drgnx-tty-frames--guard "clipboard" #'drgnx-tty-clip-setup frame))
      (when (fboundp 'drgnx-tty-popups-setup)
        (drgnx-tty-frames--guard "popups" #'drgnx-tty-popups-setup frame)))))

(defun drgnx-tty-frames--after-make-frame ()
  "`server-after-make-frame-hook' (the client's frame is selected): set it up; an editor frame shows the
editor only; give its windows their tabs now — a client showing the buffer the daemon's editor already showed
(*scratch*) is no change the workbench's bus would see, and its tab line would stay empty.  The frame has shown
now.  (The server runs this hook outside a minibuffer and isearch: `server-goto-toplevel' leaves both first.)"
  (let ((frame (selected-frame)))
    (drgnx-tty-frames-setup frame)
    (unless (display-graphic-p frame)
      (set-frame-parameter frame 'drgnx-tty-shown t)
      (when (frame-parameter frame 'drgnx-tty-editor-only)
        (drgnx-tty-frames--guard "editor frame" #'drgnx-tty-frames--editor-only frame))
      (when (fboundp 'drgnx-chrome-apply)
        (drgnx-tty-frames--guard "tabs" #'drgnx-chrome-apply frame t))
      (when (fboundp 'drgnx-tty-layout-apply)
        (drgnx-tty-frames--guard "layout" #'drgnx-tty-layout-apply frame t)))))

;;;; Colours

;; Emacs's terminal setup (`init_tty' in term.c, 30.2 and 31.1) takes 24-bit colour from the terminfo (the `RGB'
;; flag, or `setf24' with `setb24') or from COLORTERM=truecolor, and it reads COLORTERM with C's getenv: the
;; *daemon's* environment, not the environment `emacsclient' sent (`server-create-tty-frame' only binds that in
;; Lisp).  And the frame parameter `tty-color-mode' cannot raise the colours (its modes are 8, none and "as set
;; up"), so the frame has to be created with the right terminfo: when the client says COLORTERM=truecolor (or
;; 24bit) and its TERM has no true colour, the frame is created as the `-direct' variant of that TERM
;; (xterm-256color gives xterm-direct, tmux-256color gives tmux-direct), whose terminfo has `RGB', if the
;; daemon's machine has that terminfo.

(defcustom drgnx-tty-true-colour 'known
  "Which terminal windows get true colour when their client says COLORTERM=truecolor (or 24bit).
`known': those whose terminal drgnx's table says has it (`drgnx-tty-terminals', :truecolor); `t': any, on the
client's word alone; nil: none (Emacs's own choice stays).  A window gets it by being created with the `-direct'
variant of its TERM, when that terminfo exists on the machine running the daemon."
  :type '(choice (const :tag "Terminals known to have it" known) (const :tag "Whenever COLORTERM says so" t)
                 (const :tag "Never" nil))
  :group 'drgnx)

(defconst drgnx-tty-frames--infocmp-timeout 2 "Seconds `infocmp' may take.")

(defvar drgnx-tty-frames--direct-cache (make-hash-table :test #'equal)
  "Terminal type → whether its terminfo has true colour as Emacs reads it, from infocmp's answer.  Bounded by its
keys, never evicted: the TERM types clients used and their `-direct' variants (a handful).  Only answers are kept:
an infocmp that printed nothing (missing, timed out, an unknown type) is asked again at the next frame.")

(defun drgnx-tty-frames--terminfo-true-colour-p (type)
  "Whether the terminfo of terminal type TYPE (on this machine) has true colour as Emacs's term.c reads it: the
`RGB' flag, or `setf24' together with `setb24'.  Asked of `infocmp' (bounded: `drgnx-tty--command-lines'); its
answer is kept per type.  Nil when there is no such terminfo or no infocmp, which is not kept."
  (let ((hit (gethash type drgnx-tty-frames--direct-cache 'unknown)))
    (if (not (eq hit 'unknown)) hit
      (when-let* (((and (stringp type) (not (string-empty-p type))))
                  (lines (drgnx-tty--command-lines (list "infocmp" "-x" "-1" type) drgnx-tty-frames--infocmp-timeout)))
        (puthash type
                 (let ((has (lambda (re) (seq-some (lambda (l) (string-match-p re l)) lines))))
                   (and (or (funcall has "\\`[ \t]+RGB,")
                            (and (funcall has "\\`[ \t]+setf24=") (funcall has "\\`[ \t]+setb24=")))
                        t))
                 drgnx-tty-frames--direct-cache)))))

(defun drgnx-tty-frames--client-wants-true-colour-p (env)
  "Whether the client with ENV (\"K=V\" strings) may get true colour: it says COLORTERM=truecolor or 24bit, and
`drgnx-tty-true-colour' allows it (for `known': its terminal's row says `:truecolor')."
  (let ((ct (getenv-internal "COLORTERM" env)))
    (and (stringp ct) (member (downcase ct) '("truecolor" "24bit"))
         (pcase drgnx-tty-true-colour
           ('t t)
           ('known (let ((alist (mapcar (lambda (var) (cons var (let ((v (getenv-internal var env))) (and (stringp v) v))))
                                        drgnx-tty-env-variables)))
                     (plist-get (drgnx-tty-terminal (plist-get (drgnx-tty-identify alist) :id)) :truecolor)))))))

(defun drgnx-tty-frames--true-colour-type (type env)
  "The terminal type to create a client's frame with: TYPE, or its `-direct' variant when the client (ENV, its
\"K=V\" environment) may get true colour (`drgnx-tty-true-colour'), TYPE's terminfo has none, the daemon's own
COLORTERM is not truecolor already (then every frame has it) and the variant's terminfo has."
  (or (and (stringp type) drgnx-tty-true-colour
           (drgnx-tty-frames--client-wants-true-colour-p env)
           (not (equal (downcase (or (getenv "COLORTERM") "")) "truecolor"))
           (not (drgnx-tty-frames--terminfo-true-colour-p type))
           (seq-find #'drgnx-tty-frames--terminfo-true-colour-p
                     (list (concat (string-remove-suffix "-256color" type) "-direct") (concat type "-direct"))))
      type))

(defun drgnx-tty-frames--create-tty-frame (fn tty type proc &rest args)
  "Around `server-create-tty-frame': create the frame as a true-colour terminal where the client may get one
(`drgnx-tty-frames--true-colour-type').  Never costs the client its frame: if Emacs cannot load the other type
(infocmp and Emacs can see different terminfo databases) and made no frame on the way, the frame is created as
asked."
  (let ((wanted (or (ignore-errors (drgnx-tty-frames--true-colour-type type (process-get proc 'env))) type)))
    (if (equal wanted type)
        (apply fn tty type proc args)
      (let ((before (frame-list)))
        (condition-case err
            (apply fn tty wanted proc args)
          (error (if (seq-difference (frame-list) before)
                     (signal (car err) (cdr err))      ; a frame exists already (an error in a frame hook)
                   (apply fn tty type proc args))))))))

(defconst drgnx-tty-frames-state-faces
  '((git :faces (drgnx-git-modified drgnx-git-added drgnx-git-deleted drgnx-git-conflict drgnx-git-ignored)
         :attribute-faces (drgnx-git-ignored)
         :cue letter :doc "The status letter (M, A, U, D, C) at the row's edge in the Explorer; ignored files, which have none, are italic")
    (review :faces (drgnx-review-critical drgnx-review-important drgnx-review-minor)
            :cue word :doc "The severity word that starts a finding's line")
    (tabs :faces (drgnx-chrome-tab drgnx-chrome-tab-current)
          :cue attribute :doc "The shown tab differs from the others in weight or inverse video")
    (work :faces (drgnx-work-ui-spec drgnx-work-ui-done drgnx-work-ui-stale drgnx-work-ui-branch)
          :cue label :doc "The glyph and the words of a node's line (warning sign, merged, the branch in brackets)"))
  "The faces that mark a state, by group, and the cue besides colour that tells the state on an 8-colour terminal:
`letter', `word' and `label' are in the text on the screen; `attribute' is in the faces themselves.  :attribute-faces
are the faces of a group that rely on an attribute because their state has no text.")

(drgnx-module-define 'ui/terminal
                     :doc "Terminal windows: what each terminal can do, asked once; the mouse; editor-only EDITOR frames."
                     :stage 'startup
                     :setup (lambda ()
                              (drgnx-command-define 'terminal-toggle-mouse :category "Terminal"
                                                    :title "Toggle Mouse in Terminal Windows" :scope 'window
                                                    :command #'drgnx-tty-frames-toggle-mouse
                                                    :doc "Mouse clicks, wheel and drags in terminal windows on or off")
                              (drgnx-command-define 'terminal-check :category "Help"
                                                    :title "Check This Terminal" :scope 'window
                                                    :command #'drgnx-tty-frames-terminal-check
                                                    :doc "What this terminal window can do and lacks, with the line that fixes each (the doctor's Terminal group)")
                              (add-hook 'tty-setup-hook #'drgnx-tty-frames-setup)
                              (add-hook 'server-visit-hook #'drgnx-tty-frames--visit)
                              (add-hook 'server-after-make-frame-hook #'drgnx-tty-frames--after-make-frame)
                              (advice-add 'drgnx-chrome-close-tab :around #'drgnx-tty-frames--close-tab)
                              (advice-add 'drgnx-chrome--close-clicked :around #'drgnx-tty-frames--close-clicked)
                              ;; a daemon loads server.el after init: there is nothing to advise yet
                              (with-eval-after-load 'server
                                (advice-add 'server-create-tty-frame :around #'drgnx-tty-frames--create-tty-frame))
                              ;; the fallback layer is rebuilt after every key apply (drgnx-tty-fallback-layer.el)
                              (when (fboundp 'drgnx-tty-fallback-setup) (drgnx-tty-fallback-setup))
                              ;; a terminal Emacs set up before this module ran (`emacs -nw' sets its own up after init)
                              (when (terminal-parameter nil 'terminal-initted)
                                (drgnx-tty-frames-setup))))

(provide 'drgnx-tty-frames)
;;; drgnx-tty-frames.el ends here
