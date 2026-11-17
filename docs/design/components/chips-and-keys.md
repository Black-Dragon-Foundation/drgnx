# Chips, keycaps and buttons

The small things inside rows, bars and cards: a **chip** says a status or a name, a **keycap** shows a key, a
**button** runs something, a **pill** is a choice.

![Chips, keycaps and buttons in the title row and status bar, dark](../img/chips-and-keys-dark.png)

![Chips, keycaps and buttons in the title row and status bar, light](../img/chips-and-keys-light.png)

## Anatomy

| Piece | Look | Radius | Face |
|---|---|---|---|
| Chip | caption text on a tint, 7 px of room either side, no ring | 4 | `drgnx-chip-quiet`, `-accent`, `-attention`, `-ok`, `-warn`, `-error`; `drgnx-chip-solid` for a filled one |
| Key hint | the keys in the code font in a 1 px ring (`key-hint-edge`), 5 px of room either side | 4 | `drgnx-kit-key-hint-cap`; `-menu` is the text alone (`drgnx-keycap` is its alias) |
| Button | the quiet selection's fill in a 1 px ring (`button-edge`), 12 px of room either side, 26 px tall (22 small), its key hint after the label | 6 | `drgnx-kit-button-secondary`, `-primary` for the main action, `-quiet`, `-danger` (see [button](button.md), [key hint](key-hint.md)) |
| Choice pill | caption text in a 1 px ring; the chosen one is the accent on its tint | 6 | `drgnx-pill`, `drgnx-pill-on`, `drgnx-pill-accent`, `drgnx-pill-agent` |

## Rules

- A chip is a tint with room inside it. The colour says the kind, and the words say it again: never colour alone.
- High contrast has no tints: a chip is ringed in its own text colour, with the same room.
- A key alone reads as typed (`a`, `D`: Shift with a letter is its capital); with another modifier a letter is a
  capital (`Ctrl Shift P`, `Alt X`); Enter is `↵`.
- The main action of a group is the one `drgnx-kit-button-primary`; a group has at most one.
- A ring's colour cannot be inherited, so the theme gives it. Do not write a colour on a face to get a ring.
- Chips are as tall as their text, never taller than the row they sit in.
