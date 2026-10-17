;;; search-query-test.el --- batch tests: the search query engine (fingerprint scan, int8 rescore, RRF with BM25) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-search-query)

(defconst drgnx-search-query-test--dims 64)

(defun drgnx-search-query-test--normalise (v)
  (let ((norm (sqrt (cl-loop for x across v sum (* x x)))))
    (if (zerop norm) v (vconcat (mapcar (lambda (x) (/ x norm)) v)))))

(cl-defun drgnx-search-query-test--embed-text (text &optional (dims drgnx-search-query-test--dims))
  "A deterministic unit vector for TEXT: each word adds a +-1 pattern from its md5; similar words, similar vectors."
  (let ((v (make-vector dims 0.0)))
    (dolist (word (split-string (downcase text) "[^[:alnum:]_]+" t))
      (let ((digest (secure-hash 'md5 word nil nil t)))
        (dotimes (i dims)
          (aset v i (+ (aref v i) (if (zerop (logand 1 (ash (aref digest (% (/ i 8) 16)) (- (% i 8))))) -1.0 1.0))))))
    (drgnx-search-query-test--normalise v)))

(defmacro drgnx-search-query-test--with (&rest body)
  "Run BODY with a temp state dir; ROOT is a fake project and DB a writer on its (fresh) index."
  (declare (indent 0))
  `(progn
     (skip-unless (sqlite-available-p))
     (let* ((dir (make-temp-file "drgnx-search" t))
            (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
            (root "/fake/project")
            (drgnx-search-last-notice nil)
            (db (drgnx-search-store-open root)))
       (unwind-protect (progn ,@body)
         (ignore-errors (sqlite-close db))
         (delete-directory dir t)))))

(defun drgnx-search-query-test--index (db texts &optional meta)
  "Put TEXTS as chunks of one file (embedded by the stub) and record the stub provider in the meta."
  (let ((line 0))
    (drgnx-search-store-put-file
     db "src/a.el" "h"
     (mapcar (lambda (text) (list :start (cl-incf line) :end line :text text
                                  :vector (drgnx-search-query-test--embed-text text)))
             texts)))
  (drgnx-search-store-set-meta db (append meta (list :provider 'stub :model "stub-1"
                                                     :dims drgnx-search-query-test--dims
                                                     :indexed-at (float-time)))))

(defun drgnx-search-query-test--embedder (&optional vector)
  "An EMBED function: the stub vector of the query text, or VECTOR whatever the text."
  (lambda (inputs)
    (setq drgnx-ai-embed-last-info '(:provider stub :model "stub-1"))
    (vector (or vector (drgnx-search-query-test--embed-text (aref inputs 0))))))

(defun drgnx-search-query-test--texts (results) (mapcar (lambda (r) (plist-get r :text)) results))

(defconst drgnx-search-query-test--texts
  '("open the database connection and read rows"
    "render the user interface window"
    "parse json configuration file"
    "compute the checksum of a buffer"))

;;;; The engine

(ert-deftest drgnx-search/finds-the-closest-chunk-first ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (let ((r (drgnx-search root "database connection rows" :embed (drgnx-search-query-test--embedder))))
      (should (equal (plist-get (car r) :text) (nth 0 drgnx-search-query-test--texts)))
      (should (equal (plist-get (car r) :path) "src/a.el"))
      (should (= (plist-get (car r) :start) 1))
      (should (= (plist-get (car r) :end) 1))
      (should (eq (plist-get (car r) :why) 'both)) ; its words are in the text, and its vector is closest
      (should (> (plist-get (car r) :score) 0))
      (should-not drgnx-search-last-notice)
      ;; best first
      (should (equal (mapcar (lambda (x) (plist-get x :score)) r)
                     (sort (mapcar (lambda (x) (plist-get x :score)) r) #'>))))
    ;; the vector alone: the question's words are in no chunk
    (let ((r (drgnx-search root "zzq" :embed (drgnx-search-query-test--embedder
                                              (drgnx-search-query-test--embed-text
                                               (nth 2 drgnx-search-query-test--texts))))))
      (should (equal (plist-get (car r) :text) (nth 2 drgnx-search-query-test--texts)))
      (should (eq (plist-get (car r) :why) 'vector)))))

(ert-deftest drgnx-search/k-bounds-the-results ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (let ((embed (drgnx-search-query-test--embedder)))
      (should (= (length (drgnx-search root "the" :k 2 :embed embed)) 2))
      (should (= (length (drgnx-search root "the" :embed embed)) 4))  ; k defaults to 10; four chunks exist
      (should (= (length (drgnx-search root "the" :k 1 :embed embed)) 1)))))

(ert-deftest drgnx-search/keyword-only-when-the-provider-is-down ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (let ((r (drgnx-search root "checksum buffer"
                           :embed (lambda (_) (signal 'drgnx-ai-embed-error '("no provider answered"))))))
      (should (= (length r) 1))
      (should (equal (plist-get (car r) :text) (nth 3 drgnx-search-query-test--texts)))
      (should (eq (plist-get (car r) :why) 'keyword))
      (should (stringp drgnx-search-last-notice))
      (should (string-match-p "no provider answered" drgnx-search-last-notice))
      (should-not (string-match-p "\n" drgnx-search-last-notice)))
    ;; the notice belongs to one search
    (drgnx-search root "checksum" :embed (drgnx-search-query-test--embedder))
    (should-not drgnx-search-last-notice)))

(ert-deftest drgnx-search/keyword-and-vector-hits-merge ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    ;; the vector points at chunk 2 (the window), the words at chunk 4 (the checksum)
    (let* ((drgnx-search-list-depth 1)
           (r (drgnx-search root "checksum" :embed (drgnx-search-query-test--embedder
                                                    (drgnx-search-query-test--embed-text
                                                     (nth 1 drgnx-search-query-test--texts)))))
           (by-text (lambda (i) (cl-find (nth i drgnx-search-query-test--texts) r
                                         :key (lambda (x) (plist-get x :text)) :test #'equal))))
      (should (eq (plist-get (funcall by-text 1) :why) 'vector))
      (should (eq (plist-get (funcall by-text 3) :why) 'keyword))
      ;; rank 1 in one list each: the same score, and the better vector similarity is first on the tie
      (should (= (plist-get (funcall by-text 1) :score) (plist-get (funcall by-text 3) :score)))
      (should (equal (plist-get (car r) :text) (nth 1 drgnx-search-query-test--texts))))
    ;; a chunk in both lists outscores the single-list ones
    (let* ((drgnx-search-list-depth 2)
           (r (drgnx-search root "database" :embed (drgnx-search-query-test--embedder
                                                    (drgnx-search-query-test--embed-text
                                                     (nth 0 drgnx-search-query-test--texts))))))
      (should (eq (plist-get (car r) :why) 'both))
      (should (> (plist-get (car r) :score) (plist-get (cadr r) :score))))))

(ert-deftest drgnx-search/rrf-scores-are-reciprocal-ranks ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (let ((r (drgnx-search root "database connection rows"
                           :embed (drgnx-search-query-test--embedder
                                   (drgnx-search-query-test--embed-text (nth 0 drgnx-search-query-test--texts))))))
      ;; rank 1 in the vector list and rank 1 in the keyword list: 1/61 + 1/61
      (should (< (abs (- (plist-get (car r) :score) (/ 2.0 61))) 1e-12)))))

(ert-deftest drgnx-search/cache-reloads-after-a-new-index ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (let ((loads 0) (embed (drgnx-search-query-test--embedder)))
      (advice-add 'drgnx-search-store-snapshot :before (lambda (&rest _) (cl-incf loads)) '((name . count-loads)))
      (unwind-protect
          (progn
            (should-not (cl-find "zebra stripes pattern" (drgnx-search root "zebra stripes pattern" :embed embed)
                                 :key (lambda (x) (plist-get x :text)) :test #'equal))
            (should (= loads 1))
            (drgnx-search root "database" :embed embed)
            (should (= loads 1))               ; nothing changed: the cache serves
            ;; an indexer run adds a chunk and advances the meta
            (drgnx-search-store-put-file
             db "src/b.el" "h2" (list (list :start 1 :end 3 :text "zebra stripes pattern"
                                            :vector (drgnx-search-query-test--embed-text "zebra stripes pattern"))))
            (drgnx-search-store-set-meta db (list :indexed-at (+ 100.0 (float-time))))
            (let ((r (drgnx-search root "zebra stripes pattern" :embed embed)))
              (should (= loads 2))
              (should (equal (plist-get (car r) :path) "src/b.el"))
              (should (eq (plist-get (car r) :why) 'both))))
        (advice-remove 'drgnx-search-store-snapshot 'count-loads)))))

(ert-deftest drgnx-search/a-chunk-written-before-the-meta-advances-is-seen ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (let ((embed (drgnx-search-query-test--embedder (drgnx-search-query-test--embed-text "zebra stripes pattern"))))
      (drgnx-search root "x" :embed embed)
      ;; an indexer still running: chunks arrive, indexed-at not yet advanced
      (drgnx-search-store-put-file
       db "src/b.el" "h2" (list (list :start 1 :end 3 :text "zebra stripes pattern"
                                      :vector (drgnx-search-query-test--embed-text "zebra stripes pattern"))))
      (should (equal (plist-get (car (drgnx-search root "x" :embed embed)) :path) "src/b.el")))))

(ert-deftest drgnx-search/no-index-is-a-notice-not-an-error ()
  (drgnx-search-query-test--with
    (let ((other "/fake/never-indexed") (called nil))
      (should-not (drgnx-search other "anything" :embed (lambda (_) (setq called t) (error "asked"))))
      (should-not called)                     ; nothing to search: nothing embedded
      (should (string-match-p "no index for this project" drgnx-search-last-notice))
      (should (string-match-p "Search: Index Project" drgnx-search-last-notice))
      (should-not (file-exists-p (drgnx-search-store-file other))))))

(ert-deftest drgnx-search/no-sqlite-is-a-notice-not-an-error ()
  (cl-letf (((symbol-function 'sqlite-available-p) (lambda () nil)))
    (let ((drgnx-search-last-notice nil))
      (should-not (drgnx-search "/fake/project" "anything" :embed (lambda (_) (error "asked"))))
      (should (string-match-p "no SQLite" drgnx-search-last-notice)))))

(ert-deftest drgnx-search/another-model-or-dimension-is-keyword-only ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    ;; other dimensions
    (let ((r (drgnx-search root "checksum"
                           :embed (lambda (_) (vector (make-vector 128 0.1))))))
      (should (equal (mapcar (lambda (x) (plist-get x :why)) r) '(keyword)))
      (should (string-match-p "built with stub-1 (64); re-index" drgnx-search-last-notice)))
    ;; same dimensions, another model
    (setq drgnx-search-last-notice nil)
    (let ((r (drgnx-search root "checksum"
                           :embed (lambda (_)
                                    (setq drgnx-ai-embed-last-info '(:provider other :model "o-1"))
                                    (vector (drgnx-search-query-test--embed-text "checksum"))))))
      (should (equal (mapcar (lambda (x) (plist-get x :why)) r) '(keyword)))
      (should (string-match-p "re-index" drgnx-search-last-notice)))))

(ert-deftest drgnx-search/an-index-without-vectors-is-keyword-only ()
  (drgnx-search-query-test--with
    (should-not (drgnx-search root "anything" :embed (drgnx-search-query-test--embedder)))
    (should (stringp drgnx-search-last-notice))))

(ert-deftest drgnx-search/a-search-never-writes-the-index ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (sqlite-execute db "begin immediate")      ; the indexer holds the write lock
    (unwind-protect
        (let ((t0 (float-time)))
          (should (drgnx-search root "database" :embed (drgnx-search-query-test--embedder)))
          (should (< (- (float-time) t0) 2.0)))
      (sqlite-execute db "rollback"))))

;;;; Async

(ert-deftest drgnx-search/async-embeds-through-the-ai-client ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (let ((got 'none) (asked nil))
      (cl-letf (((symbol-function 'drgnx-ai-request)
                 (lambda (role kind payload callback &rest _)
                   (setq asked (list role kind payload))
                   (funcall callback (vector (drgnx-search-query-test--embed-text (aref (plist-get payload :inputs) 0)))
                            '(:provider stub :model "stub-1")))))
        (drgnx-search-async root "database connection rows" (lambda (r) (setq got r))))
      (should (equal (car asked) 'embed))
      (should (equal (cadr asked) 'embed))
      (should (equal (plist-get (caddr asked) :inputs) ["database connection rows"]))
      (should (equal (plist-get (car got) :text) (nth 0 drgnx-search-query-test--texts))))))

(ert-deftest drgnx-search/async-without-a-provider-is-keyword-only ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (let ((got 'none))
      (cl-letf (((symbol-function 'drgnx-ai-request)
                 (lambda (_r _k _p callback &rest _) (funcall callback nil '(:error "ollama: no answer")))))
        (drgnx-search-async root "checksum" (lambda (r) (setq got r))))
      (should (equal (mapcar (lambda (x) (plist-get x :why)) got) '(keyword)))
      (should (string-match-p "ollama: no answer" drgnx-search-last-notice)))))

(ert-deftest drgnx-search/async-with-no-index-calls-back-at-once ()
  (drgnx-search-query-test--with
    (let ((got 'none))
      (cl-letf (((symbol-function 'drgnx-ai-request) (lambda (&rest _) (error "asked"))))
        (drgnx-search-async "/fake/never-indexed" "x" (lambda (r) (setq got r))))
      (should (null got))
      (should (string-match-p "no index" drgnx-search-last-notice)))))

;; The callback of an asynchronous search is called whatever is wrong with the index.
(ert-deftest drgnx-search/async-always-calls-back-on-a-corrupt-meta ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (sqlite-execute db "update meta set value = '(' where key = 'dims'")
    (let ((got 'none))
      (cl-letf (((symbol-function 'drgnx-ai-request)
                 (lambda (_r _k payload callback &rest _)
                   (funcall callback (vector (drgnx-search-query-test--embed-text (aref (plist-get payload :inputs) 0)))
                            '(:provider stub :model "stub-1")))))
        (drgnx-search-async root "checksum" (lambda (r) (setq got r))))
      (should (null got))                      ; called, with nothing (the meta cannot be read)
      (should (string-match-p "cannot be read" drgnx-search-last-notice)))))

(ert-deftest drgnx-search/async-always-calls-back-on-a-short-vector ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (sqlite-execute db "update chunk set vec = zeroblob(3)")
    (let ((got 'none))
      (cl-letf (((symbol-function 'drgnx-ai-request)
                 (lambda (_r _k payload callback &rest _)
                   (funcall callback (vector (drgnx-search-query-test--embed-text (aref (plist-get payload :inputs) 0)))
                            '(:provider stub :model "stub-1")))))
        (drgnx-search-async root "checksum" (lambda (r) (setq got r))))
      (should (consp got))                     ; the keyword hit survives
      (should (equal (mapcar (lambda (x) (plist-get x :why)) got) '(keyword)))
      (should (string-match-p "keyword" drgnx-search-last-notice)))))

(ert-deftest drgnx-search/async-calls-back-once-when-the-request-itself-fails ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (let ((calls 0))
      (cl-letf (((symbol-function 'drgnx-ai-request) (lambda (&rest _) (error "no way to ask"))))
        (drgnx-search-async root "checksum" (lambda (_r) (cl-incf calls))))
      (should (= calls 1))
      (should (stringp drgnx-search-last-notice)))))

(ert-deftest drgnx-search/an-inconsistent-index-skips-the-vectors-and-says-so ()
  (drgnx-search-query-test--with
    (drgnx-search-query-test--index db drgnx-search-query-test--texts)
    (sqlite-execute db "update chunk set bits = zeroblob(1) where id = 1")   ; a fingerprint of the wrong size
    (let ((r (drgnx-search root "checksum" :embed (drgnx-search-query-test--embedder))))
      (should (equal (mapcar (lambda (x) (plist-get x :why)) r) '(keyword)))
      (should (string-match-p "keyword" drgnx-search-last-notice))
      (should (string-match-p "inconsistent" drgnx-search-last-notice)))))

;;;; The scan

(ert-deftest drgnx-search/nearest-picks-the-smallest-distances ()
  (let* ((state (cl-make-random-state 7)) (w 3) (count 500) (n 40)
         (words (make-vector (* w count) 0))
         (q (vconcat (cl-loop repeat w collect (drgnx-search-query-test--word state)))))
    (dotimes (i (length words)) (aset words i (drgnx-search-query-test--word state)))
    (let* ((got (drgnx-search--nearest q words count n))
           (dist (lambda (i) (cl-loop for j below w sum (logcount (logxor (aref q j) (aref words (+ (* i w) j)))))))
           (all (sort (number-sequence 0 (1- count)) (lambda (a b) (< (funcall dist a) (funcall dist b)))))
           (cut (funcall dist (nth (1- n) all))))
      (should (= (length got) n))
      (should (= (length (delete-dups (append got nil))) n))
      (should (cl-every (lambda (i) (<= (funcall dist i) cut)) got))
      ;; everything strictly closer than the cut is in
      (should (cl-every (lambda (i) (or (>= (funcall dist i) cut) (seq-contains-p got i))) (number-sequence 0 (1- count)))))
    ;; fewer chunks than wanted: all of them
    (should (equal (append (drgnx-search--nearest q words count 900) nil) (number-sequence 0 (1- count))))
    (should (equal (drgnx-search--nearest q [] 0 5) []))))

(defun drgnx-search-query-test--word (state) (cl-random (ash 1 56) state))

;;;; Recall

(defun drgnx-search-query-test--random-unit (dims state)
  (let ((v (make-vector dims 0.0)))
    (dotimes (i dims)                          ; Box-Muller: gaussian, so directions are uniform
      (aset v i (* (sqrt (* -2.0 (log (- 1.0 (cl-random 1.0 state)))))
                   (cos (* 2 float-pi (cl-random 1.0 state))))))
    (drgnx-search-query-test--normalise v)))

(ert-deftest drgnx-search/quantized-recall-at-10 ()
  (drgnx-search-query-test--with
    (let* ((dims 256) (n 1000) (queries 20) (k 10)
           (state (cl-make-random-state 20261017))
           (vectors (cl-loop repeat n collect (drgnx-search-query-test--random-unit dims state)))
           (recall 0.0))
      (drgnx-search-store-put-file
       db "src/a.el" "h"
       (cl-loop for v in vectors for i from 1
                collect (list :start i :end i :text (format "chunk%d" i) :vector v)))
      (drgnx-search-store-set-meta db (list :provider 'stub :model "stub-1" :dims dims :indexed-at 1.0))
      (dotimes (_ queries)
        (let* ((q (drgnx-search-query-test--random-unit dims state))
               (exact (mapcar #'cdr
                              (seq-take
                               (sort (cl-loop for v in vectors for i from 1
                                              collect (cons (cl-loop for a across q for b across v sum (* a b))
                                                            (format "chunk%d" i)))
                                     (lambda (a b) (> (car a) (car b))))
                               k)))
               (got (drgnx-search-query-test--texts
                     (drgnx-search root "zzq" :k k :embed (drgnx-search-query-test--embedder q)))))
          (should (= (length got) k))
          (cl-incf recall (/ (length (seq-intersection exact got #'equal)) (float k)))))
      (setq recall (/ recall queries))
      (message "drgnx-search recall@10 = %.3f" recall)
      (should (>= recall 0.95)))))

;;;; Final review

(defmacro drgnx-search-query-test--with-dir (&rest body)
  "BODY with ROOT a real directory (a directory name) whose index (DB) holds the stub texts."
  (declare (indent 0))
  `(progn
     (skip-unless (sqlite-available-p))
     (let* ((dir (make-temp-file "drgnx-search" t))
            (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
            (root (file-name-as-directory (make-temp-file "drgnx-search-proj" t)))
            (drgnx-search-last-notice nil)
            (db (drgnx-search-store-open root)))
       (unwind-protect (progn (drgnx-search-query-test--index db drgnx-search-query-test--texts) ,@body)
         (ignore-errors (sqlite-close db))
         (delete-directory root t)
         (delete-directory dir t)))))

(ert-deftest drgnx-search/search-off-is-honoured-at-query-time ()
  (drgnx-search-query-test--with-dir
    (make-directory (expand-file-name ".drgnx" root))
    (write-region "(:off t)" nil (expand-file-name ".drgnx/search.eld" root) nil 'silent)
    (let ((asked nil) (got 'none))
      (should-not (drgnx-search root "database" :embed (lambda (_) (setq asked t) (error "asked"))))
      (should (equal drgnx-search-last-notice "search is off for this project (.drgnx/search.eld)"))
      (setq drgnx-search-last-notice nil)
      (cl-letf (((symbol-function 'drgnx-ai-request) (lambda (&rest _) (setq asked t) (error "asked"))))
        (drgnx-search-async root "database" (lambda (r) (setq got r))))
      (should (null got))
      (should (equal drgnx-search-last-notice "search is off for this project (.drgnx/search.eld)"))
      (should-not asked))))

(ert-deftest drgnx-search/a-broken-config-refuses-queries-of-an-existing-index ()
  "A search.eld that cannot be read is no licence to search: the index exists, but the query refuses with the
config error, as the indexer does."
  (drgnx-search-query-test--with-dir
    (make-directory (expand-file-name ".drgnx" root))
    (write-region "(:include " nil (expand-file-name ".drgnx/search.eld" root) nil 'silent)
    (let ((asked nil) (got 'none))
      (should-not (drgnx-search root "database" :embed (lambda (_) (setq asked t) (error "asked"))))
      (should (string-match-p "\\`\\.drgnx/search\\.eld cannot be read: ." drgnx-search-last-notice))
      (setq drgnx-search-last-notice nil)
      (cl-letf (((symbol-function 'drgnx-ai-request) (lambda (&rest _) (setq asked t) (error "asked"))))
        (drgnx-search-async root "database" (lambda (r) (setq got r))))
      (should (null got))
      (should (string-match-p "cannot be read" drgnx-search-last-notice))
      (should-not asked))))

(ert-deftest drgnx-search/the-embed-role-is-the-searched-projects ()
  "The question is embedded with the `embed' role of ROOT (its .drgnx/ai.eld), not of the current buffer."
  (drgnx-search-query-test--with-dir
    (let ((elsewhere (make-temp-file "drgnx-search-elsewhere" t)) (seen nil))
      (unwind-protect
          (let ((default-directory (file-name-as-directory elsewhere)))
            (drgnx-search root "database" :embed (lambda (inputs) (push default-directory seen)
                                                   (funcall (drgnx-search-query-test--embedder) inputs)))
            (cl-letf (((symbol-function 'drgnx-ai-request)
                       (lambda (_r _k payload callback &rest _)
                         (push default-directory seen)
                         (funcall callback (vector (drgnx-search-query-test--embed-text (aref (plist-get payload :inputs) 0)))
                                  '(:provider stub :model "stub-1")))))
              (drgnx-search-async root "database" #'ignore))
            (should (equal seen (list root root))))
        (delete-directory elsewhere t)))))

(ert-deftest drgnx-search/hit-line-is-the-first-top-level-line ()
  "A chunk that starts inside a body shows its first column-0 line that is not just closing brackets."
  (should (equal (drgnx-search-hit-line '(:start 10 :text "    (setq x 1))\n  )\n\n(defun foo ()\n  1)"))
                 '(13 . "(defun foo ()")))
  (should (equal (drgnx-search-hit-line '(:start 5 :text "  a\n});\n)\nfunction g() {}"))
                 '(8 . "function g() {}")))
  ;; no column-0 line at all: the first non-blank line, as before
  (should (equal (drgnx-search-hit-line '(:start 3 :text "\n   one\n   two"))
                 '(4 . "one")))
  (should (equal (drgnx-search-hit-line '(:start 7 :text "(defun f ()\n  1)"))
                 '(7 . "(defun f ()"))))

(provide 'search-query-test)
;;; search-query-test.el ends here
