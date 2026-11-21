;;; typescript: a built-in language pack (docs/develop/packs.md)
(:pack "typescript" :schema 1 :version "1" :name "TypeScript" :summary "TypeScript language support"
 :files (:extensions ("ts" "mts" "cts")
         :mode-regexp "\\.ts\\'")
 :grammars ((:name typescript :repo "https://github.com/tree-sitter/tree-sitter-typescript" :commit "8e13e1db35b941fc57f2bd2dd4628180448c17d5"
             :tree-sha256 "553a4597c09957255c2d58e5aa1e815d8993717cbdd8bd914d5dc9ab79a50d34" :src "typescript/src" :required t))
 :mode (:ts typescript-ts-mode :builtin t :classic typescript-mode)
 :hrafn (:lang "typescript" :chunks "queries/chunks.scm" :docs (:line "//" :block "/**" :members (block)) :helpers (js-callback-body))
 :inline (:functions ("function_declaration" "function_expression" "function" "generator_function" "generator_function_declaration" "arrow_function" "method_definition")
          :loops ("for_statement" "for_in_statement" "while_statement" "do_statement")
          :names ("identifier" "shorthand_property_identifier"))
 :origin (:decls ("const {t} = $V" "let {t} = $V" "var {t} = $V"))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
