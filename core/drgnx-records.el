;;; drgnx-records.el --- records as JSON, guided by schemas -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub's records (a session's snapshot, a transcript entry, an event's, a card's, a job's and a work node's
;; `data') travel and rest as JSON, not as printed Lisp.  This file turns a Lisp record into a value `json-serialize'
;; takes and back, walking the schema (`drgnx-schema.el', the one schema DSL) and the data together:
;;
;; - A keyword plist is an object; `(list-of S)' an array (nil is `[]'); `(alist string S)' and `(map S)' objects;
;;   `(enum …)' and `symbol' strings; `boolean' is `true' or `false'.  Any other nil value leaves its key out.
;; - Keys the schema does not list pass through by plain JSON rules (string, number, t, nested keyword plists, lists
;;   of atoms).  A symbol there is an error (`drgnx-records-unknown-symbol'): every symbol is an enum in a schema.
;; - Decoding interns nothing: an enum string becomes the member it names, any other string is refused
;;   (`drgnx-records-invalid', with `(PATH . TEXT)').  `read' is never called.
;;
;; The input of `drgnx-records-from-json' is what `json-parse-string' gives with `:object-type' `plist',
;; `:array-type' `list', `:null-object' nil and `:false-object' nil (`drgnx-records-decode' parses so).  See
;; docs/develop/core.md, "Records".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-schema)

(define-error 'drgnx-records-invalid "Not a valid record")
(define-error 'drgnx-records-unknown-symbol "A symbol no schema covers" 'drgnx-records-invalid)

(defconst drgnx-records--max-depth 100 "How deep a record may nest: a deeper one is refused.")

(defun drgnx-records--fail (condition rpath text)
  "Signal CONDITION with `(PATH . TEXT)', PATH being the reversed RPATH put right."
  (signal condition (cons (reverse rpath) text)))

(defun drgnx-records--resolve (schema)
  "SCHEMA with named types looked through to the schema they stand for."
  (let (def)
    (while (and schema (symbolp schema) (setq def (gethash schema drgnx-schema--types)))
      (setq schema (car def)))
    schema))

(defun drgnx-records--plist-p (value)
  "Whether VALUE is a keyword plist (an object as the parser gives it)."
  (and (keywordp (car-safe value)) (proper-list-p value) (cl-evenp (length value))))

(defun drgnx-records--key-name (key)
  "The name of the keyword KEY without its colon."
  (substring (symbol-name key) 1))

(defun drgnx-records--name (x)
  "The name of the symbol or string X (a keyword without its colon), or nil for anything else."
  (cond ((stringp x) x)
        ((keywordp x) (drgnx-records--key-name x))
        ((and x (symbolp x)) (symbol-name x))))

(defun drgnx-records--nil-kept-p (schema)
  "Whether a nil value of SCHEMA is written (`false' or `[]'), not left out."
  (let ((s (drgnx-records--resolve schema)))
    (or (eq s 'boolean) (eq (car-safe s) 'list-of))))

;;;; Lisp to JSON

(defun drgnx-records--enc-any (value rpath depth)
  "VALUE, which no schema describes, as JSON data by plain rules; a symbol is refused."
  (when (> depth drgnx-records--max-depth) (drgnx-records--fail 'drgnx-records-invalid rpath "nested too deep"))
  (cond ((null value) nil)
        ((or (eq value t) (memq value '(:false :null)) (stringp value) (numberp value)) value)
        ((symbolp value) (drgnx-records--fail 'drgnx-records-unknown-symbol rpath "a symbol no schema covers"))
        ((vectorp value) (drgnx-records--enc-list (append value nil) 'any rpath depth))
        ((drgnx-records--plist-p value)
         (let ((out nil) (seen nil))
           (cl-loop for (k v) on value by #'cddr
                    do (when (memq k seen) (drgnx-records--fail 'drgnx-records-invalid (cons k rpath) "the key is given twice"))
                    (push k seen)
                    (when-let* ((e (drgnx-records--enc-any v (cons k rpath) (1+ depth)))) (push k out) (push e out)))
           (nreverse out)))
        ((proper-list-p value) (drgnx-records--enc-list value 'any rpath depth))
        (t (drgnx-records--fail 'drgnx-records-invalid rpath "not JSON data"))))

(defun drgnx-records--enc-list (value elem rpath depth)
  "The proper list VALUE as a vector of its elements encoded by ELEM."
  (unless (proper-list-p value) (drgnx-records--fail 'drgnx-records-invalid rpath "expected a list"))
  (let ((i -1))
    (apply #'vector
           (mapcar (lambda (v)
                     (let ((e (drgnx-records--enc elem v (cons (cl-incf i) rpath) (1+ depth))))
                       (if (and (null e) (null v)) :null e)))
                   value))))

(defun drgnx-records--enc-plist (entries value rpath depth)
  "VALUE, a keyword plist, as a plist of JSON data: ENTRIES (a plist schema's) say how a key's value is written."
  (unless (drgnx-records--plist-p value)
    (if value (drgnx-records--fail 'drgnx-records-invalid rpath "expected a plist") (setq value nil)))
  (let ((out nil) (seen nil))
    (cl-loop for (k v) on value by #'cddr
             do (let ((entry (assq k entries)) (kpath (cons k rpath)))
                  (when (memq k seen) (drgnx-records--fail 'drgnx-records-invalid kpath "the key is given twice"))
                  (push k seen)
                  (cond ((and (null v) (not (and entry (drgnx-records--nil-kept-p (nth 1 entry))))))
                        (t (let ((e (if entry (drgnx-records--enc (nth 1 entry) v kpath (1+ depth))
                                      (drgnx-records--enc-any v kpath (1+ depth)))))
                             (when e (push k out) (push e out)))))))
    (nreverse out)))

(defun drgnx-records--enc-pairs (key-s val-s value rpath depth)
  "VALUE, an alist with string keys or a keyword plist, as a hash table (an object) of VAL-S's encodings."
  (let ((table (make-hash-table :test 'equal))
        (pairs (cond ((null value) nil)
                     ((drgnx-records--plist-p value)
                      (cl-loop for (k v) on value by #'cddr collect (cons (drgnx-records--key-name k) v)))
                     ((and (proper-list-p value) (cl-every #'consp value)) value)
                     (t (drgnx-records--fail 'drgnx-records-invalid rpath "expected an object")))))
    (dolist (pair pairs)
      (let* ((kpath (cons (car pair) rpath))
             (key (drgnx-records--enc key-s (car pair) kpath (1+ depth))))
        (unless (stringp key) (drgnx-records--fail 'drgnx-records-invalid kpath "an object key that is not a string"))
        (when (gethash key table) (drgnx-records--fail 'drgnx-records-invalid kpath "the key is given twice"))
        (let ((e (drgnx-records--enc val-s (cdr pair) kpath (1+ depth))))
          (puthash key (if (and (null e) (null (cdr pair))) :null e) table))))
    table))

(defun drgnx-records--enc (schema value rpath depth)
  "VALUE as JSON data, as SCHEMA (a schema, named types and all) describes it; RPATH is the reversed path."
  (when (> depth drgnx-records--max-depth) (drgnx-records--fail 'drgnx-records-invalid rpath "nested too deep"))
  (let ((s (drgnx-records--resolve schema)))
    (cl-flet ((bad (text) (drgnx-records--fail 'drgnx-records-invalid rpath text)))
      (if (symbolp s)
          (pcase s
            ('any (drgnx-records--enc-any value rpath depth))
            ('boolean (cond ((eq value t) t) ((null value) :false) (t (bad "expected t or nil"))))
            ('symbol (if (and value (symbolp value) (not (keywordp value))) (symbol-name value) (bad "expected a symbol")))
            ('keyword (if (keywordp value) (drgnx-records--key-name value) (bad "expected a keyword")))
            ('null (if value (bad "expected nil") nil))
            ((or 'string 'home-path 'https-url) (if (stringp value) value (bad "expected a string")))
            ((or 'integer 'natnum) (if (integerp value) value (bad "expected an integer")))
            ('number (if (numberp value) value (bad "expected a number")))
            (_ (drgnx-schema--unknown-form s)))
        (pcase s
          (`(enum . ,members)
           (let ((name (drgnx-records--name value)))
             (unless (and name (cl-some (lambda (m) (equal (drgnx-records--name m) name)) members))
               (bad "not one of the listed values"))
             name))
          (`(or . ,alts)
           (if (and (null value) (memq 'null alts)) nil
             (let ((alt (cl-find-if (lambda (a) (and (not (eq a 'null)) (null (drgnx-schema-check a value)))) alts)))
               (if alt (drgnx-records--enc alt value rpath (1+ depth)) (bad "fits none of the alternatives")))))
          (`(list-of ,elem . ,_) (drgnx-records--enc-list value elem rpath depth))
          (`(plist . ,entries) (drgnx-records--enc-plist entries value rpath depth))
          (`(alist ,key-s ,val-s) (drgnx-records--enc-pairs key-s val-s value rpath depth))
          (`(map ,val-s . ,opts) (drgnx-records--enc-pairs (or (plist-get opts :keys) 'string) val-s value rpath depth))
          (`(,(or 'integer 'number) . ,_)
           (if (numberp value) value (bad "expected a number")))
          (`(string . ,_) (if (stringp value) value (bad "expected a string")))
          (`(pred . ,_) (drgnx-records--enc-any value rpath depth))
          (_ (drgnx-schema--unknown-form s)))))))

(defun drgnx-records-to-json (schema value)
  "VALUE, a record SCHEMA describes, as a value `json-serialize' takes.
Keyword plists become objects (a key whose value is nil is left out, a boolean's nil is `:false'), enums and
symbols strings, `(list-of S)' vectors (nil is `[]'), `(alist string S)' and `(map S)' objects.  Keys the schema
does not list pass through by plain JSON rules.  Signals `drgnx-records-unknown-symbol' for a symbol no schema
covers and `drgnx-records-invalid' for a value its schema refuses; both carry `(PATH . TEXT)'."
  (drgnx-records--enc schema value nil 0))

(defun drgnx-records-encode (schema value)
  "VALUE, a record SCHEMA describes, as a JSON string (`drgnx-records-to-json')."
  (let ((json (drgnx-records-to-json schema value)))
    (condition-case nil (json-serialize json)
      (error (drgnx-records--fail 'drgnx-records-invalid nil "not serializable as JSON")))))

;;;; JSON to Lisp

(defun drgnx-records--dec-any (value rpath depth)
  "VALUE, parsed JSON that no schema describes, as Lisp: strings stay strings, a nil-valued key is left out."
  (when (> depth drgnx-records--max-depth) (drgnx-records--fail 'drgnx-records-invalid rpath "nested too deep"))
  (cond ((memq value '(:false :null)) nil)
        ((or (null value) (eq value t) (stringp value) (numberp value)) value)
        ((vectorp value) (drgnx-records--dec-list (append value nil) 'any rpath depth))
        ((drgnx-records--plist-p value)
         (let ((out nil))
           (cl-loop for (k v) on value by #'cddr
                    do (when-let* ((d (drgnx-records--dec-any v (cons k rpath) (1+ depth)))) (push k out) (push d out)))
           (nreverse out)))
        ((and (proper-list-p value) (not (keywordp (car value)))) (drgnx-records--dec-list value 'any rpath depth))
        (t (drgnx-records--fail 'drgnx-records-invalid rpath "not JSON data"))))

(defun drgnx-records--dec-list (value elem rpath depth)
  "The array VALUE (a list) as a list of its elements decoded by ELEM."
  (unless (and (proper-list-p value) (not (keywordp (car value))))
    (drgnx-records--fail 'drgnx-records-invalid rpath "expected an array"))
  (let ((i -1))
    (mapcar (lambda (v) (drgnx-records--dec elem v (cons (cl-incf i) rpath) (1+ depth))) value)))

(defun drgnx-records--dec-plist (entries value rpath depth)
  "The object VALUE as a plist: ENTRIES (a plist schema's) say how a key's value is read; a nil value is left out."
  (unless (or (null value) (drgnx-records--plist-p value))
    (drgnx-records--fail 'drgnx-records-invalid rpath "expected an object"))
  (let ((out nil))
    (cl-loop for (k v) on value by #'cddr
             do (let* ((entry (assq k entries)) (kpath (cons k rpath))
                       (d (if entry (drgnx-records--dec (nth 1 entry) v kpath (1+ depth))
                            (drgnx-records--dec-any v kpath (1+ depth)))))
                  (when d (push k out) (push d out))))
    (nreverse out)))

(defun drgnx-records--dec-pairs (key-s val-s value rpath depth asplist)
  "The object VALUE as an alist of (KEY . VALUE) (a keyword plist when ASPLIST), keys read by KEY-S, values by VAL-S."
  (unless (or (null value) (drgnx-records--plist-p value))
    (drgnx-records--fail 'drgnx-records-invalid rpath "expected an object"))
  (let ((out nil))
    (cl-loop for (k v) on value by #'cddr
             do (let* ((name (drgnx-records--key-name k)) (kpath (cons name rpath))
                       (key (drgnx-records--dec key-s name kpath (1+ depth)))
                       (d (drgnx-records--dec val-s v kpath (1+ depth))))
                  (if asplist
                      (when d (push k out) (push d out))
                    (push (cons key d) out))))
    (nreverse out)))

(defun drgnx-records--dec (schema value rpath depth)
  "The parsed JSON VALUE as the Lisp SCHEMA (a schema, named types and all) describes it; RPATH is the reversed path."
  (when (> depth drgnx-records--max-depth) (drgnx-records--fail 'drgnx-records-invalid rpath "nested too deep"))
  (let ((s (drgnx-records--resolve schema)))
    (cl-flet ((bad (text) (drgnx-records--fail 'drgnx-records-invalid rpath text)))
      (if (symbolp s)
          (pcase s
            ('any (drgnx-records--dec-any value rpath depth))
            ('boolean (cond ((eq value t) t) ((memq value '(nil :false)) nil) (t (bad "expected true or false"))))
            ((or 'symbol 'keyword)
             (let ((sym (and (stringp value) (intern-soft (if (eq s 'keyword) (concat ":" value) value)))))
               (if (and sym (eq (keywordp sym) (eq s 'keyword)) (not (eq sym t))) sym (bad "not a symbol drgnx knows"))))
            ('null (if value (bad "expected null") nil))
            ((or 'string 'home-path 'https-url) (if (stringp value) value (bad "expected a string")))
            ((or 'integer 'natnum) (if (integerp value) value (bad "expected an integer")))
            ('number (if (numberp value) value (bad "expected a number")))
            (_ (drgnx-schema--unknown-form s)))
        (pcase s
          (`(enum . ,members)
           (let ((member (and (stringp value) (cl-find value members :test (lambda (v m) (equal v (drgnx-records--name m)))))))
             (or member (bad "not one of the listed values"))))
          (`(or . ,alts)
           (if (and (null value) (memq 'null alts)) nil
             (let ((hit (cl-some (lambda (alt)       ; (DECODED), so a nil result still counts as a hit
                                   (and (not (eq alt 'null))
                                        (condition-case nil
                                            (let ((d (drgnx-records--dec alt value rpath (1+ depth))))
                                              (and (null (drgnx-schema-check alt d)) (list d)))
                                          (drgnx-records-invalid nil))))
                                 alts)))
               (if hit (car hit) (bad "fits none of the alternatives")))))
          (`(list-of ,elem . ,_) (drgnx-records--dec-list value elem rpath depth))
          (`(plist . ,entries) (drgnx-records--dec-plist entries value rpath depth))
          (`(alist ,key-s ,val-s) (drgnx-records--dec-pairs key-s val-s value rpath depth nil))
          (`(map ,val-s . ,opts)
           (drgnx-records--dec-pairs (or (plist-get opts :keys) 'string) val-s value rpath depth t))
          (`(,(or 'integer 'number) . ,_) (if (numberp value) value (bad "expected a number")))
          (`(string . ,_) (if (stringp value) value (bad "expected a string")))
          (`(pred . ,_) (drgnx-records--dec-any value rpath depth))
          (_ (drgnx-schema--unknown-form s)))))))

(defun drgnx-records-from-json (schema value)
  "The Lisp record SCHEMA describes, from VALUE as `json-parse-string' gives it.
VALUE is parsed with `:object-type' `plist', `:array-type' `list', `:null-object' nil and `:false-object' nil.
A nil-valued key is left out.  An enum string is the member it names; no other string becomes a symbol.  A value
SCHEMA refuses, or any other string for an enum, signals `drgnx-records-invalid' with `(PATH . TEXT)'.  `read' is
never called."
  (let ((record (drgnx-records--dec schema value nil 0)))
    (when-let* ((problem (drgnx-schema-check schema record)))
      (signal 'drgnx-records-invalid (cons (car problem) (cdr problem))))
    record))

(defun drgnx-records-decode (schema string)
  "The Lisp record SCHEMA describes, from the JSON STRING (`drgnx-records-from-json')."
  (drgnx-records-from-json
   schema
   (condition-case nil
       (json-parse-string string :object-type 'plist :array-type 'list :null-object nil :false-object nil)
     (error (drgnx-records--fail 'drgnx-records-invalid nil "not valid JSON")))))

;;;; The named records

(drgnx-schema-deftype 'drgnx-records-rpc-id '(or integer string)
                      "A JSON-RPC id: a number or a string, as the agent chose it.")

(drgnx-schema-deftype
 'drgnx-records-session
 '(plist (:id string "The session's id") (:name string) (:profile string) (:cwd string) (:task string) (:job string)
         (:status (enum starting idle busy exited) "Where the session is in its life")
         (:via (enum gateway direct) "Whether its traffic goes through the gateway")
         (:mode (enum queue steer interrupt) "What a message sent while it works does")
         (:queue (list-of string) "Messages waiting for the turn to end") (:paused boolean)
         (:permissions (list-of (plist (:id drgnx-records-rpc-id) (:title string) (:tool any) (:options (list-of any))))
                       "Requests the agent waits on")
         (:reviews (list-of (plist (:id drgnx-records-rpc-id) (:path string) (:content string))) "Writes held for review")
         (:usage (plist (:used number) (:size number) (:cost any))) (:commands (list-of any)) (:capabilities any)
         (:exit integer "The agent process's exit status") (:stderr string) (:entries-count natnum) (:enforced boolean))
 "What an editor mirrors of an agent session, everything but its transcript: the keys of `drgnx-hub--snapshot'.")

(drgnx-schema-deftype
 'drgnx-records-entry
 '(plist (:type (enum user agent thought tool plan stop error usage notice compaction)
                "What the entry is (usage, notice and compaction are reserved)")
         (:text string "The entry's whole text (no :chunks)") (:length natnum) (:id drgnx-records-rpc-id) (:title string)
         (:kind string) (:status string) (:content any) (:url string) (:children (list-of drgnx-records-entry))
         (:entries (list-of any)) (:stop string) (:steer boolean) (:done boolean))
 "One entry of a session's transcript, its text joined.")

(drgnx-schema-deftype
 'drgnx-records-event-data
 '(plist (:accepted boolean) (:agent string) (:answers natnum) (:base string) (:branch string) (:by string) (:card natnum)
         (:choice string) (:command string) (:cwd string) (:direct boolean) (:failed natnum) (:hash string) (:head string)
         (:id string) (:into string) (:kind string) (:line natnum) (:message natnum) (:more natnum) (:n integer)
         (:op string) (:option string) (:parts (list-of string)) (:passed natnum) (:path string) (:paths (list-of string))
         (:permission drgnx-records-rpc-id) (:proposed natnum) (:question natnum) (:rate number) (:requested boolean)
         (:root string) (:size natnum) (:state string) (:status string) (:to string)
         (:truncated boolean "Set with :size when the data was too long to keep") (:turn boolean)
         (:ver integer) (:verdict (enum pass fail)) (:version integer))
 "The `data' of an event, one plist for every kind's keys (what each kind carries is in docs/develop/coordination.md).")

(drgnx-schema-deftype
 'drgnx-records-card-data
 '(plist (:agent string) (:files (list-of string)) (:gate boolean) (:key string) (:lines natnum) (:message natnum)
         (:no-recommendation boolean) (:profile string) (:rate number) (:recommendation (plist (:side string) (:why string)))
         (:request drgnx-records-rpc-id) (:review boolean) (:rule string) (:sid string)
         (:sides (list-of (plist (:label string) (:text string) (:decision natnum) (:agent string) (:task string)
                                 (:reason string))))
         (:size (or string natnum) "A clash's size (long or short), or the byte count of truncated data")
         (:subject string) (:truncated boolean))
 "The `data' of a card: what the code that raises each kind of card keeps for acting on it.")

(drgnx-schema-deftype
 'drgnx-records-job-data
 '(plist (:plan string) (:sha string) (:repo string) (:title string)
         (:tasks (list-of (plist (:n natnum) (:title string) (:role string) (:deps (list-of natnum)) (:body string))))
         (:routes (alist (enum implement test docs review review-long) (or string (list-of string)))
                  "Which profile does each role, as proposed")
         (:estimate (plist (:usd number) (:tokens natnum) (:unpriced (list-of string))))
         (:budget number) (:gate (enum review review+accept) "What gates a merge") (:unpriced-budget (list-of string))
         (:fails (alist string natnum)) (:exits (alist string natnum)) (:nudged (alist string natnum))
         (:in-review-since (alist string number)) (:notes (alist string string))
         (:waiting (alist string (plist (:sid string) (:back string)))) (:blocked (alist string (or string boolean)))
         (:profiles (alist string string)) (:bases (alist string string)) (:order (list-of string))
         (:clashes (list-of string)) (:truncated boolean))
 "A job's `data': its proposal and what the job keeps while it runs (counts, notes, what waits, the run order).")

(drgnx-schema-deftype
 'drgnx-records-node-data
 '(plist (:sha string) (:date integer) (:repo string) (:seq integer) (:range-stale boolean) (:name string)
         (:branch string) (:worktree string) (:merged boolean) (:gone boolean) (:stale boolean) (:truncated boolean))
 "The `data' of a work node: what its columns do not hold (a commit's sha and date, a branch's worktree, flags).")

(provide 'drgnx-records)
;;; drgnx-records.el ends here
