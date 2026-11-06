# The command palette

The palette runs any command by name: **View: Command Palette**, or the key your profile gives it (`docs/guide/keys.md`).
Type part of a label (words in any order, when `extra/completion` is on) and press Return. `#` followed by words is a
Semantic Search question. `C-g` cancels.

## Floating under Glitnir

With the `extra/completion` module on, on Nidhogg with Glitnir active, the palette floats: the prompt, the text you
type and the candidates all show in one box, top-centre in the editor frame, 640 logical pixels wide (less in a narrow
frame). It is rounded, shadowed and blurs what lies behind it, and it fades and pops in and out.

Everywhere else (a terminal, another Emacs, `extra/completion` off) the palette stays in the minibuffer, as before.
The keys, Return, `C-g` and `#` search work the same either way. A question that opens on top of the palette leaves it
open: when you have answered, the palette is there as you left it.

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
| `shadow` | `(:blur 48 :offset (0 . 16) :spread 0 :opacity 0.5)` | 0.22 in the light theme, none in High Contrast; colour comes from the `child-frame-shadow` face |
| `alpha-background` | 0.90 | 1.0 in High Contrast |
| `backdrop-blur` | 12 | logical pixels of blur radius behind the box; none in High Contrast |
| `transition` | `pop` | fade and pop in and out |

`drgnx-palette-frame-width` (640 logical pixels, at any display scale) and `drgnx-palette-frame-top` (0.12, the fraction
of the frame's height above the box) place it. No colours are set here: the theme's faces colour everything.

## Rows

Rows are in the UI font, 32 logical pixels high in the floating palette and 24 in the minibuffer. The letters you
typed are in the accent colour, semibold; the current row is the selection colour. Each row shows its key as keycaps
(`Ctrl` `Shift` `P`), from the key profile you use, and, for a command you ran lately, when ("used 2 min ago").
The commands you ran from the palette come first, newest first, then the rest in their usual order; the list is grouped
Commands, Files and Agents, and is kept in `palette-history.eld` in drgnx's state folder (200 commands at most).

## The echo area

With `ui/look` on, the echo area and the minibuffer are drawn on the same surface as the gap between the cards, and the
prompt is in the accent colour. The empty echo area keeps that surface after a prompt ends too.
