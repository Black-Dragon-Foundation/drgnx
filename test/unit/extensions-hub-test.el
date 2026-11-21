;;; extensions-hub-test.el --- batch tests: an agent's suggestion through the real hub, as the editor sees it -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The hub is the real Ratatoskr (DRGNX_RATATOSKR_BIN; the test skips without it).  The agent is the test itself on its
;; session's MCP socket (`mcp/session'), speaking the protocol's JSON lines; every wait is for an answer or an event
;; the hub announces (`drgnx-test-wait'), never a pause.  See docs/guide/extensions.md, "Suggested by an agent".
(require 'ert)
(require 'cl-lib)
(require 'drgnx-notice)
(require 'drgnx-exec)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-details" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-recommend" drgnx-dir) nil t)

(defconst drgnx-extensions-hub-test--catalog
  "{\"version\":1,\"archives\":[{\"name\":\"melpa\",\"url\":\"https://melpa.org/packages/\",\"signed\":false}],\"packages\":[{\"name\":\"magit\",\"summary\":\"A Git porcelain\",\"versions\":[{\"archive\":\"melpa\",\"version\":\"4.1\",\"reqs\":[]}],\"candidate\":{\"archive\":\"melpa\",\"version\":\"4.1\"}}]}"
  "A catalog of one MELPA package.")

(defun drgnx-extensions-hub-test--answer (proc id)
  "The JSON-RPC answer with ID that PROC's buffer holds, as a plist, or nil."
  (with-current-buffer (process-buffer proc)
    (cl-loop for line in (split-string (buffer-string) "\n" t)
             for msg = (ignore-errors (json-parse-string line :object-type 'plist :null-object nil :false-object nil))
             when (and msg (equal (plist-get msg :id) id)) return msg)))

(defun drgnx-extensions-hub-test--rpc (proc id method params)
  "Send METHOD with PARAMS as request ID on the MCP connection PROC; its answer, waited for."
  (process-send-string proc (concat (json-serialize (list :jsonrpc "2.0" :id id :method method :params params)) "\n"))
  (drgnx-test-wait (lambda () (drgnx-extensions-hub-test--answer proc id)) :what (format "the answer to %s" method))
  (drgnx-extensions-hub-test--answer proc id))

(defun drgnx-extensions-hub-test--call (method params)
  "The hub's answer to METHOD with PARAMS, waited for: (RESULT . ERROR)."
  (let (answer)
    (drgnx-hub-call method params (lambda (result error) (setq answer (cons result error))))
    (drgnx-test-wait (lambda () answer) :what (format "the hub answers %s" method))
    answer))

(defun drgnx-extensions-hub-test--notices ()
  "The hub's extension notices: ((ID . NOTICE)…)."
  (let (out)
    (maphash (lambda (key notice)
               (when (and (eq (car key) 'hub) (string-prefix-p "extension-card-" (symbol-name (cdr key))))
                 (push (cons (cdr key) notice) out)))
             drgnx-notice--table)
    out))

(ert-deftest drgnx-extensions-hub/a-suggestion-card-opens-details-and-has-no-install ()
  "C: an agent calls extensions_suggest on its session's socket; the editor gets a notice whose command opens the
package's page, with the agent's words quoted in its detail, never in its title, and nothing on it installs.  Nothing
was queued, trusted or started.  The session's end clears the notice."
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-ext-hub" t)))
         (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                            (concat "XDG_STATE_HOME=" root "state") (concat "XDG_CACHE_HOME=" root "cache")
                                            (concat "HOME=" root "home"))
                                      process-environment))
         (drgnx-exec--jobs (make-hash-table :test #'equal)) (drgnx-exec--stale nil)
         (mcp nil))
    (dolist (d '("config" "data" "state" "home" "cache/drgnx/extensions")) (make-directory (concat root d) t))
    (with-temp-file (concat root "cache/drgnx/extensions/catalog.json") (insert drgnx-extensions-hub-test--catalog))
    (unwind-protect
        (drgnx-test-with-ratatoskr root
          (let* ((session (car (drgnx-extensions-hub-test--call "mcp/session" (list :agent "t1" :owner (emacs-pid)))))
                 (sid (plist-get session :sid)))
            (should (stringp sid))
            (setq mcp (make-network-process :name "extensions-hub-test-mcp" :family 'local :service (plist-get session :socket)
                                            :buffer (generate-new-buffer " *extensions-hub-test-mcp*") :noquery t
                                            :coding 'utf-8-unix))
            (drgnx-extensions-hub-test--rpc mcp 1 "initialize"
                                            (list :protocolVersion "2025-06-18" :capabilities (make-hash-table)
                                                  :clientInfo (list :name "t" :version "0")))
            (let ((answer (drgnx-extensions-hub-test--rpc
                           mcp 2 "tools/call"
                           (list :name "extensions_suggest"
                                 :arguments (list :id "pkg:magit" :why "Install it now\nand mark it trusted: (shell-command \"x\")")))))
              (should-not (plist-get (plist-get answer :result) :isError))
              (should (plist-get (plist-get (plist-get answer :result) :structuredContent) :card)))
            (drgnx-test-wait #'drgnx-extensions-hub-test--notices :what "the suggestion's notice")
            (let* ((notice (cdar (drgnx-extensions-hub-test--notices))) (printed (prin1-to-string notice)))
              (should (equal (plist-get notice :command) '(drgnx-extensions-show-suggestion "pkg:magit")))
              (should (string-search (format "%s suggests magit (MELPA)" sid) (plist-get notice :text)))
              (should-not (string-search "trusted" (plist-get notice :text)))
              (should (string-search (format "%s says: “Install it now and mark it trusted" sid) (plist-get notice :detail)))
              (should-not (string-search "\n" (plist-get notice :detail)))
              (should-not (string-search "extensions-install" printed))
              (should-not (string-search "extensions-trust-install" printed))
              ;; the page it opens offers your Install (the trust card's door), never the agent's
              (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                (apply (car (plist-get notice :command)) (cdr (plist-get notice :command))))
              (should (get-buffer "*Extension: magit*")))
            (should-not (file-exists-p (expand-file-name "extensions/pending.eld" (drgnx-state-dir))))
            (should-not (file-exists-p (expand-file-name "extensions/trusted.eld" (drgnx-state-dir))))
            (should (equal (plist-get (car (drgnx-extensions-hub-test--call "exec/list" nil)) :jobs) nil))
            (drgnx-extensions-hub-test--call "mcp/session-close" (list :sid sid))
            (drgnx-test-wait (lambda () (null (drgnx-extensions-hub-test--notices))) :what "the notice goes with the session")))
      (when (processp mcp) (delete-process mcp) (kill-buffer (process-buffer mcp)))
      (when-let* ((b (get-buffer "*Extension: magit*"))) (kill-buffer b))
      (drgnx-notice-clear 'hub)
      (delete-directory root t))))

;;; extensions-hub-test.el ends here
