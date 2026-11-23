//! `cargo xtask wit-check [--root DIR] [--base REF]`: the extension API's version rule (api-versioning,
//! docs/develop/standards/api-versioning.md).
//!
//! `crates/ext/mal/drgnx.wit` is compared with the file at the last tag (`git describe --tags --abbrev=0`, or REF). The
//! comparison is of the API's surface (interfaces, functions with their types, type definitions, the world's imports
//! and exports), never of comments. A removed or changed item needs a breaking bump, an added one an additive bump:
//! - from 1.0 on, a breaking change bumps the major version and an additive one the minor version;
//! - below 1.0, as cargo reads it, a breaking change bumps the minor version and an additive one the patch version.
//!
//! Without an earlier tag, or a tag without the file, there is nothing to compare with and the check passes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use wit_parser::{Resolve, Type, TypeDefKind, TypeOwner, WorldItem};

const WIT_PATH: &str = "crates/ext/mal/drgnx.wit";

/// The API's surface: each item's key and its rendering, and the package version.
struct Surface {
    version: (u64, u64, u64),
    items: BTreeMap<String, String>,
}

fn ty(r: &Resolve, t: &Type) -> String {
    match t {
        Type::Bool => "bool".into(),
        Type::U8 => "u8".into(),
        Type::U16 => "u16".into(),
        Type::U32 => "u32".into(),
        Type::U64 => "u64".into(),
        Type::S8 => "s8".into(),
        Type::S16 => "s16".into(),
        Type::S32 => "s32".into(),
        Type::S64 => "s64".into(),
        Type::F32 => "f32".into(),
        Type::F64 => "f64".into(),
        Type::Char => "char".into(),
        Type::String => "string".into(),
        Type::ErrorContext => "error-context".into(),
        Type::Id(id) => {
            let d = &r.types[*id];
            match (&d.name, d.owner) {
                (Some(n), TypeOwner::Interface(i)) => {
                    format!("{}.{n}", r.interfaces[i].name.clone().unwrap_or_default())
                }
                (Some(n), _) => n.clone(),
                (None, _) => kind(r, &d.kind),
            }
        }
    }
}

fn opt(r: &Resolve, t: &Option<Type>) -> String {
    t.as_ref().map_or_else(|| "_".to_string(), |t| ty(r, t))
}

fn kind(r: &Resolve, k: &TypeDefKind) -> String {
    match k {
        TypeDefKind::Enum(e) => format!(
            "enum {{{}}}",
            e.cases
                .iter()
                .map(|c| c.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ),
        TypeDefKind::Record(rec) => format!(
            "record {{{}}}",
            rec.fields
                .iter()
                .map(|f| format!("{}: {}", f.name, ty(r, &f.ty)))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        TypeDefKind::Flags(f) => format!(
            "flags {{{}}}",
            f.flags
                .iter()
                .map(|f| f.name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ),
        TypeDefKind::Variant(v) => format!(
            "variant {{{}}}",
            v.cases
                .iter()
                .map(|c| format!("{}({})", c.name, opt(r, &c.ty)))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        TypeDefKind::Tuple(t) => format!(
            "tuple<{}>",
            t.types
                .iter()
                .map(|t| ty(r, t))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        TypeDefKind::Option(t) => format!("option<{}>", ty(r, t)),
        TypeDefKind::List(t) => format!("list<{}>", ty(r, t)),
        TypeDefKind::Result(res) => format!("result<{}, {}>", opt(r, &res.ok), opt(r, &res.err)),
        TypeDefKind::Type(t) => format!("type {}", ty(r, t)),
        TypeDefKind::Resource => "resource".into(),
        _ => "other".into(),
    }
}

fn surface(src: &str) -> Result<Surface, String> {
    let mut r = Resolve::new();
    let pkg = r
        .push_source("drgnx.wit", src)
        .map_err(|e| format!("the WIT does not parse: {e:#}"))?;
    let name = &r.packages[pkg].name;
    let v = name.version.as_ref().ok_or("the package has no version")?;
    let version = (v.major, v.minor, v.patch);
    let mut items = BTreeMap::new();
    for (_, i) in r.interfaces.iter() {
        let Some(iname) = &i.name else { continue };
        if i.package != Some(pkg) {
            continue;
        }
        items.insert(format!("interface {iname}"), String::new());
        for (fname, f) in &i.functions {
            let params = f
                .params
                .iter()
                .map(|p| format!("{}: {}", p.name, ty(&r, &p.ty)))
                .collect::<Vec<_>>()
                .join(", ");
            items.insert(
                format!("function {iname}.{fname}"),
                format!("({params}) -> {}", opt(&r, &f.result)),
            );
        }
        for (tname, id) in &i.types {
            items.insert(
                format!("type {iname}.{tname}"),
                kind(&r, &r.types[*id].kind),
            );
        }
    }
    for (_, w) in r.worlds.iter() {
        if w.package != Some(pkg) {
            continue;
        }
        for (dir, map) in [("import", &w.imports), ("export", &w.exports)] {
            for item in map.values() {
                if let WorldItem::Interface { id, .. } = item {
                    items.insert(
                        format!(
                            "world {} {dir} {}",
                            w.name,
                            r.interfaces[*id].name.clone().unwrap_or_default()
                        ),
                        String::new(),
                    );
                }
            }
        }
    }
    Ok(Surface { version, items })
}

/// What the change between two surfaces is.
#[derive(PartialEq, Eq, Debug)]
enum Change {
    None,
    Additive,
    Breaking,
}

fn change(old: &Surface, new: &Surface) -> (Change, Vec<String>) {
    let mut breaking = Vec::new();
    let mut additive = Vec::new();
    for (k, v) in &old.items {
        match new.items.get(k) {
            None => breaking.push(format!("removed: {k}")),
            Some(n) if n != v => breaking.push(format!("changed: {k}: `{v}` -> `{n}`")),
            Some(_) => {}
        }
    }
    for k in new.items.keys().filter(|k| !old.items.contains_key(*k)) {
        additive.push(format!("added: {k}"));
    }
    if !breaking.is_empty() {
        breaking.extend(additive);
        (Change::Breaking, breaking)
    } else if !additive.is_empty() {
        (Change::Additive, additive)
    } else {
        (Change::None, Vec::new())
    }
}

fn fmt_v(v: (u64, u64, u64)) -> String {
    format!("{}.{}.{}", v.0, v.1, v.2)
}

/// Whether the new version is the bump the change needs, or an error saying which.
pub fn check(old_src: &str, new_src: &str) -> Result<(), String> {
    let (old, new) = (surface(old_src)?, surface(new_src)?);
    if new.version < old.version {
        return Err(format!(
            "the version went down: {} -> {}",
            fmt_v(old.version),
            fmt_v(new.version)
        ));
    }
    let (kind, why) = change(&old, &new);
    let (o, n) = (old.version, new.version);
    let pre_one = o.0 == 0;
    let ok = match kind {
        Change::None => true,
        // below 1.0 a breaking change moves the minor version; from 1.0 the major
        Change::Breaking if pre_one => n.0 > o.0 || n.1 > o.1,
        Change::Breaking => n.0 > o.0,
        // an additive one moves the patch (below 1.0) or the minor (from 1.0): any later version of that rank
        Change::Additive if pre_one => n > o,
        Change::Additive => n.0 > o.0 || n.1 > o.1,
    };
    if ok {
        return Ok(());
    }
    let need = match (&kind, pre_one) {
        (Change::Breaking, true) => "a minor bump (below 1.0)",
        (Change::Breaking, false) => "a major bump",
        (_, true) => "a patch bump (below 1.0)",
        (_, false) => "a minor bump",
    };
    Err(format!(
        "{WIT_PATH} changed its API, which needs {need}: {} stays {} (docs/develop/standards/api-versioning.md)\n  {}",
        "the package version",
        fmt_v(n),
        why.join("\n  ")
    ))
}

fn git(root: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

pub fn run(args: Vec<String>) -> Result<ExitCode, String> {
    let mut root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default();
    let mut base: Option<String> = None;
    let mut it = args.into_iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--root" => root = PathBuf::from(it.next().ok_or("--root needs a directory")?),
            "--base" => base = Some(it.next().ok_or("--base needs a ref")?),
            other => return Err(format!("wit-check: unknown option `{other}`")),
        }
    }
    let new_src =
        std::fs::read_to_string(root.join(WIT_PATH)).map_err(|e| format!("{WIT_PATH}: {e}"))?;
    surface(&new_src)?;
    let base = match base {
        Some(b) => b,
        None => match git(&root, &["describe", "--tags", "--abbrev=0"]) {
            Some(t) => t.trim().to_string(),
            None => {
                println!("wit-check: no earlier tag: nothing to compare with");
                return Ok(ExitCode::SUCCESS);
            }
        },
    };
    let Some(old_src) = git(&root, &["show", &format!("{base}:{WIT_PATH}")]) else {
        println!("wit-check: {base} has no {WIT_PATH}: nothing to compare with");
        return Ok(ExitCode::SUCCESS);
    };
    match check(&old_src, &new_src) {
        Ok(()) => {
            println!("wit-check: {WIT_PATH} against {base}: the version is right");
            Ok(ExitCode::SUCCESS)
        }
        Err(why) => {
            println!("wit-check: against {base}: {why}");
            Ok(ExitCode::from(1))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::check;

    fn wit(version: &str, body: &str) -> String {
        format!(
            "package acme:api@{version};\ninterface i {{\n  enum k {{ a, b }}\n  f: func(x: u8) -> result<_, k>;\n{body}}}\nworld w {{ import i; }}\n"
        )
    }

    #[test]
    fn wit_change_without_bump_fails() {
        // a removed function, a changed signature and a changed enum: each breaks
        let old = wit("1.2.0", "");
        for broken in [
            "package acme:api@1.2.0;\ninterface i {\n  enum k { a, b }\n}\nworld w { import i; }\n",
            "package acme:api@1.2.0;\ninterface i {\n  enum k { a, b }\n  f: func(x: u16) -> result<_, k>;\n}\nworld w { import i; }\n",
            "package acme:api@1.2.0;\ninterface i {\n  enum k { a }\n  f: func(x: u8) -> result<_, k>;\n}\nworld w { import i; }\n",
        ] {
            let e = check(&old, broken).expect_err("the same version must fail");
            assert!(e.contains("major bump"), "{e}");
        }
        // with a minor bump only, still a break
        let e = check(&old, &broken_at("1.3.0")).expect_err("a minor bump is not enough");
        assert!(e.contains("major bump"), "{e}");
        check(&old, &broken_at("2.0.0")).expect("a major bump is enough");
    }

    fn broken_at(v: &str) -> String {
        format!(
            "package acme:api@{v};\ninterface i {{\n  enum k {{ a, b }}\n}}\nworld w {{ import i; }}\n"
        )
    }

    #[test]
    fn added_function_needs_minor() {
        let old = wit("1.2.0", "");
        let added = |v: &str| wit(v, "  g: func();\n");
        let e = check(&old, &added("1.2.0")).expect_err("no bump");
        assert!(e.contains("minor bump"), "{e}");
        let e = check(&old, &added("1.2.1")).expect_err("a patch bump is not enough");
        assert!(e.contains("minor bump"), "{e}");
        check(&old, &added("1.3.0")).expect("a minor bump");
        check(&old, &added("2.0.0")).expect("a major bump covers it");
    }

    #[test]
    fn below_one_a_break_needs_minor_and_an_addition_patch() {
        let old = wit("0.1.0", "");
        let added = |v: &str| wit(v, "  g: func();\n");
        assert!(
            check(&old, &added("0.1.0"))
                .expect_err("no bump")
                .contains("patch bump")
        );
        check(&old, &added("0.1.1")).expect("a patch bump");
        assert!(
            check(&old, &broken_at("0.1.1"))
                .expect_err("a patch is not enough")
                .contains("minor bump")
        );
        check(&old, &broken_at("0.2.0")).expect("a minor bump");
    }

    #[test]
    fn a_comment_or_doc_change_needs_no_bump_and_a_lower_version_fails() {
        let old = wit("1.2.0", "");
        let doc = old.replace("interface i", "/// now documented\ninterface i");
        check(&old, &doc).expect("docs are not the API");
        assert!(
            check(&old, &wit("1.1.0", ""))
                .expect_err("down")
                .contains("went down")
        );
    }
}
