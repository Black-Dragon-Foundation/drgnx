;;; php: a built-in language pack (docs/develop/packs.md)
(:pack "php" :schema 1 :version "1" :name "PHP" :summary "PHP language support"
 :files (:extensions ("php" "phtml")
         :mode-regexp "\\.php[0-9s]?\\'")
 :grammars ((:name php :repo "https://github.com/tree-sitter/tree-sitter-php" :commit "5b5627faaa290d89eb3d01b9bf47c3bb9e797dea"
             :tree-sha256 "ddb50ab4bf749263e3daa522ec7cbc739afd8aff52115b2c911839a8c460504d" :src "php/src" :required t)
  (:name phpdoc :repo "https://github.com/claytonrcarter/tree-sitter-phpdoc" :commit "03bb10330704b0b371b044e937d5cc7cd40b4999"
             :tree-sha256 "a2a58241aff962f136678cc574bacc87b0bee40be21bb00b8d41bdf456e30b57" :src "src")
  (:name html :from-pack "html" :required t)
  (:name javascript :from-pack "javascript" :required t)
  (:name jsdoc :from-pack "javascript")
  (:name css :from-pack "css" :required t))
 :mode (:ts php-ts-mode :builtin t :classic php-mode)
 :servers ((:id "intelephense" :modes (php-ts-mode php-mode) :command ("intelephense" "--stdio") :find (:path "intelephense"))
  (:id "phpactor" :modes (php-ts-mode php-mode) :command ("phpactor" "language-server") :find (:path "phpactor")))
 :format (:config-files (".php-cs-fixer.php"))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
