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

## Going from mark to mark

| Command | VS Code | Emacs | Vim |
|---|---|---|---|
| Next / Previous Mark (any kind) | palette | palette | `] k` / `[ k` |
| Next / Previous Problem | `F8` / `S-F8` | palette | `] d` / `[ d` |
| Next / Previous Change | `M-F5` / `M-S-F5` | `C-x v ]` / `C-x v [` | `] c` / `[ c` |
| Next / Previous Bookmark | `C-M-l` / `C-M-j` | palette | `] '` / `[ '` |
| Next / Previous Agent Edit | palette | palette | `] a` / `[ a` |

Each goes to the next mark after the current line (or the previous one before it), wraps at the end of the file, and
says where it is in the echo area, for example `error 2 of 7: unused variable, line 41` or `change 3 of 5, line 120`.

## Settings

| Setting | Default | What it does |
|---|---|---|
| `drgnx-minimap-ruler` | on | The scroll bar on every scrollable surface. Off: only buffers with marks of their own (a debugger's breakpoints) show it. |
| `drgnx-minimap-hide-short` | on | Hide the scroll bar while the content fits the window. |
| `drgnx-marks-kinds` | all | The kinds of marks shown and visited: changes, errors, warnings, notes, search hits, breakpoints, bookmarks, symbol uses, agent edits, pinned regions, and any other producer's. |
| `drgnx-marks-symbol-uses` | off | Mark every use of the symbol under the cursor, 400 ms after you stop moving. |

The module is `editor/minimap`; turning it off takes every strip away.
