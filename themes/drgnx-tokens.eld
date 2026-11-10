;;; drgnx-tokens.eld --- the colour tokens of drgnx's three themes  -*- mode: lisp-data -*-
;; The only colour literals drgnx has.  ((dark . ALIST) (light . ALIST) (hc . ALIST)), each entry (TOKEN . VALUE):
;; a "#rrggbb", or (tint COLOUR . ALPHA): COLOUR (a token of the same variant, or a "#rrggbb") at ALPHA over `editor'.
;; `overlay' is `raised'; the palette's 0.90 is the palette's own alpha.  Values are the design's palette
;; (docs/guide/look.md); high contrast adds `sel-fg', the foreground of text on the selection, and has no tints.
;; `sel-inactive' is drgnx's, not the design's: the selected row of a list without the focus, at least 1.25:1 against
;; the panel (the design's `sel-quiet' is 1.15 there, too faint; it stays for buttons and chips).
;; `match' is the search matches' fill, `match-edge' the outline of a match that is not the current one.  Dark's
;; matches are 18 % and outlined in the accent at 72 % (3:1 on the selection, so a match inside one shows; the user's
;; ruling of 2026-11-10); light and high contrast keep the design's 25 %, unoutlined (the edge is the fill).
((dark
  (gap . "#0a0b0d") (editor . "#15161a") (panel . "#18191e") (raised . "#1e1f25") (overlay . "#1e1f25")
  (hover . "#202128") (sel . "#243150") (sel-quiet . "#23252c") (sel-inactive . "#2b2d35") (current-line . "#1a1b20")
  (fg . "#e4e5ea") (muted . "#a2a5b2") (subtle . "#878b98") (disabled . "#4f525d")
  (border . "#2b2d35") (border-subtle . "#212228") (border-strong . "#3b3e49")
  (accent . "#7aa5ff") (accent-fill . "#3d6fe0") (on-accent . "#ffffff") (focus . "#7aa5ff")
  (ok . "#62d394") (warn . "#e9bc5c") (error . "#f47a72") (info . "#6fc6ea") (attention . "#ff9566")
  (ok-tint tint ok . 0.12) (warn-tint tint warn . 0.13) (error-tint tint error . 0.13)
  (info-tint tint info . 0.12) (attention-tint tint attention . 0.15) (accent-tint tint accent . 0.14)
  (add-bg tint ok . 0.11) (del-bg tint error . 0.11) (add-fg . "#a3dba3") (del-fg . "#f6a39d")
  (kw . "#c6a0ff") (fn . "#80b6ff") (str . "#a3dba3") (ty . "#7fd6d1") (const . "#f2ac7e")
  (comment . "#9599a4") (punct . "#a2a5b2")
  (match tint accent . 0.18) (match-edge tint accent . 0.72)
  (a1 . "#80b6ff") (a2 . "#f2ac7e") (a3 . "#a3dba3") (a4 . "#c6a0ff") (a5 . "#f592bb") (a6 . "#7fd6d1"))
 (light
  (gap . "#dfe0e6") (editor . "#ffffff") (panel . "#f6f6f8") (raised . "#ffffff") (overlay . "#ffffff")
  (hover . "#eeeff2") (sel . "#dbe5fb") (sel-quiet . "#ececf0") (sel-inactive . "#dadbe1") (current-line . "#f7f8fa")
  (fg . "#1c1e23") (muted . "#545866") (subtle . "#656977") (disabled . "#a9adb8")
  (border . "#dcdee4") (border-subtle . "#e9eaee") (border-strong . "#c2c5ce")
  (accent . "#2c5fd4") (accent-fill . "#2c5fd4") (on-accent . "#ffffff") (focus . "#2c5fd4")
  (ok . "#1b7f45") (warn . "#8a5d00") (error . "#c22f28") (info . "#0b6f99") (attention . "#b8461a")
  (ok-tint tint ok . 0.10) (warn-tint tint "#c48c00" . 0.14) (error-tint tint error . 0.09)
  (info-tint tint info . 0.09) (attention-tint tint attention . 0.10) (accent-tint tint accent . 0.10)
  (add-bg tint ok . 0.09) (del-bg tint error . 0.08) (add-fg . "#1b6b3a") (del-fg . "#a3271f")
  (kw . "#763ac9") (fn . "#2255c2") (str . "#286a34") (ty . "#0a6865") (const . "#944817")
  (comment . "#595d69") (punct . "#545866")
  (match tint accent . 0.25) (match-edge tint accent . 0.25)
  (a1 . "#2255c2") (a2 . "#a5501a") (a3 . "#2b7339") (a4 . "#7a3ccf") (a5 . "#b0306c") (a6 . "#0b7470"))
 (hc
  (gap . "#000000") (editor . "#000000") (panel . "#000000") (raised . "#0b0b0b") (overlay . "#0b0b0b")
  (hover . "#1a1a1a") (sel . "#1a3166") (sel-fg . "#ffffff") (sel-quiet . "#1a1a1a") (sel-inactive . "#242424")
  (current-line . "#0d0d0d")
  (fg . "#ffffff") (muted . "#d6d8de") (subtle . "#bfc2ca") (disabled . "#8c909a")
  (border . "#8c909a") (border-subtle . "#6b6f78") (border-strong . "#c9ccd3")
  (accent . "#a8c6ff") (accent-fill . "#a8c6ff") (on-accent . "#000000") (focus . "#ffd36b")
  (ok . "#7ff0ad") (warn . "#ffd36b") (error . "#ff9a92") (info . "#8fdcff") (attention . "#ffb38a")
  (ok-tint tint ok . 0) (warn-tint tint warn . 0) (error-tint tint error . 0)
  (info-tint tint info . 0) (attention-tint tint attention . 0) (accent-tint tint accent . 0)
  (add-bg . "#0f2e1b") (del-bg . "#3a1210") (add-fg . "#b9f0b9") (del-fg . "#ffc2bd")
  (kw . "#dcc0ff") (fn . "#a8c6ff") (str . "#b9f0b9") (ty . "#96ece6") (const . "#ffc49c")
  (comment . "#bfc2ca") (punct . "#d6d8de")
  (match tint accent . 0.25) (match-edge tint accent . 0.25)
  (a1 . "#a8c6ff") (a2 . "#ffc49c") (a3 . "#b9f0b9") (a4 . "#dcc0ff") (a5 . "#ffb0d3") (a6 . "#96ece6")))
