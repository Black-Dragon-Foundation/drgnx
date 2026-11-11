;;; search-pattern-test.el --- batch tests: the Search view's Pattern toggle -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: the view's state is set by hand in a buffer and the search is a stub that counts its calls.  Each test
;; names its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)

(defmacro drgnx-search-pattern-test--with (file &rest body)
  "BODY in a buffer standing for the Search view in Text mode, opened from FILE; `drgnx-replace--requery' and
`drgnx-replace--search-now' count their calls in SEARCHED."
  (declare (indent 1))
  `(with-temp-buffer
     (setq-local drgnx-replace--opts (list :mode 'text :case nil :word nil :regexp nil :scope 'project))
     (let ((searched 0) (buf (current-buffer)))
       (cl-letf (((symbol-function 'drgnx-replace--live-view) (lambda () buf))
                 ((symbol-function 'drgnx-replace--requery) (lambda () (cl-incf searched)))
                 ((symbol-function 'drgnx-replace--search-now) (lambda () (cl-incf searched)))
                 ((symbol-function 'drgnx-replace--origin-file) (lambda () ,file))
                 ((symbol-function 'drgnx-replace--text) (lambda (_) ""))
                 ((symbol-function 'drgnx-replace--scope-param) (lambda (_) '(:kind "project"))))
         ,@body))))

(ert-deftest drgnx-search-pattern/the-toggle-sends-a-pattern-in-the-files-language ()
  "Pattern D: `{}' on makes Find a code pattern: the chip says Pattern, the language is the origin file's, and the
hub gets a pattern search with no replacement; off again, Text."
  (drgnx-search-pattern-test--with "/p/src/main.rs"
    (should (equal (string-trim (drgnx-replace--chip-label)) "Text"))
    (drgnx-replace-search-toggle-pattern)
    (should (= searched 1))
    (should (drgnx-replace--opt :pattern))
    (should (equal (string-trim (drgnx-replace--chip-label)) "Pattern"))
    (should (equal (drgnx-replace--opt :lang) "rust"))
    (let ((spec (drgnx-replace--spec "foo($A)" nil)))
      (should (equal (plist-get spec :query) '(:mode "pattern" :pattern "foo($A)" :lang "rust")))
      (should-not (plist-member spec :replace)))
    (drgnx-replace-search-toggle-pattern)
    (should-not (drgnx-replace--opt :pattern))
    (should (equal (plist-get (plist-get (drgnx-replace--spec "x" nil) :query) :mode) "text"))))

(ert-deftest drgnx-search-pattern/pattern-and-regexp-exclude-each-other ()
  "Pattern D: `.*' on turns `{}' off, and `{}' on turns `.*' off."
  (drgnx-search-pattern-test--with "/p/a.el"
    (drgnx-replace--set-regexp t)
    (drgnx-replace-search-toggle-pattern)
    (should (drgnx-replace--opt :pattern))
    (should-not (drgnx-replace--opt :regexp))
    (drgnx-replace--set-regexp t)
    (should (drgnx-replace--opt :regexp))
    (should-not (drgnx-replace--opt :pattern))))

(ert-deftest drgnx-search-pattern/the-language-chip ()
  "Pattern D: with `{}' on, the chips line names the pattern's language (any, when the origin file's has no
grammar); the language can be chosen, `any' is every language; off, no line."
  (drgnx-search-pattern-test--with "/p/notes.org"
    (should (equal (drgnx-replace--pattern-line) ""))
    (drgnx-replace-search-toggle-pattern)
    (should-not (drgnx-replace--opt :lang))
    (should (string-match-p "^Pattern .*any" (substring-no-properties (drgnx-replace--pattern-line))))
    (drgnx-replace-search-pattern-language "python")
    (should (equal (drgnx-replace--opt :lang) "python"))
    (should (string-match-p "python" (substring-no-properties (drgnx-replace--pattern-line))))
    (should (equal (plist-get (plist-get (drgnx-replace--spec "f($A)" nil) :query) :lang) "python"))
    (drgnx-replace-search-pattern-language "any")
    (should-not (plist-member (plist-get (drgnx-replace--spec "f($A)" nil) :query) :lang))))

(ert-deftest drgnx-search-pattern/a-saved-pattern-search-comes-back-as-one ()
  "Pattern D: restoring a pattern search (history, saved) turns `{}' on with its language and labels it Pattern."
  (drgnx-search-pattern-test--with "/p/a.el"
    (cl-letf (((symbol-function 'drgnx-replace--fill) #'ignore)
              ((symbol-function 'drgnx-replace--apply-scope) #'ignore))
      (drgnx-replace--restore '(:query (:mode "pattern" :pattern "(eq $A $A)" :lang "elisp"))))
    (should (eq (drgnx-replace--opt :mode) 'text))
    (should (drgnx-replace--opt :pattern))
    (should (equal (drgnx-replace--opt :lang) "elisp"))
    (should (equal (drgnx-replace--spec-text '(:query (:mode "pattern" :pattern "(eq $A $A)"))) "(eq $A $A)"))
    (should (string-match-p "· Pattern" (drgnx-replace--spec-label '(:query (:mode "pattern" :pattern "x")))))))

(ert-deftest drgnx-search-pattern/replace-all-refuses-a-pattern ()
  "Pattern D: a Pattern search only finds for now: Replace All says so."
  (drgnx-search-pattern-test--with "/p/a.rs"
    (drgnx-replace-search-toggle-pattern)
    (should-error (drgnx-replace--check-writable) :type 'user-error)))

;;; search-pattern-test.el ends here
