;;; extensions-recommend-test.el --- batch tests: what a project recommends, and that a recommendation installs nothing -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: no process, no hub.  The project's setting is stubbed at `drgnx-setting-for-root', the Explorer's listing
;; cache at `drgnx-cache-get', the modules' report is let-bound; every drgnx location is a temp directory.  See
;; docs/guide/extensions.md, "Recommended".
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-recommend" drgnx-dir) nil t)

(defvar drgnx-extensions-recommend-test--listing nil "Folder → its cached entries ((NAME . DIRP)…), as the Explorer keeps them.")

(defun drgnx-extensions-recommend-test--cache-get (name dir)
  "The stub of `drgnx-cache-get': the Explorer's listing of DIR from the test's table."
  (when (eq name 'explorer-listing)
    (when-let* ((entries (cdr (assoc (file-name-as-directory dir) drgnx-extensions-recommend-test--listing))))
      (cons '(0 0 0 0) entries))))

(defmacro drgnx-extensions-recommend-test--with (setting &rest body)
  "BODY with the project's `drgnx-extensions-recommended' SETTING, every drgnx location a temp directory, the
recommendations forgotten before and after."
  (declare (indent 1) (debug t))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ext-rec" t)))
          (process-environment (append (list (concat "XDG_STATE_HOME=" root "state") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_CACHE_HOME=" root "cache"))
                                       process-environment))
          (project (concat root "work/"))
          (drgnx-modules--report nil))
     (make-directory project t)
     (drgnx-extensions-recommend-teardown)
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-setting-for-root)
                    (lambda (var r) (and (eq var 'drgnx-extensions-recommended)
                                         (equal (file-name-as-directory r) project) ,setting)))
                   ((symbol-function 'drgnx-cache-get) #'drgnx-extensions-recommend-test--cache-get))
           ,@body)
       (drgnx-extensions-recommend-teardown)
       (delete-directory root t))))

(ert-deftest drgnx-extensions-recommend/order-project-then-autosuggest-then-flags ()
  "D: the project's own list first, then Emacs's autosuggest entries that match the files the Explorer listed here
\(a .cs file: csharp-mode), then the packages a module that is on still waits for; each once, in that order."
  (drgnx-extensions-recommend-test--with '(magit csharp-mode)
    (let ((drgnx-extensions-recommend-test--listing
           `((,project ("src" . t) ("notes.txt")) (,(concat project "src/") ("Program.cs") ("data.csv"))))
          (drgnx-modules--report '((tools/fake :status missing-packages :missing (vterm)))))
      (cl-letf (((symbol-function 'drgnx-module-disabled-p) (lambda (&rest _) nil)))
        (let ((rec (drgnx-extensions-recommended project)))
          (should (equal (mapcar #'car rec) '("pkg:magit" "pkg:csharp-mode" "pkg:csv-mode" "pkg:vterm")))
          (should (string-search "this project" (cdr (assoc "pkg:magit" rec))))
          (should (string-search "data.csv" (cdr (assoc "pkg:csv-mode" rec))))
          (should (string-search "tools/fake" (cdr (assoc "pkg:vterm" rec)))))))))

(ert-deftest drgnx-extensions-recommend/no-scan-in-a-hook ()
  "D: with no listing in the Explorer's cache the autosuggest part is empty, and no folder is read."
  (drgnx-extensions-recommend-test--with nil
    (let ((reads 0))
      (cl-letf (((symbol-function 'directory-files) (lambda (&rest _) (cl-incf reads) nil))
                ((symbol-function 'directory-files-recursively) (lambda (&rest _) (cl-incf reads) nil))
                ((symbol-function 'directory-files-and-attributes) (lambda (&rest _) (cl-incf reads) nil)))
        (should-not (drgnx-extensions-recommended project)))
      (should (= reads 0)))))

(ert-deftest drgnx-extensions-recommend/the-notice-shows-once-per-project ()
  "D: the first look at a project that recommends extensions posts one notice with a Show command; the next looks at
it post none; another project gets its own."
  (drgnx-extensions-recommend-test--with '(magit forge eat)
    (let ((notices nil))
      (cl-letf (((symbol-function 'drgnx-notify) (lambda (&rest args) (push args notices))))
        (should (drgnx-extensions-recommend-notice project))
        (should-not (drgnx-extensions-recommend-notice project))
        (should-not (drgnx-extensions-recommend-notice project)))
      (should (= 1 (length notices)))
      (should (equal (nth 2 (car notices)) "This project recommends 3 extensions"))
      (should (equal (plist-get (nthcdr 3 (car notices)) :command) (list 'drgnx-extensions-show-recommended project))))))

(ert-deftest drgnx-extensions-recommend/a-repository-cannot-install ()
  "D: a repository's shared settings recommend x: the recommendation, its notice and the list's Recommended section
queue nothing and start no job; x is only a row with your Install button."
  (drgnx-extensions-recommend-test--with '(x)
    (let ((calls nil))
      (cl-letf (((symbol-function 'drgnx-extensions-jobs-queue) (lambda (&rest a) (push (cons 'queue a) calls)))
                ((symbol-function 'drgnx-extensions-jobs-run) (lambda (&rest a) (push (cons 'run a) calls)))
                ((symbol-function 'drgnx-exec-start) (lambda (&rest a) (push (cons 'exec a) calls)))
                ((symbol-function 'drgnx-notify) #'ignore))
        (should (equal (mapcar #'car (drgnx-extensions-recommended project)) '("pkg:x")))
        (drgnx-extensions-recommend-notice project)
        (let ((drgnx-extensions-recommend--root project))
          (should (equal (plist-get (plist-get (drgnx-extensions-list--section-params 'recommended) :filters) :ids)
                         ["pkg:x"]))))
      (should-not calls)
      (should-not (file-exists-p (expand-file-name "extensions/pending.eld" (drgnx-state-dir)))))))

;;; extensions-recommend-test.el ends here
