# Agent marks and progress

Two small kit components that sit inside rows, cards and bars. Both are defined once in `etc/ui/components.eld` and
expanded the same way by the hub (`drgnx_rows::kit`, `Comp::AgentMark` and `Comp::Progress`) and by Lisp chrome
(`drgnx-ui-kit-agent-mark`, `drgnx-ui-kit-progress`). Their generated pages hold the numbers:
[agent mark](agent-mark.md) and [progress](progress.md).

## Agent mark

An agent's handle (one or two letters) on its colour, the way an avatar marks a person.

- **Anatomy:** a 5 px pad, the handle in the caption size, a 5 px pad, about 18 px square. Radius 4 where Glitnir
  rounds.
- **Colour:** the agent's slot (1–12, from `drgnx-agent-identity`) picks its face `drgnx-agent-N`. The kit face
  `drgnx-kit-agent-mark` draws it in inverse video, so the agent's colour is the fill and the surface's colour is the
  letter. A theme that colours `drgnx-agent-N` colours the marks too.
- **Terminal:** `[H]` in the agent's colour.
- **Spoken label:** "agent H" (its `help-echo`).

## Progress

How far something has got, as a bar or a ring.

- **Bar:** the fill (`progress-fill`, the accent) then the track (`progress-track`), each 4 px high. The fill is the
  value times the bar's width in device pixels, rounded half up. On a terminal it is one cell per 8 px of the width
  between `▕` and `▏` (ASCII `[` and `]`), the filled cells `█` (ASCII `#`).
- **Ring:** one of `○ ◔ ◑ ◕ ●` (ASCII `0`–`4`), the value rounded to the nearest quarter, in the fill colour.
- **Spoken label:** "N percent" (its `help-echo`).

## Rules

- Do give a mark its slot, never a colour: the slot's face follows the theme, high contrast included.
- Don't draw a bar as text (`▰▱`) on a graphical frame: use the kit, so the fill's width is exact at every scale.
- Don't pulse or animate progress when the user has asked for reduced motion; the kit draws none.
