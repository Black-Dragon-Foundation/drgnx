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

;;;; Fix round 1 (review of C2-3)

(defun drgnx-agents-adapter-test--name-with (root content)
  "The package name read for a maintained-package prefix in ROOT whose package.json holds CONTENT instead."
  (let* ((new (drgnx-agents-adapter-test--prefix root "new" "@agentclientprotocol/claude-agent-acp" "0.93.0"))
         (json (expand-file-name "lib/node_modules/@agentclientprotocol/claude-agent-acp/package.json" new)))
    (write-region content nil json nil 'silent)
    (let ((exec-path (list (drgnx-agents-adapter-test--bin new))))
      (plist-get (drgnx-agents-claude-adapter) :name))))

(ert-deftest drgnx-agents-adapter/a-hostile-package-json-is-an-unknown-package ()
  ;; never read past 64 KiB, never an error: what cannot be read is a program of no known package
  (let ((good "{\"name\": \"@agentclientprotocol/claude-agent-acp\", \"version\": \"0.93.0\", \"x\": \"%s\"}"))
    (dolist (case (list (cons (format good (make-string 60000 ?a)) "@agentclientprotocol/claude-agent-acp")   ; within the limit
                        (cons (format good (make-string 70000 ?a)) nil)                                       ; oversize
                        (cons "{\"name\": " nil) (cons "[1, 2]" nil) (cons "\"x\"" nil) (cons "null" nil) (cons "5" nil)
                        (cons "{\"name\": 5, \"version\": [1]}" nil)))
      (drgnx-agents-adapter-test--with
        (should (equal (drgnx-agents-adapter-test--name-with root (car case)) (cdr case)))))))

(ert-deftest drgnx-agents-adapter/a-link-into-a-package-with-no-package-json-is-unknown ()
  (drgnx-agents-adapter-test--with
    (let ((new (drgnx-agents-adapter-test--prefix root "new" "@agentclientprotocol/claude-agent-acp" "0.93.0")))
      (delete-file (expand-file-name "lib/node_modules/@agentclientprotocol/claude-agent-acp/package.json" new))
      (let* ((exec-path (list (drgnx-agents-adapter-test--bin new))) (a (drgnx-agents-claude-adapter)))
        (should (plist-get a :program))
        (should-not (plist-get a :name))))))

(ert-deftest drgnx-agents-adapter/a-package-json-that-is-a-fifo-is-never-read ()
  ;; `file-readable-p' is true for a FIFO, and reading one waits for a writer forever
  (skip-unless (executable-find "mkfifo"))
  (drgnx-agents-adapter-test--with
    (let* ((new (drgnx-agents-adapter-test--prefix root "new" "@agentclientprotocol/claude-agent-acp" "0.93.0"))
           (json (expand-file-name "lib/node_modules/@agentclientprotocol/claude-agent-acp/package.json" new)))
      (delete-file json)
      (should (eql 0 (call-process "mkfifo" nil nil nil json)))
      (let ((exec-path (list (drgnx-agents-adapter-test--bin new))))
        (should-not (plist-get (drgnx-agents-claude-adapter) :name))))))

(ert-deftest drgnx-agents-adapter/a-prefix-in-home-is-written-for-the-shell-to-expand ()
  (let* ((home (file-name-as-directory (make-temp-file "drgnx adapter home" t)))
         (process-environment (cons (concat "HOME=" home) process-environment))
         (abbreviated-home-dir nil)
         (a (list :program "/x/claude-agent-acp" :name drgnx-agents-claude-old-package :version "0.23.1")))
    (unwind-protect
        (progn
          ;; the prefix is HOME itself: `~', never a quoted `\~' (a directory named ~)
          (should (equal (drgnx-agents--npm-g (plist-put (copy-sequence a) :prefix home) "install" "p")
                         "npm install -g --prefix ~ p"))
          (should (equal (drgnx-agents--npm-g (plist-put (copy-sequence a) :prefix (concat home ".local")) "install" "p")
                         "npm install -g --prefix ~/.local p"))
          (should (equal (drgnx-agents--npm-g (plist-put (copy-sequence a) :prefix (concat home "my npm")) "install" "p")
                         "npm install -g --prefix ~/my\\ npm p"))
          ;; outside HOME, a space is quoted too
          (should (equal (drgnx-agents--npm-g (plist-put (copy-sequence a) :prefix "/opt/my npm") "install" "p")
                         "npm install -g --prefix /opt/my\\ npm p")))
      (delete-directory home t))))

(ert-deftest drgnx-agents-adapter/a-pre-release-version-compares-without-an-error ()
  (let ((a (list :program "/q/bin/claude-agent-acp" :name drgnx-agents-claude-package :prefix "/q")))
    (should-not (drgnx-agents-adapter-problem (plist-put (copy-sequence a) :version "0.93.1-rc.1")))
    (should-not (drgnx-agents-adapter-problem (plist-put (copy-sequence a) :version "0.94.0+build.7")))
    (should (drgnx-agents-adapter-problem (plist-put (copy-sequence a) :version "0.92.0-rc.1")))))

(ert-deftest drgnx-agents-adapter/no-global-npm-prefix-gets-advice-not-an-npm-command ()
  ;; pnpm, volta, a project's node_modules/.bin: drgnx cannot name the prefix, so it gives no npm -g command
  (dolist (a (list (list :program "/w/claude-agent-acp" :name drgnx-agents-claude-old-package :version "0.23.1")
                   (list :program "/w/claude-agent-acp" :name drgnx-agents-claude-package :version "0.50.0")))
    (let ((fix (cdr (drgnx-agents-adapter-problem a))))
      (should-not (string-match-p "\\`npm\\|&& npm" fix))
      (should (string-search "the tool that installed it" fix))
      (should (string-search drgnx-agents-claude-package fix))))
  ;; the same layout found on disk: a pnpm-style store with no lib/ above node_modules
  (drgnx-agents-adapter-test--with
    (let* ((store (expand-file-name "pnpm/global/5/node_modules/@zed-industries/claude-agent-acp/" root))
           (bin (expand-file-name "pnpm/" root)))
      (make-directory (concat store "dist") t)
      (write-region "{\"name\": \"@zed-industries/claude-agent-acp\", \"version\": \"0.23.1\"}" nil (concat store "package.json") nil 'silent)
      (write-region "#!/bin/sh\n" nil (concat store "dist/index.js") nil 'silent)
      (set-file-modes (concat store "dist/index.js") #o755)
      (make-symbolic-link (concat store "dist/index.js") (expand-file-name "claude-agent-acp" bin))
      (let* ((exec-path (list bin)) (a (drgnx-agents-claude-adapter)))
        (should (equal (plist-get a :name) drgnx-agents-claude-old-package))
        (should-not (plist-get a :prefix))
        (should (string-search "the tool that installed it" (cdr (drgnx-agents-adapter-problem a))))))))

(ert-deftest drgnx-agents-adapter/a-copy-beside-both-packages-is-unknown ()
  ;; a copy cannot say which of two packages it came from: drgnx does not guess the maintained one
  (drgnx-agents-adapter-test--with
    (let* ((old (drgnx-agents-adapter-test--prefix root "p" "@zed-industries/claude-agent-acp" "0.23.1" t)))
      (let ((exec-path (list (drgnx-agents-adapter-test--bin old))))
        (should (equal (plist-get (drgnx-agents-claude-adapter) :name) drgnx-agents-claude-old-package)))
      ;; the maintained package's directory is there too, in the same prefix
      (drgnx-agents-adapter-test--prefix root "p" "@agentclientprotocol/claude-agent-acp" "0.93.0" t)
      (let* ((exec-path (list (drgnx-agents-adapter-test--bin old))) (a (drgnx-agents-claude-adapter)))
        (should (plist-get a :program))
        (should-not (plist-get a :name))))))

(ert-deftest drgnx-agents-adapter/the-doctor-names-the-package-and-floor-it-checks ()
  (let ((doc (plist-get (alist-get 'claude-adapter drgnx-doctor--checks) :doc)))
    (should (string-search drgnx-agents-claude-package doc))
    (should (string-search (concat drgnx-agents-claude-min-version " or newer") doc))))

;;; agents-adapter-test.el ends here
