;;; work-db-read-test.el --- batch tests: the read-only path to work.db (never migrates, never writes) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-coord)
(load (expand-file-name "test/fixtures/work-fixture" drgnx-dir) nil t)

(defmacro drgnx-work-db-read-test--with (&rest body)
  "BODY with drgnx's data dir a fresh temp dir (`dir'), no database open."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-work-db-read" t)))
          (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
          (drgnx-work-db--handles nil)
          (drgnx-work-db--read-handles nil))
     (unwind-protect (progn ,@body)
       (drgnx-work-db-close-all)
       (delete-directory dir t))))

(defun drgnx-work-db-read-test--hash (file)
  (if (file-exists-p file)
      (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (secure-hash 'sha256 (current-buffer)))
    "none"))

(defun drgnx-work-db-read-test--size (file) (if (file-exists-p file) (file-attribute-size (file-attributes file)) 0))

(defun drgnx-work-db-read-test--newer (dir schema compat)
  "A work.db in DIR that a newer drgnx left: a node, an event, `meta' schema SCHEMA and compat-read COMPAT; closed."
  (drgnx-work-fixture-put-node "plan:p" :kind 'plan :title "P")
  (drgnx-coord-job-create :id "j" :title "J" :plan "p.md" :repo "/r" :tasks '((:n 1 :title "one" :role "implement")))
  (drgnx-coord-job-set "j" :status "stopped")                    ; leaves a `job' event
  (sqlite-execute (drgnx-work-db) "insert or replace into meta values ('schema', ?)" (list (number-to-string schema)))
  (sqlite-execute (drgnx-work-db) "insert or replace into meta values ('compat-read', ?)" (list (number-to-string compat)))
  (sqlite-execute (drgnx-work-db) "pragma wal_checkpoint(truncate)")
  (drgnx-work-db-close-all)
  (ignore dir))

(ert-deftest drgnx-work-db/a-reader-of-a-newer-schema-writes-nothing ()
  (drgnx-work-db-read-test--with
    (drgnx-work-db-read-test--newer dir 9 6)
    (let* ((file (concat dir "work.db")) (wal (concat file "-wal"))
           (main (drgnx-work-db-read-test--hash file)) (wal-size (drgnx-work-db-read-test--size wal)))
      (should (equal (plist-get (drgnx-work-node "plan:p") :title) "P"))
      (should (consp (drgnx-coord-events)))
      (should (= (drgnx-work-db-version) 9))
      (should-error (sqlite-execute (drgnx-work-db-read) "insert or replace into meta values ('x', 'y')"))
      (drgnx-work-db-close-all)
      (should (equal (drgnx-work-db-read-test--hash file) main))
      (should (= (drgnx-work-db-read-test--size wal) wal-size))
      (should-not drgnx-work-db--handles))))

(ert-deftest drgnx-work-db/a-newer-schema-it-cannot-read-is-refused ()
  (drgnx-work-db-read-test--with
    (drgnx-work-db-read-test--newer dir 9 7)
    (let ((err (should-error (drgnx-work-node "plan:p") :type 'drgnx-work-db-too-new)))
      (should (string-match-p "schema 9.*update drgnx" (cadr err))))
    (should-not drgnx-work-db--read-handles)))

(ert-deftest drgnx-work-db/a-read-only-reader-closing-last-never-checkpoints ()
  (drgnx-work-db-read-test--with
    (let* ((file (concat dir "work.db")) (wal (concat file "-wal")))
      (drgnx-work-fixture-put-node "plan:p" :kind 'plan :title "P")
      (let ((main (drgnx-work-db-read-test--hash file)))
        (should (plist-get (drgnx-work-node "plan:p") :title))
        (sqlite-close (alist-get file drgnx-work-db--handles nil nil #'equal)) ; the writer closes first
        (setq drgnx-work-db--handles nil)
        (should (equal (drgnx-work-db-read-test--hash file) main))
        (should (> (drgnx-work-db-read-test--size wal) 0))
        (drgnx-work-db-close-all)                                              ; the reader closes last
        (should (equal (drgnx-work-db-read-test--hash file) main))
        (should (> (drgnx-work-db-read-test--size wal) 0))))))

(ert-deftest drgnx-work-db/read-never-creates ()
  (drgnx-work-db-read-test--with
    (should-not (file-exists-p (concat dir "work.db")))
    (should-not (drgnx-work-node "plan:nothing"))                 ; readers answer empty
    (should-not (drgnx-work-nodes 'plan))
    (should-not (drgnx-work-files))
    (should-not (file-exists-p (concat dir "work.db")))           ; …and nothing was made
    (should-not drgnx-work-db--handles)))

(ert-deftest drgnx-work-db/an-older-schema-is-never-migrated-by-a-reader ()
  (drgnx-work-db-read-test--with
    (let ((db (sqlite-open (concat dir "work.db"))))             ; the schema-5 fixture: below ours
      (sqlite-pragma db "journal_mode = WAL")
      (with-temp-buffer
        (insert-file-contents (expand-file-name "test/fixtures/work-db-5.sql" drgnx-dir))
        (dolist (stmt (split-string (buffer-string) ";\n" t))
          (let ((sql (string-trim (replace-regexp-in-string "^--.*\n" "" stmt))))
            (unless (string-empty-p sql) (sqlite-execute db sql)))))
      (sqlite-close db))
    (let ((before (drgnx-work-db-read-test--hash (concat dir "work.db"))))
      (should-not (drgnx-work-nodes 'plan))
      (drgnx-work-db-close-all)
      (should (equal (drgnx-work-db-read-test--hash (concat dir "work.db")) before))
      (should-not drgnx-work-db--handles))))

(ert-deftest drgnx-work-db/read-accepts-schema-7-by-compat-read ()
  (drgnx-work-db-read-test--with
    (drgnx-work-db-read-test--newer dir 7 6)
    (should (equal (plist-get (drgnx-work-node "plan:p") :title) "P"))
    (should (= (drgnx-work-db-version) 7))))

(ert-deftest drgnx-work-db/the-writers-are-gone ()
  (dolist (f '(drgnx-work-put-node drgnx-work-put-edge drgnx-work-update-node drgnx-work-forget-source
                                   drgnx-work-set-file drgnx-work-drop-file drgnx-work-forget-orphan-commits))
    (should-not (fboundp f)))
  ;; no editor path writes the tracker through the writer handle
  (dolist (file '("core/drgnx-work.el" "core/drgnx-work-scan.el"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name file drgnx-dir))
      (should-not (re-search-forward "(sqlite-execute (drgnx-work-db)" nil t)))))

(ert-deftest drgnx-work-db/a-writer-commit-changes-the-read-handles-stamp ()
  (drgnx-work-db-read-test--with
    (require 'drgnx)
    (load (expand-file-name "modules/tools/drgnx-cockpit" drgnx-dir) nil t)
    (drgnx-work-fixture-put-node "plan:p" :kind 'plan :title "P")
    (dolist (fn '(drgnx-cockpit-edits--store-key drgnx-cockpit--db-key))
      (let ((before (funcall fn)))
        (should (equal (funcall fn) before))
        (drgnx-work-fixture-put-node "plan:q" :kind 'plan :title "Q")
        (should-not (equal (funcall fn) before))))))

;;; The static walk: no read goes through the writer handle

(defconst drgnx-work-db-read-test--files
  '("core/drgnx-work-db.el" "core/drgnx-coord.el" "core/drgnx-cockpit-model.el" "core/drgnx-work.el"
    "modules/tools/drgnx-cockpit.el" "modules/tools/drgnx-cockpit-edits.el" "modules/tools/drgnx-cockpit-feed.el"))

(defun drgnx-work-db-read-test--writer-call-p (x)
  (equal x '(drgnx-work-db)))

(defun drgnx-work-db-read-test--selects-on-writer (form)
  "Whether FORM has a `sqlite-select' on `(drgnx-work-db)', directly or through a variable that a
`let'/`let*'/`when-let*'/`if-let*' binds to it."
  (let (bound found)
    (cl-labels ((walk (x)
                  (when (consp x)
                    (when (memq (car x) '(let let* when-let* if-let* and-let*))
                      (dolist (b (and (listp (cadr x)) (cadr x)))
                        (when (and (consp b) (symbolp (car b)) (drgnx-work-db-read-test--writer-call-p (cadr b)))
                          (push (car b) bound))))
                    (when (and (eq (car x) 'sqlite-select) (consp (cdr x)))
                      (let ((h (cadr x)))
                        (when (or (drgnx-work-db-read-test--writer-call-p h) (and (symbolp h) (memq h bound)))
                          (setq found t))))
                    (while (consp x) (walk (car x)) (setq x (cdr x))))))
      (walk form))
    found))

(defun drgnx-work-db-read-test--offenders (file)
  (let (out)
    (with-temp-buffer
      (insert-file-contents (expand-file-name file drgnx-dir))
      (goto-char (point-min))
      (condition-case nil
          (while t
            (let ((form (read (current-buffer))))
              (when (and (memq (car-safe form) '(defun cl-defun defmacro))
                         (drgnx-work-db-read-test--selects-on-writer form)
                         (not (memq (cadr form) (mapcar #'car drgnx-work-db--writer-reads))))
                (push (cadr form) out))))
        (end-of-file nil)))
    (nreverse out)))

(ert-deftest drgnx-work-db/readers-use-the-read-only-path ()
  (require 'drgnx-work)
  (dolist (entry drgnx-work-db--writer-reads)
    (should (stringp (cdr entry))))
  (dolist (file drgnx-work-db-read-test--files)
    (should (equal (cons file (drgnx-work-db-read-test--offenders file)) (list file)))))

(ert-deftest drgnx-work-db/the-walk-catches-a-let-bound-writer-handle ()
  (should (drgnx-work-db-read-test--selects-on-writer
           '(defun sample () (let ((db (drgnx-work-db))) (sqlite-select db "select 1")))))
  (should (drgnx-work-db-read-test--selects-on-writer
           '(defun sample () (sqlite-select (drgnx-work-db) "select 1"))))
  (should-not (drgnx-work-db-read-test--selects-on-writer
               '(defun sample (db) (sqlite-select db "select 1") (sqlite-select (drgnx-work-db-read) "select 1")))))

(provide 'work-db-read-test)
;;; work-db-read-test.el ends here
