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

## Token tiers

The token table has two tiers. The **semantic** tier is the roles: surfaces, text, borders, hover, selection, focus,
status and agent colours, named by the faces in `core/drgnx-faces.el`. The **component** tier holds only what one
component of the kit needs of its own, named `COMPONENT-SLOT[-STATE]` with the component's id first
(`button-primary-bg`, `key-hint-edge`), and its value is always a reference to the semantic tier: a token,
`(tint TOKEN . ALPHA)` or `(over BASE TOKEN . ALPHA)`, never a literal. `drgnx-design-token-tier` says which tier a
token is in, and the tokens page has a *Tier* column. The tests hold the tier to that
(`drgnx-design/component-tokens-are-references`) and to the contrast bars (`drgnx-lint/contrast-component-tokens`:
text on a primary button 4.5:1, 7:1 in high contrast; the edges a control is found by 3:1 on the panel, which is why
dark and light build them from `subtle` rather than the 1.3:1 separator borders).

Under a third-party theme `drgnx-look-derive` solves the colours the theme does not give; when it has to move one of
the theme's own (a `shadow` too faint for muted text), it clamps it to the bar and says so in one notice of the `look`
source, which the next run updates or clears, never a second one and never a prompt.

## Generated code

`bin/drgnx design` also writes code, beside the pages (`drgnx-design-code-makers`, paths relative to the checkout), so
`cargo build` never needs Emacs:

| File | Made from |
|---|---|
| `runtime/crates/drgnx-rows/src/faces.rs` | `FaceId`: every `(defface NAME` in `core/`, `wb/` and `modules/` (read as text: a face a loop defines is not seen), the kit's faces and the faces a view patch may name. A variant is the name without `drgnx-` in UpperCamelCase (`drgnx-text-muted` is `TextMuted`); `name()` and `from_name()` go between the two; a numbered family (`NAME-1`… or `NAME-0`…, two or more) is also an associated array (`FaceId::AGENT`, `FaceId::WORK_WHO`, `FaceId::TERM_COLOR`), indexed by the number less the first |
| `runtime/crates/drgnx-rows/src/kit_gen.rs` | `etc/ui/components.eld`: `CompId`, `State` (serde: its name, `"selected-inactive"`), `STATES` (each state but rest with its semantic face), `GLYPHS` (the glyphs the components name, `(name, Unicode, ASCII)`) and per component `geom(id, variant)`, `label(id, variant)` and `face(id, variant)`; a variant slice names variant values and, optionally, a density (`"compact"`, `"comfortable"`, the default, `"roomy"`) |
| `etc/ui/faces.eld` | the same face list, for Lisp |

Both Rust files are `#[rustfmt::skip]` in `lib.rs`: their layout is the generator's. `bin/drgnx design --check` lists a
stale code file as it does a stale page, and `drgnx-design/code-files-are-current` fails the unit suite; the Rust test
`runtime/crates/drgnx-rows/tests/faces.rs` checks every face's name reads back and the kit tables answer. The check
runner's `cargo` stage runs `drgnx-rows`' clippy and tests.

## Regenerating

```sh
bin/drgnx design            # write the generated pages and code
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
