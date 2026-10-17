# Opening drgnx: `drgnx .`, `drgnx open`, keep running or quit

drgnx opens like VS Code's `code .`: give it a folder or a file and it shows up in drgnx's window. There is only ever
one drgnx: a second `drgnx PATH` opens the path in the drgnx already running instead of starting another Emacs.

```sh
drgnx .                      # this folder, in the Explorer, in front
drgnx some/dir               # that folder
drgnx file.py "My Project"   # a file in an editor and a folder; quote names with spaces
drgnx open                   # drgnx with the windows as you left them
drgnx open -- -odd-name.txt  # anything after -- is a path, even when it starts with -
```

An argument is a path when it is `.` or `..`, contains a `/`, or exists; any other word that is not a drgnx command
is an error (`drgnx frobnicate` says so). A file or folder named like a command (`build`, `test`, …) opens with
`drgnx ./build` or `drgnx open build`. Paths are taken from the directory you are in and passed on as they are, so
spaces, accents (`café.py`) and iCloud folders work. A file that does not exist yet opens as a new, empty file (as
`code new.py` does).

What happens:

- **drgnx is not running:** it starts in the background (an Emacs daemon named `drgnx`, with the Emacs drgnx was
  installed with — see [install.md](install.md)), and the paths open as soon as it answers (it is given 10 s; its
  startup messages go to `~/.local/state/drgnx/daemon.log`). On Linux, when the systemd user unit `drgnx` is installed
  and enabled ([packages.md](packages.md#running-drgnx-as-a-daemon)), drgnx starts that unit instead.
- **No window is open:** a window opens, with the layout you left — groups, tabs, docks, Explorer folders
  ([workbench.md](workbench.md#the-layout-survives-a-restart)) — and the paths in front of it.
- **A window is open:** the paths open there and the window comes to the front.

A **folder** becomes the Explorer's first folder (the others stay) with the sidebar shown; it does not open as a
directory listing. A **file** opens in the editor. drgnx started by hand as a normal Emacs (not a daemon) answers
`drgnx PATH` too, as long as no other drgnx does.

## Keep running or quit

When you close drgnx's last window — its close button, or Close Window (`C-q` in the VS Code profile; the palette) —
drgnx does one of two things, your choice:

- **Keep running in the background** (the default, like VS Code on a Mac): drgnx stays running without a window, so
  the next `drgnx PATH` or `drgnx open` is instant and brings your windows back. File → **Quit drgnx** (in the
  palette too) stops it; it then stays stopped until you open drgnx again. It never starts at login: the first open
  starts it, and after a reboot or logout the next open starts it fresh with your windows restored.
- **Quit when the last window closes:** closing the last window quits drgnx.

Quitting — Quit drgnx, or closing the last window in quit mode — first offers to save each file with changes. Press
`C-g`, or keep a file unsaved and then answer no to "quit and lose the changes?", and drgnx stays running with
everything open: nothing is lost. A drgnx that is not a daemon has nothing to keep running, so closing its last
window always quits (asking the same way).

Change the choice with **Preferences: Keep drgnx Running in the Background** (palette, Options menu): it switches
between the two and says which one is on. The choice is kept in `~/.config/drgnx/session.eld` as
`(:keep-running t)` or `(:keep-running nil)` and read at every start. drgnx never asks it when a window closes.

## For CI and scripts

`drgnx open --check` starts drgnx's daemon if it is not running, asks its Emacs for its version, prints it, and
stops the daemon again if this command started it — no window, so it works without a display. It exits 0 when the
daemon answered, 1 with a message otherwise. `DRGNX_SERVER_NAME` names another server than `drgnx` (the tests use
their own, so they never reach your drgnx); a server named anything but `drgnx` never starts the systemd unit.

## How it works

`bin/drgnx` talks to the daemon with the `emacsclient` of drgnx's Emacs (beside it; in an Emacs.app,
`Contents/MacOS/bin/`), always with `-a false`, so it never starts some other Emacs by itself. It asks
`(drgnx-session-gui-frame-p)` whether a window is open, opens one with `emacsclient -c` only when none is, brings it
to the front with `(drgnx-session-raise)`, sends files as file arguments and each folder as
`(drgnx-session-open-folder "…")`. The daemon starts detached (`setsid`, else `perl` on macOS) as
`emacs --bg-daemon=drgnx --init-directory=<checkout>/init`. The close button's `delete-frame` event and Close Window
run `drgnx-session-close-frame`; Quit drgnx runs `drgnx-session-quit`. Code: `core/drgnx-session.el`; tests:
`test/unit/session-test.el`, `test/unit/bin-test.el` (fake `emacs`, `emacsclient` and `systemctl`, and one real
headless `open --check`), and the live scenario `test/live/drgnx-session-keep-or-quit-test.el` (a daemon session:
`bin/drgnx open` with a file and a folder with a space and an accent, then the last window closed in each mode).
