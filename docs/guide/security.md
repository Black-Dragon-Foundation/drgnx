# Trusted folders and the "restricted" mark

A file you open can ask Emacs to do things: run a syntax checker that executes the file, rename symbols as it is
read, or make Emacs reach out to another machine. drgnx lets files from folders you trust do all of that, and holds
back what is risky in files from any other folder — like VS Code's Workspace Trust, but without a dialog. Nothing
here ever asks you a question; you trust a folder when you choose to.

## What is trusted

- drgnx's own folders: its checkout, its config dir (`~/.config/drgnx/`) and its packages dir, and the Lisp
  files Emacs itself came with.
- The folders you trusted with **Trust This Folder**. They are kept in `~/.local/state/drgnx/trusted-folders.eld`,
  so they stay trusted in the next session. A file drgnx cannot use trusts none of its folders: one that cannot be
  read, one with a mistake (`:folders` must be a list of folder names), and one a newer drgnx wrote. A message
  names the file and the reason, once each time the file changes. Trust This Folder copies a file it cannot use
  aside (`trusted-folders.eld.bak-…`, the newest three kept) before it writes a new one, and refuses to change a
  newer drgnx's file. Two Emacs sessions trusting folders at once both keep theirs. A folder in the file that
  Trust This Folder would refuse (below), and a remote folder, are not trusted; reading the file never contacts
  another machine.
- Anything you put in Emacs's own `trusted-content` option. drgnx only adds to it; `:all` trusts everything.

Every other folder is untrusted, including the projects you open, until you trust them.

## The "restricted" mark

A file from an untrusted folder shows **restricted** in the mode line, in a quiet colour from your theme. Click it
to trust the file's folder: its project's root when the file is in a project (a git repository, for example), else
the file's own folder. The mark is not shown for remote files, and Trust This Folder refuses a remote folder.

A folder that holds far more than one project is never trusted: `/`, your home folder, the temp folder, `/tmp/`,
`/var/tmp/` and `/dev/shm/`, or a folder above any of them. A file lying directly in one of them has to move into a
project folder first.

Or use the palette: **File: Trust This Folder**, and **File: Untrust This Folder** to take it back (drgnx's own
folders stay trusted). Untrusting always takes effect at once. When `trusted-folders.eld` cannot be changed (it
cannot be used, or a newer drgnx wrote it), the message says the folder is untrusted for this session only, and
why. Trusting a folder takes effect at once in its open files: their checkers run and their
shorthands come back, without reopening them.

## What is held back in an untrusted folder

- **Flymake checkers that run the file.** Outside trusted folders Flymake runs only checkers marked safe.
  Language-server diagnostics (eglot) count as safe — Emacs runs nothing from the file, it asks the server you
  installed — so they keep working everywhere. Another checker is switched off for that file, with one message saying
  why. Emacs 31.2 does the same; drgnx adds the check on Emacs versions that lack it.
- **Symbol shorthands** (`read-symbol-shorthands` in a file's or folder's local variables). They are dropped when
  the file opens, and given back when you trust the folder.

## What is guarded everywhere

- **Crafted remote names.** A file name with a control character anywhere in it, or whose `user@host` part
  holds a shell character (`; & | ! , < > ( ) { }`, quotes, a backquote, a space…) or has a user or host starting
  with `-`, is treated as a local name: TRAMP never connects for it. Ordinary remote names — `/ssh:host:/path`,
  `/ssh:user@host#2222:/x`, `/ssh:a@b|sudo:root@b:/x`, `/-:host:/x`, `/podman:name:/`, `$USER` in a name — work
  as before. drgnx appends its pattern to
  `tramp-ignored-file-name-regexp`; if you set that option yourself, add to it rather than replacing it.
- **Remote names in compile and grep output.** In a local compilation or grep buffer, a remote file name or an
  "Entering directory" line naming a remote directory is read as a local name (quoted with `/:`). Output text never
  makes Emacs connect anywhere, and clicking such an error opens nothing remote.
- **Links in the Work tab and agent edits.** A Work row, graph box, commit or worktree that names a remote file opens
  nothing and says so. When an agent proposes a change to a remote name from a local session, the review does not
  open and the agent is told the change was rejected; in a session started in a remote folder, its files review as
  usual.
- **Links in AI answers.** The Sources links of an Ask the Codebase answer open a remote file only when you asked
  about a remote folder. A remote name that shows up in a local folder's answer is not opened; a message says so.
- **Host names in text.** `ffap` (find file at point) never pings a host name it finds in text
  (`ffap-machine-p-known` is set to `reject` while you leave it at its default). Emacs's own defaults already keep
  directory-local variables and auto-revert away from remote files; drgnx leaves them as they are.
- **Auto-saving remote files.** If you turn on `auto-save-visited-mode`, it saves local files only:
  `remote-file-name-inhibit-auto-save-visited` is set to t while you leave it at its default (nil).

## When something you trust is held back

A checker that stays silent, or a shorthand that does not apply: look for **restricted** in the mode line, and trust
the folder if you trust its files. A remote name refused by TRAMP because of an unusual user name: open it with a
plain `user@host` (an ssh config `Host` alias works for anything ssh accepts).

## Checking it

`drgnx doctor` has a `security` line. It names the Emacs security issues that apply to your version (CVE numbers)
and says OK while all of the guards above are on, or WARN naming the ones that are off. If it warns, restart drgnx:
its startup turns the guards on.
