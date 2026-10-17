;;; drgnx-mcp.el --- A small MCP server over stdio (batch Emacs) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Model Context Protocol, server side, as much as drgnx's tools need: one JSON-RPC message per line on
;; stdin/stdout; initialize, ping, tools/list, tools/call.  A tool is (NAME :description S :schema PLIST :call FN):
;; FN gets the arguments as a plist and returns a string (sent as it is) or a value (sent as JSON); an error in it is
;; the client's `isError' result, never the end of the server.  Used by the coordination tools
;; (drgnx-coord-mcp.el); see docs/develop/coordination.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defconst drgnx-mcp-protocol "2025-06-18")

(defun drgnx-mcp--json (v) (decode-coding-string (json-serialize v) 'utf-8))

(defun drgnx-mcp--content (value)
  (list :content (vector (list :type "text" :text (if (stringp value) value (drgnx-mcp--json value))))))

(define-error 'drgnx-mcp-no-method "No such MCP method")
(define-error 'drgnx-mcp-invalid-params "Invalid params")

(defun drgnx-mcp-handle (name tools msg)
  "The reply to MSG (a parsed JSON-RPC plist) for server NAME with TOOLS, or nil for a notification."
  (let ((id (plist-get msg :id)) (method (plist-get msg :method)) (params (plist-get msg :params)))
    (when id
      (condition-case err
          (list :jsonrpc "2.0" :id id
                :result
                (pcase method
                  ("initialize" (list :protocolVersion drgnx-mcp-protocol :capabilities (list :tools (make-hash-table))
                                      :serverInfo (list :name name :version "1")))
                  ("ping" (make-hash-table))
                  ("tools/list"
                   (list :tools (vconcat (mapcar (lambda (tool)
                                                   (list :name (car tool) :description (plist-get (cdr tool) :description)
                                                         :inputSchema (plist-get (cdr tool) :schema)))
                                                 tools))))
                  ("tools/call"
                   (let ((tool (assoc (plist-get params :name) tools)))
                     (if (not tool) (append (drgnx-mcp--content (format "no tool %s" (plist-get params :name))) (list :isError t))
                       (condition-case e (drgnx-mcp--content (funcall (plist-get (cdr tool) :call) (plist-get params :arguments)))
                         ;; a malformed request is the protocol's error, not a tool result
                         (drgnx-mcp-invalid-params (signal (car e) (cdr e)))
                         (error (append (drgnx-mcp--content (error-message-string e)) (list :isError t)))))))
                  (_ (signal 'drgnx-mcp-no-method (list method)))))
        (drgnx-mcp-no-method (list :jsonrpc "2.0" :id id :error (list :code -32601 :message (format "method not found: %s" method))))
        (drgnx-mcp-invalid-params (list :jsonrpc "2.0" :id id :error (list :code -32602 :message (error-message-string err))))
        (error (list :jsonrpc "2.0" :id id :error (list :code -32603 :message (error-message-string err))))))))

(defun drgnx-mcp-serve (name tools)
  "Serve TOOLS as MCP server NAME on stdin/stdout until end of input, then exit."
  (set-language-environment "UTF-8")
  (setq locale-coding-system 'utf-8-unix)
  (condition-case nil
      (while t
        (let ((line (read-from-minibuffer "")))
          (unless (string-blank-p line)
            (let* ((msg (ignore-errors (json-parse-string line :object-type 'plist :null-object nil :false-object nil)))
                   (reply (if msg (drgnx-mcp-handle name tools msg)
                            (list :jsonrpc "2.0" :id :null :error (list :code -32700 :message "parse error")))))
              (when reply
                (princ (condition-case e (drgnx-mcp--json reply)
                         (error (drgnx-mcp--json (list :jsonrpc "2.0" :id (or (plist-get reply :id) :null)
                                                       :error (list :code -32603 :message (error-message-string e)))))))
                (terpri))))))
    (end-of-file nil))
  (kill-emacs 0))

(defun drgnx-mcp-schema (props &optional required)
  "A JSON Schema object of PROPS ((NAME TYPE DESCRIPTION)…), REQUIRED names."
  (list :type "object"
        :properties (if props
                        (let ((h (make-hash-table :test #'equal)))
                          (pcase-dolist (`(,n ,type ,doc) props) (puthash n (list :type type :description doc) h))
                          h)
                      (make-hash-table))
        :required (vconcat required)))

(provide 'drgnx-mcp)
;;; drgnx-mcp.el ends here
