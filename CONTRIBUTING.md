# Contributing to drgnx

drgnx is at an early stage: the foundations (the standards every crate is built on) come first, and much of the
design is still being settled. Contributions are welcome, but please open an issue before a large change, so we can
agree on the approach before you spend time on it.

## Building

drgnx is one Cargo workspace (Rust 1.95 or newer):

```sh
cargo check --workspace
cargo test --workspace
```

On Linux the native shell (`crates/ui/nhshell`) and the test compositor (`crates/ui/recorder`) link the system's
Wayland client library and libxkbcommon: install their development packages first (`wayland-devel` and
`libxkbcommon-devel` on Fedora, `libwayland-dev` and `libxkbcommon-dev` on Debian and Ubuntu). The terminal engine
(`crates/hub/ghostty-vt-sys`) builds libghostty-vt with Zig from pinned tarballs: run
`crates/hub/ghostty-vt-sys/fetch.sh` once.

The layout:

| Path | What it holds |
|---|---|
| `crates/core` | text and models (the row format, the line model, the settings data reader) |
| `crates/ui` | drawing, the native shell, views and the kit (Glitnir, nhshell, Sjá, Smidja) |
| `crates/hub` | the hub and its services (Ratatoskr, the sandbox, code search, the gateway, the MCP server, …) |
| `crates/ext` | the extension API (WIT) and its hosts |
| `crates/std` | the standards: one crate per cross-cutting rule |
| `app/` | the editor binary |
| `docs/` | documentation |
| `xtask/` | repository tasks |

## Rules for every change

- Tests and documentation come with the change.
- Use the workspace's standards (errors, processes, logging, paths, settings, commands, …) once they exist; a change
  never adds a second way to do what a standard owns.
- No secrets, keys, personal paths or machine names in commits: the pre-commit hook (`.githooks/pre-commit`, enable it
  with `git config core.hooksPath .githooks`) refuses them.
- No code copied from GNU Emacs or other GPL-only sources into a crate that is, or is planned to be, Apache-2.0. Code
  adapted from any other project carries an `Adapted-from:` line and an entry in `THIRD_PARTY.md`.

## The contributor licence agreement

Every contributor signs the [Black Dragon Foundation Individual Contributor License Agreement](CLA.md) once, before
their first pull request is merged. You keep the copyright in your work; the agreement gives the Foundation a licence
to distribute it under the project's licences, including moving a library from the GPL to the Apache License 2.0,
which the licence plan below depends on.

How to sign: when you open your first pull request, the CLA bot comments on it. Read [CLA.md](CLA.md), then reply in
the pull request with exactly:

> I have read the CLA Document and I hereby sign the CLA

The bot records your GitHub account, the date and the pull request on the repository's `cla-signatures` branch, and
the pull request's "CLA signed" check turns green. You sign once; later pull requests pass on their own. Comment
`recheck` if the check did not update. If you contribute on behalf of your employer, make sure you are allowed to (the
agreement's section 4). Questions about the agreement: upmanyu900@gmail.com.

## Licences

The editor and the hub are GPL-3.0-or-later (`LICENSE-GPL`), hosted server parts AGPL-3.0-or-later (`LICENSE-AGPL`),
and the libraries and the extension SDK will be Apache-2.0 (`LICENSE-APACHE`). For now every crate is
GPL-3.0-or-later: a library moves to Apache-2.0 only after an audit shows it is all our own code. Each crate's
`Cargo.toml` says its licence.

## Security issues

Please report them privately, as `SECURITY.md` describes, not in a public issue.
