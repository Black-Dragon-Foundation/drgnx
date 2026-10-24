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

## Importer and views

`ratatoskr graph import-records --root DIR [--only plans|ledgers|deferred|build-board|board] [--dry-run]` (method
`records/import`; `records/status` lists the views). The importer finds `docs/plans/**/*.md` (ledgers end in
`.ledger.md`), `DEFERRED.md` and `BUILD-BOARD.md` under DIR; `board.org` only with `--only board`.

- **Backup first.** Before anything is imported, every file is copied to `<state>/hub/records-backup/<date>/` (a
  second import on the same day gets `<date>-2`, never overwriting). A dry run reads and counts and writes nothing.
- **Pieces.** `saga::import::ops(doc, source)` turns a file into ordered pieces; each piece is one entity
  (`Origin::Imported`, `source = records:<hash of the path>`) whose `body` is the piece's raw text: a plan is its head
  (`plan`), one `task` per task (heading, body and the sections after it) and its tail; a ledger a head and one
  `note` per section; DEFERRED a head, one `todo` per row and a tail; the board a `note` per text or table block;
  `board.org` a head and one `task` per headline. Ids are `<kind>:rec-<hash>-<seq>`, so importing twice changes
  nothing (the second report says 0 operations and adds no `tx` row); pieces that disappeared from the file are
  retired.
- **Views.** `saga::view::render` concatenates the pieces in `seq` order: an unchanged graph renders the imported
  file byte for byte. The hub writes the file back at its path (tmp file + rename) with a one-line header comment,
  which the importer strips.
- **Statuses.** `saga::status::normalize` maps a file's word to the graph's (`open running needs-input in-review
  blocked waiting done dropped`): a DEFERRED row's status text (`fixed in M2` is `done`), an Org keyword (`STARTED`
  is `running`, `CANCELLED` `dropped`; a keyword of the file's own like `BLOCKED` maps by its word), a plan task by
  its ticks. The raw text stays in the piece's body.
- **Views follow the graph.** `Views::flush` first writes each piece's graph status into its text
  (`saga::status::with_status`: a DEFERRED row's status cell, an Org keyword, a plan task's ticks; a text that
  already says it, a row of several lines and a keyword of the file's own are left alone), then rewrites the file.
  The follower (`records::follow`) flushes every view 2 s after the last write of the front's methods; writes by
  agent tools (their own connection) reach the file at the next such write, a `records/proposals` call or an import.
- **A hand edit is a proposal.** When the file differs from what the hub last wrote (or, after a restart, from the
  graph's text), a flush reads it with `saga::proposal::read`: a line diff against the view, one operation per
  changed piece (its new body, and its status when the new text says another), the parts that map to none
  (`unmapped`: a piece whose lines were all deleted; a record is never retired by an edit) and the graph version.
  An inserted line joins the piece before it. The result is a `proposal` entity `proposal:records-<hash>` (one per
  view; status `open`; `data` holds the ops, the base `ver` of every touched record and the edited text; link
  `proposes` to the view's head record). The file stays as edited and is not rewritten while the proposal is open
  (`records/status` shows it as `pending`); a second edit replaces the proposal. Detection happens at a flush (the
  follower, `records/proposals`, an import), there is no file watcher.
- **Deciding.** `records/decide` (the user) or the tool `proposal_decide` (a manager or worker, under the matrix's
  `graph.change`; `proposal_read` shows the diff and ops; an agent reads and decides only proposals about files under its own
  project's root). Accept applies every op in one transaction if each touched
  record still has its base version, else the proposal is `stale` (nothing applied; the file is read again at the
  next flush into a new open proposal); unmapped parts become a `note` related to the record; then the view is
  rewritten. Reject copies the edited text to `<state>/hub/records-backup/<date>-rejected/` (the file's path
  below it) and rewrites the view. A manager cannot accept an op on a user-only field
  (`saga::proposal::USER_ONLY_FIELDS`, now `matrix`: an edited piece with a line `matrix:`); it may reject.
- **Never committed.** The hub runs no git on view files. The files stay modified in the work tree; committing them
  is the user's.
