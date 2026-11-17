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

## Agent marks and progress

Two kit components that sit inside rows, cards and bars, each defined once in `etc/ui/components.eld` and expanded
the same way by the hub (`Comp::AgentMark`, `Comp::Progress`) and by Lisp chrome (`drgnx-ui-kit-agent-mark`,
`drgnx-ui-kit-progress`). Their generated pages hold the numbers and the sheets: [agent mark](agent-mark.md) and
[progress](progress.md).

### Agent marks

An agent's handle (one or two letters) on its colour, the way an avatar marks a person.

- **Anatomy:** a 5 px pad, the handle in the caption size, a 5 px pad, about 18 px square. Radius 4 where Glitnir
  rounds.
- **Colour:** the agent's slot (1–12, from `drgnx-agent-identity`) picks its face `drgnx-agent-N`. The kit face
  `drgnx-kit-agent-mark` draws it in inverse video, so the agent's colour is the fill and the surface's colour is the
  letter. A theme that colours `drgnx-agent-N` colours the marks too.
- **Terminal:** `[H]` in the agent's colour.
- **Spoken label:** "agent H" (its `help-echo`).

### Progress

How far something has got, as a bar or a ring.

- **Bar:** the fill (`progress-fill`, the accent) then the track (`progress-track`), 4 px high and centred on the
  caption's centre line (the text's, as icons are, not the line box's: the bar lines up with the caption and icons
  beside it), radius 2 at its outer ends. The fill is the value times the bar's width in device pixels, rounded half up.
  Each part is an SVG rectangle in `currentColor`, coloured by its face as the icons are, so a theme change needs no
  redraw (a space's background would fill the whole line). On a terminal it is one cell per 8 px of the width: `█`
  filled and a partial block (eighths, `▏` to `▉`) in the fill's colour, then `░` in the track's; ASCII is
  `[####------]`, rounded to whole cells.
- **Ring:** one of `○ ◔ ◑ ◕ ●` (ASCII `0`–`4`), the value rounded to the nearest quarter, in the fill colour.
- **Spoken label:** "N percent" (its `help-echo`).

### Meters

A meter is progress of kind `meter`: an amount spent against a limit (a budget), its text always beside it. The hub
sends `{"c": "meter", …}` and formats the text ("$31 / $40", "≈$31 / $40 est.", "62 % wk"); the kit never converts a
unit.

| Part | |
|---|---|
| fill | spent / limit, in the state's colour |
| forecast tick | where the forecast's p50 total lands: a 1 px line in a 2 px slot (high contrast: the whole slot) |
| span | on a `wide` meter, from the tick to the p90 total, faded (high contrast: an outline) |
| text | the hub's, in the caption |
| state word | after a ` · `, in the state's colour |

| State | Fill | Word |
|---|---|---|
| ok (under 80 %) | `meter-fill` (accent) | — |
| nearing (from 80 %) | `meter-near` (warn) | "N %" |
| reached | `meter-reached` (error) | "at limit" |
| over | `meter-reached` | "over" |
| forecast over | `meter-fill`, the tick `meter-near` | "p90 over" |
| none | no bar | "no limit" |
| inherited | `meter-fill` against the ancestor's remaining, the track an outline | — (the hub's text: "of plan's $9 left") |
| unpriced | no bar | "unpriced" |

- **Sizes:** `row` 46 × 4 px, `card` its width × 3 px, `wide` its width × 6 px with the forecast span. The bar sits on
  the caption's centre line, as the progress bar does, then a 6 px gap and the text.
- **Terminal:** a progress bar's cells (one per 8 px, eighths in the state's colour), then the text: `█████▍ $36 / $40
  · 90 %`.
- **Spoken label:** "31 of 40 dollars, nearing", then ", estimate" for `usd-est` and ", forecast P50 to P90" when
  there is one; with no bar "12 dollars, no limit".
- **Lisp chrome:** `(drgnx-ui-kit-meter SPENT LIMIT UNIT FORECAST STATE SIZE TEXT WHERE &optional WIDTH FRAME)`.

### Rules for marks and progress

- Do give a mark its slot, never a colour: the slot's face follows the theme, high contrast included.
- Don't draw a bar as text (`▰▱`) on a graphical frame: use the kit, so the fill's width is exact at every scale.
- Don't pulse or animate progress when the user has asked for reduced motion; the kit draws none.
