;;; replace-rows-test.el --- batch tests: the Search view's results arrive as the hub's rows -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call') for the hub-fed view; those tests are skipped elsewhere.  No hub:
;; the hub's calls are recorded and its patches and events are handed in by hand (the real stream is the row
;; `search/run-streams-rows').  Each test names its pattern (D: pure).
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

(ert-deftest drgnx-replace-rows/modified-buffers-go-to-the-hub-with-the-search ()
  "Pattern D: before a search the view sends the hub each modified buffer under the root (`search/buffer': its text
and tick; one over the size the view sends, or open as a large file, as `large' with no text), then `search/run'.  A
buffer outside the root is not sent.  The next search sends only what changed since: nothing for a buffer not edited
again, and a buffer saved since is forgotten (its path alone): the hub searches its file again."
  (drgnx-replace-rows-test--with
    (let* ((dir (file-name-as-directory (make-temp-file "replace-rows-hub" t)))
           (out (file-name-as-directory (make-temp-file "replace-rows-out" t)))
           (a (expand-file-name "a.txt" dir)) (big (expand-file-name "big.log" dir)) (o (expand-file-name "o.txt" out))
           (drgnx-replace-refresh-max-bytes 64) bufs)
      (unwind-protect
          (progn
            (dolist (f (list a big o)) (write-region "nothing\n" nil f nil 'silent))
            (setq bufs (mapcar #'find-file-noselect (list a big o)) drgnx-replace--root dir)
            (with-current-buffer (nth 0 bufs) (insert "a needle\n"))
            (with-current-buffer (nth 1 bufs) (insert (make-string 100 ?x)))
            (with-current-buffer (nth 2 bufs) (insert "needle\n"))
            (drgnx-replace--fill 'find "needle")
            (drgnx-replace--search-now)
            (should (equal (list (list a :tick (buffer-chars-modified-tick (nth 0 bufs)) :text "a needle\nnothing\n")
                                 (list big :tick (buffer-chars-modified-tick (nth 1 bufs)) :large t))
                           (sort (drgnx-replace-rows-test--buffer-calls) (lambda (x y) (string< (car x) (car y))))))
            (should (equal "search/run" (car (car drgnx-replace-rows-test--calls))))
            ;; again: a was saved meanwhile, big not edited
            (setq drgnx-replace-rows-test--calls nil)
            (with-current-buffer (nth 0 bufs) (set-buffer-modified-p nil))
            (drgnx-replace--fill 'find "needl")
            (drgnx-replace--search-now)
            (should (equal (list (list a)) (drgnx-replace-rows-test--buffer-calls))))
        (dolist (x bufs) (with-current-buffer x (set-buffer-modified-p nil)) (kill-buffer x))
        (delete-directory dir t)
        (delete-directory out t)))))

(defun drgnx-replace-rows-test--buffer-calls ()
  "The `search/buffer' calls made, oldest first: (PATH . the rest of its params but the view)."
  (mapcar (lambda (c) (let ((p (cdr c))) (cons (plist-get p :path) (cl-loop for (k v) on p by #'cddr
                                                                            unless (memq k '(:view :path))
                                                                            append (list k v)))))
          (seq-filter (lambda (c) (equal (car c) "search/buffer")) (reverse drgnx-replace-rows-test--calls))))

(ert-deftest drgnx-replace-rows/an-edit-sends-the-buffer-again-after-the-pause ()
  "Pattern D: an edit in a modified buffer under the root sends its text again once the pause after it is over (the
hub patches the search's rows of its file); before the pause nothing goes."
  (drgnx-replace-rows-test--with
    (let* ((dir (file-name-as-directory (make-temp-file "replace-rows-edit" t)))
           (a (expand-file-name "a.txt" dir)) buf)
      (unwind-protect
          (progn
            (write-region "nothing\n" nil a nil 'silent)
            (setq buf (find-file-noselect a) drgnx-replace--root dir)
            (with-current-buffer buf (insert "one needle\n"))
            (drgnx-replace--fill 'find "needle")
            (drgnx-replace--search-now)
            (setq drgnx-replace-rows-test--calls nil)
            (with-current-buffer buf (goto-char (point-max)) (insert "two needle\n") (drgnx-replace--buffer-changed))
            (should-not (drgnx-replace-rows-test--buffer-calls))
            (should (drgnx-timer-active-p (cons 'replace-buffers (current-buffer))))
            (drgnx-replace--buffers-timer (current-buffer))
            (should (equal (list (list a :tick (buffer-chars-modified-tick buf)
                                       :text "one needle\nnothing\ntwo needle\n"))
                           (drgnx-replace-rows-test--buffer-calls)))
            (should-not (member "search/run" (mapcar #'car drgnx-replace-rows-test--calls))))
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

(defun drgnx-replace-rows-test--status ()
  "The view's status line."
  (buffer-substring-no-properties drgnx-replace--status-beg drgnx-replace--status-end))

(defun drgnx-replace-rows-test--active (name)
  "Non-nil when widget NAME takes input (not greyed out)."
  (widget-apply (drgnx-replace--widget name) :active))

(ert-deftest drgnx-replace-rows/the-mode-chip-says-what-find-means ()
  "Pattern D: the mode chip at the left of Find cycles Text → Symbol → Meaning → Text (Next Mode, or a mode's own
command), each a `search/run' of its query; the empty field's hint says what to type.  Symbol and Meaning are
read-only: the replace field, the globs and the toggles they do not use are greyed out, no replacement is sent and
Replace All refuses."
  (drgnx-replace-rows-test--with
    (should (equal "Text" (string-trim (widget-value (drgnx-replace--widget 'mode)))))
    (drgnx-replace--update-status)
    (should (string-match-p "text or regex" (drgnx-replace-rows-test--status)))
    (drgnx-replace--fill 'find "needle")
    (drgnx-replace--fill 'replace "pin")
    (drgnx-replace-search-mode-next)
    (should (eq 'symbol (drgnx-replace--opt :mode)))
    (should (equal "Symbol" (string-trim (widget-value (drgnx-replace--widget 'mode)))))
    (let ((params (cdr (car drgnx-replace-rows-test--calls))))
      (should (equal '(:mode "symbol" :name "needle" :case :false) (drgnx-replace-rows-test--search params :query)))
      (should-not (plist-member (plist-get params :search) :replace)))
    (dolist (w '(replace include exclude :word :regexp)) (should-not (drgnx-replace-rows-test--active w)))
    (should (drgnx-replace-rows-test--active :case))
    (should-error (drgnx-replace-all) :type 'user-error)
    (drgnx-replace-search-mode-next)
    (should (equal '(:mode "meaning" :question "needle")
                   (drgnx-replace-rows-test--search (cdr (car drgnx-replace-rows-test--calls)) :query)))
    (should-not (drgnx-replace-rows-test--active :case))
    (drgnx-replace--fill 'find "")
    (drgnx-replace--hub-event "search-run-done" (list :view view :run 2 :files 0 :matches 0))
    (should (string-match-p "describe what the code does" (drgnx-replace-rows-test--status)))
    (drgnx-replace--fill 'find "needle")
    (drgnx-replace-search-mode-next)
    (should (eq 'text (drgnx-replace--opt :mode)))
    (should (equal "pin" (drgnx-replace-rows-test--search (cdr (car drgnx-replace-rows-test--calls)) :replace)))
    (dolist (w '(replace include exclude :case :word :regexp)) (should (drgnx-replace-rows-test--active w)))
    (drgnx-replace-search-mode-symbol)
    (should (eq 'symbol (drgnx-replace--opt :mode)))))

(ert-deftest drgnx-replace-rows/a-text-search-that-finds-nothing-offers-meaning ()
  "Pattern D: no automatic mode: a Text search that finds nothing says so with a \"Try Meaning\" link on the status
line, which searches the same words by meaning; a search that found something offers nothing."
  (drgnx-replace-rows-test--with
    (drgnx-replace--fill 'find "retry with backoff")
    (drgnx-replace--search-now)
    (drgnx-replace--hub-event "search-run-done" (list :view view :run 1 :files 0 :matches 0))
    (should (string-match-p "No results.*Try Meaning" (drgnx-replace-rows-test--status)))
    (goto-char drgnx-replace--status-beg)
    (should (search-forward "Try Meaning" drgnx-replace--status-end t))
    (push-button (match-beginning 0))
    (should (eq 'meaning (drgnx-replace--opt :mode)))
    (should (equal '(:mode "meaning" :question "retry with backoff")
                   (drgnx-replace-rows-test--search (cdr (car drgnx-replace-rows-test--calls)) :query)))
    (drgnx-replace--hub-event "search-run-done" (list :view view :run 2 :files 0 :matches 0))
    (should-not (string-match-p "Try Meaning" (drgnx-replace-rows-test--status)))))

(ert-deftest drgnx-replace-rows/context-labels-are-a-setting ()
  "Pattern D: the hub puts a dim label row (face `drgnx-replace-ctx', the dim face's) above the first match of each
definition; `drgnx-search-context' off asks it not to (`context' false), on sends nothing (the hub's default).  A
label row is drawn as the hub sends it and is no match: pressing it shows nothing."
  (should (eq 'drgnx-replace-dim (face-attribute 'drgnx-replace-ctx :inherit)))
  (drgnx-replace-rows-test--with
    (drgnx-replace--fill 'find "needle")
    (let ((drgnx-search-context t))
      (drgnx-replace--search-now)
      (should-not (plist-member (cdar drgnx-replace-rows-test--calls) :context)))
    (let ((drgnx-search-context nil))
      (drgnx-replace--search-now)
      (should (eq :false (plist-get (cdar drgnx-replace-rows-test--calls) :context))))
    (drgnx-view-apply-patch (drgnx-replace-rows-test--patch view 0 1 (list (list :reset nil))))
    (drgnx-view-apply-patch
     (drgnx-replace-rows-test--patch
      view 1 2 (list (list :insert (list :after nil
                                         :rows (list (drgnx-replace-rows-test--row "f:a.rs" "[x] a.rs")
                                                     (list :key "c:2:0" :text "  ƒ outer"
                                                           :runs '((0 9 "drgnx-replace-ctx")))
                                                     (drgnx-replace-rows-test--row "m:2:0" "  [x] needle()")))))))
    (drgnx-view-draw-now drgnx-view)
    (goto-char drgnx-replace--results)
    (should (search-forward "ƒ outer" nil t))
    (should (eq 'drgnx-replace-ctx (get-text-property (match-beginning 0) 'face)))))

;;; replace-rows-test.el ends here
