//! mal-gen: WIT (through `wit-parser`) to Rust that binds a world to Luau (mlua) and to wasmtime's component host
//! (docs/develop/standards/api-versioning.md).
//!
//! For a world it emits, with no hand-written part:
//! - the enums, and one `Api` trait per imported interface (the editor implements it once), each in the module of
//!   its package, version and interface (`drgnx_api_v0_1_0::commands::Api`);
//! - `install_luau`: every imported function as a Luau function in `<global>.<package>_v<version>.<interface>.<name>`
//!   (and `<global>.<interface>.<name>` while no other package has the interface); the tables are read-only;
//! - `WasmApi<A>`: the bindgen `Host` trait of each imported interface, forwarding to the same `Api`;
//! - callers for every exported function, for both hosts (`exports::<interface>::luau_<fn>` and `wasm_<fn>`).
//!
//! The supported set, checked in every position before anything is emitted (the error names the WIT item):
//! - parameters: bool, the integers, floats, string, enum;
//! - results: nothing, one of those, or `result<T, enum>` / `result<_, enum>`.
//!
//! The host's own names (where bindgen's module, the store's state and the Luau global are) are [`Options`], never
//! assumed. Luau numbers are f64: a 64-bit integer crosses only up to 2^53, and a fraction is refused for any integer.

use std::collections::BTreeMap;
use std::path::Path;

use villa::{Error, Result};
use wit_parser::{
    Function, FunctionKind, InterfaceId, PackageId, Resolve, Type, TypeDefKind, TypeId, TypeOwner,
    UnresolvedPackageGroup, WorldId, WorldItem,
};

/// What the host names, passed in.
pub struct Options {
    /// The module the generated code is included in (`crate::generated`): where its own types are named from.
    pub generated: String,
    /// The module `wasmtime::component::bindgen!` was invoked in (`crate::wasm::bindings`).
    pub bindings: String,
    /// The store's state type, spelled with the API's type parameter `A` (`crate::wasm::State<A>`).
    pub state: String,
    /// The state's field that holds the `WasmApi<A>` (`api`).
    pub api_field: String,
    /// The type of who is calling (`crate::Caller`): `Clone`. Every `Api` method gets it first, as `&Caller`; the host
    /// keeps it in an `Arc<RwLock<Caller>>` so it can change who a call is for.
    pub caller: String,
    /// The Luau global the API is installed under (`drgnx`).
    pub global: String,
}

/// What was generated.
pub struct Output {
    pub rust: String,
    /// `interface.function` (WIT names) for every imported function bound for Luau.
    pub bound: Vec<String>,
    /// `interface.function` for every exported function given callers.
    pub exports: Vec<String>,
}

macro_rules! put {
    ($d:expr, $($a:tt)*) => {{
        $d.push_str(&format!($($a)*));
        Ok::<(), Error>(())
    }};
}

macro_rules! putln {
    ($d:expr, $($a:tt)*) => {{
        $d.push_str(&format!($($a)*));
        $d.push('\n');
        Ok::<(), Error>(())
    }};
}

const RT: &str = include_str!("rt.in");

const KEYWORDS: &[&str] = &[
    "as", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn", "for",
    "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
    "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where",
    "while", "async", "await", "dyn", "abstract", "become", "box", "do", "final", "macro",
    "override", "priv", "typeof", "unsized", "virtual", "yield", "try", "gen",
];

fn fail(msg: impl Into<String>) -> Error {
    Error::invalid(msg)
}

fn snake(s: &str) -> String {
    s.replace('-', "_")
}

/// A WIT name as a Rust value or module name: snake case, a keyword raw (`r#type`); the names that cannot be raw are
/// refused.
fn ident(wit: &str, at: &str) -> Result<String> {
    let s = snake(wit);
    if matches!(s.as_str(), "self" | "super" | "crate") {
        return Err(fail(format!("{at}: `{wit}` cannot be a Rust name")));
    }
    if KEYWORDS.contains(&s.as_str()) {
        Ok(format!("r#{s}"))
    } else {
        Ok(s)
    }
}

/// The name bindgen gives a module or function: a keyword gets a trailing underscore.
fn bindgen_ident(wit: &str) -> String {
    let s = snake(wit);
    if KEYWORDS.contains(&s.as_str()) {
        format!("{s}_")
    } else {
        s
    }
}

fn camel(wit: &str, at: &str) -> Result<String> {
    let mut out = String::new();
    for part in wit.split('-').filter(|p| !p.is_empty()) {
        let mut cs = part.chars();
        if let Some(c) = cs.next() {
            out.extend(c.to_uppercase());
            out.push_str(cs.as_str());
        }
    }
    if out.is_empty() || out == "Self" || out.starts_with(|c: char| c.is_ascii_digit()) {
        return Err(fail(format!("{at}: `{wit}` cannot be a Rust type name")));
    }
    Ok(out)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Int {
    U8,
    U16,
    U32,
    U64,
    S8,
    S16,
    S32,
    S64,
}

impl Int {
    fn rust(self) -> &'static str {
        match self {
            Int::U8 => "u8",
            Int::U16 => "u16",
            Int::U32 => "u32",
            Int::U64 => "u64",
            Int::S8 => "i8",
            Int::S16 => "i16",
            Int::S32 => "i32",
            Int::S64 => "i64",
        }
    }

    fn wide(self) -> bool {
        matches!(self, Int::U64 | Int::S64)
    }

    fn range(self) -> (f64, f64) {
        let max_safe = 9_007_199_254_740_992.0;
        match self {
            Int::U8 => (0.0, f64::from(u8::MAX)),
            Int::U16 => (0.0, f64::from(u16::MAX)),
            Int::U32 => (0.0, f64::from(u32::MAX)),
            Int::U64 => (0.0, max_safe),
            Int::S8 => (f64::from(i8::MIN), f64::from(i8::MAX)),
            Int::S16 => (f64::from(i16::MIN), f64::from(i16::MAX)),
            Int::S32 => (f64::from(i32::MIN), f64::from(i32::MAX)),
            Int::S64 => (-max_safe, max_safe),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Ty {
    Bool,
    Int(Int),
    F32,
    F64,
    Str,
    Enum(TypeId),
    /// a record of scalar fields (no record inside a record)
    Record(TypeId),
}

#[derive(Clone, Copy, Debug)]
enum Ret {
    Nothing,
    Plain(Ty),
    /// `result<ok?, E>`, E an enum or a record
    Result(Option<Ty>, Ty),
}

struct Func {
    wit: String,
    ctx: String,
    params: Vec<(String, Ty)>,
    ret: Ret,
}

struct Iface {
    id: InterfaceId,
    wit: String,
    pkg: String,
    module: String,
    funcs: Vec<Func>,
}

struct Gen<'a> {
    r: &'a Resolve,
    o: &'a Options,
    /// the interfaces the world exports: bindgen puts their types under `exports::`
    exported: Vec<InterfaceId>,
}

fn pkg_label(r: &Resolve, id: PackageId) -> String {
    let n = &r.packages[id].name;
    match &n.version {
        Some(v) => format!("{}:{}@{v}", n.namespace, n.name),
        None => format!("{}:{}", n.namespace, n.name),
    }
}

impl Gen<'_> {
    /// `drgnx:api@0.1.0/commands`
    fn iface_label(&self, id: InterfaceId) -> Result<String> {
        let i = &self.r.interfaces[id];
        let (Some(p), Some(n)) = (i.package, i.name.as_deref()) else {
            return Err(fail(
                "an anonymous interface or one without a package is not supported",
            ));
        };
        Ok(format!("{}/{n}", pkg_label(self.r, p)))
    }

    /// The generated module of a package and its version: `drgnx_api_v0_1_0`.
    fn pkg_module(&self, p: PackageId) -> String {
        let n = &self.r.packages[p].name;
        let base = format!("{}_{}", snake(&n.namespace), snake(&n.name));
        match &n.version {
            Some(v) => format!("{base}_v{}", v.to_string().replace(['.', '-', '+'], "_")),
            None => base,
        }
    }

    /// The Luau key of a package's table: `api_v0_1_0`.
    fn pkg_key(&self, p: PackageId) -> String {
        let n = &self.r.packages[p].name;
        match &n.version {
            Some(v) => format!(
                "{}_v{}",
                snake(&n.name),
                v.to_string().replace(['.', '-', '+'], "_")
            ),
            None => snake(&n.name),
        }
    }

    /// bindgen's module for a package: the name, with the version only when the resolve holds several of them.
    fn bindgen_pkg(&self, p: PackageId) -> String {
        let n = &self.r.packages[p].name;
        let same = self
            .r
            .packages
            .iter()
            .filter(|(_, q)| q.name.namespace == n.namespace && q.name.name == n.name)
            .count();
        let base = bindgen_ident(&n.name);
        match (&n.version, same) {
            (Some(v), s) if s > 1 => {
                format!("{base}{}", v.to_string().replace(['.', '-', '+'], "_"))
            }
            _ => base,
        }
    }

    fn wasm_iface(&self, id: InterfaceId) -> Result<String> {
        let i = &self.r.interfaces[id];
        let (Some(p), Some(n)) = (i.package, i.name.as_deref()) else {
            return Err(fail("an interface without a package or a name"));
        };
        Ok(format!(
            "{}::{}{}::{}::{}",
            self.o.bindings,
            if self.exported.contains(&id) {
                "exports::"
            } else {
                ""
            },
            bindgen_ident(&self.r.packages[p].name.namespace),
            self.bindgen_pkg(p),
            bindgen_ident(n)
        ))
    }

    fn pkg_of(&self, id: InterfaceId) -> Result<PackageId> {
        self.r.interfaces[id]
            .package
            .ok_or_else(|| fail("an interface without a package is not supported"))
    }

    fn enum_owner(&self, id: TypeId) -> Result<(InterfaceId, String)> {
        let d = &self.r.types[id];
        let (TypeOwner::Interface(i), Some(name)) = (d.owner, d.name.as_deref()) else {
            return Err(fail("an enum outside an interface, or without a name"));
        };
        Ok((i, name.to_string()))
    }

    fn enum_path(&self, id: TypeId) -> Result<String> {
        let (i, name) = self.enum_owner(id)?;
        let label = self.iface_label(i)?;
        let p = self.pkg_of(i)?;
        Ok(format!(
            "{}::{}::{}::{}",
            self.o.generated,
            self.pkg_module(p),
            ident(
                self.r.interfaces[i].name.as_deref().unwrap_or_default(),
                &label
            )?,
            camel(&name, &label)?
        ))
    }

    fn wasm_enum_path(&self, id: TypeId) -> Result<String> {
        let (i, name) = self.enum_owner(id)?;
        let label = self.iface_label(i)?;
        Ok(format!(
            "{}::{}",
            self.wasm_iface(i)?,
            camel(&name, &label)?
        ))
    }

    fn cases(&self, id: TypeId) -> Vec<String> {
        match &self.r.types[id].kind {
            TypeDefKind::Enum(e) => e.cases.iter().map(|c| c.name.clone()).collect(),
            _ => Vec::new(),
        }
    }

    /// A parameter or an ok payload.
    fn scalar(&self, t: &Type, at: &str) -> Result<Ty> {
        Ok(match t {
            Type::Bool => Ty::Bool,
            Type::U8 => Ty::Int(Int::U8),
            Type::U16 => Ty::Int(Int::U16),
            Type::U32 => Ty::Int(Int::U32),
            Type::U64 => Ty::Int(Int::U64),
            Type::S8 => Ty::Int(Int::S8),
            Type::S16 => Ty::Int(Int::S16),
            Type::S32 => Ty::Int(Int::S32),
            Type::S64 => Ty::Int(Int::S64),
            Type::F32 => Ty::F32,
            Type::F64 => Ty::F64,
            Type::String => Ty::Str,
            Type::Char => return Err(fail(format!("{at}: `char` is not supported"))),
            Type::ErrorContext => {
                return Err(fail(format!("{at}: `error-context` is not supported")));
            }
            Type::Id(id) => match &self.r.types[*id].kind {
                TypeDefKind::Type(inner) => self.scalar(inner, at)?,
                TypeDefKind::Enum(_) => Ty::Enum(*id),
                TypeDefKind::Record(rec) => {
                    let name = self.r.types[*id].name.clone().unwrap_or_default();
                    for f in &rec.fields {
                        let at = format!("{at}: record `{name}`, field `{}`", f.name);
                        if matches!(self.scalar(&f.ty, &at)?, Ty::Record(_)) {
                            return Err(fail(format!(
                                "{at}: a record inside a record is not supported"
                            )));
                        }
                    }
                    Ty::Record(*id)
                }
                TypeDefKind::Result(_) => {
                    return Err(fail(format!(
                        "{at}: a `result` is supported only as a function's result"
                    )));
                }
                other => {
                    return Err(fail(format!("{at}: {} is not supported", kind_name(other))));
                }
            },
        })
    }

    fn err_of(&self, t: &Type, at: &str) -> Result<Ty> {
        match self.scalar(t, at)? {
            e @ (Ty::Enum(_) | Ty::Record(_)) => Ok(e),
            _ => Err(fail(format!(
                "{at}: the error of a `result` must be an enum or a record"
            ))),
        }
    }

    /// The fields of a record, each as its Ty.
    fn record_fields(&self, id: TypeId) -> Result<Vec<(String, Ty)>> {
        let TypeDefKind::Record(rec) = &self.r.types[id].kind else {
            return Err(fail("a record was expected"));
        };
        let name = self.r.types[id].name.clone().unwrap_or_default();
        rec.fields
            .iter()
            .map(|f| {
                let at = format!("record `{name}`, field `{}`", f.name);
                Ok((f.name.clone(), self.scalar(&f.ty, &at)?))
            })
            .collect()
    }

    fn result_of(&self, t: &Type) -> Option<(Option<Type>, Option<Type>)> {
        let Type::Id(id) = t else { return None };
        match &self.r.types[*id].kind {
            TypeDefKind::Result(res) => Some((res.ok, res.err)),
            TypeDefKind::Type(inner) => self.result_of(inner),
            _ => None,
        }
    }

    fn func(&self, iface_label: &str, f: &Function) -> Result<Func> {
        let ctx = format!("{iface_label}.{}", f.name);
        if !matches!(f.kind, FunctionKind::Freestanding) {
            return Err(fail(format!("{ctx}: only plain functions are supported")));
        }
        let mut params = Vec::new();
        for p in &f.params {
            let at = format!("{ctx}, parameter `{}`", p.name);
            params.push((p.name.clone(), self.scalar(&p.ty, &at)?));
        }
        let at = format!("{ctx}, result");
        let ret = match &f.result {
            None => Ret::Nothing,
            Some(t) => match self.result_of(t) {
                Some((ok, err)) => {
                    let Some(err) = err else {
                        return Err(fail(format!("{at}: a `result` needs an error type")));
                    };
                    let ok = match ok {
                        Some(t) => Some(self.scalar(&t, &at)?),
                        None => None,
                    };
                    Ret::Result(ok, self.err_of(&err, &at)?)
                }
                None => Ret::Plain(self.scalar(t, &at)?),
            },
        };
        Ok(Func {
            wit: f.name.clone(),
            ctx,
            params,
            ret,
        })
    }

    fn iface(&self, id: InterfaceId) -> Result<Iface> {
        let label = self.iface_label(id)?;
        let i = &self.r.interfaces[id];
        let p = self.pkg_of(id)?;
        let name = i.name.clone().unwrap_or_default();
        let mut funcs = Vec::new();
        for f in i.functions.values() {
            funcs.push(self.func(&label, f)?);
        }
        Ok(Iface {
            id,
            module: ident(&name, &label)?,
            pkg: self.pkg_module(p),
            wit: name,
            funcs,
        })
    }

    // ---- types as Rust spells them

    fn rust_ty(&self, t: Ty) -> Result<String> {
        Ok(match t {
            Ty::Bool => "bool".into(),
            Ty::Int(i) => i.rust().into(),
            Ty::F32 => "f32".into(),
            Ty::F64 => "f64".into(),
            Ty::Str => "String".into(),
            Ty::Enum(id) | Ty::Record(id) => self.enum_path(id)?,
        })
    }

    fn wasm_ty(&self, t: Ty) -> Result<String> {
        match t {
            Ty::Enum(id) | Ty::Record(id) => self.wasm_enum_path(id),
            other => self.rust_ty(other),
        }
    }

    fn ret_ty(&self, r: Ret, wasm: bool) -> Result<String> {
        let ty = |t: Ty| {
            if wasm {
                self.wasm_ty(t)
            } else {
                self.rust_ty(t)
            }
        };
        Ok(match r {
            Ret::Nothing => "()".into(),
            Ret::Plain(t) => ty(t)?,
            Ret::Result(ok, err) => {
                let ok = match ok {
                    Some(t) => ty(t)?,
                    None => "()".into(),
                };
                let err = ty(err)?;
                format!("Result<{ok}, {err}>")
            }
        })
    }

    // ---- Luau: decode a Value, encode a value

    fn dec(&self, t: Ty, val: &str, ctx: &str) -> Result<String> {
        Ok(match t {
            Ty::Bool => format!("rt::dec_bool({val}, \"{ctx}\")?"),
            Ty::Int(i) => {
                let (lo, hi) = i.range();
                format!(
                    "rt::dec_int({val}, \"{ctx}\", {lo:?}, {hi:?})? as {}",
                    i.rust()
                )
            }
            Ty::F32 => format!("rt::dec_num({val}, \"{ctx}\")? as f32"),
            Ty::F64 => format!("rt::dec_num({val}, \"{ctx}\")?"),
            Ty::Str => format!("rt::dec_str({val}, \"{ctx}\")?"),
            Ty::Enum(id) => {
                let names = self.cases(id).join(", ");
                format!(
                    "{}::from_name(&rt::dec_str({val}, \"{ctx}\")?).ok_or_else(|| rt::bad(\"{ctx}\", \"not one of: {names}\"))?",
                    self.enum_path(id)?
                )
            }
            Ty::Record(id) => {
                let mut s = format!(
                    "{{ let __tb = rt::dec_table({val}, \"{ctx}\")?; {} {{ ",
                    self.enum_path(id)?
                );
                for (name, t) in self.record_fields(id)? {
                    let inner = self.dec(t, "&__f", &format!("{ctx}.{name}"))?;
                    s.push_str(&format!(
                        "{}: {{ let __f: mlua::Value = __tb.get(\"{}\")?; {inner} }}, ",
                        ident(&name, ctx)?,
                        snake(&name)
                    ));
                }
                s.push_str("} }");
                s
            }
        })
    }

    fn enc(&self, t: Ty, e: &str, ctx: &str) -> Result<String> {
        Ok(match t {
            Ty::Bool => format!("mlua::Value::Boolean({e})"),
            Ty::Int(i) if i.wide() => {
                if i == Int::U64 {
                    format!("rt::enc_u64({e}, \"{ctx}\")?")
                } else {
                    format!("rt::enc_i64({e}, \"{ctx}\")?")
                }
            }
            Ty::Int(_) | Ty::F32 => format!("mlua::Value::Number(f64::from({e}))"),
            Ty::F64 => format!("mlua::Value::Number({e})"),
            Ty::Str => format!("rt::enc_str(__lua, &{e})?"),
            Ty::Enum(_) => format!("rt::enc_str(__lua, {e}.as_str())?"),
            Ty::Record(id) => {
                let mut s = String::from("{ let __rt = __lua.create_table()?; ");
                for (name, t) in self.record_fields(id)? {
                    let field = format!("{e}.{}", ident(&name, ctx)?);
                    s.push_str(&format!(
                        "__rt.set(\"{}\", {})?; ",
                        snake(&name),
                        self.enc(t, &field, ctx)?
                    ));
                }
                s.push_str("mlua::Value::Table(__rt) }");
                s
            }
        })
    }

    // ---- component host conversions

    /// The wasm value E (of type T) as our own type.
    fn from_wasm(t: Ty, e: &str) -> String {
        match t {
            Ty::Enum(_) | Ty::Record(_) => format!("{e}.into()"),
            _ => e.to_string(),
        }
    }

    fn ret_from_ours(r: Ret, e: &str) -> String {
        match r {
            Ret::Nothing => e.to_string(),
            Ret::Plain(Ty::Enum(_) | Ty::Record(_)) => format!("{e}.into()"),
            Ret::Plain(_) => e.to_string(),
            Ret::Result(Some(Ty::Enum(_) | Ty::Record(_)), _) => {
                format!("{e}.map(|__v| __v.into()).map_err(Into::into)")
            }
            Ret::Result(_, _) => format!("{e}.map_err(Into::into)"),
        }
    }

    fn ret_from_wasm(r: Ret, e: &str) -> String {
        Self::ret_from_ours(r, e)
    }
}

fn kind_name(k: &TypeDefKind) -> &'static str {
    match k {
        TypeDefKind::Record(_) => "a record",
        TypeDefKind::Resource => "a resource",
        TypeDefKind::Handle(_) => "a handle",
        TypeDefKind::Flags(_) => "flags",
        TypeDefKind::Tuple(_) => "a tuple",
        TypeDefKind::Variant(_) => "a variant",
        TypeDefKind::Enum(_) => "an enum",
        TypeDefKind::Option(_) => "an option",
        TypeDefKind::Result(_) => "a result",
        TypeDefKind::List(_) => "a list",
        TypeDefKind::Future(_) => "a future",
        TypeDefKind::Stream(_) => "a stream",
        _ => "this type",
    }
}

#[derive(Default)]
struct Body {
    enums: String,
    api: String,
    exports: String,
}

/// The bindings for WORLD of the WIT package in WIT_DIR.
pub fn generate(wit_dir: &Path, world: &str, o: &Options) -> Result<Output> {
    let group = UnresolvedPackageGroup::parse_dir(wit_dir)
        .map_err(|e| fail("The API definition could not be read.").with_detail(format!("{e:#}")))?;
    let mut r = Resolve::new();
    let pkg = r
        .push_group(group)
        .map_err(|e| fail("The API definition is not valid.").with_detail(format!("{e:?}")))?;
    let wid = r
        .select_world(&[pkg], Some(world))
        .map_err(|e| fail(format!("no world `{world}`")).with_detail(format!("{e:#}")))?;
    generate_world(&r, wid, o)
}

fn generate_world(r: &Resolve, wid: WorldId, o: &Options) -> Result<Output> {
    let exported = r.worlds[wid]
        .exports
        .values()
        .filter_map(|item| match item {
            WorldItem::Interface { id, .. } => Some(*id),
            _ => None,
        })
        .collect();
    let g = Gen { r, o, exported };
    let w = &r.worlds[wid];

    let mut imports = Vec::new();
    for item in w.imports.values() {
        match item {
            WorldItem::Interface { id, .. } => imports.push(g.iface(*id)?),
            WorldItem::Function(f) => {
                return Err(fail(format!(
                    "{}: world-level functions are not supported",
                    f.name
                )));
            }
            WorldItem::Type { .. } => {}
        }
    }
    let mut exports = Vec::new();
    for item in w.exports.values() {
        match item {
            WorldItem::Interface { id, .. } => exports.push(g.iface(*id)?),
            WorldItem::Function(f) => {
                return Err(fail(format!(
                    "{}: world-level functions are not supported",
                    f.name
                )));
            }
            WorldItem::Type { .. } => {}
        }
    }

    // Luau's tables: a package's key is its name and version; the bare interface name only where it is unique
    let mut keys: BTreeMap<String, PackageId> = BTreeMap::new();
    for i in &imports {
        let p = g.pkg_of(i.id)?;
        let key = g.pkg_key(p);
        if let Some(other) = keys.insert(key.clone(), p)
            && other != p
        {
            return Err(fail(format!(
                "{} and {} both map to the Luau table `{key}`",
                pkg_label(r, other),
                pkg_label(r, p)
            )));
        }
    }
    let mut count: BTreeMap<&str, usize> = BTreeMap::new();
    for i in &imports {
        *count.entry(i.wit.as_str()).or_default() += 1;
    }

    // every enum an imported or exported interface owns, so each is declared where it is owned
    let mut modules: BTreeMap<String, BTreeMap<String, Body>> = BTreeMap::new();
    let mut seen_ifaces: Vec<InterfaceId> = Vec::new();
    for i in imports.iter().chain(exports.iter()) {
        if !seen_ifaces.contains(&i.id) {
            seen_ifaces.push(i.id);
        }
        for f in &i.funcs {
            for t in f.params.iter().map(|(_, t)| *t).chain(ret_tys(f.ret)) {
                if let Ty::Enum(id) | Ty::Record(id) = t {
                    let owner = g.enum_owner(id)?.0;
                    if !seen_ifaces.contains(&owner) {
                        seen_ifaces.push(owner);
                    }
                }
            }
        }
    }
    for iid in &seen_ifaces {
        let label = g.iface_label(*iid)?;
        let it = &r.interfaces[*iid];
        let p = g.pkg_of(*iid)?;
        let pkg = g.pkg_module(p);
        let module = ident(it.name.as_deref().unwrap_or_default(), &label)?;
        let body = modules.entry(pkg).or_default().entry(module).or_default();
        for tid in it.types.values() {
            let d = &r.types[*tid];
            if let TypeDefKind::Record(_) = &d.kind {
                let name = camel(d.name.as_deref().unwrap_or_default(), &label)?;
                body.enums.push_str(&record_code(&g, *tid, &name)?);
            }
            if let TypeDefKind::Enum(e) = &d.kind {
                let name = camel(d.name.as_deref().unwrap_or_default(), &label)?;
                let cases = e
                    .cases
                    .iter()
                    .map(|c| camel(&c.name, &label))
                    .collect::<Result<Vec<_>>>()?;
                body.enums
                    .push_str(&enum_code(&g, *tid, &name, &cases, &e.cases)?);
            }
        }
    }

    let mut bound = Vec::new();
    let mut luau = String::new();
    let mut wasm = String::new();
    let mut link = String::new();
    let mut traits = Vec::new();

    for i in &imports {
        let label = g.iface_label(i.id)?;
        let trait_path = format!("{}::{}::{}::Api", o.generated, i.pkg, i.module);
        traits.push(trait_path.clone());
        let body = modules
            .entry(i.pkg.clone())
            .or_default()
            .entry(i.module.clone())
            .or_default();
        let mut tr = String::from("pub trait Api {\n");
        for f in &i.funcs {
            let mut sig = String::new();
            for (n, t) in &f.params {
                put!(sig, ", {}: {}", ident(n, &f.ctx)?, g.rust_ty(*t)?)?;
            }
            putln!(
                tr,
                "    fn {}(&mut self, __caller: &{}{sig}) -> {};",
                ident(&f.wit, &label)?,
                o.caller,
                g.ret_ty(f.ret, false)?
            )?;
        }
        tr.push_str("}\n");
        body.api = tr;

        // Luau
        let p = g.pkg_of(i.id)?;
        putln!(luau, "    {{\n        let __t = lua.create_table()?;")?;
        for f in &i.funcs {
            bound.push(format!("{}.{}", i.wit, f.wit));
            luau.push_str(&luau_fn(&g, &trait_path, f, &label)?);
        }
        putln!(
            luau,
            "        __t.set_readonly(true);\n        __p_{}.set(\"{}\", __t.clone())?;",
            g.pkg_module(p),
            snake(&i.wit)
        )?;
        if count.get(i.wit.as_str()) == Some(&1) {
            putln!(luau, "        __d.set(\"{}\", __t)?;", snake(&i.wit))?;
        }
        luau.push_str("    }\n");

        // the component host
        let wp = g.wasm_iface(i.id)?;
        putln!(wasm, "impl<A: {trait_path}> {wp}::Host for WasmApi<A> {{")?;
        for f in &i.funcs {
            let mut sig = String::new();
            let mut args = Vec::new();
            for (n, t) in &f.params {
                put!(sig, ", {}: {}", ident(n, &f.ctx)?, g.wasm_ty(*t)?)?;
                args.push(Gen::from_wasm(*t, &ident(n, &f.ctx)?));
            }
            let name = ident(&f.wit, &label)?;
            let call = format!(
                "{trait_path}::{name}(__m, &__c{})",
                args.iter().map(|a| format!(", {a}")).collect::<String>()
            );
            let back = Gen::ret_from_ours(f.ret, "__r");
            putln!(
                wasm,
                "    fn {name}(&mut self{sig}) -> wasmtime::Result<{}> {{\n        let __c = rt::caller(&self.1);\n        rt::with_wasm(&*self.0, \"{}\", |__m| {call}).map(|__r| {back})\n    }}",
                g.ret_ty(f.ret, true)?,
                f.ctx
            )?;
        }
        wasm.push_str("}\n");
        putln!(
            link,
            "    {wp}::add_to_linker::<{}, wasmtime::component::HasSelf<WasmApi<A>>>(__linker, |__s| &mut __s.{})?;",
            o.state,
            o.api_field
        )?;
    }

    let mut export_names = Vec::new();
    let ext_ty = camel(&w.name, &format!("world {}", w.name))?;
    for i in &exports {
        let p = g.pkg_of(i.id)?;
        let acc = format!(
            "{}_{}_{}",
            bindgen_ident(&r.packages[p].name.namespace),
            bindgen_ident(&r.packages[p].name.name),
            bindgen_ident(&i.wit)
        );
        let body = modules
            .entry(i.pkg.clone())
            .or_default()
            .entry(i.module.clone())
            .or_default();
        for f in &i.funcs {
            export_names.push(format!("{}.{}", i.wit, f.wit));
            body.exports.push_str(&export_fn(&g, f, &acc, &ext_ty)?);
        }
    }

    let mut out = String::new();
    putln!(
        out,
        "// @generated by mal-gen from world `{}`. Do not edit.",
        w.name
    )?;
    for (pkg, ifaces) in &modules {
        putln!(out, "pub mod {pkg} {{")?;
        let mut ex = String::new();
        for (module, b) in ifaces {
            putln!(out, "pub mod {module} {{\n{}{}}}", b.enums, b.api)?;
            if !b.exports.is_empty() {
                putln!(
                    ex,
                    "pub mod {module} {{\nuse {}::rt;\n{}}}",
                    o.generated,
                    b.exports
                )?;
            }
        }
        if !ex.is_empty() {
            putln!(out, "pub mod exports {{\n{ex}}}")?;
        }
        out.push_str("}\n");
    }
    out.push_str("");
    out.push_str(RT);
    putln!(out, "pub const BOUND: &[&str] = &[{}];", quoted(&bound))?;
    putln!(
        out,
        "pub const EXPORTS: &[&str] = &[{}];",
        quoted(&export_names)
    )?;
    let versions: Vec<String> = keys
        .values()
        .filter_map(|p| {
            r.packages[*p]
                .name
                .version
                .as_ref()
                .map(ToString::to_string)
        })
        .collect();
    if let [v] = versions.as_slice() {
        putln!(out, "pub const API_VERSION: &str = \"{v}\";")?;
    }
    putln!(
        out,
        "/// Every interface's `Api` in one trait: what the editor implements.\npub trait Api: {} {{}}\nimpl<T: {}> Api for T {{}}",
        if traits.is_empty() {
            "Sized".to_string()
        } else {
            traits.join(" + ")
        },
        if traits.is_empty() {
            "Sized".to_string()
        } else {
            traits.join(" + ")
        }
    )?;
    putln!(
        out,
        "pub fn install_luau<A: Api + 'static>(lua: &mlua::Lua, api: &std::sync::Arc<std::sync::Mutex<A>>, caller: &std::sync::Arc<std::sync::RwLock<{}>>) -> mlua::Result<()> {{\n    let __d = lua.create_table()?;",
        o.caller
    )?;
    for p in keys.values() {
        putln!(
            out,
            "    let __p_{} = lua.create_table()?;",
            g.pkg_module(*p)
        )?;
    }
    out.push_str(&luau);
    for (key, p) in &keys {
        putln!(
            out,
            "    __p_{m}.set_readonly(true);\n    __d.set(\"{key}\", __p_{m})?;",
            m = g.pkg_module(*p)
        )?;
    }
    if let [v] = versions.as_slice() {
        putln!(out, "    __d.set(\"api_version\", \"{v}\")?;")?;
    }
    putln!(
        out,
        "    __d.set_readonly(true);\n    lua.globals().set(\"{}\", __d)?;\n    Ok(())\n}}",
        o.global
    )?;
    putln!(
        out,
        "pub struct WasmApi<A>(pub std::sync::Arc<std::sync::Mutex<A>>, pub std::sync::Arc<std::sync::RwLock<{}>>);",
        o.caller
    )?;
    out.push_str(&wasm);
    putln!(
        out,
        "pub fn wasm_link<A: Api + Send + 'static>(__linker: &mut wasmtime::component::Linker<{}>) -> wasmtime::Result<()> {{\n{link}    Ok(())\n}}",
        o.state
    )?;
    Ok(Output {
        rust: out,
        bound,
        exports: export_names,
    })
}

fn quoted(v: &[String]) -> String {
    v.iter()
        .map(|b| format!("\"{b}\""))
        .collect::<Vec<_>>()
        .join(", ")
}

fn ret_tys(r: Ret) -> Vec<Ty> {
    match r {
        Ret::Nothing => vec![],
        Ret::Plain(t) => vec![t],
        Ret::Result(ok, e) => ok.into_iter().chain([e]).collect(),
    }
}

fn enum_code(
    g: &Gen,
    tid: TypeId,
    name: &str,
    cases: &[String],
    raw: &[wit_parser::EnumCase],
) -> Result<String> {
    let mut s = String::new();
    putln!(
        s,
        "#[derive(Clone, Copy, Debug, PartialEq, Eq)]\npub enum {name} {{ {} }}",
        cases.join(", ")
    )?;
    let to_str = cases
        .iter()
        .zip(raw)
        .map(|(c, w)| format!("Self::{c} => \"{}\"", w.name))
        .collect::<Vec<_>>()
        .join(", ");
    let from_str = cases
        .iter()
        .zip(raw)
        .map(|(c, w)| format!("\"{}\" => Some(Self::{c})", w.name))
        .collect::<Vec<_>>()
        .join(", ");
    putln!(
        s,
        "impl {name} {{\n    pub fn as_str(self) -> &'static str {{ match self {{ {to_str} }} }}\n    pub fn from_name(s: &str) -> Option<Self> {{ match s {{ {from_str}, _ => None }} }}\n}}"
    )?;
    let wasm = g.wasm_enum_path(tid)?;
    putln!(
        s,
        "impl From<{name}> for {wasm} {{ fn from(e: {name}) -> Self {{ match e {{ {}  }} }} }}",
        cases
            .iter()
            .map(|c| format!("{name}::{c} => Self::{c}"))
            .collect::<Vec<_>>()
            .join(", ")
    )?;
    putln!(
        s,
        "impl From<{wasm}> for {name} {{ fn from(e: {wasm}) -> Self {{ match e {{ {}  }} }} }}",
        cases
            .iter()
            .map(|c| format!("{wasm}::{c} => Self::{c}"))
            .collect::<Vec<_>>()
            .join(", ")
    )?;
    Ok(s)
}

fn luau_fn(g: &Gen, trait_path: &str, f: &Func, label: &str) -> Result<String> {
    let mut s = String::new();
    let n = f.params.len();
    let mut args = Vec::new();
    let mut decode = String::new();
    for (k, (pn, t)) in f.params.iter().enumerate() {
        let ctx = format!("{}({pn})", f.ctx);
        putln!(
            decode,
            "            let __p{k} = {};",
            g.dec(*t, &format!("&__a[{k}]"), &ctx)?
        )?;
        args.push(format!("__p{k}"));
    }
    let name = ident(&f.wit, label)?;
    let encode = match f.ret {
        Ret::Nothing => "Ok(mlua::MultiValue::new())".to_string(),
        Ret::Plain(t) => format!(
            "Ok([{}].into_iter().collect::<mlua::MultiValue>())",
            g.enc(t, "__r", &f.ctx)?
        ),
        Ret::Result(ok, err) => {
            let errv = g.enc(err, "__e", &f.ctx)?;
            let okv = match ok {
                Some(t) => g.enc(t, "__v", &f.ctx)?,
                None => "mlua::Value::Boolean(true)".to_string(),
            };
            format!(
                "Ok(match __r {{\n                Ok(__v) => [{okv}].into_iter().collect::<mlua::MultiValue>(),\n                Err(__e) => [mlua::Value::Nil, {errv}].into_iter().collect::<mlua::MultiValue>(),\n            }})"
            )
        }
    };
    putln!(
        s,
        "        {{\n        let __api = std::sync::Arc::clone(api);\n        let __caller = std::sync::Arc::clone(caller);\n        __t.set(\"{}\", lua.create_function(move |__lua, __args: mlua::MultiValue| -> mlua::Result<mlua::MultiValue> {{\n            let __a: Vec<mlua::Value> = __args.into_iter().collect();\n            rt::arity(\"{}\", &__a, {n})?;\n{decode}            let __c = rt::caller(&__caller);\n            let __r = rt::with_api(&*__api, \"{}\", |__m| {trait_path}::{name}(__m, &__c{}))?;\n            {encode}\n        }})?)?;\n        }}",
        snake(&f.wit),
        f.ctx,
        f.ctx,
        args.iter().map(|a| format!(", {a}")).collect::<String>()
    )?;
    Ok(s)
}

fn export_fn(g: &Gen, f: &Func, acc: &str, ext_ty: &str) -> Result<String> {
    let mut s = String::new();
    let name = snake(&f.wit);
    let mut sig = String::new();
    let mut enc = Vec::new();
    let mut wargs = Vec::new();
    for (pn, t) in &f.params {
        let id = ident(pn, &f.ctx)?;
        let ty = match t {
            Ty::Str => "&str".to_string(),
            other => g.rust_ty(*other)?,
        };
        put!(sig, ", {id}: {ty}")?;
        let ctx = format!("{}({pn})", f.ctx);
        enc.push(match t {
            Ty::Str => format!("rt::enc_str(__lua, {id})?"),
            Ty::Enum(_) => format!("rt::enc_str(__lua, {id}.as_str())?"),
            other => g.enc(*other, &id, &ctx)?,
        });
        wargs.push(match t {
            Ty::Enum(_) => format!("{id}.into()"),
            _ => id,
        });
    }
    let ret = g.ret_ty(f.ret, false)?;
    let ctx = &f.ctx;
    let interpret = match f.ret {
        Ret::Nothing => format!(
            "    if !__v.is_empty() {{ return Err(rt::contract(\"{ctx}\", \"values returned by a function with no result\")); }}\n    Ok(())"
        ),
        Ret::Plain(t) => format!(
            "    if __v.len() != 1 {{ return Err(rt::contract(\"{ctx}\", \"exactly one value is expected\")); }}\n    Ok({})",
            g.dec(t, "&__v[0]", ctx)?
        ),
        Ret::Result(ok, e) => {
            let errdec = g.dec(e, "&__v[1]", ctx)?;
            let okv = match ok {
                Some(t) => format!("Ok(Ok({}))", g.dec(t, "&__v[0]", ctx)?),
                None => format!(
                    "if !matches!(__v[0], mlua::Value::Boolean(true)) {{ return Err(rt::contract(\"{ctx}\", \"success is `true`\")); }}\n    Ok(Ok(()))"
                ),
            };
            format!(
                "    if __v.len() == 2 && matches!(__v[0], mlua::Value::Nil) {{\n        return Ok(Err({errdec}));\n    }}\n    if __v.len() != 1 || matches!(__v[0], mlua::Value::Nil) {{ return Err(rt::contract(\"{ctx}\", \"a result is `value`, or `nil, error`\")); }}\n    {okv}"
            )
        }
    };
    putln!(
        s,
        "pub fn luau_{name}(__lua: &mlua::Lua, __ext: &mlua::Table{sig}) -> mlua::Result<{ret}> {{\n    let __f: mlua::Function = __ext.get(\"{name}\")?;\n    let __args: mlua::MultiValue = [{}].into_iter().collect();\n    let __v: Vec<mlua::Value> = __f.call::<mlua::MultiValue>(__args)?.into_iter().collect();\n{interpret}\n}}",
        enc.join(", ")
    )?;
    let wret = g.ret_ty(f.ret, false)?;
    let conv = Gen::ret_from_wasm(f.ret, "__r");
    let body = if matches!(f.ret, Ret::Nothing) {
        format!(
            "__ext.{acc}().call_{name}(__store{})?;\n    Ok(())",
            wargs.iter().map(|a| format!(", {a}")).collect::<String>()
        )
    } else {
        format!(
            "let __r = __ext.{acc}().call_{name}(__store{})?;\n    Ok({conv})",
            wargs.iter().map(|a| format!(", {a}")).collect::<String>()
        )
    };
    putln!(
        s,
        "pub fn wasm_{name}(__store: impl wasmtime::AsContextMut, __ext: &{}::{ext_ty}{sig}) -> wasmtime::Result<{wret}> {{\n    {body}\n}}",
        g.o.bindings
    )?;
    Ok(s)
}

/// A record as a Rust struct, and its conversions to and from bindgen's.
fn record_code(g: &Gen, tid: TypeId, name: &str) -> Result<String> {
    let mut s = String::new();
    let fields = g.record_fields(tid)?;
    let wasm = g.wasm_enum_path(tid)?;
    let mut decl = String::new();
    let mut to_wasm = String::new();
    let mut from_wasm = String::new();
    for (n, t) in &fields {
        let ours = ident(n, name)?;
        let theirs = bindgen_ident(n);
        decl.push_str(&format!("pub {ours}: {}, ", g.rust_ty(*t)?));
        let conv = |v: String| match t {
            Ty::Enum(_) | Ty::Record(_) => format!("{v}.into()"),
            _ => v,
        };
        to_wasm.push_str(&format!("{theirs}: {}, ", conv(format!("e.{ours}"))));
        from_wasm.push_str(&format!("{ours}: {}, ", conv(format!("e.{theirs}"))));
    }
    putln!(
        s,
        "#[derive(Clone, Debug, PartialEq)]\npub struct {name} {{ {decl}}}"
    )?;
    putln!(
        s,
        "impl From<{name}> for {wasm} {{ fn from(e: {name}) -> Self {{ Self {{ {to_wasm}}} }} }}"
    )?;
    putln!(
        s,
        "impl From<{wasm}> for {name} {{ fn from(e: {wasm}) -> Self {{ Self {{ {from_wasm}}} }} }}"
    )?;
    Ok(s)
}
