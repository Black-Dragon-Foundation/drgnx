;;; drgnx-search-chunk.el --- Semantic search: the files of a project and their chunks -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The indexer asks `drgnx-search-files' for a project's files with their git blob hashes (a file whose
;; hash is unchanged is not embedded again) and splits the text of each into chunks with
;; `drgnx-search-chunks'.  The text of these files goes to an embedding provider, so the file list is
;; strict: the tracked files and the untracked ones .gitignore does not exclude, regular files only (no
;; symlink, FIFO or submodule), never a dot file or anything under a dot directory, never a key or secret
;; by name (`drgnx-search--sensitive-name-p'), never a file over 1 MiB, never a binary — whatever
;; `.drgnx/search.eld' says.  That file can only narrow the list.  A file in a merge conflict (index
;; stages 1-3 only) is not listed until it is resolved.  If git fails the listing signals
;; `drgnx-search-files-error' rather than return a partial list.
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

(defun drgnx-search--config-problem (data)
  "Why DATA (the form read from .drgnx/search.eld) is no search configuration, or nil."
  (cond ((not (and (proper-list-p data) (cl-evenp (length data)))) "it is not a plist")
        ((not (or (null (plist-get data :include)) (drgnx-search--string-list (plist-get data :include))))
         ":include must be a list of strings")
        ((not (or (null (plist-get data :exclude)) (drgnx-search--string-list (plist-get data :exclude))))
         ":exclude must be a list of strings")
        ((not (memq (plist-get data :off) '(nil t))) ":off must be t or nil")))

(defun drgnx-search-config (root)
  "The search configuration of the project at ROOT.
A plist (:include GLOBS :exclude GLOBS :off BOOL), read from
ROOT/.drgnx/search.eld with `read-eval' off; the defaults (all nil) when there is no such file.  A file that
is there but cannot be read (also: a `.drgnx' that cannot be searched, a `search.eld' that is a dangling
symlink), does not hold a plist, or gives a key the wrong type (:include or :exclude not a
list of strings, :off not t or nil) is (:error \".drgnx/search.eld cannot be read: WHY\"), never the defaults:
`drgnx-search-files' then signals instead of listing more than the project asked for.  With `:include' only the
files matching one of its globs are indexed; `:exclude' removes files; `:off' t turns the
project's search off.  This can only narrow the list: dot files, big files, binaries and symlinks
are never indexed.  Globs are matched against the path relative to ROOT: `*' and `?' stay within
one path component, `**/' stands for any number of directories and `**' for anything; a glob
without `/' matches at any depth (\"*.md\"), and a trailing `/' means everything below that
directory (\"vendor/\")."
  (let* ((dir (expand-file-name ".drgnx" root))
         (file (expand-file-name "search.eld" dir)))
    (cond
     ;; Something is there but hides the file: a .drgnx that cannot be searched, or search.eld a dangling symlink.
     ((and (file-attributes dir) (not (file-accessible-directory-p dir)))
      (list :error ".drgnx/search.eld cannot be read: .drgnx is not an accessible directory"))
     ((and (not (file-exists-p file)) (file-symlink-p file))
      (list :error ".drgnx/search.eld cannot be read: it is a symbolic link to nothing"))
     (t
      (if (not (file-exists-p file))
          (list :include nil :exclude nil :off nil)
        (let* ((data (condition-case err
                         (with-temp-buffer
                           (let ((read-eval nil) (coding-system-for-read 'utf-8-unix))
                             (insert-file-contents file nil 0 65536)
                             (read (current-buffer))))
                       (error (cons 'drgnx-search--unreadable (error-message-string err)))))
               (problem (if (eq (car-safe data) 'drgnx-search--unreadable) (cdr data) (drgnx-search--config-problem data))))
          (if problem
              (list :error (concat ".drgnx/search.eld cannot be read: " problem))
            (list :include (plist-get data :include) :exclude (plist-get data :exclude) :off (plist-get data :off)))))))))

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
  "Non-nil when PATH matches one of the glob REGEXPS (case-sensitively)."
  (let ((case-fold-search nil))
    (cl-some (lambda (re) (string-match-p re path)) regexps)))

;;;; Files

(define-error 'drgnx-search-files-error "Listing the project's files failed")

(defvar drgnx-search-git-timeout nil
  "Seconds `drgnx-search-files' may take in all, git and file reads together, or nil for no limit (the indexer's
case: a big repository takes as long as it takes).  Bound by the doctor, which must never wait long: past it the
listing signals `drgnx-search-files-error' \"timed out\".")

(defvar drgnx-search--git-deadline nil
  "The `float-time' at which a listing under `drgnx-search-git-timeout' times out (bound by `drgnx-search-files').")

(defun drgnx-search--check-deadline (what)
  "Signal `drgnx-search-files-error' naming WHAT when the listing's deadline has passed."
  (when (and drgnx-search--git-deadline (> (float-time) drgnx-search--git-deadline))
    (signal 'drgnx-search-files-error (list (format "%s timed out" what)))))

(defun drgnx-search--git-run-timed (input args)
  "Like `drgnx-search--git-run' for the caller's `default-directory' and environment, but with a hard bound:
the deadline of `drgnx-search--git-deadline'.  Past it git is killed and `drgnx-search-files-error' is signaled."
  (drgnx-search--check-deadline (format "git %s" (string-join args " ")))
  (let* ((out (generate-new-buffer " *drgnx-search-git*" t)) (err (generate-new-buffer " *drgnx-search-git-err*" t))
         (proc nil))
    (unwind-protect
        (condition-case e
            (progn
              (setq proc (make-process :name "drgnx-search-git" :command (cons "git" args) :buffer out :stderr err
                                       :connection-type 'pipe :coding 'utf-8-unix :noquery t :sentinel #'ignore))
              (when-let* ((errproc (get-buffer-process err))) (set-process-sentinel errproc #'ignore))
              (when input (process-send-string proc input))
              (process-send-eof proc)
              (while (and (or (process-live-p proc) (let ((p (get-buffer-process err))) (and p (process-live-p p))))
                          (<= (float-time) drgnx-search--git-deadline))
                (accept-process-output proc 0.05))
              (when (process-live-p proc)
                (delete-process proc)
                (signal 'drgnx-search-files-error (list (format "git %s timed out" (string-join args " ")))))
              (accept-process-output nil 0.01)
              (list (process-exit-status proc) (with-current-buffer out (buffer-string))
                    (with-current-buffer err (buffer-substring (point-min) (progn (goto-char (point-min)) (line-end-position))))))
          (drgnx-search-files-error (signal (car e) (cdr e)))
          (error (list nil nil (error-message-string e))))
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer out) (kill-buffer err))))

(defun drgnx-search--git-run (root input args)
  "Run git ARGS in ROOT, feeding it the string INPUT (or nil); no shell.
Returns (STATUS OUTPUT STDERR-FIRST-LINE), STATUS nil when git cannot be started.  Under
`drgnx-search-git-timeout' (see `drgnx-search-files') it waits for git only until the listing's deadline."
  (let ((default-directory (file-name-as-directory (expand-file-name root)))
        ;; Untranslated messages: `drgnx-search--repo-p' reads git's stderr, and git translates it.
        (process-environment (append '("LC_ALL=C" "LANGUAGE=")
                                     (cl-remove-if (lambda (e) (string-match-p "\\`GIT_\\(DIR\\|WORK_TREE\\|INDEX_FILE\\)=" e))
                                                   process-environment)))
        (coding-system-for-read 'utf-8-unix)
        (coding-system-for-write 'utf-8-unix)
        (errfile (make-temp-file "drgnx-search-git")))
    (unwind-protect
        (if drgnx-search--git-deadline
            (drgnx-search--git-run-timed input args)
          (with-temp-buffer
            (let ((status (condition-case err
                              (if input
                                  (progn (insert input)
                                         (apply #'call-process-region (point-min) (point-max) "git" t (list t errfile) nil args))
                                (apply #'call-process "git" nil (list t errfile) nil args))
                            (error (list 'error (error-message-string err))))))
              (if (consp status)
                  (list nil nil (cadr status))
                (list status (buffer-string)
                      (with-temp-buffer
                        (insert-file-contents errfile)
                        (buffer-substring (point-min) (line-end-position))))))))
      (delete-file errfile))))

(defun drgnx-search--git (root input &rest args)
  "Run git ARGS in ROOT with INPUT on stdin (or nil): its output.
Signals `drgnx-search-files-error', naming the command and the first line of git's stderr, when git
fails."
  (pcase (drgnx-search--git-run root input args)
    (`(0 ,out ,_) out)
    (`(,_ ,_ ,err)
     (signal 'drgnx-search-files-error
             (list (format "git %s: %s" (string-join args " ") err))))))

(defun drgnx-search--repo-p (root)
  "Non-nil when ROOT is a directory inside a git work tree and git can run."
  (and (file-directory-p root) (executable-find "git")
       (pcase (drgnx-search--git-run root nil '("rev-parse" "--is-inside-work-tree"))
         (`(0 ,out ,_) (string-prefix-p "true" out))
         (`(,_ ,_ ,err) (unless (string-match-p "not a git repository" err)
                          (signal 'drgnx-search-files-error (list (format "git rev-parse: %s" err))))))))

(defun drgnx-search-toplevel (dir)
  "The top of the git work tree holding the directory DIR, as a directory name without trailing slash — spelled
from DIR (`--show-cdup', not `--show-toplevel', which resolves symlinks: the index file is named after the
path, and the editor's project root keeps the user's spelling) — or nil when DIR is in no git work tree."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (when (file-directory-p dir)
      (pcase (drgnx-search--git-run dir nil '("rev-parse" "--show-cdup"))
        (`(0 ,out ,_) (directory-file-name (expand-file-name (string-trim out) dir)))))))

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
  "The NUL-separated paths git ARGS print in ROOT (`ls-files -z' options).
Signals `drgnx-search-files-error' when git fails."
  (split-string (or (apply #'drgnx-search--git root nil args) "") "\0" t))

(defun drgnx-search--hashable-p (path file)
  "Non-nil when PATH (at FILE) can go through `git hash-object --stdin-paths'.
That reads one path per line and unquotes a leading double quote, so neither a newline nor a leading
quote can be passed; the file must also still be a regular file."
  (and (not (string-search "\n" path)) (not (string-prefix-p "\"" path)) (file-regular-p file)))

(defun drgnx-search--hash-objects (root paths)
  "The git blob SHAs of the working-tree content of PATHS in ROOT: an alist (PATH . SHA).
One `git hash-object --stdin-paths' call over the PATHS that are still regular files; signals
`drgnx-search-files-error' when it fails."
  (let ((paths (cl-remove-if-not (lambda (p) (drgnx-search--hashable-p p (concat root p))) paths)))
    (when paths
      (let ((shas (split-string (drgnx-search--git root (concat (string-join paths "\n") "\n")
                                                   "hash-object" "--stdin-paths")
                                "\n" t)))
        (unless (= (length shas) (length paths))
          (signal 'drgnx-search-files-error (list "git hash-object: unexpected output")))
        (cl-mapcar #'cons paths shas)))))

(defun drgnx-search--dot-path-p (path)
  "Non-nil when a component of the relative PATH starts with a dot."
  (string-match-p "\\(?:\\`\\|/\\)\\." path))

(defconst drgnx-search--sensitive-name-regexp
  (concat "\\(?:\\.\\(?:pem\\|key\\|p12\\|pfx\\|kdbx\\|keystore\\|jks\\|asc\\|gpg\\|env\\)\\'"
          "\\|\\`id_\\(?:rsa\\|dsa\\|ecdsa\\|ed25519\\)"
          "\\|secret\\|credential\\|authinfo\\|netrc\\)")
  "File names (basename, case-insensitive) that look like keys or secrets.")

(defun drgnx-search--sensitive-name-p (path)
  "Non-nil when the basename of PATH looks like a key, certificate or secret.
These are never indexed, whatever the configuration says."
  (let ((case-fold-search t))
    (string-match-p drgnx-search--sensitive-name-regexp (file-name-nondirectory path))))

(defun drgnx-search--binary-p (file)
  "Non-nil when FILE has a NUL byte among its first 8000 bytes (or cannot be read)."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file nil 0 8000)
        (goto-char (point-min))
        (search-forward "\0" nil t))
    (error t)))

(defun drgnx-search--inside-p (dir true-root cache)
  "Non-nil when the directory DIR, its symlinks resolved, is TRUE-ROOT (a truename, as a directory name) or
below it — a directory of the project replaced by a symlink to elsewhere is not.  CACHE (a hash table) keeps
the answer per directory."
  (let ((known (gethash dir cache 'unknown)))
    (if (not (eq known 'unknown)) known
      (puthash dir (string-prefix-p true-root (file-name-as-directory (file-truename dir))) cache))))

(defun drgnx-search-files (root)
  "The files of the project at ROOT to index, as (PATH . HASH).
PATH is relative to ROOT; HASH is the working-tree content hash (git blob SHA), so an unchanged
file keeps its hash and an edit changes it, staged or not.  The files are the tracked ones
(`git ls-files -s'; a clean file's hash comes from the index, a modified one is hashed with one
`git hash-object' call) plus the untracked ones that .gitignore does not exclude; a tracked file
deleted on disk is not listed, nor is one in a merge conflict (index stages 1-3 only).  Never
included, whatever `drgnx-search-config' says: anything but a regular file (symlink, FIFO,
submodule), a dot file or a file under a dot directory, a key or secret by name (*.pem, *.key, *.p12,
*.pfx, *.kdbx, *.keystore, *.jks, *.asc, *.gpg, *.env, id_rsa*, id_dsa*, id_ecdsa*, id_ed25519*,
anything containing secret, credential, authinfo or netrc, case-insensitively), a file over 1 MiB,
a binary, a file in a directory whose real path (symlinks resolved) is outside the project.  A modified or
untracked file whose path contains a newline or starts with a double quote cannot be hashed and is left out
too.  The configuration then narrows the list.

nil when ROOT is no git repository, git is missing or the project's search is `:off'.  When git
fails, or .drgnx/search.eld is there but cannot be read (see `drgnx-search-config'), the listing signals
`drgnx-search-files-error' (never a partial list, never more than the project asked for)."
  (let ((drgnx-search--git-deadline (or drgnx-search--git-deadline
                                        (and drgnx-search-git-timeout (+ (float-time) drgnx-search-git-timeout)))))
    (drgnx-search--files-1 root)))

(defun drgnx-search--files-1 (root)
  "The body of `drgnx-search-files' (ROOT)."
  (let* ((config (drgnx-search-config root))
         (include (mapcar #'drgnx-search--glob-regexp (plist-get config :include)))
         (exclude (mapcar #'drgnx-search--glob-regexp (plist-get config :exclude)))
         (root (file-name-as-directory (expand-file-name root)))
         (true-root (file-name-as-directory (file-truename root)))
         (dirs (make-hash-table :test #'equal))
         known pending)
    (when (plist-get config :error) (signal 'drgnx-search-files-error (list (plist-get config :error))))
    (when (and (not (plist-get config :off)) (drgnx-search--repo-p root))
      (let ((dirty (make-hash-table :test #'equal))
            (staged (drgnx-search--git root nil "ls-files" "-s" "-z")))
        (dolist (p (drgnx-search--git-paths root "ls-files" "-m" "-z")) (puthash p t dirty))
        ;; Candidates (PATH . BLOB), BLOB nil when the working-tree content has to be hashed.
        (dolist (entry (append
                        (cl-loop for (mode blob path) in (drgnx-search--parse-index staged)
                                 when (member mode '("100644" "100755")) ; no symlink, no submodule
                                 collect (cons path (unless (gethash path dirty) blob)))
                        (mapcar #'list (drgnx-search--git-paths root "ls-files" "-z" "--others" "--exclude-standard"))))
          (drgnx-search--check-deadline "listing the files")
          (let ((path (car entry)))
            (when (and (not (string-suffix-p "/" path)) ; a nested repository
                       (not (drgnx-search--dot-path-p path))
                       (not (drgnx-search--sensitive-name-p path))
                       (or (null include) (drgnx-search--matches-p path include))
                       (not (drgnx-search--matches-p path exclude)))
              ;; Never `expand-file-name': PATH is relative to ROOT, even when it starts with "~".
              (let* ((file (concat root path))
                     (attrs (file-attributes file 'integer)))
                (when (and attrs (null (file-attribute-type attrs)) (file-regular-p file)
                           (drgnx-search--inside-p (file-name-directory file) true-root dirs)
                           (<= (file-attribute-size attrs) drgnx-search-chunk-max-file-bytes)
                           (not (drgnx-search--binary-p file)))
                  (if (cdr entry) (push entry known) (push path pending)))))))
        ;; One batched call for every modified or untracked file; order by path.
        (sort (nconc known (drgnx-search--hash-objects root (nreverse pending)))
              (lambda (a b) (string< (car a) (car b))))))))

(provide 'drgnx-search-chunk)
;;; drgnx-search-chunk.el ends here
