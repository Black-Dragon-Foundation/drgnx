;;; design-site-test.el --- batch tests: the design system's static site (docs/design/ → HTML) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure.  Markdown goes in as a string, HTML comes out; the site is built into a temp folder.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(add-to-list 'load-path (expand-file-name "harness" drgnx-dir))
(require 'drgnx-design-site)

(defun design-site-test--html (md) (drgnx-design-site-markdown md "components/page.md"))

(ert-deftest drgnx-design-site/headings-paragraphs-and-inline-markup ()
  (let ((html (design-site-test--html "# A title\n\nSome *quiet* and **loud** words with `code`.\n\n## Next\n")))
    (should (string-search "<h1 id=\"a-title\">A title</h1>" html))
    (should (string-search "<p>Some <em>quiet</em> and <strong>loud</strong> words with <code>code</code>.</p>" html))
    (should (string-search "<h2 id=\"next\">Next</h2>" html))))

(ert-deftest drgnx-design-site/code-is-escaped ()
  (let ((html (design-site-test--html "Use `a<b` here.\n\n```elisp\n(if (< a b) \"x&y\")\n```\n")))
    (should (string-search "<code>a&lt;b</code>" html))
    (should (string-search "<pre><code>(if (&lt; a b) \"x&amp;y\")\n</code></pre>" html))))

(ert-deftest drgnx-design-site/lists-and-tables ()
  (let ((html (design-site-test--html "- one\n- two\n  continued\n\n1. first\n2. second\n\n| A | B |\n|---|---|\n| `x` | y |\n")))
    (should (string-search "<ul>\n<li>one</li>\n<li>two continued</li>\n</ul>" html))
    (should (string-search "<ol>\n<li>first</li>\n<li>second</li>\n</ol>" html))
    (should (string-search "<table>\n<thead>\n<tr><th>A</th><th>B</th></tr>\n</thead>\n<tbody>\n<tr><td><code>x</code></td><td>y</td></tr>\n</tbody>\n</table>"
                           html))))

(ert-deftest drgnx-design-site/links-stay-in-the-site-or-point-at-the-repository ()
  (let ((html (design-site-test--html "[tokens](../tokens.md#dark) [face](../../guide/face.md) [web](https://lucide.dev) [dir](./)\n")))
    (should (string-search "<a href=\"../tokens.html#dark\">tokens</a>" html))
    (should (string-search "<a href=\"https://github.com/Black-Dragon-Foundation/drgnx/blob/main/docs/guide/face.md\">face</a>" html))
    (should (string-search "<a href=\"https://lucide.dev\">web</a>" html))
    (should (string-search "<a href=\"./\">dir</a>" html))))

(ert-deftest drgnx-design-site/images-and-comments ()
  (let ((html (design-site-test--html "<!-- generated -->\n\n![The sheet](../img/tokens-dark.svg)\n")))
    (should-not (string-search "generated" html))
    (should (string-search "<img src=\"../img/tokens-dark.svg\" alt=\"The sheet\">" html))))

(ert-deftest drgnx-design-site/the-site-builds-every-page-with-the-tokens-css ()
  (let ((out (make-temp-file "drgnx-design-site" t)))
    (unwind-protect
        (progn
          (drgnx-design-site-build out)
          (dolist (page '("index.html" "tokens.html" "type.html" "icons.html" "app-icon.html" "theme-authors.html"
                          "tokens.css" "site.css" "img/tokens-dark.svg" ".nojekyll"))
            (should (file-exists-p (expand-file-name page out))))
          (let ((index (with-temp-buffer (insert-file-contents (expand-file-name "index.html" out)) (buffer-string))))
            (should (string-search "<link rel=\"stylesheet\" href=\"tokens.css\">" index))
            (should (string-search "<link rel=\"stylesheet\" href=\"site.css\">" index))
            (should (string-search "<a href=\"tokens.html\">" index)))
          (let ((nested (directory-files (expand-file-name "components" out) nil "\\.html\\'")))
            (should nested)
            (let ((text (with-temp-buffer (insert-file-contents (expand-file-name (car nested) (expand-file-name "components" out)))
                                          (buffer-string))))
              (should (string-search "href=\"../tokens.css\"" text)))))
      (delete-directory out t))))

(ert-deftest drgnx-design-site/no-markdown-link-is-left-dangling ()
  ;; every relative link of every page resolves to a file of docs/design/ or to something outside it (sent to the repository)
  (let ((root (expand-file-name "docs/design/" drgnx-dir)) (problems nil))
    (dolist (md (directory-files-recursively root "\\.md\\'"))
      (with-temp-buffer
        (insert-file-contents md)
        (while (re-search-forward "\\](\\([^)#]+\\)\\(#[^)]*\\)?)" nil t)
          (let* ((target (match-string 1))
                 (file (expand-file-name target (file-name-directory md))))
            (when (and (not (string-match-p "\\`[a-z]+:" target))
                       (string-prefix-p root file)
                       (not (file-exists-p file))
                       (not (file-directory-p file)))
              (push (format "%s -> %s" (file-relative-name md root) target) problems))))))
    (should-not problems)))

(ert-deftest drgnx-design-site/the-stylesheet-has-no-colour-literal ()
  ;; the site's colours come from the generated tokens.css; site.css only reads them
  (with-temp-buffer
    (insert-file-contents (expand-file-name "docs/design/site.css" drgnx-dir))
    (should-not (re-search-forward "#[0-9a-fA-F]\\{3,8\\}\\b\\|rgba?(\\|hsla?(" nil t))))

(ert-deftest drgnx-design-site/the-pages-workflow-deploys-from-main-only ()
  (let ((yml (with-temp-buffer (insert-file-contents (expand-file-name ".github/workflows/design-pages.yml" drgnx-dir))
                               (buffer-string))))
    (should (string-search "pages: write" yml))
    (should (string-search "bin/drgnx design --site" yml))
    ;; the deploy job runs for main only; a branch or a pull request only builds
    (let ((deploy (substring yml (string-search "\n  deploy:\n" yml))))
      (should (string-search "github.ref == 'refs/heads/main'" deploy)))
    (should-not (string-search "pull_request_target" yml))))

;;; The guides hand the visual reference to the design system

(defun design-site-test--text (rel)
  (with-temp-buffer (insert-file-contents (expand-file-name rel drgnx-dir)) (buffer-string)))

(ert-deftest drgnx-design-site/the-guides-link-the-design-system ()
  (dolist (rel '("docs/guide/look.md" "docs/guide/face.md"))
    (should (string-search "../design/index.md" (design-site-test--text rel))))
  (should (string-search "design/index.md" (design-site-test--text "docs/index.md")))
  (should (string-search "design/tokens.md" (design-site-test--text "docs/guide/face.md"))))

(ert-deftest drgnx-design-site/the-theme-author-text-lives-in-one-place ()
  ;; moved, not copied: look.md keeps a pointer, the design system holds the text
  (let ((marker "moved 3 % toward the text colour"))
    (should (string-search marker (design-site-test--text "docs/design/theme-authors.md")))
    (should-not (string-search marker (design-site-test--text "docs/guide/look.md")))
    (should (string-search "../design/theme-authors.md" (design-site-test--text "docs/guide/look.md")))))

(ert-deftest drgnx-design-site/the-links-of-the-guides-resolve ()
  (dolist (rel '("docs/guide/look.md" "docs/guide/face.md" "docs/index.md"))
    (let ((file (expand-file-name rel drgnx-dir)) (problems nil))
      (with-temp-buffer
        (insert-file-contents file)
        (while (re-search-forward "\\](\\([^)#]+\\)\\(#[^)]*\\)?)" nil t)
          (let ((target (match-string 1)))
            (unless (or (string-match-p "\\`[a-z]+:" target)
                        (file-exists-p (expand-file-name target (file-name-directory file))))
              (push target problems)))))
      (should-not problems))))
