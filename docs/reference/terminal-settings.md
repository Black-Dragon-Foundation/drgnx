# Terminal settings: Ghostty's options in drgnx

<!-- Generated from `drgnx-term-settings-options' (modules/tools/drgnx-term-settings.el) by `drgnx-term-settings-write-reference'; do not edit by hand. -->

drgnx's terminal runs on Ghostty's engine (libghostty-vt). Every option of Ghostty's configuration ([reference](https://ghostty.org/docs/config/reference)) has its place here: a drgnx setting, a face, a setting drgnx or Emacs already has, or none, with the reason. Set the settings in the Settings view or `~/.config/drgnx/settings.el` ([settings](settings.md)); a face is the theme's (a face remap changes it).

## Settings that apply at once

A change reaches every open terminal.

| Ghostty option | drgnx setting | What it does |
|---|---|---|
\| `scrollback-limit` \| `drgnx-term-scrollback-bytes` \| The most bytes of scrollback a terminal remembers (Find in Terminal and copy reach that far), whatever `drgnx-term-scrollback-lines' keeps in its buffer (the rows in the buffer: `drgnx-term-scrollback-lines') \|
\| `cursor-style` \| `drgnx-term-cursor-style` \| The cursor a terminal shows until its program chooses one: "block", "block_hollow", "bar" or "underline". A change applies to every terminal at once (a program's own choice is reset) \|
\| `enquiry-response` \| `drgnx-term-enquiry-response` \| What a terminal answers a program that sends ENQ (0x05); empty: nothing \|
\| `desktop-notifications` \| `drgnx-term-desktop-notifications` \| Whether a program's notification (OSC 9, OSC 777) becomes a drgnx notice \|
\| `title-report` \| `drgnx-term-title-report` \| Whether a program may read a terminal's title back (CSI 21 t) \|
\| `grapheme-width-method` \| `drgnx-term-grapheme-width-method` \| How wide a terminal counts a grapheme cluster (an emoji sequence, a letter with accents): "unicode" (as Unicode says, one width for the cluster) or "legacy" (each code point its own width, as older programs expect) \|
\| `clipboard-write` \| `drgnx-term-clipboard-write` \| Whether a program in a terminal may write the clipboard (OSC 52): what it writes goes to the kill ring \|
\| `clipboard-paste-protection` \| `drgnx-term-clipboard-paste-protection` \| Whether Paste asks first when the text could run commands: it holds a line break, or the end of a bracketed paste, and the program did not ask for bracketed paste (or `drgnx-term-clipboard-paste-bracketed-safe' is off) \|
\| `clipboard-paste-bracketed-safe` \| `drgnx-term-clipboard-paste-bracketed-safe` \| Whether a paste into a program that asked for bracketed paste is safe whatever it holds (but the end of a bracketed paste itself) \|
\| `clipboard-trim-trailing-spaces` \| `drgnx-term-clipboard-trim-trailing-spaces` \| Whether text copied from a terminal loses the spaces at the end of each line \|
\| `clipboard-codepoint-map` \| `drgnx-term-clipboard-codepoint-map` \| Characters replaced in text copied from a terminal: a list of (FROM TO REPLACEMENT), each character from FROM to TO (code points) becoming the string REPLACEMENT; e.g. box-drawing lines as plain dashes \|
\| `copy-on-select` \| `drgnx-term-copy-on-select` \| Whether selecting a terminal's text with the mouse copies it at once (to the kill ring and the clipboard). Applies to every terminal at once \|
\| `selection-clear-on-copy` \| `drgnx-term-selection-clear-on-copy` \| Whether Copy in a terminal deselects the text it copied \|
\| `selection-clear-on-typing` \| `drgnx-term-selection-clear-on-typing` \| Whether typing into a terminal deselects its text \|
\| `selection-word-chars` \| `drgnx-term-selection-word-chars` \| The characters that end a word when a double click selects one in a terminal; every other character (a slash, a dot, a dash) is part of the word, so a path or an address is selected whole \|
\| `mouse-reporting` \| `drgnx-term-mouse-reporting` \| Whether a program that asks for the mouse gets it \|
\| `mouse-shift-capture` \| `drgnx-term-mouse-shift-capture` \| Whether a program that tracks the mouse also gets clicks with Shift held \|
\| `scroll-to-bottom` \| `drgnx-term-scroll-to-bottom` \| When a terminal scrolled back to earlier output goes back to its cursor: on a keystroke (`keystroke'), on new output (`output'), both, or never (nil) \|
\| `notify-on-command-finish` \| `drgnx-term-notify-on-command-finish` \| When a command that ran a long time ending in a terminal is told (`drgnx-term-notify-on-command-finish-action'): `never', `unfocused' (when its terminal is not the selected window) or `always' \|
\| `notify-on-command-finish-action` \| `drgnx-term-notify-on-command-finish-action` \| How a finished command is told: `bell' rings the bell, `notify' adds a drgnx notice \|
\| `notify-on-command-finish-after` \| `drgnx-term-notify-on-command-finish-after` \| How many seconds a command must run before its end is told \|
\| `abnormal-command-exit-runtime` \| `drgnx-term-abnormal-command-exit-runtime` \| Milliseconds: a terminal whose program fails (a code other than 0, or a signal) sooner than this after it started keeps its buffer open with the status, even a shell's, so the error can be read \|
\| `wait-after-command` \| `drgnx-term-wait-after-command` \| Whether every terminal's buffer stays open after its program ended, with the status \|
\| `confirm-close-surface` \| `drgnx-term-confirm-close-surface` \| Whether closing a terminal asks first: t when a program runs in it (not a shell at its prompt), `always', or nil (never) \|
\| `progress-style` \| `drgnx-term-progress-style` \| Whether a program's progress (OSC 9;4) shows on its terminal's tab \|
\| `title` \| `drgnx-term-title` \| A fixed title for every terminal's tab; nil: the title the program sets \|

## Settings for new terminals

They shape the program a terminal starts, so a change applies to the terminals opened after it.

| Ghostty option | drgnx setting | What it does |
|---|---|---|
\| `command` \| `drgnx-term-command` \| The program a new terminal runs, with its arguments; nil: your shell (`drgnx-terminal-shell') \|
\| `input` \| `drgnx-term-input` \| Text typed into a new terminal as soon as it starts, as if from the keyboard; nil: none \|
\| `env` \| `drgnx-term-env` \| Environment entries of new terminals' programs, "NAME=VALUE" each, over drgnx's own; "NAME" alone unsets it. Applies to new terminals \|
\| `term` \| `drgnx-term-term` \| The TERM a new terminal's program sees \|
\| `working-directory` \| `drgnx-term-working-directory` \| Where New Terminal starts: nil, the folder of what you are looking at; `home', your home folder; or a folder. Applies to new terminals \|
\| `shell-integration` \| `drgnx-term-shell-integration` \| Which shell integration a new terminal loads: `detect' (from the shell's name: bash, zsh, fish, elvish), one of those, or `none' \|
\| `shell-integration-features` \| `drgnx-term-shell-integration-features` \| The features of the shell integration a new terminal turns on (Ghostty's names: "cursor", "title", "sudo", "path") \|
\| `linux-cgroup-memory-limit` \| `drgnx-term-linux-cgroup-memory-limit` \| The most memory a new terminal (its program and all it starts) may use, in systemd's form ("4G", "512M"); nil: no limit \|
\| `linux-cgroup-processes-limit` \| `drgnx-term-linux-cgroup-processes-limit` \| The most processes a new terminal (its program and all it starts) may run; nil: no limit \|

## Colours: faces

A terminal's colours are faces, so the theme sets them; no setting holds a colour.

| Ghostty option | Face | Attribute |
|---|---|---|
\| `background` \| `drgnx-term-default` \| :background \|
\| `foreground` \| `drgnx-term-default` \| :foreground \|
\| `palette` \| `drgnx-term-color-0` \| `drgnx-term-color-0' to `drgnx-term-color-15', from the theme's `ansi-color-*' \|
\| `bold-color` \| `drgnx-term-bold` \|  \|
\| `faint-opacity` \| `drgnx-term-faint` \|  \|
\| `cursor-color` \| `drgnx-term-cursor` \| :background \|
\| `cursor-text` \| `drgnx-term-cursor` \| :foreground \|
\| `selection-background` \| `drgnx-term-selection` \| :background \|
\| `selection-foreground` \| `drgnx-term-selection` \| :foreground \|
\| `search-background` \| `drgnx-term-search` \| :background \|
\| `search-foreground` \| `drgnx-term-search` \| :foreground \|
\| `search-selected-background` \| `drgnx-term-search-selected` \| :background \|
\| `search-selected-foreground` \| `drgnx-term-search-selected` \| :foreground \|

## Already a drgnx or Emacs setting

| Ghostty option | Where | Note |
|---|---|---|
\| `cursor-style-blink` \| `blink-cursor-mode' \| Emacs blinks every cursor alike \|
\| `mouse-scroll-multiplier` \| `mouse-wheel-scroll-amount' \|  \|
\| `link-previews` \| `help-echo' \| a link's target shows when the pointer rests on it \|
\| `bell-features` \| `ring-bell-function', `visible-bell' \| the bell is Emacs's \|
\| `bell-audio-path` \| `ring-bell-function' \|  \|
\| `bell-audio-volume` \| `ring-bell-function' \|  \|
\| `right-click-action` \| the right-click menu (`drgnx-surfaces-define-context') \|  \|
\| `initial-command` \| `drgnx-term-command' \| drgnx has no first window: one setting for every terminal \|
\| `theme` \| `drgnx-look-theme' \|  \|
\| `window-theme` \| `drgnx-look-theme' \|  \|
\| `font-family` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-family-bold` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-family-italic` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-family-bold-italic` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-style` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-style-bold` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-style-italic` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-style-bold-italic` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-size` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-feature` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-variation` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-variation-bold` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-variation-italic` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-variation-bold-italic` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-synthetic-style` \| `drgnx-look-font-terminal' (the look's terminal font) \|  \|
\| `font-codepoint-map` \| Emacs's fontsets (`set-fontset-font') \|  \|
\| `adjust-cell-height` \| `line-spacing' in a terminal's buffer \|  \|
\| `adjust-underline-position` \| `underline-minimum-offset' \|  \|
\| `keybind` \| key profiles (`drgnx-keys-bind', `drgnx-keys-unbind', `drgnx-keys-layers') \|  \|
\| `key-tables` \| key profiles (`drgnx-keys-bind', `drgnx-keys-unbind', `drgnx-keys-layers') \|  \|
\| `key-remap` \| key profiles (`drgnx-keys-bind', `drgnx-keys-unbind', `drgnx-keys-layers') \|  \|
\| `chained-actions` \| key profiles (`drgnx-keys-bind', `drgnx-keys-unbind', `drgnx-keys-layers') \|  \|
\| `macos-option-as-alt` \| `drgnx-keys-mac-option' \|  \|
\| `command-palette-entry` \| the command registry (`drgnx-command-define') \|  \|
\| `mouse-hide-while-typing` \| `make-pointer-invisible' \|  \|
\| `focus-follows-mouse` \| `mouse-autoselect-window' \|  \|
\| `click-repeat-interval` \| `double-click-time' \|  \|
\| `app-notifications` \| drgnx's notices \|  \|
\| `scrollbar` \| the panel's scroll bar \|  \|
\| `unfocused-split-opacity` \| drgnx's window dimming \|  \|
\| `unfocused-split-fill` \| drgnx's window dimming \|  \|
\| `split-divider-color` \| the window divider's face \|  \|
\| `window-save-state` \| the workbench's state \| terminals are not restored \|
\| `window-inherit-font-size` \| `text-scale-mode' in each buffer \|  \|
\| `split-inherit-working-directory` \| New Terminal opens in the folder of what you are looking at \|  \|
\| `tab-inherit-working-directory` \| New Terminal opens in the folder of what you are looking at \|  \|
\| `window-inherit-working-directory` \| New Terminal opens in the folder of what you are looking at \|  \|

## Not yet

| Ghostty option | What drgnx does for now |
|---|---|
\| `clipboard-read` \| a program never reads the clipboard: every read is refused \|
\| `palette-generate` \| the 256 colours above the 16 faces stay the standard cube and greys \|
\| `palette-harmonious` \| the 256 colours above the 16 faces stay the standard cube and greys \|
\| `minimum-contrast` \| a program's colours are drawn as it sets them \|
\| `cursor-click-to-move` \| a click does not move the cursor at a prompt \|
\| `link` \| only OSC 8 links are links; there are no link patterns of your own \|
\| `link-url` \| an address in plain output is not a link (OSC 8 links are) \|

## No place in drgnx

| Ghostty option | Why |
|---|---|
\| `image-storage-limit` \| images are not shown in this release: the engine keeps none \|
\| `osc-color-report-format` \| libghostty-vt 1.0 has no switch for it: the engine's own behaviour applies \|
\| `vt-kam-allowed` \| libghostty-vt 1.0 has no switch for it: the engine's own behaviour applies \|
\| `linux-cgroup` \| under a user systemd every terminal runs in a scope of its own, which keeps it running across a hub restart: drgnx never starts one without it \|
\| `linux-cgroup-hard-fail` \| under a user systemd every terminal runs in a scope of its own, which keeps it running across a hub restart: drgnx never starts one without it \|
\| `adjust-cell-width` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `adjust-font-baseline` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `adjust-box-thickness` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `adjust-cursor-height` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `adjust-cursor-thickness` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `adjust-icon-height` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `adjust-overline-position` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `adjust-overline-thickness` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `adjust-strikethrough-position` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `adjust-strikethrough-thickness` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `adjust-underline-thickness` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `font-thicken` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `font-thicken-strength` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `font-shaping-break` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `freetype-load-flags` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `alpha-blending` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `cursor-opacity` \| Emacs draws the glyphs and the cursor; drgnx has no cell renderer of its own \|
\| `background-opacity` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `background-opacity-cells` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `background-blur` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `background-image` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `background-image-fit` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `background-image-opacity` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `background-image-position` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `background-image-repeat` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `custom-shader` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `custom-shader-animation` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `window-colorspace` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `window-vsync` \| Ghostty's GPU renderer; transparency and backgrounds are the frame's, set in Nidhogg \|
\| `window-decoration` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-height` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-width` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-position-x` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-position-y` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-padding-x` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-padding-y` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-padding-balance` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-padding-color` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-step-resize` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-subtitle` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-title-font-family` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-titlebar-background` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-titlebar-foreground` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-new-tab-position` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `window-show-tab-bar` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `maximize` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `fullscreen` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `initial-window` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `resize-overlay` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `resize-overlay-duration` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `resize-overlay-position` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `split-preserve-zoom` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `undo-timeout` \| Ghostty's own windows, tabs and splits; the workbench manages drgnx's windows \|
\| `quick-terminal-animation-duration` \| Ghostty's drop-down terminal; the panel's Terminal tab does that job \|
\| `quick-terminal-autohide` \| Ghostty's drop-down terminal; the panel's Terminal tab does that job \|
\| `quick-terminal-keyboard-interactivity` \| Ghostty's drop-down terminal; the panel's Terminal tab does that job \|
\| `quick-terminal-position` \| Ghostty's drop-down terminal; the panel's Terminal tab does that job \|
\| `quick-terminal-screen` \| Ghostty's drop-down terminal; the panel's Terminal tab does that job \|
\| `quick-terminal-size` \| Ghostty's drop-down terminal; the panel's Terminal tab does that job \|
\| `quick-terminal-space-behavior` \| Ghostty's drop-down terminal; the panel's Terminal tab does that job \|
\| `gtk-quick-terminal-layer` \| Ghostty's drop-down terminal; the panel's Terminal tab does that job \|
\| `gtk-quick-terminal-namespace` \| Ghostty's drop-down terminal; the panel's Terminal tab does that job \|
\| `gtk-custom-css` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `gtk-opengl-debug` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `gtk-single-instance` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `gtk-tabs-location` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `gtk-titlebar` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `gtk-titlebar-hide-when-maximized` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `gtk-titlebar-style` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `gtk-toolbar-style` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `gtk-wide-tabs` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `class` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `x11-instance-name` \| Ghostty's GTK app; drgnx's Linux window is Nidhogg's \|
\| `macos-applescript` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-auto-secure-input` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-custom-icon` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-dock-drop-behavior` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-hidden` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-icon` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-icon-frame` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-icon-ghost-color` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-icon-screen-color` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-non-native-fullscreen` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-secure-input-indication` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-shortcuts` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-titlebar-proxy-icon` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-titlebar-style` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-window-buttons` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `macos-window-shadow` \| Ghostty's macOS app; Naglfar owns drgnx's Mac window \|
\| `auto-update` \| Ghostty's own lifecycle, config files, IO loop and UI language; drgnx has its own \|
\| `auto-update-channel` \| Ghostty's own lifecycle, config files, IO loop and UI language; drgnx has its own \|
\| `config-file` \| Ghostty's own lifecycle, config files, IO loop and UI language; drgnx has its own \|
\| `config-default-files` \| Ghostty's own lifecycle, config files, IO loop and UI language; drgnx has its own \|
\| `quit-after-last-window-closed` \| Ghostty's own lifecycle, config files, IO loop and UI language; drgnx has its own \|
\| `quit-after-last-window-closed-delay` \| Ghostty's own lifecycle, config files, IO loop and UI language; drgnx has its own \|
\| `async-backend` \| Ghostty's own lifecycle, config files, IO loop and UI language; drgnx has its own \|
\| `language` \| Ghostty's own lifecycle, config files, IO loop and UI language; drgnx has its own \|
