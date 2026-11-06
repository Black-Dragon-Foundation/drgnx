# The look

How drgnx looks, and how to change it. The module `ui/look` ([modules](modules.md)) draws the colours, the type, the
density and the icons. Everything here is a setting: change it in the settings page or in `settings.el`, and it
applies at once to every frame, with no restart.

## Colours and themes

drgnx ships three themes, all generated from one table of colours: **drgnx Dark**, **drgnx Light** and **drgnx High
Contrast**. Load one like any Emacs theme (`M-x load-theme`, or Preferences: Color Theme); they are found without any
setup.

### What a theme paints

- **Surfaces.** The editor is `default`. Beside it are the gap behind the cards and the bars (`drgnx-surface-gap`), the
  side panels (`drgnx-surface-panel`), raised things such as chips and the current tab (`drgnx-surface-raised`) and
  popups (`drgnx-surface-overlay`). In the dark theme the gap is darker than the editor; in the light theme it is
  darker than the white editor, so the cards read as depth.
- **Text.** Body text is `default`; secondary, tertiary and unavailable text are `drgnx-text-muted`, `-subtle` and
  `-disabled`.
- **Syntax and the rest.** Every `font-lock-*` face, the mode and header lines, tabs, dividers, search, completion,
  diffs, version-control state, diagnostics and the language server's faces, `outline-1` to `outline-8` (colour only,
  no size change) and the terminal's sixteen `ansi-color-*` colours come from the same table, so a package that
  inherits standard faces looks right with no work of its own.
- **Native title strip.** `nidhogg-title-bar` and `nidhogg-title-bar-inactive` follow the theme.

### The three variants

| | Dark | Light | High Contrast |
|---|---|---|---|
| Selection | blue-grey | pale blue | deep blue, text on it is white |
| Tints (status chips, diff lines) | 11 to 15 % of the status colour | 8 to 14 % | none |

High Contrast has no tints and no shadow faces; every text pair is at least 7:1.

### Terminals

On a terminal with 256 colours or fewer, the gap, the editor and the panel are one colour: the cards are drawn by the
vertical border instead.

### For theme authors

A theme of your own can set any of the semantic faces listed in [The face](face.md) ("Faces for theme authors"). The
token table is `themes/drgnx-tokens.eld`; `(drgnx-look-token 'panel)` reads a token of the active variant, and
`(drgnx-look-variant)` says which variant is on (`dark`, `light` or `hc`).

## Fonts

Every piece of text has a **role**, and every role is one setting holding a plist:

| Setting | What it sets | Default |
| --- | --- | --- |
| `drgnx-look-font-code` | code, and everything that must line up | JetBrains Mono, 13.5 px, 21 px lines |
| `drgnx-look-font-ui` | tabs, status bar, lists, the palette's candidates, notices | Adwaita Sans, 13 px |
| `drgnx-look-font-ui-heading` | panel titles and section heads | the UI font, semibold |
| `drgnx-look-font-ui-caption` | the status bar, meta text, the tree's end column | the UI font, 12 px |
| `drgnx-look-font-title` | the start page's and the reviews' headings | the UI font, 17 px, semibold |
| `drgnx-look-font-code-small` | diffs and output inside cards | the code font, 12 px, 19 px lines |
| `drgnx-look-font-agent` | the agent panel's prose | the UI font |
| `drgnx-look-font-terminal` | the terminal's text | the code font |

A role's plist has these keys, and you give only the ones you want to change:

- `:family` a family name, or `ui` / `code` for "the same as that role";
- `:fallback` families to try, in order, when the family is not installed;
- `:size` a **ratio to the code size** (1.0 is the code size, 13.5 px), so zooming (`View: Zoom In`) scales every role
  together; 13 px is 0.963, and a size typed on the settings page as pixels is stored as that ratio;
- `:weight` a weight name such as `regular`, `semibold` or `bold`;
- `:line-height` (the code roles) pixels per line;
- `:ligatures` (the code role) `t` or `nil`.

```elisp
;; settings.el
(drgnx-look-font-code (:family "Iosevka" :size 1.05))
(drgnx-look-font-ui (:family "Inter" :fallback ("sans-serif")))
(drgnx-look-font-terminal follow-desktop)          ; the desktop's monospace font
```

`follow-desktop` as a whole value makes the role take the desktop's font (GNOME's interface and monospace fonts). It is
opt-in per role and is never the default.

### Where a value comes from

When several places name a font for a role, the first match wins:

1. **Your Lisp and Customize.** A `custom-set-faces` entry in `custom.el`, or a `set-face-attribute` on a role face
   in `config.el`. drgnx then leaves that face alone, and the settings page says where the value is set
   (`config.el:31`, `custom.el:9`). A theme load wipes `set-face-attribute`, so drgnx puts your attributes back after
   every theme change.
2. **A per-mode override**, a `(:mode MODE ...)` section of `settings.el` (for example Org's prose in the UI font).
3. **The setting.**
4. **The theme.** A theme may name fonts for the role faces.
5. **The desktop**, only for roles set to `follow-desktop`.
6. **drgnx's defaults** (the table above).

A setting changes only the attributes you set; the theme's other attributes show through. A family that is not
installed falls back down its `:fallback` list, then to the generic family.

Terminal frames ignore families and sizes and keep only the weight.

### Per-mode overrides

A `(:mode MODE ...)` section of `settings.el` gives one mode another font, for example Org's prose in the UI font:

```elisp
(:mode org-mode
 (drgnx-look-font-code (:family ui :size 1.05)))
```

drgnx installs a remap of the role's faces in each buffer of that mode (after the mode starts, and again when the
setting changes) and removes it when the override goes. Buffers without an override get nothing, so they stay on
Emacs's fast paths for the default face.

### Live changes

A change applies at once to every frame. The settings page waits 300 ms after the last change of a role before it
redraws, so a size slider or typed digits do not redraw on every key.

### Ligatures

`:ligatures t` on the code role installs composition rules for the usual programming sequences (`->`, `=>`, `!=`,
`<=`, `::` and so on); `nil` takes them away. They only show with a font that has the ligatures: the default prefers
the `-nl` build of JetBrains Mono, which has none, so turning them on also means installing the regular build.
The rules are global (they are Emacs's composition table), and turning the module off gives the table back.

### Missing fonts

[`drgnx doctor`](install.md#fonts) names each role whose family is not installed, the family it fell back to and the
package to install.

The role faces are `drgnx-ui-text`, `drgnx-ui-heading`, `drgnx-ui-caption`, `drgnx-ui-title`, `drgnx-code-small`,
`drgnx-agent-prose` and `drgnx-terminal`; the code role is the `default` and `fixed-pitch` faces and the UI role also
sets `variable-pitch`. Their specs hold `:family`, `:height` (relative) and `:weight` only, never `:font`.

## Density

`drgnx-look-density` is `compact`, `comfortable` (the default) or `roomy`, and applies at once. Sizes are logical
pixels (a frame at scale 2 draws twice as many):

| Thing | Compact | Comfortable | Roomy |
| --- | --- | --- | --- |
| Code line | 19 | 21 | 23 |
| Tree and list row | 22 | 26 | 30 |
| Tab row | 30 | 34 | 38 |
| Status bar | 22 | 24 | 28 |
| Title row | 34 | 38 | 42 |
| Gap between cards, outer gap | 4 | 6 | 8 |
| Panel padding | 8 | 12 | 16 |
| Tree indent | 12 | 12 | 14 |

**The code line** is the frame's `line-spacing` parameter, worked out in device pixels (the line less the font's own
height) for every frame, and again when the frame is resized, its scale changes or the code font changes. Who decides,
first match: the `:line-height` you set on `drgnx-look-font-code`, then the density. A `line-spacing` you set
yourself (`setq-default`) stays: drgnx then leaves the frames alone. `drgnx-face-line-spacing` is obsolete (use the
code role's `:line-height`); while it is set it still wins, as a default `line-spacing`.

## Icons

drgnx draws its marks with [Lucide](https://lucide.dev) line icons: tree rows, tab leading icons, panel headers, the
status bar, the palette's rows, the agent panel's steps and notices (never inside code). About 60 SVG files sit in
`etc/icons/`, each drawn with `currentColor`, so an icon takes the colour of the text around it: in a
`drgnx-text-subtle` run it is subtle, in any theme, and no colour is written in the files. They are 16 px (14 px in
dense rows) with a 1.6 px stroke at any size.

`drgnx-look-icons` chooses how they are drawn:

- `svg` (the default): the line icons, on graphical frames;
- `glyphs`: the characters of the glyph table `drgnx-face-glyphs` (`⑂ ⚠ ✓ ◎ ● ×` and so on; every icon has a glyph
  of the same name), which is also what a terminal frame always shows.

A change applies to the icons drawn from then on.

For code, `(drgnx-look-icon 'folder 'shadow)` is the string for the icon `folder` in the face `shadow` (the optional
third argument is the size), and `(drgnx-look-file-icon "main.rs")` is the icon of a file's kind: code, text, config,
image, archive, or a plain file, and a folder (open or closed) for a directory. The kind comes from the file name,
then from the major mode in `auto-mode-alist`; there are no per-language logos.

The icons are from Lucide (ISC licence) and a few from Feather (MIT licence); both notices are in `etc/icons/`
(`LICENSE-lucide`, `LICENSE-feather`) and must stay with the icons in any copy.
