;;; gen.el --- Nidhogg's side of huginn's differential: the dumps and the random data -*- lexical-binding: t -*-
;; The reader on this side is Emacs's `read' behind `drgnx-file--parse' (the token and value checks of
;; core/drgnx-file.el).  This file turns what it reads into the canonical JSON dump of README.md and generates the
;; random data both readers are compared on.  Batch, in a Nidhogg container (from the checkout):
;;
;;   emacs --batch -L core -l test/fixtures/huginn/gen.el -f huginn-gen-all
;;
;; rewrites corpus/accept/*.json (one JSON array per file: its top-level data), checks that Emacs refuses every
;; corpus/refuse file (except the listed divergence, kind CharName) and rewrites random-seeded.eld and
;; random-seeded.dump (seed 1, 2000 data).  The runtime's side is runtime/crates/huginn/tests/differential.rs.
(require 'cl-lib)
(require 'drgnx-file)

(defconst huginn-gen-dir (file-name-directory (or load-file-name buffer-file-name))
  "This folder: test/fixtures/huginn/.")

;;;; The dump

(defun huginn-gen--float-text (f)
  "The float F as Emacs prints it (any NaN reads as NaN on the other side)."
  (let ((float-output-format nil)) (prin1-to-string f)))

(defun huginn-gen--tree (x)
  "The datum X as the vectors and strings `json-serialize' writes in the dump format of README.md."
  (cond ((integerp x) (vector "int" (number-to-string x)))
        ((floatp x) (vector "float" (huginn-gen--float-text x)))
        ((stringp x) (vector "str" x))
        ((symbolp x) (vector "sym" (symbol-name x)))
        ((vectorp x) (vector "vec" (vconcat (mapcar #'huginn-gen--tree x))))
        ((proper-list-p x) (vector "list" (vconcat (mapcar #'huginn-gen--tree x))))
        (t (let ((items nil))
             (while (consp x) (push (huginn-gen--tree (pop x)) items))
             (vector "cons" (vconcat (nreverse items)) (huginn-gen--tree x))))))

(defun huginn-gen-dump (datum)
  "DATUM as one JSON string in the dump format (call 4 of the plan).
Decoded: `json-serialize' returns UTF-8 bytes (a unibyte string), and the dumps compare as text."
  (decode-coding-string (json-serialize (huginn-gen--tree datum)) 'utf-8-unix))

(defun huginn-gen-dump-all (data)
  "The list DATA as one JSON array of dumps."
  (concat "[" (mapconcat #'huginn-gen-dump data ",") "]"))

;;;; Files

(defun huginn-gen--path (name)
  "NAME under this folder."
  (expand-file-name name huginn-gen-dir))

(defun huginn-gen-file-text (file)
  "FILE's bytes decoded as UTF-8, bytes that are not UTF-8 kept as raw bytes (what `drgnx-file-read' feeds the parser)."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (decode-coding-string (buffer-string) 'utf-8-unix t)))

(defun huginn-gen-file-parse (file)
  "The result of `drgnx-file--parse' over all the data in FILE."
  (drgnx-file--parse (huginn-gen-file-text file) t))

(defun huginn-gen-file-dump (file)
  "The dump of every datum in the corpus file FILE, as one JSON array (no newline).  An error when Emacs refuses it."
  (let ((r (huginn-gen-file-parse file)))
    (unless (memq (car r) '(ok absent))
      (error "%s: Emacs refuses it: %S" file (cdr r)))
    (huginn-gen-dump-all (and (eq (car r) 'ok) (cdr r)))))

(defun huginn-gen-refuse-kind (file)
  "The kind named in FILE's first line, \";; refuse: KIND\"."
  (with-temp-buffer
    (insert-file-contents file nil 0 200)
    (goto-char (point-min))
    (unless (looking-at ";; refuse: \\([A-Za-z0-9]+\\)$")
      (error "%s: no \";; refuse: KIND\" first line" file))
    (match-string 1)))

(defun huginn-gen--write (file text)
  "Write TEXT and a final newline to FILE as UTF-8."
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region (concat text "\n") nil file nil 'silent)))

(defun huginn-gen--corpus-files (dir)
  "The .el files in the corpus folder DIR (\"accept\" or \"refuse\"), sorted."
  (directory-files (huginn-gen--path (concat "corpus/" dir)) t "\\.el\\'"))

;;;; Random data

(defconst huginn-gen--symbol-pool
  '("foo" "bar-baz" "nil" "t" ":key" "&optional" "1+" "-" "+" "a.b" "λ" "x?" "foo-★" "%" "_" "=" "e" "E5" "quote" "function")
  "Symbol names drawn as they are.")

(defconst huginn-gen--symbol-chars "abcxyzABC019-+*/<>=!?_:%&$~^@{}|.\\\"';#,`()[] \t\nλé"
  "Characters of the random symbol names (`prin1' escapes the ones that need it).")

(defun huginn-gen--pick (items)
  "One of the list ITEMS."
  (nth (random (length items)) items))

(defun huginn-gen--char ()
  "A random character for a string: control, ASCII, Latin, CJK, an emoji, or one of the awkward ones."
  (pcase (random 8)
    (0 (random 32))
    ((or 1 2 3) (+ 32 (random 95)))
    (4 (+ #xa0 (random #x160)))
    (5 (+ #x4e00 (random 256)))
    (6 (+ #x1f300 (random 256)))
    (_ (huginn-gen--pick '(?\" ?\\ ?\n ?\t #xa0 #x200b #x2028 #xfeff #x7f)))))

(defun huginn-gen--string ()
  "A random string of up to 9 characters."
  (concat (cl-loop repeat (random 10) collect (huginn-gen--char))))

(defun huginn-gen--symbol ()
  "A random symbol: from the pool, or random characters (never the empty name)."
  (if (zerop (random 3))
      (intern (huginn-gen--pick huginn-gen--symbol-pool))
    (intern (concat (cl-loop repeat (1+ (random 6))
                             collect (aref huginn-gen--symbol-chars (random (length huginn-gen--symbol-chars))))))))

(defun huginn-gen--integer ()
  "A random integer within 64 bits, the bounds and small values often."
  (pcase (random 6)
    (0 (huginn-gen--pick '(0 1 -1 9223372036854775807 -9223372036854775808 2305843009213693951 -2305843009213693952)))
    (1 (- (random 200) 100))
    (2 (- (random 2000000) 1000000))
    (3 (random most-positive-fixnum))
    (4 (- (random most-positive-fixnum)))
    (_ (* (random 4294967296) (random 2147483648)))))

(defun huginn-gen--float ()
  "A random float: special values, plain decimals, tiny and huge ones."
  (pcase (random 6)
    (0 (huginn-gen--pick (list 0.0 -0.0 1.5 -2.25 1.0e+INF -1.0e+INF 0.0e+NaN -0.0e+NaN 5e-324 1.7976931348623157e308)))
    (1 (/ (random 1000000) 1000.0))
    (2 (* (- (random 2000) 1000) 1e-7))
    (3 (* (float (random 100000)) (expt 10.0 (- (random 600) 300))))
    (4 (/ 1.0 (1+ (random 1000))))
    (_ (- (random 100) 50.5))))

(defun huginn-gen--atom ()
  "A random atom."
  (pcase (random 4)
    (0 (huginn-gen--integer))
    (1 (huginn-gen--float))
    (2 (huginn-gen--string))
    (_ (huginn-gen--symbol))))

(defun huginn-gen--datum (depth)
  "A random datum, containers down to DEPTH."
  (if (or (<= depth 0) (< (random 10) 5))
      (huginn-gen--atom)
    (let ((items (cl-loop repeat (random 5) collect (huginn-gen--datum (1- depth)))))
      (pcase (random 6)
        (0 (vconcat items))
        (1 (cons (huginn-gen--atom) (huginn-gen--atom-tail)))
        (2 (list 'quote (huginn-gen--datum (1- depth))))
        (3 (list 'function (huginn-gen--datum (1- depth))))
        (4 (nconc items (huginn-gen--atom-tail)))
        (_ items)))))

(defun huginn-gen--atom-tail ()
  "An atom for a dotted tail: never nil (an atom is never a list)."
  (let ((tail (huginn-gen--atom))) (if (null tail) 1 tail)))

(defun huginn-gen-random-data (seed n)
  "N random data from SEED (a number or a string): a list of (TEXT . DATUM), TEXT as `prin1' prints it and DATUM
read back from TEXT by `drgnx-file--parse' (so the dump is of what the file says, whatever `prin1' made of it).
Data Emacs would refuse are drawn again."
  (random (format "%s" seed))
  (let ((rows nil) (tries 0)
        (print-escape-newlines nil) (print-length nil) (print-level nil) (print-circle nil) (float-output-format nil))
    (while (and (< (length rows) n) (< tries (* 5 n)))
      (cl-incf tries)
      (let* ((text (prin1-to-string (huginn-gen--datum 4)))
             (r (drgnx-file--parse text t)))
        (when (and (eq (car r) 'ok) (= (length (cdr r)) 1))
          (push (cons text (cadr r)) rows))))
    (unless (= (length rows) n) (error "only %d of %d random data were readable" (length rows) n))
    (nreverse rows)))

(defun huginn-gen-write-random (seed n eld dump)
  "Write N random data of SEED to ELD (one `prin1' text per line) and their dumps to DUMP (one JSON per line)."
  (let ((rows (huginn-gen-random-data seed n)))
    (huginn-gen--write eld (mapconcat #'car rows "\n"))
    (huginn-gen--write dump (mapconcat (lambda (row) (huginn-gen-dump (cdr row))) rows "\n"))))

;;;; The committed files

(defun huginn-gen-dump-lines (eld)
  "The dumps of the data in the file ELD, one JSON string each."
  (let ((r (huginn-gen-file-parse eld)))
    (unless (eq (car r) 'ok) (error "%s: Emacs refuses it: %S" eld (cdr r)))
    (mapcar #'huginn-gen-dump (cdr r))))

(defun huginn-gen-corpus ()
  "Rewrite the .json of every accept file; check Emacs refuses every refuse file (CharName: it reads it)."
  (dolist (f (huginn-gen--corpus-files "accept"))
    (huginn-gen--write (concat (file-name-sans-extension f) ".json") (huginn-gen-file-dump f)))
  (dolist (f (huginn-gen--corpus-files "refuse"))
    (let ((r (huginn-gen-file-parse f)))
      (if (equal (huginn-gen-refuse-kind f) "CharName")
          (unless (memq (car r) '(ok absent)) (error "%s: Emacs should read it: %S" f (cdr r)))
        (unless (eq (car r) 'problem) (error "%s: Emacs should refuse it, read %S" f r))))))

(defun huginn-gen-all ()
  "The corpus dumps and the committed random data (seed 1, 2000 data)."
  (huginn-gen-corpus)
  (huginn-gen-write-random 1 2000 (huginn-gen--path "random-seeded.eld") (huginn-gen--path "random-seeded.dump")))

(provide 'huginn-gen)
;;; gen.el ends here
