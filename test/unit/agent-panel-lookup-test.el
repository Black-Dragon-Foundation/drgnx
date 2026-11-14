;;; agent-panel-lookup-test.el --- the agent panel's session lookup is a table -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub; the hub client's calls go nowhere.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel--panel-for "drgnx-agent-panel")

(ert-deftest drgnx-agent-panel/panel-for-is-a-table-lookup ()
  (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
    (drgnx-test-with-modules '(tools/agent-panel)
      (let ((a (drgnx-agent-panel-buffer "s-a")) (b (drgnx-agent-panel-buffer "s-b")))
        (unwind-protect
            (progn
              ;; no walk over the buffers: one event, one lookup
              (cl-letf (((symbol-function 'buffer-list) (lambda (&rest _) (error "walked the buffers"))))
                (should (eq a (drgnx-agent-panel--panel-for "s-a")))
                (should (eq b (drgnx-agent-panel--panel-for "s-b")))
                (should-not (drgnx-agent-panel--panel-for "s-none")))
              ;; a killed panel is no longer found, and its entry goes
              (kill-buffer a)
              (should-not (drgnx-agent-panel--panel-for "s-a"))
              (should (eq b (drgnx-agent-panel--panel-for "s-b"))))
          (mapc (lambda (x) (when (buffer-live-p x) (kill-buffer x))) (list a b)))))))
