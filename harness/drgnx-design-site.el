;;; drgnx-design-site.el --- the design system as a static site (docs/design/ → HTML) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx design --site DIR' turns docs/design/ into a static site: every page's Markdown becomes HTML in one layout
;; with a navigation list, the generated tokens.css supplies every colour (site.css only reads those custom
;; properties), and the images are copied.  The Markdown reader is the small subset the pages use: headings,
;; paragraphs, bullet and numbered lists (one level), tables, fenced code, inline code, emphasis, links and images.
;; A link to another page of the design system becomes a link to its HTML; a link to anything else of the repository
;; (the user guide) goes to the file on GitHub, since the site holds the design system only.  GitHub Pages serves the
;; result (.github/workflows/design-pages.yml); no runtime other than Emacs is needed to build it.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'drgnx-paths)

(defconst drgnx-design-site-repo "https://github.com/Black-Dragon-Foundation/drgnx"
  "The repository the site's links to files outside docs/design/ point into.")

(defconst drgnx-design-site-ref "main" "The branch those links read.")

(defconst drgnx-design-site-nav-order
  '("index.md" "tokens.md" "type.md" "icons.md" "components/index.md" "app-icon.md" "theme-authors.md")
  "The pages the navigation lists first, in this order; the pages under components/ follow components/index.md.")

;;;; Markdown

(defun drgnx-design-site--escape (text)
  "TEXT with &, < and > made safe in HTML."
  (replace-regexp-in-string ">" "&gt;" (replace-regexp-in-string "<" "&lt;" (replace-regexp-in-string "&" "&amp;" text t t) t t) t t))

(defun drgnx-design-site--slug (text)
  "A heading's id: its text, lowercase, with runs of other characters as one hyphen."
  (let ((s (downcase (replace-regexp-in-string "`" "" text))))
    (string-trim (replace-regexp-in-string "[^a-z0-9]+" "-" s) "-" "-")))

(defun drgnx-design-site--link (target path)
  "The href for the Markdown link TARGET written in the page PATH (relative to docs/design/)."
  (if (or (string-match-p "\\`[a-z][a-z0-9+.-]*:" target) (string-prefix-p "#" target) (string-prefix-p "./" target)
          (equal target "."))
      target
    (let* ((hash (string-match "#" target))
           (file (if hash (substring target 0 hash) target))
           (frag (if hash (substring target hash) ""))
           (stack (butlast (split-string (or path "") "/" t)))
           (up 0))
      (dolist (seg (split-string file "/" t))
        (cond ((equal seg "..") (if stack (setq stack (butlast stack)) (cl-incf up)))
              ((equal seg ".") nil)
              (t (setq stack (append stack (list seg))))))
      (cond ((> up 0)                   ; outside docs/design/: the file in the repository
             (format "%s/blob/%s/%s%s" drgnx-design-site-repo drgnx-design-site-ref
                     (string-join (append (butlast '("docs" "design") up) stack) "/") frag))
            ((string-suffix-p ".md" file)
             (concat (replace-regexp-in-string "\\.md\\'" ".html"
                                               (file-relative-name (string-join stack "/")
                                                                   (or (file-name-directory (or path "")) "./")))
                     frag))
            (t target)))))

(defun drgnx-design-site--image-src (target path)
  "The src for the image TARGET written in the page PATH: the file itself,
or its place on GitHub when it is not in docs/design/."
  (let ((href (drgnx-design-site--link target path)))
    (if (string-match "\\`\\(.*\\)/blob/" href)
        (replace-regexp-in-string "\\`https://github.com/\\([^/]+/[^/]+\\)/blob/" "https://raw.githubusercontent.com/\\1/" href)
      href)))

(defun drgnx-design-site--inline (text path)
  "TEXT's inline Markdown as HTML: code, images, links, strong and emphasis."
  (let ((spans nil))
    ;; code spans first, so nothing inside them is read as markup
    (setq text (replace-regexp-in-string
                "`\\([^`]+\\)`"
                (lambda (m)
                  (push (format "<code>%s</code>" (drgnx-design-site--escape (substring m 1 -1))) spans)
                  (format "\x01%d\x02" (1- (length spans))))
                text t t))
    (setq text (drgnx-design-site--escape text))
    (setq text (replace-regexp-in-string
                "!\\[\\([^]]*\\)\\](\\([^)]+\\))"
                (lambda (m)
                  (save-match-data
                    (string-match "!\\[\\([^]]*\\)\\](\\([^)]+\\))" m)
                    (let ((alt (match-string 1 m)) (target (match-string 2 m)))
                      (format "<img src=\"%s\" alt=\"%s\">" (drgnx-design-site--image-src target path) alt))))
                text t t))
    (setq text (replace-regexp-in-string
                "\\[\\([^]]+\\)\\](\\([^)]+\\))"
                (lambda (m)
                  (save-match-data
                    (string-match "\\[\\([^]]+\\)\\](\\([^)]+\\))" m)
                    (let ((label (match-string 1 m)) (target (match-string 2 m)))
                      (format "<a href=\"%s\">%s</a>" (drgnx-design-site--link target path) label))))
                text t t))
    (setq text (replace-regexp-in-string "\\*\\*\\([^*]+\\)\\*\\*" "<strong>\\1</strong>" text))
    (setq text (replace-regexp-in-string "\\*\\([^* ][^*]*\\)\\*" "<em>\\1</em>" text))
    (replace-regexp-in-string "\x01\\([0-9]+\\)\x02"
                              (lambda (m) (nth (- (length spans) 1 (string-to-number (substring m 1 -1))) spans))
                              text t t)))

(defun drgnx-design-site--cells (line)
  "The cells of the table row LINE: split at the bars that are not inside a code span."
  (let ((cells nil) (cur "") (in-code nil))
    (dolist (c (string-to-list (string-trim (string-trim line "|[ \t]*" "[ \t]*|"))))
      (cond ((eq c ?`) (setq in-code (not in-code)) (setq cur (concat cur "`")))
            ((and (eq c ?|) (not in-code)) (push (string-trim cur) cells) (setq cur ""))
            (t (setq cur (concat cur (string c))))))
    (push (string-trim cur) cells)
    (nreverse cells)))

(defun drgnx-design-site-markdown (md &optional path)
  "MD (Markdown, the subset the design pages use) as HTML.  PATH is the page's path under docs/design/, for its links."
  (let ((lines (split-string md "\n")) (out nil))
    (while lines
      (let ((line (car lines)))
        (cond
         ((string-blank-p line) (pop lines))
         ((string-match-p "\\`<!--.*-->\\'" (string-trim line)) (pop lines))
         ((string-prefix-p "```" line)
          (pop lines)
          (let ((code nil))
            (while (and lines (not (string-prefix-p "```" (car lines)))) (push (pop lines) code))
            (pop lines)
            (push (format "<pre><code>%s</code></pre>"
                          (drgnx-design-site--escape (apply #'concat (mapcar (lambda (l) (concat l "\n")) (nreverse code)))))
                  out)))
         ((string-match "\\`\\(#+\\) \\(.*\\)\\'" line)
          (let ((n (length (match-string 1 line))) (title (match-string 2 line)))
            (push (format "<h%d id=\"%s\">%s</h%d>" n (drgnx-design-site--slug title)
                          (drgnx-design-site--inline title path) n)
                  out))
          (pop lines))
         ((and (string-prefix-p "|" line) (cdr lines) (string-match-p "\\`|[-| :]+|\\'" (cadr lines)))
          (let ((head (drgnx-design-site--cells (pop lines))) rows)
            (pop lines)
            (while (and lines (string-prefix-p "|" (car lines))) (push (drgnx-design-site--cells (pop lines)) rows))
            (push (concat "<table>\n<thead>\n<tr>"
                          (mapconcat (lambda (c) (format "<th>%s</th>" (drgnx-design-site--inline c path))) head "")
                          "</tr>\n</thead>\n<tbody>\n"
                          (mapconcat (lambda (r)
                                       (concat "<tr>" (mapconcat (lambda (c) (format "<td>%s</td>" (drgnx-design-site--inline c path)))
                                                                 r "")
                                               "</tr>\n"))
                                     (nreverse rows) "")
                          "</tbody>\n</table>")
                  out)))
         ((string-match "\\`\\(-\\|[0-9]+\\.\\) " line)
          (let ((tag (if (equal (match-string 1 line) "-") "ul" "ol")) (items nil))
            (while (and lines (or (string-match "\\`\\(-\\|[0-9]+\\.\\) \\(.*\\)\\'" (car lines))
                                  (and items (string-match "\\`  +\\(.+\\)\\'" (car lines)))))
              (if (string-match "\\`\\(?:-\\|[0-9]+\\.\\) \\(.*\\)\\'" (car lines))
                  (push (match-string 1 (car lines)) items)
                (setcar items (concat (car items) " " (string-trim (car lines)))))
              (pop lines))
            (push (format "<%s>\n%s</%s>" tag
                          (mapconcat (lambda (i) (format "<li>%s</li>\n" (drgnx-design-site--inline i path))) (nreverse items) "")
                          tag)
                  out)))
         (t
          (let ((para nil))
            (while (and lines (not (string-blank-p (car lines)))
                        (not (string-match-p "\\`\\(#+ \\|```\\|-  *\\|- \\|[0-9]+\\. \\||\\)" (car lines))))
              (push (pop lines) para))
            (when (null para) (push (pop lines) para))
            (push (format "<p>%s</p>" (drgnx-design-site--inline (string-join (nreverse para) " ") path)) out))))))
    (concat (string-join (nreverse out) "\n") "\n")))

;;;; The site

(defun drgnx-design-site--read (file)
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
    (buffer-string)))

(defun drgnx-design-site--title (md)
  "The text of MD's first heading."
  (if (string-match "^# \\(.*\\)$" md) (string-trim (replace-regexp-in-string "`" "" (match-string 1 md))) "drgnx"))

(defun drgnx-design-site--pages (root)
  "The Markdown pages under ROOT as relative paths, the navigation's order first."
  (let* ((all (mapcar (lambda (f) (file-relative-name f root)) (directory-files-recursively root "\\.md\\'")))
         (listed (seq-filter (lambda (p) (member p all)) drgnx-design-site-nav-order))
         (rest (sort (seq-remove (lambda (p) (member p listed)) all) #'string<))
         (components (seq-filter (lambda (p) (string-prefix-p "components/" p)) rest)))
    (append (seq-take-while (lambda (p) (not (equal p "components/index.md"))) listed)
            (and (member "components/index.md" listed) '("components/index.md"))
            components
            (cdr (member "components/index.md" listed))
            (and (not (member "components/index.md" listed)) listed)
            (seq-remove (lambda (p) (string-prefix-p "components/" p)) rest))))

(defun drgnx-design-site--layout (path title body pages titles)
  "The HTML page for PATH with TITLE and BODY; PAGES and TITLES make the navigation."
  (let* ((depth (1- (length (split-string path "/"))))
         (up (apply #'concat (make-list depth "../")))
         (nav (mapconcat
               (lambda (p)
                 (let ((html (replace-regexp-in-string "\\.md\\'" ".html" p)))
                   (format "<li class=\"%s\"><a href=\"%s%s\">%s</a></li>"
                           (concat (if (string-prefix-p "components/" p) "sub" "top")
                                   (if (equal p path) " here" ""))
                           up html (drgnx-design-site--escape (cdr (assoc p titles))))))
               pages "\n")))
    (concat "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            (format "<title>%s - drgnx design system</title>\n" (drgnx-design-site--escape title))
            (format "<link rel=\"stylesheet\" href=\"%stokens.css\">\n<link rel=\"stylesheet\" href=\"%ssite.css\">\n" up up)
            "<script>try{var t=localStorage.getItem('drgnx-design-theme');if(t)document.documentElement.dataset.theme=t}catch(e){}</script>\n"
            "</head>\n<body>\n<nav>\n<p class=\"brand\">drgnx design system</p>\n<ul>\n" nav "\n</ul>\n"
            "<label class=\"theme\">Theme <select onchange=\"var v=this.value;if(v){document.documentElement.dataset.theme=v}else{delete document.documentElement.dataset.theme}"
            "try{localStorage.setItem('drgnx-design-theme',v)}catch(e){}\">"
            "<option value=\"\">Follow the system</option><option value=\"dark\">Dark</option>"
            "<option value=\"light\">Light</option><option value=\"hc\">High contrast</option></select></label>\n</nav>\n"
            "<main>\n" body "</main>\n"
            "<script>try{var s=document.querySelector('select'),t=localStorage.getItem('drgnx-design-theme');if(s&&t)s.value=t}catch(e){}</script>\n"
            "</body>\n</html>\n")))

(defun drgnx-design-site-build (out &optional root)
  "Build the site into OUT from ROOT (default the checkout's docs/design/)."
  (let* ((root (file-name-as-directory (or root (expand-file-name "docs/design/" drgnx-dir))))
         (pages (drgnx-design-site--pages root))
         (texts (mapcar (lambda (p) (cons p (drgnx-design-site--read (expand-file-name p root)))) pages))
         (titles (mapcar (lambda (c) (cons (car c) (drgnx-design-site--title (cdr c)))) texts)))
    (make-directory out t)
    (dolist (c texts)
      (let* ((path (car c)) (file (expand-file-name (replace-regexp-in-string "\\.md\\'" ".html" path) out)))
        (make-directory (file-name-directory file) t)
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (drgnx-design-site--layout path (cdr (assoc path titles))
                                                   (drgnx-design-site-markdown (cdr c) path) pages titles)
                        nil file nil 'silent))))
    (dolist (f (append (directory-files root nil "\\.css\\'")
                       (mapcar (lambda (f) (file-relative-name f root))
                               (directory-files-recursively (expand-file-name "img" root) "\\.\\(svg\\|png\\)\\'"))))
      (make-directory (file-name-directory (expand-file-name f out)) t)
      (copy-file (expand-file-name f root) (expand-file-name f out) t))
    (write-region "" nil (expand-file-name ".nojekyll" out) nil 'silent)
    pages))

(provide 'drgnx-design-site)
;;; drgnx-design-site.el ends here
