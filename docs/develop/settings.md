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
  A dotted tail that is a list joins its list, as `read` reads it, a quoted one too (`(a . 'b)` is `(a quote b)`, as
  huginn reads it). A section that is not a proper list is one problem, and the rest of the file stands.

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

## The applier rule

`core/drgnx-settings-apply.el` puts drgnx's global layers into Emacs through one custom theme, `drgnx` (design
§4.2). The theme is declared and enabled once, then taken out of `custom-enabled-themes`, as use-package does with its
own: `(mapc #'disable-theme custom-enabled-themes)` leaves it alone. **Never `disable-theme 'drgnx`**: it does nothing
for a theme that is not in the list, and a forced disable would reset a later `setq` to the standard value.

- `(drgnx-settings-winner-p VAR)`: drgnx's layer is Emacs's winner when (1) no theme but `drgnx` has an entry in
  VAR's `theme-value` (no `user`, `use-package`, colour theme or `changed` stash) and (2) VAR's default value is
  `equal` to drgnx's entry, or to the standard value when drgnx has none yet. A void VAR meets rule 2; a bound
  variable with no standard value (a plain `defvar`) does not, so it is stored, never applied (the described
  `defvar`s of Task 31 get their own branch). Decided from Emacs's data, never from provenance: a `setq` no watcher
  saw breaks rule 2.
- `(drgnx-settings-push VAR VALUE)` → `applied` or `stored`. The winner goes through `custom-theme-set-variables`
  (`custom--inhibit-theme-enable` nil): the value applies and `:set` runs, or, for a void VAR, waits in
  `saved-value` for the `defcustom` (for a bound VAR drgnx clears that stash at once, as `custom-declare-variable`
  does for a non-`user` theme: `saved-value` stays Customize's). A value already in effect is only recorded (no `:set` on a no-op, row C18).
  A loser is stored in place: drgnx's entry is replaced where it stands in `theme-value` (or appended), and
  `theme-settings` follows. When no entry holds the value in effect (and it is not the standard value), that value
  first becomes Emacs's `changed` stash at the front, so Emacs's own recalculation (disabling another theme, Erase
  Customization) keeps it: V3 gives `((changed 80) (drgnx 100))`. **Never `custom-push-theme` for a losing store**:
  Emacs 31 moves an altered entry to the front (`custom.el:987`), over your Lisp. Before deciding, an option whose
  `custom-autoload` asks for it is loaded (`custom-load-symbol`), as `custom-theme-set-variables` does (R3).
- `(drgnx-settings-teardown VAR)`: `custom-push-theme 'theme-value VAR 'drgnx 'reset`, then
  `custom-theme-recalc-variable` only while the value is still `equal` to drgnx's (V2); `saved-value` is cleared
  when no theme is left. Returns non-nil when drgnx had an entry.
- `(drgnx-settings-let-go VAR)`: what removes settings.el's value of a variable once the applied entries no longer
  hold it (a live sync, Turn Off): `drgnx-settings-resolve-apply` when modules claim VAR, so their value stays, else
  `drgnx-settings-teardown`.
- `(drgnx-settings-apply-global &key owned-only)` (start, safe mode, Turn On): reads `settings.el` with
  `drgnx-settings-file-state`, checks each top-level entry with `drgnx-setting-check` and pushes it, in Emacs's
  order (`custom--sort-vars`: `:set-after`, minor modes last). An entry that fails falls back alone by `:on-error`:
  `strict` → torn down to the default; else the value this session last applied for it, else the last good copy's
  entry when that checks. A failed file falls back the same way per setting from the last good copy. Problems go to
  `drgnx-settings-apply-problems` and one notice (source `config`, id `settings-entries`); the failed file is the config
  layer's own notice. `OWNED-ONLY`, `drgnx-settings-package-settings-off` and `DRGNX_PACKAGE_SETTINGS=off` apply only
  `drgnx-setting-own-p` entries. Returns `((VAR . RESULT)…)`, RESULT `applied`, `stored`, `default`, `problem` or
  `failed`. It binds `inhibit-interaction` and never signals: the start-up call sites have no `condition-case`.
- `(drgnx-settings-dormant)`: the entries last applied whose variable is still void (information, never a problem).
- `drgnx-settings-apply-durations`: seconds per push of the last apply (its `:set` included);
  `(drgnx-settings-apply-slow &optional THRESHOLD)` lists those over 1 ms, slowest first.
- **Settings: Turn Off Package Settings** / **Turn On Package Settings** (registry ids `settings-package-off`,
  `settings-package-on`, in `drgnx-config-register-commands`): `drgnx-settings-let-go` of every applied entry drgnx does not own, or
  `drgnx-settings-apply-global` again. `drgnx-pkg-bisect` gains the step: when the problem shows with every module
  off, it tries once more with `DRGNX_PACKAGE_SETTINGS=off` and answers `:package-settings` when that clears it.
- Language overrides (`(:mode …)` sections) are `core/drgnx-settings-mode.el`'s; module claims resolve with G2 in
  `core/drgnx-settings-resolve.el` before the push.

Tests: `drgnx-settings-apply/*` (`test/unit/settings-apply-test.el`) and the rows C1, C2, C3, C5, C7, C7b, C13, C14,
C16, C17, C18, C22 (`drgnx-settings-compat/*`, `test/unit/settings-compat-global-test.el`, each in a child Emacs).

## Module claims and the resolver

`core/drgnx-settings-resolve.el` makes a module's choices claims (layer G1) and resolves them with the entry of
`settings.el` (G2) inside theme `drgnx`; only the result goes through the applier rule (design §4.2, row C26). So
modules stop overriding Customize, `use-package :custom` and your Lisp.

- **Claims.** `(drgnx-settings-claim VAR MODULE KIND DATUM)` and `(drgnx-settings-unclaim VAR MODULE KIND DATUM)`
  record and drop one; KIND is `value` (`drgnx-module-set`, DATUM the value), `key` (`drgnx-module-alist-put`, DATUM
  `(KEY . VALUE)`) or `element` (an `add-to-list` the recorder sees in a setup, DATUM the element).
  `(drgnx-settings-claims VAR)` lists them oldest first; `(drgnx-settings-claim-modules VAR)` names the modules.
  Claims are made only inside a setup (a module's own code); outside one the helpers just make the change.
- **`(drgnx-settings-resolve VAR)` → `(VALUE . REPLACED)`**, pure. The merge is the entry's own `:merge`, else the
  setting's (`drgnx-setting-meta`): `replace` (G2's value; REPLACED is `((MODULE DATUM…)…)`), `alist` (G2's entries,
  then the modules' keys G2 does not have, the newest claim of a key winning), `append` (the modules' elements, then
  G2's), `lower-only` (the lower of the newest value claim and G2 when both are numbers). With no G2 entry, VALUE is
  G1: the newest value claim, or the value under the claims, with the key and element claims put in.
- **`(drgnx-settings-resolve-apply VAR)`** pushes the result with `drgnx-settings-push` (inside
  `drgnx-modules--quietly`, so the recorder's net records nothing of it): `applied`, `stored`, `dropped` (nothing in
  drgnx holds VAR: drgnx's theme entry goes, and the value goes back to the layer below while it is still drgnx's, or
  to its value before the first claim for a variable with no standard value, void again if it was), or nil when VAR
  does not go through the theme.
- **Which route.** Through the theme: an option (a standard value, or void) with a value claim or a `settings.el`
  entry, and any variable the theme already holds. Directly, as before (each helper's own undo, "Two modules, one
  target" in core.md): a key or element claim with no `settings.el` entry, and anything on a bound plain `defvar`
  (the applier stores those, never applies them). A void variable a value claim applies is also set at once, as
  `drgnx-module-set` always did; its `defcustom` keeps the value.
- **Direct changes, then an entry.** When a `settings.el` entry arrives after modules changed VAR directly (a live
  change), the value they left (`drgnx-settings-resolve--last`) becomes drgnx's theme entry first, while no other
  theme holds VAR and the value is still theirs, so the push decides as the winner. `drgnx-settings-apply-global`
  pushes each entry's value through `drgnx-settings-resolve-entry`, which merges the claims in.
- **Undo.** `drgnx-module-set`'s and the theme route's undo unclaim and resolve again: another module's claim takes
  over, or the value drops. A key or element put in directly is removed only while it is still in the value (as
  before); once a `settings.el` entry holds VAR, the undo resolves instead.
- **Settings: Keep Module Entries…** (`drgnx-settings-keep-module-entries VAR`, registry id
  `settings-keep-module-entries`): offers the variables whose entry replaces modules' entries, writes `:merge alist` on
  that entry (`drgnx-settings-file-put`) and applies it at once.
- Provenance names the modules: the G1 layer's `:source` is "module lang/eglot" (`:modules` lists them), also for a
  value the modules set directly (no theme entry), while it is still theirs.

Tests: `drgnx-settings-resolve/*` (`test/unit/settings-resolve-test.el`), row C26
(`test/unit/settings-compat-modules-test.el`, in a child Emacs), and the helpers' own (`drgnx-module-set/*`,
`drgnx-module-helpers/*`, `test/unit/modules-helpers-test.el`).

## Provenance

`core/drgnx-settings-prov.el` records who set a variable and explains Emacs's value (design §4.5). Provenance
explains; it never decides what the applier does (that is the winner rule, from Emacs's own data).

- **While your Lisp loads.** `drgnx--load-user-config` wraps each load in `(drgnx-settings-prov-with-load FILE
  BODY…)`. For BODY's extent it binds `load-read-function` to a reader that notes, per `load-file-name` (an alist, so a
  nested `load` never overwrites the outer file's entry), the line and span of the form being read; an `:around`
  advice on `custom-declare-variable` marks a `defcustom`'s own initialisation; an `:around` advice on
  `do-after-load-evaluation` marks after-load bodies with the form that loaded the package; an `:around` advice on
  `custom-theme-recalc-variable` marks a value that a theme enabled or disabled there gives (a `load-theme` in
  `config.el` is the theme's, not that line's). The advices are removed when BODY ends. FILE joins your Lisp files.
- **Watchers** go on the managed variables: those theme `drgnx` holds a value for and those `settings.el` names
  (`drgnx-settings-prov-watch VAR` adds one later). Only `set` counts (`let`, `unlet`, `makunbound` are ignored);
  an alias is resolved with `indirect-variable`. A write is recorded as (design §4.5's table, in this order):
  `drgnx` (inside `drgnx-settings-prov-applying`, which the applier binds, or a `defcustom` taking theme `drgnx`'s
  value, also one loaded after start), `theme` (a theme recalculation while your Lisp loads; `:theme` is the theme
  that holds the value, nil for the default), `definition` (a `defcustom`'s own value, or the first value of a void
  variable), `session` (after start;
  buffer-local writes after start are not recorded), `deferred` (an after-load body), `lisp` (a file of yours: in
  your config dir, loaded with provenance, or listed) or `package` (any other file being loaded). At most
  `drgnx-settings-prov-max-records` per variable. A watcher never signals.
- **`(drgnx-settings-prov VAR)`** gives the records, newest first: `(:kind :value :file :line …)`, `:line` being
  the line the running form starts at (none for a compiled file). The static index (`drgnx-lisp-index`, through
  aliases) confirms it: exactly one setter of VAR inside the form's span (for `deferred`, one conditional setter in
  your files; for a compiled file, one in its `.el`) gives `:certain t` and `:setter-line`; otherwise `:certain nil`
  and `:candidates` (`:file :line`).
- **`(drgnx-settings-explain VAR &optional BUFFER)`** explains `VAR`'s value in BUFFER (default the current
  buffer): `(:value :layer :kind :source :file :line :certain :candidates :layers :changed-this-session
  :buffer-local-only)`. `:value` is always Emacs's value there; `:source` is the text the UI shows, `:layer` one of
  `G0` `G1` `G2` `G3` `G4` `package` `theme` `session`, or in a buffer `L1` `buffer` `W1` `dir-local` `W2`
  `file-local`. Without a local value, the winner is the newest record whose value is Emacs's (a `session` record
  yields to an equal theme entry, a record of your Lisp inside `custom-set-variables` is Customize's), else the first
  `theme-value` entry with that value, else the default; nothing matching is `unknown` with the index's candidates.
  With a local value, the buffer layers are ranked `L1` < `buffer` < `W1` < `dir-local` < `W2` < `file-local`
  and the highest one holding the value wins.
- **`drgnx-settings-explain-functions`**: each is called with `(VAR BUFFER)` when VAR is local in BUFFER and
  returns layer plists `(:layer ID :value V :file F :line N :source TEXT …)`; language overrides add `L1`, the
  workspace files `W1` and `W2`.
- Tests: `drgnx-settings-prov/*` (`test/unit/settings-prov-test.el`) and rows C1b, C6, C23
  (`test/unit/settings-compat-prov-test.el`), each in a child Emacs. The explained winner is always `symbol-value`
  (`drgnx-settings-prov/explained-winner-is-symbol-value`, and `drgnx-settings-test-check-row` in every row).

## The Lisp index

`core/drgnx-lisp-index.el` is a static read of your Lisp files (`custom.el`, `config.el`, `drgnx-user-lisp-files`):
which variable each one sets, on which line. It reads the forms with positions and never evaluates them (`read-eval`
is off; a file that stops reading gives what was found before the problem). Provenance (Task 11) uses it for the lines
the dynamic record cannot give, and the Lisp files page and Move (Task 28) are built on it.

- `(drgnx-lisp-index-file FILE)` returns `(:setters LIST :findings LIST)`.
  - A setter is `(:var :kind :line :beg :end :top-level :conditional :const-p :value)`. `:kind` is `setq` (each pair
    gets its own setter), `setq-default`, `setopt`, `customize-set-variable`, `custom-set-variables` (each entry, on
    its own line) or `use-package-custom`. `:beg`/`:end` are buffer positions of the pair or entry.
  - `:top-level` is t for a form at the top of the file, also inside a top-level `progn`. `:conditional` is t under
    `when`, `unless`, `if`, `cond`, `with-eval-after-load`, an `add-hook` lambda, or a `use-package` `:config` (deferred
    unless `:demand t`) and anything under `:if`/`:when`/`:unless`/`:requires`. Move refuses a conditional form.
  - `:const-p` is t when `:value` is the literal value (a number, string, keyword, `nil`, `t`, a vector, `'X`, `#'f`),
    else `:value` is the form as written.
  - A finding is `(:kind :line :text)`: `custom-file` and `user-emacs-directory` (the file sets them),
    `emacs-dir-use` (each use of `user-emacs-directory` or `locate-user-emacs-file`) and `buffer-local-setq` (a
    top-level `setq` of an automatically buffer-local variable that this Emacs already knows).
- `(drgnx-lisp-index-setters VAR FILES)` returns the setters of VAR in FILES, each with `:file`, through the cache.
- The cache is `<cache>/lisp-index/<sha1 of the truename>.eld`, keyed by the file stamp (`drgnx-file-stamp`) and a
  format version; a changed file is read again. `drgnx-lisp-index-get FILE` answers from it.
- `drgnx-lisp-index-refresh` brings the cache up to date; `drgnx-lisp-index-schedule` runs it once at idle through
  `drgnx-timer` (key `lisp-index`), never on the main thread at start. `drgnx-init` calls it last, after the live
  watches, and not in safe mode. Tests: `drgnx-lisp-index/*`
  (`test/unit/lisp-index-test.el`).

## The Lisp files page and Move (Task 28)

`core/drgnx-settings-lisp-page.el` and `core/drgnx-settings-move.el`, autoloaded from `core/drgnx-config.el` (they work
in safe mode and with every module off).

- **The page.** `(drgnx-settings-lisp-page-rows)` gives the rows as data, in load order (early files, custom.el,
  config.el, `drgnx-user-lisp-files`, files in the config dir those loaded from `load-history`, then settings.el and
  `drgnx-settings-workspace-files`): `(:file :role :exists :on :early :loaded :seconds :error :parent :settings
  :findings)`. A setting's `:won` is `won` when `drgnx-settings-explain` is certain and names that file and line,
  `lost` when it is certain of another source, else `unknown`. `drgnx-settings-lisp-files` draws them (special mode,
  drawn on the user's action); `drgnx-settings-lisp-page-open` follows the `drgnx-settings-lisp-page-at` property
  `(FILE . LINE)` of a line; a setting's line also has `drgnx-settings-lisp-page-var`.
- **Load times and errors.** The loader of your Lisp calls `(drgnx-settings-lisp-page-note-load FILE :seconds S
  :error MESSAGE :parent FILE)` inside `drgnx-settings-prov-with-load`, where an error's line is the form provenance
  saw being read. Until a loader calls it the page shows loaded or not (`load-history`) without times.
- **Move.** `(drgnx-settings-move-plan VAR &optional DIRECTION FILE)` decides everything and writes nothing: a refusal
  `(:refused REASON :why TEXT)` or a plan holding both files' texts now and after, VAR's settings.el entry before and
  after, and the value in effect before and after. The checks, in order: the static index finds exactly one setter in
  your Lisp (`drgnx-settings-prov--user-files`); it is top-level and unconditional (a `use-package :custom` entry
  need only be unconditional); its value is a constant settings.el can hold; the value in effect is that value, and
  `drgnx-settings-move--after-into` predicts the same at the next start (a theme over `drgnx` still wins: Customize's
  saved value, a colour theme; the modules' claims merge as the resolver merges them); provenance is certain of that
  file and line. The edit of your file is checked by reading both texts as data: one top-level form differs (or is
  gone), and every other setter stays.
- **Apply and undo.** `drgnx-settings-move-apply PLAN` takes the Lisp file's drgnx lock, refuses when either file
  changed since the plan, keeps a backup (`drgnx-file-backup`), writes the entry with the settings writer and then your
  file with `drgnx-file-write-text` (the entry goes back when that fails), then `drgnx-settings-live-sync`. Move to My
  Lisp then sets the value with its `setopt` when letting go of the entry changed it. The plan is the undo record
  (`drgnx-settings-move--undo`, this session's last 20); `drgnx-settings-move-undo` refuses unless your file is
  exactly what the move wrote and the entry is what it set.
- Tests: `drgnx-settings-move/*` (`test/unit/settings-move-test.el`), `drgnx-settings-lisp-page/*`
  (`test/unit/settings-lisp-page-test.el`), each in a child Emacs. Mutation: with the comparison of the value after
  the move taken out of `drgnx-settings-move--check-value`, `refuses-a-value-change` goes red.

## Tidy custom.el and en/disable-command (Task 30)

`core/drgnx-settings-tidy.el`, autoloaded from `core/drgnx-config.el`.

- **The plan.** `(drgnx-settings-tidy-plan &key remove file)` writes nothing: a refusal `(:refused REASON :why TEXT)`
  or `(:file :old :new :changed :entries :dropped :deduped :removed :undefined)`. It reads `custom-file` with
  `drgnx-file-read-bounded`, its top-level forms with `read` (`read-eval` and `read-circle` off, positions kept), and
  takes the one `custom-set-variables` form's entries `'(VAR VALUE [NOW [REQUESTS [COMMENT]]])` as data. It refuses a
  file that does not read, no such form or several, an entry of another shape, a variable twice, and a comment inside
  the form other than Customize's header lines (printing again would lose it). An entry is dropped when it has no
  comment and its value expression is a constant (self-evaluating or quoted) `equal` to the evaluated `standard-value`
  (as Customize compares). `package-selected-packages` keeps the first of each package. REMOVE may name only
  variables nothing defines (`drgnx-settings-tidy--undefined-p`: not bound, no `standard-value`, `custom-autoload`,
  `custom-type`, not special). The kept entries are printed as `custom-save-variables` prints (sorted by name, the
  four header lines, a value of 60 characters or more on its own line indented by `indent-pp-sexp`) and replace the
  form's text; every other byte stays. The new text is read back: the same top-level forms in the same order, only
  the form changed, holding exactly the kept entries. Nothing reads the session's `saved-value` properties and
  `custom-save-variables` is never called (design §8.4, review M7).
- **Apply and undo.** `drgnx-settings-tidy-apply PLAN` takes custom.el's drgnx lock through
  `drgnx-settings-move--with-lock` (a modified buffer visiting it refuses), refuses when the file changed since the
  plan, keeps a backup (`drgnx-file-backup`) and writes with `drgnx-file-write-text`: `drgnx-file-write` reads its
  text back as one data form, and custom.el holds several forms and code, so the check above stands in for its
  read-back. The record is the plan plus `:bak` (`drgnx-settings-tidy--undo`, this session's last 20);
  `drgnx-settings-tidy-undo` refuses unless the file is exactly what Tidy wrote.
- **Move offers.** `(drgnx-settings-tidy-move-offers PLAN)` → `((VAR . WHY)…)` through `drgnx-settings-move-plan`
  (kind `custom-set-variables`); the command lists them, Move itself stays its own command.
- **en/disable-command.** `core/drgnx-config.el` adds `drgnx-settings-tidy-disable-command` `:around`
  `en/disable-command` at load (it applies when novice.el loads); it binds `user-init-file` to custom.el for the call.
- **Doctor.** The `custom-file` check (group drgnx, fact `:custom-file` from `drgnx-settings-tidy-facts`): INFO with
  the size, entries and dormant entries; no row when custom.el is missing.
- Tests: `drgnx-settings-tidy/*` (`test/unit/settings-tidy-test.el`) and rows C4, C20
  (`test/unit/settings-compat-custom-test.el`), each in a child Emacs. Mutation: with the entries printed from the
  session's `saved-value` in place of the file's form, `keeps-hand-edits-made-since-start` goes red.

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

## Language overrides (Task 10)

`core/drgnx-settings-mode.el` reads the `(:mode M …)` entries of the global `settings.el` (cached per file stamp;
`(drgnx-settings-mode-entries MODE)` -> `((VAR . VALUE)…)`) and `drgnx-settings--apply-mode-overrides` sets them from
`change-major-mode-after-body-hook`, the mode's parents first. A variable's `:set` is called with `buffer-local` as the
third argument only when it is loaded and its `func-arity` accepts three; otherwise `setq-local`. Never `setopt-local`,
never a `load`. Each entry runs under `condition-case`: one message per variable per session. While
`drgnx-settings-own-only-p` holds (safe mode, Turn Off Package Settings, `DRGNX_PACKAGE_SETTINGS=off`; the applier
uses the same predicate), only own settings' overrides apply. The file registers
itself on the hook and on `drgnx-settings-explain-functions` (layer `L1`) when loaded; `core/drgnx.el` requires it
with the other settings files, so the overrides apply from the first buffer on (rows C12 and C21 check it with only
`drgnx` loaded).

## Live changes and `:apply` (Task 13)

`core/drgnx-settings-live.el`. `drgnx-settings-live-start` (idempotent; `drgnx-settings-live-stop` undoes it) watches the
directory of every file in `(drgnx-settings-live-files)` with `file-notify` and adds `drgnx-settings-live--focus` to
`after-focus-change-function`. Both, and the Settings page, end in `(drgnx-settings-live-check &optional FILES)`: a
file is synced only when its `drgnx-file-stamp` is not the one last synced (the inode sees a rename over the file).
`drgnx-settings-live-files` is settings.el plus the workspace files drgnx has read (`drgnx-settings-workspace-files`,
the open projects' W1 and W2); a workspace file read for the first time after the start is watched through
`drgnx-settings-live-watch`. A new workspace file is seen at the next open in its folder.

`(drgnx-settings-live-sync FILE)` for a workspace file calls `drgnx-settings-workspace-sync` (its changes since the
last sync; its roots' open buffers re-hacked when there are any) and runs `drgnx-settings-changed-functions` the same
way. For settings.el it re-runs `drgnx-settings-apply-global` (idempotent), lets go of
variables the applied entries had and the file no longer names (`drgnx-settings-let-go`), calls `drgnx-settings-prov-watch` for the rest, and
runs `drgnx-settings-changed-functions` with FILE and CHANGES, a list of `(SCOPE VAR OLD NEW)` (SCOPE nil for the top
level; `:unset` for an added or removed entry). It returns CHANGES, never signals and never prompts.

`:apply` is called with no arguments, after the variable changed. Every own setting with an `:apply` carries a
variable watcher that only queues the variable; the queue runs on an idle tick through `drgnx-timer` (key
`settings-apply`), once per variable however many changes came. `drgnx-settings-apply-pass` runs at the end of init
for each such setting whose value is not its default and not the one its `:apply` last ran for. Settings declared
after `drgnx-settings-live-start` get their watcher at the next sync.

## The migration and the shim (Task 14)

`core/drgnx-settings-migrate.el` (design §14, §5.4).

- **`drgnx-settings-migrate-table`**: data, `((FILE . KEY) . VAR)` for every schema key of `agents`, `ai`, `keys`,
  `modules`, `large-files` and `session` (`drgnx-AREA-KEY`; `modules :theme` → `drgnx-look-theme`). A new key in one
  of those schemas needs its row: `drgnx-settings-migrate/every-schema-key-has-a-target` fails without it.
  `drgnx-settings-migrate-unset-when-nil` lists the keys whose nil means "not chosen" (`keys :layers`), which get no
  entry.
- **`drgnx-settings-migrate-maybe`** (first in `drgnx-init`, safe mode too) acts only while `settings.el` does not
  exist. It never signals and never prompts. Steps:
  - Each present file is read with `drgnx-config-read`. The definitions are loaded first: the core feature, or
    large-files' module file by its path, defined only for the run.
  - A file stays when it has a problem, unknown keys or a newer format, or when a value cannot be written as data.
  - The text is built by hand: the header, then the entries sorted by name. Each key's comments (the `;` lines
    directly above it, and its end-of-line comment) go above its entry.
  - It is written with `drgnx-file-write-text` under settings.el's lock, only if the file is still absent.
  - The file is read back from disk, and `drgnx-settings-migrate--difference` compares each file's plist
    (`--plist`) with what the entries give (`--assemble`). Any difference deletes the file, and nothing moves. This
    one comparison is the step the mutation check removes: `a-difference-moves-nothing` must go red.
  - Then each file is `copy-file`d to `<state>/backups/migrated-DATE[-N]/` and `rename-file`d to
    `<config>/migrated-DATE[-N]/`. A failed move leaves the file, which is still read.
  - Last: the moved names are re-read, and the report is written to `<state>/settings-migration.eld` (statuses
    `migrated`, `differs`, `exists`, `nothing`), with one notice.
- **The shim:** `drgnx-config-get` calls `(drgnx-settings-migrate-shim NAME STATE)` for a name in
  `drgnx-settings-shim-areas` (in `core/drgnx-config.el`; `drgnx-config` itself never requires the settings files).
  - It returns the plist settings.el's top-level entries give, from the config layer's applied form. While the file
    has a mistake, that is its last good copy, except for `agents` (strict: nothing, so the defaults apply).
  - The keys of an old file that is still there and reads well go over it, so a writer that still writes `keys.eld`
    keeps working until Tasks 15 and 16 move it.
  - With no entry for the area, the old state's value is used: a file that stayed is read as before.
  - Results are cached per area on `eq` of the settings form and the old value.
  - Taking an area out of `drgnx-settings-shim-areas` is how Tasks 15 and 16 retired it; the list is empty now.
- **A file that stayed** (a mistake, unknown keys, a value that is not data, or a copy that came back changed) is no
  longer read once its area left the shim. It never stops applying silently (the design's §14.2 "still read by the
  shim" no longer holds once §14.9 removed the shims): `drgnx-settings-migrate-stayed` gives `((FILE WHY)…)` for the
  old files of retired areas whose plist settings.el does not give, and `drgnx-settings-migrate-maybe` posts one
  notice condition (source `config`, id `settings-stayed`, command Migrate Old Files) at every start while there are
  any, and clears it when there are none.
- **Commands** (registry ids in `drgnx-config-register-commands`): `settings-migration-report`,
  `settings-migrate-old-files` and `settings-move-old-files-away` (only files whose plist settings.el already gives:
  `drgnx-settings-migrate-leftovers`). While `settings.el` exists, Migrate Old Files folds in the stayed files that now
  read cleanly (`--fold-stayed`): their entries are written with `drgnx-settings-area-set` for the settings
  `settings.el` has no entry for (an entry there is never changed), then Move Old Files Away moves the files
  `settings.el` now holds. With nothing to fold it refuses (a `user-error`). Comments of the old file do not move on
  this path.
- **Doctor:** the `settings-migrated` check (facts `:settings-leftovers`, `:settings-stayed`) warns "no longer read"
  naming each stayed file and why, else "already migrated" naming Move Old Files Away; it has no row while neither
  holds.

## Agents, AI and the shipped defaults (Task 15)

`core/drgnx-agents.el`, `core/drgnx-ai.el`, `core/drgnx-settings-defaults.el`, `settings/runtime-defaults.el`.

- **The settings.** `drgnx-agents-{profiles,default,mcp,routes,openrouter,allow-unsandboxed}` are declared with
  `drgnx-defsetting`: `:scope global`, `:workspace never` (so a workspace file's refusal catches them), `:on-error strict`,
  `:agents never`, `:runtime TYPE` (a Rust type name, the list Task 20 checks against `RUNTIME_NAMES`) and a `:schema`
  taken from `drgnx-agents-config-schema`. `drgnx-ai-providers` is `:workspace never`; `drgnx-ai-roles` is
  `:scope project`, `:workspace data` (a project may route roles among your providers); both are `:agents never` and
  `:runtime`, `:on-error last-good`. `drgnx-agents-allow-unsandboxed` is new (nothing reads it before the sandbox
  tasks). The sandbox's `drgnx-sandbox-memory-max`, `drgnx-sandbox-secret-files` (`core/drgnx-sandbox.el`) and
  `drgnx-sandbox-proxy-pinned-addresses` (`core/drgnx-sandbox-proxy.el`) are settings too: `:scope global`,
  `:workspace never`, `:agents never` (design §13).
- **Callers read `default-value`.** `drgnx-agents-profile`, `-profile-names`, `-default-profile`, `-mcp-names`,
  `drgnx-job--routes`, `drgnx-ai-providers` (the function), `drgnx-ai-role` and `drgnx-ai-user-role` read the global
  value, so a buffer-local value (a `.dir-locals.el`, a `setq-local`) never reaches them. Tests bind the variable with
  `let`, which is the global value.
- **Writers.** `drgnx-agents-set-setting KEY VALUE` (KEY `:profiles :default :mcp :routes :openrouter`) and
  `drgnx-ai-set-role ROLE CHAIN` write one entry through `drgnx-settings-defaults-save` (`drgnx-settings-file-put`, then
  `drgnx-settings-live-sync`, so the value applies at once). A settings.el with a mistake is a `drgnx-settings-refused`
  (a `user-error`) and stays as it is.
- **OpenRouter fails closed.** `drgnx-agents-openrouter-restrictions` signals a `user-error` when the config layer
  has a problem with settings.el, or `drgnx-settings-apply-problems` holds one for `drgnx-agents-openrouter`: strict
  would otherwise turn a mistyped restriction into "none".
- **The shipped data.** `settings/runtime-defaults.el` (head `drgnx-settings`) holds `drgnx-ai-presets`,
  `drgnx-ai-default-roles`, `drgnx-agents-builtin-profiles` and the strict default of every `:on-error strict`
  setting. `drgnx-settings-defaults-value VAR` reads it with the data reader (cached per file stamp, never `load`ed);
  the three `defconst`s take their values from it. `test/fixtures/settings/defconsts-before.eld` is the three constants
  as `main` had them: `drgnx-settings-defaults/equal-the-old-defconsts` compares. Ratatoskr embeds the same file
  (Task 20).
- **The old files.** `drgnx-config-define 'agents` and `'ai` stay, for the migration only (it reads the old files
  through them). `agents` and `ai` are out of `drgnx-settings-shim-areas`, so a file that stayed is no longer read.
  The project's `.drgnx/ai.eld` (`ai-project`) is unchanged until the workspace layers fold it in.
- **Batch entry points.** A batch Emacs that loads no init (the hub, `search index`, `search mcp`/`query`, `onboard`)
  calls `drgnx-settings-defaults-apply`: it applies drgnx's own entries of settings.el, so the profiles, routes,
  providers and roles are the user's there too.
- **Tests.** `test/fixtures/runtime-settings-fixture.el`: `drgnx-test-with-runtime-settings` (the eight settings at
  their defaults, a temp config dir, the applier's traces removed afterwards), `drgnx-test-with-runtime-bindings` (no
  config dir), `drgnx-test-runtime-settings-put`, `drgnx-test-write-settings` (a settings.el for a child process).

## Keys, modules, large files and session (Task 16)

The four areas read settings and have left `drgnx-settings-shim-areas`. Their old config definitions (`keys`,
`modules`, `session`, and `large-files` by `drgnx-large-files--define-user-config`) stay for one reason: the migration
reads those files once. Nothing else reads them.

- **Declarations** (all `:scope global`, `:workspace never` except the large-file sizes, `:agents never` for keys,
  modules and theme): `drgnx-keys-{layers,pending-layers,bind,unbind,mac-option,tty-fallback}` (`:apply` re-binds the
  keys; `-layers` also drops the session's stack), `drgnx-modules-{disabled,enabled,flags,external}` (`:apply` is
  `drgnx-modules--settings-apply`), `drgnx-look-theme` (`ui/look`; `:apply` loads the theme while the module runs),
  `drgnx-large-files-{ask-above,chunks-above,chunk-size}` (`:merge lower-only`, read on use) and
  `drgnx-session-keep-running` (read on use; `drgnx-keep-running` is an alias). `docs/reference/settings.md` lists them.
- **`core/drgnx-settings-area.el`** is the one writer the four share. `(drgnx-settings-area-update VARS FN &optional
  ALWAYS)` is a read-modify-write of settings.el under its lock (`drgnx-settings-file--write`): FN gets the current
  `((VAR . VALUE)…)` and returns the values wanted; only differing ones are written (an entry replaced in place, a new
  one at its sorted place), comments and other entries untouched, and `drgnx-settings-apply-global` runs after (owned
  settings only in a process that applied nothing yet). `-set` is the same for known values; `-unset` removes an
  entry and lets go of the value through `drgnx-settings-resolve-apply`, never `drgnx-settings-teardown`, so module
  claims on the variable stay. `-ensure-writable` refuses a file that does not read (and, with VARS, an entry a
  setting refuses). `(drgnx-settings-area-values VARS)` reads the values in this process; in a batch command that has
  applied nothing (`drgnx sync`, `drgnx onboard`) a variable at its standard value takes settings.el's entry (cached
  by the file's stamp; an entry the setting's schema refuses is ignored, as the applier would).
- **Modules.** `drgnx-modules-read-state` and `-update-state` keep their plist API (`:disabled :enabled :flags
  :external [:theme]`) over the settings, so the Modules page, Onboarding, the modal chooser and the package code did not
  change. `-update-state` is atomic across processes. `drgnx-modules--settings-apply` tears down a running module that
  is now disabled (with the modules that need it, deepest first; `restart` modules wait) and starts a module that is
  chosen again once its stage has passed; it is idempotent, so the writers that already stopped or started a module
  cost nothing. `drgnx-pkg-bisect` writes `drgnx-modules-disabled` into the copy's settings.el.
- **Keys.** `drgnx-keys-read-user` builds the old plist from the six settings; `drgnx-keys--save-key` writes one.
  `drgnx-keys-edit` works on a copy of the three lists the editor writes, inside one `drgnx-settings-area-update`; its
  undo record is `<state>/keys-edit.undo` (`:old` per setting: `(VALUE)` or `:absent`, `:new` the values written).
  A comment inside a rewritten list is lost (the settings writer replaces a value whole).
- **Tests.** `test/fixtures/areas-fixture.el` (`drgnx-test-with-areas`, `drgnx-test-areas-put*`,
  `drgnx-test-areas-reset`) gives a temp config with settings.el unapplied and puts the area settings back; a test that
  saves through the writers must use it or `drgnx-test-with-modules`, which does.

## Workspace layers (Task 17)

`core/drgnx-settings-workspace.el` (design §4.1, §4.2, §5.3). `drgnx-settings-live` requires it; it puts itself in
when it loads (`drgnx-settings-workspace-enable`, undone by `-disable`).

- **Two dir-local functions** on `hack-dir-local-get-variables-functions`: W2 (your private
  `<config>/workspaces/<slug>.el`) at depth −90, W1 (the repository's `<root>/.drgnx/settings.el`) at depth 90, so at
  one directory W2 beats `.dir-locals.el` and `.dir-locals.el` beats W1 (P5). Each returns items `(DIR . ALIST)`: one
  for the root (top-level entries and the `(:mode M …)` sections whose M the buffer's mode derives from, the more
  specific mode last) and one per `(:dir "SUB/" …)` section holding the buffer, with DIR `ROOT/SUB/`, so Emacs's sort
  (nearest directory first, `files.el:5066`) and its duplicate filter decide between them and `.dir-locals.el` files
  (D2). Emacs applies an item's alist from its end; the alist is built reversed so that values apply first and an
  `(:eval F…)` section (as `(eval . (progn F…))`) after them. W2 is matched by root (the longest of a file's `:roots`
  holding the buffer's directory, truenames), W1 by `locate-dominating-file`. Remote buffers get neither.
- **No prompt for drgnx's items.** Each item's DIR is a fresh string kept in a weak `eq` table. The `:around` advice on
  `hack-local-variables-filter` binds `enable-local-variables` to `:all` for a call whose DIR is one of them, only
  while it is t. `:safe` and nil are Emacs's own (with nil Emacs runs no dir-local function, `files.el:5052`);
  `enable-local-eval` is never bound; nothing reaches `safe-local-variable-values` or
  `safe-local-variable-directories`. The mutation check (bind `:all` for every call) must turn
  `drgnx-settings-workspace/safe-gives-safe-values-only` red.
- **Refusals** (`drgnx-settings-workspace-problems FILE`, one notice condition per file): an entry of a `:scope
  global` setting, of a `:workspace never` setting (`drgnx-setting-meta`, which holds the deny-list of design §13), and
  the pseudo-variables `eval` and `mode`. `:scope project` entries are never buffer values.
- **W1's filter:** `drgnx-settings-workspace-filter-function`, called with ROOT, FILE and the entries left after the
  refusals, returns those to apply; the default `drgnx-settings-workspace-safe-only` passes `safe-local-variable-p`
  values and never an `:eval`. Task 18 replaces it with the trust split.
- **`(drgnx-setting-for-root VAR ROOT)`**: the global value, then W1 (the old `.drgnx/{search,ai,large-files}.eld`
  through the config layer, `drgnx-settings-workspace-old-files`, then `.drgnx/settings.el`'s filtered entries), then
  W2, each over the one below by its `:merge` (`replace`, `alist`, `append`, `lower-only`: the lower of two numbers,
  anything else keeps the lower layer). `drgnx-search-config` reads `drgnx-search-{include,exclude,off}` this way.
- **`(drgnx-settings-workspace-file ROOT &optional CREATE)`**: by root, else by `:project` through
  `drgnx-settings-workspace-project`, which returns nil until the Urdr gate (matching a moved folder by its project id
  is a post-gate row). CREATE writes `<slug>.el` (then `-2`, `-3` …) under the file's lock, with `:roots` and
  `:project` when known.
- **Re-hack:** `(drgnx-settings-workspace-rehack ROOT)` resets each buffer's `dir-local-variables-alist`, runs
  `hack-dir-local-variables` (Emacs's own items under `:safe` meanwhile, so it never prompts) and
  `hack-local-variables-apply` without the major mode and without `mode` entries; the file's own local variables
  keep winning; a value no source gives any more is killed while it is still the value that source gave.
- **Explain:** `drgnx-settings-workspace--layers` on `drgnx-settings-explain-functions` gives the W2, W1,
  `.dir-locals.el`/`.dir-locals-2.el` (nearest folder, with the line) and EditorConfig layers of a dir-local value.
  `drgnx-settings-prov` counts a `file-local-variables-alist` value as file-local only when it is not the dir-local
  value Emacs applied.
- **Docs cache:** workspace docs by file and stamp, at most `drgnx-settings-workspace-cache-max` files.
