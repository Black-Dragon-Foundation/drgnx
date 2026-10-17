;;; drgnx-search-store.el --- The search index's store: one SQLite file per project -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Semantic code search keeps, per project, one SQLite file (Emacs's own SQLite, 29+) in drgnx's state
;; dir: the chunks of every indexed file, an FTS5 index of their text (kept in step by triggers), and
;; each chunk's embedding twice — a 1-bit fingerprint (the sign of each dimension) to rank every chunk
;; cheaply, and int8 values with a scale to re-rank the best.  The indexer writes through
;; `drgnx-search-store-put-file'; the query engine reads the fingerprints into one flat vector, then
;; fetches the vectors and text of only the candidates.  See docs/guide/search.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'sqlite)                       ; with-sqlite-transaction

(defvar read-eval)                      ; `let'-bound in `-meta': must be dynamic once compiled

(defconst drgnx-search-store-schema-version 1)

(defconst drgnx-search-store--schema
  '("create table if not exists file (path text primary key, hash text, chunks integer)"
    "create table if not exists chunk (id integer primary key, path text, start_line integer, end_line integer,
     text text, bits blob, vec blob, scale real)"
    "create index if not exists chunk_path on chunk(path)"
    "create virtual table if not exists chunk_fts using fts5 (text, content='chunk', content_rowid='id',
     tokenize=\"unicode61 tokenchars '_'\")"
    "create trigger if not exists chunk_ai after insert on chunk begin
       insert into chunk_fts (rowid, text) values (new.id, new.text);
     end"
    "create trigger if not exists chunk_ad after delete on chunk begin
       insert into chunk_fts (chunk_fts, rowid, text) values ('delete', old.id, old.text);
     end"
    "create trigger if not exists chunk_au after update on chunk begin
       insert into chunk_fts (chunk_fts, rowid, text) values ('delete', old.id, old.text);
       insert into chunk_fts (rowid, text) values (new.id, new.text);
     end")
  "The schema, version 1: every statement is idempotent.")

(defconst drgnx-search-store--word-bytes 7
  "Bytes of a fingerprint per word: 56 bits fit a fixnum (62 bits) with room to xor.")

;;;; Quantizing

(defun drgnx-search-quantize (vector)
  "Quantize the float VECTOR (already normalised): (BITS INT8 SCALE).
BITS is a unibyte string of ceil(dims/8) bytes, bit i%8 of byte i/8 set when dimension i > 0; INT8 a
unibyte string of one two's complement byte per dimension, round(v/SCALE) in -127..127; SCALE is
max|v|/127 (0.0 for the zero vector)."
  (let* ((n (length vector))
         (bits (make-string (ceiling n 8) 0))
         (int8 (make-string n 0))
         (peak 0.0))
    (dotimes (i n) (setq peak (max peak (abs (float (aref vector i))))))
    (let ((scale (/ peak 127.0)))
      (dotimes (i n)
        (let ((v (float (aref vector i))))
          (when (> v 0.0)
            (let ((byte (ash i -3)))
              (aset bits byte (logior (aref bits byte) (ash 1 (logand i 7))))))
          (unless (zerop scale)
            (aset int8 i (logand (round (/ v scale)) 255)))))
      (list (string-to-unibyte bits) (string-to-unibyte int8) scale))))

(defun drgnx-search-bits-words (bits)
  "The fingerprint BITS (a unibyte string) as a vector of fixnums, 7 bytes (56 bits) per word, the last
word zero-padded — the form `drgnx-search-store-fingerprints' returns, for ranking by Hamming distance."
  (let* ((per drgnx-search-store--word-bytes)
         (words (make-vector (ceiling (length bits) per) 0)))
    (dotimes (i (length bits))
      (let ((w (/ i per)))
        (aset words w (logior (aref words w) (ash (aref bits i) (* 8 (% i per)))))))
    words))

(defun drgnx-search-store--blob (string)
  "STRING (unibyte) marked to be bound as a BLOB, not as text."
  (propertize string 'coding-system 'binary))

;;;; The file

(defun drgnx-search-store-file (root)
  "The index file of the project at ROOT: search/<16 hex of sha1 of the root path>.db in the state dir."
  (expand-file-name (format "search/%s.db" (substring (sha1 (directory-file-name (expand-file-name root))) 0 16))
                    (drgnx-state-dir)))

(defun drgnx-search-store--schema-of (db)
  "The schema version DB records (0 when it has none yet), read without taking the write lock."
  (or (ignore-errors (plist-get (drgnx-search-store-meta db) :schema)) 0))

(defun drgnx-search-store--newer-error (have)
  (user-error "Search index is schema %d, newer than this drgnx (%d): update drgnx"
              have drgnx-search-store-schema-version))

(defun drgnx-search-store--init (db)
  "Create (or complete) the schema in DB; refuse a database newer than this drgnx.
An index that is current is only read: the write lock is for creating or completing it."
  (let ((have (drgnx-search-store--schema-of db)))
    (when (> have drgnx-search-store-schema-version) (drgnx-search-store--newer-error have))
    (unless (= have drgnx-search-store-schema-version)
      ;; one writer at a time: the version is read again under the write lock, so two Emacsen opening a
      ;; fresh index create it once
      (sqlite-execute db "begin immediate")
      (condition-case err
          (progn
            (sqlite-execute db "create table if not exists meta (key text primary key, value text)")
            (let ((have (drgnx-search-store--schema-of db)))
              (when (> have drgnx-search-store-schema-version) (drgnx-search-store--newer-error have))
              (dolist (sql drgnx-search-store--schema) (sqlite-execute db sql))
              (drgnx-search-store--put-meta db (list :schema drgnx-search-store-schema-version)))
            (sqlite-execute db "commit"))
        (error (ignore-errors (sqlite-execute db "rollback"))
               (signal (car err) (cdr err)))))))

(defun drgnx-search-store-open (root)
  "Open (creating it when new) the index of the project at ROOT.  The caller closes it (`sqlite-close')."
  (let ((file (drgnx-search-store-file root)))
    (make-directory (file-name-directory file) t)
    (let ((db (sqlite-open file)))
      (condition-case err
          (progn
            (sqlite-pragma db "busy_timeout = 5000")   ; another Emacs writing: wait, never fail at once
            (sqlite-pragma db "journal_mode = WAL")    ; readers see a snapshot while the indexer writes
            (drgnx-search-store--init db)
            db)
        (error (ignore-errors (sqlite-close db))
               (signal (car err) (cdr err)))))))

(defun drgnx-search-store-open-read (root)
  "Open the index of the project at ROOT for reading, or nil when it has none.  For queries: it never
creates the file or the schema, never takes the write lock and never writes the meta, so a search neither
waits for the indexer nor disturbs it (the file is WAL: a reader sees a snapshot while a writer works).
The caller closes it (`sqlite-close')."
  (let ((file (drgnx-search-store-file root)))
    (when (file-exists-p file)
      (let ((db (sqlite-open file)))
        (condition-case err
            (progn (sqlite-pragma db "busy_timeout = 5000") db)
          (error (ignore-errors (sqlite-close db))
                 (signal (car err) (cdr err))))))))

;;;; Meta

(defun drgnx-search-store-meta (db)
  "What the index records about itself: (:schema N :provider P :model M :dims N :indexed-at TIME), the
keys that are set."
  (cl-loop for (key value) in (sqlite-select db "select key, value from meta order by key")
           append (list (intern (concat ":" key)) (let ((read-eval nil)) (car (read-from-string value))))))

(defun drgnx-search-store--put-meta (db plist)
  (cl-loop for (key value) on plist by #'cddr
           do (sqlite-execute db "insert or replace into meta values (?, ?)"
                              (list (substring (symbol-name key) 1) (prin1-to-string value)))))

(defun drgnx-search-store-set-meta (db plist)
  "Set the keys of PLIST in the meta (others stay)."
  (with-sqlite-transaction db (drgnx-search-store--put-meta db plist)))

;;;; Files and chunks

(defun drgnx-search-store-files (db)
  "A hash table: the path of every indexed file → the hash of the blob it was indexed from."
  (let ((table (make-hash-table :test #'equal)))
    (pcase-dolist (`(,path ,hash) (sqlite-select db "select path, hash from file"))
      (puthash path hash table))
    table))

(defun drgnx-search-store--bump (db key)
  "Add one to the counter KEY of the meta (it starts at 1).  Called inside the write's transaction, so a
rolled-back write leaves the counter as it was."
  (sqlite-execute db "insert into meta values (?, '1')
                      on conflict (key) do update set value = cast(value as integer) + 1"
                  (list key)))

(defun drgnx-search-store--delete (db path)
  "Remove PATH's chunks and record; when it had chunks, bump `cut' (the counter of removals)."
  (when (> (caar (sqlite-select db "select count(*) from chunk where path = ?" (list path))) 0)
    (sqlite-execute db "delete from chunk where path = ?" (list path))
    (drgnx-search-store--bump db "cut"))
  (sqlite-execute db "delete from file where path = ?" (list path)))

(defun drgnx-search-store-put-file (db path hash chunks)
  "Replace everything indexed for PATH, in one transaction: its blob HASH and CHUNKS, a list of
\(:start LINE :end LINE :text STRING :vector FLOATS).  Moves the index's generation (`-stamp')."
  (with-sqlite-transaction db
    (drgnx-search-store--delete db path)
    (dolist (chunk chunks)
      (pcase-let ((`(,bits ,int8 ,scale) (drgnx-search-quantize (plist-get chunk :vector))))
        (sqlite-execute db "insert into chunk (path, start_line, end_line, text, bits, vec, scale)
                            values (?, ?, ?, ?, ?, ?, ?)"
                        (list path (plist-get chunk :start) (plist-get chunk :end) (plist-get chunk :text)
                              (drgnx-search-store--blob bits) (drgnx-search-store--blob int8) scale))))
    (sqlite-execute db "insert into file values (?, ?, ?)" (list path hash (length chunks)))
    (drgnx-search-store--bump db "gen")))

(defun drgnx-search-store-delete-file (db path)
  "Forget PATH: its chunks (and their text index) and its record.  Moves the index's generation."
  (with-sqlite-transaction db
    (drgnx-search-store--delete db path)
    (drgnx-search-store--bump db "gen")))

;;;; Reading

(defun drgnx-search-store-stamp (db)
  "What changes when the index does: (INDEXED-AT GENERATION CUT).  GENERATION counts the writes of files
\(`put-file', `delete-file'), CUT the writes that removed chunks — both are bumped inside the write's
transaction, so ids the database reuses cannot make two states look alike.  Chunks arrive before the
indexer advances `:indexed-at', so the generation also tells a half-finished run's progress."
  (let ((meta (drgnx-search-store-meta db)))
    (list (plist-get meta :indexed-at) (plist-get meta :gen) (plist-get meta :cut))))

(defun drgnx-search-store-snapshot (db &optional since)
  "The index as of one moment, read in one transaction: (:stamp STAMP :meta META :ids IDS :words WORDS
:append APPEND) — `drgnx-search-store-stamp', `-meta' and `-fingerprints'.  A write between its pages does
not show.  SINCE is (CUT . LAST-ID) of a copy the caller holds: when no chunk was removed since (the same
CUT), only the chunks after LAST-ID are read and APPEND is t."
  (with-sqlite-transaction db
    (let* ((stamp (drgnx-search-store-stamp db))
           (append (and since (equal (car since) (nth 2 stamp))))
           (fp (drgnx-search-store-fingerprints db (and append (cdr since)))))
      (list :stamp stamp :meta (drgnx-search-store-meta db) :ids (car fp) :words (cdr fp) :append append))))

(defconst drgnx-search-store--page 5000 "Fingerprints read per query (bounds the transient rows).")

(defun drgnx-search-store-fingerprints (db &optional after)
  "Every chunk's fingerprint (those with an id above AFTER, when given): (IDS . WORDS).  IDS is a vector of
chunk ids; WORDS one flat vector of fixnums, `ceiling(dims/56)' per chunk (19 for 1024 dims) — chunk i's
words start at i times that.  No per-row objects: about 8 MB per 50 000 chunks."
  (let ((ids nil) (words nil) (after (or after -1)) rows)
    (while (setq rows (sqlite-select db "select id, bits from chunk where id > ? order by id limit ?"
                                     (list after drgnx-search-store--page)))
      (let ((page (apply #'vconcat (mapcar (lambda (r) (drgnx-search-bits-words (cadr r))) rows))))
        (push page words))
      (push (vconcat (mapcar #'car rows)) ids)
      (setq after (car (car (last rows)))))
    (cons (apply #'vconcat (nreverse ids)) (apply #'vconcat (nreverse words)))))

(defun drgnx-search-store--by-id (db ids columns row-fn)
  "An alist id → (ROW-FN of the COLUMNS row) for IDS, in the order of IDS; unknown ids are left out."
  (let ((found (make-hash-table)) (ids (append ids nil)))
    (cl-loop for batch in (seq-split ids 500)
             do (dolist (row (sqlite-select db (format "select id, %s from chunk where id in (%s)" columns
                                                       (string-join (make-list (length batch) "?") ", "))
                                            batch))
                  (puthash (car row) (funcall row-fn (cdr row)) found)))
    (cl-loop for id in ids
             when (gethash id found) collect (cons id (gethash id found)))))

(defun drgnx-search-store-vectors (db ids)
  "The int8 vectors of the chunks IDS: an alist id → (INT8 . SCALE)."
  (drgnx-search-store--by-id db ids "vec, scale" (lambda (r) (cons (nth 0 r) (nth 1 r)))))

(defun drgnx-search-store-chunks (db ids)
  "The chunks IDS: an alist id → (:path P :start LINE :end LINE :text STRING)."
  (drgnx-search-store--by-id db ids "path, start_line, end_line, text"
                             (lambda (r) (list :path (nth 0 r) :start (nth 1 r) :end (nth 2 r) :text (nth 3 r)))))

;;;; Keyword search

(defun drgnx-search-store--fts-query (query)
  "QUERY's words as quoted FTS5 tokens joined by OR — no operator, column filter or NEAR from the user
text reaches FTS5.  Nil when no word is left."
  (when (stringp query)
    (let ((words (delete-dups (split-string (replace-regexp-in-string "[^[:alnum:]_]+" " " query) " " t))))
      (and words (mapconcat (lambda (w) (concat "\"" w "\"")) words " OR ")))))

(defun drgnx-search-store-fts (db query k)
  "The K best chunks for the words of QUERY: ((ID . RANK)…), best first (RANK is bm25: lower is better).
Nil when QUERY has no usable word."
  (when-let* ((match (drgnx-search-store--fts-query query)))
    (mapcar (lambda (r) (cons (car r) (cadr r)))
            (sqlite-select db "select rowid, rank from chunk_fts where chunk_fts match ? order by rank limit ?"
                           (list match k)))))

(provide 'drgnx-search-store)
;;; drgnx-search-store.el ends here
