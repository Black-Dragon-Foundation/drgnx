;;; palette-labels-test.el --- batch test: no palette label repeats its group -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: the registry of the core commands and every stage's modules whose packages need nothing installed.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)

(ert-deftest drgnx-palette-labels/no-label-repeats-its-group ()
  "The palette shows a command as its category and its title (`drgnx-commands-label'), so a title that starts with
its own category reads twice (\"Runners: Runners: Rotate Cloud CA\")."
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (trusted-content trusted-content))
    (drgnx--core-commands)
    (drgnx-test-with-modules nil
      :stages drgnx-modules-stages :packages 'hidden
      (should (> (length (drgnx-commands-all)) 50))
      (should-not (cl-loop for c in (drgnx-commands-all)
                           for category = (drgnx-cmd-category c)
                           when (and (stringp category)
                                     (string-prefix-p (concat category ": ") (drgnx-cmd-title c)))
                           collect (drgnx-commands-label c))))))

(provide 'palette-labels-test)
;;; palette-labels-test.el ends here
