;;; elixir: a built-in language pack (docs/develop/packs.md)
(:pack "elixir" :schema 1 :version "1" :name "Elixir" :summary "Elixir language support"
 :files (:extensions ("ex" "exs"))
 :grammars ((:name elixir :repo "https://github.com/elixir-lang/tree-sitter-elixir" :commit "02a6f7fd4be28dd94ee4dd2ca19cb777053ea74e"
             :tree-sha256 "54460ba7c251ef5e4844b3b3862097505c7095a8d93f9853472372cd046b6a10" :src "src" :required t)
  (:name heex :repo "https://github.com/phoenixframework/tree-sitter-heex" :commit "f6b83f305a755cd49cf5f6a66b2b789be93dc7b9"
             :tree-sha256 "c828888a9ed4b784c85a19b69e6d5d3cb8fff812f6f40e886cd02d260548705c" :src "src"))
 :mode (:ts elixir-ts-mode :builtin t :classic elixir-mode)
 :servers ((:id "elixir-ls" :modes (elixir-ts-mode elixir-mode) :command ("elixir-ls") :find (:path "elixir-ls")))
 :format (:formatter mix :command ("mix" "format" "-") :standard t)
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
