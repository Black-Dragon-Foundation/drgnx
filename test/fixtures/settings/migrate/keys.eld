;; drgnx keys (docs/guide/keys.md): :layers — profile stack, :bind — (ID KEY… [:map M]),
;; :unbind — (ID…)
(:version 1
 ;; Emacs editing, VS Code keys for the rest
 :layers ((emacs editing) (vscode app window))
 :pending-layers nil
 :bind ((palette "C-S-p"))
 :unbind (keys-sheet)
 :mac-option meta
 :tty-fallback (("C-S-p" . "M-Z")))
