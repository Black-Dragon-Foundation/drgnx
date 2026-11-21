;;; lua: a built-in language pack (docs/develop/packs.md)
(:pack "lua" :schema 1 :version "1" :name "Lua" :summary "Lua language support"
 :files (:extensions ("lua")
         :mode-regexp "\\.lua\\'")
 :grammars ((:name lua :repo "https://github.com/tree-sitter-grammars/tree-sitter-lua" :commit "db16e76558122e834ee214c8dc755b4a3edc82a9"
             :tree-sha256 "1f7905d14a65602a99b0a1b224f6fe1ab70c8f94b1eed66b313d7b88236fdb9d" :src "src" :required t))
 :mode (:ts lua-ts-mode :builtin t :classic lua-mode)
 :format (:config-files ("stylua.toml" ".stylua.toml"))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
