;;; history-hub-test.el --- batch tests: the editor tracks project buffers and drains Nidhogg's changes to the real hub -*- lexical-binding: t -*-
;; The hub runs as its own process (Ratatoskr from DRGNX_RATATOSKR_BIN, a test-hooks build); this Emacs plays the
;; editor on a Nidhogg configured with `--with-nidhogg-history'.  Each test runs inside the delivery gate: the hub's
;; answers reach the editor when the test releases them, and what the hub holds is read from the replies (a batch whose
;; hash matches the document's text answers ok), never from a deadline.
;; test-class: cond
;; test-pattern: gated
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-hub-client)
(require 'drgnx-history)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/delivery-gate-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/hub-client-fixture" drgnx-dir) nil t)   ; its Ratatoskr helpers

(defun drgnx-history-hub-test--git (dir &rest args)
  "git ARGS in DIR; the output must be empty of failure."
  (let ((default-directory dir) (process-environment (append (list "GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null") process-environment)))
    (should (zerop (apply #'process-file "git" nil nil nil
                          "-c" "user.name=t" "-c" "user.email=t@example.invalid" "-c" "commit.gpgsign=false" args)))))

(defun drgnx-history-hub-test--project ()
  "A git project under this test's HOME with a.txt committed and skip.log ignored; its directory."
  (let ((dir (file-name-as-directory (expand-file-name "proj" (getenv "HOME")))))
    (make-directory dir t)
    (with-temp-file (concat dir "a.txt") (insert "one\ntwo\n"))
    (with-temp-file (concat dir "skip.log") (insert "noise\n"))
    (with-temp-file (concat dir ".gitignore") (insert "skip.log\n"))
    (drgnx-history-hub-test--git dir "init" "-q")
    (drgnx-history-hub-test--git dir "add" "a.txt" ".gitignore")
    (drgnx-history-hub-test--git dir "commit" "-q" "-m" "seed")
    dir))

(defmacro drgnx-history-hub-test--with (&rest body)
  "BODY inside the gate with a hub serving ROOT, the project made (DIR), this Emacs connected; the mode and the buffers
BODY made are gone at the end.  Skipped without the hub or the hook (without the hook it fails under DRGNX_NIDHOGG_STRICT=1)."
  (declare (indent 0))
  `(drgnx-hub-client-test--with-hub
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-history-track) "nidhogg-history-track")
     (let ((dir (drgnx-history-hub-test--project)))
       (drgnx-test-gated '((:answers t))
         (drgnx-hub-call-sync "ping" nil 10)
         (unwind-protect (progn ,@body)
           (drgnx-history-mode -1)
           (dolist (b (buffer-list))
             (when (and (buffer-file-name b) (string-prefix-p (expand-file-name root) (buffer-file-name b)))
               (set-buffer-modified-p nil)
               (kill-buffer b))))))))

(defun drgnx-history-hub-test--settle (pred what)
  "Wait until PRED holds, the hub's clock and the drain timer moved before each look."
  (drgnx-test-wait (lambda () (drgnx-test-hub-advance 100) (drgnx-test-advance 0.1) (funcall pred)) :what what))

(ert-deftest drgnx-history/registers-tracked-buffers-only ()
  ;; B: a project file is registered; a gitignored file, a file outside any repository and a buffer with no file are not
  (drgnx-history-hub-test--with
    (let* ((outside (expand-file-name "outside.txt" (getenv "HOME")))
           (ignored (find-file-noselect (concat dir "skip.log")))
           (loose (progn (with-temp-file outside (insert "x")) (find-file-noselect outside)))
           (scratch (generate-new-buffer "history-scratch"))
           (tracked (find-file-noselect (concat dir "a.txt"))))
      (drgnx-history-mode 1)
      (drgnx-history-hub-test--settle (lambda () (drgnx-history-tracked-p tracked)) "the project file registered")
      (drgnx-test-deliver-all)
      (should (drgnx-history-tracked-p tracked))
      (should-not (drgnx-history-tracked-p ignored))
      (should-not (drgnx-history-tracked-p loose))
      (should-not (drgnx-history-tracked-p scratch))
      (kill-buffer scratch)
      (kill-buffer loose))))

(ert-deftest drgnx-history/drain-sends-batches ()
  ;; B: typing in a registered buffer reaches the hub in a batch whose hash matches the document: the hub says ok
  (drgnx-history-hub-test--with
    (let ((b (find-file-noselect (concat dir "a.txt"))))
      (drgnx-history-mode 1)
      (drgnx-history-hub-test--settle (lambda () (drgnx-history-tracked-p b)) "the file registered")
      (with-current-buffer b
        (goto-char (point-max)) (insert "three\n")
        (goto-char 1) (insert "zero ") (delete-region 6 9))
      (drgnx-history-hub-test--settle (lambda () (eq (drgnx-history-last-result b) 'ok)) "the hub took the batch")
      (should (eq (drgnx-history-last-result b) 'ok)))))

(ert-deftest drgnx-history/resync-sends-text ()
  ;; B: a change the hook did not see makes the hub ask for a resync; the buffer's whole text goes, and the next batch is ok
  (drgnx-history-hub-test--with
    (let ((b (find-file-noselect (concat dir "a.txt"))))
      (drgnx-history-mode 1)
      (drgnx-history-hub-test--settle (lambda () (drgnx-history-tracked-p b)) "the file registered")
      (with-current-buffer b
        (nidhogg-history-track b nil)
        (goto-char (point-max)) (insert "unseen\n")
        (nidhogg-history-track b t)
        (insert "seen\n"))
      (drgnx-history-hub-test--settle (lambda () (eq (drgnx-history-last-result b) 'resynced)) "the text resynced")
      (with-current-buffer b (insert "after\n"))
      (drgnx-history-hub-test--settle (lambda () (eq (drgnx-history-last-result b) 'ok)) "the next batch is ok")
      (should (eq (drgnx-history-last-result b) 'ok)))))

(provide 'history-hub-test)
;;; history-hub-test.el ends here
