# Settings (contributors)

How drgnx's settings work inside: the files, the layers and how they are applied, and the two readers that read them.
The user's side is [docs/guide/settings.md](../guide/settings.md) (once it exists).

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
