;;; drgnx-replace.el --- Module tools/replace: search and replace across files, text or symbol -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One engine for VS Code's Search & Replace.  Text: ripgrep when installed, else git grep in a repository, else
;; grep, in the background and cancellable; matches stream in batches.  Symbol: the language server's rename edits
;; (asked for with a placeholder name, never applied by the server), as the same matches.  Replacing checks every
;; match against the file as it is now (its buffer when visited) and skips the stale ones; each file is one change
;; group, saved, so one Undo puts every file back.  See docs/guide/replace.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)
(require 'drgnx-modules)

(declare-function eglot-current-server "eglot")
(declare-function eglot-server-capable "eglot")
(declare-function eglot--TextDocumentPositionParams "eglot")
(declare-function eglot-move-to-utf-16-linepos "eglot")
(declare-function jsonrpc-request "jsonrpc")
(defvar eglot-move-to-linepos-function)

(defvar drgnx-replace-context-chars 80 "Characters of the line kept before and after a match (:before, :after).")

(defconst drgnx-replace--rename-suffix "_drgnx_rename"
  "Appended to the symbol at point to make the placeholder name a rename is asked for with.")

(defvar drgnx-replace--search-proc nil "The text search still running (a newer one replaces it).")

(defvar drgnx-replace--syntax
  (let ((st (copy-syntax-table (standard-syntax-table)))) (modify-syntax-entry ?_ "w" st) st)
  "Matching in Emacs (fallback columns, regexp groups): `_' is a word character, as in ripgrep's \\w and \\b.")

;;;; Patterns

(defun drgnx-replace--globs (globs)
  "GLOBS as a list: a list as it is, a string split at commas."
  (if (stringp globs) (split-string globs "," t "[ \t\n]+") globs))

(defun drgnx-replace--emacs-regexp (re)
  "RE, a regexp as ripgrep reads it (groups `(a|b)', `{2}', `\\d', `\\s'), in Emacs syntax."
  (let ((i 0) (n (length re)) (out nil) (in-class nil))
    (while (< i n)
      (let ((c (aref re i)) (d (and (< (1+ i) n) (aref re (1+ i)))))
        (cond
         ((and (eq c ?\\) d)
          (setq i (1+ i))
          (push (if in-class
                    (pcase d (?d "0-9") (?s "[:space:]") (?w "[:alnum:]_") (?n "\n") (?t "\t") (_ (string d)))
                  (pcase d
                    (?d "[0-9]") (?D "[^0-9]") (?s "[[:space:]]") (?S "[^[:space:]]") (?n "\n") (?t "\t")
                    ((or ?w ?W ?b ?B) (string ?\\ d))
                    (_ (regexp-quote (string d)))))
                out))
         (in-class (when (eq c ?\]) (setq in-class nil)) (push (string c) out))
         ((eq c ?\[)
          (setq in-class t)
          (push "[" out)
          (when (eq d ?^) (push "^" out) (setq i (1+ i)))
          (when (and (< (1+ i) n) (eq (aref re (1+ i)) ?\])) (push "]" out) (setq i (1+ i))))
         ((and (eq c ?\() (eq d ??) (< (+ i 2) n) (eq (aref re (+ i 2)) ?:))
          (push "\\(?:" out) (setq i (+ i 2)))
         ((memq c '(?\( ?\) ?| ?{ ?})) (push (string ?\\ c) out))
         (t (push (string c) out))))
      (setq i (1+ i)))
    (apply #'concat (nreverse out))))

(defun drgnx-replace--line-regexp (query)
  "QUERY's pattern in Emacs syntax, whole words only when asked."
  (let* ((text (plist-get query :text))
         (re (if (plist-get query :regexp) (drgnx-replace--emacs-regexp text) (regexp-quote text))))
    (if (plist-get query :word) (concat "\\b\\(?:" re "\\)\\b") re)))

(defun drgnx-replace-new-text (match new)
  "What MATCH becomes when replaced by NEW.
A text match: NEW; after a regexp search NEW's \\1… are MATCH's groups (nil when the regexp no longer matches
MATCH's text).  A symbol match: the server's edit with NEW in place of the placeholder name."
  (cond ((plist-get match :placeholder)
         (string-replace (plist-get match :placeholder) new (plist-get match :new)))
        ((plist-get match :pattern)
         (let ((case-fold-search (not (plist-get match :case))) (text (plist-get match :text)))
           (with-syntax-table drgnx-replace--syntax
             (when (string-match (concat "\\`\\(?:" (plist-get match :pattern) "\\)\\'") text)
               (replace-match new t nil text)))))
        (t new)))

;;;; Text search

(defun drgnx-replace--match (file line text col end &optional extra)
  "The match in FILE's LINE (1-based), whose text TEXT holds it from character COL to END; EXTRA appended."
  (let ((k drgnx-replace-context-chars))
    (append (list :file file :line line :col col :end end :text (substring text col end)
                  :before (substring text (max 0 (- col k)) col)
                  :after (substring text end (min (length text) (+ end k))))
            extra)))

(defun drgnx-replace--rg-text (x)
  "An `rg --json' text object: text, or bytes (base64) decoded as UTF-8."
  (or (plist-get x :text) (decode-coding-string (base64-decode-string (plist-get x :bytes)) 'utf-8)))

(defun drgnx-replace--rg-line (line root extra)
  "The matches in LINE of `rg --json' output (paths relative to ROOT)."
  (when (string-prefix-p "{\"type\":\"match\"" line)
    (let* ((d (plist-get (json-parse-string line :object-type 'plist :null-object nil :false-object nil) :data))
           (file (expand-file-name (drgnx-replace--rg-text (plist-get d :path)) root))
           (text (string-trim-right (drgnx-replace--rg-text (plist-get d :lines)) "\r?\n"))
           (bytes (and (/= (length text) (string-bytes text)) (encode-coding-string text 'utf-8 t)))
           (col (lambda (b)                     ; rg counts bytes, Emacs characters
                  (if bytes (length (decode-coding-string (substring bytes 0 (min b (length bytes))) 'utf-8))
                    (min b (length text))))))
      (mapcar (lambda (s)
                (drgnx-replace--match file (plist-get d :line_number) text
                                      (funcall col (plist-get s :start)) (funcall col (plist-get s :end)) extra))
              (plist-get d :submatches)))))

(defun drgnx-replace--grep-line (line root re case extra)
  "The matches in LINE of `git grep -z -n' or `grep -Z -n' output: each of RE (Emacs syntax) in the line's text."
  (when (string-match "\\`\\([^\0]+\\)\0\\([0-9]+\\)[\0:]" line)
    (let ((file (expand-file-name (match-string 1 line) root))
          (n (string-to-number (match-string 2 line)))
          (text (string-trim-right (substring line (match-end 0)) "\r"))
          (case-fold-search (not case))
          (start 0) (out nil))
      (with-syntax-table drgnx-replace--syntax
        (while (and (<= start (length text)) (string-match re text start))
          (push (drgnx-replace--match file n text (match-beginning 0) (match-end 0) extra) out)
          (setq start (max (match-end 0) (1+ (match-beginning 0))))))
      (nreverse out))))

(defun drgnx-replace--backend (root)
  "`rg' when installed, else `git' when ROOT is in a repository, else `grep'."
  (cond ((executable-find "rg") 'rg)
        ((and (executable-find "git") (locate-dominating-file root ".git")) 'git)
        (t 'grep)))

(defun drgnx-replace--git-glob (glob)
  "GLOB as a git pathspec glob: one without a slash matches at any depth, as in ripgrep."
  (if (string-search "/" glob) glob (concat "**/" glob)))

(defun drgnx-replace--command (backend query)
  "The command line searching QUERY with BACKEND."
  (let* ((text (plist-get query :text)) (file (plist-get query :file))
         (inc (unless file (drgnx-replace--globs (plist-get query :include))))
         (exc (unless file (drgnx-replace--globs (plist-get query :exclude))))
         (re (plist-get query :regexp)) (case (plist-get query :case)) (word (plist-get query :word)))
    (pcase backend
      ('rg `("rg" "--json" "--no-config" ,@(unless re '("-F")) ,(if case "-s" "-i") ,@(when word '("-w"))
             ,@(mapcar (lambda (g) (concat "--glob=" g)) inc) ,@(mapcar (lambda (g) (concat "--glob=!" g)) exc)
             "-e" ,text "--" ,(or file ".")))
      ('git `("git" "-c" "core.quotePath=false" "grep" "-n" "-z" "-I" "--untracked" "--no-color" ,(if re "-E" "-F")
              ,@(unless case '("-i")) ,@(when word '("-w")) "-e" ,text "--"
              ,@(if file (list file)
                  (append (mapcar (lambda (g) (concat ":(glob)" (drgnx-replace--git-glob g))) inc)
                          (mapcar (lambda (g) (concat ":(exclude,glob)" (drgnx-replace--git-glob g))) exc)))))
      ('grep `("grep" ,(if file "-H" "-r") "-n" "-Z" "-I" "--color=never" ,(if re "-E" "-F")
               ,@(unless case '("-i")) ,@(when word '("-w")) "--exclude-dir=.git"
               ,@(mapcar (lambda (g) (concat "--include=" g)) inc) ,@(mapcar (lambda (g) (concat "--exclude=" g)) exc)
               "-e" ,text "--" ,(or file "."))))))

(defun drgnx-replace--cleanup (proc)
  "Kill PROC's stderr buffer and its process."
  (let ((err (process-get proc 'drgnx-replace-err)))
    (when (buffer-live-p err)
      (when-let* ((ep (get-buffer-process err))) (delete-process ep))
      (kill-buffer err))))

(defun drgnx-replace--output (proc chunk parse callback)
  "PROC's output CHUNK: its complete lines PARSEd, their matches sent to CALLBACK as one batch."
  (unless (process-get proc 'drgnx-replace-cancelled)
    (let* ((s (concat (process-get proc 'drgnx-replace-rest) chunk))
           (i (cl-position ?\n s :from-end t)))
      (if (null i)
          (process-put proc 'drgnx-replace-rest s)
        (process-put proc 'drgnx-replace-rest (substring s (1+ i)))
        (when-let* ((ms (mapcan parse (split-string (substring s 0 i) "\n" t))))
          (funcall callback ms))))))

(defun drgnx-replace--finished (proc parse callback)
  "PROC ended: its last line PARSEd, then CALLBACK gets (:error REASON) when it failed, and :done."
  (unless (process-live-p proc)
    (unless (process-get proc 'drgnx-replace-cancelled)
      (let ((rest (process-get proc 'drgnx-replace-rest)))
        (when (> (length rest) 0)
          (process-put proc 'drgnx-replace-rest nil)
          (when-let* ((ms (funcall parse rest))) (funcall callback ms))))
      (let ((code (process-exit-status proc)))
        (unless (memq code '(0 1))              ; 1: nothing found
          (let* ((err (process-get proc 'drgnx-replace-err))
                 (msg (if (buffer-live-p err) (string-trim (with-current-buffer err (buffer-string))) "")))
            (funcall callback (list :error (if (string-empty-p msg)
                                               (format "%s exited with code %s" (car (process-command proc)) code)
                                             msg)))))
        (funcall callback :done)))
    (when (eq proc drgnx-replace--search-proc) (setq drgnx-replace--search-proc nil))
    (drgnx-replace--cleanup proc)))

(defun drgnx-replace-search (query callback)
  "Search the files for QUERY in the background; a handle for `drgnx-replace-cancel' (nil when nothing runs).
QUERY: (:root DIR :file FILE-or-nil :text S :case BOOL :word BOOL :regexp BOOL :include GLOBS :exclude GLOBS).
:file limits the search to that file (globs then do not apply); GLOBS is a list or a comma-separated string.
:case nil ignores case.  ripgrep runs when installed, else git grep in a repository, else grep.
CALLBACK gets batches of matches, each (:file ABSOLUTE :line N :col C :end E :text S :before S :after S) — LINE
from 1, COL and END characters of the line from 0 — and last :done, just after (:error REASON) when it failed.
A regexp search's matches also carry :pattern (the regexp in Emacs syntax) and :case.  A newer search stops
this one; a stopped search calls CALLBACK no more."
  (drgnx-replace-cancel drgnx-replace--search-proc)
  (if (string-empty-p (or (plist-get query :text) ""))
      (progn (funcall callback :done) nil)
    (let* ((root (file-name-as-directory (expand-file-name (plist-get query :root))))
           (default-directory root)
           (backend (drgnx-replace--backend root))
           (extra (when (plist-get query :regexp)
                    (list :pattern (drgnx-replace--emacs-regexp (plist-get query :text)) :case (plist-get query :case))))
           (parse (if (eq backend 'rg)
                      (lambda (l) (drgnx-replace--rg-line l root extra))
                    (let ((re (drgnx-replace--line-regexp query)) (case (plist-get query :case)))
                      (lambda (l) (drgnx-replace--grep-line l root re case extra)))))
           (err (generate-new-buffer " *drgnx-replace err*" t))
           (proc (condition-case e
                     (make-process :name (format "drgnx-replace-%s" backend) :buffer nil :stderr err :noquery t
                                   :connection-type 'pipe :coding 'utf-8-unix
                                   :command (drgnx-replace--command backend query)
                                   :filter (lambda (p chunk) (drgnx-replace--output p chunk parse callback))
                                   :sentinel (lambda (p _event) (drgnx-replace--finished p parse callback)))
                   (error (kill-buffer err)
                          (funcall callback (list :error (error-message-string e)))
                          (funcall callback :done)
                          nil))))
      (when proc
        (process-put proc 'drgnx-replace-err err)
        (process-send-eof proc)
        (setq drgnx-replace--search-proc proc)))))

(defun drgnx-replace-cancel (handle)
  "Stop the search HANDLE (from `drgnx-replace-search'); its callback gets nothing more."
  (when (processp handle)
    (process-put handle 'drgnx-replace-cancelled t)
    (when (process-live-p handle) (delete-process handle))
    (when (eq handle drgnx-replace--search-proc) (setq drgnx-replace--search-proc nil))
    (drgnx-replace--cleanup handle)))

;;;; Symbol edits

(defun drgnx-replace--uri-path (uri)
  "URI as a file name (a file: URI on this buffer's host)."
  (let ((url (url-generic-parse-url uri)))
    (if (not (equal (url-type url) "file"))
        uri
      (let ((path (decode-coding-string (url-unhex-string (url-filename url)) 'utf-8)))
        (when (string-match-p "\\`/[A-Za-z]:" path) (setq path (substring path 1))) ; file:///C:/…
        (concat (file-remote-p default-directory) path)))))

(defun drgnx-replace--lsp-point (pos linepos)
  "The point of LSP position POS (line from 0, character as LINEPOS counts it) in this buffer."
  (goto-char (point-min))
  (forward-line (plist-get pos :line))
  (unless (eobp) (funcall linepos (plist-get pos :character)))
  (point))

(defun drgnx-replace--file-edits (file edits linepos placeholder)
  "The match plists of FILE's LSP text EDITS (positions counted by LINEPOS), read from its buffer when visited."
  (let ((buf (find-buffer-visiting file)) (k drgnx-replace-context-chars) (out nil))
    (with-temp-buffer
      (if buf
          (insert (with-current-buffer buf
                    (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max)))))
        (insert-file-contents file))
      (seq-doseq (e edits)
        (let* ((r (plist-get e :range))
               (beg (drgnx-replace--lsp-point (plist-get r :start) linepos))
               (end (drgnx-replace--lsp-point (plist-get r :end) linepos))
               (bol (progn (goto-char beg) (line-beginning-position)))
               (line (line-number-at-pos beg))
               (end-bol (progn (goto-char end) (line-beginning-position)))
               (end-eol (line-end-position)))
          (push (list :file file :line line :col (- beg bol) :end (- end end-bol)
                      :text (buffer-substring-no-properties beg end)
                      :before (buffer-substring-no-properties (max bol (- beg k)) beg)
                      :after (buffer-substring-no-properties end (min end-eol (+ end k)))
                      :new (plist-get e :newText) :placeholder placeholder)
                out))))
    (nreverse out)))

(defun drgnx-replace--workspace-edit (edit placeholder)
  "The text edits of WorkspaceEdit EDIT as match plists; `documentChanges' is preferred over `changes'.
Resource operations (create, rename, delete a file) are not text edits and are left out."
  (let ((linepos (if (boundp 'eglot-move-to-linepos-function) eglot-move-to-linepos-function
                   #'eglot-move-to-utf-16-linepos))
        (per-file nil))
    (if-let* ((dc (plist-get edit :documentChanges)))
        (seq-doseq (c dc)
          (when-let* ((td (plist-get c :textDocument)))
            (push (cons (plist-get td :uri) (plist-get c :edits)) per-file)))
      (cl-loop for (uri edits) on (plist-get edit :changes) by #'cddr
               do (push (cons (if (keywordp uri) (substring (symbol-name uri) 1) uri) edits) per-file)))
    (mapcan (lambda (pair)
              (drgnx-replace--file-edits (drgnx-replace--uri-path (car pair)) (cdr pair) linepos placeholder))
            (nreverse per-file))))

(defun drgnx-replace--error-message (e)
  "Error E's message; a JSON-RPC error's own message."
  (or (and (eq (car e) 'jsonrpc-error) (alist-get 'jsonrpc-error-message (seq-filter #'consp (cdr e))))
      (error-message-string e)))

(defun drgnx-replace-symbol-edits (callback)
  "Ask this buffer's language server how to rename the symbol at point; never apply it.
CALLBACK gets the edits as one batch of matches (as `drgnx-replace-search' sends, with :new, the server's text
holding :placeholder for the new name; see `drgnx-replace-new-text'), then :done.  Without a server, with one
that cannot rename, or when it refuses, CALLBACK gets (:error REASON), then :done."
  (let* ((server (and (featurep 'eglot) (eglot-current-server)))
         (placeholder (concat (or (thing-at-point 'symbol t) "x") drgnx-replace--rename-suffix))
         (result
          (cond
           ((not server) '(:error "No language server for this buffer"))
           ((not (eglot-server-capable :renameProvider)) '(:error "The language server cannot rename"))
           ((not buffer-file-name) '(:error "This buffer has no file"))
           (t (condition-case e
                  (drgnx-replace--workspace-edit
                   (jsonrpc-request server :textDocument/rename
                                    (append (eglot--TextDocumentPositionParams) (list :newName placeholder)))
                   placeholder)
                (error (list :error (drgnx-replace--error-message e))))))))
    (when result (funcall callback result))
    (funcall callback :done)
    nil))

;;;; Applying and undoing

(defun drgnx-replace--skip (m why)
  "Match M, skipped because of WHY."
  (append m (list :reason why)))

(defun drgnx-replace--live-pos (m)
  "Where match M's text starts in this buffer, when it is still there."
  (save-excursion
    (goto-char (point-min))
    (when (zerop (forward-line (1- (plist-get m :line))))
      (let ((pos (+ (point) (plist-get m :col))) (text (plist-get m :text)))
        (when (and (<= pos (line-end-position)) (<= (+ pos (length text)) (point-max))
                   (string= text (buffer-substring-no-properties pos (+ pos (length text)))))
          pos)))))

(defun drgnx-replace--apply-file (file ms new)
  "Replace FILE's matches MS by NEW in one change group, saved: (WRITTEN SKIPPED UNDO-ENTRY-or-nil)."
  (let ((buf (find-buffer-visiting file)))
    (cond
     ((not (file-exists-p file))
      (list 0 (mapcar (lambda (m) (drgnx-replace--skip m "the file is gone")) ms) nil))
     ((and buf (buffer-modified-p buf) (not (verify-visited-file-modtime buf)))
      (list 0 (mapcar (lambda (m) (drgnx-replace--skip m "changed on disk and in its buffer")) ms) nil))
     (t
      (when (and buf (not (verify-visited-file-modtime buf)))
        (with-current-buffer buf (revert-buffer t t t)))
      (setq buf (or buf (let ((large-file-warning-threshold nil)) (find-file-noselect file))))
      (with-current-buffer buf
        (save-restriction
          (widen)
          (let ((todo nil) (bad nil) (ok nil) (limit (point-max)) (create-lockfiles nil))
            (dolist (m ms)
              (let* ((pos (drgnx-replace--live-pos m))
                     (rep (and pos (condition-case e (drgnx-replace-new-text m new)
                                     (error (list 'error (error-message-string e)))))))
                (cond ((not pos) (push (drgnx-replace--skip m "its text changed") bad))
                      ((null rep) (push (drgnx-replace--skip m "the regexp no longer matches its text") bad))
                      ((consp rep) (push (drgnx-replace--skip m (cadr rep)) bad))
                      (t (push (list pos (+ pos (length (plist-get m :text))) rep m) todo)))))
            ;; from the end, so the positions before stay put; a match overlapping the next is skipped
            (dolist (e (sort todo (lambda (a b) (> (car a) (car b)))))
              (if (> (nth 1 e) limit) (push (drgnx-replace--skip (nth 3 e) "overlaps another match") bad)
                (push e ok) (setq limit (car e))))
            (setq ok (nreverse ok))
            (if (null ok)
                (list 0 bad nil)
              (let ((g (prepare-change-group)))
                (condition-case e
                    (progn
                      (activate-change-group g)
                      (dolist (x ok) (goto-char (car x)) (delete-region (car x) (nth 1 x)) (insert (nth 2 x)))
                      (undo-amalgamate-change-group g)
                      (accept-change-group g)
                      (let ((save-silently t)) (save-buffer))
                      (list (length ok) bad (list :buffer buf :group g :file file :tick (buffer-chars-modified-tick))))
                  (error (cancel-change-group g)
                         (list 0 (append bad (mapcar (lambda (x) (drgnx-replace--skip (nth 3 x) (error-message-string e))) ok))
                               nil))))))))))))

(defun drgnx-replace-apply (matches new)
  "Replace MATCHES (from `drgnx-replace-search' or `drgnx-replace-symbol-edits') by NEW, file by file.
Each match is checked against its file as it is now (its buffer when visited; an unedited buffer whose file
changed on disk is reverted first) and skipped when its text is no longer there.  A file's replacements are one
change group, and the file is saved.  Returns (:written N :files F :skipped MATCHES :undo UNDO-DATA): N matches
written in F files; each skipped match carries :reason; UNDO-DATA is for `drgnx-replace-undo'."
  (let ((by-file nil) (written 0) (files 0) (skipped nil) (undo nil))
    (dolist (m matches) (push m (alist-get (plist-get m :file) by-file nil nil #'equal)))
    (pcase-dolist (`(,file . ,ms) (nreverse by-file))
      (pcase-let ((`(,n ,bad ,u) (drgnx-replace--apply-file file (nreverse ms) new)))
        (setq written (+ written n) skipped (append skipped bad))
        (when u (push u undo) (cl-incf files))))
    (list :written written :files files :skipped skipped :undo (nreverse undo))))

(defun drgnx-replace-undo (undo-data)
  "Undo a `drgnx-replace-apply' (its UNDO-DATA): every file's change group, saved.
A file edited, killed or changed on disk since is left alone.  Returns (:undone N :skipped FILES)."
  (let ((n 0) (skipped nil))
    (dolist (u undo-data)
      (let ((b (plist-get u :buffer)))
        (if (not (and (buffer-live-p b) (= (buffer-chars-modified-tick b) (plist-get u :tick))
                      (verify-visited-file-modtime b)
                      (with-current-buffer b
                        (condition-case nil
                            (let ((create-lockfiles nil) (save-silently t))
                              (cancel-change-group (plist-get u :group))
                              (save-buffer)
                              t)
                          (error nil)))))
            (push (plist-get u :file) skipped)
          (cl-incf n))))
    (list :undone n :skipped (nreverse skipped))))

(drgnx-module-define 'tools/replace
                     :doc "Search and replace across files: text through ripgrep or git grep, symbols through the language server."
                     :stage 'idle
                     :setup #'ignore)

(provide 'drgnx-replace)
;;; drgnx-replace.el ends here
