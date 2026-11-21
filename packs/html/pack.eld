;;; html: a built-in language pack (docs/develop/packs.md)
(:pack "html" :schema 1 :version "1" :name "HTML" :summary "HTML language support"
 :files (:extensions ("html" "htm")
         :mode-regexp "\\.html?\\'")
 :grammars ((:name html :repo "https://github.com/tree-sitter/tree-sitter-html" :commit "d9219ada6e1a2c8f0ab0304a8bd9ca4285ae0468"
             :tree-sha256 "a3ce890fdca1d0dd3a84a5e25d949a895da2731e24cbf6ae66fd2c1308243ac7" :src "src" :required t))
 :mode (:ts html-ts-mode :builtin t :classic mhtml-mode)
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
