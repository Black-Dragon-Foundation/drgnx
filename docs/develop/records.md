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
