;;; search-store-test.el --- batch tests: the search store (SQLite: chunks, FTS5, fingerprints, int8 vectors) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-search-store)

(defmacro drgnx-search-store-test--with (&rest body)
  "Run BODY with a temp state dir, DB bound to a fresh store for a fake project root."
  (declare (indent 0))
  `(progn
     (skip-unless (sqlite-available-p))
     (let* ((dir (make-temp-file "drgnx-search" t))
            (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
            (db (drgnx-search-store-open "/fake/project")))
       (unwind-protect (progn ,@body)
         (ignore-errors (sqlite-close db))
         (delete-directory dir t)))))

(defun drgnx-search-store-test--vec (dims seed)
  "A deterministic DIMS-long float vector, sign pattern varying with SEED."
  (let ((v (make-vector dims 0.0)))
    (dotimes (i dims) (aset v i (if (cl-evenp (logxor (* (1+ i) seed) (ash i -1))) 0.5 -0.25)))
    v))

(cl-defun drgnx-search-store-test--chunk (text seed &optional (dims 1024))
  (list :start 1 :end 5 :text text :vector (drgnx-search-store-test--vec dims seed)))

(defun drgnx-search-store-test--count (db)
  (caar (sqlite-select db "select count(*) from chunk")))

(ert-deftest drgnx-search-store/quantize-keeps-sign-and-scale ()
  (let* ((v (vconcat [0.5 -1.0 0.25] (make-vector 1021 0.0)))
         (q (drgnx-search-quantize v))
         (bits (nth 0 q)) (int8 (nth 1 q)) (scale (nth 2 q)))
    (should (= (length bits) 128))
    (should-not (multibyte-string-p bits))
    (should (= (logand (aref bits 0) 1) 1))            ; dim 0 > 0
    (should (= (logand (aref bits 0) 2) 0))            ; dim 1 < 0
    (should (= (logand (aref bits 0) 4) 4))            ; dim 2 > 0
    (should (= (logand (aref bits 0) 8) 0))            ; dim 3 = 0 is not > 0
    (should (= (length int8) 1024))
    (should-not (multibyte-string-p int8))
    (should (= (aref int8 1) (logand -127 255)))       ; -1.0 -> -127, two's complement
    (should (= (aref int8 0) 64))                      ; round(0.5 * 127) = 64
    (should (= (aref int8 2) 32))                      ; round(0.25 * 127) = 32
    (should (< (abs (- scale (/ 1.0 127))) 1e-12))))

(ert-deftest drgnx-search-store/quantize-handles-the-zero-vector ()
  (let ((q (drgnx-search-quantize (make-vector 16 0.0))))
    (should (equal (nth 0 q) (make-string 2 0)))
    (should (equal (nth 1 q) (make-string 16 0)))
    (should (= (nth 2 q) 0.0))))

(ert-deftest drgnx-search-store/the-file-is-per-project-under-the-state-dir ()
  (let ((process-environment (cons "XDG_STATE_HOME=/tmp/drgnx-st" process-environment)))
    (let ((f (drgnx-search-store-file "/fake/project")))
      (should (string-match-p "\\`/tmp/drgnx-st/drgnx/search/[0-9a-f]\\{16\\}\\.db\\'" f))
      (should (equal f (drgnx-search-store-file "/fake/project/")))
      (should-not (equal f (drgnx-search-store-file "/fake/other"))))))

(ert-deftest drgnx-search-store/meta-round-trip ()
  (drgnx-search-store-test--with
    (should (= (plist-get (drgnx-search-store-meta db) :schema) 1))
    (should-not (plist-get (drgnx-search-store-meta db) :dims))
    (drgnx-search-store-set-meta db '(:provider "ollama" :model "bge-m3" :dims 1024 :indexed-at 1792000000.5))
    (let ((m (drgnx-search-store-meta db)))
      (should (equal (plist-get m :provider) "ollama"))
      (should (equal (plist-get m :model) "bge-m3"))
      (should (= (plist-get m :dims) 1024))
      (should (= (plist-get m :indexed-at) 1792000000.5))
      (should (= (plist-get m :schema) 1)))
    ;; a later set changes only the keys it names
    (drgnx-search-store-set-meta db '(:model "other"))
    (should (equal (plist-get (drgnx-search-store-meta db) :model) "other"))
    (should (equal (plist-get (drgnx-search-store-meta db) :provider) "ollama"))))

(ert-deftest drgnx-search-store/a-file-is-replaced-whole ()
  (drgnx-search-store-test--with
    (drgnx-search-store-put-file db "a.el" "h1"
                                 (list (drgnx-search-store-test--chunk "alpha one" 1)
                                       (drgnx-search-store-test--chunk "beta two" 2)
                                       (drgnx-search-store-test--chunk "gamma three" 3)))
    (should (= (drgnx-search-store-test--count db) 3))
    (should (equal (gethash "a.el" (drgnx-search-store-files db)) "h1"))
    (drgnx-search-store-put-file db "a.el" "h2"
                                 (list (drgnx-search-store-test--chunk "delta four" 4)
                                       (drgnx-search-store-test--chunk "epsilon five" 5)))
    (should (= (drgnx-search-store-test--count db) 2))
    (should (equal (gethash "a.el" (drgnx-search-store-files db)) "h2"))
    (should (= (hash-table-count (drgnx-search-store-files db)) 1))
    (should-not (drgnx-search-store-fts db "alpha" 10))
    (should-not (drgnx-search-store-fts db "gamma" 10))
    (should (= (length (drgnx-search-store-fts db "delta" 10)) 1))))

(ert-deftest drgnx-search-store/other-files-are-left-alone ()
  (drgnx-search-store-test--with
    (drgnx-search-store-put-file db "a.el" "h1" (list (drgnx-search-store-test--chunk "alpha" 1)))
    (drgnx-search-store-put-file db "b.el" "h2" (list (drgnx-search-store-test--chunk "beta" 2)))
    (drgnx-search-store-put-file db "a.el" "h3" nil)
    (should (= (drgnx-search-store-test--count db) 1))
    (should (= (hash-table-count (drgnx-search-store-files db)) 2))
    (should (= (length (drgnx-search-store-fts db "beta" 10)) 1))))

(ert-deftest drgnx-search-store/delete-removes-chunks-and-fts ()
  (drgnx-search-store-test--with
    (drgnx-search-store-put-file db "a.el" "h1" (list (drgnx-search-store-test--chunk "alpha one" 1)))
    (drgnx-search-store-put-file db "b.el" "h2" (list (drgnx-search-store-test--chunk "beta two" 2)))
    (drgnx-search-store-delete-file db "a.el")
    (should (= (drgnx-search-store-test--count db) 1))
    (should-not (gethash "a.el" (drgnx-search-store-files db)))
    (should (gethash "b.el" (drgnx-search-store-files db)))
    (should-not (drgnx-search-store-fts db "alpha" 10))
    (should (= (length (drgnx-search-store-fts db "beta" 10)) 1))))

(ert-deftest drgnx-search-store/fingerprints-round-trip ()
  (drgnx-search-store-test--with
    (let ((v1 (drgnx-search-store-test--vec 1024 1))
          (v2 (drgnx-search-store-test--vec 1024 2)))
      (drgnx-search-store-put-file db "a.el" "h"
                                   (list (list :start 1 :end 2 :text "one" :vector v1)
                                         (list :start 3 :end 4 :text "two" :vector v2)))
      (let* ((fp (drgnx-search-store-fingerprints db)) (ids (car fp)) (words (cdr fp)))
        (should (vectorp ids)) (should (vectorp words))
        (should (= (length ids) 2))
        (should (= (length words) (* 2 19)))
        (should (cl-every #'fixnump words))
        (should (cl-every (lambda (w) (< -1 w (ash 1 56))) words))
        (let ((q1 (drgnx-search-bits-words (car (drgnx-search-quantize v1))))
              (q2 (drgnx-search-bits-words (car (drgnx-search-quantize v2)))))
          (should (= (length q1) 19))
          (cl-flet ((hamming (q i) (cl-loop for j below 19
                                            sum (logcount (logxor (aref q j) (aref words (+ (* 19 i) j)))))))
            (should (= (hamming q1 0) 0))
            (should (= (hamming q2 1) 0))
            (should (> (hamming q1 1) 0))))))))

(ert-deftest drgnx-search-store/fingerprints-are-read-in-pages-without-loss ()
  (drgnx-search-store-test--with
    (drgnx-search-store-put-file db "a.el" "h"
                                 (cl-loop for i from 1 to 5
                                          collect (drgnx-search-store-test--chunk (format "chunk %d" i) i 64)))
    (let ((drgnx-search-store--page 2))
      (let ((fp (drgnx-search-store-fingerprints db)))
        (should (= (length (car fp)) 5))
        (should (equal (append (car fp) nil) (sort (append (car fp) nil) #'<)))
        (should (= (length (cdr fp)) (* 5 2)))))))   ; ceil (64 bits / 56) = 2 words

(ert-deftest drgnx-search-store/fingerprint-words-follow-the-dimension ()
  (drgnx-search-store-test--with
    (drgnx-search-store-put-file db "a.el" "h" (list (drgnx-search-store-test--chunk "one" 1 256)))
    (should (= (length (cdr (drgnx-search-store-fingerprints db))) 5)))) ; ceil (256 / 56)

(ert-deftest drgnx-search-store/an-empty-store-has-no-fingerprints ()
  (drgnx-search-store-test--with
    (should (equal (drgnx-search-store-fingerprints db) (cons [] [])))))

(ert-deftest drgnx-search-store/vectors-and-chunks-come-back-by-id ()
  (drgnx-search-store-test--with
    (let ((v (vconcat [0.5 -1.0 0.25] (make-vector 5 0.0))))
      (drgnx-search-store-put-file db "src/a.el" "h"
                                   (list (list :start 10 :end 20 :text "first chunk" :vector v)
                                         (list :start 21 :end 30 :text "second chunk" :vector v)))
      (let* ((ids (append (car (drgnx-search-store-fingerprints db)) nil))
             (vecs (drgnx-search-store-vectors db ids))
             (chunks (drgnx-search-store-chunks db ids))
             (q (drgnx-search-quantize v)))
        (should (= (length vecs) 2))
        (should (equal (car (cdr (assq (car ids) vecs))) (nth 1 q)))
        (should (= (cdr (cdr (assq (car ids) vecs))) (nth 2 q)))
        (should-not (multibyte-string-p (car (cdr (assq (car ids) vecs)))))
        (should (equal (cdr (assq (cadr ids) chunks))
                       '(:path "src/a.el" :start 21 :end 30 :text "second chunk")))
        ;; an unknown id is left out; no ids at all is an empty answer
        (should (= (length (drgnx-search-store-chunks db (list (car ids) 99999))) 1))
        (should-not (drgnx-search-store-vectors db nil))))))

(ert-deftest drgnx-search-store/fts-ranks-best-first-and-honours-k ()
  (drgnx-search-store-test--with
    (drgnx-search-store-put-file
     db "a.el" "h"
     (list (drgnx-search-store-test--chunk "parse_config reads parse_config files" 1)
           (drgnx-search-store-test--chunk "parse something else entirely" 2)
           (drgnx-search-store-test--chunk "unrelated words here" 3)))
    (let ((hits (drgnx-search-store-fts db "parse_config" 10)))
      (should (= (length hits) 1))              ; underscore is part of a token
      (should (numberp (cdar hits))))
    (let* ((hits (drgnx-search-store-fts db "parse_config parse" 10))
           (top (caar hits)))
      (should (= (length hits) 2))
      (should (<= (cdr (nth 0 hits)) (cdr (nth 1 hits)))) ; bm25: lower is better, best first
      (should (equal (plist-get (cdr (assq top (drgnx-search-store-chunks db (list top)))) :text)
                     "parse_config reads parse_config files")))
    (should (= (length (drgnx-search-store-fts db "parse_config parse" 1)) 1))))

(ert-deftest drgnx-search-store/fts-query-is-sanitised ()
  (drgnx-search-store-test--with
    (drgnx-search-store-put-file db "a.el" "h" (list (drgnx-search-store-test--chunk "foo is here" 1)))
    (should (= (length (drgnx-search-store-fts db "foo\" OR (bar" 10)) 1))
    (should (= (length (drgnx-search-store-fts db "NEAR(foo) * ^foo -foo" 10)) 1))
    (should-not (drgnx-search-store-fts db "" 10))
    (should-not (drgnx-search-store-fts db "\" ) ( * ^" 10))
    (should-not (drgnx-search-store-fts db nil 10))))

(ert-deftest drgnx-search-store/two-handles-see-each-others-writes ()
  (drgnx-search-store-test--with
    (let ((db2 (drgnx-search-store-open "/fake/project")))
      (unwind-protect
          (progn
            (drgnx-search-store-put-file db "a.el" "h" (list (drgnx-search-store-test--chunk "shared words" 1)))
            (should (equal (gethash "a.el" (drgnx-search-store-files db2)) "h"))
            (should (= (length (drgnx-search-store-fts db2 "shared" 5)) 1))
            (drgnx-search-store-delete-file db2 "a.el")
            (should (= (hash-table-count (drgnx-search-store-files db)) 0)))
        (sqlite-close db2)))))

(ert-deftest drgnx-search-store/a-newer-schema-is-refused ()
  (drgnx-search-store-test--with
    (sqlite-execute db "update meta set value = '99' where key = 'schema'")
    (should-error (drgnx-search-store-open "/fake/project") :type 'user-error)))

(provide 'search-store-test)
;;; search-store-test.el ends here
