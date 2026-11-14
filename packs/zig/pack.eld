;;; zig: a built-in language pack (docs/develop/packs.md)
(:pack "zig" :schema 1 :version "1" :name "Zig" :summary "Zig language support"
 :files (:extensions ("zig" "zon")
         :mode-regexp "\\.z\\(?:ig\\|on\\)\\'")
 :grammars ((:name zig :repo "https://github.com/tree-sitter-grammars/tree-sitter-zig" :commit "6479aa13f32f701c383083d8b28360ebd682fb7d"
             :tree-sha256 "ab93c081a02dd3609bb4a707d579e621ecca43f3c816537aa51241e4c85e72ba" :src "src" :required t))
 :mode (:generic t :classic zig-mode :indent ((block . 4) (struct_declaration . 4) (initializer_list . 4)))
 :servers ((:id "zls" :modes (drgnx-pack-ts-mode zig-mode) :command ("zls") :find (:path "zls")))
 :format (:formatter zig :command ("zig" "fmt" "--stdin") :standard t)
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
