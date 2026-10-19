;;; drgnx-ui-mcp-test.el --- batch tests: the drgnx-ui MCP server -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui-mcp)

(defconst drgnx-ui-mcp-test--tools
  '("ui_start" "ui_frame" "ui_stop" "ui_list" "ui_state" "ui_screenshot" "ui_click" "ui_drag" "ui_keys" "ui_type" "ui_wait" "ui_measure" "ui_diff" "ui_record" "ui_perf" "ui_wm"))

(defmacro drgnx-ui-mcp-test--with-state (&rest body)
  (declare (indent 0))
  `(let* ((root (make-temp-file "drgnx-mcp-state" t))
          (process-environment (append (list (concat "DRGNX_UI_STATE=" root)
                                             (concat "XDG_RUNTIME_DIR=" root))
                                       process-environment)))
     (unwind-protect (progn ,@body) (delete-directory root t))))

(defun drgnx-ui-mcp-test--call (name args)
  (plist-get (drgnx-ui-mcp-handle (list :jsonrpc "2.0" :id 1 :method "tools/call"
                                        :params (list :name name :arguments args)))
             :result))

(defun drgnx-ui-mcp-test--text (result)
  (plist-get (aref (plist-get result :content) 0) :text))

(ert-deftest drgnx-ui-mcp/initialize-and-list ()
  (let ((init (drgnx-ui-mcp-handle '(:jsonrpc "2.0" :id 1 :method "initialize"
                                              :params (:protocolVersion "2025-06-18")))))
    (should (equal (plist-get (plist-get (plist-get init :result) :serverInfo) :name) "drgnx-ui"))
    (should (equal (plist-get (plist-get init :result) :protocolVersion) "2025-06-18")))
  (should-not (drgnx-ui-mcp-handle '(:jsonrpc "2.0" :method "notifications/initialized")))
  (let ((tools (plist-get (plist-get (drgnx-ui-mcp-handle '(:jsonrpc "2.0" :id 2 :method "tools/list")) :result)
                          :tools)))
    (should (equal (sort (mapcar (lambda (tool) (plist-get tool :name)) tools) #'string<)
                   (sort (copy-sequence drgnx-ui-mcp-test--tools) #'string<)))))

(ert-deftest drgnx-ui-mcp/tool-list-serializes ()
  (let ((json (drgnx-ui--json (drgnx-ui-mcp-handle '(:jsonrpc "2.0" :id 2 :method "tools/list")))))
    (should (string-search "\"inputSchema\"" json))
    (should (string-search "\"properties\":{}" json))))            ; ui_list: an empty object, not null

(ert-deftest drgnx-ui-mcp/foreign-sessions-refused ()
  (drgnx-ui-mcp-test--with-state
    (dolist (session '("server" "../../emacs/server" "drgnx-ui-1-00000a"))
      (let ((r (drgnx-ui-mcp-test--call "ui_state" (list :session session))))
        (should (eq (plist-get r :isError) t))
        (should (string-search "refused" (drgnx-ui-mcp-test--text r)))))))

(ert-deftest drgnx-ui-mcp/unknown-tool-and-method ()
  (should (eq (plist-get (drgnx-ui-mcp-test--call "ui_fly" nil) :isError) t))
  (should (equal (plist-get (plist-get (drgnx-ui-mcp-handle '(:jsonrpc "2.0" :id 5 :method "nope")) :error) :code)
                 -32601)))

(ert-deftest drgnx-ui-mcp/a-reply-that-cannot-be-serialised-is-an-error-with-its-id ()
  ;; the stdio loop must outlive it: the client gets an internal error for its request, never silence
  (let ((reply (drgnx-ui--parse-json (drgnx-ui-mcp--reply-text (list :jsonrpc "2.0" :id 7 :result (list :x (make-marker)))))))
    (should (equal (plist-get reply :id) 7))
    (should (equal (plist-get (plist-get reply :error) :code) -32603)))
  (should (equal (drgnx-ui--parse-json (drgnx-ui-mcp--reply-text '(:jsonrpc "2.0" :id 8 :result (:ok t))))
                 '(:jsonrpc "2.0" :id 8 :result (:ok t)))))

(ert-deftest drgnx-ui-mcp/ui-drag-is-declared-like-the-other-input-tools ()
  (let* ((tool (seq-find (lambda (tl) (equal (plist-get tl :name) "ui_drag")) drgnx-ui-mcp-tools))
         (schema (plist-get tool :inputSchema)))
    (should tool)
    (should (equal (append (plist-get schema :required) nil)
                   '("session" "from_x" "from_y" "to_x" "to_y")))
    (dolist (k '(:session :from_x :from_y :to_x :to_y :steps :button))
      (should (plist-get (plist-get schema :properties) k)))
    (should (string-search "guard_violations" (plist-get tool :description)))))

(ert-deftest drgnx-ui-mcp/ui-drag-builds-the-measure-action ()
  (should (equal (drgnx-ui-mcp--drag-action '(:session "s" :from_x 10 :from_y 20 :to_x 110 :to_y 20))
                 '(:drag (:from (10 . 20) :to (110 . 20)))))
  (should (equal (drgnx-ui-mcp--drag-action '(:session "s" :from_x 1 :from_y 2 :to_x 3 :to_y 4 :steps 5 :button 3))
                 '(:drag (:from (1 . 2) :to (3 . 4) :steps 5 :button 3)))))

(ert-deftest drgnx-ui-mcp/ui-drag-refuses-bad-arguments-as-errors ()
  ;; never a drag from 0,0: a missing or wrong coordinate is an error result
  (drgnx-ui-mcp-test--with-state
    (dolist (args '((:session "drgnx-ui-9" :from_x 1 :from_y 2 :to_x 3)
                    (:session "drgnx-ui-9" :from_x "1" :from_y 2 :to_x 3 :to_y 4)
                    (:session "drgnx-ui-9" :from_x 1.5 :from_y 2 :to_x 3 :to_y 4)
                    (:session "drgnx-ui-9" :from_x -1 :from_y 2 :to_x 3 :to_y 4)
                    (:session "drgnx-ui-9" :from_x 1 :from_y 2 :to_x 3 :to_y 4 :steps 0)
                    (:session "drgnx-ui-9" :from_x 1 :from_y 2 :to_x 3 :to_y 4 :steps 5000)
                    (:session "drgnx-ui-9" :from_x 1 :from_y 2 :to_x 3 :to_y 4 :button 4)))
      (let ((r (drgnx-ui-mcp-test--call "ui_drag" args)))
        (should (eq (plist-get r :isError) t))
        (should (string-search "drag" (drgnx-ui-mcp-test--text r)))))
    ;; a foreign session is refused like for every other tool
    (let ((r (drgnx-ui-mcp-test--call "ui_drag" '(:session "server" :from_x 1 :from_y 2 :to_x 3 :to_y 4))))
      (should (eq (plist-get r :isError) t))
      (should (string-search "refused" (drgnx-ui-mcp-test--text r))))))

(ert-deftest drgnx-ui-mcp/list-is-empty-without-sessions ()
  (drgnx-ui-mcp-test--with-state
    (should (equal (drgnx-ui-mcp-test--text (drgnx-ui-mcp-test--call "ui_list" nil)) "[]"))))

(ert-deftest drgnx-ui-mcp/stdio-roundtrip-utf8-without-locale ()
  (drgnx-ui-mcp-test--with-state
    (let* ((process-environment (append '("LANG" "LC_ALL" "LC_CTYPE") process-environment))  ; unset
           (client (drgnx-ui-mcp-client-start)))
      (unwind-protect
          (progn
            (should (equal (plist-get (plist-get (drgnx-ui-mcp-client-request client "initialize"
                                                                              '(:protocolVersion "2025-06-18"))
                                                 :serverInfo)
                                      :name)
                           "drgnx-ui"))
            (let ((r (drgnx-ui-mcp-client-request client "tools/call"
                                                  '(:name "ui_state" :arguments (:session "drgnx-ui-✓")))))
              (should (string-search "drgnx-ui-✓" (drgnx-ui-mcp-test--text r)))))
        (drgnx-ui-mcp-client-stop client)))))

;;;; Another client's session needs adopt (HARNESS-SESS-1)

(defun drgnx-ui-mcp-test--session (name client)
  "A fake live session NAME owned by CLIENT (a token or nil): its socket exists.  Return the process holding it."
  (let* ((drgnx-ui-owner-client client)
         (s (drgnx-ui-prepare-run name nil "1600x900")))
    (make-network-process :name name :family 'local :server t :service (plist-get s :socket) :noquery t)))

(defun drgnx-ui-mcp-test--adopted (name)
  (plist-get (drgnx-ui--read-json (expand-file-name "session.json" (expand-file-name name (drgnx-ui-state-root))))
             :adopted))

(ert-deftest drgnx-ui-mcp/another-clients-session-is-refused-unless-adopted ()
  (drgnx-ui-mcp-test--with-state
    (let ((server (drgnx-ui-mcp-test--session "drgnx-ui-1-00000a" "aaaaaaaaaaaaaaaa"))
          (drgnx-ui-mcp--token "bbbbbbbbbbbbbbbb"))
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-ui-state) (lambda (&rest _) '(:ok t))))
            (let ((r (drgnx-ui-mcp-test--call "ui_state" '(:session "drgnx-ui-1-00000a"))))
              (should (eq (plist-get r :isError) t))
              (should (string-match-p "drgnx-ui-1-00000a belongs to another client ([a-z]+, .*, pid [0-9]+); pass adopt: true to drive it"
                                      (drgnx-ui-mcp-test--text r))))
            (let ((r (drgnx-ui-mcp-test--call "ui_state" '(:session "drgnx-ui-1-00000a" :adopt t))))
              (should-not (plist-get r :isError)))
            ;; its own client's token needs nothing
            (let ((drgnx-ui-mcp--token "aaaaaaaaaaaaaaaa"))
              (should-not (plist-get (drgnx-ui-mcp-test--call "ui_state" '(:session "drgnx-ui-1-00000a")) :isError))))
        (delete-process server)))))

(ert-deftest drgnx-ui-mcp/adopting-is-recorded ()
  (drgnx-ui-mcp-test--with-state
    (let ((server (drgnx-ui-mcp-test--session "drgnx-ui-1-00000a" "aaaaaaaaaaaaaaaa"))
          (drgnx-ui-mcp--token "bbbbbbbbbbbbbbbb"))
      (unwind-protect
          (progn
            (should-not (drgnx-ui-mcp-test--adopted "drgnx-ui-1-00000a"))
            (drgnx-ui-own-session "drgnx-ui-1-00000a" :client drgnx-ui-mcp--token :adopt t)
            (drgnx-ui-own-session "drgnx-ui-1-00000a" :client drgnx-ui-mcp--token :adopt t)   ; once only
            (let ((adopted (append (drgnx-ui-mcp-test--adopted "drgnx-ui-1-00000a") nil)))
              (should (= (length adopted) 1))
              (should (equal (plist-get (car adopted) :client) "bbbbbbbbbbbbbbbb"))
              (should (stringp (plist-get (car adopted) :at)))))
        (delete-process server)))))

(ert-deftest drgnx-ui-mcp/ui-list-marks-yours ()
  (drgnx-ui-mcp-test--with-state
    (let ((a (drgnx-ui-mcp-test--session "drgnx-ui-1-00000a" "aaaaaaaaaaaaaaaa"))
          (b (drgnx-ui-mcp-test--session "drgnx-ui-2-00000a" "bbbbbbbbbbbbbbbb"))
          (drgnx-ui-mcp--token "aaaaaaaaaaaaaaaa"))
      (unwind-protect
          (let ((rows (drgnx-ui--parse-json
                       (drgnx-ui-mcp-test--text (drgnx-ui-mcp-test--call "ui_list" nil)))))
            (should (= (length rows) 2))
            (let ((mine (seq-find (lambda (r) (equal (plist-get r :name) "drgnx-ui-1-00000a")) rows))
                  (theirs (seq-find (lambda (r) (equal (plist-get r :name) "drgnx-ui-2-00000a")) rows)))
              (should (eq (plist-get mine :yours) t))
              (should (eq (plist-get theirs :yours) :false))
              (should (equal (plist-get (plist-get theirs :owner) :client) "bbbbbbbbbbbbbbbb"))))
        (mapc #'delete-process (list a b))))))

(ert-deftest drgnx-ui-mcp/ui-start-records-this-clients-token ()
  (let (seen (drgnx-ui-mcp--token "cccccccccccccccc"))
    (cl-letf (((symbol-function 'drgnx-ui-start) (lambda (&rest _) (setq seen drgnx-ui-owner-client) '(:name "x"))))
      (drgnx-ui-mcp-test--call "ui_start" nil))
    (should (equal seen "cccccccccccccccc"))))
