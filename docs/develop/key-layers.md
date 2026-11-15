# Key layers for other keymaps

A profile's key in the global map goes into the profile's layer (`drgnx-keys--profile-map`). A profile key in any other keymap (an entry's `:map`)
is not written into that map either: it goes into a layer of its own, so a profile switch, a reload or a package's later
write cannot leave it behind or overwrite it. Which layer depends on whose map it is.

| The map | The layer | Code |
|---|---|---|
| the global map | `drgnx-keys--profile-map`, composed under your keys | `drgnx-keys--fill-profile` |
| one of drgnx's own (`drgnx-…`) | the map's parent: child → layer → old parent | `drgnx-keys--fill-own` |
| any other (a package's, wgrep's) | the foreign layer: one global minor mode, filtered entries | `drgnx-keys--fill-foreign` |
| the modal engine's (evil's state maps) | still written, with a ledger (`drgnx-keys--applied`) | `drgnx-keys--apply-binding` |

## Parent layers for drgnx's own maps

`drgnx-keys--set-layers` groups the apply's keys by map. For each of drgnx's own maps (`drgnx-keys--own-map-p`: the
symbol starts with `drgnx-`), once the map exists (now, or when the entry's feature loads: `drgnx-keys--when-map-ready`),
`drgnx-keys--fill-own` fills the map's layer and inserts it between the map and its parent. The layer's parent is the
map's old parent.

- **The parent a derived mode will take.** `define-derived-mode` sets a map's parent when the *mode first runs*, and only
  `unless (keymap-parent map)` (derived.el). A layer put on a map before the mode ran would be that parent, and the
  derived mode would never get its parent mode's map. A map with no parent therefore gets the parent mode's map
  (`drgnx-keys--natural-parent`: `PARENT-mode-map` of the mode `get`ting `derived-mode-parent`) as its layer's parent.
  A derived chain reads child → child layer → parent map → parent layer. When the parent mode's map is not loaded at
  the apply, the layer waits without a parent and `drgnx-keys--complete-parents` (on `after-load-functions`, only
  while a layer waits) gives it the parent once the library loads. A parent that installs another map than
  `PARENT-map` with `use-local-map` is not found (derived.el reads `current-local-map`).
- **Checked at every apply.** `drgnx-keys--restore` (the start of every apply) takes each layer out again and empties it
  (`drgnx-keys--detach-all`). When someone called `set-keymap-parent` on the map meanwhile, that parent is kept, the layer
  goes above it at this apply, and a problem says so ("its parent was replaced…").
- **Yours win.** A key you bind in the map itself shadows the layer's; nothing needs recording.
- **Modules never put profile keys in their maps.** `drgnx-keys-lint-children` lists the profile keys that also sit in a
  child map itself (they would shadow the layer and survive a profile switch); the lint test `drgnx-keys/layers-lint-…`
  holds it to nothing.

## The foreign layer

`drgnx-keys--fill-foreign` makes one keymap, `drgnx-keys--foreign-map`, with one wrapped keymap per target map. Its switch
`drgnx-keys--foreign-on` and the map are one entry (`drgnx-keys--foreign-entry`) of `minor-mode-map-alist`, kept last
(`drgnx-keys--foreign-keep-last`, at every apply): another minor mode's key beats a profile key, which beats the major
mode's own. Every entry is `(menu-item "" DEF :filter FILTER)`, where FILTER (`drgnx-keys--foreign-filter`) gives DEF only
while the buffer's local map is, or inherits (parents, composed maps), the target map. The target is looked up by its
symbol when a key is pressed, so a map made later or replaced needs nothing.

The target is active (`drgnx-keys--foreign-active-p`) when the buffer's local map is or inherits it, or a minor mode's
map is or inherits it (`current-minor-mode-maps`: `minor-mode-map-alist`, `minor-mode-overriding-map-alist` and the
emulation alists; vlf's `vlf-prefix-map` is such a map), or the `keymap` or `local-map` property at point is or inherits it
(an overlay's or a button's). Text-property keymaps outrank the minor-mode alist, so a button's own map beats a profile key.
A buffer-local `minor-mode-map-alist` does not see the layer's entry.

- **By local map, not by mode.** wgrep switches maps with `use-local-map` and keeps `major-mode`; a mode derived from a
  covered one inherits the map by keymap parent. Both are the local map reaching the target, so both work; an unrelated
  local map (wgrep's `wgrep-mode-map` over a grep buffer, for the grep map's key) does not.
- **Prefixes are filtered too.** A prefix entry (`C-c` of `C-c y a`) is a filtered item as well: a plain prefix map in the
  layer would turn a command bound on `C-c` in another buffer into a prefix there.
- **The target map is never written.** What the package, a hook or you put in it stays, and the layer is above it.
  Keys of yours in a foreign map step aside once the watched set records them (the keymap redesign's T6); until
  then a profile `:map` key wins over your binding in that map.
- **The minibuffer's C-h** (the profile's global C-h gives way to `help-command` there) is a foreign entry for
  `minibuffer-local-map`.
- **Evil.** `drgnx-keys--bind-evil-aux` still binds the keys in evil's auxiliary maps of the target when evil is loaded.
