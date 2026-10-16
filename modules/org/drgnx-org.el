;;; drgnx-org.el --- Module org/org: capture and agenda -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Org's capture and agenda, on the keys people know (C-c c, C-c a).  See docs/modules.md.

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)

(drgnx-module-define 'org/org
  :doc "Org capture and agenda."
  :stage 'startup
  :setup
  (lambda ()
    (drgnx-command-define 'org-capture :category "Org" :title "Capture" :command #'org-capture
      :doc "Capture a note or task")
    (drgnx-command-define 'org-agenda :category "Org" :title "Agenda Menu" :command #'org-agenda
      :doc "The agenda views")))

(provide 'drgnx-org)
;;; drgnx-org.el ends here
