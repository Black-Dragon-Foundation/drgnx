# Key layers for other keymaps

A profile's key in the global map goes into the profile's layer (`drgnx-keys--profile-map`). A profile key in one of
drgnx's own maps (an entry's `:map`) is not written into that map either: it goes into a layer of its own, so a profile
switch or a reload cannot leave it behind. Which layer depends on whose map it is.

| The map | The layer | Code |
|---|---|---|
| the global map | `drgnx-keys--profile-map`, composed under your keys | `drgnx-keys--fill-profile` |
| one of drgnx's own (`drgnx-…`) | the map's parent: child → layer → old parent | `drgnx-keys--fill-own` |
| any other map (a package's, the modal engine's) | still written, with a ledger (`drgnx-keys--applied`) | `drgnx-keys--apply-binding` |

## Parent layers for drgnx's own maps

`drgnx-keys--set-layers` groups the apply's keys by map. For each of drgnx's own maps (`drgnx-keys--own-map-p`: the
symbol starts with `drgnx-`), once the map exists (now, or when the entry's feature loads: `drgnx-keys--when-map-ready`),
`drgnx-keys--fill-own` fills the map's layer and inserts it between the map and its parent. The layer's parent is the
map's old parent.

- **The parent a derived mode will take.** `define-derived-mode` sets a map's parent when the *mode first runs*, and only
  `unless (keymap-parent map)` (derived.el). A layer put on a map before the mode ran would be that parent, and the
  derived mode would never get its parent mode's map. A map with no parent therefore gets the parent mode's map
  (`drgnx-keys--natural-parent`: `PARENT-mode-map` of the mode `get`ting `derived-mode-parent`) as its layer's parent.
  A derived chain reads child → child layer → parent map → parent layer.
- **Checked at every apply.** `drgnx-keys--restore` (the start of every apply) takes each layer out again and empties it
  (`drgnx-keys--detach-all`). When someone called `set-keymap-parent` on the map meanwhile, that parent is kept, the layer
  goes above it at this apply, and a problem says so ("its parent was replaced…").
- **Yours win.** A key you bind in the map itself shadows the layer's; nothing needs recording.
- **Modules never put profile keys in their maps.** `drgnx-keys-lint-children` lists the profile keys that also sit in a
  child map itself (they would shadow the layer and survive a profile switch); the lint test `drgnx-keys/layers-lint-…`
  holds it to nothing.
