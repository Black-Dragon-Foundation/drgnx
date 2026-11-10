;;; replace-rows-nav-test.el --- batch tests: the Search view's keys, ticks and Replace All on the rows path answer from Sjá -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere.  No hub, no search: the Search view's buffer is
;; attached as a hub-fed view, given a model shaped like the hub's (view/grep.rs: a `tree' of files and matches) and
;; its rows, and every key is a call in it.  Each test names its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-view)
(require 'drgnx-view-nav)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)

(defvar drgnx-replace-rows-nav-test--n 0 "Each run's view gets a name of its own in Sjá.")

(defun drgnx-replace-rows-nav-test--model ()
  "The hub's model of a search: a.txt (matches on lines 1 and 2), then b.txt (one match on line 5)."
  (let ((file (lambda (f name) (list :id (concat "f:" (substring f 3)) :kind "file" :flags 1
                                     :fields (vector (vector "label" name) (vector "path" f)))))
        (hit (lambda (f line) (list :id (format "m:%s:%d:4" (substring f 3) line) :kind "match" :flags 0
                                    :parent (concat "f:" (substring f 3))
                                    :fields (vector (vector "label" "let needle;") (vector "line" line)
                                                    (vector "col" 4) (vector "end" 10) (vector "text" "needle"))))))
    (json-serialize
     (list :ops
           (vector
            (list :reset
                  (list :descriptor (list :scheme "tree" :chain_kinds [] :match_fields ["label"] :lists ["order"]
                                          :classes ["selected" "match" "dim"] :flags ["expanded"] :forms []
                                          :start "order")
                        :nodes (vector (funcall file "/r/a.txt" "a.txt") (funcall hit "/r/a.txt" 1)
                                       (funcall hit "/r/a.txt" 2) (funcall file "/r/b.txt" "b.txt")
                                       (funcall hit "/r/b.txt" 5))
                        :edges []
                        :lists (vector (list :name "order"
                                             :ids ["f:a.txt" "m:a.txt:1:4" "m:a.txt:2:4" "f:b.txt"
                                                   "m:b.txt:5:4"])))))))))

(defun drgnx-replace-rows-nav-test--row (id text box)
  "The hub's row ID: TEXT, its tick box at BOX, the node id over the whole row."
  (list :key id :text text
        :props (list (list box (+ box 3) "drgnx-replace-box" id) (list 0 (length text) "drgnx-work-id" id))))

(defun drgnx-replace-rows-nav-test--rows ()
  (list (drgnx-replace-rows-nav-test--row "f:a.txt" "[x] a.txt" 0)
        (drgnx-replace-rows-nav-test--row "m:a.txt:1:4" "  [x] let needle;" 2)
        (drgnx-replace-rows-nav-test--row "m:a.txt:2:4" "  [x] let needle;" 2)
        (drgnx-replace-rows-nav-test--row "f:b.txt" "[x] b.txt" 0)
        (drgnx-replace-rows-nav-test--row "m:b.txt:5:4" "  [x] let needle;" 2)))

(defmacro drgnx-replace-rows-nav-test--with (&rest body)
  "BODY in the Search view's buffer on the rows path holding the model and rows above, nothing selected, nothing sent."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
     (should-not (get-buffer drgnx-replace-buffer-name))
     (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil)
           (drgnx-view-old-path nil)
           (drgnx-view-patch-send-function #'ignore)
           (view (format "rrn-test-%d" (cl-incf drgnx-replace-rows-nav-test--n)))
           (buf (get-buffer-create drgnx-replace-buffer-name)))
       (with-current-buffer buf
         (drgnx-replace-mode)
         (setq drgnx-replace--root "/r/")      ; the hub's ids name files relative to it
         ;; the view's tables, as `drgnx-replace--render-view' makes them
         (setq drgnx-replace--off (make-hash-table :test #'eq))
         (dolist (v '(drgnx-replace--seen drgnx-replace--listed drgnx-replace--off-files drgnx-replace--headers
                                          drgnx-replace--last-row))
           (set v (make-hash-table :test #'equal)))
         (drgnx-view-patch-attach view "c" :epoch 1)
         (drgnx-replace-rows-attached)
         (unwind-protect
             (progn
               (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t
                                             :model (drgnx-replace-rows-nav-test--model)))
               (drgnx-view-apply-patch (list :view view :class "c" :hub 7 :base 0 :version 1 :env_epoch 1 :model 1
                                             :ops (list (list :reset (drgnx-replace-rows-nav-test--rows)))))
               (drgnx-view-draw-now drgnx-view)
               ,@body)
           (drgnx-view-patch-teardown)
           (drgnx-timer-cancel (cons 'drgnx-view buf))
           (drgnx-timer-cancel (cons 'drgnx-view-nav-notice buf))
           (drgnx-timer-cancel (cons 'drgnx-view-model view))
           (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))))

(defun drgnx-replace-rows-nav-test--boxes ()
  "Each row's tick box as shown: the overlay's `display' over the drawn text."
  (save-excursion
    (goto-char (point-min))
    (let (boxes)
      (while (not (eobp))
        (when-let* ((pos (text-property-not-all (point) (line-end-position) 'drgnx-replace-box nil)))
          (push (or (cl-some (lambda (o) (overlay-get o 'display)) (overlays-at pos))
                    (buffer-substring-no-properties pos (+ pos 3)))
                boxes))
        (forward-line 1))
      (nreverse boxes))))

(ert-deftest drgnx-replace-rows/next-match-walks-the-tree ()
  "Pattern D: Next Match goes from match to match over the file rows, wrapping at the end, Previous back; each is
shown in the editor from the model's fields."
  (drgnx-replace-rows-nav-test--with
    (let ((shown nil))
      (cl-letf (((symbol-function 'drgnx-replace--show-match) (lambda (m _select) (push m shown))))
        (drgnx-replace-next)
        (should (equal "m:a.txt:1:4" (drgnx-view-nav-selection)))
        (drgnx-replace-next)
        (drgnx-replace-next)
        (should (equal "m:b.txt:5:4" (drgnx-view-nav-selection)))
        (drgnx-replace-next)
        (should (equal "m:a.txt:1:4" (drgnx-view-nav-selection)))
        (drgnx-replace-prev)
        (should (equal "m:b.txt:5:4" (drgnx-view-nav-selection))))
      (should (equal '(:file "/r/b.txt" :line 5 :col 4 :end 10 :text "needle") (car shown)))
      (should (= 5 (length shown))))))

(ert-deftest drgnx-replace-rows/ticks-are-user-state ()
  "Pattern D: a match's box unticks in Sjá and shows [ ], its file's [-]; the file's box then unticks all of its
matches, and again ticks them all; a hub patch that redraws a row keeps its box as the ticks say."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace--rows-tick "m:a.txt:2:4")
    (should (equal ["m:a.txt:2:4"] (vconcat (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked))))
    (should (equal '("[-]" "[x]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    (drgnx-replace--rows-tick "f:a.txt")
    (should (equal '("[ ]" "[ ]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    ;; the hub redraws a row (a new replace preview): the box goes back on
    (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                  :env_epoch 1 :model 1
                                  :ops (list (list :replace (list (drgnx-replace-rows-nav-test--row
                                                                   "m:a.txt:1:4" "  [x] let needlepin;" 2))))))
    (drgnx-view-draw-now drgnx-view)
    (should (equal '("[ ]" "[ ]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    (drgnx-replace--rows-tick "f:a.txt")
    (should (equal '("[x]" "[x]" "[x]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))))

(defun drgnx-replace-rows-nav-test--box-at (id)
  "Where row ID's tick box starts."
  (let ((p (point-min)) found)
    (while (and (not found) (setq p (text-property-not-all p (point-max) 'drgnx-replace-box nil)))
      (if (equal (get-text-property p 'drgnx-work-id) id)
          (setq found p)
        (setq p (or (next-single-property-change p 'drgnx-replace-box) (point-max)))))
    found))

(ert-deftest drgnx-replace-rows/ret-and-a-click-on-a-box-tick-it ()
  "Pattern D: a hub row's tick box is a button (SJA-SEARCH-1 (1)): RET on a match's box unticks it in Sjá, a click on
its file's box (a link: mouse-1 follows it) unticks the file's other match, and a box a hub patch redraws is one again."
  (drgnx-replace-rows-nav-test--with
    (goto-char (drgnx-replace-rows-nav-test--box-at "m:a.txt:2:4"))
    (call-interactively (key-binding (kbd "RET")))
    (should (equal '("[-]" "[x]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    (let ((file (drgnx-replace-rows-nav-test--box-at "f:a.txt")))
      (should (mouse-on-link-p file))
      (push-button file))
    (should (equal '("[ ]" "[ ]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                  :env_epoch 1 :model 1
                                  :ops (list (list :replace (list (drgnx-replace-rows-nav-test--row
                                                                   "m:b.txt:5:4" "  [x] let needlepin;" 2))))))
    (drgnx-view-draw-now drgnx-view)
    (goto-char (drgnx-replace-rows-nav-test--box-at "m:b.txt:5:4"))
    (call-interactively (key-binding (kbd "RET")))
    (should (equal '("[ ]" "[ ]" "[ ]" "[ ]" "[ ]") (drgnx-replace-rows-nav-test--boxes)))))

(ert-deftest drgnx-replace-rows/a-new-search-ticks-every-match-again ()
  "Pattern D: a new search empties Sjá's ticked set, as the old path empties its unticked matches (SJA-SEARCH-1 (2)):
else a match of the new search with the same file, line and column as an unticked one would start unticked."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace--rows-tick "m:a.txt:2:4")
    (drgnx-replace--rows-tick "m:b.txt:5:4")
    (let ((searched 0))
      (cl-letf (((symbol-function 'drgnx-replace--hub-ready-p) #'always)
                ((symbol-function 'drgnx-replace--hub-search) (lambda (&rest _) (cl-incf searched)))
                ((symbol-function 'drgnx-replace--ensure-origin) #'ignore)
                ((symbol-function 'drgnx-replace--update-status) #'ignore))   ; the fields' status line
        (drgnx-replace--search-now))
      (should (= 1 searched)))
    (should-not (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked))
    (should (equal '("[x]" "[x]" "[x]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))))

(ert-deftest drgnx-replace-rows/next-and-previous-file-walk-the-files ()
  "Pattern D: Next File selects the next file's row from a match (`down:file' in Sjá), Previous File the one before;
both have keys in every profile (SJA-SEARCH-1 (4))."
  (drgnx-replace-rows-nav-test--with
    (drgnx-view-nav 'select "m:a.txt:2:4")
    (drgnx-replace-next-file)
    (should (equal "f:b.txt" (drgnx-view-nav-selection)))
    (drgnx-replace-prev-file)
    (should (equal "f:a.txt" (drgnx-view-nav-selection)))
    (dolist (id '(replace-next-file replace-prev-file))
      (dolist (profile '("vscode" "emacs" "vim"))
        (with-temp-buffer
          (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
          (should (search-forward (format "(%s " id) nil t)))))))

(ert-deftest drgnx-replace-rows/replace-all-writes-the-ticked ()
  "Pattern D: Replace All writes the matches not unticked, read from the model's fields; the list is then what it
left (none here: `search/grep-skipped' with no match), not a new search."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace--rows-tick "m:a.txt:1:4")
    (let ((applied nil) (searched 0) (calls nil))
      (cl-letf (((symbol-function 'drgnx-replace-apply) (lambda (ms new) (push (cons new ms) applied)
                                                          (list :written (length ms) :files 2 :skipped nil :undo nil)))
                ((symbol-function 'drgnx-replace--search-now) (lambda () (cl-incf searched)))
                ((symbol-function 'drgnx-replace--hub-call) (lambda (method params) (push (cons method params) calls)))
                ((symbol-function 'drgnx-replace--message) #'ignore))
        (drgnx-replace--rows-replace-all "pin"))
      (should (= 0 searched))
      (should (equal `(("search/grep-skipped" :view ,drgnx-replace-view :skipped [])) calls))
      (should (equal "pin" (caar applied)))
      (should (equal '(("/r/a.txt" 2) ("/r/b.txt" 5))
                     (mapcar (lambda (m) (list (plist-get m :file) (plist-get m :line))) (cdar applied)))))))

(ert-deftest drgnx-replace-rows/replace-all-leaves-the-skipped-with-their-reasons ()
  "Pattern D: a match Replace All skipped stays listed with its reason (SJA-SEARCH-1 (3)): the hub is told which
\(`search/grep-skipped', by node id) and lists only those; the ticks start over."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace--rows-tick "m:a.txt:1:4")
    (let ((calls nil))
      (cl-letf (((symbol-function 'drgnx-replace-apply)
                 (lambda (ms _new)
                   (list :written (1- (length ms)) :files 1
                         :skipped (list (drgnx-replace--skip (car (last ms)) "changed since the search")) :undo nil)))
                ((symbol-function 'drgnx-replace--hub-call) (lambda (method params) (push (cons method params) calls)))
                ((symbol-function 'drgnx-replace--message) #'ignore))
        (drgnx-replace--rows-replace-all "pin"))
      (should (equal `(("search/grep-skipped" :view ,drgnx-replace-view
                        :skipped [(:id "m:b.txt:5:4" :why "changed since the search")]))
                     calls))
      (should-not (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked)))))

(defun drgnx-replace-rows-nav-test--drop-b ()
  "The hub sent a window of the rows that stops after a.txt: b.txt's rows are not in the view (its nodes are in the model)."
  (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                :env_epoch 1 :model 1 :ops (list (list :remove (list "f:b.txt" "m:b.txt:5:4")))))
  (drgnx-view-draw-now drgnx-view)
  (should-not (gethash "m:b.txt:5:4" (drgnx-view-patch-rows drgnx-view-patch))))

(ert-deftest drgnx-replace-rows/next-match-beyond-the-rows-asks-the-hub-for-its-row ()
  "Pattern D: the model holds every match, the hub sends a window of the rows: Next Match to a match whose row is not
in the view selects it from the model, shows it in the editor and asks the hub for the rows up to it (`upto'); a match
whose row is in the view asks nothing."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace-rows-nav-test--drop-b)
    (let ((asked nil) (shown nil))
      (cl-letf (((symbol-function 'drgnx-replace--look) (lambda (params) (push params asked)))
                ((symbol-function 'drgnx-replace--show-match) (lambda (m _select) (push m shown))))
        (drgnx-replace-next)
        (drgnx-replace-next)
        (should-not asked)
        (drgnx-replace-next)
        (should (equal "m:b.txt:5:4" (drgnx-view-nav-selection)))
        (should (equal '((:upto "m:b.txt:5:4")) asked))
        (should (equal '(:file "/r/b.txt" :line 5 :col 4 :end 10 :text "needle") (car shown)))
        ;; the row arrives: point goes to it
        (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 2 :version 3
                                      :env_epoch 1 :model 1
                                      :ops (list (list :insert (list :after "m:a.txt:2:4"
                                                                     :rows (list (drgnx-replace-rows-nav-test--row "f:b.txt" "[x] b.txt" 0)
                                                                                 (drgnx-replace-rows-nav-test--row "m:b.txt:5:4" "  [x] let needle;" 2)))))))
        (drgnx-view-draw-now drgnx-view)
        (should (equal "m:b.txt:5:4" (get-text-property (line-beginning-position) 'drgnx-work-id)))))))

(ert-deftest drgnx-replace-rows/replace-all-writes-the-matches-beyond-the-rows ()
  "Pattern D: Replace All reads the model, not the rows: with b.txt's rows not in the view, its match is written too."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace-rows-nav-test--drop-b)
    (let ((applied nil))
      (cl-letf (((symbol-function 'drgnx-replace-apply) (lambda (ms _new) (setq applied ms)
                                                          (list :written (length ms) :files 2 :skipped nil :undo nil)))
                ((symbol-function 'drgnx-replace--search-now) #'ignore)
                ((symbol-function 'drgnx-replace--message) #'ignore))
        (drgnx-replace--rows-replace-all "pin")
        (should (equal '("/r/a.txt" "/r/a.txt" "/r/b.txt") (mapcar (lambda (m) (plist-get m :file)) applied)))))))

(ert-deftest drgnx-replace-rows/the-end-of-the-rows-asks-for-more-once-per-growth ()
  "Pattern D: when the window shows the end of the rows the view asks the hub for one more window (`more'); it asks
again only when the rows have grown since, so a hub with no more is not asked over and over."
  (drgnx-replace-rows-nav-test--with
    (let ((asked nil) (win (selected-window)) (old (window-buffer (selected-window))))
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-replace--look) (lambda (params) (push params asked))))
            (set-window-buffer win (current-buffer))
            (drgnx-replace--look-more win)
            (drgnx-replace--look-more win)
            (should (equal '((:more t)) asked))
            (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                          :env_epoch 1 :model 1
                                          :ops (list (list :insert (list :after "m:b.txt:5:4"
                                                                         :rows (list (drgnx-replace-rows-nav-test--row
                                                                                      "m:b.txt:6:4" "  [x] let needle;" 2)))))))
            (drgnx-view-draw-now drgnx-view)
            (drgnx-replace--look-more win)
            (should (equal '((:more t) (:more t)) asked)))
        (set-window-buffer win old)))))

(ert-deftest drgnx-replace-rows/a-gap-in-sight-asks-for-the-rows-before-it ()
  "Pattern D: after a far jump the hub sends a block of rows after a gap row (SJA-ROWS-FAR-1); when the window shows
the gap row the view asks for the rows before it (`fill'), again only once the rows have changed."
  (drgnx-replace-rows-nav-test--with
    (let ((asked nil) (win (selected-window)) (old (window-buffer (selected-window))))
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-replace--look) (lambda (params) (push params asked))))
            (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                          :env_epoch 1 :model 1
                                          :ops (list (list :insert (list :after "m:a.txt:2:4"
                                                                         :rows (list (list :key "gap" :text "  ⋯ 1200 more")))))))
            (drgnx-view-draw-now drgnx-view)
            (set-window-buffer win (current-buffer))
            (drgnx-replace--look-more win)
            (drgnx-replace--look-more win)
            (should (equal 1 (cl-count '(:fill t) asked :test #'equal)))
            (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 2 :version 3
                                          :env_epoch 1 :model 1
                                          :ops (list (list :replace (list (list :key "gap" :text "  ⋯ 1000 more"))))))
            (drgnx-view-draw-now drgnx-view)
            (drgnx-replace--look-more win)
            (should (equal 2 (cl-count '(:fill t) asked :test #'equal))))
        (set-window-buffer win old)))))

;;; replace-rows-nav-test.el ends here
