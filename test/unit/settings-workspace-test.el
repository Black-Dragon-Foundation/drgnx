;;; settings-workspace-test.el --- batch tests: the workspace layers W1 and W2 -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Every test runs under `drgnx-test-with-config' (a temp config folder) with a project folder beside it, fresh
;; workspace caches and `inhibit-interaction' t around every open: a prompt would signal.  Files are written as an
;; editor writes them (a new file renamed over the old one), so a stamp always changes.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-setting)
(require 'drgnx-settings-prov)
(require 'drgnx-settings-workspace)
(require 'drgnx-settings-live)

(defvar drgnx-swt--root nil "The test's project folder (a truename ending in a slash).")
(defvar drgnx-swt--buffers nil "The buffers a test opened.")
(defvar drgnx-swt-risky-function nil "A variable risky by its name.")
(defvar drgnx-swt--seen nil "What a W2 :eval saw.")

(defconst drgnx-swt--settings '(drgnx-swt--global drgnx-swt--never drgnx-swt--limit)
  "The fixture settings, declared fresh by `drgnx-swt--with'.")

(defun drgnx-swt--declare ()
  "Declare the fixture settings."
  (eval '(drgnx-defsetting drgnx-swt--global 1 "One value for all of Emacs." :type 'integer :group 'drgnx-swt
           :scope 'global)
        t)
  (eval '(drgnx-defsetting drgnx-swt--never 1 "Never from a workspace." :type 'integer :group 'drgnx-swt
           :workspace 'never)
        t)
  (eval '(drgnx-defsetting drgnx-swt--limit 50 "A project's limit, lower only." :type 'integer :group 'drgnx-swt
           :safe #'integerp :scope 'project :merge 'lower-only)
        t))

(defun drgnx-swt--undeclare ()
  "Take the fixture settings away."
  (dolist (var drgnx-swt--settings)
    (makunbound var)
    (dolist (p '(standard-value theme-value saved-value custom-type drgnx-setting safe-local-variable))
      (put var p nil))
    (setq drgnx-setting--names (delq var drgnx-setting--names))))

(defmacro drgnx-swt--with (&rest body)
  "BODY with a temp config folder, the project folder `drgnx-swt--root' beside it, fresh workspace caches and the
fixture settings; the buffers it opened are killed after."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-config
     (let ((drgnx-settings-workspace--docs (make-hash-table :test 'equal))
           (drgnx-settings-workspace--seen (make-hash-table :test 'equal))
           (drgnx-settings-workspace-filter-function #'drgnx-settings-workspace-safe-only)
           (drgnx-swt--root (progn (make-directory (expand-file-name "proj" drgnx-test-config-root) t)
                                   (file-name-as-directory
                                    (file-truename (expand-file-name "proj" drgnx-test-config-root)))))
           (drgnx-swt--buffers nil))
       (drgnx-swt--declare)
       (unwind-protect (progn ,@body)
         (dolist (b drgnx-swt--buffers) (when (buffer-live-p b) (kill-buffer b)))
         (drgnx-swt--undeclare)))))

(defun drgnx-swt--write (file text)
  "Make FILE hold TEXT: a new file renamed over it."
  (make-directory (file-name-directory file) t)
  (let ((tmp (concat file ".test-new")) (coding-system-for-write 'utf-8-unix))
    (write-region text nil tmp nil 'silent)
    (rename-file tmp file t)
    file))

(defun drgnx-swt--put (rel text)
  "Make REL under the project folder hold TEXT."
  (drgnx-swt--write (expand-file-name rel drgnx-swt--root) text))

(defun drgnx-swt--private-file (&optional name)
  "The private workspace file NAME (default proj.el)."
  (expand-file-name (or name "proj.el") (drgnx-settings-workspace-private-dir)))

(defun drgnx-swt--private (entries)
  "The project's private workspace file with ENTRIES (text): its entries start on line 4."
  (drgnx-swt--write (drgnx-swt--private-file)
                    (format "(drgnx-workspace-settings\n :version 1\n :roots (%S)\n%s)\n" drgnx-swt--root entries)))

(defun drgnx-swt--shared (entries)
  "The project's .drgnx/settings.el with ENTRIES (text): its entries start on line 3."
  (drgnx-swt--put ".drgnx/settings.el" (format "(drgnx-workspace-settings\n :version 1\n%s)\n" entries)))

(defun drgnx-swt--open (rel)
  "Visit REL under the project folder (made when missing), with `inhibit-interaction' t; its buffer."
  (let ((file (expand-file-name rel drgnx-swt--root)))
    (unless (file-exists-p file) (drgnx-swt--write file "hi\n"))
    (let* ((inhibit-interaction t) (b (find-file-noselect file)))
      (push b drgnx-swt--buffers)
      b)))

(defmacro drgnx-swt--in (rel &rest body)
  "BODY in the buffer visiting REL (`drgnx-swt--open')."
  (declare (indent 1) (debug t))
  `(with-current-buffer (drgnx-swt--open ,rel) ,@body))

(ert-deftest drgnx-settings-workspace/w2-wins-over-dir-locals-at-the-root ()
  (drgnx-swt--with
    (drgnx-swt--put ".dir-locals.el" "((nil . ((fill-column . 82) (tab-width . 6))))\n")
    (drgnx-swt--private " (fill-column 91)")
    (drgnx-swt--in "a.txt"
      (should (= fill-column 91))
      (should (= tab-width 6))
      (should (eq (plist-get (drgnx-settings-explain 'fill-column) :layer) 'W2))
      (should (equal (plist-get (drgnx-settings-explain 'fill-column) :source) "Workspace (proj.el:4)")))))

(ert-deftest drgnx-settings-workspace/a-nearer-dir-locals-wins-in-src ()
  (drgnx-swt--with
    (drgnx-swt--private " (fill-column 91)\n (:dir \"src/\" (tab-width 5))")
    (drgnx-swt--put "src/.dir-locals.el" "((nil . ((fill-column . 72) (tab-width . 6))))\n")
    (drgnx-swt--in "src/b.txt"
      (should (= fill-column 72))                     ; nearest directory first (D2)
      (should (= tab-width 5)))                       ; W2's (:dir "src/") wins at the same directory
    (drgnx-swt--in "a.txt"
      (should (= fill-column 91))
      (should-not (local-variable-p 'tab-width)))))

(ert-deftest drgnx-settings-workspace/w1-loses-to-dir-locals ()
  (drgnx-swt--with
    (drgnx-swt--shared " (fill-column 81)\n (tab-width 3)")
    (drgnx-swt--put ".dir-locals.el" "((nil . ((fill-column . 82))))\n")
    (drgnx-swt--in "a.txt"
      (should (= fill-column 82))
      (should (= tab-width 3))
      (should (equal (plist-get (drgnx-settings-explain 'tab-width) :source) "Shared (.drgnx/settings.el:4)")))))

(ert-deftest drgnx-settings-workspace/w2-risky-value-applies-without-a-prompt ()
  (drgnx-swt--with
    (should (risky-local-variable-p 'drgnx-swt-risky-function))
    (drgnx-swt--private " (drgnx-swt-risky-function ignore)\n (fill-column 91)")
    (drgnx-swt--in "a.txt"
      (should (local-variable-p 'drgnx-swt-risky-function))
      (should (eq drgnx-swt-risky-function 'ignore))
      (should (= fill-column 91)))))

(ert-deftest drgnx-settings-workspace/w2-eval-runs-after-its-values ()
  (drgnx-swt--with
    (drgnx-swt--private " (fill-column 93)\n (:eval (setq-local drgnx-swt--seen fill-column))")
    (drgnx-swt--in "a.txt"
      (should (= fill-column 93))
      (should (eql drgnx-swt--seen 93)))))

(ert-deftest drgnx-settings-workspace/a-global-only-entry-is-refused-with-its-line ()
  (drgnx-swt--with
    (drgnx-swt--private " (drgnx-swt--global 5)\n (fill-column 91)")
    (drgnx-swt--shared " (drgnx-swt--global 6)")
    (drgnx-swt--in "a.txt"
      (should-not (local-variable-p 'drgnx-swt--global))
      (should (= drgnx-swt--global 1))
      (should (= fill-column 91)))
    (let ((p (drgnx-settings-workspace-problems (drgnx-swt--private-file))))
      (should (= (length p) 1))
      (should (= (plist-get (car p) :line) 4))
      (should (equal (plist-get (car p) :text)
                     "drgnx-swt--global has one value for all of Emacs; set it in Settings → User")))
    (let ((p (drgnx-settings-workspace-problems (expand-file-name ".drgnx/settings.el" drgnx-swt--root))))
      (should (equal (mapcar (lambda (x) (plist-get x :line)) p) '(3))))))

(ert-deftest drgnx-settings-workspace/a-never-entry-is-refused ()
  (drgnx-swt--with
    (drgnx-swt--private " (drgnx-swt--never 5)\n (enable-local-eval t)\n (fill-column 91)")
    (drgnx-swt--in "a.txt"
      (should-not (local-variable-p 'drgnx-swt--never))
      (should-not (local-variable-p 'enable-local-eval))
      (should (= fill-column 91)))
    (let ((p (drgnx-settings-workspace-problems (drgnx-swt--private-file))))
      (should (equal (mapcar (lambda (x) (plist-get x :line)) p) '(4 5)))
      (should (cl-every (lambda (x) (string-match-p "never set by a workspace" (plist-get x :text))) p)))))

(ert-deftest drgnx-settings-workspace/slug-clash-gets-2 ()
  (drgnx-swt--with
    (let ((a (expand-file-name "a/proj/" drgnx-test-config-root))
          (b (expand-file-name "b/proj/" drgnx-test-config-root)))
      (make-directory a t)
      (make-directory b t)
      (let ((fa (drgnx-settings-workspace-file a t))
            (fb (drgnx-settings-workspace-file b t)))
        (should (equal (file-name-nondirectory fa) "proj.el"))
        (should (equal (file-name-nondirectory fb) "proj-2.el"))
        (should (equal (drgnx-settings-workspace-file b) fb))
        (should (equal (drgnx-settings-workspace-file a t) fa))
        (should-not (drgnx-settings-workspace-file (expand-file-name "c/" drgnx-test-config-root)))
        (should (equal (plist-get (drgnx-settings-doc-meta (drgnx-settings-file-read fb 'drgnx-workspace-settings))
                                  :roots)
                       (list (abbreviate-file-name (file-name-as-directory (file-truename b))))))))))

(ert-deftest drgnx-settings-workspace/enable-local-variables-nil-applies-nothing ()
  (drgnx-swt--with
    (drgnx-swt--private " (fill-column 91)")
    (drgnx-swt--shared " (tab-width 3)")
    (let ((enable-local-variables nil))
      (drgnx-swt--open "a.txt"))
    (drgnx-swt--in "a.txt"
      (should-not (local-variable-p 'fill-column))
      (should-not (local-variable-p 'tab-width)))))

(ert-deftest drgnx-settings-workspace/safe-gives-safe-values-only ()
  (drgnx-swt--with
    (drgnx-swt--private " (drgnx-swt-risky-function ignore)\n (fill-column 91)")
    (drgnx-swt--shared " (tab-width 3)")
    (let ((enable-local-variables :safe))
      (drgnx-swt--open "a.txt"))
    (drgnx-swt--in "a.txt"
      (should (= fill-column 91))
      (should (= tab-width 3))
      (should-not (local-variable-p 'drgnx-swt-risky-function)))
    ;; Emacs's own item with a risky value keeps its stock filter (batch: not applied, never a prompt).
    (drgnx-swt--put "lib/.dir-locals.el" "((nil . ((drgnx-swt-risky-function . ignore))))\n")
    (drgnx-swt--in "lib/c.txt"
      (should-not (local-variable-p 'drgnx-swt-risky-function))
      (should (= fill-column 91)))))

(ert-deftest drgnx-settings-workspace/nothing-written-to-safe-local-variable-values ()
  (drgnx-swt--with
    (let ((values safe-local-variable-values)
          (dirs safe-local-variable-directories)
          (saved (get 'safe-local-variable-values 'saved-value)))
      (drgnx-swt--private " (drgnx-swt-risky-function ignore)\n (fill-column 91)\n (:eval (setq-local drgnx-swt--seen 1))")
      (drgnx-swt--shared " (tab-width 3)")
      (drgnx-swt--put ".dir-locals.el" "((nil . ((indent-tabs-mode . nil))))\n")
      (drgnx-swt--in "a.txt"
        (should (eq drgnx-swt-risky-function 'ignore))
        (should (eql drgnx-swt--seen 1)))
      (should (equal safe-local-variable-values values))
      (should (equal safe-local-variable-directories dirs))
      (should (equal (get 'safe-local-variable-values 'saved-value) saved)))))

(ert-deftest drgnx-settings-workspace/project-scoped-lower-only ()
  (drgnx-swt--with
    (drgnx-swt--shared " (drgnx-swt--limit 80)")
    (should (= (drgnx-setting-for-root 'drgnx-swt--limit drgnx-swt--root) 50))
    (drgnx-swt--shared " (drgnx-swt--limit 20)")
    (should (= (drgnx-setting-for-root 'drgnx-swt--limit drgnx-swt--root) 20))
    (drgnx-swt--private " (drgnx-swt--limit 30)")
    (should (= (drgnx-setting-for-root 'drgnx-swt--limit drgnx-swt--root) 20))
    (drgnx-swt--private " (drgnx-swt--limit 10)")
    (should (= (drgnx-setting-for-root 'drgnx-swt--limit drgnx-swt--root) 10))
    (drgnx-swt--in "a.txt"                             ; read with a root, never a buffer value
      (should-not (local-variable-p 'drgnx-swt--limit)))))

(ert-deftest drgnx-settings-workspace/old-project-files-read-as-w1 ()
  (drgnx-swt--with
    (require 'drgnx-search-chunk)
    (unless (fboundp 'drgnx-large-files--define-config)
      (load (expand-file-name "modules/editor/drgnx-large-files" drgnx-dir) nil t))
    (drgnx-large-files--define-config)
    (drgnx-swt--put ".drgnx/search.eld" "(:include (\"*.md\") :exclude (\"vendor/\"))\n")
    (drgnx-swt--put ".drgnx/large-files.eld" "(:version 1 :ask-above 10)\n")
    (should (equal (drgnx-setting-for-root 'drgnx-search-include drgnx-swt--root) '("*.md")))
    (should (equal (drgnx-setting-for-root 'drgnx-search-exclude drgnx-swt--root) '("vendor/")))
    (should (equal (mapcar (lambda (e) (list (drgnx-settings-entry-var e) (drgnx-settings-entry-value e)
                                             (drgnx-settings-entry-merge e)))
                           (drgnx-settings-workspace--old-entries drgnx-swt--root))
                   '((drgnx-search-include ("*.md") nil) (drgnx-search-exclude ("vendor/") nil)
                     (drgnx-large-files-ask-above 10 lower-only))))
    ;; .drgnx/settings.el adds to the old file's excludes; your private file to both.
    (drgnx-swt--shared " (drgnx-search-exclude (\"build/\"))")
    (drgnx-swt--private " (drgnx-search-exclude (\"tmp/\"))")
    (should (equal (drgnx-setting-for-root 'drgnx-search-exclude drgnx-swt--root) '("vendor/" "build/" "tmp/")))))

(ert-deftest drgnx-settings-workspace/a-workspace-file-edit-applies-live ()
  (drgnx-swt--with
    (let ((drgnx-settings-changed-functions nil)
          (drgnx-settings-live--stamps (make-hash-table :test 'equal))
          (file (drgnx-swt--private " (fill-column 91)")))
      (drgnx-swt--in "a.txt" (should (= fill-column 91)))
      (should (member file (drgnx-settings-live-files)))
      (drgnx-swt--private " (fill-column 95)")
      (should (equal (drgnx-settings-live-sync file) '((nil fill-column 91 95))))
      (drgnx-swt--in "a.txt" (should (= fill-column 95)))
      (drgnx-swt--private " (tab-width 4)")
      (should (equal (drgnx-settings-live-sync file) '((nil tab-width :unset 4) (nil fill-column 95 :unset))))
      (drgnx-swt--in "a.txt"
        (should (= tab-width 4))
        (should-not (local-variable-p 'fill-column))))))

(provide 'settings-workspace-test)
;;; settings-workspace-test.el ends here
