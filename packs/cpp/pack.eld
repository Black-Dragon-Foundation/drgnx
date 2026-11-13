;;; cpp: a built-in language pack (docs/develop/packs.md)
(:pack "cpp" :schema 1 :version "1" :name "C++" :summary "C++ language support"
 :files (:extensions ("cc" "cpp" "cxx" "hpp" "hh" "h++"))
 :grammars ((:name cpp :repo "https://github.com/tree-sitter/tree-sitter-cpp" :commit "f41b4f66a42100be405f96bdc4ebc4a61095d3e8"
             :tree-sha256 "100f236bab903ebc36c85667bda9d24d82c6983128511d6fc0246482e131330c" :src "src" :required t))
 :mode (:ts c++-ts-mode :builtin t :classic c++-mode)
 :format (:config-files (".clang-format"))
 :adapters ((:id "cpptools" :name "C, C++ (cpptools)" :types ("cppdbg" "cppvsdbg") :not-built-in t))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
