;;; view-ui-test.el --- GUI tests: views drawing live on a graphical frame (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; The Search view lists 10k matches; a replacement typed into its Replace field patches the rows in place, in
;; slices, the visible ones first, and the jank guard sees no window move it did not own.  The git repository is a
;; temp dir.
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
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-view-ui-test--repo) nil t)

(defun drgnx-view-ui-test--wait (pred &optional secs)
  "Wait (SECS, default 30) until PRED holds, reading process output; PRED's last value."
  (let ((deadline (+ (float-time) (or secs 30))))
    (while (and (not (funcall pred)) (< (float-time) deadline)) (accept-process-output nil 0.05)))
  (funcall pred))

(ert-deftest drgnx-view-ui/replace-retype-has-no-jank ()
  (let* ((root (drgnx-uitest-root-frame))
         (drgnx-wb--sections nil) (drgnx-signal--editor-window nil)
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
            (setq drgnx-signal--editor-window (selected-window))
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
                (let ((first (car (last slices))))
                  (dolist (key visible) (should (memq key first))))
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
