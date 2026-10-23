;;; gen.el --- the Lisp oracle for norn's writers (test tooling, not an ERT test) -*- lexical-binding: t -*-
;;
;; Run by hand in the build container, from the repository root (Nidhogg):
;;   emacs --batch -Q -L core -l test/fixtures/coord-parity/gen.el -f drgnx-parity-gen-all
;;   emacs --batch -Q -L core -l test/fixtures/coord-parity/gen.el -f drgnx-parity-gen-schema > test/fixtures/work-db-6.sql
;;
;; For each CASE.input.json {setup: [SQL…], clock: [T…], calls: [{fn, args}…]} it makes a schema-6 work.db in a
;; temporary directory with the real `drgnx-work-db', runs the real Lisp functions in order with `float-time' answering
;; from the case's clock (or, in a call that has "now": T, answering T), and writes CASE.expect.json {results, tables: {event, meta}}, `data' parsed.  Strings of the
;; form "__REP:C:N__" stand for the character C repeated N times (long summaries, big data).  norn's
;; tests/parity.rs replays the same input against the Rust writers and compares.
;; Add a function to `drgnx-parity--call' when a later task adds cases for it.
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-coord)

(defvar drgnx-parity--dir (file-name-directory (or load-file-name buffer-file-name)))

(defun drgnx-parity--expand (v)
  "V with every \"__REP:C:N__\" string expanded."
  (cond ((and (stringp v) (string-match "\\`__REP:\\(.\\):\\([0-9]+\\)__\\'" v))
         (make-string (string-to-number (match-string 2 v)) (string-to-char (match-string 1 v))))
        ((consp v) (cons (drgnx-parity--expand (car v)) (drgnx-parity--expand (cdr v))))
        (t v)))

(defun drgnx-parity--call (fn args)
  "Call the Lisp function named FN with ARGS, a plist; its result (nil for the ones that return nothing useful)."
  (pcase fn
    ((or "drgnx-coord-event-add" "drgnx-coord-event-add-best-effort") (apply (intern fn) args))
    ("drgnx-coord-version" (drgnx-coord-version))
    ("drgnx-coord--bump" (drgnx-coord--tx #'drgnx-coord--bump))
    ("drgnx-coord-set-seen" (drgnx-coord-set-seen (plist-get args :agent) (plist-get args :version)) nil)
    ("drgnx-coord-seen" (drgnx-coord-seen (plist-get args :agent)))
    ("drgnx-coord-note-held" (drgnx-coord-note-held (plist-get args :agent) (plist-get args :held)) nil)
    ("drgnx-coord-held" (drgnx-coord-held (plist-get args :agent)))
    ;; jobs, tasks and leases, decisions, pruning (Task 6)
    ("drgnx-coord-job-create" (apply #'drgnx-coord-job-create args))
    ("drgnx-coord-job-set" (drgnx-coord-job-set (plist-get args :id) :status (plist-get args :status) :data (plist-get args :data)) nil)
    ("drgnx-coord-force-status" (drgnx-coord-force-status (plist-get args :task) (plist-get args :status) (plist-get args :agent)))
    ("drgnx-coord-claim" (drgnx-coord-claim (plist-get args :task) (plist-get args :agent) (plist-get args :seen)))
    ("drgnx-coord-set-status" (drgnx-coord-set-status (plist-get args :task) (plist-get args :agent) (plist-get args :status) (plist-get args :seen)))
    ("drgnx-coord-heartbeat" (drgnx-coord-heartbeat (plist-get args :task) (plist-get args :agent)) nil)
    ("drgnx-coord-renew" (drgnx-coord-renew (plist-get args :agent)) nil)
    ("drgnx-coord-release-stale" (drgnx-coord-release-stale))
    ("drgnx-coord-decide" (apply #'drgnx-coord-decide args))
    ("drgnx-coord-events-prune" (drgnx-coord-events-prune))
    ("drgnx-coord--events-cap"
     (let ((drgnx-coord-event-max-rows (plist-get args :max_rows))) (drgnx-coord--tx #'drgnx-coord--events-cap)))
    ("drgnx-coord-events-prune-daily" (drgnx-coord-events-prune-daily))
    (_ (error "No oracle call for %s" fn))))

(defun drgnx-parity--json (v)
  "V, a Lisp result, as something `json-serialize' takes: a plist becomes an object (keys without the colon), any other
list an array, nil null."
  (cond ((null v) :null)
        ((and (consp v) (keywordp (car v)))
         (let ((h (make-hash-table :test 'equal)))
           (cl-loop for (k val) on v by #'cddr do (puthash (substring (symbol-name k) 1) (drgnx-parity--json val) h))
           h))
        ((consp v) (vconcat (mapcar #'drgnx-parity--json v)))
        (t v)))

(defvar drgnx-parity--now nil "The time `float-time' answers during a call that names one (\"now\" in the case).")

(defun drgnx-parity--table (db table)
  "TABLE's rows in rowid order (`meta' by key), every column."
  (let ((cols (mapcar #'cadr (sqlite-select db (format "pragma table_info(%s)" table)))))
    (drgnx-parity--rows db (format "select %s from %s order by %s" (string-join cols ", ") table
                                   (if (equal table "meta") "key" "rowid"))
                        cols)))

(defun drgnx-parity--rows (db sql cols)
  (vconcat
   (mapcar (lambda (row)
             (let ((h (make-hash-table :test 'equal)))
               (cl-mapc (lambda (c v)
                          (puthash c (cond ((null v) :null)
                                           ((and (equal c "data") (stringp v)) (json-parse-string v))
                                           (t v))
                                   h))
                        cols row)
               h))
           (sqlite-select db sql))))

(defun drgnx-parity--run (file)
  (let* ((case (with-temp-buffer
                 (insert-file-contents file)
                 (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil :false-object nil)))
         (clock (append (plist-get case :clock) nil))
         (dir (make-temp-file "parity" t))
         (orig (symbol-function 'float-time))
         (drgnx-work-db--handles nil)
         (drgnx-work-db--read-handles nil))
    (cl-letf (((symbol-function 'drgnx-data-dir) (lambda () dir))
              ((symbol-function 'float-time)
               (lambda (&optional time)
                 (cond (time (funcall orig time))
                       (drgnx-parity--now)
                       (t (or (pop clock) (error "The clock ran out")))))))
      (let* ((db (drgnx-work-db))
             (results (progn
                        (dolist (sql (plist-get case :setup)) (sqlite-execute db sql))
                        (mapcar (lambda (c)
                                  ;; a call that names "now" sees that time at every `float-time'; others take the clock
                                  (let ((drgnx-parity--now (plist-get c :now)))
                                    (condition-case err
                                        (drgnx-parity--json (drgnx-parity--call (plist-get c :fn)
                                                                                (drgnx-parity--expand (plist-get c :args))))
                                      ;; a refused call: {"signal": MESSAGE}
                                      (error (let ((h (make-hash-table :test 'equal)))
                                               (puthash "signal" (error-message-string err) h)
                                               h)))))
                                (plist-get case :calls))))
             (tables (make-hash-table :test 'equal)))
        ;; the tables a case names ("tables"), `event' and `meta' otherwise
        (dolist (table (or (plist-get case :tables) '("event" "meta")))
          (puthash table (drgnx-parity--table db table) tables))
        (let ((out (make-hash-table :test 'equal)))
          (puthash "results" (vconcat results) out)
          (puthash "tables" tables out)
          (with-temp-file (concat (string-remove-suffix ".input.json" file) ".expect.json")
            (insert (json-serialize out) "\n")))))
    (drgnx-work-db-close-all)
    (delete-directory dir t)))

(defun drgnx-parity-gen-all ()
  (dolist (f (directory-files drgnx-parity--dir t "\\.input\\.json\\'"))
    (message "parity: %s" (file-name-nondirectory f))
    (drgnx-parity--run f)))

(defun drgnx-parity-gen-schema ()
  "Print the schema-6 DDL and the meta rows of a freshly made work.db."
  (let* ((dir (make-temp-file "parity" t)) (drgnx-work-db--handles nil))
    (cl-letf (((symbol-function 'drgnx-data-dir) (lambda () dir)))
      (let ((db (drgnx-work-db)))
        (princ "-- work.db schema 6, as core/drgnx-work-db.el's migration leaves it (docs/develop/coordination.md).\n")
        (princ "-- Generated by test/fixtures/coord-parity/gen.el (`drgnx-parity-gen-schema'); the Rust tests build\n")
        (princ "-- every database from this file.\n")
        (dolist (r (sqlite-select db "select sql from sqlite_master where sql is not null and name not like 'sqlite_%' order by name"))
          (princ (format "%s;\n" (car r))))
        (dolist (r (sqlite-select db "select key, value from meta order by key"))
          (princ (format "insert into meta values ('%s', '%s');\n" (car r) (cadr r))))))
    (drgnx-work-db-close-all)
    (delete-directory dir t)))
