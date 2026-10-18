;;; perf-modal-test.el --- batch tests: the perf workloads for typing, motions and the Explorer with evil -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-perf-run)

(defmacro drgnx-perf-modal-test--env (var value &rest body)
  "BODY with the environment variable VAR set to VALUE (nil: unset)."
  (declare (indent 2))
  `(let ((process-environment (cons (if ,value (concat ,var "=" ,value) ,var) process-environment)))
     ,@body))

(defun drgnx-perf-modal-test--names (workloads) (mapcar #'car workloads))

(ert-deftest drgnx-perf-modal/workloads-only-with-the-elpa ()
  (drgnx-perf-modal-test--env "DRGNX_MODAL_ELPA" nil
    (should-not (seq-filter (lambda (n) (string-suffix-p "-evil" (symbol-name n)))
                            (drgnx-perf-modal-test--names (drgnx-perf-run--workloads)))))
  (drgnx-perf-modal-test--env "DRGNX_MODAL_ELPA" "/tmp/drgnx-elpa-x"
    (let ((ws (drgnx-perf-run--workloads)))
      (should (equal (seq-filter (lambda (n) (string-suffix-p "-evil" (symbol-name n))) (drgnx-perf-modal-test--names ws))
                     '(typing-evil motions-evil explorer-evil)))
      (dolist (n '(typing-evil motions-evil explorer-evil))
        (let ((spec (cdr (assq n ws))))
          (should (string-search "/tmp/drgnx-elpa-x" (plist-get spec :setup)))
          (should (string-search "(drgnx-modal-engine-start-now 'evil)" (plist-get spec :setup)))
          (should (string-search "(vim app editing window)" (plist-get spec :setup)))
          (should (string-search "vscode" (plist-get spec :teardown))))))))

(ert-deftest drgnx-perf-modal/budgets-have-the-rows ()
  (let ((b (drgnx-perf-run--budgets)))
    (dolist (row '((typing-evil (:input :p95) 16) (typing-evil (:input :max) 50)
                   (motions-evil (:input :p95) 16) (motions-evil (:input :max) 50)
                   (explorer-evil (:input :p95) 8) (explorer-evil (:input :max) 50)))
      (should (member row b)))
    ;; no existing row changed
    (should (member '(typing (:input :p95) 16) b))
    (should (member '(typing (:input :max) 50) b))
    (should (member '(explorer (:input :p95) 16) b))
    (should (member '(explorer (:input :max) 50) b))))

(ert-deftest drgnx-perf-modal/relative-check ()
  (let ((r (lambda (typing evil) `((typing :input (:p95 ,typing)) (typing-evil :input (:p95 ,evil))))))
    (let ((fails (drgnx-perf-run--relative-fails (funcall r 3.0 4.1))))
      (should (= (length fails) 1))
      (should (string-search "1.1 ms" (car fails))))
    (should-not (drgnx-perf-run--relative-fails (funcall r 3.0 3.9)))
    (should-not (drgnx-perf-run--relative-fails '((typing :input (:p95 3.0)) (typing-evil :error "boom"))))
    (should-not (drgnx-perf-run--relative-fails '((typing :input (:p95 3.0)))))))

(ert-deftest drgnx-perf-modal/session-sees-the-elpa ()
  (should (member "DRGNX_MODAL_ELPA" drgnx-ui-keep-env)))

(ert-deftest drgnx-perf-modal/only-filters-workloads-by-name ()
  (let ((ws '((typing) (typing-evil) (explorer) (explorer-evil))))
    (drgnx-perf-modal-test--env "DRGNX_PERF_ONLY" nil
      (should (= (length (drgnx-perf-run--only ws)) 4)))
    (drgnx-perf-modal-test--env "DRGNX_PERF_ONLY" ""
      (should (= (length (drgnx-perf-run--only ws)) 4)))
    (drgnx-perf-modal-test--env "DRGNX_PERF_ONLY" "-evil\\'"
      (should (equal (mapcar #'car (drgnx-perf-run--only ws)) '(typing-evil explorer-evil))))
    (drgnx-perf-modal-test--env "DRGNX_PERF_ONLY" "\\`typing\\'"
      (should (equal (mapcar #'car (drgnx-perf-run--only ws)) '(typing))))))

(ert-deftest drgnx-perf-modal/a-filtered-run-judges-only-what-ran-and-keeps-no-history ()
  (let* ((dir (make-temp-file "drgnx-perf-only" t)) (history (expand-file-name "perf-history.jsonl" dir))
         (process-environment (append '("DRGNX_PERF_ONLY=\\`frames\\'" "DRGNX_PERF_MAX_LOAD=4" "DRGNX_PERF_WAIT=0") process-environment)))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-perf-load) (lambda () 1.0))
                  ((symbol-function 'drgnx-ui-state-root) (lambda () dir))
                  ((symbol-function 'drgnx-ui-start) (lambda (&rest _) '(:name "fake")))
                  ((symbol-function 'drgnx-ui-own-session) (lambda (_) 'sess))
                  ((symbol-function 'drgnx-ui-stop) #'ignore)
                  ((symbol-function 'drgnx-perf-run--make-fixture) (lambda () (make-temp-file "drgnx-perf-fixture")))
                  ((symbol-function 'drgnx-perf-run--workloads) (lambda () '((frames :measure "m") (memory :measure "m"))))
                  ((symbol-function 'drgnx-perf-run--call) (lambda (&rest _) '(:frame (:p50 1 :p95 1 :max 1))))
                  ((symbol-function 'drgnx-perf-run--budgets)
                   (lambda () '((frames (:frame :p95) 500) (memory (:rss_kb) 409600))))
                  ((symbol-function 'drgnx-perf-run--commit) (lambda () "c0")))
          (let ((out (with-output-to-string (should (eql (drgnx-perf-run) 0)))))
            (should-not (string-search "memory" out))
            (should-not (string-search "not measured" out))
            (should-not (file-exists-p history))))
      (delete-directory dir t))))

(provide 'perf-modal-test)
;;; perf-modal-test.el ends here
