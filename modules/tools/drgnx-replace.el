;;; drgnx-replace.el --- Module tools/replace: search and replace across files, text or symbol -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; VS Code's Search & Replace.  Text: the hub searches (`search/run') and streams the rows; Sjá holds the model the
;; keys walk; a search typed before the hub is up waits for it.  Symbol: the language server's rename edits (asked for
;; with a placeholder name, never applied by the server), as matches of Emacs's own.  Replacing checks every
;; match against the file as it is now (its buffer when visited) and skips the stale ones; each file is one change
;; group, saved unless its buffer held unsaved edits (they stay unsaved), so one Undo puts every file back.
;; The UI: the Search view in the sidebar (fields, toggles, a result tree with tick boxes and old → new previews: the
;; hub's rows, or a view's own rows in Symbol mode, wb/drgnx-view.el, patched in place) and the
;; find bar above an editor, which searches its own buffer in Emacs.  See
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
(require 'drgnx-view-nav)
(require 'drgnx-large-file)             ; a large file: Replace needs it whole (lean), never asks; skips chunks and raw

(declare-function eglot-current-server "eglot")
(declare-function eglot-server-capable "eglot")
(declare-function eglot--TextDocumentPositionParams "eglot")
(declare-function eglot-move-to-utf-16-linepos "eglot")
(declare-function eglot--signal-textDocument/didChange "eglot")
(declare-function jsonrpc-request "jsonrpc")
(declare-function project-root "project")
(declare-function nidhogg-view-get "nidhogg-views" (h what &optional arg arg2))
(declare-function nidhogg-view-set "nidhogg-views" (h what value))
(declare-function drgnx-hub--call-on "drgnx-hub-client")
(declare-function drgnx-view-env-register "drgnx-view-env" (view buffer &optional resubscribe))
(declare-function drgnx-view-env-unregister "drgnx-view-env" (view))
(defvar drgnx-hub--events)
(defvar drgnx-hub-event-functions)
(defvar eglot-move-to-linepos-function)
(defvar apheleia-format-after-save-in-progress) ; bound around our saves: no format on save (extra/format)

(defvar drgnx-replace-view "search" "The hub's view id of the Search view's results (tests bind a name of their own).")

(defvar drgnx-replace-context-chars 80 "Characters of the line kept before and after a match (:before, :after).")

(defconst drgnx-replace--rename-suffix "_drgnx_rename"
  "Appended to the symbol at point to make the placeholder name a rename is asked for with.")

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

;;;; Text matches (a modified buffer's rescan: `drgnx-replace--scan')

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
CALLBACK gets the edits as one batch of matches (as `drgnx-replace--match' makes them, with :new, the server's text
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

(defun drgnx-replace--partial (buf)
  "Why BUF, a file's visiting buffer (or nil), cannot take the whole file's lines and columns: a reason, else nil.
A large file open in chunks holds one part of the file; one open raw holds its bytes undecoded."
  (pcase (and buf (buffer-local-value 'drgnx-large-file buf))
    ('chunks "open in chunks: Large File: Open Whole first")
    ('raw "open raw: Large File: Open Whole first")))

(defun drgnx-replace--save ()
  "Save this buffer quietly and without format on save (a formatter's rewrite would make Undo skip the file)."
  (let ((save-silently t) (apheleia-format-after-save-in-progress t))
    (save-buffer)))

(defun drgnx-replace--apply-file (file ms new)
  "Replace FILE's matches MS by NEW in one change group: (WRITTEN SKIPPED UNDO-ENTRY-or-nil).
The buffer is saved unless it held unsaved edits before."
  (let* ((buf (find-buffer-visiting file)) (partial (drgnx-replace--partial buf)))
    (cond
     ((not (file-exists-p file))
      (list 0 (mapcar (lambda (m) (drgnx-replace--skip m "the file is gone")) ms) nil))
     (partial (list 0 (mapcar (lambda (m) (drgnx-replace--skip m partial)) ms) nil))
     ((and buf (buffer-modified-p buf) (not (verify-visited-file-modtime buf)))
      (list 0 (mapcar (lambda (m) (drgnx-replace--skip m "changed on disk and in its buffer")) ms) nil))
     (t
      (when (and buf (not (verify-visited-file-modtime buf)))
        (with-current-buffer buf (revert-buffer t t t)))
      (setq buf (or buf (let ((large-file-warning-threshold nil) (drgnx-large-file-open 'whole)) (find-file-noselect file))))
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
  "Replace MATCHES (from `drgnx-replace--scan' or `drgnx-replace-symbol-edits') by NEW, file by file.
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
(defvar-local drgnx-replace--local nil
  "On the rows path, hash FILE → the matches Emacs scanned in its modified buffer (they replace the hub's rows of FILE).")
(defvar-local drgnx-replace--local-rows nil "Hash row key → the row shown for a file of `drgnx-replace--local'.")
(defvar-local drgnx-replace--local-ids nil "Hash row key → the match of that row, for a file of `drgnx-replace--local'.")
(defvar-local drgnx-replace--local-hub nil "Hash FILE → (HEADERS . MATCHES) the hub had of it before its rows were replaced.")
(defvar-local drgnx-replace--local-delta nil "(FILES . MATCHES) the local rows add to the hub's counts.")
(defvar-local drgnx-replace--look-at nil "The number of rows the view had when it last asked the hub for more.")
(defvar-local drgnx-replace--fill-at nil "The rows' version when the view last asked for the rows before the gap.")
(defvar-local drgnx-replace--reach-id nil "The match whose row was asked for and has not arrived: point goes there when it does.")
(defvar-local drgnx-replace--hub-counts nil
  "On the rows path, (FILES . MATCHES) the hub's last search found, from `search-run-done'; nil while it runs.")
(defvar-local drgnx-replace--carry nil
  "The match ids the user unticked before a new search, sent with it (`search/run''s `off'): the hub names the same
matches of the new run in `search-run-done', which are unticked again.")
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
(defvar-local drgnx-replace--waiting nil "Non-nil while a text search waits for the hub (`drgnx-replace--hub-up').")
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
  (let* ((n (if drgnx-view-patch (+ (or (cdr drgnx-replace--hub-counts) 0) (or (cdr drgnx-replace--local-delta) 0)) (length drgnx-replace--matches)))
         (files (if drgnx-view-patch (+ (or (car drgnx-replace--hub-counts) 0) (or (car drgnx-replace--local-delta) 0)) (hash-table-count drgnx-replace--seen)))
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
  (unless drgnx-view-patch (drgnx-view-reset drgnx-view nil))   ; hub-fed: the hub's reset takes the rows out
  (setq drgnx-replace--matches nil drgnx-replace--tail nil drgnx-replace--status "" drgnx-replace--end-file nil
        drgnx-replace--look-at nil drgnx-replace--fill-at nil drgnx-replace--reach-id nil
        drgnx-replace--hub-counts nil drgnx-replace--local nil drgnx-replace--local-rows nil drgnx-replace--local-ids nil
        drgnx-replace--local-hub nil drgnx-replace--local-delta nil
        drgnx-replace--new (drgnx-replace--text 'replace))
  (dolist (h (list drgnx-replace--seen drgnx-replace--off drgnx-replace--off-files drgnx-replace--listed
                   drgnx-replace--headers drgnx-replace--last-row))
    (clrhash h))
  (drgnx-replace--rows-untick-all)
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
  (if drgnx-view-patch
      (progn (drgnx-replace--hub-call "search/grep-replace" (list :view drgnx-replace-view :replace drgnx-replace--new))
             (drgnx-replace--local-refresh))
    (drgnx-view-dirty drgnx-view drgnx-replace--matches))
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
    (cond
     ((drgnx-replace--rows-p) (drgnx-replace--rows-tick (get-text-property (button-start button) 'drgnx-work-id)))
     ((stringp v)
      (let ((ms (seq-filter (lambda (m) (equal (plist-get m :file) file)) drgnx-replace--matches)))
        (let ((on (not (seq-some (lambda (m) (not (gethash m drgnx-replace--off))) ms))))
          (dolist (m ms) (drgnx-replace--set-tick m on)))
        (drgnx-replace--refresh-boxes file)))
     (t (drgnx-replace--set-tick v (gethash v drgnx-replace--off))
        (drgnx-replace--refresh-boxes file)))))

(defun drgnx-replace--row-pressed (button)
  "Show BUTTON's match in the editor and go there."
  (drgnx-replace--show-match (get-text-property (button-start button) 'drgnx-replace-match) t))

(defun drgnx-replace--show-match (m select)
  "Show match M in the editor, scrolled to it, marked; move there when SELECT.
A file open in chunks or raw has no place for the whole file's line and column: shown as it is, unmarked, and the
echo area says why."
  (let* ((visiting (find-buffer-visiting (plist-get m :file))) (partial (drgnx-replace--partial visiting)))
    (if partial
        (progn
          (when (overlayp drgnx-replace--shown) (delete-overlay drgnx-replace--shown))
          (drgnx-wb-show-in-editor visiting select)
          (message "%s is %s" (file-name-nondirectory (plist-get m :file)) partial))
      (drgnx-replace--show-match-at m select))))

(defun drgnx-replace--show-match-at (m select)
  "Show match M in the editor at its whole-file line and column, marked; move there when SELECT."
  (let* ((view (current-buffer))
         (buf (let ((large-file-warning-threshold nil) (drgnx-large-file-open 'whole)) (find-file-noselect (plist-get m :file))))
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

(defun drgnx-replace--search-now ()
  "Search now with the fields and toggles: the language server's edits in symbol mode, else the files' text."
  (drgnx-timer-cancel (cons 'replace-pause (current-buffer)))
  (setq drgnx-replace--want nil)
  (setq drgnx-replace--searching nil)
  ;; the unticked matches go with the search, before the new search empties the ticks
  (setq drgnx-replace--carry (append (drgnx-replace--rows-carry) drgnx-replace--carry))
  (drgnx-replace--clear)
  (drgnx-replace--ensure-origin)
  (when (drgnx-replace--opt :symbol) (drgnx-replace--hub-detach))   ; the server's edits are rows of Emacs's own
  (let ((err (and (drgnx-replace--opt :symbol) (drgnx-replace--symbol-search))))
    (when (eq err 'nothing) (setq err nil))
    (when err (drgnx-replace--set-symbol nil))        ; no edits from the server: search the text instead
    (if (drgnx-replace--opt :symbol) (drgnx-replace--watch) (drgnx-replace--text-search))
    (if err (drgnx-replace--message "%s" err) (drgnx-replace--update-status))))

(defun drgnx-replace--text-search ()
  "Search the fields' text through the hub; with the hub not up yet, say so and search when it is
\(`drgnx-replace--hub-up')."
  (let ((text (drgnx-replace--text 'find)) (file (and (eq (drgnx-replace--opt :scope) 'file) (drgnx-replace--origin-file))))
    (setq drgnx-replace--waiting nil)
    (cond ((drgnx-replace--hub-ready-p) (drgnx-replace--hub-search text file))
          ((string-empty-p text))
          ((not (fboundp 'nidhogg-view--call))
           (setq drgnx-replace--status "Search needs Nidhogg's view model (Sjá), which this Emacs has not got"))
          (t (setq drgnx-replace--waiting t drgnx-replace--status "Waiting for the hub: the search starts when it is up")))))

(defun drgnx-replace--hub-up ()
  "`drgnx-hub-connected-functions': a search that waited for the hub starts now."
  (when-let* ((buf (get-buffer drgnx-replace-buffer-name)))
    (with-current-buffer buf
      (when drgnx-replace--waiting (drgnx-replace--search-now)))))

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
  (setq drgnx-replace--watches nil drgnx-replace--changed nil))

(defun drgnx-replace--watch ()
  "Watch the folders of the listed files (the first `drgnx-replace-watch-limit') for changes on disk."
  (drgnx-replace--unwatch)
  (let ((dirs nil) (n 0) (view (current-buffer)))
    (maphash (lambda (f _)
               (when (<= (cl-incf n) drgnx-replace-watch-limit)
                 (cl-pushnew (file-name-directory f) dirs :test #'equal)))
             drgnx-replace--listed)
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
  "After a change in any buffer: when it visits a listed file, that file's rows are searched again.  Not on the rows
path: the hub reads the disk, which an unsaved edit has not changed (the save is a file event), so the modified
buffers' rows are rescanned by Emacs after a pause (`drgnx-replace--local-refresh')."
  (when (and buffer-file-name (not drgnx-replace--applying))
    (condition-case e
        (when-let* ((view (get-buffer drgnx-replace-buffer-name)) (file buffer-file-name))
          (with-current-buffer view
            (cond (drgnx-view-patch (drgnx-replace--local-later))
                  ((and drgnx-replace--listed (gethash file drgnx-replace--listed)) (drgnx-replace--file-changed file)))))
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
  "The pause after listed files changed is over: search again (the hub reads the disk).  A timer: never signals."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (condition-case e
          (cond ((drgnx-timer-active-p (cons 'replace-pause buf)) (setq drgnx-replace--changed nil)) ; a new search is coming
                (drgnx-replace--searching (drgnx-replace--refresh-later))                        ; after the search
                (drgnx-replace--changed                                     ; the hub reads the disk again
                 (setq drgnx-replace--changed nil)
                 (drgnx-replace--search-now)))
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
          (cond (buf
                 (insert (with-current-buffer buf
                           (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))))
                (t (insert-file-contents file)))
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

(defun drgnx-replace--drop-header (file)
  "FILE has no row left: its header goes."
  (drgnx-view-remove drgnx-view (list (gethash file drgnx-replace--headers)))
  (remhash file drgnx-replace--headers)
  (remhash file drgnx-replace--last-row)
  (when (equal file drgnx-replace--end-file) (setq drgnx-replace--end-file nil)))

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

;;;;; On the rows path: the keys, the ticks and Replace All through the native view model (Sjá)
;; Fed by the hub's `search/run', the Search view's results are a `tree' model: a node per file (`f:FILE'), its
;; matches as children (`m:RUN:N', opaque: the run's number and the match's), the rows' keys and their
;; `drgnx-work-id'.  The match keys walk it in-process.  The ticks are user state: Sjá's ticked set of the view's
;; instance holds the matches the user unticked (a file's box ticks or unticks all of its matches), shown over the
;; hub's "[x]" boxes; a new search sends them (`drgnx-replace--carry') and unticks the same matches of its run when it
;; ends.  Replace All writes the matches not in it, read from the model's fields.

(defvar-local drgnx-replace--box-overlays nil "Hash ROW-KEY → the overlay showing its tick box as the ticks say.")

(defun drgnx-replace--rows-p ()
  "Whether the Search view is hub-fed with Sjá's model (the rows path)."
  (and drgnx-view-patch (drgnx-view-patch-handle drgnx-view-patch) t))

(defun drgnx-replace-rows-attached ()
  "The Search view is now hub-fed (the rows path): its tick boxes follow the ticks after every draw."
  (add-hook 'drgnx-view-patch-patched-functions #'drgnx-replace--rows-boxes nil t)
  (add-hook 'drgnx-view-patch-patched-functions #'drgnx-replace--local-patched nil t)
  (add-hook 'drgnx-view-patch-patched-functions #'drgnx-replace--reached nil t)
  (add-hook 'drgnx-view-nav-paged-functions #'drgnx-replace--paged nil t)
  (add-hook 'window-scroll-functions #'drgnx-replace--scrolled nil t))

(defun drgnx-replace--paged (id)
  "`drgnx-view-nav-paged-functions': Next Match waited for the model's next window and moved to ID: its row is shown."
  (when (stringp id) (drgnx-replace--reach id)))

(defun drgnx-replace--key-path (file)
  "FILE as the Search view's file ids and row keys name it: relative to the root when under it, else whole (the hub's
`key_path' in view/search/rows.rs, the same way)."
  (let ((root (and drgnx-replace--root (file-name-as-directory drgnx-replace--root))))
    (if (and root (string-prefix-p root file) (> (length file) (length root))) (substring file (length root)) file)))

(defun drgnx-replace--file-key (file)
  "FILE's node id and header row key: `f:' and FILE as `drgnx-replace--key-path' names it."
  (concat "f:" (drgnx-replace--key-path file)))

(defun drgnx-replace--match-key (file line col)
  "The row key of the match at LINE and COL of FILE that Emacs scanned in a modified buffer (the hub's are `m:RUN:N')."
  (format "m:%s:%s:%s" (drgnx-replace--key-path file) line col))

(defun drgnx-replace--rows-match (id &optional extra)
  "Match node ID of the model as `drgnx-replace-apply' takes a match, EXTRA appended.  Its file is its parent's
`path' (the hub sends the path once, on the file node)."
  (let ((f (lambda (name) (drgnx-view-nav-field name id)))
        (parent (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'parent id)))
    (append (list :file (drgnx-view-nav-field "path" parent) :line (funcall f "line") :col (funcall f "col")
                  :end (funcall f "end") :text (funcall f "text"))
            extra)))

(defun drgnx-replace--rows-kind-p (id kind)
  "Whether node ID of the model is of KIND (\"file\" or \"match\")."
  (equal (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'kind id) kind))

(defun drgnx-replace--rows-off ()
  "The unticked matches: a hash ID → t."
  (let ((off (make-hash-table :test #'equal)))
    (mapc (lambda (id) (puthash id t off)) (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked))
    off))

(defun drgnx-replace--rows-file-matches (file)
  "The ids of node FILE's matches, in order: the model's order holds them right after it."
  (let ((tail (cdr (member file (append (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'list "order")
                                        nil))))
        ms)
    (while (and tail (drgnx-replace--rows-kind-p (car tail) "match"))
      (push (pop tail) ms))
    (nreverse ms)))

(defun drgnx-replace--rows-box-text (key off)
  "The tick box of row KEY (a node id) with the unticked matches OFF: a file's is [x], [ ] or [-] for some."
  (if (drgnx-replace--rows-kind-p key "file")
      (let* ((ms (drgnx-replace--rows-file-matches key)) (n (cl-count-if (lambda (m) (gethash m off)) ms)))
        (cond ((zerop n) "[x]") ((= n (length ms)) "[ ]") (t "[-]")))
    (if (gethash key off) "[ ]" "[x]")))

(defun drgnx-replace--rows-boxes (view keys)
  "Show the tick boxes of VIEW's rows KEYS as the ticks say, over the hub's \"[x]\" (a `display' overlay; none for
[x]), each a button (RET or a click ticks it, `drgnx-replace--box-pressed').  `drgnx-view-patch-patched-functions'
runs it after a draw."
  (let ((off (drgnx-replace--rows-off))
        (table (or drgnx-replace--box-overlays (setq drgnx-replace--box-overlays (make-hash-table :test #'equal)))))
    (dolist (key keys)
      (let* ((ov (gethash key table)) (beg (drgnx-view-row-start view key))
             (pos (and beg (text-property-not-all beg (save-excursion (goto-char beg) (line-end-position))
                                                  'drgnx-replace-box nil)))
             (text (cond ((not pos) "[x]") ((zerop (hash-table-count off)) "[x]")
                         (t (drgnx-replace--rows-box-text key off)))))
        (when (and pos (not (get-text-property pos 'button)))
          (with-silent-modifications
            (let ((inhibit-read-only t))
              (make-text-button pos (+ pos 3) :type 'drgnx-replace-box 'mouse-face 'drgnx-hover))))
        (if (equal text "[x]")
            (when ov (delete-overlay ov) (remhash key table))
          (if ov (move-overlay ov pos (+ pos 3)) (setq ov (make-overlay pos (+ pos 3))) (puthash key ov table))
          (overlay-put ov 'display text))))))

(defun drgnx-replace--rows-untick-all ()
  "On the rows path, every match ticked again: Sjá's ticked set emptied (a new search, Replace All's leftovers), the
boxes shown as the hub sends them."
  (when-let* (((drgnx-replace--rows-p)) (h (drgnx-view-patch-handle drgnx-view-patch)))
    (mapc (lambda (id) (nidhogg-view-set h 'tick id)) (nidhogg-view-get h 'ticked))
    (when drgnx-replace--box-overlays
      (maphash (lambda (_ ov) (delete-overlay ov)) drgnx-replace--box-overlays)
      (clrhash drgnx-replace--box-overlays))))

(defun drgnx-replace--rows-tick (&optional id)
  "Tick or untick ID (default: the selection) on the rows path: a match, or a file, all of its matches (ticked when
every one was unticked, else unticked)."
  (let* ((h (drgnx-view-patch-handle drgnx-view-patch))
         (id (or id (drgnx-view-nav-selection) (user-error "No match is selected")))
         (file (if (drgnx-replace--rows-kind-p id "file") id (nidhogg-view-get h 'parent id)))
         (ms (drgnx-replace--rows-file-matches file)))
    (if (equal id file)
        (let* ((off (drgnx-replace--rows-off)) (tick (cl-every (lambda (m) (gethash m off)) ms)))
          (dolist (m ms) (when (eq tick (gethash m off)) (nidhogg-view-set h 'tick m))))
      (nidhogg-view-set h 'tick id))
    (drgnx-replace--rows-boxes drgnx-view (cons file ms))))

(defvar-local drgnx-replace--local-at nil "(KEY . SELECTION): the rescanned row Next Match is on, and the model's selection then.")

(defun drgnx-replace--rows-step (dir)
  "Select the next (DIR 1) or previous (DIR -1) match, wrapping, and make sure its row is shown (the hub sends a window
of the rows, the model holds every match): its id, or nil when there is none."
  (let ((id (drgnx-replace--rows-step-1 dir)))
    (when (stringp id) (drgnx-replace--reach id))
    id))

(defun drgnx-replace--rows-step-1 (dir)
  "Select the next (DIR 1) or previous (DIR -1) shown match, wrapping: its id, or nil when there is none.  The model's
matches come first, then the rows Emacs scanned in modified buffers (`drgnx-replace--local-ids'), which the model
does not hold; Next Match walks both."
  (if (zerop (hash-table-count (or drgnx-replace--local-ids (make-hash-table))))
      (drgnx-replace--rows-step-model dir)
    (let* ((h (drgnx-view-patch-handle drgnx-view-patch)) (sel (drgnx-view-nav-selection))
           (cur (and drgnx-replace--local-at (equal (cdr drgnx-replace--local-at) sel) (car drgnx-replace--local-at)))
           (local (let (ks) (maphash (lambda (k _) (push k ks)) drgnx-replace--local-ids) (nreverse ks)))
           (all (append (cl-remove-if-not (lambda (i) (drgnx-replace--rows-kind-p i "match"))
                                          (append (nidhogg-view-get h 'list "visible") nil))
                        local))
           (pos (seq-position all (or cur sel)))
           (next (nth (mod (+ (or pos (if (> dir 0) -1 0)) dir) (length all)) all)))
      (if (gethash next drgnx-replace--local-ids)
          (progn (setq drgnx-replace--local-at (cons next sel)) next)
        (setq drgnx-replace--local-at nil)
        (drgnx-view-nav 'select next)))))

;; The hub sends the first rows of a search (a window) and the editor asks for the rest as it needs them: when its
;; window nears the end of the rows (`more'), and when Next or Previous Match goes to a match beyond them (`upto'; the
;; point goes to the row when it arrives).  Replace All and the model's keys do not need the rows.

(defun drgnx-replace--look (params)
  "`search/grep-look' with PARAMS (the view added), without waiting."
  (when (and (fboundp 'drgnx-hub--call-on) (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (condition-case nil
        (drgnx-hub--call-on drgnx-hub--events "search/grep-look" (append (list :view drgnx-replace-view) params) #'ignore)
      (error nil))))

(defun drgnx-replace--reach (id)
  "Ask the hub for the row of match ID when the view does not have it, and put point on it when it comes."
  (unless (or (gethash id (drgnx-view-patch-rows drgnx-view-patch))
              (and drgnx-replace--local-ids (gethash id drgnx-replace--local-ids)))
    (setq drgnx-replace--reach-id id)
    (drgnx-replace--look (list :upto id))))

(defun drgnx-replace--reached (_view keys)
  "`drgnx-view-patch-patched-functions': the row asked for came, point goes to it; the end of the rows is near, more."
  (when (and drgnx-replace--reach-id (member drgnx-replace--reach-id keys))
    (let ((id (prog1 drgnx-replace--reach-id (setq drgnx-replace--reach-id nil))))
      (when (equal id (drgnx-view-nav-selection)) (drgnx-view-nav 'select id))))
  (drgnx-replace--look-more))

(defconst drgnx-replace-look-lines 40 "Lines before the end of the rows at which the view asks the hub for more.")

(defun drgnx-replace--look-more (&optional window)
  "When WINDOW (default: the view's) nears the end of the rows and the hub has more, ask for them (once per growth);
when it shows the gap row of a far jump, ask for the rows before the gap (once per patch)."
  (when-let* (((drgnx-replace--rows-p))
              (win (or window (get-buffer-window (current-buffer))))
              ((eq (window-buffer win) (current-buffer)))
              (gap (drgnx-view-row-start drgnx-view "gap"))
              ;; in the window, or as near its end as `more' asks
              ((<= (window-start win) gap))
              ((< (count-lines (window-start win) gap) (+ (window-body-height win) drgnx-replace-look-lines)))
              (version (drgnx-view-patch-version drgnx-view-patch))
              ((not (eql version drgnx-replace--fill-at))))
    (setq drgnx-replace--fill-at version)
    (drgnx-replace--look (list :fill t)))
  (when-let* (((drgnx-replace--rows-p))
              (win (or window (get-buffer-window (current-buffer))))
              ((eq (window-buffer win) (current-buffer)))
              (n (hash-table-count (drgnx-view-patch-rows drgnx-view-patch)))
              ((not (eql n drgnx-replace--look-at)))
              ((save-excursion (goto-char (window-start win))
                               (/= 0 (forward-line (+ (window-body-height win) drgnx-replace-look-lines))))))
    (setq drgnx-replace--look-at n)
    (drgnx-replace--look (list :more t))))

(defun drgnx-replace--scrolled (window _start)
  "`window-scroll-functions': the Search view's WINDOW scrolled."
  (with-current-buffer (window-buffer window) (drgnx-replace--look-more window)))

(defun drgnx-replace--rows-step-model (dir)
  "`drgnx-replace--rows-step' over the model's matches alone."
  (let* ((h (drgnx-view-patch-handle drgnx-view-patch)) (before (drgnx-view-nav-selection))
         (id (drgnx-view-nav 'follow (if (> dir 0) "down:match" "up:match"))))
    (if (or (and id (not (equal id before)) (drgnx-replace--rows-kind-p id "match"))
            (drgnx-view-nav-paging-p))   ; past the model's window: the key runs again once the next one is in
        id
      (let ((ms (cl-remove-if-not (lambda (i) (drgnx-replace--rows-kind-p i "match"))
                                  (append (nidhogg-view-get h 'list "visible") nil))))
        (when ms (drgnx-view-nav 'select (if (> dir 0) (car ms) (car (last ms)))))))))

(defun drgnx-replace--rows-ticked (extra)
  "The model's ticked matches in order, as `drgnx-replace-apply' takes them, EXTRA and `:id' (the node) appended to
each."
  (let ((off (drgnx-replace--rows-off)) ms)
    (mapc (lambda (id) (when (and (not (gethash id off)) (drgnx-replace--rows-kind-p id "match"))
                         (let ((m (drgnx-replace--rows-match id (append extra (list :id id)))))
                           (unless (and drgnx-replace--local (gethash (plist-get m :file) drgnx-replace--local))
                             (push m ms)))))   ; a modified buffer's file: the buffer's matches, below
          (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'list "order"))
    (when drgnx-replace--local
      (maphash (lambda (_ lms) (dolist (m lms) (push m ms))) drgnx-replace--local))
    (nreverse ms)))

(defun drgnx-replace--rows-replace-all (new)
  "Replace All on the rows path: the ticked matches by NEW (a regexp search's matches carry its pattern); the list is
then what it skipped, each with why (`search/grep-skipped'), as the old path leaves it."
  (let ((ms (drgnx-replace--rows-ticked
             (when (drgnx-replace--opt :regexp)
               (list :pattern (drgnx-replace--emacs-regexp (drgnx-replace--text 'find))
                     :case (drgnx-replace--opt :case))))))
    (unless ms (user-error "Nothing to replace: no match is ticked"))
    (let* ((res (let ((drgnx-replace--applying t)) (drgnx-replace-apply ms new)))
           (skipped (plist-get res :skipped)))
      (drgnx-replace--clear)
      ;; what is left: the skipped, with their reasons (the hub lists them alone, by node id, and stops the search)
      (drgnx-replace--hub-call "search/grep-skipped"
                               (list :view drgnx-replace-view
                                     :skipped (vconcat (delq nil (mapcar (lambda (m)
                                                                           (when-let* ((id (plist-get m :id)))
                                                                             (list :id id :why (plist-get m :reason))))
                                                                         skipped)))))
      (setq drgnx-replace--hub-counts (cons (length (seq-uniq (mapcar (lambda (m) (plist-get m :file)) skipped)))
                                            (length skipped)))
      (drgnx-replace--message "%s" (drgnx-replace--apply-report res)))))

;;;;; On the rows path: the hub searches and streams the results (`search/run')
;; A text search goes to the hub (this Emacs has Sjá; a search typed before the hub is up waits for it): the view is
;; attached as the hub-fed view `drgnx-replace-view', `search/run' starts the search, and the hub's rows (a reset,
;; then each file's header and matches) are inserted by `drgnx-view-apply-patch'.  A new query makes the hub send a
;; reset and drop the old query's late rows, and the editor drops one that still comes by its base.  `search-run-done'
;; ends the search and names the matches the user had unticked before it, found again.  A replace text typed meanwhile is `search/grep-replace' (the hub patches the previews).  Symbol mode
;; (the server's edits) keeps rows of Emacs's own (the `replace-results' view type).  What the hub does not see stays
;; Lisp: file-notify watches on the listed files (a change on disk searches again through the hub) and the rescan of
;; a file from its buffer, unsaved edits included (`drgnx-replace--scan').

(defun drgnx-replace--hub-ready-p ()
  "Non-nil when a text search can go to the hub: Sjá in this Emacs, the hub connected."
  (and (fboundp 'nidhogg-view--call)
       (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(defun drgnx-replace--hub-attach ()
  "Make the view hub-fed (the hub's rows below the fields), when it is not; its env goes while a window shows it."
  (unless drgnx-view-patch
    (drgnx-view-patch-attach drgnx-replace-view "unshown" :start drgnx-replace--results)
    (drgnx-replace-rows-attached)
    (add-hook 'drgnx-hub-event-functions #'drgnx-replace--hub-event)
    (require 'drgnx-view-env)
    (drgnx-view-env-register drgnx-replace-view (current-buffer) #'drgnx-replace--hub-resubscribe)))

(defun drgnx-replace--hub-detach ()
  "Make the view Emacs's own again (the Lisp engine's rows), when it is hub-fed.  Always nil."
  (when drgnx-view-patch
    (drgnx-view-env-unregister drgnx-replace-view)
    (drgnx-view-patch-detach)
    (remove-hook 'drgnx-view-patch-patched-functions #'drgnx-replace--rows-boxes t)
    (remove-hook 'drgnx-view-patch-patched-functions #'drgnx-replace--reached t)
    (remove-hook 'drgnx-view-nav-paged-functions #'drgnx-replace--paged t)
    (remove-hook 'window-scroll-functions #'drgnx-replace--scrolled t)
    (when drgnx-replace--box-overlays (maphash (lambda (_ ov) (delete-overlay ov)) drgnx-replace--box-overlays)
          (clrhash drgnx-replace--box-overlays))
    (drgnx-view-attach 'replace-results :start drgnx-replace--results))
  nil)

(defun drgnx-replace--hub-call (method params)
  "METHOD with PARAMS to the hub, without waiting; a failure is the status line's."
  (let ((buf (current-buffer)))
    (condition-case err
        (progn (unless (fboundp 'drgnx-hub--call-on) (require 'drgnx-hub-client))
               ;; on the subscribed connection: the rows and the end event go to the connection that asks
               (drgnx-hub--call-on drgnx-hub--events method params
                                   (lambda (_result error)
                                     (when (and error (buffer-live-p buf))
                                       (with-current-buffer buf
                                         (setq drgnx-replace--searching nil)
                                         (drgnx-replace--message "%s" error))))))
      (error (setq drgnx-replace--searching nil)
             (drgnx-replace--message "%s" (error-message-string err))))))

(defun drgnx-replace--hub-search (text file)
  "Search TEXT (in FILE when given) through the hub: the view is hub-fed, `search/run' sends the rows.  An empty
text is sent too: the hub empties the rows and stops the search before.  The matches unticked before the search
\(`drgnx-replace--carry') go with it."
  (drgnx-replace--hub-attach)
  (when (and (eq (drgnx-replace--opt :scope) 'file) (not file))
    (setq text "" drgnx-replace--status "This file: the view was not opened from a file"))
  (let ((globs (lambda (name) (drgnx-replace--globs (drgnx-replace--text name))))
        (on (lambda (name) (if (drgnx-replace--opt name) t :false)))
        (off (prog1 drgnx-replace--carry (setq drgnx-replace--carry nil))))
    (setq drgnx-replace--searching t)
    (drgnx-replace--hub-call
     "search/run"
     (append (list :view drgnx-replace-view :root drgnx-replace--root
                   :search (append (list :query (list :mode "text" :text text :case (funcall on :case)
                                                      :word (funcall on :word) :regexp (funcall on :regexp))
                                         :replace (drgnx-replace--text 'replace)
                                         :scope (if file
                                                    (list :kind "file" :files (vector file))
                                                  (list :kind "project")))
                                   (when-let* ((g (funcall globs 'include))) (list :include (vconcat g)))
                                   (when-let* ((g (funcall globs 'exclude))) (list :exclude (vconcat g)))))
             (and off (list :off (vconcat off)))))))

(defun drgnx-replace--rows-carry ()
  "The hub's match ids the user unticked (Sjá's ticked set), for the next search to keep: see `drgnx-replace--carry'."
  (when-let* (((drgnx-replace--rows-p)) (h (drgnx-view-patch-handle drgnx-view-patch)))
    ;; by id alone: a match outside the model's window has no node here
    (seq-filter (lambda (id) (and (stringp id) (string-prefix-p "m:" id))) (nidhogg-view-get h 'ticked))))

(defun drgnx-replace--rows-untick (ids)
  "Untick the matches IDS (a search's `off': the ones the user had unticked before it) and show their boxes so."
  (when-let* (((and ids (drgnx-replace--rows-p))) (h (drgnx-view-patch-handle drgnx-view-patch)))
    (let ((off (drgnx-replace--rows-off)) shown)
      (dolist (id ids)
        (unless (gethash id off) (nidhogg-view-set h 'tick id))
        (push id shown)
        (when-let* ((file (nidhogg-view-get h 'parent id))) (push file shown)))
      (drgnx-replace--rows-boxes drgnx-view (delete-dups shown)))))

(defun drgnx-replace--hub-event (event data)
  "`drgnx-hub-event-functions': `search-run-done' ends the Search view's search, counts what it found and unticks
the matches the user had unticked before it (`:off')."
  (when (and (equal event "search-run-done") (equal (plist-get data :view) drgnx-replace-view))
    (when-let* ((buf (get-buffer drgnx-replace-buffer-name)))
      (with-current-buffer buf
        (when drgnx-view-patch
          (drgnx-replace--rows-untick (plist-get data :off))
          (setq drgnx-replace--searching nil
                drgnx-replace--hub-counts (cons (or (plist-get data :files) 0) (or (plist-get data :matches) 0)))
          (when-let* ((err (plist-get data :error))) (setq drgnx-replace--status (format "%s" err)))
          (drgnx-replace--hub-listed)
          (drgnx-replace--local-refresh)
          (drgnx-replace--watch)
          (drgnx-replace--update-status))))))

(defun drgnx-replace--hub-listed ()
  "The files the search listed (the `f:' nodes of the model, their `path', not only the rows sent), for the watches."
  (clrhash drgnx-replace--listed)
  (let ((h (drgnx-view-patch-handle drgnx-view-patch)))
    (mapc (lambda (id) (when (and (stringp id) (string-prefix-p "f:" id))
                         (puthash (nidhogg-view-get h 'field "path" id) t drgnx-replace--listed)))
          (nidhogg-view-get h 'list "order"))))

;; A modified buffer is not what the hub reads (the disk).  After a search, and after a pause when a buffer is edited,
;; Emacs rescans every modified file buffer under the root (`drgnx-replace--scan': the buffer's text, unsaved edits
;; included, through `--grep-line' and `--match') and its matches take the place of the hub's rows of that file,
;; also for a buffer whose file the hub found nothing in.  The rows are built here in the hub's row format and put
;; in the view's row table; Replace All and Replace This write them; the counts follow.  Not in Sjá's model: Next Match
;; and the tick boxes skip them.  A new search forgets them.

(defun drgnx-replace--local-files ()
  "The files of the modified file buffers a search of the fields would list: under the root, in the scope."
  (let ((find (drgnx-replace--text 'find)) (root (file-name-as-directory (expand-file-name drgnx-replace--root)))
        (only (and (eq (drgnx-replace--opt :scope) 'file) (or (drgnx-replace--origin-file) t))) out)
    (unless (or (string-empty-p find) (drgnx-replace--opt :symbol))
      (dolist (b (buffer-list))
        (when-let* ((f (buffer-file-name b)) ((buffer-modified-p b)) ((not (file-remote-p f)))
                    ((string-prefix-p root f)) ((or (not only) (equal only f))))
          (push f out))))
    out))

(defun drgnx-replace--local-flat (s) (string-replace "\n" "⏎" s))

(defun drgnx-replace--local-header (file)
  "The header row of FILE, as the hub makes it."
  (let* ((name (file-name-nondirectory file))
         (dir (file-relative-name (file-name-directory file) drgnx-replace--root))
         (text (concat "[x] " name (if (equal dir "./") "" (concat "  " dir)))) (key (drgnx-replace--file-key file)))
    (list :key key :text text
          :runs (unless (equal dir "./") (list (list (+ 4 (length name)) (length text) "drgnx-replace-dim")))
          :props (list (list 0 (length text) "drgnx-work-id" key)))))

(defun drgnx-replace--local-match-row (m)
  "The row of match M, as the hub makes it: the text around it, M as old and new when a replacement is typed."
  (let* ((key (drgnx-replace--match-key (plist-get m :file) (plist-get m :line) (plist-get m :col)))
         (before (string-trim-left (plist-get m :before)))
         (before (drgnx-replace--local-flat (if (> (length before) 16) (concat "…" (substring before -15)) before)))
         (new drgnx-replace--new) (txt (drgnx-replace--local-flat (plist-get m :text)))
         (rep (and (or (plist-get m :placeholder) (not (string-empty-p new)))
                   (ignore-errors (drgnx-replace-new-text m new))))
         (head (concat "  [x] " before)) (b (length head))
         (mid (if rep (concat txt (drgnx-replace--local-flat rep)) txt))
         (runs (if rep (list (list b (+ b (length txt)) "drgnx-replace-old")
                             (list (+ b (length txt)) (+ b (length mid)) "drgnx-replace-new"))
                 (list (list b (+ b (length txt)) "drgnx-replace-match"))))
         (text (concat head mid (drgnx-replace--local-flat (plist-get m :after))
                       (if-let* ((why (plist-get m :reason))) (concat "  — " why) ""))))
    (list :key key :text text :runs runs :props (list (list 0 (length text) "drgnx-work-id" key)))))

(defun drgnx-replace--local-refresh ()
  "Rescan the modified buffers and show their matches in place of the hub's rows of those files (see above)."
  (when drgnx-view-patch
    (let* ((table (drgnx-view-patch-rows drgnx-view-patch)) (view drgnx-view)
           (scans (delq nil (mapcar (lambda (f) (let ((r (drgnx-replace--scan f))) (and (listp r) (cons f r))))
                                    (drgnx-replace--local-files))))
           (files (mapcar #'car scans)) old new hub)
      (unless drgnx-replace--local-hub (setq drgnx-replace--local-hub (make-hash-table :test #'equal)))
      (unless drgnx-replace--local-rows (setq drgnx-replace--local-rows (make-hash-table :test #'equal)))
      (setq drgnx-replace--local (make-hash-table :test #'equal)
            drgnx-replace--local-ids (make-hash-table :test #'equal))
      (maphash (lambda (k _) (push k old)) drgnx-replace--local-rows)
      ;; what the hub found in these files, counted once (from the model: the rows are a window of it), and its rows
      ;; shown are taken out
      (dolist (f files)
        (unless (gethash f drgnx-replace--local-hub)
          (puthash f (drgnx-replace--model-counts f) drgnx-replace--local-hub)))
      (maphash (lambda (k _)
                 (when (and (stringp k) (not (gethash k drgnx-replace--local-rows)) (drgnx-replace--hub-row-local-p k files))
                   (push k hub)))
               table)
      (dolist (s scans)
        (puthash (car s) (cdr s) drgnx-replace--local)
        (when (cdr s)
          (let ((h (drgnx-replace--local-header (car s))))
            (push h new)
            (dolist (m (cdr s))
              (let ((r (drgnx-replace--local-match-row m)))
                (puthash (plist-get r :key) m drgnx-replace--local-ids)
                (push r new))))))
      (setq new (nreverse new))
      (let ((new-keys (mapcar (lambda (r) (plist-get r :key)) new)) (shown nil))
        (dolist (k hub) (remhash k table))
        (dolist (k old) (unless (member k new-keys) (remhash k drgnx-replace--local-rows) (remhash k table)))
        (dolist (r new)
          (puthash (plist-get r :key) r drgnx-replace--local-rows)
          (puthash (plist-get r :key) r table))
        (dolist (k new-keys) (when (member k old) (push k shown)))
        (let ((gone (append hub (seq-remove (lambda (k) (member k new-keys)) old)))
              (fresh (seq-remove (lambda (k) (member k old)) new-keys)))
          (when gone (drgnx-view-remove view gone))
          (when fresh (drgnx-view-insert view fresh))
          (when shown (drgnx-view-dirty view shown))))
      ;; what the rows add to the hub's counts
      (let ((df 0) (dm 0))
        (dolist (s scans)
          (let ((h (gethash (car s) drgnx-replace--local-hub)))
            (cl-incf df (- (if (cdr s) 1 0) (or (car h) 0)))
            (cl-incf dm (- (length (cdr s)) (or (cdr h) 0)))))
        (setq drgnx-replace--local-delta (cons df dm)))
      (drgnx-replace--update-status))))

(defun drgnx-replace--model-counts (file)
  "(FILES . MATCHES) the hub found in FILE: from the model (the rows are a window of it); a file the model does not
hold (past its cap) counts the rows the view has of it."
  (let ((id (drgnx-replace--file-key file)))
    (if (drgnx-replace--rows-kind-p id "file")
        (cons 1 (length (drgnx-replace--rows-file-matches id)))
      (let ((f 0) (m 0))
        (maphash (lambda (k row)
                   (when (and (stringp k) (equal (drgnx-replace--row-file row) file))
                     (if (equal k id) (setq f 1) (cl-incf m))))
                 (drgnx-view-patch-rows drgnx-view-patch))
        (cons f m)))))

(defun drgnx-replace--row-file (row)
  "The file of the hub's ROW: a header's `drgnx-replace-file', a match's `drgnx-replace-match' `:file' (its key does
not name it, `m:RUN:N')."
  (cl-loop for (_ _ name value) in (plist-get row :props)
           when (equal name "drgnx-replace-file") return value
           when (equal name "drgnx-replace-match") return (plist-get value :file)))

(defun drgnx-replace--hub-row-local-p (key files)
  "Whether row KEY is the hub's row of one of FILES (the modified buffers' files, whose rows Emacs makes)."
  (when-let* ((row (gethash key (drgnx-view-patch-rows drgnx-view-patch))))
    (member (drgnx-replace--row-file row) files)))

(defun drgnx-replace--local-patched (view keys)
  "`drgnx-view-patch-patched-functions': a hub patch redrew a row of a rescanned file: the buffer's row goes back; a
row of such a file the hub sent now (the window went on) is taken out."
  (when drgnx-replace--local-rows
    (let ((table (drgnx-view-patch-rows drgnx-view-patch)) (files nil) back gone)
      (maphash (lambda (f _) (push f files)) drgnx-replace--local)
      (dolist (k keys)
        (if-let* ((mine (gethash k drgnx-replace--local-rows)))
            (unless (eq mine (gethash k table))
              (puthash k mine table)
              (push k back))
          (when (and (stringp k) (drgnx-replace--hub-row-local-p k files))
            (remhash k table)
            (push k gone))))
      (when gone (drgnx-view-remove view gone))
      (when back (drgnx-view-dirty view back)))))

(defun drgnx-replace--local-later ()
  "A buffer was edited: after a pause (and when no search runs, whose end rescans) rescan the modified buffers."
  (unless drgnx-replace--searching
    (drgnx-timer-debounce (cons 'replace-local (current-buffer)) drgnx-replace-refresh-delay
                          #'drgnx-replace--local-timer :args (list (current-buffer)) :owner (current-buffer))))

(defun drgnx-replace--local-timer (buf)
  "The pause after an edit is over in BUF's Search view.  A timer: never signals."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (condition-case e (drgnx-replace--local-refresh)
        (error (drgnx-replace--message "%s" (error-message-string e)))))))

(defun drgnx-replace--hub-resubscribe (_view)
  "The hub is up again (`drgnx-view-env-register'): search again, as the fields say; its searches were lost."
  (when-let* ((buf (get-buffer drgnx-replace-buffer-name)))
    (with-current-buffer buf
      (when (and drgnx-view-patch (not (string-empty-p (drgnx-replace--text 'find))))
        (drgnx-replace--search-now)))))

(defun drgnx-replace--rows-this (new)
  "Replace the match on the row at point (else the selected one) by NEW, ticked or not, then search again."
  (let* ((id (or (get-text-property (point) 'drgnx-work-id) (drgnx-view-nav-selection)))
         (m (or (and drgnx-replace--local-ids (gethash id drgnx-replace--local-ids))
                (and id (drgnx-replace--rows-kind-p id "match")
                     (drgnx-replace--rows-match id (when (drgnx-replace--opt :regexp)
                                                     (list :pattern (drgnx-replace--emacs-regexp (drgnx-replace--text 'find))
                                                           :case (drgnx-replace--opt :case)))))
                (user-error "No match on this row")))
         (res (let ((drgnx-replace--applying t)) (drgnx-replace-apply (list m) new)))
         (msg (if (plist-get res :skipped)
                  (format "Skipped: %s" (plist-get (car (plist-get res :skipped)) :reason))
                (drgnx-replace--apply-report res))))
    (drgnx-replace--search-now)
    (drgnx-replace--message "%s" msg)))

(defun drgnx-replace-all ()
  "Replace every ticked match of the Search view (in the find bar: every match of its buffer)."
  (interactive)
  (if (drgnx-replace--bar-context-p)
      (with-current-buffer drgnx-replace-bar-buffer-name (drgnx-replace--bar-replace-all))
    (with-current-buffer (drgnx-replace--live-view)
      (if (drgnx-replace--rows-p)
          (drgnx-replace--rows-replace-all (drgnx-replace--new-name))
        (drgnx-replace--replace-all-symbol)))))

(defun drgnx-replace--replace-all-symbol ()
  "`drgnx-replace-all' in Symbol mode: the server's edits are the view's own rows, not the hub's."
  (let ((new (drgnx-replace--new-name))
        (ms (seq-remove (lambda (m) (gethash m drgnx-replace--off)) drgnx-replace--matches)))
    (unless ms (user-error "Nothing to replace: no match is ticked"))
    (let* ((res (let ((drgnx-replace--applying t)) (drgnx-replace-apply ms new)))
           (msg (drgnx-replace--apply-report res)))
      (drgnx-replace--clear)
      (drgnx-replace--add (plist-get res :skipped))       ; what is left: the skipped, with their reasons
      (drgnx-replace--watch)
      (drgnx-replace--message "%s" msg))))

(defun drgnx-replace-this ()
  "Replace the match on this row of the Search view, ticked or not."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (if (drgnx-replace--rows-p) (drgnx-replace--rows-this (drgnx-replace--new-name)) (drgnx-replace--this-symbol))))

(defun drgnx-replace--this-symbol ()
  "`drgnx-replace-this' in Symbol mode (the view's own rows)."
  (progn
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
      (if (drgnx-replace--rows-p)
          (let ((id (or (drgnx-replace--rows-step dir) (user-error "No matches"))))
            (drgnx-replace--show-match (or (and drgnx-replace--local-ids (gethash id drgnx-replace--local-ids))
                                           (drgnx-replace--rows-match id))
                                       nil))
        (let* ((win (get-buffer-window (current-buffer)))
               (pos (drgnx-replace--next-row (if win (window-point win) (point)) dir)))
          (unless pos (user-error "No matches"))
          (goto-char pos)
          (when win (set-window-point win pos))
          (drgnx-replace--show-match (get-text-property pos 'drgnx-replace-match) nil))))))

(defun drgnx-replace-next () "The next match, shown in the editor." (interactive) (drgnx-replace--step 1))
(defun drgnx-replace-prev () "The previous match, shown in the editor." (interactive) (drgnx-replace--step -1))

(defun drgnx-replace--file-step (dir)
  "Select the next (DIR 1) or previous (DIR -1) file's row of the Search view: on the rows path through Sjá
\(`down:file' / `up:file'), else the next header row."
  (with-current-buffer (drgnx-replace--live-view)
    (if (drgnx-replace--rows-p)
        (let ((id (drgnx-view-nav 'follow (if (> dir 0) "down:file" "up:file"))))
          (when (stringp id) (drgnx-replace--reach id))
          id)
      (let ((pos (save-excursion
                   (forward-line 0)
                   (cl-loop while (zerop (forward-line dir))
                            when (get-text-property (point) 'drgnx-replace-file) return (point)))))
        (goto-char (or pos (user-error "No other file")))))))

(defun drgnx-replace-next-file () "The next file of the Search view's results." (interactive) (drgnx-replace--file-step 1))
(defun drgnx-replace-prev-file ()
  "The previous file of the Search view's results." (interactive) (drgnx-replace--file-step -1))

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
        (drgnx-replace--insert-button nil (drgnx-face-glyph 'close) "Close (ESC)" #'drgnx-replace-bar-close)
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
                   (replace-next-file "Next File" drgnx-replace-next-file "The next file of the Search view's results")
                   (replace-prev-file "Previous File" drgnx-replace-prev-file
                                      "The previous file of the Search view's results")
                   (replace-bar-close "Close Find Bar" drgnx-replace-bar-close "Close the find bar and its highlights")))
    (drgnx-command-define id :category "Search" :title title :command fn :doc doc :scope scope))
  (drgnx-command-define 'replace-this :category "Search" :title "Replace This Match" :command #'drgnx-replace-this
                        :doc "Replace the match on this row of the Search view"
                        :when (lambda () (derived-mode-p 'drgnx-replace-mode))))

(defun drgnx-replace--teardown ()
  "Turn the Search view and the find bar off: close the bar, stop what the view runs (search, drawing, file
watches), kill both buffers.  Never asks.  Their pauses and refreshes are layer keys the buffers own: killing them
cancels those."
  (remove-hook 'drgnx-hub-event-functions #'drgnx-replace--hub-event)
  (remove-hook 'drgnx-hub-connected-functions #'drgnx-replace--hub-up)
  (drgnx-replace-bar-close)
  (let ((kill-buffer-query-functions nil))
    (dolist (name (list drgnx-replace-buffer-name drgnx-replace-bar-buffer-name))
      (when-let* ((buf (get-buffer name)))
        (with-current-buffer buf
          (drgnx-replace--unwatch))
        (kill-buffer buf)))))

;; Startup, not idle: `View: Search' (C-S-f) works from the first second, as the Explorer's key does.
(drgnx-module-define 'tools/replace
                     :doc "Search and replace across files: text through the hub, symbols through the language server."
                     :stage 'startup
                     :teardown #'drgnx-replace--teardown
                     :setup (lambda ()
                              (drgnx-replace--define-section)
                              (drgnx-replace--define-commands)
                              (add-hook 'drgnx-hub-connected-functions #'drgnx-replace--hub-up)
                              (drgnx-state-define-role 'bar) ; the find bar's window: no editor, no chrome
                              (eval-after-load 'evil (drgnx-modules-with-owner (drgnx-replace--evil-states)))
                              ;; wb/drgnx-persist.el saves the main area with `window-state-get': the bar's window would be in it.
                              (advice-add 'drgnx-persist-save :before #'drgnx-replace--close-bars)))

(provide 'drgnx-replace)
;;; drgnx-replace.el ends here
