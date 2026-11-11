# The command palette

The palette runs any command by name: **View: Command Palette**, or the key your profile gives it (`docs/guide/keys.md`).
Type part of a label (words in any order, when `extra/completion` is on) and press Return. `#` followed by words is a
Semantic Search question. `C-g` cancels.

The rows come in three groups (palette.html):

- **Commands**: every command you can run here, its category, when you last ran it and its keys.
- **Files**: the files of the current project (the ones open in buffers first, at most 5000), each with its folder.
  Return visits the file; `Tab` shows it in the window you came from without leaving the palette, and closing the
  palette without choosing it puts that window back.
- **Agents**: with `tools/agents` on, "Ask an agent" with what you typed, the default profile's model beside it.
  Return on it, `Ctrl+Return` from any row, or `@` before your words starts an agent of the default profile in this
  project, opens its panel and gives it your words (**Agents: Ask an Agent…** does the same from anywhere).

The hint at the input row's right edge names them: Commands, `#` code, `@` agents. The footer shows the keys: move,
run, preview, close.

## Floating under Glitnir

With the `extra/completion` module on, on Nidhogg with Glitnir active, the palette floats: the prompt, the text you
type and the candidates all show in one box, top-centre in the editor frame, 640 logical pixels wide (less in a narrow
frame). It is rounded and shadowed, hides what lies behind it, and fades and pops in and out.

Everywhere else (a terminal, another Emacs, `extra/completion` off) the palette stays in the minibuffer, as before.
The keys, Return, `C-g` and `#` search work the same either way. A question that opens on top of the palette leaves it
open: when you have answered, the palette is there as you left it.

- **Keyboard focus never moves.** The box is a child frame that cannot take focus; the minibuffer window stays in the
  editor frame, so input methods and the keys you type go where they always went.
- **One frame, reused.** The box is made the first time and hidden afterwards, which lets it animate. Turning
  `extra/completion` off deletes it.
- **The workbench leaves it alone.** The palette's display action is marked `(drgnx-explicit . t)`, so the
  workbench's placement rules (`docs/guide/workbench.md`) do not put the list in an editor window.
- **The list's length follows the box.** The box is `vertico-count` lines of candidates high (10 by default).

## Look

`drgnx-look-palette` holds the box's frame parameters (`M-x customize-variable`):

| Parameter | Default | |
|---|---|---|
| `corner-radius` | 12 | logical pixels |
| `shadow` | `(:blur 48 :offset (0 . 16) :spread 0 :opacity 0.5)` | 0.22 in the light theme, none in High Contrast; colour comes from the `child-frame-shadow` face |
| `alpha-background` | 0.90 | 1.0 in High Contrast |
| `backdrop-blur` | 16 | logical pixels of blur radius behind the box; none in High Contrast |
| `transition` | `pop` | fade and pop in and out |

The box is frosted, as the design is: 90 % opaque over a blur of what lies behind it, so the editor shows through as
a soft wash of its colours and never as text.

`drgnx-palette-frame-width` (640 logical pixels, at any display scale) and `drgnx-palette-frame-top` (0.12, the fraction
of the frame's height above the box) place it. No colours are set here: the theme's faces colour everything.

## Rows

Rows are in the UI font, 32 logical pixels high in the floating palette and 24 in the minibuffer. A row shows its
category's icon and the command's title, then the category and, for a command you ran lately, when ("Tests · used 2
min ago") in the faint secondary colour, and its key as keycaps at the right edge. Each group (Commands, Files, Agents)
has its name above its rows, with no count. The letters you
typed are in the accent colour, semibold; the current row is the selection colour, one rounded fill 6 pixels in from the list's sides, its text 8 more inside the fill (as the sidebar's rows; every row and group title keeps the same left inset, lined up with the input row's icon, so nothing moves as the selection does). The keycaps
(`Ctrl` `Shift` `P`; in a terminal the names alone, `Ctrl Shift P`) come from the key profile you use. On the current row the
keycaps and hints turn from the faint secondary colour to the muted one, so they stay readable on the selection. A row's
keycaps are small drawn chips, as tall as their text, so the current row's fill stays one unbroken rounded shape around them.
The groups always come in this order: Commands, then Files, then Agents, so "Ask an agent" is the last row and never the
one chosen while a command or a file matches. With nothing typed, the commands you ran from the palette come first,
newest first, then the rest in their usual order. Once you type, how well a row matches comes first, as in VS Code:
each word you type counts more at the start of a word of the title than inside one, and more again when it starts the
word after the previous one's ("run te" puts Run Tests in This File above Run in Terminal…). A command you ran
recently only wins between rows that match about as well. The history is kept in `palette-history.eld` in drgnx's
state folder (200 commands at most).

In the floating palette the prompt is a search icon, a hint at the right of what you type says what it searches
(`Commands · # code · @ agents`, the last with `tools/agents` on), and a footer 30 logical pixels high, 6 below the
last row, shows the keys in its middle: `↑` `↓` move, `↵` run, `Tab` preview, `Esc` close. A 1 pixel hairline in the border
colour runs along the footer's top. The minibuffer in the echo area is not changed by any of this.

## The echo area

With `ui/look` on, the echo area and the minibuffer are drawn on the same surface as the gap between the cards, and the
prompt is in the accent colour. The empty echo area keeps that surface after a prompt ends too.
