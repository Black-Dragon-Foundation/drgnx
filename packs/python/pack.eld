;;; python: a built-in language pack (docs/develop/packs.md)
(:pack "python" :schema 1 :version "1" :name "Python" :summary "Python language support"
 :files (:extensions ("py" "pyi" "pyw") :shebangs ("^python[0-9.]*$"))
 :grammars ((:name python :repo "https://github.com/tree-sitter/tree-sitter-python" :commit "bffb65a8cfe4e46290331dfef0dbf0ef3679de11"
             :tree-sha256 "c5c57ab41dadbfd2f28a76cfc9391b1046ee8e42f1c92b485f22e4aa035d2dc7" :src "src" :required t))
 :mode (:ts python-ts-mode :builtin t :classic python-mode)
 :format (:config-files ("ruff.toml" ".ruff.toml"))
 :hrafn (:lang "python")
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
