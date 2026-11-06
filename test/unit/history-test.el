;;; history-test.el --- batch tests: the editor's side of the edit history, without a hub -*- lexical-binding: t -*-
;; Pure: batch splitting, the origin macro, the event-path lints.  The buffers, Nidhogg's change hook and the drain's
;; own timer run for real; no hub is involved (test/unit/history-hub-test.el has the hub).  The rows that need the
;; hook skip on a Nidhogg built without `--with-nidhogg-history'.
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-history)
(require 'drgnx-large-file)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)

(defun drgnx-history-test--hooked-p ()
  "Whether this Emacs has Nidhogg's change hook."
  (fboundp 'nidhogg-history-track))

(defun drgnx-history-test--replay (text changes)
  "TEXT with CHANGES (the hub's: 0-based START, OLD_LEN, INSERTED) applied in order."
  (dolist (c changes text)
    (let ((start (plist-get c :start)))
      (setq text (concat (substring text 0 start) (plist-get c :inserted)
                         (substring text (+ start (plist-get c :old_len))))))))

(ert-deftest drgnx-history/huge-batch-splits ()
  ;; D: a yank of several MiB is one change; the batches stay under the cap, each insert whole characters, and replayed
  ;; they give the text the one change gave
  (let* ((cap drgnx-history-batch-max)
         (big (make-string (* 3 1024 1024) ?é))
         (drained (list (list 3 0 "ab" 1.0 nil) (list 5 2 big 2.0 nil) (list 2 1 "z" 3.0 "agent:s1")))
         (batches (drgnx-history--batches (drgnx-history--changes drained) cap))
         (flat (apply #'append batches)))
    (should (> (length batches) 1))
    (dolist (b batches)
      (should (<= (apply #'+ (mapcar (lambda (c) (string-bytes (plist-get c :inserted))) b)) cap)))
    (should (equal (mapcar (lambda (c) (plist-get c :origin)) (last flat)) '("agent:s1")))
    (should (equal (drgnx-history-test--replay "0123456789" flat)
                   (with-temp-buffer
                     (insert "0123456789")
                     (dolist (c drained)
                       (delete-region (nth 0 c) (+ (nth 0 c) (nth 1 c)))
                       (goto-char (nth 0 c))
                       (insert (nth 2 c)))
                     (buffer-string))))))

(ert-deftest drgnx-history/undo-after-revert-is-the-users ()
  ;; D: Emacs's undo of a revert's edit runs outside `drgnx-history-with-origin': it is the user's change
  (skip-unless (drgnx-history-test--hooked-p))
  (let ((b (generate-new-buffer "history-undo")))
    (unwind-protect
        (with-current-buffer b
          (buffer-enable-undo)
          (insert "one two three")
          (setq buffer-undo-list nil)
          (should (nidhogg-history-track b t))
          (drgnx-history-with-origin "revert" (delete-region 5 9))
          (primitive-undo 1 buffer-undo-list)
          (should (equal (buffer-string) "one two three"))
          (let ((changes (drgnx-history--changes (nidhogg-history-drain b))))
            (should (equal (mapcar (lambda (c) (plist-get c :origin)) changes) '("revert" nil)))))
      (nidhogg-history-track b nil)
      (kill-buffer b))))

(ert-deftest drgnx-history/indirect-buffer-changes-once ()
  ;; D: an indirect buffer shares its base's text: one document, a change made through the clone is drained once, and
  ;; the clone's death leaves the base tracked
  (skip-unless (drgnx-history-test--hooked-p))
  (let ((base (generate-new-buffer "history-base")) clone)
    (unwind-protect
        (progn
          (with-current-buffer base (insert "shared text"))
          (drgnx-history--adopt base "b-1")
          (setq clone (with-current-buffer base (clone-indirect-buffer "history-clone" nil)))
          (should (drgnx-history-tracked-p clone))
          (should-not (drgnx-history--candidate clone))
          (with-current-buffer clone (goto-char 7) (insert "new "))
          (should (= (length (nidhogg-history-drain base)) 1))
          (should-not (nidhogg-history-drain clone))
          (kill-buffer clone)
          (should (drgnx-history-tracked-p base)))
      (when (buffer-live-p clone) (kill-buffer clone))
      (drgnx-history--forget base)
      (kill-buffer base))))

(ert-deftest drgnx-history/mode-off-stops-timer-and-untracks ()
  ;; D under the virtual clock: the drain timer runs only while a buffer is tracked; turning the mode off cancels it
  ;; and stops Nidhogg's recording
  (skip-unless (drgnx-history-test--hooked-p))
  (drgnx-test-with-clock ()
    (let ((b (generate-new-buffer "history-mode")) (was (plist-get (nidhogg-history-stats) :tracked)))
      (unwind-protect
          (progn
            (drgnx-history-mode 1)
            (should-not (drgnx-timer-active-p 'history-drain))
            (drgnx-history--adopt b "b-1")
            (should (drgnx-history-tracked-p b))
            (should (drgnx-timer-active-p 'history-drain))
            (should (= (plist-get (nidhogg-history-stats) :tracked) (1+ was)))
            (drgnx-history-mode -1)
            (should-not (drgnx-timer-active-p 'history-drain))
            (should-not (drgnx-history-tracked-p b))
            (should (= (plist-get (nidhogg-history-stats) :tracked) was))
            (should-not (memq 'drgnx-history--found find-file-hook)))
        (drgnx-history-mode -1)
        (kill-buffer b)))))

(ert-deftest drgnx-history/large-file-is-not-registered ()
  ;; D: a buffer that holds a large file (or a chunk of one) is no producer; one flagged after it was tracked is let go
  (let* ((dir (make-temp-file "history-lf" t)) (file (expand-file-name "a.txt" dir)) b)
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" dir))
          (write-region "x" nil file nil 'silent)
          (setq b (find-file-noselect file))
          (should (drgnx-history--candidate b))
          (with-current-buffer b (setq drgnx-large-file 'chunks))
          (should-not (drgnx-history--candidate b))
          (when (drgnx-history-test--hooked-p)
            (with-current-buffer b (setq drgnx-large-file nil))
            (drgnx-history--adopt b "b-1")
            (should (drgnx-history-tracked-p b))
            (with-current-buffer b (setq drgnx-large-file 'lean) (insert "y"))
            (drgnx-history--drain)
            (should-not (drgnx-history-tracked-p b))))
      (when b (with-current-buffer b (set-buffer-modified-p nil)) (drgnx-history--forget b) (kill-buffer b))
      (delete-directory dir t))))

(ert-deftest drgnx-history/no-prompt-in-timer ()
  ;; D lint: nothing in the module asks the user anything; its hooks and its timer run unattended
  (let ((file (locate-library "drgnx-history.el")))
    (should file)
    (with-temp-buffer
      (insert-file-contents file)
      (dolist (fn '("read-string" "read-from-minibuffer" "completing-read" "y-or-n-p" "yes-or-no-p" "read-key"
                    "read-char" "read-number" "read-file-name" "sit-for" "sleep-for" "accept-process-output"))
        (goto-char (point-min))
        (should-not (re-search-forward (concat "(" (regexp-quote fn) "[ )]") nil t))))))

(provide 'history-test)
;;; history-test.el ends here
