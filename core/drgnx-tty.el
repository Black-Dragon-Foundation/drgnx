;;; drgnx-tty.el --- Terminals: which one this is, what it can do, which keys it can send -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Knowledge about text terminals, safe in batch: nothing here needs a frame or talks to a terminal.  The only
;; I/O is looking up terminfo files and, inside tmux, one `tmux show' with a 1 s limit.
;;
;; - `drgnx-tty-identify': which terminal a client runs in, from its environment and, when the caller has one,
;;   the terminal's answer to XTVERSION or DA2.  Under tmux the terminal is tmux, and the one around it, when
;;   the environment says so.
;; - `drgnx-tty-terminals': what each terminal can do — the kitty keyboard protocol (kkp), modifyOtherKeys
;;   (mok), OSC 52 copy, true colour, the mouse — the chords it keeps for itself, and the line that fixes what
;;   is missing.  Rows are "reported" from each terminal's documentation until the builder has run them.
;; - `drgnx-tty-key-sendable-p': which keys a terminal can send at all: plain (legacy) terminals cannot send
;;   C-S- chords, C-. and the like; modifyOtherKeys can, except super and hyper; kkp sends everything.
;; - `drgnx-tty-facts': the above for the terminal this Emacs runs in, for the doctor and onboarding.
;; See docs/guide/terminal.md.

;;; Code:
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

;;;; Which terminal

(defconst drgnx-tty-env-variables
  '("TERM" "TERM_PROGRAM" "TERM_PROGRAM_VERSION" "VTE_VERSION" "KITTY_WINDOW_ID" "WEZTERM_PANE"
    "GHOSTTY_RESOURCES_DIR" "ALACRITTY_SOCKET" "XTERM_VERSION" "TMUX" "COLORTERM" "SSH_CONNECTION" "SSH_TTY"
    "TERMINFO" "TERMINFO_DIRS" "HOME")
  "The variables of a client's environment that drgnx reads: `drgnx-tty-identify' the terminal ones,
`drgnx-tty-terminfo-p' TERMINFO, TERMINFO_DIRS and HOME, `drgnx-tty-tmux-options' TMUX.")

(defun drgnx-tty-env (&optional frame)
  "The client's environment as an alist over `drgnx-tty-env-variables': FRAME's (the environment its
emacsclient brought, which a daemon's own `process-environment' must not shadow), or this Emacs's own when
FRAME is nil (a plain `emacs -nw')."
  (mapcar (lambda (var) (cons var (getenv var frame))) drgnx-tty-env-variables))

(defconst drgnx-tty--xtversion-names
  '(("kitty" . kitty) ("wezterm" . wezterm) ("foot" . foot) ("ghostty" . ghostty) ("alacritty" . alacritty)
    ("iterm2" . iterm2) ("vte" . vte) ("xterm" . xterm) ("tmux" . tmux))
  "XTVERSION names (lower case) → terminal ids.")

(defconst drgnx-tty--da2-types '(("65" . vte) ("41" . xterm) ("84" . tmux))
  "DA2 terminal types → ids: 65 is VTE (GNOME Terminal, Ptyxis; Emacs's term/xterm.el), 41 xterm since patch
280 (the same file), 84 tmux (its answer `ESC [ > 84 ; 0 ; 0 c').  Type 1 is ambiguous (old VTE, kitty, foot,
others), so it names nothing.")

(defconst drgnx-tty--term-programs
  '(("WezTerm" . wezterm) ("iTerm.app" . iterm2) ("Apple_Terminal" . apple-terminal) ("ghostty" . ghostty)
    ("tmux" . tmux))
  "TERM_PROGRAM values → terminal ids.")

(defconst drgnx-tty--window-variables
  '(("KITTY_WINDOW_ID" . kitty) ("WEZTERM_PANE" . wezterm) ("GHOSTTY_RESOURCES_DIR" . ghostty)
    ("ALACRITTY_SOCKET" . alacritty) ("VTE_VERSION" . vte) ("XTERM_VERSION" . xterm))
  "Variables a terminal sets in its shells → terminal ids.  They are inherited by whatever starts from that
shell (another terminal, a tmux server), so they come after TERM and TERM_PROGRAM.")

(defun drgnx-tty--get (env var)
  "VAR's value in ENV (an alist), nil when unset or empty."
  (let ((v (cdr (assoc var env))))
    (and v (not (string-empty-p v)) v)))

(defun drgnx-tty--from-answer (answer)
  "(ID . VERSION) from ANSWER, an XTVERSION (`ESC P > | NAME(VERSION) ESC \\') or DA2 (`ESC [ > T ; V ; X c')
reply; nil when it names no terminal drgnx knows."
  (cond
   ((null answer) nil)
   ((string-match "\eP>|\\([^ (\e]+\\)[ (]?\\([^)\e]*\\)" answer)
    (when-let* ((id (cdr (assoc (downcase (match-string 1 answer)) drgnx-tty--xtversion-names))))
      (cons id (let ((v (match-string 2 answer))) (and (not (string-empty-p v)) v)))))
   ((string-match "\e\\[>\\([0-9]+\\);\\([0-9]+\\)" answer)
    (when-let* ((id (cdr (assoc (match-string 1 answer) drgnx-tty--da2-types))))
      (cons id (match-string 2 answer))))))

(defun drgnx-tty--from-env (env)
  "(ID . VERSION) from ENV when a variable names the terminal, else nil."
  (let ((term (or (drgnx-tty--get env "TERM") ""))
        (program (drgnx-tty--get env "TERM_PROGRAM")))
    (or
     ;; TERM names a few terminals exactly; it travels over SSH where the others do not
     (when-let* ((id (cond ((equal term "xterm-kitty") 'kitty)
                           ((string-match-p "\\`foot\\(-\\|\\'\\)" term) 'foot)
                           ((equal term "xterm-ghostty") 'ghostty)
                           ((equal term "wezterm") 'wezterm)
                           ((equal term "alacritty") 'alacritty)
                           ((equal term "linux") 'linux))))
       (cons id nil))
     (when-let* ((id (cdr (assoc program drgnx-tty--term-programs))))
       (cons id (drgnx-tty--get env "TERM_PROGRAM_VERSION")))
     (seq-some (lambda (pair)
                 (when-let* ((v (drgnx-tty--get env (car pair))))
                   (cons (cdr pair) (and (memq (cdr pair) '(vte xterm)) v))))
               drgnx-tty--window-variables))))

(defun drgnx-tty--tmux-p (env)
  "Non-nil when ENV is a client inside tmux: TMUX set, or TERM tmux-* (a tmux on the other side of SSH)."
  (or (drgnx-tty--get env "TMUX")
      (string-prefix-p "tmux" (or (drgnx-tty--get env "TERM") ""))))

(defun drgnx-tty-identify (env &optional answer)
  "Which terminal a client runs in: (:id ID :outer OUTER :version STRING).
ENV is an alist of the client's variables (`drgnx-tty-env-variables'); ANSWER, when given, the terminal's
reply to XTVERSION or DA2.  ID is one of the ids of `drgnx-tty-terminals', or `unknown'.  The answer comes
from the terminal itself, so it wins over variables inherited from another one.  Inside tmux the terminal is
tmux (it decides what reaches Emacs), and OUTER a hint at the terminal around it, from the variables the tmux
server inherited from its first client (stale when another terminal attached since; none over SSH), else nil.
`drgnx-tty-facts' prefers tmux's own #{client_termtype} (tmux 3.4 and later) when it names one."
  (if (drgnx-tty--tmux-p env)
      (let* ((outer-env (seq-remove (lambda (pair)
                                      (or (member (car pair) '("TMUX" "TERM"))
                                          (and (member (car pair) '("TERM_PROGRAM" "TERM_PROGRAM_VERSION"))
                                               (equal (drgnx-tty--get env "TERM_PROGRAM") "tmux"))))
                                    env))
             (outer (car (drgnx-tty--from-env outer-env)))
             (answered (drgnx-tty--from-answer answer)))
        (list :id 'tmux :outer outer
              :version (or (and (eq (car answered) 'tmux) (cdr answered))
                           (and (equal (drgnx-tty--get env "TERM_PROGRAM") "tmux")
                                (drgnx-tty--get env "TERM_PROGRAM_VERSION")))))
    (let ((found (or (drgnx-tty--from-answer answer) (drgnx-tty--from-env env))))
      (list :id (or (car found) 'unknown) :outer nil :version (cdr found)))))

;;;; What each terminal can do

(defconst drgnx-tty-terminals
  `((:id kitty :name "kitty"
         :kkp t :mok nil :osc52 t :truecolor t :mouse t
         :takes ("C-S-c" "C-S-v" "C-S-s" "C-S-o" "C-S-<up>" "C-S-<down>" "C-S-k" "C-S-j" "C-S-<prior>" "C-S-<next>"
                 "C-S-<home>" "C-S-<end>" "C-S-z" "C-S-x" "C-S-h" "C-S-<return>" "C-S-n" "C-S-w" "C-S-]" "C-S-["
                 "C-S-f" "C-S-b" "C-S-`" "C-S-r" "C-S-1" "C-S-2" "C-S-3" "C-S-4" "C-S-5" "C-S-6" "C-S-7" "C-S-8"
                 "C-S-9" "C-S-0" "C-S-<right>" "C-S-<left>" "C-S-<tab>" "C-S-t" "C-S-q" "C-S-." "C-S-," "C-S-l"
                 "C-S-=" "C-S--" "C-S-<backspace>" "C-S-e" "C-S-p" "C-S-/" "C-S-g" "C-S-u" "C-S-<escape>" "C-S-a"
                 "C-S-<delete>" "C-S-<f1>" "C-S-<f2>" "C-S-<f3>" "C-S-<f5>" "C-S-<f6>" "C-S-<f7>" "C-S-<f8>"
                 "C-S-<f10>" "C-S-<f11>")
         :fixes ((mok . "none: kitty speaks its own keyboard protocol (kkp), which drgnx uses instead")
                 (takes . "clear_all_shortcuts yes   (in kitty.conf, before your own map lines; `map kitty_mod+t' with no action frees one chord)"))
         :unconfirmed (:mok :truecolor :mouse)
         :verified nil :source "https://sw.kovidgoyal.net/kitty/conf/")
    (:id wezterm :name "WezTerm"
         :kkp nil :mok t :osc52 t :truecolor t :mouse t
         :takes ("C-S-c" "C-S-v" "C-S-n" "C-S-t" "C-S-w" "C-S-1" "C-S-2" "C-S-3" "C-S-4" "C-S-5" "C-S-6" "C-S-7"
                 "C-S-8" "C-S-9" "C-S-<tab>" "C-S-<prior>" "C-S-<next>" "C-S-r" "C-S-k" "C-S-l" "C-S-p" "C-S-u"
                 "C-S-f" "C-S-x" "C-S-SPC" "C-S-<left>" "C-S-<right>" "C-S-<up>" "C-S-<down>" "C-S-z"
                 "s-c" "s-v" "s-m" "s-n" "s--" "s-=" "s-0" "s-t" "s-w" "s-1" "s-2" "s-3" "s-4" "s-5" "s-6" "s-7"
                 "s-8" "s-9" "s-r" "s-h" "s-k" "s-f" "S-s-t" "S-s-[" "S-s-]")
         :fixes ((kkp . "config.enable_kitty_keyboard = true   (in wezterm.lua; off by default)")
                 (takes . "config.disable_default_key_bindings = true   (in wezterm.lua; then bind only what you want)"))
         :unconfirmed (:truecolor :mouse)
         :verified nil :source "https://wezterm.org/config/key-encoding.html")
    (:id foot :name "foot"
         :kkp t :mok nil :osc52 t :truecolor t :mouse t
         :takes ("C-S-c" "C-S-v" "C-S-r" "C-S-n" "C-S-o" "C-S-z" "C-S-x" "C-S-u")
         :fixes ((mok . "none: foot's documentation does not describe modifyOtherKeys; it speaks kkp, which drgnx uses")
                 (takes . "search-start=none   (in foot.ini under [key-bindings]; one line per action to free)"))
         :unconfirmed (:mok)
         :verified nil :source "https://codeberg.org/dnkl/foot/src/branch/master/doc/foot.ini.5.scd")
    (:id ghostty :name "Ghostty"
         :kkp t :mok t :osc52 t :truecolor t :mouse t
         :takes ("C-S-c" "C-S-v" "C-S-t" "C-S-n" "C-S-w")
         :fixes ((takes . "keybind = ctrl+shift+t=unbind   (in Ghostty's config; `ghostty +list-keybinds --default' lists the rest)"))
         :unconfirmed (:mok :truecolor :takes)
         :verified nil :source "https://ghostty.org/docs/config/reference")
    (:id alacritty :name "Alacritty"
         :kkp t :mok nil :osc52 t :truecolor t :mouse t
         :takes ("C-S-c" "C-S-v" "C-S-f" "C-S-b" "C-S-SPC" "C-S-o")
         :fixes ((mok . "none: Alacritty's documentation does not describe modifyOtherKeys; it speaks kkp, which drgnx uses")
                 (takes . "[[keyboard.bindings]] key = \"F\", mods = \"Control|Shift\", action = \"ReceiveChar\"   (in alacritty.toml)"))
         :unconfirmed (:mok :truecolor :mouse)
         :verified nil :source "https://alacritty.org/config-alacritty.html")
    (:id iterm2 :name "iTerm2"
         :kkp nil :mok nil :osc52 nil :truecolor t :mouse t
         :takes ("s-c" "s-v" "s-t" "s-n" "s-w" "s-q")
         :fixes ((kkp . "Settings → Profiles → Keys → General: Apps can change how keys are reported")
                 (mok . "none: iTerm2's documentation points programs to kkp, which drgnx uses")
                 (osc52 . "Settings → General → Selection: Applications in terminal may access clipboard")
                 (takes . "none: macOS keeps the Cmd (s-) chords; drgnx's keys in a terminal are C- and M- chords"))
         :unconfirmed (:kkp :mok :osc52 :truecolor :mouse :takes)
         :verified nil :source "https://iterm2.com/documentation-preferences-profiles-keys.html")
    (:id vte :name "GNOME Terminal, Ptyxis (VTE)"
         :kkp nil :mok nil :osc52 nil :truecolor t :mouse t
         :takes ("C-S-c" "C-S-v" "C-S-t" "C-S-n" "C-S-o" "C-S-f" "C-S-a" "C-S-w" "C-S-q" "C-S-<prior>" "C-S-<next>"
                 "S-<f10>" "C-M-S-t")
         :fixes ((kkp . "none: VTE has no kitty keyboard protocol; F1 and the palette reach every command")
                 (mok . "none: VTE sends no modifyOtherKeys (Emacs's term/xterm.el turns it off for VTE)")
                 (osc52 . "none: VTE does not take OSC 52 (GNOME VTE issue 2495); copy stays in drgnx")
                 (takes . "none: freeing a chord in Preferences → Shortcuts sends it without Shift, VTE has no C-S- encoding"))
         :unconfirmed (:kkp :truecolor :mouse)
         :verified nil :source "https://gitlab.gnome.org/GNOME/vte/-/issues/2495")
    (:id apple-terminal :name "Terminal.app"
         :kkp nil :mok nil :osc52 nil :truecolor nil :mouse t
         :takes ("s-c" "s-v" "s-t" "s-n" "s-w" "s-q")
         :fixes ((kkp . "none: Terminal.app has no kitty keyboard protocol; F1 and the palette reach every command")
                 (mok . "none: Terminal.app sends no modifyOtherKeys")
                 (osc52 . "none: Terminal.app is not known to take OSC 52; copy stays in drgnx")
                 (truecolor . "none: 256 colours; true colour was announced for macOS 26 (unconfirmed)")
                 (meta . "Settings → Profiles → Keyboard: Use Option as Meta key")
                 (takes . "none: macOS keeps the Cmd (s-) chords"))
         :unconfirmed (:kkp :mok :osc52 :truecolor :mouse :takes)
         :verified nil :source "https://support.apple.com/guide/terminal/change-profiles-keyboard-settings-trmlkbrd/mac")
    (:id xterm :name "xterm"
         :kkp nil :mok t :osc52 nil :truecolor nil :mouse t
         :takes ("S-<prior>" "S-<next>" "S-<insert>")
         :fixes ((kkp . "none: xterm speaks modifyOtherKeys, which Emacs turns on by itself")
                 (osc52 . "XTerm*disallowedWindowOps: GetChecksum,GetIconTitle,GetSelection,GetWinTitle,SetXprop   (in ~/.Xresources: xterm's default list without SetSelection)")
                 (truecolor . "TERM=xterm-direct   (xterm's direct-colour terminfo; unconfirmed)"))
         :unconfirmed (:kkp :truecolor :takes)
         :verified nil :source "https://invisible-island.net/xterm/ctlseqs/ctlseqs.html")
    (:id linux :name "Linux console"
         :kkp nil :mok nil :osc52 nil :truecolor nil :mouse nil
         :takes ,(append (mapcar (lambda (n) (format "M-<f%d>" n)) (number-sequence 1 12))
                         (mapcar (lambda (n) (format "C-M-<f%d>" n)) (number-sequence 1 12)))
         :fixes ((kkp . "none: the console sends neither kkp nor modifyOtherKeys; F1 and the palette reach every command")
                 (mok . "none: the console sends neither kkp nor modifyOtherKeys")
                 (osc52 . "none: the console has no clipboard to copy to")
                 (truecolor . "none: the console shows 16 colours")
                 (mouse . "M-x gpm-mouse-mode   (with the gpm service running)")
                 (takes . "none: Alt+F1…F12 and Ctrl+Alt+F1…F12 switch consoles"))
         :unconfirmed (:kkp :mok :truecolor :mouse :takes)
         :verified nil :source "https://man7.org/linux/man-pages/man4/console_codes.4.html")
    (:id tmux :name "tmux"
         :kkp nil :mok nil :osc52 nil :truecolor nil :mouse t
         :takes ("C-b")
         :fixes ((kkp . "none: tmux passes modifyOtherKeys (extended-keys), not the kitty keyboard protocol")
                 (mok . "set -s extended-keys on   (in ~/.tmux.conf; off by default)")
                 (osc52 . "set -s set-clipboard on   (in ~/.tmux.conf; the default, external, refuses programs)")
                 (truecolor . "set -as terminal-features ',xterm-kitty:RGB'   (in ~/.tmux.conf, with the outer TERM)")
                 (takes . "none: C-b is tmux's prefix; press it twice to send C-b, or `set -g prefix' another key"))
         :unconfirmed (:mouse)
         :verified nil :source "https://man.openbsd.org/tmux"))
  "What each terminal can do with its default settings, as its documentation reports it (`:verified' nil
until the builder ran it; `:source' the page).  :kkp the kitty keyboard protocol, :mok modifyOtherKeys,
:osc52 copy to the local clipboard, :truecolor 24-bit colour, :mouse mouse reporting; :takes the chords the
terminal keeps for itself (Emacs notation); :fixes, per missing capability, the line that fixes it, or
\"none: \" and why.  :unconfirmed names the cells no official page drgnx read backs (secondary sources or
general knowledge); docs/guide/terminal.md marks them.")

(defun drgnx-tty-terminal (id)
  "The row of `drgnx-tty-terminals' for ID, nil for `unknown'."
  (seq-find (lambda (row) (eq (plist-get row :id) id)) drgnx-tty-terminals))

;;;; Which keys a terminal can send

(defconst drgnx-tty--c0-aliases '(?@ ?\[ ?\\ ?\] ?^ ?_ ??)
  "Characters C- of which a plain terminal sends as a C0 control code Emacs reads back as the same key.")

(defun drgnx-tty--event-sendable-p (event caps)
  "Non-nil when a terminal with CAPS (`kkp', `mok' or `legacy') can send EVENT."
  (let ((mods (event-modifiers event))
        (base (event-basic-type event)))
    (cond
     ((eq caps 'kkp) t)
     ((or (memq 'super mods) (memq 'hyper mods)) nil)
     ((eq caps 'mok) t)
     ;; legacy: C- reaches only letters and the C0 aliases; Shift does not travel with C-
     ((integerp base)
      (or (not (memq 'control mods))
          (and (not (memq 'shift mods))
               (or (<= ?a base ?z) (memq base drgnx-tty--c0-aliases)))))
     ;; RET, TAB, DEL and ESC are C0 codes too: no modifier but S-TAB (backtab) survives
     ((memq base '(return tab backspace escape))
      (or (null (remq 'meta mods)) (and (eq base 'tab) (equal (remq 'meta mods) '(shift)))))
     ;; arrows, F keys, Home…: xterm-style terminals send their modifiers (the Linux console does not; this
     ;; answers for the key model, not for one terminal)
     (t t))))

(defun drgnx-tty-key-sendable-p (key caps)
  "Non-nil when a terminal with CAPS (`kkp', `mok' or `legacy') can send KEY (a `kbd' string or a vector).
Legacy terminals cannot send C-S-<letter>, C-<punctuation> other than Emacs's C0 aliases (C-@ C-[ C-\\ C-]
C-^ C-_ C-?), C-<digit>, C-<return>, C-<tab>, C-S-<tab> or any s- or H- key; modifyOtherKeys sends all but s-
and H- keys; kkp sends every key.  Any other CAPS counts as legacy."
  (seq-every-p (lambda (event) (drgnx-tty--event-sendable-p event caps))
               (if (stringp key) (key-parse key) key)))

(defun drgnx-tty-unsendable (keys caps)
  "The KEYS (a list of `kbd' strings) a terminal with CAPS cannot send, in their order."
  (seq-remove (lambda (key) (drgnx-tty-key-sendable-p key caps)) keys))

;;;; terminfo and tmux

(defvar drgnx-tty-terminfo-system-dirs '("/etc/terminfo" "/lib/terminfo" "/usr/share/terminfo")
  "The system's terminfo directories, searched after TERMINFO, ~/.terminfo and TERMINFO_DIRS.")

(defun drgnx-tty--env-get (env var)
  "VAR from ENV (an alist, see `drgnx-tty-env'), or from this Emacs's environment when ENV is nil."
  (if env (drgnx-tty--get env var) (getenv var)))

(defun drgnx-tty-terminfo-p (term &optional env)
  "Non-nil when a terminfo entry for TERM exists: in TERMINFO, ~/.terminfo, TERMINFO_DIRS or the system
directories, under the first letter (Linux) or its hex code (macOS).  TERMINFO, TERMINFO_DIRS and HOME come
from ENV, the client's environment (`drgnx-tty-env'): a daemon creates a client's terminal frame with these
of the client's (server.el), so the client's view is the one that counts.  A TERM that is not a plain file
name (a `/', a NUL, a leading `.') has no entry."
  (when (and term (not (string-empty-p term)) (not (string-match-p "[/\0]" term))
             (not (string-prefix-p "." term)))
    (let* ((get (lambda (var) (drgnx-tty--env-get env var)))
           (home (funcall get "HOME"))
           (dirs (append (and (funcall get "TERMINFO") (list (funcall get "TERMINFO")))
                         (and home (list (expand-file-name ".terminfo" home)))
                         (and (funcall get "TERMINFO_DIRS") (split-string (funcall get "TERMINFO_DIRS") ":" t))
                         drgnx-tty-terminfo-system-dirs)))
      (seq-some (lambda (dir)
                  (seq-some (lambda (sub) (file-regular-p (expand-file-name (concat sub "/" term) dir)))
                            (list (substring term 0 1) (format "%x" (aref term 0)))))
                dirs))))

(defun drgnx-tty--command-lines (command timeout &optional env)
  "The lines COMMAND (a list: program and arguments) prints within TIMEOUT seconds; nil when the program is
missing, fails to start or takes longer (it is then killed).  ENV (an alist) overrides the environment it
runs with (an unset variable is removed); it runs from a local directory, never a remote one."
  (when-let* ((exe (executable-find (car command))))
    (let ((out (generate-new-buffer " *drgnx-tty*" t))
          (err (generate-new-buffer " *drgnx-tty-err*" t))
          (deadline (+ (float-time) timeout))
          (default-directory "/")
          (process-environment (append (mapcar (lambda (pair)
                                                 (if (cdr pair) (format "%s=%s" (car pair) (cdr pair)) (car pair)))
                                               env)
                                       process-environment)))
      (unwind-protect
          (when-let* ((proc (ignore-errors
                              (make-process :name "drgnx-tty" :buffer out :stderr err :noquery t
                                            :connection-type 'pipe :sentinel #'ignore
                                            :command (cons exe (cdr command))))))
            (while (and (process-live-p proc) (< (float-time) deadline))
              (accept-process-output proc 0.05))
            (if (process-live-p proc)
                (progn (delete-process proc) nil)
              (accept-process-output proc 0)
              (split-string (with-current-buffer out (buffer-string)) "\n" t)))
        (let ((kill-buffer-query-functions nil))
          (dolist (buf (list out err))
            (when-let* ((p (get-buffer-process buf))) (delete-process p))
            (kill-buffer buf)))))))

(defun drgnx-tty-tmux-options (&optional env)
  "tmux's options that decide copy and keys, and its client's terminal: (:set-clipboard STR :extended-keys STR
:client-termtype STR), from one `tmux' call, 1 s at most.  TMUX comes from ENV, the client's environment
(`drgnx-tty-env'; this Emacs's own when nil): the call goes to that client's server (`-S' its socket, with its
TMUX).  nil outside tmux, or when tmux does not answer.  A nil value means unknown: an option this tmux lacks
(extended-keys before 3.2) or no #{client_termtype} (before 3.4, or no client)."
  (when-let* ((tmux (drgnx-tty--env-get env "TMUX"))
              ((not (string-empty-p tmux)))
              (socket (car (split-string tmux ",")))
              ((not (string-empty-p socket)))
              (lines (drgnx-tty--command-lines
                      (list "tmux" "-S" socket "show" "-sv" "set-clipboard" ";" "show" "-sv" "extended-keys"
                            ";" "display" "-p" "#{client_termtype}")
                      1 (list (cons "TMUX" tmux)))))
    (list :set-clipboard (nth 0 lines) :extended-keys (nth 1 lines) :client-termtype (nth 2 lines))))

;;;; This terminal

(defun drgnx-tty--read-report ()
  "terminal-report.eld from the state dir (written for each terminal frame), nil when missing, unreadable or
not a plist.  Emacs's reader evaluates nothing (it has no read-time evaluation), so a planted file is only data."
  (let ((file (expand-file-name "terminal-report.eld" (drgnx-state-dir))))
    (when-let* ((data (ignore-errors
                        (with-temp-buffer
                          (insert-file-contents file)
                          (read (current-buffer)))))
                ((and (consp data) (plistp data))))
      data)))

(defun drgnx-tty-facts (&optional frame)
  "The terminal FRAME's client runs in (this Emacs's own when FRAME is nil):
\(:in-terminal BOOL :term :identity :colorterm :terminfo :tmux :ssh :report).
Everything comes from the client's environment (`drgnx-tty-env'), never the daemon's.  :in-terminal is nil
when TERM is unset or dumb, and the terminal's other facts are then nil too.  Inside tmux, the identity's
:outer is tmux's #{client_termtype} when it names a terminal, else the environment's hint.  :report is the
last terminal-report.eld."
  (let* ((env (drgnx-tty-env frame))
         (term (drgnx-tty--get env "TERM"))
         (in (and term (not (equal term "dumb")) t))
         (tmux (and in (drgnx-tty-tmux-options env)))
         (identity (and in (drgnx-tty-identify env)))
         (outer (car (drgnx-tty--from-answer
                      (and (plist-get tmux :client-termtype)
                           (concat "\eP>|" (plist-get tmux :client-termtype) "\e\\"))))))
    (when (and outer (not (eq outer 'tmux)) (eq (plist-get identity :id) 'tmux))
      (setq identity (plist-put identity :outer outer)))
    (list :in-terminal in
          :term term
          :identity identity
          :colorterm (drgnx-tty--get env "COLORTERM")
          :terminfo (and in (drgnx-tty-terminfo-p term env) t)
          :tmux tmux
          :ssh (and (or (drgnx-tty--get env "SSH_CONNECTION") (drgnx-tty--get env "SSH_TTY")) t)
          :report (drgnx-tty--read-report))))

;;;; Onboarding

(defun drgnx-tty--fix-lines (row)
  "ROW's fixes that are config lines (not \"none: …\")."
  (seq-remove (lambda (fix) (string-prefix-p "none" fix)) (mapcar #'cdr (plist-get row :fixes))))

(defun drgnx-tty-onboard-note (&optional id)
  "One paragraph for onboarding: the terminals drgnx works best in and, with ID, that terminal's row — what
works, what does not, and the lines that fix it."
  (let* ((best "drgnx works best in kitty, foot, Ghostty, or WezTerm with enable_kitty_keyboard on: they send \
C-S- chords and the other shortcuts, and copy to your computer's clipboard, over SSH as well (OSC 52). Each \
keeps some C-S- chords for itself; docs/guide/terminal.md gives the line that frees them.")
         (row (and id (drgnx-tty-terminal id))))
    (if (not row)
        (concat best (if id " drgnx does not know this terminal: F1 (VS Code keys) and the palette, or M-x, reach \
every command." ""))
      (let* ((unconfirmed (plist-get row :unconfirmed))
             (say (lambda (text &rest cells)
                    (if (seq-some (lambda (cell) (memq cell unconfirmed)) cells) (concat text " (unconfirmed)") text)))
             (keys (or (plist-get row :kkp) (plist-get row :mok)))
             (works (delq nil (list (and (plist-get row :kkp)
                                         (funcall say "every shortcut (kitty keyboard protocol)" :kkp))
                                    (and (not (plist-get row :kkp)) (plist-get row :mok)
                                         (funcall say "C-S- chords (modifyOtherKeys)" :mok))
                                    (and (plist-get row :osc52) (funcall say "copy to the clipboard (OSC 52)" :osc52))
                                    (and (plist-get row :truecolor) (funcall say "true colour" :truecolor))
                                    (and (plist-get row :mouse) (funcall say "the mouse" :mouse)))))
             (lacks (delq nil (list (and (not keys) (funcall say "no C-S- chords" :kkp :mok))
                                    (and (not (plist-get row :osc52))
                                         (funcall say "no OSC 52 copy to the clipboard" :osc52))
                                    (and (not (plist-get row :truecolor)) (funcall say "no true colour" :truecolor))
                                    (and (not (plist-get row :mouse)) (funcall say "no mouse" :mouse)))))
             (takes (plist-get row :takes))
             (fixes (drgnx-tty--fix-lines row)))
        (concat best " In " (plist-get row :name) ": "
                (if works (concat (string-join works ", ") (if (cdr works) " work" " works")) "little works")
                (if lacks (concat "; " (string-join lacks ", ")) "")
                "."
                (if takes
                    (funcall say (format " It keeps %d shortcut%s for itself (%s%s)" (length takes) (if (cdr takes) "s" "")
                                         (string-join (seq-take takes 3) ", ") (if (nthcdr 3 takes) ", …" ""))
                             :takes)
                  "")
                (if takes "." "")
                (if fixes (concat " Fixes: " (string-join fixes "; ") ".") "")
                (if keys "" " F1 (VS Code keys) and the palette, or M-x, reach every command."))))))

(provide 'drgnx-tty)
;;; drgnx-tty.el ends here
