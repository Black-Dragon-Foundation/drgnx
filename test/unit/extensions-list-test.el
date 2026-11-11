;;; extensions-list-test.el --- batch tests: the Extensions list, its query language and its live rows -*- lexical-binding: t -*-
;; test-class: det
;; The hub's search and the job layer are stubbed (`cl-letf'), the clock is virtual: nothing here reaches a process, a
;; network or the user's packages.  See docs/guide/extensions.md.
(require 'ert)
(defvar drgnx-view-old-path)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-view)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions" drgnx-dir) nil t)

(defun drgnx-extensions-test--row (name state &rest more)
  "A row as the hub's `extensions/search' sends it."
  (append (list :id (concat "pkg:" name) :kind "package" :name name :summary (concat name " summary") :state state
                :source "melpa" :signed "unsigned-archive" :version "1.0" :latest nil :downloads 10 :why nil)
          more))

(defmacro drgnx-extensions-test--with (&rest body)
  "BODY with a fresh list model and an empty job layer (its state table is fresh); the list buffer is killed after."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (let ((drgnx-view-old-path t) (drgnx-extensions-jobs--state (make-hash-table)) (drgnx-extensions-live--restart nil))
         (drgnx-extensions-list--reset)
         (add-hook 'drgnx-extensions-jobs-changed-functions #'drgnx-extensions-list--jobs-changed)
         ,@body)
     (remove-hook 'drgnx-extensions-jobs-changed-functions #'drgnx-extensions-list--jobs-changed)
     (when (get-buffer drgnx-extensions-list-buffer-name) (kill-buffer drgnx-extensions-list-buffer-name))
     (drgnx-view--undefine 'extensions)
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

(ert-deftest drgnx-extensions/sections-fold-while-a-query-is-typed ()
  (drgnx-extensions-test--with
    (drgnx-extensions-list--receive 'installed (list (drgnx-extensions-test--row "magit" "installed")) 1 0)
    (drgnx-extensions-list--receive 'updates (list (drgnx-extensions-test--row "dash" "update")) 1 0)
    (should (equal (cl-remove-if-not #'consp (drgnx-extensions-list--keys))
                   '((section . installed) (section . updates))))
    (setq drgnx-extensions-list--query "mag")
    (drgnx-extensions-list--receive 'search (list (drgnx-extensions-test--row "magit" "installed")) 1 0)
    (should (equal (drgnx-extensions-list--keys) '((section . search) "pkg:magit")))))

(ert-deftest drgnx-extensions/a-busy-row-shows-step-and-elapsed ()
  (drgnx-extensions-test--with
    (drgnx-extensions-list--receive 'installed (list (drgnx-extensions-test--row "magit" "installed")) 1 0)
    (drgnx-extensions-jobs--put '(magit) (list :status 'busy :step 'native :i 14 :n 37 :since (- (float-time) 12)))
    (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '(magit))
    (let ((text (substring-no-properties (drgnx-extensions-list--render "pkg:magit"))))
      (should (string-match-p "native 14/37" text))
      (should (string-match-p "12s" text)))))

(ert-deftest drgnx-extensions/the-second-tick-redraws-busy-rows-only ()
  (drgnx-extensions-test--with
    (drgnx-test-with-clock (:allow-pending t)
      (drgnx-extensions-list--receive 'installed (list (drgnx-extensions-test--row "magit" "installed")
                                                       (drgnx-extensions-test--row "dash" "installed")) 2 0)
      (with-current-buffer (drgnx-extensions-list--buffer)
        (let (dirty)
          (drgnx-extensions-jobs--put '(magit) (list :status 'busy :step 'download :since (float-time)))
          (cl-letf (((symbol-function 'drgnx-view-dirty) (lambda (_view keys) (push keys dirty))))
            (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '(magit))
            (setq dirty nil)
            (drgnx-test-advance 1.0)
            (should (equal (car dirty) '("pkg:magit"))))
          (remhash 'magit drgnx-extensions-jobs--state)
          (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '(magit))
          (should-not (drgnx-timer-active-p 'extensions-list-tick)))))))

(ert-deftest drgnx-extensions/no-timer-without-a-busy-row ()
  (drgnx-extensions-test--with
    (drgnx-test-with-clock (:allow-pending t)
      (drgnx-extensions-list--receive 'installed (list (drgnx-extensions-test--row "magit" "installed")) 1 0)
      (with-current-buffer (drgnx-extensions-list--buffer)
        (should-not (drgnx-timer-active-p 'extensions-list-tick))
        (drgnx-extensions-jobs--put '(magit) (list :status 'queued))
        (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '(magit))
        (should-not (drgnx-timer-active-p 'extensions-list-tick))
        (drgnx-extensions-jobs--put '(magit) (list :status 'busy :since (float-time)))
        (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '(magit))
        (should (drgnx-timer-active-p 'extensions-list-tick))
        (drgnx-extensions-jobs--put '(magit) (list :status 'done))
        (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '(magit))
        (should-not (drgnx-timer-active-p 'extensions-list-tick))))))

(ert-deftest drgnx-extensions/the-next-page-is-asked-near-the-end ()
  (drgnx-extensions-test--with
    (setq drgnx-extensions-list--query "git")
    (drgnx-extensions-list--receive
     'search (cl-loop for i below 200 collect (drgnx-extensions-test--row (format "p%03d" i) "available")) 450 0)
    (let (calls)
      (cl-letf (((symbol-function 'drgnx-hub-call)
                 (lambda (method params _cb &rest _) (push (cons method params) calls))))
        (with-current-buffer (drgnx-extensions-list--buffer)
          (let ((inhibit-read-only t)) (erase-buffer) (insert (make-string 6000 ?x)))
          (goto-char (point-max))
          (drgnx-extensions-list--post-command)
          (drgnx-extensions-list--post-command)
          (should (= (length calls) 1))
          (should (equal (caar calls) "extensions/search"))
          (should (= (plist-get (cdar calls) :offset) 200)))))))

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

(ert-deftest drgnx-extensions/a-refused-click-says-try-again-and-is-not-busy ()
  (drgnx-extensions-test--with
    (drgnx-test-with-clock (:allow-pending t)
      (drgnx-extensions-list--receive 'installed (list (drgnx-extensions-test--row "magit" "available")) 1 0)
      (with-current-buffer (drgnx-extensions-list--buffer)
        ;; what the job layer says when another drgnx held the queue file
        (drgnx-extensions-jobs--put '(magit) (list :status 'refused :error "busy, try again" :since (float-time)))
        (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '(magit))
        (let ((text (substring-no-properties (drgnx-extensions-list--render "pkg:magit"))))
          (should (string-search "busy, try again" text))
          (should-not (string-search "working" text)))
        (should-not (drgnx-extensions-list--busy-ids))
        (should-not (drgnx-timer-active-p 'extensions-list-tick))))))

(ert-deftest drgnx-extensions/an-install-without-the-trust-layer-is-refused ()
  (let (queued)
    (cl-letf (((symbol-function 'drgnx-extensions-jobs-queue) (lambda (entry) (push entry queued) 1))
              ((symbol-function 'drgnx-extensions-trust-before-install) nil))
      (should-error (drgnx-extensions--before-install '(:add magit)) :type 'user-error)
      (should-not queued))))

(ert-deftest drgnx-extensions/what-needs-you-falls-back-to-the-needs-you-face ()
  (cl-letf (((symbol-function 'facep) (lambda (f) (not (eq f 'drgnx-status-attention)))))
    (should (eq (drgnx-extensions-list--attention) 'drgnx-status-needs-you))))

(ert-deftest drgnx-extensions/the-list-draws-in-slices-and-keeps-its-section-ids ()
  (drgnx-extensions-test--with
    (drgnx-extensions-list--define-view)
    (should (drgnx-view-type-slice (alist-get 'extensions drgnx-view--types)))
    (drgnx-extensions-list--receive 'installed (list (drgnx-extensions-test--row "magit" "installed")
                                                     (drgnx-extensions-test--row "dash" "update")) 2 0)
    ;; read again with nothing new: the same list, not one made again per header and per sync
    (should (eq (drgnx-extensions-list--section-ids 'installed) (drgnx-extensions-list--section-ids 'installed)))
    (should (equal (drgnx-extensions-list--section-ids 'installed) '("pkg:magit")))
    (drgnx-extensions-list--receive 'installed (list (drgnx-extensions-test--row "magit" "installed")
                                                     (drgnx-extensions-test--row "dash" "installed")) 2 0)
    (should (equal (drgnx-extensions-list--section-ids 'installed) '("pkg:magit" "pkg:dash")))))

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
    (should (drgnx-view-type-p 'extensions))
    (drgnx-extensions-list--buffer)
    (should-not (drgnx-module-teardown 'tools/extensions))
    (should-not (drgnx-commands-get 'extensions-open))
    (should-not (drgnx-view-type-p 'extensions))
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
