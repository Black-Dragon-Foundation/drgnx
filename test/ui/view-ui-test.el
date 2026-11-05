;;; view-ui-test.el --- GUI tests: views drawing live on a graphical frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; The Search view lists 10k matches; a replacement typed into its Replace field patches the rows in place, in
;; slices, the visible ones first, and the jank guard sees no window move it did not own.  The git repository is a
;; temp dir.  (A transcript streaming from a hub session while keys are typed is the perf scenario `agent-stream'.)
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-view-ui-test--repo                      ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-view-ui-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-view-ui-test--repo))
(require 'drgnx)
(require 'drgnx-wb)
(load (expand-file-name "test/fixtures/git-fixture" drgnx-view-ui-test--repo) nil t)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-view-ui-test--repo) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-view-ui-test--repo) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-view-ui-test--repo) nil t)

(defun drgnx-view-ui-test--wait (pred &optional secs)
  "Wait until PRED holds, reading process output: PRED's value (`drgnx-test-wait', at least 30 s or SECS).
It runs the view's slice chain back to back (CI-GUI-1: a poll per slice starved 10,100 rows)."
  (drgnx-test-wait pred :secs (max 30 (or secs 0)) :what "the view GUI test's predicate"))

(ert-deftest drgnx-view-ui/replace-retype-has-no-jank ()
  ;; The rows the window shows are patched before any other row.  Not that the first slice holds them all: a slice
  ;; stops at its 4 ms deadline (`drgnx-view-slice'), which a loaded machine reaches inside the visible rows, and the
  ;; next slice goes on with them.
  :tags '(:timing)
  (let* ((root (drgnx-uitest-root-frame))
         (drgnx-wb--sections nil)
         (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (types drgnx-view--types) (orig (symbol-function 'drgnx-replace--rows-drawn)) (slices nil))
    (unwind-protect
        (drgnx-git-test-with-repo
          (let ((text (apply #'concat (make-list 100 "a needle in the haystack, line after line\n"))))
            (dotimes (i 100) (drgnx-git-test-write repo (format "d/f%03d.txt" i) text)))
          (with-selected-frame root
            (delete-other-windows)
            (set-frame-parameter nil 'drgnx-wb-view nil)
            (drgnx-replace--define-section)
            (drgnx-replace--define-commands)
            (find-file (expand-file-name "d/f000.txt" repo))
            (drgnx-test-use-editor (selected-window))
            (goto-char 4)
            (drgnx-replace-in-files)
            (let* ((view (get-buffer drgnx-replace-buffer-name)) (w (drgnx-wb-section-window 'search))
                   (v (buffer-local-value 'drgnx-view view)))
              (should (drgnx-view-ui-test--wait (lambda () (with-current-buffer view (not (drgnx-replace--busy-p))))))
              (should (= 10100 (drgnx-view-row-count v)))
              ;; point in the Replace field (the window shows it: the fields and the first rows)
              (select-window w)
              (with-current-buffer view (goto-char (widget-field-start (drgnx-replace--widget 'replace))))
              (redisplay t)
              (let ((visible nil)
                    (drgnx-uitest-quiet 0.6))     ; the redraw starts a pause (0.25 s) after the last key
                (cl-letf (((symbol-function 'drgnx-replace--rows-drawn)
                           (lambda (vw keys)
                             (unless slices        ; the first slice after the typing: what the window shows now
                               (pcase-dolist (`(,from . ,to) (drgnx-view--visible-ranges vw))
                                 (cl-loop for i from from below (min to (drgnx-view-row-count vw))
                                          for key = (aref (drgnx-view--keys vw) i)
                                          unless (eq (car key) 'drgnx-replace-file) do (push key visible))))
                             (push keys slices)
                             (funcall orig vw keys))))
                  (let ((r (drgnx-uitest-run (drgnx-uitest-type-events "pin"))))
                    (message "replace-retype: %S" (list :guard (plist-get r :guard_violations) :slices (length slices)
                                                        :stats (drgnx-view-stats v)))
                    (should (eq t (plist-get r :settled)))
                    (should (= 0 (plist-get r :guard_violations)))))
                (should (drgnx-view-ui-test--wait (lambda () (with-current-buffer view (not (drgnx-replace--busy-p))))))
                (should visible)
                (should (> (length slices) 1))
                ;; in drawing order, every shown row is first drawn before the first match row the window did not show
                ;; (a redraw that starts again, after a late key, draws them again later)
                (let* ((order (apply #'append (reverse slices)))
                       (last-shown (cl-loop for key in visible   ; a shown row never drawn: never before the others
                                            maximize (or (cl-position key order :test #'eq) most-positive-fixnum)))
                       (first-other (cl-loop for key in order for i from 0   ; a match's key is its plist
                                             when (and (not (eq (car key) 'drgnx-replace-file)) (not (memq key visible)))
                                             return i)))
                  (dolist (key visible) (should (memq key order)))
                  (should (or (null first-other) (< last-shown first-other))))
                (should (= 0 (plist-get (drgnx-view-stats v) :full-draws)))
                (with-current-buffer view
                  (should (string-search "needlepin" (buffer-substring-no-properties (window-start w) (point-max)))))))))
      (with-selected-frame root
        (drgnx-wb-hide-sidebar)
        (delete-other-windows)
        (set-frame-parameter nil 'drgnx-wb-view nil)
        (switch-to-buffer "*scratch*"))
      (when (get-buffer drgnx-replace-buffer-name) (kill-buffer drgnx-replace-buffer-name))
      (setq drgnx-view--types types))))

;;; view-ui-test.el ends here
