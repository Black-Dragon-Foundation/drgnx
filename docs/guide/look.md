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

The role faces are `drgnx-ui-text`, `drgnx-ui-heading`, `drgnx-ui-caption`, `drgnx-ui-title`, `drgnx-code-small`,
`drgnx-agent-prose` and `drgnx-terminal`; the code role is the `default` and `fixed-pitch` faces and the UI role also
sets `variable-pitch`. Their specs hold `:family`, `:height` (relative) and `:weight` only, never `:font`.
