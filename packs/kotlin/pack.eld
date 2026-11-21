;;; kotlin: a built-in language pack (docs/develop/packs.md)
(:pack "kotlin" :schema 1 :version "1" :name "Kotlin" :summary "Kotlin language support"
 :files (:extensions ("kt" "kts")
         :mode-regexp "\\.kts?\\'")
 :grammars ((:name kotlin :repo "https://github.com/fwcd/tree-sitter-kotlin" :commit "d6af96d2e23ef0a8ff5ab512864378cf08fba311"
             :tree-sha256 "a178d85f1f7784f783ec766edced9ec592fc9035e71903240a641ec2c1677815" :src "src" :required t))
 :mode (:generic t :indent ((class_body . 4) (function_body . 4) (lambda_literal . 4)))
 :servers ((:id "kotlin-language-server" :modes (drgnx-pack-ts-mode) :command ("kotlin-language-server") :find (:path "kotlin-language-server")))
 :format (:formatter ktfmt :command ("ktfmt" "--kotlinlang-style" "-"))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
