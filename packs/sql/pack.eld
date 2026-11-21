;;; sql: a built-in language pack (docs/develop/packs.md)
(:pack "sql" :schema 1 :version "1" :name "SQL" :summary "SQL language support"
 :files (:extensions ("sql")
         :mode-regexp "\\.sql\\'")
 :grammars ((:name sql :repo "https://github.com/DerekStride/tree-sitter-sql" :commit "2d088525f3f986108d969dab526a0d7129281e24"
             :tree-sha256 "c4d237ea8a484c49b3af7d7dbf67236f08fe2087a1e5a9460ab5f4403f96c405" :src "src" :required t))
 :mode (:generic t)
 :servers ((:id "sqls" :modes (drgnx-pack-ts-mode) :command ("sqls") :find (:path "sqls")))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
