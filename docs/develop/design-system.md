# The design system

`docs/design/` is drgnx's design system: one reference for how drgnx looks, for people and agents building drgnx and
for authors of themes and extensions. Part of it is hand-written (principles, a page per component); the rest is
**generated from the code that draws the look**, so it cannot disagree with it.

| Page | Made from |
|---|---|
| `tokens.md`, `tokens.css`, `img/tokens-*.svg` | `themes/drgnx-tokens.eld` (every colour, three variants) and the faces the theme generator builds from it: which faces use which token |
| `type.md` | the font roles (`drgnx-type-defaults`), the type faces (`core/drgnx-type-faces.el`) and the density table (`drgnx-look-density-table`) |
| `icons.md`, `img/icons-*.svg` | `etc/icons` (the pictures and names), `etc/icons/files.eld` (file kinds) and the Lisp files that name each icon |

## Regenerating

```sh
bin/drgnx design            # write the generated pages
bin/drgnx design --check    # list the stale ones, exit 1 when there is any
```

The generator is `harness/drgnx-design.el` (batch Emacs, no other runtime). Nothing in it holds a colour: every colour
on a page is read from the token table. The unit test `test/unit/design-test.el` builds the pages in memory and
compares them with the files, so a token or face change without a regeneration fails the unit suite.

## Adding a generated page

Write a function that returns `((PATH . TEXT)...)`, PATH relative to `docs/design/`, and add it to
`drgnx-design-page-makers`. Add a test that reads the page for the facts it must state.
