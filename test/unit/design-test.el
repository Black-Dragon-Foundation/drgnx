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

(defun design-test--rows (page)
  "The table rows of PAGE (the lines that start with `| `')."
  (seq-filter (lambda (l) (string-prefix-p "| " l)) (split-string page "\n")))

(defun design-test--row-of (page key)
  "The table row of PAGE whose first cell is `KEY`."
  (seq-find (lambda (l) (string-prefix-p (format "| `%s` |" key) l)) (design-test--rows page)))

(ert-deftest drgnx-design/the-type-page-has-every-font-role-with-its-size ()
  (require 'drgnx-type-faces)
  (let ((page (design-test--page "type.md")))
    (dolist (role drgnx-type-defaults)
      (should (design-test--row-of page (car role))))
    ;; a ratio and the pixels it gives at the code size
    (let ((row (design-test--row-of page 'ui-caption)))
      (should (string-search "0.889" row))
      (should (string-search (format "%.1f" (* 0.889 drgnx-type-code-px)) row)))
    ;; a role whose family names another role shows that role's family
    (should (string-search "Adwaita Sans" (design-test--row-of page 'ui-heading)))))

(ert-deftest drgnx-design/the-type-page-has-the-density-table ()
  (let ((page (design-test--page "type.md")))
    (dolist (row drgnx-look-density-table)
      (should (string-search (format "| `%s` | %d | %d | %d |" (car row) (nth 1 row) (nth 2 row) (nth 3 row)) page)))))

(ert-deftest drgnx-design/the-type-page-lists-the-type-faces ()
  (let ((page (design-test--page "type.md")))
    (dolist (face '(drgnx-ui-text drgnx-ui-caption drgnx-code-small drgnx-terminal))
      (should (design-test--row-of page face)))))

(ert-deftest drgnx-design/the-icons-page-has-every-icon-file ()
  (let ((page (design-test--page "icons.md"))
        (names (mapcar #'file-name-sans-extension
                       (directory-files (expand-file-name "etc/icons" drgnx-dir) nil "\\.svg\\'"))))
    (should (> (length names) 50))
    (dolist (name names) (should (design-test--row-of page name)))
    (should (assoc "img/icons-dark.svg" (drgnx-design-pages)))
    (should (assoc "img/icons-light.svg" (drgnx-design-pages)))))

(ert-deftest drgnx-design/an-icon-names-the-files-that-use-it ()
  (let ((row (design-test--row-of (design-test--page "icons.md") 'bell)))
    (should (string-search "core/drgnx-notice-toast.el" row))))

(ert-deftest drgnx-design/the-icons-page-gives-the-file-kinds ()
  ;; the icons the Explorer and Quick Open pick by file name come from etc/icons/files.eld
  (let ((row (design-test--row-of (design-test--page "icons.md") 'file-archive)))
    (should (string-search "file kind" row))))
