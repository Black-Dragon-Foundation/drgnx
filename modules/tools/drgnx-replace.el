;;; drgnx-replace.el --- Module tools/replace: search and replace across files, text or symbol -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; VS Code's Search & Replace.  Text: the hub searches (`search/run') and streams the rows; Sjá holds the model the
;; keys walk; a search typed before the hub is up waits for it.  Symbol: the language server's rename edits (asked for
;; with a placeholder name, never applied by the server), as matches of Emacs's own.  Replacing goes through the hub's
;; write path (`search/edits', `search/apply'): every match is checked against the file as it is now and the stale ones
;; are skipped; the hub writes closed files, this Emacs the files it has open (`search-apply', one change group each,
;; saved unless the buffer held unsaved edits), so one Undo (`search/undo') puts every file back.
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
(require 'drgnx-setting)
(require 'drgnx-timer)
(require 'drgnx-wb)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(require 'drgnx-large-file)             ; a large file: Replace needs it whole (lean), never asks; skips chunks and raw
(require 'drgnx-no-prompt)              ; the saves of the hub's writes ask nothing
(require 'drgnx-ui-kit)                 ; the sheet's buttons
;; Edit Results: the results as an editable buffer, on the same write path
(unless (featurep 'drgnx-search-edit)
  (load (expand-file-name "drgnx-search-edit" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(declare-function drgnx-search-edit-change "drgnx-search-edit")
(unless (featurep 'drgnx-search-handoff)
  (load (expand-file-name "drgnx-search-handoff" (file-name-directory (or load-file-name buffer-file-name))) nil t))
(declare-function drgnx-search-handoff-event "drgnx-search-handoff")
(declare-function drgnx-search-handoff-chip "drgnx-search-handoff")

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
(declare-function drgnx-wb-place "drgnx-rules")
(declare-function drgnx-popup-refit "drgnx-popup" (buffer))
(declare-function drgnx-palette-keycap "drgnx-palette" (name))
(declare-function drgnx-palette-keycap-names "drgnx-palette" (key))
(declare-function drgnx-palette-keycaps "drgnx-palette" (key))
(declare-function drgnx-surfaces-key-label "drgnx-surfaces")
(declare-function drgnx-hub-call-sync "drgnx-hub-client")
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

;;;; Text matches (the hub finds them: `search/run'; a match's plist, as the writer takes it)

(defun drgnx-replace--match (file line text col end &optional extra)
  "The match in FILE's LINE (1-based), whose text TEXT holds it from character COL to END; EXTRA appended."
  (let ((k drgnx-replace-context-chars))
    (append (list :file file :line line :col col :end end :text (substring text col end)
                  :before (substring text (max 0 (- col k)) col)
                  :after (substring text end (min (length text) (+ end k))))
            extra)))

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
;; The hub writes (docs/guide/replace.md, "How Replace All writes"; spec: the shared write path).  Replace All, Replace
;; This and Undo Replace ask the hub for an edit set (`search/edits'), then write it (`search/apply') or put a change set
;; back (`search/undo'); the hub writes closed files itself and sends each file this Emacs has open here
;; (`search-apply'), where its edits go into the buffer, each only where its old text is, as one undo group, saved
;; unless the buffer held unsaved edits.  The answer (`search/applied') carries the inverse edits, so the hub's Undo
;; reaches a buffer killed since.  `search-change' ends the write.

(defvar drgnx-replace--applying nil "Non-nil while the hub's edits go into a buffer here: no change underneath.")

(defun drgnx-replace--skip (m why)
  "Match M, skipped because of WHY."
  (append m (list :reason why)))

(defun drgnx-replace--partial (buf)
  "Why BUF, a file's visiting buffer (or nil), cannot take the whole file's lines and columns: a reason, else nil.
A large file open in chunks holds one part of the file; one open raw holds its bytes undecoded."
  (pcase (and buf (buffer-local-value 'drgnx-large-file buf))
    ('chunks "open in chunks: Large File: Open Whole first")
    ('raw "open raw: Large File: Open Whole first")))

(defun drgnx-replace--save ()
  "Save this buffer quietly, without format on save (a formatter's rewrite would make Undo skip the file), asking
nothing: a question it would ask, or an error, leaves it unsaved.  Non-nil when it saved."
  (condition-case nil
      (drgnx-with-no-prompts
        (let ((save-silently t) (apheleia-format-after-save-in-progress t) (create-lockfiles nil))
          (save-buffer)))
    (error nil))
  (not (buffer-modified-p)))

(defun drgnx-replace--revert ()
  "Read the visited file again into this buffer, which has none of your edits, asking nothing: non-nil when read."
  (condition-case nil
      (progn (drgnx-with-no-prompts (revert-buffer t t t)) t)
    (error nil)))

(defun drgnx-replace--pos (line col)
  "The position of LINE (from 1) and character column COL (from 0) of this buffer (widened), or nil past its end."
  (save-excursion
    (goto-char (point-min))
    (and (zerop (forward-line (1- line))) (<= col (- (line-end-position) (point))) (+ (point) col))))

(defun drgnx-replace--place (pos)
  "The line (from 1) and character column (from 0) of POS: (LINE . COL)."
  (save-excursion (goto-char pos) (cons (line-number-at-pos pos t) (- pos (line-beginning-position)))))

(defun drgnx-replace--write-edits (edits)
  "Write EDITS (the hub's, plists :id :line :col :end_line :end_col :old :new) into this buffer: each only where its
old text is, the first of two that overlap; all in one undo group; saved when the buffer had no unsaved edits.
The answer (`search/applied' params but the change and path)."
  (save-restriction
    (widen)
    (let ((todo nil) (skipped nil) (ok nil) (limit nil))
      (dolist (e edits)
        (let* ((beg (drgnx-replace--pos (plist-get e :line) (plist-get e :col)))
               (end (and beg (drgnx-replace--pos (plist-get e :end_line) (plist-get e :end_col)))))
          (if (and end (<= beg end) (equal (buffer-substring-no-properties beg end) (plist-get e :old)))
              (push (list beg end e) todo)
            (push (list :id (plist-get e :id) :why "its text changed") skipped))))
      ;; in file order; a range starting inside the one before it is skipped
      (dolist (x (sort (nreverse todo) (lambda (a b) (< (car a) (car b)))))
        (if (and limit (< (car x) limit))
            (push (list :id (plist-get (nth 2 x) :id) :why "overlaps another match") skipped)
          (push x ok)
          (setq limit (nth 1 x))))
      (setq ok (nreverse ok))
      (if (null ok)
          (list :applied [] :skipped (vconcat (nreverse skipped)) :saved :false)
        (let* ((clean (not (buffer-modified-p))) (group (prepare-change-group)) (done nil) (create-lockfiles nil))
          (undo-boundary)
          (unwind-protect
              (progn
                (activate-change-group group)
                (dolist (x (reverse ok))     ; from the end, so the positions before stay put
                  (goto-char (car x))
                  (delete-region (car x) (nth 1 x))
                  (insert (plist-get (nth 2 x) :new)))
                (undo-amalgamate-change-group group)
                (setq done t))
            (if done (accept-change-group group) (cancel-change-group group)))
          (undo-boundary)
          ;; each new text's range now: its old start moved by what the edits before it added
          (let ((shift 0) (inverse nil))
            (dolist (x ok)
              (let* ((edit (nth 2 x)) (beg (+ (car x) shift)) (end (+ beg (length (plist-get edit :new))))
                     (s (drgnx-replace--place beg)) (e (drgnx-replace--place end)))
                (setq shift (+ shift (- end beg) (- (car x) (nth 1 x))))
                (push (list :id (plist-get edit :id) :line (car s) :col (cdr s) :end_line (car e) :end_col (cdr e)
                            :old (plist-get edit :new) :new (plist-get edit :old))
                      inverse)))
            (let ((saved (and clean (drgnx-replace--save))))
              (list :applied (vconcat (mapcar (lambda (x) (plist-get (nth 2 x) :id)) ok))
                    :skipped (vconcat (nreverse skipped)) :inverse (vconcat (nreverse inverse))
                    :tick (buffer-chars-modified-tick) :saved (if saved t :false)))))))))

(defun drgnx-replace-apply-edits (data)
  "`search-apply' DATA written into the buffer visiting its file: the answer (`search/applied' params but the change and
path).  No buffer visits it any more: `not_open' (the hub writes the file).  A buffer open in chunks or raw, one
edited since the write an undo puts back (DATA's `tick'), or one changed on disk and in the buffer is left alone, every
edit skipped with why; an unedited buffer whose file changed on disk is read again first."
  (let* ((buf (find-buffer-visiting (plist-get data :path)))
         (edits (append (plist-get data :edits) nil))
         (all (lambda (why) (list :applied [] :saved :false
                                  :skipped (vconcat (mapcar (lambda (e) (list :id (plist-get e :id) :why why)) edits)))))
         (tick (plist-get data :tick)))
    (cond
     ((not buf) (list :not_open t))
     ((drgnx-replace--partial buf) (funcall all (drgnx-replace--partial buf)))
     ((and tick (/= tick (buffer-chars-modified-tick buf))) (funcall all "edited since the replacement"))
     ((with-current-buffer buf
        (and (not (verify-visited-file-modtime buf)) (or (buffer-modified-p) (not (drgnx-replace--revert)))))
      (funcall all "changed on disk and in its buffer"))
     (t (with-current-buffer buf (let ((drgnx-replace--applying t)) (drgnx-replace--write-edits edits)))))))

(defvar drgnx-replace--applies nil "The hub's `search-apply' writes not done yet, newest first.")

(defun drgnx-replace--apply-later (data)
  "`search-apply' DATA came (in the hub's process filter): written from a timer, outside the filter."
  (push data drgnx-replace--applies)
  (drgnx-timer-soon 'replace-apply 0 #'drgnx-replace--apply-pending :owner 'tools/replace))

(defun drgnx-replace--apply-pending ()
  "Write the hub's waiting `search-apply's, oldest first, each answered (`search/applied').  A timer: never signals."
  (while drgnx-replace--applies
    (let* ((data (car (last drgnx-replace--applies)))
           (answer (condition-case e (drgnx-replace-apply-edits data)
                     (error (list :applied [] :saved :false
                                  :skipped (vconcat (mapcar (lambda (x) (list :id (plist-get x :id)
                                                                              :why (error-message-string e)))
                                                            (plist-get data :edits))))))))
      (setq drgnx-replace--applies (butlast drgnx-replace--applies))
      (ignore-errors
        (drgnx-hub--call-on drgnx-hub--events "search/applied"
                            (append (list :change (plist-get data :change) :path (plist-get data :path)) answer)
                            #'ignore)))))

;;;; The Search view (the sidebar) and the find bar

(defface drgnx-replace-match '((t :inherit lazy-highlight)) "A match, in the Search view and the find bar." :group 'drgnx)
(defface drgnx-replace-current '((t :inherit isearch)) "The match shown: the find bar's current one." :group 'drgnx)
(defface drgnx-replace-old '((t :inherit diff-removed :strike-through t)) "The text a replacement takes out." :group 'drgnx)
(defface drgnx-replace-new '((t :inherit diff-added)) "The text a replacement puts in." :group 'drgnx)
(defface drgnx-replace-dim '((t :inherit shadow)) "Folders, the status line, reasons, toggles that are off." :group 'drgnx)
(defface drgnx-replace-on '((t :inherit lazy-highlight :weight bold)) "A toggle that is on." :group 'drgnx)
(defface drgnx-replace-ctx '((t :inherit drgnx-replace-dim))
  "A context label row: the definition the matches below it are in." :group 'drgnx)
(defface drgnx-replace-kind '((t :inherit font-lock-function-name-face))
  "Symbol mode's kind icon on a definition row; Meaning's hit names." :group 'drgnx)
(defface drgnx-replace-score '((t :inherit font-lock-keyword-face))
  "Meaning's score bar: how close a hit is, as a share of the best one." :group 'drgnx)

(drgnx-defsetting drgnx-search-preview-threshold 1
  "Replace All with at least this many ticked matches first shows the Replace All sheet (every file's changes, then
Replace or Cancel); 0 never shows it.  `C-u' Replace All skips it once."
  :type 'natnum :group 'drgnx :scope 'global :agents 'never :schema 'natnum)

(drgnx-defsetting drgnx-search-context t
  "Non-nil: the Search view shows a dim label row (the definition's name) above the first match of each definition."
  :type 'boolean :group 'drgnx :safe #'booleanp :scope 'global :workspace 'never :agents 'never)

(defvar drgnx-replace-delay 0.25 "Seconds after typing stops before the Search view searches (or redraws).")
(defvar drgnx-replace-bar-limit 5000 "The most matches the find bar highlights.")
(defconst drgnx-replace-buffer-name "*drgnx search*")
(defconst drgnx-replace-bar-buffer-name "*drgnx find*")

(defvar-local drgnx-replace--widgets nil
  "Alist NAME → widget: fields `find' `replace' `include' `exclude', toggles :symbol :case :word :regexp :lines, the
mode chip `mode' and the scope chips (`drgnx-replace--scopes').")
(defvar-local drgnx-replace--opts nil
  "Plist (:mode :symbol :case :word :regexp :scope :base :lines): :base is Branch's chosen base, :lines `±'.")
(defconst drgnx-replace--scopes
  '((project "Project" "Search every file of the project")
    (file "This file" "Search only the file the view was opened from")
    (open "Open" "Search the files open in the editor")
    (changed "Changed" "Search the working tree's modified, added and untracked files")
    (staged "Staged" "Search the files with staged changes (their working-tree text)")
    (branch "Branch" "Search the files changed on this branch; pressed again, choose the base"))
  "The Search view's scope chips, in order: (SCOPE LABEL HELP).  The last three are git scopes.")
(defvar-local drgnx-replace--scope-done nil
  "What the hub's last search said of its git scope (`search-run-done''s `:scope'), or nil.")
(defvar-local drgnx-replace--origin nil "Marker: the buffer and point the view or the bar works for (a symbol, This file).")
(defvar-local drgnx-replace--root nil "The directory the view searches.")
(defvar-local drgnx-replace--matches nil "The view's matches, in order.")
(defvar-local drgnx-replace--sent nil
  "Hash FILE → what the hub was last sent of its modified buffer (`search/buffer'): the buffer's tick, or `large'.")
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
(defvar-local drgnx-replace--lists-beg nil "Marker: the lists' start (pinned counts; saved and recent searches).")
(defvar-local drgnx-replace--lists-end nil "Marker: the lists' end.")
(defvar-local drgnx-replace--saved nil "The project's saved searches (`search/saved/list'), as the hub lists them.")
(defvar-local drgnx-replace--saved-asked nil "Non-nil once this view asked for the project's saved searches.")
(defvar-local drgnx-replace--recent nil "The project's recent searches (`search/recent'), newest first, Find empty.")
(defvar-local drgnx-replace--pin-counts nil "Alist: a pinned saved search's place in `drgnx-replace--saved' → matches.")
(defvar-local drgnx-replace--history nil "The recent searches a history walk goes through, newest first.")
(defvar-local drgnx-replace--history-at nil "The walk's place in `drgnx-replace--history', or nil (no walk).")
(defvar-local drgnx-replace--history-here nil "The search the view held when the walk began.")
(defvar-local drgnx-replace--status "" "The last action's message (Replaced …, an error), on the status line.")
(defvar-local drgnx-replace--waiting nil "Non-nil while a text search waits for the hub (`drgnx-replace--hub-up').")
(defvar-local drgnx-replace--searching nil "Non-nil until the view's search sends :done.")
(defvar-local drgnx-replace--want nil "What the pause after typing ends in: `search' or `redraw'.")
(defvar-local drgnx-replace--undo nil "The hub's change sets of the view's replacements (`search/undo' puts one back), newest first.")
(defvar-local drgnx-replace--shown nil "Overlay on the match shown in the editor.")
(defvar-local drgnx-replace--bar-overlays nil "The find bar's matches: overlays in its target buffer, in order.")
(defvar-local drgnx-replace--bar-index nil "The current match's index in `drgnx-replace--bar-overlays'.")
(defvar drgnx-replace--quiet nil "Non-nil while the code, not the user, fills a field.")
(defvar drgnx-replace-refresh-delay 0.5 "Seconds after a listed file changes before its rows are searched again.")
(defvar drgnx-replace-watch-limit 200
  "The most listed files whose folders are watched for changes on disk (more: searched again when the view shows).")
(defvar drgnx-replace-refresh-max-bytes (* 4 1024 1024)
  "A modified buffer bigger than this is not sent to the hub: its file is searched on disk (`search/buffer' `large').")
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
(defvar drgnx-replace-find-keys-map (make-sparse-keymap)
  "The Search view's Find field's own keys (the history walk's Up and Down in the VS Code profile), from the key
profiles.")
(defvar drgnx-replace--find-field-map (make-composed-keymap (list drgnx-replace-find-keys-map drgnx-replace--field-map))
  "The Search view's Find field.")
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
                                  :keymap (cond ((drgnx-replace--bar-p) drgnx-replace--bar-field-map)
                                                ((eq name 'find) drgnx-replace--find-field-map)
                                                (t drgnx-replace--field-map))
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
  (cond ((memq name '(:symbol :case :word :regexp :lines))
         (if (drgnx-replace--opt name) 'drgnx-replace-on 'drgnx-replace-dim))
        ((assq name drgnx-replace--scopes) (if (eq (drgnx-replace--opt :scope) name) 'drgnx-replace-on 'drgnx-replace-dim))
        (t 'widget-button)))

(defun drgnx-replace--restyle (name)
  "Draw button NAME again in the face its state gives."
  (when-let* ((w (drgnx-replace--widget name)))
    (let ((buffer-undo-list t))
      (widget-put w :button-face (drgnx-replace--button-face name))
      (save-excursion (widget-value-set w (widget-value w))))))

(defun drgnx-replace--insert-toggles (&optional symbol)
  "The Aa, ab and .* toggles; with SYMBOL (the find bar) the ⟨⟩ Symbol toggle before them."
  (pcase-dolist (`(,name ,label ,help) `(,@(and symbol '((:symbol "⟨⟩ Symbol" "Rename the symbol: the language server's edits")))
                                         (:case "Aa" "Match case") (:word "ab" "Whole word") (:regexp ".*" "Regular expression")))
    (drgnx-replace--insert-button name label help (lambda () (drgnx-replace--toggle name)))))

(defconst drgnx-replace--modes
  '((text "Text" "text or regex") (symbol "Symbol" "a name: its definitions, then its uses")
    (meaning "Meaning" "describe what the code does"))
  "The Search view's modes, in the chip's order: (MODE LABEL HINT); HINT says what to type in Find.")

(defun drgnx-replace--chip-label ()
  "The mode chip's text: the mode, or Rename while the view shows the language server's edits."
  (format "%-7s" (if (drgnx-replace--opt :symbol) "Rename"
                   (nth 1 (assq (drgnx-replace--opt :mode) drgnx-replace--modes)))))

(defun drgnx-replace--hint ()
  "What to type in Find, for the view's mode."
  (if (drgnx-replace--opt :symbol) "" (or (nth 2 (assq (drgnx-replace--opt :mode) drgnx-replace--modes)) "")))

(defun drgnx-replace--apply-mode ()
  "Name the mode on the chip and grey out what it does not use: Symbol and Meaning are read-only (no replace field,
no globs; Symbol keeps Aa); Rename (the language server's edits) keeps the replace field only."
  (let ((off (cond ((drgnx-replace--opt :symbol) '(include exclude :case :word :regexp))
                   ((eq (drgnx-replace--opt :mode) 'symbol) '(replace include exclude :word :regexp))
                   ((eq (drgnx-replace--opt :mode) 'meaning) '(replace include exclude :case :word :regexp)))))
    (dolist (name '(replace include exclude :case :word :regexp))
      (when-let* ((w (drgnx-replace--widget name)))
        (let ((buffer-undo-list t)) (widget-apply w (if (memq name off) :deactivate :activate)))))
    (when-let* ((w (drgnx-replace--widget 'mode)))
      (let ((buffer-undo-list t)) (save-excursion (widget-value-set w (drgnx-replace--chip-label)))))))

(defun drgnx-replace--set-mode (mode)
  "Search in MODE (`text', `symbol' or `meaning'), out of Rename, and search again."
  (when (drgnx-replace--opt :symbol) (setq drgnx-replace--opts (plist-put drgnx-replace--opts :symbol nil)))
  (setq drgnx-replace--opts (plist-put drgnx-replace--opts :mode mode))
  (drgnx-replace--apply-mode)
  (drgnx-replace--search-now))

(defun drgnx-replace--check-writable ()
  "A user error in a mode that finds without replacing (Symbol, Meaning)."
  (when (and (not (drgnx-replace--opt :symbol)) (memq (drgnx-replace--opt :mode) '(symbol meaning)))
    (user-error "%s searches only find: Text mode replaces" (string-trim (drgnx-replace--chip-label)))))

(defun drgnx-replace--mode-command (mode)
  "Search the Search view in MODE (nil: the next one after its mode)."
  (with-current-buffer (drgnx-replace--live-view)
    (drgnx-replace--set-mode
     (or mode (car (or (cadr (memq (assq (drgnx-replace--opt :mode) drgnx-replace--modes) drgnx-replace--modes))
                       (car drgnx-replace--modes)))))))

(defun drgnx-replace-search-mode-next ()
  "The Search view's next mode: Text → Symbol → Meaning → Text; it searches again."
  (interactive)
  (drgnx-replace--mode-command nil))

(defun drgnx-replace-search-mode-text ()
  "Search the Search view's words as text (Replace works here)."
  (interactive)
  (drgnx-replace--mode-command 'text))

(defun drgnx-replace-search-mode-symbol ()
  "Search the Search view's name as a symbol: its definitions, then its uses (read-only)."
  (interactive)
  (drgnx-replace--mode-command 'symbol))

(defun drgnx-replace-search-mode-meaning ()
  "Search by meaning: the code the Search view's words describe (read-only)."
  (interactive)
  (drgnx-replace--mode-command 'meaning))

(defun drgnx-replace--toggle (name)
  "Turn the toggle NAME (:symbol :case :word :regexp) on or off, and search again.  A greyed-out toggle stays."
  (let ((w (drgnx-replace--widget name)))
    (when (and w (widget-apply w :active))
      (if (eq name :symbol)
          (drgnx-replace--set-symbol (not (drgnx-replace--opt :symbol)))
        (setq drgnx-replace--opts (plist-put drgnx-replace--opts name (not (drgnx-replace--opt name))))
        (drgnx-replace--restyle name))
      (drgnx-replace--requery))))

(defun drgnx-replace--git-scope-p ()
  "Non-nil when the view searches a git scope (Changed, Staged, Branch)."
  (memq (drgnx-replace--opt :scope) '(changed staged branch)))

(defun drgnx-replace--scope-label (scope)
  "Chip SCOPE's text: its name, Branch's base and ▾, and the file count the last search of it gave."
  (let ((n (and (eq scope (drgnx-replace--opt :scope)) (plist-get drgnx-replace--scope-done :files)))
        (base (and (eq scope 'branch) (drgnx-replace--opt :base))))
    (concat (nth 1 (assq scope drgnx-replace--scopes)) (and base (concat " " base)) (and n (format " %d" n))
            (and (eq scope 'branch) " ▾"))))

(defun drgnx-replace--apply-scope ()
  "Draw the scope chips as the view's scope makes them: on or off, their labels; `±' only in a git scope."
  (let ((buffer-undo-list t))
    (pcase-dolist (`(,scope . ,_) drgnx-replace--scopes)
      (when-let* ((w (drgnx-replace--widget scope)))
        (widget-put w :button-face (drgnx-replace--button-face scope))
        (save-excursion (widget-value-set w (drgnx-replace--scope-label scope)))))
    (when-let* ((w (drgnx-replace--widget :lines)))
      (widget-apply w (if (drgnx-replace--git-scope-p) :activate :deactivate)))))

(defun drgnx-replace--set-scope (scope)
  "Search SCOPE (a chip of `drgnx-replace--scopes'), and search again."
  (setq drgnx-replace--opts (plist-put drgnx-replace--opts :scope scope)
        drgnx-replace--scope-done nil)
  (drgnx-replace--apply-scope)
  (drgnx-replace--requery))

(defun drgnx-replace--branch-pressed ()
  "The Branch chip: Branch on, or, when it is, its menu of bases."
  (if (eq (drgnx-replace--opt :scope) 'branch) (drgnx-replace--choose-base) (drgnx-replace--set-scope 'branch)))

(defun drgnx-replace--choose-base ()
  "The Branch menu: the base to search the branch's changes against (the upstream, the default, recent branches, or
any name typed), from `search/scope-bases'.  Only from a command or a press: it asks."
  (unless (fboundp 'drgnx-hub-call-sync) (require 'drgnx-hub-client))
  (let* ((b (drgnx-hub-call-sync "search/scope-bases" (list :root drgnx-replace--root)))
         (names (delete-dups (delq nil (append (list (plist-get b :upstream) (plist-get b :default))
                                               (append (plist-get b :recent) nil)))))
         (pick (string-trim (completing-read "Search the branch's changes against: " names))))
    (unless (string-empty-p pick)
      (setq drgnx-replace--opts (plist-put drgnx-replace--opts :base pick))
      (drgnx-replace--set-scope 'branch))))

(defun drgnx-replace--open-files ()
  "The files normal buffers visit under the root, sorted, as a vector (the Open scope)."
  (let ((root (file-name-as-directory (expand-file-name drgnx-replace--root))) out)
    (dolist (b (buffer-list))
      (when-let* ((f (buffer-file-name b)) ((not (string-prefix-p " " (buffer-name b))))
                  ((not (file-remote-p f))) ((string-prefix-p root f)))
        (push f out)))
    (vconcat (sort (delete-dups out) #'string<))))

(defun drgnx-replace--scope-param (file)
  "The scope `search/run' takes: FILE's for This file (the project without one), the open files, or a git scope with
Branch's base and `±'."
  (pcase (drgnx-replace--opt :scope)
    ('file (if file (list :kind "file" :files (vector file)) (list :kind "project")))
    ('open (list :kind "open" :files (drgnx-replace--open-files)))
    ((and s (or 'changed 'staged 'branch))
     (append (list :kind (symbol-name s))
             (when-let* (((eq s 'branch)) (base (drgnx-replace--opt :base))) (list :base base))
             (and (drgnx-replace--opt :lines) (list :changed_lines t))))
    (_ (list :kind "project"))))

(defun drgnx-replace--scope-text ()
  "What the status line says of the last search's git scope: its files and what it skipped, or why it is empty."
  (when-let* ((d drgnx-replace--scope-done) ((not (plist-get d :needs_base)))
              (name (nth 1 (assq (drgnx-replace--opt :scope) drgnx-replace--scopes))))
    (if-let* ((why (plist-get d :why_empty)))
        (format "%s: %s" name why)
      (let ((n (or (plist-get d :files) 0)) (sub (or (plist-get d :submodules) 0)) (del (or (plist-get d :deleted) 0)))
        (string-join (delq nil (list (format "%s: %d file%s" name n (if (= n 1) "" "s"))
                                     (and (> sub 0) (format "%d submodule%s not searched" sub (if (= sub 1) "" "s")))
                                     (and (> del 0) (format "%d deleted" del))))
                     " · ")))))

(defun drgnx-replace--scope-command (scope)
  "Search the Search view in SCOPE (nil: the chip after its scope)."
  (with-current-buffer (drgnx-replace--live-view)
    (drgnx-replace--set-scope
     (or scope (car (or (cadr (memq (assq (drgnx-replace--opt :scope) drgnx-replace--scopes) drgnx-replace--scopes))
                        (car drgnx-replace--scopes)))))))

(defun drgnx-replace-search-scope-next ()
  "The Search view's next scope: Project → This file → Open → Changed → Staged → Branch → Project; it searches again."
  (interactive)
  (drgnx-replace--scope-command nil))

(defun drgnx-replace-search-scope-changed ()
  "Show the Search view searching the working tree's changed files, the word at point to find."
  (interactive)
  (drgnx-replace--open :scope 'changed))

(defun drgnx-replace-search-scope-branch ()
  "Show the Search view searching the files changed on this branch, the word at point to find."
  (interactive)
  (drgnx-replace--open :scope 'branch))

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
  (drgnx-replace--apply-mode)
  (when-let* ((on) (name (drgnx-replace--symbol-at drgnx-replace--origin)))
    (drgnx-replace--fill 'find name)))

(defun drgnx-replace--requery ()
  "Search again now: the view's search, or the bar's."
  (if (drgnx-replace--bar-p) (drgnx-replace--bar-search) (drgnx-replace--search-now)))

(defun drgnx-replace--edited (name)
  "The user typed in field NAME."
  (unless drgnx-replace--quiet
    (setq drgnx-replace--history-at nil)          ; typing ends a history walk
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
  (setq drgnx-replace--opts (list :mode 'text :symbol nil :case nil :word nil :regexp nil :scope 'project
                                  :base nil :lines nil)
        drgnx-replace--widgets nil
        drgnx-replace--off (make-hash-table :test #'eq)
        drgnx-replace--seen (make-hash-table :test #'equal)
        drgnx-replace--listed (make-hash-table :test #'equal)
        drgnx-replace--off-files (make-hash-table :test #'equal)
        drgnx-replace--headers (make-hash-table :test #'equal)
        drgnx-replace--last-row (make-hash-table :test #'equal))
  ;; the mode chip is Find's label: it says what Find means
  (drgnx-replace--insert-button 'mode (drgnx-replace--chip-label) "Search mode: Text, Symbol or Meaning (the next one)"
                                #'drgnx-replace-search-mode-next)
  (drgnx-replace--insert-field 'find "" nil)
  (drgnx-replace--insert-field 'replace "Replace   " nil)
  (drgnx-replace--insert-toggles)
  (widget-insert "\n")
  (pcase-dolist (`(,scope ,_ ,help) drgnx-replace--scopes)
    (drgnx-replace--insert-button scope (drgnx-replace--scope-label scope) help
                                  (if (eq scope 'branch) #'drgnx-replace--branch-pressed
                                    (lambda () (drgnx-replace--set-scope scope)))))
  (drgnx-replace--insert-button :lines "±" "Changed lines only: matches in the lines the scope's changes added"
                                (lambda () (drgnx-replace--toggle :lines)))
  (widget-insert "\n")
  (drgnx-replace--insert-field 'include "Include   " nil)
  (drgnx-replace--insert-field 'exclude "Exclude   " nil)
  (drgnx-replace--insert-button nil "Replace All" "Replace every ticked match" #'drgnx-replace-all)
  (drgnx-replace--insert-button nil "Preview" "The changes of the selected row's file, as a diff"
                                #'drgnx-replace-preview-file)
  (drgnx-replace--insert-button nil "Undo" "Undo the last replacement, in every file" #'drgnx-replace-view-undo)
  (drgnx-replace--insert-button nil "☆" "Save this search (the empty view lists the saved ones)"
                                #'drgnx-replace-search-save)
  (widget-insert "\n")
  (setq drgnx-replace--status-beg (point-marker))
  (widget-insert "\n")
  (setq drgnx-replace--status-end (copy-marker (1- (point)) t))
  ;; the pinned searches' counts, and under an empty Find the saved and recent searches
  (setq drgnx-replace--lists-beg (point-marker))
  (widget-insert "\n")
  (setq drgnx-replace--lists-end (copy-marker (1- (point)) t))   ; before the blank line: the results start after it
  (setq drgnx-replace--results (point-marker))
  (widget-setup)
  (drgnx-replace--apply-scope)
  (goto-char (widget-field-start (drgnx-replace--widget 'find))))

(defmacro drgnx-replace--drawing (&rest body)
  "BODY changes the view's own text (results, status): no read-only check, no undo, no field reactions."
  `(let ((inhibit-read-only t) (inhibit-modification-hooks t) (buffer-undo-list t))
     (save-excursion ,@body)))

(defun drgnx-replace--update-status ()
  "Write the status line: how many results, still searching, the last message."
  (let* ((n (if drgnx-view-patch (or (cdr drgnx-replace--hub-counts) 0) (length drgnx-replace--matches)))
         (files (if drgnx-view-patch (or (car drgnx-replace--hub-counts) 0) (hash-table-count drgnx-replace--seen)))
         (counts (cond ((and (zerop n) drgnx-replace--searching) "Searching…")
                       ((zerop n) (if (string-empty-p (drgnx-replace--text 'find)) (drgnx-replace--hint) "No results"))
                       (t (format "%s%d result%s in %d file%s" (if drgnx-replace--searching "Searching… " "")
                                  n (if (= n 1) "" "s") files (if (= files 1) "" "s")))))
         ;; Symbol finds by name only (no type resolution): its results say so
         (by-name (if (and (> n 0) (eq (drgnx-replace--opt :mode) 'symbol))
                      "by name: same-named things in other scopes are listed too"
                    ""))
         (line (string-join (seq-remove #'string-empty-p
                                        (list counts by-name (or (drgnx-replace--scope-text) "")
                                              drgnx-replace--status))
                            " · ")))
    (drgnx-replace--drawing
     (delete-region drgnx-replace--status-beg drgnx-replace--status-end)
     (goto-char drgnx-replace--status-beg)
     (insert (propertize line 'face 'drgnx-replace-dim))
     ;; the newest hand-off to an agent: its state chip
     (insert (drgnx-search-handoff-chip))
     ;; Branch with no base to take (a detached HEAD, no upstream, main or master): its menu
     (when (plist-get drgnx-replace--scope-done :needs_base)
       (insert (propertize " · " 'face 'drgnx-replace-dim))
       (insert-text-button "Choose…" 'face 'link 'follow-link t 'help-echo "Choose the branch's base"
                           'action (lambda (_) (drgnx-replace--choose-base))))
     ;; no automatic mode: a text search that found nothing offers the same words by meaning
     (when (and (equal counts "No results") (eq (drgnx-replace--opt :mode) 'text) (not (drgnx-replace--opt :symbol))
                (not (plist-get drgnx-replace--scope-done :needs_base)))
       (insert (propertize " · " 'face 'drgnx-replace-dim))
       (insert-text-button "Try Meaning" 'face 'link 'follow-link t 'help-echo "Search these words by meaning"
                           'action (lambda (_) (drgnx-replace-search-mode-meaning)))))))

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
        drgnx-replace--hub-counts nil
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
      (drgnx-replace--hub-call "search/grep-replace" (list :view drgnx-replace-view :replace drgnx-replace--new))
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
    ;; the lists under an empty Find; the pinned counts again (their files may have changed too)
    (drgnx-replace--lists-update)
    (when drgnx-replace--saved (drgnx-replace--pins-later))
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
      (if drgnx-replace--waiting (drgnx-replace--search-now) (drgnx-replace--lists-update)))))

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
      (setq drgnx-replace--opts (plist-put drgnx-replace--opts :scope scope)
            drgnx-replace--scope-done nil)
      (drgnx-replace--apply-scope)
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
buffers' text goes to the hub after a pause (`drgnx-replace--send-buffers'), which searches it in place of the file."
  (when (and buffer-file-name (not drgnx-replace--applying))
    (condition-case e
        (when-let* ((view (get-buffer drgnx-replace-buffer-name)) (file buffer-file-name))
          (with-current-buffer view
            (cond (drgnx-view-patch (drgnx-replace--buffers-later))
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

(defun drgnx-replace--report (written files skipped)
  "What a write said: WRITTEN matches in FILES files, SKIPPED of them left (\"Replaced 58 in 4 files · 2 skipped\")."
  (format "Replaced %d in %d file%s%s" written files (if (= files 1) "" "s")
          (if (> skipped 0) (format " · %d skipped" skipped) "")))

(defvar-local drgnx-replace--writes nil
  "The view's writes the hub has not ended: alist CHANGE → (KIND DATA SKIPPED), KIND and DATA what its end does
\(`drgnx-replace--change-done'), SKIPPED what its edit set left out.")

(defun drgnx-replace--open-paths ()
  "The files this Emacs has open (every buffer visiting one): the hub sends their edits here (`search-apply')."
  (vconcat (delq nil (mapcar #'buffer-file-name (buffer-list)))))

(defun drgnx-replace--hub-write (method params then)
  "METHOD with PARAMS to the hub on the subscribed connection; THEN with its result in this buffer; an error goes to
the status line."
  (let ((buf (current-buffer)))
    (unless (fboundp 'drgnx-hub--call-on) (require 'drgnx-hub-client))
    (condition-case err
        (drgnx-hub--call-on drgnx-hub--events method params
                            (lambda (result error)
                              (when (buffer-live-p buf)
                                (with-current-buffer buf
                                  (if error (drgnx-replace--message "%s" error) (funcall then result))))))
      (error (drgnx-replace--message "%s" (error-message-string err))))))

(defun drgnx-replace--write (params kind &optional data sheet)
  "Write what PARAMS (`search/edits' params but the view) name: the hub's edit set, then its apply (`search/apply').
When it ends, KIND (`all', `this', `symbol-all', `symbol-this') and DATA say what the view does
\(`drgnx-replace--change-done').  SHEET: the edit set goes to the Replace All sheet first when it has at least
`drgnx-search-preview-threshold' edits (0: never)."
  (drgnx-replace--hub-write
   "search/edits" (append (list :view drgnx-replace-view) params)
   (lambda (r)
     (let ((n (apply #'+ (mapcar (lambda (f) (length (plist-get f :edits))) (plist-get r :files)))))
       (if (and sheet (> drgnx-search-preview-threshold 0) (>= n drgnx-search-preview-threshold))
           (drgnx-replace--sheet-show r)
         (drgnx-replace--apply-change (plist-get r :change) kind data (append (plist-get r :skipped) nil)))))))

(defun drgnx-replace--apply-change (change kind data skipped)
  "Write the hub's change set CHANGE (`search/apply'), its edit set having left out SKIPPED; KIND and DATA as in
`drgnx-replace--write'."
  (push (list change kind data skipped) drgnx-replace--writes)
  (drgnx-replace--hub-write "search/apply" (list :view drgnx-replace-view :change change
                                                 :open (drgnx-replace--open-paths))
                            #'ignore))

(defun drgnx-replace--skipped-ids (skipped)
  "SKIPPED (the hub's, :id :path :why) as `search/grep-skipped' takes them: the matches' ids and why."
  (vconcat (delq nil (mapcar (lambda (s) (when-let* ((id (plist-get s :id))) (list :id id :why (plist-get s :why))))
                             skipped))))

(defun drgnx-replace--change-done (data)
  "The hub's `search-change' DATA: one of the view's writes ended; the view shows what it wrote and what it left."
  (let* ((change (plist-get data :change))
         (entry (assoc change drgnx-replace--writes))
         (undo (equal (plist-get data :origin) "undo")))
    (when (or entry undo)
      (setq drgnx-replace--writes (delq entry drgnx-replace--writes))
      (pcase-let* ((`(,_ ,kind ,extra ,before) entry)
                   (skipped (append before (plist-get data :skipped) nil))
                   (written (or (plist-get data :written) 0))
                   (files (or (plist-get data :files) 0))
                   (msg (drgnx-replace--report written files (length skipped))))
        (when (and (not undo) (> written 0)) (push change drgnx-replace--undo))
        (pcase (if undo 'undo kind)
          ('undo
           (let ((left (append (plist-get data :left) nil)))
             (drgnx-replace--search-now)
             (drgnx-replace--message "Undone in %d file%s%s" files (if (= files 1) "" "s")
                                     (if left (format "; left alone (changed since): %s"
                                                      (mapconcat #'file-name-nondirectory left ", "))
                                       ""))))
          ('all
           ;; what is left: the skipped, with their reasons (the hub lists them alone, by node id, and stops the search)
           (drgnx-replace--clear)
           (drgnx-replace--hub-call "search/grep-skipped"
                                    (list :view drgnx-replace-view :skipped (drgnx-replace--skipped-ids skipped)))
           (setq drgnx-replace--hub-counts (cons (length (seq-uniq (mapcar (lambda (s) (plist-get s :path)) skipped)))
                                                 (length skipped)))
           (drgnx-replace--message "%s" msg))
          ('this
           (drgnx-replace--search-now)
           (drgnx-replace--message "%s" (if skipped (format "Skipped: %s" (plist-get (car skipped) :why)) msg)))
          ('symbol-all
           ;; EXTRA: the matches in the order the edits named them (`e:K')
           (drgnx-replace--clear)
           (drgnx-replace--add (delq nil (mapcar (lambda (s)
                                                   (when-let* ((id (plist-get s :id)) ((string-prefix-p "e:" id))
                                                               (m (nth (string-to-number (substring id 2)) extra)))
                                                     (drgnx-replace--skip m (plist-get s :why))))
                                                 skipped)))
           (drgnx-replace--watch)
           (drgnx-replace--message "%s" msg))
          ('symbol-this
           (if skipped
               (progn (setq drgnx-replace--status (format "Skipped: %s" (plist-get (car skipped) :why)))
                      (drgnx-replace--update-status))
             (drgnx-replace--symbol-row-gone (car extra) (cadr extra))
             (setq drgnx-replace--status msg)
             (drgnx-replace--update-status))))))))

(defun drgnx-replace--given (ms new)
  "Symbol mode's matches MS (the server's edits, the view's own rows) as edits the hub takes (`search/edits' `edits'),
each replaced by NEW."
  (vconcat (mapcar (lambda (m)
                     (list :path (plist-get m :file) :line (plist-get m :line) :col (plist-get m :col)
                           :end_col (plist-get m :end) :old (plist-get m :text)
                           :new (drgnx-replace-new-text m new)))
                   ms)))

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

(defun drgnx-replace--rows-match (id &optional extra)
  "Match node ID of the model as a match plist (:file :line :col :end :text), EXTRA appended.  Its file is its parent's
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
    (drgnx-replace--rows-boxes drgnx-view (cons file ms))
    (drgnx-replace--previews-later)))


(defun drgnx-replace--rows-step (dir)
  "Select the next (DIR 1) or previous (DIR -1) match, wrapping, and make sure its row is shown (the hub sends a window
of the rows, the model holds every match): its id, or nil when there is none."
  (let ((id (drgnx-replace--rows-step-model dir)))
    (when (stringp id) (drgnx-replace--reach id))
    id))

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
  (unless (gethash id (drgnx-view-patch-rows drgnx-view-patch))
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

(defun drgnx-replace--rows-replace-all (new &optional sheet)
  "Replace All on the rows path: every match of the hub's search but the unticked (Sjá's ticked set, sent as `off':
the model may hold only a window of a long search) by NEW; the list is then what it skipped, each with why
\(`search/grep-skipped').  SHEET: the Replace All sheet first (`drgnx-replace--write')."
  (let ((off (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked))
        (all (cdr drgnx-replace--hub-counts)))
    (when (or (eql all 0) (and all (>= (length off) all)))
      (user-error "Nothing to replace: no match is ticked"))
    (drgnx-replace--write (list :off (vconcat off) :replace new) 'all nil sheet)))

;;;;; On the rows path: the hub searches and streams the results (`search/run')
;; A text search goes to the hub (this Emacs has Sjá; a search typed before the hub is up waits for it): the view is
;; attached as the hub-fed view `drgnx-replace-view', `search/run' starts the search, and the hub's rows (a reset,
;; then each file's header and matches) are inserted by `drgnx-view-apply-patch'.  A new query makes the hub send a
;; reset and drop the old query's late rows, and the editor drops one that still comes by its base.  `search-run-done'
;; ends the search and names the matches the user had unticked before it, found again.  A replace text typed meanwhile is `search/grep-replace' (the hub patches the previews).  Symbol mode
;; (the server's edits) keeps rows of Emacs's own (the `replace-results' view type).  What the hub does not see, Lisp
;; tells it: the modified buffers' text (`search/buffer', `drgnx-replace--send-buffers': the hub searches it in place
;; of the file) and, through file-notify watches on the listed files, a change on disk (searched again).

(defun drgnx-replace--hub-ready-p ()
  "Non-nil when a text search can go to the hub: Sjá in this Emacs, the hub connected."
  (and (fboundp 'nidhogg-view--call)
       (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events)))

(declare-function drgnx-view-env-twin "drgnx-view-env" (class prefixes &optional setup))

(defconst drgnx-replace--twin-keys
  '(drgnx-replace-next drgnx-replace-prev drgnx-replace-next-file drgnx-replace-prev-file)
  "The Search view's commands a twin runs: it moves and visits; the rest (ticks, replace, the fields) are the view's.")

(defun drgnx-replace--twin-guard ()
  "`pre-command-hook' of a Search twin: a Search command other than `drgnx-replace--twin-keys' is refused."
  (when (and (symbolp this-command) (string-prefix-p "drgnx-replace-" (symbol-name this-command))
             (not (memq this-command drgnx-replace--twin-keys)))
    (setq this-command (lambda () (interactive) (message "Search: edit, tick and replace in the Search view")))))

(defun drgnx-replace--twin (class)
  "The Search view's results in display CLASS (`drgnx-view-patch-twin-function'): a mirror with no fields, its
query on the header line; its keys move and visit (`drgnx-replace--twin-keys'), and it draws no tick boxes."
  (let ((query (drgnx-replace--text 'find)))
    (drgnx-view-env-twin class '("drgnx-replace-")
                         (lambda ()
                           (remove-hook 'kill-buffer-hook #'drgnx-replace--view-killed t)
                           (remove-hook 'drgnx-view-patch-patched-functions #'drgnx-replace--rows-boxes t)
                           (add-hook 'window-scroll-functions #'drgnx-replace--scrolled nil t)
                           (add-hook 'pre-command-hook #'drgnx-replace--twin-guard nil t)
                           (setq-local header-line-format (format "Search: %s" query))))))

(defun drgnx-replace--hub-attach ()
  "Make the view hub-fed (the hub's rows below the fields), when it is not; its env goes while a window shows it."
  (unless drgnx-view-patch
    (drgnx-view-patch-attach drgnx-replace-view "unshown" :start drgnx-replace--results)
    (setq-local drgnx-view-patch-twin-function #'drgnx-replace--twin)
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
  (let ((off (prog1 drgnx-replace--carry (setq drgnx-replace--carry nil))))
    (setq drgnx-replace--searching t)
    (drgnx-replace--send-buffers)
    (drgnx-replace--hub-call
     "search/run"
     (append (list :view drgnx-replace-view :root drgnx-replace--root :search (drgnx-replace--spec text file))
             (and off (list :off (vconcat off)))
             (and (not drgnx-search-context) (list :context :false))))))

(defun drgnx-replace--spec (text file)
  "The view's search of TEXT (in FILE for This file) as the hub takes it (`search/run', the saved searches): the
mode's query, and in Text mode the replacement and the globs; the scope."
  (let* ((globs (lambda (name) (drgnx-replace--globs (drgnx-replace--text name))))
         (on (lambda (name) (if (drgnx-replace--opt name) t :false)))
         (mode (drgnx-replace--opt :mode))
         (text-p (not (memq mode '(symbol meaning)))))   ; Symbol and Meaning: no replacement, no globs
    (append (list :query (pcase mode
                           ('symbol (list :mode "symbol" :name text :case (funcall on :case)))
                           ('meaning (list :mode "meaning" :question text))
                           (_ (list :mode "text" :text text :case (funcall on :case)
                                    :word (funcall on :word) :regexp (funcall on :regexp)))))
            (and text-p (list :replace (drgnx-replace--text 'replace)))
            (list :scope (drgnx-replace--scope-param file))
            (when-let* ((_ text-p) (g (funcall globs 'include))) (list :include (vconcat g)))
            (when-let* ((_ text-p) (g (funcall globs 'exclude))) (list :exclude (vconcat g))))))

(defun drgnx-replace--hub-ask (method params then)
  "METHOD with PARAMS to the hub, without waiting; THEN with its result in this buffer (a failure is dropped: what
it would draw stays as it was)."
  (let ((buf (current-buffer)))
    (unless (fboundp 'drgnx-hub--call-on) (require 'drgnx-hub-client))
    (ignore-errors
      (drgnx-hub--call-on drgnx-hub--events method params
                          (lambda (result error)
                            (when (and (not error) (buffer-live-p buf))
                              (with-current-buffer buf (funcall then result))))))))

;;;;; Recent and saved searches

(defconst drgnx-replace-recent-shown 8 "How many recent searches the empty view lists.")

(defun drgnx-replace--true (v) "Non-nil when the hub's V is true (not nil, not JSON false)." (and v (not (eq v :false))))

(defun drgnx-replace--spec-text (spec)
  "What SPEC's query searched for."
  (let ((q (plist-get spec :query))) (or (plist-get q :text) (plist-get q :name) (plist-get q :question) "")))

(defun drgnx-replace--spec-label (spec)
  "SPEC as a line of the lists: its words, its mode unless Text, its scope unless Project."
  (let ((mode (plist-get (plist-get spec :query) :mode)) (kind (plist-get (plist-get spec :scope) :kind)))
    (concat (drgnx-replace--spec-text spec)
            (and mode (not (equal mode "text")) (format " · %s" (capitalize mode)))
            (when-let* (((and kind (not (equal kind "project")))) (s (assq (intern kind) drgnx-replace--scopes)))
              (format " · %s" (nth 1 s))))))

(defun drgnx-replace--restore (spec)
  "Make SPEC (a search as the hub keeps it) the view's search, whole, and run it."
  (let* ((q (plist-get spec :query)) (scope (plist-get spec :scope))
         (globs (lambda (k) (string-join (append (plist-get spec k) nil) ", "))))
    (when (drgnx-replace--opt :symbol) (drgnx-replace--set-symbol nil))
    (setq drgnx-replace--opts (plist-put drgnx-replace--opts :mode (intern (or (plist-get q :mode) "text"))))
    (dolist (k '(:case :word :regexp))
      (setq drgnx-replace--opts (plist-put drgnx-replace--opts k (drgnx-replace--true (plist-get q k))))
      (drgnx-replace--restyle k))
    (when (equal (plist-get q :mode) "symbol")      ; Symbol's case is on unless the search said otherwise
      (setq drgnx-replace--opts (plist-put drgnx-replace--opts :case (not (eq (plist-get q :case) :false))))
      (drgnx-replace--restyle :case))
    (setq drgnx-replace--opts (plist-put drgnx-replace--opts :scope (if scope (intern (plist-get scope :kind)) 'project))
          drgnx-replace--opts (plist-put drgnx-replace--opts :base (plist-get scope :base))
          drgnx-replace--opts (plist-put drgnx-replace--opts :lines (drgnx-replace--true (plist-get scope :changed_lines)))
          drgnx-replace--scope-done nil)
    (drgnx-replace--restyle :lines)
    (drgnx-replace--fill 'find (drgnx-replace--spec-text spec))
    (drgnx-replace--fill 'replace (or (plist-get spec :replace) ""))
    (drgnx-replace--fill 'include (funcall globs :include))
    (drgnx-replace--fill 'exclude (funcall globs :exclude))
    (drgnx-replace--apply-mode)
    (drgnx-replace--apply-scope)
    (drgnx-replace--search-now)))

(defun drgnx-replace--history-step (n)
  "Walk N searches back (1) or forward (-1) through the project's recent ones, restoring each; forward past the
newest restores the search the walk began from."
  (with-current-buffer (drgnx-replace--live-view)
    (unless drgnx-replace--history-at
      (unless (fboundp 'drgnx-hub-call-sync) (require 'drgnx-hub-client))
      (setq drgnx-replace--history
            (append (plist-get (drgnx-hub-call-sync "search/recent" (list :root drgnx-replace--root) 2) :recent) nil)
            drgnx-replace--history-here
            (let ((text (drgnx-replace--text 'find)))
              (drgnx-replace--spec text (and (eq (drgnx-replace--opt :scope) 'file) (drgnx-replace--origin-file))))))
    (let ((at (+ (or drgnx-replace--history-at -1) n)))
      (cond ((< at 0)
             (when drgnx-replace--history-at
               (setq drgnx-replace--history-at nil)
               (drgnx-replace--restore drgnx-replace--history-here)))
            ((>= at (length drgnx-replace--history)) (message "No older search"))
            (t (setq drgnx-replace--history-at at)
               (drgnx-replace--restore (nth at drgnx-replace--history)))))))

(defun drgnx-replace-search-history-prev ()
  "The project's search before this one (its recent searches, newest first), restored whole and run."
  (interactive)
  (drgnx-replace--history-step 1))

(defun drgnx-replace-search-history-next ()
  "The project's search after this one in the history walk; past the newest, the search the walk began from."
  (interactive)
  (drgnx-replace--history-step -1))

(defun drgnx-replace-search-save ()
  "Save the Search view's search under a name (the words by default): `search/saved/put', for this project."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (let ((text (drgnx-replace--text 'find)))
      (when (string-empty-p text) (user-error "Nothing to save: Find is empty"))
      (let ((name (string-trim (read-string (format-prompt "Save search as" text) nil nil text)))
            (file (and (eq (drgnx-replace--opt :scope) 'file) (drgnx-replace--origin-file))))
        (drgnx-replace--hub-ask "search/saved/put"
                                (list :root drgnx-replace--root :name (if (string-empty-p name) text name)
                                      :search (drgnx-replace--spec text file) :pinned :false)
                                (lambda (_) (setq drgnx-replace--saved-asked nil) (drgnx-replace--lists-update)))))))

(defun drgnx-replace-search-run-saved ()
  "Run one of the project's saved searches in the Search view, picked by name."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (unless (fboundp 'drgnx-hub-call-sync) (require 'drgnx-hub-client))
    (let* ((saved (append (plist-get (drgnx-hub-call-sync "search/saved/list" (list :root drgnx-replace--root) 2)
                                     :saved)
                          nil))
           (names (mapcar (lambda (s) (plist-get s :name)) saved)))
      (unless names (user-error "No saved search in this project: Save This Search first"))
      (let ((name (completing-read "Run saved search: " names nil t)))
        (drgnx-replace--restore (plist-get (seq-find (lambda (s) (equal (plist-get s :name) name)) saved) :search))))))

(defun drgnx-replace--lists-update ()
  "Ask the hub for the project's saved searches (once, and again with Find empty) and, with Find empty, its recent
ones; draw what the view has meanwhile."
  (when (and drgnx-replace--root (drgnx-replace--hub-ready-p))
    (let ((empty (string-empty-p (drgnx-replace--text 'find))))
      (when (or empty (not drgnx-replace--saved-asked))
        (setq drgnx-replace--saved-asked t)
        (drgnx-replace--hub-ask "search/saved/list" (list :root drgnx-replace--root)
                                (lambda (r) (setq drgnx-replace--saved (append (plist-get r :saved) nil))
                                  (drgnx-replace--lists-draw)
                                  (drgnx-replace--pins-later))))
      (if (not empty)
          (setq drgnx-replace--recent nil)
        (drgnx-replace--hub-ask "search/recent" (list :root drgnx-replace--root)
                                (lambda (r) (setq drgnx-replace--recent (append (plist-get r :recent) nil))
                                  (drgnx-replace--lists-draw))))))
  (drgnx-replace--lists-draw))

(defun drgnx-replace--saved-put (saved &rest changes)
  "Keep SAVED again with CHANGES (:pinned), then list the saved searches again."
  (drgnx-replace--hub-ask "search/saved/put"
                          (list :root drgnx-replace--root :name (plist-get saved :name) :search (plist-get saved :search)
                                :pinned (if (drgnx-replace--true (plist-get changes :pinned)) t :false))
                          (lambda (_) (setq drgnx-replace--saved-asked nil) (drgnx-replace--lists-update))))

(defun drgnx-replace--saved-do (method saved)
  "METHOD (`search/saved/delete' or `search/saved/share') on SAVED, then list the saved searches again."
  (drgnx-replace--hub-ask method (list :root drgnx-replace--root :name (plist-get saved :name))
                          (lambda (r) (setq drgnx-replace--saved-asked nil)
                            (when-let* ((path (plist-get r :path))) (message "Shared in %s" path))
                            (drgnx-replace--lists-update))))

(defun drgnx-replace--list-button (label help action)
  "A text button LABEL in the lists: ACTION (no argument) when pressed."
  (insert-text-button label 'follow-link t 'help-echo help 'action (lambda (_) (funcall action))))

(defun drgnx-replace--lists-draw ()
  "Draw the lists region: the pinned saved searches with their live counts, then, with Find empty, the saved searches
and the last recent ones (`drgnx-replace-recent-shown'), each a button that restores it."
  (when (markerp drgnx-replace--lists-beg)
    (drgnx-replace--drawing
     (delete-region drgnx-replace--lists-beg drgnx-replace--lists-end)
     (goto-char drgnx-replace--lists-beg)
     (let ((i 0) pins)
       (dolist (s drgnx-replace--saved)
         (when (drgnx-replace--true (plist-get s :pinned))
           (let ((s s) (n (alist-get i drgnx-replace--pin-counts)))
             (push (lambda ()
                     (drgnx-replace--list-button (format "%s · %s" (plist-get s :name) (if n n "…"))
                                                 "Run this pinned search" (lambda () (drgnx-replace--restore
                                                                                      (plist-get s :search))))
                     (insert " "))
                   pins)))
         (cl-incf i))
       (when pins (mapc #'funcall (nreverse pins)) (insert "\n")))
     (when (string-empty-p (drgnx-replace--text 'find))
       (when drgnx-replace--saved
         (insert (propertize "Saved\n" 'face 'drgnx-replace-dim))
         (dolist (s drgnx-replace--saved)
           (let ((s s) (pinned (drgnx-replace--true (plist-get s :pinned))))
             (insert "  ")
             (drgnx-replace--list-button (concat "☆ " (plist-get s :name)) (drgnx-replace--spec-label (plist-get s :search))
                                         (lambda () (drgnx-replace--restore (plist-get s :search))))
             (unless (drgnx-replace--true (plist-get s :project))
               (insert "  ")
               (drgnx-replace--list-button (if pinned "unpin" "pin") "Show its live count above the results"
                                           (lambda () (drgnx-replace--saved-put s :pinned (not pinned))))
               (insert " ")
               (drgnx-replace--list-button "share" "Share with the project (.drgnx/searches.eld)"
                                           (lambda () (drgnx-replace--saved-do "search/saved/share" s)))
               (insert " ")
               (drgnx-replace--list-button "×" "Delete this saved search"
                                           (lambda () (drgnx-replace--saved-do "search/saved/delete" s))))
             (insert "\n"))))
       (when drgnx-replace--recent
         (insert (propertize "Recent\n" 'face 'drgnx-replace-dim))
         (dolist (s (seq-take drgnx-replace--recent drgnx-replace-recent-shown))
           (let ((s s))
             (insert "  ")
             (drgnx-replace--list-button (drgnx-replace--spec-label s) "Run this search again"
                                         (lambda () (drgnx-replace--restore s)))
             (insert "\n"))))))))

(defun drgnx-replace--shown-p ()
  "Non-nil while the Search view shows in a window on a visible frame (its results view's `drgnx-view-shown-p': the
workbench state store's records)."
  (and drgnx-view (drgnx-view-shown-p drgnx-view)))

(defun drgnx-replace--pins-later ()
  "Count the pinned saved searches soon: at most once every 5 seconds."
  (drgnx-timer-soon (cons 'replace-pins (current-buffer)) 0.5 #'drgnx-replace--pins-run
                    :args (list (current-buffer)) :min-interval 5 :owner (current-buffer)))

(defun drgnx-replace--pins-run (buf)
  "Count each pinned saved search of BUF's view (a count-only `search/run' on a view of its own), only while the
view shows.  A timer: never signals."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (and drgnx-replace--root (drgnx-replace--shown-p))
        (let ((i 0))
          (dolist (s drgnx-replace--saved)
            (when (drgnx-replace--true (plist-get s :pinned))
              (drgnx-replace--hub-ask "search/run"
                                      (list :view (format "%s~pin%d" drgnx-replace-view i) :root drgnx-replace--root
                                            :search (plist-get s :search) :count t)
                                      #'ignore))
            (cl-incf i)))))))

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

(defun drgnx-replace--write-event (event data)
  "`drgnx-hub-event-functions': `search-apply' (a file of the view's write) and `search-change' (the write ended);
`search-handoff-state' is Ask an Agent's."
  (drgnx-search-handoff-event event data)
  (pcase event
    ("search-apply" (drgnx-replace--apply-later data))
    ("search-change"
     ;; an Edit Results save or its undo is that buffer's
     (when-let* (((not (drgnx-search-edit-change data)))
                 ((equal (plist-get data :view) drgnx-replace-view)) (buf (get-buffer drgnx-replace-buffer-name)))
       (with-current-buffer buf (drgnx-replace--change-done data))))))

(defun drgnx-replace--hub-event (event data)
  "`drgnx-hub-event-functions': `search-run-done' ends the Search view's search, counts what it found and unticks
the matches the user had unticked before it (`:off'); `search-apply' and `search-change' are the view's writes
\(`drgnx-replace--write-event')."
  (drgnx-replace--write-event event data)
  (when-let* (((equal event "search-run-done")) (view (plist-get data :view))
              ((string-prefix-p (concat drgnx-replace-view "~pin") view))
              (buf (get-buffer drgnx-replace-buffer-name)))
    ;; a pinned saved search's live count
    (with-current-buffer buf
      (setf (alist-get (string-to-number (substring view (+ (length drgnx-replace-view) 4))) drgnx-replace--pin-counts)
            (or (plist-get data :matches) 0))
      (drgnx-replace--lists-draw)))
  (when (and (equal event "search-run-done") (equal (plist-get data :view) drgnx-replace-view))
    (when-let* ((buf (get-buffer drgnx-replace-buffer-name)))
      (with-current-buffer buf
        (when drgnx-view-patch
          (drgnx-replace--rows-untick (plist-get data :off))
          (setq drgnx-replace--searching nil
                drgnx-replace--hub-counts (cons (or (plist-get data :files) 0) (or (plist-get data :matches) 0)))
          (when-let* ((err (plist-get data :error))) (setq drgnx-replace--status (format "%s" err)))
          (setq drgnx-replace--scope-done (plist-get data :scope))
          (drgnx-replace--apply-scope)
          (drgnx-replace--hub-listed)
          (drgnx-replace--watch)
          (drgnx-replace--update-status))))))

(defun drgnx-replace--hub-listed ()
  "The files the search listed (the `f:' nodes of the model, their `path', not only the rows sent), for the watches."
  (clrhash drgnx-replace--listed)
  (let ((h (drgnx-view-patch-handle drgnx-view-patch)))
    (mapc (lambda (id) (when (and (stringp id) (string-prefix-p "f:" id))
                         (puthash (nidhogg-view-get h 'field "path" id) t drgnx-replace--listed)))
          (nidhogg-view-get h 'list "order"))))

;; A modified buffer is not what the hub reads (the disk).  Before each search, and after a pause when a buffer is
;; edited, the view sends the hub every modified file buffer under the root it has not had as it is now
;; (`search/buffer'): the hub searches the buffer's text in place of the file (the search running, or done, takes it
;; at once), so its matches are rows, model nodes and tick boxes like any other.  A buffer too large to send (over
;; `drgnx-replace-refresh-max-bytes', or open as a large file) goes as `large': its file is searched on disk and its
;; header says so.  A buffer saved or killed since is forgotten: the hub reads its file again.

(defun drgnx-replace--dirty-buffers ()
  "The modified file buffers under the root, as (FILE . BUFFER)."
  (let ((root (file-name-as-directory (expand-file-name drgnx-replace--root))) out)
    (dolist (b (buffer-list))
      (when-let* ((f (buffer-file-name b)) ((buffer-modified-p b)) ((not (file-remote-p f))) ((string-prefix-p root f)))
        (push (cons f b) out)))
    out))

(defun drgnx-replace--send-buffers ()
  "Send the hub the modified buffers it has not had as they are now, and forget the ones saved or killed (see above)."
  (unless (or (drgnx-replace--opt :symbol) (not drgnx-view-patch))
    (unless drgnx-replace--sent (setq drgnx-replace--sent (make-hash-table :test #'equal)))
    (let ((dirty (drgnx-replace--dirty-buffers)) gone)
      (dolist (fb dirty)
        (let* ((b (cdr fb)) (tick (buffer-chars-modified-tick b))
               (large (or (drgnx-large-file-p b) (> (buffer-size b) drgnx-replace-refresh-max-bytes)))
               (now (if large 'large tick)))
          (unless (equal now (gethash (car fb) drgnx-replace--sent))
            (puthash (car fb) now drgnx-replace--sent)
            (drgnx-replace--hub-call
             "search/buffer"
             (append (list :view drgnx-replace-view :path (car fb) :tick tick)
                     (if large
                         (list :large t)
                       (list :text (with-current-buffer b
                                     (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max)))))))))))
      (maphash (lambda (f _) (unless (assoc f dirty) (push f gone))) drgnx-replace--sent)
      (dolist (f gone)
        (remhash f drgnx-replace--sent)
        (drgnx-replace--hub-call "search/buffer" (list :view drgnx-replace-view :path f))))))

(defun drgnx-replace--buffers-later ()
  "A buffer was edited: send the modified buffers after a pause."
  (drgnx-timer-debounce (cons 'replace-buffers (current-buffer)) drgnx-replace-refresh-delay
                        #'drgnx-replace--buffers-timer :args (list (current-buffer)) :owner (current-buffer)))

(defun drgnx-replace--buffers-timer (buf)
  "The pause after an edit is over in BUF's Search view.  A timer: never signals."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (condition-case e (drgnx-replace--send-buffers)
        (error (drgnx-replace--message "%s" (error-message-string e)))))))

(defun drgnx-replace--hub-resubscribe (_view)
  "The hub is up again (`drgnx-view-env-register'): search again, as the fields say; its searches and the buffers it
was sent were lost."
  (when-let* ((buf (get-buffer drgnx-replace-buffer-name)))
    (with-current-buffer buf
      (when drgnx-replace--sent (clrhash drgnx-replace--sent))
      (when (and drgnx-view-patch (not (string-empty-p (drgnx-replace--text 'find))))
        (drgnx-replace--search-now)))))

(defun drgnx-replace--rows-this (new)
  "Replace the match on the row at point (else the selected one) by NEW, ticked or not, then search again."
  (let ((id (or (get-text-property (point) 'drgnx-work-id) (drgnx-view-nav-selection))))
    (unless (and id (drgnx-replace--rows-kind-p id "match")) (user-error "No match on this row"))
    (drgnx-replace--write (list :ids (vector id) :replace new) 'this)))

(defun drgnx-replace-all (&optional now)
  "Replace every ticked match of the Search view (in the find bar: every match of its buffer).  The Replace All sheet
shows the changes first (`drgnx-search-preview-threshold'); NOW (\\[universal-argument]) writes them at once."
  (interactive "P")
  (if (drgnx-replace--bar-context-p)
      (with-current-buffer drgnx-replace-bar-buffer-name (drgnx-replace--bar-replace-all))
    (with-current-buffer (drgnx-replace--live-view)
      (drgnx-replace--check-writable)
      (if (drgnx-replace--rows-p)
          (drgnx-replace--rows-replace-all (drgnx-replace--new-name) (not now))
        (drgnx-replace--replace-all-symbol)))))

(defun drgnx-replace--replace-all-symbol ()
  "`drgnx-replace-all' in Symbol mode: the server's edits are the view's own rows, not the hub's."
  (let ((new (drgnx-replace--new-name))
        (ms (seq-remove (lambda (m) (gethash m drgnx-replace--off)) drgnx-replace--matches)))
    (unless ms (user-error "Nothing to replace: no match is ticked"))
    (drgnx-replace--write (list :root drgnx-replace--root :edits (drgnx-replace--given ms new)) 'symbol-all ms)))

(defun drgnx-replace-this ()
  "Replace the match on this row of the Search view, ticked or not."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (drgnx-replace--check-writable)
    (if (drgnx-replace--rows-p) (drgnx-replace--rows-this (drgnx-replace--new-name)) (drgnx-replace--this-symbol))))

(defun drgnx-replace--this-symbol ()
  "`drgnx-replace-this' in Symbol mode (the view's own rows)."
  (let ((m (or (get-text-property (point) 'drgnx-replace-match) (user-error "No match on this row")))
        (new (drgnx-replace--new-name)))
    (drgnx-replace--write (list :root drgnx-replace--root :edits (drgnx-replace--given (list m) new))
                          'symbol-this (list m new))))

(defun drgnx-replace--symbol-row-gone (m new)
  "Symbol mode's match M was replaced by NEW: its row goes; later matches on its line moved."
  (let ((delta (- (length (or (drgnx-replace-new-text m new) "")) (length (plist-get m :text))))
        (file (plist-get m :file)))
    (setq drgnx-replace--matches (delq m drgnx-replace--matches)
          drgnx-replace--tail (last drgnx-replace--matches))
    (dolist (o drgnx-replace--matches)
      (when (and (equal (plist-get o :file) file) (= (plist-get o :line) (plist-get m :line))
                 (>= (plist-get o :col) (plist-get m :end)))
        (plist-put o :col (+ (plist-get o :col) delta))
        (plist-put o :end (+ (plist-get o :end) delta))))
    (cl-decf (gethash file drgnx-replace--seen 0))
    (when (gethash m drgnx-replace--off)
      (remhash m drgnx-replace--off)
      (cl-decf (gethash file drgnx-replace--off-files 0)))
    ;; its row goes; its file's header shows the new count, or goes with its last row
    (drgnx-view-remove drgnx-view (list m))
    (if (zerop (gethash file drgnx-replace--seen 0))
        (progn (remhash file drgnx-replace--seen) (drgnx-replace--drop-header file))
      (drgnx-view-dirty drgnx-view (list (gethash file drgnx-replace--headers)))
      (when (eq m (gethash file drgnx-replace--last-row))
        (puthash file (car (last (seq-filter (lambda (o) (equal (plist-get o :file) file)) drgnx-replace--matches)))
                 drgnx-replace--last-row)))))

(defun drgnx-replace-view-undo ()
  "Undo the Search view's last replacement, in every file it wrote (the hub's `search/undo'); then search again.
A file edited since is left alone."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (let ((change (or (pop drgnx-replace--undo) (user-error "Nothing to undo"))))
      (drgnx-replace--hub-write "search/undo" (list :view drgnx-replace-view :change change
                                                    :open (drgnx-replace--open-paths))
                                #'ignore))))

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
            (drgnx-replace--show-match (drgnx-replace--rows-match id) nil))
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
        (drgnx-replace--insert-toggles t)
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
                   (replace-bar-close "Close Find Bar" drgnx-replace-bar-close "Close the find bar and its highlights")
                   (search-mode-next "Next Mode (Text → Symbol → Meaning)" drgnx-replace-search-mode-next
                                     "The Search view's next mode; it searches again")
                   (search-mode-text "Text Mode" drgnx-replace-search-mode-text
                                     "The Search view finds text (and replaces it)")
                   (search-mode-symbol "Symbol Mode" drgnx-replace-search-mode-symbol
                                       "The Search view finds a name's definitions, then its uses (read-only)")
                   (search-mode-meaning "Meaning Mode" drgnx-replace-search-mode-meaning
                                        "The Search view finds the code its words describe (read-only)")
                   (search-history-prev "Previous Search" drgnx-replace-search-history-prev
                                        "The project's search before this one, restored whole and run")
                   (search-history-next "Next Search" drgnx-replace-search-history-next
                                        "The next search of the history walk (past the newest, the one you had)")
                   (search-save "Save This Search" drgnx-replace-search-save
                                "Keep the Search view's search under a name, for this project")
                   (search-run-saved "Run Saved Search…" drgnx-replace-search-run-saved
                                     "Run one of the project's saved searches in the Search view")
                   (search-scope-next "Next Scope" drgnx-replace-search-scope-next
                                      "The Search view's next scope (Project → This file → Open → Changed → Staged → Branch)")
                   (search-scope-changed "In Changed Files" drgnx-replace-search-scope-changed
                                         "The Search view in the working tree's changed files, the word at point to find")
                   (search-scope-branch "In Files Changed on This Branch" drgnx-replace-search-scope-branch
                                        "The Search view in the files changed on this branch, the word at point to find")
                   (search-preview-file "Preview This File's Changes" drgnx-replace-preview-file
                                        "The changes of the file on this row of the Search view, as a read-only diff")
                   (search-preview-open "Open File" drgnx-replace-preview-open
                                        "In a preview: open its file in the editor")
                   (search-preview-replace-file "Replace in This File" drgnx-replace-preview-replace-file
                                                "In a preview: write its file's ticked matches")
                   (search-preview-keep "Keep This Hunk" drgnx-replace-preview-keep
                                        "In a preview: tick the matches of the hunk at point")
                   (search-preview-drop "Drop This Hunk" drgnx-replace-preview-drop
                                        "In a preview: untick the matches of the hunk at point")
                   (search-sheet-confirm "Replace" drgnx-replace-sheet-confirm
                                         "On the Replace All sheet: write the changes it shows")
                   (search-sheet-cancel "Cancel" drgnx-replace-sheet-cancel
                                        "On the Replace All sheet: close it, nothing written")
                   (search-sheet-next "Next File" drgnx-replace-sheet-next
                                      "On the Replace All sheet: the next file and its first hunk")
                   (search-sheet-previous "Previous File" drgnx-replace-sheet-previous
                                          "On the Replace All sheet: the previous file and its first hunk")
                   (search-edit-results "Edit Results" drgnx-search-edit-results
                                        "The Search view's results as an editable buffer; save writes your changes")
                   (search-edit-save "Save Edited Results" drgnx-search-edit-save
                                     "In Edit Results: write the changed lines to their files")
                   (search-edit-abort "Discard Edited Results" drgnx-search-edit-abort
                                      "In Edit Results: drop the unsaved edits and close it")
                   (search-edit-delete-line "Delete This Line (on save)" drgnx-search-edit-delete-line
                                            "In Edit Results: delete the line at point from its file when you save")
                   (search-edit-refresh-line "Take the File's Line" drgnx-search-edit-refresh-line
                                             "In Edit Results: show the file's current text for the line at point")
                   (search-edit-undo-saves "Undo All Saves of Edited Results" drgnx-search-edit-undo-saves
                                           "In Edit Results: put back every save of it, newest first")
                   (search-to-agent "Ask an Agent" drgnx-search-to-agent
                                    "Hand the Search view's ticked matches (or this row's) to an agent with what to do")
                   (search-handoff-send "Send to the Agent" drgnx-search-handoff-send
                                        "On the Ask an Agent card: send the brief to the agent")
                   (search-handoff-cancel "Cancel Asking an Agent" drgnx-search-handoff-cancel
                                          "On the Ask an Agent card: close it, nothing sent")
                   (search-handoff-next-who "Next Agent" drgnx-search-handoff-next-who
                                            "On the Ask an Agent card: who it goes to next (a new worker, a live session)")
                   (search-handoff-hidden "Hidden Files In or Out" drgnx-search-handoff-hidden
                                          "On the Ask an Agent card: put the matches in dot paths and secret-looking files in the brief, or not")
                   (search-handoff-rerun "Re-run in Worktree" drgnx-search-handoff-rerun
                                         "Run the search again in the worktree of the worker it was handed to: what is left")))
    (drgnx-command-define id :category "Search" :title title :command fn :doc doc :scope scope))
  (drgnx-command-define 'replace-this :category "Search" :title "Replace This Match" :command #'drgnx-replace-this
                        :doc "Replace the match on this row of the Search view"
                        :when (lambda () (derived-mode-p 'drgnx-replace-mode))))

;;;; Preview and the Replace All sheet
;; A file's changes before they are written (docs/guide/replace.md, "Preview"): the hub's diff of the file after its
;; ticked edits (`search/preview', the same edit set Replace All writes) in a read-only tile in the editor area, each
;; hunk with its tick (`a' keep, `D' drop: the hunk's matches ticked or unticked in the view, both ways) and, for a
;; regexp search, its groups line.  Replace All first shows the sheet (`drgnx-search-preview-threshold'): every file
;; with its lines added and removed, the selected file's first hunk, what is skipped and why, and Replace / Cancel;
;; Replace writes the edit set the sheet shows (`search/apply').

(defface drgnx-replace-preview-head '((t :inherit (drgnx-ui-text drgnx-selected-quiet) :extend t))
  "A preview tile's hunk band: its tick box, `hunk N', its definition and its keys." :group 'drgnx)

(defface drgnx-replace-preview-def '((t :inherit drgnx-accent))
  "The definition a preview hunk is in (`ƒ drgnx-gateway--queue')." :group 'drgnx)

(defface drgnx-replace-preview-number '((t :inherit line-number))
  "A preview's line numbers." :group 'drgnx)

(defface drgnx-replace-preview-del '((t :inherit diff-removed :extend nil :box (:line-width (-1 . -1) :style flat-button)))
  "A removed line of a preview or the sheet: its tint, a box in its own colour inside the glyphs (rounded under
Glitnir by the theme, the mockup's `.dl'), so the text never moves." :group 'drgnx)

(defface drgnx-replace-preview-add '((t :inherit diff-added :extend nil :box (:line-width (-1 . -1) :style flat-button)))
  "An added line of a preview or the sheet: its tint, as `drgnx-replace-preview-del'." :group 'drgnx)

;; the word tints keep a box like the line's: a run with no box would end the line's rounded run in its middle
(defface drgnx-replace-preview-word-old '((t :inherit diff-refine-removed :box (:line-width (-1 . -1) :style flat-button)))
  "The part of a removed line that its replacement changes: a filled tint, no outline (the mockup's `.w-del')."
  :group 'drgnx)

(defface drgnx-replace-preview-word-new '((t :inherit diff-refine-added :box (:line-width (-1 . -1) :style flat-button)))
  "The part of an added line that is new: a filled tint, no outline (the mockup's `.w-add')." :group 'drgnx)

(defface drgnx-replace-preview-kept '((t :inherit (drgnx-ui-caption drgnx-text-subtle)))
  "`← unticked, kept' after a line whose match stays." :group 'drgnx)

(defface drgnx-replace-preview-group '((t :inherit drgnx-chip))
  "What a group took, on a groups line (`\\1 = gateway')." :group 'drgnx)

(defface drgnx-replace-tick-on '((t :inherit drgnx-control-primary :box nil))
  "A ticked box (every match of the hunk or file written): filled with the accent." :group 'drgnx)

(defface drgnx-replace-tick-mark '((t :inherit drgnx-replace-tick-on))
  "The run of a ticked box drawn as an image: the mark's colour only (the theme leaves the background out), so the
row's own background fills the line around the image, which carries the fill itself." :group 'drgnx)

(defface drgnx-replace-tick-off '((t :inherit drgnx-text-subtle))
  "An unticked box." :group 'drgnx)

(defface drgnx-replace-sheet-key '((t :inherit drgnx-keycap))
  "The key chip on the sheet's Replace button (`Ctrl ↵'): ringed in the button's text colour." :group 'drgnx)

(defface drgnx-replace-sheet-code '((t :inherit drgnx-code-small))
  "The code lines of the Replace All sheet (the lane's text is the UI font)." :group 'drgnx)

(defface drgnx-replace-plus '((t :inherit success))
  "Lines added, a count (`+4'): coloured text, no tint (the mockup's `.pl')." :group 'drgnx)

(defface drgnx-replace-minus '((t :inherit error))
  "Lines removed, a count (`−4'): coloured text, no tint (the mockup's `.mi')." :group 'drgnx)

(defface drgnx-replace-sheet-rule '((t :inherit shadow :overline t))
  "The hairline above the Replace All sheet's foot: an overline in the border's colour." :group 'drgnx)

(defface drgnx-replace-sheet-selected '((t :inherit (drgnx-selected-quiet drgnx-focus)))
  "The Replace All sheet's selected file: the selection in the focus ring, rounded where the theme rounds it."
  :group 'drgnx)

(defface drgnx-replace-preview-empty '((t :inherit warning))
  "A group that matched nothing (`\\2 = ∅') on a preview's groups line." :group 'drgnx)

(defun drgnx-replace--hunks-of (diff)
  "The hunks of the unified DIFF: plists (:header \"@@ -1,2 +1,2 @@\" :lines (\" a\" \"-b\" \"+c\"))."
  (let (hunks)
    (dolist (line (split-string diff "\n"))
      (cond ((string-prefix-p "@@" line) (push (list :header line :lines nil) hunks))
            ((and hunks (not (string-empty-p line)))
             (setcar hunks (plist-put (car hunks) :lines (cons line (plist-get (car hunks) :lines)))))))
    (mapcar (lambda (h) (plist-put h :lines (nreverse (plist-get h :lines)))) (nreverse hunks))))

(defun drgnx-replace--diff-line (indent line &optional number face note stop)
  "LINE of a diff (its first character `+', `-' or a space) after INDENT and its line NUMBER, in its face (and FACE
under it: the sheet's code font), with its newline: `208 - text'.  NOTE goes after the text.  STOP: where the line's
tint ends, a `:align-to' position (the card's inset edge); without it the tint runs to the window's edge."
  (let* ((mark (aref line 0))
         (text (concat (if (memq mark '(?+ ?-)) (string mark) " ") " " (substring line 1) (or note "")
                       (if stop (propertize " " 'display `(space :align-to ,stop)) "\n")))
         (nl (if stop (propertize "\n" 'face face) ""))
         ;; the number is inside the line's tint (the mockup's `.dl .n'), in its own colour
         (text (concat (propertize (if number (format "%4d " number) "") 'face 'drgnx-replace-preview-number) text)))
    (when face (add-face-text-property 0 (length text) face t text))
    (add-face-text-property 0 (length text) (pcase mark (?+ 'drgnx-replace-preview-add) (?- 'drgnx-replace-preview-del) (_ 'default)) t text)
    (concat indent text nl)))

(defun drgnx-replace--refine (old new)
  "OLD and NEW (a removed line and the line that replaced it, their marks first) with the part that differs in the
word faces: what is between their common start and common end."
  (let* ((n (min (length old) (length new)))
         (pre (let ((i 1)) (while (and (< i n) (eq (aref old i) (aref new i))) (cl-incf i)) i))
         (suf (let ((i 0)) (while (and (< i (- n pre)) (eq (aref old (- (length old) i 1)) (aref new (- (length new) i 1))))
                             (cl-incf i))
                   i))
         (old (copy-sequence old)) (new (copy-sequence new)))
    (when (< pre (- (length old) suf))
      (add-face-text-property pre (- (length old) suf) 'drgnx-replace-preview-word-old nil old))
    (when (< pre (- (length new) suf))
      (add-face-text-property pre (- (length new) suf) 'drgnx-replace-preview-word-new nil new))
    (cons old new)))

(defun drgnx-replace--refined (lines)
  "LINES of a hunk with each run of removed lines and the added lines after it refined pairwise
\(`drgnx-replace--refine')."
  (let ((v (vconcat lines)) (i 0))
    (while (< i (length v))
      (if (not (eq (aref (aref v i) 0) ?-))
          (cl-incf i)
        (let* ((j i) k)
          (while (and (< j (length v)) (eq (aref (aref v j) 0) ?-)) (cl-incf j))
          (setq k j)
          (while (and (< k (length v)) (eq (aref (aref v k) 0) ?+) (< (- k j) (- j i)))
            (let ((r (drgnx-replace--refine (aref v (+ i (- k j))) (aref v k))))
              (aset v (+ i (- k j)) (car r))
              (aset v k (cdr r)))
            (cl-incf k))
          (setq i (max k j)))))
    (append v nil)))

(defun drgnx-replace--hunk-lines (indent hunk &optional face kept changed stop)
  "HUNK's lines (`drgnx-replace--hunks-of') after INDENT, each with its number: the old file's for a removed line,
the new file's for the others; changed words marked; FACE under each line (the sheet's code font).  KEPT: the old
file's lines of unticked matches, noted `← unticked, kept'.  CHANGED: the removed and added lines only (the sheet's).
STOP: where each line's tint ends (`drgnx-replace--diff-line')."
  (let* ((head (plist-get hunk :header))
         (old (if (string-match "-\\([0-9]+\\)" head) (string-to-number (match-string 1 head)) 1))
         (new (if (string-match "\\+\\([0-9]+\\)" head) (string-to-number (match-string 1 head)) 1))
         (note (propertize "   ← unticked, kept" 'face 'drgnx-replace-preview-kept))
         (lines (plist-get hunk :lines)) (blank (lambda (l) (string-blank-p (substring l 1)))))
    ;; no empty context at the hunk's ends (the mockup's hunks start and end on text)
    (while (and lines (eq (aref (car lines) 0) ?\s) (funcall blank (car lines)))
      (setq lines (cdr lines) old (1+ old) new (1+ new)))
    (setq lines (reverse lines))
    (while (and lines (eq (aref (car lines) 0) ?\s) (funcall blank (car lines)))
      (setq lines (cdr lines)))
    (setq lines (nreverse lines))
    (mapconcat (lambda (l)
                 (pcase (aref l 0)
                   (?- (prog1 (drgnx-replace--diff-line indent l old face nil stop) (cl-incf old)))
                   (?+ (prog1 (drgnx-replace--diff-line indent l new face nil stop) (cl-incf new)))
                   (_ (prog1 (if changed ""
                               (drgnx-replace--diff-line indent l new face (and (memql old kept) note) stop))
                        (cl-incf old) (cl-incf new)))))
               (drgnx-replace--refined lines) "")))

(defun drgnx-replace--key-hint (id label)
  "Registry command ID's key as keycaps, then LABEL dim: `[a] keep'; LABEL alone when ID has no key."
  (let ((key (and (fboundp 'drgnx-surfaces-key-label) (drgnx-surfaces-key-label id :short t))))
    (concat (if (and key (fboundp 'drgnx-palette-keycaps)) (concat (drgnx-palette-keycaps key) " ") "")
            (propertize label 'face 'shadow))))

(defun drgnx-replace--right (text &optional margin)
  "TEXT at the right edge of the window, MARGIN pixels (a character's width by default) after it: a stretch space
before it, its width measured in pixels (buttons and keycaps are wider than their characters)."
  (concat (propertize " " 'display `(space :align-to (- right (,(+ (string-pixel-width text (current-buffer))
                                                                   (or margin (frame-char-width)))))))
          text))

(defvar-local drgnx-replace--preview nil "This preview tile's file and its last answer: (PATH . ANSWER).")

(defvar-local drgnx-replace--preview-root nil "The Search view's folder: the tile's file name is relative to it.")

(defvar drgnx-replace-preview-keys-map (make-sparse-keymap)
  "A preview tile's keys (Keep and Drop This Hunk), from the key profiles.")

(defvar drgnx-replace-preview-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m (make-composed-keymap drgnx-replace-preview-keys-map special-mode-map)) m)
  "A preview tile's keymap: the profiles' keys over `special-mode-map'.")

(define-derived-mode drgnx-replace-preview-mode special-mode "Preview"
  "One file's changes of the Search view's search, read-only: `a' keeps a hunk's matches, `D' drops them."
  ;; its own header line from the start: the editor's chrome shows it only when the buffer has one as it shows
  (setq-local truncate-lines t header-line-format (list " " (propertize "Preview" 'face 'drgnx-ui-heading)))
  ;; the hunk band's tick shows where you are: no hollow cursor box on it when another window is selected
  (setq-local cursor-in-non-selected-windows nil)
  (buffer-disable-undo))

(defun drgnx-replace--preview-buffer (path)
  "The preview tile of PATH (made when there is none)."
  (let ((buf (get-buffer-create (format "%s · preview" (file-name-nondirectory path)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'drgnx-replace-preview-mode)
        (drgnx-replace-preview-mode)
        (drgnx-view-attach 'replace-preview))
      (setq drgnx-replace--preview (cons path (cdr drgnx-replace--preview))))
    (let ((root (and (boundp 'drgnx-replace--root) drgnx-replace--root)))
      (when-let* ((view (get-buffer drgnx-replace-buffer-name)))
        (setq root (or (buffer-local-value 'drgnx-replace--root view) root)))
      (with-current-buffer buf (setq drgnx-replace--preview-root root)))
    buf))

(defun drgnx-replace--preview-params (path)
  "`search/preview' params of PATH: the view's unticked matches and its replacement (from the Search view)."
  (list :view drgnx-replace-view :path path
        :off (vconcat (and drgnx-view-patch (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked)))
        :replace (drgnx-replace--text 'replace)))

(defun drgnx-replace--preview-ask (path buf)
  "Ask the hub for PATH's preview (from the Search view), drawn in BUF when it comes."
  (drgnx-replace--hub-write "search/preview" (drgnx-replace--preview-params path)
                            (lambda (r) (when (buffer-live-p buf)
                                          (with-current-buffer buf (drgnx-replace--preview-draw r))))))

(defun drgnx-replace--groups-line (indent captures)
  "The groups line of CAPTURES (the hub's, :id :groups) after INDENT: `groups  \\1 = pending · \\2 = ∅' (∅ in the
warning colour: a group that matched nothing), one line per distinct capture, \"\" without groups."
  (mapconcat (lambda (line) (concat indent (propertize "groups  " 'face 'drgnx-replace-preview-kept) line "\n"))
             (delete-dups
              (mapcar (lambda (c)
                        (mapconcat #'identity
                                   (cl-loop for g in (append (plist-get c :groups) nil) for n from 1
                                            collect (let ((chip (if (stringp g) (format " \\%d = %s " n g)
                                                                  (concat (format " \\%d = " n)
                                                                          (propertize "∅" 'face 'drgnx-replace-preview-empty)
                                                                          " "))))
                                                      ;; under the ∅'s warning colour, not over it
                                                      (add-face-text-property 0 (length chip) 'drgnx-replace-preview-group
                                                                              t chip)
                                                      chip))
                                   " "))
                      (append captures nil)))
             ""))

(defun drgnx-replace--tick (state)
  "A tick box in STATE (`on', `mix' or `off'): Lucide's check, minus or square on a graphical frame, else its text."
  (if (eq state 'off)
      (drgnx-look-icon 'square 'drgnx-replace-tick-off 14)
    (let* ((s (drgnx-look-icon (if (eq state 'on) 'check 'minus) 'drgnx-replace-tick-on 14))
           (img (get-text-property 0 'display s)))
      ;; the image fills itself: the face's background on a taller row (a hunk band's box) would fill all of it
      (when (eq (car-safe img) 'image)
        (setq s (propertize s 'face 'drgnx-replace-tick-mark
                            'display (append img (list :background (face-background 'drgnx-replace-tick-on nil t))))))
      s)))

(defun drgnx-replace--hunk-box (ids off &optional kept)
  "The tick box of a hunk with match IDS, OFF the unticked, KEPT its unticked matches the hub left out of IDS: ticked
when all are, empty when none, a minus for some."
  (let* ((n (+ (cl-count-if (lambda (id) (member id off)) ids) kept)) (all (+ (length ids) kept))
         (state (cond ((zerop n) 'on) ((= n all) 'off) (t 'mix))))
    (propertize (drgnx-replace--tick state)
                'drgnx-replace-tick (pcase state ('on "[x]") ('off "[ ]") (_ "[-]")))))

(defun drgnx-replace--preview-render (key)
  "The preview tile's row KEY: the head, a skipped match, the empty note or a hunk (its tick box, header, lines and
groups line; the hunk's match ids on the whole row)."
  (let* ((answer (cdr drgnx-replace--preview)) (off (drgnx-replace--preview-off)))
    (pcase key
      (`(:skip ,i)
       (propertize (format "  skipped: %s\n" (plist-get (seq-elt (plist-get answer :skipped) i) :why)) 'face 'warning))
      (`(:empty) "\n  Nothing to replace in this file.\n")
      (`(:hunk ,i)
       (let* ((h (seq-elt (plist-get answer :hunks) i))
              (p (nth i (drgnx-replace--hunks-of (or (plist-get answer :diff) ""))))
              (ids (append (plist-get h :ids) nil)))
         (propertize
          (concat (if (> i 0) "\n" "")
                  ;; a card: inset 8 px at either side, the band's face to its right end (no `:extend': a box)
                  (let* ((inset (drgnx-px 8))
                         (band (concat " " (drgnx-replace--hunk-box ids off (length (plist-get h :kept)))
                                       " " (format "hunk %d" (1+ i))
                                       (if-let* ((label (plist-get h :label)))
                                           (concat (propertize " · " 'face 'drgnx-text-subtle)
                                                   (propertize label 'face 'drgnx-replace-preview-def))
                                         "")
                                       (drgnx-replace--right
                                        (concat (drgnx-replace--key-hint 'search-preview-keep "keep") "  "
                                                (drgnx-replace--key-hint 'search-preview-drop "drop"))
                                        (+ inset (drgnx-px 12)))
                                       (propertize " " 'display `(space :align-to (- right (,inset)))))))
                    (add-face-text-property 0 (length band) 'drgnx-replace-preview-head t band)
                    (concat (propertize " " 'display `(space :width (,inset))) band "\n"))
                  ;; the lines' tints start and stop at the card's inset, as the band (the mockup's `.dl' margin)
                  (drgnx-replace--hunk-lines (propertize " " 'display `(space :width (,(drgnx-px 8)))) p nil (append (plist-get h :kept) nil) nil
                                             `(- right (,(drgnx-px 8))))
                  (drgnx-replace--groups-line "       " (plist-get h :captures)))
          'drgnx-replace-hunk ids)))
      (_ "\n"))))

(drgnx-view-define 'replace-preview :render #'drgnx-replace--preview-render :slice drgnx-view-slice :delay 0)

(defun drgnx-replace--preview-head (path answer off)
  "The tile's header line: `Preview', PATH (relative to the search's folder), the ticked count and +/− of ANSWER
\(OFF the unticked), then Open File and Replace in This File at the right."
  (let ((all (apply #'append (mapcar (lambda (h) (append (plist-get h :ids) nil)) (plist-get answer :hunks))))
        (kept (apply #'+ (mapcar (lambda (h) (length (plist-get h :kept))) (plist-get answer :hunks)))))
    (list " " (propertize "Preview" 'face 'drgnx-ui-heading) " "
          (if drgnx-replace--preview-root (file-relative-name path drgnx-replace--preview-root)
            (abbreviate-file-name path))
          (propertize (format " · %d of %d matches ticked · " (cl-count-if-not (lambda (id) (member id off)) all)
                              (+ (length all) kept))
                      'face 'drgnx-text-subtle)
          (propertize (format "+%d" (or (plist-get answer :plus) 0)) 'face 'drgnx-replace-plus) " "
          (propertize (format "−%d" (or (plist-get answer :minus) 0)) 'face 'drgnx-replace-minus)
          (drgnx-replace--right
           (concat (drgnx-replace--header-button "Open File" 'search-preview-open 'drgnx-ui-button) " "
                   (drgnx-replace--header-button "Replace in This File" 'search-preview-replace-file
                                                 'drgnx-ui-button-primary))))))

(defun drgnx-replace--header-button (label id face)
  "LABEL as a button in FACE on the header line running registry command ID, with a button's room at either end (a
line's buttons have none of their own)."
  (let ((pad (propertize " " 'display (drgnx-ui-button-pad face))))
    (drgnx-ui-button (concat pad label pad) id :where 'header-line :face face)))

(defun drgnx-replace--preview-draw (answer)
  "Draw ANSWER (`search/preview') in this tile, point kept on its line; the head goes to the header line."
  (setcdr drgnx-replace--preview answer)
  (setq-local header-line-format
              (drgnx-replace--preview-head (car drgnx-replace--preview) answer (drgnx-replace--preview-off)))
  (force-mode-line-update)
  (let ((line (line-number-at-pos)) (hunks (length (plist-get answer :hunks))))
    (drgnx-view-reset drgnx-view
                      (append nil
                              (cl-loop for i below (length (plist-get answer :skipped)) collect (list :skip i))
                              (if (zerop hunks) '((:empty)) (cl-loop for i below hunks collect (list :hunk i)))))
    (drgnx-view-draw-now drgnx-view)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun drgnx-replace--preview-off ()
  "The Search view's unticked matches (Sjá's ticked set)."
  (when-let* ((view (get-buffer drgnx-replace-buffer-name)))
    (with-current-buffer view
      (and drgnx-view-patch (append (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked) nil)))))

(defun drgnx-replace-preview-file ()
  "Show the changes of the file on this row of the Search view (a match's file) in a preview tile, read-only."
  (interactive)
  (with-current-buffer (drgnx-replace--live-view)
    (unless (drgnx-replace--rows-p) (user-error "Preview needs a text search"))
    (let* ((h (drgnx-view-patch-handle drgnx-view-patch))
           (id (or (get-text-property (point) 'drgnx-work-id) (drgnx-view-nav-selection)
                   (user-error "No file on this row")))
           (file (if (drgnx-replace--rows-kind-p id "file") id (nidhogg-view-get h 'parent id)))
           (path (or (and file (nidhogg-view-get h 'field "path" file)) (user-error "No file on this row")))
           (path (expand-file-name path drgnx-replace--root))
           (buf (drgnx-replace--preview-buffer path)))
      (drgnx-replace--preview-ask path buf)
      (drgnx-wb-show-in-editor buf t))))

(defun drgnx-replace--preview-set (keep)
  "Tick (KEEP) or untick the matches of the hunk at point, in the Search view; the tile is drawn again."
  (let ((ids (or (get-text-property (point) 'drgnx-replace-hunk) (user-error "No hunk here")))
        (off (drgnx-replace--preview-off)))
    (with-current-buffer (drgnx-replace--live-view)
      (dolist (id ids)
        ;; Sjá's ticked set holds the unticked: a tick toggles
        (when (eq keep (and (member id off) t)) (drgnx-replace--rows-tick id))))))

(defun drgnx-replace-preview-open ()
  "Open the file of this preview tile in the editor."
  (interactive)
  (find-file (or (car drgnx-replace--preview) (user-error "Not a preview"))))

(defun drgnx-replace-preview-replace-file ()
  "Replace in This File: write this tile's ticked matches (its file only) through the hub."
  (interactive)
  (let* ((off (drgnx-replace--preview-off))
         (ids (cl-loop for h in (append (plist-get (cdr drgnx-replace--preview) :hunks) nil)
                       append (cl-remove-if (lambda (id) (member id off)) (append (plist-get h :ids) nil)))))
    (unless ids (user-error "Nothing ticked in this file"))
    (with-current-buffer (drgnx-replace--live-view)
      (drgnx-replace--write (list :ids (vconcat ids) :replace (drgnx-replace--text 'replace)) 'this))))

(defun drgnx-replace-preview-keep ()
  "Keep the hunk at point: its matches are ticked in the Search view."
  (interactive)
  (drgnx-replace--preview-set t))

(defun drgnx-replace-preview-drop ()
  "Drop the hunk at point: its matches are unticked in the Search view."
  (interactive)
  (drgnx-replace--preview-set nil))

(defun drgnx-replace--previews-later ()
  "The open preview tiles are asked for again once the current command's ticks are done."
  (when (cl-some (lambda (b) (eq (buffer-local-value 'major-mode b) 'drgnx-replace-preview-mode)) (buffer-list))
    (drgnx-timer-soon 'replace-previews 0 #'drgnx-replace--previews-refresh :owner 'tools/replace)))

(defun drgnx-replace--previews-refresh ()
  "Ask again for every open preview tile (the ticks or the replacement changed)."
  (dolist (b (buffer-list))
    (when (eq (buffer-local-value 'major-mode b) 'drgnx-replace-preview-mode)
      (when-let* ((path (car (buffer-local-value 'drgnx-replace--preview b)))
                  (view (get-buffer drgnx-replace-buffer-name)))
        (with-current-buffer view (drgnx-replace--preview-ask path b))))))

;;;;; The Replace All sheet

(defvar-local drgnx-replace--sheet nil
  "The sheet's edit set: plist :change :files :skipped (the hub's `search/edits' answer), :sel the selected file's
index, :hunk its first hunk's diff text when it came, :captures that hunk's groups.")

(defvar drgnx-replace-sheet-keys-map (make-sparse-keymap)
  "The Replace All sheet's keys (Replace, Cancel, next and previous file), from the key profiles.")

(defvar drgnx-replace-sheet-mode-map
  (let ((m (make-sparse-keymap))) (set-keymap-parent m (make-composed-keymap drgnx-replace-sheet-keys-map special-mode-map)) m)
  "The Replace All sheet's keymap: the profiles' keys over `special-mode-map'.")

(define-derived-mode drgnx-replace-sheet-mode special-mode "Replace All"
  "The Replace All sheet: every file's changes; Replace writes them, Cancel leaves everything as it is."
  ;; its foot says what it is and what ends it; the selected file's ring shows where you are (no cursor)
  (setq-local truncate-lines t mode-line-format nil cursor-type nil)
  (face-remap-add-relative 'default 'drgnx-surface-overlay)   ; a popup's surface, as the palette's
  (buffer-disable-undo))

(defconst drgnx-replace-sheet-buffer-name "*drgnx replace all*")

(defvar-local drgnx-replace--sheet-root nil "The Search view's folder: the sheet's file names are relative to it.")

(defun drgnx-replace--lines-changed (edits)
  "How many lines EDITS (one file's) change: the distinct lines they start on."
  (length (delete-dups (mapcar (lambda (e) (plist-get e :line)) (append edits nil)))))

(defun drgnx-replace--sheet-show (answer)
  "Show the Replace All sheet of ANSWER (`search/edits'), the Search view's edit set (from the Search view)."
  (let ((buf (get-buffer-create drgnx-replace-sheet-buffer-name)) (root drgnx-replace--root))
    (with-current-buffer buf
      (drgnx-replace-sheet-mode)
      (drgnx-view-attach 'replace-sheet)
      (setq drgnx-replace--sheet-root root)
      (setq drgnx-replace--sheet (list :change (plist-get answer :change) :files (append (plist-get answer :files) nil)
                                       :skipped (append (plist-get answer :skipped) nil) :sel 0))
      (drgnx-replace--sheet-draw)
      (drgnx-replace--sheet-hunk))
    (pop-to-buffer buf)))

(defun drgnx-replace--sheet-name (f)
  "The sheet's name of file F: relative to the Search view's folder."
  (file-relative-name (plist-get f :path) drgnx-replace--sheet-root))

(defun drgnx-replace--sheet-tail (f skipped)
  "File F's tail on the sheet: its +/−, how many of its matches SKIPPED holds, and a note when it is open unsaved."
  (let ((k (drgnx-replace--lines-changed (plist-get f :edits)))
        (skips (cl-count-if (lambda (x) (equal (plist-get x :path) (plist-get f :path))) skipped))
        (b (find-buffer-visiting (plist-get f :path))))
    (concat (propertize (format "+%d" k) 'face '(drgnx-replace-plus drgnx-replace-sheet-code)) " "
            (propertize (format "−%d" k) 'face '(drgnx-replace-minus drgnx-replace-sheet-code))
            (if (> skips 0) (propertize (format "  %d skipped" skips) 'face 'warning) "")
            (if (and b (buffer-modified-p b)) (propertize "  open, unsaved: stays unsaved" 'face 'warning) ""))))

(defun drgnx-replace--gap (px)
  "A stretch PX logical pixels wide."
  (propertize " " 'display `(space :width (,(drgnx-px px)))))

(defun drgnx-replace--sheet-head (f open)
  "File F's head on the sheet, from inside its row's ring: 8 px, its chevron (OPEN: down), its icon and its name, 8 px
between each (the mockup's `.fl')."
  (concat (drgnx-replace--gap 8) (drgnx-look-icon (if open 'chevron-down 'chevron-right) 'drgnx-text-subtle 14)
          (drgnx-replace--gap 8) (drgnx-look-file-icon (plist-get f :path) 'drgnx-text-muted)
          (drgnx-replace--gap 8) (drgnx-replace--sheet-name f)))

(defun drgnx-replace--sheet-edge (files skipped)
  "The sheet's right edge in pixels, in this buffer: the widest head, a gap, the widest tail; the tails end there.
Further when the selected file's hunk (shown under it) has a wider line: the code stays inside the rows' ring."
  (let ((px (lambda (str) (string-pixel-width str (current-buffer))))
        (h (plist-get drgnx-replace--sheet :hunk)))
    (max (+ (drgnx-px 6)                                     ; the row's inset (outside its ring)
            (apply #'max 0 (mapcar (lambda (f) (funcall px (drgnx-replace--sheet-head f t))) files))
            (drgnx-px 32)
            (apply #'max (funcall px (drgnx-replace--sheet-buttons))
                   (mapcar (lambda (f) (funcall px (drgnx-replace--sheet-tail f skipped))) files)))
         (if h (funcall px (drgnx-replace--hunk-lines (drgnx-replace--gap 40) h 'drgnx-replace-sheet-code nil t)) 0))))

(defun drgnx-replace--sheet-at-edge (edge text)
  "TEXT ending at EDGE pixels (`drgnx-replace--sheet-edge'): a stretch space before it."
  (concat (propertize " " 'display `(space :align-to (,(- edge (string-pixel-width text (current-buffer))))))
          text))

(defun drgnx-replace--sheet-buttons ()
  "The sheet's Cancel and Replace: Cancel plain (Esc is every popup's), Replace with its key as one chip."
  (concat (drgnx-ui-button "Cancel" 'search-sheet-cancel :face 'drgnx-ui-button) (drgnx-replace--gap 8)
          (drgnx-replace--sheet-button "Replace" 'search-sheet-confirm 'drgnx-ui-button-primary)))

(defun drgnx-replace--sheet-render (key)
  "The sheet's row KEY: its title, a file (chevron, icon, name; its +/−, skipped and unsaved notes at the right edge;
when selected, in the selection's ring with its first hunk's changed lines under it), its foot (what is skipped and
why, what Undo does, Cancel and Replace)."
  (let* ((s drgnx-replace--sheet) (files (plist-get s :files)) (skipped (plist-get s :skipped)))
    (pcase key
      (`(:title)
       (let ((n (apply #'+ (mapcar (lambda (f) (length (plist-get f :edits))) files))))
         ;; the title row is 44 px high (`line-height' on its newline: the mockup's `.sheet .t')
         (concat (drgnx-replace--gap 14) (drgnx-look-icon 'replace-all 'drgnx-text-muted) (drgnx-replace--gap 8)
                 (propertize (format "Replace %d match%s in %d file%s" n (if (= n 1) "" "es") (length files)
                                     (if (= (length files) 1) "" "s"))
                             'face 'drgnx-ui-heading)
                 (if skipped (propertize (format " · %d skipped" (length skipped)) 'face 'drgnx-text-subtle) "")
                 (propertize "\n" 'line-height 2.4)
                 ;; its rule (the mockup's `.sheet .t' bottom line): an overline on a 6 px row (the room above the
                 ;; files), as wide as the foot's
                 (propertize " " 'display `(space :align-to (,(+ (drgnx-replace--sheet-edge files skipped) (drgnx-px 14))))
                             'face 'drgnx-replace-sheet-rule)
                 (propertize " " 'display `(space :width (0) :height (,(drgnx-px 6)))) "\n")))
      (`(:file ,i)
       (let* ((f (nth i files)) (sel (= i (plist-get s :sel))) (h (and sel (plist-get s :hunk)))
              (edge (drgnx-replace--sheet-edge files skipped))
              ;; the row's ring: from its 6 px inset to 8 px past the tails' edge
              (row (concat (drgnx-replace--sheet-head f sel)
                           (drgnx-replace--sheet-at-edge edge (drgnx-replace--sheet-tail f skipped))
                           (propertize " " 'display `(space :align-to (,(+ edge (drgnx-px 8))))))))
         (when sel (add-face-text-property 0 (length row) 'drgnx-replace-sheet-selected t row))
         (propertize
          ;; 30 px rows, the text in their middle: a strut 30 px high, 63 % above the baseline (a `line-height' puts
          ;; all its room above the text)
          (concat (drgnx-replace--gap 6)
                  (propertize " " 'display `(space :width (0) :height (,(drgnx-px 30)) :ascent 63))
                  row "\n"
                  ;; the hunk under the file's name (the mockup's `.sheet .hunk', 40 px in)
                  (if h (concat (drgnx-replace--hunk-lines (drgnx-replace--gap 40) h 'drgnx-replace-sheet-code nil t
                                                           ;; the tints end with the rows' ring
                                                           (list (+ edge (drgnx-px 8))))
                                (drgnx-replace--groups-line (concat (drgnx-replace--gap 40) "      ")
                                                            (plist-get s :captures)))
                    ""))
          'drgnx-replace-sheet-file i)))
      (`(:foot)
       (concat "\n"
               (if skipped
                   (propertize (format " %d skipped: %s\n" (length skipped)
                                       (mapconcat #'identity
                                                  (delete-dups (mapcar (lambda (x) (plist-get x :why)) skipped))
                                                  "; "))
                               'face 'warning)
                 "")
               ;; the foot's rule (the mockup's `.sheet .ft' top line): an overline over a line of room, to the rows'
               ;; ring and its inset (not `right': the popup fits its widest line)
               (propertize " " 'display `(space :align-to (,(+ (drgnx-replace--sheet-edge files skipped) (drgnx-px 14))))
                           'face 'drgnx-replace-sheet-rule)
               "\n" (drgnx-replace--gap 14)
               (propertize (format "Undo puts all %d file%s back" (length files) (if (= (length files) 1) "" "s"))
                           'face 'drgnx-text-subtle)
               (drgnx-replace--sheet-at-edge (+ (drgnx-replace--sheet-edge files skipped) (drgnx-px 8))
                                             (drgnx-replace--sheet-buttons))
               "\n\n"))   ; a line of room under the buttons (the mockup's foot padding; a taller line would stretch them)
      (_ "\n"))))

(drgnx-view-define 'replace-sheet :render #'drgnx-replace--sheet-render :slice drgnx-view-slice :delay 0)

(defun drgnx-replace--sheet-draw ()
  "Draw the sheet from `drgnx-replace--sheet', point on the selected file."
  (drgnx-view-reset drgnx-view (append '((:title))
                                       (cl-loop for i below (length (plist-get drgnx-replace--sheet :files))
                                                collect (list :file i))
                                       '((:foot))))
  (drgnx-view-draw-now drgnx-view)
  (goto-char (point-min))
  (when (text-property-search-forward 'drgnx-replace-sheet-file (plist-get drgnx-replace--sheet :sel) #'eql)
    (goto-char (line-beginning-position 0))))

(defun drgnx-replace--sheet-button (label id face)
  "LABEL as a button in FACE running registry command ID, its key after the label as one chip (`Ctrl ↵')."
  (let* ((key (and (fboundp 'drgnx-surfaces-key-label) (drgnx-surfaces-key-label id :short t)))
         (cap (and key (fboundp 'drgnx-palette-keycap)
                   (drgnx-palette-keycap (string-join (drgnx-palette-keycap-names key) " "))))
         (img (and cap (drgnx-replace--chip-image (substring-no-properties cap))))
         (button (drgnx-ui-button (if cap (concat label "  " (or img cap)) label) id :face face)))
    ;; without an image the button's face replaces the chip's: ring the chip again, over the button (after its pad);
    ;; that ring breaks the button's (one box per run), the image keeps it whole
    (when (and cap (not img))
      (let ((start (+ 1 (length label) 2)))
        (add-face-text-property start (+ start (length cap)) 'drgnx-replace-sheet-key nil button)))
    button))

(defun drgnx-replace--chip-image (text)
  "TEXT (a key: `Ctrl ↵') as one SVG chip in a string: rounded, ringed and written in `drgnx-replace-sheet-key''s
colour and font, on no fill (the button's shows through), so the button's own ring runs on over it: a face's box in
the button would end the button's run.  Nil without SVG on a graphical frame or the face's font."
  (when-let* (((display-graphic-p)) ((image-type-available-p 'svg))
              (font (face-font 'drgnx-replace-sheet-key)) (info (font-info font))
              (family (face-attribute 'drgnx-replace-sheet-key :family nil t)) ((stringp family))
              (fg (face-foreground 'drgnx-replace-sheet-key nil t)))
    (require 'svg)
    ;; `font-info': [NAME FULL SIZE HEIGHT … ASCENT (8) DESCENT (9) …]
    (let* ((asc (aref info 8)) (desc (aref info 9)) (lw (drgnx-px-line 1)) (pad (drgnx-px 5))
           (w (+ (* 2 pad) (string-pixel-width (propertize text 'face 'drgnx-replace-sheet-key))))
           (h (+ asc desc (* 2 lw) (drgnx-px 2)))
           (svg (svg-create w h)))
      (svg-rectangle svg (/ lw 2.0) (/ lw 2.0) (- w lw) (- h lw)
                     :rx (drgnx-px 4) :fill "none" :stroke fg :stroke-width lw)
      ;; centred: the SVG's font may set the text a little narrower than the frame's
      (svg-text svg text :x (/ w 2.0) :text-anchor "middle" :y (+ (/ (- h asc desc) 2) asc) :fill fg
                :font-family family :font-size (aref info 2))
      (propertize " " 'display (svg-image svg :ascent 'center :scale 1)))))

(defun drgnx-replace--sheet-hunk ()
  "Ask the hub for the selected file's first hunk (its preview), drawn under it when it comes."
  (let* ((s drgnx-replace--sheet) (f (nth (plist-get s :sel) (plist-get s :files))) (buf (current-buffer)))
    (when-let* ((view (and f (get-buffer drgnx-replace-buffer-name))))
      (with-current-buffer view
        (drgnx-replace--hub-write
         "search/preview" (drgnx-replace--preview-params (plist-get f :path))
         (lambda (r)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (let ((h (and (> (length (plist-get r :hunks)) 0) (seq-elt (plist-get r :hunks) 0))))
                 (setq drgnx-replace--sheet
                       (plist-put (plist-put drgnx-replace--sheet :hunk
                                             (car (drgnx-replace--hunks-of (or (plist-get r :diff) ""))))
                                  :captures (plist-get h :captures))))
               (drgnx-replace--sheet-draw)
               (when (fboundp 'drgnx-popup-refit) (drgnx-popup-refit buf))))))))))       ; the lane fits the hunk too

(defun drgnx-replace-sheet-next (&optional n)
  "Select the sheet's next file (N files on), showing its first hunk."
  (interactive "p")
  (let ((s drgnx-replace--sheet))
    (setq drgnx-replace--sheet (plist-put (plist-put s :hunk nil) :sel
                                          (mod (+ (plist-get s :sel) (or n 1)) (max 1 (length (plist-get s :files))))))
    (drgnx-replace--sheet-draw)
    (drgnx-replace--sheet-hunk)))

(defun drgnx-replace-sheet-previous ()
  "Select the sheet's previous file."
  (interactive)
  (drgnx-replace-sheet-next -1))

(defun drgnx-replace-sheet-confirm ()
  "Replace: write the edit set the sheet shows (`search/apply'); the sheet goes."
  (interactive)
  (let ((change (plist-get drgnx-replace--sheet :change)) (skipped (plist-get drgnx-replace--sheet :skipped)))
    (quit-window t)
    (with-current-buffer (drgnx-replace--live-view)
      (drgnx-replace--apply-change change 'all nil skipped))))


(defun drgnx-replace-sheet-cancel ()
  "Cancel: the sheet goes, nothing is written."
  (interactive)
  (quit-window t))

(defun drgnx-replace--teardown ()
  "Turn the Search view and the find bar off: close the bar, stop what the view runs (search, drawing, file
watches), kill both buffers.  Never asks.  Their pauses and refreshes are layer keys the buffers own: killing them
cancels those."
  (remove-hook 'drgnx-hub-event-functions #'drgnx-replace--hub-event)
  (remove-hook 'drgnx-hub-connected-functions #'drgnx-replace--hub-up)
  (drgnx-replace-bar-close)
  (let ((kill-buffer-query-functions nil))
    (dolist (b (buffer-list))                ; the preview tiles and the sheet
      (when (memq (buffer-local-value 'major-mode b) '(drgnx-replace-preview-mode drgnx-replace-sheet-mode))
        (kill-buffer b)))
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
                              (drgnx-wb-place 'drgnx-replace-sheet-mode 'popup :height 0.8 :modal t) ; the sheet: the popup lane, tall
                              (drgnx-wb-place 'drgnx-search-handoff-mode 'popup :height 0.3 :modal t) ; Ask an Agent's card
                              (eval-after-load 'evil (drgnx-modules-with-owner (drgnx-replace--evil-states)))
                              ;; wb/drgnx-persist.el saves the main area with `window-state-get': the bar's window would be in it.
                              (advice-add 'drgnx-persist-save :before #'drgnx-replace--close-bars)))

(provide 'drgnx-replace)
;;; drgnx-replace.el ends here
