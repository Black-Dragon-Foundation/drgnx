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
pub const MIGRATIONS: &[(u32, &str)] = &[(1, V1)];

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
