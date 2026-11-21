;;; extensions-builtin-test.el --- batch tests: the Extensions list's Built-in section (packages drgnx provides) -*- lexical-binding: t -*-
;; test-class: det
;; The hub is stubbed (`cl-letf'); nothing here reaches a process, a network or the user's packages.  The section's rows
;; are the hub's (extensions/catalog.rs tests); this file covers what the editor sends and asks.  See
;; docs/guide/extensions.md.
(require 'ert)
(require 'cl-lib)
(require 'package)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions" drgnx-dir) nil t)

(defun drgnx-extensions-builtin-test--section (name)
  "The section NAME of the list's params as the editor builds them now."
  (seq-find (lambda (s) (equal (plist-get s :name) name))
            (append (plist-get (drgnx-extensions-list--list-params) :sections) nil)))

(ert-deftest drgnx-extensions-builtin/the-list-has-a-built-in-section-after-installed-closed-by-default ()
  (drgnx-extensions-list--reset)
  (let* ((names (mapcar (lambda (s) (plist-get s :name))
                        (append (plist-get (drgnx-extensions-list--list-params) :sections) nil)))
         (s (drgnx-extensions-builtin-test--section "bundled")))
    (should s)
    (should (equal (plist-get s :title) "Built-in"))
    (should (eq (plist-get (plist-get (plist-get s :search) :filters) :bundled) t))
    (should (eq (plist-get s :collapsed) t))
    (should (< (seq-position names "installed") (seq-position names "bundled")))))

(ert-deftest drgnx-extensions-builtin/the-section-opens-and-closes-from-its-header ()
  (drgnx-extensions-list--reset)
  (let ((asked 0))
    (cl-letf (((symbol-function 'drgnx-extensions-list--ask) (lambda (&rest _) (cl-incf asked))))
      (with-temp-buffer
        (insert (propertize "Built-in (3)" 'drgnx-work-id "section:bundled"))
        (goto-char (point-min))
        (drgnx-extensions-toggle-section)
        (should-not (eq (plist-get (drgnx-extensions-builtin-test--section "bundled") :collapsed) t))
        (drgnx-extensions-toggle-section)
        (should (eq (plist-get (drgnx-extensions-builtin-test--section "bundled") :collapsed) t))
        (should (= asked 2))
        (erase-buffer)
        (insert (propertize "Installed (3)" 'drgnx-work-id "section:installed"))
        (goto-char (point-min))
        (should-error (drgnx-extensions-toggle-section) :type 'user-error)))))

(ert-deftest drgnx-extensions-builtin/a-module-sends-the-packages-it-names-with-their-descriptions ()
  (let* ((package-alist (list (list 'drgnx-test-pkg (package-desc-create :name 'drgnx-test-pkg :version '(1)
                                                                         :summary "Does a test thing."))))
         (drgnx-modules--table '((tools/test :doc "A test module." :packages (drgnx-test-pkg other-pkg))))
         (rows (append (drgnx-extensions--module-rows) nil))
         (me (car rows)))
    (should (equal (append (plist-get me :packages) nil) '("drgnx-test-pkg" "other-pkg")))
    (should (equal (append (plist-get me :summaries) nil) (list (vector "drgnx-test-pkg" "Does a test thing."))))))

(ert-deftest drgnx-extensions-builtin/disable-module-turns-off-the-module-that-names-the-package ()
  (let ((drgnx-modules--table '((tools/test :packages (drgnx-test-pkg))))
        off)
    (cl-letf (((symbol-function 'drgnx-extensions-list--id-at-point) (lambda () "bundled:drgnx-test-pkg"))
              ((symbol-function 'drgnx-module-running-p) (lambda (m) (eq m 'tools/test)))
              ((symbol-function 'drgnx-modules-turn-off) (lambda (m &rest _) (push m off) nil)))
      (drgnx-extensions-disable-module)
      (should (equal off '(tools/test)))
      (cl-letf (((symbol-function 'drgnx-extensions-list--id-at-point) (lambda () "pkg:magit")))
        (should-error (drgnx-extensions-disable-module) :type 'user-error)))))

;;; extensions-builtin-test.el ends here
