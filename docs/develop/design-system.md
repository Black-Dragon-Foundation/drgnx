# The design system

`docs/design/` is drgnx's design system: one reference for how drgnx looks, for people and agents building drgnx, for
contributors and for authors of themes and extensions. Part of it is hand-written (principles, a page per component, the
app icon, how to write a theme); the rest is **generated from the code that draws the look**, so it cannot disagree
with it.

| Page | Made from |
|---|---|
| `tokens.md`, `tokens.css`, `img/tokens-*.svg` | `themes/drgnx-tokens.eld` (every colour, three variants) and the faces the theme generator builds from it: which faces use which token |
| `type.md` | the font roles (`drgnx-type-defaults`), the type faces (`core/drgnx-type-faces.el`) and the density table (`drgnx-look-density-table`) |
| `icons.md`, `img/icons-*.svg` | `etc/icons` (the pictures and names), `etc/icons/files.eld` (file kinds) and the Lisp files that name each icon |
| `components/*.md` | by hand; each has a dark and a light picture in `img/` cut from the look scenes |
| `index.md`, `app-icon.md`, `theme-authors.md`, `site.css` | by hand (`site.css` only reads the custom properties of the generated `tokens.css`) |

## Regenerating

```sh
bin/drgnx design            # write the generated pages
bin/drgnx design --check    # list the stale ones, exit 1 when there is any
bin/drgnx design --site DIR # build the static site into DIR
bin/drgnx design --shots SCENES-DIR...   # cut the component pictures from look-scene output
```

The generator is `harness/drgnx-design.el` (batch Emacs, no other runtime); the site is `harness/drgnx-design-site.el`.
Nothing in either holds a colour: every colour on a page is read from the token table. The unit test
`test/unit/design-test.el` builds the pages in memory and compares them with the files, so a token, face, font role,
density value or icon change without a regeneration fails the unit suite.

## The pictures

The pictures are drgnx's own, never the mockups: `bin/drgnx ui look-scenes OUT` (in a container, through the slot, at
scale 1; see [the harness](harness.md)) draws the scenes, and `bin/drgnx design --shots OUT` cuts the boxes of
`drgnx-design-shots` out of them (it needs ImageMagick). Scenes that need the Work space run on their own
(`DRGNX_LOOK_ONLY='work-space-dark\|work-space-light'`, on Nidhogg's line image), and the others together. A picture is
judged by people; the unit test only checks that every component page shows its pictures and that they exist.

To add a component: write `components/NAME.md` with `![...](../img/NAME-dark.png)` and `-light.png`, add a line to
`drgnx-design-shots` (the scenes and the box), draw the scenes, cut, and list it in `components/index.md`.

## The site

`bin/drgnx design --site DIR` turns every page into HTML in one layout (a navigation list, a theme switch, `tokens.css`
and `site.css`); a link to another page of the design system stays in the site, a link to anything else in the
repository goes to the file on GitHub. The workflow `.github/workflows/design-pages.yml` builds it on Fedora 45's Emacs,
checks the generated pages are current, and publishes it to GitHub Pages; only a run on `main` deploys, a branch or a
pull request only builds. Emacs is the only tool: the site builder is a small Markdown reader (headings, paragraphs,
lists, tables, code, links, images) in Lisp, so a page keeps to that subset.

## Adding a generated page

Write a function that returns `((PATH . TEXT)...)`, PATH relative to `docs/design/`, and add it to
`drgnx-design-page-makers`. Add a test that reads the page for the facts it must state.
