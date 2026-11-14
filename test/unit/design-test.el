;;; design-test.el --- batch tests: the design system's generated pages (docs/design/) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure.  The pages are built in memory from the token table, the faces and the look's constants.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(add-to-list 'load-path (expand-file-name "harness" drgnx-dir))
(require 'drgnx-design)

(defun design-test--page (name)
  "The generated page NAME (its path under docs/design/), or fail."
  (or (cdr (assoc name (drgnx-design-pages))) (ert-fail (format "no generated page %s" name))))

(defun design-test--row (page token)
  "The table row of TOKEN in PAGE's section for its first variant that has one."
  (and (string-match (format "^| `%s` |.*$" (regexp-quote (symbol-name token))) page) (match-string 0 page)))

(ert-deftest drgnx-design/the-tokens-page-has-a-section-per-variant ()
  (let ((page (design-test--page "tokens.md")))
    (dolist (heading '("## Dark" "## Light" "## High contrast"))
      (should (string-search (concat "\n" heading "\n") page)))))

(ert-deftest drgnx-design/the-tokens-page-lists-every-token-with-its-colour ()
  (let ((page (design-test--page "tokens.md")))
    (dolist (variant '(dark light hc))
      (let* ((section (drgnx-design--section page variant)))
        (dolist (token (mapcar #'car (alist-get variant (drgnx-design--table))))
          (should (string-search (format "| `%s` | `%s` |" token (drgnx-look-token token variant)) section)))))))

(ert-deftest drgnx-design/a-token-names-the-faces-that-use-it ()
  (let ((section (drgnx-design--section (design-test--page "tokens.md") 'dark)))
    (should (string-match-p "^| `sel` | .*`drgnx-selected`" section))
    (should (string-match-p "^| `ok` | .*`drgnx-status-ok`" section))))

(ert-deftest drgnx-design/the-css-has-every-token-of-every-variant ()
  (let ((css (design-test--page "tokens.css")))
    (dolist (variant '(dark light hc))
      (let ((block (drgnx-design--css-block css variant)))
        (should block)
        (dolist (token (mapcar #'car (alist-get variant (drgnx-design--table))))
          (should (string-search (format "--%s: %s;" token (drgnx-look-token token variant)) block)))))))
