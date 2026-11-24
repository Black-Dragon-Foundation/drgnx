//! Generates the `Token` enum from `themes/tokens.eld`: the file is the table, the enum cannot drift from it.

#[path = "src/sexp.rs"]
mod sexp;

use std::os::fd::AsFd;
use std::path::Path;

use sexp::Item;

fn pascal(name: &str) -> String {
    name.split('-')
        .map(|p| {
            let mut cs = p.chars();
            cs.next()
                .map(|c| c.to_ascii_uppercase().to_string() + cs.as_str())
                .unwrap_or_default()
        })
        .collect()
}

fn main() -> villa::Result<()> {
    annall::cli_out("cargo::rerun-if-changed=themes/tokens.eld")?;
    let root = std::env::var("CARGO_MANIFEST_DIR").map_err(|e| {
        villa::Error::internal("The build has no CARGO_MANIFEST_DIR.").with_source(e)
    })?;
    let themes = Path::new(&root).join("themes");
    let path = themes.join("tokens.eld");
    let dir = eitri::open_path(&themes, eitri::Kind::Dir).map_err(|e| {
        villa::Error::io("The themes folder could not be opened.").with_detail(format!("{e:?}"))
    })?;
    let bytes =
        eitri::read_regular(dir.fd.as_fd(), Path::new("tokens.eld"), 1 << 20).map_err(|e| {
            villa::Error::io(format!("{} could not be read.", path.display()))
                .with_detail(format!("{e:?}"))
        })?;
    let forms = sexp::parse(&String::from_utf8_lossy(&bytes))
        .map_err(|e| villa::Error::invalid(format!("tokens.eld:{}: {}", e.line, e.message)))?;
    let Some(Item::List(items)) = forms.first() else {
        return Err(villa::Error::invalid("tokens.eld holds no form."));
    };
    let mut variants = String::new();
    let mut all = String::new();
    let mut names = String::new();
    let mut kinds = String::new();
    let mut docs = String::new();
    for item in items {
        let Item::List(e) = item else { continue };
        let [Item::Atom(name), Item::Atom(kind), Item::Str(doc)] = e.as_slice() else {
            return Err(villa::Error::invalid(
                "tokens.eld: an entry is not (name kind \"doc\").",
            ));
        };
        let kind = match kind.as_str() {
            "colour" => "Kind::Colour",
            "metric" => "Kind::Metric",
            other => {
                return Err(villa::Error::invalid(format!(
                    "tokens.eld: `{name}` has the kind `{other}`: colour or metric."
                )));
            }
        };
        let v = pascal(name);
        variants += &format!("    /// {doc}\n    {v},\n");
        all += &format!("        Token::{v},\n");
        names += &format!("            Token::{v} => {name:?},\n");
        kinds += &format!("            Token::{v} => {kind},\n");
        docs += &format!("            Token::{v} => {doc:?},\n");
    }
    let out = format!(
        "/// A token of the kit: a colour or a metric a theme gives a value (generated from `themes/tokens.eld`).\n\
         #[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]\n\
         pub enum Token {{\n{variants}}}\n\n\
         impl Token {{\n\
         \x20   /// Every token, in the table's order.\n\
         \x20   pub const ALL: &'static [Token] = &[\n{all}    ];\n\n\
         \x20   /// The name a theme file gives it.\n\
         \x20   pub const fn name(self) -> &'static str {{\n        match self {{\n{names}        }}\n    }}\n\n\
         \x20   pub const fn kind(self) -> Kind {{\n        match self {{\n{kinds}        }}\n    }}\n\n\
         \x20   pub const fn doc(self) -> &'static str {{\n        match self {{\n{docs}        }}\n    }}\n}}\n"
    );
    let dir = std::env::var("OUT_DIR")
        .map_err(|e| villa::Error::internal("The build has no OUT_DIR.").with_source(e))?;
    eitri::replace_file(&Path::new(&dir).join("tokens.rs"), out.as_bytes()).map_err(|e| {
        villa::Error::io("The token table could not be written.").with_detail(format!("{e:?}"))
    })?;
    Ok(())
}
