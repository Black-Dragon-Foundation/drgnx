;;; leaky-key.el --- fixture: a test file that leaves a global key, a header line and a frame parameter behind -*- lexical-binding: t -*-
;; Copied into a temp suite as a *-test.el by test/unit/run-ert-test.el.
;; a command of its own: a key bound to an Emacs function (`ignore', subr.el) is one the allowlist leaves out, as keys an
;; Emacs library binds when it loads
(defun file-leak-fixture-command () "A command the fixture binds." (interactive))

(ert-deftest file-leak-fixture/leaves-a-global-key ()
  (global-set-key (kbd "C-c C-x C-l") #'file-leak-fixture-command)
  (setq-default header-line-format "LEAKED-HEADER")
  (set-frame-parameter nil 'file-leak-fixture-parameter 'left-behind)
  (should t))
