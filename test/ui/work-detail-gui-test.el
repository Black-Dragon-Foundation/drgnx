;;; work-detail-gui-test.el --- GUI tests: Detail's target field (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; A spec's or plan's Detail has a Target field in place: a date typed there is sent as `work/target/set' (the item and
;; the time), an empty field clears it.  The hub is stubbed at `drgnx-hub-call'.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ui-work-detail--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-work-detail--repo)))
(require 'drgnx)
(require 'drgnx-work-target)

(defmacro drgnx-ui-work-detail--with (calls &rest body)
  (declare (indent 1))
  `(let ((,calls nil))
     (skip-unless (display-graphic-p))
     (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (method params &optional _cb) (push (cons method params) ,calls)))
               ((symbol-function 'read-string) (lambda (&rest _) (error "A prompt: the target field never prompts")))
               ((symbol-function 'quit-window) #'ignore))
       (unwind-protect (progn ,@body)
         (when (get-buffer "*Set target*") (kill-buffer "*Set target*"))))))

(ert-deftest drgnx-ui-work-detail/target-field-sets-and-clears ()
  (drgnx-ui-work-detail--with calls
    (drgnx-work-target-set "plan:p1" "2026-12-01")
    (let ((c (cdr (cl-find "work/target/set" calls :key #'car :test #'equal))))
      (should (equal "plan:p1" (plist-get c :item)))
      (should (= (float-time (date-to-time "2026-12-01 00:00:00")) (plist-get c :target_at))))
    ;; an empty field clears it
    (drgnx-work-target-set "plan:p1" "")
    (let ((c (cdr (car calls))))
      (should (equal "plan:p1" (plist-get c :item)))
      (should-not (plist-get c :target_at)))))

(ert-deftest drgnx-ui-work-detail/a-target-is-for-a-spec-or-a-plan-only ()
  (drgnx-ui-work-detail--with calls
    (should-error (drgnx-work-target-set "task:t1" "2026-12-01") :type 'user-error)
    (should-not calls)))

(provide 'work-detail-gui-test)
;;; work-detail-gui-test.el ends here
