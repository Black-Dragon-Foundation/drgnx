;;; work-view-test.el --- Scenarios: the Work space is a view in the editor -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; SPDX-License-Identifier: GPL-3.0-or-later
;; UX audit S1-1 (2026-11-16): opening the Work space kept you in a full-window layout where a file opened with
;; Ctrl+P never showed.  The reference is VS Code: a view is a tab; the Explorer and the editor groups stay, and
;; Quick Open always shows the file.  See docs/develop/scenarios.md.

(require 'ert)
(require 'drgnx-scenario)
(require 'drgnx-uitest)

(declare-function drgnx-driver--key "drgnx" (id))
(declare-function drgnx-layouts-current "drgnx-layouts" (&optional frame))
(declare-function drgnx-wb-sidebar-showing-p "drgnx-wb")
(declare-function drgnx-module-running-p "drgnx-modules" (name))
(declare-function drgnx-modules--run-one "drgnx-modules" (name spec stage))
(defvar drgnx-modules--table)
(defvar drgnx-modules--report)

(defvar drgnx-work-space--lens-modes)

(defun drgnx-scn-work--lens-shown-p ()
  "Whether an editor window shows a Work lens."
  (seq-some (lambda (w) (memq (buffer-local-value 'major-mode (window-buffer w)) drgnx-work-space--lens-modes))
            (window-list nil 'nomini)))

(ert-deftest drgnx-scenario/work-is-a-view-and-quick-open-shows-the-file ()
  "Work: Open keeps the Explorer and the layout; Ctrl+P over the Work map shows the file in that window."
  (drgnx-scenario-settling
   (drgnx-scenario-load-driver)
   (drgnx-scenario-with-fixture (root 'basic)
     (drgnx-driver-reset)
     (drgnx-driver-open-file (expand-file-name "src/app/main.py" root))
     (drgnx-driver-show-sidebar)
     (drgnx-uitest-run nil)
     ;; the layouts module on, as in a user's session (its stage is idle: a scenario can start before it ran)
     (unless (drgnx-module-running-p 'tools/layouts)
       (when-let* ((spec (cdr (assq 'tools/layouts drgnx-modules--table))))
         (drgnx-modules--run-one 'tools/layouts spec 'idle)))
     (drgnx-scenario-require (drgnx-module-running-p 'tools/layouts)
                             (format "module tools/layouts running (in the table: %s; report: %S)"
                                     (and (assq 'tools/layouts drgnx-modules--table) t)
                                     (alist-get 'tools/layouts drgnx-modules--report)))
     (let ((layout (and (fboundp 'drgnx-layouts-current) (drgnx-layouts-current))))
       ;; the Work space, by its key (Ctrl+K T in the VS Code profile)
       (drgnx-uitest-run (drgnx-uitest-key-events (drgnx-driver--key 'work-view)))
       (drgnx-uitest-run nil)
       (should (drgnx-scn-work--lens-shown-p))
       (should (drgnx-wb-sidebar-showing-p))
       (should (eq layout (and (fboundp 'drgnx-layouts-current) (drgnx-layouts-current))))
       ;; Ctrl+P, a file's name, RET: the file is on screen, in the window the map was in
       (let ((editor (seq-find (lambda (w) (memq (buffer-local-value 'major-mode (window-buffer w))
                                                 drgnx-work-space--lens-modes))
                               (window-list nil 'nomini))))
         ;; one run: a run ends its recursive edit when settled, which would end Quick Open's minibuffer; the pause
         ;; lets the hub's ranked rows arrive before RET
         (drgnx-uitest-run (append (drgnx-uitest-key-events (drgnx-driver--key 'go-quick-open))
                                   (list (cons 'drgnx-uitest-pause 0.5))
                                   (drgnx-uitest-type-events "README.md")
                                   (list (cons 'drgnx-uitest-pause 2))
                                   (drgnx-uitest-key-events "RET"))
                           20)
         (drgnx-uitest-run nil)
         (let ((readme (get-file-buffer (expand-file-name "README.md" root))))
           (should readme)
           (should (get-buffer-window readme))
           (should (eq (window-buffer editor) readme)))
         (should (drgnx-wb-sidebar-showing-p))
         (should (eq layout (and (fboundp 'drgnx-layouts-current) (drgnx-layouts-current)))))))))

;;; work-view-test.el ends here
