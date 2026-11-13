;;; go: a built-in language pack (docs/develop/packs.md)
(:pack "go" :schema 1 :version "1" :name "Go" :summary "Go language support"
 :files (:extensions ("go")
         :mode-regexp "\\.go\\'")
 :grammars ((:name go :repo "https://github.com/tree-sitter/tree-sitter-go" :commit "12fe553fdaaa7449f764bc876fd777704d4fb752"
             :tree-sha256 "3544dc70396b63e9c7cfa7629352999b3da677a4b297034993dce9e772e1d055" :src "src" :required t))
 :mode (:ts go-ts-mode :builtin t :classic go-mode)
 :format (:formatter gofmt :command ("gofmt") :standard t)
 :hrafn (:lang "go" :chunks "queries/chunks.scm" :docs (:line "//"))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
