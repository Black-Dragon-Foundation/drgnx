;;; shell: a built-in language pack (docs/develop/packs.md)
(:pack "shell" :schema 1 :version "1" :name "Shell" :summary "Shell language support"
 :files (:extensions ("sh" "bash" "zsh") :shebangs ("^(ba|z|da|a|k)?sh$"))
 :grammars ((:name bash :repo "https://github.com/tree-sitter/tree-sitter-bash" :commit "487734f87fd87118028a65a4599352fa99c9cde8"
             :tree-sha256 "3f561487956b0aad48623b79457aa404ede24546fd228614a9a3ddf35e9d9b30" :src "src" :required t))
 :mode (:ts bash-ts-mode :builtin t :classic sh-mode)
 :hrafn (:lang "shell" :chunks "queries/chunks.scm" :docs (:line "#"))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
