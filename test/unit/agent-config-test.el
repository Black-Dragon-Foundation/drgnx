;;; agent-config-test.el --- batch tests: the agent settings model (homes, JSON files, secrets, skills) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-file)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agent-config)
(load (expand-file-name "test/fixtures/agent-config-fixture" drgnx-dir) nil t)

(defun drgnx-agent-config-test--write (file text &optional modes)
  "Write TEXT to FILE (making its directory), with MODES when given."
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent)
  (when modes (set-file-modes file modes))
  file)

(defun drgnx-agent-config-test--read (file)
  "The text of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest drgnx-agent-config/homes-follow-the-environment ()
  (should (equal drgnx-agent-config-kinds '(claude codex gemini kimi)))
  (should (equal (mapcar #'drgnx-agent-config-title drgnx-agent-config-kinds)
                 '("Claude Code" "Codex" "Gemini" "Kimi Code")))
  (drgnx-agent-config-test-env
    (dolist (kind drgnx-agent-config-kinds)
      (let ((h (drgnx-agent-config-home kind)))
        (should (string-prefix-p drgnx-agent-config-test--dir h))
        (should (string-suffix-p "/" h))))
    (should (equal (drgnx-agent-config-home 'claude) (concat drgnx-agent-config-test--dir "claude/")))
    (should (equal (drgnx-agent-config-home 'codex) (concat drgnx-agent-config-test--dir "codex/")))
    (should (equal (drgnx-agent-config-home 'kimi) (concat drgnx-agent-config-test--dir "kimi/")))
    (should (equal (drgnx-agent-config-home 'gemini) (concat drgnx-agent-config-test--dir "gemini/.gemini/")))
    ;; without the variables: under HOME
    (dolist (var '("CLAUDE_CONFIG_DIR" "CODEX_HOME" "KIMI_CODE_HOME" "GEMINI_CLI_HOME"))
      (setenv var nil))
    (should (equal (drgnx-agent-config-home 'claude) (concat home ".claude/")))
    (should (equal (drgnx-agent-config-home 'codex) (concat home ".codex/")))
    (should (equal (drgnx-agent-config-home 'gemini) (concat home ".gemini/")))
    (should (equal (drgnx-agent-config-home 'kimi) (concat home ".kimi-code/")))
    ;; an empty variable counts as unset
    (setenv "CODEX_HOME" "")
    (should (equal (drgnx-agent-config-home 'codex) (concat home ".codex/")))
    (should-error (drgnx-agent-config-home 'nobody))
    (should-error (drgnx-agent-config-read 'nobody nil))))

(ert-deftest drgnx-agent-config/fixture-has-fake-clis ()
  (drgnx-agent-config-test-env
    (should (equal (executable-find "claude") (expand-file-name "claude" (expand-file-name "bin" drgnx-agent-config-test--dir))))
    (should (null (drgnx-agent-config-test-argv)))
    (should (eql 0 (call-process "codex" nil nil nil "mcp" "list")))
    (should (equal (drgnx-agent-config-test-argv) '("codex mcp list")))))

(ert-deftest drgnx-agent-config/json-round-trip-keeps-order-and-indent ()
  (drgnx-agent-config-test-env
    (let* ((file (expand-file-name "settings.json" home))
           (text "{\n    \"z\": 1,\n    \"a\": {\n        \"deep\": [\n            \"x\",\n            true\n        ],\n        \"none\": null\n    },\n    \"m\": \"é \\\"q\\\"\"\n}\n"))
      (drgnx-agent-config-test--write file text)
      (let* ((read (drgnx-agent-config-json-read file))
             (value (plist-get read :value)))
        (should (= (plist-get read :indent) 4))
        (should (equal (mapcar #'car value) '(z a m)))
        ;; unchanged: the very same bytes
        (drgnx-agent-config-json-write file value 4)
        (should (equal (drgnx-agent-config-test--read file) text))
        ;; one entry changed: the other lines are identical
        (setcdr (assq 'z value) 2)
        (drgnx-agent-config-json-write file value (plist-get read :indent))
        (let ((old (split-string text "\n")) (new (split-string (drgnx-agent-config-test--read file) "\n")))
          (should (= (length old) (length new)))
          (should (equal (cl-loop for o in old for n in new unless (equal o n) collect (cons o n))
                         '(("    \"z\": 1," . "    \"z\": 2,")))))))))

(ert-deftest drgnx-agent-config/json-read-edges ()
  (drgnx-agent-config-test-env
    (let ((file (expand-file-name "x.json" home)))
      (should (equal (drgnx-agent-config-json-read file) '(:value nil :indent 2)))
      (drgnx-agent-config-test--write file "  \n")
      (should (equal (drgnx-agent-config-json-read file) '(:value nil :indent 2)))
      (drgnx-agent-config-test--write file "{\"a\": [], \"b\": {}, \"c\": false, \"d\": null}")
      (should (equal (plist-get (drgnx-agent-config-json-read file) :value)
                     '((a . []) (b) (c . :false) (d . :null))))
      (drgnx-agent-config-test--write file "{\"a\": 1} x")
      (should (equal (cdr (should-error (drgnx-agent-config-json-read file) :type 'drgnx-agent-config-unreadable))
                     (list file 1 "unexpected text after the JSON value")))
      (drgnx-agent-config-test--write file "{\"a\": ")
      (should-error (drgnx-agent-config-json-read file) :type 'drgnx-agent-config-unreadable)
      ;; a value that is not JSON is refused before anything is touched
      (drgnx-agent-config-test--write file "{}\n")
      (should-error (drgnx-agent-config-json-write file '((a . car)) 2))
      (should (equal (drgnx-agent-config-test--read file) "{}\n"))
      (should-not (file-exists-p (concat file ".drgnx-bak"))))))

(ert-deftest drgnx-agent-config/unreadable-json-is-never-written ()
  (drgnx-agent-config-test-env
    (let* ((file (expand-file-name "settings.json" home))
           (text "{\n  \"a\": 1,\n  \"b\": 2,\n}\n"))
      (drgnx-agent-config-test--write file text #o600)
      (set-file-times file (seconds-to-time 1000000000))
      (let ((mtime (file-attribute-modification-time (file-attributes file)))
            (err (should-error (drgnx-agent-config-json-write file '((a . 2)) 2)
                               :type 'drgnx-agent-config-unreadable)))
        (should (equal (nth 0 (cdr err)) file))
        (should (= (nth 1 (cdr err)) 3))
        (should (stringp (nth 2 (cdr err))))
        (should (equal (nth 1 (cdr (should-error (drgnx-agent-config-json-read file)
                                                 :type 'drgnx-agent-config-unreadable)))
                       3))
        (should (equal (drgnx-agent-config-test--read file) text))
        (should (equal (file-attribute-modification-time (file-attributes file)) mtime))
        (should-not (file-exists-p (concat file ".drgnx-bak")))
        (should (equal (directory-files (file-name-directory file) nil "\\`[^.]") '("settings.json")))))))

(ert-deftest drgnx-agent-config/one-backup-next-to-the-file ()
  (drgnx-agent-config-test-env
    (let* ((file (expand-file-name "sub/settings.json" home))
           (bak (concat file ".drgnx-bak")))
      ;; a new file (and its directory): no backup, private modes
      (drgnx-agent-config-json-write file '((n . 1)) 2)
      (should (equal (drgnx-agent-config-test--read file) "{\n  \"n\": 1\n}\n"))
      (should-not (file-exists-p bak))
      (set-file-modes file #o600)
      (drgnx-agent-config-json-write file '((n . 2)) 2)
      (should (equal (drgnx-agent-config-test--read bak) "{\n  \"n\": 1\n}\n"))
      (drgnx-agent-config-json-write file '((n . 3)) 2)
      (should (equal (drgnx-agent-config-test--read bak) "{\n  \"n\": 2\n}\n"))
      (should (equal (drgnx-agent-config-test--read file) "{\n  \"n\": 3\n}\n"))
      (should (= (file-modes file) #o600))
      (should (= (file-modes bak) #o600))
      ;; one backup, no temp files left
      (should (equal (sort (directory-files (file-name-directory file) nil "\\`[^.]") #'string<)
                     '("settings.json" "settings.json.drgnx-bak")))
      (should (equal (directory-files (file-name-directory file) nil "\\`\\.drgnx") nil))
      ;; other modes are kept for the file; the backup (the secrets of before) is for the owner alone, from the start:
      ;; an old backup's wider mode never reaches the new one, not even until the rename
      (set-file-modes file #o640)
      (set-file-modes bak #o644)
      (let ((orig (symbol-function 'rename-file)) (at-rename nil))
        (cl-letf (((symbol-function 'rename-file)
                   (lambda (from to &rest r) (push (cons to (file-modes from)) at-rename) (apply orig from to r))))
          (drgnx-agent-config-json-write file '((n . 4)) 2))
        (should (= (cdr (assoc (file-truename bak) at-rename)) #o600)))
      (should (= (file-modes file) #o640))
      (should (= (file-modes bak) #o600)))))

(ert-deftest drgnx-agent-config/write-text-checks-and-follows-symlinks ()
  (drgnx-agent-config-test-env
    (let* ((real (expand-file-name "real/config.toml" home))
           (link (expand-file-name "config.toml" home)))
      (drgnx-agent-config-test--write real "old\n")
      (make-symbolic-link real link)
      (drgnx-agent-config-write-text link "new\n" #'ignore)
      (should (file-symlink-p link))
      (should (equal (drgnx-agent-config-test--read real) "new\n"))
      (should (equal (drgnx-agent-config-test--read (concat real ".drgnx-bak")) "old\n"))
      ;; a CHECK that signals stops everything; so does a VERIFY of the new text
      (should-error (drgnx-agent-config-write-text link "newer\n" (lambda (_) (error "no"))))
      (should-error (drgnx-agent-config-write-text link "newer\n" #'ignore (lambda (_) (error "bad"))))
      (should (equal (drgnx-agent-config-test--read real) "new\n"))
      (should (equal (drgnx-agent-config-test--read (concat real ".drgnx-bak")) "old\n")))))

(ert-deftest drgnx-agent-config/an-agent-settings-file-keeps-its-symlink-and-mode ()
  (drgnx-agent-config-test-env
    (let* ((real (expand-file-name "dotfiles/settings.json" home))
           (link (expand-file-name "settings.json" home))
           (calls nil)
           (orig (symbol-function 'drgnx-file-write-text)))
      (drgnx-agent-config-test--write real "old\n" #o640)
      (make-symbolic-link real link)
      (cl-letf (((symbol-function 'drgnx-file-write-text)
                 (lambda (file text &rest args) (push file calls) (apply orig file text args))))
        (drgnx-agent-config-write-text link "new\n" #'ignore))
      ;; both the backup and the file go through the file layer
      (should (= (length calls) 2))
      (should (file-symlink-p link))
      (should (equal (drgnx-agent-config-test--read real) "new\n"))
      (should (= (file-modes real) #o640))
      (should (equal (drgnx-agent-config-test--read (concat real ".drgnx-bak")) "old\n"))
      (should (= (file-modes (concat real ".drgnx-bak")) #o600))       ; a backup is the owner's alone
      ;; no temp file is left beside it
      (should (equal (sort (directory-files (file-name-directory real) nil "\\`[^.]\\|\\`\\.[^.]") #'string<)
                     '("settings.json" "settings.json.drgnx-bak")))
      ;; a new file is private, and its folder too
      (let ((fresh (expand-file-name "new/dir/settings.json" home)))
        (drgnx-agent-config-write-text fresh "x\n" #'ignore)
        (should (= (file-modes fresh) #o600))
        (should (= (file-modes (file-name-directory fresh)) #o700))))))

(ert-deftest drgnx-agent-config/a-backup-keeps-the-bytes-of-a-file-that-is-not-utf-8 ()
  (drgnx-agent-config-test-env
    (let ((file (expand-file-name "config.toml" home))
          (bytes (unibyte-string ?a ?\n #xff #xfe ?\r ?\n #xc3 ?\n)))
      (make-directory home t)
      (let ((coding-system-for-write 'no-conversion)) (write-region bytes nil file nil 'silent))
      (drgnx-agent-config-save-backup file)
      (should (equal (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally (concat file ".drgnx-bak"))
                                       (buffer-string))
                     bytes)))))


(ert-deftest drgnx-agent-config/secrets-are-found-and-masked ()
  (let* ((spec '(:type stdio :command "npx" :args ("-y" "srv")
                       :env (("GITHUB_TOKEN" . "ghp_abc123") ("MODE" . "dev") (LEVEL . "verbose"))
                       :headers ((Authorization . "Bearer xyz789") ("X-Short" . "ab"))
                       :oauth ((client_secret . "s3cr3tvalue") (name . "plain") (api_key . "k"))))
         (secrets (drgnx-agent-config-secrets spec)))
    (should (member "ghp_abc123" secrets))
    (should (member "Bearer xyz789" secrets))
    (should (member "xyz789" secrets))
    (should (member "s3cr3tvalue" secrets))
    (should (member "verbose" secrets))
    (should-not (member "ab" secrets))
    (should-not (member "k" secrets))
    (should-not (member "plain" secrets))
    (let ((masked (drgnx-agent-config-mask-text
                   "GITHUB_TOKEN=ghp_abc123 Authorization: Bearer xyz789 x-api: xyz789 ok" secrets)))
      (should (equal masked "GITHUB_TOKEN=•••• Authorization: •••• x-api: •••• ok")))
    (should (equal (drgnx-agent-config-secrets nil) nil))
    (should (equal (drgnx-agent-config-mask-text "nothing" nil) "nothing"))
    ;; a key that matches by name, case-insensitively, outside env and headers
    (should (equal (drgnx-agent-config-secrets '(:url "https://x.invalid" :PassWord "hunter22"))
                   '("hunter22")))))

(ert-deftest drgnx-agent-config/cheap-status-never-runs-anything ()
  (drgnx-agent-config-test-env
    (cl-letf (((symbol-function 'make-process) (lambda (&rest _) (ert-fail "make-process")))
              ((symbol-function 'start-process) (lambda (&rest _) (ert-fail "start-process")))
              ((symbol-function 'call-process) (lambda (&rest _) (ert-fail "call-process")))
              ((symbol-function 'process-file) (lambda (&rest _) (ert-fail "process-file")))
              ((symbol-function 'shell-command-to-string) (lambda (&rest _) (ert-fail "shell"))))
      (let ((mcp (lambda (spec) (list :kind 'claude :section 'mcp :name "s" :spec spec))))
        (should (equal (car (drgnx-agent-config-cheap-status (funcall mcp '(:type stdio :command "no-such-command-xyz"))))
                       'missing-command))
        (should (equal (cdr (drgnx-agent-config-cheap-status (funcall mcp '(:command "no-such-command-xyz"))))
                       "no-such-command-xyz"))
        (should (eq (car (drgnx-agent-config-cheap-status (funcall mcp '(:type stdio :command "claude")))) 'ok))
        (should (eq (car (drgnx-agent-config-cheap-status (funcall mcp (list :command (executable-find "codex"))))) 'ok))
        (should (eq (car (drgnx-agent-config-cheap-status (funcall mcp '(:type http :url "https://x.invalid/mcp")))) 'ok))
        (should (eq (car (drgnx-agent-config-cheap-status (funcall mcp '(:type sse :url "")))) 'no-url))
        (should (eq (car (drgnx-agent-config-cheap-status (funcall mcp '(:type http)))) 'no-url))
        (should (eq (car (drgnx-agent-config-cheap-status (funcall mcp nil))) 'unreadable))
        (should (equal (drgnx-agent-config-cheap-status '(:section mcp :name "s" :problem "bad entry" :spec (:command "claude")))
                       '(unreadable . "bad entry")))
        (should (eq (car (drgnx-agent-config-cheap-status '(:section hook :name "h" :spec (:event "Stop" :command "x")))) 'ok))))))

(ert-deftest drgnx-agent-config/skills-and-new-skill ()
  (drgnx-agent-config-test-env
    (let ((dir (expand-file-name "skills" home)))
      (should (equal (drgnx-agent-config-skills-in dir 'user 'claude) nil))
      (drgnx-agent-config-test--write (expand-file-name "b-plain/SKILL.md" dir)
                                      "---\nname: b-skill\ndescription: Does b things\n---\nBody\n")
      (drgnx-agent-config-test--write (expand-file-name "a-quoted/SKILL.md" dir)
                                      "---\nname: \"a-skill\"\ndescription: 'It''s: a thing'\nother: 1\n---\n")
      (drgnx-agent-config-test--write (expand-file-name "c-folded/SKILL.md" dir)
                                      "---\nname: c-skill\ndescription: >\n  folds over\n  two lines\n---\n")
      (drgnx-agent-config-test--write (expand-file-name "d-bare/SKILL.md" dir) "no front matter\n")
      (make-directory (expand-file-name "e-empty" dir) t)
      (drgnx-agent-config-test--write (expand-file-name ".hidden/SKILL.md" dir) "---\nname: h\n---\n")
      (let ((items (drgnx-agent-config-skills-in dir 'user 'claude)))
        (should (equal (mapcar (lambda (i) (plist-get i :name)) items) '("a-skill" "b-skill" "c-skill" "d-bare")))
        (should (equal (mapcar (lambda (i) (plist-get (plist-get i :spec) :description)) items)
                       '("It's: a thing" "Does b things" "folds over two lines" "")))
        (let ((i (nth 1 items)))
          (should (eq (plist-get i :kind) 'claude))
          (should (eq (plist-get i :section) 'skill))
          (should (eq (plist-get i :from) 'user))
          (should (equal (plist-get i :file) (expand-file-name "b-plain/SKILL.md" dir)))
          (should (equal (plist-get (plist-get i :spec) :dir) (expand-file-name "b-plain" dir)))))
      ;; new-skill
      (let ((file (drgnx-agent-config-new-skill dir "my-skill" "Use when: testing \"quotes\" # here")))
        (should (equal file (expand-file-name "my-skill/SKILL.md" dir)))
        (let ((item (car (cl-remove-if-not (lambda (i) (equal (plist-get i :name) "my-skill"))
                                           (drgnx-agent-config-skills-in dir 'user 'claude)))))
          (should (equal (plist-get (plist-get item :spec) :description) "Use when: testing \"quotes\" # here")))
        (let ((lines (split-string (string-trim-right (drgnx-agent-config-test--read file)) "\n")))
          (should (equal (car lines) "---"))
          (should (equal (nth 1 lines) "name: my-skill"))
          (should (equal (nth 3 lines) "---"))
          (should (= (length lines) 6))))
      (should-error (drgnx-agent-config-new-skill dir "my-skill" "again"))
      (should-error (drgnx-agent-config-new-skill dir "e-empty" "a dir exists"))
      (should-error (drgnx-agent-config-new-skill dir "Bad Name" "x"))
      (should-error (drgnx-agent-config-new-skill dir "../escape" "x"))
      (should-not (file-exists-p (expand-file-name "../escape" dir))))))

;;;; Fix round 1: secrets in args, URLs and commands

(defun drgnx-agent-config-test--secrets-of (&rest spec)
  "The secrets found in the plist SPEC."
  (drgnx-agent-config-secrets spec))

(ert-deftest drgnx-agent-config/secrets-in-flags-and-assignments ()
  (let ((s (drgnx-agent-config-test--secrets-of
            :args '("--api-key=ak12345678" "MY_SECRET=sh12345678" "--mode=fast" "--Password=\"pw 12345\"" "plain"))))
    (should (member "ak12345678" s))
    (should (member "sh12345678" s))
    (should (member "pw 12345" s))
    (should-not (member "fast" s))
    (should-not (member "plain" s))
    (should (= (length s) 3))))

(ert-deftest drgnx-agent-config/secrets-in-the-arg-after-a-secret-flag ()
  (let ((s (drgnx-agent-config-test--secrets-of
            :args '("--api-key" "ak22222222" "--TOKEN" "tk22222222" "-p" "pp22222222" "--port" "9999" "-y" "srv"))))
    (should (equal (sort (copy-sequence s) #'string<) '("ak22222222" "pp22222222" "tk22222222")))))

(ert-deftest drgnx-agent-config/secrets-in-header-and-env-args ()
  (let ((s (drgnx-agent-config-test--secrets-of
            :args '("-H" "Authorization: Bearer hb33333333" "--header" "X-Api-Key: kk33333333"
                    "-H" "Content-Type: json" "--header" "X-Other: Basic bs33333333"
                    "-e" "PLAIN=pv33333333" "--env" "OTHER=ev33333333"))))
    (dolist (v '("hb33333333" "kk33333333" "bs33333333" "pv33333333" "ev33333333" "Bearer hb33333333"))
      (should (member v s)))
    (should-not (member "json" s))
    (should-not (member "Content-Type: json" s))
    (should-not (member "X-Api-Key: kk33333333" s))))

(ert-deftest drgnx-agent-config/secrets-in-schemes-inside-any-arg ()
  (let ((s (drgnx-agent-config-test--secrets-of
            :command "curl -s -H 'Authorization: Bearer cm44444444' -H \"X: Basic dXNlcjpwYXNz\" -H 'Authorization: Digest dg44444444'")))
    (should (member "cm44444444" s))
    (should (member "dXNlcjpwYXNz" s))
    (should (member "Digest dg44444444" s))
    (should-not (member "curl" s))
    (should (equal (drgnx-agent-config-mask-text "curl -H 'Authorization: Bearer cm44444444' -s" s)
                   "curl -H 'Authorization: ••••' -s"))))

(ert-deftest drgnx-agent-config/secrets-in-urls ()
  (let ((s (drgnx-agent-config-test--secrets-of
            :url "https://user:pw55555555@h.invalid/mcp?api_key=qk55555555&x=1&Sig=sg55555555#f")))
    (should (equal (sort (copy-sequence s) #'string<) '("pw55555555" "qk55555555" "sg55555555")))
    (should (equal (drgnx-agent-config-mask-text "https://user:pw55555555@h.invalid/mcp?api_key=qk55555555&x=1" s)
                   "https://user:••••@h.invalid/mcp?api_key=••••&x=1")))
  (let ((s (drgnx-agent-config-test--secrets-of :url "https://h.invalid/mcp?token=t6666666&other=ab&password=p6666666")))
    (should (equal (sort (copy-sequence s) #'string<) '("p6666666" "t6666666"))))
  ;; a URL inside an arg too
  (should (member "aq77777777" (drgnx-agent-config-test--secrets-of :args '("https://h.invalid/x?access-token=aq77777777")))))

(ert-deftest drgnx-agent-config/secrets-by-well-known-prefix ()
  (let* ((fakes (list (concat "sk-" (make-string 20 ?a))
                      (concat "gh" "p_" (make-string 24 ?b))
                      (concat "github_" "pat_" (make-string 20 ?c) "_x")
                      (concat "xo" "xb-" "1234-5678-abcd")
                      (concat "AK" "IA" (make-string 16 ?D))
                      (concat "AI" "za" (make-string 32 ?e))
                      (concat "ey" "J" (make-string 8 ?f) "." (make-string 8 ?g) "." (make-string 8 ?h))))
         (s (drgnx-agent-config-test--secrets-of :command (concat "run " (string-join fakes " and ")))))
    (dolist (f fakes) (should (member f s)))
    (should-not (member "run" s))
    ;; too short to be one
    (should-not (drgnx-agent-config-test--secrets-of :command (concat "sk-" (make-string 5 ?a))))))

(ert-deftest drgnx-agent-config/secrets-in-long-url-path-segments ()
  (let ((s (drgnx-agent-config-test--secrets-of :url "https://h.invalid/hooks/abcdefghijklmnopqrstuvwx1234/run")))
    (should (equal s '("abcdefghijklmnopqrstuvwx1234"))))
  (should-not (drgnx-agent-config-test--secrets-of :url "https://h.invalid/mcp/v1/some-short-name")))

(ert-deftest drgnx-agent-config/secrets-inside-secret-named-containers ()
  (let ((s (drgnx-agent-config-test--secrets-of
            :oauth '((api_keys . ["ak88888888" ("bk88888888") ((deep . "dk88888888"))]) (name . "plain")
                     (secrets . ((a . "sa88888888") (b . ["sb88888888"])))))))
    (dolist (v '("ak88888888" "bk88888888" "dk88888888" "sa88888888" "sb88888888"))
      (should (member v s)))
    (should-not (member "plain" s))))

(ert-deftest drgnx-agent-config/cheap-status-detail-hides-secrets ()
  (let* ((url "https://u:pw99999999@h.invalid/mcp?api_key=qk99999999")
         (detail (cdr (drgnx-agent-config-cheap-status
                       (list :section 'mcp :name "s" :spec (list :type 'http :url url))))))
    (should (string-match-p "h\\.invalid/mcp" detail))
    (should-not (string-match-p "pw99999999\\|qk99999999" detail))))

(ert-deftest drgnx-agent-config/json-errors-never-print-the-data ()
  (drgnx-agent-config-test-env
    (let* ((file (expand-file-name "x.json" home))
           (leak "leak-me-1234")
           (messages
            (mapcar (lambda (value) (error-message-string (should-error (drgnx-agent-config-json-write file value 2))))
                    `(((mcpServers . ((x . ((args . (,leak "b"))))))) ((a . ((b . (,leak . 1)))))
                      ((k . (,(intern leak)))) ((a . ,(intern leak))) ((a . ,(lambda () leak)))))))
      (should (string-match-p "mcpServers\\.x\\.args (a list, expected a vector)" (nth 0 messages)))
      (should (string-match-p "a\\.b" (nth 1 messages)))
      (should (string-match-p "at k" (nth 2 messages)))
      (should (string-match-p "a symbol" (nth 3 messages)))
      (dolist (m messages) (should-not (string-match-p (regexp-quote leak) m)))
      (should-not (file-exists-p file)))))

;;;; Fix round 1: the write path

(ert-deftest drgnx-agent-config/write-text-refuses-a-file-that-changed ()
  (drgnx-agent-config-test-env
    (let ((file (expand-file-name "claude.json" home)))
      (drgnx-agent-config-test--write file "one\n")
      (let ((text (drgnx-agent-config-read-text file))
            (mtime (file-attribute-modification-time (file-attributes file))))
        ;; unchanged: both kinds of expectation pass
        (drgnx-agent-config-write-text file "two\n" #'ignore nil text)
        (should (equal (drgnx-agent-config-test--read file) "two\n"))
        (set-file-times file (seconds-to-time 1000000000))
        (drgnx-agent-config-write-text file "three\n" #'ignore nil (file-attribute-modification-time (file-attributes file)))
        ;; changed meanwhile
        (let ((err (should-error (drgnx-agent-config-write-text file "four\n" #'ignore nil text)
                                 :type 'drgnx-agent-config-changed)))
          (should (equal (cadr err) file)))
        (should-error (drgnx-agent-config-write-text file "four\n" #'ignore nil mtime) :type 'drgnx-agent-config-changed)
        (should (equal (drgnx-agent-config-test--read file) "three\n"))
        (should (equal (drgnx-agent-config-test--read (concat file ".drgnx-bak")) "two\n"))
        ;; the JSON writer passes it on
        (drgnx-agent-config-test--write file "{}\n")
        (should-error (drgnx-agent-config-json-write file '((a . 1)) 2 "{ }\n") :type 'drgnx-agent-config-changed)
        ;; a file that appeared or vanished since
        (should-error (drgnx-agent-config-write-text (expand-file-name "gone.json" home) "x" #'ignore nil "was here")
                      :type 'drgnx-agent-config-changed)))))

(ert-deftest drgnx-agent-config/writing-the-same-text-keeps-the-backup ()
  (drgnx-agent-config-test-env
    (let ((file (expand-file-name "s.json" home)))
      (drgnx-agent-config-json-write file '((n . 1)) 2)
      (drgnx-agent-config-json-write file '((n . 2)) 2)
      (set-file-times file (seconds-to-time 1000000000))
      (let ((mtime (file-attribute-modification-time (file-attributes file))))
        (drgnx-agent-config-json-write file '((n . 2)) 2)
        (should (equal (file-attribute-modification-time (file-attributes file)) mtime))
        (should (equal (drgnx-agent-config-test--read (concat file ".drgnx-bak")) "{\n  \"n\": 1\n}\n"))))))

(ert-deftest drgnx-agent-config/directories-made-for-a-file-are-private ()
  (drgnx-agent-config-test-env
    (let ((file (expand-file-name "a/b/settings.json" home)))
      (drgnx-agent-config-json-write file '((n . 1)) 2)
      (should (= (file-modes (expand-file-name "a" home)) #o700))
      (should (= (file-modes (expand-file-name "a/b" home)) #o700))
      (should (= (file-modes file) #o600))
      ;; a directory that exists keeps its modes
      (set-file-modes (expand-file-name "a" home) #o755)
      (drgnx-agent-config-json-write (expand-file-name "a/c/other.json" home) '((n . 1)) 2)
      (should (= (file-modes (expand-file-name "a" home)) #o755))
      (should (= (file-modes (expand-file-name "a/c" home)) #o700)))))

(ert-deftest drgnx-agent-config/fixture-isolates-xdg-and-keeps-its-names-to-itself ()
  (drgnx-agent-config-test-env
    (dolist (v '("XDG_CONFIG_HOME" "XDG_DATA_HOME" "XDG_STATE_HOME" "XDG_CACHE_HOME"))
      (should (string-prefix-p drgnx-agent-config-test--dir (getenv v))))
    ;; the body may use its own `dir' and `bin'
    (let ((dir "mine") (bin "mine"))
      (should (string-prefix-p drgnx-agent-config-test--dir (executable-find "claude")))
      (should (equal (list dir bin) '("mine" "mine"))))))
