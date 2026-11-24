//! The api-versioning standard's conformance test: every function of the world is bound, by the generator and by
//! nothing else (docs/develop/standards/api-versioning.md).

mod common;

use std::collections::BTreeSet;
use std::path::Path;

use sattr::luau::LuauHost;
use wit_parser::{Resolve, UnresolvedPackageGroup, WorldItem};

/// `interface.function` for every function the world imports, read from the WIT by wit-parser, not by the generator.
fn world_functions() -> BTreeSet<String> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../mal");
    let group = UnresolvedPackageGroup::parse_dir(&dir).expect("the WIT parses");
    let mut r = Resolve::new();
    let pkg = r.push_group(group).expect("the WIT resolves");
    let w = r
        .select_world(&[pkg], Some("extension"))
        .expect("the world");
    let mut out = BTreeSet::new();
    for item in r.worlds[w].imports.values() {
        if let WorldItem::Interface { id, .. } = item {
            let i = &r.interfaces[*id];
            for f in i.functions.keys() {
                out.insert(format!("{}.{f}", i.name.clone().unwrap_or_default()));
            }
        }
    }
    out
}

#[test]
fn generated_luau_binds_every_function() {
    let wanted = world_functions();
    assert!(
        wanted.len() >= 10,
        "the world has its functions: {wanted:?}"
    );
    let bound: BTreeSet<String> = sattr::generated::BOUND
        .iter()
        .map(ToString::to_string)
        .collect();
    assert_eq!(
        bound, wanted,
        "the generator binds exactly the world's functions"
    );

    let (api, _ex) = common::editor();
    let h = LuauHost::new(&api, "conf", common::LIMITS).expect("starts");
    for f in &wanted {
        let (iface, name) = f.split_once('.').expect("interface.function");
        let name = name.replace('-', "_");
        // a function of the Luau API, under the package's versioned table and under the bare interface
        for path in [
            format!("drgnx.{iface}.{name}"),
            format!("drgnx.api_v0_1_0.{iface}.{name}"),
        ] {
            h.exec(
                common::user(),
                "bound",
                &format!("assert(type({path}) == 'function', '{path}')"),
            )
            .unwrap_or_else(|e| panic!("{f}: {e:?}"));
        }
    }
}

#[test]
fn the_exports_have_callers_in_both_hosts() {
    assert_eq!(
        sattr::generated::EXPORTS,
        ["entry.init", "entry.run", "entry.answered"]
    );
    // the callers exist by name: this fails to compile when the generator skips one
    let _luau = sattr::generated::drgnx_api_v0_1_0::exports::entry::luau_init;
    let _luau_run = sattr::generated::drgnx_api_v0_1_0::exports::entry::luau_run;
    let _luau_answered = sattr::generated::drgnx_api_v0_1_0::exports::entry::luau_answered;
}

#[test]
fn no_binding_is_written_by_hand() {
    for (file, text) in [
        ("lib.rs", include_str!("../src/lib.rs")),
        ("luau.rs", include_str!("../src/luau.rs")),
        ("wasm.rs", include_str!("../src/wasm.rs")),
    ] {
        for glue in [
            "create_function",
            "func_wrap",
            "UserData",
            "add_to_linker",
            "set(\"",
        ] {
            assert!(!text.contains(glue), "{file} binds by hand: `{glue}`");
        }
    }
}

#[test]
fn the_api_version_is_the_package_version() {
    assert_eq!(sattr::generated::API_VERSION, "0.1.0");
    assert!(mal::PACKAGE.ends_with("@0.1.0"));
    assert!(mal::WIT.contains("package drgnx:api@0.1.0;"));
}
