;;; drgnx-search-query.el --- The query engine of semantic code search -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-search' turns a question into ranked code: the question is embedded (the `embed' role), every
;; chunk's 1-bit fingerprint is compared with the question's by Hamming distance (a fixnum xor and popcount
;; per 56 dimensions — no float work for the 99% that are far away), the nearest few hundred are re-scored
;; against their int8 vectors (cosine), and that ranking is merged with the FTS5 keyword ranking by
;; reciprocal rank fusion, so an exact identifier and a paraphrase both find their chunk.
;;
;; The fingerprints of a project are read once into one flat vector and kept (`drgnx-search--cache') until
;; the index changes.  Reading never writes: the index is opened read-only in effect
;; (`drgnx-search-store-open-read'), so a search neither waits for a running indexer nor disturbs it.
;;
;; Nothing here is an error for the user: no SQLite, no index, no embedding provider, or an index made by
;; another model each leave `drgnx-search-last-notice' (one line) and return what can be answered — the
;; keyword hits, or nil.  Nothing here prompts.  See docs/guide/search.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-search-store)
(require 'drgnx-search-chunk)
(require 'drgnx-ai-client)

(defconst drgnx-search-default-k 10 "Results `drgnx-search' returns unless asked for another number.")

(defconst drgnx-search--candidates-floor 500
  "Chunks the fingerprint scan hands to the int8 rescore, at least (more for a larger K: 50 per result).
On random vectors, the worst case for a 1-bit fingerprint, 300 candidates of 1000 reach a recall@10 of
about 0.92 and 500 about 0.97.  Rescoring costs a dot product each, so this is tens of milliseconds.")

(defconst drgnx-search--rrf-k 60 "The constant of reciprocal rank fusion: a hit at rank r scores 1/(60 + r) per list.")

(defvar drgnx-search-list-depth 50
  "How many hits of each ranking (vector, keyword) enter the fusion.  A K above this is answered by at most
twice as many chunks.")

(defvar drgnx-search-last-notice nil
  "Why the last search could not do everything, as one line (nil when it did): no index, no SQLite, no
embedding provider, an index built with another model, or a .drgnx/search.eld that cannot be read.  Reset by every
search.")

;;;; The scan

(defun drgnx-search--nearest (qwords words count n)
  "The indexes (a vector, not sorted) of the N of COUNT chunks nearest to the fingerprint QWORDS.
WORDS holds the chunks' fingerprints flat, (length QWORDS) fixnums each; the distance is the number of
differing bits.  Two passes over WORDS and a histogram of distances: no sort, no per-chunk allocation.
Ties at the cut are taken in index order."
  (if (<= count n)
      (let ((all (make-vector count 0))) (dotimes (i count) (aset all i i)) all)
    (let* ((w (length qwords)) (dist (make-vector count 0))
           (hist (make-vector (1+ (* 56 w)) 0)) (pos 0))
      (dotimes (i count)
        (let ((d 0) (j 0))
          (while (< j w)
            (setq d (+ d (logcount (logxor (aref qwords j) (aref words (+ pos j))))) j (1+ j)))
          (aset dist i d)
          (aset hist d (1+ (aref hist d)))
          (setq pos (+ pos w))))
      (let ((below 0) (cut 0))                 ; the smallest distance with at least n chunks within it
        (while (< (+ below (aref hist cut)) n)
          (setq below (+ below (aref hist cut)) cut (1+ cut)))
        (let ((out (make-vector n 0)) (taken 0) (ties (- n below)))
          (dotimes (i count)
            (let ((d (aref dist i)))
              (when (or (< d cut) (and (= d cut) (> ties 0)))
                (when (= d cut) (setq ties (1- ties)))
                (aset out taken i)
                (setq taken (1+ taken)))))
          out)))))

(defun drgnx-search--dot (qint8 qscale int8 scale)
  "The cosine estimate of two quantized unit vectors: the int8 strings QINT8 (the question) and INT8 (a chunk),
two's complement bytes, each times its SCALE.  The sum is in integers (fixnums, nothing boxed per
dimension); only the result is a float."
  (let ((sum 0) (i 0) (n (length qint8)))
    (while (< i n)
      (let ((a (aref qint8 i)) (b (aref int8 i)))
        (setq sum (+ sum (* (if (> a 127) (- a 256) a) (if (> b 127) (- b 256) b)))))
      (setq i (1+ i)))
    (* sum qscale scale)))

;;;; The cache

(defvar drgnx-search--cache (make-hash-table :test #'equal)
  "Index file → (STAMP IDS WORDS): the fingerprints as of the index's STAMP (`drgnx-search-store-stamp').
Only the last project searched is kept.")

(defun drgnx-search--fingerprints (db file)
  "(IDS . WORDS) of the index DB (FILE): from the cache while its stamp is still the index's, else read —
only the chunks added since, when none was removed (an indexer run adding files)."
  (let ((entry (gethash file drgnx-search--cache)) (stamp (drgnx-search-store-stamp db)))
    (unless (equal (car entry) stamp)
      (let* ((ids (nth 1 entry))
             (snap (drgnx-search-store-snapshot
                    db (and entry (> (length ids) 0) (list (nth 3 (car entry)) (nth 2 (car entry)) (aref ids (1- (length ids)))))))
             (more (plist-get snap :append)))
        (setq entry (list (plist-get snap :stamp)
                          (if more (vconcat ids (plist-get snap :ids)) (plist-get snap :ids))
                          (if more (vconcat (nth 2 entry) (plist-get snap :words)) (plist-get snap :words))))
        (clrhash drgnx-search--cache)
        (puthash file entry drgnx-search--cache)))
    (cons (nth 1 entry) (nth 2 entry))))

;;;; Searching

(defun drgnx-search--model-name (meta)
  (or (plist-get meta :model) (plist-get meta :provider) "an unknown model"))

(defun drgnx-search--vector-problem (meta vector info)
  "Why VECTOR (the question's embedding, made by INFO's provider and model) cannot be compared with the
index described by META, or nil.  Mirrors the indexer's own check."
  (cond ((null (plist-get meta :dims)) "the index is empty — Search: Index Project")
        ((or (/= (length vector) (plist-get meta :dims))
             (and (plist-get info :provider)
                  (not (and (equal (plist-get info :provider) (plist-get meta :provider))
                            (equal (plist-get info :model) (plist-get meta :model))))))
         (format "the index was built with %s (%s); re-index"
                 (drgnx-search--model-name meta) (plist-get meta :dims)))))

(defun drgnx-search--notice (format &rest args)
  "Set `drgnx-search-last-notice' to FORMAT's text, on one line."
  (setq drgnx-search-last-notice (replace-regexp-in-string "[ \t\n]+" " " (string-trim (apply #'format format args)))))

(defun drgnx-search--ready (root)
  "Non-nil when ROOT's index can be searched; else nil, and the notice says why.
A search.eld that cannot be read refuses the query, as it stops the indexer."
  (let ((config (and (sqlite-available-p) (drgnx-search-config root))))
    (cond ((not (sqlite-available-p)) (drgnx-search--notice "this Emacs has no SQLite") nil)
          ((plist-get config :error) (drgnx-search--notice "%s" (plist-get config :error)) nil)
          ((eq t (plist-get config :off))
           (drgnx-search--notice "search is off for this project (.drgnx/search.eld)") nil)
          ((not (file-exists-p (drgnx-search-store-file root)))
           (drgnx-search--notice "no index for this project — Search: Index Project") nil)
          (t t))))

(defun drgnx-search-hit-line (hit)
  "(LINE . TEXT) for HIT (a result of `drgnx-search'): its chunk's first line that starts at column 0 and is
not only closing brackets (the top-level form a window cut into), else its first non-blank line; trimmed, with
that line's number — what one line of a result list shows and where it jumps."
  (let* ((lines (split-string (or (plist-get hit :text) "") "\n")) (n 0)
         (top (seq-position lines t (lambda (l _) (and (string-match-p "\\`[^ \t]" l)
                                                       (not (string-match-p "\\`[])}>;, \t]+\\'" l)))))))
    (if top
        (setq lines (nthcdr top lines) n top)
      (while (and lines (string-blank-p (car lines))) (setq lines (cdr lines) n (1+ n))))
    (cons (+ (max 1 (or (plist-get hit :start) 1)) (if lines n 0))
          (string-trim (or (car lines) "")))))

(defun drgnx-search--ranked-ids (db file query k vector info)
  "The fused ranking for QUERY: a list of (ID SCORE SIMILARITY WHY), best first, at most K long.
VECTOR is the question's embedding (nil: keyword only); INFO says who made it.  SIMILARITY is the cosine
for the chunks the vector ranking holds, else nil."
  (let* ((meta (drgnx-search-store-meta db)) (depth drgnx-search-list-depth)
         (problem (and vector (drgnx-search--vector-problem meta vector info)))
         (sims nil) (fused (make-hash-table)) (all nil))
    (when problem (drgnx-search--notice "%s" problem))
    (when (and vector (not problem))
      (condition-case err
          (pcase-let* ((`(,ids . ,words) (drgnx-search--fingerprints db file))
                       (q (drgnx-search-quantize (vconcat (mapcar #'float vector))))
                       (qwords (drgnx-search-bits-words (car q))))
            (cond
             ((zerop (length ids)))
             ((/= (* (length ids) (length qwords)) (length words))
              (drgnx-search--notice "the index is inconsistent (re-index) — keyword results only"))
             (t
              (let* ((near (drgnx-search--nearest qwords words (length ids) (max drgnx-search--candidates-floor (* 50 k))))
                     (stored (drgnx-search-store-vectors db (mapcar (lambda (i) (aref ids i)) near))))
                (setq sims (sort (mapcar (lambda (e) (cons (car e) (drgnx-search--dot (nth 1 q) (nth 2 q) (cadr e) (cddr e)))) stored)
                                 (lambda (a b) (> (cdr a) (cdr b)))))))))
        (error (setq sims nil)
               (drgnx-search--notice "the index is inconsistent (%s; re-index) — keyword results only"
                                     (error-message-string err)))))
    (let ((rank 0))
      (dolist (e (seq-take sims depth))
        (puthash (car e) (list (/ 1.0 (+ drgnx-search--rrf-k (cl-incf rank))) (cdr e) 'vector) fused)))
    (let ((rank 0))
      (dolist (e (drgnx-search-store-fts db query depth))
        (let ((add (/ 1.0 (+ drgnx-search--rrf-k (cl-incf rank)))) (old (gethash (car e) fused)))
          (puthash (car e) (if old (list (+ (car old) add) (cadr old) 'both) (list add nil 'keyword)) fused))))
    (maphash (lambda (id v) (push (cons id v) all)) fused)
    (seq-take (mapcar (lambda (e) (list (car e) (nth 1 e) (nth 2 e) (nth 3 e)))
                      (sort all (lambda (a b)
                                  (cond ((/= (nth 1 a) (nth 1 b)) (> (nth 1 a) (nth 1 b)))
                                        ((not (eql (nth 2 a) (nth 2 b))) (> (or (nth 2 a) -2.0) (or (nth 2 b) -2.0)))
                                        (t (< (car a) (car b)))))))
              k)))

(defun drgnx-search--results (db ranked)
  "RANKED ((ID SCORE SIMILARITY WHY)…) as result plists (:path :start :end :text :score :why), best first:
by score, then vector similarity, then path."
  (let ((chunks (drgnx-search-store-chunks db (mapcar #'car ranked))) (rows nil))
    (pcase-dolist (`(,id ,score ,sim ,why) ranked)
      (when-let* ((chunk (cdr (assq id chunks))))
        (push (cons (list :path (plist-get chunk :path) :start (plist-get chunk :start) :end (plist-get chunk :end)
                          :text (plist-get chunk :text) :score score :why why)
                    (or sim -2.0))
              rows)))
    (mapcar #'car
            (sort (nreverse rows)
                  (lambda (a b)
                    (cond ((/= (plist-get (car a) :score) (plist-get (car b) :score))
                           (> (plist-get (car a) :score) (plist-get (car b) :score)))
                          ((/= (cdr a) (cdr b)) (> (cdr a) (cdr b)))
                          (t (string< (plist-get (car a) :path) (plist-get (car b) :path)))))))))

(defun drgnx-search--finish (root query k vector info)
  "The results for QUERY in ROOT's index, given the question's embedding VECTOR (nil: none) made by INFO."
  (let ((db (condition-case nil (drgnx-search-store-open-read root) (error nil))))
    (if (null db)
        (progn (drgnx-search--notice "no index for this project — Search: Index Project") nil)
      (unwind-protect
          (condition-case err
              (if (> (or (plist-get (drgnx-search-store-meta db) :schema) 0) drgnx-search-store-schema-version)
                  (progn (drgnx-search--notice "the index is newer than this drgnx — update drgnx") nil)
                (drgnx-search--results
                 db (drgnx-search--ranked-ids db (drgnx-search-store-file root) query k vector info)))
            (error (drgnx-search--notice "the index cannot be read yet (%s)" (error-message-string err))
                   nil))
        (ignore-errors (sqlite-close db))))))

(defun drgnx-search--vector-of (vectors)
  "The first of VECTORS (an embedding answer) as a vector of numbers, or nil."
  (let ((v (and (sequencep vectors) (> (length vectors) 0) (elt vectors 0))))
    (and (sequencep v) (> (length v) 0) (cl-every #'numberp v) (vconcat v))))

(defun drgnx-search--root-dir (root)
  "The `default-directory' to embed a question for ROOT under: ROOT itself, so the `embed' role is ROOT's (a
.drgnx/ai.eld there counts), or the current one when ROOT is no directory (curl must start somewhere)."
  (let ((dir (file-name-as-directory (expand-file-name root))))
    (if (file-directory-p dir) dir default-directory)))

(defun drgnx-search--no-embedding (why)
  (drgnx-search--notice "no embedding provider answered (%s) — keyword results only" (or why "no reason given")))

(cl-defun drgnx-search (root query &key k embed)
  "The best K (default 10) chunks of the project at ROOT for QUERY: a list of plists (:path :start :end
:text :score :why), best first.  :score is the reciprocal-rank-fusion score; :why says which ranking found
the chunk — `vector', `keyword' or `both'.
EMBED (default `drgnx-ai-embed-sync') takes a vector of texts and returns a vector of vectors, setting
`drgnx-ai-embed-last-info' to who answered.  It waits for the provider: call this from a command the user ran.
The question is embedded with ROOT's `embed' role (its .drgnx/ai.eld counts, not the current buffer's).
No provider or another model than the index's: only the keyword hits; no index, no SQLite, search turned off
for the project or a .drgnx/search.eld that cannot be read: nil.  Either way `drgnx-search-last-notice' says why, in
one line — and never an error, never a prompt."
  (setq drgnx-search-last-notice nil)
  (when (drgnx-search--ready root)
    (let ((vector nil) (info nil))
      (let ((drgnx-ai-embed-last-info nil) (default-directory (drgnx-search--root-dir root)))
        (condition-case err
            (progn (setq vector (drgnx-search--vector-of (funcall (or embed #'drgnx-ai-embed-sync) (vector query)))
                         info drgnx-ai-embed-last-info)
                   (unless vector (drgnx-search--no-embedding "an answer without a vector")))
          (error (drgnx-search--no-embedding (error-message-string err)))))
      (drgnx-search--finish root query (or k drgnx-search-default-k) vector info))))

(cl-defun drgnx-search-async (root query callback &key k)
  "Like `drgnx-search', but the question is embedded without waiting: CALLBACK gets the result list and the
notice (one line or nil — what `drgnx-search-last-notice' says for this search).  CALLBACK is always called,
once: with no index, no SQLite, search off or an unreadable .drgnx/search.eld at once with nil, and whatever
goes wrong (the request, the index) with the keyword hits or nil and a notice.  The index is read from a
timer after the embedding answer, not inside the process sentinel that delivers it.
As there, the `embed' role is ROOT's."
  (setq drgnx-search-last-notice nil)
  (let ((called nil))
    (cl-flet ((answer (results)
                (unless called (setq called t) (funcall callback results drgnx-search-last-notice))))
      (if (not (drgnx-search--ready root))
          (answer nil)
        (condition-case err
            (let ((default-directory (drgnx-search--root-dir root)))
              (drgnx-ai-request
               'embed 'embed (list :inputs (vector query))
               (lambda (vectors info)
                 (run-at-time
                  0 nil
                  (lambda ()
                    (answer (condition-case err
                                (let ((vector (drgnx-search--vector-of vectors)))
                                  (setq drgnx-search-last-notice nil)
                                  (unless vector (drgnx-search--no-embedding (plist-get info :error)))
                                  (drgnx-search--finish root query (or k drgnx-search-default-k) vector info))
                              (error (drgnx-search--notice "the search failed (%s)" (error-message-string err))
                                     nil))))))))
          (error (unless called
                   (drgnx-search--notice "the search failed (%s)" (error-message-string err))
                   (answer nil))))))))

(provide 'drgnx-search-query)
;;; drgnx-search-query.el ends here
