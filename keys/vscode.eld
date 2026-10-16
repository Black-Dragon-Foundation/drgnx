;; VS Code key profile — command id → keys (docs/keys.md).  On macOS, C- becomes s- (Cmd).
(:name "VS Code"
 :doc "Visual Studio Code's default keys"
 :mac-cmd t
 :bind ((palette "C-S-p" "<f1>")
        (keys-sheet "C-k C-s")
        (keyboard-profile "C-k C-p")
        (open-file "C-o")
        (save-file "C-s")
        (line-numbers :none "VS Code has no default key for line numbers")
        (modules-report :none "drgnx-only; in the palette")
        (toggle-sidebar "C-b")
        (focus-editor "C-1")
        (dock-back "<escape>")))
