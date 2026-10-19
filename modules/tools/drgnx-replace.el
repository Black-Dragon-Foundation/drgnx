;;; drgnx-replace.el --- Module tools/replace: search and replace across files, text or symbol -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; One engine for VS Code's Search & Replace.  Text: ripgrep when installed, else git grep in a repository, else
;; grep, in the background and cancellable; matches stream in batches.  Symbol: the language server's rename edits
;; (asked for with a placeholder name, never applied by the server), as the same matches.  Replacing checks every
;; match against the file as it is now (its buffer when visited) and skips the stale ones; each file is one change
;; group, saved unless its buffer held unsaved edits (they stay unsaved), so one Undo puts every file back.
;; The UI, below the engine: the Search view in the sidebar (fields, toggles, a result tree with tick boxes and
;; old → new previews: rows of a view, wb/drgnx-view.el, patched in place in slices so typing never waits) and the
;; find bar above an editor, which searches its own buffer in Emacs (one engine search runs at a time).  See
;; docs/guide/replace.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'url-util)
(require 'wid-edit)
(require 'filenotify)
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-timer)
(require 'drgnx-wb)
(require 'drgnx-view)

(declare-function eglot-current-server "eglot")
(declare-function eglot-server-capable "eglot")
(declare-function eglot--TextDocumentPositionParams "eglot")
(declare-function eglot-move-to-utf-16-linepos "eglot")
(declare-function eglot--signal-textDocument/didChange "eglot")
(declare-function jsonrpc-request "jsonrpc")
(defvar eglot-move-to-linepos-function)
(defvar apheleia-format-after-save-in-progress) ; bound around our saves: no format on save (extra/format)

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

(defvar drgnx-replace--last-path nil "(RELATIVE ROOT . ABSOLUTE): the file name the last output line had.")

(defun drgnx-replace--path (rel root)
  "REL (a searcher's output) expanded in ROOT; a file's lines come in a row, so the last answer is kept."
  (if (and (equal rel (car drgnx-replace--last-path)) (equal root (cadr drgnx-replace--last-path)))
      (cddr drgnx-replace--last-path)
    (cddr (setq drgnx-replace--last-path (cons rel (cons root (expand-file-name rel root)))))))

(defun drgnx-replace--rg-text (x)
  "An `rg --json' text object: text, or bytes (base64) decoded as UTF-8."
  (or (plist-get x :text) (decode-coding-string (base64-decode-string (plist-get x :bytes)) 'utf-8)))

(defun drgnx-replace--rg-line (line root extra)
  "The matches in LINE of `rg --json' output (paths relative to ROOT)."
  (when (string-prefix-p "{\"type\":\"match\"" line)
    (let* ((d (plist-get (json-parse-string line :object-type 'plist :null-object nil :false-object nil) :data))
           (file (drgnx-replace--path (drgnx-replace--rg-text (plist-get d :path)) root))
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
  "The matches in LINE of `git grep -z -n' or `grep --null -n' output: each of RE (Emacs syntax) in the line's text."
  (when (string-match "\\`\\([^\0]+\\)\0\\([0-9]+\\)[\0:]" line)
    (let ((file (drgnx-replace--path (match-string 1 line) root))
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
      ('grep `("grep" ,(if file "-H" "-r") "-n" "--null" "-I" "--color=never" ,(if re "-E" "-F")
               ,@(unless case '("-i")) ,@(when word '("-w")) "--exclude-dir=.git"
               ,@(mapcar (lambda (g) (concat "--include=" g)) inc) ,@(mapcar (lambda (g) (concat "--exclude=" g)) exc)
               "-e" ,text "--" ,(or file "."))))))

(defun drgnx-replace--cleanup (proc)
  "Kill PROC's stderr buffer and its process."
  (let ((err (process-get proc 'drgnx-replace-err)))
    (when (buffer-live-p err)
      (when-let* ((ep (get-buffer-process err))) (delete-process ep))
      (kill-buffer err))))

(defvar drgnx-replace-parse-lines 64
  "The most output lines a search parses at a time (a filter call, or the continuation at the next timer pass): a
chunk of thousands of lines never holds Emacs up in one go.")

(defun drgnx-replace--stream-init (proc parse callback err)
  "Make PROC a search's stream: each output line goes through PARSE, the matches to CALLBACK; ERR its stderr buffer,
which owns the parse continuation."
  (process-put proc 'drgnx-replace-parse parse)
  (process-put proc 'drgnx-replace-callback callback)
  (process-put proc 'drgnx-replace-err err))

(defun drgnx-replace--output (proc chunk)
  "PROC's output CHUNK: its complete lines join PROC's queue (a partial last line waits for its end), then a bounded
part of the queue is parsed (`drgnx-replace--parse-some')."
  (unless (process-get proc 'drgnx-replace-cancelled)
    (let ((lines (split-string chunk "\n")) (rest (process-get proc 'drgnx-replace-rest)))
      (if (null (cdr lines))
          (when (> (length chunk) 0)
            (process-put proc 'drgnx-replace-rest (cons chunk rest)))   ; no newline yet: one more piece
        (when rest (setcar lines (drgnx-replace--join (cons (car lines) rest))))
        (let ((tail (car (last lines))))                             ; "" when CHUNK ends with a newline
          (process-put proc 'drgnx-replace-rest (and (> (length tail) 0) (list tail))))
        (drgnx-replace--enqueue proc (delete "" (nbutlast lines 1)))
        (drgnx-replace--parse-some proc)))))

(defun drgnx-replace--join (pieces)
  "A partial line's PIECES (newest first) as one string: joined once, at its end, never per chunk."
  (apply #'concat (reverse pieces)))

(defun drgnx-replace--enqueue (proc lines)
  "Put LINES (a fresh list) at the end of PROC's queue of lines to parse."
  (when lines
    (let ((tail (process-get proc 'drgnx-replace-tail)))
      (if tail (setcdr tail lines) (process-put proc 'drgnx-replace-queue lines))
      (process-put proc 'drgnx-replace-tail (last lines)))))

(defun drgnx-replace--parse-some (proc)
  "Parse at most `drgnx-replace-parse-lines' of PROC's queued lines and send their matches as one batch.  Lines
left: the rest at the next timer pass (`drgnx-timer-soon', owned by the search's stderr buffer).  None left and
PROC ended: the end of the stream (`drgnx-replace--end').  A line that does not parse is left out; the first such
error of the search goes to the callback as (:error REASON).  A cancelled search parses and sends nothing."
  (unless (process-get proc 'drgnx-replace-cancelled)
    (let ((q (process-get proc 'drgnx-replace-queue)) (parse (process-get proc 'drgnx-replace-parse))
          (n drgnx-replace-parse-lines) (parts nil) (bad nil))
      (while (and q (> n 0))
        (let ((line (car q)))
          (setq q (cdr q) n (1- n))                 ; taken before it is parsed: a bad line never stops the queue
          (condition-case e (push (funcall parse line) parts)
            (error (unless bad (setq bad (error-message-string e)))))))
      (process-put proc 'drgnx-replace-queue q)
      (unless q (process-put proc 'drgnx-replace-tail nil))
      (let ((ms (apply #'nconc (nreverse parts))) (callback (process-get proc 'drgnx-replace-callback)))
        (when ms (funcall callback ms))
        (when (and bad (not (process-get proc 'drgnx-replace-parse-failed)))
          (process-put proc 'drgnx-replace-parse-failed t)
          (funcall callback (list :error (format "Search output not read: %s" bad)))))
      (unless (process-get proc 'drgnx-replace-cancelled)  ; the callback may have started another search
        (cond (q (drgnx-timer-soon (cons 'replace-parse proc) 0 #'drgnx-replace--parse-some :args (list proc)
                                   :owner (process-get proc 'drgnx-replace-err)))
              ((process-get proc 'drgnx-replace-ended) (drgnx-replace--end proc)))))))

(defun drgnx-replace--finished (proc)
  "PROC ended: its last line joins the queue; the end of the stream comes once the queue is parsed."
  (unless (process-live-p proc)
    (if (process-get proc 'drgnx-replace-cancelled)
        (progn (when (eq proc drgnx-replace--search-proc) (setq drgnx-replace--search-proc nil))
               (drgnx-replace--cleanup proc))
      (let ((rest (process-get proc 'drgnx-replace-rest)))
        (process-put proc 'drgnx-replace-rest nil)
        (when rest (drgnx-replace--enqueue proc (list (drgnx-replace--join rest)))))
      (process-put proc 'drgnx-replace-ended t)
      (drgnx-replace--parse-some proc))))

(defun drgnx-replace--end (proc)
  "PROC's output is all parsed: its callback gets (:error REASON) when it failed, then :done; its stderr goes."
  (let ((callback (process-get proc 'drgnx-replace-callback)) (code (process-exit-status proc)))
    (unwind-protect
        (progn
          (unless (memq code '(0 1))              ; 1: nothing found
            (let* ((err (process-get proc 'drgnx-replace-err))
                   (msg (if (buffer-live-p err) (string-trim (with-current-buffer err (buffer-string))) "")))
              (funcall callback (list :error (if (string-empty-p msg)
                                                 (format "%s exited with code %s" (car (process-command proc)) code)
                                               msg)))))
          (funcall callback :done))
      (when (eq proc drgnx-replace--search-proc) (setq drgnx-replace--search-proc nil))
      (drgnx-replace--cleanup proc))))

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
                                   :filter #'drgnx-replace--output
                                   :sentinel (lambda (p _event) (drgnx-replace--finished p)))
                   (error (kill-buffer err)
                          (funcall callback (list :error (error-message-string e)))
                          (funcall callback :done)
                          nil))))
      (when proc
        (drgnx-replace--stream-init proc parse callback err)
        (ignore-errors (process-send-eof proc))         ; a tool that finished already (a busy machine) is no error
        (setq drgnx-replace--search-proc proc)))))

(defun drgnx-replace-cancel (handle)
  "Stop the search HANDLE (from `drgnx-replace-search'); its callback gets nothing more."
  (when (processp handle)
    (process-put handle 'drgnx-replace-cancelled t)
    (process-put handle 'drgnx-replace-queue nil)
    (process-put handle 'drgnx-replace-tail nil)
    (drgnx-timer-cancel (cons 'replace-parse handle))   ; its owner buffer runs no kill hook
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

(defun drgnx-replace--stale-edits (ms placeholder file line col)
  "The plain renames among MS (:new just PLACEHOLDER) whose text is not the name renamed: the text of the one at
point (FILE's LINE and COL), else the symbol PLACEHOLDER was made from.  A server that read older text gives these."
  (let* ((plain (seq-filter (lambda (m) (equal (plist-get m :new) placeholder)) ms))
         (at (seq-find (lambda (m) (and (equal (plist-get m :file) file) (= (plist-get m :line) line)
                                        (<= (plist-get m :col) col (plist-get m :end))))
                       plain))
         (name (if at (plist-get at :text) (string-remove-suffix drgnx-replace--rename-suffix placeholder))))
    (seq-remove (lambda (m) (equal (plist-get m :text) name)) plain)))

(defun drgnx-replace-symbol-edits (callback)
  "Ask this buffer's language server how to rename the symbol at point; never apply it.
CALLBACK gets the edits as one batch of matches (as `drgnx-replace-search' sends, with :new, the server's text
holding :placeholder for the new name; see `drgnx-replace-new-text'), then :done.  Without a server, with one
that cannot rename, or when it refuses, CALLBACK gets (:error REASON), then :done.  Edits whose text is not the
name renamed (the server read older text) are left out, and (:error REASON) after the batch says so."
  (let* ((server (and (featurep 'eglot) (eglot-current-server)))
         (placeholder (concat (or (thing-at-point 'symbol t) "x") drgnx-replace--rename-suffix))
         (results
          (cond
           ((not server) '((:error "No language server for this buffer")))
           ((not (eglot-server-capable :renameProvider)) '((:error "The language server cannot rename")))
           ((not buffer-file-name) '((:error "This buffer has no file")))
           (t (condition-case e
                  (let* ((file (file-truename buffer-file-name))
                         (line (line-number-at-pos nil t)) (col (- (point) (line-beginning-position)))
                         (ms (progn
                               (eglot--signal-textDocument/didChange) ; the server reads the text as it is now
                               (drgnx-replace--workspace-edit
                                (jsonrpc-request server :textDocument/rename
                                                 (append (eglot--TextDocumentPositionParams)
                                                         (list :newName placeholder)))
                                placeholder)))
                         (stale (drgnx-replace--stale-edits ms placeholder file line col))
                         (ms (seq-difference ms stale #'eq)))
                    (delq nil (list ms (when stale
                                         (list :error (format "%d edits left out: their text is not the name renamed (the server read older text)"
                                                              (length stale)))))))
                (error (list (list :error (drgnx-replace--error-message e)))))))))
    (dolist (r results) (funcall callback r))
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

(defun drgnx-replace--save ()
  "Save this buffer quietly and without format on save (a formatter's rewrite would make Undo skip the file)."
  (let ((save-silently t) (apheleia-format-after-save-in-progress t))
    (save-buffer)))

(defun drgnx-replace--apply-file (file ms new)
  "Replace FILE's matches MS by NEW in one change group: (WRITTEN SKIPPED UNDO-ENTRY-or-nil).
The buffer is saved unless it held unsaved edits before."
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
              (let ((g (prepare-change-group))
                    (save (not (buffer-modified-p)))) ; the user's unsaved edits stay unsaved, as in VS Code
                (condition-case e
                    (progn
                      (activate-change-group g)
                      (dolist (x ok) (goto-char (car x)) (delete-region (car x) (nth 1 x)) (insert (nth 2 x)))
                      (undo-amalgamate-change-group g)
                      (accept-change-group g)
                      (when save (drgnx-replace--save))
                      (list (length ok) bad
                            (list :buffer buf :group g :file file :saved save :tick (buffer-chars-modified-tick))))
                  (error (cancel-change-group g)
                         (list 0 (append bad (mapcar (lambda (x) (drgnx-replace--skip (nth 3 x) (error-message-string e))) ok))
                               nil))))))))))))

(defun drgnx-replace-apply (matches new)
  "Replace MATCHES (from `drgnx-replace-search' or `drgnx-replace-symbol-edits') by NEW, file by file.
Each match is checked against its file as it is now (its buffer when visited; an unedited buffer whose file
changed on disk is reverted first) and skipped when its text is no longer there.  A file's replacements are one
change group; the file is saved unless its buffer held unsaved edits before (they stay unsaved).
Returns (:written N :files F :skipped MATCHES :undo UNDO-DATA): N matches written in F files; each skipped match
carries :reason; UNDO-DATA is for `drgnx-replace-undo'."
  (let ((by-file nil) (written 0) (files 0) (skipped nil) (undo nil))
    (dolist (m matches) (push m (alist-get (plist-get m :file) by-file nil nil #'equal)))
    (pcase-dolist (`(,file . ,ms) (nreverse by-file))
      (pcase-let ((`(,n ,bad ,u) (drgnx-replace--apply-file file (nreverse ms) new)))
        (setq written (+ written n) skipped (append skipped bad))
        (when u (push u undo) (cl-incf files))))
    (list :written written :files files :skipped skipped :undo (nreverse undo))))

(defun drgnx-replace-undo (undo-data)
  "Undo a `drgnx-replace-apply' (its UNDO-DATA): every file's change group, saved when apply saved it.
A file edited, killed or changed on disk since is left alone.  Returns (:undone N :skipped FILES)."
  (let ((n 0) (skipped nil))
    (dolist (u undo-data)
      (let ((b (plist-get u :buffer)))
        (if (not (and (buffer-live-p b) (= (buffer-chars-modified-tick b) (plist-get u :tick))
                      (verify-visited-file-modtime b)
                      (with-current-buffer b
                        (condition-case nil
                            (let ((create-lockfiles nil))
                              (cancel-change-group (plist-get u :group))
                              (when (plist-get u :saved) (drgnx-replace--save))
                              t)
                          (error nil)))))
            (push (plist-get u :file) skipped)
          (cl-incf n))))
    (list :undone n :skipped (nreverse skipped))))

;;;; The Search view (the sidebar) and the find bar

(defface drgnx-replace-match '((t :inherit lazy-highlight)) "A match, in the Search view and the find bar." :group 'drgnx)
(defface drgnx-replace-current '((t :inherit isearch)) "The match shown: the find bar's current one." :group 'drgnx)
(defface drgnx-replace-old '((t :inherit diff-removed :strike-through t)) "The text a replacement takes out." :group 'drgnx)
(defface drgnx-replace-new '((t :inherit diff-added)) "The text a replacement puts in." :group 'drgnx)
(defface drgnx-replace-dim '((t :inherit shadow)) "Folders, the status line, reasons, toggles that are off." :group 'drgnx)
(defface drgnx-replace-on '((t :inherit lazy-highlight :weight bold)) "A toggle that is on." :group 'drgnx)

(defvar drgnx-replace-delay 0.25 "Seconds after typing stops before the Search view searches (or redraws).")
(defvar drgnx-replace-bar-limit 5000 "The most matches the find bar highlights.")
(defconst drgnx-replace-buffer-name "*drgnx search*")
(defconst drgnx-replace-bar-buffer-name "*drgnx find*")

(defvar-local drgnx-replace--widgets nil
  "Alist NAME → widget: fields `find' `replace' `include' `exclude', toggles :symbol :case :word :regexp, scopes
`project' `file'.")
(defvar-local drgnx-replace--opts nil "Plist (:symbol :case :word :regexp :scope).")
(defvar-local drgnx-replace--origin nil "Marker: the buffer and point the view or the bar works for (a symbol, This file).")
(defvar-local drgnx-replace--root nil "The directory the view searches.")
(defvar-local drgnx-replace--matches nil "The view's matches, in order.")
(defvar-local drgnx-replace--tail nil "The last cons of `drgnx-replace--matches'.")
(defvar-local drgnx-replace--seen nil "Hash FILE → how many matches it has.")
(defvar-local drgnx-replace--off-files nil "Hash FILE → how many of its matches are unticked.")
(defvar-local drgnx-replace--headers nil
  "Hash FILE → its header row's key, (drgnx-replace-file . FILE), made once per search (a match's key is its plist).")
(defvar-local drgnx-replace--last-row nil "Hash FILE → the key of its last row: where its next match goes.")
(defvar-local drgnx-replace--end-file nil "The file whose rows end the list: its next match is appended.")
(defvar-local drgnx-replace--new "" "The replace field's text the rows show, set when it changes (no widget read per row).")
(defvar-local drgnx-replace--off nil "Hash MATCH → t: the unticked matches.")
(defvar-local drgnx-replace--results nil "Marker: where the result tree starts (the view's rows).")
(defvar-local drgnx-replace--status-beg nil "Marker: the status line's start.")
(defvar-local drgnx-replace--status-end nil "Marker: the status line's end.")
(defvar-local drgnx-replace--status "" "The last action's message (Replaced …, an error), on the status line.")
(defvar-local drgnx-replace--handle nil "The engine search running for the view.")
(defvar-local drgnx-replace--searching nil "Non-nil until the view's search sends :done.")
(defvar-local drgnx-replace--want nil "What the pause after typing ends in: `search' or `redraw'.")
(defvar-local drgnx-replace--undo nil "Undo data of the view's replacements, newest first.")
(defvar-local drgnx-replace--shown nil "Overlay on the match shown in the editor.")
(defvar-local drgnx-replace--bar-overlays nil "The find bar's matches: overlays in its target buffer, in order.")
(defvar-local drgnx-replace--bar-index nil "The current match's index in `drgnx-replace--bar-overlays'.")
(defvar drgnx-replace--quiet nil "Non-nil while the code, not the user, fills a field.")
(defvar drgnx-replace--applying nil "Non-nil while the view writes files itself: no change underneath.")
(defvar drgnx-replace-refresh-delay 0.5 "Seconds after a listed file changes before its rows are searched again.")
(defvar drgnx-replace-watch-limit 200
  "The most listed files whose folders are watched for changes on disk (more: searched again when the view shows).")
(defvar drgnx-replace-refresh-max-bytes (* 4 1024 1024) "A changed file bigger than this keeps its rows.")
(defvar-local drgnx-replace--listed nil "Hash FILE → t: the files the search listed, watched for changes.")
(defvar-local drgnx-replace--watches nil "The file-notify watches on the listed files' folders.")
(defvar-local drgnx-replace--overflow nil "Non-nil when more files are listed than are watched.")
(defvar-local drgnx-replace--changed nil "Listed files changed since the last refresh.")
(defvar-local drgnx-replace--stale nil "Non-nil when the code changed under a symbol list.")

(defvar drgnx-replace-keys-map (make-sparse-keymap)
  "The Search view's and the find bar's keys (replace-* commands), from the key profiles; in their fields too.")

(defvar drgnx-replace-bar-keys-map (make-sparse-keymap)
  "The find bar's own keys (Close Find Bar), from the key profiles.  RET in a field is the field's action: the
next match, or replace it in the Replace field.")

(defvar drgnx-replace--field-map (make-composed-keymap (list drgnx-replace-keys-map widget-field-keymap))
  "The Search view's fields: the profile keys, then the widget field keys (never the dock's single letters).")
(defvar drgnx-replace--bar-field-map
  (make-composed-keymap (list drgnx-replace-bar-keys-map drgnx-replace-keys-map widget-field-keymap))
  "The find bar's fields.")

(defvar drgnx-replace-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m (make-composed-keymap (list drgnx-replace-keys-map drgnx-wb-dock-map) widget-keymap))
    m)
  "The Search view: the profile keys, the dock's, then TAB and RET as in every widget buffer.")

(defvar drgnx-replace-bar-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m (make-composed-keymap (list drgnx-replace-bar-keys-map drgnx-replace-keys-map) widget-keymap))
    m)
  "The find bar.")

(define-derived-mode drgnx-replace-mode nil "Search"
  "The Search view: find and replace across files, text or symbol (docs/guide/replace.md)."
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook #'drgnx-replace--view-killed nil t))

(define-derived-mode drgnx-replace-bar-mode nil "Find"
  "The find bar above an editor: find and replace in its buffer (docs/guide/replace.md)."
  (setq-local truncate-lines t mode-line-format nil header-line-format nil tab-line-format nil))

(declare-function evil-set-initial-state "evil-core")
(declare-function evil-initial-state "evil-core")
(defun drgnx-replace--evil-states ()
  "The fields take typing in the Vim profile too: both modes start in Emacs state (the module's setup runs
this once evil is loaded).  The undo puts each mode's earlier state back, only while it is still Emacs state."
  (when (fboundp 'evil-set-initial-state)
    (dolist (mode '(drgnx-replace-mode drgnx-replace-bar-mode))
      (let ((old (evil-initial-state mode)))
        (evil-set-initial-state mode 'emacs)
        (drgnx-modules-push-undo (format "evil state %s" mode)
                                 (lambda () (when (eq (evil-initial-state mode) 'emacs) (evil-set-initial-state mode old))))))))

(define-button-type 'drgnx-replace-box 'action #'drgnx-replace--box-pressed 'follow-link t 'face nil
  'help-echo "Tick or untick: Replace All writes the ticked matches")
(define-button-type 'drgnx-replace-row 'action #'drgnx-replace--row-pressed 'follow-link t 'face nil
  'help-echo "Show in the editor")

;;;;; Fields and toggles (the view and the bar)

(defun drgnx-replace--widget (name) "The widget NAME of this view or bar." (alist-get name drgnx-replace--widgets))
(defun drgnx-replace--opt (name) "The toggle or scope NAME of this view or bar." (plist-get drgnx-replace--opts name))
(defun drgnx-replace--bar-p () "Non-nil in the find bar." (derived-mode-p 'drgnx-replace-bar-mode))

(defun drgnx-replace--text (name)
  "Field NAME's text (\"\" when there is no such field)."
  (if-let* ((w (drgnx-replace--widget name))) (widget-value w) ""))

(defun drgnx-replace--fill (name text)
  "Put TEXT in field NAME, without the field's reaction to typing."
  (let ((drgnx-replace--quiet t) (w (drgnx-replace--widget name)))
    (when (and w (not (equal (widget-value w) text))) (widget-value-set w text))))

(defun drgnx-replace--insert-field (name label size)
  "A field NAME after LABEL; SIZE columns wide, or to the end of the line when nil."
  (widget-insert label)
  (push (cons name (widget-create 'editable-field :size size :format "%v"
                                  :keymap (if (drgnx-replace--bar-p) drgnx-replace--bar-field-map drgnx-replace--field-map)
                                  :notify (lambda (&rest _) (drgnx-replace--edited name))
                                  :action (lambda (&rest _) (drgnx-replace--field-action name))
                                  ""))
        drgnx-replace--widgets))

(defun drgnx-replace--insert-button (name label help action)
  "A button NAME (a toggle or a scope when NAME is one; nil for a plain button) showing LABEL; ACTION when pressed."
  (let ((w (widget-create 'push-button :button-face (drgnx-replace--button-face name) :help-echo help
                          :notify (lambda (&rest _) (funcall action))
                          label)))
    (when name (push (cons name w) drgnx-replace--widgets))
    (widget-insert " ")
    w))

(defun drgnx-replace--button-face (name)
  "The face of button NAME: on or off, for toggles and scopes."
  (cond ((memq name '(:symbol :case :word :regexp)) (if (drgnx-replace--opt name) 'drgnx-replace-on 'drgnx-replace-dim))
        ((memq name '(project file)) (if (eq (drgnx-replace--opt :scope) name) 'drgnx-replace-on 'drgnx-replace-dim))
        (t 'widget-button)))

(defun drgnx-replace--restyle (name)
  "Draw button NAME again in the face its state gives."
  (when-let* ((w (drgnx-replace--widget name)))
    (let ((buffer-undo-list t))
      (widget-put w :button-face (drgnx-replace--button-face name))
      (save-excursion (widget-value-set w (widget-value w))))))

(defun drgnx-replace--insert-toggles ()
  "The ⟨⟩ Symbol, Aa, ab and .* toggles."
  (pcase-dolist (`(,name ,label ,help) '((:symbol "⟨⟩ Symbol" "Rename the symbol: the language server's edits")
                                         (:case "Aa" "Match case") (:word "ab" "Whole word") (:regexp ".*" "Regular expression")))
    (drgnx-replace--insert-button name label help (lambda () (drgnx-replace--toggle name)))))

(defun drgnx-replace--toggle (name)
  "Turn the toggle NAME (:symbol :case :word :regexp) on or off, and search again.  A greyed-out toggle stays."
  (let ((w (drgnx-replace--widget name)))
    (when (and w (widget-apply w :active))
      (if (eq name :symbol)
          (drgnx-replace--set-symbol (not (drgnx-replace--opt :symbol)))
        (setq drgnx-replace--opts (plist-put drgnx-replace--opts name (not (drgnx-replace--opt name))))
        (drgnx-replace--restyle name))
      (drgnx-replace--requery))))

(defun drgnx-replace--set-scope (scope)
  "Search the project or this file (SCOPE `project' or `file'), and search again."
  (setq drgnx-replace--opts (plist-put drgnx-replace--opts :scope scope))
  (drgnx-replace--restyle 'project)
  (drgnx-replace--restyle 'file)
  (drgnx-replace--requery))

(defun drgnx-replace--symbol-at (marker)
  "The name at MARKER, or nil."
  (when (and (markerp marker) (buffer-live-p (marker-buffer marker)))
    (with-current-buffer (marker-buffer marker)
      (save-excursion (goto-char marker) (thing-at-point 'symbol t)))))

(defun drgnx-replace--renamable-p (marker)
  "Non-nil when MARKER is on a name its buffer's language server can rename."
  (and (drgnx-replace--symbol-at marker)
       (with-current-buffer (marker-buffer marker)
         (and (featurep 'eglot) (eglot-current-server) (eglot-server-capable :renameProvider) t))))

(defun drgnx-replace--set-symbol (on)
  "Symbol mode ON or off: on, the find field holds the name and what does not apply is greyed out."
  (setq drgnx-replace--opts (plist-put drgnx-replace--opts :symbol on))
  (drgnx-replace--restyle :symbol)
  (dolist (name '(include exclude :case :word :regexp))
    (when-let* ((w (drgnx-replace--widget name)))
      (let ((buffer-undo-list t)) (widget-apply w (if on :deactivate :activate)))))
  (when-let* ((on) (name (drgnx-replace--symbol-at drgnx-replace--origin)))
    (drgnx-replace--fill 'find name)))

(defun drgnx-replace--requery ()
  "Search again now: the view's search, or the bar's."
  (if (drgnx-replace--bar-p) (drgnx-replace--bar-search) (drgnx-replace--search-now)))

(defun drgnx-replace--edited (name)
  "The user typed in field NAME."
  (unless drgnx-replace--quiet
    (when (and (eq name 'find) (drgnx-replace--opt :symbol))
      (drgnx-replace--set-symbol nil))            ; a symbol is the name at point; other text is a text search
    (cond ((drgnx-replace--bar-p) (unless (eq name 'replace) (drgnx-replace--bar-search)))
          ((eq name 'replace) (drgnx-replace--schedule 'redraw))
          (t (drgnx-replace--schedule 'search)))))

(defun drgnx-replace--field-action (name)
  "RET in field NAME: the view searches now; the bar goes to the next match, or replaces it (the replace field)."
  (cond ((not (drgnx-replace--bar-p)) (drgnx-replace--search-now))
        ((eq name 'replace) (drgnx-replace--bar-replace-one))
        (t (drgnx-replace--bar-step 1))))

;;;;; The view

(defun drgnx-replace--define-section ()
  "Put the Search view in the sidebar (its `search' view), and define the view type of its result rows."
  (drgnx-view-define 'replace-results :render #'drgnx-replace--render-row :delay 0 :slice drgnx-view-slice
                     :key-test 'eq :patched #'drgnx-replace--rows-drawn)
  (drgnx-wb-define-section 'search :view 'search :slot 0 :title " SEARCH" :buffer #'drgnx-replace--view-buffer
                           :on-show (lambda (_w) (drgnx-replace--on-show))
                           :on-focus #'drgnx-replace--focus-find))

(defun drgnx-replace--focus-find (window)
  "The Search view focused in WINDOW by its key (VS Code's Ctrl+Shift+F): point in the find field."
  (with-current-buffer (window-buffer window)
    (set-window-point window (widget-field-start (drgnx-replace--widget 'find)))))

(defun drgnx-replace--view-buffer ()
  "The Search view's buffer, drawn the first time."
  (or (get-buffer drgnx-replace-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-replace-buffer-name)
        (drgnx-replace-mode)
        (drgnx-replace--render-view)
        (drgnx-view-attach 'replace-results :start drgnx-replace--results)
        (add-hook 'after-change-functions #'drgnx-replace--buffer-changed)
        (current-buffer))))

(defun drgnx-replace--render-view ()
  "Draw the view's fields, toggles and buttons; the results go below."
  (setq drgnx-replace--opts (list :symbol nil :case nil :word nil :regexp nil :scope 'project)
        drgnx-replace--widgets nil
        drgnx-replace--off (make-hash-table :test #'eq)
        drgnx-replace--seen (make-hash-table :test #'equal)
        drgnx-replace--listed (make-hash-table :test #'equal)
        drgnx-replace--off-files (make-hash-table :test #'equal)
        drgnx-replace--headers (make-hash-table :test #'equal)
        drgnx-replace--last-row (make-hash-table :test #'equal))
  (drgnx-replace--insert-field 'find "Find     " nil)
  (drgnx-replace--insert-field 'replace "Replace  " nil)
  (drgnx-replace--insert-toggles)
  (widget-insert "\n")
  (drgnx-replace--insert-button 'project "Project" "Search every file of the project"
                                (lambda () (drgnx-replace--set-scope 'project)))
  (drgnx-replace--insert-button 'file "This file" "Search only the file the view was opened from"
                                (lambda () (drgnx-replace--set-scope 'file)))
  (widget-insert "\n")
  (drgnx-replace--insert-field 'include "Include  " nil)
  (drgnx-replace--insert-field 'exclude "Exclude  " nil)
  (drgnx-replace--insert-button nil "Replace All" "Replace every ticked match" #'drgnx-replace-all)
  (drgnx-replace--insert-button nil "Undo" "Undo the last replacement, in every file" #'drgnx-replace-view-undo)
  (widget-insert "\n")
  (setq drgnx-replace--status-beg (point-marker))
  (widget-insert "\n")
  (setq drgnx-replace--status-end (copy-marker (1- (point)) t))
  (widget-insert "\n")
  (setq drgnx-replace--results (point-marker))
  (widget-setup)
  (goto-char (widget-field-start (drgnx-replace--widget 'find))))

(defmacro drgnx-replace--drawing (&rest body)
  "BODY changes the view's own text (results, status): no read-only check, no undo, no field reactions."
  `(let ((inhibit-read-only t) (inhibit-modification-hooks t) (buffer-undo-list t))
     (save-excursion ,@body)))

(defun drgnx-replace--update-status ()
  "Write the status line: how many results, still searching, the last message."
  (let* ((n (length drgnx-replace--matches)) (files (hash-table-count drgnx-replace--seen))
         (counts (cond ((and (zerop n) drgnx-replace--searching) "Searching…")
                       ((zerop n) (if (string-empty-p (drgnx-replace--text 'find)) "" "No results"))
                       (t (format "%s%d result%s in %d file%s" (if drgnx-replace--searching "Searching… " "")
                                  n (if (= n 1) "" "s") files (if (= files 1) "" "s")))))
         (line (string-join (seq-remove #'string-empty-p (list counts drgnx-replace--status)) " · ")))
    (drgnx-replace--drawing
     (delete-region drgnx-replace--status-beg drgnx-replace--status-end)
     (goto-char drgnx-replace--status-beg)
     (insert (propertize line 'face 'drgnx-replace-dim)))))

(defun drgnx-replace--message (fmt &rest args)
  "Show FMT with ARGS on the status line."
  (setq drgnx-replace--status (apply #'format fmt args))
  (drgnx-replace--update-status))

(defun drgnx-replace--clear ()
  "Forget the matches and their ticks: a new search.  The rows go in slices (the view's reset), never erased."
  (when (overlayp drgnx-replace--shown) (delete-overlay drgnx-replace--shown))
  (drgnx-view-reset drgnx-view nil)
  (setq drgnx-replace--matches nil drgnx-replace--tail nil drgnx-replace--status "" drgnx-replace--end-file nil
        drgnx-replace--new (drgnx-replace--text 'replace))
  (dolist (h (list drgnx-replace--seen drgnx-replace--off drgnx-replace--off-files drgnx-replace--listed
                   drgnx-replace--headers drgnx-replace--last-row))
    (clrhash h))
  (drgnx-replace--unwatch)
  (setq drgnx-replace--stale nil))

(defun drgnx-replace--header (file)
  "FILE's header key, made the first time this search lists FILE."
  (or (gethash file drgnx-replace--headers) (puthash file (cons 'drgnx-replace-file file) drgnx-replace--headers)))

(defun drgnx-replace--mark-rows (file rows)
  "Mark the new ROWS of FILE (its matches, in order): after its last row, or, for a file not shown yet or the one
whose rows end the list, at the end (a new file after its header)."
  (let ((last (gethash file drgnx-replace--last-row)))
    (cond ((null last)
           (drgnx-view-append drgnx-view (cons (drgnx-replace--header file) rows))
           (setq drgnx-replace--end-file file))
          ((equal file drgnx-replace--end-file) (drgnx-view-append drgnx-view rows))
          (t (drgnx-view-insert drgnx-view rows :after last)))
    (puthash file (car (last rows)) drgnx-replace--last-row)))

(defun drgnx-replace--add (ms)
  "Matches MS arrived: list them, mark their rows (each run of one file's matches is one mark)."
  (when ms
    (let ((ms (copy-sequence ms)) (file nil) (run nil))
      (dolist (m ms)
        (cl-incf (gethash (plist-get m :file) drgnx-replace--seen 0))
        (puthash (plist-get m :file) t drgnx-replace--listed))
      (if drgnx-replace--matches (setcdr drgnx-replace--tail ms) (setq drgnx-replace--matches ms))
      (setq drgnx-replace--tail (last ms))
      (dolist (m ms)
        (unless (equal (plist-get m :file) file)
          (when run (drgnx-replace--mark-rows file (nreverse run)))
          (setq file (plist-get m :file) run nil))
        (push m run))
      (drgnx-replace--mark-rows file (nreverse run)))))

(defun drgnx-replace--redraw ()
  "The replace text changed: every match row shows its new preview, patched in place (the headers stay)."
  (setq drgnx-replace--new (drgnx-replace--text 'replace))
  (drgnx-view-dirty drgnx-view drgnx-replace--matches)
  (drgnx-replace--update-status))

(defun drgnx-replace--rows-drawn (_view _keys)
  "The view drew rows (its PATCHED): the status line counts them."
  (drgnx-replace--update-status))

(defun drgnx-replace--file-box (file)
  "FILE's tick box: [x] every match ticked, [ ] none, [-] some."
  (let ((off (gethash file drgnx-replace--off-files 0)))
    (cond ((zerop off) "[x]") ((>= off (gethash file drgnx-replace--seen 0)) "[ ]") (t "[-]"))))

(defun drgnx-replace--set-tick (m on)
  "Tick match M (ON non-nil) or untick it."
  (unless (eq (not on) (and (gethash m drgnx-replace--off) t))
    (if on (remhash m drgnx-replace--off) (puthash m t drgnx-replace--off))
    (cl-incf (gethash (plist-get m :file) drgnx-replace--off-files 0) (if on -1 1))))

(defun drgnx-replace--preview (m new)
  "What M's row shows: the text around it, M as old → new (NEW, the replace field), a skipped match's reason."
  (let* ((before (string-trim-left (plist-get m :before)))
         (before (if (> (length before) 16) (concat "…" (substring before -15)) before))
         (rep (and (or (plist-get m :placeholder) (not (string-empty-p new)))
                   (ignore-errors (drgnx-replace-new-text m new))))
         (flat (lambda (s) (string-replace "\n" "⏎" s))))
    (concat (funcall flat before)
            (if rep
                (concat (propertize (funcall flat (plist-get m :text)) 'face 'drgnx-replace-old)
                        (propertize (funcall flat rep) 'face 'drgnx-replace-new))
              (propertize (funcall flat (plist-get m :text)) 'face 'drgnx-replace-match))
            (funcall flat (plist-get m :after))
            (if-let* ((why (plist-get m :reason))) (propertize (concat "  — " why) 'face 'drgnx-replace-dim) ""))))

(defun drgnx-replace--render-row (key)
  "The row of KEY: a file's header (KEY (drgnx-replace-file . FILE)) or a match's row (KEY its plist), the preview
from `drgnx-replace--new'.  The view's RENDER, in the view's buffer."
  (if (eq (car key) 'drgnx-replace-file)
      (let* ((file (cdr key)) (dir (file-relative-name (file-name-directory file) (or drgnx-replace--root "/"))))
        (propertize (concat (make-text-button (drgnx-replace--file-box file) nil
                                              :type 'drgnx-replace-box 'drgnx-replace-box file)
                            " " (file-name-nondirectory file)
                            (if (equal dir "./") "" (propertize (concat "  " dir) 'face 'drgnx-replace-dim))
                            "\n")
                    'drgnx-replace-file file))
    (propertize (concat "  "
                        (make-text-button (if (gethash key drgnx-replace--off) "[ ]" "[x]") nil
                                          :type 'drgnx-replace-box 'drgnx-replace-box key)
                        " "
                        (make-text-button (drgnx-replace--preview key drgnx-replace--new) nil :type 'drgnx-replace-row)
                        "\n")
                'drgnx-replace-match key)))

(defun drgnx-replace--set-box (pos text)
  "Make the tick box at POS show TEXT."
  (unless (equal (buffer-substring-no-properties pos (+ pos 3)) text)
    (drgnx-replace--drawing
     (subst-char-in-region (1+ pos) (+ pos 2) (char-after (1+ pos)) (aref text 1) t))))

(defun drgnx-replace--refresh-boxes (file)
  "Show FILE's ticks again, its header's and its rows'."
  (let ((pos (marker-position drgnx-replace--results)))
    (while (and pos (< pos (point-max)))
      (let ((v (get-text-property pos 'drgnx-replace-box)))
        (when (and v (equal (if (stringp v) v (plist-get v :file)) file))
          (drgnx-replace--set-box pos (cond ((stringp v) (drgnx-replace--file-box file))
                                            ((gethash v drgnx-replace--off) "[ ]")
                                            (t "[x]")))))
      (setq pos (next-single-property-change pos 'drgnx-replace-box)))))

(defun drgnx-replace--box-pressed (button)
  "Tick or untick the match or the file (all its matches) of BUTTON."
  (let* ((v (get-text-property (button-start button) 'drgnx-replace-box))
         (file (if (stringp v) v (plist-get v :file))))
    (if (stringp v)
        (let ((ms (seq-filter (lambda (m) (equal (plist-get m :file) file)) drgnx-replace--matches)))
          (let ((on (not (seq-some (lambda (m) (not (gethash m drgnx-replace--off))) ms))))
            (dolist (m ms) (drgnx-replace--set-tick m on))))
      (drgnx-replace--set-tick v (gethash v drgnx-replace--off)))
    (drgnx-replace--refresh-boxes file)))

(defun drgnx-replace--row-pressed (button)
  "Show BUTTON's match in the editor and go there."
  (drgnx-replace--show-match (get-text-property (button-start button) 'drgnx-replace-match) t))

(defun drgnx-replace--show-match (m select)
  "Show match M in the editor, scrolled to it, marked; move there when SELECT."
  (let* ((view (current-buffer))
         (buf (let ((large-file-warning-threshold nil)) (find-file-noselect (plist-get m :file))))
         (w (drgnx-wb-show-in-editor buf select)))
    (with-current-buffer buf
      (save-restriction
        (widen)
        (goto-char (point-min))
        (forward-line (1- (plist-get m :line)))
        (let* ((b (min (+ (point) (plist-get m :col)) (line-end-position))) (e (min (+ b (length (plist-get m :text))) (point-max))))
          (goto-char b)
          (set-window-point w b)
          (with-current-buffer view
            (if (overlayp drgnx-replace--shown) (move-overlay drgnx-replace--shown b e buf)
              (setq drgnx-replace--shown (make-overlay b e buf))
              (overlay-put drgnx-replace--shown 'face 'drgnx-replace-current)
              (overlay-put drgnx-replace--shown 'priority 1001))))))
    (ignore-errors (with-selected-window w (recenter)))))

(defun drgnx-replace--ensure-origin ()
  "The marker the view works for; the editor's buffer and point when the view has none."
  (unless (and (markerp drgnx-replace--origin) (buffer-live-p (marker-buffer drgnx-replace--origin)))
    (let ((w (drgnx-wb-editor-window)))
      (setq drgnx-replace--origin (with-current-buffer (window-buffer w) (copy-marker (window-point w)))
            drgnx-replace--root (drgnx-replace--root-of drgnx-replace--origin))))
  drgnx-replace--origin)

(defun drgnx-replace--root-of (marker)
  "The directory to search for MARKER's buffer: its project's root, else its directory."
  (with-current-buffer (marker-buffer marker)
    (require 'project)
    (if-let* ((p (project-current nil))) (expand-file-name (project-root p)) (expand-file-name default-directory))))

(defun drgnx-replace--origin-file ()
  "The file of the buffer the view works for, or nil."
  (when-let* ((m (drgnx-replace--ensure-origin))) (buffer-file-name (marker-buffer m))))

(defun drgnx-replace--schedule (want)
  "After the pause in typing: WANT `search' (a search stays wanted over a redraw) or `redraw'."
  (unless (eq drgnx-replace--want 'search) (setq drgnx-replace--want want))
  (drgnx-timer-debounce (cons 'replace-pause (current-buffer)) drgnx-replace-delay #'drgnx-replace--pause-over
                        :args (list (current-buffer)) :owner (current-buffer)))

(defun drgnx-replace--pause-over (buf)
  "Typing paused in BUF's fields: search or redraw.  A timer: never asks the language server, never signals."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((want drgnx-replace--want))
        (setq drgnx-replace--want nil)
        (condition-case e
            (if (and (eq want 'search) (not (drgnx-replace--opt :symbol))) (drgnx-replace--search-now) (drgnx-replace--redraw))
          (error (drgnx-replace--message "%s" (error-message-string e))))))))

(defun drgnx-replace--got (x)
  "The engine sent X: a batch of matches, (:error REASON) or :done."
  (cond ((eq x :done)
         (setq drgnx-replace--searching nil drgnx-replace--handle nil)
         (drgnx-replace--watch)
         (drgnx-replace--update-status))
        ((eq (car-safe x) :error) (drgnx-replace--message "%s" (cadr x)))
        (t (drgnx-replace--add x))))

(defun drgnx-replace--search-now ()
  "Search now with the fields and toggles: the language server's edits in symbol mode, else the files' text."
  (drgnx-timer-cancel (cons 'replace-pause (current-buffer)))
  (setq drgnx-replace--want nil)
  (drgnx-replace-cancel drgnx-replace--handle)
  (setq drgnx-replace--handle nil drgnx-replace--searching nil)
  (drgnx-replace--clear)
  (drgnx-replace--ensure-origin)
  (let ((err (and (drgnx-replace--opt :symbol) (drgnx-replace--symbol-search))))
    (when (eq err 'nothing) (setq err nil))
    (when err (drgnx-replace--set-symbol nil))        ; no edits from the server: search the text instead
    (if (drgnx-replace--opt :symbol) (drgnx-replace--watch) (drgnx-replace--text-search))
    (if err (drgnx-replace--message "%s" err) (drgnx-replace--update-status))))

(defun drgnx-replace--text-search ()
  "Start the engine on the fields' text."
  (let* ((text (drgnx-replace--text 'find)) (file (and (eq (drgnx-replace--opt :scope) 'file) (drgnx-replace--origin-file)))
         (buf (current-buffer)))
    (cond ((string-empty-p text))
          ((and (eq (drgnx-replace--opt :scope) 'file) (not file))
           (setq drgnx-replace--status "This file: the view was not opened from a file"))
          (t (setq drgnx-replace--searching t)
             (let ((h (drgnx-replace-search
                       (list :root drgnx-replace--root :file file :text text :case (drgnx-replace--opt :case)
                             :word (drgnx-replace--opt :word) :regexp (drgnx-replace--opt :regexp)
                             :include (drgnx-replace--text 'include) :exclude (drgnx-replace--text 'exclude))
                       (lambda (x) (when (buffer-live-p buf) (with-current-buffer buf (drgnx-replace--got x)))))))
               (when drgnx-replace--searching (setq drgnx-replace--handle h)))))))

(defun drgnx-replace--symbol-search ()
  "List the language server's edits for the name at the origin (one request).
Nil when it sent edits; else the reason as a string (`nothing' when it sent none and no reason)."
  (let ((origin drgnx-replace--origin) (ms nil) (err nil))
    (if (not (drgnx-replace--symbol-at origin))
        (setq err "Symbol: no name at point in the editor")
      (with-current-buffer (marker-buffer origin)
        (save-excursion
          (goto-char origin)
          (drgnx-replace-symbol-edits (lambda (x) (cond ((eq x :done))
                                                        ((eq (car-safe x) :error) (setq err (cadr x)))
                                                        (t (setq ms (append ms x)))))))))
    (when (and ms (eq (drgnx-replace--opt :scope) 'file))
      (let ((f (drgnx-replace--origin-file)))
        (setq ms (seq-filter (lambda (m) (and f (file-equal-p (plist-get m :file) f))) ms))))
    (drgnx-replace--add ms)
    (cond ((and ms err) (setq drgnx-replace--status err) nil)
          (ms nil)
          (t (or err 'nothing)))))

(defun drgnx-replace--busy-p ()
  "Non-nil while the view still has work: a pause to wait out, a search running, rows to draw."
  (or (drgnx-timer-active-p (cons 'replace-pause (current-buffer))) drgnx-replace--searching
      (drgnx-view-pending-p drgnx-view) (drgnx-timer-active-p (cons 'replace-refresh (current-buffer)))))

(defun drgnx-replace--live-view ()
  "The Search view's buffer, or a user error when it was never opened."
  (or (get-buffer drgnx-replace-buffer-name) (user-error "No search: open the Search view first")))

(defun drgnx-replace--word-here ()
  "The text to search for at point: the region (one line), else the name at point."
  (if (and (use-region-p) (= (line-number-at-pos (region-beginning)) (line-number-at-pos (region-end))))
      (buffer-substring-no-properties (region-beginning) (region-end))
    (thing-at-point 'symbol t)))

(cl-defun drgnx-replace--open (&key symbol text replace opts (scope 'project) origin)
  "Show the Search view searching TEXT (default: the word at point) in SCOPE, REPLACE in the replace field.
SYMBOL: t (on), `auto' (on at a name the language server can rename) or nil.  OPTS: (:case :word :regexp) to set.
ORIGIN: the marker the view works for (default: point in the editor)."
  (let* ((origin (or origin
                     (if (drgnx-signal-editor-window-p (selected-window)) (point-marker)
                       (let ((w (drgnx-wb-editor-window))) (with-current-buffer (window-buffer w) (copy-marker (window-point w)))))))
         (text (or text (with-current-buffer (marker-buffer origin) (save-excursion (goto-char origin) (drgnx-replace--word-here)))))
         (view (drgnx-replace--view-buffer)))
    (with-current-buffer view
      (setq drgnx-replace--origin origin drgnx-replace--root (drgnx-replace--root-of origin))
      (when text (drgnx-replace--fill 'find text))
      (when replace (drgnx-replace--fill 'replace replace))
      (when (drgnx-replace--opt :symbol) (drgnx-replace--set-symbol nil))
      (dolist (k '(:case :word :regexp))
        (when (plist-member opts k)
          (setq drgnx-replace--opts (plist-put drgnx-replace--opts k (plist-get opts k)))
          (drgnx-replace--restyle k)))
      (setq drgnx-replace--opts (plist-put drgnx-replace--opts :scope scope))
      (drgnx-replace--restyle 'project)
      (drgnx-replace--restyle 'file)
      (when (if (eq symbol 'auto) (drgnx-replace--renamable-p origin) symbol) (drgnx-replace--set-symbol t)))
    (drgnx-wb-show-view 'search)
    (select-window (drgnx-wb-section-window 'search))
    (with-current-buffer view
      (drgnx-replace--search-now)
      (goto-char (widget-field-start (drgnx-replace--widget (if (drgnx-replace--opt :symbol) 'replace 'find)))))))

;;;;; Keeping the list current

(defun drgnx-replace--unwatch ()
  "Stop watching the listed files' folders; forget the changes not refreshed yet."
  (dolist (w drgnx-replace--watches) (ignore-errors (file-notify-rm-watch w)))
  (drgnx-timer-cancel (cons 'replace-refresh (current-buffer)))
  (setq drgnx-replace--watches nil drgnx-replace--overflow nil drgnx-replace--changed nil))

(defun drgnx-replace--watch ()
  "Watch the folders of the listed files (the first `drgnx-replace-watch-limit') for changes on disk."
  (drgnx-replace--unwatch)
  (let ((dirs nil) (n 0) (view (current-buffer)))
    (maphash (lambda (f _)
               (when (<= (cl-incf n) drgnx-replace-watch-limit)
                 (cl-pushnew (file-name-directory f) dirs :test #'equal)))
             drgnx-replace--listed)
    (setq drgnx-replace--overflow (> n drgnx-replace-watch-limit))
    (condition-case e
        (dolist (d dirs)
          (unless (file-remote-p d)
            (push (file-notify-add-watch d '(change) (lambda (event) (drgnx-replace--file-event view event)))
                  drgnx-replace--watches)))
      (error (message "drgnx search: files are not watched for changes: %s" (error-message-string e))))))

(defun drgnx-replace--view-killed ()
  "The view's buffer goes: its watches and the edit hook go too."
  (drgnx-replace--unwatch)
  (remove-hook 'after-change-functions #'drgnx-replace--buffer-changed))

(defun drgnx-replace--file-event (view event)
  "A file-notify EVENT for VIEW: a listed file changed on disk (an agent, a checkout, another editor)."
  (condition-case e
      (pcase-let ((`(,_ ,action ,file . ,more) event))
        (when (and (memq action '(created changed deleted renamed)) (buffer-live-p view))
          (with-current-buffer view
            (dolist (f (list file (car more)))
              (when (and (stringp f) (gethash f drgnx-replace--listed)) (drgnx-replace--file-changed f))))))
    (error (message "drgnx search: %s" (error-message-string e)))))

(defun drgnx-replace--buffer-changed (&rest _)
  "After a change in any buffer: when it visits a listed file, that file's rows are searched again."
  (when (and buffer-file-name (not drgnx-replace--applying))
    (condition-case e
        (when-let* ((view (get-buffer drgnx-replace-buffer-name)) (file buffer-file-name))
          (with-current-buffer view
            (when (and drgnx-replace--listed (gethash file drgnx-replace--listed)) (drgnx-replace--file-changed file))))
      (error (message "drgnx search: %s" (error-message-string e))))))

(defun drgnx-replace--file-changed (file)
  "Listed FILE changed: search its rows again after a pause; a symbol list only says it is stale (no request)."
  (if (drgnx-replace--opt :symbol)
      (unless drgnx-replace--stale
        (setq drgnx-replace--stale t)
        (drgnx-replace--message "The code changed: Rename Symbol again to see the edits as they are now"))
    (cl-pushnew file drgnx-replace--changed :test #'equal)
    (drgnx-replace--refresh-later)))

(defun drgnx-replace--refresh-later ()
  "Refresh the changed files' rows after `drgnx-replace-refresh-delay' with no further change (a debounce)."
  (drgnx-timer-debounce (cons 'replace-refresh (current-buffer)) drgnx-replace-refresh-delay #'drgnx-replace--refresh
                        :args (list (current-buffer)) :owner (current-buffer)))

(defun drgnx-replace--refresh (buf)
  "The pause after listed files changed is over: search them again, their rows only.  A timer: never signals."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (condition-case e
          (cond ((drgnx-timer-active-p (cons 'replace-pause buf)) (setq drgnx-replace--changed nil)) ; a new search is coming
                (drgnx-replace--searching (drgnx-replace--refresh-later))                        ; after the search
                (t (let ((files (reverse drgnx-replace--changed)))
                     (setq drgnx-replace--changed nil)
                     (dolist (f files) (when (gethash f drgnx-replace--listed) (drgnx-replace--rescan f)))
                     (drgnx-replace--update-status))))
        (error (drgnx-replace--message "%s" (error-message-string e)))))))

(defun drgnx-replace--scan (file)
  "FILE's matches for the fields' text, read from its buffer when visited (unsaved edits too), else from disk.
Nil when it is gone; `big' when it is bigger than `drgnx-replace-refresh-max-bytes'."
  (let* ((text (drgnx-replace--text 'find)) (case (drgnx-replace--opt :case)) (regexp (drgnx-replace--opt :regexp))
         (re (drgnx-replace--line-regexp (list :text text :regexp regexp :word (drgnx-replace--opt :word))))
         (extra (when regexp (list :pattern (drgnx-replace--emacs-regexp text) :case case)))
         (buf (find-buffer-visiting file)) (root drgnx-replace--root)
         (size (if buf (buffer-size buf) (file-attribute-size (file-attributes file)))))
    (cond
     ((null size) nil)
     ((> size drgnx-replace-refresh-max-bytes) 'big)
     (t (with-temp-buffer
          (if buf
              (insert (with-current-buffer buf
                        (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max)))))
            (insert-file-contents file))
          (let ((case-fold-search (not case)) (line 1) (last (point-min)) (lines nil) (done nil))
            (with-syntax-table drgnx-replace--syntax
              (goto-char (point-min))
              (while (and (not done) (re-search-forward re nil t))
                (let ((bol (line-beginning-position)) (eol (line-end-position)))
                  (setq line (+ line (count-lines last bol)) last bol)
                  ;; the line as grep prints it, read by the same parser as a search's
                  (push (drgnx-replace--grep-line
                         (concat file "\0" (number-to-string line) ":" (buffer-substring-no-properties bol eol))
                         root re case extra)
                        lines)
                  (if (>= eol (point-max)) (setq done t) (goto-char (1+ eol))))))
            (apply #'nconc (nreverse lines))))))))

(defun drgnx-replace--rescan (file)
  "Search FILE again: its rows become its matches now, unticked where an unticked one had the same text around it.
Only FILE's rows move: the old ones go, the new ones come after its header (drawn again for its box); a file with no
match left loses its header too."
  (let ((new (drgnx-replace--scan file)))
    (unless (eq new 'big)
      (let* ((key (lambda (m) (list (plist-get m :before) (plist-get m :text) (plist-get m :after))))
             (mine (lambda (m) (equal (plist-get m :file) file)))
             (olds (seq-filter mine drgnx-replace--matches))
             (old-off (mapcar key (seq-filter (lambda (m) (gethash m drgnx-replace--off)) olds)))
             (pos (seq-position drgnx-replace--matches file (lambda (m _) (funcall mine m))))
             (rest (seq-remove mine drgnx-replace--matches))
             (header (gethash file drgnx-replace--headers)))
        (dolist (m olds) (remhash m drgnx-replace--off))
        (remhash file drgnx-replace--off-files)
        (remhash file drgnx-replace--seen)
        (setq drgnx-replace--matches (if pos (append (seq-take rest pos) new (seq-drop rest pos)) (append rest new))
              drgnx-replace--tail (last drgnx-replace--matches))
        (when new (puthash file (length new) drgnx-replace--seen))
        (dolist (m new) (when (member (funcall key m) old-off) (drgnx-replace--set-tick m nil)))
        (drgnx-view-remove drgnx-view olds)
        (cond ((and new header)
               (drgnx-view-insert drgnx-view new :after header)
               (drgnx-view-dirty drgnx-view (list header))
               (puthash file (car (last new)) drgnx-replace--last-row))
              (new (drgnx-replace--mark-rows file new))
              (header (drgnx-replace--drop-header file)))))))

(defun drgnx-replace--drop-header (file)
  "FILE has no row left: its header goes."
  (drgnx-view-remove drgnx-view (list (gethash file drgnx-replace--headers)))
  (remhash file drgnx-replace--headers)
  (remhash file drgnx-replace--last-row)
  (when (equal file drgnx-replace--end-file) (setq drgnx-replace--end-file nil)))

(defun drgnx-replace--on-show ()
  "The view shows again: when more files were listed than watched, search again (a change may have been missed)."
  (when-let* ((view (get-buffer drgnx-replace-buffer-name)))
    (with-current-buffer view
      (when (and drgnx-replace--overflow (not (drgnx-replace--busy-p)) (not (drgnx-replace--opt :symbol)))
        (drgnx-replace--search-now)))))

;;;;; Commands

(defun drgnx-replace-in-files ()
  "Show the Search view for the project, the word at point to find; Symbol on at a name the server can rename."
  (interactive)
  (drgnx-replace--open :symbol 'auto))

(defun drgnx-replace-rename-symbol ()
  "Show the Search view with Symbol on: the language server's edits for the name at point, the new name to type."
  (interactive)
  (drgnx-replace--open :symbol t))

(defun drgnx-replace--bar-context-p ()
  "Non-nil when the replace commands mean the find bar: in it, or in the buffer it searches."
  (when-let* ((bar (get-buffer drgnx-replace-bar-buffer-name)))
    (or (eq (current-buffer) bar)
        (and (get-buffer-window bar)
             (eq (current-buffer) (with-current-buffer bar (and drgnx-replace--origin (marker-buffer drgnx-replace--origin))))))))

(defun drgnx-replace--apply-report (res)
  "Keep the undo data of RES (from `drgnx-replace-apply') and say what was written."
  (when (plist-get res :undo) (push (plist-get res :undo) drgnx-replace--undo))
  (let ((n (plist-get res :written)) (f (plist-get res :files)) (skipped (length (plist-get res :skipped))))
    (format "Replaced %d in %d file%s%s" n f (if (= f 1) "" "s")
            (if (> skipped 0) (format "; %d skipped (changed since the search)" skipped) ""))))

(defun drgnx-replace--new-name ()
  "The replace field's text; a user error when a symbol would get an empty name."
  (let ((new (drgnx-replace--text 'replace)))
    (when (and (drgnx-replace--opt :symbol) (string-empty-p new)) (user-error "Type the new name first"))
    new))

(defun drgnx-replace-all ()
  "Replace every ticked match of the Search view (in the find bar: every match of its buffer)."
  (interactive)
  (if (drgnx-replace--bar-context-p)
      (with-current-buffer drgnx-replace-bar-buffer-name (drgnx-replace--bar-replace-all))
    (with-current-buffer (drgnx-replace--live-view)
      (let ((new (drgnx-replace--new-name))
            (ms (seq-remove (lambda (m) (gethash m drgnx-replace--off)) drgnx-replace--matches)))
        (unless ms (user-error "Nothing to replace: no match is ticked"))
        (drgnx-replace-cancel drgnx-replace--handle)
        (setq drgnx-replace--handle nil drgnx-replace--searching nil)
        (let* ((res (let ((drgnx-replace--applying t)) (drgnx-replace-apply ms new)))
               (msg (drgnx-replace--apply-report res)))
          (drgnx-replace--clear)
          (drgnx-replace--add (plist-get res :skipped))       ; what is left: the skipped, with their reasons
          (drgnx-replace--watch)
          (drgnx-replace--message "%s" msg))))))

(defun drgnx-replace-this ()
  "Replace the match on this row of the Search view, ticked or not."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (let ((m (or (get-text-property (point) 'drgnx-replace-match) (user-error "No match on this row")))
          (new (drgnx-replace--new-name)))
      (let* ((res (let ((drgnx-replace--applying t)) (drgnx-replace-apply (list m) new)))
             (msg (drgnx-replace--apply-report res)))
        (if (plist-get res :skipped)
            (setq msg (format "Skipped: %s" (plist-get (car (plist-get res :skipped)) :reason)))
          ;; the match is gone; later matches on its line moved
          (let ((delta (- (length (or (drgnx-replace-new-text m new) "")) (length (plist-get m :text)))))
            (setq drgnx-replace--matches (delq m drgnx-replace--matches)
                  drgnx-replace--tail (last drgnx-replace--matches))
            (dolist (o drgnx-replace--matches)
              (when (and (equal (plist-get o :file) (plist-get m :file)) (= (plist-get o :line) (plist-get m :line))
                         (>= (plist-get o :col) (plist-get m :end)))
                (plist-put o :col (+ (plist-get o :col) delta))
                (plist-put o :end (+ (plist-get o :end) delta))))
            (cl-decf (gethash (plist-get m :file) drgnx-replace--seen 0))
            (when (gethash m drgnx-replace--off)
              (remhash m drgnx-replace--off)
              (cl-decf (gethash (plist-get m :file) drgnx-replace--off-files 0)))
            ;; its row goes; its file's header shows the new count, or goes with its last row
            (let ((file (plist-get m :file)))
              (drgnx-view-remove drgnx-view (list m))
              (if (zerop (gethash file drgnx-replace--seen 0))
                  (progn (remhash file drgnx-replace--seen) (drgnx-replace--drop-header file))
                (drgnx-view-dirty drgnx-view (list (gethash file drgnx-replace--headers)))
                (when (eq m (gethash file drgnx-replace--last-row))
                  (puthash file (car (last (seq-filter (lambda (o) (equal (plist-get o :file) file))
                                                       drgnx-replace--matches)))
                           drgnx-replace--last-row))))))
        (setq drgnx-replace--status msg)
        (drgnx-replace--update-status)))))

(defun drgnx-replace-view-undo ()
  "Undo the Search view's last replacement, in every file it wrote; then search again."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (let* ((u (or (pop drgnx-replace--undo) (user-error "Nothing to undo")))
           (r (let ((drgnx-replace--applying t)) (drgnx-replace-undo u))) (skipped (plist-get r :skipped)))
      (drgnx-replace--search-now)
      (drgnx-replace--message "Undone in %d file%s%s" (plist-get r :undone) (if (= (plist-get r :undone) 1) "" "s")
                              (if skipped (format "; left alone (changed since): %s"
                                                  (mapconcat #'file-name-nondirectory skipped ", "))
                                "")))))

(defun drgnx-replace--next-row (pos dir)
  "The start of the next row with a match after (DIR 1) or before (DIR -1) POS's row, wrapping; nil without rows."
  (save-excursion
    (goto-char pos)
    (let ((start (line-beginning-position)) (found nil) (wrapped nil))
      (while (not found)
        (if (zerop (forward-line dir))
            (when (and (> dir 0) (eobp)) (setq found 'edge))
          (setq found 'edge))
        (cond ((eq found 'edge)
               (if wrapped (setq found 'none)
                 (setq wrapped t found nil)
                 (goto-char (if (> dir 0) drgnx-replace--results (point-max)))
                 (when (get-text-property (line-beginning-position) 'drgnx-replace-match)
                   (setq found (line-beginning-position)))))
              ((get-text-property (point) 'drgnx-replace-match) (setq found (point)))
              ((and wrapped (= (point) start)) (setq found 'none))))
      (and (integerp found) (>= found drgnx-replace--results) found))))

(defun drgnx-replace--step (dir)
  "The next (DIR 1) or previous (DIR -1) match: in the find bar, or the Search view's, shown in the editor."
  (if (drgnx-replace--bar-context-p)
      (with-current-buffer drgnx-replace-bar-buffer-name (drgnx-replace--bar-step dir))
    (with-current-buffer (drgnx-replace--live-view)
      (let* ((win (get-buffer-window (current-buffer)))
             (pos (drgnx-replace--next-row (if win (window-point win) (point)) dir)))
        (unless pos (user-error "No matches"))
        (goto-char pos)
        (when win (set-window-point win pos))
        (drgnx-replace--show-match (get-text-property pos 'drgnx-replace-match) nil)))))

(defun drgnx-replace-next () "The next match, shown in the editor." (interactive) (drgnx-replace--step 1))
(defun drgnx-replace-prev () "The previous match, shown in the editor." (interactive) (drgnx-replace--step -1))

;;;;; The find bar

(defun drgnx-replace--bar-buffer ()
  "The find bar's buffer, drawn the first time."
  (or (get-buffer drgnx-replace-bar-buffer-name)
      (with-current-buffer (get-buffer-create drgnx-replace-bar-buffer-name)
        (drgnx-replace-bar-mode)
        (setq drgnx-replace--opts (list :symbol nil :case nil :word nil :regexp nil :scope 'file)
              drgnx-replace--widgets nil)
        (drgnx-replace--insert-field 'find "Find    " 24)
        (widget-insert " ")
        (drgnx-replace--insert-toggles)
        (setq drgnx-replace--status-beg (point-marker))
        (widget-insert " ")
        (setq drgnx-replace--status-end (copy-marker (1- (point)) t))
        (widget-insert " ")
        (drgnx-replace--insert-button nil "↑" "Previous match (S-RET)" (lambda () (drgnx-replace--bar-step -1)))
        (drgnx-replace--insert-button nil "↓" "Next match (RET)" (lambda () (drgnx-replace--bar-step 1)))
        (drgnx-replace--insert-button nil "×" "Close (ESC)" #'drgnx-replace-bar-close)
        (widget-insert "\n")
        (drgnx-replace--insert-field 'replace "Replace " 24)
        (widget-insert " ")
        (drgnx-replace--insert-button nil "Replace" "Replace this match (RET in the field)" #'drgnx-replace--bar-replace-one)
        (drgnx-replace--insert-button nil "Replace All" "Replace every match (C-RET)" #'drgnx-replace--bar-replace-all)
        (drgnx-replace--insert-button nil "Show all in sidebar" "Move the search to the Search view"
                                      #'drgnx-replace-bar-show-all)
        (widget-setup)
        (current-buffer))))

(defun drgnx-replace--bar-target ()
  "The buffer the find bar searches, or nil: the one shown below it (followed when the window shows another)."
  (when-let* ((w (get-buffer-window (current-buffer))) (below (window-in-direction 'below w))
              ((not (and (markerp drgnx-replace--origin) (eq (window-buffer below) (marker-buffer drgnx-replace--origin))))))
    (setq drgnx-replace--origin (with-current-buffer (window-buffer below) (copy-marker (window-point below)))))
  (and (markerp drgnx-replace--origin) (buffer-live-p (marker-buffer drgnx-replace--origin))
       (marker-buffer drgnx-replace--origin)))

(defun drgnx-replace--bar-window (editor)
  "A two-line window for the find bar above EDITOR (the one there already, when it is)."
  (let ((old (get-buffer-window drgnx-replace-bar-buffer-name)))
    (if (and old (eq (window-in-direction 'below old) editor))
        old
      (when old (delete-window old))
      (let* ((window-min-height 1) (window-safe-min-height 1)
             (w (split-window editor -4 'above)))
        (set-window-parameter w 'drgnx-role 'bar)
        (set-window-buffer w (drgnx-replace--bar-buffer))
        (set-window-dedicated-p w t)
        (ignore-errors (window-resize w (- 2 (window-total-height w)) nil t))
        (window-preserve-size w nil t)
        w))))

(defun drgnx-replace--bar-clear ()
  "Take the bar's highlights out."
  (mapc #'delete-overlay drgnx-replace--bar-overlays)
  (setq drgnx-replace--bar-overlays nil drgnx-replace--bar-index nil))

(defun drgnx-replace--bar-count (text)
  "Show TEXT (\"2 of 5\", an error) in the bar."
  (drgnx-replace--drawing
   (delete-region drgnx-replace--status-beg drgnx-replace--status-end)
   (goto-char drgnx-replace--status-beg)
   (insert (propertize text 'face 'drgnx-replace-dim))))

(defun drgnx-replace--bar-ranges (buf)
  "The matches in BUF as (BEG END MATCH-or-nil): the server's edits in symbol mode, else the fields' text.
A string instead when there are none for a reason."
  (let ((text (drgnx-replace--text 'find)))
    (cond
     ((string-empty-p text) nil)
     ((drgnx-replace--opt :symbol)
      (let ((ms nil) (err nil) (file (buffer-file-name buf)) (origin drgnx-replace--origin)) ; the bar's, not BUF's
        (with-current-buffer buf
          (save-excursion
            (goto-char origin)
            (drgnx-replace-symbol-edits (lambda (x) (cond ((eq x :done)) ((eq (car-safe x) :error) (setq err (cadr x)))
                                                          (t (setq ms (append ms x))))))
            (or (delq nil (mapcar (lambda (m)
                                    (when (and file (file-equal-p (plist-get m :file) file))
                                      (goto-char (point-min))
                                      (forward-line (1- (plist-get m :line)))
                                      (let ((b (+ (point) (plist-get m :col))))
                                        (list b (+ b (length (plist-get m :text))) m))))
                                  ms))
                err)))))
     (t
      (let ((re (drgnx-replace--line-regexp (list :text text :regexp (drgnx-replace--opt :regexp)
                                                  :word (drgnx-replace--opt :word))))
            (case-fold-search (not (drgnx-replace--opt :case))) (out nil) (n 0))
        (with-current-buffer buf
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              (with-syntax-table drgnx-replace--syntax
                (condition-case e
                    (while (and (< n drgnx-replace-bar-limit) (not (eobp)) (re-search-forward re nil t))
                      (if (= (match-beginning 0) (match-end 0))
                          (unless (eobp) (forward-char 1))
                        (push (list (match-beginning 0) (match-end 0) nil) out)
                        (cl-incf n)))
                  (invalid-regexp (setq out (format "Invalid regexp: %s" (cadr e))))))))
          (if (stringp out) out (nreverse out))))))))

(defun drgnx-replace--bar-search ()
  "Highlight the fields' matches in the bar's buffer; the current one is the one at point, else the next."
  (drgnx-replace--bar-clear)
  (let* ((buf (drgnx-replace--bar-target))
         (ranges (and buf (drgnx-replace--bar-ranges buf))))
    (if (stringp ranges)
        (drgnx-replace--bar-count ranges)
      (setq drgnx-replace--bar-overlays
            (mapcar (pcase-lambda (`(,b ,e ,m))
                      (let ((o (make-overlay b e buf)))
                        (overlay-put o 'face 'drgnx-replace-match)
                        (overlay-put o 'priority 1000)
                        (overlay-put o 'drgnx-replace-m m)
                        o))
                    ranges))
      (let* ((w (get-buffer-window buf)) (pt (if w (window-point w) (with-current-buffer buf (point)))))
        (setq drgnx-replace--bar-index
              (and drgnx-replace--bar-overlays
                   (or (seq-position drgnx-replace--bar-overlays pt (lambda (o p) (> (overlay-end o) p))) 0))))
      (drgnx-replace--bar-mark))))

(defun drgnx-replace--bar-mark ()
  "Show which match is current, and the count."
  (let ((n (length drgnx-replace--bar-overlays)))
    (seq-do-indexed (lambda (o i) (overlay-put o 'face (if (eql i drgnx-replace--bar-index) 'drgnx-replace-current
                                                         'drgnx-replace-match)))
                    drgnx-replace--bar-overlays)
    (drgnx-replace--bar-count (cond ((zerop n) (if (string-empty-p (drgnx-replace--text 'find)) "" "No results"))
                                    (t (format "%d of %d%s" (1+ drgnx-replace--bar-index) n
                                               (if (>= n drgnx-replace-bar-limit) "+" "")))))))

(defun drgnx-replace--bar-step (dir)
  "Make the next (DIR 1) or previous (DIR -1) match current, wrapping, and move the editor's point there."
  (when-let* ((n (and drgnx-replace--bar-overlays (length drgnx-replace--bar-overlays))))
    (setq drgnx-replace--bar-index (mod (+ (or drgnx-replace--bar-index -1) dir) n))
    (drgnx-replace--bar-mark)
    (let* ((o (nth drgnx-replace--bar-index drgnx-replace--bar-overlays)) (buf (overlay-buffer o)))
      (with-current-buffer buf (goto-char (overlay-start o)))
      (when-let* ((w (get-buffer-window buf))) (set-window-point w (overlay-start o))))))

(defun drgnx-replace--bar-spec ()
  "What the bar replaces with: (REGEXP CASE-FOLD LITERAL), from its fields and toggles."
  (list (drgnx-replace--line-regexp (list :text (drgnx-replace--text 'find) :regexp (drgnx-replace--opt :regexp)
                                          :word (drgnx-replace--opt :word)))
        (not (drgnx-replace--opt :case)) (not (drgnx-replace--opt :regexp))))

(defun drgnx-replace--bar-replacement (o new spec)
  "Replace the match of overlay O by NEW, in O's buffer (current); SPEC from `drgnx-replace--bar-spec'.
Nil when the match's text changed."
  (let ((m (overlay-get o 'drgnx-replace-m)) (b (overlay-start o)) (e (overlay-end o)))
    (goto-char b)
    (if m
        (when (equal (buffer-substring-no-properties b e) (plist-get m :text))
          (delete-region b e) (insert (drgnx-replace-new-text m new)) t)
      (pcase-let ((`(,re ,case-fold-search ,literal) spec))
        (with-syntax-table drgnx-replace--syntax
          (when (and (looking-at re) (= (match-end 0) e))
            (replace-match new t literal)
            t))))))

(defun drgnx-replace--bar-replace-all ()
  "Replace every match of the bar's buffer: one undo step, the buffer left unsaved."
  (let* ((new (drgnx-replace--new-name)) (spec (drgnx-replace--bar-spec)) (ovs (reverse drgnx-replace--bar-overlays))
         (n 0))
    (unless ovs (user-error "No matches"))
    (with-current-buffer (overlay-buffer (car ovs))
      (let ((g (prepare-change-group)))
        (condition-case e
            (save-excursion
              (activate-change-group g)
              (dolist (o ovs) (when (drgnx-replace--bar-replacement o new spec) (cl-incf n)))
              (undo-amalgamate-change-group g)
              (accept-change-group g))
          (error (cancel-change-group g) (signal (car e) (cdr e))))))
    (drgnx-replace--bar-search)
    (message "Replaced %d" n)))

(defun drgnx-replace--bar-replace-one ()
  "Replace the current match of the bar's buffer, then make the next one current."
  (let* ((new (drgnx-replace--new-name)) (spec (drgnx-replace--bar-spec))
         (o (or (and drgnx-replace--bar-index (nth drgnx-replace--bar-index drgnx-replace--bar-overlays))
                (user-error "No match")))
         (i drgnx-replace--bar-index))
    (with-current-buffer (overlay-buffer o)
      (save-excursion (drgnx-replace--bar-replacement o new spec)))
    (drgnx-replace--bar-search)
    (when drgnx-replace--bar-overlays
      (setq drgnx-replace--bar-index (min i (1- (length drgnx-replace--bar-overlays))))
      (drgnx-replace--bar-mark))))

(defun drgnx-replace-in-file ()
  "The find bar above the editor: find and replace in its buffer, the word at point to find."
  (interactive)
  (let* ((editor (if (drgnx-signal-editor-window-p (selected-window)) (selected-window) (drgnx-wb-editor-window)))
         (buf (window-buffer editor))
         (origin (with-current-buffer buf (copy-marker (window-point editor))))
         (word (with-current-buffer buf (save-excursion (goto-char origin) (drgnx-replace--word-here))))
         (w (drgnx-replace--bar-window editor)))
    (with-current-buffer (window-buffer w)
      (setq drgnx-replace--origin origin)
      (when word (drgnx-replace--fill 'find word))
      (drgnx-replace--set-symbol (drgnx-replace--renamable-p origin))
      (drgnx-replace--bar-search))
    (select-window w)
    (goto-char (widget-field-start (drgnx-replace--widget 'find)))))

(defun drgnx-replace-bar-close ()
  "Close the find bar and its highlights; back to the editor."
  (interactive)
  (when-let* ((bar (get-buffer drgnx-replace-bar-buffer-name)))
    (let ((target (with-current-buffer bar (drgnx-replace--bar-clear) (drgnx-replace--bar-target)))
          (w (get-buffer-window bar)))
      (when (window-live-p w)
        (let ((below (window-in-direction 'below w)))
          (delete-window w)
          (when (and (window-live-p below) (eq (window-buffer below) target)) (select-window below)))))))

(declare-function drgnx-persist--save-skipped-p "drgnx-persist")

(defun drgnx-replace--close-bars (&optional _file frames)
  "Close the find bar in every frame: before the workbench is saved, so a restart never brings back its window.
Not when the save writes nothing (from a terminal window; FRAMES is what `drgnx-persist-save' was given).
An error here is ignored: it must never make the save fail."
  (ignore-errors
    (when-let* (((not (drgnx-persist--save-skipped-p frames)))
                (bar (get-buffer drgnx-replace-bar-buffer-name)))
      (with-current-buffer bar (drgnx-replace--bar-clear))
      (dolist (w (get-buffer-window-list bar nil t))
        (when (window-live-p w) (ignore-errors (delete-window w)))))))

(defun drgnx-replace-bar-show-all ()
  "Move the find bar's search to the Search view, scope This file.
The find bar's button; not a command of its own (it needs the bar)."
  (with-current-buffer (drgnx-replace--bar-buffer)
    (let ((text (drgnx-replace--text 'find)) (new (drgnx-replace--text 'replace)) (origin drgnx-replace--origin)
          (opts (list :case (drgnx-replace--opt :case) :word (drgnx-replace--opt :word) :regexp (drgnx-replace--opt :regexp)))
          (symbol (drgnx-replace--opt :symbol)))
      (drgnx-replace-bar-close)
      (drgnx-replace--open :symbol symbol :text text :replace new :opts opts :scope 'file
                           :origin (and (markerp origin) (marker-buffer origin) origin)))))

(defun drgnx-replace--define-commands ()
  "Register the replace commands (category Search)."
  (pcase-dolist (`(,id ,title ,fn ,doc ,scope)
                 '((replace-in-files "Replace in Files" drgnx-replace-in-files
                                     "The Search view for the project, the word at point to find")
                   (rename-symbol "Rename Symbol" drgnx-replace-rename-symbol
                                  "The Search view with Symbol on: the language server's edits, one new name")
                   (replace-in-file "Replace in File" drgnx-replace-in-file
                                    "The find bar above the editor: find and replace in this buffer" editing)
                   (replace-all "Replace All" drgnx-replace-all
                                "Replace every ticked match of the Search view (the find bar: every match)")
                   (replace-undo "Undo Replace" drgnx-replace-view-undo
                                 "Undo the Search view's last replacement, in every file")
                   (replace-next "Next Match" drgnx-replace-next "The next match, shown in the editor")
                   (replace-prev "Previous Match" drgnx-replace-prev "The previous match, shown in the editor")
                   (replace-bar-close "Close Find Bar" drgnx-replace-bar-close "Close the find bar and its highlights")))
    (drgnx-command-define id :category "Search" :title title :command fn :doc doc :scope scope))
  (drgnx-command-define 'replace-this :category "Search" :title "Replace This Match" :command #'drgnx-replace-this
                        :doc "Replace the match on this row of the Search view"
                        :when (lambda () (derived-mode-p 'drgnx-replace-mode))))

(defun drgnx-replace--teardown ()
  "Turn the Search view and the find bar off: close the bar, stop what the view runs (search, drawing, file
watches), kill both buffers.  Never asks.  Their pauses and refreshes are layer keys the buffers own: killing them
cancels those."
  (drgnx-replace-bar-close)
  (let ((kill-buffer-query-functions nil))
    (dolist (name (list drgnx-replace-buffer-name drgnx-replace-bar-buffer-name))
      (when-let* ((buf (get-buffer name)))
        (with-current-buffer buf
          (drgnx-replace-cancel drgnx-replace--handle)
          (setq drgnx-replace--handle nil)
          (drgnx-replace--unwatch))
        (kill-buffer buf)))))

;; Startup, not idle: `View: Search' (C-S-f) works from the first second, as the Explorer's key does.
(drgnx-module-define 'tools/replace
                     :doc "Search and replace across files: text through ripgrep or git grep, symbols through the language server."
                     :stage 'startup
                     :teardown #'drgnx-replace--teardown
                     :setup (lambda ()
                              (drgnx-replace--define-section)
                              (drgnx-replace--define-commands)
                              (drgnx-state-define-role 'bar) ; the find bar's window: no editor, no chrome
                              (eval-after-load 'evil (drgnx-modules-with-owner (drgnx-replace--evil-states)))
                              ;; wb/drgnx-persist.el saves the main area with `window-state-get': the bar's window would be in it.
                              (advice-add 'drgnx-persist-save :before #'drgnx-replace--close-bars)))

(provide 'drgnx-replace)
;;; drgnx-replace.el ends here
