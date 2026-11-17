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
- In a terminal frame there is no strip yet (it arrives with the terminal column).

## The minimap

Rest the pointer on an editor's scroll bar and it widens into a map of the whole file, drawn over the right edge of
the text (the text does not move): a bar for each line, the part you see as a band, and the names of the file's
definitions, indented by how deeply they nest. The name under the pointer is in the accent colour. MARK sections
are drawn in capitals in the warning colour with a line above: comments such as `// MARK: Parsing`, `// region
Helpers` or `#region`, `#pragma mark`, Lisp `;;;;` headings and `# %%` notebook cells. Click or drag on the map to
go there; move away and it shrinks back after 600 ms.

Definitions are named for files up to 8 MiB (they come from the same outline as the Outline view); MARK sections
are found in files of any size.

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
| `drgnx-minimap` | on | The scroll bar of an editor widens into the minimap when the pointer rests on it. |
| `drgnx-minimap-width` | 120 | The minimap's width in pixels, 80 to 200. |
| `drgnx-minimap-labels` | on | Names over the minimap: definitions and MARK sections, MARK sections only, or none. |
| `drgnx-minimap-mark-regexp` | MARK comments, regions, `;;;;`, `# %%` | Which comment lines are MARK sections: a regular expression in Rust's syntax, matched against each line; the name is its group `name`, else its first group. |
| `drgnx-marks-symbol-uses` | off | Mark every use of the symbol under the cursor, 400 ms after you stop moving. |

The module is `editor/minimap`; turning it off takes every strip away.
