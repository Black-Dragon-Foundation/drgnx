;;; config-doc-test.el --- batch tests: the generated reference of drgnx's config files -*- lexical-binding: t -*-
;; The reference is generated in a child `emacs --batch -Q' (as docs/develop/core.md says), so this process's own
;; definitions never reach it; the test waits for the child under a 30 s bound.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(add-to-list 'load-path (expand-file-name "harness" drgnx-dir))
(require 'drgnx-config-doc)

(defun drgnx-config-doc-test--command ()
  "The command docs/develop/core.md gives for regenerating the reference, on one line."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents (expand-file-name "docs/develop/core.md" drgnx-dir)))
    (goto-char (point-min))
    (unless (re-search-forward "^```sh\n\\(emacs --batch [^`]*drgnx-config-doc[^`]*\\)```" nil t)
      (ert-fail "docs/develop/core.md does not give the command that regenerates the reference"))
    (string-trim (replace-regexp-in-string "\\\\\n[ \t]*" "" (match-string 1)))))

(defun drgnx-config-doc-test--run-documented (command)
  "Run the shell COMMAND from the checkout with HOME and XDG_* in a temp folder (tests never reach ~)."
  (let* ((home (make-temp-file "drgnx-config-doc-home" t))
         (default-directory drgnx-dir)
         (buf (generate-new-buffer " *config-doc-cmd*" t))
         (process-environment
          (append (list (concat "HOME=" home) (concat "XDG_CONFIG_HOME=" home "/config")
                        (concat "XDG_STATE_HOME=" home "/state") (concat "XDG_DATA_HOME=" home "/data")
                        (concat "XDG_CACHE_HOME=" home "/cache"))
                  process-environment))
         (proc (make-process :name "drgnx-config-doc-cmd" :buffer buf :noquery t :command (list "sh" "-c" command)))
         (deadline (+ (float-time) 60)))
    (unwind-protect
        (progn
          (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output proc 0.05))
          (should (eq (process-status proc) 'exit))
          (should (eql (process-exit-status proc) 0)))
      (delete-directory home t)
      (kill-buffer buf))))

(defun drgnx-config-doc-test--child (form)
  "Run FORM in `emacs --batch -Q' with the doc generator loaded, from the checkout; its standard output."
  (let* ((default-directory drgnx-dir)
         (buf (generate-new-buffer " *config-doc*" t))
         (proc (make-process
                :name "drgnx-config-doc" :buffer buf :noquery t :stderr (generate-new-buffer " *config-doc-err*" t)
                :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                               "--eval" "(setq load-prefer-newer t)"
                               "-L" "core" "-L" "wb" "-L" "harness" "-L" "modules/tools" "-L" "modules/editor" "-l" "drgnx-config-doc"
                               "--eval" (prin1-to-string form))))
         (deadline (+ (float-time) 30)))
    (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output proc 0.05))
    (should (eq (process-status proc) 'exit))
    (should (eql (process-exit-status proc) 0))
    (with-current-buffer buf (buffer-string))))

(ert-deftest drgnx-config-doc/the-reference-matches ()
  ;; runs the command docs/develop/core.md gives (output swapped for a temp file), so the documented command is the one
  ;; that works
  (let* ((tmp (make-temp-file "drgnx-config-doc" nil ".md"))
         (documented (drgnx-config-doc-test--command))
         (command (replace-regexp-in-string "docs/reference/config\\.md" tmp documented t t))
         (read (lambda (file)
                 (with-temp-buffer
                   (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
                   (buffer-string)))))
    (should (string-search tmp command))
    (should (string-search "drgnx-config-doc-regenerate" documented))
    (unwind-protect
        (progn
          ;; a stale .elc must not hide a changed source
          (drgnx-config-doc-test--run-documented
           (replace-regexp-in-string "emacs --batch -Q" "emacs --batch -Q --eval '(setq load-prefer-newer t)'" command t t))
          (unless (equal (funcall read tmp) (funcall read (expand-file-name "docs/reference/config.md" drgnx-dir)))
            (ert-fail (format "docs/reference/config.md is out of date; regenerate it with:\n  %s" documented))))
      (delete-file tmp))))

(ert-deftest drgnx-config-doc/every-definition-has-a-doc ()
  (let ((missing (car (read-from-string
                       (drgnx-config-doc-test--child
                        '(prin1 (progn (drgnx-config-doc-load)
                                       (seq-remove (lambda (name)
                                                     (let ((doc (plist-get (drgnx-config-definition name) :doc)))
                                                       (and (stringp doc) (not (string-empty-p doc)))))
                                                   (drgnx-config-names)))))))))
    (should-not missing)))

(ert-deftest drgnx-config-doc/the-markdown-describes-a-definition ()
  (drgnx-test-with-config
    (drgnx-config-define 'doc-test-a :file "zz-a.eld" :dir 'state :reload 'start
                         :schema '(plist (:a integer "A | number" :required t) (:b string "A string"))
                         :default '(:a 1) :doc "The first test file.")
    (drgnx-config-define 'doc-test-b :file "zz-b.eld" :dir 'project :last-good nil
                         :schema '(plist (:c boolean "A flag")) :doc "The second test file.")
    (drgnx-config-define 'doc-test-c :file "zz-c.eld" :last-good nil
                         :schema '(plist (:d boolean "A flag")) :doc "The third test file.")
    (drgnx-config-define 'doc-test-d :file "zz-d.eld" :last-good nil :on-mistake "drgnx sync stops until it is fixed"
                         :schema '(plist (:e boolean "A flag")) :doc "The fourth test file.")
    (let ((text (drgnx-config-doc-markdown)))
      (should (string-prefix-p "# " text))
      (should (string-match-p "^## zz-d\\.eld\n\nFolder: config\\. Format: 1\\. Read: when it changes\\. On a mistake: drgnx sync stops until it is fixed\\."
                              text))
      (should (string-suffix-p "\n" text))
      (should (string-match-p
               (concat "^## zz-a\\.eld\n\n"
                       "Folder: state\\. Format: 1\\. Read: at start\\. "
                       "On a mistake: its last good copy, else the defaults\\.\n\n"
                       "The first test file\\.\n\n"
                       "| Key | Type | Required | What |\n| --- | --- | --- | --- |\n"
                       "| `:a` | integer | yes | A \\\\| number |\n"
                       "| `:b` | string | no | A string |\n")
               text))
      (should (string-match-p "^## zz-b\\.eld\n\nFolder: project\\. Format: 1\\. Read: when it changes\\. On a mistake: refused\\."
                              text))
      (should (string-match-p "On a mistake: the defaults\\." text))
      ;; sorted by name
      (should (< (string-match "## zz-a.eld" text) (string-match "## zz-b.eld" text) (string-match "## zz-c.eld" text))))
    (let ((file (expand-file-name "out/config.md" drgnx-test-config-root)))
      (make-directory (file-name-directory file) t)
      (drgnx-config-doc-write file)
      (should (equal (with-temp-buffer (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file))
                                       (buffer-string))
                     (drgnx-config-doc-markdown))))))
