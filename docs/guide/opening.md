# Opening drgnx: `drgnx .`, `drgnx open`, keep running or quit

drgnx opens like VS Code's `code .`: give it a folder or a file and it shows up in drgnx's window. There is only ever
one drgnx: a second `drgnx PATH` opens the path in the drgnx already running instead of starting another Emacs.

```sh
drgnx .                      # this folder, in the Explorer, in front
drgnx some/dir               # that folder
drgnx file.py "My Project"   # a file in an editor and a folder; quote names with spaces
drgnx open                   # drgnx with the windows as you left them
drgnx open -- -odd-name.txt  # anything after -- is a path, even when it starts with -
drgnx open --wait notes.md   # returns when you are done with the file: drgnx as $EDITOR
drgnx -t .                   # this folder, in this terminal (also: drgnx open -t .)
drgnx --gui .                # this folder, in a window, even over SSH or without a display
```

`drgnx` lives in `~/.local/bin`; "command not found" means that is not on your PATH yet — open a new terminal window
after the installer added it, or add it yourself ([install.md](install.md#what-installsh-does)).

An argument is a path when it is `.` or `..`, contains a `/`, or exists; any other word that is not a drgnx command
is an error (`drgnx frobnicate` says so). A file or folder named like a command (`build`, `test`, …) opens with
`drgnx ./build` or `drgnx open build`. Paths are taken from the directory you are in and passed on as they are, so
spaces, accents (`café.py`) and iCloud folders work. A file that does not exist yet opens as a new, empty file (as
`code new.py` does).

What happens:

- **drgnx is not running:** it starts in the background (an Emacs daemon named `drgnx`, with the Emacs drgnx was
  installed with — see [install.md](install.md)), and the paths open as soon as it answers (it is given 30 s, or
  `DRGNX_OPEN_WAIT` seconds, a whole number above 0 counted on the clock; anything else is refused with a note and 30
  is used; it says "still starting" after a third of that; its startup messages are added to
  `~/.local/state/drgnx/daemon.log`). On Linux, when the systemd user unit `drgnx` is installed and enabled ([packages.md](packages.md#running-drgnx-as-a-daemon)), drgnx starts that unit instead.
  Two `drgnx` commands started at once make one daemon and one window: the second waits for the first (a lock,
  `~/.local/state/drgnx/open-drgnx.lock`, dropped as stale 15 s after the wait above, 45 s by default, if its owner
  died; it is taken by making its `owner` file, never by `mkdir` alone, which uutils' coreutils let two commands both
  win). A window that takes more than 10 s to appear is not waited for further.
- **No window is open:** a window opens, with the layout you left — groups, tabs, docks, Explorer folders
  ([workbench.md](workbench.md#the-layout-survives-a-restart)) — and the paths in front of it.
- **A window is open:** the paths open there and the window comes to the front.

A **folder** becomes the Explorer's first folder (the others stay) and the Explorer is selected, as in VS Code after
`code .`, so quick open and the Search view (`C-p`, `C-S-f`; ⌘P, ⌘⇧F on a Mac) work in that folder's project right away; it does not
open as a directory listing. A **file** opens in the editor. drgnx started by hand as a normal Emacs (not a daemon) answers
`drgnx PATH` too, as long as no other drgnx does.

Inside drgnx, **File → Open Folder…** (palette; `C-k C-o` in the VS Code profile, `SPC f o` in Vim's) asks for a
folder and shows it the same way.

## In a terminal: `drgnx -t`

`drgnx -t [PATH…]` (or `drgnx open -t [PATH…]`) opens a **terminal frame** of the same drgnx, in the terminal you ran
it in, instead of a window: the daemon is started first if it is not running (as above), then the command becomes
`emacsclient -t -s drgnx` and shows the paths — each folder as the Explorer's folder, each file in an editor — in the new
frame. Leave the frame as you leave any client (`C-x C-c`, or close the terminal); the daemon and its windows keep
running. No window is made or raised: a folder opens in the terminal frame even while a desktop window is open (so
does File → Open Folder… typed in a terminal frame). With no path, you get the frame as it stands.

You do not have to type `-t` in two cases: `drgnx` picks the terminal by itself when you are in an **SSH session**
(`SSH_CONNECTION` or `SSH_TTY` is set, even if a display is forwarded) and, on Linux, when there is **no display**
(neither `DISPLAY` nor `WAYLAND_DISPLAY`; a text console) — but only when `drgnx` is run at a terminal (its standard
input and output are one). A script, a launcher or an editor hook gets a window, as without these, and no terminfo
question. Everywhere else `drgnx` opens a window, as above, and `-t` is how you ask for the terminal.

`drgnx --gui [PATH…]` (or `drgnx open --gui [PATH…]`) is the opposite: it skips that choice and opens a window, for
an SSH session with a forwarded display, or a machine where the display is not in the environment. `-t` and `--gui`
together are an error (exit 2). `drgnx open --wait FILE…` in a terminal waits there, as before.

**Unknown terminal type.** (Checked after the opt-in below: a frame that opens in another terminal does not need this one's description.) A terminal frame needs the terminal's description (terminfo) on the machine running Emacs.
When `infocmp "$TERM"` fails there (typically `xterm-kitty` or `xterm-ghostty` over SSH), `drgnx -t` stops with exit 1
and says how to fix it, instead of drawing a broken screen:

```sh
kitten ssh HOST                          # kitty: copies its terminal description to HOST (use it instead of ssh)
infocmp -x | ssh HOST -- tic -x -        # any terminal: run where the terminal works; HOST is the machine running drgnx
TERM=xterm-256color drgnx -t             # this once, with a terminal type the machine knows
```

**A terminal that cannot send every key.** GNOME Terminal and the other VTE terminals, Apple's Terminal and the
Linux console cannot send chords such as `C-S-p`. If you set `drgnx-tty-open-in` (off by default; see
[terminal.md](terminal.md)), `drgnx -t` in one of those starts the capable terminal you chose, detached, with
`emacsclient -t -s drgnx …` inside it, and returns. Over SSH, or with no display, it never does: `drgnx` decides
that from the terminal you typed it in (as for picking the terminal above), not from the daemon, which usually runs
on the desktop.

## Waiting for you: drgnx as `$EDITOR`

`drgnx open --wait FILE…` opens the files like `drgnx FILE…` and returns only when you are done with them, as
`code --wait` does — so git, crontab and other tools can use drgnx as their editor:

```sh
export EDITOR='drgnx open --wait' VISUAL='drgnx open --wait'
```

You are done with a file when you press `C-x #` in it (Emacs' "done with this server buffer"; it offers to save
first) or kill its buffer. Closing its tab is not enough: the buffer stays open, so the command keeps waiting. With
no display (over ssh, on a console; never on a Mac) the file opens in the terminal you ran the command in, and waits
there. `--wait` takes files only; a folder, or no path, is an error (exit 2) before drgnx is asked.

## From drgnx's terminal

In drgnx's own terminal (New Terminal, [shell.md](shell.md)) the same commands reach *this* drgnx — the one the
terminal runs in — and open in the frame you are typing in:

```sh
drgnx .                  # this folder becomes the Explorer's first folder
drgnx 'My "File" café.py' # the file opens in an editor next to the terminal
git commit               # the message opens in drgnx; save it and press C-x # to finish the commit
```

No new window is ever made from there, not even when drgnx shows only a terminal frame, and no other drgnx is asked
or started. `drgnx open --wait FILE` (an `EDITOR` of your own) waits for `C-x #` in this drgnx too. `git commit` uses
the terminal's `GIT_EDITOR`, which points at this drgnx's server ([shell.md](shell.md#editor-git-and-drgnx-reach-the-emacs-hosting-the-terminal));
`cd` in the shell moves the terminal's directory with it, so `C-x C-f` in the terminal starts in the folder the shell
is in.

## On macOS: the drgnx app

On a Mac, drgnx is also an app: **drgnx** in `~/Applications` (the Applications folder in your home folder), so
Finder and Spotlight find it, and you can keep it in the Dock. The installer puts it there and opens it once
([install.md](install.md#macos)); onboarding's Daemon and Desktop step offers it when it is missing; `drgnx macos-app`
(re)installs it at any time and prints where.

- **Open it** (Finder, Spotlight, the Dock): the same as `drgnx open` — drgnx with your windows, started in the
  background if it is not running. The very first time, the Welcome opens ([onboarding.md](onboarding.md)).
- **Open folders and files with it:** drop them on its Dock icon, or choose drgnx in Finder's **Open With** (right-click
  a folder or a file). Open With offers drgnx for folders, text and code files, as VS Code does (not for images, PDFs and the like; Open With → **Other…** reaches any file). They
  open as `drgnx PATH` would open them — a folder in the Explorer, a file in an editor. drgnx is offered there, never
  made the default app for anything (set that yourself with Get Info → Open with → Change All, if you like).
- **Its windows are Emacs's.** drgnx runs in Emacs: while it runs, the Dock and ⌘Tab show it as **Emacs**, with the
  same icon — "Keep in Dock" on that icon pins Emacs, not drgnx. To keep drgnx in the Dock, drag
  `~/Applications/drgnx.app` there (Finder: Go → Home, then Applications) and open drgnx from it; or open it with
  Spotlight (⌘Space, type "drgnx") or Launchpad.
- **macOS may ask** whether Emacs may access your Documents, Desktop or Downloads folder the first time you open a
  project there: choose Allow (drgnx cannot open the files otherwise; System Settings → Privacy & Security → Files
  and Folders changes it later).

The app is a small AppleScript applet: Finder hands an app the files it opens as an Apple Event, not as arguments.
It runs `<checkout>/bin/drgnx open -- PATH…`, each path passed through `quoted form of`, so spaces, accents and
quotes stay one argument, with Homebrew's `/opt/homebrew/bin` and `/usr/local/bin` first on PATH (an app gets only
`/usr/bin:/bin:/usr/sbin:/sbin`; drgnx itself runs the Emacs the installer recorded). Its Info.plist names it `drgnx`
(`org.drgnx.app`), lists folders (`public.folder`) and text and source files (`public.text`, `public.source-code`,
`public.script`; JSON and YAML conform to `public.text`) as documents it can edit, as an alternate, and it carries Emacs's icon (from the
Emacs.app drgnx runs in, else `/Applications/Emacs.app`). `drgnx macos-app` builds it with `osacompile`, edits the
Info.plist with `plutil`, signs it again (ad hoc, `codesign --sign -`: the edits break osacompile's signature, and
Apple silicon runs no app with a broken one), replaces the drgnx.app that was there (no other app is touched), and
registers it with Launch Services (`lsregister -f`) so Finder and Spotlight know it at once. If the checkout moves,
run `drgnx macos-app` again. To remove it, delete `~/Applications/drgnx.app`. Code: `core/drgnx-macos.el`; tests:
`test/unit/macos-test.el`.

## Keep running or quit

When you close drgnx's last window — its close button, or Close Window (`C-q` in the VS Code profile, ⌘⇧W on a Mac;
the palette) — drgnx does one of two things, your choice:

- **Keep running in the background** (the default, like VS Code on a Mac): drgnx stays running without a window, so
  the next `drgnx PATH` or `drgnx open` is instant and brings your windows back. File → **Quit drgnx** (⌘Q on a Mac;
  in the palette too) stops it; it then stays stopped until you open drgnx again. It never starts at login: the first open
  starts it, and after a reboot or logout the next open starts it fresh with your windows restored. (The one
  exception: on Linux, if you enabled the systemd user service `drgnx`, it starts at login, as enabled services do.)
- **Quit when the last window closes:** closing the last window quits drgnx.

Quitting — Quit drgnx, or closing the last window in quit mode — first offers to save each file with changes, and
each New Untitled buffer (tab) you typed in (it asks for a file name); the `*scratch*` buffer is not offered. Press
Ctrl+G (`C-g`, Emacs' cancel), or keep one unsaved and then answer no to "quit and lose the changes?", and drgnx
stays running with everything open: nothing is lost. If terminals or other programs are still running, drgnx then
asks once whether to quit and stop them (no keeps everything running). A drgnx that is not a daemon has nothing to
keep running, so closing its last window always quits (asking the same way).

The keys close a window the same way. `C-x C-c` (Save Buffers Kill Terminal) and `C-x 5 0` (Delete Frame) in a
graphical window do what its close button does: another window is open, so only this one closes; it is the last one,
so drgnx keeps running or quits as chosen above. The keys are not rebound — the commands are remapped, so whatever
key runs them follows — and programmatic calls to those commands are left alone. A terminal frame (`drgnx -t`) and a
child frame (a popup) keep Emacs' behaviour. If you expect `C-x C-c` to leave a daemon running in quit mode, the
setting says otherwise; switch it to keep running.

`drgnx safe` is a debugging session: it never serves, so `drgnx PATH` does not reach it (and starts the normal
drgnx beside it). Close it like any Emacs.

Onboarding's Daemon and Desktop step asks it once ([onboarding.md](onboarding.md#the-steps)).
Change the choice with **Preferences: Keep drgnx Running in the Background** (palette, Options menu): it switches
between the two and says which one is on. The choice is kept in `~/.config/drgnx/session.eld` as
`(:keep-running t)` or `(:keep-running nil)` and read at every start. drgnx never asks it when a window closes.
Changing the choice edits only that key: comments and other keys you added stay as they are. If the file has a mistake,
drgnx keeps using the last good choice and says where the mistake is (`drgnx doctor` too); the toggle then refuses to
write, so your file is never replaced. Fix the file, or delete it, and toggle again. The file is described in
[the config reference](../reference/config.md).

## For CI and scripts

`drgnx open --check` starts drgnx's daemon if it is not running, asks its Emacs for its version, prints it, and
stops the daemon again if this command started it — no window, so it works without a display. It exits 0 when the
daemon answered, 1 with a message otherwise. `DRGNX_SERVER_NAME` names another server than `drgnx` (the tests use
their own, so they never reach your drgnx); a server named anything but `drgnx` never starts the systemd unit.

## How it works

`bin/drgnx` talks to the daemon with the `emacsclient` of drgnx's Emacs (beside it; in an Emacs.app,
`Contents/MacOS/bin/`), always with `-a false`, so it never starts some other Emacs by itself. It asks
`(drgnx-session-gui-frame-p)` whether a window is open, opens one with `emacsclient -c` only when none is, brings it
to the front with `(drgnx-session-raise)`, has it read the AI keys once per start (`drgnx-ai-load-keys-soon`: from
a timer, [ai.md](ai.md#keys)), sends files as file arguments and each folder as
`(drgnx-session-open-folder "…")`. Every call but `--wait`'s file call has `-n` (no waiting); with no display,
`--wait` is just `emacsclient -t -- FILE…`. In drgnx's terminal (`INSIDE_EMACS` names eat and `DRGNX_SERVER_NAME`
is set: the terminal's Emacs's socket) none of that runs: the files and folders go straight to that server, with
neither `-c` nor `-t`, so they open in its selected frame. The daemon starts detached (`setsid`, else `perl` on macOS) as
`emacs --bg-daemon=drgnx --init-directory=<checkout>/init`. The close button's `delete-frame` event and Close Window
run `drgnx-session-close-frame`, as do `C-x C-c` and `C-x 5 0` (`drgnx-session-kill-terminal`,
`drgnx-session-delete-frame`: remaps of the stock commands); Quit drgnx runs `drgnx-session-quit`. An `emacsclient -c` frame does not print Emacs's "When done with a buffer, type C-x 5 0"
(`server-client-instructions` is nil). On macOS drgnx
ignores `XDG_RUNTIME_DIR`: a shell exports it and an app started from Finder does not, which would put the server
socket in two places. The daemon puts it in Emacs' non-XDG directory, `emacs<uid>` under `$TMPDIR`, and `bin/drgnx`
runs `emacsclient` with `env -u XDG_RUNTIME_DIR`, so Terminal and Finder reach the same drgnx. Code: `core/drgnx-session.el`; tests:
`test/unit/session-test.el`, `test/unit/session-close-keys-test.el`, `test/unit/session-darwin-socket-test.el`,
`test/unit/bin-test.el` (fake `emacs`, `emacsclient` and `systemctl`, and one real
headless `open --check`), and the live scenario `test/live/drgnx-session-keep-or-quit-test.el` (a daemon session:
`bin/drgnx open` with a file and a folder with a space and an accent, then the last window closed in each mode).
From drgnx's terminal: `test/unit/terminal-bin-test.el` (the emacsclient calls inside and outside eat) and the live
`test/live/drgnx-terminal-test.el` (zsh in eat: `cd` followed, `drgnx` with odd names, `git commit`, the key split).
