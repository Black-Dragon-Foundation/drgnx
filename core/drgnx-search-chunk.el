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

(defun drgnx-search--git-index (root)
  "The staged entries of the git repository at ROOT: (MODE BLOB PATH) each.
nil when ROOT is no repository or git is missing."
  (when (and (file-directory-p root) (executable-find "git"))
    (let ((default-directory (file-name-as-directory (expand-file-name root)))
          (process-environment (cl-remove-if (lambda (e) (string-match-p "\\`GIT_\\(DIR\\|WORK_TREE\\|INDEX_FILE\\)=" e))
                                             process-environment))
          (coding-system-for-read 'utf-8-unix)
          entries)
      (with-temp-buffer
        (when (condition-case nil
                  (zerop (call-process "git" nil (list t nil) nil "ls-files" "-s" "-z"))
                (error nil))
          (goto-char (point-min))
          ;; MODE SP BLOB SP STAGE TAB PATH NUL
          (while (re-search-forward "\\([0-7]+\\) \\([0-9a-f]+\\) \\([0-3]\\)\t\\([^\0]*\\)\0" nil t)
            (when (equal (match-string 3) "0")
              (push (list (match-string 1) (match-string 2) (match-string 4)) entries)))))
      (nreverse entries))))

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
  "The files of the project at ROOT to index, as (PATH . BLOB-HASH).
PATH is relative to ROOT.  From `git ls-files -s' (tracked files only; the hash
is the git blob SHA, so an unchanged file keeps
its hash).  Never included, whatever `drgnx-search-config' says: a dot file or a file under a dot
directory, a symlink or a submodule, a file over 1 MiB, a binary.  The configuration then narrows
the list.  nil when ROOT is no git repository, git is missing or the project's search is `:off'."
  (let* ((config (drgnx-search-config root))
         (include (mapcar #'drgnx-search--glob-regexp (plist-get config :include)))
         (exclude (mapcar #'drgnx-search--glob-regexp (plist-get config :exclude)))
         (root (file-name-as-directory (expand-file-name root)))
         files)
    (unless (plist-get config :off)
      (pcase-dolist (`(,mode ,blob ,path) (drgnx-search--git-index root))
        (when (and (member mode '("100644" "100755"))
                   (not (drgnx-search--dot-path-p path))
                   (or (null include) (drgnx-search--matches-p path include))
                   (not (drgnx-search--matches-p path exclude)))
          (let* ((file (expand-file-name path root))
                 (attrs (file-attributes file 'integer)))
            (when (and attrs (null (file-attribute-type attrs))
                       (<= (file-attribute-size attrs) drgnx-search-chunk-max-file-bytes)
                       (not (drgnx-search--binary-p file)))
              (push (cons path blob) files))))))
    (nreverse files)))

(provide 'drgnx-search-chunk)
;;; drgnx-search-chunk.el ends here
