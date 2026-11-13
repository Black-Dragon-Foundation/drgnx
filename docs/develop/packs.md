# Language packs

A language pack is a folder with one manifest, `pack.eld`, plus tree-sitter queries and test fixtures. It is data
that names programs: it contains no code, but it can name a language server, a formatter or a debug adapter that
drgnx starts for you. The format and its rules live in the `skald` crate (`runtime/crates/skald`); this page is the
contributor reference. (The user pages arrive with the Extensions side of packs.)

## Layout

```
pack.eld                 the manifest (data, read with huginn: nothing is evaluated)
queries/tags.scm         definitions, references, docs
queries/chunks.scm       containers, wrappers, splits, cut points
queries/inline.scm       optional "not a value" patterns for inline values
queries/highlights.scm   the generic mode's highlighting (below)
test/…                   fixtures and goldens
README.md, LICENSE       shown as inert text
```

## The manifest

One plist. Every key is known; a misspelt or unknown key is refused with its path (`grammars[0].bogus`).

| Key | Meaning |
|---|---|
| `:pack`, `:schema`, `:version`, `:name`, `:summary`, `:license`, `:maintainers` | identity. `:schema` is the manifest format (1) |
| `:files` | `:extensions` (no dot), `:names`, `:shebangs` (regexps on the interpreter's base name), `:mode-regexp` |
| `:grammars` | units keyed by language name. Pinned: `:repo` (https), `:commit` (40 hex), `:tree-sha256` (64 hex), `:src`; or referenced: `:from-pack`. `:required t` must load before the mode is remapped |
| `:mode` | `(:generic t [:indent ((NODE . N)…)])`, or `(:ts MODE :builtin t [:classic MODE])`, or `(:ts MODE :package PKG …)` |
| `:servers` | `:id`, `:modes`, `:command`, `:find`, `:install` |
| `:format` | `:formatter`, `:command`, `:standard`, `:config-files` |
| `:hrafn` | `:lang`, `:tags`, `:chunks`, `:docs (:line :block :members)`, `:sigil`, `:helpers` (a closed set: `js-callback-body`, `c-declarator-name`) |
| `:origin` | `:decls`, ast-grep templates |
| `:adapters` | debug adapters, the schema of `etc/debug-adapters.eld` |
| `:inline` | `:functions`, `:loops`, `:names`, `:query` |
| `:requires` | `:packs`, `:packages` |

## Names

A fetched pack may not use a built-in pack's name, a language name the index already stores (`shell`, not `bash`;
`typescript`, `tsx`, `jsx`), or a grammar language name a built-in pack owns (it references that grammar with
`:from-pack`). `skald::reserved` holds the tables. A built-in pack's `:hrafn :lang` must be one of the stored names.

## Rules for a pack that is not built in

`ratatoskr packs check` and the pack job refuse a fetched pack when:

- a command's `argv[0]` is not the program its `:find` or `:install` names (a bare name, a `{tools}/…` path, or
  `{program}`); a formatter's `argv[0]` is a bare program name;
- `argv[0]` is a shell or an interpreter (`sh`, `bash`, `python*`, `node`, `ruby`, `perl`, `env`, …) and the arguments
  carry inline code (`-c`, `-e`, `--eval`, …);
- it claims a file extension, a file name, an interpreter pattern, a classic mode or a debug launch type that a
  built-in pack, the adapter table or another installed pack owns, or pins a grammar another pack already pins;
- an `:install` recipe has no digest (`:sha256`, a pip `:hash`); `:system` is shown and never run.

## highlights.scm

Emacs accepts only `eq?`, `match?` and `pred?`, so a pack may use `#eq?`, `#match?` and `#not-match?` with a portable
regexp (literals, `.`, classes, `^ $ * + ? |`, groups), `#any-of?` and `#not-eq?`. `#set!`, `#lua-match?` and other
predicates, `{n}` intervals, `\d`-style escapes and `(?…)` groups are refused.

## Checking a pack

```
ratatoskr packs check DIR [--builtin] [--other DIR]…
```

Reads `pack.eld`, every file it names, `queries/highlights.scm` (required for a generic mode), and refuses a symlink
leaving the folder. `--builtin` runs only the schema rules; `--other` adds the packs whose claims count. Exit 0 when it
passes, 1 with a line per problem, 2 for bad arguments. Fetching, building and loading grammars, and compiling the
queries against them, belong to the pack job.
