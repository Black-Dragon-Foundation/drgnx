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

## Adopting and keeping in step

`ratatoskr graph import-records --root DIR [--only specs|plans|ledgers|decisions|deferred|build-board|board]
[--dry-run]` (method `records/import`; `records/status` lists the files and their conflicted records). The importer
finds `docs/specs/**/*.md`, `docs/plans/**/*.md` (ledgers end in `.ledger.md`), `docs/decisions/**/*.md`,
`docs/adr/**/*.md`, `DEFERRED.md` and `BUILD-BOARD.md` under DIR; `board.org` only with `--only board`.

- **Backup first.** Before anything is imported, every file is copied to `<state>/hub/records-backup/<date>/` (a
  second import on the same day gets `<date>-2`, never overwriting); the first adoption of a file also copies the graph
  store there (`work.db`, `vacuum into`). A dry run reads and counts and writes nothing.
- **The notice.** A file's first adoption sends `records-notice {root, files, backup}` (the editor shows it once) and
  then marks the file adopted (`kv` `records-adopted:PATH`); no file is rewritten before its mark (a sync says
  `Waiting`). Adoption itself writes no byte: an unchanged graph renders the file as it is.
- **Pieces.** `saga::import::ops(doc, source)` turns a file into ordered pieces; each piece is one entity
  (`Origin::Imported`, `source = records:<hash of the path>`) whose `body` is the piece's raw text: a plan is its head
  (`plan`), one `task` per task (heading, body and the sections after it) and its tail; a ledger a head and one
  `note` per section; DEFERRED prose pieces (a head first) and one `todo` per row of every four-cell register table (`#`/`id` first, `status`/`state` last) and per `### <ID> — title` entry (role `entry`, status the first word of its `- **Status:**` bullet); the board a `note` per text or table block;
  `board.org` a head and one `task` per headline; a spec (`docs/specs/**`) or a decision record (`docs/decisions/**`,
  `docs/adr/**`) is one `spec` or `decision` piece, the whole file (`saga::spec`: title from the first `# ` heading,
  status from a `**Status:**` line or MADR front matter, `approved`/`accepted` read as `done`, headings kept as
  anchors). Each piece has a **key**, what it is in its file and unique there (`head`, `rest`, `row 12`, `entry
  R6-KI-3`, `task 5`, `section Done`; a repeated key gets ` #2`), and its id is `<kind>:rec-<hash of the path>-<hash
  of the key>`: importing twice changes nothing (the second report says 0 operations and adds no `tx` row), a row
  added in the middle leaves every other piece's id alone, and pieces that disappeared from the file are retired.
- **Links.** `saga::links::links(text, file, root, known)` reads a record file's links to other records from its own
  text: a relative markdown link or a backtick path naming a record is `relates`; a plan's `**Spec:**` line (or its
  first link to a spec) is `derives`; `X.ledger.md` relates to `X.md`; an ADR's link on a line saying `Supersedes` is
  `supersedes`. Links inside code fences, to files that are not records, or out of the root are dropped.
- **The merge.** `saga::merge::merge(file, base, live)` is the three-way merge of a view with the graph, piece by
  piece: FILE is the file's pieces now, BASE what the hub last wrote or read of each (the digests of its last texts,
  newest first), LIVE the graph's pieces in order. A piece changed on one side takes that side; changed on both to
  different text, or changed in the file back to an older text of the base (a stale editor save), or changed in a
  user-only field (`saga::merge::USER_ONLY_FIELDS`), keeps the file's text and is flagged (`Act::Conflict`); a
  piece new in the file is created, one deleted from it retired (flagged when the graph changed it meanwhile); a
  piece new in the graph is placed after its neighbour. An unchanged graph and file render the file byte for byte.
- **Views.** `saga::view::render` concatenates the pieces in `seq` order: an unchanged graph renders the imported
  file byte for byte. The hub writes no header; a file still carrying the old view header loses it at its next write.
- **Statuses.** `saga::status::normalize` maps a file's word to the graph's (`open running needs-input in-review
  blocked waiting done dropped`): a DEFERRED row's or entry's first status word (`saga::status::normalize_deferred`: `open` is open, `fixed closed done decided mitigated` are `done`, `dropped moot` `dropped`, any other word like `moved` or `kept` stays `open`; `fixed in M2` is `done`), an Org keyword (`STARTED`
  is `running`, `CANCELLED` `dropped`; a keyword of the file's own like `BLOCKED` maps by its word), a plan task by
  its ticks. The raw text stays in the piece's body.
- **Keeping in step: `Views::sync(path)`.** One function for both directions, under a lock per file. It first writes
  each piece's graph status into its text (`saga::status::with_status`: a DEFERRED row's status/state cell or an
  entry's `Status:` bullet word, an Org keyword, a plan task's ticks; a text that already says it, a row of several
  lines and a keyword of the file's own are left alone). Then it reads the file, parses it, keeps the graph's id for a
  piece the graph knows by an older id with the same text (`align`: records adopted before the ids were keyed), and
  merges it with the graph's pieces against the **base** (`saga::merge`, above): the base is, per piece, the digests
  of the last 8 texts the hub wrote or read (`kv` `records-base:PATH`, kept in memory too). The merge's acts go into
  one transaction (file edits update records, new pieces are created, deleted ones retired, both-changed ones get
  `data.records.conflict {file, at}`, and pieces take the merge's order as `seq`); then, when the merged text differs,
  the file is read again and, if it changed meanwhile, the merge starts over (3 times, then the file is `busy` until
  the next change); else the text is written (tmp file, `fsync`, rename). The base becomes what was written, except
  for conflicted pieces, which keep theirs, so they stay flagged and the file keeps its text.
- **When it runs.** The follower (`records::follow`) syncs every file 300 ms after the last write of the front's
  methods; `records/status` and an import sync too. Newly flagged records are sent as `records-conflict {path, ids}`.
- **Resolving.** `records/resolve {id, keep: file|graph}` (the user) or the tool `record_conflict_resolve` (a manager
  or worker, under the matrix's `graph.change`, only for files under its own project's root; `record_conflict_read` /
  `records/conflict` show both versions). `file`: the file's text becomes the record's (its status read from it);
  `graph`: the base takes the file's text, so the next sync sees only the graph changed and writes the graph's version
  back. Either clears the flag. An agent never keeps a file's change to a user-only field (`saga::merge::USER_ONLY_FIELDS`,
  now `matrix`); the user may.
- **Never committed.** The hub runs no git on view files. The files stay modified in the work tree; committing them
  is the user's.

## Comment anchors

A paragraph comment's thread (hub.md, "Paragraph comments") keeps where it sits as its `comments_on` link's data,
`{heading, key, quote, state}`, and finds its place again each time the record's file syncs.

- **Paragraphs.** The record's text (its file, the view header left out; a record with no file, its body) splits into
  paragraphs: runs of non-blank lines, a fenced block as one. Heading lines are not paragraphs; each paragraph carries
  the headings above it, outermost first.
- **Key and quote.** The key is 16 hex digits of the SHA-256 of the paragraph's text with its whitespace folded, so a
  reflow keeps it. The quote is that folded text, cut at 200 characters. `comments/add` finds the paragraph by `key`,
  or by `quote` (the first paragraph whose text holds it); a comment on no paragraph is refused.
- **Re-anchoring.** After each sync of a file (`Views::sync`), every thread on its records is aligned again
  (`work::comments::realign`):
  - by key: as it was (`here` or `moved`; a `removed` thread whose paragraph is back is `here`);
  - else the paragraph most like the quote by words (`similar`'s word ratio, at least 0.4; under the same headings
    on a tie): `moved`, with that paragraph's key, quote and headings;
  - else `removed`, with the quote, key and headings kept.

  A changed anchor retires the link and makes it again, so the link's history keeps each place. A thread is never
  dropped.
