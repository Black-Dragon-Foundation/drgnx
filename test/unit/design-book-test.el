;;; design-book-test.el --- batch tests: docs/ as one book (mdBook): its contents, links, theme and workflow -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure.  Reads the checkout's docs/, docs/SUMMARY.md, docs/book.toml and the Pages workflow as text.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defun design-book-test--text (rel)
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents (expand-file-name rel drgnx-dir)))
    (buffer-string)))

(defun design-book-test--pages ()
  "Every Markdown page of docs/ except the table of contents, relative to docs/."
  (let ((root (expand-file-name "docs/" drgnx-dir)))
    (sort (seq-remove (lambda (p) (equal p "SUMMARY.md"))
                      (mapcar (lambda (f) (file-relative-name f root)) (directory-files-recursively root "\\.md\\'")))
          #'string<)))

(defun design-book-test--summary ()
  "The entries of docs/SUMMARY.md: ((SECTION . PATH)...) in order, SECTION the part title above it (nil before any)."
  (let (section result)
    (dolist (line (split-string (design-book-test--text "docs/SUMMARY.md") "\n"))
      (cond ((equal line "# Summary") nil)
            ((string-match "\\`# \\(.+\\)\\'" line) (setq section (match-string 1 line)))
            ((string-match "\\`[ \t]*- \\[[^]]+\\](\\([^)]+\\))" line) (push (cons section (match-string 1 line)) result))
            ((string-match "\\`\\[[^]]+\\](\\([^)]+\\))" line) (push (cons section (match-string 1 line)) result))))
    (nreverse result)))

(ert-deftest drgnx-design-book/the-contents-list-every-page-and-only-real-pages ()
  (let* ((listed (mapcar #'cdr (design-book-test--summary)))
         (pages (design-book-test--pages)))
    (should-not (seq-difference pages listed))     ; a page the contents forget
    (should-not (seq-difference listed pages))     ; an entry with no file
    (should (= (length listed) (length (delete-dups (copy-sequence listed)))))))

(ert-deftest drgnx-design-book/the-contents-are-grouped-by-folder ()
  (let ((entries (design-book-test--summary)))
    (should (equal (cdar entries) "index.md"))     ; the landing page comes first, before any part
    (should-not (caar entries))
    (should (equal (delete-dups (delq nil (mapcar #'car entries))) '("Guide" "Reference" "Develop" "Design")))
    (dolist (e (cdr entries))
      (should (string-prefix-p (format "%s/" (downcase (car e))) (cdr e))))))

(ert-deftest drgnx-design-book/every-relative-link-of-the-docs-resolves ()
  (let ((root (expand-file-name "docs/" drgnx-dir)) problems)
    (dolist (page (cons "SUMMARY.md" (design-book-test--pages)))
      (let ((file (expand-file-name page root)) (fenced nil))
        (dolist (line (split-string (design-book-test--text (concat "docs/" page)) "\n"))
          (if (string-prefix-p "```" line)
              (setq fenced (not fenced))
            (unless fenced
              (let ((start 0) (plain (replace-regexp-in-string "`[^`]*`" "" line)))
                (while (string-match "\\](\\([^)#]+\\)\\(#[^)]*\\)?)" plain start)
                  (let ((target (match-string 1 plain)))
                    (setq start (match-end 0))
                    (unless (or (string-match-p "\\`[a-z]+:" target) (string-prefix-p "/" target)
                                (file-exists-p (expand-file-name target (file-name-directory file))))
                      (push (format "%s -> %s" page target) problems))))))))))
    (should-not problems)))

(ert-deftest drgnx-design-book/the-book-is-configured-for-the-generated-theme ()
  (let ((toml (design-book-test--text "docs/book.toml")))
    (should (string-match-p "^src = \"\\.\"$" toml))
    (should (string-match-p "additional-css = \\[\"design/tokens.css\", \"design/book.css\"\\]" toml))
    (should (string-match-p "use-default-preprocessors = false" toml))
    (should-not (string-match-p "\\[preprocessor\\." toml))))

(ert-deftest drgnx-design-book/the-theme-reads-the-tokens-and-holds-no-colour ()
  (let ((css (design-book-test--text "docs/design/book.css")))
    (should-not (string-match-p "#[0-9a-fA-F]\\{3,8\\}\\b\\|rgba?(\\|hsla?(" css))
    (should (string-search "var(--drgnx-editor)" css))
    ;; mdBook's own variables are set from the tokens, for each of its themes
    (dolist (var '("--bg" "--fg" "--sidebar-bg" "--links" "--table-border-color"))
      (should (string-search (concat var ":") css)))
    (dolist (class '("html.light" "html.coal"))
      (should (string-search class css)))))

(ert-deftest drgnx-design-book/the-tokens-css-serves-the-book-and-the-system ()
  (let ((css (design-book-test--text "docs/design/tokens.css")))
    (should (string-search "--drgnx-sel:" css))
    (should-not (string-match-p "^ *--sel:" css))
    (should (string-search "html.coal" css))
    (should (string-search "html.light" css))
    (should (string-search ":root[data-theme=\"hc\"]" css))))

(ert-deftest drgnx-design-book/the-pages-workflow-builds-the-book-and-deploys-from-main-only ()
  (let ((yml (design-book-test--text ".github/workflows/design-pages.yml")))
    (should (string-search "pages: write" yml))
    (should (string-match-p "MDBOOK_VERSION: \"0\\.5\\.[0-9]+\"" yml))
    (should (string-match-p "MDBOOK_SHA256: \"[0-9a-f]\\{64\\}\"" yml))
    (should (string-search "sha256sum -c" yml))
    (should (string-search "mdbook build docs" yml))
    (should (string-search "bin/drgnx design --check" yml))
    (let ((deploy (substring yml (string-search "\n  deploy:\n" yml))))
      (should (string-search "github.ref == 'refs/heads/main'" deploy)))
    (should (string-search "pull_request:" yml))
    (should-not (string-search "pull_request_target" yml))))

;;; The guides hand the visual reference to the design system

(ert-deftest drgnx-design-book/the-guides-link-the-design-system ()
  (dolist (rel '("docs/guide/look.md" "docs/guide/face.md"))
    (should (string-search "../design/index.md" (design-book-test--text rel))))
  (should (string-search "design/index.md" (design-book-test--text "docs/index.md")))
  (should (string-search "design/tokens.md" (design-book-test--text "docs/guide/face.md"))))

(ert-deftest drgnx-design-book/the-theme-author-text-lives-in-one-place ()
  (let ((marker "moved 3 % toward the text colour"))
    (should (string-search marker (design-book-test--text "docs/design/theme-authors.md")))
    (should-not (string-search marker (design-book-test--text "docs/guide/look.md")))))
