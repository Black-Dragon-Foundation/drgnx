;;; rust: a built-in language pack (docs/develop/packs.md)
(:pack "rust" :schema 1 :version "1" :name "Rust" :summary "Rust language support"
 :files (:extensions ("rs")
         :mode-regexp "\\.rs\\'")
 :grammars ((:name rust :repo "https://github.com/tree-sitter/tree-sitter-rust" :commit "18b0515fca567f5a10aee9978c6d2640e878671a"
             :tree-sha256 "1baf03ad55207b699fbb21057e103a593afdebf0d117e728c1715a928eed379a" :src "src" :required t))
 :mode (:ts rust-ts-mode :builtin t :classic rust-mode)
 :format (:formatter rustfmt :command ("rustfmt") :standard t)
 :hrafn (:lang "rust")
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
