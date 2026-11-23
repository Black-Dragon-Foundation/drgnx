# drgnx documentation

drgnx is a native code editor written in Rust, with agents at the centre of the work, by the Black Dragon
Foundation.

**Status: early, foundations stage.** There is no editor to use yet. The first stage lays down the standards every
crate is built on: for each cross-cutting concern (errors, processes, logging and tracing, paths, files, settings,
commands, keys, prompts, concurrency, lists and views, the UI kit, notices, resource budgets, data hygiene, scale and
zoom, accessibility, extension API versioning, the test harness) one owning crate with one API, a lint that rejects
any other way, a documentation page and a conformance test. Feature code starts once they are in.

## Goals

1. **Agents at the centre.** Agents use the same commands as people, with their own cursors, history and review, in
   a sandbox, with any model.
2. **Huge projects and huge files.** Opening, searching and editing stay fast in very large repositories and in
   multi-gigabyte files.
3. **A multi-window workbench.** One project across several windows and displays, layouts you arrange and keep, zoom
   at every level.
4. **Extensible to the core.** Every feature is a command you can find, inspect, redefine and bind live, through one
   extension API: WebAssembly components for packages, Luau for configuration and quick extensions.
5. **Light on resources.** A fast cold start, no work when idle, a small memory footprint: measured against budgets on
   every change.

## How the code is organised

One Cargo workspace:

| Path | What it holds |
|---|---|
| `crates/core` | text and models: the row and patch format (`rodd`), the line model (`hlidskjalf`), the settings data reader (`huginn`) |
| `crates/ui` | drawing and the native shell: the compositor library (`glitnir`), the Wayland and macOS shell (`skel`), the view model (`sja`), the reactive engine (`tafl`, [develop/engine.md](develop/engine.md)), the workbench model (`smidja`), a recording test compositor (`recorder`) |
| `crates/hub` | the hub (`ratatoskr`) and its services: the sandbox (`gleipnir`), code search (`hrafn`), the model gateway (`bifrost`), the MCP server (`mimir`), the ACP client (`hermod`), the runners (`sleipnir`), storage (`urdr`), and the rest |
| `crates/ext` | the extension API (WIT) and its hosts (to come) |
| `crates/std` | the standards: errors (`villa`), logging (`annall`), paths (`stig`), the test sandbox (`raun`), concurrency (`saman`), secrets (`hulda`), resource budgets (`vag`); the table and the rules are in [`develop/standards/`](develop/standards/README.md) |
| `app/` | the editor binary |
| `xtask/` | repository tasks |

Developer notes for the hub's crates are in [`develop/`](develop/runtime.md), carried over from the earlier drgnx;
some of them still describe that version's Emacs side, and they are revised as the new editor replaces it.

User guides: [agents outside drgnx](guide/outside-agents.md) (Claude Code, Codex… joining the work, and binding them
to a role).

## Licences

- The editor and the hub: GPL-3.0-or-later (`LICENSE-GPL`).
- Hosted server parts: AGPL-3.0-or-later (`LICENSE-AGPL`).
- The libraries and the extension SDK: Apache-2.0 (`LICENSE-APACHE`).

Every crate is GPL-3.0-or-later today; a library moves to Apache-2.0 once an audit confirms it is entirely our own
code. Adapted third-party code is listed in `THIRD_PARTY.md`.

## Contributing

Open an issue before a large change. Every contributor signs the contributor licence agreement (`CLA.md`) once, by a
comment on their first pull request. `CONTRIBUTING.md` covers building, the rules for a change and signing.

## Sponsoring

Sponsorship pays for the time to build drgnx and the machines its tests run on: GitHub Sponsors
(`Black-Dragon-Foundation`), Open Collective (`black-dragon-foundation`) and Polar (`black-dragon-foundation`).
Grant programmes can read `funding.json` (FLOSS/fund format).

## drgnx classic

The earlier drgnx, a workbench-first framework for GNU Emacs, is no longer developed. Its last state is the tag
`classic-final`.
