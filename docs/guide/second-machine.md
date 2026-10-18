# drgnx on a second machine

Your drgnx settings are one directory, `~/.config/drgnx` (`$DRGNX_CONFIG_DIR`). The whole of it travels: copy it,
or keep it as a git repository and clone it on the next machine. Nothing in it belongs to one machine, and no
secret is in it in plain text. Everything that is this machine's lives in drgnx's data, state and cache dirs, which
never travel.

## What travels and what stays

| | Files |
| --- | --- |
| Travels (the config dir) | `keys.eld`, `modules.eld`, `packages.eld`, `drgnx.lock.eld`, `ai.eld`, `agents.eld`, `projects.eld`, `session.eld`, `config.el`; `secrets.age` (your provider keys, encrypted: ciphertext only) |
| Stays on this machine | the data dir `~/.local/share/drgnx` (`$DRGNX_DATA_DIR`): `emacs` (the Emacs the installer recorded), `systemd/drgnx.service` and `applications/drgnx.desktop` (written by onboarding's Daemon and Desktop step), the packages (`elpa/`, rebuilt from the lock on the next machine), generations, the work tracker's `work.db`; the state dir `~/.local/state/drgnx` (`workbench.eld` fits this machine's monitors); the cache dir `~/.cache/drgnx` (downloaded packages). The search index is rebuilt where it is needed. |
| Not drgnx's | your dotfiles, `~/org`, your project repositories, agent CLI logins (`claude` logs in again on each machine; drgnx never reads its tokens) |

Your provider keys stay in your Keychain or keyring ([ai.md](ai.md#keys)); they never travel in plain text.

## Paths under your home

A path under your home directory is written `~/…` in the files that travel — the project roots in `projects.eld`,
the rc line ([shell.md](shell.md)) — and read back as this machine's home. So `~/work/alpha` on a machine whose home
is `/home/ana` is `~/work/alpha` on a Mac whose home is `/Users/ana` too. A home behind a symlink (Fedora
Silverblue's `/home`, which is `/var/home`) counts as home in both spellings. A path outside your home stays as
it is.

A project root that is not on the new machine is shown as missing; drgnx never clones it for you.

## Machine-local files from older installs

Older installs wrote the `emacs` record and onboarding's `systemd/` and `applications/` into the config dir. They
are moved to the data dir: copied, compared, and only then deleted from the config dir. When the data dir has an
identical copy already, the config dir's is deleted; when it has a different one, neither is touched and the
doctor keeps saying so. `drgnx bootstrap --step config` does the move, or do it yourself:

```sh
mkdir -p ~/.local/share/drgnx && mv ~/.config/drgnx/emacs ~/.config/drgnx/systemd ~/.config/drgnx/applications ~/.local/share/drgnx/
```

Until then `drgnx` still reads the old `emacs` record when the data dir has none.

## The doctor's check

`drgnx doctor`'s `portable-config` line says whether the config dir can travel as it is:

- **WARN, a key in plain text in FILE:** a file of the config dir holds something that looks like a secret — an
  OpenRouter, Anthropic or OpenAI-style key, a GitHub token, an AWS access key, a private key, an age identity — or
  is named like one (`.env`, `secrets.env`, `*.pem`, `*.key`). The doctor names the file, never the key. Move the
  key to your keyring ([ai.md](ai.md#keys)) and take it out of the file. `secrets.age`, the repository's own
  `.git/` and symlinks are not read.
- **WARN, machine-local files in the config dir:** the older install's files above; move them.
- **INFO, not cloned on this machine:** `projects.eld` roots that are not here. Clone them to work on them here, or
  leave them.
- **OK:** the config dir can travel as it is.
