# The scroll bar and minimap

Every editor and every list drgnx draws has a thin scroll bar at its right edge: the Explorer, Outline, Open, Source
Control, Search results, Problems, the panel's Output and Terminal, the agent transcript, the palette's lists,
Settings, Keyboard Shortcuts, Extensions and the Work views. It is a map as well as a scroll bar.

## The scroll bar

- **The thumb** shows the part of the content the window shows. It is hidden while everything fits; it comes back
  as soon as the content runs past the window, and the text keeps its width either way.
- **Marks** show where things are in the whole file, each kind in its lane:
  - left: lines changed since the last commit (green added, blue changed, red deleted), a run of lines as one bar;
  - right: problems (red errors, yellow warnings, blue notes);
  - left: places an agent edited;
  - middle: search hits while you search (every hit in the file, not only the ones on screen), breakpoints (a dot),
    bookmarks, and, if you turn it on, every use of the symbol under the cursor;
  - In the Problems list, its error and warning rows are marked too.
  - Which kinds show is a setting (`drgnx-marks-kinds`).
- **Lists the hub sends in parts** (a big folder tree in the Explorer, a long result list) take their thumb from the
  whole list, not from the rows loaded so far, so the thumb sits where you are in the whole list.
- **Mouse:** press on the strip to go to that place; drag to scroll with the pointer.
- **In a terminal** the scroll bar is one column at the window's right edge: `┃` over the part shown, `│` elsewhere,
  and `▐` in a mark's colour where a mark falls. Scrolling moves it without running any Lisp.

### Horizontal scroll bar

An editor that cuts its long lines (word wrap `off`, see Editing) gets a thin strip along the bottom of the text
while some line is wider than the window: it starts after the line numbers, lies over the text (nothing moves) and
has only a thumb, no marks. Press on it to jump there; drag the thumb to scroll sideways. Point stays where it is
until you move it.

The sideways wheel, a tilted wheel and Shift with the wheel scroll an editor that cuts its lines. Over a buffer that
wraps them they do nothing, so the buffer keeps wrapping (`C-x <` and `C-x >` still scroll it, and cut its lines, as
in Emacs). Lists that end a long row with `…` get no strip. Turn the strip off with `drgnx-minimap-hstrip`.

## The minimap

Rest the pointer on an editor's scroll bar and it widens into a map of the whole file, drawn over the right edge of
the text (the text does not move): a bar for each line, the part you see as a band, and the names of the file's
definitions, indented by how deeply they nest. The name under the pointer is in the accent colour. MARK sections
are drawn in capitals in the warning colour with a line above: comments such as `// MARK: Parsing`, `// region
Helpers` or `#region`, `#pragma mark`, Lisp `;;;;` headings and `# %%` notebook cells. Click or drag on the map to
go there; move away and it shrinks back after 600 ms.

In a file with a tree-sitter mode, the bars are coloured by what the text is: keywords, function names, types,
strings, comments and constants in your theme's colours for them, everything else in the text colour. The colours
come from the language pack's highlight query, or from the mode's own highlighting rules when the pack has none, and
cover the whole file, including the parts you have never scrolled to.

A pinned region (**Pin Region**, see Editing, "Sticky scroll") shows as a band in its own colour over its lines, with
its name as a label, labels on or off.

Definitions are named for files up to 8 MiB (they come from the same outline as the Outline view); MARK sections
are found in files of any size.

### Peek, problems and describe

Rest the pointer on a row of the minimap for 300 ms and a **peek** opens beside it: the real lines there at full size,
6 of them by default, with the line number and the definition they are in at the top. Press `RET` or click it to go
there. `Esc`, any other key or moving the pointer away closes it. Rest on the marks along the minimap's outer edge
instead and, when the section there has problems, the **problems card** opens in its place. It lists each error and
warning of the innermost foldable block around that row, with their counts; `RET` or a click goes to the one you
choose.

Rest on a definition's name and the echo area says where you are. **Describe Position** (palette; Vim `SPC u d`) says
the same for the cursor: the block around it, its lines, its marks by kind ("2 errors, 1 warning") and the heat
layer's value there. Screen readers such as Emacspeak and speechd-el read the echo area.

### Visited trail

The places you stayed at least 2 seconds, or jumped to (Go to Definition, the next-mark keys, a peek), show as faint
bars at the minimap's left edge, the newest brightest. The last 20 show. The trail is per file and is not saved.
**Clear Visited Trail** (palette) forgets it. After a jump the minimap flashes the row you landed on for 400 ms;
with reduced motion it lights without fading.

### Search, focus and selecting lines

While you search with `C-s` (or `/` in Vim), every match in the file shows on the minimap as a short accent bar at
its column, the one you are on ringed. Big files are scanned a few milliseconds at a time, so typing never waits; a
pattern the fast scanner cannot read (a back-reference, say) is searched the usual way, with the same matches.

**Focus Minimap** (palette; Vim `SPC u M`) keeps the minimap open and gives it the keys:

| Key | Does |
|---|---|
| `j` / `k`, `↓` / `↑` | move one line; the editor follows and the row flashes |
| `/` | search without leaving the minimap |
| `n` / `N` | the next or previous match, with "12 of 87" in the echo area |
| `SPC` | peek at the line |
| `z` | fold or unfold the block there |
| `RET` | go there and leave the minimap |
| `Esc` | leave, the cursor back where it was |

These keys, the peek's (`RET`, `Esc`) and the selection card's below are commands of their own (`minimap-focus-*`,
`minimap-card-*`, `minimap-bucket-*`, `minimap-chip-*`), the same in every key profile; rebind them as any other
(docs/guide/keys.md).

Hold Shift and drag on the minimap to select whole lines. When you let go a small card offers **Copy** (`c`),
**Fold** (`f`), **Pin** (`p`) and **Ask Agent** (`a`, the agent panel's composer with the lines attached).

Rest the pointer on a definition's name on the minimap and its row lights in the Outline. A definition you folded
shows `⋯` after its name in the Outline.

### Huge files

A file of more than 250,000 lines, or one that opened as a large file, has no line map: its minimap is a **density
strip**. Each pixel row is a part of the file, brighter where it holds more text, with a red mark at the edge where
that part has errors and a yellow one where it has warnings. The hub reads the file from disk in the background, so
the strip fills in as it goes (parts not read yet are outlined) and a log that grows is read again. Rest the pointer
on the strip to peek at that part's first lines; `RET` or a click goes there. A file open in chunks places the band at
the chunk's place in the whole file, and a part in another chunk is shown but not jumped to.

What counts as an error or a warning is `drgnx-minimap-density-regexps` (by default lines with `ERROR` or `FATAL`,
and lines with `WARN`), in [Rust regex](https://docs.rs/regex/latest/regex/#syntax) syntax.

### Heat layers

**Minimap Heat Layer…** (palette; Vim `SPC u h`) recolours the bars by one of four things, on a scale from your
theme's border colour (cold) to its second agent colour (hot). Marks stay on top. Choose **None** to go back to the
colours by kind.

| Layer | Hot lines | Where it comes from |
|---|---|---|
| Blame age | the newest (lines not committed yet are hottest) | git's blame of the file, including your unsaved typing |
| Coverage | the covered lines (uncovered ones are cold) | the newest report your test run left at one of `drgnx-minimap-coverage-files`: lcov (`lcov.info`), Cobertura XML (`coverage.xml`) or llvm-cov JSON. A new report is picked up as soon as it is written |
| Profile | the lines with the most samples of their own | a profile you choose: pprof (`.pb.gz`), `perf script -F +srcline` output, or a speedscope `.json` |
| Lines agents read | the lines agents read most | the files agents read, as the Work space's timeline records them |

### Diffs

In a diff (a `*vc-diff*` buffer, a `.patch` file) the bars take the diff's added and removed colours, and each hunk
gets a label such as `hunk 2 · +4 −2`, counted from its lines. In a file with its change marks on, each change against
the last commit is labelled the same way. **Next / Previous Change** go from hunk to hunk there.

## Going from mark to mark

| Command | VS Code | Emacs | Vim |
|---|---|---|---|
| Next / Previous Mark (any kind) | palette | palette | `] k` / `[ k` |
| Next / Previous Problem | `F8` / `S-F8` | palette | `] d` / `[ d` |
| Next / Previous Change | `M-F5` / `M-S-F5` | `C-x v ]` / `C-x v [` | `] c` / `[ c` |
| Next / Previous Bookmark | `C-M-l` / `C-M-j` | palette | `] '` / `[ '` |
| Toggle Bookmark | `C-M-k` | `C-x r m` | `SPC b m` |
| Name Bookmark… | palette | palette | `SPC b M` |
| Go to Bookmark… | palette | `C-x r b` | `SPC RET` |
| Next / Previous Agent Edit | palette | palette | `] a` / `[ a` |

Each goes to the next mark after the current line (or the previous one before it), wraps at the end of the file, and
says where it is in the echo area, for example `error 2 of 7: unused variable, line 41` or `change 3 of 5, line 120`.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `drgnx-minimap-ruler` | on | The scroll bar on every scrollable surface. Off: only buffers with marks of their own (a debugger's breakpoints) show it. |
| `drgnx-minimap-hide-short` | on | Hide the scroll bar while the content fits the window. |
| `drgnx-marks-kinds` | all | The kinds of marks shown and visited: changes, errors, warnings, notes, search hits, breakpoints, bookmarks, symbol uses, agent edits, pinned regions, and any other producer's. |
| `drgnx-minimap-hstrip` | on | The horizontal scroll bar of an editor that cuts its lines. |
| `drgnx-minimap` | on | The scroll bar of an editor widens into the minimap when the pointer rests on it. |
| `drgnx-minimap-width` | 120 | The minimap's width in pixels, 80 to 200. |
| `drgnx-minimap-scale` | 2 | How tall a line is on the minimap, 1 to 3 pixels. |
| `drgnx-minimap-side` | right | The edge of the text the minimap opens over. The scroll bar stays on the right. |
| `drgnx-minimap-sticky` | off | Keep the minimap open. On the right, the text narrows so the minimap covers no code. |
| `drgnx-minimap-labels` | on | Names over the minimap: definitions and MARK sections, MARK sections only, or none. |
| `drgnx-minimap-layer` | none | The heat layer: blame age, coverage, profile, lines agents read, or none. |
| `drgnx-minimap-coverage-files` | `lcov.info`, `coverage/*.info`, `coverage.xml`, `coverage.json`, … | Where coverage reports are, relative to the project (`*` and `?` match in the last part). |
| `drgnx-minimap-mark-regexp` | MARK comments, regions, `;;;;`, `# %%` | Which comment lines are MARK sections: a regular expression in Rust's syntax, matched against each line; the name is its group `name`, else its first group. |
| `drgnx-minimap-peek` | on | Resting on a minimap row opens the peek. |
| `drgnx-minimap-peek-lines` | 6 | How many lines the peek shows. |
| `drgnx-minimap-trail` | on | The visited trail on the minimap. |
| `drgnx-minimap-trail-dwell` | 2 | Seconds the cursor rests on a line before the line joins the trail. |
| `drgnx-minimap-trail-length` | 20 | How many visits the trail shows, 1 to 64. |
| `drgnx-minimap-density-above` | 250000 | Past how many lines the minimap is a density strip. |
| `drgnx-minimap-density-regexps` | `(:error "ERROR\|FATAL" :warning "WARN")` | What the density strip marks as errors and warnings. |
| `drgnx-marks-symbol-uses` | off | Mark every use of the symbol under the cursor, 400 ms after you stop moving. |

Every setting applies at once, to every open window.

The module is `editor/minimap`; turning it off takes every strip away.
