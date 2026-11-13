//! Names only built-in packs may use (design N1, §3.2): a fetched pack that took one would shadow a built-in language.

/// Built-in pack names (design §6.1, §8.1).
pub const PACKS: &[&str] = &[
    "python",
    "javascript",
    "typescript",
    "tsx",
    "go",
    "rust",
    "java",
    "c",
    "cpp",
    "shell",
    "ruby",
    "lua",
    "html",
    "css",
    "json",
    "yaml",
    "toml",
    "markdown",
    "elisp",
    "org",
    "terraform",
    "dart",
    "php",
    "elixir",
    "haskell",
    "kotlin",
    "swift",
    "zig",
    "sql",
];

/// The names Hrafn stores for a file's language (`hrafn::files::Lang::as_str`, plus `jsx`, N3, and the languages the
/// seven new packs add). `shell`, not `bash`; `typescript` and `tsx`.
pub const LANGS: &[&str] = &[
    "elisp",
    "rust",
    "c",
    "cpp",
    "shell",
    "python",
    "javascript",
    "jsx",
    "typescript",
    "tsx",
    "go",
    "java",
    "org",
    "markdown",
    "text",
    "ruby",
    "lua",
    "html",
    "css",
    "json",
    "yaml",
    "toml",
    "php",
    "elixir",
    "haskell",
    "kotlin",
    "swift",
    "zig",
    "sql",
];

/// Grammar language names a built-in pack owns (design B1: one owner per name; a fetched pack references these).
pub const GRAMMARS: &[&str] = &[
    "bash",
    "c",
    "cpp",
    "css",
    "go",
    "html",
    "java",
    "javascript",
    "jsdoc",
    "json",
    "lua",
    "python",
    "ruby",
    "rust",
    "toml",
    "tsx",
    "typescript",
    "yaml",
    "markdown",
    "markdown-inline",
    "php",
    "phpdoc",
    "elixir",
    "heex",
    "haskell",
    "kotlin",
    "swift",
    "zig",
    "sql",
];

pub fn is_pack(name: &str) -> bool {
    PACKS.contains(&name)
}

pub fn is_lang(name: &str) -> bool {
    LANGS.contains(&name)
}

pub fn is_grammar(name: &str) -> bool {
    GRAMMARS.contains(&name)
}
