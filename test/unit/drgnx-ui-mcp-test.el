;;; drgnx-ui-mcp-test.el --- batch tests: the drgnx-ui MCP server -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui-mcp)

(defconst drgnx-ui-mcp-test--tools
  '("ui_start" "ui_frame" "ui_stop" "ui_list" "ui_state" "ui_screenshot" "ui_click" "ui_keys" "ui_type" "ui_wait" "ui_measure" "ui_diff" "ui_record" "ui_perf"))

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
    (dolist (session '("server" "../../emacs/server" "drgnx-ui-1"))
      (let ((r (drgnx-ui-mcp-test--call "ui_state" (list :session session))))
        (should (eq (plist-get r :isError) t))
        (should (string-search "refused" (drgnx-ui-mcp-test--text r)))))))

(ert-deftest drgnx-ui-mcp/unknown-tool-and-method ()
  (should (eq (plist-get (drgnx-ui-mcp-test--call "ui_fly" nil) :isError) t))
  (should (equal (plist-get (plist-get (drgnx-ui-mcp-handle '(:jsonrpc "2.0" :id 5 :method "nope")) :error) :code)
                 -32601)))

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
