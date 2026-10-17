;;; search-setup-test.el --- batch tests: Set Up Semantic Search, the doctor's search facts, onboarding step 5 -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-onboard)
(require 'drgnx-search-setup)
(require 'drgnx-search-index)
(require 'drgnx-search-query)

(defconst drgnx-search-setup-test--dims 4)

(defun drgnx-search-setup-test--vector (text)
  "A unit vector for TEXT, the same for the same text."
  (let ((v (make-vector drgnx-search-setup-test--dims 0.0)) (i 0))
    (dolist (c (string-to-list (downcase text)))
      (aset v (% (cl-incf i) drgnx-search-setup-test--dims) (+ (aref v (% i drgnx-search-setup-test--dims)) (float c))))
    (let ((norm (sqrt (cl-loop for x across v sum (* x x)))))
      (vconcat (mapcar (lambda (x) (/ x (max norm 1.0))) v)))))

(defun drgnx-search-setup-test--embed (inputs)
  (setq drgnx-ai-embed-last-info '(:provider tei :model nil))
  (vconcat (mapcar #'drgnx-search-setup-test--vector inputs)))

(defmacro drgnx-search-setup-test--with (&rest body)
  "Run BODY in a git project ROOT (a.txt) with a temp state dir, a TEI that is up (probe stubbed, requests
answered at once with DIMS-wide vectors), and the index job start recorded in STARTED.  No network, no HOME."
  (declare (indent 0))
  `(progn
     (skip-unless (and (sqlite-available-p) (executable-find "git")))
     (let* ((root (directory-file-name (make-temp-file "drgnx-setup-proj" t)))
            (state (make-temp-file "drgnx-setup-state" t))
            (process-environment (append (list (concat "XDG_STATE_HOME=" state) (concat "DRGNX_CONFIG_DIR=" state "/config")
                                               "OPENROUTER_API_KEY")
                                         process-environment))
            (default-directory (file-name-as-directory root))
            (drgnx-ai-detected nil) (drgnx-ai-embed-last-info nil) (drgnx-search-last-notice nil)
            (started nil) (up t) (request-dims drgnx-search-setup-test--dims))
       (unwind-protect
           (progn
             (call-process "git" nil nil nil "init" "-q")
             (write-region "(defun start-here () 1)\n" nil (expand-file-name "a.txt" root) nil 'silent)
             (cl-letf (((symbol-function 'drgnx-ai-probe)
                        (lambda (callback &optional _ids)
                          (setq drgnx-ai-detected (and up '((tei :up t :models ("bge")))))
                          (funcall callback)))
                       ((symbol-function 'drgnx-ai-role) (lambda (_role) '((tei))))
                       ((symbol-function 'drgnx-ai-request)
                        (lambda (_role _kind payload callback &rest _)
                          (funcall callback
                                   (vconcat (mapcar (lambda (text) (make-vector request-dims 0.5)) (plist-get payload :inputs)))
                                   '(:provider tei :model nil))
                          nil))
                       ((symbol-function 'drgnx-search-index-start)
                        (lambda (r &optional rebuild) (push (cons r rebuild) started) "job-1")))
               ,@body))
         (delete-directory root t)
         (delete-directory state t)))))

(ert-deftest drgnx-search-setup/wizard-indexes-and-tests ()
  (drgnx-search-setup-test--with
    ;; no index yet: the job starts in the background, the answer says how to follow it
    (let ((r (drgnx-search-setup root)))
      (should (eq (car r) 'ok))
      (should (equal (mapcar #'car started) (list root)))
      (should (string-match-p "background" (cadr r)))
      (should (string-match-p "Index Status" (cadr r)))
      (should (string-match-p "tei" (cadr r)))
      (should (string-match-p "4 dims" (cadr r))))
    ;; an index that is current: a test query runs and the top hit is shown
    (let ((res (drgnx-search-index root :embed #'drgnx-search-setup-test--embed)))
      (should-not (plist-get res :error)))
    (setq started nil)
    (cl-letf (((symbol-function 'drgnx-ai-request)
               (lambda (_role _kind payload callback &rest _)
                 (funcall callback (vconcat (mapcar #'drgnx-search-setup-test--vector (plist-get payload :inputs)))
                          '(:provider tei :model nil))
                 nil)))
      (let ((r (drgnx-search-setup root)))
        (should (eq (car r) 'ok))
        (should-not started)
        (should (string-match-p "a\\.txt:1" (cadr r)))))))

(ert-deftest drgnx-search-setup/wizard-without-a-provider-says-how-to-start-one ()
  (drgnx-search-setup-test--with
    (setq up nil)
    (let ((r (drgnx-search-setup root)))
      (should (eq (car r) 'info))
      (should (string-match-p "Text Embeddings Inference" (cadr r)))
      (should (string-match-p "Ollama" (cadr r)))
      (should-not started))))

(ert-deftest drgnx-search-setup/wizard-an-embedding-that-fails-stops ()
  (drgnx-search-setup-test--with
    (cl-letf (((symbol-function 'drgnx-ai-request)
               (lambda (_role _kind _payload callback &rest _)
                 (funcall callback nil '(:error "tei: HTTP 500")) nil)))
      (let ((r (drgnx-search-setup root)))
        (should (eq (car r) 'warn))
        (should (string-match-p "HTTP 500" (cadr r)))
        (should-not started)))))

(ert-deftest drgnx-search-setup/wizard-does-not-rebuild-an-index-of-another-size ()
  (drgnx-search-setup-test--with
    (drgnx-search-index root :embed #'drgnx-search-setup-test--embed)
    (setq request-dims 8)
    (let ((r (drgnx-search-setup root)))
      (should (eq (car r) 'warn))
      (should (string-match-p "4 dims" (cadr r)))
      (should (string-match-p "rebuild" (cadr r)))
      (should-not started))))

(ert-deftest drgnx-search-setup/doctor-facts-count-stale-and-unindexed ()
  (drgnx-search-setup-test--with
    (let ((other (directory-file-name (make-temp-file "drgnx-setup-other" t))))
      (unwind-protect
          (progn
            (drgnx-search-index root :embed #'drgnx-search-setup-test--embed)
            (write-region "changed\n" nil (expand-file-name "a.txt" root) nil 'silent)
            (write-region "new\n" nil (expand-file-name "b.txt" root) nil 'silent)
            (let* ((facts (drgnx-search-doctor-facts (list root other)))
                   (entry (cdr (assoc root (plist-get facts :indexes)))))
              (should (plist-get facts :sqlite))
              (should (plist-get facts :fts5))
              (should (= (length (plist-get facts :indexes)) 1))
              (should (= (plist-get facts :unindexed) 1))        ; `other': listed as not indexed, not stale
              (should (= (plist-get entry :dims) 4))
              (should (= (plist-get entry :stale) 2))            ; one changed, one new
              (should (> (plist-get entry :chunks) 0))))
        (delete-directory other t)))))

(ert-deftest drgnx-search-setup/doctor-facts-never-prompt-or-block-without-a-provider ()
  (drgnx-search-setup-test--with
    (drgnx-search-index root :embed #'drgnx-search-setup-test--embed)
    (let ((asked nil))
      (cl-letf (((symbol-function 'drgnx-ai-request) (lambda (&rest _) (setq asked t) nil))
                ((symbol-function 'drgnx-ai-detected-cached) (lambda () nil)))
        (let ((facts (drgnx-search-doctor-facts (list root))))
          (should-not asked)                                    ; nothing cached as up: no request at all
          (should-not (plist-get facts :embed-up))
          (should-not (plist-get facts :embed-dims)))))))

(ert-deftest drgnx-onboard/search-step-non-interactive-detects ()
  (drgnx-search-setup-test--with
    (let ((roots (list root)))
      (cl-letf (((symbol-function 'drgnx-search-setup--roots) (lambda () roots)))
        ;; a provider is up, the project has no index: info, names the way to index
        (let ((r (drgnx-onboard--search-step '(:interactive nil))))
          (should (eq (car r) 'info))
          (should (string-match-p "tei" (cadr r)))
          (should (string-match-p "no index" (cadr r)))
          (should-not started))                                 ; detecting never starts a job
        ;; indexed: ok
        (drgnx-search-index root :embed #'drgnx-search-setup-test--embed)
        (should (eq (car (drgnx-onboard--search-step '(:interactive nil))) 'ok))
        ;; no provider: info with how to start one
        (setq up nil)
        (let ((r (drgnx-onboard--search-step '(:interactive nil))))
          (should (eq (car r) 'info))
          (should (string-match-p "Text Embeddings Inference" (cadr r))))))))

(ert-deftest drgnx-onboard/search-step-interactive-runs-the-wizard ()
  (drgnx-search-setup-test--with
    (cl-letf (((symbol-function 'drgnx-search-setup--current-root) (lambda () root)))
      (let ((r (drgnx-onboard--search-step '(:interactive t))))
        (should (eq (car r) 'ok))
        (should (equal (mapcar #'car started) (list root)))))))

(ert-deftest drgnx-search-setup/the-command-has-a-key-entry-in-every-profile ()
  (load (expand-file-name "modules/tools/drgnx-search" drgnx-dir) nil t)
  (should (commandp 'drgnx-search-set-up))
  (dolist (profile '("vscode" "emacs" "vim"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
      (should (search-forward "(search-set-up :none \"in the palette\")" nil t)))))

(provide 'search-setup-test)
;;; search-setup-test.el ends here
