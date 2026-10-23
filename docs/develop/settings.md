# Settings (contributors)

How drgnx's settings work inside: the files, the layers and how they are applied, and the two readers that read them.
The user's side is [docs/guide/settings.md](../guide/settings.md).

## The data subset

Settings files are data, never code: drgnx never `load`s them. Two readers read them and must agree: the editor's
(Emacs's `read`, behind the config layer's checks in `core/drgnx-file.el`) and the runtime's (`runtime/crates/huginn`).
Both read the cases in `test/fixtures/huginn/cases.json`.

What the subset holds, and what both readers refuse:

| Syntax | Status |
|---|---|
| comments `;` | accepted (kept as gaps for spans) |
| integers: decimal, trailing dot, `#x`, `#o`, `#b`, `#NrN` | accepted. Values beyond i64 are refused with a problem (no setting needs a bignum) |
| floats, incl. `1.0e+INF`, `0.0e+NaN` | accepted |
| strings: every escape incl. `\uNNNN`, `\U00NNNNNN`, `\N{U+X}`, `"\ "` (dropped), backslash-newline (dropped); `\xNN` and octal escapes below 0x80 | accepted |
| strings Emacs reads as **unibyte** with a byte ≥ 0x80 (`"\xe9"`, `"\351"`, `"\M-a"`), and multibyte strings with a raw byte (`"é\xe9"`, which Emacs reads as the raw-byte character 4194281) | refused by both. The writer never emits them |
| `\N{NAME}` | refused by Rust only: it would need the Unicode name table, and the writer never emits it. A listed divergence |
| chars `?a`, `?\n`, `?\C-a`, `?\^a`, `?\M-x`, `?\s`, `?\^?`, and the modifiers `?\s-a`, `?\H-a`, `?\A-a`, `?\S-a` | accepted, as the integers Emacs gives (`?\C-a` → 1, `?\M-x` → 134217848, `?\s-a` → 8388705) |
| symbols with escapes (`foo\ bar`, `\,x`, `1+`, `-`, `:kw`), `nil`, `t` | accepted |
| lists, dotted pairs, vectors | accepted |
| `'X` and `#'F` | accepted as `(quote X)` and `(function F)`; one top-level `quote` or `function` on a value is dropped (by the settings-file reader, not by `read`) |
| `` ` ``, `,`, `,@`, `#s(`, `#(`, `#[`, `#&`, `#N=`, `#N#`, `#@`, `#$`, `#.`, `##`, `#_`, `#:` | refused with a span, by both (the Lisp side's token check). `#.` is invalid in Emacs anyway |
| a file that is not valid UTF-8 | refused by both. Emacs would decode it to raw bytes; the Lisp side checks for `eight-bit` characters after decoding. A listed divergence from plain `read` |
| depth > 64, file > 1 MiB | refused |

How `huginn` reads it (`runtime/crates/huginn/src/read.rs`), where Emacs's `lread.c` has rules the table does not
spell out. Each is pinned by a row in the shared table or a test in `read::tests`:

- **Values are Emacs's.** Escapes, modifier chains (`?\M-\C-a`, `"\M-\M-a"`), `\x` with three or more digits (a
  character, not a byte: `"\x080"` is U+0080), octal above `\177`, `?\C-%` (the control bit), `"\C- "` (NUL), and
  `\N{U+41.}` (Emacs allows the trailing dot) all give what Emacs gives. Reading never recurses, so a long modifier
  chain or a deep file cannot exhaust the stack.
- **Tokens end where Emacs ends them.** Whitespace is every control character, space and no-break space. A symbol
  ends at whitespace or `"';#()[]`,` (not at `?` or `.`: `a?b` is one symbol). A token is a number only when the
  whole token has number syntax (`1+`, `1.5.`, `0x10`, `.e5` are symbols; `1.` is the integer 1). A radix integer
  needs no delimiter after it (`#x10.5` is 16 then 0.5). A character literal must be followed by a delimiter (`?ab`
  is refused), except `? ` and `?\t`.
- **Dots.** A `.` is the dot of a dotted pair only when whitespace, `"';([#?`,` or the end follows; otherwise it
  starts a symbol (`(a .)` is `(a \.)`). A dotted tail that is a list joins it: `(a . (b c))` is `(a b c)`,
  `(a . nil)` is `(a)`, `(a . 'b)` is `(a quote b)`.
- **`#` forms.** Only `#'`, `#x`, `#o`, `#b` and `#NrN` are data. `#!` is refused too, though Emacs skips the
  rest of its line: a settings file has no use for a script line, and the Lisp check refuses it the same way.
  Every other `#` form is refused as a reader macro, including the char-table `#^[`, which the row above does not
  name, and `#t`.
- **Depth** counts lists, vectors and `'`/`#'` (each is a list in the datum): 64 levels read, 65 are refused.
- **Spans** are byte offsets: a list's span runs from its `(` to its `)`, a string's includes its quotes, and every
  span re-read alone gives the same datum. The `quote` or `function` that a `'` or `#'` stands for has that token
  as its span.

Found while building `huginn`, beyond the listed divergences: a string with a character that UTF-8 cannot hold, a
surrogate or a code point beyond U+10FFFF (`"\uD800"`, `"\x110000"`), is read by Emacs and refused by `huginn`
(`NotUtf8`). The writer never emits either.

## Reading a settings file in Rust

`huginn::form::parse_settings(bytes, expect_head, limits)` reads one settings file (`runtime/crates/huginn/src/form.rs`).
The file is one form, `(HEAD :version 1 META… ENTRY… SECTION…)`, whose head must be `expect_head`
(`drgnx-settings` or `drgnx-workspace-settings`).

- **Refused whole** (`Err(Refusal)`, kind `Syntax`, or the reader's own): no form or more than one, a wrong head, no
  `:version`, a `:version` other than 1 (a higher one says "written by a newer drgnx").
- **Meta** is the leading `:key value` pairs: `:version`, `:roots`, `:project`, kept in `meta` with their colon. An
  unknown or repeated meta key is a problem.
- **Entries** are `(VAR VALUE)` or `(VAR VALUE :merge KIND)`; one leading `quote` or `function` on the value is
  dropped (`''a` leaves `(quote a)`). `(:mode MODE ENTRY…)` is allowed anywhere; `(:dir "D/" ENTRY…)` and
  `(:eval FORM…)` only under the head `drgnx-workspace-settings`, and a `:mode` may sit inside a `:dir`, nothing else
  nests. An `:eval` becomes an entry with `var` `":eval"` and the list of its forms as value.
- **Problems** are per entry and the rest of the file stands: a malformed entry, a section where it is not allowed, or
  a second entry for the same variable in the same scope path (the problem names both lines; the first stands).

`huginn::de` (feature `serde`, off by default) is a `serde::Deserializer` over a `Node` (`de::from_node`,
`de::Deserializer::new`):

| Lisp | Rust |
|---|---|
| plist `(:on-error strict :max-turns 3)` | struct: key without its colon, `-` as `_` (`on_error`, `max_turns`) |
| alist `(("a" . 1) (b 1 2))` | map: `(K . V)` gives `V`; `(K A B)` is `(K . (A B))`, so `V` is the list `(A B)` |
| list or vector | sequence |
| dotted `(A . B)` (or a two-element list) | 2-tuple |
| `nil` | the empty value the type asks for: empty sequence or map, `None`, `false`, a unit |
| `t` / `nil` | `bool` |
| string or symbol | string; integers `i64`; floats `f64` (an integer also fits a float) |
| symbol or string, or `(VARIANT …)` | enum: unit variant, or the rest of the list is the variant's value |

An `Error` carries the byte span of the node that did not fit. Use `serde_path_to_error::deserialize` around
`Deserializer::new` for the path; `huginn` itself does not depend on it.

## Conformance

The two readers are held to each other by four things, all under `test/fixtures/huginn/` and `runtime/crates/huginn`:

- **The shared case table** (`cases.json`, above): hand-written rows both readers' unit tests read.
- **The corpus** (`corpus/accept/*.el` with a `.json` dump of what Emacs reads; `corpus/refuse/*.el` whose first line
  is `;; refuse: KIND`, the `RefusalKind` huginn must name). It holds Emacs's `test/src/lread-tests.el` cases that
  fall inside the subset, tree-sitter-elisp's `test/corpus/` cases (MIT; `corpus/README.md` has the attribution) and
  file-shaped cases of our own (the review's R5 and X cases are rows of the shared table). A file is one case: add
  `x-NAME.el`, run `gen.el` (below) for its `.json`, and commit both. The corpus is data: `bin/drgnx fmt` and the
  pre-commit hook leave it alone.
- **Seeded random data** (`random-seeded.eld`, 2000 data from seed 1, and `random-seeded.dump`, one dump per line):
  `gen.el` generates them in a Nidhogg container. Emacs prints each datum with `prin1`, reads that text back through
  `drgnx-file--parse` and dumps what it read, so the dump is of the file's text, whatever `prin1` made of it.
- **A fresh seed on every CI run:** `drgnx-huginn/differential-fresh-seed` takes a seed from the clock, writes 500
  random data and runs huginn's `dump` example (`DRGNX_HUGINN_DUMP`, built by `runtime.yml`) on them; the dumps must
  agree line by line. A failure prints the seed. The test skips without the variable and is on the no-skip list, so
  CI cannot skip it.

Regenerate the committed dumps (batch Nidhogg, in a container, from the checkout):

```
emacs --batch -L core -l test/fixtures/huginn/gen.el -f huginn-gen-all
```

`drgnx-huginn/committed-dumps-are-current` fails when a dump no longer matches what Emacs reads, or when Emacs reads
a refuse file (but for kind `CharName`, the listed `\N{NAME}` divergence). huginn's side is
`runtime/crates/huginn/tests/{differential,properties}.rs`: `committed_corpus_matches`, `random_seeded_matches`, and
the property that every node's span, sliced out of the source, reads alone to the same datum. The fuzz target is
`huginn_read` (docs/develop/runtime.md, "Fuzzing"). The mutation check over the refusal paths is
`cargo mutants -p huginn --file crates/huginn/src/read.rs`, from `runtime/` (and `form.rs`, and `de.rs` with
`--features serde`; it tests a copy of `runtime/` alone, so the checkout's `test/` must sit beside that copy:
`/tmp/test` for a copy in `/tmp`): every
mutant is caught or times out, but for these equivalent ones, which no input can tell apart from the code:

- `read.rs`, `|` to `^` in `MODIFIERS`, in `META | (META - 1)` and in `code | modifiers` (`string_escape`'s
  result), and in `0x7FF8_0000_0000_0000 | payload` (the NaN in `decimal`): the bits never overlap.
- `read.rs`, `ch | 0x80` to `ch ^ 0x80` (`string_literal`, `\M-`): `ch` is below 0x80 there. To `ch & 0x80`: the
  string is refused as unibyte or raw-byte before the character is looked at.
- `read.rs`, `i + 1` to `i * 1` in `skip_line`: it stops on the newline, which the caller then skips as space.
- `read.rs`, `count < 3` to `count <= 3` (`\x`): only `count == 0` and `count < 3` are read, so a cap of 4
  changes neither.
- `form.rs`, `*n > 1` to `*n >= 1` (`:version`): `1` is matched by the arm before.

Floats are compared by value on the Rust side and in `drgnx-huginn/differential-fresh-seed`: any NaN equals any NaN,
`-0.0` differs from `0.0`.

## The writer

`core/drgnx-settings-file.el` reads and writes settings files (design §5.2, §6); its tests are
`test/unit/settings-file-test.el` (`drgnx-settings-file/`).

**Reading.** `(drgnx-settings-file-parse TEXT HEAD)` and `(drgnx-settings-file-read FILE HEAD &key max-bytes)` give a
`drgnx-settings-doc` (`file head meta entries problems failed text stamp`), HEAD `drgnx-settings` or
`drgnx-workspace-settings`. Each entry is a `drgnx-settings-entry` (`var value merge scope beg end line`): `scope` is
a scope path (`nil`, `((:mode . M))`, `((:dir . "D/"))`, `((:dir . "D/") (:mode . M))`), `beg`/`end` are positions in
a buffer holding `text` from its start, and an `(:eval FORM…)` section is an entry of var `:eval`. The rules are
`huginn`'s (`form.rs`, above), so both readers agree on every file:

- The text goes through `drgnx-file--parse` first (the data subset). Then the form must be `(HEAD :version 1 …)`:
  a syntax mistake, a wrong head, no `:version` or one other than 1 (a higher one: "written by a newer drgnx"), a
  file with no form at all (empty, or only comments) or over the limit (1 MiB; 64 KiB in a `.drgnx` folder) makes
  the doc `failed`, with one problem `(:file :text :line :column)`.
- A malformed entry, a section in the wrong file or place, an unknown meta key and a second entry for one variable in
  one scope path are problems of their own (`:beg`/`:end` too; a duplicate's names `:var` and `:scope`), and the rest
  stands. One top-level `quote` or `function` on a value is dropped.
- Positions come from reading the form element by element (`drgnx-settings-file--elements`), after the token check.
  A dotted tail that is a list joins its list, as `read` reads it; any other dotted tail in a settings list fails
  the file (huginn would read `(a . 'b)` as `(a quote b)`; no settings file needs it).

`(drgnx-settings-file-state FILE HEAD)` gives `(:doc :last-good :problem)`. `settings.el` is the config file
`settings` of the new shape `settings` (`drgnx-config-define … :shape 'settings :schema '(settings drgnx-settings)`):
the config layer reads it (head and `:version` only, by the same rules), says its mistake once and keeps its last
good copy (`drgnx-config-last-good-file`); `:last-good` is that copy read as a doc (its `file` is the copy). While
the file reads, the copy holds the same text: a per-setting fallback for an entry that fails its type (Task 8) needs
more than this copy. A file that is no config file (a workspace file) has no last good copy. `drgnx-config-update`
refuses a settings file (an `error`): only this writer writes it.

**Writing.** `(drgnx-settings-file-put FILE HEAD SCOPE VAR VALUE &key merge)`, `(drgnx-settings-file-remove FILE
HEAD SCOPE VAR)` and `(drgnx-settings-file-sort FILE HEAD)` (the command **Settings: Sort File**, registered with the
config commands) return the doc after. Each is one `drgnx-file-update` (the lock, waiting
`drgnx-settings-file-lock-timeout` seconds; a fresh read under it), and each refuses with `drgnx-settings-refused`
(a `user-error` and a `file-error`), leaving the file as it was: a failed or newer file, a modified buffer visiting
it, a value that is not plain data, a new text over the limit, a busy lock.

- **Text spans, never a re-print.** A changed entry's span (`beg`..`end`) is replaced; its comments around it stay. A
  new entry goes before the first item of its container whose sort key is greater (plain entries by name, then
  sections by kind `:mode`, `:dir`, `:eval` and name), above that item's comment lines; with none, after the last
  element, past the comment on its line. Missing sections are made around it. A removed entry takes its block (the
  `;` lines directly above it and the comment at the end of its line) and, when it has its lines to itself, those
  lines; a section it leaves empty goes too. A duplicate of the variable goes on every put and remove of it. `merge`
  given sets `:merge` (nil: none); left out, the entry keeps its own.
- **Sort File** permutes each container's blocks into the slots the blocks held, so the text between items (blank
  lines, loose comments) stays where it was; a block that ends in a comment moved before a close paren gets a newline.
  It repeats until no container is out of order.
- **The read-back check.** The new text is parsed again before the rename: it must not fail, its meta must be the
  same, the changed entry must read as the new value, every other entry must read as before (in order, for put and
  remove; as a set, for sort), and it may hold no new problem. Else nothing is written ("does not read back as
  meant"). `drgnx-file-write` then checks the bytes on disk read back as that data.
- **A visiting buffer.** Modified: the write refuses ("settings.el has unsaved edits in a buffer; save or revert it
  first"). Unmodified: reverted after the write, with `inhibit-interaction` t.
- **A new file** starts with design §5.2's three header lines (`drgnx-settings-file-global-header`), or for a
  workspace file one line naming its folder (a `.drgnx/settings.el`: the repository's folder name, never a path),
  then `(HEAD\n :version 1)`. A file with only comments keeps them, with the form after them.
- `drgnx-settings-file-written-functions` run with `(FILE BEFORE AFTER)` (the docs) after every write that changed
  the file, each under `condition-case` (an error is a `warn` notice of source `config`).

**The printer.** `(drgnx-settings-print VALUE COLUMN)` is drgnx's own, not `pp` (whose output changed between Emacs
29 and 30): one line when it ends by column 100 (`drgnx-settings-print-width`, counted in characters); else a proper
list of two or more elements breaks, before each keyword when it holds one (the elements before the first keyword stay
on the first line), else one element per line, each line one column in from its paren. Vectors, dotted pairs and
strings never break. An entry that does not fit on one line puts its value on the next line, one column in. The
print variables are bound (`print-length`, `print-level`, `print-circle`, `print-quoted` nil; `print-escape-newlines`
and `print-escape-control-characters` t; other characters as UTF-8 text). It refuses what is not plain data: a buffer,
a marker, a record, text properties, a unibyte or raw-byte string, a character UTF-8 cannot hold (a surrogate, past
U+10FFFF), a circular list, nesting past 64. A put also refuses a value `(quote X)` or `(function X)`, which would
read back as X. A comment inside a replaced value is lost.

The mutation check of the plan (Task 6, Step 5): replace the span edit with a whole-file re-print; then
`one-entry-one-span` and `comments-travel-with-their-entry` fail.

## Declaring a setting

drgnx's own settings are declared with `drgnx-defsetting` (`core/drgnx-setting.el`), a macro around `defcustom`:

```elisp
(drgnx-defsetting drgnx-example-limit 10 "How many rows the example shows."
  :type 'integer :group 'drgnx
  :scope 'buffer :workspace 'data :merge 'replace)
```

`defcustom` refuses unknown keywords, so drgnx's keys go into the symbol property `drgnx-setting`; the rest become
the `defcustom`. A keyword that is neither is an error when the form is compiled. Values are evaluated, as in
`defcustom` (`:scope 'global`, `:apply #'my-apply`).

| Key | Values | Inferred when not declared |
|---|---|---|
| `:scope` | `global`, `buffer`, `project` | `global` for a global minor mode's variable (`custom-set` is `custom-set-minor-mode`, or a variable that is not automatically buffer-local, named `…-mode`, whose function is a command); else `buffer` |
| `:workspace` | `safe`, `data`, `code`, `never` | `never` for the deny-list of names (Emacs's and drgnx's security settings); `code` when `risky-local-variable-p`, the name ends in `-interpreter`, `-executable`, `-program-name`, `-args` or `-arguments`, or the `:type` is or contains `function` or `hook`; else `data`. `safe` is never inferred: it is decided per value with `safe-local-variable-p` |
| `:merge` | `replace`, `append`, `alist`, `lower-only` | `replace` |
| `:on-error` | `last-good`, `strict` | `last-good` |
| `:apply` | a function | none |
| `:runtime` | the Rust type name | none |
| `:agents` | `grantable`, `never` | `never` when `:workspace` is `code` or `never`, else `grantable` |
| `:schema` | a `drgnx-schema` | none: the `:type` is used |

- `(drgnx-setting-meta VAR)` returns all eight keys for any variable, declared or not. Each function of
  `drgnx-setting-meta-functions` (the descriptions) is then called with the variable and the plist, and returns a
  plist of the keys it overrides. The result is cached per symbol; a new `defcustom` or `drgnx-defsetting` of the
  symbol (or a change of the function list) makes the cache entry stale on the next call.
- `(drgnx-setting-check VAR VALUE)` returns nil or `(PATH . MESSAGE)`: `drgnx-schema-check` for a `:schema`, else the
  `:type` must match.
- `(drgnx-setting-own-p VAR)` and `(drgnx-setting-names)` tell what was declared with `drgnx-defsetting`.
- `docs/reference/settings.md` lists the declared settings; it is generated (see `docs/develop/core.md`).

## The start-up order (Task 5)

`drgnx-init` (`core/drgnx.el`) and `init/early-init.el` call the settings code in one fixed order. Each call is a
function of the file that owns it; until that file is filled, the function does nothing.

1. `init/early-init.el`: `drgnx-user-lisp-load-early` (`core/drgnx-user-lisp.el`, loaded by its path): your
   `:early t` Lisp files. Not in safe mode.
2. `drgnx-settings-migrate-maybe` (`core/drgnx-settings-migrate.el`): the old settings files into `settings.el`, once.
3. `drgnx-pkg-activate`, then `drgnx-settings-apply-global` (`core/drgnx-settings-apply.el`): `settings.el`, after the
   packages are active and before `custom.el`.
4. `custom.el`, then (after the modules start) `config.el`: each loaded by `drgnx--load-user-config` inside
   `drgnx-settings-prov-with-load` (`core/drgnx-settings-prov.el`), which records who sets what.
5. `drgnx-user-lisp-load-all` (`core/drgnx-user-lisp.el`): your Lisp files.
6. `drgnx-settings-apply-pass`, then `drgnx-settings-live-start` (`core/drgnx-settings-live.el`): the end-of-init
   `:apply` pass, then the watches that apply a changed settings file at once.

Safe mode (`drgnx safe`, `DRGNX_SAFE`) runs step 2, then `drgnx-settings-apply-global :owned-only t` (drgnx's own
settings only), and none of the rest.

## The applier rule (Task 8)

## Provenance (Task 11)

## The Lisp index (Task 12)

## Testing in a child Emacs (Task 5)

A compatibility row runs in a child Emacs of its own, under a fresh temporary HOME and config dir, so it never sees
the test runner's state, `~` or your drgnx (`test/settings-child.el`; its own test is
`drgnx-settings-child/a-child-has-a-temp-home`).

- `(drgnx-settings-test-child FORMS :files FILES :env ENV)` writes FILES (`(NAME . TEXT)`; NAME relative to the
  config dir, or `~/…` for the temp HOME), starts this Emacs batch and `-Q` with the runner's `load-path`, requires
  `drgnx` as a test file does (no init file, no `drgnx-init`: a form calls it when a row needs a start), evaluates
  FORMS in order and returns `(:results :values :error :exit :output :root)`: each value printed and read back, what
  stopped the forms, the exit code and the child's output. ENV strings win over the test environment
  (`drgnx-test-env`); `DRGNX_SAFE=1` starts in safe mode, `DRGNX_SETTINGS_TEST_STOCK=1` gives a stock Emacs (drgnx
  not loaded).
- `(drgnx-settings-test-check-row VAR :value :state :describe :source :stock-equal)`, a form in the child, asserts
  the row's checks: the effective value, `custom-variable-state`, `describe-variable`'s text, the
  source `drgnx-settings-explain` names, the stock answer (`drgnx-settings-test-answer` in a stock child with the same
  files), and always that the explained winner is `symbol-value`. A failed check comes back as the child's `:error`.
