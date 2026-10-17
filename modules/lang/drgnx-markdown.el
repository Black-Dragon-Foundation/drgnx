;;; drgnx-markdown.el --- Module lang/markdown: Markdown with a preview and Mermaid diagrams -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Markdown files open in markdown-mode (READMEs as GitHub Flavored Markdown), code blocks highlighted in their own
;; language, math marked.  Markdown: Open Preview renders the buffer beside it — through pandoc (or cmark, markdown)
;; when installed, else markdown-mode's view — and again after each save.  ```mermaid blocks become pictures when
;; mmdc is installed: drawn in the background (a durable job), kept in drgnx's cache by their text's hash; until
;; then they show as code.  See docs/guide/editing.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-jobs)

(defvar markdown-fontify-code-blocks-natively)
(defvar markdown-enable-math)
(defvar markdown-header-scaling)
(defvar markdown-display-remote-images)
(declare-function markdown-view-mode "markdown-mode")
(declare-function shr-insert-document "shr")

(defvar drgnx-markdown-programs
  '(("pandoc" "-f" "gfm" "-t" "html") ("cmark-gfm" "--extension" "table" "--extension" "strikethrough") ("cmark") ("markdown"))
  "Markdown-to-HTML programs, the first installed one renders previews (PROGRAM ARGS…, reading standard input).")

(defvar-local drgnx-markdown--source nil "A preview's Markdown buffer.")
(defvar drgnx-markdown--drawing (make-hash-table :test #'equal) "Diagram hashes being drawn (this session).")

(defun drgnx-markdown--program () (seq-find (lambda (p) (executable-find (car p))) drgnx-markdown-programs))

(defun drgnx-markdown--diagram-dir () (expand-file-name "mermaid/" (drgnx-cache-dir)))

(defun drgnx-markdown--draw (code hash)
  "Draw the Mermaid CODE (its HASH) into the cache in the background (once)."
  (unless (gethash hash drgnx-markdown--drawing)
    (puthash hash t drgnx-markdown--drawing)
    (let* ((dir (drgnx-markdown--diagram-dir)) (mmd (expand-file-name (concat hash ".mmd") dir))
           (png (expand-file-name (concat hash ".png") dir)))
      (make-directory dir t)
      (write-region code nil mmd nil 'silent)
      (drgnx-markdown--watch (drgnx-jobs-start "mermaid" (list "mmdc" "-i" mmd "-o" png "-b" "transparent")) hash))))

(defun drgnx-markdown--watch (id hash)
  "When job ID ends, the previews are rendered again (looked at every 2 s; never waits)."
  (let ((timer nil))
    (setq timer (run-with-timer 2 2 (lambda ()
                                      (unless (eq (plist-get (drgnx-jobs-get id) :status) 'running)
                                        (cancel-timer timer)
                                        (remhash hash drgnx-markdown--drawing)
                                        (drgnx-markdown--rerender-all)))))))

(defun drgnx-markdown--with-diagrams (text)
  "TEXT with each ```mermaid block whose picture is cached replaced by that picture; the others are drawn in the
background when mmdc is installed, and stay as code meanwhile."
  (if (not (executable-find "mmdc")) text
    (let ((re "^```mermaid[ \t]*\n\\(\\(?:.*\n\\)*?\\)```[ \t]*$") (out "") (start 0))
      (while (string-match re text start)
        (let* ((code (match-string 1 text)) (whole (match-string 0 text)) (beg (match-beginning 0)) (end (match-end 0))
               (hash (secure-hash 'sha1 code)) (png (expand-file-name (concat hash ".png") (drgnx-markdown--diagram-dir))))
          (setq out (concat out (substring text start beg)
                            (if (file-exists-p png) (format "![diagram](%s)" png) (drgnx-markdown--draw code hash) whole))
                start end)))
      (concat out (substring text start)))))

(defun drgnx-markdown--render (src buf)
  "Render the Markdown buffer SRC into the preview buffer BUF."
  (let ((text (with-current-buffer src (drgnx-markdown--with-diagrams (buffer-substring-no-properties (point-min) (point-max)))))
        (prog (and (fboundp 'libxml-parse-html-region) (drgnx-markdown--program)))
        (dir (buffer-local-value 'default-directory src)))
    (with-current-buffer buf
      (let ((inhibit-read-only t) (pt (point)))
        (erase-buffer)
        (setq default-directory dir)                   ; relative pictures and links
        (if (not prog)
            (progn (insert text) (markdown-view-mode))
          (let ((html (with-temp-buffer
                        (insert text)
                        (let ((coding-system-for-read 'utf-8) (coding-system-for-write 'utf-8))
                          (apply #'call-process-region (point-min) (point-max) (car prog) t t nil (cdr prog)))
                        (buffer-string))))
            (special-mode)
            (require 'shr)
            (let ((inhibit-read-only t))
              (shr-insert-document (with-temp-buffer (insert html) (libxml-parse-html-region (point-min) (point-max)))))))
        (setq drgnx-markdown--source src)
        (goto-char (min pt (point-max)))))
    buf))

(defun drgnx-markdown--rerender-all ()
  (dolist (b (buffer-list))
    (let ((src (buffer-local-value 'drgnx-markdown--source b)))
      (when (buffer-live-p src) (drgnx-markdown--render src b)))))

(defun drgnx-markdown--after-save ()
  "The preview follows the saved file (just after the save, never in it)."
  (let ((src (current-buffer)))
    (run-with-idle-timer 0.2 nil (lambda ()
                                   (dolist (b (buffer-list))
                                     (when (eq (buffer-local-value 'drgnx-markdown--source b) src)
                                       (drgnx-markdown--render src b)))))))

(defun drgnx-markdown-preview ()
  "Markdown: Open Preview — this buffer rendered beside it; again after each save.  The preview buffer."
  (interactive)
  (let ((buf (get-buffer-create (format "*markdown preview: %s*" (buffer-name)))))
    (drgnx-markdown--render (current-buffer) buf)
    (add-hook 'after-save-hook #'drgnx-markdown--after-save nil t)
    (when (called-interactively-p 'any) (display-buffer buf '(display-buffer-in-direction (direction . right))))
    buf))

(defun drgnx-markdown--setup ()
  (setq markdown-fontify-code-blocks-natively t
        markdown-enable-math t
        markdown-header-scaling t
        markdown-display-remote-images nil)
  (autoload 'markdown-mode "markdown-mode" nil t)
  (autoload 'gfm-mode "markdown-mode" nil t)
  (add-to-list 'auto-mode-alist '("\\.\\(?:md\\|markdown\\|mkd\\|mdx\\)\\'" . markdown-mode))
  (add-to-list 'auto-mode-alist '("/README\\.md\\'" . gfm-mode)))

(drgnx-module-define 'lang/markdown
                     :doc "Markdown (READMEs as GFM): code blocks in their language, math; a preview, Mermaid diagrams through mmdc."
                     :stage 'startup :packages '(markdown-mode)
                     :setup (lambda ()
                              (drgnx-markdown--setup)
                              (drgnx-command-define 'markdown-preview :category "Markdown" :title "Markdown: Open Preview"
                                                    :command #'drgnx-markdown-preview :doc "This file rendered beside it, after each save")))

(provide 'drgnx-markdown)
;;; drgnx-markdown.el ends here
