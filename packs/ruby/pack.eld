;;; ruby: a built-in language pack (docs/develop/packs.md)
(:pack "ruby" :schema 1 :version "1" :name "Ruby" :summary "Ruby language support"
 :files (:extensions ("rb"))
 :grammars ((:name ruby :repo "https://github.com/tree-sitter/tree-sitter-ruby" :commit "71bd32fb7607035768799732addba884a37a6210"
             :tree-sha256 "efcc96e49ed9c19776cce0f2ed997b0cb992ecd3c821927480aba5c32ae080fd" :src "src" :required t))
 :mode (:ts ruby-ts-mode :builtin t :classic ruby-mode)
 :format (:config-files (".rubocop.yml"))
 :adapters ((:id "rdbg" :name "Ruby (rdbg)" :types ("rdbg") :languages () :tested nil
  :find (:path "rdbg")
  :start (:tcp ("{program}" "--open" "--host" "127.0.0.1" "--port" "{port}"))))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
