;;; csharp: a built-in language pack (docs/develop/packs.md)
(:pack "csharp" :schema 1 :version "1" :name "C#" :summary "C# language support"
 :files (:extensions ("cs"))
 :grammars ((:name c-sharp :repo "https://github.com/tree-sitter/tree-sitter-c-sharp" :commit "362a8a41b265056592a0c3771664a21d23a71392"
             :tree-sha256 "e883157c9f7205435742912e6b09bee37e0472637151a866855fe78e02ae1cf1" :src "src" :required t))
 :mode (:ts csharp-ts-mode :builtin t :classic csharp-mode)
 :format (:formatter csharpier :command ("csharpier" "format" "--write-stdout") :config-files (".csharpierrc" ".csharpierrc.json" ".csharpierrc.yaml" ".csharpierrc.yml"))
 :hrafn (:lang "csharp" :chunks "queries/chunks.scm" :docs (:line "///" :block "/**" :members (line block)))
 :inline (:functions ("method_declaration" "constructor_declaration" "local_function_statement" "lambda_expression")
          :loops ("for_statement" "foreach_statement" "while_statement" "do_statement")
          :names ("identifier"))
 :origin (:decls ("$TY {t} = $V;"))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
