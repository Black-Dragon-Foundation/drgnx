# The drgnx design system

How drgnx looks, in one place. It is for people and agents building drgnx, for contributors, and for authors of themes
and extensions. Part of it is hand-written (this page, the components, the guides); part is **generated from the code
that draws the look**, so it cannot disagree with it, and a unit test fails when the generated part is stale
([how it is made](../develop/design-system.md)).

| Read | What it holds | Made |
|---|---|---|
| [Colour tokens](tokens.md) ([CSS](tokens.css)) | every colour in the three variants, and the faces that use each | generated |
| [Type, density and spacing](type.md) | font roles and sizes, type faces, the sizes of rows, tabs and bars | generated |
| [Icons](icons.md) | the icon set, with where each icon is used | generated |
| [Components](components/) | one page per piece of chrome: anatomy, faces, rules, screenshots | by hand, screenshots generated |
| [The app icon](app-icon.md) | the dragon tile, its sizes and how it is installed | by hand |
| [Writing a theme](theme-authors.md) | what a theme sets, and what drgnx reads from other themes | by hand |

## Principles

1. **Islands on a gap.** The Explorer, the editor groups, the agent panel and the terminal are cards on a slightly
   darker gap: radius 10, a hairline edge, a barely-there shadow. Structure comes from surfaces, not from borders
   alone.
2. **Calm chrome, informed code.** Chrome is set in the UI font role, code in the code role. Nothing on screen that
   was not asked for; everything you need one glance away.
3. **One colour system.** Every colour is a [token](tokens.md). Faces name tokens (or inherit faces that do); nothing
   outside `themes/` holds a colour literal. The accent marks focus and the current thing, and nothing else.
4. **Attention is the one loud colour.** `attention` means an agent needs you: one per place, never blinking.
5. **Never colour alone.** Status has an icon or a word as well; agents have a colour, a mark and a name; high contrast
   has no tints and rings things instead.
6. **Soft tints, inset and rounded.** Selected rows, hover, the current line, matches and diff backgrounds are
   translucent tints inset from the edge, never edge-to-edge solid blocks.
7. **Sizes are logical pixels.** Every size goes through `drgnx-px` and a scale (`drgnx-look-scale`, 100 to 200 %) that
   scales everything, the code font included. A bare pixel number in chrome code is a bug.

## Rules that hold everywhere

- **State ladder.** A row, tab or button shows rest, hover, selected (window unfocused), selected and focused, each
  visibly different. Hover never equals or outranks selected. Focus is always visible: a ring of at least 2 px on a
  standalone control; the 1 px inset ring only together with the selection tint.
- **Overlays are translucent.** Region, matches, symbol highlights, show-paren and diff backgrounds blend over the
  text; they never hide syntax colours or each other. Targets where nothing else speaks: hover 8 %, symbol highlights
  10 to 15 %, a selected row 12 to 16 % of the accent, the region 20 to 25 % dark and 15 to 20 % light.
- **Contrast floors**, held in all three variants: text 4.5:1 (muted text too, also on the selection), large text and
  icons 3:1, focus rings and the only boundary of a control 3:1, high contrast 7:1. A hairline border is never the
  only cue.
- **Radii nest.** 3 to 4 for a chip or an in-text run, 6 for a button or row, 8 for a popup, 10 for a card, 12 for a
  modal; a rounded thing inside a rounded thing takes the outer radius minus the gap (never below 2 or 3).
- **Spacing steps** are 4, 8, 12, 16 and 24 through `drgnx-px`; heights come from the [density table](type.md#density).
- **Three elevations:** card, popup, modal. High contrast replaces shadows with a 1 or 2 px ring.
- **Motion only shows a change** (a hover fade, a panel slide), within about 150 to 200 ms, interruptible, and cut to
  nothing under reduced motion (`drgnx-look-motion`).
- **Content stress.** A list is shown with long names (an ellipsis, no layout shift), empty (a real empty state, never
  a blank card) and with a thousand items.

## Changing the look

The look was approved as mockups and is built to match them. A change to how drgnx looks goes through a mockup and an
approval first; a fix that makes the screen match what is documented here needs neither. Change a colour in
`themes/drgnx-tokens.eld`, a font role in `core/drgnx-type-faces.el`, a size in `modules/ui/drgnx-look-density.el`, an
icon in `etc/icons/`, then run `bin/drgnx design`; the unit suite fails until you do.
