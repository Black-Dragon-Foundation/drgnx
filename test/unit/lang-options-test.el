;;; lang-options-test.el --- batch tests: lang/eglot sets its options when eglot loads, never over the user's -*- lexical-binding: t -*-
;; Its own file (its own Emacs): the test needs eglot not loaded yet, and other tests of lang/eglot load it.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(defvar eglot-sync-connect)
(defvar eglot-autoshutdown)

(ert-deftest drgnx-lang/an-option-set-before-eglot-loads-stays-and-the-rest-come-back ()
  ;; the library loads after the setup (the deferred path): a user's value survives, the module's own is undone
  (skip-unless (not (featurep 'eglot)))
  (set-default 'eglot-sync-connect 5)                                  ; the user's, before eglot is loaded
  (drgnx-test-with-modules '(lang/eglot)
    (require 'eglot)
    (should (eql eglot-sync-connect 5))
    (should (eq eglot-autoshutdown t)))
  (should (eql eglot-sync-connect 5))
  (should (boundp 'eglot-autoshutdown))
  (should-not eglot-autoshutdown))                             ; eglot's own default, bound

;;; lang-options-test.el ends here
