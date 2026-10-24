;;; drgnx-settings-history.el --- Settings: history (reports, journal, undo, timeline) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 25 (design §12): the history of your settings.  The settings files stay the truth; the hub
;; only keeps a record of who changed what.
;; - Every write drgnx makes (`drgnx-settings-file-written-functions') is reported with `settings/record', tool
;;   `ui:settings'; every change of a settings file drgnx did not make (`drgnx-settings-changed-functions' with a
;;   stamp drgnx did not leave) is reported as `file:<name>', or, for a repository's .drgnx/settings.el, sent with
;;   `graph/put-parsed' as the scan does.  `req' is a hash of the file's stamp, so a repeat writes nothing.
;; - A report the hub cannot take (no hub, a lost connection) goes to `<state>/settings-journal.eld' (at most 1 MiB,
;;   oldest dropped) and is sent again when the editor connects.
;; - Once per start `drgnx-settings-history-record-lisp' reports the settings your Lisp (config.el) decides, when
;;   the value differs from the last one reported (tool `lisp:<file>').
;; - `drgnx-settings-undo' and `drgnx-settings-undo-tx' write the previous value back through the settings writer
;;   and report it with `reverts'; a change made by your Lisp is not undone (Open takes you to its line).
;; - `drgnx-settings-history-list' is the data of the timeline.
;; Nothing here prompts; reporting never signals.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-config)
(require 'drgnx-settings-file)

(declare-function drgnx-hub-call "drgnx-hub-client" (method params callback &rest keys))
(declare-function drgnx-hub-call-sync "drgnx-hub-client" (method params &optional timeout))
(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-setting-meta "drgnx-setting" (var))
(declare-function drgnx-secrets-looks-like "drgnx-secrets" (text))
(declare-function drgnx-settings-explain "drgnx-settings-prov" (var &optional buffer))
(declare-function drgnx-settings-prov--managed "drgnx-settings-prov" ())
(declare-function drgnx-settings-workspace-project "drgnx-settings-workspace" (dir))
(declare-function drgnx-settings-workspace-file-p "drgnx-settings-workspace" (file))
(defvar drgnx-settings-changed-functions)
(defvar read-eval)

(defvar drgnx-settings-history-journal-max (* 1024 1024)
  "The most bytes the journal of reports waiting for a hub keeps; the oldest go first.")

(defvar drgnx-settings-history--reverts nil "The tx an undo in progress takes back, or nil.")
(defvar drgnx-settings-history--pending nil
  "While an undo runs: (CHANGES) where its writes collect their changes, so one report is sent; else nil.")
(defvar drgnx-settings-history--ours (make-hash-table :test 'equal)
  "File -> the stamp drgnx left when it last wrote it (and reported it).")
(defvar drgnx-settings-history--lisp-done nil "Non-nil once `drgnx-settings-history-record-lisp' ran this start.")
(defvar drgnx-settings-history--flushing nil "Non-nil while the journal is being sent.")
(defvar drgnx-settings-history--warned nil "Non-nil once the journal's overflow was said; the next flush clears it.")

;;;; Ids and changes

(defun drgnx-settings-history--sanitize (s)
  "S as a project part of an option id: [a-z0-9-]."
  (let ((x (string-trim (replace-regexp-in-string "[^a-z0-9-]+" "-" (downcase s)) "-+" "-+")))
    (if (string-empty-p x) "x" x)))

(defun drgnx-settings-history--global-p (file)
  (equal (expand-file-name file) (expand-file-name (drgnx-config-file 'settings))))

(defun drgnx-settings-history--shared-p (file)
  (string-suffix-p "/.drgnx/settings.el" (expand-file-name file)))

(defun drgnx-settings-history--shared-root (file)
  (file-name-directory (directory-file-name (file-name-directory (expand-file-name file)))))

(defun drgnx-settings-history--project (root)
  "The Urdr project part for ROOT (a folder), or nil when the editor does not know one."
  (when-let* ((p (and (fboundp 'drgnx-settings-workspace-project) (drgnx-settings-workspace-project root)))
              (id (car p)))
    (drgnx-settings-history--sanitize (string-remove-prefix "project:" (format "%s" id)))))

(defun drgnx-settings-history--root-part (root)
  "The project part for a folder with no Urdr project (call 13): root-<first 12 hex of sha256(ROOT's true path)>.
The true path is the truename with no trailing slash, so two clones with the same folder name never share an id."
  (concat "root-" (substring (secure-hash 'sha256 (directory-file-name (file-truename (expand-file-name root))))
                             0 12)))

(defun drgnx-settings-history--scope-id (file doc)
  "FILE's part of an option id: global, private/PROJECT or shared/PROJECT."
  (cond ((drgnx-settings-history--global-p file) "global")
        ((drgnx-settings-history--shared-p file)
         (let ((root (drgnx-settings-history--shared-root file)))
           (concat "shared/" (or (drgnx-settings-history--project root)
                                 (drgnx-settings-history--root-part root)))))
        (t (let ((meta (and doc (drgnx-settings-doc-meta doc))))
             (concat "private/"
                     (or (when-let* ((p (plist-get meta :project)))
                           (drgnx-settings-history--sanitize (string-remove-prefix "project:" (format "%s" p))))
                         (let ((roots (plist-get meta :roots)))
                           (and (proper-list-p roots) (stringp (car roots))
                                (drgnx-settings-history--root-part (car roots))))
                         (drgnx-settings-history--root-part file)))))))

(defun drgnx-settings-history--id (file doc scope var)
  "The option id of VAR in SCOPE (a scope path) of FILE."
  (let ((dir (alist-get :dir scope)) (mode (alist-get :mode scope)))
    (concat "option:" (drgnx-settings-history--scope-id file doc) ":"
            (and dir (format "dir/%s:" dir)) (and mode (format "mode/%s:" mode)) (format "%s" var))))

(defun drgnx-settings-history--option-p (e)
  (let ((v (drgnx-settings-entry-var e))) (and (symbolp v) (not (keywordp v)))))

(defun drgnx-settings-history--find (doc e)
  (and doc (cl-find-if (lambda (x) (and (eq (drgnx-settings-entry-var x) (drgnx-settings-entry-var e))
                                        (equal (drgnx-settings-entry-scope x) (drgnx-settings-entry-scope e))))
                       (drgnx-settings-doc-entries doc))))

(defun drgnx-settings-history--change (file doc e removed)
  "The change plist of entry E of DOC (FILE); REMOVED: it has no value."
  (append (list :id (drgnx-settings-history--id file doc (drgnx-settings-entry-scope e) (drgnx-settings-entry-var e))
                :value (unless removed (drgnx-settings-print (drgnx-settings-entry-value e) 0))
                :file (expand-file-name file))
          (and (not removed) (drgnx-settings-entry-line e) (list :line (drgnx-settings-entry-line e)))))

(defun drgnx-settings-history--diff (file before after)
  "The changes from doc BEFORE to doc AFTER of FILE: change plists (see `--change')."
  (let (out)
    (dolist (e (and after (drgnx-settings-doc-entries after)))
      (when (drgnx-settings-history--option-p e)
        (let ((o (drgnx-settings-history--find before e)))
          (unless (and o (equal (drgnx-settings-entry-value o) (drgnx-settings-entry-value e)))
            (push (drgnx-settings-history--change file after e nil) out)))))
    (dolist (o (and before (drgnx-settings-doc-entries before)))
      (when (and (drgnx-settings-history--option-p o) (not (drgnx-settings-history--find after o)))
        (push (drgnx-settings-history--change file before o t) out)))
    (nreverse out)))

(defun drgnx-settings-history--req (&rest things)
  (substring (secure-hash 'sha256 (let ((print-length nil) (print-level nil)) (prin1-to-string things))) 0 32))

;;;; Sending and the journal

(defun drgnx-settings-history--journal-file () (expand-file-name "settings-journal.eld" (drgnx-state-dir)))

(defun drgnx-settings-history--line (record)
  (let ((print-length nil) (print-level nil) (print-circle nil) (print-escape-newlines t))
    (concat (prin1-to-string record) "\n")))

(defun drgnx-settings-history--journal-read ()
  "The records in the journal, oldest first (a line that does not read is skipped)."
  (let ((file (drgnx-settings-history--journal-file)) out)
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (dolist (line (split-string (buffer-string) "\n" t))
          (when-let* ((r (ignore-errors (let ((read-eval nil)) (car (read-from-string line))))))
            (push r out)))))
    (nreverse out)))

(defun drgnx-settings-history--journal-write (records)
  (let ((file (drgnx-settings-history--journal-file)))
    (if (null records)
        (when (file-exists-p file) (delete-file file))
      (make-directory (file-name-directory file) t)
      (let ((tmp (concat file ".new")))
        (with-temp-file tmp
          (set-buffer-multibyte t) (setq buffer-file-coding-system 'utf-8-unix)
          (dolist (r records) (insert (drgnx-settings-history--line r))))
        (rename-file tmp file t)))))

(defconst drgnx-settings-history--redacted (concat "\"-----BEGIN REDACTED PRIVATE KEY" "-----\"")
  "What the journal keeps for a value that looks like a secret: a printed string the shared secret table's first rule
matches, so the hub, when the journal is sent, records the change as redacted (no value) as it would have.")

(defun drgnx-settings-history--redact-value (v)
  "V (a printed value), or `drgnx-settings-history--redacted' when it looks like a secret (escaped or not)."
  (require 'drgnx-secrets)
  (if (and (stringp v)
           (or (drgnx-secrets-looks-like v)
               (drgnx-secrets-looks-like (string-replace "\\\\" "\\" (string-replace "\\\"" "\"" v)))))
      drgnx-settings-history--redacted
    v))

(defun drgnx-settings-history--redact (record)
  "RECORD, (METHOD PARAMS), with every value that looks like a secret replaced (the changes of `settings/record',
the options' data of `graph/put-parsed'): the journal is plain text in drgnx's state folder."
  (let* ((params (copy-tree (cadr record)))
         (fix (lambda (pl) (if (plist-member pl :value)
                               (plist-put pl :value (drgnx-settings-history--redact-value (plist-get pl :value)))
                             pl))))
    (dolist (c (plist-get params :changes)) (funcall fix c))
    (dolist (s (plist-get params :sources))
      (dolist (e (plist-get s :entities)) (funcall fix (plist-get e :data))))
    (list (car record) params)))

(defun drgnx-settings-history--journal-add (record)
  "Append RECORD, (METHOD PARAMS), to the journal, values that look like secrets redacted
\(`drgnx-settings-history--redact'); past the bound the oldest records go, with one notice."
  (let* ((records (append (drgnx-settings-history--journal-read) (list (drgnx-settings-history--redact record))))
         (size (apply #'+ (mapcar (lambda (r) (string-bytes (drgnx-settings-history--line r))) records)))
         (dropped 0))
    (while (and (cdr records) (> size drgnx-settings-history-journal-max))
      (cl-decf size (string-bytes (drgnx-settings-history--line (car records))))
      (setq records (cdr records) dropped (1+ dropped)))
    (drgnx-settings-history--journal-write records)
    (when (and (> dropped 0) (not drgnx-settings-history--warned))
      (setq drgnx-settings-history--warned t)
      (drgnx-settings-history--say (format "The settings journal is full: the %d oldest records were dropped" dropped)
                                   'settings-journal))))

(defun drgnx-settings-history--say (text id)
  (condition-case nil
      (progn (require 'drgnx-notice) (drgnx-notify 'config 'warn text :id id))
    (error (message "Settings: %s" text))))

(defun drgnx-settings-history--transport-p (err)
  "Non-nil when ERR (a hub call's) says the hub was not reached, so the report is worth sending again."
  (not (and (consp err) (member (plist-get err :code) '("invalid-params" "not-allowed" "invalid-request")))))

(defun drgnx-settings-history--send (method params)
  "Send METHOD with PARAMS to the hub asynchronously; what the hub cannot take goes to the journal.  Never signals."
  (let ((record (list method params)))
    (condition-case nil
        (drgnx-hub-call method params
                        (lambda (_result err)
                          (when (and err (drgnx-settings-history--transport-p err))
                            (ignore-errors (drgnx-settings-history--journal-add record))))
                        :full t)
      (error (ignore-errors (drgnx-settings-history--journal-add record))))))

(defun drgnx-settings-history-flush ()
  "Send the journal's records to the hub and empty it (a record the hub still cannot take comes back to it)."
  (unless drgnx-settings-history--flushing
    (let ((drgnx-settings-history--flushing t)
          (records (ignore-errors (drgnx-settings-history--journal-read))))
      (when records
        (setq drgnx-settings-history--warned nil)
        (ignore-errors (drgnx-settings-history--journal-write nil))
        (dolist (r records) (drgnx-settings-history--send (car r) (cadr r)))))))

(defun drgnx-settings-history--record (tool changes &optional reverts stamp)
  "Report CHANGES (change plists) with TOOL; REVERTS the tx they take back."
  (when changes
    (drgnx-settings-history--send
     "settings/record"
     (append (list :tool tool :req (drgnx-settings-history--req tool changes reverts stamp) :changes changes)
             (and reverts (list :reverts reverts))))))

;;;; What drgnx wrote

(defun drgnx-settings-history--written (file before after)
  "`drgnx-settings-file-written-functions': report the change drgnx made to FILE."
  (puthash file (or (drgnx-file-stamp file) (and after (drgnx-settings-doc-stamp after))) drgnx-settings-history--ours)
  (when-let* ((changes (drgnx-settings-history--diff file before after)))
    (if drgnx-settings-history--pending
        (setcar drgnx-settings-history--pending (append (car drgnx-settings-history--pending) changes))
      (drgnx-settings-history--record drgnx-settings-file-tool changes nil (gethash file drgnx-settings-history--ours)))))

;;;; What changed outside

(defun drgnx-settings-history--put-parsed (file doc)
  "Send repository file FILE (read as DOC) as the scan does: the file, and its shared settings when the project is known."
  (let* ((root (drgnx-settings-history--shared-root file))
         (path (expand-file-name file))
         (mtime (float-time (or (file-attribute-modification-time (file-attributes path)) 0)))
         (project (drgnx-settings-history--project root))
         (options (and project doc
                       (delq nil
                             (mapcar (lambda (e)
                                       (when (drgnx-settings-history--option-p e)
                                         (list :id (drgnx-settings-history--id file doc (drgnx-settings-entry-scope e)
                                                                               (drgnx-settings-entry-var e))
                                               :kind "option"
                                               :data (append (list :value (drgnx-settings-print
                                                                           (drgnx-settings-entry-value e) 0)
                                                                   :file path)
                                                             (and (drgnx-settings-entry-line e)
                                                                  (list :line (drgnx-settings-entry-line e)))))))
                                     (drgnx-settings-doc-entries doc))))))
    (drgnx-settings-history--send
     "graph/put-parsed"
     (list :root (directory-file-name root)
           :sources (list (list :source (list :kind "file" :path path) :mtime mtime
                                :entities (cons (list :id (concat "file:" path) :kind "file" :data (list :path path))
                                                options)))))))

(defun drgnx-settings-history--notify-never (changes)
  "A notice for each change of CHANGES (change plists) to a setting agents may never change."
  (dolist (c changes)
    (let* ((id (plist-get c :id)) (var (and (string-match "\\(?::\\)\\([^:/]+\\)\\'" id) (intern (match-string 1 id)))))
      (when (and var (eq (plist-get (ignore-errors (drgnx-setting-meta var)) :agents) 'never))
        (condition-case nil
            (progn (require 'drgnx-notice)
                   (drgnx-notify 'config 'warn (format "%s changed outside drgnx [Undo]" var)
                                 :id (intern (concat "settings-outside-" (symbol-name var)))
                                 :command (list 'drgnx-settings-undo id)))
          (error nil))))))

(defun drgnx-settings-history--from-changes (file doc changes)
  "Change plists for CHANGES, (SCOPE VAR OLD NEW) as `drgnx-settings-changed-functions' gets them, in FILE (read as DOC)."
  (delq nil
        (mapcar (lambda (c)
                  (pcase-let ((`(,scope ,var ,_old ,new) c))
                    (when (and (symbolp var) (not (keywordp var)))
                      (let ((e (cl-find-if (lambda (x) (and (eq (drgnx-settings-entry-var x) var)
                                                            (equal (drgnx-settings-entry-scope x) scope)))
                                           (drgnx-settings-doc-entries doc))))
                        (append (list :id (drgnx-settings-history--id file doc scope var)
                                      :value (unless (eq new :unset) (drgnx-settings-print new 0))
                                      :file (expand-file-name file))
                                (and e (drgnx-settings-entry-line e) (list :line (drgnx-settings-entry-line e))))))))
                changes)))

(defun drgnx-settings-history--changed (file changes)
  "`drgnx-settings-changed-functions': a change of FILE drgnx did not make is reported."
  (let ((stamp (drgnx-file-stamp file)))
    (unless (equal stamp (gethash file drgnx-settings-history--ours))
      (puthash file stamp drgnx-settings-history--ours)
      (let* ((head (if (drgnx-settings-history--global-p file) 'drgnx-settings 'drgnx-workspace-settings))
             (doc (ignore-errors (drgnx-settings-file-read file head))))
        (cond ((null doc))
              ((drgnx-settings-history--shared-p file) (drgnx-settings-history--put-parsed file doc))
              (t (let ((c (drgnx-settings-history--from-changes file doc changes)))
                   (drgnx-settings-history--record (concat "file:" (file-name-nondirectory file)) c nil stamp)
                   (drgnx-settings-history--notify-never c))))))))

;;;; Your Lisp's effect

(defun drgnx-settings-history--lisp-seen-file () (expand-file-name "settings-lisp-seen.eld" (drgnx-state-dir)))

(defun drgnx-settings-history--lisp-seen ()
  (when (file-readable-p (drgnx-settings-history--lisp-seen-file))
    (ignore-errors (with-temp-buffer
                     (insert-file-contents (drgnx-settings-history--lisp-seen-file))
                     (let ((read-eval nil)) (read (current-buffer)))))))

(defun drgnx-settings-history-record-lisp ()
  "Once per start: report the settings your Lisp decides whose value differs from the last report (`lisp:<file>').
Returns the number of changes sent.  Never signals."
  (unless drgnx-settings-history--lisp-done
    (setq drgnx-settings-history--lisp-done t)
    (condition-case nil
        (let ((seen (drgnx-settings-history--lisp-seen)) (by-file nil) (n 0))
          (dolist (var (drgnx-settings-prov--managed))
            (let* ((x (drgnx-settings-explain var))
                   (printed (and (memq (plist-get x :kind) '(lisp deferred))
                                 (ignore-errors (drgnx-settings-print (plist-get x :value) 0)))))
              (when (and printed (not (equal (secure-hash 'sha256 printed) (cdr (assq var seen)))))
                (let ((file (or (plist-get x :file) "config.el")))
                  (setf (alist-get file by-file nil nil #'equal)
                        (append (alist-get file by-file nil nil #'equal)
                                (list (append (list :id (format "option:global:%s" var) :value printed :file file)
                                              (and (plist-get x :line) (list :line (plist-get x :line)))))))
                  (setf (alist-get var seen) (secure-hash 'sha256 printed))))))   ; a hash: the file is plain text
          (pcase-dolist (`(,file . ,changes) by-file)
            (cl-incf n (length changes))
            (drgnx-settings-history--record (concat "lisp:" (file-name-nondirectory file)) changes))
          (when by-file
            (make-directory (file-name-directory (drgnx-settings-history--lisp-seen-file)) t)
            (with-temp-file (drgnx-settings-history--lisp-seen-file)
              (let ((print-length nil) (print-level nil) (print-escape-newlines t)) (prin1 seen (current-buffer)))))
          n)
      (error nil))))

(defun drgnx-settings-history-connected ()
  "The editor connected to the hub: send the journal, and report your Lisp's effect (once per start)."
  (drgnx-settings-history-flush)
  (drgnx-settings-history-record-lisp))

;;;; The data of the timeline

(defun drgnx-settings-history--list-of (x) (if (vectorp x) (append x nil) x))

(defun drgnx-settings-history--versions (id &optional since)
  "ID's versions from the hub, oldest first: plists (:ver :tx :at :actor :class :tool :session :fields)."
  (drgnx-settings-history--list-of
   (plist-get (drgnx-hub-call-sync "graph/history" (append (list :id id) (and since (list :since since))) 10)
              :versions)))

(defun drgnx-settings-history--data (id tx)
  "The data plist of option ID as of tx TX (nil when it did not exist)."
  (let* ((e (plist-get (drgnx-hub-call-sync "graph/entity" (list :id id :as_of tx) 10) :entity))
         (d (plist-get e :data)))
    (cond ((stringp d) (ignore-errors (json-parse-string d :object-type 'plist :null-object nil :false-object nil)))
          (t d))))

(cl-defun drgnx-settings-history-list (&key name scope agent since)
  "The recorded changes of settings, newest first: plists (:id :ver :tx :at :actor :class :tool :session :fields).
NAME (a variable or a string) narrows to one setting, SCOPE (\"global\", \"private/P\", \"shared/P\"; default global
when NAME is given) to one file's scope, AGENT to the changes whose actor is that agent, SINCE to the txs from that
one.  From the hub's `graph/history'."
  (let* ((scope (or scope (and name "global")))
         (ids (if name
                  (list (format "option:%s:%s" scope name))
                (mapcar #'car
                        (drgnx-settings-history--list-of
                         (plist-get (drgnx-hub-call-sync
                                     "graph/sql"
                                     (list :sql (if scope
                                                    "select id from entity where kind = 'option' and id like ?1 order by id"
                                                  "select id from entity where kind = 'option' order by id")
                                           :params (and scope (list (format "option:%s:%%" scope)))
                                           :rows 1000)
                                     10)
                                    :rows)))))
         out)
    (dolist (id ids)
      (dolist (v (drgnx-settings-history--versions id since))
        (when (or (null agent) (equal (plist-get v :actor) agent))
          (push (append (list :id id) v) out))))
    (sort out (lambda (a b) (> (or (plist-get a :tx) 0) (or (plist-get b :tx) 0))))))

;;;; Undo

(defun drgnx-settings-history-open (file line)
  "Visit FILE at LINE (the notice's Open for a change made by your Lisp)."
  (find-file file)
  (when line (goto-char (point-min)) (forward-line (1- line))))

(defun drgnx-settings-history--parse-id (id)
  "ID as (SCOPE-PART SCOPE-PATH VAR), or nil."
  (when (string-match "\\`option:\\(global\\|private/[^:]+\\|shared/[^:]+\\):\\(?:dir/\\([^:]+/\\):\\)?\\(?:mode/\\([^:/]+\\):\\)?\\(.+\\)\\'" id)
    (list (match-string 1 id)
          (append (and (match-string 2 id) (list (cons :dir (match-string 2 id))))
                  (and (match-string 3 id) (list (cons :mode (intern (match-string 3 id))))))
          (intern (match-string 4 id)))))

(defun drgnx-settings-history--plan (id tx)
  "What undoing ID's change in tx TX (nil: its latest) writes: (ID FILE HEAD SCOPE VAR VALUE-TEXT-or-nil).
Signals a `user-error' for what cannot be undone."
  (let* ((parsed (or (drgnx-settings-history--parse-id id) (user-error "%s is not a setting" id)))
         (versions (drgnx-settings-history--versions id))
         (pos (if tx (cl-position tx versions :key (lambda (v) (plist-get v :tx)))
                (and versions (1- (length versions)))))
         (v (and pos (nth pos versions)))
         (p (and v (> pos 0) (nth (1- pos) versions))))
    (unless v (user-error "No recorded change of %s" id))
    (let* ((cur (drgnx-settings-history--data id (plist-get v :tx)))
           (file (plist-get cur :file)))
      (when (string-prefix-p "lisp:" (or (plist-get v :tool) ""))
        (condition-case nil
            (progn (require 'drgnx-notice)
                   (drgnx-notify 'config 'info (format "%s was set by your Lisp; change it there [Open]" (nth 2 parsed))
                                 :id 'settings-undo-lisp :command (list 'drgnx-settings-history-open file
                                                                        (plist-get cur :line))))
          (error nil))
        (user-error "%s was set by your Lisp; change it there" (nth 2 parsed)))
      (unless file (user-error "The file of %s is not known" id))
      (let ((prev (and p (drgnx-settings-history--data id (plist-get p :tx)))))
        (when (and prev (plist-get prev :redacted))
          (user-error "The earlier value of %s was not kept" (nth 2 parsed)))
        (list id file (if (drgnx-settings-history--global-p file) 'drgnx-settings 'drgnx-workspace-settings)
              (nth 1 parsed) (nth 2 parsed) (plist-get prev :value))))))

(defun drgnx-settings-history--apply (plan)
  (pcase-let ((`(,_id ,file ,head ,scope ,var ,text) plan))
    (if text
        (drgnx-settings-file-put file head scope var (let ((read-eval nil)) (car (read-from-string text))))
      (drgnx-settings-file-remove file head scope var))))

(defun drgnx-settings-history--undo-plans (plans tx)
  "Write PLANS back, and report them as one undo of tx TX (a call per project)."
  (let ((drgnx-settings-history--reverts tx) (drgnx-settings-history--pending (list nil)))
    (unwind-protect (dolist (p plans) (drgnx-settings-history--apply p))
      (let (groups)
        (dolist (c (car drgnx-settings-history--pending))
          (let ((key (and (string-match "\\`option:\\([^:]+\\):" (plist-get c :id)) (match-string 1 (plist-get c :id)))))
            (setf (alist-get key groups nil nil #'equal) (append (alist-get key groups nil nil #'equal) (list c)))))
        (pcase-dolist (`(,_ . ,changes) groups)
          (drgnx-settings-history--record "ui:settings" changes tx))
        (setq drgnx-settings-history--pending nil)))
    t))

(defun drgnx-settings-undo (id)
  "Undo the latest recorded change of option ID: write the previous value back and report it as a revert.
Signals a `user-error' when your Lisp made the change (a notice offers Open at its line)."
  (let* ((versions (drgnx-settings-history--versions id))
         (tx (plist-get (car (last versions)) :tx)))
    (drgnx-settings-history--undo-plans (list (drgnx-settings-history--plan id tx)) tx)))

(defun drgnx-settings-undo-tx (tx)
  "Undo every setting tx TX changed, as one report with `reverts'.  Refuses before writing when one was your Lisp's."
  (let* ((rows (drgnx-settings-history--list-of
                (plist-get (drgnx-hub-call-sync
                            "graph/sql"
                            (list :sql "select distinct e.id from entity e join entity_hist h on h.n = e.n where e.kind = 'option' and h.tx_from = ?1 order by e.id"
                                  :params (list tx))
                            10)
                           :rows)))
         (plans (mapcar (lambda (r) (drgnx-settings-history--plan (car r) tx)) rows)))
    (unless plans (user-error "tx %s changed no setting" tx))
    (drgnx-settings-history--undo-plans plans tx)))

;;;; Hooks

(add-hook 'drgnx-settings-file-written-functions #'drgnx-settings-history--written)
(add-hook 'drgnx-settings-changed-functions #'drgnx-settings-history--changed)

(provide 'drgnx-settings-history)
;;; drgnx-settings-history.el ends here
