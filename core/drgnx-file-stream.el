;;; drgnx-file-stream.el --- A folder's files, delivered in batches as they are listed -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The files of a local folder, handed to a function batch by batch while the listing still runs, so Quick Open and
;; Find in Explorer show candidates before it ends.  A git repository is listed by `git ls-files -z --cached --others
;; --exclude-standard' through Nidhogg's `records' framing (one NUL-separated name per record); any other local
;; folder by `nidhogg-directory-files-async' (recursive, unsorted).  Both need Nidhogg's workers and the switch
;; `nidhogg-workers-framing' on (`drgnx-file-stream-available-p'); a remote folder never streams (TRAMP processes
;; are not read by the reader, and nh-blk refuses remote names).  The callers keep their synchronous path for those.
;; Names are relative to the folder.  See docs/guide/workbench.md and docs/develop/core.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-guard)

(defvar nidhogg-workers-framing)
(declare-function nidhogg-set-process-framing "nidhogg-io.c" (process framing &rest args))
(declare-function nidhogg-directory-files-async "nidhogg-blk.c" (dir callback &rest args))

(defconst drgnx-file-stream-skip '(".git" ".hg" ".svn" "__pycache__")
  "Folders a listing outside a repository lists but does not descend into.")

(cl-defstruct (drgnx-file-stream (:constructor drgnx-file-stream--make) (:copier nil))
  "A running listing: PROC (the git process, or nil) and STOPPED (non-nil once `drgnx-file-stream-stop' ran)."
  proc stopped)

(defun drgnx-file-stream-available-p (root)
  "Non-nil when the files under ROOT can be streamed: a local folder, Nidhogg's framing there and its switch on."
  (and (not (file-remote-p root))
       (fboundp 'nidhogg-set-process-framing) (fboundp 'nidhogg-directory-files-async)
       (bound-and-true-p nidhogg-workers-framing)))

(defun drgnx-file-stream-record-names (batch)
  "The names in BATCH, a list of (RECORD RAW ERROR) from the records framing; entries with an error are dropped."
  (let (names)
    (dolist (e batch) (when (and (stringp (car e)) (not (nth 2 e)) (not (string-empty-p (car e)))) (push (car e) names)))
    (nreverse names)))

(defun drgnx-file-stream-directory-names (batch)
  "The names of the files in BATCH, a list of (NAME . ATTRIBUTES) from `nidhogg-directory-files-async' (folders left out)."
  (let (names)
    (dolist (e batch) (unless (eq (file-attribute-type (cdr e)) t) (push (car e) names)))
    (nreverse names)))

(defun drgnx-file-stream--git-p (root)
  (and (file-exists-p (expand-file-name ".git" root)) (executable-find "git")))

(defun drgnx-file-stream-start (root on-batch on-done)
  "List the files under ROOT, calling (ON-BATCH NAMES) for each batch and then (ON-DONE OK) once; the stream, or nil
when it cannot stream (see `drgnx-file-stream-available-p'; the caller then lists synchronously).
The callbacks run from the main loop, in order, and never after `drgnx-file-stream-stop'."
  (when (drgnx-file-stream-available-p root)
    (let* ((root (file-name-as-directory (expand-file-name root)))
           (stream (drgnx-file-stream--make))
           (batch (lambda (names) (when (and names (not (drgnx-file-stream-stopped stream))) (funcall on-batch names))))
           (done (lambda (ok) (unless (drgnx-file-stream-stopped stream)
                                (setf (drgnx-file-stream-stopped stream) t)
                                (funcall on-done ok))))
           (default-directory root) failed)
      (if (drgnx-file-stream--git-p root)
          (let* ((err (make-pipe-process :name "drgnx-files-stderr" :noquery t :sentinel #'ignore :filter #'ignore))
                 (proc (make-process
                        :name "drgnx-files" :buffer nil :noquery t :connection-type 'pipe :stderr err
                        :command '("git" "ls-files" "-z" "--cached" "--others" "--exclude-standard")
                        :sentinel (drgnx-guard-wrap
                                   (lambda (p _e)
                                     (when (memq (process-status p) '(exit signal))
                                       (delete-process err)
                                       (funcall done (and (eq (process-status p) 'exit) (= (process-exit-status p) 0)))))
                                   "file listing"))))
            (setf (drgnx-file-stream-proc stream) proc)
            (condition-case nil
                (nidhogg-set-process-framing proc 'records :separator 0 :coding 'utf-8-unix
                                             :batch-function (lambda (_p b) (funcall batch (drgnx-file-stream-record-names b))))
              (error (drgnx-file-stream-stop stream) (setq failed t))))
        (condition-case nil
            (nidhogg-directory-files-async
             root (lambda (b d err)
                    (funcall batch (drgnx-file-stream-directory-names b))
                    (when (or d err) (funcall done (null err))))
             :recursive t :nosort t :skip drgnx-file-stream-skip)
          (error (setf (drgnx-file-stream-stopped stream) t) (setq failed t))))
      (unless failed stream))))

(defun drgnx-file-stream-stop (stream)
  "Stop STREAM (nil is fine): no callback runs after this, and a git process still listing is killed."
  (when stream
    (setf (drgnx-file-stream-stopped stream) t)
    (when-let* ((p (drgnx-file-stream-proc stream))) (when (process-live-p p) (delete-process p)))))

(provide 'drgnx-file-stream)
;;; drgnx-file-stream.el ends here
