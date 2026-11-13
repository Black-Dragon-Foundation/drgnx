;;; javascript: a built-in language pack (docs/develop/packs.md)
(:pack "javascript" :schema 1 :version "1" :name "JavaScript" :summary "JavaScript language support"
 :files (:extensions ("js" "mjs" "cjs" "jsx") :shebangs ("^node(js)?$"))
 :grammars ((:name javascript :repo "https://github.com/tree-sitter/tree-sitter-javascript" :commit "108b2d4d17a04356a340aea809e4dd5b801eb40d"
             :tree-sha256 "137a08c98c77c6ad64d4991ffaacfc2e79691e615f29a3b37370e381d641e7fc" :src "src" :required t)
  (:name jsdoc :repo "https://github.com/tree-sitter/tree-sitter-jsdoc" :commit "b253abf68a73217b7a52c0ec254f4b6a7bb86665"
             :tree-sha256 "ee19cf9d9e5b767d8475af6ddcc024565fcf658682efb0a4ef01cd082f8bea2e" :src "src"))
 :mode (:ts js-ts-mode :builtin t :classic js-mode)
 :format (:config-files (".prettierrc" ".prettierrc.json" ".prettierrc.yaml" ".prettierrc.yml" ".prettierrc.js" ".prettierrc.cjs" ".prettierrc.mjs" ".prettierrc.toml" "prettier.config.js" "prettier.config.cjs" "prettier.config.mjs" "biome.json" "biome.jsonc" "deno.json" "deno.jsonc"))
 :hrafn (:lang "javascript")
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
