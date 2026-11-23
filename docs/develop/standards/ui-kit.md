# The UI kit's token table

**The rule.** Every colour and metric the UI draws with is a `mot::Token`. The tokens are listed in
`crates/std/mot/themes/tokens.eld` (the `Token` enum is generated from it), and each theme (`dark.eld`, `light.eld`,
`high-contrast.eld`: the approved look's tokens) gives every token a value. Code asks the theme.

**Doing it right.**

```rust
let theme = mot::Theme::load(&path)?;          // or Theme::builtin()
let bg = theme.colour(mot::Token::Panel);      // an Rgba
let row = theme.metric(mot::Token::Row);       // a kvardi::Lp (logical px)
```

A theme file is `(drgnx-theme :version 1 :name "dark" (gap "#0a0b0d") … (row 26))`. A token the table does not have, a
colour given as a number (or the other way round), a token twice and a token left out are errors that name the token.

**In tests.** A test that needs a colour takes it from a token: `Theme::builtin()[0].colour(Token::X).to_argb()` (the
number Glitnir's `argb` fields hold). A test of the pixel arithmetic itself uses named bit patterns that are not
colours of the UI (premultiplied half-alpha, a shadow's alpha).

**Switching.** `skipan::ThemeSwitch` (not `mot`: the token table has no settings, so the crates under it may use the table; a layer row keeps `mot` off `skipan` and `huginn`) follows the setting `ui.theme` (through `skipan`): `poll()` applies a change and counts one
damage event for each switch that changes the theme (the UI redraws on it); an unrelated setting, or the same theme again,
counts none; a theme that does not exist is reported and the current one stays.

**Enforced by:** the scan rule `no-colour-literal` outside `mot`: `Rgba::new(…)`, `rgb(…)` and its kin with literal numbers,
a `0xRRGGBB[AA]` number given to a call, method, field, `let`, `const` or `static` whose name says colour, and a `"#rrggbb"`
string. Colour literals live in `themes/` only. Owner: `mot`. Conformance: `crates/std/mot/tests/conformance.rs`.

**Why.** A colour in a view is a colour no theme can change, and the high-contrast theme cannot reach it.
