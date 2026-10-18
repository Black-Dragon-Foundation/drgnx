# Remote editing

Edit on another machine, or in a podman container, from this drgnx (module `tools/remote`), through Emacs's TRAMP.
You work as on a local folder: the Explorer, tabs, saving, search, the terminal and language servers all follow the
folder to the host.

| Command | What it does |
|---|---|
| Remote: Open Remote… | Pick an ssh host, a podman container or another host, then a folder on it. The folder becomes the Explorer's first folder. |
| Remote: Reconnect | Bring a lost connection back. Buffers, their unsaved changes and point stay; the host's language servers are stopped and started again. |

Keys: in the Vim profile `SPC r o` and `SPC r r`. In the VS Code and Emacs profiles the commands are in the palette
(and the segment on the status line, below); `C-x C-f /ssh:HOST:/path` works as it always did.

## Open Remote…

The list has `ssh: HOST` for every `Host` name in `~/.ssh/config` (and in the files it `Include`s, one level deep,
globs allowed; names with `*`, `?` or `!` are patterns and left out), `podman: NAME` for each running container
(`podman ps`, given five seconds), and **Other host…** for anything else: type `user@host`, or a whole TRAMP name such
as `/ssh:host|sudo:host:/etc/`. Then you pick the folder, starting from `/ssh:HOST:~/` or `/podman:NAME:/`, with the
usual completion.

ssh asks its questions here (a host key to accept, a password or passphrase), in the minibuffer, as it does for
`C-x C-f /ssh:HOST:`. Your `~/.ssh/config` applies: `ProxyJump`, `User`, `ControlMaster` and the rest.

## The status-line segment

While a remote folder is in the Explorer, or the buffer you are in is remote, the status line shows `⇄ HOST` (`<> HOST`
on terminal frames that cannot draw the arrows):

- **connected**: in the theme's `success` colour (face `drgnx-remote-connected`);
- **lost**: in its `warning` colour (face `drgnx-remote-lost`).

It only reads whether the connection's process is alive, so it never touches the network, and a connection that dropped
shows as lost within a moment of Emacs noticing. A connection opened again some other way (a typed ssh path) shows as
connected within two seconds; after Open Remote… or Reconnect, at once. The segment's text is made once per host and
state and kept, so redrawing the status line costs nothing. A click opens a short list: Reconnect, or Open Remote….

## Reconnect

Reconnect works on the remote of the buffer you are in, else on the Explorer's (it asks when the Explorer has several).
It stops that host's language servers (their buffers stay open), closes the connection, opens it again by reading the
folder, looks for the servers again and starts a new server in the code buffers of that host (the old ones were
stopped, so they restart rather than carry on). Other processes on the host, such as a shell you left running, are not
touched. It asks for a password again only if ssh needs one. Nothing is reconnected by itself: when a connection
drops, you decide when to try again.

## Language servers on the remote side

Language servers run on the host, next to the code (eglot over TRAMP). Open Remote… and Reconnect look, once, for
every server eglot knows on the host's `PATH` and remember the answer per connection. A code file of that host then:

- starts its server when it was found and the connection is up, but only while a command of yours runs: Open Remote…
  (for the code files already open on that host), Reconnect, or the command that visits the file (`C-x C-f`, a click
  in the Explorer). A file that a timer, a background process or a restored session opens starts nothing, even when
  it fires while one of your commands waits, and eglot's own start after the next keystroke is not used. One server
  per project: later files of the project join the running one;
- says once per host and language when it was not found: `No language server for python-mode on HOST: install pylsp there`;
- does nothing when the connection was never opened with Open Remote… (a typed ssh path, say), as before.

The probe is one shell call on the host for all the servers eglot knows. Install a server on the host, then Reconnect
to look again. A server whose connection drops is not restarted by eglot (eglot would log in again on its own, so
`eglot-reconnect` is refused for a remote server unless you run it yourself); Reconnect starts it.

## What is never automatic

TRAMP stays on for what you start: Open Remote…, Reconnect and ssh paths you type or open. Nothing runs by itself on a
remote name: no timer, hook or background check, no file watching, no Git or diff decorations, no Flymake, no link or
compile-output path, no semantic-search indexing of a remote folder, and the Explorer lists a remote folder only when
you open, expand or refresh it, or create, rename, delete or paste in it (until then it shows the listing it has, or
`(not listed — Refresh)`). Folders set from outside a command (`drgnx open DIR` from a shell, which arrives through
the Emacs server) do not list a remote folder either, and a folder whose host cannot be reached keeps the listing it
had. The one intended exception is Find in the Explorer: you are typing in the minibuffer and its
live filter runs from an idle timer, as part of your command. The change gutter (diff-hl) is off for remote files; the
Explorer's Git letters, inline blame and the Outline skip them, and sticky scroll works from the buffer's text alone.
Nothing remote asks a question from an automatic path; every ssh question comes from a command you ran. As a second
guard, while the module is on, TRAMP's login, password, yes/no, one-time-code and confirm questions fail with an error
unless the code asking is part of a command of yours (a key you press, `M-x`, a click) or Open Remote… or Reconnect
asked for it. A timer, a process filter or a sentinel is never part of your command, even when it fires
while the command waits: its login gets an error message, never a hidden question.

Auto-save files of remote buffers go to a private folder (mode 0700) in drgnx's state directory
(`~/.local/state/drgnx/tramp-auto-save/`, the module sets `tramp-auto-save-directory` unless you set it yourself). So
TRAMP never asks "Autosave file on local temporary directory, do you want to continue?" for a file owned by root (every
file of a container that runs as root), from a visit, a daemon or a sentinel alike.

## Limits

- Eglot's own hook, which runs when a buffer's major mode changes, asks the project of the buffer and so would reach the
  host (about forty TRAMP calls). For a remote buffer drgnx lets it run only inside a command of yours (the visit of
  the file), or when a server you started has answered (then the open files of that server's project are attached).
  A remote buffer whose mode changes outside a command, from a timer or a revert, say, stays unattached to its language
  server until you reopen it, revert it in a command, or run Reconnect. Remote files are never restored at the next
  start, so nothing is waiting to be attached then.
- Shell integration in a remote terminal (eat or zsh integration over TRAMP) is not built.
- Remote folders are not restored at the next start (see the Explorer's rules in [workbench.md](workbench.md)); open
  them again with Open Remote….
- Language servers are found on the host's `PATH` (what TRAMP sees, see `tramp-remote-path`); a server installed
  elsewhere needs that variable extended.

## Tests

The GUI test `test/ui/editor-m11c2-test.el` (`drgnx test --ui`) starts a podman container, opens it with Open Remote…,
and shows the Explorer on it and the segment connected; it kills the connection (the segment shows it lost) and
reconnects (connected, the buffer and its unsaved change kept), with screenshots. Without podman that part is
skipped. The perf workload `remote-typing` types in a local file while a dead remote root is listed in the Explorer:
p95 under 16 ms and nothing sent to the remote ([perf.md](../develop/perf.md)).
