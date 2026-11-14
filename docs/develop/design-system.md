# The design system

`docs/design/` is drgnx's design system: one reference for how drgnx looks, for people and agents building drgnx, for
contributors and for authors of themes and extensions. Part of it is hand-written (principles, a page per component, the
app icon, how to write a theme); the rest is **generated from the code that draws the look**, so it cannot disagree
with it.

| Page | Made from |
|---|---|
| `tokens.md`, `tokens.css` | `themes/drgnx-tokens.eld` (every colour, three variants) and the faces the theme generator builds from it: which faces use which token |
| `type.md` | the font roles (`drgnx-type-defaults`), the type faces (`core/drgnx-type-faces.el`) and the density table (`drgnx-look-density-table`) |
| `icons.md`, `img/icons-*.svg` | `etc/icons` (the pictures and names), `etc/icons/files.eld` (file kinds) and the Lisp files that name each icon |
| `components/*.md` | by hand; each has a dark and a light picture in `img/` cut from the look scenes |
| `index.md`, `app-icon.md`, `theme-authors.md`, `book.css` | by hand (`book.css` only reads the custom properties of the generated `tokens.css`) |

## Regenerating

```sh
bin/drgnx design            # write the generated pages
bin/drgnx design --check    # list the stale ones, exit 1 when there is any
bin/drgnx design --shots SCENES-DIR...   # cut the component pictures from look-scene output
```

The generator is `harness/drgnx-design.el` (batch Emacs, no other runtime). Nothing in it holds a colour: every colour
on a page is read from the token table; the tokens page shows each as an inline swatch. The unit test
`test/unit/design-test.el` builds the pages in memory and compares them with the files, so a token, face, font role,
density value or icon change without a regeneration fails the unit suite.

## The pictures

The pictures are drgnx's own, never the mockups: `bin/drgnx ui look-scenes OUT` (in a container, through the slot, at
scale 1; see [the harness](harness.md)) draws the scenes, and `bin/drgnx design --shots OUT` cuts the boxes of
`drgnx-design-shots` out of them (it needs ImageMagick). Scenes that need the Work space run on their own
(`DRGNX_LOOK_ONLY='work-space-dark\|work-space-light'`, on Nidhogg's line image), and the others together. A picture is
judged by people; the unit test only checks that every component page shows its pictures and that they exist.

To add a component: write `components/NAME.md` showing `img/NAME-dark.png` and `img/NAME-light.png`, add a line to
`drgnx-design-shots` (the scenes and the box), draw the scenes, cut, and list it in `components/index.md` and in
`docs/SUMMARY.md`.

## The book

The whole of `docs/` is published as one book with [mdBook](https://rust-lang.github.io/mdBook/) (pinned, 0.5.4):
guide, reference, develop and the design system under one sidebar, `docs/index.md` as the landing page.

- `docs/SUMMARY.md` is the table of contents, in four parts. A unit test fails when a page of `docs/` is not in it or
  an entry has no file, and when a relative link anywhere in `docs/` does not resolve. A new page goes in the file.
- `docs/book.toml` configures it: no preprocessors, and `design/tokens.css` and `design/book.css` as the theme.
- The theme is the design system's own. `tokens.css` is generated, one block per variant: its selectors cover the
  page's `data-theme` and the classes mdBook puts on the html element, so mdBook's light themes get the light tokens and
  its dark ones the dark tokens, and a reader who asks for more contrast gets the high-contrast ones. `book.css` sets
  mdBook's own variables from the tokens and holds no colour literal. The token custom properties are `--drgnx-NAME`.
- `.github/workflows/design-pages.yml` checks the generated pages are current, builds the book on Fedora 45 (mdBook by
  version and checksum) and publishes it to GitHub Pages. Only a run on `main` deploys; a pull request or a branch
  builds without deploying, so breakage shows. To build it here: `mdbook build docs -d FOLDER`.

## Adding a generated page

Write a function that returns `((PATH . TEXT)...)`, PATH relative to `docs/design/`, and add it to
`drgnx-design-page-makers`. Add a test that reads the page for the facts it must state.
