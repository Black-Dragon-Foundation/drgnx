;;; go: a built-in language pack (docs/develop/packs.md)
(:pack "go" :schema 1 :version "1" :name "Go" :summary "Go language support"
 :files (:extensions ("go")
         :mode-regexp "\\.go\\'")
 :grammars ((:name go :repo "https://github.com/tree-sitter/tree-sitter-go" :commit "12fe553fdaaa7449f764bc876fd777704d4fb752"
             :tree-sha256 "3544dc70396b63e9c7cfa7629352999b3da677a4b297034993dce9e772e1d055" :src "src" :required t))
 :mode (:ts go-ts-mode :builtin t :classic go-mode)
 :format (:formatter gofmt :command ("gofmt") :standard t)
 :hrafn (:lang "go" :chunks "queries/chunks.scm" :docs (:line "//"))
 :inline (:functions ("function_declaration" "method_declaration" "func_literal")
          :loops ("for_statement")
          :names ("identifier"))
 :origin (:decls ("{t} := $V" "var {t} = $V" "var {t} $TY = $V"))
 :adapters ((:id "delve" :name "Go (delve)" :types ("go") :languages ("go") :tested t
   :find (:path "dlv")
   :start (:tcp ("{program}" "dap" "--listen" "127.0.0.1:{port}"))
   :defaults ((:name "Go: Launch Package" :type "go" :request "launch" :mode "debug" :program "${fileDirname}"))
   :install (:system "dnf install delve")))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
