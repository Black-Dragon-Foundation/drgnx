;;; replace-rows-test.el --- batch tests: the Search view's results arrive as the hub's rows -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call') for the hub-fed view; those tests are skipped elsewhere.  No hub:
;; the hub's calls are recorded and its patches and events are handed in by hand (the real stream is the row
;; `search/run-streams-rows').  Each test names its pattern (D: pure; A: every order, unsaved-buffer rescan).
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

(defun drgnx-replace-rows-test--row (id text &optional file)
  "The hub's row ID: TEXT, with FILE as the hub names it (a header's `drgnx-replace-file', a match's
`drgnx-replace-match' `:file') when given."
  (list :key id :text text
        :props (append (and file (list (list 0 (length text)
                                             (if (string-prefix-p "f:" id) "drgnx-replace-file" "drgnx-replace-match")
                                             (if (string-prefix-p "f:" id) file (list :file file)))))
                       (list (list 0 (length text) "drgnx-work-id" id)))))

(defun drgnx-replace-rows-test--search (params key)
  "KEY of `search/run''s PARAMS' search (`:query' for its query's)."
  (plist-get (plist-get params :search) key))

(defun drgnx-replace-rows-test--query (params key)
  "KEY of `search/run''s PARAMS' query."
  (plist-get (drgnx-replace-rows-test--search params :query) key))

(defun drgnx-replace-rows-test--patch (view base version ops)
  (list :view view :class "unshown" :hub 7 :base base :version version :env_epoch 1 :ops ops))

(defun drgnx-replace-rows-test--define-type ()
  "The Search view's old rows' view type, as its section defines it (undone with the macro's `drgnx-view--types')."
  (drgnx-view-define 'replace-results :render #'drgnx-replace--render-row :delay 0 :slice drgnx-view-slice :key-test 'eq))

(defmacro drgnx-replace-rows-test--with (&rest body)
  "BODY in the Search view's buffer (`buf', view `view') with a hub that is up: its calls are recorded, nothing is sent."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
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
  "Pattern D: a text search is a `search/run' call naming the view; the hub's reset and its per-file inserts are
drawn through `drgnx-view-apply-patch' below the fields, `search-run-done' ends the search and counts it."
  (drgnx-replace-rows-test--with
    (drgnx-replace--fill 'find "needle")
    (drgnx-replace--fill 'replace "pin")
    (drgnx-replace--search-now)
    (should drgnx-view-patch)
    (let ((call (car drgnx-replace-rows-test--calls)))
      (should (equal "search/run" (car call)))
      (should (equal view (plist-get (cdr call) :view)))
      (should (equal "/r/" (plist-get (cdr call) :root)))
      (should (equal "text" (drgnx-replace-rows-test--query (cdr call) :mode)))
      (should (equal "needle" (drgnx-replace-rows-test--query (cdr call) :text)))
      (should (equal "pin" (drgnx-replace-rows-test--search (cdr call) :replace)))
      (should (eq :false (drgnx-replace-rows-test--query (cdr call) :regexp)))
      (should (equal '(:kind "project") (drgnx-replace-rows-test--search (cdr call) :scope)))
      (should-not (plist-member (cdr call) :off)))
    (should drgnx-replace--searching)
    (drgnx-view-apply-patch (drgnx-replace-rows-test--patch view 0 1 (list (list :reset nil))))
    (drgnx-view-apply-patch
     (drgnx-replace-rows-test--patch
      view 1 2 (list (list :insert (list :after nil
                                         :rows (list (drgnx-replace-rows-test--row "f:a.txt" "[x] a.txt")
                                                     (drgnx-replace-rows-test--row "m:1:0" "  [x] one needle")))))))
    (drgnx-view-draw-now drgnx-view)
    (let ((text (buffer-substring-no-properties drgnx-replace--results (point-max))))
      (should (equal "[x] a.txt\n  [x] one needle\n" text)))
    (drgnx-replace--hub-event "search-run-done" (list :view view :run 1 :files 1 :matches 1))
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
      view 1 2 (list (list :insert (list :after nil :rows (list (drgnx-replace-rows-test--row "f:old.txt" "[x] old.txt")))))))
    (drgnx-replace--fill 'find "other")
    (drgnx-replace--search-now)
    (should (equal "other" (drgnx-replace-rows-test--query (cdr (car drgnx-replace-rows-test--calls)) :text)))
    (drgnx-view-apply-patch (drgnx-replace-rows-test--patch view 2 3 (list (list :reset nil))))
    ;; the old query's next file, built before the hub stopped it: base 2, the version the new reset has passed
    (drgnx-view-apply-patch
     (drgnx-replace-rows-test--patch
      view 2 3 (list (list :insert (list :after nil :rows (list (drgnx-replace-rows-test--row "f:late.txt" "[x] late.txt")))))))
    (drgnx-view-apply-patch
     (drgnx-replace-rows-test--patch
      view 3 4 (list (list :insert (list :after nil :rows (list (drgnx-replace-rows-test--row "f:new.txt" "[x] new.txt")))))))
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
has.  After `search-run-done' the view shows a.txt's match and no row of b.txt, the status counts what is shown, and
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
                                                 :rows (list (drgnx-replace-rows-test--row "f:b.txt" "[x] b.txt" b)
                                                             (drgnx-replace-rows-test--row "m:1:0" "  [x] old needle" b)
                                                             (drgnx-replace-rows-test--row "f:c.txt" "[x] c.txt" c)
                                                             (drgnx-replace-rows-test--row
                                                              "m:1:1" "  [x] disk needle" c)))))))
            (drgnx-replace--hub-event "search-run-done" (list :view view :run 1 :files 2 :matches 2))
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

(ert-deftest drgnx-replace-rows/next-match-walks-the-unsaved-buffer-rows ()
  "Pattern A: Next Match and Previous Match go through the rows Emacs scanned in a modified buffer (they are not in the
hub's model), wrapping, and show each match from the buffer's scan."
  (drgnx-replace-rows-test--with
    (let* ((dir (file-name-as-directory (make-temp-file "replace-rows-next" t)))
           (a (expand-file-name "a.txt" dir)) buf (shown nil))
      (unwind-protect
          (progn
            (write-region "nothing here\n" nil a nil 'silent)
            (setq buf (find-file-noselect a))
            (with-current-buffer buf (goto-char (point-max)) (insert "one needle\ntwo needle\n"))
            (setq drgnx-replace--root dir)
            (drgnx-replace--fill 'find "needle")
            (drgnx-replace--search-now)
            (drgnx-view-apply-patch (drgnx-replace-rows-test--patch view 0 1 (list (list :reset nil))))
            (drgnx-replace--hub-event "search-run-done" (list :view view :run 1 :files 0 :matches 0))
            (cl-letf (((symbol-function 'drgnx-replace--show-match) (lambda (m _select) (push (plist-get m :line) shown))))
              (drgnx-replace-next)
              (drgnx-replace-next)
              (drgnx-replace-next)
              (drgnx-replace-prev))
            (should (equal '(3 2 3 2) shown)))
        (when buf (with-current-buffer buf (set-buffer-modified-p nil)) (kill-buffer buf))
        (delete-directory dir t)))))

(ert-deftest drgnx-replace-rows/a-search-before-the-hub-waits-for-it ()
  "Pattern D: with the hub not up a text search makes no call and says it waits; when the hub comes
\(`drgnx-hub-connected-functions') the search goes as `search/run'.  There is no Lisp engine."
  (drgnx-replace-rows-test--with
    (let ((up nil))
      (cl-letf (((symbol-function 'drgnx-replace--hub-ready-p) (lambda () up)))
        (drgnx-replace--fill 'find "needle")
        (drgnx-replace--search-now)
        (should-not drgnx-replace-rows-test--calls)
        (should drgnx-replace--waiting)
        (should-not drgnx-replace--searching)
        (should (string-match-p "Waiting for the hub" (buffer-substring-no-properties
                                                       drgnx-replace--status-beg drgnx-replace--status-end)))
        (setq up t)
        (drgnx-replace--hub-up)
        (should-not drgnx-replace--waiting)
        (should (equal "search/run" (car (car drgnx-replace-rows-test--calls))))
        (should (equal "needle" (drgnx-replace-rows-test--query (cdr (car drgnx-replace-rows-test--calls)) :text)))
        ;; a later connect searches nothing again (nothing waits)
        (setq drgnx-replace-rows-test--calls nil)
        (drgnx-replace--hub-up)
        (should-not drgnx-replace-rows-test--calls)))))

(ert-deftest drgnx-replace-rows/the-fields-make-the-search ()
  "Pattern D: the fields and toggles are the `search/run' call's search: globs as arrays (a comma-separated field
split), the toggles as booleans, and This file is the File scope naming the file the view was opened from."
  (drgnx-replace-rows-test--with
    (let* ((call (lambda () (cdr (car drgnx-replace-rows-test--calls))))
           (search (lambda (key) (drgnx-replace-rows-test--search (funcall call) key)))
           (query (lambda (key) (drgnx-replace-rows-test--query (funcall call) key))))
      (drgnx-replace--fill 'find "need(le)?")
      (drgnx-replace--fill 'include "src/**, test/**")
      (drgnx-replace--fill 'exclude "*.md")
      (drgnx-replace--toggle :case)
      (drgnx-replace--toggle :regexp)
      (drgnx-replace--search-now)
      (should (equal ["src/**" "test/**"] (funcall search :include)))
      (should (equal ["*.md"] (funcall search :exclude)))
      (should (eq t (funcall query :case)))
      (should (eq t (funcall query :regexp)))
      (should (eq :false (funcall query :word)))
      (should (equal '(:kind "project") (funcall search :scope)))
      (let ((file (make-temp-file "replace-rows-scope" nil ".txt")) buf)
        (unwind-protect
            (progn
              (setq buf (find-file-noselect file))
              (setq drgnx-replace--origin (with-current-buffer buf (point-min-marker)))
              (drgnx-replace--set-scope 'file)
              (drgnx-replace--search-now)
              (should (equal (list :kind "file" :files (vector file)) (funcall search :scope))))
          (when buf (kill-buffer buf))
          (delete-file file))))))

(ert-deftest drgnx-replace-rows/a-listed-file-changed-on-disk-searches-again ()
  "Pattern D: a change on disk to a file the search listed (a file-notify event, handed in) searches again through
the hub after the pause; a file it did not list changes nothing."
  (drgnx-replace-rows-test--with
    (drgnx-replace--fill 'find "needle")
    (drgnx-replace--search-now)
    (drgnx-view-apply-patch (drgnx-replace-rows-test--patch view 0 1 (list (list :reset nil))))
    (cl-letf (((symbol-function 'drgnx-replace--watch) #'ignore))   ; no folder is watched here: the events come by hand
      (drgnx-replace--hub-event "search-run-done" (list :view view :run 1 :files 1 :matches 1)))
    (setq drgnx-replace-rows-test--calls nil)
    (puthash "/r/a.txt" t drgnx-replace--listed)
    (drgnx-replace--file-event (current-buffer) (list 1 'changed "/r/other.txt"))
    (should-not (drgnx-timer-active-p (cons 'replace-refresh (current-buffer))))
    (drgnx-replace--file-event (current-buffer) (list 1 'changed "/r/a.txt"))
    (should (drgnx-timer-active-p (cons 'replace-refresh (current-buffer))))
    (drgnx-replace--refresh (current-buffer))
    (should (equal "search/run" (car (car drgnx-replace-rows-test--calls))))))

(defun drgnx-replace-rows-test--model (run lines)
  "The hub's model line of run RUN over a.txt, one match per line of LINES (ids `m:RUN:N'), as a reset."
  (let ((hits (cl-loop for line in lines for n from 0
                       collect (list :id (format "m:%d:%d" run n) :kind "match" :flags 0 :parent "f:a.txt"
                                     :fields (vector (vector "label" "a needle") (vector "line" line)
                                                     (vector "col" 2) (vector "end" 8) (vector "text" "needle"))))))
    (json-serialize
     (list :ops
           (vector
            (list :reset
                  (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"] :lists ["order"]
                                          :classes ["selected" "match" "dim"] :flags ["expanded"] :forms []
                                          :start "order")
                        :nodes (vconcat (list (list :id "f:a.txt" :kind "file" :flags 1
                                                    :fields (vector (vector "label" "a.txt")
                                                                    (vector "path" "/r/a.txt"))))
                                        hits)
                        :edges []
                        :lists (vector (list :name "order"
                                             :ids (vconcat (list "f:a.txt")
                                                           (mapcar (lambda (h) (plist-get h :id)) hits)))))))))))

(ert-deftest drgnx-replace-rows/an-untick-survives-a-new-search ()
  "Pattern D: the matches the user unticked go with the next search (`search/run''s `off', by the old run's ids); the
ticks start over, and when the hub's `search-run-done' names the same matches of the new run (`off', new ids) they are
unticked again; a search with nothing unticked sends no `off'."
  (drgnx-replace-rows-test--with
    (drgnx-replace--fill 'find "needle")
    (drgnx-replace--search-now)
    (should-not (plist-member (cdr (car drgnx-replace-rows-test--calls)) :off))
    (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t
                                  :model (drgnx-replace-rows-test--model 1 '(1 2))))
    (let ((h (drgnx-view-patch-handle drgnx-view-patch)))
      (drgnx-replace--rows-tick "m:1:1")
      (should (equal '("m:1:1") (nidhogg-view-get h 'ticked)))
      ;; the same search again (a file changed on disk): two lines were added above the matches
      (drgnx-replace--search-now)
      (should (equal ["m:1:1"] (plist-get (cdr (car drgnx-replace-rows-test--calls)) :off)))
      (should-not (nidhogg-view-get h 'ticked))
      (drgnx-view-model-event (list :view view :hub 7 :base 1 :version 2 :reset t
                                    :model (drgnx-replace-rows-test--model 2 '(3 4))))
      (drgnx-replace--hub-event "search-run-done" (list :view view :run 2 :files 1 :matches 2 :off '("m:2:1")))
      (should (equal '("m:2:1") (nidhogg-view-get h 'ticked)))
      (should-not drgnx-replace--carry))))

;;; replace-rows-test.el ends here
