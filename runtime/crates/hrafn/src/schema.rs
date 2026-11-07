//! The code store's schema, as migrations for `urdr` (data, applied once under `BEGIN IMMEDIATE`).
//!
//! `urdr` owns the `meta(key, value)` table and its `schema` row; the store's own facts (`chunker_version`,
//! `built_from`, `instruction:<model>:<scope>`, the corpus mean) live in the same table.

/// Schema v1.
///
/// - `chunk_fts` is contentless (`contentless_delete=1`, SQLite 3.43 or later) with rowid = `chunk.id`, so a chunk's
///   text is stored once, in `chunk.embed_text`. A trigger removes the FTS row, and the chunk's symbols, with the chunk.
/// - FTS5 has one tokenizer per table, so the symbol column is encoded (see [`encode_symbol`]) rather than given
///   its own token characters, which would hide `timer` in `body`.
/// - `vec` keys on `(model, key)`: the content's key is shared by every model that embedded it.
const V1: &str = "
create table file(
  path text primary key,
  blob text not null,
  class text not null,
  lang text not null,
  generated integer not null default 0,
  size integer not null,
  indexed_at integer not null
);

create table chunk(
  id integer primary key,
  path text not null,
  start integer not null,
  end integer not null,
  line_start integer not null,
  line_end integer not null,
  symbol text,
  key blob not null,
  embed integer not null default 1,
  embed_text text not null
);
create index chunk_path on chunk(path);
create index chunk_key on chunk(key);

create virtual table chunk_fts using fts5(
  path, symbols, doc, body,
  content = '', contentless_delete = 1
);

create table symbol(
  name text not null,
  kind text not null,
  path text not null,
  start integer not null,
  end integer not null,
  chunk integer not null,
  definer text not null,
  doc1 text
);
create index symbol_name on symbol(name);
create index symbol_chunk on symbol(chunk);
create index symbol_path on symbol(path);

create virtual table symbol_fts using fts5(
  name,
  content = '', contentless_delete = 1, tokenize = 'trigram'
);

create trigger symbol_ai after insert on symbol begin
  insert into symbol_fts(rowid, name) values (new.rowid, new.name);
end;
create trigger symbol_ad after delete on symbol begin
  delete from symbol_fts where rowid = old.rowid;
end;
create trigger chunk_ad after delete on chunk begin
  delete from chunk_fts where rowid = old.id;
  delete from symbol where chunk = old.id;
end;

create table vec(
  model text not null,
  dims integer not null,
  key blob not null,
  bits integer not null,
  vec blob not null,
  scale real not null,
  last_used integer not null,
  primary key(model, key)
);
create index vec_used on vec(model, last_used);
";

/// The migrations for `urdr::StoreSpec`.
pub const MIGRATIONS: &[(u32, &str)] = &[(1, V1), (2, V2), (3, V3)];

/// The indexes of a query's own passes: the lag's counts run on the first (the chunk rows hold their text, so counting
/// them through the table reads the whole store on every query); the second serves the symbol-name prefix, which `like`
/// matches without regard to case.
const V2: &str = "create index chunk_embed on chunk(embed, key, path);
create index symbol_name_nc on symbol(name collate nocase);";

/// Schema v3: per-worktree overlays over shared content (H16 overlay design §3, §9).
///
/// - `tree` registers the worktrees; `file` is the only per-tree table (`tree = 0` is the base), and a NULL `blob`
///   in a tree's row marks a path the tree does not have (a tombstone, which needs no other column).
/// - Chunks and symbols are keyed by `(path, blob)` and shared by every `file` row that names the pair; the pair's
///   rows go when the last such row goes (the reference sweep, `store::sweep`), so there is no counter to drift.
/// - `chunk_path_blob` carries `embed` and `key`, so a worktree's lag delta counts its rows' chunks on the index alone.
/// - The data is migrated in place: `chunk` gains its `blob` (its ids, and so `chunk_fts`'s rowids and the vectors'
///   keys, are kept: nothing is re-chunked or re-embedded); `symbol` is rebuilt with `id` set from its old rowid, so
///   `symbol_fts` keeps its link and the ids survive `VACUUM`. The triggers name `symbol`, so they are dropped
///   around the rebuild and made again on `id`.
const V3: &str = "
create table tree(
  id integer primary key check (id > 0),
  key text not null unique,
  root text not null,
  git_dir text not null,
  branch text,
  head text,
  seeded_from text,
  door text not null check (door in ('cli', 'gix')),
  state text not null default 'seeding' check (state in ('seeding', 'live', 'stale', 'unwatched')),
  last_used integer not null default 0
);

create table file_v3(
  tree integer not null default 0,
  path text not null,
  blob text,
  class text not null default '',
  lang text not null default '',
  generated integer not null default 0,
  size integer not null default 0,
  indexed_at integer not null default 0,
  primary key(tree, path),
  check (blob is not null or tree > 0)
) without rowid;
insert into file_v3(tree, path, blob, class, lang, generated, size, indexed_at)
  select 0, path, blob, class, lang, generated, size, indexed_at from file;
drop table file;
alter table file_v3 rename to file;
create index file_path_blob on file(path, blob);

alter table chunk add column blob text not null default '';
update chunk set blob = coalesce((select f.blob from file f where f.tree = 0 and f.path = chunk.path), '');
drop index chunk_path;
create index chunk_path_blob on chunk(path, blob, embed, key);
drop index chunk_embed;
create index chunk_embed on chunk(embed, key, path, blob);

drop trigger chunk_ad;
drop trigger symbol_ai;
drop trigger symbol_ad;
create table symbol_v3(
  id integer primary key,
  name text not null,
  kind text not null,
  path text not null,
  blob text not null,
  start integer not null,
  end integer not null,
  chunk integer not null,
  definer text not null,
  doc1 text
);
insert into symbol_v3(id, name, kind, path, blob, start, end, chunk, definer, doc1)
  select s.rowid, s.name, s.kind, s.path, coalesce(c.blob, ''), s.start, s.end, s.chunk, s.definer, s.doc1
  from symbol s left join chunk c on c.id = s.chunk;
drop table symbol;
alter table symbol_v3 rename to symbol;
create index symbol_name on symbol(name);
create index symbol_name_nc on symbol(name collate nocase);
create index symbol_chunk on symbol(chunk);
create index symbol_path_blob on symbol(path, blob);

create trigger symbol_ai after insert on symbol begin
  insert into symbol_fts(rowid, name) values (new.id, new.name);
end;
create trigger symbol_ad after delete on symbol begin
  delete from symbol_fts where rowid = old.id;
end;
create trigger chunk_ad after delete on chunk begin
  delete from chunk_fts where rowid = old.id;
  delete from symbol where chunk = old.id;
end;
";

/// A Lisp symbol made one `unicode61` token. `unicode61` splits on every character that is not a letter, a number or
/// a private-use character (category Co), so `drgnx-timer--fire` would be three tokens. Each ASCII punctuation
/// character is mapped to the private-use character U+E000 plus its code, which is a token character by default.
/// The same function runs on write and on query, so a whole name matches the whole name, and `body`, which is not
/// encoded, still splits it.
pub fn encode_symbol(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_punctuation() {
                char::from_u32(0xE000 + c as u32).unwrap_or(c)
            } else {
                c
            }
        })
        .collect()
}
