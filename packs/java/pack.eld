;;; java: a built-in language pack (docs/develop/packs.md)
(:pack "java" :schema 1 :version "1" :name "Java" :summary "Java language support"
 :files (:extensions ("java"))
 :grammars ((:name java :repo "https://github.com/tree-sitter/tree-sitter-java" :commit "94703d5a6bed02b98e438d7cad1136c01a60ba2c"
             :tree-sha256 "af9bb8450fab7dca452aa209ada54b3638fc23c3e4c10d10490895c1ad35144b" :src "src" :required t))
 :mode (:ts java-ts-mode :builtin t :classic java-mode)
 :hrafn (:lang "java" :chunks "queries/chunks.scm" :docs (:line "//" :block "/**" :members (block)))
 :inline (:functions ("method_declaration" "constructor_declaration" "lambda_expression")
          :loops ("enhanced_for_statement" "for_statement" "while_statement" "do_statement")
          :names ("identifier"))
 :origin (:decls ("$TY {t} = $V;"))
 :adapters ((:id "java" :name "Java (jdtls)" :types ("java") :not-built-in t))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
