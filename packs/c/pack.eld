;;; c: a built-in language pack (docs/develop/packs.md)
(:pack "c" :schema 1 :version "1" :name "C" :summary "C language support"
 :files (:extensions ("c" "h"))
 :grammars ((:name c :repo "https://github.com/tree-sitter/tree-sitter-c" :commit "3aa2995549d5d8b26928e8d3fa2770fd4327414e"
             :tree-sha256 "14d5aa73d1066e821c9fd75ad63fdcf72c922c589f1311ed5672b84723add2cc" :src "src" :required t))
 :mode (:ts c-ts-mode :builtin t :classic c-mode)
 :format (:config-files (".clang-format"))
 :hrafn (:lang "c" :chunks "queries/chunks.scm" :docs (:line "//") :helpers (c-declarator-name))
 :inline (:functions ("function_definition")
          :loops ("for_statement" "while_statement" "do_statement")
          :names ("identifier"))
 :origin (:decls ("$TY {t} = $V;"))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
