;;; settings-compat-workspace-test.el --- compatibility rows C9, C10, C11, C19, C25: the workspace layers in a child Emacs -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Each row runs in a child Emacs under a temp HOME with only `drgnx' required, as at start: the workspace layers
;; apply because drgnx.el loads drgnx-settings-live, which loads drgnx-settings-workspace.  Every open runs with
;; `inhibit-interaction' t (a prompt would signal); `drgnx-settings-test-check-row' checks the value and the explained
;; source in the buffer.  The project is ~/proj/; your private file for it is <config>/workspaces/proj.el.

;;; Code:
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defun drgnx-settings-compat-workspace--private (entries)
  "The private workspace file of ~/proj/ with ENTRIES (text): its entries start on line 4."
  (cons "workspaces/proj.el" (format "(drgnx-workspace-settings\n :version 1\n :roots (\"~/proj/\")\n%s)\n" entries)))

(defun drgnx-settings-compat-workspace--open (file &rest forms)
  "FORMS evaluated in the buffer visiting FILE, opened with `inhibit-interaction' t."
  `(let ((inhibit-interaction t))
     (with-current-buffer (find-file-noselect ,file) ,@forms)))

(ert-deftest drgnx-settings-compat/c9-dir-locals-beats-shared-at-the-same-root ()
  (let ((r (drgnx-settings-test-child
            (list (drgnx-settings-compat-workspace--open
                   "~/proj/a.txt"
                   '(list fill-column tab-width
                          (drgnx-settings-test-check-row 'fill-column :value 82
                                                         :source "Directory-local (~/proj/.dir-locals.el:1)")
                          (drgnx-settings-test-check-row 'tab-width :value 3 :source "Shared (.drgnx/settings.el:4)"))))
            :files '(("~/proj/a.txt" . "hi\n")
                     ("~/proj/.dir-locals.el" . "((nil . ((fill-column . 82))))\n")
                     ("~/proj/.drgnx/settings.el" . "(drgnx-workspace-settings\n :version 1\n (fill-column 81)\n (tab-width 3))\n")))))
    (should-not (plist-get r :error))
    (should (equal (car (plist-get r :values)) '(82 3 t t)))))

(ert-deftest drgnx-settings-compat/c10-private-wins-at-the-root-and-src-wins-in-src ()
  (let ((r (drgnx-settings-test-child
            (list '(defvar drgnx-c10-risky-function nil)
                  (drgnx-settings-compat-workspace--open
                   "~/proj/a.txt"
                   '(list fill-column drgnx-c10-risky-function
                          (drgnx-settings-test-check-row 'fill-column :value 91 :source "Workspace (proj.el:5)")))
                  (drgnx-settings-compat-workspace--open
                   "~/proj/src/b.txt"
                   '(list fill-column drgnx-c10-risky-function
                          (drgnx-settings-test-check-row 'fill-column :value 72
                                                         :source "Directory-local (~/proj/src/.dir-locals.el:1)")))
                  '(list safe-local-variable-values safe-local-variable-directories))
            :files (list '("~/proj/a.txt" . "hi\n")
                         '("~/proj/src/b.txt" . "hi\n")
                         '("~/proj/.dir-locals.el" . "((nil . ((fill-column . 82))))\n")
                         '("~/proj/src/.dir-locals.el" . "((nil . ((fill-column . 72))))\n")
                         (drgnx-settings-compat-workspace--private
                          " (drgnx-c10-risky-function ignore)\n (fill-column 91)")))))
    (should-not (plist-get r :error))
    (should (equal (nth 1 (plist-get r :values)) '(91 ignore t)))   ; W2's risky value: no prompt
    (should (equal (nth 2 (plist-get r :values)) '(72 ignore t)))   ; nearest directory first (D2)
    (should (equal (nth 3 (plist-get r :values)) '(nil nil)))))

(ert-deftest drgnx-settings-compat/c11-file-local-variables-win-over-every-dir-local-layer ()
  (let ((r (drgnx-settings-test-child
            (list (drgnx-settings-compat-workspace--open
                   "~/proj/a.txt"
                   '(list fill-column (drgnx-settings-test-check-row 'fill-column :value 55 :source "file-local variable")))
                  (drgnx-settings-compat-workspace--open
                   "~/proj/b.txt"
                   '(list tab-width fill-column
                          (drgnx-settings-test-check-row 'tab-width :value 4 :source "file-local variable"))))
            :files (list '("~/proj/a.txt" . "-*- fill-column: 55 -*-\nhi\n")
                         '("~/proj/b.txt" . "hi\n\nLocal Variables:\ntab-width: 4\nEnd:\n")
                         '("~/proj/.drgnx/settings.el" . "(drgnx-workspace-settings\n :version 1\n (fill-column 81)\n (tab-width 3))\n")
                         (drgnx-settings-compat-workspace--private " (fill-column 91)\n (tab-width 7)")))))
    (should-not (plist-get r :error))
    (should (equal (nth 0 (plist-get r :values)) '(55 t)))
    (should (equal (nth 1 (plist-get r :values)) '(4 91 t)))))

(defconst drgnx-settings-compat-workspace--c19-files
  '(("~/proj/a.txt" . "hi\n")
    ("~/proj/.editorconfig" . "root = true\n\n[*]\nmax_line_length = 61\ntab_width = 3\n")
    ("~/proj/.dir-locals.el" . "((nil . ((tab-width . 5))))\n"))
  "C19's files: EditorConfig and .dir-locals.el at one root.")

(ert-deftest drgnx-settings-compat/c19-editorconfig-in-its-stock-order ()
  (let ((r (drgnx-settings-test-child
            (list '(progn (require 'editorconfig) (editorconfig-mode 1) t)
                  (drgnx-settings-compat-workspace--open
                   "~/proj/a.txt"
                   '(list fill-column tab-width
                          (drgnx-settings-test-check-row 'fill-column :value 61
                                                         :source "EditorConfig (~/proj/.editorconfig)")
                          (drgnx-settings-test-check-row 'tab-width :value 5
                                                         :source "Directory-local (~/proj/.dir-locals.el:1)"))))
            :files drgnx-settings-compat-workspace--c19-files))
        (stock (drgnx-settings-test-child
                (list '(progn (require 'editorconfig) (editorconfig-mode 1) t)
                      (drgnx-settings-compat-workspace--open "~/proj/a.txt" '(list fill-column tab-width)))
                :files drgnx-settings-compat-workspace--c19-files :env '("DRGNX_SETTINGS_TEST_STOCK=1"))))
    (should-not (plist-get r :error))
    (should-not (plist-get stock :error))
    (should (equal (nth 1 (plist-get r :values)) '(61 5 t t)))
    (should (equal (nth 1 (plist-get stock :values)) '(61 5)))))

(ert-deftest drgnx-settings-compat/c25-enable-local-variables-nil-and-safe ()
  (let ((r (drgnx-settings-test-child
            (list '(defvar drgnx-c25-risky-function nil)
                  `(let ((enable-local-variables nil))
                     ,(drgnx-settings-compat-workspace--open
                       "~/proj/a.txt" '(list fill-column tab-width drgnx-c25-risky-function (local-variable-p 'fill-column))))
                  `(let ((enable-local-variables :safe))
                     ,(drgnx-settings-compat-workspace--open
                       "~/proj/b.txt"
                       '(list fill-column tab-width drgnx-c25-risky-function
                              (drgnx-settings-test-check-row 'fill-column :value 91 :source "Workspace (proj.el:4)")))))
            :files (list '("~/proj/a.txt" . "hi\n")
                         '("~/proj/b.txt" . "hi\n")
                         '("~/proj/.drgnx/settings.el" . "(drgnx-workspace-settings\n :version 1\n (tab-width 3))\n")
                         (drgnx-settings-compat-workspace--private
                          " (fill-column 91)\n (drgnx-c25-risky-function ignore)")))))
    (should-not (plist-get r :error))
    (should (equal (nth 1 (plist-get r :values)) '(70 8 nil nil)))   ; no workspace layer applies
    (should (equal (nth 2 (plist-get r :values)) '(91 3 nil t)))))   ; safe values only

(provide 'settings-compat-workspace-test)
;;; settings-compat-workspace-test.el ends here
