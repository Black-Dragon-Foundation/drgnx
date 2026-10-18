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

## Making your config portable

Onboarding's **Portability** step (Help → Welcome, or `drgnx onboard --step portability`) does this for you, and
asks before it changes anything:

1. **Where your config comes from.** A git repository of its own (the config dir is the top of the work tree), with
   its remote; chezmoi, when `chezmoi source-path ~/.config/drgnx` says it manages it; the work tree of another
   repository (a dotfiles repository holding `~/.config`, say) — then it travels with that one, and the step names it
   and offers no repository of its own; or none. A remote is shown without any user name, password or query.
2. **A git repository, when you say yes.** When the config dir is neither, the step first moves the machine-local
   files above to the data dir. If a file holds a key in plain text, it stops there: the step warns, names the
   file and commits nothing; move the key to your keyring ([ai.md](ai.md#keys)) and run the step again. Otherwise
   it asks "Make ~/.config/drgnx a git repository (you push it to a remote of your choice)?" — yes runs `git init`,
   `git add` (never the machine-local items) and one commit, "drgnx configuration" — without your git hooks,
   templates or commit signing, and each git command stopped after 30 seconds. That is all: drgnx never adds a
   remote, never pushes and never commits again. Add a remote and push yourself:

   ```sh
   git -C ~/.config/drgnx remote add origin https://example.org/you/drgnx-config.git
   git -C ~/.config/drgnx push -u origin HEAD
   ```

   Without a git identity (`user.name`, `user.email`) the commit cannot be made: the repository stays initialised
   and the step says how to set the identity and commit.
3. **chezmoi.** With chezmoi installed and the config dir not in it, the step says how to add it: `chezmoi add
   ~/.config/drgnx`. Add `secrets.age` as a plain file, not with `--encrypt`: it is encrypted already. drgnx runs
   nothing of chezmoi's here but `chezmoi source-path`.
4. **Your keys.** In drgnx's window, when your keyring holds a provider key, it asks "Export your provider keys to
   secrets.age, encrypted with a passphrase?" — yes installs age if it is missing (asked, like every install) and
   opens the Export Keys terminal ([below](#your-provider-keys-secretsage)). With a `secrets.age` there already it
   does not ask (Portability: Export Keys replaces it). Commit `secrets.age` with the rest
   yourself. `drgnx onboard` on a terminal never opens the keyring here; it names `drgnx secrets export`.
5. **The next machine's command:**

   ```sh
   curl -fsSL https://raw.githubusercontent.com/Black-Dragon-Foundation/drgnx/main/install.sh | bash -s -- --config URL
   ```

   with your remote as URL (`--chezmoi URL` when chezmoi manages the config). install.sh takes an https URL or a
   local path, so with no remote, or an ssh one, the command says `YOUR-REPO-URL`; a user name or password in the
   remote is never shown. See [install.md](install.md#on-a-second-machine) and [One command](#one-command-drgnx-bootstrap).

With `--non-interactive` the step only reports where the config comes from and the command: it moves, makes and
exports nothing.

## One command: drgnx bootstrap

On the new machine, `curl … install.sh | bash -s -- --config URL` installs drgnx and hands over to `drgnx bootstrap
--config URL` ([install.md](install.md#on-a-second-machine)). On a machine that has drgnx already, run that yourself:

```sh
drgnx bootstrap --config https://example.org/you/drgnx-config.git
drgnx bootstrap --config https://example.org/you/drgnx-config.git --dry-run   # what each step would do; changes nothing
drgnx bootstrap --step shell                                                  # one step (--step repeats)
```

It runs these steps in order and prints one line for each: `ok` (nothing to do), `changed`, `skipped` (with the
command that does it) or `failed` (with the problem). It exits 1 when a step failed, 2 for a wrong option. A second
run changes nothing. A failed `preflight`, `config` or `sync` stops the steps after it; the others go on.

| Step | What it does | Asks |
| --- | --- | --- |
| `preflight` | the OS, `git` (missing: failed), `age` when there is or may be a `secrets.age`, the keyring; moves the [machine-local files](#machine-local-files-from-older-installs) of an older install to the data dir | nothing |
| `config` | `--config URL`: a missing or empty `~/.config/drgnx` (machine-local files moved first) gets `git clone URL`; a clone of the same URL is left as it is (`git -C ~/.config/drgnx pull` updates it: bootstrap never pulls); anything else stops it: "~/.config/drgnx already holds a configuration (…): move it aside (mv ~/.config/drgnx ~/.config/drgnx.before) and run this again", and nothing is touched. `--chezmoi URL`: see below. Neither: says what the config dir is. `--step config` alone also moves the machine-local files | for chezmoi |
| `keys` | the keys of `secrets.age` into the keyring ([below](#your-provider-keys-secretsage)): with `--identity FILE`, or age's passphrase on the terminal. No `secrets.age`: ok; no keyring: skipped; no terminal and no identity: skipped with the command. A key the keyring holds differently is kept (failed, naming the host) unless you pass `--replace` | "Import the provider keys of secrets.age…?"; age's install |
| `sync` | the packages of your configuration's lock (`drgnx sync`); a pinned package nobody serves fails, named | nothing |
| `onboard` | `drgnx onboard --non-interactive`: records what is set up, changes nothing ([onboarding.md](onboarding.md)) | nothing |
| `desktop` | onboarding's Daemon and Desktop step: the systemd service and desktop entry (Linux) or the drgnx app (macOS); installed already: ok | its own questions |
| `shell` | the rc line of your shell ([shell.md](shell.md)) | "Add this line to ~/.zshrc?" |
| `doctor` | `drgnx doctor`: a FAIL fails the step, naming the checks; a WARN does not (Emacs 30.2, say, is supported and warns): the step is ok and names the checks that warn | nothing |

**Questions** are asked on the terminal only. Without one (stdin not a terminal) nothing is asked: what would be
asked is skipped, with its command. **`--yes`** answers yes for the announced age or chezmoi install, the key import
and `chezmoi init` — never for the rc line, the desktop entry, `chezmoi apply` or `--replace`, which are skipped with
their commands.

**age or chezmoi missing.** When the keys need age (or `--chezmoi` needs chezmoi) and it is not installed, bootstrap
prints the install line — "As root: sudo dnf install -y age" (the package manager it finds), `brew install age` on
macOS — and asks before it runs it; sudo asks for your password on the terminal. A no fails the step with the line
to run yourself. Nothing else is installed, and nothing else runs as root.

**chezmoi.** `drgnx bootstrap --chezmoi URL` takes your dotfiles' chezmoi repository instead of a drgnx
configuration: `chezmoi init URL` (asked; `--yes` confirms it), then `chezmoi diff` is shown, then `chezmoi apply`
runs only after a second yes, and never under `--yes`. The diff is shown only when that question follows: under
`--yes` or without a terminal (where the output may go to a log) the step only says how many lines differ, and
`chezmoi diff` shows them. A failure is reported with chezmoi's own error line, never a line of your files. chezmoi runs without a terminal (`--no-tty`): if your
templates ask questions, or a file is encrypted with a passphrase, the step fails and says to run `chezmoi init URL`
or `chezmoi apply` yourself. A chezmoi source dir that holds another repository is never replaced.

**The URL** is an https URL or an absolute path that exists. `http://`, `ssh://`, `git@host:path`, `file://`,
`ext::`, a relative path and a URL with a user name or password are refused (exit 2) without showing the value; use
a git credential helper for a private repository. A query or fragment (`?…`, `#…`) goes to git for the clone, but
is never shown, and `.git/config` keeps the URL without it. git runs without your hooks, templates and commit signing, over
https or a local path only, never asks for a password, and is stopped after two minutes. A clone goes into a new
directory beside the config dir and is renamed into place only when it worked, so a failed or stopped clone leaves
nothing behind. **`--identity FILE`** must be a file only you can read (`chmod 600`); bootstrap passes its path to
age and never reads it.

**How the terminal is used.** sudo's password and age's passphrase are typed on your terminal, which a program
drgnx's Emacs starts does not have. So for those two the run stops, `bin/drgnx` runs the command (only an age or
chezmoi install line of drgnx's own, or `drgnx secrets import`), and the run goes on from that step with the answers
you gave; you see one run.

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
