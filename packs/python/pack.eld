;;; python: a built-in language pack (docs/develop/packs.md)
(:pack "python" :schema 1 :version "1" :name "Python" :summary "Python language support"
 :files (:extensions ("py" "pyi" "pyw") :shebangs ("^python[0-9.]*$"))
 :grammars ((:name python :repo "https://github.com/tree-sitter/tree-sitter-python" :commit "bffb65a8cfe4e46290331dfef0dbf0ef3679de11"
             :tree-sha256 "c5c57ab41dadbfd2f28a76cfc9391b1046ee8e42f1c92b485f22e4aa035d2dc7" :src "src" :required t))
 :mode (:ts python-ts-mode :builtin t :classic python-mode)
 :format (:config-files ("ruff.toml" ".ruff.toml"))
 :hrafn (:lang "python" :chunks "queries/chunks.scm" :docs (:line "#" :members (docstring)))
 :inline (:functions ("function_definition" "lambda")
          :loops ("for_statement" "while_statement")
          :names ("identifier"))
 :origin (:decls ())
 :adapters ((:id "debugpy" :name "Python (debugpy)" :types ("debugpy" "python") :languages ("python") :tested t
   :find (:python-module "debugpy")
   :start (:stdio ("{python}" "-m" "debugpy.adapter"))
   :defaults ((:name "Python: Current File" :type "debugpy" :request "launch" :program "${file}"
               :console "integratedTerminal" :cwd "${workspaceFolder}"))
   :install (:pip "debugpy==1.8.22"
             :hash "sha256:a9e9d3550e15ca479c59333e90845029190531f0cacfedab3b815a57bd913947")))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
