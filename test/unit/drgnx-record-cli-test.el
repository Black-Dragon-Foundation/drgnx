;;; drgnx-record-cli-test.el --- batch tests: bin/drgnx record's stop, lint and export -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Runs are directories made in a temp dir; nothing here reaches the user's recordings or HOME.  The lint is
;; Ratatoskr's (`ratatoskr recording lint'): its test is skipped without DRGNX_RATATOSKR_BIN, the others lint with
;; a stand-in.  Fake keys are built from two parts, so the repository's leak hook never sees a whole one.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-record)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)

(defun drgnx-record-cli-test--put (file text)
  "FILE (made with its directories) holding TEXT."
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent))

(defun drgnx-record-cli-test--run (root &optional provenance)
  "A small run in ROOT/run made under the roots ROOT/state and ROOT/home, with a bundle: its directory."
  (let* ((run (expand-file-name "run" root))
         (state (expand-file-name "state" root))
         (home (expand-file-name "home" root))
         (manifest (format "{\"format\":\"drgnx-recording\",\"version\":1,\"status\":\"incomplete\",\"provenance\":%S,\"started\":\"2026-11-06T10:00:00Z\",\"build\":\"test\",\"roots\":{\"$STATE\":%S,\"$HOME\":%S},\"caps\":{},\"connections\":[{\"n\":1,\"argv\":[\"/srv/builder/proj/target/debug/ratatoskr-mock\",\"acp\"]}]}"
                           (or provenance "mock") state home)))
    (drgnx-record-cli-test--put (expand-file-name "manifest.json" run) manifest)
    (drgnx-record-cli-test--put (expand-file-name "llm.jsonl" run)
                                (format "{\"seq\":1,\"t_ms\":0,\"request\":{\"body\":\"cwd %s/work on 127.0.0.1:41234\"}}\n" home))
    (drgnx-record-cli-test--put (expand-file-name "acp/1.jsonl" run)
                                (format "{\"seq\":2,\"t_ms\":1,\"dir\":\"in\",\"msg\":{\"cwd\":\"%s/work\",\"mcpServers\":[{\"command\":\"/srv/builder/proj/target/debug/ratatoskr\",\"args\":[\"mcp-bridge\",\"--socket\",\"/run/user/1000/drgnx/s/a0123456789ab/mcp.sock\"]}]}}\n" home))
    (drgnx-record-cli-test--put (expand-file-name "effects/1-3/files/hello.txt" run) "hello\n")
    (drgnx-record-cli-test--put (expand-file-name "bundle/work.db" run) "SQLite format 3")
    (drgnx-record-cli-test--put (expand-file-name "bundle/hub-log/hub.jsonl" run) "{}\n")
    (drgnx-record-cli-test--put (expand-file-name "bundle/transcript.json" run) "[]\n")
    run))

(defmacro drgnx-record-cli-test--with-root (&rest body)
  "BODY with ROOT a temp directory, removed at the end, and the lint a stand-in that finds nothing."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-rec" t)))
          (drgnx-record-lint-function (lambda (_dirs) (cons 0 ""))))
     (unwind-protect (progn ,@body)
       (delete-directory root t))))

(ert-deftest drgnx-record-cli/lint-fails-on-a-planted-key-without-printing-it ()
  (skip-unless (drgnx-test-ratatoskr-bin))
  (drgnx-record-cli-test--with-root
    (let* ((process-environment (cons (concat "DRGNX_RATATOSKR_BIN=" (drgnx-test-ratatoskr-bin)) process-environment))
           (drgnx-record-lint-function #'drgnx-record-lint)
           (run (drgnx-record-cli-test--run root))
           (key (concat "sk-or" "-v1-" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")))
      ;; a clean run passes
      (should (eql (car (drgnx-record-lint (list run))) 0))
      (drgnx-record-cli-test--put (expand-file-name "llm.jsonl" run)
                                  (format "{\"seq\":1,\"request\":{\"body\":\"%s\"}}\n" key))
      (let ((r (drgnx-record-lint (list run))))
        (should (eql (car r) 1))
        (should (string-match-p "llm\\.jsonl:[0-9]+: key-prefix" (cdr r)))
        (should (string-match-p "(sk-o…)" (cdr r)))
        ;; the key is not in what it printed, not even the part after its first four characters
        (should-not (string-match-p (regexp-quote (substring key 5 30)) (cdr r)))))))

(ert-deftest drgnx-record-cli/export-never-copies-the-bundle ()
  (drgnx-record-cli-test--with-root
    (let* ((run (drgnx-record-cli-test--run root))
           (to (expand-file-name "fixture" root)))
      (drgnx-record-export run to)
      (should (file-exists-p (expand-file-name "manifest.json" to)))
      (should (file-exists-p (expand-file-name "llm.jsonl" to)))
      (should (file-exists-p (expand-file-name "acp/1.jsonl" to)))
      (should (file-exists-p (expand-file-name "effects/1-3/files/hello.txt" to)))
      (should-not (file-exists-p (expand-file-name "bundle" to)))
      (should-not (directory-files-recursively to "work\\.db\\|hub\\.jsonl"))
      ;; the transcript is a fixture file of its own, beside the manifest
      (should (file-exists-p (expand-file-name "transcript.json" to))))))

(ert-deftest drgnx-record-cli/export-keeps-the-manifests-roots-and-normalizes-the-streams ()
  (drgnx-record-cli-test--with-root
    (let* ((run (drgnx-record-cli-test--run root))
           (to (expand-file-name "fixture" root))
           (home (expand-file-name "home" root)))
      (drgnx-record-export run to)
      (let ((m (drgnx-record--read (expand-file-name "manifest.json" to))))
        (should (equal (alist-get '$HOME (alist-get 'roots m)) home))
        (should (alist-get '$STATE (alist-get 'roots m)))
        (should (equal (aref (alist-get 'argv (aref (alist-get 'connections m) 0)) 0) "$BIN/ratatoskr-mock")))
      (let ((llm (with-temp-buffer (insert-file-contents (expand-file-name "llm.jsonl" to)) (buffer-string)))
            (acp (with-temp-buffer (insert-file-contents (expand-file-name "acp/1.jsonl" to)) (buffer-string))))
        (should (string-match-p "cwd \\$HOME/work on \\$PORT" llm))
        (should (string-match-p "\"cwd\":\"\\$HOME/work\"" acp))
        ;; the build's and the machine's paths are named, not kept: a public fixture names neither
        (should (string-match-p "\"command\":\"\\$BIN/ratatoskr\"" acp))
        (should (string-match-p "\"\\$SOCK/s/a0123456789ab/mcp.sock\"" acp))
        (should-not (string-match-p "/srv/builder\\|/run/user" (concat llm acp)))
        (should-not (string-match-p (regexp-quote root) (concat llm acp)))))))

(ert-deftest drgnx-record-cli/export-refuses-over-256-kib ()
  (drgnx-record-cli-test--with-root
    (let* ((run (drgnx-record-cli-test--run root))
           (to (expand-file-name "fixture" root)))
      (drgnx-record-cli-test--put (expand-file-name "effects/1-9/files/big.txt" run)
                                  (make-string (1+ (* 256 1024)) ?x))
      (let ((err (should-error (drgnx-record-export run to) :type 'user-error)))
        (should (string-match-p "256\\|262144" (cadr err))))
      (should-not (file-exists-p to)))))

(ert-deftest drgnx-record-cli/export-refuses-a-run-the-mocks-did-not-make ()
  (drgnx-record-cli-test--with-root
    (let* ((run (drgnx-record-cli-test--run root "live"))
           (to (expand-file-name "fixture" root)))
      (should-error (drgnx-record-export run to) :type 'user-error)
      (should-not (file-exists-p to)))))

(ert-deftest drgnx-record-cli/export-leaves-nothing-when-the-lint-refuses ()
  (drgnx-record-cli-test--with-root
    (let* ((run (drgnx-record-cli-test--run root))
           (to (expand-file-name "fixture" root))
           (drgnx-record-lint-function (lambda (_dirs) (cons 1 "llm.jsonl:1: key-prefix (sk-o…)\n"))))
      (should-error (drgnx-record-export run to) :type 'user-error)
      (should-not (file-exists-p to)))))

(ert-deftest drgnx-record-cli/stop-ends-the-record-and-writes-the-report ()
  (drgnx-record-cli-test--with-root
    (let ((run (drgnx-record-cli-test--run root)))
      (drgnx-record-cli-test--put (expand-file-name "bundle/run.json" run) "{\"exit\":0}\n")
      (let ((r (drgnx-record-stop run))
            (m (drgnx-record--read (expand-file-name "manifest.json" run))))
        (should (car r))
        (should (equal (alist-get 'status m) "complete"))
        (should (equal (alist-get 'lint m) "pass"))
        (should (stringp (alist-get 'ended m)))
        (should (alist-get 'roots m)))
      (should (string-match-p "gateway exchanges: 1" (with-temp-buffer
                                                       (insert-file-contents (expand-file-name "report.md" run))
                                                       (buffer-string))))
      ;; a test command that failed leaves the run incomplete
      (drgnx-record-cli-test--put (expand-file-name "bundle/run.json" run) "{\"exit\":1}\n")
      (drgnx-record-stop run)
      (should (equal (alist-get 'status (drgnx-record--read (expand-file-name "manifest.json" run))) "incomplete")))))

(ert-deftest drgnx-record-cli/a-failing-lint-fails-the-stop ()
  (drgnx-record-cli-test--with-root
    (let ((run (drgnx-record-cli-test--run root))
          (drgnx-record-lint-function (lambda (_dirs) (cons 1 "llm.jsonl:1: key-prefix (sk-o…)\n"))))
      (let ((r (drgnx-record-stop run)))
        (should-not (car r))
        (should (equal (alist-get 'lint (drgnx-record--read (expand-file-name "manifest.json" run))) "fail"))))))

(ert-deftest drgnx-record-cli/the-fixtures-in-the-repository-are-mock-made-and-lint-clean ()
  (skip-unless (drgnx-test-ratatoskr-bin))
  (let* ((process-environment (cons (concat "DRGNX_RATATOSKR_BIN=" (drgnx-test-ratatoskr-bin)) process-environment))
         (base (expand-file-name "test/fixtures/recordings" drgnx-dir))
         (dirs (and (file-directory-p base) (directory-files base t directory-files-no-dot-files-regexp))))
    (when dirs
      (let ((r (drgnx-record-lint dirs)))
        (should (equal r (cons 0 "")))))))

;;; drgnx-record-cli-test.el ends here
