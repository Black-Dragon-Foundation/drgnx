;;; swift: a built-in language pack (docs/develop/packs.md)
(:pack "swift" :schema 1 :version "1" :name "Swift" :summary "Swift language support"
 :files (:extensions ("swift")
         :mode-regexp "\\.swift\\'")
 :grammars ((:name swift :repo "https://github.com/alex-pinkus/tree-sitter-swift" :commit "82bb3a533e0801fd2bbaa11dc49676e10bf41948"
             :tree-sha256 "8116f335849708c7845249178482f3f28535d4ca1fa2cae0df710cc1a5b9e448" :src "src" :required t))
 :mode (:generic t :indent ((class_body . 4) (function_body . 4) (enum_class_body . 4) (protocol_body . 4)))
 :servers ((:id "sourcekit-lsp" :modes (drgnx-pack-ts-mode) :command ("sourcekit-lsp") :find (:path "sourcekit-lsp")))
 :format (:formatter swift-format :command ("swift-format") :config-files (".swift-format"))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
