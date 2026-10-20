;;; wb-signal-edge-test.el --- batch tests: the change bus, edge cases -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-signal)

(ert-deftest drgnx-signal-edge/a-failing-window-function-is-recorded-and-the-flush-still-armed ()
  "M3d-3: an error in one `drgnx-signal-window-functions' function neither skips the others nor the
flush schedule, and it is recorded."
  (let* ((drgnx-signal-errors nil) (called nil)
         (drgnx-signal-window-functions
          (list (lambda (_f) (error "Boom")) (lambda (f) (push f called)))))
    (drgnx-timer-cancel 'signal-flush)
    (unwind-protect
        (progn
          (drgnx-signal--windows (selected-frame))
          (should (equal called (list (selected-frame))))
          (should (drgnx-timer-active-p 'signal-flush))
          (should (string-match-p "Boom" (car drgnx-signal-errors))))
      (drgnx-timer-cancel 'signal-flush))))

(ert-deftest drgnx-signal-edge/a-flush-with-many-buffers-is-cheap ()
  "M3d-8: a flush with 1500 file buffers takes under 10 ms — the best of five, so one slice of a
busy machine is not judged."
  :tags '(:timing)                                      ; a quiet machine: bin/drgnx check runs it alone
  (let ((drgnx-signal--subscribers nil) (drgnx-signal--state nil) (drgnx-signal-errors nil)
        (dir (make-temp-file "drgnx-signal-edge" t)))
    (unwind-protect
        (progn
          (dotimes (i 1500)
            (let ((f (expand-file-name (format "f%04d.txt" i) dir)))
              (write-region "x\n" nil f nil 'silent)
              (find-file-noselect f)))
          (drgnx-signal--flush)                       ; the starting state
          (should (< (cl-loop repeat 5
                              minimize (let ((t0 (float-time))) (drgnx-signal--flush) (- (float-time) t0)))
                     0.01)))
      (dolist (b (buffer-list))
        (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b))) (kill-buffer b)))
      (drgnx-timer-cancel 'signal-flush)
      (delete-directory dir t))))

;;; Dirty flags (PERF-M2): a flush rebuilds only what a hook said changed.

(defmacro drgnx-signal-edge--with-hooks (events-var &rest body)
  "BODY with a fresh bus, the mode on (its real hooks) and the starting state flushed.
Every emission is pushed onto EVENTS-VAR as (EVENT . DATA)."
  (declare (indent 1))
  `(let ((drgnx-signal--subscribers nil) (drgnx-signal--state nil) (drgnx-signal-errors nil)
         (drgnx-signal--dirty nil) (drgnx-signal--seen-buffer nil)
         (drgnx-signal--seen-modified nil) (drgnx-signal--seen-name nil)
         (was-on drgnx-signal-mode) (,events-var nil)
         (dir (make-temp-file "drgnx-signal-edge" t)))
     (unwind-protect
         (progn
           (drgnx-signal-mode 1)
           (dolist (e '(buffer-set-changed modified-changed))
             (let ((e e)) (drgnx-signal-subscribe e (lambda (data) (push (cons e data) ,events-var)))))
           (drgnx-signal--flush)
           (setq ,events-var nil)
           ,@body)
       (unless was-on (drgnx-signal-mode -1))
       (drgnx-timer-cancel 'signal-flush)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p dir (buffer-file-name b)))
           (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b)))
       (delete-directory dir t))))

(defun drgnx-signal-edge--file (dir name)
  (let ((f (expand-file-name name dir))) (write-region "x\n" nil f nil 'silent) (find-file-noselect f)))

(defun drgnx-signal-edge--keystroke ()
  "What a keystroke does to the bus: the real `post-command-hook', then the idle flush."
  (run-hooks 'post-command-hook)
  (drgnx-signal--flush))

(ert-deftest drgnx-signal-edge/a-keystroke-with-nothing-dirty-reads-no-buffer-list ()
  (drgnx-signal-edge--with-hooks events
    (let ((a (drgnx-signal-edge--file dir "a.txt")) (calls 0) (real (symbol-function 'buffer-list)))
      (drgnx-signal--flush)
      (with-current-buffer a
        (cl-letf (((symbol-function 'buffer-list) (lambda (&rest args) (cl-incf calls) (apply real args))))
          ;; Redefining a primitive may compile a trampoline (native compilation), which makes buffers
          ;; and so dirties the set: take that flush before counting.
          (drgnx-signal-edge--keystroke)
          (setq calls 0 events nil)
          (dotimes (_ 3) (drgnx-signal-edge--keystroke))))
      (should (= calls 0))
      (should (null events)))))

(ert-deftest drgnx-signal-edge/undo-to-saved-still-flips-modified ()
  (drgnx-signal-edge--with-hooks events
    (let ((a (drgnx-signal-edge--file dir "a.txt")))
      (drgnx-signal--flush)
      (with-current-buffer a
        (buffer-enable-undo)
        (undo-boundary)
        (insert "more")
        (drgnx-signal-edge--keystroke)
        (should (equal (cdr (assq 'modified-changed events)) (list a)))
        (setq events nil)
        (undo-boundary)
        (let ((last-command nil) (this-command 'undo)) (undo))
        (should-not (buffer-modified-p))                ; back to the saved state: no hook ran
        (drgnx-signal-edge--keystroke)
        (should (equal (cdr (assq 'modified-changed events)) (list a)))))))

(ert-deftest drgnx-signal-edge/set-buffer-modified-p-is-still-seen ()
  (drgnx-signal-edge--with-hooks events
    (let ((a (drgnx-signal-edge--file dir "a.txt")))
      (drgnx-signal--flush)
      (with-current-buffer a
        (drgnx-signal-edge--keystroke)
        (set-buffer-modified-p t)
        (drgnx-signal-edge--keystroke)
        (should (equal (cdr (assq 'modified-changed events)) (list a)))
        (setq events nil)
        (set-buffer-modified-p nil)
        (drgnx-signal-edge--keystroke)
        (should (equal (cdr (assq 'modified-changed events)) (list a)))))))

(ert-deftest drgnx-signal-edge/a-rename-is-still-seen ()
  "The hook alone sees it (no `post-command-hook' runs): `rename-buffer' runs `buffer-list-update-hook'."
  (drgnx-signal-edge--with-hooks events
    (let ((a (drgnx-signal-edge--file dir "a.txt")))
      (drgnx-signal--flush)
      (setq events nil)
      (with-current-buffer a (rename-buffer "renamed.txt"))
      (drgnx-signal--flush)
      (should (memq a (cdr (assq 'buffer-set-changed events)))))))

(ert-deftest drgnx-signal-edge/a-kill-is-still-seen ()
  (drgnx-signal-edge--with-hooks events
    (let ((a (drgnx-signal-edge--file dir "a.txt")))
      (drgnx-signal--flush)
      (setq events nil)
      (kill-buffer a)
      (drgnx-signal--flush)
      (should (assq 'buffer-set-changed events))
      (should-not (memq a (cdr (assq 'buffer-set-changed events)))))))

(ert-deftest drgnx-signal-edge/each-hook-marks-its-part ()
  "Named raw-hook functions, one per kind of change; none of them is a lambda."
  (drgnx-signal-edge--with-hooks events
    (pcase-dolist (`(,hook ,fn ,parts)
                   '((buffer-list-update-hook drgnx-signal--set-dirty (set))
                     (first-change-hook drgnx-signal--modified-dirty (modified))
                     (after-save-hook drgnx-signal--modified-dirty (modified))
                     (after-save-hook drgnx-signal--set-dirty (set))
                     (after-revert-hook drgnx-signal--modified-dirty (modified))
                     (after-change-major-mode-hook drgnx-signal--mode-changed (set))
                     (kill-buffer-hook drgnx-signal--killed (set modified))))
      (should (memq fn (default-value hook)))
      (setq drgnx-signal--dirty nil)
      (with-temp-buffer (rename-buffer "visible") (funcall fn))
      (should (equal (sort (copy-sequence drgnx-signal--dirty) (function string<))
                     (sort (copy-sequence parts) (function string<)))))
    (setq drgnx-signal--dirty nil)
    (with-temp-buffer (rename-buffer " internal") (drgnx-signal--mode-changed))
    (should-not drgnx-signal--dirty)                  ; a mode call in an internal buffer is no change
    (drgnx-signal-mode -1)
    (pcase-dolist (`(,hook . ,fn) drgnx-signal--hooks)
      (should-not (memq fn (default-value hook))))
    (should-not (memq 'drgnx-signal--windows (default-value 'window-buffer-change-functions)))
    (should-not drgnx-signal--seen-buffer)))

(ert-deftest drgnx-signal-edge/write-file-and-a-mode-change-enter-the-set ()
  "No rename, no new buffer: only `after-save-hook' / `after-change-major-mode-hook' say the set changed."
  (drgnx-signal-edge--with-hooks events
    (let ((w (generate-new-buffer "plain")) (d (generate-new-buffer "listing")))
      (unwind-protect
          (progn
            (drgnx-signal--flush)                    ; both created: take their hook's flush first
            (setq events nil)
            (with-current-buffer w
              (write-file (expand-file-name "plain" dir)) ; same name as the buffer: no rename
              (should (equal (buffer-name) "plain")))
            (drgnx-signal--flush)
            (should (memq w (cdr (assq 'buffer-set-changed events))))
            (setq events nil)
            (with-current-buffer d (require 'dired) (dired-mode dir))
            (drgnx-signal--flush)
            (should (memq d (cdr (assq 'buffer-set-changed events)))))
        (mapc #'kill-buffer (list w d))))))

(ert-deftest drgnx-signal-edge/a-flag-changed-in-another-buffer-is-seen-when-it-becomes-current ()
  "The cross-buffer branch of the post-command check: compared with what the last flush saw of the buffer."
  (drgnx-signal-edge--with-hooks events
    (let ((a (drgnx-signal-edge--file dir "a.txt")) (b (drgnx-signal-edge--file dir "b.txt")))
      (drgnx-signal--flush)
      (with-current-buffer a (drgnx-signal-edge--keystroke))
      (setq events nil)
      (with-current-buffer b (set-buffer-modified-p t))   ; no hook; `a' is the buffer the last command saw
      (with-current-buffer b (drgnx-signal-edge--keystroke))
      (should (equal (cdr (assq 'modified-changed events)) (list b))))))

(ert-deftest drgnx-signal-edge/a-keystroke-flush-with-300-buffers-is-cheap ()
  "A keystroke that changed no buffer: the hook and the flush take a median of 50 µs at most with 300 buffers
\(479 µs when the flush scanned them all)."
  :tags '(:timing)
  (drgnx-signal-edge--with-hooks events
    (let ((bufs nil))
      (unwind-protect
          (progn
            (dotimes (i 300)
              (with-current-buffer (generate-new-buffer (format "edge-%d" i))
                (setq buffer-file-name (expand-file-name (format "edge-%d.txt" i) dir))
                (push (current-buffer) bufs)))
            (drgnx-signal--flush)
            (with-current-buffer (car bufs)
              (drgnx-signal-edge--keystroke)
              (let ((samples nil))
                (dotimes (_ 200)
                  (let ((t0 (float-time))) (drgnx-signal-edge--keystroke) (push (- (float-time) t0) samples)))
                (setq samples (sort samples #'<))
                (should (< (nth 100 samples) 50e-6)))))
        (dolist (b bufs) (with-current-buffer b (set-buffer-modified-p nil) (setq buffer-file-name nil)) (kill-buffer b))))))

;;; wb-signal-edge-test.el ends here
