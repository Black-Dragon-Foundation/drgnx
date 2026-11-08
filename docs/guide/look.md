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

### Following the desktop

The setting `drgnx-look-theme` is `auto` by default: drgnx Dark, Light or High Contrast, as your desktop says (through
its settings portal; on macOS, the system appearance).

| The desktop says | Theme |
|---|---|
| Contrast: more | High Contrast |
| Dark | Dark |
| Light, or no preference | Light |
| Nothing (no portal, or it has not answered yet) | Dark |

The portal is read in the background and never waited for, so the first frame is drawn at once in Dark and the theme
switches when the answer comes, and again whenever you change the desktop's setting. A theme you choose yourself
(Color Theme, `load-theme` in `config.el`, a package), drgnx's own three included, switches `auto` off for the
session, and one notice says so ("Theme follows the desktop: paused while modus-vivendi is on"); drgnx never replaces
it. To keep one theme, pick it with Color Theme; set `drgnx-look-theme` to `nil` to keep Emacs's own colours.

The first time drgnx starts with `auto` because your `settings.el` named no theme, one notice says "drgnx now has its
own themes; Color Theme picks another". It is shown once.

`drgnx-look-accent` is `system` by default: the accent and the focus ring take the accent colour the desktop gives,
made lighter on a dark theme and darker on a light one until it reads at 4.5:1 as text (7:1 under High Contrast).
Set it to `theme` for the theme's own accent.

### Terminals

On a terminal with 256 colours or fewer, the gap, the editor and the panel are one colour: the cards are drawn by the
vertical border instead. On every terminal (true colour too) drgnx's themes draw the selection in inverse video
rather than in the selection colour, which a terminal can barely tell from the editor's.

### For theme authors

A theme of your own can set any of the semantic faces listed in [The face](face.md) ("Faces for theme authors"). The
token table is `themes/drgnx-tokens.eld`; `(drgnx-look-token 'panel)` reads a token of the active variant, and
`(drgnx-look-variant)` says which variant is on (`dark`, `light` or `hc`).

### Under another theme

With a theme that is not drgnx's (modus, leuven, Doom One, your own), the semantic faces that have no standard face
to inherit get colours worked out from the theme, when ui/look turns on and every time a theme is enabled or disabled
or the first graphical frame of a daemon appears:

- **Surfaces.** The panel is the editor colour moved 3 % toward the text colour. On a dark theme the gap is the editor
  moved toward black, on a light theme toward the text colour, only as far as the panel needs to stand out from it
  (1.10:1 dark, 1.20:1 light); on a black editor the gap stays black and the panel moves on instead. Raised, popups and
  the quiet selection are the panel moved another 3 %.
- **Text.** Muted and subtle text take the theme's `shadow` colour, moved toward the text colour until it reads at 4.5:1
  on the editor, the panel and raised surfaces.
- **Accent and focus.** Both take the colour of `link`; the hidden control takes the panel colour.
- **Agents.** Agents 1 to 6 take the foregrounds of the function, keyword, string, type, constant and builtin faces,
  each only if it is at least 30 degrees of hue and a delta E of 15 away from the others and from the cursor (a grey
  has no hue to compare); otherwise drgnx's own colour for that agent stands.
- **More agents.** Each of the six also gets a variant of the same hue, 0.13 lighter on a dark theme and darker on a light
  one (`drgnx-agent-7` to `drgnx-agent-12`), kept only if it reads at 3:1 on the editor and is a delta E of 12 from every
  other agent colour and the cursor. A colour that sits on the cursor's gives its slot to its variant. How many colours a
  theme gives (6 to 12) is in `drgnx doctor`.

### Agent colours, marks and handles

Agents are told apart by a colour, a mark and a name, never by colour alone. The mark is one of circle, square, triangle,
diamond, hexagon, star (Lucide icons in the UI, `●■▲◆⬢★` in text, `o # ^ < H *` where those do not display one column
wide, and the first four as gutter bitmaps). With the look's six colours the first 36 agents get a distinct colour and
mark pair, up to 72 with a full second ring; the first six also get six different marks. Past that an agent takes the pair
of the least recently active one no buffer shows. `drgnx-agents-identity-walk` chooses the order: `diagonal` (the
default) or `colour-first` (the six colours as circles, marks from the seventh agent). For code,
`(drgnx-agent-identity ORDINAL)` is `(:face F :mark M :glyph G)` for the selected frame's display.

A face your theme or your Customize settings set is left as you set it; a theme that is loaded but not enabled does not
count. Colours are worked out for a graphical display and a 256-colour terminal separately, so a terminal client of a
daemon never reads a graphical frame's colours or the other way round. A colour the theme leaves unspecified falls back
to the theme's default colours, and `drgnx-look-derive-gaps` lists the faces that could not be worked out. Turning ui/look
off puts every face back as drgnx defines it.

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
   every theme change. This holds for the code font too: a `(set-face-attribute 'default nil :family "Iosevka")` in
   `config.el` stays, under drgnx's themes and without one.
2. **A per-mode override**, a `(:mode MODE ...)` section of `settings.el` (for example Org's prose in the UI font).
3. **The setting.**
4. **The theme.** A theme may name fonts for the role faces.
5. **The desktop**, only for roles set to `follow-desktop`.
6. **drgnx's defaults** (the table above).

A setting changes only the attributes you set; the theme's other attributes show through. A theme that paints a role
face without naming a font (drgnx's three themes paint `default`, its colours) leaves the role's font as the list
says: the desktop's or drgnx's defaults, so the code font is JetBrains Mono 13.5 px under drgnx Dark. A family that
is not installed falls back down its `:fallback` list, then to the generic family.

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

A role whose family is not installed uses the next family of its `:fallback` list that is (the code role's default:
JetBrains Mono, then Adwaita Mono, then the system's `monospace`), never whatever font the system picks: the lists are
handed to Emacs's font matching (`face-font-family-alternatives`, set through `internal-set-alternative-font-family-alist`
so that the C side sees them).
[`drgnx doctor`](install.md#fonts) names each role whose family is not installed, the family it fell back to and the
package to install. drgnx checks each new window's display and writes what it found to `fonts-report.eld` in the
state directory; the `drgnx doctor` command, which runs without a window, reads it there.

The role faces are `drgnx-ui-text`, `drgnx-ui-heading`, `drgnx-ui-caption`, `drgnx-ui-title`, `drgnx-code-small`,
`drgnx-agent-prose` and `drgnx-terminal`; the code role is the `default` and `fixed-pitch` faces and the UI role also
sets `variable-pitch`. Their specs hold `:family`, `:height` and `:weight` only, never `:font`. The height is
relative to `default`, except for the chrome's faces (`drgnx-ui-text`, `drgnx-ui-heading`, `drgnx-ui-caption`,
`drgnx-ui-title`, `drgnx-code-small`): they get the absolute height their size gives on `default` (Emacs copies a font
spec at every run of a face with a relative height, and the bars and the sidebar's rows are many runs). drgnx writes it
again whenever the code size, the theme or a zoom (`View: Zoom In`) changes `default`, and in a buffer you scale with
`C-x C-+` it remaps them by the same scale, so they look as a relative height would. For the same reason the editor
tabs' faces and the header rows' band (`drgnx-wb-bar`) name no `:height` at all.

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
height) for every frame, a frame made later included (`C-x 5 2`, `emacsclient -c`, a daemon's first graphical
frame), and again when the frame is resized, its scale changes or the code font changes. Who decides,
first match: the `:line-height` you set on `drgnx-look-font-code`, then the density. A `line-spacing` you set
yourself (`setq-default`) stays: drgnx then leaves the frames alone. `drgnx-face-line-spacing` is obsolete (use the
code role's `:line-height`); while it is set it still wins, as a default `line-spacing`.

**The rows, tabs and the status bar** follow a change at once too, with no restart: the Explorer, Open and Outline
rows take the new tree row, every editor's tab row the new tab row and every status bar its new height. They are made
in the pixels of the frame that shows them, again when its scale changes (a frame moved to a ×2 monitor), and a
sidebar made before any graphical frame (a daemon's) gets its rows when a graphical frame first shows it.

## Popups and the palette

Under Glitnir (the compositor; not in a terminal, and not where it is off) popups and the floating command palette are
rounded and shadowed, with values per variant:

| | Dark | Light | High Contrast |
|---|---|---|---|
| Popups | radius 8, shadow blur 16 down 6, opacity 0.35 | the same at 0.14 | no shadow, a 1 px `drgnx-border-strong` ring |
| Palette | radius 12, shadow blur 48 down 16 at 0.50, 90 % opaque, blur 12 behind | shadow 0.22 | opaque, no shadow, no blur, a 2 px ring |

The values follow the theme when it changes. `drgnx-look-chrome` and `drgnx-look-palette` hold them as frame
parameter lists; a value you set (Customize or `settings.el`) stands in every variant. In the popup lane, descriptions
(transient, which-key) use the UI font and their keys the code font.

`drgnx-look-motion` (a setting) says how things move: `auto` (the default) follows the desktop's reduced-motion
preference, `full` always moves, `reduced` never does: popups, the palette and notices then appear and vanish at once, and
blur and shadows stay. A change applies at once. It sets Glitnir's own `glitnir-reduced-motion` (`auto`, `nil` or
`t`) as the module, so a value you gave that option stays, and turning ui/look off gives it back. Where Glitnir is
off, nothing floats and nothing moves: popups and the palette use the plain frames and notices go to the echo area.

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
then from the major mode in `auto-mode-alist`; there are no per-language logos. It is worked out once per extension
(once per name for a name without one: `Makefile`, `LICENSE`) and kept, at most 256 of them, the least recently used
going first; a change of `auto-mode-alist` works them out again.

The icons are from Lucide (ISC licence) and a few from Feather (MIT licence); both notices are in `etc/icons/`
(`LICENSE-lucide`, `LICENSE-feather`) and must stay with the icons in any copy.
