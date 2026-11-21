;;; css: a built-in language pack (docs/develop/packs.md)
(:pack "css" :schema 1 :version "1" :name "CSS" :summary "CSS language support"
 :files (:extensions ("css"))
 :grammars ((:name css :repo "https://github.com/tree-sitter/tree-sitter-css" :commit "6a442a3cf461b0ce275339e5afa178693484c927"
             :tree-sha256 "d859ee458e89bbfe8bda25b5c50c4c67171e60fd2f90dbd410738644e9ecb2f3" :src "src" :required t))
 :mode (:ts css-ts-mode :builtin t :classic css-mode)
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
