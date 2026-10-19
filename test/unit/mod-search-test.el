;;; mod-search-test.el --- batch tests: Semantic Search commands, index on save -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-area)
(require 'project)
(require 'drgnx-search-store)
(require 'drgnx-search-chunk)                 ; the libraries whose variables the tests let-bind and whose
(require 'drgnx-search-query)                 ; functions they stub: loaded here, so the file passes alone
(require 'drgnx-search-index)                 ; (and in any shard of drgnx check)
(load (expand-file-name "modules/tools/drgnx-search" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defmacro drgnx-search-ui-test--timed (&rest body)
  "BODY on the virtual clock, with the module `tools/search' running (it owns the re-index timers); what is still
pending at the end is cancelled."
  (declare (indent 0))
  `(let ((drgnx-modules--runs (list (cons 'tools/search (list 'run)))))
     (drgnx-test-with-clock ()
       (unwind-protect (progn ,@body)
         (drgnx-timer-reset)))))

(defun drgnx-search-ui-test--reindexes ()
  "The keys of the re-index timers now pending."
  (seq-filter (lambda (key) (eq (car-safe key) 'search-reindex)) (mapcar #'car (drgnx-timer-pending))))

(defmacro drgnx-search-ui-test--project (&rest body)
  "Run BODY in a git project (ROOT, with a.txt) whose index and state live in a temp state dir."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-proj" t)))
          (state (make-temp-file "drgnx-state" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
          (default-directory root) (drgnx-search-last-notice nil))
     (unwind-protect
         (progn
           (call-process "git" nil nil nil "init" "-q")
           (write-region "alpha\nbeta\n" nil (expand-file-name "a.txt" root) nil 'silent)
           ,@body)
       (delete-directory root t)
       (delete-directory state t))))

(defun drgnx-search-ui-test--stub-search (results &optional notice)
  "A `drgnx-search-async' that answers RESULTS and NOTICE (its callback's two arguments) at once."
  (lambda (_root _query callback &rest _)
    (funcall callback results notice)))

(ert-deftest drgnx-search-ui/results-go-to-the-results-tab ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (drgnx-test-with-state
      (let ((display-buffer-alist nil)
            (hits (list (list :path "a.txt" :start 2 :end 2 :text "beta\n  more" :score 0.03 :why 'both))))
        (delete-other-windows)
        (drgnx-rules-mode 1)
        (unwind-protect
            (cl-letf (((symbol-function 'drgnx-search-async) (drgnx-search-ui-test--stub-search hits)))
              (drgnx-search-semantic "second line")
              (let ((buf (window-buffer (drgnx-wb-area-window 'panel))))
                (should (string-match-p "xref" (buffer-name buf)))
                (should (eq (drgnx-wb-area-tab 'panel) 'results))
                (with-current-buffer buf
                  (should (string-match-p "beta" (buffer-string)))
                  (should-not (string-match-p "more" (buffer-string))))))   ; the first line only
          (drgnx-rules-mode -1)
          (drgnx-wb-area-hide 'panel))))))

(ert-deftest drgnx-search-ui/keyword-only-says-why ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (drgnx-test-with-state
      (let ((display-buffer-alist nil) (said nil)
            (hits (list (list :path "a.txt" :start 1 :end 1 :text "alpha" :score 0.03 :why 'keyword))))
        (cl-letf (((symbol-function 'drgnx-search-async)
                   (drgnx-search-ui-test--stub-search hits "no embedding provider answered (down) — keyword results only"))
                  ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
          ;; hits and a notice: both
          (drgnx-search-semantic "alpha")
          (should (cl-some (lambda (s) (string-match-p "keyword results only" s)) said))
          ;; nothing found: the notice (or a plain line), no error, nothing shown
          (setq said nil)
          (let ((shown nil))
            (cl-letf (((symbol-function 'drgnx-search-async)
                       (drgnx-search-ui-test--stub-search nil "no index for this project — Search: Index Project"))
                      ((symbol-function 'xref-show-xrefs) (lambda (&rest _) (setq shown t))))
              (drgnx-search-semantic "alpha")
              (should (cl-some (lambda (s) (string-match-p "no index for this project" s)) said))
              (should-not shown))))))))

(ert-deftest drgnx-search-ui/outside-a-project-is-a-message-not-an-index ()
  (let ((dir (make-temp-file "drgnx-noproj" t)))
    (unwind-protect
        (let ((default-directory (file-name-as-directory dir)) (project-find-functions nil))
          (should-error (drgnx-search-semantic "x") :type 'user-error)
          (should-error (drgnx-search-index-project) :type 'user-error))
      (delete-directory dir t))))

(defun drgnx-search-ui-test--index-exists (root)
  (require 'drgnx-search-store)
  (let ((f (drgnx-search-store-file root)))
    (make-directory (file-name-directory f) t)
    (write-region "" nil f nil 'silent)))

(ert-deftest drgnx-search-ui/save-schedules-one-reindex ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (drgnx-search-ui-test--index-exists root)
    (let* ((file (expand-file-name "a.txt" root)) (started nil))
      (cl-letf (((symbol-function 'drgnx-jobs-list) (lambda () (error "a timer listed the jobs")))
                ((symbol-function 'drgnx-search-index-start) (lambda (r &rest _) (push r started) 1)))
        (drgnx-search-ui-test--timed
          (dotimes (_ 3)
            (with-temp-buffer (setq buffer-file-name file) (drgnx-search--after-save))
            (drgnx-test-advance 5))
          (should (= (length (drgnx-search-ui-test--reindexes)) 1))   ; each save replaced the pending timer
          (drgnx-test-advance 24)                       ; 29 s after the last save
          (should-not started)
          (drgnx-test-advance 1)                        ; 30 s: the re-index is due…
          (should-not started)                          ; …and waits for Emacs to be idle
          (should (= (length (drgnx-search-ui-test--reindexes)) 1))
          (drgnx-test-idle 2)                           ; the start comes from the idle timer
          (should (= (length started) 1))
          (should (equal (file-name-as-directory (car started)) root))
          (should-not (drgnx-search-ui-test--reindexes)))))))

(ert-deftest drgnx-search-ui/a-job-still-running-when-the-timer-fires-waits-again ()
  "A live indexer is known from the project's lock file — the timer never lists the jobs."
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (drgnx-search-ui-test--index-exists root)
    (require 'drgnx-search-index)
    (let ((started nil)
          (lock (drgnx-search-index--lock-file root)))
      (write-region (format "%d %s" (emacs-pid) (drgnx-search-index--start-time (emacs-pid))) nil lock nil 'silent)
      (cl-letf (((symbol-function 'drgnx-jobs-list) (lambda () (error "a timer listed the jobs")))
                ((symbol-function 'drgnx-search-index-start) (lambda (r &rest _) (push r started) 1)))
        (drgnx-search-ui-test--timed
          (drgnx-search--reindex root)
          (should-not started)
          (should (= (length (drgnx-search-ui-test--reindexes)) 1))
          ;; the lock is gone: the next firing starts
          (delete-file lock)
          (drgnx-search--reindex root)
          (should (= (length started) 1)))))))

(ert-deftest drgnx-search-ui/no-index-no-reindex ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let* ((file (expand-file-name "a.txt" root)))
      (drgnx-search-ui-test--timed
        ;; no index file
        (with-temp-buffer (setq buffer-file-name file) (drgnx-search--after-save))
        (should-not (drgnx-search-ui-test--reindexes))
        ;; an index, but the project turned search off
        (drgnx-search-ui-test--index-exists root)
        (make-directory (expand-file-name ".drgnx" root) t)
        (write-region "(:off t)" nil (expand-file-name ".drgnx/search.eld" root) nil 'silent)
        (with-temp-buffer (setq buffer-file-name file) (drgnx-search--after-save))
        (should-not (drgnx-search-ui-test--reindexes))
        ;; a file outside any project
        (delete-file (expand-file-name ".drgnx/search.eld" root))
        (let ((project-find-functions nil))
          (with-temp-buffer (setq buffer-file-name (expand-file-name "x" state)) (drgnx-search--after-save)))
        (should-not (drgnx-search-ui-test--reindexes))
        ;; and with the index and no :off it does schedule
        (with-temp-buffer (setq buffer-file-name file) (drgnx-search--after-save))
        (should (= (length (drgnx-search-ui-test--reindexes)) 1))))))

(ert-deftest drgnx-search-ui/a-save-with-the-module-off-schedules-nothing ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (drgnx-search-ui-test--index-exists root)
    (let ((drgnx-modules--runs nil))                    ; tools/search has no run: it is off
      (drgnx-test-with-clock ()
        (with-temp-buffer (setq buffer-file-name (expand-file-name "a.txt" root)) (drgnx-search--after-save))
        (should-not (drgnx-search-ui-test--reindexes))))))

(ert-deftest drgnx-search-ui/index-project-starts-the-job-and-a-prefix-rebuilds ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let ((calls nil))
      (cl-letf (((symbol-function 'drgnx-search-index-start) (lambda (r &optional rebuild) (push (list r rebuild) calls) 1)))
        (drgnx-search-index-project)
        (drgnx-search-index-project t)
        (should (equal (mapcar #'cadr (reverse calls)) '(nil t)))
        (make-directory (expand-file-name ".drgnx" root) t)
        (write-region "(:off t)" nil (expand-file-name ".drgnx/search.eld" root) nil 'silent)
        (drgnx-search-index-project)
        (should (= (length calls) 2))))))   ; search off: no job

(ert-deftest drgnx-search-ui/a-start-that-backs-off-says-so ()
  "An index job started a moment ago makes the start return nil: the message must not claim indexing began."
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let ((said nil))
      (cl-letf (((symbol-function 'drgnx-search-index-start) (lambda (&rest _) nil))
                ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
        (drgnx-search-index-project t)
        (should (cl-some (lambda (m) (string-match-p "try again shortly" m)) said))
        (should-not (cl-some (lambda (m) (string-match-p "\\`Indexing" m)) said))))))

(ert-deftest drgnx-search-ui/index-status-reports-the-index ()
  (skip-unless (and (executable-find "git") (sqlite-available-p)))
  (drgnx-search-ui-test--project
    (should (string-match-p "no index" (drgnx-search-status root)))
    (let ((db (drgnx-search-store-open root)))
      (drgnx-search-store-put-file db "a.txt" "h" (list (list :start 1 :end 2 :text "alpha" :vector [1.0 0.0])))
      (drgnx-search-store-set-meta db '(:provider stub :model "stub-1" :dims 2 :indexed-at 1700000000.0))
      (sqlite-close db))
    (cl-letf (((symbol-function 'drgnx-search-index--running-job) (lambda (_) nil)))
      (let ((s (drgnx-search-status root)))
        (should (string-match-p "1 chunk" s))
        (should (string-match-p "1 file" s))
        (should (string-match-p "stub-1" s))
        (should (string-match-p "not running" s))))
    (cl-letf (((symbol-function 'drgnx-search-index--running-job) (lambda (_) '(:id 3))))
      (should (string-match-p "indexing now" (drgnx-search-status root))))))

;;;; Fix round 1

(ert-deftest drgnx-search-ui/results-are-shown-from-the-originating-buffer-and-window ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let* ((origin (generate-new-buffer " origin")) (win (selected-window)) (later nil) (seen nil)
           (hits (list (list :path "a.txt" :start 1 :end 1 :text "alpha" :score 0.03 :why 'both))))
      (unwind-protect
          (with-current-buffer origin
            (setq default-directory root)
            (set-window-buffer win origin)
            (cl-letf (((symbol-function 'drgnx-search-async) (lambda (_r _q cb &rest _) (setq later cb)))
                      ((symbol-function 'xref-show-xrefs)
                       (lambda (&rest _) (setq seen (list (current-buffer) (selected-window))))))
              (drgnx-search-semantic "alpha")
              ;; the answer arrives from a sentinel: other buffer current, another window selected
              (with-temp-buffer
                (let ((other (split-window win)))
                  (unwind-protect
                      (with-selected-window other (funcall later hits))
                    (delete-window other))))
              (should (eq (car seen) origin))
              (should (eq (cadr seen) win))))
        (kill-buffer origin)))))

(ert-deftest drgnx-search-ui/focus-moves-to-the-results-when-the-answer-arrives ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let ((later nil) (hits (list (list :path "a.txt" :start 1 :end 1 :text "alpha" :score 0.03 :why 'both)))
          (xref (get-buffer-create "*xref*")))
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (cl-letf (((symbol-function 'drgnx-search-async) (lambda (_r _q cb &rest _) (setq later cb)))
                      ((symbol-function 'xref-show-xrefs)
                       (lambda (&rest _) (set-window-buffer (split-window (selected-window)) xref))))
              (drgnx-search-semantic "alpha")
              (should-not (eq (window-buffer (selected-window)) xref))
              (funcall later hits)
              (should (eq (window-buffer (selected-window)) xref))))
        (kill-buffer xref)))))

(ert-deftest drgnx-search-ui/results-fall-back-when-the-origin-is-gone-and-errors-are-messages ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let* ((origin (generate-new-buffer " origin")) (later nil) (said nil) (seen nil)
           (hits (list (list :path "a.txt" :start 1 :end 1 :text "alpha" :score 0.03 :why 'both))))
      (with-current-buffer origin (setq default-directory root))
      (cl-letf (((symbol-function 'drgnx-search-async) (lambda (_r _q cb &rest _) (setq later cb)))
                ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said)))
                ((symbol-function 'xref-show-xrefs) (lambda (&rest _) (setq seen (current-buffer)))))
        (with-current-buffer origin (drgnx-search-semantic "alpha"))
        (kill-buffer origin)                          ; gone before the answer
        (with-temp-buffer (funcall later hits) (should (buffer-live-p seen)))   ; shown, in whatever is current
        ;; an error while showing is one message, never a signal from the sentinel
        (cl-letf (((symbol-function 'xref-show-xrefs) (lambda (&rest _) (error "display broke"))))
          (setq said nil)
          (funcall later hits)
          (should (cl-some (lambda (m) (string-match-p "display broke" m)) said)))))))

(ert-deftest drgnx-search-ui/a-project-is-checked-before-the-prompt ()
  (let ((dir (make-temp-file "drgnx-noproj" t)))
    (unwind-protect
        (let ((default-directory (file-name-as-directory dir)) (project-find-functions nil))
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) (error "prompted"))))
            (should-error (call-interactively #'drgnx-search-semantic) :type 'user-error)))
      (delete-directory dir t))))

(ert-deftest drgnx-search-ui/save-skips-files-the-indexer-never-indexes ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (drgnx-search-ui-test--index-exists root)
    (make-directory (expand-file-name ".drgnx" root) t)
    (write-region "(:exclude (\"vendor/\"))" nil (expand-file-name ".drgnx/search.eld" root) nil 'silent)
    (drgnx-search-ui-test--timed
      (dolist (rel '(".env" ".github/ci.yml" "id_rsa" "deploy.pem" "my-secret.txt" "vendor/x.js"))
        (with-temp-buffer (setq buffer-file-name (expand-file-name rel root)) (drgnx-search--after-save)))
      (should-not (drgnx-search-ui-test--reindexes))
      (with-temp-buffer (setq buffer-file-name (expand-file-name "src/a.el" root)) (drgnx-search--after-save))
      (should (= (length (drgnx-search-ui-test--reindexes)) 1)))))

(ert-deftest drgnx-search-ui/the-timer-rechecks-the-index-and-the-config ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let ((started nil))
      (cl-letf (((symbol-function 'drgnx-search-index-running-p) (lambda (_) nil))
                ((symbol-function 'drgnx-search-index-start) (lambda (r &rest _) (push r started) 1)))
        ;; the index was deleted since the save
        (drgnx-search--reindex root)
        (should-not started)
        ;; the index is there but search was turned off since
        (drgnx-search-ui-test--index-exists root)
        (make-directory (expand-file-name ".drgnx" root) t)
        (write-region "(:off t)" nil (expand-file-name ".drgnx/search.eld" root) nil 'silent)
        (drgnx-search--reindex root)
        (should-not started)
        (delete-file (expand-file-name ".drgnx/search.eld" root))
        (drgnx-search--reindex root)
        (should (= (length started) 1))))))

(ert-deftest drgnx-search-ui/status-tells-an-unreadable-index-from-no-index ()
  (skip-unless (and (executable-find "git") (sqlite-available-p)))
  (drgnx-search-ui-test--project
    (let ((f (drgnx-search-store-file root)))
      (make-directory (file-name-directory f) t)
      (write-region "this is not a database at all, just text\n" nil f nil 'silent))
    (cl-letf (((symbol-function 'drgnx-search-index--running-job) (lambda (_) nil)))
      (let ((s (drgnx-search-status root)))
        (should (string-match-p "cannot be read" s))
        (should-not (string-match-p "no index" s)))
      (cl-letf (((symbol-function 'drgnx-search-store-open-read) (lambda (_) (error "cannot open"))))
        (let ((s (drgnx-search-status root)))
          (should (string-match-p "cannot be read" s))
          (should-not (string-match-p "no index" s)))))))

;;;; Final review

(defun drgnx-search-ui-test--said (fn)
  "The messages FN says, newest first."
  (let ((said nil))
    (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said) nil)))
      (funcall fn))
    said))

(ert-deftest drgnx-search-ui/without-sqlite-the-index-commands-say-so-and-do-nothing ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let ((no-sqlite "this Emacs has no SQLite — semantic search needs Emacs built with SQLite") (touched nil))
      (cl-letf (((symbol-function 'sqlite-available-p) (lambda () nil))
                ((symbol-function 'drgnx-search-index-start) (lambda (&rest _) (setq touched 'start)))
                ((symbol-function 'drgnx-search-index--running-job) (lambda (&rest _) (setq touched 'jobs) nil))
                ((symbol-function 'drgnx-search-store-file) (lambda (&rest _) (setq touched 'store) "/nonexistent")))
        (dolist (rebuild '(nil t))
          (let ((said (drgnx-search-ui-test--said (lambda () (drgnx-search-index-project rebuild)))))
            (should (equal said (list no-sqlite)))))
        (should (equal (drgnx-search-ui-test--said #'drgnx-search-index-status) (list no-sqlite)))
        (should-not touched)))))

(ert-deftest drgnx-search-ui/a-rebuild-while-a-job-runs-says-to-wait ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let ((calls nil))
      (cl-letf (((symbol-function 'drgnx-search-index-start) (lambda (&rest a) (push a calls) 1))
                ((symbol-function 'drgnx-search-index--running-job) (lambda (_) '(:id "j" :status running))))
        (let ((said (drgnx-search-ui-test--said (lambda () (drgnx-search-index-project t)))))
          (should (string-match-p "\\`an index job is already running for .+; rebuild after it finishes\\'" (car said))))
        (let ((said (drgnx-search-ui-test--said (lambda () (drgnx-search-index-project)))))
          (should (string-match-p "already being indexed" (car said))))
        (should-not calls)))))

(ert-deftest drgnx-search-ui/the-prompt-offers-the-symbol-as-its-default ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let ((asked nil))
      (with-temp-buffer
        (setq default-directory root)
        (insert "parse_config")
        (goto-char 3)
        (cl-letf (((symbol-function 'read-string) (lambda (&rest args) (setq asked args) "parse_config"))
                  ((symbol-function 'drgnx-search-async) #'ignore))
          (call-interactively #'drgnx-search-semantic)))
      (should (string-match-p "parse_config" (nth 0 asked)))   ; shown in the prompt
      (should-not (nth 1 asked))                                ; no initial input to delete
      (should (equal (nth 3 asked) "parse_config")))))           ; RET takes it

(ert-deftest drgnx-search-ui/a-broken-config-stops-the-index-commands-and-the-save-hook ()
  (skip-unless (and (executable-find "git") (sqlite-available-p)))
  (drgnx-search-ui-test--project
    (drgnx-search-ui-test--index-exists root)
    (make-directory (expand-file-name ".drgnx" root) t)
    (write-region "(:exclude \"vendor/\")" nil (expand-file-name ".drgnx/search.eld" root) nil 'silent)
    (let ((started nil))
      (cl-letf (((symbol-function 'drgnx-search-index--running-job) (lambda (_) nil))
                ((symbol-function 'drgnx-search-index-start) (lambda (r &rest _) (push r started) 1)))
        (drgnx-search-ui-test--timed
          (with-temp-buffer (setq buffer-file-name (expand-file-name "a.txt" root)) (drgnx-search--after-save))
          (should-not (drgnx-search-ui-test--reindexes))
          (drgnx-search--reindex root)
          (should-not started)
          (let ((said (drgnx-search-ui-test--said (lambda () (drgnx-search-index-project)))))
            (should (string-match-p "\\.drgnx/search\\.eld cannot be read: :exclude: expected a list, got string" (car said))))
          (should-not started)
          (should (string-match-p "\\.drgnx/search\\.eld cannot be read" (drgnx-search-status root))))))))

(ert-deftest drgnx-search-ui/status-names-the-index-file ()
  (skip-unless (and (executable-find "git") (sqlite-available-p)))
  (drgnx-search-ui-test--project
    (let ((db (drgnx-search-store-open root)))
      (drgnx-search-store-put-file db "a.txt" "h" (list (list :start 1 :end 2 :text "alpha" :vector [1.0 0.0])))
      (drgnx-search-store-set-meta db '(:provider stub :model "stub-1" :dims 2 :indexed-at 1700000000.0))
      (sqlite-close db))
    (cl-letf (((symbol-function 'drgnx-search-index--running-job) (lambda (_) nil)))
      (should (string-search (abbreviate-file-name (drgnx-search-store-file root)) (drgnx-search-status root))))))

(ert-deftest drgnx-search-ui/the-xref-line-is-the-line-shown ()
  "The summary is the chunk's first non-blank line, and the location is that line."
  (require 'xref)
  (let* ((item (drgnx-search--xref "/p/" '(:path "a.el" :start 10 :end 20 :text "\n  \n(defun foo ()\n  1)")))
         (loc (xref-item-location item)))
    (should (equal (xref-item-summary item) "(defun foo ()"))
    (should (= (xref-file-location-line loc) 12))))

(provide 'mod-search-test)
;;; mod-search-test.el ends here

(ert-deftest drgnx-search-ui/commands-ask-about-a-projects-remote-route-first ()
  ;; The project's .drgnx/ai.eld may route the embed role to a remote provider; the user is asked once, in the
  ;; command they ran, with the project as the current directory (never later, from the job or a timer).
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let (asked (outside (make-temp-file "drgnx-elsewhere" t)))
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-ai-confirm-project-route)
                     (lambda () (push (file-truename default-directory) asked) t))
                    ((symbol-function 'drgnx-search-async) (drgnx-search-ui-test--stub-search nil "no index"))
                    ((symbol-function 'drgnx-search-setup) (lambda (&rest _) (list 'ok "fine")))
                    ((symbol-function 'drgnx-search-index-start) (lambda (&rest _) t))
                    ((symbol-function 'message) #'ignore))
            (let ((default-directory (file-name-as-directory (expand-file-name "sub" root))))
              (make-directory default-directory t)
              (dolist (cmd '(drgnx-search-semantic drgnx-search-index-project drgnx-search-set-up))
                (setq asked nil)
                (if (eq cmd 'drgnx-search-semantic) (funcall cmd "alpha") (funcall cmd))
                (should (equal asked (list (file-truename root)))))))     ; once, with the project root
        (delete-directory outside t)))))

(ert-deftest drgnx-search/off-stops-a-running-indexer-and-leaves-no-lock ()
  (skip-unless (executable-find "sleep"))
  (drgnx-search-ui-test--project
    (let* ((proc (make-process :name "fake-indexer" :command '("sleep" "60") :noquery t))
           (pid (process-id proc))
           (lock (drgnx-search-index--lock-file root))
           (job (list :status 'running :name "search-index: proj" :pid pid
                      :command (list "emacs" "--batch" "-f" "drgnx-search-index-cli" (directory-file-name root)))))
      (unwind-protect
          (progn
            (make-directory (file-name-directory lock) t)
            (write-region (format "%d 0" pid) nil lock nil 'silent)
            (should (drgnx-search-index-running-p root))
            (cl-letf (((symbol-function 'drgnx-jobs-list) (lambda () (list job))))
              (drgnx-search--teardown))
            (should-not (file-exists-p lock))                   ; at once: no stale lock
            (let ((deadline (+ (float-time) 5)))                 ; the signal does the rest, nothing here waited
              (while (and (process-live-p proc) (< (float-time) deadline)) (accept-process-output nil 0.05)))
            (should-not (process-live-p proc)))
        (when (process-live-p proc) (kill-process proc))))))
