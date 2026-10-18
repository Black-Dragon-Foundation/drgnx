;;; agents-adapter-test.el --- batch tests: which Claude Code adapter the claude profiles run -*- lexical-binding: t -*-
;; Fake npm prefixes in a temp directory: package.json files and links only.  No npm, no network, no agent runs.
(require 'ert)
(require 'drgnx-agents)

(defun drgnx-agents-adapter-test--prefix (root name package version &optional copy)
  "A fake npm prefix ROOT/NAME with PACKAGE at VERSION installed globally, as npm lays it out:
lib/node_modules/PACKAGE (package.json, dist/index.js and a nameless dist/package.json, as some packages have) and
bin/claude-agent-acp, a link to dist/index.js (COPY: a copy, as a shim manager makes).  Returns the prefix."
  (let* ((prefix (file-name-as-directory (expand-file-name name root)))
         (pkg (expand-file-name (concat "lib/node_modules/" package "/") prefix))
         (bin (expand-file-name "bin/" prefix)))
    (make-directory (expand-file-name "dist" pkg) t)
    (make-directory bin t)
    (write-region (format "{\"name\": \"%s\", \"version\": \"%s\", \"bin\": {\"claude-agent-acp\": \"dist/index.js\"}}"
                          package version)
                  nil (expand-file-name "package.json" pkg) nil 'silent)
    (write-region "{\"type\": \"module\"}" nil (expand-file-name "dist/package.json" pkg) nil 'silent)
    (write-region "#!/bin/sh\nexit 0\n" nil (expand-file-name "dist/index.js" pkg) nil 'silent)
    (set-file-modes (expand-file-name "dist/index.js" pkg) #o755)
    (if copy
        (copy-file (expand-file-name "dist/index.js" pkg) (expand-file-name "claude-agent-acp" bin) t)
      (make-symbolic-link (concat "../lib/node_modules/" package "/dist/index.js") (expand-file-name "claude-agent-acp" bin)))
    prefix))

(defmacro drgnx-agents-adapter-test--with (&rest body)
  "BODY with ROOT a temp directory for fake prefixes, the once-only message not said yet, and every message
collected in MESSAGES."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-adapter" t)))
          (drgnx-agents--old-adapter-said nil)
          (messages nil))
     (unwind-protect
         (cl-letf (((symbol-function 'message)
                    (lambda (fmt &rest args) (push (apply #'format-message fmt args) messages))))
           ,@body)
       (delete-directory root t))))

(defun drgnx-agents-adapter-test--bin (prefix) (expand-file-name "bin" prefix))

(defun drgnx-agents-adapter-test--fix (prefix)
  "The fix for the deprecated package in PREFIX, as the doctor and the message give it."
  (let ((p (abbreviate-file-name (directory-file-name (file-truename prefix)))))
    (format "npm uninstall -g --prefix %s @zed-industries/claude-agent-acp && npm install -g --prefix %s @agentclientprotocol/claude-agent-acp"
            p p)))

(ert-deftest drgnx-agents-adapter/the-maintained-package-wins-over-the-deprecated-one ()
  (drgnx-agents-adapter-test--with
    (let* ((old (drgnx-agents-adapter-test--prefix root "old" "@zed-industries/claude-agent-acp" "0.23.1"))
           (new (drgnx-agents-adapter-test--prefix root "new" "@agentclientprotocol/claude-agent-acp" "0.93.0"))
           ;; the deprecated one comes first on the path: the maintained one is still chosen
           (exec-path (list (drgnx-agents-adapter-test--bin old) (drgnx-agents-adapter-test--bin new)))
           (a (drgnx-agents-claude-adapter)))
      (should (equal (plist-get a :program) (expand-file-name "claude-agent-acp" (drgnx-agents-adapter-test--bin new))))
      (should (equal (plist-get a :name) "@agentclientprotocol/claude-agent-acp"))
      (should (equal (plist-get a :version) "0.93.0"))
      (should (equal (file-truename (plist-get a :prefix)) (file-truename (directory-file-name new))))
      (should (equal (drgnx-agents-command '("claude-agent-acp" "--flag"))
                     (list (expand-file-name "claude-agent-acp" (drgnx-agents-adapter-test--bin new)) "--flag")))
      (should-not messages)
      (should-not (drgnx-agents-adapter-problem a)))))

(ert-deftest drgnx-agents-adapter/the-deprecated-package-still-runs-and-says-so-once ()
  (drgnx-agents-adapter-test--with
    (let* ((old (drgnx-agents-adapter-test--prefix root "old" "@zed-industries/claude-agent-acp" "0.23.1"))
           (exec-path (list (drgnx-agents-adapter-test--bin old)))
           (program (expand-file-name "claude-agent-acp" (drgnx-agents-adapter-test--bin old))))
      ;; it keeps working: the old program runs, twice — and the message comes once, with the fix
      (should (equal (drgnx-agents-command '("claude-agent-acp")) (list program)))
      (should (equal (drgnx-agents-command '("claude-agent-acp")) (list program)))
      (should (= (length messages) 1))
      (should (string-search "@zed-industries/claude-agent-acp" (car messages)))
      (should (string-search (drgnx-agents-adapter-test--fix old) (car messages)))
      ;; nothing was removed
      (should (file-executable-p program)))))

(ert-deftest drgnx-agents-adapter/an-old-version-of-the-maintained-package-is-a-problem ()
  (drgnx-agents-adapter-test--with
    (let* ((new (drgnx-agents-adapter-test--prefix root "new" "@agentclientprotocol/claude-agent-acp" "0.92.9"))
           (exec-path (list (drgnx-agents-adapter-test--bin new)))
           (a (drgnx-agents-claude-adapter))
           (problem (drgnx-agents-adapter-problem a)))
      (should (string-search "0.92.9" (car problem)))
      (should (string-search "0.93.0" (car problem)))
      (should (equal (cdr problem)
                     (format "npm install -g --prefix %s @agentclientprotocol/claude-agent-acp@latest"
                             (abbreviate-file-name (directory-file-name (file-truename new))))))
      ;; versions compare as versions, not as text
      (should-not (drgnx-agents-adapter-problem (plist-put (copy-sequence a) :version "0.100.0")))
      (should (drgnx-agents-adapter-problem (plist-put (copy-sequence a) :version "not a version"))))))

(ert-deftest drgnx-agents-adapter/a-copy-is-recognised-beside-its-prefix ()
  ;; no link to follow (a copy or a shim): the package is looked for at ../lib/node_modules beside it
  (drgnx-agents-adapter-test--with
    (let* ((new (drgnx-agents-adapter-test--prefix root "new" "@agentclientprotocol/claude-agent-acp" "0.95.1" t))
           (exec-path (list (drgnx-agents-adapter-test--bin new)))
           (a (drgnx-agents-claude-adapter)))
      (should (equal (plist-get a :name) "@agentclientprotocol/claude-agent-acp"))
      (should (equal (plist-get a :version) "0.95.1")))))

(ert-deftest drgnx-agents-adapter/an-adapter-of-no-known-package-is-run-unjudged ()
  (drgnx-agents-adapter-test--with
    (let* ((bin (expand-file-name "bin" root)) (program (expand-file-name "claude-agent-acp" bin)))
      (make-directory bin t)
      (write-region "#!/bin/sh\nexit 0\n" nil program nil 'silent)
      (set-file-modes program #o755)
      (let* ((exec-path (list bin)) (a (drgnx-agents-claude-adapter)))
        (should (equal (plist-get a :program) program))
        (should-not (plist-get a :name))
        (should (equal (drgnx-agents-command '("claude-agent-acp")) (list program)))
        (should-not messages)))))

(ert-deftest drgnx-agents-adapter/other-commands-are-left-alone ()
  (drgnx-agents-adapter-test--with
    (let* ((old (drgnx-agents-adapter-test--prefix root "old" "@zed-industries/claude-agent-acp" "0.23.1"))
           (exec-path (list (drgnx-agents-adapter-test--bin old))))
      (should (equal (drgnx-agents-command '("other-agent" "-x")) '("other-agent" "-x")))
      ;; a path the profile names is the user's choice
      (should (equal (drgnx-agents-command '("/opt/x/claude-agent-acp")) '("/opt/x/claude-agent-acp")))
      (should-not messages))
    ;; none installed: the name stays, and starting it says it is not there
    (let ((exec-path (list root)))
      (should-not (drgnx-agents-claude-adapter))
      (should (equal (drgnx-agents-command '("claude-agent-acp")) '("claude-agent-acp"))))))

(ert-deftest drgnx-agents-adapter/agent-sessions-and-jobs-start-the-chosen-program ()
  ;; job agents start through `drgnx-agents-start' too (drgnx-job--launch-task)
  (drgnx-agents-adapter-test--with
    (let* ((old (drgnx-agents-adapter-test--prefix root "old" "@zed-industries/claude-agent-acp" "0.23.1"))
           (new (drgnx-agents-adapter-test--prefix root "new" "@agentclientprotocol/claude-agent-acp" "0.93.0"))
           (exec-path (list (drgnx-agents-adapter-test--bin old) (drgnx-agents-adapter-test--bin new)))
           (drgnx-agents-profiles nil) (drgnx-agents--sessions nil) (started nil))
      (cl-letf (((symbol-function 'drgnx-acp-start)
                 (lambda (command &rest _) (push command started) (error "not started in this test"))))
        (let ((s (drgnx-agents-start "claude" root)))
          (should (eq (drgnx-agent-session-status s) 'exited))))
      (should (equal started (list (list (expand-file-name "claude-agent-acp" (drgnx-agents-adapter-test--bin new)))))))))


(require 'drgnx-doctor)

(ert-deftest drgnx-agents-adapter/the-doctor-reads-the-package-on-disk ()
  ;; the doctor's fact: the adapter the profiles would run, read from its package.json — never run
  (drgnx-agents-adapter-test--with
    (let* ((old (drgnx-agents-adapter-test--prefix root "old" "@zed-industries/claude-agent-acp" "0.23.1"))
           (exec-path (list (drgnx-agents-adapter-test--bin old)))
           (fact (drgnx-doctor--claude-adapter))
           (r (drgnx-doctor-check 'claude-adapter (list :claude-adapter fact))))
      (should (equal (plist-get fact :name) "@zed-industries/claude-agent-acp"))
      (should (eq (car r) 'warn))
      (should (equal (nth 2 r) (drgnx-agents-adapter-test--fix old)))
      (should-not messages))
    (let ((exec-path (list root)))
      (should-not (drgnx-doctor--claude-adapter)))))

;;; agents-adapter-test.el ends here
