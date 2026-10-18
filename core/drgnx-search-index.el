;;; drgnx-search-index.el --- The background indexer of semantic code search -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-search-index' brings a project's index (`drgnx-search-store') up to date: the files that are new or
;; whose content hash changed are read, cut into chunks (`drgnx-search-chunks'), embedded in batches along the
;; `embed' role and written one file at a time; files that are gone are forgotten.  A file is written only when
;; all its chunks have vectors, so a stopped run leaves a consistent index that the next run completes.
;;
;; It runs as a background job (`drgnx-search-index-start'): a batch Emacs under systemd with a memory cap, so
;; indexing a big project can neither freeze the editor nor eat the machine.  Only the current batch's vectors
;; are ever in memory.  One indexer per project: a lock file next to the index holds the pid and start time of
;; the process indexing; a lock whose process is gone is taken over.  The lock is removed on exit only while it
;; still holds this process's pid and start time; a SIGTERM or an OOM kill leaves it behind, and the next run
;; takes it over as stale.  See docs/guide/search.md once it exists.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-search-store)
(require 'drgnx-search-chunk)
(require 'drgnx-ai-client)
(require 'drgnx-jobs)

(defconst drgnx-search-index-default-batch 32
  "Chunks per embedding request: TEI's default max-client-batch-size (a 413 halves it for the rest of the run).")

(defconst drgnx-search-index--core-dir (file-name-directory (or load-file-name buffer-file-name))
  "Where drgnx's core libraries are: the indexer's batch Emacs loads them from here.")

;;;; The lock

(defun drgnx-search-index--lock-file (root) (concat (drgnx-search-store-file root) ".lock"))

(defun drgnx-search-index--start-time (pid)
  "When process PID started (seconds), or nil when there is no such process."
  (when-let* ((start (alist-get 'start (process-attributes pid)))) (float-time start)))

(defun drgnx-search-index--lock-live-p (file)
  "Non-nil when the lock FILE (\"PID START\") belongs to a running process.  The start time must agree
within half a second, as for jobs: a pid recycled by another process is no holder."
  (let ((text (ignore-errors (with-temp-buffer (insert-file-contents file) (buffer-string)))))
    (if (and text (string-match "\\`\\([0-9]+\\) \\([0-9.]+\\)" text))
        (let ((now (drgnx-search-index--start-time (string-to-number (match-string 1 text))))
              (start (string-to-number (match-string 2 text))))
          (and now (or (zerop start) (< (abs (- now start)) 0.5))))
      ;; unparsable: a writer may be mid-write, so only an old one is stale
      (let ((attrs (file-attributes file)))
        (and attrs (< (float-time (time-since (file-attribute-modification-time attrs))) 10))))))

(defun drgnx-search-index--lock-text (file)
  (ignore-errors (with-temp-buffer (insert-file-contents file) (buffer-string))))

(defun drgnx-search-index--lock (root)
  "Take ROOT's indexing lock: its contents (\"PID START\"), or nil when a live process holds it.  A stale
lock is replaced."
  (let ((file (drgnx-search-index--lock-file root)) (taken nil) (tries 2)
        (token (format "%d %s" (emacs-pid) (or (drgnx-search-index--start-time (emacs-pid)) 0))))
    (make-directory (file-name-directory file) t)
    (while (and (not taken) (> tries 0))
      (cl-decf tries)
      (condition-case nil
          (progn (write-region token nil file nil 'silent nil 'excl)
                 ;; read it back: another process taking over a stale lock at the same moment may have
                 ;; replaced it, and then it is theirs
                 (if (equal token (drgnx-search-index--lock-text file)) (setq taken token) (setq tries 0)))
        (file-already-exists
         (if (drgnx-search-index--lock-live-p file) (setq tries 0) (ignore-errors (delete-file file))))))
    taken))

(defun drgnx-search-index--unlock (root token)
  "Remove ROOT's lock if it still holds TOKEN (a lock taken over meanwhile is another indexer's)."
  (let ((file (drgnx-search-index--lock-file root)))
    (ignore-errors
      (when (equal token (drgnx-search-index--lock-text file))
        (delete-file file)))))

;;;; Reading files

(defconst drgnx-search-index--raw-byte-regexp (concat "[" (string #x3fff80) "-" (string #x3fffff) "]")
  "A byte that did not decode (Emacs keeps those as raw-byte characters).")

(defun drgnx-search-index--read (root path)
  "The text of ROOT/PATH, decoded as UTF-8; nil when the file vanished, cannot be read, grew past the size
limit since it was listed (at most one byte more than the limit is read) or is not valid UTF-8."
  (condition-case nil
      (let* ((bytes (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert-file-contents-literally (concat root path) nil 0 (1+ drgnx-search-chunk-max-file-bytes))
                      (buffer-string)))
             (text (and (<= (length bytes) drgnx-search-chunk-max-file-bytes)
                        (decode-coding-string bytes 'utf-8-unix))))
        (unless (or (null text) (string-match-p drgnx-search-index--raw-byte-regexp text))
          ;; a byte-order mark and Windows line ends are not content: they would reach the chunks and the summary
          (replace-regexp-in-string "\r\n" "\n" (string-remove-prefix "\ufeff" text) t t)))
    (error nil)))

;;;; Indexing

(cl-defstruct (drgnx-search-index--file (:constructor drgnx-search-index--file (path hash kind left)) (:copier nil))
  path hash kind left (done nil))

(defun drgnx-search-index--model-name (meta)
  (or (plist-get meta :model) (plist-get meta :provider) "an unknown model"))

(cl-defun drgnx-search-index (root &key embed progress batch rebuild)
  "Bring the index of the project at ROOT up to date.  Returns (:added :changed :removed :chunks :skipped
:seconds :error): the files written new, rewritten (their content changed) and forgotten, the chunks written,
the files that could not be read as UTF-8 text or grew past the size limit (skipped, not an error; a changed
one loses its old rows) or that have a chunk the provider refuses even alone (skipped too, tried again by the
next run, old rows kept), and :error — a message, or nil.
EMBED (default `drgnx-ai-embed-sync') takes a vector of texts and returns a vector of vectors, setting
`drgnx-ai-embed-last-info' to who answered (provider, model).  BATCH (default 32) chunks go in one request;
a request the provider refuses is retried once in halves (the halved size stays for the run), and a second
failure stops the run: what is written stays, `:indexed-at' is not advanced so the index remains stale, and
:error has the provider's reason.  PROGRESS gets (FILES-DONE FILES-TOTAL) after each file.  REBUILD drops
everything first (the way to change model or dimensions); without it other vectors than the index was built
with are an :error.  A project that is no git project, has search off, or whose files git cannot list is an
:error and changes nothing.  A second indexer for the project is an :error \"indexing\"."
  (let* ((t0 (float-time)) (root (file-name-as-directory (expand-file-name root)))
         (embed (or embed #'drgnx-ai-embed-sync)) (batch (or batch drgnx-search-index-default-batch))
         (added 0) (changed 0) (removed 0) (chunks 0) (skipped 0) (done 0) (total 0) (failure nil) (token nil)
         (result (lambda ()
                   (list :added added :changed changed :removed removed :chunks chunks :skipped skipped
                         :seconds (- (float-time) t0) :error failure)))
         (files (condition-case err (drgnx-search-files root)
                  (drgnx-search-files-error (setq failure (or (cadr err) "listing the project's files failed")) nil))))
    (cond (failure nil)
          ((plist-get (drgnx-search-config root) :off) (setq failure "search is off for this project"))
          ((not (condition-case err (drgnx-search--repo-p root)
                  (error (setq failure (or (cadr err) "checking the project failed")) nil)))
           (unless failure (setq failure "not a git project"))))
    (if failure (funcall result)
      (if (not (setq token (drgnx-search-index--lock root)))
          (progn (setq failure "indexing") (funcall result))
        (let ((db nil))
          (unwind-protect
              (condition-case err
                  (let* ((known (progn (setq db (drgnx-search-store-open root)) (drgnx-search-store-files db)))
                         (fresh (or rebuild (zerop (hash-table-count known))))
                         (wanted (make-hash-table :test #'equal))
                         todo (buf nil) (retried-halving nil) (strikes 0) (dropped nil))
                    (when fresh                 ; nothing indexed to stay comparable with
                      (maphash (lambda (path _) (drgnx-search-store-delete-file db path)) known)
                      (clrhash known)
                      (drgnx-search-store-set-meta db (append '(:provider nil :model nil :dims nil)
                                                              (and rebuild '(:indexed-at nil)))))
                    (pcase-dolist (`(,path . ,hash) files)
                      (puthash path t wanted)
                      (let ((old (gethash path known)))
                        (cond ((null old) (push (drgnx-search-index--file path hash 'added 0) todo))
                              ((not (equal old hash)) (push (drgnx-search-index--file path hash 'changed 0) todo)))))
                    (setq todo (nreverse todo) total (length todo))
                    (maphash (lambda (path _)
                               (unless (gethash path wanted)
                                 (drgnx-search-store-delete-file db path)
                                 (cl-incf removed)))
                             known)
                    (cl-labels
                        ((tick () (cl-incf done) (when progress (funcall progress done total)))
                         (check-meta (vectors)
                           ;; the first batch of an index records who made its vectors; later ones must agree
                           (let* ((meta (drgnx-search-store-meta db)) (info drgnx-ai-embed-last-info)
                                  (dims (length (aref vectors 0))))
                             (if (null (plist-get meta :dims))
                                 (drgnx-search-store-set-meta
                                  db (list :provider (plist-get info :provider) :model (plist-get info :model) :dims dims))
                               (let ((same-model (or (null (plist-get info :provider))
                                                     (and (equal (plist-get info :provider) (plist-get meta :provider))
                                                          (equal (plist-get info :model) (plist-get meta :model))))))
                                 (cond ((/= dims (plist-get meta :dims))
                                        (error "the index was built with %s (%s); re-index"
                                               (drgnx-search-index--model-name meta) (plist-get meta :dims)))
                                       ((not same-model)   ; the same size from another model: a fallback answered
                                        (error "answered by fallback %s; the index was built with %s — run again when that is back, or rebuild to change the model"
                                               (drgnx-search-index--model-name info) (drgnx-search-index--model-name meta))))))))
                         (request (texts)
                           (setq drgnx-ai-embed-last-info nil)
                           (funcall embed (vconcat texts)))
                         (embed-texts (texts)
                           (condition-case nil
                               (request texts)
                             (drgnx-ai-embed-error
                              (unless retried-halving
                                (setq retried-halving t batch (max 1 (/ (1+ batch) 2))))
                              ;; the same texts again, in requests of the (halved) batch size
                              (let (vectors)
                                (while texts
                                  (push (request (seq-take texts batch)) vectors)
                                  (setq texts (nthcdr batch texts)))
                                (apply #'vconcat (nreverse vectors))))))
                         (skip (file)
                           ;; a chunk the provider refuses even alone: its file is skipped, and tried again by the
                           ;; next run (a changed file keeps its old rows meanwhile)
                           (push file dropped)
                           (setq buf (cl-remove file buf :key #'car))
                           (setf (drgnx-search-index--file-done file) nil)
                           (cl-incf skipped)
                           (tick))
                         (refused (entry err)
                           ;; ENTRY, one chunk alone, was refused: skip its file; two in a row mean the provider
                           ;; is down, not the text, and stop the run
                           (if (< (cl-incf strikes) 2)
                               (skip (car entry))
                             (signal (car err) (cdr err)))
                           nil)
                         (isolate (entries)
                           ;; a refused batch, one request per chunk: ((ENTRY . VECTOR-OR-NIL)…)
                           (let (out)
                             (dolist (e entries)
                               (push (cons e (unless (memq (car e) dropped)
                                               (condition-case err
                                                   (prog1 (aref (request (list (plist-get (cdr e) :text))) 0)
                                                     (setq strikes 0))
                                                 (drgnx-ai-embed-error (refused e err)))))
                                     out))
                             (nreverse out)))
                         (flush ()
                           (let* ((now (seq-take buf batch)) (pairs nil))
                             (setq buf (nthcdr (length now) buf))
                             (setq pairs
                                   (condition-case err
                                       (let ((vectors (embed-texts (mapcar (lambda (e) (plist-get (cdr e) :text)) now))))
                                         (unless (= (length vectors) (length now))
                                           (error "the provider answered %d vectors for %d texts" (length vectors) (length now)))
                                         (setq strikes 0)
                                         (cl-mapcar #'cons now (append vectors nil)))
                                     (drgnx-ai-embed-error
                                      (if (cdr now) (isolate now) (refused (car now) err)))))
                             (setq pairs (cl-remove-if (lambda (p) (or (null (cdr p)) (memq (car (car p)) dropped))) pairs))
                             (when pairs
                               (check-meta (vconcat (mapcar #'cdr pairs)))
                               (pcase-dolist (`((,file . ,chunk) . ,vector) pairs)
                                 (push (append (list :vector vector) chunk) (drgnx-search-index--file-done file))
                                 (when (zerop (cl-decf (drgnx-search-index--file-left file)))
                                   (finish file))))))
                         (finish (file)
                           (let ((chunk-list (nreverse (drgnx-search-index--file-done file))))
                             (drgnx-search-store-put-file db (drgnx-search-index--file-path file) (drgnx-search-index--file-hash file) chunk-list)
                             (cl-incf chunks (length chunk-list))
                             (if (eq (drgnx-search-index--file-kind file) 'added) (cl-incf added) (cl-incf changed))
                             (setf (drgnx-search-index--file-done file) nil)
                             (tick))))
                      (dolist (file todo)
                        (let ((text (drgnx-search-index--read root (drgnx-search-index--file-path file))))
                          (if (null text)
                              ;; no longer readable: what was indexed of it is no longer there either
                              (progn (when (eq (drgnx-search-index--file-kind file) 'changed)
                                       (drgnx-search-store-delete-file db (drgnx-search-index--file-path file)))
                                     (cl-incf skipped) (tick))
                            (let ((cs (drgnx-search-chunks text)))
                              (setf (drgnx-search-index--file-left file) (length cs))
                              (if (null cs) (finish file)
                                (setq buf (nconc buf (mapcar (lambda (c) (cons file c)) cs)))
                                (while (>= (length buf) batch) (flush)))))))
                      (while buf (flush)))
                    (drgnx-search-store-set-meta db (list :indexed-at (float-time))))
                (error (setq failure (if (eq (car err) 'drgnx-ai-embed-error) (cadr err) (error-message-string err)))))
            (when db (ignore-errors (sqlite-close db)))
            (drgnx-search-index--unlock root token)))
        (funcall result)))))

;;;; Batch entry and the job

(defun drgnx-search-index--summary (result)
  "The one line `drgnx-search-index-cli' prints for RESULT."
  (let ((counts (format "added %d, changed %d, removed %d (%d chunks%s)"
                        (or (plist-get result :added) 0) (or (plist-get result :changed) 0) (or (plist-get result :removed) 0)
                        (or (plist-get result :chunks) 0)
                        (if (> (or (plist-get result :skipped) 0) 0) (format ", %d files skipped (unreadable, or a chunk the provider refuses)" (plist-get result :skipped)) ""))))
    (if (plist-get result :error)
        (format "search index: error: %s (%s)" (plist-get result :error) counts)
      (format "search index: %s in %.1f s" counts (or (plist-get result :seconds) 0)))))

(defun drgnx-search-index-cli ()
  "Batch entry: `emacs --batch -L core -l drgnx-search-index -f drgnx-search-index-cli ROOT [--rebuild]'.
ROOT may be any directory of the project: its git top level is indexed (`drgnx-search-toplevel').
Prints one summary line; exits 0, or 1 on an error."
  (let* ((args command-line-args-left) (rebuild (member "--rebuild" args)) (root (car (delete "--rebuild" (copy-sequence args)))))
    (setq command-line-args-left nil)
    (if (null root)
        (progn (princ "search index: usage: drgnx-search-index-cli ROOT [--rebuild]\n") (kill-emacs 1))
      (let ((result (drgnx-search-index (or (drgnx-search-toplevel root) root) :rebuild (and rebuild t))))
        (princ (concat (drgnx-search-index--summary result) "\n"))
        (kill-emacs (if (plist-get result :error) 1 0))))))

(defun drgnx-search-index-running-p (root)
  "Non-nil when an indexer runs for the project at ROOT: a live process holds its lock.  Reads the lock file
only — never lists the jobs — so a timer may ask."
  (drgnx-search-index--lock-live-p (drgnx-search-index--lock-file root)))

(defun drgnx-search-index--running-job (root)
  "The running indexing job for ROOT (a directory name without trailing slash), if any.  Lists every job (a
process query each): for commands the user runs, never a timer."
  (cl-find-if (lambda (job) (and (eq (plist-get job :status) 'running)
                                 (string-prefix-p "search-index:" (or (plist-get job :name) ""))
                                 (member root (plist-get job :command))))
              (drgnx-jobs-list)))

(defun drgnx-search-index-busy-p (root)
  "Non-nil when the project at ROOT is being indexed: its lock is held, or one of its index jobs runs (one that
has not taken the lock yet).  For commands the user runs: it lists the jobs."
  (or (drgnx-search-index-running-p root)
      (drgnx-search-index--running-job (directory-file-name (expand-file-name root)))))

(defun drgnx-search-index--reap (root)
  "Remove the directories of ROOT's finished index jobs (exited or stopped: they have an exit file; gone: a pid
file but no live process) but the newest.
Reads each job's job.eld and looks for its exit file; only a job of ROOT without one costs a process query."
  (let ((dir (drgnx-jobs-dir)) (kept nil))
    (when (file-directory-p dir)
      (dolist (id (sort (directory-files dir nil "\\`[0-9]") (lambda (a b) (string> a b))))
        (let* ((jdir (drgnx-jobs--dir id)) (job (drgnx-jobs--read (expand-file-name "job.eld" jdir))))
          (when (and (string-prefix-p "search-index:" (or (plist-get job :name) ""))
                     (member root (plist-get job :command))
                     (or (file-exists-p (expand-file-name "exit" jdir))
                         ;; killed without an exit file (a reboot, a SIGKILL): started, but its process is gone
                         (and (file-exists-p (expand-file-name "pid" jdir))
                              (eq (plist-get (drgnx-jobs-get id) :status) 'gone))))
            (if kept (ignore-errors (delete-directory jdir t)) (setq kept t))))))))

;; The job is a fresh process: it gets the editor's state directories (so it writes the index and lock the
;; editor reads) and the keys of the embed chain (resolved here, where a key may live in auth-source).

(defun drgnx-search-index--dir-env ()
  "\"NAME=value\"… of the XDG and DRGNX_*_DIR variables set here: where a batch drgnx finds the user's files."
  (cl-loop for e in process-environment
           when (string-match-p "\\`\\(XDG_\\(STATE\\|CONFIG\\|CACHE\\|DATA\\)_HOME\\|DRGNX_[A-Z0-9_]*_DIR\\)=." e)
           collect e))

(defun drgnx-search-index--job-env (root)
  "\"NAME=value\"… for the indexing job of the project at ROOT: the XDG and DRGNX_*_DIR variables set here, and for
each provider in ROOT's `embed' role (its .drgnx/ai.eld counts, not the current buffer's) with a key, its key
variable.  Resolved without prompting.  The values travel in the environment only."
  (append
   (drgnx-search-index--dir-env)
   (let ((default-directory (file-name-as-directory (expand-file-name root))))
     (cl-loop for (id . _) in (drgnx-ai-role 'embed)
              for name = (plist-get (drgnx-ai-provider id) :key-env)
              for key = (and name (drgnx-ai-key id nil))
              when key collect (concat name "=" key)))))

(defconst drgnx-search-index--start-grace 30
  "Seconds a job just started may take to hold the lock: a second start in that time waits for it.")

(defun drgnx-search-index--starting-p (root)
  "Non-nil when a job of ROOT (a directory name without trailing slash) was started a moment ago and has no
exit file: it may not hold the lock yet, and a second job would only exit with \"indexing\".  Reads the job
directories, lists no process."
  (let ((dir (drgnx-jobs-dir)))
    (and (file-directory-p dir)
         (cl-some (lambda (id)
                    (let ((jdir (drgnx-jobs--dir id)))
                      (and (not (file-exists-p (expand-file-name "exit" jdir)))
                           (when-let* ((attrs (file-attributes jdir)))
                             (< (float-time (time-since (file-attribute-modification-time attrs)))
                                drgnx-search-index--start-grace))
                           (let ((job (drgnx-jobs--read (expand-file-name "job.eld" jdir))))
                             (and (string-prefix-p "search-index:" (or (plist-get job :name) ""))
                                  (member root (plist-get job :command)))))))
                  (directory-files dir nil "\\`[0-9]")))))

(defun drgnx-search-index-start (root &optional rebuild)
  "Index the project at ROOT in a background job (REBUILD: from scratch); returns the job's id, or nil when an
indexer holds ROOT's lock or a job of ROOT started within the last 30 seconds (nothing starts then).  The finished index jobs of ROOT are removed first, the newest kept.
The job is a batch Emacs of the running version, memory-capped at 1G and niced where the jobs run under systemd.
Never lists the jobs (the re-index timer calls this), but a job of ROOT without an exit file costs a process query
(under systemd a `systemctl' call) while the old jobs are reaped; a command the user runs asks `drgnx-search-index-busy-p' first."
  (let ((root (directory-file-name (expand-file-name root))))
    (unless (or (drgnx-search-index-running-p root) (drgnx-search-index--starting-p root))
      (drgnx-search-index--reap root)
      (drgnx-jobs-start (format "search-index: %s" (file-name-nondirectory root))
                        (append (list (expand-file-name invocation-name invocation-directory)
                                      "--batch" "-Q" "--eval" "(setq load-prefer-newer t)" "-L" drgnx-search-index--core-dir
                                      "-l" "drgnx-search-index" "-f" "drgnx-search-index-cli" root)
                                (and rebuild (list "--rebuild")))
                        :cwd root :memory-max "1G" :nice 10
                        :env (drgnx-search-index--job-env root)))))

(provide 'drgnx-search-index)
;;; drgnx-search-index.el ends here
