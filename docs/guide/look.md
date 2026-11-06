# The look

How drgnx looks, and how to change it. The module `ui/look` ([modules](modules.md)) draws the colours, the type, the
density and the icons. Everything here is a setting: change it in the settings page or in `settings.el`, and it
applies at once to every frame, with no restart.

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
