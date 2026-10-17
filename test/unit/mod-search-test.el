;;; mod-search-test.el --- batch tests: Semantic Search commands, index on save -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-area)
(require 'project)
(require 'drgnx-search-store)
(load (expand-file-name "modules/tools/drgnx-search" drgnx-dir) nil t)

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
  "A `drgnx-search-async' that answers RESULTS (and sets NOTICE) at once."
  (lambda (_root _query callback &rest _)
    (setq drgnx-search-last-notice notice)
    (funcall callback results)))

(ert-deftest drgnx-search-ui/results-go-to-the-results-tab ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let ((display-buffer-alist nil) (drgnx-signal--editor-window nil)
          (hits (list (list :path "a.txt" :start 2 :end 2 :text "  beta  \nmore" :score 0.03 :why 'both))))
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
        (drgnx-wb-area-hide 'panel)))))

(ert-deftest drgnx-search-ui/keyword-only-says-why ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let ((display-buffer-alist nil) (drgnx-signal--editor-window nil) (said nil)
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
            (should-not shown)))))))

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
    (let* ((file (expand-file-name "a.txt" root)) (timers nil) (cancelled nil) (started nil)
           (drgnx-search--timers (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (secs repeat fn &rest args)
                   (let ((tm (list secs repeat fn args))) (push tm timers) tm)))
                ((symbol-function 'cancel-timer) (lambda (tm) (push tm cancelled)))
                ((symbol-function 'drgnx-search-index--running-job) (lambda (_) nil))
                ((symbol-function 'drgnx-search-index-start) (lambda (r &rest _) (push r started) 1)))
        (dotimes (_ 3)
          (with-temp-buffer (setq buffer-file-name file) (drgnx-search--after-save)))
        (should (= (length timers) 3))
        (should (= (length cancelled) 2))               ; each save replaced the pending timer
        (should (= (hash-table-count drgnx-search--timers) 1))
        (should (= (car (car timers)) 30))
        (apply (nth 2 (car timers)) (nth 3 (car timers)))   ; the last one fires
        (should (= (length started) 1))
        (should (equal (file-name-as-directory (car started)) root))
        (should (= (hash-table-count drgnx-search--timers) 0))))))

(ert-deftest drgnx-search-ui/a-job-still-running-when-the-timer-fires-waits-again ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let ((timers nil) (started nil) (drgnx-search--timers (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (secs repeat fn &rest args) (push (list secs repeat fn args) timers) 'timer))
                ((symbol-function 'drgnx-search-index--running-job) (lambda (_) '(:id 7)))
                ((symbol-function 'drgnx-search-index-start) (lambda (r &rest _) (push r started) 1)))
        (drgnx-search--reindex root)
        (should-not started)
        (should (= (length timers) 1))))))

(ert-deftest drgnx-search-ui/no-index-no-reindex ()
  (skip-unless (executable-find "git"))
  (drgnx-search-ui-test--project
    (let* ((file (expand-file-name "a.txt" root)) (timers nil)
           (drgnx-search--timers (make-hash-table :test #'equal)))
      (cl-letf (((symbol-function 'run-with-timer) (lambda (&rest a) (push a timers) 'timer)))
        ;; no index file
        (with-temp-buffer (setq buffer-file-name file) (drgnx-search--after-save))
        (should-not timers)
        ;; an index, but the project turned search off
        (drgnx-search-ui-test--index-exists root)
        (make-directory (expand-file-name ".drgnx" root) t)
        (write-region "(:off t)" nil (expand-file-name ".drgnx/search.eld" root) nil 'silent)
        (with-temp-buffer (setq buffer-file-name file) (drgnx-search--after-save))
        (should-not timers)
        ;; a file outside any project
        (delete-file (expand-file-name ".drgnx/search.eld" root))
        (let ((project-find-functions nil))
          (with-temp-buffer (setq buffer-file-name (expand-file-name "x" state)) (drgnx-search--after-save)))
        (should-not timers)
        ;; and with the index and no :off it does schedule
        (with-temp-buffer (setq buffer-file-name file) (drgnx-search--after-save))
        (should (= (length timers) 1))))))

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

(provide 'mod-search-test)
;;; mod-search-test.el ends here
