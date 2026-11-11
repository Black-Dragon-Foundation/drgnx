;;; drgnx-term-settings.el --- Ghostty's options as drgnx settings -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Every option of Ghostty's configuration (https://ghostty.org/docs/config/reference) has its place in drgnx's
;; terminal (`drgnx-term-settings-options'): a `drgnx-term-<option>' setting that applies to open terminals at once
;; (`live') or to new ones (`spawn'), a face (every colour), an existing drgnx or Emacs setting (`mapped'), or no
;; place, with the reason (`none', `later').  The live settings the worker reads go to every open terminal as one
;; `term/config' (`drgnx-term--apply-config'); the others are read where they act.  The table is written into
;; docs/reference/terminal-settings.md (`drgnx-term-settings-write-reference'), and a test checks it against the
;; pinned list of Ghostty's options (test/fixtures/ghostty-options.txt), so an option Ghostty adds fails until it has
;; a place.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-setting)

(declare-function drgnx-term--apply-config "drgnx-term" ())
(declare-function drgnx-term--apply-local "drgnx-term" ())

;;;; Live: the worker's

(drgnx-defsetting drgnx-term-scrollback-bytes (* 64 1024 1024)
  "The most bytes of scrollback a terminal remembers (Find in Terminal and copy reach that far), whatever
`drgnx-term-scrollback-lines' keeps in its buffer.  A change applies to every terminal at once."
  :type 'natnum :group 'drgnx :scope 'global :agents 'never :schema 'natnum :apply #'drgnx-term--apply-config)

(drgnx-defsetting drgnx-term-cursor-style "block"
  "The cursor a terminal shows until its program chooses one: \"block\", \"block_hollow\", \"bar\" or \"underline\".
A change applies to every terminal at once (a program's own choice is reset)."
  :type '(choice (const "block") (const "block_hollow") (const "bar") (const "underline"))
  :group 'drgnx :scope 'global :agents 'never :schema '(enum "block" "block_hollow" "bar" "underline")
  :apply #'drgnx-term--apply-config)

(drgnx-defsetting drgnx-term-enquiry-response ""
  "What a terminal answers a program that sends ENQ (0x05); empty: nothing.  Applies to every terminal at once."
  :type 'string :group 'drgnx :scope 'global :agents 'never :schema 'string :apply #'drgnx-term--apply-config)

(drgnx-defsetting drgnx-term-title-report nil
  "Whether a program may read a terminal's title back (CSI 21 t).  Off by default: a program can set a title and read
it back as typed input, which can carry commands.  Applies to every terminal at once."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean :apply #'drgnx-term--apply-config)

(drgnx-defsetting drgnx-term-grapheme-width-method "unicode"
  "How wide a terminal counts a grapheme cluster (an emoji sequence, a letter with accents): \"unicode\" (as Unicode
says, one width for the cluster) or \"legacy\" (each code point its own width, as older programs expect).  A program
can still switch it (mode 2027).  Applies to every terminal at once."
  :type '(choice (const "unicode") (const "legacy"))
  :group 'drgnx :scope 'global :agents 'never :schema '(enum "unicode" "legacy") :apply #'drgnx-term--apply-config)

;;;; Live: drgnx's

(drgnx-defsetting drgnx-term-desktop-notifications t
  "Whether a program's notification (OSC 9, OSC 777) becomes a drgnx notice."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean)

(drgnx-defsetting drgnx-term-clipboard-paste-protection t
  "Whether Paste asks first when the text could run commands: it holds a line break, or the end of a bracketed paste,
and the program did not ask for bracketed paste (or `drgnx-term-clipboard-paste-bracketed-safe' is off)."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean)

(drgnx-defsetting drgnx-term-clipboard-paste-bracketed-safe t
  "Whether a paste into a program that asked for bracketed paste is safe whatever it holds (but the end of a
bracketed paste itself).  Off: `drgnx-term-clipboard-paste-protection' asks about every multi-line paste."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean)

(drgnx-defsetting drgnx-term-clipboard-trim-trailing-spaces t
  "Whether text copied from a terminal loses the spaces at the end of each line."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean)

(drgnx-defsetting drgnx-term-clipboard-codepoint-map nil
  "Characters replaced in text copied from a terminal: a list of (FROM TO REPLACEMENT), each character from FROM to
TO (code points) becoming the string REPLACEMENT; e.g. box-drawing lines as plain dashes."
  :type '(repeat (list (character :tag "From") (character :tag "To") (string :tag "Replacement")))
  :group 'drgnx :scope 'global :agents 'never :schema '(list-of (list-of any)))

(drgnx-defsetting drgnx-term-copy-on-select nil
  "Whether selecting a terminal's text with the mouse copies it at once (to the kill ring and the clipboard).
Applies to every terminal at once."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean :apply #'drgnx-term--apply-local)

(drgnx-defsetting drgnx-term-selection-clear-on-copy t
  "Whether Copy in a terminal deselects the text it copied."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean)

(drgnx-defsetting drgnx-term-selection-clear-on-typing t
  "Whether typing into a terminal deselects its text."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean)

(drgnx-defsetting drgnx-term-selection-word-chars " \t'\"│`|:;,()[]{}<>$"
  "The characters that end a word when a double click selects one in a terminal; every other character (a slash, a
dot, a dash) is part of the word, so a path or an address is selected whole.  Applies to every terminal at once."
  :type 'string :group 'drgnx :scope 'global :agents 'never :schema 'string :apply #'drgnx-term--apply-local)

(drgnx-defsetting drgnx-term-mouse-reporting t
  "Whether a program that asks for the mouse gets it.  Off: clicks and the wheel in a terminal are always drgnx's."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean)

(drgnx-defsetting drgnx-term-mouse-shift-capture nil
  "Whether a program that tracks the mouse also gets clicks with Shift held.  Off: a Shift-click is drgnx's, to
select text in a program that takes the mouse."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean)

(drgnx-defsetting drgnx-term-scroll-to-bottom '(keystroke)
  "When a terminal scrolled back to earlier output goes back to its cursor: on a keystroke (`keystroke'), on new
output (`output'), both, or never (nil)."
  :type '(set (const keystroke) (const output))
  :group 'drgnx :scope 'global :agents 'never :schema '(list-of symbol))

(drgnx-defsetting drgnx-term-notify-on-command-finish 'never
  "When a command that ran a long time ending in a terminal is told (`drgnx-term-notify-on-command-finish-action'):
`never', `unfocused' (when its terminal is not the selected window) or `always'.  It needs the shell's integration,
which marks where a command starts and ends."
  :type '(choice (const never) (const unfocused) (const always))
  :group 'drgnx :scope 'global :agents 'never :schema '(enum never unfocused always))

(drgnx-defsetting drgnx-term-notify-on-command-finish-action '(bell)
  "How a finished command is told: `bell' rings the bell, `notify' adds a drgnx notice."
  :type '(set (const bell) (const notify))
  :group 'drgnx :scope 'global :agents 'never :schema '(list-of symbol))

(drgnx-defsetting drgnx-term-notify-on-command-finish-after 5
  "How many seconds a command must run before its end is told."
  :type 'number :group 'drgnx :scope 'global :agents 'never :schema 'number)

(drgnx-defsetting drgnx-term-abnormal-command-exit-runtime 250
  "Milliseconds: a terminal whose program fails (a code other than 0, or a signal) sooner than this after it started
keeps its buffer open with the status, even a shell's, so the error can be read."
  :type 'natnum :group 'drgnx :scope 'global :agents 'never :schema 'natnum)

(drgnx-defsetting drgnx-term-wait-after-command nil
  "Whether every terminal's buffer stays open after its program ended, with the status.  Off: a shell's buffer
closes, and a command's stays (what it printed can be read)."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean)

(drgnx-defsetting drgnx-term-confirm-close-surface t
  "Whether closing a terminal asks first: t when a program runs in it (not a shell at its prompt), `always', or nil
(never).  Only a command you run asks; quitting drgnx asks once for every terminal."
  :type '(choice (const :tag "When a program runs" t) (const always) (const :tag "Never" nil))
  :group 'drgnx :scope 'global :agents 'never :schema '(or boolean (enum always)))

(drgnx-defsetting drgnx-term-on-quit 'ask
  "What quitting drgnx does with its terminals: `ask' (when a program runs in one, the quit question offers Keep
Running, Close Them and Cancel; Keep Running keeps those terminals and closes idle shells), `keep' (every terminal
keeps running, for the next drgnx to reattach) or `close' (they close, after the usual question about running
programs).  A quit that cannot ask (a daemon's shutdown, `kill-emacs' from a script) keeps the terminals whose program
runs; a crash keeps them all."
  :type '(choice (const ask) (const keep) (const close))
  :group 'drgnx :scope 'global :agents 'never :schema '(enum ask keep close))

(drgnx-defsetting drgnx-term-reattach 'ask
  "What drgnx does with the terminals an earlier drgnx left running (kept at its quit, or after its crash): `ask' (a
notice offers them: Reattach All, Choose… or Close Them), `always' (they open here at once) or `never' (only
Reattach Terminal shows them).  A terminal another running drgnx shows is never offered."
  :type '(choice (const ask) (const always) (const never))
  :group 'drgnx :scope 'global :agents 'never :schema '(enum ask always never))

(drgnx-defsetting drgnx-term-detached-keep 24
  "Hours a terminal no drgnx shows keeps running before its program is ended (SIGHUP); 0: until it ends by itself or
the machine restarts.  The terminal's own worker counts the time, so no drgnx needs to run.  A change applies to
every terminal at once."
  :type 'natnum :group 'drgnx :scope 'global :agents 'never :schema 'natnum :apply #'drgnx-term--apply-config)

(drgnx-defsetting drgnx-term-progress-style t
  "Whether a program's progress (OSC 9;4) shows on its terminal's tab."
  :type 'boolean :group 'drgnx :scope 'global :agents 'never :schema 'boolean)

(drgnx-defsetting drgnx-term-title nil
  "A fixed title for every terminal's tab; nil: the title the program sets."
  :type '(choice (const nil) string) :group 'drgnx :scope 'global :agents 'never :schema '(or null string))

;;;; New terminals: the process

(drgnx-defsetting drgnx-term-command nil
  "The program a new terminal runs, with its arguments; nil: your shell (`drgnx-terminal-shell').  Applies to new
terminals."
  :type '(repeat string) :group 'drgnx :scope 'global :agents 'never :schema '(list-of string))

(drgnx-defsetting drgnx-term-input nil
  "Text typed into a new terminal as soon as it starts, as if from the keyboard; nil: none.  Applies to new
terminals."
  :type '(choice (const nil) string) :group 'drgnx :scope 'global :agents 'never :schema '(or null string))

(drgnx-defsetting drgnx-term-env nil
  "Environment entries of new terminals' programs, \"NAME=VALUE\" each, over drgnx's own; \"NAME\" alone unsets it.
Applies to new terminals."
  :type '(repeat string) :group 'drgnx :scope 'global :agents 'never :schema '(list-of string))

(drgnx-defsetting drgnx-term-term "xterm-ghostty"
  "The TERM a new terminal's program sees.  \"xterm-ghostty\" (Ghostty's entry, which `drgnx build' compiles into
<data>/terminfo; TERMINFO then names that folder) falls back to \"xterm-256color\" while the entry is not there.
Applies to new terminals."
  :type 'string :group 'drgnx :scope 'global :agents 'never :schema 'string)

(drgnx-defsetting drgnx-term-working-directory nil
  "Where New Terminal starts: nil, the folder of what you are looking at; `home', your home folder; or a folder.
Applies to new terminals."
  :type '(choice (const nil) (const home) directory)
  :group 'drgnx :scope 'global :agents 'never :schema '(or null symbol string))

(drgnx-defsetting drgnx-term-shell-integration 'detect
  "Which shell integration a new terminal loads: `detect' (from the shell's name: bash, zsh, fish, elvish), one of
those, or `none'.  It marks prompts and commands, reports the folder and sets the title.  Applies to new terminals."
  :type '(choice (const detect) (const none) (const bash) (const zsh) (const fish) (const elvish))
  :group 'drgnx :scope 'global :agents 'never :schema '(enum detect none bash zsh fish elvish))

(drgnx-defsetting drgnx-term-shell-integration-features '("cursor" "title" "sudo")
  "The features of the shell integration a new terminal turns on (Ghostty's names: \"cursor\", \"title\", \"sudo\",
\"path\").  Ghostty's ssh features are `drgnx-term-ssh-terminfo'.  Applies to new terminals."
  :type '(repeat string) :group 'drgnx :scope 'global :agents 'never :schema '(list-of string))

(drgnx-defsetting drgnx-term-ssh-terminfo 'fallback
  "What `ssh' typed in a terminal does about TERM (with drgnx's shell file sourced): `fallback', ssh says
\"xterm-256color\", which every host knows; `install', the first ssh to a host installs Ghostty's entry there with the
host's tic, once, and later ones keep \"xterm-ghostty\".  Applies to new terminals."
  :type '(choice (const fallback) (const install)) :group 'drgnx :scope 'global :agents 'never
  :schema '(enum fallback install))

(drgnx-defsetting drgnx-term-linux-cgroup-memory-limit nil
  "The most memory a new terminal (its program and all it starts) may use, in systemd's form (\"4G\", \"512M\"); nil:
no limit.  Needs a user systemd.  Applies to new terminals."
  :type '(choice (const nil) string) :group 'drgnx :scope 'global :agents 'never
  :schema '(or null (string :match "\\`[0-9]+[KMGT]?\\'")))

(drgnx-defsetting drgnx-term-linux-cgroup-processes-limit nil
  "The most processes a new terminal (its program and all it starts) may run; nil: no limit.  Needs a user systemd.
Applies to new terminals."
  :type '(choice (const nil) natnum) :group 'drgnx :scope 'global :agents 'never :schema '(or null natnum))

;;;; Every Ghostty option's place

(defconst drgnx-term-settings--reasons
  '((renderer . "Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own")
    (gpu . "Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg")
    (windows . "Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows")
    (quick . "Ghostty's drop-down terminal; the panel's Terminal tab does that job")
    (gtk . "Ghostty's GTK app; drgnx's Linux window is Nidhogg's")
    (macos . "Ghostty's macOS app; Naglfar owns drgnx's Mac window")
    (app . "Ghostty's own lifecycle, config files, IO loop and UI language; drgnx has its own")
    (scope . "under a user systemd every terminal runs in a scope of its own, which keeps it running across a hub restart: drgnx never starts one without it")
    (no-switch . "libghostty-vt 1.0 has no switch for it: the engine's own behaviour applies")
    (images . "images are not shown in this release: the engine keeps none"))
  "Why an option has no place in drgnx: a key of `drgnx-term-settings-options' rows of class `none'.")

(defconst drgnx-term-settings-options
  `(;; the terminal core: live, the worker's
    ("scrollback-limit" live drgnx-term-scrollback-bytes "the rows in the buffer: `drgnx-term-scrollback-lines'")
    ("cursor-style" live drgnx-term-cursor-style)
    ("cursor-style-blink" mapped "`blink-cursor-mode'" "Emacs blinks every cursor alike")
    ("image-storage-limit" none images)
    ("enquiry-response" live drgnx-term-enquiry-response)
    ("desktop-notifications" live drgnx-term-desktop-notifications)
    ("title-report" live drgnx-term-title-report)
    ("osc-color-report-format" none no-switch)
    ("vt-kam-allowed" none no-switch)
    ("grapheme-width-method" live drgnx-term-grapheme-width-method)
    ("clipboard-read" later "a program never reads the clipboard: every read is refused")
    ("clipboard-write" live drgnx-term-clipboard-write)
    ("palette-generate" later "the 256 colours above the 16 faces stay the standard cube and greys")
    ("palette-harmonious" later "the 256 colours above the 16 faces stay the standard cube and greys")
    ("minimum-contrast" later "a program's colours are drawn as it sets them")
    ;; drgnx's behaviour: live
    ("clipboard-paste-protection" live drgnx-term-clipboard-paste-protection)
    ("clipboard-paste-bracketed-safe" live drgnx-term-clipboard-paste-bracketed-safe)
    ("clipboard-trim-trailing-spaces" live drgnx-term-clipboard-trim-trailing-spaces)
    ("clipboard-codepoint-map" live drgnx-term-clipboard-codepoint-map)
    ("copy-on-select" live drgnx-term-copy-on-select)
    ("selection-clear-on-copy" live drgnx-term-selection-clear-on-copy)
    ("selection-clear-on-typing" live drgnx-term-selection-clear-on-typing)
    ("selection-word-chars" live drgnx-term-selection-word-chars)
    ("mouse-reporting" live drgnx-term-mouse-reporting)
    ("mouse-shift-capture" live drgnx-term-mouse-shift-capture)
    ("mouse-scroll-multiplier" mapped "`mouse-wheel-scroll-amount'")
    ("cursor-click-to-move" later "a click does not move the cursor at a prompt")
    ("link" later "only OSC 8 links are links; there are no link patterns of your own")
    ("link-url" later "an address in plain output is not a link (OSC 8 links are)")
    ("link-previews" mapped "`help-echo'" "a link's target shows when the pointer rests on it")
    ("scroll-to-bottom" live drgnx-term-scroll-to-bottom)
    ("bell-features" mapped "`ring-bell-function', `visible-bell'" "the bell is Emacs's")
    ("bell-audio-path" mapped "`ring-bell-function'")
    ("bell-audio-volume" mapped "`ring-bell-function'")
    ("notify-on-command-finish" live drgnx-term-notify-on-command-finish)
    ("notify-on-command-finish-action" live drgnx-term-notify-on-command-finish-action)
    ("notify-on-command-finish-after" live drgnx-term-notify-on-command-finish-after)
    ("abnormal-command-exit-runtime" live drgnx-term-abnormal-command-exit-runtime)
    ("wait-after-command" live drgnx-term-wait-after-command)
    ("confirm-close-surface" live drgnx-term-confirm-close-surface)
    ("progress-style" live drgnx-term-progress-style)
    ("title" live drgnx-term-title)
    ("right-click-action" mapped "the right-click menu (`drgnx-surfaces-define-context')")
    ;; the process: new terminals
    ("command" spawn drgnx-term-command)
    ("initial-command" mapped "`drgnx-term-command'" "drgnx has no first window: one setting for every terminal")
    ("input" spawn drgnx-term-input)
    ("env" spawn drgnx-term-env)
    ("term" spawn drgnx-term-term)
    ("working-directory" spawn drgnx-term-working-directory)
    ("shell-integration" spawn drgnx-term-shell-integration)
    ("shell-integration-features" spawn drgnx-term-shell-integration-features
     "ssh-env and ssh-terminfo: `drgnx-term-ssh-terminfo'")
    ("linux-cgroup" none scope)
    ("linux-cgroup-memory-limit" spawn drgnx-term-linux-cgroup-memory-limit)
    ("linux-cgroup-processes-limit" spawn drgnx-term-linux-cgroup-processes-limit)
    ("linux-cgroup-hard-fail" none scope)
    ;; colours: faces
    ("background" face drgnx-term-default ":background")
    ("foreground" face drgnx-term-default ":foreground")
    ("palette" face drgnx-term-color-0 "`drgnx-term-color-0' to `drgnx-term-color-15', from the theme's `ansi-color-*'")
    ("bold-color" face drgnx-term-bold)
    ("faint-opacity" face drgnx-term-faint)
    ("cursor-color" face drgnx-term-cursor ":background")
    ("cursor-text" face drgnx-term-cursor ":foreground")
    ("selection-background" face drgnx-term-selection ":background")
    ("selection-foreground" face drgnx-term-selection ":foreground")
    ("search-background" face drgnx-term-search ":background")
    ("search-foreground" face drgnx-term-search ":foreground")
    ("search-selected-background" face drgnx-term-search-selected ":background")
    ("search-selected-foreground" face drgnx-term-search-selected ":foreground")
    ;; drgnx's or Emacs's own settings
    ("theme" mapped "`drgnx-look-theme'")
    ("window-theme" mapped "`drgnx-look-theme'")
    ,@(mapcar (lambda (o) (list o 'mapped "`drgnx-look-font-terminal' (the look's terminal font)"))
              '("font-family" "font-family-bold" "font-family-italic" "font-family-bold-italic"
                "font-style" "font-style-bold" "font-style-italic" "font-style-bold-italic"
                "font-size" "font-feature" "font-variation" "font-variation-bold" "font-variation-italic"
                "font-variation-bold-italic" "font-synthetic-style"))
    ("font-codepoint-map" mapped "Emacs's fontsets (`set-fontset-font')")
    ("adjust-cell-height" mapped "`line-spacing' in a terminal's buffer")
    ("adjust-underline-position" mapped "`underline-minimum-offset'")
    ,@(mapcar (lambda (o) (list o 'mapped "key profiles (`drgnx-keys-bind', `drgnx-keys-unbind', `drgnx-keys-layers')"))
              '("keybind" "key-tables" "key-remap" "chained-actions"))
    ("macos-option-as-alt" mapped "`drgnx-keys-mac-option'")
    ("command-palette-entry" mapped "the command registry (`drgnx-command-define')")
    ("mouse-hide-while-typing" mapped "`make-pointer-invisible'")
    ("focus-follows-mouse" mapped "`mouse-autoselect-window'")
    ("click-repeat-interval" mapped "`double-click-time'")
    ("app-notifications" mapped "drgnx's notices")
    ("scrollbar" mapped "the panel's scroll bar")
    ("unfocused-split-opacity" mapped "drgnx's window dimming")
    ("unfocused-split-fill" mapped "drgnx's window dimming")
    ("split-divider-color" mapped "the window divider's face")
    ("window-save-state" mapped "the workbench's state" "terminals are not restored")
    ("window-inherit-font-size" mapped "`text-scale-mode' in each buffer")
    ,@(mapcar (lambda (o) (list o 'mapped "New Terminal opens in the folder of what you are looking at"))
              '("split-inherit-working-directory" "tab-inherit-working-directory" "window-inherit-working-directory"))
    ;; no place
    ,@(mapcar (lambda (o) (list o 'none 'renderer))
              '("adjust-cell-width" "adjust-font-baseline" "adjust-box-thickness" "adjust-cursor-height"
                "adjust-cursor-thickness" "adjust-icon-height" "adjust-overline-position" "adjust-overline-thickness"
                "adjust-strikethrough-position" "adjust-strikethrough-thickness" "adjust-underline-thickness"
                "font-thicken" "font-thicken-strength" "font-shaping-break" "freetype-load-flags" "alpha-blending"
                "cursor-opacity"))
    ,@(mapcar (lambda (o) (list o 'none 'gpu))
              '("background-opacity" "background-opacity-cells" "background-blur" "background-image"
                "background-image-fit" "background-image-opacity" "background-image-position"
                "background-image-repeat" "custom-shader" "custom-shader-animation" "window-colorspace"
                "window-vsync"))
    ,@(mapcar (lambda (o) (list o 'none 'windows))
              '("window-decoration" "window-height" "window-width" "window-position-x" "window-position-y"
                "window-padding-x" "window-padding-y" "window-padding-balance" "window-padding-color"
                "window-step-resize" "window-subtitle" "window-title-font-family" "window-titlebar-background"
                "window-titlebar-foreground" "window-new-tab-position" "window-show-tab-bar" "maximize" "fullscreen"
                "initial-window" "resize-overlay" "resize-overlay-duration" "resize-overlay-position"
                "split-preserve-zoom" "undo-timeout"))
    ,@(mapcar (lambda (o) (list o 'none 'quick))
              '("quick-terminal-animation-duration" "quick-terminal-autohide" "quick-terminal-keyboard-interactivity"
                "quick-terminal-position" "quick-terminal-screen" "quick-terminal-size"
                "quick-terminal-space-behavior" "gtk-quick-terminal-layer" "gtk-quick-terminal-namespace"))
    ,@(mapcar (lambda (o) (list o 'none 'gtk))
              '("gtk-custom-css" "gtk-opengl-debug" "gtk-single-instance" "gtk-tabs-location" "gtk-titlebar"
                "gtk-titlebar-hide-when-maximized" "gtk-titlebar-style" "gtk-toolbar-style" "gtk-wide-tabs" "class"
                "x11-instance-name"))
    ,@(mapcar (lambda (o) (list o 'none 'macos))
              '("macos-applescript" "macos-auto-secure-input" "macos-custom-icon" "macos-dock-drop-behavior"
                "macos-hidden" "macos-icon" "macos-icon-frame" "macos-icon-ghost-color" "macos-icon-screen-color"
                "macos-non-native-fullscreen" "macos-secure-input-indication" "macos-shortcuts"
                "macos-titlebar-proxy-icon" "macos-titlebar-style" "macos-window-buttons" "macos-window-shadow"))
    ,@(mapcar (lambda (o) (list o 'none 'app))
              '("auto-update" "auto-update-channel" "config-file" "config-default-files"
                "quit-after-last-window-closed" "quit-after-last-window-closed-delay" "async-backend" "language")))
  "Where each Ghostty option is in drgnx: (OPTION CLASS TARGET NOTE).  CLASS is `live' (TARGET a setting that applies
to open terminals at once), `spawn' (a setting for new terminals), `face' (TARGET a face; NOTE its attribute),
`mapped' (TARGET names drgnx's or Emacs's setting), `none' (TARGET a key of `drgnx-term-settings--reasons') or
`later' (TARGET says what drgnx does instead, for now).")

(defun drgnx-term-settings--docline (var)
  "The first sentence of VAR's documentation."
  (let ((doc (or (documentation-property var 'variable-documentation t) "")))
    (string-trim (replace-regexp-in-string "\n" " " (car (split-string doc "\\.  \\|\\.\\'"))))))

(defun drgnx-term-settings--cell (s)
  "S safe in a markdown table cell."
  (replace-regexp-in-string "|" "\\\\|" s))

(defun drgnx-term-settings-reference ()
  "The text of docs/reference/terminal-settings.md, from `drgnx-term-settings-options'."
  (let ((rows (lambda (class fn)
                (mapconcat (lambda (r) (drgnx-term-settings--cell (funcall fn r)))
                           (seq-filter (lambda (r) (eq (nth 1 r) class)) drgnx-term-settings-options)
                           "\n"))))
    (concat
     "# Terminal settings: Ghostty's options in drgnx\n\n"
     "<!-- Generated from `drgnx-term-settings-options' (modules/tools/drgnx-term-settings.el) by "
     "`drgnx-term-settings-write-reference'; do not edit by hand. -->\n\n"
     "drgnx's terminal runs on Ghostty's engine (libghostty-vt). Every option of Ghostty's configuration "
     "([reference](https://ghostty.org/docs/config/reference)) has its place here: a drgnx setting, a face, a setting "
     "drgnx or Emacs already has, or none, with the reason. Set the settings in the Settings view or "
     "`~/.config/drgnx/settings.el` ([settings](settings.md)); a face is the theme's (a face remap changes it).\n\n"
     "## Settings that apply at once\n\nA change reaches every open terminal.\n\n"
     "| Ghostty option | drgnx setting | What it does |\n|---|---|---|\n"
     (funcall rows 'live (lambda (r) (format "| `%s` | `%s` | %s%s |" (nth 0 r) (nth 2 r)
                                             (drgnx-term-settings--docline (nth 2 r))
                                             (if (nth 3 r) (format " (%s)" (nth 3 r)) ""))))
     "\n\n## Settings for new terminals\n\nThey shape the program a terminal starts, so a change applies to the "
     "terminals opened after it.\n\n"
     "| Ghostty option | drgnx setting | What it does |\n|---|---|---|\n"
     (funcall rows 'spawn (lambda (r) (format "| `%s` | `%s` | %s |" (nth 0 r) (nth 2 r)
                                              (drgnx-term-settings--docline (nth 2 r)))))
     "\n\n## Colours: faces\n\nA terminal's colours are faces, so the theme sets them; no setting holds a colour.\n\n"
     "| Ghostty option | Face | Attribute |\n|---|---|---|\n"
     (funcall rows 'face (lambda (r) (format "| `%s` | `%s` | %s |" (nth 0 r) (nth 2 r) (or (nth 3 r) ""))))
     "\n\n## Already a drgnx or Emacs setting\n\n| Ghostty option | Where | Note |\n|---|---|---|\n"
     (funcall rows 'mapped (lambda (r) (format "| `%s` | %s | %s |" (nth 0 r) (nth 2 r) (or (nth 3 r) ""))))
     "\n\n## Not yet\n\n| Ghostty option | What drgnx does for now |\n|---|---|\n"
     (funcall rows 'later (lambda (r) (format "| `%s` | %s |" (nth 0 r) (nth 2 r))))
     "\n\n## No place in drgnx\n\n| Ghostty option | Why |\n|---|---|\n"
     (funcall rows 'none (lambda (r) (format "| `%s` | %s |" (nth 0 r)
                                             (alist-get (nth 2 r) drgnx-term-settings--reasons))))
     "\n")))

(defun drgnx-term-settings-write-reference (file)
  "Write `drgnx-term-settings-reference' to FILE (docs/reference/terminal-settings.md)."
  (with-temp-file file (insert (drgnx-term-settings-reference))))

(provide 'drgnx-term-settings)
;;; drgnx-term-settings.el ends here
