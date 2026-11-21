;;; haskell: a built-in language pack (docs/develop/packs.md)
(:pack "haskell" :schema 1 :version "1" :name "Haskell" :summary "Haskell language support"
 :files (:extensions ("hs"))
 :grammars ((:name haskell :repo "https://github.com/tree-sitter/tree-sitter-haskell" :commit "c30d812bc90827f1a54106a25bc9a6307f5cdcec"
             :tree-sha256 "7c092ad50aa92ccc74a58723085899fd5740a2353aeb31dce9f95acace7d287a" :src "src" :required t))
 :mode (:ts haskell-ts-mode :package haskell-ts-mode :classic haskell-mode)
 :servers ((:id "haskell-language-server" :modes (haskell-ts-mode haskell-mode) :command ("haskell-language-server-wrapper" "--lsp") :find (:path "haskell-language-server-wrapper")))
 :format (:formatter ormolu :command ("ormolu" "--stdin-input-file" "stdin") :config-files ("fourmolu.yaml" ".ormolu"))
 :requires (:packages (haskell-ts-mode))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
