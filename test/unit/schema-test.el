;;; schema-test.el --- batch tests: the schema DSL -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-schema)

(defmacro drgnx-schema-test--ok (schema &rest values)
  "Assert every one of VALUES passes SCHEMA."
  `(progn ,@(mapcar (lambda (v) `(should-not (drgnx-schema-check ,schema ,v))) values)))

(defmacro drgnx-schema-test--bad (schema &rest values)
  "Assert every one of VALUES fails SCHEMA with a (PATH . TEXT) problem."
  `(progn ,@(mapcar (lambda (v)
                      `(let ((p (drgnx-schema-check ,schema ,v)))
                         (should (consp p)) (should (listp (car p))) (should (stringp (cdr p)))))
                    values)))

;; Named types are made at load, so each test runs alone.
(drgnx-schema-deftype 'drgnx-schema-test-tree '(or null (plist (:kids (list-of drgnx-schema-test-tree)))) "A tree")
(drgnx-schema-deftype 'drgnx-schema-test-id '(string :max 4 :match "\\`[a-z]+\\'") "A short id")
(drgnx-schema-deftype 'drgnx-schema-test-d'(plist (:inner string "Inner doc")) "A named plist")
(drgnx-schema-deftype 'drgnx-schema-test-u '(list-of any) "Holds any")

(defun drgnx-schema-test--path (schema value)
  "The path of SCHEMA's first problem with VALUE."
  (car (drgnx-schema-check schema value)))

(ert-deftest drgnx-schema/atoms ()
  (drgnx-schema-test--ok 'any 1 nil "x" '(a . b))
  (drgnx-schema-test--ok 'symbol 'a t)
  (drgnx-schema-test--bad 'symbol nil :k "a" 1)
  (drgnx-schema-test--ok 'keyword :a)
  (drgnx-schema-test--bad 'keyword 'a nil "a")
  (drgnx-schema-test--ok 'string "" "a")
  (drgnx-schema-test--bad 'string 'a nil 1)
  (drgnx-schema-test--ok 'boolean t nil)
  (drgnx-schema-test--bad 'boolean 0 'yes "t")
  (drgnx-schema-test--ok 'null nil)
  (drgnx-schema-test--bad 'null t 0 "")
  (drgnx-schema-test--ok 'integer 0 -3 (expt 2 70))
  (drgnx-schema-test--bad 'integer 1.5 "1" nil)
  (drgnx-schema-test--ok 'natnum 0 7)
  (drgnx-schema-test--bad 'natnum -1 1.0 "1" nil)
  (drgnx-schema-test--ok 'number 0 -1 2.5)
  (drgnx-schema-test--bad 'number "1" nil 0.0e+NaN))

(ert-deftest drgnx-schema/integer-bounds ()
  (drgnx-schema-test--ok '(integer :min 1 :max 3) 1 3)
  (drgnx-schema-test--bad '(integer :min 1 :max 3) 0 4 1.5)
  (drgnx-schema-test--ok '(integer :min 1) 99)
  (drgnx-schema-test--bad '(integer :max 0) 1))

(ert-deftest drgnx-schema/number-bounds ()
  (drgnx-schema-test--ok '(number :min 0 :max 10.5) 0 0.25 10.5)
  (drgnx-schema-test--bad '(number :min 0 :max 10.5) -0.1 10.6 "1" 0.0e+NaN))

(ert-deftest drgnx-schema/string-max-and-match ()
  (drgnx-schema-test--ok '(string :max 3) "" "abc")
  (drgnx-schema-test--bad '(string :max 3) "abcd" 1)
  (drgnx-schema-test--ok '(string :match "\\`[a-z]+\\'") "abc")
  (drgnx-schema-test--bad '(string :match "\\`[a-z]+\\'") "ab1" "")
  (should (equal (drgnx-schema-test--path '(plist (:n (string :max 1))) '(:n "ab")) '(:n))))

(ert-deftest drgnx-schema/a-problem-never-echoes-the-value ()
  (should-not (string-match-p "hunter2" (cdr (drgnx-schema-check 'integer "hunter2"))))
  (should-not (string-match-p "hunter2" (cdr (drgnx-schema-check '(enum "a") "hunter2"))))
  (should-not (string-match-p "hunter2" (cdr (drgnx-schema-check 'home-path "hunter2")))))

(ert-deftest drgnx-schema/enum ()
  (drgnx-schema-test--ok '(enum snapshot worktree) 'snapshot 'worktree)
  (drgnx-schema-test--bad '(enum snapshot worktree) 'other "snapshot" nil)
  (drgnx-schema-test--ok '(enum "a" 1) "a" 1))

(ert-deftest drgnx-schema/or ()
  (drgnx-schema-test--ok '(or null string) nil "a")
  (drgnx-schema-test--bad '(or null string) 1 'a)
  (should (equal (drgnx-schema-test--path '(plist (:a (or null string))) '(:a 1)) '(:a)))
  ;; (or null S) reports the problem inside S, where it is; any other `or' reports its own path
  (should (equal (drgnx-schema-test--path '(or null (plist (:a integer))) '(:a "x")) '(:a)))
  (should (equal (drgnx-schema-test--path '(plist (:a (or string integer))) '(:a (:b 1))) '(:a))))

(ert-deftest drgnx-schema/list-of ()
  (drgnx-schema-test--ok '(list-of string) nil '("a" "b"))
  (drgnx-schema-test--bad '(list-of string) '("a" 1) "a" '(a . b))
  (should (equal (drgnx-schema-test--path '(list-of string) '("a" "b" 3)) '(2)))
  (drgnx-schema-test--ok '(list-of string :max 2) '("a" "b"))
  (drgnx-schema-test--bad '(list-of string :max 2) '("a" "b" "c")))

(ert-deftest drgnx-schema/plist ()
  (let ((s '(plist (:name string "The name" :required t) (:n integer) (:tags (list-of string)))))
    (drgnx-schema-test--ok s '(:name "a") '(:name "a" :n 1 :tags ("x")) '(:name "a" :unknown 1))
    (should (equal (drgnx-schema-test--path s '(:name "a" :n "1")) '(:n)))
    (should (equal (drgnx-schema-test--path s '(:name "a" :tags ("x" 2))) '(:tags 1)))
    (should (equal (drgnx-schema-test--path s '(:n 1)) '(:name)))
    (should (string-match-p ":name" (cdr (drgnx-schema-check s '(:n 1)))))
    (drgnx-schema-test--bad s "str" '(:name) '(1 2) '(:name "a" "b"))
    (drgnx-schema-test--ok '(plist (:a string)) nil)))

(ert-deftest drgnx-schema/a-duplicate-key-is-a-problem ()
  (let ((p (drgnx-schema-check '(plist (:a integer)) '(:a 1 :a 2))))
    (should (equal (car p) '(:a)))
    (should (string-match-p "twice\\|duplicate" (cdr p))))
  ;; an unknown key counts too
  (should (drgnx-schema-check '(plist (:a integer)) '(:x 1 :x 2)))
  (should (drgnx-schema-check '(alist string integer) '(("a" . 1) ("a" . 2)))))

(ert-deftest drgnx-schema/alist ()
  (let ((s '(alist string (plist (:command (list-of string))))))
    (drgnx-schema-test--ok s nil '(("local" :command ("x")) ("b")))
    (should (equal (drgnx-schema-test--path s '(("local" :command (1)))) '("local" :command 0)))
    (should (equal (drgnx-schema-test--path s '((a :command ("x")))) '(a)))
    (drgnx-schema-test--bad s '("local") 'x '(("a" . 1))))
  (drgnx-schema-test--ok '(alist string integer) '(("a" . 1) ("b" . 2)))
  (drgnx-schema-test--bad '(alist string integer) '(("a" . "x"))))

(ert-deftest drgnx-schema/map ()
  (drgnx-schema-test--ok '(map integer) nil '(("a" . 1) ("b" . 2)))
  (drgnx-schema-test--bad '(map integer) '((a . 1)) '(("a" . "x")) '(("a" . 1) ("a" . 2)))
  (should (equal (drgnx-schema-test--path '(map integer) '(("a" . 1) ("b" . x))) '("b")))
  (drgnx-schema-test--ok '(map integer :max 1) '(("a" . 1)))
  (drgnx-schema-test--bad '(map integer :max 1) '(("a" . 1) ("b" . 2)))
  (drgnx-schema-test--ok '(map integer :keys (string :match "\\`[a-z]+\\'")) '(("ab" . 1)))
  (drgnx-schema-test--bad '(map integer :keys (string :match "\\`[a-z]+\\'")) '(("A1" . 1))))

(ert-deftest drgnx-schema/map-takes-the-shape-the-hub-decodes ()
  ;; `json-parse-string :object-type plist' gives keyword keys; the path and :keys use the name without the colon
  (let ((keys (json-parse-string "{\"openrouter\":\"k1\",\"anthropic\":\"k2\"}" :object-type 'plist))
        (s '(map (string :max 8) :max 4 :keys (string :match "\\`[a-z]+\\'"))))
    (drgnx-schema-test--ok s keys nil '(:openrouter "k1"))
    (should (equal (drgnx-schema-test--path s '(:openrouter "k1" :anthropic 2)) '("anthropic")))
    (should (equal (drgnx-schema-test--path s '(:A1 "x")) '("A1")))
    (drgnx-schema-test--bad s '(:a "x" :a "y") '(:a) '("a" "b") '(:a "x" ("b" . "y")) '(("a" . "x") :b "y")
                            '(:a "1" :b "2" :c "3" :d "4" :e "5"))
    (drgnx-schema-test--bad '(map integer :max 1) '(:a 1 :b 2))
    ;; an unknown key's value is reached by the unknown-keys walk
    (should (equal (drgnx-schema-unknown-keys '(plist (:keys (map (plist (:id integer))))) '(:keys (:p (:id 1 :x 2))))
                   '((:keys "p" :x))))))

(ert-deftest drgnx-schema/home-path ()
  (drgnx-schema-test--ok 'home-path "/usr/bin" "~" "~/" "~/x/y" "/")
  (drgnx-schema-test--bad 'home-path "" "rel/x" "./x" "~user/x" "~x" "a\0b" "~/a\0b" 'a nil
                          "/ssh:host:/x" "/ssh:host|sudo:root@h:/x" "/scp:u@h:")
  (drgnx-schema-test--ok 'home-path "/tmp/a:b" "/usr/lib/x:y/z"))

(ert-deftest drgnx-schema/https-url ()
  (drgnx-schema-test--ok 'https-url "https://example.org" "https://example.org/a/b" "https://example.org:8443/x")
  (drgnx-schema-test--bad 'https-url "https://h/x?token=a" "https://h/x#f" "https://h?x" "https://h#f"
                          "http://example.org" "https://" "https:///x" "https://:80/x"
                          "https://user@example.org/" "https://u:p@example.org/" "ssh://h/x" "/x" ""
                          "https://example.org/\n" "https://exa mple.org" "https://example.org/\0" 'a nil))

(ert-deftest drgnx-schema/pred ()
  (let ((s '(pred stringp "a string")))
    (drgnx-schema-test--ok s "a")
    (should (equal (cdr (drgnx-schema-check s 1)) "a string")))
  (should (equal (drgnx-schema-test--path '(plist (:a (pred natnump "a count"))) '(:a -1)) '(:a))))

(ert-deftest drgnx-schema/an-unbound-pred-fails-closed ()
  (let ((p (drgnx-schema-check '(pred drgnx-schema-test--no-such-function "x") 1)))
    (should p)
    (should (string-match-p "drgnx-schema-test--no-such-function is not defined" (cdr p))))
  ;; a pred that signals fails too, and the error does not escape
  (should (drgnx-schema-check '(pred drgnx-schema-test--boom "x") 1)))

(defun drgnx-schema-test--boom (_value) "A pred that signals." (error "boom"))

(defun drgnx-schema-test--picky (_value) "A pred that explains itself." (user-error "the picky message"))

(ert-deftest drgnx-schema/a-pred-that-explains-itself-is-heard ()
  (let ((p (drgnx-schema-check '(pred drgnx-schema-test--picky "a fine value") 1)))
    (should (equal (cdr p) "a fine value: the picky message")))
  (should (string-search "boom" (cdr (drgnx-schema-check '(pred drgnx-schema-test--boom "x") 1)))))

(ert-deftest drgnx-schema/an-improper-list-is-a-problem-not-an-error ()
  (dolist (s '((plist (:a integer)) (alist string integer) (list-of integer) (map integer)))
    (should (consp (drgnx-schema-check s '(:a . 1))))
    (should (consp (drgnx-schema-check s 5)))
    (should (consp (drgnx-schema-check s '(("a" . 1) . 2)))))
  (let ((circular (list :a 1)))
    (setcdr (cdr circular) circular)
    (should (consp (drgnx-schema-check '(plist (:a integer)) circular)))
    (should (consp (drgnx-schema-check '(list-of any) circular)))))

(ert-deftest drgnx-schema/deftype-names-a-form ()
  (should (eq (drgnx-schema-deftype 'drgnx-schema-test-id '(string :max 4 :match "\\`[a-z]+\\'") "A short id")
              'drgnx-schema-test-id))
  (drgnx-schema-test--ok 'drgnx-schema-test-id "abcd")
  (drgnx-schema-test--bad 'drgnx-schema-test-id "abcde" "A1" 1)
  (should (equal (drgnx-schema-test--path '(plist (:id drgnx-schema-test-id)) '(:id "A")) '(:id)))
  (drgnx-schema-test--ok '(list-of drgnx-schema-test-id) '("a" "b"))
  ;; a type can be defined in terms of another, and a recursive one checks finite data
  (drgnx-schema-test--ok 'drgnx-schema-test-tree nil '(:kids ((:kids nil) (:kids ((:kids nil))))))
  (should (equal (drgnx-schema-test--path 'drgnx-schema-test-tree '(:kids ((:kids (1))))) '(:kids 0 :kids 0)))
  ;; a built-in name is not redefinable
  (should-error (drgnx-schema-deftype 'string 'integer "no"))
  (should-error (drgnx-schema-deftype 'plist 'integer "no")))

(ert-deftest drgnx-schema/an-unknown-form-is-an-error ()
  (should-error (drgnx-schema-check 'no-such-form 1) :type 'error)
  (should-error (drgnx-schema-check '(no-such-form 1) 1) :type 'error)
  (should-error (drgnx-schema-check "string" 1) :type 'error)
  (should-error (drgnx-schema-check '(integer :mn 1) 1) :type 'error)
  (should (string-match-p "drgnx-schema: unknown form"
                          (error-message-string (condition-case e (drgnx-schema-check 'no-such-form 1) (error e))))))

(ert-deftest drgnx-schema/an-unknown-form-is-an-error-when-defined ()
  (dolist (bad '((or string (bogus)) (plist (:a intgr)) (list-of nope) (alist string) (alist string integer integer)
                 (integer :mn 1) (integer :min "1") (string :max -1) (string :match 1) (list-of string :max x)
                 (map integer :keys bogus) (map) (enum) (or) (pred stringp) (pred "stringp" "d") (pred stringp 1)
                 (plist (a string)) (plist (:a)) (plist (:a string) (:a integer)) (plist (:a string :required))
                 (plist (:a string "d" :bogus t)) (plist ("a" string)) "string" 1 nil (symbol) (list-of)))
    (should (condition-case nil (progn (drgnx-schema-validate bad) nil) (error t))))
  (dolist (good '(any (or string (list-of integer)) (plist (:a string "doc" :required t) (:b (or null integer)))
                      (map integer :max 3 :keys (string :max 8)) (alist string (alist string any))
                      (enum a "b" 1) (pred stringp "a string") (integer :min 1 :max 2) (string :max 2 :match "x")
                      drgnx-schema-test-tree drgnx-schema-test-id))
    (should (eq (drgnx-schema-validate good) good)))
  (should (string-match-p "unknown form"
                          (error-message-string (condition-case e (drgnx-schema-validate '(or string (bogus))) (error e)))))
  ;; deftype validates, and a refused definition leaves nothing (or the old one) behind
  (should-error (drgnx-schema-deftype 'drgnx-schema-test-bad '(or string (bogus)) "x"))
  (should-error (drgnx-schema-check 'drgnx-schema-test-bad "x"))
  (should-error (drgnx-schema-deftype 'drgnx-schema-test-id '(plist (:a intgr)) "x"))
  (drgnx-schema-test--ok 'drgnx-schema-test-id "abcd")
  ;; a type naming an unbound type, or itself with no container in between, is refused
  (should-error (drgnx-schema-deftype 'drgnx-schema-test-b '(list-of drgnx-schema-test-unbound) "x"))
  (should-error (drgnx-schema-deftype 'drgnx-schema-test-c '(or drgnx-schema-test-c string) "x"))
  (drgnx-schema-deftype 'drgnx-schema-test-e '(or null string) "x")
  (should-error (drgnx-schema-deftype 'drgnx-schema-test-f '(or drgnx-schema-test-e drgnx-schema-test-f) "x"))
  (should-not (gethash 'drgnx-schema-test-f drgnx-schema--types))
  (should (drgnx-schema-deftype 'drgnx-schema-test-g '(plist (:kids (list-of drgnx-schema-test-g))) "x")))

(ert-deftest drgnx-schema/unknown-keys-pass-and-are-listed ()
  (let ((s '(plist (:a integer)
                   (:profiles (alist string (plist (:command (list-of string)))))
                   (:rows (list-of (plist (:id integer)))))))
    (should-not (drgnx-schema-check s '(:a 1 :zz 2 :profiles (("p" :command ("x") :extra 1)) :rows ((:id 1 :more 2)))))
    (should (equal (sort (mapcar #'prin1-to-string
                                 (drgnx-schema-unknown-keys s '(:a 1 :zz 2 :profiles (("p" :command ("x") :extra 1)) :rows ((:id 1 :more 2)))))
                         #'string<)
                   (sort (mapcar #'prin1-to-string '((:zz) (:profiles "p" :extra) (:rows 0 :more))) #'string<)))
    (should-not (drgnx-schema-unknown-keys s '(:a 1)))
    (should-not (drgnx-schema-unknown-keys s nil))
    ;; the first alternative of an `or' that fits is the one walked
    (should (equal (drgnx-schema-unknown-keys '(or null (plist (:a integer))) '(:a 1 :b 2)) '((:b))))))

(ert-deftest drgnx-schema/a-value-under-an-unknown-key-is-not-walked ()
  (let ((bad (list :x 1 :y)))               ; odd plist, improper tail below
    (should-not (drgnx-schema-check '(plist (:a integer)) (list :a 1 :unk bad :unk2 '(1 . 2))))
    (should (equal (drgnx-schema-unknown-keys '(plist (:a integer)) (list :a 1 :unk bad :unk2 '(1 . 2)))
                   '((:unk) (:unk2))))))

(ert-deftest drgnx-schema/describe-lists-every-key ()
  (let ((rows (drgnx-schema-describe
               '(plist (:name string "The name" :required t)
                       (:profiles (alist string (plist (:command (list-of string) "Argv")))
                                  "Profiles")
                       (:named drgnx-schema-test-d)
                       (:n (integer :min 0))))))
    (should (equal (mapcar #'car rows)
                   '((:name) (:profiles) (:profiles * :command) (:named) (:named :inner) (:n))))
    (let ((row (assoc '(:name) rows)))
      (should (equal (nth 2 row) "The name"))
      (should (nth 3 row))
      (should (stringp (nth 1 row))))
    (should-not (nth 3 (assoc '(:n) rows)))
    (should (equal (nth 2 (assoc '(:named) rows)) "A named plist"))
    (should (string-match-p "string" (nth 1 (assoc '(:profiles * :command) rows)))))
  ;; a recursive type is described once, not forever
  (should (drgnx-schema-describe 'drgnx-schema-test-tree)))

(ert-deftest drgnx-schema/uses-form-p-finds-a-form-through-types ()
  (should (drgnx-schema-uses-form-p '(plist (:a (list-of any))) 'any))
  (should-not (drgnx-schema-uses-form-p '(plist (:a (enum any)) (:b string)) 'any))
  (should (drgnx-schema-uses-form-p '(plist (:a drgnx-schema-test-u)) 'any))
  (should (drgnx-schema-uses-form-p '(map (list-of integer)) 'list-of))
  (should-not (drgnx-schema-uses-form-p 'drgnx-schema-test-tree 'any)))

(provide 'schema-test)
;;; schema-test.el ends here
