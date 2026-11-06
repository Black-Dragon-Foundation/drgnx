# The look

How drgnx looks, and how to change it. The module `ui/look` ([modules](modules.md)) draws the colours, the type, the
density and the icons. Everything here is a setting: change it in the settings page or in `settings.el`, and it
applies at once.

## Icons

drgnx draws its marks with [Lucide](https://lucide.dev) line icons: tree rows, tab leading icons, panel headers, the
status bar, the palette's rows, the agent panel's steps and notices (never inside code). About 60 SVG files sit in
`etc/icons/`, each drawn with `currentColor`, so an icon takes the colour of the text around it: in a
`drgnx-text-subtle` run it is subtle, in any theme, and no colour is written in the files. They are 16 px (14 px in
dense rows) with a 1.6 px stroke at any size.

`drgnx-look-icons` chooses how they are drawn:

- `svg` (the default): the line icons, on graphical frames;
- `glyphs`: the characters of the glyph table `drgnx-face-glyphs` (`⑂ ⚠ ✓ ◎ ● ×` and so on; every icon has a glyph
  of the same name), which is also what a terminal frame always shows.

A change applies to the icons drawn from then on.

For code, `(drgnx-look-icon 'folder 'shadow)` is the string for the icon `folder` in the face `shadow` (the optional
third argument is the size), and `(drgnx-look-file-icon "main.rs")` is the icon of a file's kind: code, text, config,
image, archive, or a plain file, and a folder (open or closed) for a directory. The kind comes from the file name,
then from the major mode in `auto-mode-alist`; there are no per-language logos.

The icons are from Lucide (ISC licence) and a few from Feather (MIT licence); both notices are in `etc/icons/`
(`LICENSE-lucide`, `LICENSE-feather`) and must stay with the icons in any copy.
