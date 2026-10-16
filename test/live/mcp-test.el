;;; mcp-test.el --- live test: drive a session through the MCP server only -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui-mcp)

(defun drgnx-live-mcp--json (content n)
  (drgnx-ui--parse-json (plist-get (aref content n) :text)))

(ert-deftest drgnx-live/drive-a-session-through-mcp-only ()
  (let* ((root (make-temp-file "drgnx-mcp-live" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (c (drgnx-ui-mcp-client-start)))
    (unwind-protect
        (let ((name (plist-get (drgnx-live-mcp--json (drgnx-ui-mcp-client-tool c "ui_start" :config "minimal") 0)
                               :name)))
          (drgnx-ui-mcp-client-tool c "ui_type" :session name :text "click me")
          (let* ((shot (drgnx-ui-mcp-client-tool c "ui_screenshot" :session name))
                 (img (aref shot 0))
                 (win (aref (plist-get (drgnx-live-mcp--json shot 1) :windows) 0)))
            (should (equal (plist-get img :type) "image"))
            (should (string-prefix-p "\x89PNG" (base64-decode-string (plist-get img :data))))
            (let ((r (drgnx-live-mcp--json
                      (drgnx-ui-mcp-client-tool c "ui_click" :session name
                                                :x (+ (aref (plist-get win :body) 0) 5)
                                                :y (+ (aref (plist-get win :body) 1) 5))
                      0)))
              (should (eq (plist-get r :settled) t))))
          (let ((r (drgnx-live-mcp--json (drgnx-ui-mcp-client-tool c "ui_click" :session name
                                                                   :buffer "*scratch*" :text "me")
                                         0)))
            (should (= (plist-get r :collateral_moves) 0)))
          (let ((m (drgnx-live-mcp--json (drgnx-ui-mcp-client-tool c "ui_measure" :session name
                                                                   :actions [(:keys "C-x 2") (:keys "C-x 1")])
                                         0)))
            (should (>= (plist-get m :layout_changes) 2)))
          (should (string-search "refused" (condition-case err
                                               (progn (drgnx-ui-mcp-client-tool c "ui_state" :session "server") "")
                                             (error (error-message-string err)))))
          (drgnx-ui-mcp-client-tool c "ui_stop" :session name)
          (should (equal (plist-get (aref (drgnx-ui-mcp-client-tool c "ui_list") 0) :text) "[]")))
      (drgnx-ui-mcp-client-stop c)
      (let ((default-directory root)) (seq-doseq (s (drgnx-ui-ls)) (drgnx-ui-stop (plist-get s :name))))
      (delete-directory root t))))
