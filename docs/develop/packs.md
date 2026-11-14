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
drgnx packs sync [--add NAME…] [--remove NAME…]   # also: drgnx packs install NAME… / remove NAME…
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

## Screenshots

`test/ui/packs-gui-test.el` opens each new pack's sample in the GUI harness, once in the light theme and once in the dark
one, checks that it is highlighted and takes a picture (`PACK-THEME.png`). It needs grammars the pack job built: it skips
unless `test/ui/.packs-live-data` names the folder of a `drgnx packs sync` (the harness session has no environment of its
own, so a file carries it). The run that makes the pictures is local tooling: build the grammars once in a container
with `test/packs/live.sh` (`DRGNX_PACKS_LIVE_KEEP=DIR` keeps the data), then run the GUI suite with that folder mounted at
the same path and `DRGNX_TEST_SELECTOR='"drgnx-packs-gui"'`.

## The chunker's rules: `queries/chunks.scm`

Hrafn's chunker takes what a top-level form defines from the pack's `queries/chunks.scm` (compiled into the hub with the
manifest, `hrafn::chunk::registry`), under rules fixed in `hrafn::chunk::engine`, in place of a Rust walker per language
(Rust, C, C++, shell, Python, JavaScript, TypeScript, TSX, Go, Java and C#; Emacs Lisp, Org and Markdown keep their chunkers).
A pattern captures `@definition.KIND` (the node that defines; the kind is the suffix) with `@name`; `@container` on a node
whose `body` field holds members; `@transparent` on a node a definition may sit inside that is itself the member (a `const`
statement, a C `declaration`, a Go `var` declaration); `@skip` on a go-between (a Java enum's declarations, Go's `var (...)`
list); `@wrapper` with `@wrapped` for `export` and decorators; `@doc` with `@docowner` for a docstring.

1. A top-level form's definitions have no span of their own.
2. A definition counts when every node between it and the form is a wrapper, a transparent node, a skip node or a
   container's body, at most four containers deep: nested functions and closures are not symbols.
3. A member's span and doc anchor are the child of the container's body that holds it.
4. `(#set! drgnx.split)` gives each definition its own span, only when the form holds more than one such definition (Go).
5. Of the patterns that capture one node as a definition, the first in the file decides (a method pattern before a
   function pattern); `(#set! drgnx.name "c-declarator")` has the named helper find the name.
6. `:docs (:line "///" :block "/**" :members (...) :top (...))`: members take a line comment run, a `/** */` block or
   a docstring; Rust's top-level items take line comments too; a form's own doc is its docstring, then its block, then
   its line comments.

The engine was checked against the Rust walkers it replaced on the repository's own files (about 700 Rust files, plus
the other languages' fixtures) before they were deleted; the byte-for-byte goldens (`chunk_golden.rs`) and the property
tests (`chunk_langs.rs`) pass unchanged. References come from each pack's `queries/tags.scm` (the grammars' own tags
queries; C and shell have small ones of ours), keeping the `@reference.*` matches.

## Inline values, origin trails and debug adapters from packs

What the debugger and the trails knew per language is the pack's:
- **`:inline (:functions … :loops … :names …)`**: the node kinds inline values look for (the union over the built-in packs
  is what the hub's lists were).
- **`:origin (:decls …)`**: the declaration templates (ast-grep, `{t}` the name) of the language's origin trails; a pack with an
  `:origin` is a language trails work in, and its `:files :extensions` say which files (Python's `:decls ()` is empty).
- **`:adapters`**: the debug adapters of the language, merged after `etc/debug-adapters.eld`'s (`skald::builtin`), and an
  installed or fixture pack's through `Table::with_pack`; a launch type another entry already serves stays with the first.
  The doctor and the installer (Lisp) read the same union (`drgnx-packs-adapters`).
Probe families stay Rust, keyed by the adapter's id (design Q15).
  An adapter started by a language server uses `:start (:lsp-command …)`, with `:fill` steps whose argument language
  has `${config:KEY}`, `${config:KEY?}` (null when missing), `${file}` and the brace words; an `:into` entry may be
  `:optional t`. The `:install` of such an adapter can be several `:parts` (a JDK, a server, a plugin jar `:file`),
  each pinned by hash. See "The `lsp-command` start kind" in `debugging.md`. A fetched pack may not use it.

## The hub's grammars: the pack registry

The hub links no grammar crate but `tree-sitter-elisp` (Emacs Lisp has no pack). Every other parse site (the chunker and
its references, structural search, inline values, origin trails) asks `skald::registry` for a grammar by name. The
registry reads the lock's `:grammars` (`drgnx.lock.eld` in the config folder), finds each library at
`<data>/grammars/NAME/COMMIT/libtree-sitter-NAME.so`, checks its hash against the lock's `:lib-sha256` and its ABI
(at least 14), loads it and never drops it (a `Language`, a cached `Tree` or a `Query` may point into it). One path, no
fallback to a crate.

A grammar that is not built, does not match the lock or does not load is not an error the hub dies of: its files read as
text (no symbols, references or highlights), the first miss of each pack is one log line naming it, and `ratatoskr
doctor` prints `pack X not built (why)`. The registry looks again on the next use, so a grammar built after the hub
started is found without a restart. `install.sh` and `drgnx update` run `drgnx packs migrate`, which installs the eleven
packs the hub parses with (`drgnx-packs-hub-defaults`: rust, c, cpp, shell, python, javascript, typescript, tsx, go, java, csharp);
until that job finishes, code files read as text. A pack you remove (`drgnx packs remove NAME`, the Remove button) is
recorded in the lock's `:removed-packs`: `packs migrate` never installs it again, its files read as text, and `ratatoskr
doctor` says `pack X removed by you; drgnx packs install X to get it back`. `drgnx packs install NAME` (or `sync --add`)
forgets the record.

**Tests** parse with the same loader. `test/packs/hub-grammars.sh CACHE` builds those eleven packs' grammars with the pack
job (`ratatoskr packs sync --builtin OUT [PACK...]`) into `CACHE/KEY` (KEY: a hash of their commits, tree hashes and
sources) and prints `DRGNX_PACK_LOCK` and `DRGNX_PACK_GRAMMARS`; before the hub installs anything, the registry reads
those two variables. An unchanged set of pins reuses the folder; a pin change builds a new one. Run it in a container
(it needs network, git and a C compiler); `chunk_golden.rs` and the other Hrafn goldens run on these libraries, so a
golden that changes points at a pin or ABI mismatch between a pack and its mode's pin, not at the loader.

## C++

The `cpp` pack (`.cc .cpp .cxx .hpp .hh .h++`; a `.h` is C++ when its text is, `hrafn::files::looks_cpp`: the same rule for the index, the
debugger's inline values and search, in a pure C project or a mixed one) is Hrafn's `cpp` language: `queries/chunks.scm` makes classes,
structs, unions and namespaces (and `extern "C"` blocks) containers, so a class's inline members are methods and nested
types are members; `template <...>` is a wrapper, so a templated class or function is one form with its template line;
`c-declarator-name` finds the name of `Cache<V>::put` (`put`), `~Cache`, `operator==` and `T& f()`. `queries/tags.scm`
holds the references (calls, `new T`, base classes). `/** */` and `///` comments are the docs. The pack also carries its
`:inline` lists (lambdas, range-for) and `:origin` declarations, so inline values and origin trails work in C++;
debugging reuses lldb-dap and CodeLLDB by adapter id.

## C#

The `csharp` pack (`.cs`; grammar `c-sharp`, the commit Emacs's `csharp-ts-mode` pins) is Hrafn's `csharp` language:
`queries/chunks.scm` makes namespaces, classes, structs, interfaces and records containers, so a type's methods,
constructors, destructors, properties, events and nested types are members (a file-scoped `namespace N;` has no body, its
types sit at the top); delegates, enums and operators are symbols too. `queries/tags.scm` holds the references (calls,
`new T`, base types). `///` and `/** */` comments are the docs (the XML tags stay in the first line). The pack carries
its `:inline` lists (local functions, lambdas, `foreach`) and `:origin` declarations (`$TY {t} = $V;`; the store forms are
tried with a closing `;` too, since C# has no bare expression at the top). `:format` names CSharpier
(`csharpier format --write-stdout`, a .NET tool the user installs, tested against 1.4.0; the marker files are `.csharpierrc*`).
The debugger is netcoredbg 3.2.0-1092 (`:adapters`, launch types `coreclr` and `netcoredbg`): a pinned, hashed download
(linux-x64, linux-arm64, darwin-arm64) into the tools folder, started as `netcoredbg --interpreter=vscode`. It needs the
.NET runtime to run the program (`dotnet` on the PATH or `DOTNET_ROOT`); a build puts the dll in `bin/Debug/netN.0/`, which
the default launch configuration names. The live test (`csharp_breaks_steps_and_inspects_through_netcoredbg`, in the adapter
image whose .NET SDK is pinned by SHA-512 in `test/container/debug-adapters-image.sh`) breaks, steps and inspects.

## Fetched packs: the parse worker

A pack that is not built in brings a grammar library somebody else wrote. The hub never loads it: `hrafn::chunk::worker`
runs it in a worker process, `ratatoskr hrafn-parse --lib FILE --grammar NAME --sha256 HASH` (this binary again), which
checks the library's hash, loads it, builds the pack's `chunks.scm` and `tags.scm`, and answers requests until its stdin
ends. The tree never crosses the process: a request is one file (`path`, `text`, `budget`, at most 4 MiB), the answer is
its chunks, symbols and references. A file whose extension a fetched pack claims (`hrafn::chunk::worker::claims`; only
files no built-in language takes) goes through `chunk_file_refs` to the worker; every other outcome is the file read as text.

- **Protocol.** Length-prefixed JSON frames (`u32` big-endian, then the body) on stdin and stdout, nothing else. The reader
  refuses a length over the cap (32 MiB) before it allocates, reads the body in pieces, and calls a stream that ends inside a
  frame truncated; a fuzzed-stream test runs it over random bytes. The hub also checks what a worker says: chunk offsets
  inside the text, on character boundaries and in order, symbols pointing at chunks that exist, the id of the request.
- **Failure costs the worker.** A request has a deadline (20 s, set by the hub, not by the worker: a scanner that never
  returns cannot check a flag). A fault, a bad frame, a wrong answer or a missed deadline ends the process and its group, fails
  that file (it reads as text) and the next file starts a fresh worker; three failures in ten minutes and the pack reads as
  text until the hub restarts. A reason, with the end of the worker's stderr, goes to the log once and to `ratatoskr doctor`
  (`pack X not built (why): its files read as text`).
- **The sandbox** (`parse_worker.rs`): Gleipnir's full tier, a spec with two read-only files (the library and this
  binary) and nothing else: no write root, no home, no session dir, no socket, a network namespace with no relay (only its
  own loopback), no environment but `PATH` and `LANG`. stdin is the pipe (a sandboxed one-shot gets `/dev/null`; the
  launcher turns that off for this). On the reduced tier, with no sandbox backend, or when the spec is refused, nothing is
  started and the pack reads as text with the reason in the doctor. `hrafn_parse_sandbox.rs` (the sandbox lane, `ctr.sh
  --sandbox`) runs the worker in the real sandbox: its answer equals the in-process chunker's, and a `probe` grammar that
  tries on load to write beside itself and in `/etc`, `/usr` and `/var/tmp`, to read a secret file and to connect to a TCP
  port and a Unix socket the test serves, gets nowhere (its control, started plainly, reaches them). A `/var/tmp` write
  succeeds inside the sandbox and goes to a private tmpfs; the test checks the outside for files.
- **Where the packs come from.** At start the hub reads `<state>/packs/active.eld` and the lock (`parse_worker::fetched`):
  the installed packs the built-in set lacks, with `:hrafn :chunks` (and `queries/tags.scm` unless `:tags` says another),
  a built library the lock hashes. The language stamp includes each one (library hash, extensions, queries), so installing,
  updating or removing a pack parses a project's files again.
- **Tests.** `test/packs/hub-grammars.sh` also builds three fixture grammars from the JSON grammar: `loopy` (spins on the
  first token), `crashy` (faults on it) and `probe`; `hrafn_parse.rs` starts the real worker (equals the in-process
  chunker; a wrong hash is refused; `crashy` and `loopy` cost the worker and never the caller, the spinner is killed at the
  deadline); `fetched_pack.rs` checks the chunker's side (the worker's answer, a refused launcher, the stamp).

**What the worker does for the other parse sites (Task 6b-2).** Besides `chunk`, a request can be `find` (a structural
pattern, ast-grep's syntax, in a file: the Search view's Pattern toggle sends each file of a fetched pack to its worker and
reads back the matches) and `scan` (the names inline values show at a stopped row: the tree walk of `hrafn::inline_scan`,
the same function the debugger runs for a built-in language, with the pack's `:inline` node kinds; the matching of the
frame's variables and the lines drawn stay the hub's). The pack's `:hrafn :sigil` is its metavariable character. A
pattern the pack's grammar refuses comes back as the pattern's error (the worker and the pack are not struck for it). The
hub checks these answers like the chunks: match spans inside the text on character boundaries, lines the file's, a bounded
number of bounded captures; names on rows of the file. Origin trails (`debug::origin`) keep their per-language Rust path
for the built-in languages and do not reach a fetched pack's grammar yet.

## The language stamp

The code index records the stamp the files were parsed under (`hrafn::chunk::lang_stamp`: a hash of every tree-sitter
language's pack data, its manifest, `chunks.scm` and `tags.scm`, and whether its grammar is built). When it moves (a
pack changed, a grammar was built after the hub indexed the files as text, or one went missing), the next refresh parses
every file again; a chunk whose text did not change keeps its key and so its vector, so nothing is embedded twice.
