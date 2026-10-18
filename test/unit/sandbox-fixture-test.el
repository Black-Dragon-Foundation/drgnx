;;; sandbox-fixture-test.el --- batch tests: the mock agent's probes and the sandbox fixture -*- lexical-binding: t -*-
;; The probes are real only if every one of them reaches its target when nothing stands in the way: the mock agent
;; runs here with no sandbox, against the fixture (test/fixtures/sandbox-fixture.el), and each probe must say
;; "reached" and leave its trace (a listener's connection, a settled card, a deleted object).  The sandbox's own
;; tests (escape tests) then read the same lines as "blocked".  Everything lives in the test's temporary directory.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require (quote drgnx-agents))
(require (quote drgnx-paths))
(load (expand-file-name "test/fixtures/sandbox-fixture" drgnx-dir) nil t)

(defconst drgnx-sandbox-fixture-test--probes
  '("hub-socket" "hub-card" "hub-card-no-hello" "work-db" "coord-forged" "git-config" "git-hooks" "git-ref-main"
    "git-ref-job" "git-pointer" "git-objects-delete" "dot-env" "dirty-file" "emacs-server" "bus" "ssh-agent"
    "abstract-socket" "host-loopback" "ssh-key" "other-repo" "other-task" "env" "nested-git" "fsmonitor-plant")
  "Every probe that takes no argument.")

(defun drgnx-sandbox-fixture-test--wait (pred &optional secs)
  (let ((deadline (+ (float-time) (or secs 60))) v)
    (while (and (not (setq v (funcall pred))) (< (float-time) deadline)) (accept-process-output nil 0.05))
    v))

(defun drgnx-sandbox-fixture-test--ask (prompt)
  "The mock agent's answer to PROMPT, run with the fixture's probe environment and no sandbox."
  (let* ((drgnx-agents-profiles (list (drgnx-sandbox-fixture-mock-profile)))
         (drgnx-agents--sessions nil) (drgnx-agents-env-functions nil)
         (s (drgnx-agents-start "mock" drgnx-sandbox-fixture-folder)))
    (unwind-protect
        (progn
          (should (drgnx-sandbox-fixture-test--wait (lambda () (eq (drgnx-agent-session-status s) 'idle))))
          (let ((before (length (drgnx-agent-session-entries s))))
            (drgnx-agents-send s prompt)
            (should (drgnx-sandbox-fixture-test--wait
                     (lambda () (seq-some (lambda (e) (eq (plist-get e :type) 'agent)) (nthcdr before (drgnx-agent-session-entries s))))))
            (string-join (mapcar (lambda (e) (plist-get e :text))
                                 (seq-filter (lambda (e) (eq (plist-get e :type) 'agent)) (drgnx-agent-session-entries s)))
                         "")))
      (drgnx-agents-kill s))))

(ert-deftest drgnx-sandbox-fixture/probes-report-reached-when-unsandboxed ()
  (drgnx-sandbox-fixture-with
    :unsandboxed
    (let* ((text (drgnx-sandbox-fixture-test--ask
                  (concat "probe " (string-join drgnx-sandbox-fixture-test--probes " ")
                          " connect " drgnx-sandbox-fixture-loopback " connect 127.0.0.1:1")))
           (lines (split-string text "\n" t))
           (names (append drgnx-sandbox-fixture-test--probes '("connect" "connect"))))
      ;; one line per name, in order; the dead port is blocked and says why, all the others are reached
      (should (= (length lines) (length names)))
      (cl-loop for line in lines for name in names for i from 1
               do (ert-info (line)
                    (if (= i (length names))
                        (should (string-match-p (format "\\`probe %s: blocked (.+)\\'" name) line))
                      (should (string-match-p (format "\\`probe %s: reached\\(?: (.*)\\)?\\'" name) line)))))
      ;; and each left its trace
      (let ((c (drgnx-sandbox-fixture-connections)))
        (dolist (name '("emacs-server" "bus" "ssh-agent" "abstract"))
          (ert-info (name) (should (= 1 (cdr (assoc name c))))))
        (should (>= (cdr (assoc "loopback" c)) 2)))                        ; host-loopback, and connect without a proxy
      (dolist (card (list (car drgnx-sandbox-fixture-cards) (cdr drgnx-sandbox-fixture-cards)))
        (should-not (equal (plist-get (drgnx-coord-card card) :state) "open")))
      (should-not (cl-some (lambda (kv) (and (string-prefix-p "MOCK_PROBE_GIT_OBJECT=" kv)
                                             (file-exists-p (substring kv (length "MOCK_PROBE_GIT_OBJECT=")))))
                           drgnx-sandbox-fixture-probe-env))
      (should (file-exists-p (concat drgnx-sandbox-fixture-folder "/sub/.git/config")))
      (should (file-exists-p (concat drgnx-sandbox-fixture-own "/.git/hooks/post-merge")))
      ;; a probe says reached or blocked and never what it read
      (dolist (canary (drgnx-sandbox-fixture-canaries)) (should-not (string-search canary text))))))

(ert-deftest drgnx-sandbox-fixture/canaries-are-random ()
  (let (a b)
    (drgnx-sandbox-fixture-with
      :unsandboxed
      (setq a (drgnx-sandbox-fixture-canaries))
      (should (>= (length a) 6))
      (dolist (c a) (should (string-match-p "\\`canary-[0-9a-f]\\{64\\}\\'" c)))
      (should (equal (length a) (length (delete-dups (copy-sequence a)))))
      ;; planted where the probes look: the key, the other repo, the .env, the tracked file's change, the remote's URL
      (with-temp-buffer (insert-file-contents (concat drgnx-sandbox-fixture-home "/.ssh/id_canary"))
                        (should (member (string-trim (buffer-string)) a)))
      (with-temp-buffer (insert-file-contents (concat drgnx-sandbox-fixture-home "/other-repo/secret"))
                        (should (member (string-trim (buffer-string)) a)))
      (with-temp-buffer (insert-file-contents (concat drgnx-sandbox-fixture-repo "/.env"))
                        (should (cl-some (lambda (c) (string-search c (buffer-string))) a)))
      (should (cl-some (lambda (c) (string-search c (drgnx-sandbox-fixture--git drgnx-sandbox-fixture-repo "remote" "get-url" "origin"))) a))
      (should (string-search "M tracked.txt" (concat (drgnx-sandbox-fixture--git drgnx-sandbox-fixture-repo "status" "--porcelain" "-uno") "")))
      (should (string-prefix-p "?? " (car (seq-filter (lambda (l) (string-search ".env" l))
                                                      (split-string (drgnx-sandbox-fixture--git drgnx-sandbox-fixture-repo "status" "--porcelain") "\n" t)))))
      (should (cl-some (lambda (kv) (string-prefix-p "OPENROUTER_API_KEY=canary-" kv)) process-environment)))
    (drgnx-sandbox-fixture-with
      :unsandboxed
      (setq b (drgnx-sandbox-fixture-canaries)))
    (should-not (cl-intersection a b :test #'equal))))

(defun drgnx-sandbox-fixture-test--real-home ()
  "The login user's real home directory, whatever $HOME says (read from the account database)."
  (file-name-as-directory (expand-file-name (concat "~" (user-login-name)) "/")))

(defun drgnx-sandbox-fixture-test--listing (dir)
  "Size and modification time (nil: absent) of the exact names under DIR that the fixture creates or uses: what a
stray write there would change.  Nothing else of the real home is looked at."
  (mapcar (lambda (name)
            (let ((attrs (file-attributes (concat dir name))))
              (list name (and attrs (file-attribute-size attrs)) (and attrs (file-attribute-modification-time attrs)))))
          '(".ssh/id_canary" "other-repo" "other-repo/secret" "repo" ".config/drgnx/agents.eld")))

(ert-deftest drgnx-sandbox-fixture/nothing-under-the-real-home ()
  (let* ((real (drgnx-sandbox-fixture-test--real-home))
         (outer-home (getenv "HOME"))
         (before (drgnx-sandbox-fixture-test--listing real))
         (paths nil))
    (drgnx-sandbox-fixture-with
      :unsandboxed
      (should-not (equal (file-name-as-directory (getenv "HOME")) real))
      (should (string-prefix-p drgnx-sandbox-fixture-root (getenv "HOME")))
      (should-not (equal (getenv "HOME") outer-home))
      ;; every path the probes name, and the hub's socket, is in the fixture's directory
      (dolist (kv drgnx-sandbox-fixture-probe-env)
        (let ((v (cadr (split-string kv "=" nil))))
          (when (string-prefix-p "/" v) (push v paths))))
      (should paths)
      (dolist (p paths) (ert-info (p) (should (string-prefix-p drgnx-sandbox-fixture-root p))))
      (should-not (file-exists-p (concat real ".ssh/id_canary")))
      (should-not (file-exists-p (concat real "other-repo/secret")))
      (drgnx-sandbox-fixture-test--ask "probe ssh-key other-repo"))
    (should (equal before (drgnx-sandbox-fixture-test--listing real)))
    (should-not (file-exists-p (concat real ".ssh/id_canary")))
    (should-not (file-exists-p (concat real "other-repo/secret")))))

(provide 'sandbox-fixture-test)
;;; sandbox-fixture-test.el ends here
