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

## The pack job's grammar half

`skald::job` builds what a manifest pins (the sync that drives it, the lock and `active.eld` come with the lock work):

1. **Fetch** each grammar at its `:commit`: `git fetch --depth 1 REPO COMMIT`, else a full fetch, then a detached
   checkout and a check that `HEAD` is the commit. Git runs with no user or system config, no prompts and no hooks.
2. **Tree hash.** `:tree-sha256` is the sha256 over the sorted lines `MODE PATH sha256(blob)` (one per file, `MODE`
   `100644` or `100755`, a top-level `.git` left out) of the tree. A symlink or any non-regular file is refused. It
   depends on neither git's SHA-1 nor `git archive`.
3. **Build** `parser.c` (plus `scanner.c` or `scanner.cc`) from the grammar's `:src` folder into
   `libtree-sitter-LANG.so` (`.dylib` on macOS) with the `cc` crate, with target and host set explicitly because
   there is no Cargo build-script environment at runtime.
4. **Load check.** The library is opened, `tree_sitter_LANG` is found, and its ABI must be at least the floor
   (`Options::min_abi`, the design's one ABI is 15). The library's sha256 is recorded as `:lib-sha256`, a local
   integrity check (`verify_lib`) the hub and the editor's loader repeat; it is not reproducible across compilers.
5. **Queries.** Every query file of the pack is compiled against its grammar, so a node the grammar lacks fails the
   job, not a buffer.
6. **Stage.** Work happens in a folder of the staging folder that is always removed. Only when every unit passed are
   the libraries moved to `grammars/LANG/COMMIT/`, so any failure leaves staging as it was. Folders are
   content-addressed and never rewritten.

The test fixture is the vendored tree-sitter-json grammar (MIT) in a throwaway git repository.

## `ratatoskr packs sync`, `load-check` and `pin`

```
ratatoskr packs sync --plan FILE [--out FILE]
ratatoskr packs load-check LIB NAME MIN_ABI [FILE=PATH]…
ratatoskr packs pin REPO COMMIT [--src DIR]
```

- `sync` is the job above, driven by a plan (a plist: `:version 1 :staging DIR :min-abi 15 :units ((:name :repo :commit
  :tree-sha256 [:src])…) :queries ((:grammar :file :path)…)`). Its answer, on stdout or in `--out`, is
  `(:ok t :staged ((:name :commit :tree-sha256 :lib :lib-sha256 :abi)…))` or `(:ok nil :error "…")`.
- **Loading a grammar runs its code, so it never happens in the process that matters.** `sync` runs the load check, the
  ABI check and the query compile for each library in a child of the same binary (`load-check`, one answer line, a
  60 s deadline). A grammar that crashes or loops there fails the job with the signal or the deadline in the answer;
  the hub, which runs `sync` as a separate process, is never involved.
- `pin` fetches a grammar at a commit and prints its `:grammars` entry with the tree hash, and the ABI its `parser.c`
  declares. A commit with no `src/parser.c` is refused (Swift's and SQL's `main` have none).

## Installed packs: the lock, `active.eld` and `drgnx packs`

The built-in packs are the folders of `packs/`. What is installed is in the lock (`drgnx.lock.eld`): `:packs`
(`NAME :commit :tree-sha256 :source :wanted`, a built-in pack's commit being the tree hash of its folder) and
`:grammars` (`LANG :commit :tree-sha256 :lib-sha256 :owner`). `core/drgnx-packs.el` owns them.

```
drgnx packs list
drgnx packs sync [--add NAME…] [--remove NAME…]
```

`sync` computes the wanted packs (the locked ones, plus `--add`, minus `--remove`, plus the packs they reference),
hands the grammars the lock lacks to `ratatoskr packs sync --plan` (minimum ABI 14: Emacs 31's modes pin ABI 14
parsers, Rust's is 15, and every libtree-sitter from 0.22 loads both), and then, in this order: writes the lock, makes a
generation, moves the built folders to `<data>/grammars/LANG/COMMIT/`, writes `<state>/packs/active.eld` (what a session
activates, derived from the lock) and sweeps. A failure before the lock write changes nothing; one after it leaves
`active.eld` and the grammar folders alone. `drgnx rollback` brings the old lock back and derives `active.eld` from it.
The sweep deletes grammar folders that no lock, no kept generation and no live session's claim
(`<state>/packs-in-use/PID.eld`) names. A pack cannot be removed while another installed pack references its grammars.

## Migrating the build before packs

`drgnx update` ends with `drgnx packs migrate`: the grammars the old build left in `<data>/tree-sitter/` become the
built-in packs that own them (`:wanted default`), built at their pins in one job. The old folder stays on the load path
after the packs' folders until every language in it has a build of its own, and then goes. A failure (no compiler,
offline) never rolls the update back: the old grammars keep highlighting, and `drgnx packs migrate` tries again.

## The pin test

`test/unit/packs-pins-test.el` loads each built-in pack's Emacs mode and compares its grammars' repository, commit and
source folder with the mode's `treesit-language-source-alist` entry (under ABI 15, where Rust's and PHP's modes pin
another commit than below it), so a Nidhogg rebase that moves a mode's pin fails a test, not a user's highlighting.

## The generic mode's queries (`ratatoskr packs translate`)

A pack with `:mode (:generic t)` highlights with `drgnx-pack-ts-mode` from its `queries/highlights.scm`. Emacs names a
capture by the face it applies and knows only `#eq?`, `#match?` and `#pred?`, so `ratatoskr packs translate PACKDIR OUT`
(`skald::translate`) rewrites the file once: a capture becomes a face by a fixed table (`@keyword.return` →
`font-lock-keyword-face`; a name the table lacks becomes an ignored `@_NAME`, a pattern with no known capture is dropped);
`#match?` keeps its regexp, rewritten into Emacs's syntax; `#any-of?` becomes an anchored `#match?`; `#not-eq?` and
`#not-match?` become `#pred?` on functions the editor defines (`:preds`). Patterns keep the file's order, consecutive ones of the same feature sharing a rule, and a later rule overrides an
earlier one (Neovim's order, which these queries are written for); each rule has the feature of its first known capture (`comment`, `keyword`, `string`, `type`, `constant`, `number`, `function`, `variable`, `property`,
`operator`, `delimiter`, `bracket`, `escape-sequence`, `attribute`), which the feature levels turn on and off. The node
kinds of the `@definition.*` patterns of `tags.scm` become `:defuns`, what navigation treats as a definition.

## The live test

`test/packs/live.sh` (in a container: needs network, git and a C compiler) installs the new packs with `drgnx packs sync
--add`: each grammar is fetched at its pin, built, load-checked in a child and its queries compiled. It then opens each
pack's sample (`packs/NAME/test/samples/`) in a batch Emacs and checks the mode and the faces of chosen tokens
(`test/packs/live-test.el`). The seven samples (PHP, Elixir, Kotlin, Swift, Zig, SQL and the Haskell grammar's build)
pass on Emacs 31 with libtree-sitter 0.26.
