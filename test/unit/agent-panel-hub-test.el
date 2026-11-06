;;; agent-panel-hub-test.el --- batch tests: the agent panel against a real hub -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: gated
;; The hub runs as its own process; this Emacs plays the editor inside the delivery gate (`drgnx-test-gated').  The
;; agent is a real child (mock-acp) whose turns run in real time: what it did is a condition the test sees after each
;; release of the hub's lines (the helpers of agents-mirror-test.el), never a deadline.  Skipped without the hub binary.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-modules)
(require 'drgnx-agents)
(require 'drgnx-hub-client)
(load (expand-file-name "test/unit/agents-mirror-test" drgnx-dir) nil t)   ; its helpers and the hub fixtures
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel-sync-windows "drgnx-agent-panel")
(declare-function drgnx-agent-panel-older "drgnx-agent-panel")
(defvar drgnx-agent-panel--entries)
(defvar drgnx-agent-panel--subscribed)
(defvar drgnx-agent-panel--loaded)
(defvar drgnx-agent-panel--more)
(defvar drgnx-agent-panel--steps)
(defvar drgnx-agent-panel-page-steps)

(defmacro drgnx-agent-panel-hub-test--with (&rest body)
  "BODY with a gated hub, the module on and this Emacs connected; `id' is a started mock session."
  (declare (indent 0))
  `(drgnx-agents-mirror-test--with '()
     (drgnx-test-with-modules '(tools/agent-panel)
       (save-window-excursion
         (delete-other-windows)
         (drgnx-hub-connect)
         (let ((id (plist-get (drgnx-agents-mirror-test--ask "agents/start" (list :profile "mock" :cwd (getenv "HOME"))) :id)))
           ,@body)))))

(defun drgnx-agent-panel-hub-test--entry-text (buf)
  (with-current-buffer buf
    (mapconcat (lambda (e) (format "%s" (or (plist-get e :text) (plist-get e :title) "")))
               (hash-table-values drgnx-agent-panel--entries) " ")))

(defun drgnx-agent-panel-hub-test--turn (id text)
  (drgnx-agents-mirror-test--ask "agents/send" (list :id id :text text)))

(ert-deftest drgnx-agent-panel/subscribes-only-while-shown ()
  (drgnx-agent-panel-hub-test--with
    (let ((buf (drgnx-agent-panel-buffer id)) (other (get-buffer-create "*panel-other*")))
      (unwind-protect
          (progn
            ;; hidden: nothing is subscribed and a turn leaves no entry in the panel
            (set-window-buffer (selected-window) other)
            (drgnx-agent-panel-sync-windows)
            (should-not (buffer-local-value 'drgnx-agent-panel--subscribed buf))
            (drgnx-agent-panel-hub-test--turn id "hidden turn")
            (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "the hidden turn over")
            (should-not (string-search "hidden turn" (drgnx-agent-panel-hub-test--entry-text buf)))
            ;; shown: subscribed, the last page comes and the next turn arrives as entries
            (set-window-buffer (selected-window) buf)
            (drgnx-agent-panel-sync-windows)
            (should (buffer-local-value 'drgnx-agent-panel--subscribed buf))
            (drgnx-agents-mirror-test--settle (lambda () (buffer-local-value 'drgnx-agent-panel--loaded buf)) "the first page")
            (drgnx-agent-panel-hub-test--turn id "shown turn")
            (drgnx-agents-mirror-test--settle
             (lambda () (string-search "You said: shown turn" (drgnx-agent-panel-hub-test--entry-text buf)))
             "the shown turn's entries in the panel")
            ;; hidden again: unsubscribed, and the next turn's entries do not come
            (set-window-buffer (selected-window) other)
            (drgnx-agent-panel-sync-windows)
            (should-not (buffer-local-value 'drgnx-agent-panel--subscribed buf))
            (drgnx-agent-panel-hub-test--turn id "later turn")
            (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "the later turn over")
            (should-not (string-search "later turn" (drgnx-agent-panel-hub-test--entry-text buf))))
        (kill-buffer other)))))

(ert-deftest drgnx-agent-panel/pages-back-50-steps ()
  ;; the page size is lowered to 2 so that three tool turns make two pages; 50 is the hub's own limit for it
  (drgnx-agent-panel-hub-test--with
    (let ((drgnx-agent-panel-page-steps 2) (buf (drgnx-agent-panel-buffer id)))
      (dotimes (i 3)
        (drgnx-agent-panel-hub-test--turn id (format "tool %d" i))
        (drgnx-agents-mirror-test--settle (lambda () (drgnx-agents-mirror-test--idle-mirror id)) "a tool turn over"))
      (set-window-buffer (selected-window) buf)
      (drgnx-agent-panel-sync-windows)
      (drgnx-agents-mirror-test--settle (lambda () (buffer-local-value 'drgnx-agent-panel--loaded buf)) "the last page")
      (let ((first-count (hash-table-count (buffer-local-value 'drgnx-agent-panel--steps buf))))
        (should (<= first-count 2))
        (should (buffer-local-value 'drgnx-agent-panel--more buf))
        (with-current-buffer buf (drgnx-agent-panel-older))
        (drgnx-agents-mirror-test--settle
         (lambda () (> (hash-table-count (buffer-local-value 'drgnx-agent-panel--steps buf)) first-count))
         "the page before")))))

(provide 'agent-panel-hub-test)
;;; agent-panel-hub-test.el ends here
