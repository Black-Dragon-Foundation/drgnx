;;; config-test.el --- batch tests: config files — definitions, the fallback, versions, the surgical writer -*- lexical-binding: t -*-
;; Every test runs under `drgnx-test-with-config': drgnx's config and state folders under a fresh temp root.
;; The hub test compiles the hub's four files into a temp folder and loads them in a child `emacs --batch -Q',
;; waited for under a 30 s bound.
(require 'ert)
(require 'bytecomp)                                  ; `byte-compile-warnings' is let-bound below
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-registry)
(require 'drgnx-modules)
(require 'drgnx-modules-fingerprint)

(defconst drgnx-config-test--schema
  '(plist (:a integer "A number") (:b string "A string") (:c (list-of symbol) "Some symbols"))
  "The schema of the test file.")

(defun drgnx-config-test--define (&rest args)
  "Define the plist file `drgnx-config-test' (t.eld); ARGS come first, so they win."
  (apply #'drgnx-config-define 'drgnx-config-test
         (append args (list :file "t.eld" :schema drgnx-config-test--schema :default '(:a 1 :b "x")
                            :doc "A test file."))))

(defun drgnx-config-test--rename-old (data)
  "Format 1 → 2 of the test file: :old is called :a."
  (let ((out nil))
    (while data
      (let ((k (pop data)) (v (pop data)))
        (push (if (eq k :old) :a k) out)
        (push v out)))
    (nreverse out)))

(defun drgnx-config-test--file () (drgnx-config-file 'drgnx-config-test))

(defun drgnx-config-test--good-copy ()
  (expand-file-name "drgnx/config-good/drgnx-config-test.eld" (concat drgnx-test-config-root "state")))

(defun drgnx-config-test--backups ()
  (directory-files (file-name-directory (drgnx-config-test--file)) nil "\\`t\\.eld\\.bak-"))

(defmacro drgnx-config-test--messages (&rest body)
  "BODY run; what it told the user, oldest first: each message, and the text of each `drgnx-notify' call.
A file's mistake is a notice (`drgnx-config--notify'): `drgnx-modules', required above, loads the notice model."
  (declare (indent 0))
  `(let ((said nil))
     (cl-letf (((symbol-function 'message)
                (lambda (fmt &rest args) (when fmt (push (apply #'format-message fmt args) said))))
               ((symbol-function 'drgnx-notify)
                (lambda (_source _severity text &rest _) (push text said))))
       ,@body)
     (nreverse said)))

(defmacro drgnx-config-test--with-modules (&rest body)
  "BODY with fresh module tables, as the module tests make them."
  (declare (indent 0))
  `(let ((drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
         (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
         (drgnx-module--claims (make-hash-table :test 'equal))
         (drgnx-module--releasers (make-hash-table :test 'equal)))
     ,@body))

(defun drgnx-config-test--run-module (name setup)
  "Define module NAME with SETUP and run it as its stage would (through `drgnx-modules--run-setup')."
  (drgnx-module-define name :doc "a test module" :setup setup)
  (drgnx-modules--run-one name (alist-get name drgnx-modules--table) 'startup)
  (should (eq (plist-get (alist-get name drgnx-modules--report) :status) 'ok)))

;;;; Definitions

(ert-deftest drgnx-config/define-checks-its-arguments ()
  (drgnx-test-with-config
    (should-error (drgnx-config-test--define :dir 'home))
    (should-error (drgnx-config-test--define :shape 'vector))
    (should-error (drgnx-config-test--define :reload 'never))
    (should-error (drgnx-config-test--define :schema '(alist string integer)))   ; a plist file
    (should-error (drgnx-config-test--define :schema '(plist (:a intgr))))        ; validated when defined
    (should-error (drgnx-config-test--define :migrate '((x . ignore))))
    (should-error (drgnx-config-test--define :migrate '((1 . 2))))
    (should-error (drgnx-config-test--define :migrate 'ignore))
    (should-not (gethash 'drgnx-config-test drgnx-config--defs))
    (should (eq (drgnx-config-test--define) 'drgnx-config-test))
    (let ((def (gethash 'drgnx-config-test drgnx-config--defs)))
      (should (eq (plist-get def :dir) 'config))
      (should (eq (plist-get def :shape) 'plist))
      (should (eq (plist-get def :version) 1))
      (should (eq (plist-get def :reload) 'mtime))
      (should (eq (plist-get def :last-good) t))
      (should (eql (plist-get def :max-bytes) 1048576))
      (should (equal (plist-get def :header) ";; drgnx: t.eld (docs/reference/config.md)\n")))
    (drgnx-config-define 'drgnx-config-test-p :file "p.eld" :dir 'project :schema drgnx-config-test--schema)
    (let ((def (gethash 'drgnx-config-test-p drgnx-config--defs)))
      (should-not (plist-get def :last-good))
      (should (eql (plist-get def :max-bytes) 65536)))
    (should (eq (drgnx-config-undefine 'drgnx-config-test-p) 'drgnx-config-test-p))
    (should-not (gethash 'drgnx-config-test-p drgnx-config--defs))))

(ert-deftest drgnx-config/define-in-a-setup-pushes-its-undo ()
  (drgnx-test-with-config
    (drgnx-config-test--with-modules
      (drgnx-config-test--run-module 'test/cfg (lambda () (drgnx-config-test--define)))
      (should (gethash 'drgnx-config-test drgnx-config--defs))
      (should (member "config drgnx-config-test" (mapcar #'car (alist-get 'test/cfg drgnx-modules--stacks))))
      (drgnx-test-config-put 'drgnx-config-test "(:a 5)")
      (should (eql (drgnx-config-get 'drgnx-config-test :a) 5))
      (should-not (drgnx-module-teardown 'test/cfg))
      (should-not (gethash 'drgnx-config-test drgnx-config--defs))
      (should-not (gethash 'drgnx-config-test drgnx-config--state))          ; its cached state goes too
      ;; A name defined before the setup gets its previous definition back.
      (drgnx-config-test--define :doc "before")
      (drgnx-config-test--run-module 'test/cfg2 (lambda () (drgnx-config-test--define :doc "in the setup")))
      (should (equal (plist-get (gethash 'drgnx-config-test drgnx-config--defs) :doc) "in the setup"))
      (drgnx-module-teardown 'test/cfg2)
      (should (equal (plist-get (gethash 'drgnx-config-test drgnx-config--defs) :doc) "before")))))

(ert-deftest drgnx-config/an-undo-leaves-a-redefinition-alone ()
  (drgnx-test-with-config
    (drgnx-config-test--with-modules
      (drgnx-config-test--run-module 'test/cfg (lambda () (drgnx-config-test--define :doc "the module's")))
      (drgnx-config-test--define :doc "redefined after")
      (drgnx-test-config-put 'drgnx-config-test "(:a 5)")
      (should (eql (drgnx-config-get 'drgnx-config-test :a) 5))
      (drgnx-module-teardown 'test/cfg)
      (should (equal (plist-get (gethash 'drgnx-config-test drgnx-config--defs) :doc) "redefined after"))
      (should (gethash 'drgnx-config-test drgnx-config--state)))))

(ert-deftest drgnx-config/config-definitions-are-in-the-census ()
  (drgnx-test-with-config
    (should (memq 'drgnx-config--defs drgnx-modules-fingerprint-registries))
    (let ((key '(registry drgnx-config--defs drgnx-config-test)))
      (should-not (assoc key (plist-get (drgnx-modules-fingerprint) :registries)))
      (drgnx-config-test--define)
      (should (assoc key (plist-get (drgnx-modules-fingerprint) :registries))))))

;;;; Reading and getting

(ert-deftest drgnx-config/absent-gives-the-default ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (should (equal (drgnx-config-get 'drgnx-config-test) '(:a 1 :b "x")))
    (should (eq (plist-get (drgnx-config-read 'drgnx-config-test) :status) 'absent))
    (drgnx-test-config-put 'drgnx-config-test ";; only a comment\n")
    (should (equal (drgnx-config-get 'drgnx-config-test) '(:a 1 :b "x")))
    (should-not (file-exists-p (drgnx-config-test--good-copy)))))

(ert-deftest drgnx-config/absent-key-gives-the-default-key ()
  (drgnx-test-with-config
    (drgnx-config-test--define :default '(:a 1 :b "x" :c (d)))
    (drgnx-test-config-put 'drgnx-config-test "(:a 5)")
    (should (eql (drgnx-config-get 'drgnx-config-test :a) 5))
    (should (equal (drgnx-config-get 'drgnx-config-test :b) "x"))
    (should (equal (drgnx-config-get 'drgnx-config-test :c) '(d)))
    (drgnx-test-config-put 'drgnx-config-test "(:a 5 :c nil)")         ; present but nil: not the default
    (should-not (drgnx-config-get 'drgnx-config-test :c))
    (drgnx-config-define 'drgnx-config-test-al :file "al.eld" :shape 'alist :schema '(alist string integer)
                         :default '(("k" . 1)))
    (drgnx-test-config-put 'drgnx-config-test-al "((\"j\" . 2))")
    (should (eql (drgnx-config-get 'drgnx-config-test-al "j") 2))
    (should (eql (drgnx-config-get 'drgnx-config-test-al "k") 1))
    (should (equal (plist-get (drgnx-config-read 'drgnx-config-test-al) :version) 1))))

(ert-deftest drgnx-config/a-mistake-uses-the-last-good-copy ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test ";; mine\n(:a 2)\n")
    (should (equal (drgnx-config-get 'drgnx-config-test) '(:a 2)))
    (should (file-exists-p (drgnx-config-test--good-copy)))
    (drgnx-config-test--messages
      (drgnx-test-config-put 'drgnx-config-test "(:a \"oops\")")
      (should (equal (drgnx-config-get 'drgnx-config-test) '(:a 2)))
      (let ((p (drgnx-config-problem 'drgnx-config-test)))
        (should (string-prefix-p ":a: expected an integer" (plist-get p :text)))
        (should (eql (plist-get p :line) 1))
        (should (equal (plist-get p :file) (drgnx-config-test--file))))
      (drgnx-test-config-put 'drgnx-config-test "(:a 3")                 ; cut short
      (should (equal (drgnx-config-get 'drgnx-config-test) '(:a 2)))
      (should (eq (plist-get (drgnx-config-read 'drgnx-config-test) :status) 'problem)))))

(ert-deftest drgnx-config/a-mistake-without-a-copy-uses-the-default ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-config-test--messages
      (drgnx-test-config-put 'drgnx-config-test "(:a \"oops\")")
      (should (equal (drgnx-config-get 'drgnx-config-test) '(:a 1 :b "x"))))))

(ert-deftest drgnx-config/last-good-nil-uses-the-default-even-with-a-copy ()
  (drgnx-test-with-config
    (drgnx-config-test--define :last-good nil)
    (drgnx-test-config-put 'drgnx-config-test "(:a 2)")
    (should (eql (drgnx-config-get 'drgnx-config-test :a) 2))
    (should-not (file-exists-p (drgnx-config-test--good-copy)))          ; none is kept
    (make-directory (file-name-directory (drgnx-config-test--good-copy)) t)
    (with-temp-file (drgnx-config-test--good-copy) (insert "(:a 9)"))
    (drgnx-config-test--messages
      (drgnx-test-config-put 'drgnx-config-test "(:a \"oops\")")
      (should (equal (drgnx-config-get 'drgnx-config-test) '(:a 1 :b "x"))))))

(ert-deftest drgnx-config/one-problem-and-one-message-per-mistake ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (let ((said (drgnx-config-test--messages
                  (drgnx-test-config-put 'drgnx-config-test "(:a \"oops\")")
                  (drgnx-config-get 'drgnx-config-test)
                  (drgnx-config-get 'drgnx-config-test :a)
                  (drgnx-config-reread 'drgnx-config-test)
                  (drgnx-test-config-put 'drgnx-config-test "(:a \"oops\")  ")   ; the same mistake, a new stamp
                  (drgnx-config-get 'drgnx-config-test))))
      (should (equal said (list (format "%s: :a: expected an integer, got string (line 1) — using the defaults"
                                        (abbreviate-file-name (drgnx-config-test--file)))))))
    (should (equal (mapcar (lambda (p) (plist-get p :name)) (drgnx-config-problems)) '(drgnx-config-test)))
    (should (= 1 (length (drgnx-config-test--messages
                           (drgnx-test-config-put 'drgnx-config-test "(:a 1 :b 2)")   ; another mistake
                           (drgnx-config-get 'drgnx-config-test)))))
    (drgnx-test-config-put 'drgnx-config-test "(:a 2)")                   ; fixed
    (drgnx-config-get 'drgnx-config-test)
    (should-not (drgnx-config-problems))
    (should-not (drgnx-config-problem 'drgnx-config-test))))

(ert-deftest drgnx-config/on-mistake-says-what-happens-instead ()
  (drgnx-test-with-config
    ;; :on-mistake replaces "using the defaults" in the notice
    (drgnx-config-test--define :on-mistake "drgnx sync stops until it is fixed")
    (let ((said (drgnx-config-test--messages
                  (drgnx-test-config-put 'drgnx-config-test "(:a \"oops\")")
                  (drgnx-config-get 'drgnx-config-test))))
      (should (= 1 (length said)))
      (should (string-suffix-p "(line 1) — drgnx sync stops until it is fixed" (car said))))
    ;; a project file with no :on-mistake says the file is refused
    (drgnx-config-define 'drgnx-config-test-p :file "p.eld" :dir 'project :schema drgnx-config-test--schema)
    (let ((said (drgnx-config-test--messages
                  (drgnx-test-config-put 'drgnx-config-test-p "(:a \"oops\")" drgnx-test-config-root)
                  (drgnx-config-get 'drgnx-config-test-p nil drgnx-test-config-root))))
      (should (= 1 (length said)))
      (should (string-suffix-p "(line 1) — the file is refused" (car said))))
    (should-error (drgnx-config-test--define :on-mistake 5))))

(ert-deftest drgnx-config/mtime-get-is-one-stat ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test "(:a 2)")
    (drgnx-config-get 'drgnx-config-test :a)
    (let* ((n 0) (count (lambda (&rest _) (setq n (1+ n)))))
      (advice-add 'file-attributes :before count)
      (unwind-protect (should (eql (drgnx-config-get 'drgnx-config-test :a) 2))
        (advice-remove 'file-attributes count))
      (should (= n 1)))))

(ert-deftest drgnx-config/an-unchanged-get-allocates-only-the-stat ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test "(:a 2)")
    ;; interpreted code conses for its own bookkeeping, and the runner loads a file's source when it is newer than its
    ;; .elc: measure the get and everything it calls compiled
    (dolist (fn '(drgnx-config-get drgnx-config--current drgnx-config--def drgnx-config--path drgnx-config--key
                                   drgnx-config--same-stamp-p drgnx-config--lookup drgnx-user-dir drgnx-paths--expand
                                   drgnx-paths-dir drgnx-paths-env-dir drgnx-paths-config-moved-p))
      (unless (byte-code-function-p (symbol-function fn)) (byte-compile fn)))
    (let* ((file (drgnx-config-test--file))
           (measure (byte-compile (lambda (fn) (let ((before (car (memory-use-counts))))
                                                 (funcall fn)
                                                 (- (car (memory-use-counts)) before)))))
           (stat (byte-compile `(lambda () (file-attributes ,file))))
           (get (byte-compile (lambda () (drgnx-config-get 'drgnx-config-test :a)))))
      (funcall get) (funcall stat)
      (let ((stat-conses (funcall measure stat))
            (get-conses (funcall measure get)))
        (should (<= get-conses (+ stat-conses 4)))))))

(ert-deftest drgnx-config/start-reads-once-until-reread ()
  (drgnx-test-with-config
    (drgnx-config-test--define :reload 'start)
    (drgnx-test-config-put 'drgnx-config-test "(:a 2)")
    (should (eql (drgnx-config-get 'drgnx-config-test :a) 2))
    (drgnx-test-config-put 'drgnx-config-test "(:a 3)")
    (should (eql (drgnx-config-get 'drgnx-config-test :a) 2))
    (should (eql (plist-get (drgnx-config-reread 'drgnx-config-test) :a) 3))
    (should (eql (drgnx-config-get 'drgnx-config-test :a) 3))))

(ert-deftest drgnx-config/changed-functions-run-on-a-new-stamp ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (let ((seen nil))
      (add-hook 'drgnx-config-changed-functions (lambda (name) (push (list name inhibit-interaction) seen)))
      (add-hook 'drgnx-config-changed-functions (lambda (_) (error "A broken listener")))
      (drgnx-test-config-put 'drgnx-config-test "(:a 2)")
      (drgnx-config-get 'drgnx-config-test)
      (should-not seen)                                                  ; the first read is no change
      (drgnx-test-config-put 'drgnx-config-test "(:a 3)")
      (let ((said (drgnx-config-test--messages (should (eql (drgnx-config-get 'drgnx-config-test :a) 3)))))
        (should (= 1 (length said))))                                    ; the broken listener: one message
      (should (equal seen '((drgnx-config-test t))))
      (drgnx-test-config-put 'drgnx-config-test "(:a 3) ; the same value\n")
      (drgnx-config-get 'drgnx-config-test)
      (should (= 1 (length seen))))))

(ert-deftest drgnx-config/a-newer-file-is-applied-read-only ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test "(:version 2 :a 7 :new-key t)\n")
    (should (eql (drgnx-config-get 'drgnx-config-test :a) 7))
    (let ((r (drgnx-config-read 'drgnx-config-test)))
      (should (eq (plist-get r :status) 'newer))
      (should (eql (plist-get r :version) 2))
      (should (equal (plist-get r :unknown-keys) '((:new-key)))))
    (should-error (drgnx-config-set 'drgnx-config-test :a 8) :type 'drgnx-config-refused)
    (should (equal (drgnx-test-config-text 'drgnx-config-test) "(:version 2 :a 7 :new-key t)\n"))))

(ert-deftest drgnx-config/a-newer-file-that-fails-falls-back ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-config-test--messages
      (drgnx-test-config-put 'drgnx-config-test "(:version 2 :a \"str\")")
      (should (equal (drgnx-config-get 'drgnx-config-test) '(:a 1 :b "x")))
      (should (eq (plist-get (drgnx-config-read 'drgnx-config-test) :status) 'problem)))))

(ert-deftest drgnx-config/an-older-file-is-migrated-in-memory-only ()
  (drgnx-test-with-config
    (drgnx-config-test--define :version 2 :migrate '((1 . drgnx-config-test--rename-old)))
    (drgnx-test-config-put 'drgnx-config-test ";; mine\n(:old 4 :b \"y\")\n")
    (should (eql (drgnx-config-get 'drgnx-config-test :a) 4))
    (should (equal (drgnx-config-get 'drgnx-config-test) '(:version 2 :a 4 :b "y")))
    (let ((r (drgnx-config-read 'drgnx-config-test)))
      (should (eq (plist-get r :status) 'migrated))
      (should (eql (plist-get r :version) 1)))
    (should (equal (drgnx-test-config-text 'drgnx-config-test) ";; mine\n(:old 4 :b \"y\")\n"))
    (should-not (drgnx-config-test--backups))
    ;; a format with no step up is a problem
    (drgnx-config-test--define :version 3 :migrate '((1 . drgnx-config-test--rename-old)))
    (drgnx-config-test--messages
      (should (equal (drgnx-config-get 'drgnx-config-test) '(:a 1 :b "x"))))
    (should (equal (plist-get (drgnx-config-problem 'drgnx-config-test) :text) "no migration from format 2"))))

(ert-deftest drgnx-config/format-0-needs-a-0-migration ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test "(foo bar)")
    (drgnx-config-test--messages (drgnx-config-get 'drgnx-config-test))
    (should (equal (plist-get (drgnx-config-problem 'drgnx-config-test) :text) "no migration from format 0"))
    (drgnx-config-test--define :migrate (list (cons 0 (lambda (l) (list :c l)))))
    (should (equal (drgnx-config-get 'drgnx-config-test :c) '(foo bar)))
    (should (eq (plist-get (drgnx-config-read 'drgnx-config-test) :status) 'migrated))
    (should (eql (plist-get (drgnx-config-read 'drgnx-config-test) :version) 0))))

;;;; Writers

(ert-deftest drgnx-config/writers-refuse-a-file-with-a-problem ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-config-test--messages
      (dolist (text '("(:a 1 ;; c\n :b" "(:a \"x\")\n"))
        (drgnx-test-config-put 'drgnx-config-test text)
        (let ((err (should-error (drgnx-config-set 'drgnx-config-test :a 2) :type 'drgnx-config-refused)))
          (should (string-match-p "has a mistake at line [0-9]+: .* — fix it (Preferences: Open Config File…) or reset it; it was not changed"
                                  (cadr err))))
        (should-error (drgnx-config-unset 'drgnx-config-test :a) :type 'drgnx-config-refused)
        (should-error (drgnx-config-update 'drgnx-config-test #'identity) :type 'drgnx-config-refused)
        (should (equal (drgnx-test-config-text 'drgnx-config-test) text))
        (should-not (drgnx-config-test--backups))))))

(ert-deftest drgnx-config/writers-refuse-a-newer-file ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (let ((text ";; from a newer drgnx\n(:version 2 :a 7)\n"))
      (drgnx-test-config-put 'drgnx-config-test text)
      (let ((err (should-error (drgnx-config-set 'drgnx-config-test :a 8) :type 'drgnx-config-refused)))
        (should (string-match-p "was written by a newer drgnx (format 2; this one writes 1): update drgnx here; it was not changed"
                                (cadr err))))
      (should-error (drgnx-config-unset 'drgnx-config-test :a) :type 'drgnx-config-refused)
      (should-error (drgnx-config-update 'drgnx-config-test #'identity) :type 'drgnx-config-refused)
      (should (equal (drgnx-test-config-text 'drgnx-config-test) text)))))

(ert-deftest drgnx-config/ensure-writable-refuses-before-anything-changes ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (should-not (drgnx-config-ensure-writable 'drgnx-config-test))          ; absent: fine
    (drgnx-test-config-put 'drgnx-config-test "(:a 1)\n")
    (should-not (drgnx-config-ensure-writable 'drgnx-config-test))
    (drgnx-config-test--messages
      (dolist (text '("(:a 1 ;; c\n :b" "(:a \"x\")\n" ";; newer\n(:version 2 :a 7)\n"))
        (drgnx-test-config-put 'drgnx-config-test text)
        (should-error (drgnx-config-ensure-writable 'drgnx-config-test) :type 'drgnx-config-refused)
        (should (equal (drgnx-test-config-text 'drgnx-config-test) text))
        (should-not (drgnx-config-test--backups))))
    (should-error (drgnx-config-ensure-writable 'drgnx-config-no-such-file) :type 'error)))

(ert-deftest drgnx-config/names-and-definitions-are-public ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-config-define 'drgnx-config-test-z :file "zz.eld" :dir 'project :schema '(plist (:c boolean "A flag"))
                         :doc "A project file.")
    (should (drgnx-config-defined-p 'drgnx-config-test))
    (should-not (drgnx-config-defined-p 'drgnx-config-no-such-file))
    (should (equal (plist-get (drgnx-config-definition 'drgnx-config-test) :file) "t.eld"))
    (should-not (drgnx-config-definition 'drgnx-config-no-such-file))
    (let ((all (drgnx-config-names)))
      (should (memq 'drgnx-config-test all))
      (should (memq 'drgnx-config-test-z all))
      (should (equal all (sort (copy-sequence all) (lambda (a b) (string< (symbol-name a) (symbol-name b)))))))
    (should (memq 'drgnx-config-test (drgnx-config-names '(config state))))
    (should-not (memq 'drgnx-config-test-z (drgnx-config-names '(config state))))
    (should (equal (cl-remove-if-not (lambda (n) (string-prefix-p "drgnx-config-test" (symbol-name n)))
                                     (drgnx-config-names 'project))
                   '(drgnx-config-test-z)))))

(defconst drgnx-config-test--commented
  ";; my config\n(:a 1 ; the a\n :zz (keep me \"exactly\")   ;; unknown\n ;; about b\n :b \"x\")\n"
  "A file with comments and an unknown key.")

(ert-deftest drgnx-config/set-keeps-comments-and-unknown-keys-byte-for-byte ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test drgnx-config-test--commented)
    (should (equal (drgnx-config-set 'drgnx-config-test :a 2) '(:a 2 :zz (keep me "exactly") :b "x")))
    (should (equal (drgnx-test-config-text 'drgnx-config-test)
                   ";; my config\n(:a 2 ; the a\n :zz (keep me \"exactly\")   ;; unknown\n ;; about b\n :b \"x\")\n"))
    (drgnx-config-set 'drgnx-config-test :b "y")
    (should (equal (drgnx-test-config-text 'drgnx-config-test)
                   ";; my config\n(:a 2 ; the a\n :zz (keep me \"exactly\")   ;; unknown\n ;; about b\n :b \"y\")\n"))
    (should (equal (drgnx-config-get 'drgnx-config-test :b) "y"))
    (should (equal (plist-get (drgnx-config-read 'drgnx-config-test) :unknown-keys) '((:zz))))))

(ert-deftest drgnx-config/set-adds-a-key-where-new-has-it ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test drgnx-config-test--commented)
    (drgnx-config-set 'drgnx-config-test :c '(p q))                     ; at the end, as `plist-put' adds it
    (should (equal (drgnx-test-config-text 'drgnx-config-test)
                   ";; my config\n(:a 1 ; the a\n :zz (keep me \"exactly\")   ;; unknown\n ;; about b\n :b \"x\"\n :c (p q))\n"))
    (drgnx-test-config-put 'drgnx-config-test drgnx-config-test--commented)
    (drgnx-config-update 'drgnx-config-test (lambda (d) (append (list :a 1 :c '(p)) (cddr d))))   ; after :a and its comment
    (should (equal (drgnx-test-config-text 'drgnx-config-test)
                   ";; my config\n(:a 1 ; the a\n :c (p)\n :zz (keep me \"exactly\")   ;; unknown\n ;; about b\n :b \"x\")\n"))
    (drgnx-test-config-put 'drgnx-config-test drgnx-config-test--commented)
    (drgnx-config-update 'drgnx-config-test (lambda (d) (append (list :c '(p)) d)))                 ; first
    (should (equal (drgnx-test-config-text 'drgnx-config-test)
                   ";; my config\n(:c (p)\n :a 1 ; the a\n :zz (keep me \"exactly\")   ;; unknown\n ;; about b\n :b \"x\")\n"))))

(ert-deftest drgnx-config/unset-removes-a-key-and-its-line ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test "(:a 1\n :b \"x\"\n :c (p))\n")
    (should (equal (drgnx-config-unset 'drgnx-config-test :b) '(:a 1 :c (p))))
    (should (equal (drgnx-test-config-text 'drgnx-config-test) "(:a 1\n :c (p))\n"))
    (drgnx-test-config-put 'drgnx-config-test "(:a 1\n :b \"x\"\n :c (p))\n")
    (drgnx-config-unset 'drgnx-config-test :c)                            ; the last one
    (should (equal (drgnx-test-config-text 'drgnx-config-test) "(:a 1\n :b \"x\")\n"))
    (drgnx-test-config-put 'drgnx-config-test "(:a 1\n :b \"x\"\n :c (p))\n")
    (drgnx-config-update 'drgnx-config-test (lambda (_) (list :a 1)))     ; the last two
    (should (equal (drgnx-test-config-text 'drgnx-config-test) "(:a 1)\n"))
    (drgnx-test-config-put 'drgnx-config-test drgnx-config-test--commented)
    (drgnx-config-unset 'drgnx-config-test :zz)                           ; its trailing comment stays
    (should (equal (drgnx-test-config-text 'drgnx-config-test)
                   ";; my config\n(:a 1 ; the a\n ;; unknown\n ;; about b\n :b \"x\")\n"))))

(ert-deftest drgnx-config/alist-entries-replace-add-remove ()
  (drgnx-test-with-config
    (drgnx-config-define 'drgnx-config-test-al :file "al.eld" :shape 'alist :schema '(alist string integer))
    (drgnx-test-config-put 'drgnx-config-test-al ";; layouts\n((\"one\" . 1)\n ;; two is mine\n (\"two\" . 2))\n")
    (drgnx-config-set 'drgnx-config-test-al "two" 3)
    (should (equal (drgnx-test-config-text 'drgnx-config-test-al)
                   ";; layouts\n((\"one\" . 1)\n ;; two is mine\n (\"two\" . 3))\n"))
    (drgnx-config-set 'drgnx-config-test-al "three" 4)
    (should (equal (drgnx-test-config-text 'drgnx-config-test-al)
                   ";; layouts\n((\"one\" . 1)\n ;; two is mine\n (\"two\" . 3)\n (\"three\" . 4))\n"))
    (should (equal (drgnx-config-unset 'drgnx-config-test-al "one") '(("two" . 3) ("three" . 4))))
    (should (equal (drgnx-test-config-text 'drgnx-config-test-al)
                   ";; layouts\n(;; two is mine\n (\"two\" . 3)\n (\"three\" . 4))\n"))))

(ert-deftest drgnx-config/a-wide-value-is-pretty-printed ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test "(:a 1\n :c (x))\n")
    (let ((wide (mapcar (lambda (i) (intern (format "alpha-beta-%02d" i))) (number-sequence 1 12))))
      (drgnx-config-set 'drgnx-config-test :c wide)
      (let ((text (drgnx-test-config-text 'drgnx-config-test)))
        (should (string-prefix-p "(:a 1\n :c (alpha-beta-01 " text))
        (should (> (cl-count ?\n text) 2))                              ; more than one line
        (should (string-match-p "\n    +alpha-beta-" text)))            ; indented to its column
      (should (equal (drgnx-config-get 'drgnx-config-test :c) wide))
      (should (eq (plist-get (drgnx-config-read 'drgnx-config-test) :status) 'ok)))))

(ert-deftest drgnx-config/fn-result-failing-the-schema-is-an-error ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test "(:a 1)\n")
    (let ((err (should-error (drgnx-config-update 'drgnx-config-test (lambda (d) (plist-put d :a "str"))))))
      (should (eq (car err) 'error))
      (should (string-match-p ":a: expected an integer" (cadr err))))
    (should (equal (drgnx-test-config-text 'drgnx-config-test) "(:a 1)\n"))))

(ert-deftest drgnx-config/a-reorder-is-an-error ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test "(:a 1 :b \"x\")\n")
    (should-error (drgnx-config-update 'drgnx-config-test (lambda (_) (list :b "y" :a 1))))
    (should (equal (drgnx-test-config-text 'drgnx-config-test) "(:a 1 :b \"x\")\n"))))

(ert-deftest drgnx-config/a-no-op-update-writes-nothing ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test "(:a 1)\n")
    (let ((stamp (drgnx-file-stamp (drgnx-config-test--file))))
      (should (equal (drgnx-config-update 'drgnx-config-test #'identity) '(:a 1)))
      (drgnx-config-set 'drgnx-config-test :a 1)
      (drgnx-config-unset 'drgnx-config-test :b)
      (should (equal (drgnx-file-stamp (drgnx-config-test--file)) stamp)))
    (should-not (directory-files (file-name-directory (drgnx-config-test--file)) nil "\\.tmp-\\|\\.lock"))))

(ert-deftest drgnx-config/a-user-write-migrates-with-a-backup ()
  (drgnx-test-with-config
    (drgnx-config-test--define :version 2 :migrate '((1 . drgnx-config-test--rename-old)))
    (drgnx-test-config-put 'drgnx-config-test ";; mine\n(:old 4 :b \"x\")\n")
    (should (equal (drgnx-config-set 'drgnx-config-test :b "y") '(:version 2 :a 4 :b "y")))
    (let ((backups (drgnx-config-test--backups)))
      (should (= 1 (length backups)))
      (should (equal (with-temp-buffer
                       (insert-file-contents (expand-file-name (car backups) (file-name-directory (drgnx-config-test--file))))
                       (buffer-string))
                     ";; mine\n(:old 4 :b \"x\")\n")))
    (should (equal (drgnx-test-config-text 'drgnx-config-test) ";; mine\n(:version 2 :a 4 :b \"y\")\n"))
    (should (eq (plist-get (drgnx-config-read 'drgnx-config-test) :status) 'ok))))

(ert-deftest drgnx-config/an-absent-file-is-written-with-header-and-version ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (should (equal (drgnx-config-set 'drgnx-config-test :a 3) '(:version 1 :a 3)))
    (should (equal (drgnx-test-config-text 'drgnx-config-test)
                   ";; drgnx: t.eld (docs/reference/config.md)\n(:version 1 :a 3)\n"))
    (should (equal (drgnx-config-get 'drgnx-config-test :b) "x"))))       ; the rest still from the default

(ert-deftest drgnx-config/project-files-are-read-only ()
  (drgnx-test-with-config
    (drgnx-config-define 'drgnx-config-test-p :file "p.eld" :dir 'project :schema drgnx-config-test--schema
                         :default '(:a 1))
    (let ((root (concat drgnx-test-config-root "proj/")))
      (should-error (drgnx-config-file 'drgnx-config-test-p))
      (should (equal (drgnx-config-file 'drgnx-config-test-p root) (concat root ".drgnx/p.eld")))
      (drgnx-test-config-put 'drgnx-config-test-p "(:a 5)" root)
      (should (eql (drgnx-config-get 'drgnx-config-test-p :a root) 5))
      (let ((err (should-error (drgnx-config-set 'drgnx-config-test-p :a 6 root))))
        (should (equal (cadr err) "drgnx-config-test-p is read-only")))
      (should-error (drgnx-config-update 'drgnx-config-test-p #'identity :root root))
      (should (equal (drgnx-test-config-text 'drgnx-config-test-p root) "(:a 5)")))))

;;;; Commands

(ert-deftest drgnx-config/reset-keeps-a-backup-and-writes-defaults ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-config-test--messages
      (drgnx-test-config-put 'drgnx-config-test "(:a \"x\")\n")
      (drgnx-config-get 'drgnx-config-test)
      (should (equal (drgnx-config--reset 'drgnx-config-test) '(:version 1 :a 1 :b "x"))))
    (should (= 1 (length (drgnx-config-test--backups))))
    (should (equal (drgnx-test-config-text 'drgnx-config-test)
                   ";; drgnx: t.eld (docs/reference/config.md)\n(:version 1 :a 1 :b \"x\")\n"))
    (should-not (drgnx-config-problem 'drgnx-config-test))))

(ert-deftest drgnx-config/reset-command-refuses-in-batch ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test "(:a 2)\n")
    (should-error (drgnx-config-reset 'drgnx-config-test) :type 'user-error)
    (should (equal (drgnx-test-config-text 'drgnx-config-test) "(:a 2)\n"))
    (should-not (drgnx-config-test--backups))))

(ert-deftest drgnx-config/reset-refuses-a-newer-file ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (let ((text ";; from a newer drgnx\n(:version 2 :a 7)\n"))
      (drgnx-test-config-put 'drgnx-config-test text)
      (should-error (drgnx-config--reset 'drgnx-config-test) :type 'drgnx-config-refused)
      (should (equal (drgnx-test-config-text 'drgnx-config-test) text))
      (should-not (drgnx-config-test--backups)))))

(ert-deftest drgnx-config/a-refusal-prints-without-quotes ()
  (should (equal (error-message-string '(drgnx-config-refused "X has a mistake")) "X has a mistake")))

(ert-deftest drgnx-config/open-goes-to-the-problem-line ()
  (drgnx-test-with-config
    (drgnx-config-test--define)
    (drgnx-test-config-put 'drgnx-config-test ";; c\n(:a 1\n :b #<buffer x>)\n")
    (drgnx-config-test--messages (drgnx-config-get 'drgnx-config-test))
    (let ((buf nil))
      (unwind-protect
          (progn
            (drgnx-config-open 'drgnx-config-test)
            (setq buf (current-buffer))
            (should (equal (buffer-file-name) (drgnx-config-test--file)))
            (should (= (line-number-at-pos) 3)))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest drgnx-config/commands-are-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-config-register-commands)
    (dolist (c '((config-open "Open Config File…" drgnx-config-open)
                 (config-reset "Reset Config File…" drgnx-config-reset)
                 (config-migrate "Migrate Config File…" drgnx-config-migrate)))
      (let ((cmd (drgnx-commands-get (car c))))
        (should cmd)
        (should (equal (drgnx-cmd-category cmd) "Preferences"))
        (should (equal (drgnx-cmd-title cmd) (nth 1 c)))
        (should (eq (drgnx-cmd-command cmd) (nth 2 c)))
        (should (commandp (nth 2 c)))))))

;;;; The hub

(ert-deftest drgnx-config/loads-with-only-cl-lib-subr-x-and-paths ()
  ;; Compiled, as an installed drgnx runs it: loading the source would expand macros and load cl-macs.
  (let ((dir (file-name-as-directory (make-temp-file "drgnx-config-hub" t)))
        (core (file-name-directory (locate-library "drgnx-config.el")))
        (files '("drgnx-paths" "drgnx-file" "drgnx-schema" "drgnx-config"))
        (buf (generate-new-buffer " *drgnx-config-hub*" t)))
    (unwind-protect
        (progn
          (dolist (f files) (copy-file (expand-file-name (concat f ".el") core) dir))
          (let ((load-path (cons dir load-path)) (byte-compile-warnings nil) (inhibit-message t))
            (dolist (f files) (should (byte-compile-file (expand-file-name (concat f ".el") dir)))))
          (let ((proc (make-process
                       :name "drgnx-config-hub" :buffer buf :noquery t :stderr (generate-new-buffer " *hub-err*" t)
                       :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-L" dir
                                      "--eval" "(let ((before features)) (require 'drgnx-config)
                                                  (let ((new nil)) (dolist (f features) (unless (memq f before) (push f new)))
                                                    (prin1 new)))")))
                (deadline (+ (float-time) 30)))
            (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output proc 0.05))
            (should (eq (process-status proc) 'exit))
            (should (eql (process-exit-status proc) 0))
            (let ((new (car (read-from-string (with-current-buffer buf (buffer-string))))))
              (dolist (f '(drgnx-paths drgnx-file drgnx-schema drgnx-config)) (should (memq f new)))
              ;; cl-loaddefs is cl-lib's own autoloads, loaded by (require 'cl-lib); from Emacs 31 subr-x requires
              ;; mule-util
              (should-not (cl-set-difference new '(cl-lib cl-loaddefs subr-x mule-util drgnx-paths drgnx-file
                                                          drgnx-schema drgnx-config))))))
      (kill-buffer buf)
      (delete-directory dir t))))

;;; config-test.el ends here
