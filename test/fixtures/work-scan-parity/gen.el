;;; gen.el --- the oracle of Urdr Task 16: what the schema-6 work scan stored -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Test tooling.  `expected.json' was made with this file on commit d676b6c4 (branch u7-t15b), where
;; `drgnx-work-scan' still wrote work.db itself:
;;   emacs --batch -L <core of that commit> -l test/fixtures/work-scan-parity/gen.el \
;;         --eval '(drgnx-work-parity-generate "test/fixtures/work-scan-parity/expected.json")'
;; It builds the fixture tree (a spec, two plans, a spec a plan names outside specs/, a ledger that marks a task done,
;; a plan whose steps are all done, a linked git worktree with a ledger, the board's TODO, three commits with fixed
;; dates so their SHAs are the same everywhere), scans it, and writes the rows of the `node', `edge' and `file'
;; tables sorted, with the fixture root as $ROOT.  `updated' and the file times are left out (they are the clock's).
;; `work-scan-test.el' builds the same tree and compares what the new scan stores, read through the schema-7 views.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defun drgnx-work-parity--git (dir &rest args)
  "git ARGS in DIR with a fixed identity and clock: its trimmed output."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir))
          (process-environment (append (list "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t.invalid"
                                             "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t.invalid"
                                             "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null")
                                       process-environment)))
      (unless (eql 0 (apply #'call-process "git" nil t nil args)) (error "git %S: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun drgnx-work-parity--write (root file text)
  (let ((f (expand-file-name file root)))
    (make-directory (file-name-directory f) t)
    (write-region text nil f nil 'silent)
    f))

(defun drgnx-work-parity--commit (repo file text msg n)
  "Commit FILE with TEXT as the Nth commit (a fixed date); its short SHA."
  (write-region text nil (expand-file-name file repo) nil 'silent)
  (drgnx-work-parity--git repo "add" "-A")
  (let ((process-environment (append (list (format "GIT_AUTHOR_DATE=2026-01-01T00:00:0%d+0000" n)
                                           (format "GIT_COMMITTER_DATE=2026-01-01T00:00:0%d+0000" n))
                                     process-environment)))
    (drgnx-work-parity--git repo "commit" "-q" "-m" msg))
  (drgnx-work-parity--git repo "rev-parse" "--short" "HEAD"))

(defun drgnx-work-parity-build (root)
  "Build the fixture tree under ROOT (a directory name ending in a slash); the board file."
  (let* ((code (concat root "code/")) c0 c1 c2)
    (make-directory code t)
    (drgnx-work-parity--git code "init" "-q" "-b" "main")
    (write-region ".superpowers/\n.claude/\n" nil (expand-file-name ".gitignore" code) nil 'silent)
    (setq c0 (drgnx-work-parity--commit code "a" "0" "base" 1)
          c1 (drgnx-work-parity--commit code "a" "1" "task one" 2)
          c2 (drgnx-work-parity--commit code "b" "2" "task one, more" 3))
    (ignore c1)
    (drgnx-work-parity--write root "docs/specs/s.md" "# The spec\n")
    (drgnx-work-parity--write root "docs/extra/x.md" "# Named from outside specs\n")
    (drgnx-work-parity--write
     root "docs/plans/p.md"
     (concat "# Plan P\n\n**Spec:** `docs/specs/s.md`\n\n### Task 1: First\n- [x] **Step 1: test**\n- [ ] **Step 2: code**\n\n"
             "### Task 2: Second\n- [ ] one\n\n### Task 3: Third\n- [x] a\n- [x] b\n"))
    (drgnx-work-parity--write
     root "docs/plans/q.md"
     "# Plan Q\n\n**Spec:** `docs/extra/x.md`\n\n### Task 1: Only\n- [ ] s\n")
    (drgnx-work-parity--write
     root "code/.superpowers/sdd/p/progress.md"
     (format "# SDD ledger — plan: %sdocs/plans/p.md\nTask 1: complete (commits %s..%s, tests: ok)\nTask 1: Ruling: keep it small — why — cost\nRuling: general\n"
             root c0 c2))
    ;; a linked worktree on branch feat, with a ledger of its own: the plan gets its worktree and branch
    (drgnx-work-parity--git code "worktree" "add" "-q" "-b" "feat" (concat root "wt"))
    (drgnx-work-parity--write
     root "wt/.superpowers/sdd/q/progress.md"
     (format "# SDD ledger — plan: %sdocs/plans/q.md\nTask 1: complete (commit %s)\n" root c2))
    (drgnx-work-parity--write
     root "org/board.org"
     (format "* code\n:PROPERTIES:\n:PROJECT_ROOT: %s\n:END:\n** DONE one\n:PROPERTIES:\n:ONBOARD_ID: x1\n:PLAN_FILE: docs/plans/p.md\n:PLAN_TEXT: one\n:END:\n** TODO two\n:PROPERTIES:\n:ONBOARD_ID: x2\n:PLAN_FILE: docs/plans/p.md\n:PLAN_TEXT: two\n:END:\n"
             root))
    (concat root "org/board.org")))

(defun drgnx-work-parity--clean (data)
  "DATA (a JSON object as text) as a plist without null, false and empty members, members sorted by name; nil for none."
  (let* ((plist (json-parse-string data :object-type 'plist :null-object nil :false-object nil))
         (pairs nil))
    (cl-loop for (k v) on plist by #'cddr
             unless (or (null v) (equal v "")) do (push (cons (symbol-name k) v) pairs))
    (cl-loop for (k . v) in (sort pairs (lambda (a b) (string< (car a) (car b)))) append (list (intern (concat ":" k)) v))))

(defun drgnx-work-parity-dump (db root)
  "The rows of DB's `node', `edge' and `file' (tables or views), ROOT as $ROOT, as a sorted list of JSON arrays
\(text), each starting with its table: \"n\", \"e\" or \"f\"."
  (let ((rows nil) (root (directory-file-name root)))
    (dolist (r (sqlite-select db "select id, kind, title, path, line, status, parent, ord, source, data from node"))
      (let ((parsed (and (nth 9 r) (drgnx-work-parity--clean (nth 9 r)))))
        (push (json-serialize (vconcat (list "n") (mapcar (lambda (x) (or x :null)) (seq-take r 9)) (list (or parsed :null)))
                              :null-object :null :false-object :false)
              rows)))
    (dolist (r (sqlite-select db "select src, dst, kind, origin, source from edge"))
      (push (json-serialize (vconcat (list "e") (mapcar (lambda (x) (or x :null)) r))) rows))
    (dolist (r (sqlite-select db "select path from file"))
      (push (json-serialize (vconcat (list "f") r)) rows))
    ;; json-serialize gives UTF-8 bytes: decode them, so a file written later is not encoded twice
    (mapcar (lambda (line) (string-replace root "$ROOT" (decode-coding-string line 'utf-8))) (sort rows #'string<))))

(defun drgnx-work-parity-generate (out)
  "Scan the fixture tree with `drgnx-work-scan' (the schema-6 one) and write the dump to OUT."
  (let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-parity" t))))
         (process-environment (append (list (concat "DRGNX_DATA_DIR=" root "data") (concat "DRGNX_CONFIG_DIR=" root "config"))
                                      process-environment)))
    (unwind-protect
        (progn
          (require 'drgnx-work-scan)
          (let ((board (drgnx-work-parity-build root)))
            (drgnx-work-scan (list root) :board board)
            (with-temp-file out
              (setq buffer-file-coding-system 'utf-8-unix)
              (insert "[\n" (mapconcat (lambda (l) (concat "  " l)) (drgnx-work-parity-dump (drgnx-work-db) root) ",\n") "\n]\n"))))
      (drgnx-work-db-close-all)
      (delete-directory root t))))

(provide 'work-scan-parity-gen)
;;; gen.el ends here
