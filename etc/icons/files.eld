;; The file-kind icons, read by the hub (the Explorer's rows, runtime/crates/drgnx-ratatoskr/src/view/icons.rs) and by
;; Lisp (`drgnx-look-file-name-icon-name': Buffers, Quick Open), so both name the same icon for a name.  Plain data, one
;; plist (`drgnx-file-read'):
;;   :names       (ICON NAME...): a file called NAME exactly (any case), tried first: build files, notes without an
;;                extension, well-known dotfiles;
;;   :extensions  (ICON EXTENSION...): a file whose name ends in `.EXTENSION' (any case; a dotfile's name counts).
;; The first line that lists a name or an extension wins; any other file has `file'.
(:names
 ((file-code "makefile" "gnumakefile" "bsdmakefile" "dockerfile" "containerfile" "justfile" "rakefile" "gemfile"
             "vagrantfile" "brewfile" "pkgbuild" "sconstruct" "sconscript" "kconfig" "build" "workspace" "cmakelists.txt"
             "meson.build" ".emacs" ".bashrc" ".bash_profile" ".bash_logout" ".zshrc" ".zprofile" ".zshenv" ".profile"
             ".envrc")
  (file-text "readme" "license" "licence" "copying" "changelog" "changes" "authors" "contributors" "news" "todo"
             "install" "notice" "history" "codeowners")
  (file-cog ".gitignore" ".gitattributes" ".gitmodules" ".gitconfig" ".mailmap" ".dockerignore" ".npmrc" ".yarnrc"
            ".nvmrc" ".tool-versions" ".clang-format" ".clang-tidy" ".prettierrc" ".eslintrc" ".babelrc" ".stylelintrc"
            ".editorconfig" ".env" "procfile" "pipfile" "go.mod" "go.sum" "go.work" "cargo.lock" "flake.lock"))
 :extensions
 ((file-text "md" "markdown" "txt" "org" "rst" "adoc" "tex" "log" "texi" "texinfo" "bib" "csv" "tsv" "po" "pot"
             "article" "letter" "srt" "vtt" "info" "man" "ms")
  (file-cog "json" "jsonc" "json5" "jsonl" "ndjson" "yml" "yaml" "toml" "ini" "conf" "cfg" "cnf" "properties" "env"
            "lock" "editorconfig" "desktop" "service" "timer" "socket" "plist" "xml" "xsd" "xsl" "dtd" "pem" "crt" "ron"
            "kdl" "tf" "tfvars" "hcl")
  (file-image "png" "jpg" "jpeg" "gif" "webp" "bmp" "svg" "svgz" "ico" "tif" "tiff" "avif" "heic" "xcf" "tga" "xpm"
              "xbm" "pbm" "pgm" "ppm" "pnm" "eps")
  (file-archive "zip" "tar" "tgz" "txz" "tzst" "gz" "bz2" "xz" "7z" "rar" "zst" "jar" "deb" "rpm" "oxt")
  (file-code "el" "eld" "elc" "lisp" "cl" "asd" "l" "scm" "ss" "rkt" "clj" "fnl" "rs" "py" "pyi" "js" "mjs" "cjs" "ts"
             "tsx" "jsx" "mts" "cts" "go" "c" "h" "cc" "cpp" "cxx" "c++" "hpp" "hh" "hxx" "cs" "java" "kt" "kts" "scala"
             "groovy" "gradle" "rb" "php" "swift" "m" "mm" "lua" "sh" "bash" "zsh" "fish" "nu" "ps1" "bat" "cmd" "pl"
             "pm" "tcl" "awk" "hs" "ml" "mli" "fs" "fsx" "erl" "hrl" "ex" "exs" "elm" "dart" "r" "jl" "nim" "d" "zig"
             "nix" "sql" "css" "scss" "sass" "less" "html" "htm" "xhtml" "vue" "svelte" "astro" "proto" "graphql" "gql"
             "v" "sv" "vhd" "vhdl" "asm" "s" "f" "f90" "for" "pas" "ada" "adb" "ads" "m4" "y" "cmake" "make" "mk"
             "patch" "diff" "glsl" "wgsl" "cu" "sol" "vb")))
