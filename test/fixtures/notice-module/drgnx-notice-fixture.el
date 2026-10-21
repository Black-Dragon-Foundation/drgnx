;;; drgnx-notice-fixture.el --- an external module whose setup fails (notices GUI test) -*- lexical-binding: t -*-

;;; Commentary:
;; Listed in modules.eld as an `:external' module by test/ui/notices-ui-test.el.  Loading it defines the module
;; `test/fails'; running the module signals, so drgnx has a failed module to show.

;;; Code:
(require 'drgnx-modules)

(drgnx-module-define 'test/fails
                     :doc "A fixture module whose setup signals."
                     :stage 'startup
                     :setup (lambda () (error "fixture failure")))

(provide 'drgnx-notice-fixture)
;;; drgnx-notice-fixture.el ends here
