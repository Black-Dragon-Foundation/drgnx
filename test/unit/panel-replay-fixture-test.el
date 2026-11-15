;;; panel-replay-fixture-test.el --- the panel-replay fixture leaves the modules as it found them -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the fixture's module step and its down.  A session that had not run tools/agent-panel
;; (a UI session: its idle stage has not come) has the module turned on by the fixture's up and off again by its down,
;; so no setup of the module's is left for the rows after (the look rows' clean-session check names one).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(defvar drgnx-agents--sessions)
(declare-function drgnx-panel-replay--module-on "panel-replay-fixture" ())
(declare-function drgnx-panel-replay-down "panel-replay-fixture" ())
(declare-function drgnx-test-modules--load "modules-fixture" (entries))

(defun drgnx-panel-replay-test--hooked-p ()
  "Whether the module's window hook is on `window-buffer-change-functions', globally or in any buffer (a session's jank
guard wraps it, so the hook's printed form is searched)."
  (let ((name "drgnx-tools/agent-panel--panel-windows"))
    (or (string-search name (prin1-to-string (default-value 'window-buffer-change-functions)))
        (seq-some (lambda (b) (and (local-variable-p 'window-buffer-change-functions b)
                                   (string-search name (prin1-to-string
                                                        (buffer-local-value 'window-buffer-change-functions b)))))
                  (buffer-list)))))

(ert-deftest drgnx-panel-replay/down-turns-off-the-module-up-turned-on ()
  (drgnx-test-with-modules nil
    (let ((drgnx-agents--sessions nil))
      (drgnx-test-modules--load '(tools/agent-panel))   ; defined and not running, as in a UI session
      (should-not (drgnx-module-running-p 'tools/agent-panel))
      (should-not (drgnx-panel-replay-test--hooked-p))
      (unwind-protect
          (progn
            (drgnx-panel-replay--module-on)
            (should (drgnx-module-running-p 'tools/agent-panel))
            (should (drgnx-panel-replay-test--hooked-p))
            (drgnx-panel-replay-down)
            (should-not (drgnx-module-running-p 'tools/agent-panel))
            (should-not (drgnx-panel-replay-test--hooked-p)))
        (drgnx-module-teardown 'tools/agent-panel)))))

(ert-deftest drgnx-panel-replay/down-leaves-a-module-that-ran-before ()
  "A session that runs the module already keeps it after the down."
  (drgnx-test-with-modules '(tools/agent-panel)
    (let ((drgnx-agents--sessions nil))
      (should (drgnx-module-running-p 'tools/agent-panel))
      (drgnx-panel-replay--module-on)
      (drgnx-panel-replay-down)
      (should (drgnx-module-running-p 'tools/agent-panel))
      (should (drgnx-panel-replay-test--hooked-p)))))

(provide 'panel-replay-fixture-test)
;;; panel-replay-fixture-test.el ends here
