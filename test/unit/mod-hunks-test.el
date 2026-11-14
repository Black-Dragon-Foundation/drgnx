;;; mod-hunks-test.el --- batch tests: the change marks in the gutter, from the hub -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-hunks" drgnx-dir) nil t)

(defvar mod-hunks-test--asked nil "The questions `drgnx-history-ask' got: (METHOD PARAMS CALLBACK), newest first.")
(defvar mod-hunks-test--tracked t "Whether the stubbed history tracks the buffer.")

(defmacro mod-hunks-test--with-buffer (text &rest body)
  "BODY in a buffer holding TEXT with the hunks mode on, the history stubbed: it records its questions."
  (declare (indent 1))
  `(let ((mod-hunks-test--asked nil) (mod-hunks-test--tracked t))
     (cl-letf (((symbol-function 'drgnx-history-ask)
                (lambda (_buffer method callback &optional params)
                  (when mod-hunks-test--tracked
                    (push (list method params callback) mod-hunks-test--asked)
                    t)))
               ((symbol-function 'drgnx-hunks--schedule) #'ignore))
       (with-temp-buffer
         (insert ,text)
         (drgnx-hunks-mode 1)
         (drgnx-hunks--refresh (current-buffer))              ; the timer's job: the question goes
         (unwind-protect (progn ,@body) (drgnx-hunks-mode -1))))))

(defun mod-hunks-test--hub-marks (hunks)
  "The marks the hub sends for HUNKS (plists as the JSON gives them) over this buffer's text: what
`editor::marks::hunk_marks' makes (pinned by its Rust test), so the answers below are the hub's."
  (let (out (last (1+ (cl-count ?\n (buffer-string)))))
    (dolist (h hunks)
      (let ((oc (plist-get h :old_count)) (nc (plist-get h :new_count)) (ns (plist-get h :new_start)))
        (dotimes (i (max nc 1))
          (let ((line (min last (if (zerop nc) (1+ ns) (+ ns i)))))
            (push (list :line line
                        :pos (save-excursion (goto-char (point-min)) (forward-line (1- line)) (point))
                        :kind (cond ((zerop nc) "deleted") ((< i oc) "changed") (t "added")))
                  out)))))
    (sort (nreverse out) (lambda (a b) (< (plist-get a :line) (plist-get b :line))))))

(defun mod-hunks-test--answer (&rest hunks)
  "The hub's answer to the oldest question: HUNKS (plists as the JSON gives them) and their marks."
  (let ((q (car (last mod-hunks-test--asked))))
    (setq mod-hunks-test--asked (butlast mod-hunks-test--asked))
    (funcall (nth 2 q) (list :tracked t :hunks hunks :marks (mod-hunks-test--hub-marks hunks)) nil)))

(defun mod-hunks-test--marks ()
  "(LINE . KIND) of the marks drawn, in line order."
  (sort (mapcar (lambda (o) (cons (line-number-at-pos (overlay-start o)) (overlay-get o 'drgnx-hunk)))
                drgnx-hunks--overlays)
        (lambda (a b) (< (car a) (car b)))))

;; The marks' arithmetic (added, changed, deleted; the lines' positions) is the hub's: `editor::marks' and its tests.
;; Lisp keeps the overlays: no line is counted or walked to, and an answer touches only the overlays that changed.
(ert-deftest drgnx-hunks/an-answer-lays-its-marks-without-counting-or-walking-lines ()
  (mod-hunks-test--with-buffer "one\ntwo\nthree\nfour\nfive\n"
    (let* ((hunk '(:old_start 2 :old_count 1 :new_start 2 :new_count 1 :old_lines ("2\n")))
           (result (list :tracked t :hunks (list hunk) :marks (mod-hunks-test--hub-marks (list hunk))))
           (callback (nth 2 (car mod-hunks-test--asked))))
      (cl-letf (((symbol-function 'forward-line) (lambda (&rest _) (error "walked a line")))
                ((symbol-function 'line-number-at-pos) (lambda (&rest _) (error "counted a line"))))
        (funcall callback result nil)))
    (should (equal (mapcar (lambda (o) (overlay-start o)) drgnx-hunks--overlays) '(5)))))

(ert-deftest drgnx-hunks/a-new-answer-changes-only-the-overlays-whose-mark-changed ()
  (mod-hunks-test--with-buffer "a\nb\nc\nd\n"
    (mod-hunks-test--answer '(:old_start 1 :old_count 1 :new_start 1 :new_count 1 :old_lines ("x\n"))
                            '(:old_start 3 :old_count 1 :new_start 3 :new_count 1 :old_lines ("y\n")))
    (let ((first (seq-find (lambda (o) (= (overlay-start o) 1)) drgnx-hunks--overlays))
          (third (seq-find (lambda (o) (= (overlay-start o) 5)) drgnx-hunks--overlays)))
      (drgnx-hunks--refresh (current-buffer))
      ;; line 3's change went, line 4's came: line 1's overlay is the same one
      (mod-hunks-test--answer '(:old_start 1 :old_count 1 :new_start 1 :new_count 1 :old_lines ("x\n"))
                              '(:old_start 4 :old_count 0 :new_start 4 :new_count 1 :old_lines nil))
      (should (memq first drgnx-hunks--overlays))
      (should-not (overlay-buffer third))
      (should (equal (sort (mapcar #'overlay-start drgnx-hunks--overlays) #'<) '(1 7))))))

(ert-deftest drgnx-hunks/an-answer-for-text-since-edited-waits-for-the-next ()
  (mod-hunks-test--with-buffer "a\nb\n"
    (goto-char (point-min))
    (insert "new\n")                                          ; typed after the question went
    (mod-hunks-test--answer '(:old_start 1 :old_count 1 :new_start 1 :new_count 1 :old_lines ("x\n")))
    (should-not drgnx-hunks--overlays)))

(ert-deftest drgnx-hunks/the-hubs-answer-is-drawn-as-solid-bars ()
  (mod-hunks-test--with-buffer "one\ntwo\nthree\nfour\nfive\n"
    (should (equal (car (car mod-hunks-test--asked)) "history/hunks/head"))
    (mod-hunks-test--answer '(:old_start 2 :old_count 1 :new_start 2 :new_count 1 :old_lines ("2\n"))
                            '(:old_start 4 :old_count 0 :new_start 5 :new_count 1 :old_lines nil))
    (should (equal (mod-hunks-test--marks) '((2 . changed) (5 . added))))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (drgnx-hunks--draw)
      (let ((spec (get-text-property 0 'display (overlay-get (car drgnx-hunks--overlays) 'before-string))))
        (should (eq (car spec) 'left-fringe))
        (should (memq (nth 1 spec) '(drgnx-hunk-bar drgnx-hunk-delete)))
        (should (memq (nth 2 spec) '(drgnx-hunk-added drgnx-hunk-changed)))))
    ;; a terminal has no fringe: a margin character, and a margin to hold it
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (drgnx-hunks--draw)
      (should (equal (car (get-text-property 0 'display (overlay-get (car drgnx-hunks--overlays) 'before-string)))
                     '(margin left-margin)))
      (should (= left-margin-width 1)))
    ;; an answer again replaces the marks
    (drgnx-hunks--refresh (current-buffer))
    (mod-hunks-test--answer)
    (should-not drgnx-hunks--overlays)))

(ert-deftest drgnx-hunks/the-bars-and-faces-follow-the-status-colours ()
  (should (memq 'drgnx-status-ok (ensure-list (face-attribute 'drgnx-hunk-added :inherit nil t))))
  (should (memq 'drgnx-status-info (ensure-list (face-attribute 'drgnx-hunk-changed :inherit nil t))))
  (should (memq 'drgnx-status-fail (ensure-list (face-attribute 'drgnx-hunk-deleted :inherit nil t)))))

(ert-deftest drgnx-hunks/the-bar-is-three-logical-pixels-of-device-pixels ()
  (skip-unless (fboundp 'define-fringe-bitmap))
  (setq drgnx-hunks--bitmap-width nil)
  (cl-letf (((symbol-function 'drgnx-px) (lambda (n &rest _) (* 2 n))))     ; scale 2
    (drgnx-hunks--define-bitmaps)
    (should (= drgnx-hunks--bitmap-width 6))
    (should (equal (get 'drgnx-hunk-bar 'fringe) (get 'drgnx-hunk-bar 'fringe)))))

(ert-deftest drgnx-hunks/the-bar-sits-against-the-line-numbers ()
  "window-dark.html `.ln .g': the bar is just left of the number column, so its bits are the bitmap's right ones
(the fringe's inner side, where the numbers start)."
  (should (= (drgnx-hunks--bar-row 3) #b00000111))
  (should (= (drgnx-hunks--bar-row 6) #b00111111)))

(ert-deftest drgnx-hunks/a-line-an-agent-draws-is-left-out ()
  (mod-hunks-test--with-buffer "a\nb\nc\nd\n"
    (let ((drgnx-hunks-skip-line-function (lambda (line) (= line 2))))
      (mod-hunks-test--answer '(:old_start 1 :old_count 3 :new_start 1 :new_count 3 :old_lines ("x\n" "y\n" "z\n")))
      (should (equal (mod-hunks-test--marks) '((1 . changed) (3 . changed)))))
    (drgnx-hunks-redraw)                                    ; the strip went: the line is marked again
    (should (equal (mod-hunks-test--marks) '((1 . changed) (2 . changed) (3 . changed))))))

(ert-deftest drgnx-hunks/a-buffer-the-history-does-not-track-yet-is-tried-again-then-left ()
  (mod-hunks-test--with-buffer "a\n"
    (setq mod-hunks-test--tracked nil)
    (setq mod-hunks-test--asked nil)
    (let ((scheduled 0))
      (cl-letf (((symbol-function 'drgnx-hunks--schedule) (lambda (&rest _) (cl-incf scheduled))))
        (dotimes (_ 30) (drgnx-hunks--refresh (current-buffer)))
        (should (= scheduled (1- drgnx-hunks--tries-max)))))
    (should-not drgnx-hunks--overlays)))

(ert-deftest drgnx-hunks/an-answer-that-says-untracked-clears-the-marks ()
  (mod-hunks-test--with-buffer "a\nb\n"
    (mod-hunks-test--answer '(:old_start 1 :old_count 1 :new_start 1 :new_count 1 :old_lines ("x\n")))
    (should drgnx-hunks--overlays)
    (drgnx-hunks--refresh (current-buffer))
    (funcall (nth 2 (car mod-hunks-test--asked)) (list :tracked nil :hunks nil) nil)
    (should-not drgnx-hunks--overlays)))

(ert-deftest drgnx-hunks/the-drained-hook-asks-again ()
  (let ((scheduled nil))
    (with-temp-buffer
      (cl-letf (((symbol-function 'drgnx-hunks--schedule) (lambda (b &rest _) (push b scheduled))))
        (drgnx-hunks--drained (current-buffer) 1 nil)
        (should-not scheduled)                              ; the mode is off here
        (setq-local drgnx-hunks-mode t)
        (drgnx-hunks--drained (current-buffer) 2 nil)
        (should (equal scheduled (list (current-buffer))))))))

(ert-deftest drgnx-hunks/revert-puts-the-commits-lines-back ()
  (mod-hunks-test--with-buffer "a\nB\nc\nnew\n"
    (mod-hunks-test--answer '(:old_start 2 :old_count 1 :new_start 2 :new_count 1 :old_lines ("b\n"))
                            '(:old_start 3 :old_count 0 :new_start 4 :new_count 1 :old_lines nil)
                            '(:old_start 0 :old_count 0 :new_start 0 :new_count 0 :old_lines nil))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (goto-char (point-min)) (forward-line 1)
      (drgnx-hunks-revert)
      (should (equal (buffer-string) "a\nb\nc\nnew\n"))
      (goto-char (point-min)) (forward-line 3)              ; an added line goes
      (drgnx-hunks-revert)
      (should (equal (buffer-string) "a\nb\nc\n")))))

(ert-deftest drgnx-hunks/revert-of-a-deletion-inserts-the-lines ()
  (mod-hunks-test--with-buffer "a\nc\n"
    (mod-hunks-test--answer '(:old_start 2 :old_count 1 :new_start 1 :new_count 0 :old_lines ("b\n")))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (goto-char (point-min)) (forward-line 1)              ; the line after the deletion
      (drgnx-hunks-revert)
      (should (equal (buffer-string) "a\nb\nc\n")))))

(ert-deftest drgnx-hunks/no-hunk-at-point-is-a-user-error ()
  (mod-hunks-test--with-buffer "a\nb\n"
    (mod-hunks-test--answer)
    (should-error (drgnx-hunks-revert) :type 'user-error)
    (should-error (drgnx-hunks-stage) :type 'user-error)
    (should-error (drgnx-hunks-show) :type 'user-error)))

(ert-deftest drgnx-hunks/stage-asks-the-hub-for-the-hunk-at-point ()
  (mod-hunks-test--with-buffer "a\nB\nc\n"
    (mod-hunks-test--answer '(:old_start 2 :old_count 1 :new_start 2 :new_count 1 :old_lines ("b\n")))
    (goto-char (point-min)) (forward-line 1)
    (drgnx-hunks-stage)
    (let ((q (car mod-hunks-test--asked)))
      (should (equal (car q) "git/stage-hunk"))
      (should (equal (plist-get (nth 1 q) :new_start) 2))
      (should (equal (car (last mod-hunks-test--asked)) q)))
    (setq mod-hunks-test--tracked nil)
    (should-error (drgnx-hunks-stage) :type 'user-error)))

(ert-deftest drgnx-hunks/show-change-is-a-unified-hunk ()
  (mod-hunks-test--with-buffer "a\nB\nc\n"
    (mod-hunks-test--answer '(:old_start 2 :old_count 1 :new_start 2 :new_count 1 :old_lines ("b\n")))
    (goto-char (point-min)) (forward-line 1)
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (drgnx-hunks-show))
    (with-current-buffer "*drgnx change*"
      (should (equal (buffer-substring-no-properties (point-min) (point-max)) "@@ -2,1 +2,1 @@\n-b\n+B\n")))
    (kill-buffer "*drgnx change*")))

(ert-deftest drgnx-hunks/only-local-files-git-tracks ()
  (with-temp-buffer
    (setq buffer-file-name "/ssh:host:/x.txt")
    (cl-letf (((symbol-function 'file-remote-p) (lambda (&rest _) "/ssh:host:")))
      (drgnx-hunks--maybe)
      (should-not drgnx-hunks-mode))
    (setq buffer-file-name nil))
  (with-temp-buffer
    (setq buffer-file-name (expand-file-name "big.txt" temporary-file-directory))
    (setq-local drgnx-large-file 'lean)
    (drgnx-hunks--maybe)
    (should-not drgnx-hunks-mode)
    (setq buffer-file-name nil)))

(ert-deftest drgnx-hunks/turning-it-off-takes-the-marks-and-hooks-away ()
  (mod-hunks-test--with-buffer "a\nb\n"
    (mod-hunks-test--answer '(:old_start 1 :old_count 1 :new_start 1 :new_count 1 :old_lines ("x\n")))
    (should (memq #'drgnx-hunks--changed-on-disk after-save-hook))
    (drgnx-hunks-mode -1)
    (should-not drgnx-hunks--overlays)
    (should-not (memq #'drgnx-hunks--changed-on-disk after-save-hook))))

;; no package: the module runs by itself, with its three commands
(ert-deftest drgnx-hunks/the-module-needs-no-package-and-has-its-commands ()
  (let ((cfg (make-temp-file "drgnx-cfg" t)))
    (unwind-protect
        (let* ((process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
               (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
               (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
          (load (expand-file-name "modules/extra/drgnx-hunks" drgnx-dir) nil t)
          (unwind-protect
              (progn
                (drgnx-modules-run 'idle)
                (should (eq (plist-get (alist-get 'extra/hunks (drgnx-modules-report)) :status) 'ok))
                (dolist (c '(git-hunk-show git-hunk-revert git-hunk-stage)) (should (drgnx-commands-get c)))
                (should (memq #'drgnx-hunks--drained drgnx-history-drained-functions)))
            (drgnx-hunks--teardown)
            (remove-hook 'find-file-hook #'drgnx-hunks--maybe)
            (remove-hook 'drgnx-history-drained-functions #'drgnx-hunks--drained)))
      (delete-directory cfg t))))

(provide 'mod-hunks-test)
;;; mod-hunks-test.el ends here
