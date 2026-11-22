# drgnx

**A native code editor, written in Rust, with agents at the centre of the work.** By the Black Dragon Foundation.

drgnx is a new editor built around parts we have already written and tested: an agent hub that runs coding agents in
a sandbox, code search for large projects, a workbench model for panes and tabs, and a native windowing shell with
its own compositor. The text core, the editor view and the extension runtime are being built new.

> **Status: early, foundations stage.** drgnx is not an editor you can use yet. We are laying the foundations first:
> one crate, one lint, one document and one conformance test for each cross-cutting standard (errors, processes,
> logging, settings, commands, keys, views, the UI kit and more), before any feature code is written on top of them.
> Watch the repository to follow along.

## Goals

1. **Agents at the centre.** Agents work in the editor as people do: through the same commands, with their own
   cursors, history and review, in a sandbox, with any model.
2. **Huge projects and huge files.** Opening, searching and editing stay fast in very large repositories and in files
   of gigabytes.
3. **A multi-window workbench.** One project across several windows and displays, with layouts you arrange and keep,
   and zoom at every level.
4. **Extensible to the core.** Every feature is a command you can find, inspect, redefine and bind, live, through
   one extension API: WebAssembly components for packages and Luau for configuration and quick extensions.
5. **Light on resources.** A fast cold start, no work when idle, and a small memory footprint, measured on every
   change against set budgets.

## What is in this repository

One Cargo workspace:

| Path | What it holds |
|---|---|
| `crates/core` | text and models |
| `crates/ui` | drawing, the native shell, views and the UI kit |
| `crates/hub` | the hub and its services: agents, sandboxing, code search, the model gateway, the MCP server |
| `crates/ext` | the extension API and its hosts (to come) |
| `crates/std` | the standards every crate uses (to come) |
| `app/` | the editor binary |
| `docs/` | documentation ([start here](docs/index.md)) |

## Licences

drgnx follows the model of editors such as Zed:

- the editor and the hub: **GPL-3.0-or-later** ([LICENSE-GPL](LICENSE-GPL));
- hosted server parts: **AGPL-3.0-or-later** ([LICENSE-AGPL](LICENSE-AGPL));
- the libraries and the extension SDK: **Apache-2.0** ([LICENSE-APACHE](LICENSE-APACHE)), so extensions and other
  projects can use them under any licence.

Today every crate is GPL-3.0-or-later. A library moves to Apache-2.0 once an audit confirms it is entirely our own
code. Code adapted from other projects is listed in [THIRD_PARTY.md](THIRD_PARTY.md).

## Contributing

Contributions are welcome; please open an issue before a large change. Every contributor signs our
[contributor licence agreement](CLA.md) once, through a comment on their first pull request. See
[CONTRIBUTING.md](CONTRIBUTING.md) for how to build, the rules for a change, and how signing works. Security issues:
[SECURITY.md](SECURITY.md).

## Sponsoring

drgnx is built in the open by the Black Dragon Foundation. Sponsorship pays for the time to build it, and for the
machines its tests run on:

- [GitHub Sponsors](https://github.com/sponsors/Black-Dragon-Foundation)
- [Open Collective](https://opencollective.com/black-dragon-foundation)
- [Polar](https://polar.sh/black-dragon-foundation)

Funding details for grant programmes are in [funding.json](funding.json) ([FLOSS/fund](https://fundingjson.org)
format).

## drgnx classic

Before this rewrite, drgnx was a workbench-first framework for GNU Emacs. That version is no longer developed. Its
last state is kept at the tag
[`classic-final`](https://github.com/Black-Dragon-Foundation/drgnx/tree/classic-final): check that tag out to keep
using it or to read its code.
