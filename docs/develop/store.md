# The store (Urdr): `work.db` schema 7

`work.db` holds one knowledge graph across projects: entities and immutable links with transaction-time history,
written by Ratatoskr only. The graph layer is the generic `urdr::graph` (kinds, link names and policy are the
caller's); drgnx's policy, the migration and the tracker are in `norn`. This page is being written: each section
below is filled with the change that builds it.

## Tables (Task 2)

## The writer (Task 1)

## Entities and links (Task 2)

## Guards (Task 2)

## History (Task 3)

## Walks (Task 4)

## Search (Task 5)

## Vectors (Task 12b)

## Readers (Task 6)

## graph/sql (Task 6)

## Backup (Task 7)

## Export and import (Task 7)

## Excise (Task 8)

## The deny-list (Task 9)

`norn::deny` keeps the user's personal notes out of the store (storage §5.6). The denied root is `HOME/org/`; the
one exception is exactly `HOME/org/board.org` (`Verdict::Board`; `board.org.bak` is denied).

- **`DenyList::load(home, config_dir)`** is the only constructor; nothing sets a list's contents (a test reads the
  source to keep it so). The hub keeps the current list in a `SharedDeny` (`Arc<RwLock<Arc<DenyList>>>`): a reload
  replaces it whole, readers take a snapshot.
- **Two tiers.** The hard tier is `HOME/org/notes.org`; under `HOME/org/` at any depth, a file whose name starts with
  `notes`, `journal`, `diary` or `personal` (any case), or anything under a folder so named (`HARD_PATTERNS`); and
  the user's own entries. The soft tier is the rest of `HOME/org/`. `check` tries the hard tier before the opt-ins,
  so an opt-in never lifts it, and a grant never reaches it.
- **The user's entries** come from `<config>/personal-notes-deny.json`: `{"version": 1, "entries": [{"kind":
  "file"|"folder"|"glob", "path": "…"}]}`, `~` expanded, resolved through links. They may name paths outside
  `~/org`, and they cover the board too. A file or folder entry denies the path and everything under it. A glob has
  `*` and `?` in its last part only and also denies everything under a folder it matches. The built-ins cannot be
  removed: the file only adds.
- **The opt-ins** come from `<config>/personal-notes-allow.json`: `{"version": 1, "paths": [...]}`. An entry counts
  only if it resolves to an existing regular file under the denied root; a folder, a glob, a missing file, the
  board or a path outside `~/org` is ignored with a warning. An entry in the hard tier is kept but opens nothing,
  with a warning (Task 9b's notice lists it).
- **Failing closed.** A missing file means none. An opt-in file that is unreadable, malformed or writable by group
  or others opens nothing. A deny file that is unreadable or malformed leaves the built-ins; one writable by group
  or others still applies its entries; a bad entry is skipped. Any of those also drops every opt-in, since what the
  user meant to keep out is not known. Each problem is a warning (`warnings()`, for the doctor).
- **Paths are resolved, never trusted as text.** `check` resolves `..`, doubled slashes, a trailing `/` and links
  with `std::fs::canonicalize` (no `/proc`); a path that does not exist is resolved from its nearest existing parent,
  and a dangling link is followed to its target. A path is denied when its resolved form is, and also when the name
  it was given by is (a link in `~/org` to a file elsewhere). A relative path or a link loop is denied. macOS folds
  case (`cfg(target_os = "macos")`); Linux and Android compare bytes; the hard names fold case everywhere.
- **Every path a record carries.** `paths_of(source, id, data)` gives the source's path (`Source::File`,
  `Source::Spec`), the path inside a path-form id (`spec:`, `plan:`, `file:` whole; `task:`, `step:`, `ruling:`,
  `todo:` cut at the first and at the last `#`), and `data.path`. `check_record` denies a record when any of them is
  denied. `Source::parse` reads schema 6's source strings (`"spec /path"`, `/path`, `commit`, `branch`,
  `recorded`); anything else is `None`, and the door denies the record ("unknown source form").
- **Project roots** (door 3): `check_root` refuses a root inside a denied path, and for a root that contains denied
  paths (`HOME` itself) lists them (`Contains`): `~/org`, the user's file and folder entries, and the names a glob
  matches at that moment.

## The opt-in (Task 9b)

## Scope and grants (Task 10)

## Trust (Task 10)

## Projects (Task 10)

## Migration from schema 6 (Task 11)

## Parsed entities (Task 15a)

## The one-writer gate (Task 18)
