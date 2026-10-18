# drgnx on a second machine

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
