;;; drgnx-schema.el --- the one schema DSL for drgnx's data -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A schema is data: an atom (`string', `home-path', a name from `drgnx-schema-deftype') or a list
;; (`(list-of string)', `(plist (:key SCHEMA)…)').  `drgnx-schema-check' walks the schema, not the data, and
;; returns nil or `(PATH . TEXT)' for the first problem.  Unknown plist keys are allowed (and survive a write);
;; `drgnx-schema-unknown-keys' lists them.  `drgnx-schema-describe' feeds the generated reference.
;; A problem's text never quotes the value (it may be a token).  See docs/develop/core.md.
;;
;; This is the only schema DSL.  Other layers (the hub's parameters, MCP's JSON Schema) add forms here and read
;; the schema with `drgnx-schema-uses-form-p' rather than defining another.  Requires only `cl-lib' and `subr-x'.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defconst drgnx-schema--atoms
  '(any symbol keyword string boolean null integer natnum number home-path https-url)
  "Atoms that are schemas by themselves.")

(defconst drgnx-schema--heads
  '(integer number string enum or list-of plist alist map pred)
  "Heads of the list forms.")

(defvar drgnx-schema--types (make-hash-table :test 'eq)
  "Named types: NAME -> (SCHEMA . DOC), from `drgnx-schema-deftype'.  Bounded by the definitions in the code.")

(defvar drgnx-schema--acc nil
  "The rows `drgnx-schema-unknown-keys' and `drgnx-schema-describe' collect (bound by them).")

(defun drgnx-schema-deftype (name schema doc)
  "Name SCHEMA NAME, described by DOC.  Redefining a type replaces it.  Return NAME.
SCHEMA is validated (`drgnx-schema-validate'); a refused definition leaves the table as it was.  NAME may
appear inside SCHEMA only within a container (`plist', `list-of', …), never as the whole or an `or' alternative."
  (when (or (memq name drgnx-schema--atoms) (memq name drgnx-schema--heads) (not (symbolp name)) (null name))
    (error "drgnx-schema: %S is a built-in form and cannot be redefined" name))
  (unless (stringp doc) (error "drgnx-schema: type %S needs a doc string" name))
  (let ((old (gethash name drgnx-schema--types)))
    (puthash name (cons schema doc) drgnx-schema--types)  ; bound first, so SCHEMA may refer to itself
    (condition-case err
        (progn (drgnx-schema-validate schema)
               (when (drgnx-schema--unguarded-p name schema nil)
                 (error "drgnx-schema: type %S refers to itself with nothing in between" name)))
      (error (if old (puthash name old drgnx-schema--types) (remhash name drgnx-schema--types))
             (signal (car err) (cdr err)))))
  name)

(defun drgnx-schema--unguarded-p (name schema seen)
  "Non-nil when SCHEMA reaches the type NAME without passing through a container (so a check would not end).
SEEN lists the types already followed."
  (cond ((and schema (symbolp schema))
         (cond ((eq schema name) t)
               ((memq schema seen) nil)
               (t (let ((def (gethash schema drgnx-schema--types)))
                    (and def (drgnx-schema--unguarded-p name (car def) (cons schema seen)))))))
        ((eq (car-safe schema) 'or)
         (cl-some (lambda (alt) (drgnx-schema--unguarded-p name alt seen)) (cdr schema)))))

(defun drgnx-schema--bad-form (form)
  "Signal that FORM is a known form used wrongly: a definition's bug."
  (error "drgnx-schema: bad form %S" form))

(defun drgnx-schema--validate-opts (form opts spec)
  "Signal unless OPTS, the options of FORM, are a plist of keys in SPEC, an alist of (KEY . TEST), each value passing TEST."
  (unless (proper-list-p opts) (drgnx-schema--bad-form form))
  (while opts
    (let ((test (cdr (assq (car opts) spec))))
      (unless (and test (cdr opts) (funcall test (cadr opts))) (drgnx-schema--bad-form form)))
    (setq opts (cddr opts))))

(defun drgnx-schema--validate-key-schema (s)
  "Validate S, the value of `:keys'; t so it can serve as a test."
  (drgnx-schema--validate s)
  t)

(defun drgnx-schema--validate-entry (form entry)
  "Validate the plist ENTRY `(KEY S [DOC] [:required BOOL])' of FORM."
  (unless (and (proper-list-p entry) (keywordp (car entry)) (cdr entry)) (drgnx-schema--bad-form form))
  (drgnx-schema--validate (nth 1 entry))
  (let ((rest (cddr entry)))
    (when (stringp (car rest)) (setq rest (cdr rest)))
    (unless (or (null rest) (and (= (length rest) 2) (eq (car rest) :required) (memq (cadr rest) '(t nil))))
      (drgnx-schema--bad-form form))))

(defun drgnx-schema--validate (schema)
  "Signal unless SCHEMA is a well-formed schema whose named types are bound."
  (cond
   ((and schema (symbolp schema))
    (unless (or (memq schema drgnx-schema--atoms) (gethash schema drgnx-schema--types))
      (drgnx-schema--unknown-form schema)))
   ((and (consp schema) (proper-list-p schema))
    (pcase schema
      (`(,(or 'integer 'number) . ,opts) (drgnx-schema--validate-opts schema opts '((:min . numberp) (:max . numberp))))
      (`(string . ,opts) (drgnx-schema--validate-opts schema opts '((:max . natnump) (:match . stringp))))
      (`(enum ,_ . ,_))
      (`(or ,_ . ,_) (mapc #'drgnx-schema--validate (cdr schema)))
      (`(list-of ,elem . ,opts)
       (drgnx-schema--validate elem)
       (drgnx-schema--validate-opts schema opts '((:max . natnump))))
      (`(plist . ,entries)
       (dolist (entry entries) (drgnx-schema--validate-entry schema entry))
       (let ((keys (mapcar #'car entries)))
         (unless (= (length keys) (length (delete-dups (copy-sequence keys)))) (drgnx-schema--bad-form schema))))
      (`(alist ,key-s ,val-s) (drgnx-schema--validate key-s) (drgnx-schema--validate val-s))
      (`(map ,val-s . ,opts)
       (drgnx-schema--validate val-s)
       (drgnx-schema--validate-opts schema opts '((:max . natnump) (:keys . drgnx-schema--validate-key-schema))))
      (`(pred ,fn ,doc) (unless (and fn (symbolp fn) (stringp doc)) (drgnx-schema--bad-form schema)))
      (_ (drgnx-schema--unknown-form schema))))
   (t (drgnx-schema--unknown-form schema))))

(defun drgnx-schema-validate (schema)
  "Return SCHEMA when it is well formed, else signal `error' (a definition's bug), so a typo fails when the schema
is defined and not when data first reaches it.  Checks heads, options and their value types, plist entries,
`pred' arguments and that every named type is bound.  A `pred' function need not be defined yet (it is
looked up when a check runs).  Definitions (`drgnx-schema-deftype', the config layer's and the hub's) call it."
  (drgnx-schema--validate schema)
  schema)

;;;; Problems

(defun drgnx-schema--unknown-form (form)
  "Signal that FORM is no schema: a definition's bug."
  (error "drgnx-schema: unknown form %S" form))

(defun drgnx-schema--bad (rpath text)
  "The problem `(PATH . TEXT)' for the reversed path RPATH."
  (cons (reverse rpath) text))

(defun drgnx-schema--what (value)
  "What VALUE is, for a problem's text (never VALUE itself)."
  (cond ((null value) "nil") ((eq value t) "t") (t (symbol-name (type-of value)))))

(defun drgnx-schema--expected (what value)
  "The text `expected WHAT, got …' for VALUE."
  (format "expected %s, got %s" what (drgnx-schema--what value)))

(defun drgnx-schema--opts (form opts allowed)
  "OPTS (the options of the schema FORM) when every key is in ALLOWED, else signal the definition's bug."
  (let ((rest opts))
    (while rest
      (unless (and (memq (car rest) allowed) (cdr rest))
        (drgnx-schema--unknown-form form))
      (setq rest (cddr rest))))
  opts)

;;;; Atoms

(defun drgnx-schema--home-path-problem (value)
  "Why VALUE is not a home path: absolute, `~' or `~/…', local, no NUL.  Nil when it is."
  (cond ((not (stringp value)) (drgnx-schema--expected "a path string" value))
        ((string-search "\0" value) "a path with a NUL character")
        ((string-match-p "\\`/[^/|:]+:" value) "a remote name, not a local path")
        ((or (string-prefix-p "/" value) (equal value "~") (string-prefix-p "~/" value)) nil)
        (t "not an absolute path, `~' or `~/…'")))

(defun drgnx-schema--https-url-problem (value)
  "Why VALUE is not an https URL with a host and no user info, or nil.  As `drgnx-bootstrap--url-problem'."
  (if (not (stringp value))
      (drgnx-schema--expected "an https URL" value)
    (let ((authority (and (string-prefix-p "https://" value)
                          (car (split-string (substring value 8) "[/?#]")))))
      (cond ((string-match-p "[[:cntrl:]]" value) "a URL with a control character")
            ((not authority) "not an https URL")
            ((string-match-p "[[:space:]]" value) "a URL with a blank in it")
            ((or (string-empty-p authority) (string-prefix-p ":" authority)) "a URL with no host")
            ((string-match-p "[@\\]" authority) "a URL with a user name or a password")
            ((string-match-p "[?#]" value) "a URL with a query or fragment (credentials ride there)")))))

(defun drgnx-schema--number-problem (value min max integer)
  "Why VALUE is not a number (an integer when INTEGER) within MIN and MAX, or nil; MIN and MAX may be nil."
  (cond ((not (if integer (integerp value) (numberp value)))
         (drgnx-schema--expected (if integer "an integer" "a number") value))
        ((and (floatp value) (isnan value)) "not a number (NaN)")
        ((and min (< value min)) (format "below the minimum %s" min))
        ((and max (> value max)) (format "above the maximum %s" max))))

(defun drgnx-schema--check-atom (schema value rpath)
  "Check VALUE against the atom SCHEMA (a built-in or a named type); return a problem or nil."
  (let ((def (and schema (not (memq schema drgnx-schema--atoms)) (gethash schema drgnx-schema--types))))
    (if def
        (drgnx-schema--check (car def) value rpath)  ; a named type: its schema, where the name stands
      (let ((text (drgnx-schema--atom-problem schema value)))
        (and text (drgnx-schema--bad rpath text))))))

(defun drgnx-schema--atom-problem (schema value)
  "Why VALUE fails the built-in atom SCHEMA (text), or nil."
  (pcase schema
    ('any nil)
    ('symbol (unless (and value (symbolp value) (not (keywordp value)))
               (drgnx-schema--expected "a symbol" value)))
    ('keyword (unless (keywordp value) (drgnx-schema--expected "a keyword" value)))
    ('string (unless (stringp value) (drgnx-schema--expected "a string" value)))
    ('boolean (unless (memq value '(t nil)) (drgnx-schema--expected "t or nil" value)))
    ('null (when value (drgnx-schema--expected "nil" value)))
    ('integer (drgnx-schema--number-problem value nil nil t))
    ('natnum (drgnx-schema--number-problem value 0 nil t))
    ('number (drgnx-schema--number-problem value nil nil nil))
    ('home-path (drgnx-schema--home-path-problem value))
    ('https-url (drgnx-schema--https-url-problem value))
    (_ (drgnx-schema--unknown-form schema))))

;;;; Lists

(defun drgnx-schema--check-list-of (schema value rpath)
  "Check VALUE against `(list-of S [:max N])'."
  (let* ((elem (nth 1 schema))
         (max (plist-get (drgnx-schema--opts schema (cddr schema) '(:max)) :max))
         (n (proper-list-p value)))
    (cond ((not n) (drgnx-schema--bad rpath (drgnx-schema--expected "a list" value)))
          ((and max (> n max)) (drgnx-schema--bad rpath (format "more than %d elements" max)))
          (t (let ((i 0) (problem nil))
               (while (and value (not problem))
                 (setq problem (drgnx-schema--check elem (pop value) (cons i rpath))
                       i (1+ i)))
               problem)))))

(defun drgnx-schema--entry-rest (entry)
  "The options of a plist schema ENTRY `(KEY S [DOC] [:required t])' after its DOC."
  (let ((rest (cddr entry)))
    (if (stringp (car rest)) (cdr rest) rest)))

(defun drgnx-schema--check-plist (schema value rpath)
  "Check VALUE against `(plist (KEY S [DOC] [:required t])…)'."
  (let ((n (proper-list-p value)) (entries (cdr schema)))
    (cond ((not n) (drgnx-schema--bad rpath (drgnx-schema--expected "a plist" value)))
          ((cl-oddp n) (drgnx-schema--bad rpath "a plist with an odd number of elements"))
          (t
           (let ((seen nil) (rest value) (problem nil))
             (while (and rest (not problem))        ; the shape first: keywords, no key twice
               (let ((key (car rest)))
                 (cond ((not (keywordp key))
                        (setq problem (drgnx-schema--bad rpath "a plist key that is not a keyword")))
                       ((memq key seen)
                        (setq problem (drgnx-schema--bad (cons key rpath) "the key is given twice")))
                       (t (push key seen))))
               (setq rest (cddr rest)))
             (dolist (entry entries)                 ; then required keys, in schema order
               (when (and (not problem) (not (memq (car entry) seen))
                          (plist-get (drgnx-schema--entry-rest entry) :required))
                 (setq problem (drgnx-schema--bad (cons (car entry) rpath)
                                                  (format "missing required key %s" (car entry))))))
             (setq rest value)
             (while (and rest (not problem))         ; then each known key's value; unknown ones are not walked
               (let ((entry (assq (car rest) entries)))
                 (when entry
                   (setq problem (drgnx-schema--check (nth 1 entry) (cadr rest) (cons (car rest) rpath)))))
               (setq rest (cddr rest)))
             problem)))))

(defun drgnx-schema--check-pairs (value key-s val-s max strings-only rpath)
  "Check VALUE, a proper list of (KEY . VALUE) pairs with no key twice (`equal'), against KEY-S and VAL-S.
MAX bounds the pairs; STRINGS-ONLY requires string keys."
  (let ((n (proper-list-p value)))
    (cond ((not n) (drgnx-schema--bad rpath (drgnx-schema--expected "a list of pairs" value)))
          ((and max (> n max)) (drgnx-schema--bad rpath (format "more than %d entries" max)))
          (t (let ((seen (make-hash-table :test 'equal)) (problem nil))
               (while (and value (not problem))
                 (let* ((pair (pop value)) (key (car-safe pair)) (kpath (cons key rpath)))
                   (setq problem
                         (cond ((not (consp pair)) (drgnx-schema--bad rpath "expected a (KEY . VALUE) pair"))
                               ((and strings-only (not (stringp key)))
                                (drgnx-schema--bad kpath (drgnx-schema--expected "a string key" key)))
                               ((gethash key seen) (drgnx-schema--bad kpath "the key is given twice"))
                               (t (puthash key t seen)
                                  (or (drgnx-schema--check key-s key kpath)
                                      (drgnx-schema--check val-s (cdr pair) kpath)))))))
               problem)))))

(defun drgnx-schema--check-map (schema value rpath)
  "Check VALUE against `(map VAL-S [:max N] [:keys KEY-S])'.
VALUE is a keyword plist (how the hub decodes a JSON object) or an alist with string keys.  A key is
named without its colon, in the path and to KEY-S."
  (let* ((opts (drgnx-schema--opts schema (cddr schema) '(:max :keys)))
         (val-s (nth 1 schema)) (key-s (or (plist-get opts :keys) 'string)) (max (plist-get opts :max)))
    (if (not (keywordp (car-safe value)))
        (drgnx-schema--check-pairs value key-s val-s max t rpath)
      (let ((n (proper-list-p value)))
        (cond ((not n) (drgnx-schema--bad rpath (drgnx-schema--expected "an object" value)))
              ((cl-oddp n) (drgnx-schema--bad rpath "an object with a key but no value"))
              ((and max (> (/ n 2) max)) (drgnx-schema--bad rpath (format "more than %d entries" max)))
              (t (let ((seen nil) (problem nil))
                   (while (and value (not problem))
                     (let ((key (pop value)) (val (pop value)))
                       (if (not (keywordp key))
                           (setq problem (drgnx-schema--bad rpath "a key that is not a keyword"))
                         (let ((kpath (cons (substring (symbol-name key) 1) rpath)))
                           (setq problem (cond ((memq key seen) (drgnx-schema--bad kpath "the key is given twice"))
                                               (t (push key seen)
                                                  (or (drgnx-schema--check key-s (car kpath) kpath)
                                                      (drgnx-schema--check val-s val kpath)))))))))
                   problem)))))))

(defun drgnx-schema--check-form (schema value rpath)
  "Check VALUE against the list form SCHEMA; return a problem or nil."
  (pcase schema
    (`(,(and head (or 'integer 'number)) . ,opts)
     (let ((opts (drgnx-schema--opts schema opts '(:min :max))))
       (let ((text (drgnx-schema--number-problem value (plist-get opts :min) (plist-get opts :max) (eq head 'integer))))
         (and text (drgnx-schema--bad rpath text)))))
    (`(string . ,opts)
     (let* ((opts (drgnx-schema--opts schema opts '(:max :match)))
            (max (plist-get opts :max)) (re (plist-get opts :match))
            (text (cond ((not (stringp value)) (drgnx-schema--expected "a string" value))
                        ((and max (> (length value) max)) (format "longer than %d characters" max))
                        ((and re (not (let ((case-fold-search nil)) (string-match-p re value))))
                         (format "does not match %s" re)))))
       (and text (drgnx-schema--bad rpath text))))
    (`(enum . ,members)
     (unless (member value members)
       (drgnx-schema--bad rpath (format "not one of %s" (mapconcat (lambda (m) (format "%S" m)) members ", ")))))
    (`(or . ,alts)
     (let ((others (remq 'null alts)))
       (cond ((and (memq 'null alts) others (null (cdr others))) ; (or null S): a problem inside S keeps its own path
              (and value (drgnx-schema--check (car others) value rpath)))
             ((cl-some (lambda (alt) (null (drgnx-schema--check alt value rpath))) alts) nil)
             (t (drgnx-schema--bad rpath (format "expected %s, got %s" (drgnx-schema--text schema)
                                                 (drgnx-schema--what value)))))))
    (`(list-of ,_ . ,_) (drgnx-schema--check-list-of schema value rpath))
    (`(plist . ,_) (drgnx-schema--check-plist schema value rpath))
    (`(alist ,key-s ,val-s)
     (drgnx-schema--check-pairs value key-s val-s nil nil rpath))
    (`(map ,_ . ,_) (drgnx-schema--check-map schema value rpath))
    (`(pred ,fn ,doc)
     (if (not (and (symbolp fn) fn (fboundp fn)))
         (drgnx-schema--bad rpath (format "%s is not defined" fn))
       (condition-case err
           (unless (funcall fn value) (drgnx-schema--bad rpath doc))
         (error (drgnx-schema--bad rpath (format "%s (%s failed: %s)" doc fn (car err)))))))
    (_ (drgnx-schema--unknown-form schema))))

(defun drgnx-schema--check (schema value rpath)
  "Check VALUE against SCHEMA at the reversed path RPATH; a problem `(PATH . TEXT)' or nil."
  (cond ((symbolp schema) (drgnx-schema--check-atom schema value rpath))
        ((consp schema) (drgnx-schema--check-form schema value rpath))
        (t (drgnx-schema--unknown-form schema))))

(defun drgnx-schema-check (schema value)
  "Check VALUE against SCHEMA.  Nil, or `(PATH . TEXT)' for the first problem.
PATH lists the plist keys, alist keys and list indices from the top.  Signals `error' for a schema that is not
one (a definition's bug), never for a bad VALUE."
  (drgnx-schema--check schema value nil))

;;;; Reading a schema

(defun drgnx-schema--text (schema)
  "SCHEMA in a few words, for a problem and the reference."
  (cond ((symbolp schema) (symbol-name schema))
        ((not (consp schema)) (format "%S" schema))
        (t (pcase schema
             (`(enum . ,members) (concat "one of " (mapconcat (lambda (m) (format "%S" m)) members ", ")))
             (`(or . ,alts) (mapconcat #'drgnx-schema--text alts " or "))
             (`(list-of ,s . ,_) (concat "list of " (drgnx-schema--text s)))
             (`(alist ,k ,v) (format "alist of %s to %s" (drgnx-schema--text k) (drgnx-schema--text v)))
             (`(map ,v . ,_) (concat "map of " (drgnx-schema--text v)))
             (`(plist . ,_) "plist")
             (`(pred ,_ ,doc) doc)
             (`(,head . ,opts)
              (if opts
                  (format "%s (%s)" head
                          (string-join (cl-loop for (k v) on opts by #'cddr
                                                collect (format "%s %s" (substring (symbol-name k) 1) (format "%S" v)))
                                       ", "))
                (symbol-name head)))))))

(defun drgnx-schema--children (schema)
  "The schemas SCHEMA is built from (a named type's schema counts)."
  (pcase schema
    ((pred symbolp) (let ((def (and schema (gethash schema drgnx-schema--types)))) (and def (list (car def)))))
    (`(plist . ,entries) (mapcar #'cadr entries))
    (`(alist ,k ,v) (list k v))
    (`(map ,v . ,opts) (delq nil (list v (plist-get opts :keys))))
    (`(list-of ,s . ,_) (list s))
    (`(or . ,alts) alts)))

(defun drgnx-schema-uses-form-p (schema form)
  "Non-nil when SCHEMA contains the form FORM (an atom such as `any', or a head such as `list-of'), at any depth.
Looks through named types.  A literal in SCHEMA (an `enum' member, a doc) is not a form.  The hub uses it to refuse
a `:params' schema that holds `any'."
  (let ((visited nil))
    (cl-labels ((walk (s)
                  (cond ((or (eq s form) (eq (car-safe s) form)) t)
                        ((and (symbolp s) (memq s visited)) nil)
                        (t (when (symbolp s) (push s visited))
                           (cl-some #'walk (drgnx-schema--children s))))))
      (and (walk schema) t))))

(defun drgnx-schema--walk-unknown (schema value rpath)
  "Collect on `drgnx-schema--acc' the path of every unknown plist key in VALUE, which SCHEMA describes."
  (pcase schema
    ((pred symbolp)
     (let ((def (and schema (gethash schema drgnx-schema--types))))
       (when def (drgnx-schema--walk-unknown (car def) value rpath))))
    (`(plist . ,entries)
     (when (and (proper-list-p value) (cl-evenp (length value)))
       (while value
         (let* ((key (pop value)) (val (pop value)) (entry (and (keywordp key) (assq key entries))))
           (cond ((not (keywordp key)))
                 ((null entry) (push (reverse (cons key rpath)) drgnx-schema--acc))
                 (t (drgnx-schema--walk-unknown (nth 1 entry) val (cons key rpath))))))))
    ((or `(alist ,_ ,val-s) `(map ,val-s . ,_))
     (when (proper-list-p value)
       (if (keywordp (car value))              ; a map as the hub decodes it: a keyword plist
           (when (cl-evenp (length value))
             (while value
               (let ((key (pop value)))
                 (when (keywordp key)
                   (drgnx-schema--walk-unknown val-s (car value) (cons (substring (symbol-name key) 1) rpath))))
               (pop value)))
         (dolist (pair value)
           (when (consp pair)
             (drgnx-schema--walk-unknown val-s (cdr pair) (cons (car pair) rpath)))))))
    (`(list-of ,elem . ,_)
     (when (proper-list-p value)
       (let ((i 0))
         (dolist (v value)
           (drgnx-schema--walk-unknown elem v (cons i rpath))
           (setq i (1+ i))))))
    (`(or . ,alts)
     (let ((alt (cl-find-if (lambda (a) (null (drgnx-schema--check a value nil))) alts)))
       (when alt (drgnx-schema--walk-unknown alt value rpath))))))

(defun drgnx-schema-unknown-keys (schema value)
  "The PATH of every plist key in VALUE that the plists SCHEMA reaches do not name, in order.
A value under an unknown key is not walked.  VALUE need not pass the schema: a part that does not fit is skipped."
  (let ((drgnx-schema--acc nil))
    (drgnx-schema--walk-unknown schema value nil)
    (nreverse drgnx-schema--acc)))

(defun drgnx-schema--type-doc (schema)
  "The DOC of SCHEMA when it names a type, else nil."
  (and schema (symbolp schema) (cdr (gethash schema drgnx-schema--types))))

(defun drgnx-schema--walk-describe (schema rpath stack)
  "Collect on `drgnx-schema--acc' a row for every plist key SCHEMA reaches; STACK lists the types being entered."
  (pcase schema
    ((pred symbolp)
     (let ((def (and schema (not (memq schema stack)) (gethash schema drgnx-schema--types))))
       (when def (drgnx-schema--walk-describe (car def) rpath (cons schema stack)))))
    (`(plist . ,entries)
     (dolist (entry entries)
       (let* ((key (car entry)) (sub (nth 1 entry)) (path (cons key rpath)))
         (push (list (reverse path) (drgnx-schema--text sub)
                     (or (let ((rest (cddr entry))) (and (stringp (car rest)) (car rest)))
                         (drgnx-schema--type-doc sub))
                     (and (plist-get (drgnx-schema--entry-rest entry) :required) t))
               drgnx-schema--acc)
         (drgnx-schema--walk-describe sub path stack))))
    ((or `(alist ,_ ,sub) `(map ,sub . ,_) `(list-of ,sub . ,_))
     (drgnx-schema--walk-describe sub (cons '* rpath) stack))
    (`(or . ,alts)
     (dolist (alt alts) (drgnx-schema--walk-describe alt rpath stack)))))

(defun drgnx-schema-describe (schema)
  "Rows `(PATH TYPE-TEXT DOC REQUIRED)' for every plist key SCHEMA reaches, parents before children.
In PATH, `*' stands for any alist or map key and any list element.  DOC is the key's own, else its named type's."
  (let ((drgnx-schema--acc nil))
    (drgnx-schema--walk-describe schema nil nil)
    (nreverse drgnx-schema--acc)))

(provide 'drgnx-schema)
;;; drgnx-schema.el ends here
