;;; lint-with-modules-pending.eld --- sites that bind a module's name around drgnx-test-with-modules, not swept yet  -*- mode: lisp-data -*-
;; Read by test/unit/lint-with-modules-test.el.  Strings "FILE: NAME": FILE is relative to the checkout, NAME the
;; function or variable a module defines that the test binds (let / cl-letf) outside the `drgnx-test-with-modules'
;; form, where the helper's load of the module file can undo it.  The register only shrinks: move the binding into the
;; body (or require the library first), then delete the line; a line whose site is gone fails the lint.
(
 "test/unit/ai-ghost-test.el: drgnx-keys-last"
 "test/unit/job-ui-test.el: drgnx-job-ui--running"
 "test/unit/mod-editing-test.el: child-frame-chrome"
 "test/unit/mod-live-test.el: drgnx-live--browser"
 "test/unit/mod-live-test.el: drgnx-live--given"
 "test/unit/mod-remote-test.el: eglot--servers-by-project"
 "test/unit/mod-terminal-test.el: drgnx-terminal--notice-shown"
 "test/unit/mod-tty-frames-test.el: xterm-mouse-mode"
 "test/unit/mod-tty-frames-test.el: drgnx-tty-mouse"
 "test/unit/mod-tty-popups-test.el: standard-display-table"
 "test/unit/terminal-keys-test.el: drgnx-keys-last"
 "test/unit/terminal-keys-test.el: drgnx-surfaces-cheatsheet-sections"
 "test/unit/terminal-keys-test.el: eat-semi-char-non-bound-keys"
 "test/unit/terminal-keys-test.el: eat-semi-char-mode-map"
 "test/unit/terminal-keys-test.el: drgnx-terminal--eat-default-non-bound"
 "test/unit/tty-fallback-test.el: drgnx-keys-last"
 )
