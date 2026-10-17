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

(defconst drgnx-search-index-default-batch 16 "Chunks per embedding request.")

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
                 (setq taken token))
        (file-already-exists
         (if (drgnx-search-index--lock-live-p file) (setq tries 0) (ignore-errors (delete-file file))))))
    taken))

(defun drgnx-search-index--unlock (root token)
  "Remove ROOT's lock if it still holds TOKEN (a lock taken over meanwhile is another indexer's)."
  (let ((file (drgnx-search-index--lock-file root)))
    (ignore-errors
      (when (equal token (with-temp-buffer (insert-file-contents file) (buffer-string)))
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
        (unless (or (null text) (string-match-p drgnx-search-index--raw-byte-regexp text)) text))
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
one loses its old rows), and :error — a message, or nil.
EMBED (default `drgnx-ai-embed-sync') takes a vector of texts and returns a vector of vectors, setting
`drgnx-ai-embed-last-info' to who answered (provider, model).  BATCH (default 16) chunks go in one request;
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
          ((not (drgnx-search--repo-p root)) (setq failure "not a git project")))
    (if failure (funcall result)
      (if (not (setq token (drgnx-search-index--lock root)))
          (progn (setq failure "indexing") (funcall result))
        (let ((db nil))
          (unwind-protect
              (condition-case err
                  (let* ((known (progn (setq db (drgnx-search-store-open root)) (drgnx-search-store-files db)))
                         (fresh (or rebuild (zerop (hash-table-count known))))
                         (wanted (make-hash-table :test #'equal))
                         todo (buf nil) (retried-halving nil))
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
                               (unless (and (= dims (plist-get meta :dims))
                                            (or (null (plist-get info :provider))
                                                (and (equal (plist-get info :provider) (plist-get meta :provider))
                                                     (equal (plist-get info :model) (plist-get meta :model)))))
                                 (error "the index was built with %s (%s); re-index"
                                        (drgnx-search-index--model-name meta) (plist-get meta :dims))))))
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
                         (flush ()
                           (let* ((now (seq-take buf batch)) (vectors (embed-texts (mapcar (lambda (e) (plist-get (cdr e) :text)) now))))
                             (unless (= (length vectors) (length now))
                               (error "the provider answered %d vectors for %d texts" (length vectors) (length now)))
                             (check-meta vectors)
                             (setq buf (nthcdr (length now) buf))
                             (cl-loop for (file . chunk) in now for vector across vectors
                                      do (push (append (list :vector vector) chunk) (drgnx-search-index--file-done file))
                                      (when (zerop (cl-decf (drgnx-search-index--file-left file)))
                                        (finish file)))))
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
                        (if (> (or (plist-get result :skipped) 0) 0) (format ", %d unreadable files skipped" (plist-get result :skipped)) ""))))
    (if (plist-get result :error)
        (format "search index: error: %s (%s)" (plist-get result :error) counts)
      (format "search index: %s in %.1f s" counts (or (plist-get result :seconds) 0)))))

(defun drgnx-search-index-cli ()
  "Batch entry: `emacs --batch -L core -l drgnx-search-index -f drgnx-search-index-cli ROOT [--rebuild]'.
Prints one summary line; exits 0, or 1 on an error."
  (let* ((args command-line-args-left) (rebuild (member "--rebuild" args)) (root (car (delete "--rebuild" (copy-sequence args)))))
    (setq command-line-args-left nil)
    (if (null root)
        (progn (princ "search index: usage: drgnx-search-index-cli ROOT [--rebuild]\n") (kill-emacs 1))
      (let ((result (drgnx-search-index root :rebuild (and rebuild t))))
        (princ (concat (drgnx-search-index--summary result) "\n"))
        (kill-emacs (if (plist-get result :error) 1 0))))))

(defun drgnx-search-index--running-job (root)
  "The running indexing job for ROOT (a directory name without trailing slash), if any."
  (cl-find-if (lambda (job) (and (eq (plist-get job :status) 'running)
                                 (string-prefix-p "search-index:" (or (plist-get job :name) ""))
                                 (member root (plist-get job :command))))
              (drgnx-jobs-list)))

;; The job is a fresh process: it gets the editor's state directories (so it writes the index and lock the
;; editor reads) and the keys of the embed chain (resolved here, where a key may live in auth-source).

(defun drgnx-search-index--job-env ()
  "\"NAME=value\"… for the indexing job: the XDG and DRGNX_*_DIR variables set here, and for each provider in the
`embed' role with a key, its key variable.  Resolved without prompting.  The values travel in the environment only."
  (append
   (cl-loop for e in process-environment
            when (string-match-p "\\`\\(XDG_\\(STATE\\|CONFIG\\|CACHE\\|DATA\\)_HOME\\|DRGNX_[A-Z0-9_]*_DIR\\)=." e)
            collect e)
   (cl-loop for (id . _) in (drgnx-ai-role 'embed)
            for name = (plist-get (drgnx-ai-provider id) :key-env)
            for key = (and name (drgnx-ai-key id nil))
            when key collect (concat name "=" key))))

(defun drgnx-search-index-start (root &optional rebuild)
  "Index the project at ROOT in a background job (REBUILD: from scratch); returns the job's id.
The job is a batch Emacs of the running version, memory-capped at 1G and niced where the jobs run under systemd.  When a
job for ROOT already runs, nothing starts and that job's id comes back."
  (let ((root (directory-file-name (expand-file-name root))))
    (if-let* ((job (drgnx-search-index--running-job root)))
        (plist-get job :id)
      (drgnx-jobs-start (format "search-index: %s" (file-name-nondirectory root))
                        (append (list (expand-file-name invocation-name invocation-directory)
                                      "--batch" "-Q" "-L" drgnx-search-index--core-dir
                                      "-l" "drgnx-search-index" "-f" "drgnx-search-index-cli" root)
                                (and rebuild (list "--rebuild")))
                        :cwd root :memory-max "1G" :nice 10
                        :env (drgnx-search-index--job-env)))))

(provide 'drgnx-search-index)
;;; drgnx-search-index.el ends here
