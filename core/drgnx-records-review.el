;;; drgnx-records-review.el --- a project's records kept in step with their files: the notice and conflicts -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub adopts a project's record files (specs, plans, ledgers, decision records, DEFERRED) into the Work graph and
;; keeps them in step both ways: an edit to the file reaches the graph, a change in the graph reaches the file.  When
;; both sides changed the same record, the file keeps its text and the record is flagged (`records-conflict').  Here
;; the hub's events are notices, never prompts (they come down the daemon path): `records-notice' says once which
;; files of a project drgnx now keeps, and `records-conflict' carries the command that resolves the record, Records:
;; Resolve Conflict.  That command shows both versions; `C-c C-f' keeps the file's, `C-c C-g' the graph's
;; (`records/resolve').  See docs/guide/agents.md, "Plans and records".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-notice)
(require 'drgnx-registry)

(declare-function drgnx-hub-call-sync "drgnx-hub-client")
(defvar drgnx-hub--event-conn)

(defvar-local drgnx-records-review--id nil "The id of the conflicted record this buffer shows.")

(defun drgnx-records-review--notice-id (id)
  "The notice id for the conflicted record ID."
  (intern (concat "record-conflict-" id)))

(put 'drgnx-records-review--event 'hub-events-taken '("records-notice" "records-conflict"))

(defun drgnx-records-review--proven-p ()
  "Non-nil when the events come from a hub that proved itself."
  (and (processp (bound-and-true-p drgnx-hub--event-conn))
       (process-get drgnx-hub--event-conn :drgnx-proven)))

(defun drgnx-records-review--event (event data)
  "`drgnx-hub-event-functions': the records' events from a hub that proved itself become notices.  Nothing asks,
nothing waits: a notice carries the command that does."
  (when (drgnx-records-review--proven-p)
    (pcase event
      ("records-notice"
       (let ((files (plist-get data :files)) (root (or (plist-get data :root) "")))
         (drgnx-notify 'hub 'info
                       (format "drgnx keeps %d record file%s of %s in step with the Work graph"
                               (length files) (if (= (length files) 1) "" "s")
                               (file-name-nondirectory (directory-file-name root)))
                       :id (intern (concat "records-adopted-" root))
                       :detail (concat "Edits to the files reach the graph and the graph's changes are written back. "
                                       "A record changed on both sides keeps the file's text until you choose."
                                       (if (plist-get data :backup)
                                           (format " Backed up first to %s." (plist-get data :backup))
                                         "")))))
      ("records-conflict"
       (dolist (id (append (plist-get data :ids) nil))   ; a list or a vector, as the event was read
         (when (stringp id)
           (drgnx-notify 'hub 'warn
                         (format "A record in %s changed in the file and in the graph"
                                 (file-name-nondirectory (or (plist-get data :path) "a record file")))
                         :id (drgnx-records-review--notice-id id) :life 'condition
                         :detail "The file keeps its text; the graph keeps its version until you choose one."
                         :fix "Records: Resolve Conflict"
                         :command (list 'drgnx-records-resolve id))))))))

(defun drgnx-records-review--conflicts ()
  "The ids of the conflicted records, every file's."
  (cl-loop for v in (plist-get (drgnx-hub-call-sync "records/status" nil 10) :views)
           append (append (plist-get v :conflicts) nil)))

(defvar drgnx-records-review-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-f") #'drgnx-records-keep-file)
    (define-key m (kbd "C-c C-g") #'drgnx-records-keep-graph)
    m)
  "Keys of a conflict's buffer.")

(define-derived-mode drgnx-records-review-mode special-mode "Record conflict"
  "A conflicted record, both versions: \\[drgnx-records-keep-file] keeps the file's, \\[drgnx-records-keep-graph]
the graph's.")

;;;###autoload
(defun drgnx-records-resolve (&optional id)
  "Show the conflicted record ID (asked for when nil and several are flagged): the file's text and the graph's."
  (interactive)
  (let* ((open (drgnx-records-review--conflicts))
         (id (or id (pcase open
                      ('nil (user-error "No record is in conflict"))
                      (`(,only) only)
                      (_ (completing-read "Record: " open nil t)))))
         (c (drgnx-hub-call-sync "records/conflict" (list :id id) 10))
         (buffer (get-buffer-create (format "*drgnx conflict: %s*" (file-name-nondirectory (plist-get c :path))))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "In the file" 'face 'bold) "  " (plist-get c :path) "\n\n"
                (plist-get c :file) "\n"
                (propertize "In the graph" 'face 'bold) "\n\n"
                (plist-get c :graph))
        (goto-char (point-min)))
      (drgnx-records-review-mode)
      (setq drgnx-records-review--id id
            header-line-format "Keep one: C-c C-f the file's, C-c C-g the graph's"))
    (pop-to-buffer buffer)))

(defun drgnx-records-review--keep (keep)
  "Keep KEEP (\"file\" or \"graph\") for the record of this buffer; the buffer goes and so does the notice."
  (unless drgnx-records-review--id (user-error "Not a conflict buffer"))
  (let* ((id drgnx-records-review--id)
         (result (drgnx-hub-call-sync "records/resolve" (list :id id :keep keep) 10)))
    (message "Kept the %s's version of %s" keep (file-name-nondirectory (or (plist-get result :path) id)))
    (drgnx-notice-clear 'hub (drgnx-records-review--notice-id id))
    (kill-buffer (current-buffer))
    result))

(defun drgnx-records-keep-file ()
  "Keep the file's text of this conflicted record: it becomes the record's."
  (interactive)
  (drgnx-records-review--keep "file"))

(defun drgnx-records-keep-graph ()
  "Keep the graph's version of this conflicted record: it is written back into the file."
  (interactive)
  (drgnx-records-review--keep "graph"))

(defun drgnx-records-review-register-commands ()
  "The records' commands."
  (drgnx-command-define 'records-resolve-conflict :category "Agents" :title "Records: Resolve Conflict"
                        :command #'drgnx-records-resolve
                        :doc "Show a record changed in its file and in the Work graph, to keep one version")
  (drgnx-command-define 'records-keep-file :category "Agents" :title "Records: Keep the File's Version"
                        :command #'drgnx-records-keep-file
                        :doc "Keep the file's text of the conflicted record shown in this buffer")
  (drgnx-command-define 'records-keep-graph :category "Agents" :title "Records: Keep the Graph's Version"
                        :command #'drgnx-records-keep-graph
                        :doc "Keep the graph's version of the conflicted record shown in this buffer"))

(provide 'drgnx-records-review)
;;; drgnx-records-review.el ends here
