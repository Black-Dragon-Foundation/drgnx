# Trusted folders and the "restricted" mark

A file you open can ask Emacs to do things: run a syntax checker that executes the file, rename symbols as it is
read, or make Emacs reach out to another machine. drgnx lets files from folders you trust do all of that, and holds
back what is risky in files from any other folder — like VS Code's Workspace Trust, but without a dialog. Nothing
here ever asks you a question; you trust a folder when you choose to.

## What is trusted

- drgnx's own folders: its checkout, its config dir (`~/.config/drgnx/`) and its packages dir.
- The folders you trusted with **Trust This Folder**. They are kept in `~/.local/state/drgnx/trusted-folders.eld`,
  so they stay trusted in the next session.
- Anything you put in Emacs's own `trusted-content` option. drgnx only adds to it; `:all` trusts everything.

Every other folder is untrusted, including the projects you open, until you trust them.

## The "restricted" mark

A file from an untrusted folder shows **restricted** in the mode line, in a quiet colour from your theme. Click it
to trust the file's folder: its project's root when the file is in a project (a git repository, for example), else
the file's own folder. The mark is not shown for remote files.

Or use the palette: **File: Trust This Folder**, and **File: Untrust This Folder** to take it back (drgnx's own
folders stay trusted). Trusting a folder takes effect at once in its open files: their checkers run and their
shorthands come back, without reopening them.

## What is held back in an untrusted folder

- **Flymake checkers that run the file.** Outside trusted folders Flymake runs only checkers marked safe.
  Language-server diagnostics (eglot) count as safe — Emacs runs nothing from the file, it asks the server you
  installed — so they keep working everywhere. Another checker is switched off for that file, with one message saying why. Emacs 31.2
  does the same; drgnx adds the check on Emacs versions that lack it.
- **Symbol shorthands** (`read-symbol-shorthands` in a file's or folder's local variables). They are dropped when
  the file opens, and given back when you trust the folder.

## What is guarded everywhere

- **Crafted remote names.** A file name whose `user@host` part holds a control character or a shell character
  (`; & | ! , < > ( ) { }`, quotes, a backquote, a space…), or starts with `-`, is treated as a local name: TRAMP
  never connects for it. Ordinary remote names — `/ssh:host:/path`, `/ssh:user@host#2222:/x`,
  `/ssh:a@b|sudo:root@b:/x`, `/podman:name:/`, `$USER` in a name — work as before. drgnx appends its pattern to
  `tramp-ignored-file-name-regexp`; if you set that option yourself, add to it rather than replacing it.
- **Remote names in compile and grep output.** In a local compilation or grep buffer, a remote file name or an
  "Entering directory" line naming a remote directory is read as a local name (quoted with `/:`). Output text never
  makes Emacs connect anywhere, and clicking such an error opens nothing remote.

## When something you trust is held back

A checker that stays silent, or a shorthand that does not apply: look for **restricted** in the mode line, and trust
the folder if you trust its files. A remote name refused by TRAMP because of an unusual user name: open it with a
plain `user@host` (an ssh config `Host` alias works for anything ssh accepts).
