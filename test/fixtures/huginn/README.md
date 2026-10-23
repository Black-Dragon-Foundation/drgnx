# The shared case table for both settings readers

`cases.json` is read by both readers' tests: huginn's (`runtime/crates/huginn`, `read::tests`) and the editor's
(`test/unit/file-test.el`, `drgnx-file/every-case-in-the-shared-table`). Add a case here, never to one side only.

## Rows

```json
{"id": "...", "text": "...", "expect": "accept" | "refuse" | "refuse-rust-only", "dump": [...], "kind": "...", "at": 0}
```

- `id`: unique, stable.
- `text`: the file's text (UTF-8; a case about invalid UTF-8 uses `\u` escapes the test turns into bytes as its
  `id` says: an `id` starting `bytes-` means each character of `text`, all below U+0100, is one byte (U+00FF
  is the byte 0xFF).
- `expect`:
  - `accept`: both readers read it; `dump` is the list of top-level data, each in the format below.
  - `refuse`: both refuse; `kind` is huginn's `RefusalKind` (`ReaderMacro`, `Unibyte`, …) and `at` the byte offset
    where the refused token starts.
  - `refuse-rust-only`: huginn refuses (`kind`, `at`), Emacs reads it. Only the listed divergences: `\N{NAME}`.

## The dump format

One JSON value per datum:

| Datum | Dump |
|---|---|
| integer (a character literal too) | `["int", "<decimal>"]` |
| float | `["float", "<Emacs's prin1 text>"]`, compared by value: `1.0e+INF`, `-1.0e+INF`, any NaN equals any NaN, `-0.0` is not `0.0` |
| string | `["str", "<text>"]` |
| symbol (`nil` and `t` too; a keyword keeps its colon) | `["sym", "<name>"]` |
| proper list | `["list", [ … ]]` |
| dotted list | `["cons", [ … ], <tail>]` |
| vector | `["vec", [ … ]]` |
