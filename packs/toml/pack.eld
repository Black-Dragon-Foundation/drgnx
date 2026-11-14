;;; toml: a built-in language pack (docs/develop/packs.md)
(:pack "toml" :schema 1 :version "1" :name "TOML" :summary "TOML language support"
 :files (:extensions ("toml")
         :mode-regexp "\\.toml\\'")
 :grammars ((:name toml :repo "https://github.com/tree-sitter-grammars/tree-sitter-toml" :commit "64b56832c2cffe41758f28e05c756a3a98d16f41"
             :tree-sha256 "d38ab75a6df1bfb0794f0a26be27ce4ffd2fc5eabae9a67ba86d27d3cb22c68e" :src "src" :required t))
 :mode (:ts toml-ts-mode :builtin t :classic conf-toml-mode)
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
