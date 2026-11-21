;;; yaml: a built-in language pack (docs/develop/packs.md)
(:pack "yaml" :schema 1 :version "1" :name "YAML" :summary "YAML language support"
 :files (:extensions ("yml" "yaml")
         :mode-regexp "\\.ya?ml\\'")
 :grammars ((:name yaml :repo "https://github.com/tree-sitter-grammars/tree-sitter-yaml" :commit "b733d3f5f5005890f324333dd57e1f0badec5c87"
             :tree-sha256 "b9f3594468ac71bbcb5f5c5e9c54f903f033cfc6c401df869ae31989a5380e47" :src "src" :required t))
 :mode (:ts yaml-ts-mode :builtin t :classic yaml-mode)
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
