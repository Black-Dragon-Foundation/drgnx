;; Emacs key profile — command id → keys (docs/keys.md).  The emacs layer also claims Emacs' own
;; default bindings (:claims-defaults): a later layer that rebinds one of them is reported.
(:name "Emacs"
 :doc "GNU Emacs' default keys"
 :claims-defaults t
 :bind ((palette "C-S-p")
        (keys-sheet "C-h C-k")
        (keyboard-profile :none "in the palette")
        (open-file "C-x C-f")
        (save-file "C-x C-s")
        (line-numbers :none "Emacs has no default key for line numbers")
        (modules-report :none "drgnx-only; in the palette")))
