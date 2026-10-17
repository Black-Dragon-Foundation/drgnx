;;; drgnx-search-chunk.el --- Semantic search: the files of a project and their chunks -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The indexer asks `drgnx-search-files' for a project's files with their git blob hashes (a file whose
;; hash is unchanged is not embedded again) and splits the text of each into chunks with
;; `drgnx-search-chunks'.  The text of these files goes to an embedding provider, so the file list is
;; strict: only tracked regular files, never a dot file or anything under a dot directory, never a file
;; over 1 MiB, never a binary — whatever `.drgnx/search.eld' says.  That file can only narrow the list.
;; See docs/guide/search.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defconst drgnx-search-chunk-max-file-bytes 1048576
  "Files larger than this are never indexed.")

(defconst drgnx-search-chunk-window-lines 60 "Most lines in a chunk.")
(defconst drgnx-search-chunk-break-after 40 "A window breaks at a blank line only past this many lines.")
(defconst drgnx-search-chunk-overlap-lines 10 "Lines shared by consecutive chunks.")
(defconst drgnx-search-chunk-max-chars 2500 "Most characters in a chunk.")

;;;; Chunks

(defun drgnx-search-chunk--blank-p (line)
  "Non-nil when LINE holds nothing but whitespace."
  (not (string-match-p "[^ \t\r\f\n]" line)))

(defun drgnx-search-chunks (text)
  "Split TEXT into chunks (:start LINE :end LINE :text STRING).
Lines are 1-based and inclusive.  A chunk is a window of at most 60 lines
and 2500 characters.  A window cut short by those limits is
broken at its last blank line when that line comes after line 40 of the window (the blank line ends
the chunk).  Consecutive chunks share 10 lines, except around a line of more than 2500 characters:
that line is cut into 2500-character chunks, all carrying its line number.  Chunks holding only
whitespace are dropped, so empty TEXT has none."
  (let* ((lines (vconcat (split-string text "\n")))
         (n (length lines))
         (start 0) chunks)
    ;; "a\nb\n" has no third line.
    (when (and (> n 0) (string-empty-p (aref lines (1- n)))) (cl-decf n))
    (cl-flet ((emit (from to str)
                (unless (drgnx-search-chunk--blank-p str)
                  (push (list :start from :end to :text str) chunks))))
      (while (< start n)
        (if (> (length (aref lines start)) drgnx-search-chunk-max-chars)
            ;; A minified line: pieces, all on the same line number.
            (let ((line (aref lines start)) (i 0))
              (while (< i (length line))
                (let ((j (min (length line) (+ i drgnx-search-chunk-max-chars))))
                  (emit (1+ start) (1+ start) (substring line i j))
                  (setq i j)))
              (setq start (1+ start)))
          (let ((end start) (chars -1) (cut nil) (next-long nil))
            ;; Grow the window while the limits allow; CHARS is the length of the joined lines.
            (while (and (< end n) (not cut) (not next-long))
              (let ((len (length (aref lines end))))
                (cond ((>= (- end start) drgnx-search-chunk-window-lines) (setq cut t))
                      ((> (+ chars 1 len) drgnx-search-chunk-max-chars)
                       (if (> len drgnx-search-chunk-max-chars) (setq next-long t) (setq cut t)))
                      (t (setq chars (+ chars 1 len) end (1+ end))))))
            (when (and cut (< end n))
              (let ((blank (cl-loop for i from (1- end) downto (+ start drgnx-search-chunk-break-after)
                                    when (drgnx-search-chunk--blank-p (aref lines i)) return i)))
                (when blank (setq end (1+ blank)))))
            (emit (1+ start) end
                  (mapconcat #'identity (cl-subseq lines start end) "\n"))
            (setq start (cond ((>= end n) n)
                              (next-long end)
                              ((> (- end start) drgnx-search-chunk-overlap-lines)
                               (- end drgnx-search-chunk-overlap-lines))
                              (t end)))))))
    (nreverse chunks)))

;;;; Configuration

(defvar read-eval)                      ; `let'-bound below: must be dynamic once compiled

(defun drgnx-search--string-list (value)
  "VALUE when it is a list of strings, else nil."
  (and (proper-list-p value) (cl-every #'stringp value) value))

(defun drgnx-search-config (root)
  "The search configuration of the project at ROOT.
A plist (:include GLOBS :exclude GLOBS :off BOOL), read from
ROOT/.drgnx/search.eld with `read-eval' off.  Absent, unreadable or malformed
(a key with the wrong type falls back to its default) is never an error.  With `:include' only the
files matching one of its globs are indexed; `:exclude' removes files; `:off' non-nil turns the
project's search off.  This can only narrow the list: dot files, big files, binaries and symlinks
are never indexed.  Globs are matched against the path relative to ROOT: `*' and `?' stay within
one path component, `**/' stands for any number of directories and `**' for anything; a glob
without `/' matches at any depth (\"*.md\"), and a trailing `/' means everything below that
directory (\"vendor/\")."
  (let* ((file (expand-file-name ".drgnx/search.eld" root))
         (data (condition-case nil
                   (with-temp-buffer
                     (let ((read-eval nil) (coding-system-for-read 'utf-8-unix))
                       (insert-file-contents file nil 0 65536)
                       (read (current-buffer))))
                 (error nil)))
         (plist (and (proper-list-p data) (cl-evenp (length data)) data)))
    (list :include (drgnx-search--string-list (plist-get plist :include))
          :exclude (drgnx-search--string-list (plist-get plist :exclude))
          :off (and (plist-get plist :off) t))))

(defun drgnx-search--glob-regexp (glob)
  "A regexp matching the relative paths GLOB selects (see `drgnx-search-config')."
  (let ((glob (cond ((string-suffix-p "/" glob) (concat glob "**"))
                    ((string-search "/" glob) glob)
                    (t (concat "**/" glob))))
        (i 0) (out nil))
    (while (< i (length glob))
      (let ((c (aref glob i)))
        (cond ((and (eq c ?*) (eq (ignore-errors (aref glob (1+ i))) ?*))
               (if (eq (ignore-errors (aref glob (+ i 2))) ?/)
                   (progn (push "\\(?:.*/\\)?" out) (cl-incf i 3))
                 (push ".*" out) (cl-incf i 2)))
              ((eq c ?*) (push "[^/]*" out) (cl-incf i))
              ((eq c ?\?) (push "[^/]" out) (cl-incf i))
              (t (push (regexp-quote (string c)) out) (cl-incf i)))))
    (concat "\\`" (apply #'concat (nreverse out)) "\\'")))

(defun drgnx-search--matches-p (path regexps)
  (cl-some (lambda (re) (string-match-p re path)) regexps))

;;;; Files

(defun drgnx-search--git (root input &rest args)
  "Run git ARGS in ROOT feeding it the string INPUT (or nil): its output, or nil on failure.
No shell; nil too when ROOT is no repository, git is missing or git fails."
  (when (and (file-directory-p root) (executable-find "git"))
    (let ((default-directory (file-name-as-directory (expand-file-name root)))
          (process-environment (cl-remove-if (lambda (e) (string-match-p "\\`GIT_\\(DIR\\|WORK_TREE\\|INDEX_FILE\\)=" e))
                                             process-environment))
          (coding-system-for-read 'utf-8-unix)
          (coding-system-for-write 'utf-8-unix))
      (with-temp-buffer
        (when (condition-case nil
                  (zerop (if input
                             (progn (insert input)
                                    (apply #'call-process-region (point-min) (point-max) "git" t (list t nil) nil args))
                           (apply #'call-process "git" nil (list t nil) nil args)))
                (error nil))
          (buffer-string))))))

(defun drgnx-search--parse-index (out)
  "The stage 0 entries of `git ls-files -s -z' output OUT: (MODE BLOB PATH) each."
  (let ((pos 0) entries)
    ;; MODE SP BLOB SP STAGE TAB PATH NUL
    (while (string-match "\\([0-7]+\\) \\([0-9a-f]+\\) \\([0-3]\\)\t\\([^\0]*\\)\0" out pos)
      (setq pos (match-end 0))
      (when (equal (match-string 3 out) "0")
        (push (list (match-string 1 out) (match-string 2 out) (match-string 4 out)) entries)))
    (nreverse entries)))

(defun drgnx-search--git-paths (root &rest args)
  "The NUL-separated paths git ARGS print in ROOT (`ls-files -z' options), or nil."
  (split-string (or (apply #'drgnx-search--git root nil args) "") "\0" t))

(defun drgnx-search--hash-objects (root paths)
  "The git blob SHAs of the working-tree content of PATHS in ROOT: an alist (PATH . SHA).
One `git hash-object --stdin-paths' call; it takes one path per line, so a path with a newline is
left out, as is everything when git fails."
  (let* ((paths (cl-remove-if (lambda (p) (string-search "\n" p)) paths))
         (out (and paths (drgnx-search--git root (concat (string-join paths "\n") "\n")
                                            "hash-object" "--stdin-paths")))
         (shas (and out (split-string out "\n" t))))
    (when (= (length shas) (length paths))
      (cl-mapcar #'cons paths shas))))

(defun drgnx-search--dot-path-p (path)
  "Non-nil when a component of the relative PATH starts with a dot."
  (string-match-p "\\(?:\\`\\|/\\)\\." path))

(defun drgnx-search--binary-p (file)
  "Non-nil when FILE has a NUL byte among its first 8000 bytes (or cannot be read)."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil 0 8000)
        (goto-char (point-min))
        (search-forward "\0" nil t))
    (error t)))

(defun drgnx-search-files (root)
  "The files of the project at ROOT to index, as (PATH . HASH).
PATH is relative to ROOT; HASH is the working-tree content hash (git blob SHA), so an unchanged
file keeps its hash and an edit changes it, staged or not.  The files are the tracked ones
(`git ls-files -s'; a clean file's hash comes from the index, a modified one is hashed with one
`git hash-object' call) plus the untracked ones that .gitignore does not exclude; a tracked file
deleted on disk is not listed.  Never included, whatever `drgnx-search-config' says: a dot file or a
file under a dot directory, a symlink or a submodule, a file over 1 MiB, a binary.  The configuration
then narrows the list.  nil when ROOT is no git repository, git is missing or the project's search is
`:off'."
  (let* ((config (drgnx-search-config root))
         (include (mapcar #'drgnx-search--glob-regexp (plist-get config :include)))
         (exclude (mapcar #'drgnx-search--glob-regexp (plist-get config :exclude)))
         (root (file-name-as-directory (expand-file-name root)))
         (staged (and (not (plist-get config :off))
                      (drgnx-search--git root nil "ls-files" "-s" "-z")))
         (dirty (make-hash-table :test #'equal))
         known pending)
    (when staged
      (dolist (p (drgnx-search--git-paths root "ls-files" "-m" "-z")) (puthash p t dirty))
      ;; Candidates (PATH . BLOB), BLOB nil when the working-tree content has to be hashed.
      (dolist (entry (append
                      (cl-loop for (mode blob path) in (drgnx-search--parse-index staged)
                               when (member mode '("100644" "100755")) ; no symlink, no submodule
                               collect (cons path (unless (gethash path dirty) blob)))
                      (mapcar #'list (drgnx-search--git-paths root "ls-files" "-z" "--others" "--exclude-standard"))))
        (let ((path (car entry)))
          (when (and (not (string-suffix-p "/" path)) ; a nested repository
                     (not (drgnx-search--dot-path-p path))
                     (or (null include) (drgnx-search--matches-p path include))
                     (not (drgnx-search--matches-p path exclude)))
            (let* ((file (expand-file-name path root))
                   (attrs (file-attributes file 'integer)))
              (when (and attrs (null (file-attribute-type attrs))
                         (<= (file-attribute-size attrs) drgnx-search-chunk-max-file-bytes)
                         (not (drgnx-search--binary-p file)))
                (if (cdr entry) (push entry known) (push path pending)))))))
      ;; One batched call for every modified or untracked file; order by path.
      (sort (nconc known (drgnx-search--hash-objects root (nreverse pending)))
            (lambda (a b) (string< (car a) (car b)))))))

(provide 'drgnx-search-chunk)
;;; drgnx-search-chunk.el ends here
