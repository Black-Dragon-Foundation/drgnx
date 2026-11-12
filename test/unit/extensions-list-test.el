;;; extensions-list-test.el --- batch tests: the Extensions list, its query language and its live rows -*- lexical-binding: t -*-
;; test-class: det
;; The hub's search and the job layer are stubbed (`cl-letf'), the clock is virtual: nothing here reaches a process, a
;; network or the user's packages.  See docs/guide/extensions.md.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-view)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions" drgnx-dir) nil t)

(defmacro drgnx-extensions-test--with (&rest body)
  "BODY with a fresh list model and an empty job layer (its state table is fresh); the list buffer is killed after."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (let ((drgnx-extensions-jobs--state (make-hash-table)) (drgnx-extensions-live--restart nil))
         (drgnx-extensions-list--reset)
         (add-hook 'drgnx-extensions-jobs-changed-functions #'drgnx-extensions-list--jobs-changed)
         ,@body)
     (remove-hook 'drgnx-extensions-jobs-changed-functions #'drgnx-extensions-list--jobs-changed)
     (when (get-buffer drgnx-extensions-list-buffer-name) (kill-buffer drgnx-extensions-list-buffer-name))
     (drgnx-extensions-list--reset)))

(ert-deftest drgnx-extensions/query-parses-every-filter ()
  (let ((q (drgnx-extensions-parse-query
            "magit @installed @updates @enabled @disabled @builtin @plugins @unsigned @archive:melpa @kind:module @keyword:vc @sort:downloads")))
    (should (equal (plist-get q :text) "magit"))
    (should (equal (plist-get q :sort) "downloads"))
    (should-not (plist-get q :unknown))
    (let ((f (plist-get q :filters)))
      (dolist (k '(:installed :updates :enabled :disabled :builtin :plugins :unsigned)) (should (eq (plist-get f k) t)))
      (should (equal (plist-get f :archive) "melpa"))
      (should (equal (plist-get f :kind) "module"))
      (should (equal (plist-get f :keyword) "vc"))))
  (let ((q (drgnx-extensions-parse-query "@recommended @this-project @failed @restart @generations two words")))
    (should (equal (plist-get q :local) '(recommended this-project failed restart generations)))
    (should (equal (plist-get q :text) "two words"))
    (should-not (plist-get q :filters)))
  (should (equal (plist-get (drgnx-extensions-parse-query "@sort:installed") :sort) "installed")))

(ert-deftest drgnx-extensions/an-unknown-filter-is-a-chip-not-an-error ()
  (let ((q (drgnx-extensions-parse-query "git @foo @sort:nonsense")))
    (should (equal (plist-get q :text) "git"))
    (should (equal (plist-get q :unknown) '("@foo" "@sort:nonsense")))
    (should-not (plist-get q :sort))
    (should (string-match-p "not a filter" (drgnx-extensions-list--chips q)))))

(ert-deftest drgnx-extensions/local-filters-become-ids ()
  (drgnx-extensions-test--with
    (drgnx-extensions-jobs--put '(a b) (list :status 'failed :error "no"))
    ;; the job layer names packages, as symbols; the list's rows are "pkg:NAME"
    (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '(a b c))
    (let* ((params (drgnx-extensions-list-search-params (drgnx-extensions-parse-query "@failed")))
           (ids (plist-get (plist-get params :filters) :ids)))
      (should (equal (sort (append ids nil) #'string<) '("pkg:a" "pkg:b"))))))

(ert-deftest drgnx-extensions/no-colour-literal ()
  (dolist (f '("modules/tools/drgnx-extensions.el" "modules/tools/drgnx-extensions-list.el"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name f drgnx-dir))
      (goto-char (point-min))
      (should-not (re-search-forward "\"#[0-9a-fA-F]\\{3,8\\}\"\\|:\\(?:foreground\\|background\\|color\\) \"" nil t)))))

(ert-deftest drgnx-extensions/the-daily-check-never-runs-at-start ()
  (drgnx-extensions-test--with
    (drgnx-test-with-clock ()
      (let ((file (drgnx-extensions-refresh-file)) runs)
        (make-directory (file-name-directory file) t)
        (with-temp-file file (insert "{}"))
        (set-file-times file (time-subtract (current-time) (* 25 3600)))
        (cl-letf (((symbol-function 'drgnx-extensions-jobs-run) (lambda (kind &rest _) (push kind runs))))
          (let ((drgnx-extensions-check-updates 'daily))
            (drgnx-extensions--start-daily-check)
            (should (null runs))
            (drgnx-test-advance 599)
            (should (null runs))
            ;; a pause shorter than ten minutes starts nothing; a ten-minute one checks
            (drgnx-test-idle 2)
            (should (null runs))
            (drgnx-test-idle 601)
            (should (equal runs '(refresh)))))
        (drgnx-extensions--stop-daily-check)))))

(ert-deftest drgnx-extensions/an-install-without-the-trust-layer-is-refused ()
  (let (queued)
    (cl-letf (((symbol-function 'drgnx-extensions-jobs-queue) (lambda (entry) (push entry queued) 1))
              ((symbol-function 'drgnx-extensions-trust-before-install) nil))
      (should-error (drgnx-extensions--before-install '(:add magit)) :type 'user-error)
      (should-not queued))))

(ert-deftest drgnx-extensions/what-needs-you-falls-back-to-the-needs-you-face ()
  (cl-letf (((symbol-function 'facep) (lambda (f) (not (eq f 'drgnx-status-attention)))))
    (should (eq (drgnx-extensions-list--attention) 'drgnx-status-needs-you))))

(ert-deftest drgnx-extensions/the-daily-check-follows-the-setting-at-once ()
  (drgnx-test-with-modules '(tools/extensions)
    (let ((apply (plist-get (drgnx-setting-meta 'drgnx-extensions-check-updates) :apply)))
      (should (functionp apply))
      (unwind-protect
          (progn
            (setq drgnx-extensions-check-updates 'manual)
            (funcall apply)
            (should-not (drgnx-timer-active-p 'extensions-daily-check))
            (setq drgnx-extensions-check-updates 'daily)
            (funcall apply)
            (should (drgnx-timer-active-p 'extensions-daily-check)))
        (setq drgnx-extensions-check-updates 'daily)))))

(ert-deftest drgnx-extensions/packages-off-is-declared-once ()
  ;; the per-project layer owns the setting: its words, not a second declaration's
  (should (string-prefix-p "Packages whose file modes and buffer modes are off in this project"
                           (documentation-property 'drgnx-packages-off 'variable-documentation t)))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "modules/tools/drgnx-extensions.el" drgnx-dir))
    (should-not (search-forward "(drgnx-defsetting drgnx-packages-off" nil t))))

(ert-deftest drgnx-extensions/the-module-turns-off-clean ()
  (drgnx-test-with-modules '(tools/extensions)
    (should (drgnx-commands-get 'extensions-open))
    (should (drgnx-commands-get 'extensions-update-all))
    (cl-letf (((symbol-function 'drgnx-extensions-list-rows-p) (lambda () nil)))   ; the notice: no hub-fed view to set up
      (drgnx-extensions-list--buffer))
    (should-not (drgnx-module-teardown 'tools/extensions))
    (should-not (drgnx-commands-get 'extensions-open))
    (should-not (get-buffer drgnx-extensions-list-buffer-name))
    (should-not (memq 'drgnx-extensions-list--jobs-changed drgnx-extensions-jobs-changed-functions))
    (should-not (drgnx-timer-active-p 'extensions-daily-check))
    (should-not (drgnx-timer-active-p 'extensions-list-tick))))

(ert-deftest drgnx-extensions-list/the-search-follows-the-key-with-the-views-own-delay ()
  "M5: typing in the search arms a zero-second debounce (the view's delay is 0), not a 0.15 s one."
  (let (armed)
    (cl-letf (((symbol-function 'drgnx-timer-debounce) (lambda (key secs &rest _) (setq armed (cons key secs)) key)))
      (with-temp-buffer (drgnx-extensions-list--typing)))
    (should (equal armed '(extensions-list-search . 0)))))

;;; extensions-list-test.el ends here
