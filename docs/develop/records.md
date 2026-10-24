# Records (saga)

`runtime/crates/saga` reads the record formats of a project's planning folder and writes them back unchanged. It is
pure: strings in, models out, no files and no store.

## Plans and ledgers

- `plan::parse(text) -> PlanDoc` and `plan::render(&PlanDoc) -> String` satisfy `render(parse(t)) == t` for any text.
  Every section keeps its raw heading line and raw body; the parsed fields are views derived from them.
- A **task** starts at a heading `Task N…` at level 2 or 3 (`## Task 5: x`, `### Task 22b: y`). The number keeps its
  letter suffix (`22b`). A task runs to the next heading that is a task, has level 1 or 2, or is not deeper than the
  task; deeper headings stay in its body. Headings inside code fences are not headings.
- Sections that are not tasks go to `preamble` (before the first task), to the preceding task's `after` (between
  tasks, e.g. `# Wave B`) or to `rest` (after the last task). `waves` is the first table of a section titled `Waves…`.
- From a task body: `model` (`**Model:**`, up to ` · ` or ` (`), `files` (backtick spans of the `**Files:**`
  paragraph), `interfaces` (the `**Interfaces:**` block up to the first step or next `**Label:**`), `steps`
  (`- [ ]`/`- [x]` lines with their indented continuation lines). `body_span` is the body's byte range in the parsed text.
- `TaskDoc::set_body` replaces one task's body and re-derives its fields; rendering changes nothing else.
- `ledger::parse(text) -> LedgerDoc { header, sections }` splits at the same boundaries; a section's `task` is the
  first `Task N` its heading mentions (`## Library evaluation (Task 5 step 1)` -> `5`).

Headings and tables come from pulldown-cmark's offset iterator (`saga::md`); the text is always sliced from the source,
never regenerated, which is what keeps it byte-exact.

## DEFERRED, the build board and `board.org`

- `table` cuts GFM pipe tables out of the text line by line (`md::tables` flattens inline markup, so it is not used
  here). A table is a `|` header line, a separator line and the following `|` lines; an indented line after a row
  continues that row, so a row longer than one line is kept as written. Cells split at `|` unless written `\|`;
  cell text is trimmed but keeps its markup and escapes. Fenced code is skipped. Rows carry `raw` and a byte `span`.
- `deferred::parse(text) -> DeferredDoc { preamble, rows, rest }`: the register is the first table with four columns
  starting `#`/`id` (`| # | Area | Item | Status |`). `preamble` runs up to the separator line, `rest` is everything
  after the register's rows (other tables included). Each `DeferredRow` has `id`, `area`, `text`, `status` (raw
  cells), `span` and `raw`; `deferred::render` joins the pieces back unchanged.
- `board_md::parse(text) -> BoardDoc { blocks }`: text and table blocks in order. `tables()` lists the tables,
  `table_mut(first_header_cell)` finds one to replace its rows; prose stays untouched.
- `org::parse(text) -> OrgDoc { preamble, items }`: an item is a headline (`*`s at column 0) with `level`, `keyword`,
  `title`, `tags` and `properties` (the `:PROPERTIES:` drawer at the start of the body, after an optional planning
  line). `body` and `heading` hold the text as written, so planning lines, logbooks, source blocks and anything the
  parser does not know are kept. Keywords: the Org defaults, `NEXT STARTED WAITING HOLD REVIEW CANCELLED CANCELED`
  and any `#+TODO:` words of the preamble.

All four satisfy `render(parse(t)) == t`. A 1600-row register parses in well under 50 ms.
