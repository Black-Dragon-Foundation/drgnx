;; The menu bar's layout (docs/guide/face.md, "The menu bar"): VS Code's eight menus in its order.
;; Each menu is (ID TITLE GROUP…); a group is a list of registry ids, drawn with a separator between groups;
;; (:sub TITLE ID…) in a group is a submenu.  No titles or keys of commands here: both come from the registry
;; and the active key profile.  An id that is not registered now (its module is off) is left out.
;; A command defined with `:menu ("NAME")' joins the last group of the menu titled NAME (`:also' maps other names).
((file "File"
       (file-new file-new-window)
       (open-file open-folder go-recent remote-open)
       (save-file file-save-as save-all format-on-save)
       ((:sub "Preferences" preferences-settings keyboard-shortcuts keyboard-profile preferences-theme
              preferences-user-config preferences-modules face-preferences))
       (close-tab close-all file-close-window)
       (quit))
 (edit "Edit"
       (edit-undo edit-redo)
       (edit-cut edit-copy edit-paste)
       (search-file search-replace)
       (search-project replace-in-files)
       (edit-comment))
 (selection "Selection"
            (edit-select-all edit-select-line edit-expand edit-shrink)
            (edit-duplicate edit-move-up edit-move-down edit-line-above edit-line-below)
            (edit-next-occurrence edit-all-occurrences))
 (view "View"
       (palette)
       (view-explorer view-search scm-view debug-view extensions-open agents-view work-view)
       (code-problems terminal-toggle)
       ((:sub "Appearance" menu-bar-toggle toggle-sidebar toggle-panel statusbar-toggle view-zen
              view-zoom-in view-zoom-out view-zoom-reset))
       (face-toggle-wrap line-numbers))
 (go "Go"
     (go-back go-forward)
     (go-quick-open go-symbol-project go-symbol)
     (code-definition code-references)
     (go-line)
     (code-next-problem code-previous-problem))
 (run "Run"
      (debug-start debug-run-no-debug debug-stop debug-restart)
      (debug-step-over debug-step-in debug-step-out)
      (debug-breakpoint)
      (debug-open-launch-json))
 (terminal "Terminal"
           (terminal-new split-editor-right)
           (terminal-toggle))
 (help "Help"
       (onboarding palette)
       (help-documentation keys-sheet)
       (help-about))
 (:also ("Options" . "Preferences") ("Preferences" . "Preferences")))
