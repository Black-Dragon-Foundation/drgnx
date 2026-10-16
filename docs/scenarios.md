# Scenarios

Behaviour scenarios state how drgnx's UI must behave — VS Code is the reference — and run inside a harness
session of a configuration: `bin/drgnx test --scenario [--config drgnx|gryphn|DIR]` (see
[harness.md](harness.md#scenario-tier)). They were first run against **gryphn**, the Emacs layer drgnx grows out
of, to turn its known UI problems into evidence. Those that fail there are listed as known reds in
`test/scenario/known-red.eld`; the workbench (M3) must make every one of them pass on drgnx. No fixes go into
the gryphn layer.

Each red below is quoted from its trace (times from the start of the measurement; `wN` are window ids).

## Explorer (file tree)

| Scenario | Expected (VS Code) | gryphn | Why (trace) |
|---|---|---|---|
| `explorer-click-stays` | a single click on a folder keeps the selection on it | **red** | `treemacs-leftclick-action` moves the selection to the folder (point 55 → 30); 155 ms later `timer:gryphn-workspace--on-change` — the Explorer follow — moves it back to the editor's file (30 → 55) |
| `explorer-follow-override` | with the follow switched off, `explorer-click-stays` passes | green | **confirms H1**: the follow is the cause |
| `explorer-expand-stays` | a double click expands the folder; selection and view stay | **red** | the folder expands, then `timer:gryphn-workspace--on-change` moves the selection to the editor's file (+316 ms) |
| `explorer-hold-is-a-click` | press, hold 300 ms, release without moving: a click on that row | **red** | the tree changes under the held button (point 55 → 86, process output), the follow moves the selection back (+172 ms), and the release arrives as **`drag-mouse-1`** — the mechanism by which a click once moved a folder (with drag-to-move on, a drag moves files) |
| `explorer-keys-stay` | `n n` moves the selection two rows and it stays there | **red** | the two `treemacs-next-line` commands move it; ~650 ms later `timer:gryphn-workspace--on-change` moves it back to the editor's file — even without any other activity |
| `explorer-keys-then-background-event` | a buffer created in the background (an agent or status poll) does not move the selection | **red** | one background buffer event re-arms the follow; `timer:gryphn-workspace--on-change` moves the selection back 213 ms later |
| `explorer-keys-during-churn` | keys move the selection while buffers come and go every 100 ms | green | continuous churn keeps re-arming the follow's 0.15 s debounce, so it never fires *during* churn — it snaps back once churn stops (see the two scenarios above) |
| `explorer-cross-project-keeps-root` | opening a file of another project keeps the Explorer's root | **red** | two followers react: `timer:treemacs--follow` (treemacs' own follow mode) selects and moves the tree, then `timer:gryphn-workspace--on-change` replaces the root with the other project; on the way, the "Now showing" message grows the echo area 20 → 40 px and every window shrinks by 20 px |

## Buffers panel (open editors)

| Scenario | Expected (VS Code) | gryphn | Why (trace) |
|---|---|---|---|
| `buffers-header-survives-refresh` | the panel shows its header line and keeps it | **red** | the header is 0 px: `header-line-format` is set to nil by `ibuffer-update ← gryphn-workspace-refresh-now ← gryphn-workspace--on-change` (a variable watcher caught the call chain) |
| `buffers-scroll-kept` | a scrolled panel stays scrolled when another file is opened | **red** | `timer:gryphn-workspace--on-change` resets the panel's `window-start` (392 → 1) on every refresh; the top row goes from `file09.txt` to `main.py` |
| `buffers-close-hits-row` | × on a row closes that row's buffer, even if another file was opened just before | **red** | opening another file re-sorts the rows by recency, so the × the user aimed at `README.md` now belongs to `guide.md`, and `gryphn-workspace-buffers-close-at-mouse` closes that |

## New frames

The reported 2.1 s for a new frame does **not** reproduce in an isolated session: in a gryphn daemon session,
`emacsclient -c` makes the first frame visible after 519 ms (`make-frame` 324 ms, mostly first-GUI-frame setup)
and later ones after 360–400 ms (`spacious-padding` up to 55 ms). The gryphn configuration alone is therefore
not what makes frames slow; the cause is state the harness leaves out on purpose (saved workspace layouts
restored per frame, many open buffers, language servers, the real display's scale). Measuring it needs the live
session and is left for the user to authorise.

## Hypotheses — outcome

- **H1** (the follow snaps the Explorer back after a click) — confirmed on screen, and by the override
  experiment.
- **H2** (background buffer activity re-triggers the follow) — confirmed for single events; for continuous
  churn the opposite holds (the debounce is starved and the follow fires afterwards).
- **H3** (root switching collapses the tree) — confirmed, with two followers involved and echo-area jank.
- **H4** (the Buffers panel is rebuilt on every signal) — confirmed: header wiped, scroll reset, rows re-sorted
  under the pointer.
- **Step 0** (a click turned into a drag that moved files) — the mechanism is reproduced: the release arrives as
  a drag when the tree changes under a held button.
