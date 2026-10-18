# Remote editing

Edit on another machine, or in a podman container, from this drgnx (module `tools/remote`), through Emacs's TRAMP.
You work as on a local folder: the Explorer, tabs, saving, search, the terminal and language servers all follow the
folder to the host.

| Command | What it does |
|---|---|
| Remote: Open Remote… | Pick an ssh host, a podman container or another host, then a folder on it. The folder becomes the Explorer's first folder. |
| Remote: Reconnect | Bring a lost connection back. Buffers, their unsaved changes, point and language servers carry on. |

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
shows as lost within a moment of Emacs noticing. A click opens a short list: Reconnect, or Open Remote….

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
you open, expand or refresh it (until then it shows the listing it has, or `(not listed — Refresh)`). The change gutter
(diff-hl) is off for remote files, and the Explorer's Git letters, inline blame, the Outline and sticky scroll skip them. Nothing remote asks a question from an automatic path; every ssh question comes from a command
you ran. As a second guard, while the module is on, TRAMP's login, password, yes/no, one-time-code and confirm questions fail
with an error unless the code asking is part of a command of yours (a key you press, `M-x`, a click) or Open Remote…
or Reconnect asked for it. A timer, a process filter or a sentinel is never part of your command, even when it fires
while the command waits: its login gets an error message, never a hidden question.

## Limits

- Eglot's own hook, which runs when a buffer's major mode changes, asks the project of a remote buffer and so reaches the
  host (about forty TRAMP calls). It runs for the file you visit; drgnx does not patch eglot.

- Shell integration in a remote terminal (eat or zsh integration over TRAMP) is not built.
- Remote folders are not restored at the next start (see the Explorer's rules in [workbench.md](workbench.md)); open
  them again with Open Remote….
- Language servers are found on the host's `PATH` (what TRAMP sees, see `tramp-remote-path`); a server installed
  elsewhere needs that variable extended.
