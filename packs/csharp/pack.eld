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
 :adapters ((:id "netcoredbg" :name "C# (netcoredbg)" :types ("coreclr" "netcoredbg") :languages ("csharp") :tested t
   :find (:tools "netcoredbg/netcoredbg")
   :start (:stdio ("{tools}/netcoredbg/netcoredbg" "--interpreter=vscode"))
   :defaults ((:name ".NET: Launch" :type "coreclr" :request "launch"
               :program "${workspaceFolder}/bin/Debug/net10.0/${workspaceFolderBasename}.dll" :cwd "${workspaceFolder}"))
   :install (:into "netcoredbg" :root "netcoredbg" :version "3.2.0-1092"
             :platforms ((:platform "linux-x64"
                          :url "https://github.com/Samsung/netcoredbg/releases/download/3.2.0-1092/netcoredbg-linux-amd64.tar.gz"
                          :sha256 "080eb3b2d2152465f599d3b33d1ee6e747794e11cc0a3773ec689f5e5f2c5afa")
                         (:platform "linux-arm64"
                          :url "https://github.com/Samsung/netcoredbg/releases/download/3.2.0-1092/netcoredbg-linux-arm64.tar.gz"
                          :sha256 "065ff49badec8a695dbea2de6ab6a330c774a191e426a217ab8cc05250627ccb")
                         (:platform "darwin-arm64"
                          :url "https://github.com/Samsung/netcoredbg/releases/download/3.2.0-1092/netcoredbg-osx-arm64.zip"
                          :sha256 "f4fa33b3ff874910cc184b4bb3b9c56d0abdf5c6521cee0b144d7c6e4a6e59ea")))))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
