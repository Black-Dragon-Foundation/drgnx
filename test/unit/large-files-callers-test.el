;;; large-files-callers-test.el --- batch tests: callers that visit files say what they need if a file is large -*- lexical-binding: t -*-
;; Persist and layouts open automatically (`auto'), Replace, AI apply-hunk and the agent edit review need the whole
;; file (`whole'); they keep their nil `large-file-warning-threshold', so with editor/large-files off nothing asks
;; either.  The module is never set up here: only what the callers bind is checked.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx)
(require 'drgnx-large-file)
(require 'drgnx-persist)
(load (expand-file-name "modules/tools/drgnx-layouts" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-ai-ui" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)

(defmacro drgnx-large-files-callers-test--visit (form)
  "Run FORM with `find-file-noselect' stubbed: the first visit leaves FORM with what it saw, the list
\(`drgnx-large-file-open' `large-file-warning-threshold'), read in the buffer it was called from."
  `(catch 'visited
     (cl-letf (((symbol-function 'find-file-noselect)
                (lambda (&rest _) (throw 'visited (list drgnx-large-file-open large-file-warning-threshold)))))
       ,form
       'no-visit)))

(ert-deftest drgnx-large-files/callers-bind-what-they-need ()
  (let* ((dir (make-temp-file "drgnx-lf-callers" t)) (file (expand-file-name "f.txt" dir)))
    (write-region "one\ntwo\n" nil file nil 'silent)
    (unwind-protect
        (progn
          ;; Persist and layouts: automatic, and Emacs's own question stays off
          (should (equal (drgnx-large-files-callers-test--visit (drgnx-persist--visit file)) '(auto nil)))
          (should (equal (cl-letf (((symbol-function 'window-state-put) (lambda (&rest _) (find-file-noselect file)))
                                   ((symbol-function 'drgnx-layouts--reopen-groups) #'ignore))
                           (drgnx-large-files-callers-test--visit (drgnx-layouts--put-main (list :fill t :main nil))))
                         '(auto nil)))
          ;; Replace's two visits: the whole file
          (should (equal (drgnx-large-files-callers-test--visit (drgnx-replace--apply-file file nil "x")) '(whole nil)))
          (with-temp-buffer
            (should (equal (drgnx-large-files-callers-test--visit
                            (drgnx-replace--show-match (list :file file :line 1 :col 0 :text "one") nil))
                           '(whole nil))))
          ;; AI apply-hunk: the whole review copy
          (with-temp-buffer
            (setq-local drgnx-ai--edit (list :copy file))
            (should (eq (car (drgnx-large-files-callers-test--visit (drgnx-ai-edit-apply-hunk))) 'whole)))
          ;; the agent edit review: diff-mode visits the copy from the review's buffer, which says `whole'
          (let* ((s (drgnx-agents--make :name "fake" :cwd dir))
                 (b (drgnx-agents-ui--review-open s (list :id 5 :path file :content "one\nTWO\n"))))
            (unwind-protect
                (with-current-buffer b
                  (should (eq (buffer-local-value 'drgnx-large-file-open b) 'whole))
                  (goto-char (point-min))
                  (diff-hunk-next)
                  (should (eq (car (drgnx-large-files-callers-test--visit (diff-apply-hunk))) 'whole)))
              (kill-buffer b))))
      (delete-directory dir t))))

(ert-deftest drgnx-large-files/off-persist-and-replace-never-ask ()
  ;; editor/large-files is not set up, and Emacs's own threshold is 1 KiB: a 2 KiB file opened by Persist and by
  ;; Replace (both of its visits) asks nothing
  (let* ((dir (make-temp-file "drgnx-lf-off" t)) (file (expand-file-name "big.txt" dir))
         (large-file-warning-threshold 1024))
    (write-region (make-string 2048 ?x) nil file nil 'silent)
    (unwind-protect
        (cl-letf (((symbol-function 'read-multiple-choice) (lambda (&rest _) (ert-fail "read-multiple-choice asked")))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) (ert-fail "y-or-n-p asked"))))
          (let ((b (drgnx-persist--visit file)))      ; it swallows errors: a question would give nil
            (should (buffer-live-p b))
            (kill-buffer b))
          (should (equal (drgnx-replace--apply-file file nil "y") '(0 nil nil)))
          (kill-buffer (find-buffer-visiting file))
          (with-temp-buffer
            (cl-letf (((symbol-function 'drgnx-wb-show-in-editor) (lambda (_buf _select) (selected-window))))
              (drgnx-replace--show-match (list :file file :line 1 :col 0 :text "x") nil)))
          (should (find-buffer-visiting file)))
      (when-let* ((b (find-buffer-visiting file))) (kill-buffer b))
      (delete-directory dir t))))

;;; large-files-callers-test.el ends here
