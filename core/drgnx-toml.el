;;; drgnx-toml.el --- a minimal TOML reader and a writer that changes one table only -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; What the agent settings pages need of TOML (Codex's config.toml): read a whole file into an alist, and replace,
;; add or remove ONE table (`[a.b]') or one array-of-tables entry (`[[a.b]]') without touching a single other byte
;; (comments, ordering, unknown keys, spacing).  The writer works on the text's own statement positions, never on a
;; re-serialised document.  See docs/develop/core.md.
;;
;; Reader values: tables are alists of ("key" . VALUE) in file order; arrays are vectors (an array of tables is a
;; vector of alists); strings, integers, floats, t, :false; a date or time is (:date . "TEXT") with its text as written.
;; Not supported (it signals `drgnx-toml-error'): nothing in TOML 1.0, plus the 1.1 additions of newlines and a
;; trailing comma in inline tables, which are read too.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(define-error 'drgnx-toml-error "Invalid TOML")

(defun drgnx-toml--signal (line message)
  "Signal `drgnx-toml-error' for LINE (a number, or nil when no text is involved) with MESSAGE."
  (signal 'drgnx-toml-error (list line message)))

;;;; Scanning (buffer positions are 1-based while scanning; the API converts)

(defun drgnx-toml--fail (message &optional pos)
  "Signal an error for MESSAGE at POS (default point) in the scan buffer."
  (drgnx-toml--signal (line-number-at-pos (or pos (point))) message))

(defun drgnx-toml--ws ()
  "Skip spaces and tabs."
  (skip-chars-forward " \t"))

(defun drgnx-toml--trivia ()
  "Skip whitespace, newlines and comments (inside arrays and inline tables)."
  (let (more)
    (setq more t)
    (while more
      (skip-chars-forward " \t\r\n")
      (if (eq (char-after) ?#)
          (skip-chars-forward "^\n")
        (setq more nil)))))

(defun drgnx-toml--eol ()
  "Skip a trailing comment and the line end after a statement; anything else is an error."
  (drgnx-toml--ws)
  (when (eq (char-after) ?#) (skip-chars-forward "^\n"))
  (cond ((eobp))
        ((looking-at "\r?\n") (goto-char (match-end 0)))
        (t (drgnx-toml--fail "expected the end of the line"))))

(defun drgnx-toml--hex-char (n start)
  "The character for N hex digits at point (an escape starting at START)."
  (let ((digits (buffer-substring-no-properties (point) (min (point-max) (+ (point) n)))))
    (unless (and (= (length digits) n) (string-match-p "\\`[0-9A-Fa-f]+\\'" digits))
      (drgnx-toml--fail "bad \\u escape" start))
    (forward-char n)
    (let ((code (string-to-number digits 16)))
      (when (or (> code #x10FFFF) (<= #xD800 code #xDFFF))
        (drgnx-toml--fail "bad \\u escape" start))
      (string code))))

(defun drgnx-toml--escape (start)
  "Read the escape after a backslash at point; START is where the string began."
  (let ((c (char-after)))
    (unless c (drgnx-toml--fail "unterminated string" start))
    (forward-char)
    (pcase c
      (?b "\b") (?t "\t") (?n "\n") (?f "\f") (?r "\r") (?e "\e") (?\" "\"") (?\\ "\\")
      (?u (drgnx-toml--hex-char 4 start))
      (?U (drgnx-toml--hex-char 8 start))
      (_ (drgnx-toml--fail (format "bad escape \\%c" c) start)))))

(defun drgnx-toml--basic-string ()
  "A \"...\" string at point (not the multi-line form)."
  (let ((start (point)) (parts nil))
    (forward-char)
    (catch 'done
      (while t
        (let ((chunk-start (point)))
          (skip-chars-forward "^\"\\\\\n")
          (push (buffer-substring-no-properties chunk-start (point)) parts))
        (pcase (char-after)
          (?\" (forward-char) (throw 'done nil))
          (?\\ (forward-char) (push (drgnx-toml--escape start) parts))
          (_ (drgnx-toml--fail "unterminated string" start)))))
    (apply #'concat (nreverse parts))))

(defun drgnx-toml--literal-string ()
  "A '...' string at point (not the multi-line form)."
  (let ((start (point)))
    (forward-char)
    (let ((from (point)))
      (skip-chars-forward "^'\n")
      (unless (eq (char-after) ?') (drgnx-toml--fail "unterminated string" start))
      (prog1 (buffer-substring-no-properties from (point)) (forward-char)))))

(defun drgnx-toml--multi-line (q basic)
  "A multi-line string at point delimited by three QUOTEs; BASIC allows escapes."
  (let ((start (point)) (parts nil))
    (forward-char 3)
    (when (looking-at "\r?\n") (goto-char (match-end 0)))
    (catch 'done
      (while t
        (let ((chunk-start (point)))
          (skip-chars-forward (if basic "^\"\\\\" "^'"))
          (push (buffer-substring-no-properties chunk-start (point)) parts))
        (let ((c (char-after)))
          (cond
           ((null c) (drgnx-toml--fail "unterminated string" start))
           ((eq c q)
            (let ((from (point)) n)
              (skip-chars-forward (string q))
              (setq n (- (point) from))
              (cond ((< n 3) (push (make-string n q) parts))
                    ((> n 5) (drgnx-toml--fail "too many quotes in a string" from))
                    (t (push (make-string (- n 3) q) parts) (throw 'done nil)))))
           ;; a backslash in a basic string
           ((looking-at "\\\\[ \t]*\r?\n")
            (goto-char (match-end 0))
            (skip-chars-forward " \t\r\n"))
           (t (forward-char) (push (drgnx-toml--escape start) parts))))))
    (apply #'concat (nreverse parts))))

(defun drgnx-toml--key-part ()
  "One bare, double-quoted or single-quoted key part at point."
  (cond ((eq (char-after) ?\")
         (if (looking-at "\"\"\"") (drgnx-toml--fail "expected a key") (drgnx-toml--basic-string)))
        ((eq (char-after) ?')
         (if (looking-at "'''") (drgnx-toml--fail "expected a key") (drgnx-toml--literal-string)))
        ((looking-at "[A-Za-z0-9_-]+") (goto-char (match-end 0)) (match-string-no-properties 0))
        (t (drgnx-toml--fail "expected a key"))))

(defun drgnx-toml--key ()
  "A bare, quoted or dotted key at point, as a list of parts."
  (let ((parts (list (drgnx-toml--key-part))))
    (while (progn (drgnx-toml--ws) (eq (char-after) ?.))
      (forward-char)
      (drgnx-toml--ws)
      (push (drgnx-toml--key-part) parts))
    (nreverse parts)))

(defconst drgnx-toml--int-re "\\`[+-]?\\(?:0\\|[1-9]\\(?:_?[0-9]\\)*\\)\\'")
(defconst drgnx-toml--radix-re "\\`0\\(?:x[0-9A-Fa-f]\\(?:_?[0-9A-Fa-f]\\)*\\|o[0-7]\\(?:_?[0-7]\\)*\\|b[01]\\(?:_?[01]\\)*\\)\\'")
(defconst drgnx-toml--float-re
  "\\`[+-]?\\(?:0\\|[1-9]\\(?:_?[0-9]\\)*\\)\\(?:\\.[0-9]\\(?:_?[0-9]\\)*\\)?\\(?:[eE][+-]?[0-9]\\(?:_?[0-9]\\)*\\)?\\'")
(defconst drgnx-toml--time-re "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\(?:\\.[0-9]+\\)?")
(defconst drgnx-toml--zone-re "\\(?:[Zz]\\|[+-][0-9][0-9]:[0-9][0-9]\\)")
(defconst drgnx-toml--date-re
  (concat "\\`\\(?:[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\(?:[Tt ]" drgnx-toml--time-re drgnx-toml--zone-re "?\\)?\\|"
          drgnx-toml--time-re "\\)\\'"))

(defun drgnx-toml--bare-value ()
  "A number, boolean or date at point."
  (let ((start (point)))
    (unless (looking-at "[^] \t\r\n,}#]+") (drgnx-toml--fail "expected a value"))
    (goto-char (match-end 0))
    (let ((token (match-string-no-properties 0)))
      ;; a date and a time separated by a space is one value
      (when (and (string-match-p "\\`[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9]\\'" token)
                 (looking-at (concat " " drgnx-toml--time-re drgnx-toml--zone-re "?")))
        (goto-char (match-end 0))
        (setq token (buffer-substring-no-properties start (point))))
      (cond
       ((equal token "true") t)
       ((equal token "false") :false)
       ((string-match-p drgnx-toml--int-re token) (string-to-number (string-replace "_" "" token)))
       ((string-match-p drgnx-toml--radix-re token)
        (let ((clean (string-replace "_" "" (substring token 2))))
          (string-to-number clean (pcase (aref token 1) (?x 16) (?o 8) (_ 2)))))
       ((string-match-p drgnx-toml--float-re token) (float (string-to-number (string-replace "_" "" token))))
       ((string-match-p "\\`[+-]?inf\\'" token) (if (eq (aref token 0) ?-) -1.0e+INF 1.0e+INF))
       ((string-match-p "\\`[+-]?nan\\'" token) 0.0e+NaN)
       ((string-match-p drgnx-toml--date-re token) (cons :date token))
       (t (drgnx-toml--fail (format "not a value: %s" token) start))))))

(defun drgnx-toml--array ()
  "An array at point, as a vector."
  (let ((start (point)) (items nil))
    (forward-char)
    (catch 'done
      (while t
        (drgnx-toml--trivia)
        (cond ((eobp) (drgnx-toml--fail "unterminated array" start))
              ((eq (char-after) ?\]) (forward-char) (throw 'done nil)))
        (push (drgnx-toml--value) items)
        (drgnx-toml--trivia)
        (cond ((eq (char-after) ?,) (forward-char))
              ((eq (char-after) ?\]) (forward-char) (throw 'done nil))
              (t (drgnx-toml--fail "expected , or ] in an array")))))
    (vconcat (nreverse items))))

(defun drgnx-toml--inline-table ()
  "An inline table at point, as an alist."
  (let ((start (point)) (tbl (drgnx-toml--tbl-make)))
    (forward-char)
    (catch 'done
      (while t
        (drgnx-toml--trivia)
        (cond ((eobp) (drgnx-toml--fail "unterminated inline table" start))
              ((eq (char-after) ?\}) (forward-char) (throw 'done nil)))
        (let ((line (line-number-at-pos)) (keys (drgnx-toml--key)))
          (drgnx-toml--ws)
          (unless (eq (char-after) ?=) (drgnx-toml--fail "expected ="))
          (forward-char)
          (drgnx-toml--ws)
          (drgnx-toml--assign tbl keys (drgnx-toml--value) line))
        (drgnx-toml--trivia)
        (cond ((eq (char-after) ?,) (forward-char))
              ((eq (char-after) ?\}) (forward-char) (throw 'done nil))
              (t (drgnx-toml--fail "expected , or } in an inline table")))))
    (drgnx-toml--final tbl)))

(defun drgnx-toml--value ()
  "The value at point."
  (let ((c (char-after)))
    (pcase c
      ('nil (drgnx-toml--fail "expected a value"))
      (?\" (if (looking-at "\"\"\"") (drgnx-toml--multi-line ?\" t) (drgnx-toml--basic-string)))
      (?' (if (looking-at "'''") (drgnx-toml--multi-line ?' nil) (drgnx-toml--literal-string)))
      (?\[ (drgnx-toml--array))
      (?\{ (drgnx-toml--inline-table))
      (_ (drgnx-toml--bare-value)))))

(defun drgnx-toml--scan (string)
  "The statements of STRING in order, each a plist.
:type is `table' (a [header]), `aot' (a [[header]]) or `kv'; :beg and :end are 1-based buffer positions
(the start of the statement's line, and just after its line end), :line its line number.  A header has :path;
a key/value has :keys (the written key parts), :value and :header (the path of the header it sits under)."
  (let ((case-fold-search nil) (out nil) (header nil) start)
    (with-temp-buffer
      (insert string)
      (goto-char (point-min))
      (when (eq (char-after) #xFEFF) (forward-char))   ; a byte order mark is no part of any statement
      (setq start (point))
      (while (not (eobp))
        (let ((bol (max (line-beginning-position) start)) (line (line-number-at-pos)))
          (drgnx-toml--ws)
          (cond
           ((eobp))
           ((looking-at "\r?\n") (goto-char (match-end 0)))
           ((eq (char-after) ?#) (forward-line 1))
           ((eq (char-after) ?\[)
            (let* ((aot (looking-at "\\[\\["))
                   (path (progn (forward-char (if aot 2 1))
                                (drgnx-toml--ws)
                                (prog1 (drgnx-toml--key) (drgnx-toml--ws)))))
              (unless (looking-at (if aot "\\]\\]" "\\]")) (drgnx-toml--fail "expected the end of the table name"))
              (goto-char (match-end 0))
              (drgnx-toml--eol)
              (setq header path)
              (push (list :type (if aot 'aot 'table) :path path :beg bol :end (point) :line line) out)))
           (t
            (let ((keys (drgnx-toml--key)))
              (drgnx-toml--ws)
              (unless (eq (char-after) ?=) (drgnx-toml--fail "expected ="))
              (forward-char)
              (drgnx-toml--ws)
              (let ((value (drgnx-toml--value)))
                (drgnx-toml--eol)
                (push (list :type 'kv :keys keys :value value :header header :beg bol :end (point) :line line) out))))))))
    (nreverse out)))

;;;; Building the alist

(cl-defstruct (drgnx-toml--tbl (:constructor drgnx-toml--tbl-make (&optional kind)))
  kind     ; nil (the root), `implicit', `defined' (a header), `dotted'
  entries) ; (KEY . VALUE) in reverse file order

(cl-defstruct (drgnx-toml--aot (:constructor drgnx-toml--aot-make ()))
  tbls)    ; the entries, newest first

(defun drgnx-toml--final (v)
  "V with building structures turned into alists and vectors."
  (cond ((drgnx-toml--tbl-p v)
         (mapcar (lambda (c) (cons (car c) (drgnx-toml--final (cdr c)))) (reverse (drgnx-toml--tbl-entries v))))
        ((drgnx-toml--aot-p v)
         (vconcat (mapcar #'drgnx-toml--final (reverse (drgnx-toml--aot-tbls v)))))
        (t v)))

(defun drgnx-toml--child (tbl key line kind)
  "The table under KEY in TBL, made with KIND when missing (the newest entry of an array of tables)."
  (let ((cell (assoc key (drgnx-toml--tbl-entries tbl))))
    (cond ((null cell)
           (let ((new (drgnx-toml--tbl-make kind)))
             (push (cons key new) (drgnx-toml--tbl-entries tbl))
             new))
          ((drgnx-toml--tbl-p (cdr cell)) (cdr cell))
          ((drgnx-toml--aot-p (cdr cell)) (car (drgnx-toml--aot-tbls (cdr cell))))
          (t (drgnx-toml--signal line (format "%s is not a table" key))))))

(defun drgnx-toml--assign (tbl keys value line)
  "Put VALUE at KEYS (dotted) under TBL."
  (dolist (k (butlast keys))
    (setq tbl (drgnx-toml--child tbl k line 'dotted)))
  (let ((key (car (last keys))))
    (when (assoc key (drgnx-toml--tbl-entries tbl))
      (drgnx-toml--signal line (format "duplicate key %s" key)))
    (push (cons key value) (drgnx-toml--tbl-entries tbl))))

(defun drgnx-toml--open (root path line aot)
  "The table a [PATH] (or [[PATH]] when AOT) header at LINE opens under ROOT."
  (let ((tbl root))
    (dolist (k (butlast path))
      (setq tbl (drgnx-toml--child tbl k line 'implicit)))
    (let* ((key (car (last path)))
           (cell (assoc key (drgnx-toml--tbl-entries tbl))))
      (cond
       (aot
        (cond ((null cell)
               (let ((a (drgnx-toml--aot-make)) (new (drgnx-toml--tbl-make 'defined)))
                 (push new (drgnx-toml--aot-tbls a))
                 (push (cons key a) (drgnx-toml--tbl-entries tbl))
                 new))
              ((drgnx-toml--aot-p (cdr cell))
               (let ((new (drgnx-toml--tbl-make 'defined)))
                 (push new (drgnx-toml--aot-tbls (cdr cell)))
                 new))
              (t (drgnx-toml--signal line (format "%s is not an array of tables" key)))))
       ((null cell)
        (let ((new (drgnx-toml--tbl-make 'defined)))
          (push (cons key new) (drgnx-toml--tbl-entries tbl))
          new))
       ((and (drgnx-toml--tbl-p (cdr cell)) (eq (drgnx-toml--tbl-kind (cdr cell)) 'implicit))
        (setf (drgnx-toml--tbl-kind (cdr cell)) 'defined)
        (cdr cell))
       (t (drgnx-toml--signal line (format "table %s is defined twice" key)))))))

(defun drgnx-toml-parse (string)
  "STRING (TOML text) as an alist; see the Commentary for the shapes.
A syntax error signals `drgnx-toml-error' with data (LINE MESSAGE)."
  (let* ((root (drgnx-toml--tbl-make)) (cur root))
    (dolist (st (drgnx-toml--scan string))
      (pcase (plist-get st :type)
        ('kv (drgnx-toml--assign cur (plist-get st :keys) (plist-get st :value) (plist-get st :line)))
        ('table (setq cur (drgnx-toml--open root (plist-get st :path) (plist-get st :line) nil)))
        ('aot (setq cur (drgnx-toml--open root (plist-get st :path) (plist-get st :line) t)))))
    (drgnx-toml--final root)))

;;;; Encoding

(defun drgnx-toml--encode-string (s)
  "S as a TOML basic string."
  (concat "\""
          (mapconcat (lambda (c)
                       (pcase c
                         (?\" "\\\"") (?\\ "\\\\") (?\n "\\n") (?\t "\\t") (?\r "\\r") (?\b "\\b") (?\f "\\f")
                         (_ (if (or (< c 32) (= c 127)) (format "\\u%04X" c) (string c)))))
                     s "")
          "\""))

(defun drgnx-toml--encode-key (k)
  "K (a string) as a bare or quoted key part."
  (unless (stringp k) (drgnx-toml--signal nil (format "a key must be a string: %S" k)))
  (if (string-match-p "\\`[A-Za-z0-9_-]+\\'" k) k (drgnx-toml--encode-string k)))

(defun drgnx-toml--table-p (v)
  "Non-nil when V is an alist of (STRING . VALUE) (nil is the empty table)."
  (and (listp v) (not (null v)) (cl-every (lambda (c) (and (consp c) (stringp (car c)))) v)))

(defun drgnx-toml-encode-value (value)
  "VALUE as TOML text on one line: nested alists become inline tables."
  (cond
   ((eq value t) "true")
   ((eq value :false) "false")
   ((null value) "{}")
   ((stringp value) (drgnx-toml--encode-string value))
   ((integerp value) (number-to-string value))
   ((floatp value) (cond ((isnan value) "nan")
                         ((= value 1.0e+INF) "inf")
                         ((= value -1.0e+INF) "-inf")
                         (t (number-to-string value))))
   ((and (consp value) (eq (car value) :date))
    (unless (and (stringp (cdr value)) (string-match-p drgnx-toml--date-re (cdr value)))
      (drgnx-toml--signal nil (format "not a date or time: %S" (cdr value))))
    (cdr value))
   ((vectorp value) (concat "[" (mapconcat #'drgnx-toml-encode-value value ", ") "]"))
   ((drgnx-toml--table-p value)
    (concat "{ " (mapconcat (lambda (c) (concat (drgnx-toml--encode-key (car c)) " = " (drgnx-toml-encode-value (cdr c))))
                            value ", ")
            " }"))
   (t (drgnx-toml--signal nil (format "cannot encode %S" value)))))

(defun drgnx-toml--encode-block (path alist aot eol)
  "The text of a [PATH] (or [[PATH]] when AOT) header followed by ALIST's keys, every line ending in EOL."
  (concat (if aot "[[" "[")
          (mapconcat #'drgnx-toml--encode-key path ".")
          (if aot "]]" "]")
          eol
          (mapconcat (lambda (c) (concat (drgnx-toml--encode-key (car c)) " = " (drgnx-toml-encode-value (cdr c)) eol))
                     alist "")))

(defun drgnx-toml--eol-of (string)
  "The line end STRING uses: CRLF when its first line ends that way, else LF."
  (let ((i (string-search "\n" string)))
    (if (and i (> i 0) (eq (aref string (1- i)) ?\r)) "\r\n" "\n")))

(defun drgnx-toml--bom-length (string)
  "1 when STRING starts with a byte order mark, else 0."
  (if (and (> (length string) 0) (eq (aref string 0) #xFEFF)) 1 0))

;;;; Regions and the writer

(defun drgnx-toml--prefix-p (prefix list)
  "Non-nil when PREFIX is a prefix of (or equal to) LIST."
  (and (<= (length prefix) (length list)) (equal prefix (cl-subseq list 0 (length prefix)))))

(defun drgnx-toml--header-p (st) (memq (plist-get st :type) '(table aot)))

(defun drgnx-toml--refuse (st)
  (drgnx-toml--signal (plist-get st :line) "defined in a form drgnx does not edit"))

(defun drgnx-toml--check-keys (stmts path inside)
  "Refuse when a key/value outside the edited text defines PATH, part of it, or something below it.
INSIDE is a predicate on a statement saying it is part of what will be rewritten."
  (dolist (st stmts)
    (when (and (eq (plist-get st :type) 'kv) (not (funcall inside st)))
      (let ((abs (append (plist-get st :header) (plist-get st :keys))))
        (when (or (drgnx-toml--prefix-p abs path) (drgnx-toml--prefix-p path abs))
          (drgnx-toml--refuse st))))))

;; A "run" is the statements of one edited block: a header, its keys, and the sub-table headers (and their keys)
;; that follow it.  It is a list of statements, in file order.

(defun drgnx-toml--run-from (from path)
  "The run that starts at FROM (a tail of the statement list): FROM's statement, then everything up to the next
header that is not strictly below PATH."
  (let ((run (list (car from))))
    (catch 'done
      (dolist (st (cdr from))
        (when (and (drgnx-toml--header-p st)
                   (not (and (drgnx-toml--prefix-p path (plist-get st :path))
                             (> (length (plist-get st :path)) (length path)))))
          (throw 'done nil))
        (push st run)))
    (nreverse run)))

(defun drgnx-toml--table-run (stmts path)
  "The run of statements editing the table PATH: its header (or, without one, its first sub-table header) to
the last key or header below it.  nil when absent.  Signals on forms drgnx does not edit."
  (when (null path) (drgnx-toml--signal nil "an empty table path"))
  (dolist (st stmts)
    ;; an array of tables at PATH, above it (which entry?) or below it (it would become an inline array)
    (when (and (eq (plist-get st :type) 'aot)
               (or (drgnx-toml--prefix-p (plist-get st :path) path) (drgnx-toml--prefix-p path (plist-get st :path))))
      (drgnx-toml--refuse st)))
  (let* ((first (or (cl-find-if (lambda (st) (and (eq (plist-get st :type) 'table) (equal (plist-get st :path) path)))
                                stmts)
                    (cl-find-if (lambda (st) (and (drgnx-toml--header-p st) (drgnx-toml--prefix-p path (plist-get st :path))))
                                stmts)))
         (run (and first (drgnx-toml--run-from (memq first stmts) path))))
    (dolist (st stmts)
      (when (and (drgnx-toml--header-p st) (drgnx-toml--prefix-p path (plist-get st :path)) (not (memq st run)))
        (drgnx-toml--refuse st)))
    (drgnx-toml--check-keys stmts path
                            (lambda (st) (or (memq st run) (drgnx-toml--prefix-p path (plist-get st :header)))))
    run))

(defun drgnx-toml--entry-runs (stmts path)
  "The runs of every [[PATH]] entry in STMTS, in file order; refuses forms drgnx does not edit."
  (when (null path) (drgnx-toml--signal nil "an empty table path"))
  (let ((runs nil) (members nil))
    (dolist (st stmts)
      (when (and (eq (plist-get st :type) 'aot) (drgnx-toml--prefix-p (plist-get st :path) path)
                 (< (length (plist-get st :path)) (length path)))
        (drgnx-toml--refuse st))
      (when (and (eq (plist-get st :type) 'aot) (equal (plist-get st :path) path))
        (let ((run (drgnx-toml--run-from (memq st stmts) path)))
          (push run runs)
          (setq members (append run members)))))
    (dolist (st stmts)
      (when (and (drgnx-toml--header-p st) (drgnx-toml--prefix-p path (plist-get st :path)) (not (memq st members)))
        (drgnx-toml--refuse st)))
    (drgnx-toml--check-keys stmts path
                            (lambda (st) (or (memq st members) (drgnx-toml--prefix-p path (plist-get st :header)))))
    (nreverse runs)))

(defun drgnx-toml--run-range (run)
  "RUN's text range (BEG . END), 0-based."
  (cons (1- (plist-get (car run) :beg)) (1- (plist-get (car (last run)) :end))))

(defun drgnx-toml-table-region (string path)
  "The region (BEG . END), 0-based, of the table PATH (a list of keys) in STRING, or nil.
It runs from the `[PATH]' line through the last key or header of PATH and its sub-tables (`[PATH.x]').  Blank
lines and comments after the last of them are not part of it, so a comment leading into the next table stays."
  (let ((run (drgnx-toml--table-run (drgnx-toml--scan string) path)))
    (and run (drgnx-toml--run-range run))))

(defun drgnx-toml--blank-line-end (string pos)
  "The index after the empty line starting at POS in STRING, or nil when that line is not empty."
  (and (eq (string-match "\r?\n" string pos) pos) (match-end 0)))

(defun drgnx-toml--splice (string beg end text)
  "STRING with BEG..END replaced by TEXT; nil TEXT removes the range together with one adjoining blank line."
  (if text
      (concat (substring string 0 beg) text (substring string end))
    (let* ((tail-blank (string-match-p "\\`[ \t\r\n]*\\'" (substring string end)))
           (blank-before (string-match-p "\n\r?\n\\'" (substring string (max 0 (- beg 3)) beg)))
           (at-start (<= beg (drgnx-toml--bom-length string)))
           (blank-after (and (not tail-blank) (drgnx-toml--blank-line-end string end))))
      (cond
       ((and tail-blank blank-before)
        (setq beg (- beg (if (string-suffix-p "\r\n" (substring string 0 beg)) 2 1))))
       ((and blank-after (or blank-before at-start)) (setq end blank-after)))
      (concat (substring string 0 beg) (substring string end)))))

(defun drgnx-toml--append (string text eol)
  "STRING with the block TEXT added at the end, after a blank line (EOL is the file's line end)."
  (if (<= (length string) (drgnx-toml--bom-length string))
      (concat string text)
    (concat string
            (unless (string-suffix-p "\n" string) eol)
            (unless (string-match-p "\n\r?\n\\'" string) eol)
            text)))

(defun drgnx-toml-set-table (string path alist)
  "STRING with the table PATH (a list of keys) set to ALIST, changing nothing outside that table.
The table's text (its header, keys and sub-tables) is replaced by fresh text with nested alists as inline tables;
it is appended at the end when absent, and removed when ALIST is nil.  When PATH is defined some other way (dotted
keys in a parent table, an inline table, an array of tables) it signals `drgnx-toml-error' with that line."
  (let* ((stmts (drgnx-toml--scan string))
         (run (drgnx-toml--table-run stmts path))
         (eol (drgnx-toml--eol-of string))
         (text (and alist (drgnx-toml--encode-block path alist nil eol))))
    (cond
     (run (let ((r (drgnx-toml--run-range run))) (drgnx-toml--splice string (car r) (cdr r) text)))
     (text (drgnx-toml--append string text eol))
     (t string))))

(defun drgnx-toml-set-array-entry (string path pred alist)
  "STRING with the `[[PATH]]' entry PRED accepts set to ALIST, changing nothing outside that entry.
PRED is called with each entry as an alist (its sub-tables included), in file order.  The first accepted entry is
replaced, or removed when ALIST is nil; when none is accepted ALIST is appended as a new entry."
  (let* ((stmts (drgnx-toml--scan string))
         (runs (drgnx-toml--entry-runs stmts path))
         (run (cl-find-if
               (lambda (r)
                 (let* ((range (drgnx-toml--run-range r))
                        (node (drgnx-toml-parse (substring string (car range) (cdr range)))))
                   ;; the entry is the (only) element of the array at PATH in the entry's own text
                   (dolist (k path)
                     (setq node (cdr (assoc k node)))
                     (when (vectorp node) (setq node (aref node 0))))
                   (funcall pred node)))
               runs))
         (eol (drgnx-toml--eol-of string))
         (text (and alist (drgnx-toml--encode-block path alist t eol))))
    (cond
     (run (let ((r (drgnx-toml--run-range run))) (drgnx-toml--splice string (car r) (cdr r) text)))
     (text (drgnx-toml--append string text eol))
     (t string))))

(provide 'drgnx-toml)
;;; drgnx-toml.el ends here
