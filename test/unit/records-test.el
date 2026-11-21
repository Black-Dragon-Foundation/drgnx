;;; records-test.el --- batch tests: records as JSON, guided by schemas -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-records)
(require 'drgnx-agents)                 ; the session struct the transcript round trips build
(require 'drgnx-work-db)
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
    ;; every entry kind the agent layer makes today, children of tool entries too
    (let ((entries (drgnx-agent-session-entries s)))
      (should (equal (delete-dups (mapcar (lambda (e) (plist-get e :type)) entries))
                     '(user thought agent tool plan error stop)))
      (dolist (e entries) (should (records-test--round 'drgnx-records-entry e)))))
  ;; one event data per kind and shape, one card data per kind of card
  (dolist (row (records-test--fixture "events.eld"))
    (dolist (data (cdr row)) (should (records-test--round 'drgnx-records-event-data data))))
  (dolist (data (records-test--fixture "cards.eld")) (should (records-test--round 'drgnx-records-card-data data)))
  (should (records-test--round 'drgnx-records-job-data (records-test--fixture "job-runtime.eld"))))

(defmacro records-test--with-root (&rest body)
  "BODY with drgnx's dirs in a temp ROOT."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "drgnx-records" t))))
          (process-environment (append (list (concat "DRGNX_DATA_DIR=" root "data") (concat "DRGNX_CONFIG_DIR=" root "config")
                                             (concat "XDG_STATE_HOME=" root "state"))
                                       process-environment))
          (drgnx-work-db--handles nil))
     (unwind-protect (progn (make-directory (concat root "config") t) ,@body)
       (drgnx-work-db-close-all)
       (delete-directory root t))))

(ert-deftest drgnx-records/nodes-the-importer-makes-round-trip ()
  ;; the data the hub's importer keeps on a node (a commit's sha and date, a plan's branch, a task's stale mark)
  (records-test--with-root
    (drgnx-work-fixture-put-node "plan:/p.md" :kind 'plan :title "Plan P" :path "/p.md" :line 1 :status "open" :source "/p.md"
                                 :branch "feat" :merged t :repo "/r/")
    (drgnx-work-fixture-put-node "task:/p.md#1" :kind 'task :title "First" :parent "plan:/p.md" :ord 1 :source "/p.md" :stale t)
    (drgnx-work-fixture-put-node "commit:abc" :kind 'commit :title "task one, more" :path "/r/" :source "commit"
                                 :sha "abc" :date 1767225603 :repo "/r/" :seq -1)
    (let ((nodes (apply #'append (mapcar #'drgnx-work-nodes '(plan task commit)))))
      (should (cl-some (lambda (node) (plist-get node :sha)) nodes))   ; commits: data to carry
      (dolist (node nodes)
        (let ((data (cl-loop for (k v) on node by #'cddr
                             unless (memq k '(:id :kind :title :path :line :status :parent :ord :source)) append (list k v))))
          (should (records-test--round 'drgnx-records-node-data data)))))))

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

;;;; A project's records kept in step: the notice and conflicts, with a real Ratatoskr and a temp org folder

(require 'drgnx-records-review)
(load (expand-file-name "test/fixtures/hub-client-fixture" drgnx-dir) nil t)   ; its Ratatoskr helpers
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(defconst records-test--deferred
  "# Deferred items: Orchard\n\n| # | Area | Item | Status |\n|---|---|---|---|\n| M1-1 | harness | A timer | open |\n| M1-2 | sync | Retry budget is hard-coded | open |\n"
  "A DEFERRED.md for the hub to adopt.")

(defun records-test--rewrite (file from to)
  "FILE's text with FROM replaced by TO, written back."
  (write-region (string-replace from to (with-temp-buffer (insert-file-contents file) (buffer-string)))
                nil file nil 'silent))

(defmacro records-test--with-conflict (&rest body)
  "BODY with Ratatoskr serving, subscribed, an org folder adopted and one of its DEFERRED.md rows in conflict (an
editor saved the text it loaded before the hub's last change); once the conflict's notice is there, `id' is the
record's id and `file' the DEFERRED.md."
  (declare (indent 0))
  `(drgnx-notice-test-with-model
     (drgnx-hub-client-test--with-ratatoskr
       (drgnx-hub-connect)
       (drgnx-hub-client-test--wait (lambda () (and (processp drgnx-hub--events) (process-get drgnx-hub--events :drgnx-proven))) "the event connection proves itself")
       (let* ((org (file-name-as-directory (make-temp-file "drgnx-org" t)))
              (file (concat org "DEFERRED.md")) id)
         (unwind-protect
             (progn
               (write-region records-test--deferred nil file nil 'silent)
               (drgnx-hub-call-sync "records/import" (list :root (directory-file-name org)) 20)
               (drgnx-hub-client-test--wait (lambda () (drgnx-notices :source 'hub)) "the adoption notice")
               ;; a hand edit reaches the graph (a look at the status reads it) ...
               (records-test--rewrite file "Retry budget is hard-coded" "Retry budget is a setting")
               (drgnx-hub-call-sync "records/status" nil 10)
               ;; ... then an editor saves the text it had before
               (write-region records-test--deferred nil file nil 'silent)
               (drgnx-hub-call-sync "records/status" nil 10)
               (drgnx-hub-client-test--wait
                (lambda () (cl-some (lambda (n) (eq (car-safe (plist-get n :command)) 'drgnx-records-resolve))
                                    (drgnx-notices :source 'hub)))
                "the conflict notice")
               (setq id (car (drgnx-records-review--conflicts)))
               ,@body)
           (delete-directory org t)
           (dolist (b (buffer-list)) (when (buffer-local-value 'drgnx-records-review--id b) (kill-buffer b))))))))

(ert-deftest drgnx-records/the-adoption-and-a-conflict-are-notices ()
  :tags '(:cond)                        ; a real hub process and socket
  (records-test--with-conflict
    (should (stringp id))
    (let ((ns (drgnx-notices :source 'hub)))
      (should (cl-some (lambda (n) (string-match-p "keeps 1 record file" (plist-get n :text))) ns))
      (should (cl-some (lambda (n) (equal (plist-get n :command) (list 'drgnx-records-resolve id))) ns)))
    ;; the file keeps its text
    (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) records-test--deferred))))

(ert-deftest drgnx-records/resolve-shows-both-and-keeps-one ()
  :tags '(:cond)                        ; a real hub process and socket
  (records-test--with-conflict
    (drgnx-records-resolve id)
    (with-current-buffer (get-buffer "*drgnx conflict: DEFERRED.md*")
      (should (derived-mode-p 'drgnx-records-review-mode))
      (should (equal drgnx-records-review--id id))
      (should (string-match-p "hard-coded" (buffer-string)))
      (should (string-match-p "a setting" (buffer-string)))
      (should (equal (plist-get (drgnx-records-keep-graph) :keep) "graph")))
    (should-not (get-buffer "*drgnx conflict: DEFERRED.md*"))
    (should-not (drgnx-records-review--conflicts))
    (should (string-match-p "a setting" (with-temp-buffer (insert-file-contents file) (buffer-string))))))

(ert-deftest drgnx-records/no-prompt-from-the-event ()
  :tags '(:cond)
  (drgnx-notice-test-with-model
    (let ((conn (make-pipe-process :name "records-test" :noquery t)) (calls 0))
      (unwind-protect
          (progn
            (process-put conn :drgnx-proven t)
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (error "prompted")))
                      ((symbol-function 'completing-read) (lambda (&rest _) (error "prompted")))
                      ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "prompted")))
                      ((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (cl-incf calls) nil)))
              (let ((inhibit-interaction t) (drgnx-hub--event-conn conn))
                (drgnx-records-review--event "records-conflict" '(:ids ["todo:x"] :path "/o/DEFERRED.md"))
                (drgnx-records-review--event "records-notice" '(:root "/o" :files ["/o/DEFERRED.md"]))))
            (should (= calls 0))
            (should (= (length (drgnx-notices :source 'hub)) 2)))
        (delete-process conn)))))

(provide 'records-test)
;;; records-test.el ends here
