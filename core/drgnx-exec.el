;;; drgnx-exec.el --- The editor's client for the hub's jobs (`exec/*') -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The editor's background work (tree-sitter grammars, mermaid, the browser for agents, local AI servers, onboarding
;; installs, the search indexer) runs as jobs of the hub: a command in a unit of its own that outlives this Emacs, with
;; its log and exit kept by the hub (docs/guide/jobs.md).  This file is the editor's side of it.
;;
;; Everything that can run in a timer or in redisplay is a cache read: `drgnx-exec-get' and `drgnx-exec-list' read what
;; this client keeps from `exec/list' (at `drgnx-exec-sync') and from the hub's `exec-done' events, and never call
;; the hub.  `drgnx-exec-start' and `drgnx-exec-stop' are asynchronous.  `drgnx-exec-log' waits for the hub (5 s at
;; most): commands only.  A job is a plist (:id :name :status :exit :cwd :started :argv) with :status one of `running',
;; `done', `failed', `stopped', `gone', as `drgnx-jobs' gave.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-hub-client)

(defvar drgnx-exec--jobs (make-hash-table :test #'equal)
  "Job id → its plist.  Replaced by each `exec/list' (the hub keeps the newest 200 finished jobs); between lists it
holds the jobs this client started or heard end, trimmed to `drgnx-exec--keep' by `drgnx-exec--trim'.")

(defconst drgnx-exec--keep 400 "The most jobs the cache holds.")

(defvar drgnx-exec--stale nil
  "Non-nil after the hub's connection closed: the next event from the hub (it is back) refreshes the cache.")

(defconst drgnx-exec--log-lines 1000 "Lines an `exec/log' call reads at most (the hub's limit).")

(defun drgnx-exec--status (status exit)
  "The editor's status for the hub's STATUS (a string) and EXIT."
  (pcase status
    ((or "queued" "running") 'running)
    ("done" (if (memq exit '(nil 0)) 'done 'failed))
    ("stopped" 'stopped)
    ("timed-out" 'failed)
    (_ 'gone)))

(defun drgnx-exec--row (json)
  "The job plist of JSON, an `exec/get' result or one row of `exec/list'."
  (let ((exit (plist-get (plist-get json :summary) :exit)))
    (list :id (plist-get json :id) :name (plist-get json :name)
          :status (drgnx-exec--status (plist-get json :status) exit) :exit exit
          :cwd (plist-get json :cwd)
          :started (and (numberp (plist-get json :started))
                        (format-time-string "%FT%T%z" (seconds-to-time (plist-get json :started))))
          :argv (plist-get json :argv))))

(defun drgnx-exec--trim ()
  "Keep the newest `drgnx-exec--keep' finished jobs, and every running one."
  (when (> (hash-table-count drgnx-exec--jobs) drgnx-exec--keep)
    (let (done)
      (maphash (lambda (id job) (unless (eq (plist-get job :status) 'running) (push (cons (plist-get job :started) id) done)))
               drgnx-exec--jobs)
      (dolist (d (nthcdr (/ drgnx-exec--keep 2) (sort done (lambda (a b) (string> (or (car a) "") (or (car b) ""))))))
        (remhash (cdr d) drgnx-exec--jobs)))))

(defun drgnx-exec--put (json)
  "Cache the hub's row JSON; a job that ended stays ended whatever an older answer says.  Returns the plist."
  (let* ((job (drgnx-exec--row json)) (id (plist-get job :id)) (old (gethash id drgnx-exec--jobs)))
    (when id
      (if (and old (not (eq (plist-get old :status) 'running)) (eq (plist-get job :status) 'running))
          old
        (puthash id job drgnx-exec--jobs)
        (drgnx-exec--trim)
        job))))

(defun drgnx-exec--refresh ()
  "Ask the hub for the jobs and make them the cache.  Asynchronous; an error leaves the cache as it is."
  (condition-case nil
      (drgnx-hub-call "exec/list" nil
                      (lambda (r _err)
                        (when r
                          (let ((rows (plist-get r :jobs)) (running nil))
                            ;; what ran here and has not come back in the list yet stays until the next list
                            (maphash (lambda (id job) (when (eq (plist-get job :status) 'running) (push (cons id job) running)))
                                     drgnx-exec--jobs)
                            (clrhash drgnx-exec--jobs)
                            (dolist (cell running) (puthash (car cell) (cdr cell) drgnx-exec--jobs))
                            (dolist (row rows) (let ((job (drgnx-exec--row row))) (puthash (plist-get job :id) job drgnx-exec--jobs)))
                            (drgnx-exec--trim)))))
    (error nil)))

(defun drgnx-exec--fetch (id)
  "Cache job ID from the hub (asynchronous)."
  (condition-case nil
      (drgnx-hub-call "exec/get" (list :id id) (lambda (r _err) (when r (drgnx-exec--put r))))
    (error nil)))

(defun drgnx-exec--event (event data)
  "An event from the hub (`drgnx-hub-event-functions'): a job ended."
  (when drgnx-exec--stale
    (setq drgnx-exec--stale nil)
    (drgnx-exec--refresh))
  (when (equal event "exec-done")
    (let* ((id (plist-get data :id)) (old (gethash id drgnx-exec--jobs)) (exit (plist-get data :exit)))
      (if (null old)
          (drgnx-exec--fetch id)
        (puthash id (append (list :status (drgnx-exec--status (plist-get data :status) exit) :exit exit) old)
                 drgnx-exec--jobs)))))

(defun drgnx-exec--hub-gone ()
  "The hub's connection closed: what the cache says may be old until the hub is back."
  (setq drgnx-exec--stale t))

(defun drgnx-exec-sync ()
  "Keep the job cache current: subscribe to the hub's events and read its list.  Asynchronous; never starts a hub;
safe to call again.  `drgnx-exec-unsync' undoes it."
  (add-hook 'drgnx-hub-event-functions #'drgnx-exec--event)
  (add-hook 'drgnx-hub-disconnect-functions #'drgnx-exec--hub-gone)
  (condition-case nil (drgnx-hub-connect) (error nil))
  (drgnx-exec--refresh))

(defun drgnx-exec-unsync ()
  "Stop following the hub's jobs and forget the cache."
  (remove-hook 'drgnx-hub-event-functions #'drgnx-exec--event)
  (remove-hook 'drgnx-hub-disconnect-functions #'drgnx-exec--hub-gone)
  (setq drgnx-exec--stale nil)
  (clrhash drgnx-exec--jobs))

(defun drgnx-exec--env (env)
  "ENV (\"NAME=value\"…) as the request's `env' list."
  (mapcar (lambda (e)
            (let ((i (string-search "=" e)))
              (list :name (if i (substring e 0 i) e) :value (if i (substring e (1+ i)) ""))))
          env))

(cl-defun drgnx-exec-start (name argv &key cwd env memory-max nice timebox callback)
  "Run ARGV (a list of strings) as the hub's job NAME in CWD (default `default-directory').  Asynchronous: CALLBACK
is called once with (ID ERROR): the job's id, or nil and a text saying why it did not start.  ENV (\"NAME=value\"…) is
added to the job's environment (the hub refuses a name that looks like a key); MEMORY-MAX (\"2G\") caps the job's unit;
NICE (10) runs it that much nicer than the hub; TIMEBOX is its seconds (default 3600).  The job is in the cache
\(`drgnx-exec-get') before CALLBACK runs.  Returns nil."
  (let* ((params (append (list :argv argv :cwd (directory-file-name (expand-file-name (or cwd default-directory)))
                               :name name)
                         (and env (list :env (drgnx-exec--env env)))
                         (and memory-max (list :memory_max memory-max))
                         (and nice (list :nice nice))
                         (and timebox (list :timebox_s (ceiling timebox)))))
         (done (lambda (id why)
                 (when callback
                   (drgnx-guard--call callback "exec start"
                                      (list id (and why (format "the job %s did not start: %s" name why)))))))
         ;; a failure found before the call goes out is told from a timer, so the callback never runs inside this call
         (fail (lambda (why) (run-at-time 0 nil done nil why))))
    (condition-case err
        (drgnx-hub--ensure-running
         (lambda (ensure-err)
           (if ensure-err
               (funcall fail ensure-err)
             (drgnx-hub-call
              "exec/start" params
              (lambda (r why)
                (if (not r)
                    (funcall done nil why)
                  (let ((id (plist-get r :id)))
                    (drgnx-hub-call "exec/get" (list :id id)
                                    (lambda (row _why)
                                      (when row (drgnx-exec--put row))
                                      (funcall done id nil))))))))))
      (error (funcall fail (error-message-string err))))
    nil))

(defun drgnx-exec-get (id)
  "Job ID's plist from the cache, or nil.  Never calls the hub."
  (gethash id drgnx-exec--jobs))

(defun drgnx-exec-list ()
  "The cached jobs, newest first.  Never calls the hub."
  (let (jobs)
    (maphash (lambda (_id job) (push job jobs)) drgnx-exec--jobs)
    (sort jobs (lambda (a b) (string> (or (plist-get a :started) "") (or (plist-get b :started) ""))))))

(defun drgnx-exec-log (id max-bytes)
  "The end of job ID's log: at most MAX-BYTES characters.  Waits for the hub (5 s per call): for commands, never a
timer or a hook."
  (when inhibit-interaction
    (error "`drgnx-exec-log' waits for the hub: call it from a command, not from a timer or a hook"))
  (let ((from 0) (text "") (more t))
    (while more
      (let ((slice (drgnx-hub-call-sync "exec/log" (list :id id :from from :n drgnx-exec--log-lines) 5)))
        (setq text (concat text (mapconcat (lambda (l) (concat l "\n")) (plist-get slice :lines) ""))
              from (plist-get slice :next)
              more (and from t))
        ;; only the end is wanted: what is far before it is dropped as it goes
        (when (> (length text) (* 2 max-bytes)) (setq text (substring text (- (length text) max-bytes))))))
    (if (> (length text) max-bytes) (substring text (- (length text) max-bytes)) text)))

(defun drgnx-exec-stop (id)
  "End job ID, asynchronously.  The cache has its new status when the hub answers."
  (condition-case nil
      (drgnx-hub-call "exec/stop" (list :id id) (lambda (r _err) (when r (drgnx-exec--put r))))
    (error nil))
  nil)

(provide 'drgnx-exec)
;;; drgnx-exec.el ends here
