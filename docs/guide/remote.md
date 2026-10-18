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
folder, looks for the servers again and starts them in the code buffers of that host. It asks for a password again
only if ssh needs one. Nothing is reconnected by itself: when a connection drops, you decide when to try again.

## Language servers on the remote side

Language servers run on the host, next to the code (eglot over TRAMP). Open Remote… and Reconnect look, once, for
every server eglot knows on the host's `PATH` and remember the answer per connection. A code file of that host then:

- starts its server when it was found (and the connection is up);
- says once per host and language when it was not: `No language server for python-mode on HOST: install pylsp there`;
- does nothing when the connection was never opened with Open Remote… (a typed ssh path, say), as before.

Install a server on the host, then Reconnect to look again.

## What is never automatic

TRAMP stays on for what you start: Open Remote…, Reconnect and ssh paths you type or open. Nothing runs by itself on a
remote name: no timer, hook or background check, no file watching, no Git or diff decorations, no Flymake, no link or
compile-output path, and the Explorer lists a remote folder only when you open or refresh it. Nothing remote asks a
question from an automatic path; every ssh question comes from a command you ran.

## Limits

- Shell integration in a remote terminal (eat or zsh integration over TRAMP) is not built.
- Remote folders are not restored at the next start (see the Explorer's rules in [workbench.md](workbench.md)); open
  them again with Open Remote….
- Language servers are found on the host's `PATH` (what TRAMP sees, see `tramp-remote-path`); a server installed
  elsewhere needs that variable extended.
