;; The file-kind icons: (ICON EXTENSION...), one kind per line.  A file whose name ends in `.EXTENSION' (any case)
;; has the ICON of the first line that lists it; any other file has `file'.  Read by the hub (the Explorer's rows,
;; runtime/crates/drgnx-ratatoskr/src/view/icons.rs) and by Lisp (`drgnx-look-file-name-icon-name': Buffers, Quick
;; Open), so both name the same icon for a name.  Plain data in one list (`drgnx-file-read'), a kind per line: the
;; icon a symbol, the extensions strings without the dot.
((file-text "md" "markdown" "txt" "org" "rst" "adoc" "tex" "log")
 (file-cog "json" "jsonc" "json5" "yml" "yaml" "toml" "ini" "conf" "cfg" "properties" "env" "lock" "editorconfig")
 (file-image "png" "jpg" "jpeg" "gif" "webp" "bmp" "svg" "ico" "tif" "tiff" "avif")
 (file-archive "zip" "tar" "tgz" "gz" "bz2" "xz" "7z" "rar" "zst" "jar" "deb" "rpm")
 (file-code "el" "lisp" "scm" "clj" "rs" "py" "js" "mjs" "ts" "tsx" "jsx" "go" "c" "h" "cc" "cpp" "hpp" "cs" "java" "kt" "rb" "php" "swift" "lua" "sh" "bash" "zsh" "fish" "hs" "ml" "sql" "css" "scss" "html" "vue" "zig" "nix" "make" "mk"))
