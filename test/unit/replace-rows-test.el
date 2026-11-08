;;; replace-rows-test.el --- batch tests: the Search view's results arrive as the hub's rows -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call') for the hub-fed view; those tests are skipped elsewhere.  No hub:
;; the hub's calls are recorded and its patches and events are handed in by hand (the real stream is the row
;; `search/grep-streams-rows').  Each test names its pattern (D: pure; A: every order, unsaved-buffer rescan).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(require 'drgnx-view-env)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)

(defvar drgnx-replace-view)
(defvar drgnx-hub--events)
(defvar drgnx-replace-rows-test--n 0 "Each run's view gets a name of its own in Sjá.")
(defvar drgnx-replace-rows-test--calls nil "The hub calls the Search view made, newest first: (METHOD . PARAMS).")

(defun drgnx-replace-rows-test--row (id text)
  (list :key id :text text :props (list (list 0 (length text) "drgnx-work-id" id))))

(defun drgnx-replace-rows-test--patch (view base version ops)
  (list :view view :class "unshown" :hub 7 :base base :version version :env_epoch 1 :ops ops))

(defun drgnx-replace-rows-test--define-type ()
  "The Search view's old rows' view type, as its section defines it (undone with the macro's `drgnx-view--types')."
  (drgnx-view-define 'replace-results :render #'drgnx-replace--render-row :delay 0 :slice drgnx-view-slice :key-test 'eq))

(defmacro drgnx-replace-rows-test--with (&rest body)
  "BODY in the Search view's buffer (`buf', view `view') with a hub that is up: its calls are recorded, nothing is sent."
  (declare (indent 0))
  `(progn
     (skip-unless (fboundp 'nidhogg-view--call))
     (should-not (get-buffer drgnx-replace-buffer-name))
     (let* ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
            (drgnx-view-model--views (make-hash-table :test #'equal))
            (drgnx-view-patch--hooked nil)
            (drgnx-view-old-path nil)
            (drgnx-view-patch-send-function #'ignore)
            (drgnx-view-env-send-function #'ignore)
            (drgnx-hub--events nil)
            (drgnx-replace-rows-test--calls nil)
            (drgnx-replace-view (format "rr-test-%d" (cl-incf drgnx-replace-rows-test--n)))
            (view drgnx-replace-view)
            (drgnx-view--types drgnx-view--types))
       (drgnx-replace-rows-test--define-type)
       (cl-letf (((symbol-function 'drgnx-replace--hub-ready-p) (lambda () t))
                 ((symbol-function 'drgnx-hub--call-on)
                  (lambda (_conn method params &optional _cb &rest _) (push (cons method params) drgnx-replace-rows-test--calls) nil)))
         (let ((buf (drgnx-replace--view-buffer)))
           (unwind-protect
               (with-current-buffer buf
                 (setq drgnx-replace--root "/r/" drgnx-replace--origin (point-marker))
                 ,@body)
             (drgnx-view-patch-teardown)
             (drgnx-timer-cancel (cons 'drgnx-view buf))
             (drgnx-timer-cancel (cons 'drgnx-view-model view))
             (remove-hook 'drgnx-hub-event-functions #'drgnx-replace--hub-event)
             (let ((kill-buffer-query-functions nil)) (kill-buffer buf))))))))

(ert-deftest drgnx-replace-rows/inserts-streamed-rows ()
  "Pattern D: a text search is a `search/grep' call naming the view; the hub's reset and its per-file inserts are
drawn through `drgnx-view-apply-patch' below the fields, `search-grep-done' ends the search and counts it."
  (drgnx-replace-rows-test--with
    (drgnx-replace--fill 'find "needle")
    (drgnx-replace--fill 'replace "pin")
    (drgnx-replace--search-now)
    (should drgnx-view-patch)
    (let ((call (car drgnx-replace-rows-test--calls)))
      (should (equal "search/grep" (car call)))
      (should (equal view (plist-get (cdr call) :view)))
      (should (equal "/r/" (plist-get (cdr call) :root)))
      (should (equal "needle" (plist-get (cdr call) :text)))
      (should (equal "pin" (plist-get (cdr call) :replace)))
      (should (eq :false (plist-get (cdr call) :regexp))))
    (should drgnx-replace--searching)
    (drgnx-view-apply-patch (drgnx-replace-rows-test--patch view 0 1 (list (list :reset nil))))
    (drgnx-view-apply-patch
     (drgnx-replace-rows-test--patch
      view 1 2 (list (list :insert (list :after nil
                                         :rows (list (drgnx-replace-rows-test--row "f:/r/a.txt" "[x] a.txt")
                                                     (drgnx-replace-rows-test--row "m:/r/a.txt:1:4" "  [x] one needle")))))))
    (drgnx-view-draw-now drgnx-view)
    (let ((text (buffer-substring-no-properties drgnx-replace--results (point-max))))
      (should (equal "[x] a.txt\n  [x] one needle\n" text)))
    (drgnx-replace--hub-event "search-grep-done" (list :view view :query 1 :files 1 :matches 1))
    (should-not drgnx-replace--searching)
    (should (string-match-p "1 result in 1 file" (buffer-substring-no-properties
                                                  drgnx-replace--status-beg drgnx-replace--status-end)))))

(ert-deftest drgnx-replace-rows/late-rows-of-an-old-query-are-dropped ()
  "Pattern D: a new query's reset empties the rows; a row patch of the query before, still on its way (its base is
the old version), is dropped by the editor and never drawn."
  (drgnx-replace-rows-test--with
    (drgnx-replace--fill 'find "needle")
    (drgnx-replace--search-now)
    (drgnx-view-apply-patch (drgnx-replace-rows-test--patch view 0 1 (list (list :reset nil))))
    (drgnx-view-apply-patch
     (drgnx-replace-rows-test--patch
      view 1 2 (list (list :insert (list :after nil :rows (list (drgnx-replace-rows-test--row "f:/r/old.txt" "[x] old.txt")))))))
    (drgnx-replace--fill 'find "other")
    (drgnx-replace--search-now)
    (should (equal "other" (plist-get (cdr (car drgnx-replace-rows-test--calls)) :text)))
    (drgnx-view-apply-patch (drgnx-replace-rows-test--patch view 2 3 (list (list :reset nil))))
    ;; the old query's next file, built before the hub stopped it: base 2, the version the new reset has passed
    (drgnx-view-apply-patch
     (drgnx-replace-rows-test--patch
      view 2 3 (list (list :insert (list :after nil :rows (list (drgnx-replace-rows-test--row "f:/r/late.txt" "[x] late.txt")))))))
    (drgnx-view-apply-patch
     (drgnx-replace-rows-test--patch
      view 3 4 (list (list :insert (list :after nil :rows (list (drgnx-replace-rows-test--row "f:/r/new.txt" "[x] new.txt")))))))
    (drgnx-view-draw-now drgnx-view)
    (should (equal "[x] new.txt\n" (buffer-substring-no-properties drgnx-replace--results (point-max))))))

(ert-deftest drgnx-replace-rows/unsaved-buffer-rescan-still-marks ()
  "Pattern A: the Lisp rescan reads a visited file from its buffer, unsaved edits too, through `--grep-line' and
`--match': the matches the hub's disk search cannot see."
  (let* ((dir (make-temp-file "replace-rows" t)) (file (expand-file-name "a.txt" dir)) buf)
    (unwind-protect
        (progn
          (write-region "nothing here\n" nil file nil 'silent)
          (setq buf (find-file-noselect file))
          (with-current-buffer buf (goto-char (point-max)) (insert "a needle appears\n"))
          (with-temp-buffer
            (drgnx-replace-mode)
            (setq drgnx-replace--root (file-name-as-directory dir)
                  drgnx-replace--widgets nil drgnx-replace--opts (list :case nil :word nil :regexp nil))
            (cl-letf (((symbol-function 'drgnx-replace--text) (lambda (name) (if (eq name 'find) "needle" ""))))
              (let ((ms (drgnx-replace--scan file)))
                (should (= 1 (length ms)))
                (should (equal '(:line 2 :col 2 :end 8 :text "needle")
                               (list :line (plist-get (car ms) :line) :col (plist-get (car ms) :col)
                                     :end (plist-get (car ms) :end) :text (plist-get (car ms) :text))))))))
      (when buf (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf))
      (delete-directory dir t))))

(ert-deftest drgnx-replace-rows/unsaved-buffer-rescan-still-marks-on-the-hub-path ()
  "Pattern A: on the hub path a modified buffer's matches are the Lisp rescan's, not the disk's.  a.txt: the buffer
has a match the file lacks, and the hub found none; b.txt: the hub found a match on disk that the buffer no longer
has.  After `search-grep-done' the view shows a.txt's match and no row of b.txt, the status counts what is shown, and
Replace All writes the buffer's match."
  (drgnx-replace-rows-test--with
    (let* ((dir (file-name-as-directory (make-temp-file "replace-rows-hub" t)))
           (a (expand-file-name "a.txt" dir)) (b (expand-file-name "b.txt" dir)) (c (expand-file-name "c.txt" dir))
           bufs)
      (unwind-protect
          (progn
            (write-region "nothing here\n" nil a nil 'silent)
            (write-region "old needle\n" nil b nil 'silent)
            (write-region "disk needle\n" nil c nil 'silent)
            (let ((ba (find-file-noselect a)) (bb (find-file-noselect b)))
              (setq bufs (list ba bb))
              (with-current-buffer ba (goto-char (point-max)) (insert "a needle appears\n"))
              (with-current-buffer bb (erase-buffer) (insert "no match now\n")))
            (setq drgnx-replace--root dir)
            (drgnx-replace--fill 'find "needle")
            (drgnx-replace--search-now)
            (drgnx-view-apply-patch (drgnx-replace-rows-test--patch view 0 1 (list (list :reset nil))))
            (drgnx-view-apply-patch
             (drgnx-replace-rows-test--patch
              view 1 2 (list (list :insert (list :after nil
                                                 :rows (list (drgnx-replace-rows-test--row (concat "f:" b) "[x] b.txt")
                                                             (drgnx-replace-rows-test--row (concat "m:" b ":1:4") "  [x] old needle")
                                                             (drgnx-replace-rows-test--row (concat "f:" c) "[x] c.txt")
                                                             (drgnx-replace-rows-test--row (concat "m:" c ":1:5") "  [x] disk needle")))))))
            (drgnx-replace--hub-event "search-grep-done" (list :view view :query 1 :files 2 :matches 2))
            (drgnx-view-draw-now drgnx-view)
            (let ((text (buffer-substring-no-properties drgnx-replace--results (point-max))))
              (should (string-match-p "a\\.txt" text))
              (should (string-match-p "a needle appears" text))
              (should-not (string-match-p "b\\.txt" text))
              (should (string-match-p "c\\.txt" text)))
            (should (string-match-p "2 results in 2 files" (buffer-substring-no-properties
                                                            drgnx-replace--status-beg drgnx-replace--status-end)))
            (let ((ms (drgnx-replace--rows-ticked nil)))
              ;; no model here: the hub's c.txt is not in it
              (should (equal (list a) (mapcar (lambda (m) (plist-get m :file)) ms)))))
        (dolist (x bufs) (with-current-buffer x (set-buffer-modified-p nil)) (kill-buffer x))
        (delete-directory dir t)))))

(ert-deftest drgnx-replace-rows/old-path-switch-still-searches ()
  "Pattern D: with `drgnx-view-old-path' the view is not hub-fed and a search runs the engine in Emacs, no hub call."
  (let ((drgnx-view-old-path t) (asked nil) (calls nil) (drgnx-replace-view "rr-old") (drgnx-view--types drgnx-view--types))
    (drgnx-replace-rows-test--define-type)
    (should-not (get-buffer drgnx-replace-buffer-name))
    (cl-letf (((symbol-function 'drgnx-hub--call-on) (lambda (&rest a) (push a calls) nil))
              ((symbol-function 'drgnx-replace-search) (lambda (q _cb) (push q asked) nil)))
      (let ((buf (drgnx-replace--view-buffer)))
        (unwind-protect
            (with-current-buffer buf
              (setq drgnx-replace--root "/r/" drgnx-replace--origin (point-marker))
              (drgnx-replace--fill 'find "needle")
              (drgnx-replace--search-now)
              (should-not drgnx-view-patch)
              (should-not calls)
              (should (equal "needle" (plist-get (car asked) :text))))
          (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))))

;;; replace-rows-test.el ends here
