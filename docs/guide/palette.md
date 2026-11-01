# The command palette

The palette runs any command by name: **View: Command Palette**, or the key your profile gives it (`docs/guide/keys.md`).
Type part of a label (words in any order, when `extra/completion` is on) and press Return. `#` followed by words is a
Semantic Search question. `C-g` cancels.

## Floating under Glitnir

With the `extra/completion` module on, on Nidhogg with Glitnir active, the palette floats: the prompt, the text you
type and the candidates all show in one box, top-centre in the editor frame, 640 logical pixels wide (less in a narrow
frame). It is rounded, shadowed and blurs what lies behind it, and it fades and pops in and out.

Everywhere else (a terminal, another Emacs, `extra/completion` off) the palette stays in the minibuffer, as before.
The keys, Return, `C-g` and `#` search work the same either way.

- **Keyboard focus never moves.** The box is a child frame that cannot take focus; the minibuffer window stays in the
  editor frame, so input methods and the keys you type go where they always went.
- **One frame, reused.** The box is made the first time and hidden afterwards, which lets it animate. Turning
  `extra/completion` off deletes it.
- **The list's length follows the box.** The box is `vertico-count` lines of candidates high (10 by default).

## Look

`drgnx-look-palette` holds the box's frame parameters (`M-x customize-variable`):

| Parameter | Default | |
|---|---|---|
| `corner-radius` | 12 | logical pixels |
| `shadow` | `(:blur 60 :offset (0 . 24) :spread 0 :opacity 0.6)` | colour comes from the `child-frame-shadow` face |
| `alpha-background` | 0.82 | a placeholder; the look session tunes it |
| `backdrop-blur` | 10 | logical pixels of blur radius behind the box |
| `transition` | `pop` | fade and pop in and out |

`drgnx-palette-frame-width` (640) and `drgnx-palette-frame-top` (0.12, the fraction of the frame's height above the box)
place it. No colours are set here: the theme's faces colour everything.
