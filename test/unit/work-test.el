;;; work-test.el --- batch tests: the work tracker's store, its counts and the status command -*- lexical-binding: t -*-
;; The records (plans, ledgers, links) are read by the hub's importer (`records/import', tested in Rust); what is
;; tested here is the editor's side: the readers of the store, the counts, and the command line.
;; test-class: cond
(require 'ert)
(require 'drgnx-work)
(require 'drgnx-work-db)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/work-fixture" drgnx-dir) nil t)

(defun drgnx-work-test--git (dir &rest args)
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (eql 0 (apply #'call-process "git" nil t nil "-c" "user.name=t" "-c" "user.email=t@t.invalid" args))
        (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun drgnx-work-test--commit (repo file text msg)
  (write-region text nil (expand-file-name file repo) nil 'silent)
  (drgnx-work-test--git repo "add" "-A")
  (drgnx-work-test--git repo "commit" "-q" "-m" msg)
  (drgnx-work-test--git repo "rev-parse" "--short" "HEAD"))

;;;; The store

(ert-deftest drgnx-work/the-store-keeps-nodes-edges-and-its-version ()
  (let* ((dir (make-temp-file "drgnx-work-db" t))
         (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
         (drgnx-work-db--handles nil))
    (unwind-protect
        (progn
          (drgnx-work-fixture-put-node "plan:a" :kind 'plan :title "A" :path "/a.md" :line 1 :status "open" :source "/a.md")
          (drgnx-work-fixture-put-node "task:a#1" :kind 'task :title "T1" :parent "plan:a" :ord 1 :source "/a.md")
          (drgnx-work-fixture-put-node "task:a#2" :kind 'task :title "T2" :parent "plan:a" :ord 2 :source "/a.md")
          (drgnx-work-fixture-put-edge "commit:abc" "task:a#1" 'implements 'recorded)
          (should (equal (plist-get (drgnx-work-node "plan:a") :title) "A"))
          (should (equal (mapcar (lambda (n) (plist-get n :id)) (drgnx-work-children "plan:a")) '("task:a#1" "task:a#2")))
          (should (equal (drgnx-work-edges-to "task:a#1" 'implements) '(("commit:abc" . recorded))))
          (drgnx-work-fixture-forget-source "/a.md")                               ; a rescan of the file
          (should-not (drgnx-work-node "task:a#1"))
          (should (drgnx-work-edges-to "task:a#1" 'implements))           ; recorded links are kept
          (should (equal (drgnx-work-db-version) drgnx-work-db-schema-version))
          (should (= (caar (sqlite-select (drgnx-work-fixture--db) "pragma busy_timeout")) 5000)))
      (drgnx-work-db-close-all)
      (delete-directory dir t))))

(ert-deftest drgnx-work/a-store-another-process-began-migrating-opens ()
  ;; tables and an index there, no schema row yet: what a second Emacs opening a fresh work.db meets
  (let* ((dir (make-temp-file "drgnx-work-db" t))
         (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
         (drgnx-work-db--handles nil))
    (unwind-protect
        (let ((db (drgnx-work-fixture-as-hub (sqlite-open (drgnx-work-db-file)))))   ; the other process: the hub's stand-in
          (sqlite-execute db "create table meta (key text primary key, value text)")
          (sqlite-execute db "create table node (id text primary key, kind text, title text, path text, line integer,
                            status text, parent text, ord integer, source text, data text, updated real)")
          (sqlite-execute db "create index node_parent on node(parent)")
          (sqlite-close db)
          (should (equal (drgnx-work-db-version) drgnx-work-db-schema-version))
          (drgnx-work-fixture-put-edge "commit:abc" "task:a#1" 'implements 'recorded)
          (should (drgnx-work-edges-to "task:a#1" 'implements)))
      (drgnx-work-db-close-all)
      (delete-directory dir t))))

;;;; Counts

(ert-deftest drgnx-work/commits-recorded-for-a-plan-or-a-todo-are-counted ()
  (let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-work" t))))
         (code (concat root "code/"))
         (process-environment (append (list (concat "DRGNX_DATA_DIR=" root "data") (concat "DRGNX_CONFIG_DIR=" root "config"))
                                      process-environment))
         (drgnx-work-db--handles nil))
    (unwind-protect
        (progn
          (make-directory code t)
          (drgnx-work-test--git code "init" "-q" "-b" "main")
          (drgnx-work-test--commit code "a" "0" "base")
          (drgnx-work-fixture-put-node "plan:/p.md" :kind 'plan :title "P" :path "/p.md" :line 1 :status "open" :source "/p.md")
          (drgnx-work-fixture-put-node "todo:/p.md#1" :kind 'todo :title "T" :parent "plan:/p.md" :ord 1 :source "/p.md")
          (drgnx-work-fixture-with-hub
            (let ((before (plist-get (drgnx-work-counts "plan:/p.md") :commits)))
              (drgnx-work-record "plan:/p.md" code (drgnx-work-test--commit code "x" "x" "for the plan"))
              (drgnx-work-record "todo:/p.md#1" code (drgnx-work-test--commit code "y" "y" "for the todo"))
              (should (= (plist-get (drgnx-work-counts "plan:/p.md") :commits) (+ before 2))))))
      (drgnx-work-db-close-all)
      (delete-directory root t))))

;;;; The command line

(ert-deftest drgnx-work/status-json-non-ascii-title ()
  "`drgnx work status --json' is valid UTF-8 JSON whatever the locale: the title comes out as it went in."
  (let* ((dir (make-temp-file "drgnx-work-db" t))
         (core (file-name-directory (locate-library "drgnx-work")))
         (title "Café → 計画")
         (process-environment (cons (concat "DRGNX_DATA_DIR=" dir) process-environment))
         (drgnx-work-db--handles nil))
    (unwind-protect
        (progn
          (drgnx-work-fixture-put-node "plan:a" :kind 'plan :title title :path "/a.md" :line 1 :status "open" :source "/a.md")
          (drgnx-work-db-close-all)
          (dolist (locale '("C" "C.UTF-8"))
            (let ((process-environment (append (list (concat "LC_ALL=" locale) (concat "LANG=" locale) "LANGUAGE=")
                                               process-environment))
                  (out (generate-new-buffer " *work-status*")))
              (unwind-protect
                  (progn
                    (let ((coding-system-for-read 'no-conversion))
                      (should (eql 0 (call-process (expand-file-name invocation-name invocation-directory) nil out nil
                                                   "--batch" "-Q" "-L" core "-l" "drgnx-work" "-f" "drgnx-work-cli" "--" "status" "--json"))))
                    (let* ((bytes (with-current-buffer out (string-to-unibyte (buffer-string))))
                           (text (decode-coding-string bytes 'utf-8))
                           (rows (json-parse-string text :object-type 'plist)))
                      (should (equal (encode-coding-string text 'utf-8) bytes)) ; valid UTF-8, not re-encoded
                      (should (equal (plist-get (aref rows 0) :title) title))))
                (kill-buffer out)))))
      (drgnx-work-db-close-all)
      (delete-directory dir t))))
