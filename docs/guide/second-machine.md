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

Your provider keys stay in your Keychain or keyring ([ai.md](ai.md#keys)); they never travel in plain text. To
carry them, encrypted, see [secrets.age](#your-provider-keys-secretsage) below.

## Paths under your home

A path under your home directory is written `~/…` in the files that travel — the project roots in `projects.eld`,
the rc line ([shell.md](shell.md)) — and read back as this machine's home. So `~/work/alpha` on a machine whose home
is `/home/ana` is `~/work/alpha` on a Mac whose home is `/Users/ana` too. A home behind a symlink (Fedora
Silverblue's `/home`, which is `/var/home`) counts as home in both spellings. A path outside your home stays as
it is, except a symlink that points into your home: it is written as the place it points to (`/opt/proj` linked to
`~/ws/proj` is written `~/ws/proj`).

A project root that is not on the new machine is shown as missing; drgnx never clones it for you.

## Machine-local files from older installs

Older installs wrote the `emacs` record and onboarding's `systemd/` and `applications/` into the config dir. They
are moved to the data dir: copied, compared, and only then deleted from the config dir. When the data dir has an
identical copy already, the config dir's is deleted; when it has a different one, neither is touched and the
doctor keeps saying so. `drgnx bootstrap --step config` does the move, or do it yourself; this moves each item only
when the data dir has none, so it never replaces the data dir's (newer) copy:

```sh
c="${DRGNX_CONFIG_DIR:-$HOME/.config/drgnx}"; d="${DRGNX_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/drgnx}"
mkdir -p "$d"
for f in emacs systemd applications; do
  if [ -e "$c/$f" ] && [ ! -e "$d/$f" ]; then mv "$c/$f" "$d/"; fi
done
```

Anything still in the config dir afterwards has its own copy in the data dir, which drgnx uses: compare them (`diff
-r "$c/emacs" "$d/emacs"`, and the same for `systemd` and `applications`), then delete the config dir's. Until then
`drgnx` still reads the old `emacs` record when the data dir has none.

## The doctor's check

`drgnx doctor`'s `portable-config` line says whether the config dir can travel as it is:

- **WARN, a key in plain text in FILE:** a file of the config dir holds something that looks like a secret — an
  OpenRouter or Anthropic key, an OpenAI key (`sk-…`, `sk-proj-…`, `sk-svcacct-…`, `sk-admin-…`), a GitHub token
  (`ghp_…`, `github_pat_…`), an AWS access key, a private key, an age identity — or is named like one (`.env`,
  `secrets.env`, `*.pem`, `*.key`). The doctor names the file, never the key. Move the key to your keyring
  ([ai.md](ai.md#keys)) and take it out of the file. `secrets.age`, the repository's own `.git/` and symlinks are
  not read. The check finds keys in plain text only: a key encoded (base64, say) or split across lines is not found.
- **WARN, machine-local files in the config dir:** the older install's files above; move them. For an item the data
  dir has too, the fix says so: compare the two, then delete the config dir's.
- **INFO, could not check N files:** files or directories of the config dir that could not be read (their
  permissions), or the whole scan failed; the doctor never says OK then. Make them readable and run it again.
- **INFO, not cloned on this machine:** `projects.eld` roots that are not here. Clone them to work on them here, or
  leave them.
- **OK:** the config dir can travel as it is.

## Your provider keys: secrets.age

Your provider keys live in this machine's Keychain or keyring ([ai.md](ai.md#keys)), never in a drgnx file in
plain text. To have them on another machine, carry them in one encrypted file, `secrets.age`, in your config dir:

```sh
drgnx secrets export            # here: age asks for a passphrase, twice
# copy the config dir (or push and clone it), then on the other machine:
drgnx secrets import            # there: the passphrase again; each key goes into that machine's keyring
                                # (a different key already there is kept: --replace overwrites it)
drgnx secrets ls                # the hosts secrets.age holds keys for (never the keys)
```

In the drgnx app the palette has **Portability: Export Keys** and **Portability: Import Keys**: each opens a
terminal running the same command, with a header saying what to type. drgnx itself never runs age: age asks for
the passphrase in that terminal.

**What `secrets.age` holds:** for each provider that takes a key (it has a `:key-env`: OpenRouter, Anthropic, your
own in `ai.eld`) and whose key is in your keyring, the provider's id, its host and the key. A key you only set in
the environment (`OPENROUTER_API_KEY`) is not in the keyring and is not exported; with no key in the keyring
`export` says so and writes nothing. The file is age ciphertext: it can travel with the config dir, through git
too.

**Export** asks before it replaces an existing `secrets.age`, and replaces it only when age succeeded (age writes
`secrets.age.new`, which then takes its place; on any failure the old file stays and the new one is deleted).

**Import** reads the file, then for each key: `stored` (it went into the keyring), `same` (the keyring already
holds this key), `differs` (the keyring holds a *different* key for that host — perhaps you rotated it after the
export — and keeps it; exit 1), `unknown` (no provider with that id and host is known here — add it to `ai.eld`,
then import again; nothing is stored for it) or `failed` (the keyring refused it, with the reason; exit 1). Only the
hosts are printed, never a key. `drgnx secrets import --replace` overwrites the keys that differ. A wrong
passphrase, a damaged file, a file from a different drgnx version, or a bundle with a host that is not a host name
or a key with spaces or control characters stores nothing (exit 1); the error says what is wrong without showing it.

**Passphrase or age keys:** without options age asks for a passphrase, on the terminal, so `export`, `import` and
`ls` need one (run without a terminal, they stop with exit 3: "needs a terminal"). With age keys no terminal is
needed: `drgnx secrets export --recipient age1…` (once per recipient: each machine's public key, from
`age-keygen`) and `drgnx secrets import --identity FILE` (that machine's identity file). Keep identity files out of
the config dir: the doctor warns about one there. drgnx also warns when the identity file can be read by other
users (`chmod 600 FILE`). Replacing an existing `secrets.age` asks first, so it needs a terminal even with
`--recipient`.

**No keyring:** a machine without a Keychain or a Secret Service (an SSH login, a container, WSL) has nowhere to
put the keys: `import` says "no keyring here" and changes nothing. Set the provider's environment variable on that
machine instead ([ai.md](ai.md#keys)).

**age:** install it from your package manager (`brew install age`, `sudo dnf install -y age`, `sudo apt-get
install -y age`, `sudo pacman -S --noconfirm age`); without it `drgnx secrets` names the line for this machine and
stops (exit 3).

**Where the plaintext goes:** nowhere but pipes. On export drgnx prints the keys into age's standard input
(`drgnx … | age -e -p -o secrets.age.new`); on import age's output goes straight into drgnx (`age -d secrets.age |
drgnx …`). Nothing writes them to a file, a command line, a log or `*Messages*`, and drgnx overwrites the strings
that held them when it is done. While they are in memory (Emacs's, and the pipe's in the kernel), the system may
swap them out like any memory. When the Export Keys or Import Keys terminal ends, drgnx clears Emacs's record of
recent keys (`C-h l`), where the passphrase you typed would otherwise stay. These two commands are the only batch
commands that open your Keychain or keyring, and only when you run them on a terminal or with `--recipient` or
`--identity`.
