;;; json: a built-in language pack (docs/develop/packs.md)
(:pack "json" :schema 1 :version "1" :name "JSON" :summary "JSON language support"
 :files (:extensions ("json"))
 :grammars ((:name json :repo "https://github.com/tree-sitter/tree-sitter-json" :commit "4d770d31f732d50d3ec373865822fbe659e47c75"
             :tree-sha256 "4cd0afb88af6bc27cbee723ae55c2c22e0de32414e60f8305ae49aaffd39a598" :src "src" :required t))
 :mode (:ts json-ts-mode :builtin t :classic js-json-mode)
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
