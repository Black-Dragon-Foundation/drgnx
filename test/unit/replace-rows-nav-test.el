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
  (let ((file (lambda (f name) (list :id (concat "f:" f) :kind "file" :flags 1
                                     :fields (vector (vector "label" name) (vector "path" f)))))
        (hit (lambda (f line) (list :id (format "m:%s:%d:4" f line) :kind "match" :flags 0 :parent (concat "f:" f)
                                    :fields (vector (vector "label" "let needle;") (vector "file" f)
                                                    (vector "line" line) (vector "col" 4) (vector "end" 10)
                                                    (vector "text" "needle"))))))
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
                                             :ids ["f:/r/a.txt" "m:/r/a.txt:1:4" "m:/r/a.txt:2:4" "f:/r/b.txt"
                                                   "m:/r/b.txt:5:4"])))))))))

(defun drgnx-replace-rows-nav-test--row (id text box)
  "The hub's row ID: TEXT, its tick box at BOX, the node id over the whole row."
  (list :key id :text text
        :props (list (list box (+ box 3) "drgnx-replace-box" id) (list 0 (length text) "drgnx-work-id" id))))

(defun drgnx-replace-rows-nav-test--rows ()
  (list (drgnx-replace-rows-nav-test--row "f:/r/a.txt" "[x] a.txt" 0)
        (drgnx-replace-rows-nav-test--row "m:/r/a.txt:1:4" "  [x] let needle;" 2)
        (drgnx-replace-rows-nav-test--row "m:/r/a.txt:2:4" "  [x] let needle;" 2)
        (drgnx-replace-rows-nav-test--row "f:/r/b.txt" "[x] b.txt" 0)
        (drgnx-replace-rows-nav-test--row "m:/r/b.txt:5:4" "  [x] let needle;" 2)))

(defmacro drgnx-replace-rows-nav-test--with (&rest body)
  "BODY in the Search view's buffer on the rows path holding the model and rows above, nothing selected, nothing sent."
  (declare (indent 0))
  `(progn
     (skip-unless (fboundp 'nidhogg-view--call))
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
        (should (equal "m:/r/a.txt:1:4" (drgnx-view-nav-selection)))
        (drgnx-replace-next)
        (drgnx-replace-next)
        (should (equal "m:/r/b.txt:5:4" (drgnx-view-nav-selection)))
        (drgnx-replace-next)
        (should (equal "m:/r/a.txt:1:4" (drgnx-view-nav-selection)))
        (drgnx-replace-prev)
        (should (equal "m:/r/b.txt:5:4" (drgnx-view-nav-selection))))
      (should (equal '(:file "/r/b.txt" :line 5 :col 4 :end 10 :text "needle") (car shown)))
      (should (= 5 (length shown))))))

(ert-deftest drgnx-replace-rows/ticks-are-user-state ()
  "Pattern D: a match's box unticks in Sjá and shows [ ], its file's [-]; the file's box then unticks all of its
matches, and again ticks them all; a hub patch that redraws a row keeps its box as the ticks say."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace--rows-tick "m:/r/a.txt:2:4")
    (should (equal ["m:/r/a.txt:2:4"] (vconcat (nidhogg-view-get (drgnx-view-patch-handle drgnx-view-patch) 'ticked))))
    (should (equal '("[-]" "[x]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    (drgnx-replace--rows-tick "f:/r/a.txt")
    (should (equal '("[ ]" "[ ]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    ;; the hub redraws a row (a new replace preview): the box goes back on
    (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                  :env_epoch 1 :model 1
                                  :ops (list (list :replace (list (drgnx-replace-rows-nav-test--row
                                                                   "m:/r/a.txt:1:4" "  [x] let needlepin;" 2))))))
    (drgnx-view-draw-now drgnx-view)
    (should (equal '("[ ]" "[ ]" "[ ]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))
    (drgnx-replace--rows-tick "f:/r/a.txt")
    (should (equal '("[x]" "[x]" "[x]" "[x]" "[x]") (drgnx-replace-rows-nav-test--boxes)))))

(ert-deftest drgnx-replace-rows/replace-all-writes-the-ticked ()
  "Pattern D: Replace All writes the matches not unticked, read from the model's fields, then searches again."
  (drgnx-replace-rows-nav-test--with
    (drgnx-replace--rows-tick "m:/r/a.txt:1:4")
    (let ((applied nil) (searched 0))
      (cl-letf (((symbol-function 'drgnx-replace-apply) (lambda (ms new) (push (cons new ms) applied)
                                                          (list :written (length ms) :files 2 :skipped nil :undo nil)))
                ((symbol-function 'drgnx-replace--search-now) (lambda () (cl-incf searched)))
                ((symbol-function 'drgnx-replace--message) #'ignore))
        (drgnx-replace--rows-replace-all "pin"))
      (should (= 1 searched))
      (should (equal "pin" (caar applied)))
      (should (equal '(("/r/a.txt" 2) ("/r/b.txt" 5))
                     (mapcar (lambda (m) (list (plist-get m :file) (plist-get m :line))) (cdar applied)))))))

(defun drgnx-replace-rows-nav-test--drop-b ()
  "The hub sent a window of the rows that stops after a.txt: b.txt's rows are not in the view (its nodes are in the model)."
  (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 1 :version 2
                                :env_epoch 1 :model 1 :ops (list (list :remove (list "f:/r/b.txt" "m:/r/b.txt:5:4")))))
  (drgnx-view-draw-now drgnx-view)
  (should-not (gethash "m:/r/b.txt:5:4" (drgnx-view-patch-rows drgnx-view-patch))))

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
        (should (equal "m:/r/b.txt:5:4" (drgnx-view-nav-selection)))
        (should (equal '((:upto "m:/r/b.txt:5:4")) asked))
        (should (equal '(:file "/r/b.txt" :line 5 :col 4 :end 10 :text "needle") (car shown)))
        ;; the row arrives: point goes to it
        (drgnx-view-apply-patch (list :view (drgnx-view-patch-view drgnx-view-patch) :class "c" :hub 7 :base 2 :version 3
                                      :env_epoch 1 :model 1
                                      :ops (list (list :insert (list :after "m:/r/a.txt:2:4"
                                                                     :rows (list (drgnx-replace-rows-nav-test--row "f:/r/b.txt" "[x] b.txt" 0)
                                                                                 (drgnx-replace-rows-nav-test--row "m:/r/b.txt:5:4" "  [x] let needle;" 2)))))))
        (drgnx-view-draw-now drgnx-view)
        (should (equal "m:/r/b.txt:5:4" (get-text-property (line-beginning-position) 'drgnx-work-id)))))))

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
                                          :ops (list (list :insert (list :after "m:/r/b.txt:5:4"
                                                                         :rows (list (drgnx-replace-rows-nav-test--row
                                                                                      "m:/r/b.txt:6:4" "  [x] let needle;" 2)))))))
            (drgnx-view-draw-now drgnx-view)
            (drgnx-replace--look-more win)
            (should (equal '((:more t) (:more t)) asked)))
        (set-window-buffer win old)))))

;;; replace-rows-nav-test.el ends here
