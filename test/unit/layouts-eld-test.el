;;; layouts-eld-test.el --- batch tests: layouts.eld through the config layer -*- lexical-binding: t -*-
;; Save Layout As… needs a frame's arrangement; these tests stub the snapshot, so they check the file side only
;; (the frame side is in mod-layouts-test.el).  Every test runs under `drgnx-test-with-config'.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-layouts" drgnx-dir) nil t)

(defconst drgnx-layouts-eld-test--good
  ";; my own notes, kept
((zen :left nil :right nil :panel nil :editor zen) ; a built-in name, left alone
 (old :left files :right nil :panel nil :editor one :px (:left 240 :panel nil :right nil))
 ;; between two entries
 (other :left nil :right agents :panel output :editor one))
"
  "A layouts.eld holding comments, an entry named like a built-in layout and two of the user's.")

(defmacro drgnx-layouts-eld-test--with (&rest body)
  "BODY with layouts.eld defined, in a fresh config folder, and the arrangement stubbed."
  (declare (indent 0))
  `(drgnx-test-with-config
     (drgnx-layouts--define-config)
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-layouts--close-bars) #'ignore)
                   ((symbol-function 'drgnx-layouts--remember) #'ignore)
                   ((symbol-function 'drgnx-layouts--snapshot)
                    (lambda () (list :left '(:shown t :view files :px 200) :panel '(:shown nil :px nil)
                                     :right '(:shown t :tab agents :px 120))))
                   ((symbol-function 'window-state-get) (lambda (&rest _) '(window-state :fake t))))
           ,@body)
       (set-frame-parameter nil 'drgnx-layouts-current nil)
       (set-frame-parameter nil 'drgnx-layouts-previous nil))))

(defun drgnx-layouts-eld-test--text () (drgnx-test-config-text 'layouts))

(ert-deftest drgnx-layouts-eld/an-unreadable-file-is-never-overwritten-by-save-as ()
  (drgnx-layouts-eld-test--with
    (let ((broken "((mine :left files :right nil\n ;; the user's layouts, half typed\n"))
      (drgnx-test-config-put 'layouts broken)
      (should-error (drgnx-layouts-save "review") :type 'drgnx-config-refused)
      (should (equal (drgnx-layouts-eld-test--text) broken))
      (should (equal (drgnx-layouts-names) (mapcar #'car drgnx-layouts)))
      (should-not (drgnx-layouts-current)))))

(ert-deftest drgnx-layouts-eld/save-as-keeps-other-layouts-comments-and-built-in-named-entries ()
  (drgnx-layouts-eld-test--with
    (drgnx-test-config-put 'layouts drgnx-layouts-eld-test--good)
    (should (equal (drgnx-layouts-names) (append (mapcar #'car drgnx-layouts) '(old other))))
    (should-not (assq 'zen (drgnx-layouts--user)))
    ;; a new name is appended
    (should (eq (drgnx-layouts-save "review") 'review))
    (let ((text (drgnx-layouts-eld-test--text)))
      (should (string-prefix-p ";; my own notes, kept\n((zen :left nil :right nil :panel nil :editor zen) ; a built-in name, left alone\n" text))
      (should (string-search " ;; between two entries\n" text))
      (should (string-search " (other :left nil :right agents :panel output :editor one)" text))
      (should (string-search "(review :left files" text)))
    (should (equal (drgnx-layouts-names) (append (mapcar #'car drgnx-layouts) '(old other review))))
    ;; an existing name is replaced where it stands; nothing else changes
    (let ((before (drgnx-layouts-eld-test--text)))
      (drgnx-layouts-save "old")
      (let ((after (drgnx-layouts-eld-test--text)))
        (should-not (equal before after))
        (should (string-prefix-p ";; my own notes, kept\n((zen :left nil" after))
        (should (string-search " ;; between two entries\n" after))
        (should (string-search "(review :left files" after))
        (should (< (string-search "(old :left" after) (string-search ";; between" after)))
        (should (equal (alist-get 'zen (drgnx-config-get 'layouts))
                       '(:left nil :right nil :panel nil :editor zen)))
        (should (equal (plist-get (alist-get 'old (drgnx-config-get 'layouts)) :windows) '(window-state :fake t)))))
    (should (eq (drgnx-layouts-current) 'old))))

(ert-deftest drgnx-layouts-eld/a-new-file-starts-with-its-header ()
  (drgnx-layouts-eld-test--with
    (drgnx-layouts-save "first")
    (should (string-prefix-p ";; drgnx: your layouts, written by View: Save Layout As… (docs/guide/layouts.md)\n"
                             (drgnx-layouts-eld-test--text)))
    (should (memq 'first (drgnx-layouts-names)))))

(ert-deftest drgnx-layouts-eld/a-mistake-uses-the-last-good-copy ()
  (drgnx-layouts-eld-test--with
    (drgnx-test-config-put 'layouts drgnx-layouts-eld-test--good)
    (should (memq 'old (drgnx-layouts-names)))                ; read well: kept as the last good copy
    (let ((bad "((old :left 5 :right nil))\n"))             ; :left must be a symbol or nil
      (drgnx-test-config-put 'layouts bad)
      (let ((message-log-max nil) (inhibit-message t))
        (should (memq 'other (drgnx-layouts-names))))       ; the good copy, not the mistake
      (should (drgnx-config-problem 'layouts))
      (should-error (drgnx-layouts-save "review") :type 'drgnx-config-refused)
      (should (equal (drgnx-layouts-eld-test--text) bad)))))

(ert-deftest drgnx-layouts-eld/names-nil-t-and-keywords-are-refused ()
  (drgnx-layouts-eld-test--with
    (dolist (name '("nil" "t" ":left" " :x "))
      (let ((err (should-error (drgnx-layouts-save name) :type 'user-error)))
        (should (string-match-p "is not a layout name" (error-message-string err)))))
    (should-error (drgnx-layouts-save "  ") :type 'user-error)
    (should-error (drgnx-layouts-save "zen") :type 'user-error)
    (should-not (file-exists-p (drgnx-config-file 'layouts)))
    (should-not (drgnx-layouts--name-p nil))
    (should-not (drgnx-layouts--name-p t))
    (should-not (drgnx-layouts--name-p :k))
    (should-not (drgnx-layouts--name-p "str"))
    (should (drgnx-layouts--name-p 'ok))
    ;; a file holding such a name is a mistake, not an entry
    (drgnx-test-config-put 'layouts "((nil :left files))\n")
    (should-not (let ((inhibit-message t)) (drgnx-layouts--user)))
    (should (drgnx-config-problem 'layouts))))

(ert-deftest drgnx-layouts-eld/the-file-is-read-once-per-change ()
  (drgnx-layouts-eld-test--with
    (drgnx-test-config-put 'layouts drgnx-layouts-eld-test--good)
    (let ((reads 0) (orig (symbol-function 'drgnx-config--read)))
      (cl-letf (((symbol-function 'drgnx-config--read)
                 (lambda (&rest args) (cl-incf reads) (apply orig args))))
        (drgnx-layouts-names)
        (drgnx-layouts-names)
        (should (= reads 1))
        (drgnx-test-config-put 'layouts "((one :left files))\n")
        (drgnx-layouts-names)
        (drgnx-layouts-names)
        (should (= reads 2))))))

(ert-deftest drgnx-layouts-eld/teardown-undefines-it ()
  (drgnx-test-with-config
    (let ((spec (copy-tree (assq 'tools/layouts drgnx-modules--table))))
      (should spec)
      (setcdr spec (plist-put (cdr spec) :requires nil))            ; core/workbench is not in this table
      (let ((drgnx-modules--table (list spec)) (drgnx-modules--report nil) (drgnx-modules--state nil)
            (drgnx-modules--stacks nil) (drgnx-modules--runs nil) (drgnx-modules--features nil)
            (drgnx-module--claims (make-hash-table :test 'equal))
            (drgnx-module--releasers (make-hash-table :test 'equal)))
        (drgnx-modules--run-one 'tools/layouts (cdr spec) 'startup)     ; the real setup, then the real teardown
        (should (eq (plist-get (alist-get 'tools/layouts drgnx-modules--report) :status) 'ok))
        (should (gethash 'layouts drgnx-config--defs))
        (should (member "config layouts" (mapcar #'car (alist-get 'tools/layouts drgnx-modules--stacks))))
        (should-not (drgnx-module-teardown 'tools/layouts))
        (should-not (gethash 'layouts drgnx-config--defs))
        ;; with the module off, there are only the built-in layouts
        (should (equal (drgnx-layouts-names) (mapcar #'car drgnx-layouts)))))))

(provide 'layouts-eld-test)
;;; layouts-eld-test.el ends here
