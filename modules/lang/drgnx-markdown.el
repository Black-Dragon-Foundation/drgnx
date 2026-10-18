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

(defvar shr-blocked-images)
(declare-function markdown-view-mode "markdown-mode")
(declare-function shr-insert-document "shr")

(defvar drgnx-markdown-programs
  '(("pandoc" "-f" "gfm" "-t" "html") ("cmark-gfm" "--extension" "table" "--extension" "strikethrough") ("cmark") ("markdown"))
  "Markdown-to-HTML programs, the first installed one renders previews (PROGRAM ARGS…, reading standard input).")

(defvar-local drgnx-markdown--source nil "A preview's Markdown buffer.")
(defvar drgnx-markdown--drawing (make-hash-table :test #'equal) "Diagram hashes being drawn (this session).")

(defun drgnx-markdown--program () (seq-find (lambda (p) (executable-find (car p))) drgnx-markdown-programs))

(defun drgnx-markdown--diagram-dir () (expand-file-name "mermaid/" (drgnx-cache-dir)))

(defvar drgnx-markdown--failed (make-hash-table :test #'equal) "Diagram hashes mmdc could not draw (not tried again).")

(defun drgnx-markdown--theme () (if (eq (frame-parameter nil 'background-mode) 'dark) "dark" "default"))

(defun drgnx-markdown--draw (code hash)
  "Draw the Mermaid CODE (its HASH) into the cache in the background (once)."
  (unless (or (gethash hash drgnx-markdown--drawing) (gethash hash drgnx-markdown--failed))
    (puthash hash t drgnx-markdown--drawing)
    (let* ((dir (drgnx-markdown--diagram-dir)) (mmd (expand-file-name (concat hash ".mmd") dir))
           (png (expand-file-name (concat hash ".png") dir)))
      (make-directory dir t)
      (write-region code nil mmd nil 'silent)
      (drgnx-markdown--watch (drgnx-jobs-start "mermaid" (list "mmdc" "-i" mmd "-o" png "-b" "transparent" "-t" (drgnx-markdown--theme)))
                             hash))))

(defun drgnx-markdown--drawn (hash exit)
  "The drawing of HASH ended with EXIT: the previews show it — or, when mmdc failed, it stays code and is not tried again."
  (remhash hash drgnx-markdown--drawing)
  (if (eql exit 0) (drgnx-markdown--rerender-all)
    (puthash hash t drgnx-markdown--failed)
    (message "drgnx: a Mermaid diagram did not draw (Show Job Log: mermaid); it shows as code")))

(defun drgnx-markdown--watch (id hash)
  "When job ID ends: `drgnx-markdown--drawn' (looked at every 2 s; never waits)."
  (let ((timer nil))
    (setq timer (run-with-timer 2 2 (lambda ()
                                      (let ((job (drgnx-jobs-get id)))
                                        (unless (eq (plist-get job :status) 'running)
                                          (cancel-timer timer)
                                          (drgnx-markdown--drawn hash (plist-get job :exit)))))))))

(defun drgnx-markdown--with-diagrams (text)
  "TEXT with each ```mermaid block whose picture is cached replaced by that picture (a file: URL); the others are drawn
in the background when mmdc is installed, and stay as code meanwhile (or for good when mmdc cannot draw them)."
  (if (not (executable-find "mmdc")) text
    (let ((re "^```mermaid[ \t]*\n\\(\\(?:.*\n\\)*?\\)```[ \t]*$") (out "") (start 0) (theme (drgnx-markdown--theme)))
      (while (string-match re text start)
        (let* ((code (match-string 1 text)) (whole (match-string 0 text)) (beg (match-beginning 0)) (end (match-end 0))
               (hash (secure-hash 'sha1 (concat theme "\n" code)))          ; drawn per theme
               (png (expand-file-name (concat hash ".png") (drgnx-markdown--diagram-dir))))
          (setq out (concat out (substring text start beg)
                            (if (file-exists-p png) (format "![diagram](file://%s)" png) (drgnx-markdown--draw code hash) whole))
                start end)))
      (concat out (substring text start)))))

(defvar-local drgnx-markdown--proc nil "A preview's conversion still running.")

(defun drgnx-markdown--insert-html (buf html dir)
  "HTML into the preview BUF: relative pictures from DIR, local files only (no picture from the network)."
  (with-current-buffer buf
    (let ((inhibit-read-only t) (pt (point)) (shr-blocked-images "\\`https?:"))
      (erase-buffer)
      (unless (derived-mode-p 'special-mode) (special-mode))
      (require 'shr)
      (shr-insert-document (with-temp-buffer
                             (insert (format "<html><head><base href=\"file://%s\"></head><body>" (file-name-as-directory dir)) html "</body></html>")
                             (libxml-parse-html-region (point-min) (point-max))))
      (goto-char (min pt (point-max))))))

(defun drgnx-markdown--render (src buf)
  "Render the Markdown buffer SRC into the preview buffer BUF — through the program in the background (a newer render
replaces one still running), never waiting for it."
  (let ((text (with-current-buffer src (drgnx-markdown--with-diagrams (buffer-substring-no-properties (point-min) (point-max)))))
        (prog (and (fboundp 'libxml-parse-html-region) (drgnx-markdown--program)))
        (dir (buffer-local-value 'default-directory src)))
    (with-current-buffer buf
      (setq default-directory dir)
      (when (process-live-p drgnx-markdown--proc) (delete-process drgnx-markdown--proc))
      (if (not prog)
          (let ((inhibit-read-only t)) (erase-buffer) (insert text) (markdown-view-mode))
        (let* ((out (generate-new-buffer " *markdown html*" t))
               (err (generate-new-buffer " *markdown errors*" t))
               (p (make-process :name "markdown-preview" :buffer out :stderr err :command prog :noquery t
                                :connection-type 'pipe :coding 'utf-8
                                :sentinel (lambda (p _event)
                                            (unless (process-live-p p)
                                              (when (and (eql (process-exit-status p) 0) (buffer-live-p buf))
                                                (drgnx-markdown--insert-html buf (with-current-buffer out (buffer-string)) dir))
                                              (kill-buffer out)
                                              (when-let* ((ep (get-buffer-process err))) (delete-process ep))
                                              (kill-buffer err))))))
          (setq drgnx-markdown--proc p)
          (process-send-string p text)
          (process-send-eof p)))
      (setq drgnx-markdown--source src))
    buf))

(defun drgnx-markdown--rerender-all ()
  (dolist (b (buffer-list))
    (let ((src (buffer-local-value 'drgnx-markdown--source b)))
      (when (buffer-live-p src) (drgnx-markdown--render src b)))))

(defvar drgnx-markdown--pending nil "Sources saved since the previews were last rendered.")

(defun drgnx-markdown--after-save ()
  "The preview follows the saved file: just after the save, never in it; saves in a row render once."
  (unless drgnx-markdown--pending
    (run-with-idle-timer 0.2 nil (lambda ()
                                   (let ((sources drgnx-markdown--pending))
                                     (setq drgnx-markdown--pending nil)
                                     (dolist (b (buffer-list))
                                       (when (memq (buffer-local-value 'drgnx-markdown--source b) sources)
                                         (drgnx-markdown--render (buffer-local-value 'drgnx-markdown--source b) b)))))))
  (cl-pushnew (current-buffer) drgnx-markdown--pending))

(defun drgnx-markdown-preview ()
  "Markdown: Open Preview — this buffer rendered beside it; again after each save.  The preview buffer."
  (interactive)
  (let ((buf (get-buffer-create (format "*markdown preview: %s*" (buffer-name)))))
    (drgnx-markdown--render (current-buffer) buf)
    (add-hook 'after-save-hook #'drgnx-markdown--after-save nil t)
    (when (called-interactively-p 'any) (display-buffer buf '(display-buffer-in-direction (direction . right))))
    buf))

(defun drgnx-markdown--set-option (var value)
  "Set the option VAR to VALUE for as long as the module is on, unless something set it already.
The module sets options when their library loads, after the user's config.el: a value that differs from the standard
one is the user's (or a theme's, or Customize's) and wins.  The module's undo puts back what it replaced."
  (let ((standard (get var 'standard-value)))
    (when (or (not (default-boundp var)) (null standard)
              (equal (default-value var) (eval (car standard) t)))
      (drgnx-module-set var value))))

(defun drgnx-markdown--setup ()
  ;; Set once markdown-mode is loaded: set before, the undo would leave the options unbound under the package
  (eval-after-load 'markdown-mode
    (drgnx-modules-with-owner
      (drgnx-markdown--set-option 'markdown-fontify-code-blocks-natively t)
      (drgnx-markdown--set-option 'markdown-enable-math t)
      (drgnx-markdown--set-option 'markdown-header-scaling t)
      (drgnx-markdown--set-option 'markdown-display-remote-images nil)))
  (autoload 'markdown-mode "markdown-mode" nil t)
  (autoload 'gfm-mode "markdown-mode" nil t)
  (add-to-list 'auto-mode-alist '("\\.\\(?:md\\|markdown\\|mkd\\|mdx\\)\\'" . markdown-mode))
  (add-to-list 'auto-mode-alist '("/README\\.md\\'" . gfm-mode)))

(defun drgnx-markdown--define-command ()
  "Register Markdown: Open Preview; its key (any profile's) binds in markdown-mode's keymap only."
  (drgnx-command-define 'markdown-preview :category "Markdown" :title "Markdown: Open Preview"
                        :command #'drgnx-markdown-preview :map '(markdown-mode . markdown-mode-map)
                        :doc "This file rendered beside it, after each save"))

(drgnx-module-define 'lang/markdown
                     :doc "Markdown (READMEs as GFM): code blocks in their language, math; a preview, Mermaid diagrams through mmdc."
                     :stage 'startup :packages '(markdown-mode)
                     :setup (lambda ()
                              (drgnx-markdown--setup)
                              (drgnx-markdown--define-command)))

(provide 'drgnx-markdown)
;;; drgnx-markdown.el ends here
