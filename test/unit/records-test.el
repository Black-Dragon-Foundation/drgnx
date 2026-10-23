;;; records-test.el --- batch tests: records as JSON, guided by schemas -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-records)
(require 'drgnx-hub)
(require 'drgnx-job)
(require 'drgnx-work-scan)
(load (expand-file-name "test/fixtures/work-fixture" drgnx-dir) nil t)

(defconst records-test--dir (file-name-directory (or load-file-name buffer-file-name)))

(defun records-test--fixture (name)
  "The form in test/fixtures/records/NAME."
  (with-temp-buffer
    (insert-file-contents (expand-file-name (concat "../fixtures/records/" name) records-test--dir))
    (read (current-buffer))))

(defun records-test--norm (x)
  "X as a decode gives it back: `:false' is nil and a nil-valued plist key is left out."
  (cond ((eq x :false) nil)
        ((and (keywordp (car-safe x)) (proper-list-p x) (cl-evenp (length x)))
         (cl-loop for (k v) on x by #'cddr
                  for nv = (records-test--norm v)
                  when nv append (list k nv)))
        ((proper-list-p x) (mapcar #'records-test--norm x))
        ((consp x) (cons (records-test--norm (car x)) (records-test--norm (cdr x))))
        (t x)))

(defun records-test--round (schema x)
  "Whether X survives encode then decode through SCHEMA (as `records-test--norm' says it should)."
  (let ((json (drgnx-records-encode schema x)))
    (should (stringp json))
    (equal (drgnx-records-decode schema json) (records-test--norm x))))

(defun records-test--acp (updates)
  "A session fed UPDATES (ACP updates as `drgnx-acp' parses them), its text joined."
  (let ((s (drgnx-agents--make :name "agent-1" :id "agent-1" :profile "mock" :cwd "/work/repo" :status 'idle
                               :capabilities '(:loadSession t :promptCapabilities (:image :false :audio :false))
                               :usage '(:used 10 :size 1000))))
    (dolist (u updates) (drgnx-agents--update s u))
    (drgnx-agents-join-text s)
    s))

(defconst records-test--updates
  '((:sessionUpdate "user_message_chunk" :content (:type "text" :text "hello"))
    (:sessionUpdate "agent_thought_chunk" :content (:type "text" :text "thinking"))
    (:sessionUpdate "agent_message_chunk" :content (:type "text" :text "Hel"))
    (:sessionUpdate "agent_message_chunk" :content (:type "text" :text "lo"))
    (:sessionUpdate "tool_call" :toolCallId "t1" :title "Read a.el" :kind "read" :status "pending"
                    :content ((:type "content" :content (:type "text" :text "x"))))
    (:sessionUpdate "tool_call" :toolCallId "t2" :title "Grep" :kind "search" :status "pending"
                    :_meta (:parentToolCallId "t1"))
    (:sessionUpdate "tool_call_update" :toolCallId "t1" :status "completed")
    (:sessionUpdate "plan" :entries ((:content "step" :priority "high" :status "pending")))))

;;;; Round trips

(ert-deftest drgnx-records/round-trips-every-fixture ()
  (let ((s (records-test--acp records-test--updates)))
    (drgnx-agents--add s (list :type 'error :text "boom"))
    (drgnx-agents--add s (list :type 'stop :stop "end_turn" :done t))
    (setf (drgnx-agent-session-queue s) '("next" "after")
          (drgnx-agent-session-permissions s) (list (list :id 7 :title "Run it" :tool '(:toolCallId "t9" :kind "execute")
                                                          :options '((:optionId "allow" :name "Allow" :kind "allow_once"))))
          (drgnx-agent-session-reviews s) (list (list :id "r1" :path "/work/repo/a.el" :content "text"))
          (drgnx-agent-session-via s) 'direct)
    ;; the snapshot, a running and an exited one
    (should (records-test--round 'drgnx-records-session (drgnx-hub--snapshot s)))
    (setf (drgnx-agent-session-status s) 'exited (drgnx-agent-session-exit s) 3 (drgnx-agent-session-stderr s) "bye")
    (should (records-test--round 'drgnx-records-session (drgnx-hub--snapshot s)))
    ;; every entry kind the agent layer makes today, children of tool entries too
    (let ((entries (drgnx-agent-session-entries s)))
      (should (equal (delete-dups (mapcar (lambda (e) (plist-get e :type)) entries))
                     '(user thought agent tool plan error stop)))
      (dolist (e entries) (should (records-test--round 'drgnx-records-entry e)))))
  ;; one event data per kind and shape, one card data per kind of card
  (let ((kinds 0))
    (dolist (row (records-test--fixture "events.eld"))
      (should (member (car row) drgnx-coord-event-kinds))
      (cl-incf kinds)
      (dolist (data (cdr row)) (should (records-test--round 'drgnx-records-event-data data))))
    (should (= kinds (length drgnx-coord-event-kinds))))
  (dolist (data (records-test--fixture "cards.eld")) (should (records-test--round 'drgnx-records-card-data data)))
  (should (records-test--round 'drgnx-records-job-data (records-test--fixture "job-runtime.eld"))))

(defmacro records-test--with-root (&rest body)
  "BODY with drgnx's dirs in a temp ROOT."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-records" t))))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" root "data") (concat "DRGNX_CONFIG_DIR=" root "config")
                                             (concat "XDG_STATE_HOME=" root "state"))
                                       process-environment))
          (drgnx-work-db--handles nil) (drgnx-job-routes nil))
     (unwind-protect (progn (make-directory (concat root "config") t) ,@body)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(ert-deftest drgnx-records/a-proposal-the-job-code-makes-round-trips ()
  (records-test--with-root
    (let ((plan (concat root "p.md")))
      (make-directory (concat root "code") t)
      (write-region "# Build\n\n**Repo:** code\n\n### Task 1: A\n- [ ] one\n\n### Task 2: B\n**Depends:** Task 1\n**Role:** test\n- [ ] two\n"
                    nil plan nil 'silent)
      (let* ((drgnx-job-routes '((implement . "claude") (test "claude")))
             (data (plist-get (drgnx-job-get (drgnx-job-propose plan :budget 5)) :proposal)))
        (should (plist-get data :routes))
        (should (records-test--round 'drgnx-records-job-data data))))))

(ert-deftest drgnx-records/nodes-a-scan-makes-round-trip ()
  (records-test--with-root
    (let ((code (concat root "code/")) (shas nil))
      (make-directory code t)
      (cl-flet ((git (&rest args)
                  (with-temp-buffer
                    (let ((default-directory code))
                      (apply #'call-process "git" nil t nil "-c" "user.name=t" "-c" "user.email=t@t.invalid" args)
                      (string-trim (buffer-string))))))
        (git "init" "-q" "-b" "main")
        (dolist (msg '("base" "task one" "task one, more"))
          (write-region msg nil (concat code "f") nil 'silent)
          (git "add" "-A")
          (git "commit" "-q" "-m" msg)
          (push (git "rev-parse" "--short" "HEAD") shas)))
      (make-directory (concat code ".superpowers/sdd/p") t)
      (make-directory (concat root "docs/plans") t)
      (write-region "# Plan P\n\n### Task 1: First\n- [x] one\n" nil (concat root "docs/plans/p.md") nil 'silent)
      (write-region (format "# SDD ledger — plan: %sdocs/plans/p.md\nTask 1: complete (commits %s..%s, tests: ok)\n" root
                            (nth 2 shas) (nth 0 shas))
                    nil (concat code ".superpowers/sdd/p/progress.md") nil 'silent)
      (drgnx-work-fixture-with-hub (drgnx-work-scan (list root)))
      (let ((nodes (apply #'append (mapcar #'drgnx-work-nodes '(spec plan task step commit branch ruling todo)))))
        (should (cl-some (lambda (node) (plist-get node :sha)) nodes))   ; commits: data to carry
        (dolist (node nodes)
          (let ((data (cl-loop for (k v) on node by #'cddr
                               unless (memq k '(:id :kind :title :path :line :status :parent :ord :source)) append (list k v))))
            (should (records-test--round 'drgnx-records-node-data data))))))))

;;;; The rules

(ert-deftest drgnx-records/empty-lists-are-arrays ()
  (should (equal (drgnx-records-encode '(list-of string) nil) "[]"))
  (should (string-search "\"queue\":[]" (drgnx-records-encode 'drgnx-records-session '(:id "a" :queue nil))))
  (should (equal (drgnx-records-to-json '(list-of string) nil) []))
  (should (equal (drgnx-records-decode '(list-of string) "[]") nil)))

(ert-deftest drgnx-records/nil-keys-are-left-out ()
  (let ((json (drgnx-records-encode 'drgnx-records-session '(:id "a" :task nil :job nil :name "n"))))
    (should (equal (json-parse-string json :object-type 'alist) '((id . "a") (name . "n"))))
    (should-not (string-search "null" json))))

(ert-deftest drgnx-records/booleans-are-false-not-null ()
  (let ((alist (json-parse-string (drgnx-records-encode 'drgnx-records-session '(:id "a" :paused nil :enforced t))
                                  :object-type 'alist :false-object :false)))
    (should (eq (alist-get 'paused alist) :false))
    (should (eq (alist-get 'enforced alist) t)))
  (should (equal (drgnx-records-decode 'drgnx-records-session "{\"id\":\"a\",\"paused\":false,\"enforced\":true}")
                 '(:id "a" :enforced t))))

(ert-deftest drgnx-records/an-unknown-enum-is-refused-with-its-path ()
  (let ((err (should-error (drgnx-records-decode 'drgnx-records-session "{\"id\":\"a\",\"status\":\"exploded\"}")
                           :type 'drgnx-records-invalid)))
    (should (equal (cadr err) '(:status)))
    (should (stringp (cddr err))))
  (should-error (drgnx-records-decode 'drgnx-records-session "{\"status\":\"never-interned-qx7\"}") :type 'drgnx-records-invalid)
  (should-not (intern-soft "never-interned-qx7"))      ; refused, never interned
  (let ((err (should-error (drgnx-records-decode 'drgnx-records-session "{\"id\":\"a\",\"permissions\":[{\"id\":1,\"title\":3}]}")
                           :type 'drgnx-records-invalid)))
    (should (equal (cadr err) '(:permissions 0 :title))))
  (should-error (drgnx-records-decode 'drgnx-records-session "{not json") :type 'drgnx-records-invalid)
  (should-error (drgnx-records-decode 'drgnx-records-session "[1]") :type 'drgnx-records-invalid))

(ert-deftest drgnx-records/an-unlisted-symbol-is-refused ()
  (let ((err (should-error (drgnx-records-encode 'any '(:x foo)) :type 'drgnx-records-unknown-symbol)))
    (should (equal (cadr err) '(:x))))
  (should-error (drgnx-records-encode 'drgnx-records-event-data '(:n 1 :extra (1 bar))) :type 'drgnx-records-unknown-symbol)
  (should-error (drgnx-records-encode 'drgnx-records-session '(:id "a" :status exploded)) :type 'drgnx-records-invalid)
  (should (equal (drgnx-records-decode 'any (drgnx-records-encode 'any '(:x "foo" :y (1 "a") :z (:q t))))
                 '(:x "foo" :y (1 "a") :z (:q t)))))

(ert-deftest drgnx-records/decode-never-calls-read ()
  (let ((json (drgnx-records-encode 'drgnx-records-session '(:id "a" :status busy :usage (:used 1) :queue ("x"))))
        (stop (lambda (&rest _) (error "read was called"))))
    (advice-add 'read :before stop)
    (advice-add 'read-from-string :before stop)
    (unwind-protect
        (should (equal (drgnx-records-decode 'drgnx-records-session json) '(:id "a" :status busy :usage (:used 1) :queue ("x"))))
      (advice-remove 'read stop)
      (advice-remove 'read-from-string stop))))

(ert-deftest drgnx-records/truncated-data-round-trips ()
  (should (records-test--round 'drgnx-records-event-data '(:truncated t :size 9000)))
  (should (records-test--round 'drgnx-records-card-data '(:truncated t :size 9000)))
  (should (records-test--round 'drgnx-records-job-data '(:truncated t :size 9000))))

(ert-deftest drgnx-records/maps-and-alists-are-objects ()
  (let ((schema '(alist string integer)))
    (should (equal (drgnx-records-encode schema '(("a" . 1) ("b/c" . 2))) "{\"a\":1,\"b/c\":2}"))
    (should (equal (drgnx-records-decode schema "{\"a\":1,\"b/c\":2}") '(("a" . 1) ("b/c" . 2))))
    (should (equal (drgnx-records-encode schema nil) "{}")))
  (should (equal (drgnx-records-decode '(map integer) "{\"a\":1}") '(:a 1)))
  (should (equal (drgnx-records-encode '(map integer) '(:a 1)) "{\"a\":1}"))
  (should-error (drgnx-records-decode '(alist string integer) "{\"a\":\"x\"}") :type 'drgnx-records-invalid))

(provide 'records-test)
;;; records-test.el ends here
