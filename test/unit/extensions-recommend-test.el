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

(ert-deftest drgnx-extensions-recommend/ids-make-no-reasons ()
  "D: the Recommended section's ids (asked at each open of the list) are the same ids, and taking them makes no
reason text: the characters allocated are the ids' own, with a path's worth of slack."
  (drgnx-extensions-recommend-test--with '(magit)
    (let* ((missing (mapcar (lambda (i) (intern (format "waiting-package-%d" i))) (number-sequence 1 50)))
           (drgnx-modules--report `((tools/a-module-with-a-long-name :status missing-packages :missing ,missing)))
           (drgnx-extensions-recommend--root project))
      (cl-letf (((symbol-function 'drgnx-module-disabled-p) (lambda (&rest _) nil)))
        (should (equal (drgnx-extensions-recommend-ids) (mapcar #'car (drgnx-extensions-recommended project))))
        (let* ((before (nth 4 (memory-use-counts)))
               (ids (drgnx-extensions-recommend-ids))
               (chars (- (nth 4 (memory-use-counts)) before)))
          (should (= (length ids) 51))
          (should (<= chars (+ (apply #'+ (mapcar #'length ids)) 200))))))))

(ert-deftest drgnx-extensions-recommend/the-hub-holds-the-set ()
  "D: the Recommended set (1,000 packages modules wait for) goes to the hub once, at a version; an open after it names
that version and makes no id string; a change to what it is made from (a module's report) sends the next version."
  (drgnx-extensions-recommend-test--with nil
    (let* ((missing (mapcar (lambda (i) (intern (format "waiting-package-%d" i))) (number-sequence 1 1000)))
           (drgnx-modules--report `((tools/many :status missing-packages :missing ,missing)))
           (drgnx-extensions-recommend--root project) (sent nil))
      (cl-letf (((symbol-function 'drgnx-module-disabled-p) (lambda (&rest _) nil))
                ((symbol-function 'drgnx-hub-call) (lambda (method params &rest _) (push (cons method params) sent))))
        (let ((v1 (plist-get (plist-get (drgnx-extensions-list--section-params 'recommended) :filters) :recommended)))
          (should (integerp v1))
          (should (equal (mapcar #'car sent) '("extensions/recommended")))
          (should (= (length (plist-get (cdar sent) :ids)) 1000))
          (should (eql (plist-get (cdar sent) :version) v1))
          (let* ((before (nth 4 (memory-use-counts)))
                 (params (drgnx-extensions-list--section-params 'recommended))
                 (chars (- (nth 4 (memory-use-counts)) before)))
            (should (eql (plist-get (plist-get params :filters) :recommended) v1))
            (should-not (plist-get (plist-get params :filters) :ids))
            (should (< chars 100))
            (should (= (length sent) 1)))
          (drgnx-modules--record 'tools/other 'setup 1 'missing-packages nil '(one-more))
          (let ((v2 (plist-get (plist-get (drgnx-extensions-list--section-params 'recommended) :filters) :recommended)))
            (should (> v2 v1))
            (should (= (length sent) 2))
            (should (= (length (plist-get (cdar sent) :ids)) 1001))))))))

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
        (let ((drgnx-extensions-recommend--root project) (sent nil))
          (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params &rest _) (push (cons method params) sent))))
            (should (plist-get (plist-get (drgnx-extensions-list--section-params 'recommended) :filters) :recommended)))
          (should (equal (plist-get (cdr (assoc "extensions/recommended" sent)) :ids) ["pkg:x"]))))
      (should-not calls)
      (should-not (file-exists-p (expand-file-name "extensions/pending.eld" (drgnx-state-dir)))))))

;;; extensions-recommend-test.el ends here
