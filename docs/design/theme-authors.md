# Writing a theme for drgnx

drgnx draws with faces and owns no colour outside its own token table, so any Emacs theme works, and a theme that
knows drgnx's semantic faces gets exactly the look it describes. This page is for people writing a theme (or an
extension that draws chrome). The values drgnx's own themes use are in [tokens](tokens.md); the faces are in
[the face reference](../guide/face.md).

## Setting the semantic faces

A theme of your own can set any of the semantic faces listed under "Faces for theme authors" in
[The face](../guide/face.md). Their defaults inherit standard faces, so a theme that never heard of them still looks
right; a theme that styles them gets precisely what it asks for.

- The token table is `themes/drgnx-tokens.eld`. `(drgnx-look-token 'panel)` reads a token of the active variant, and
  `(drgnx-look-variant)` says which variant is on (`dark`, `light` or `hc`).
- **A theme's spec for a face replaces the face's own, `:inherit` included.** A theme that respecs a face repeats its
  `:inherit`. The unit test `drgnx-themes/a-theme-spec-keeps-the-defface-inherit` fails when a theme spec loses what a
  parent gave.
- A ring's colour (a box's `:color`) cannot be inherited, so a theme gives it; a theme that does not draws the rings in
  the text colour.
- Hold the contrast floors: text 4.5:1 on its background (muted text too, and on the selection), large text and icons
  3:1, a focus ring or the only boundary of a control 3:1, and 7:1 for a high-contrast theme.

## What drgnx reads from another theme

With a theme that is not drgnx's (modus, leuven, Doom One, your own), the semantic faces that have no standard face to
inherit get colours worked out from the theme, when ui/look turns on and every time a theme is enabled or disabled or
the first graphical frame of a daemon appears:

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
- **More agents.** Each of the six also gets a variant of the same hue, 0.13 lighter on a dark theme and darker on a
  light one (`drgnx-agent-7` to `drgnx-agent-12`), kept only if it reads at 3:1 on the editor and is a delta E of 12
  from every other agent colour and the cursor. A colour that sits on the cursor's gives its slot to its variant. How
  many colours a theme gives (6 to 12) is in `drgnx doctor`.

A face your theme or your Customize settings set is left as you set it; a theme that is loaded but not enabled does not
count. Colours are worked out for a graphical display and a 256-colour terminal separately, so a terminal client of a
daemon never reads a graphical frame's colours or the other way round. A colour the theme leaves unspecified falls back
to the theme's default colours, and `drgnx-look-derive-gaps` lists the faces that could not be worked out (`drgnx
doctor` shows them, in its `look-derive` row, under a theme that leaves some). Turning ui/look off puts every face back
as drgnx defines it. A face set only by `set-face-attribute` (not a theme or Customize) is a frame's state, not a
theme's, and derive does not read it.

## Terminals

On a terminal with 256 colours or fewer, the gap, the editor and the panel are one colour: the cards are drawn by the
vertical border instead. On every terminal drgnx's themes draw the selection in inverse video rather than in the
selection colour, which a terminal can barely tell from the editor's.

## Making a variant of drgnx's own

drgnx's three themes are generated from the token table by `themes/drgnx-theme-gen.el`; there is no second source. To
change a colour of drgnx's own look, change the token and run `bin/drgnx design` so the pages here follow; a change to
the look itself (not a bug) goes through a mockup and approval first.
