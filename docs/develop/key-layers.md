# Key layers for other keymaps

A profile's key in the global map goes into the profile's layer (`drgnx-keys--profile-map`). A profile key in any other keymap (an entry's `:map`)
is not written into that map either: it goes into a layer of its own, so a profile switch, a reload or a package's later
write cannot leave it behind or overwrite it. Which layer depends on whose map it is.

| The map | The layer | Code |
|---|---|---|
| the global map | `drgnx-keys--profile-map`, composed under your keys | `drgnx-keys--fill-profile` |
| one of drgnx's own (`drgnx-…`) | the map's parent: child → layer → old parent | `drgnx-keys--fill-own` |
| any other (a package's, wgrep's) | the foreign layer: one global minor mode, filtered entries | `drgnx-keys--fill-foreign` |
| the modal engine's (evil's state maps) | the profile map's auxiliary keymap for the state (`[normal-state]` …) | `drgnx-keys--fill-profile` |

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
(an overlay's or a button's). A `local-map` property replaces the buffer's local map, so the local map does not count
where one is at point. Text-property keymaps outrank the minor-mode alist, so a button's own map beats a profile key.
A buffer-local `minor-mode-map-alist` does not see the layer's entry.

- **By local map, not by mode.** wgrep switches maps with `use-local-map` and keeps `major-mode`; a mode derived from a
  covered one inherits the map by keymap parent. Both are the local map reaching the target, so both work; an unrelated
  local map (wgrep's `wgrep-mode-map` over a grep buffer, for the grep map's key) does not.
- **Prefixes are filtered too.** A prefix entry (`C-c` of `C-c y a`) is a filtered item as well: a plain prefix map in the
  layer would turn a command bound on `C-c` in another buffer into a prefix there.
- **The target map is never written.** What the package, a hook or you put in it stays, and the layer is above it.
- **The watched set.** Every map the last apply's profile and settings keys name, drgnx's own and foreign
  (`drgnx-keys--named-maps`), is watched by identity with its own prefix maps (`drgnx-keys--watch-named`, again before
  each load's after-load bodies, so a map a package makes afresh is watched before your `with-eval-after-load` writes
  into it). A write of yours there stays in the map and is recorded (`drgnx-keys--yours-in-maps`); the foreign layer
  leaves out every profile key that is your key, a prefix of it or under it (`drgnx-keys--yours-blocks-p`), and takes
  it back when you remove yours or a reload of your file drops it. A drgnx map needs no step aside: your key there
  shadows the layer, its parent.
- **`:everywhere` keys** are watched by key in every map (one stroke: a hash-free `memq` on the event): your binding
  of one in a mode map is recorded (`drgnx-keys--yours-everywhere`), and the entry's filter steps aside wherever that map
  is active.
- **The minibuffer's C-h** (the profile's global C-h gives way to `help-command` there) is a foreign entry for
  `minibuffer-local-map`.
- **Evil.** Under evil a state map sits above every mode map, so a mode map's key of a layer without modal keys goes in
  the layer's auxiliary keymaps for normal and motion state too (`drgnx-keys--evil-aux-p`; next section).

## evil's states

drgnx never writes evil's state maps. evil looks, in each state, for an auxiliary keymap in every active map (the event
`normal-state`, `motion-state` … bound to a keymap whose prompt starts "Auxiliary keymap"), mode maps first, the global
map last, all of them above evil's own state maps.

- **The profile's keys for a state** (an entry whose map is `evil-normal-state-map`, or a key that beats evil's in some
  states, `:also`) go in the profile map's auxiliary keymap for that state, as the key text `<normal-state> g d`
  (`drgnx-keys--fill-profile`, `drgnx-keys--define`). So they beat evil's own key there, and a mode's auxiliary keymap
  (evil-collection's dired keys, its `gx` too) beats them.
- **Your evil writes** (`evil-global-set-key`, `evil-define-key 'normal 'global`, a `define-key` on
  `evil-normal-state-map`) are watched (`drgnx-keys--watch-evil`): yours go to your map's auxiliary keymap for the state
  (`drgnx-keys--redirect-evil`) and are recorded like a global key of yours, `<normal-state> g d` in
  `drgnx-keys--yours`, so the profile's key there is taken out while yours stands (a nil of yours in an auxiliary
  keymap would not hide it) and comes back when you take yours away. A package's write stays in evil's map, below the
  profile's key. Your key in a mode map's auxiliary keymap (`evil-define-key 'normal dired-mode-map …`) is a write
  into a watched map (its auxiliary keymap is watched as evil makes it): the foreign layer steps aside for it.
- **A mode map's keys** for normal and motion state sit in auxiliary keymaps of the map's layer: of the parent layer
  for drgnx's own maps, of the foreign layer (`drgnx-keys--foreign-aux`, entries filtered as the layer's) for the
  others.
- **Made once, emptied in place.** evil collects the auxiliary keymaps per buffer when it normalizes, so drgnx never
  replaces one (`drgnx-keys--empty` keeps them, emptied); when one is made, every evil buffer normalizes once
  (`drgnx-keys--normalize-evil`).
- **evil's own keys** are read live for the claims per state (`drgnx-keys-modal-engine-maps`): nothing of drgnx's is
  in them.
