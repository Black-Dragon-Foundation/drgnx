;;; view-sja-test.el --- batch tests: hub-fed rows held in Sjá, drawn from its edits (wb/drgnx-view-sja.el) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-view-sja)

(defvar view-sja-test--sent nil "What the buffer sent the hub, newest first: (METHOD . PARAMS).")
(defvar view-sja-test--n 0 "A counter for each test's own view name (Sjá's views are the process's).")
(defvar drgnx-view-unknown-faces)

(defmacro view-sja-test--with (&rest body)
  "BODY in a fresh buffer `buf' holding the rows of the pair (`view' . \"c\") in Sjá, sending captured."
  (declare (indent 0))
  `(progn
     (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-rows) "nidhogg-view-rows")
     (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil)
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (view-sja-test--sent nil)
           (drgnx-view-patch-send-function (lambda (m p) (push (cons m p) view-sja-test--sent))))
       (with-temp-buffer
         (let ((buf (current-buffer)) (view (format "sja-test-%d" (cl-incf view-sja-test--n))))
           (ignore buf)
           (drgnx-view-sja-attach view "c" :ack t :delay 0)
           (unwind-protect (progn ,@body)
             (drgnx-timer-cancel (cons 'drgnx-view-sja buf))
             (drgnx-view-patch-teardown)))))))

(defun view-sja-test--row (key text &rest more)
  "Row KEY with TEXT and MORE (`:runs', `:props', ...), as the hub writes it."
  (append (list :key key :text text) more))

(cl-defun view-sja-test--push (view ops &key (base 0) (version 1) styles model)
  "A row patch of VIEW (OPS: a list of op plists) from BASE to VERSION, on the hub's `view-model' line; returns Sjá's
decision.  MODEL: the model version the patch names (applied with it)."
  (drgnx-view-model-line
   (json-serialize
    (list :event "view-model"
          :data (list :view view
                      :rows (append (list :view view :class "c" :hub 7 :base base :version version :env_epoch 0
                                          :ops (vconcat (mapcar (lambda (op) (view-sja-test--op op)) ops)))
                                    (and styles (list :styles (vconcat styles)))
                                    (and model (list :model model))))))))

(defun view-sja-test--op (op)
  "OP with its rows as JSON arrays."
  (pcase op
    (`(:reset ,rows) (list :reset (vconcat rows)))
    (`(:replace ,rows) (list :replace (vconcat rows)))
    (`(:insert ,after ,rows) (list :insert (list :after (or after :null) :rows (vconcat rows))))
    (`(:remove ,keys) (list :remove (vconcat keys)))))

(defun view-sja-test--reset (view keys)
  (view-sja-test--push view (list (list :reset (mapcar (lambda (k) (view-sja-test--row k (format "row %s" k))) keys)))))

(defun view-sja-test--text ()
  (drgnx-view-sja-draw-now)
  (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))

(defun view-sja-test--sent (method)
  (cl-remove-if-not (lambda (s) (equal (car s) method)) view-sja-test--sent))

;;;; The rows

(ert-deftest rows-sja/region-text-equals-store ()
  ;; every op lands where the store has it, with its faces and properties, and each applied patch is acknowledged
  (view-sja-test--with
    (should (eq 'apply (view-sja-test--reset view '("a" "b" "c"))))
    (should (equal "row a\nrow b\nrow c\n" (view-sja-test--text)))
    (should (eq 'apply (view-sja-test--push
                        view (list (list :replace (list (view-sja-test--row "b" "B!" :runs [[0 1 "bold"]]
                                                                            :props [[0 2 "drgnx-work-id" "n1"]])))
                                   (list :insert "a" (list (view-sja-test--row "x" "xx")))
                                   (list :remove '("c")))
                        :base 1 :version 2)))
    (should (equal "row a\nxx\nB!\n" (view-sja-test--text)))
    (goto-char (point-min)) (search-forward "B!")
    (should (memq 'bold (ensure-list (get-text-property (- (point) 2) 'face))))
    (should (equal "n1" (get-text-property (- (point) 1) 'drgnx-work-id)))
    (should (equal '(1 2) (mapcar (lambda (s) (plist-get (cdr s) :version)) (reverse (view-sja-test--sent "view/ack")))))
    (should (= (drgnx-view-sja-row-start "b") (- (point) 2)))))

(ert-deftest rows-sja/window-start-and-point-kept ()
  ;; a window's point stays on its row as rows go in above it; one at the end follows the tail
  (view-sja-test--with
    (view-sja-test--reset view '("a" "b" "c"))
    (drgnx-view-sja-draw-now)
    (save-window-excursion
      (delete-other-windows)
      (let* ((w1 (selected-window)) (w2 (split-window w1)))
        (set-window-buffer w1 buf) (set-window-buffer w2 buf)
        (set-window-point w1 (+ (drgnx-view-sja-row-start "b") 2))
        (set-window-point w2 (point-max))
        (view-sja-test--push view (list (list :insert nil (list (view-sja-test--row "top" "a new top")))
                                        (list :insert "c" (list (view-sja-test--row "d" "row d"))))
                             :base 1 :version 2)
        (drgnx-view-sja-draw-now)
        (should (= (window-point w1) (+ (drgnx-view-sja-row-start "b") 2)))
        (should (= (window-point w2) (point-max)))))))

(ert-deftest rows-sja/the-first-rows-keep-point-at-the-top ()
  ;; an empty region has no tail to follow: the first draw leaves the window and the buffer at its first row (a map
  ;; once opened showing its bottom, as the window's point, at the empty region's end, followed the rows in)
  (view-sja-test--with
    (save-window-excursion
      (delete-other-windows)
      (set-window-buffer (selected-window) buf)
      (view-sja-test--reset view '("a" "b" "c"))
      (drgnx-view-sja-draw-now)
      (should (= (point) (point-min)))
      (should (= (window-point (selected-window)) (point-min))))))

;; Red first for the agent panel opening on its first rows (docks plan Task 8, l-dark-s2-a start 55): a view that opens
;; at its tail (`drgnx-view-sja-tail') counts its empty region as at its end, in both orders a panel meets: a window
;; showing it before the first rows, and a window that shows it after.
(ert-deftest rows-sja/a-tail-view-opens-at-its-end-when-a-window-shows-it-first ()
  (view-sja-test--with
    (setq-local drgnx-view-sja-tail t)
    (save-window-excursion
      (delete-other-windows)
      (set-window-buffer (selected-window) buf)
      (view-sja-test--reset view '("a" "b" "c"))
      (drgnx-view-sja-draw-now)
      (should (= (point) (point-max)))
      (should (= (window-point (selected-window)) (point-max)))
      ;; and it follows the rows that come after
      (view-sja-test--push view (list (list :insert "c" (list (view-sja-test--row "d" "row d")))) :base 1 :version 2)
      (drgnx-view-sja-draw-now)
      (should (= (window-point (selected-window)) (point-max))))))

(ert-deftest rows-sja/a-tail-view-opens-at-its-end-when-a-window-shows-it-after ()
  (view-sja-test--with
    (setq-local drgnx-view-sja-tail t)
    (view-sja-test--reset view '("a" "b" "c"))
    (drgnx-view-sja-draw-now)
    (should (= (point) (point-max)))
    (save-window-excursion
      (delete-other-windows)
      (set-window-buffer (selected-window) buf)
      (should (= (window-point (selected-window)) (point-max)))
      ;; a row put above the first ones (a card, an older page) leaves the window at the end, not on its old first row
      (view-sja-test--push view (list (list :insert nil (list (view-sja-test--row "top" "a new top")))) :base 1 :version 2)
      (drgnx-view-sja-draw-now)
      (should (= (window-point (selected-window)) (point-max))))))

(ert-deftest rows-sja/read-only-region ()
  ;; the rows are read-only text in a buffer that is not
  (view-sja-test--with
    (view-sja-test--reset view '("a" "b"))
    (drgnx-view-sja-draw-now)
    (goto-char (drgnx-view-sja-row-start "b"))
    (should-error (insert "x") :type 'text-read-only)
    (should-error (progn (forward-char 2) (insert "x")) :type 'text-read-only)))

(ert-deftest rows-sja/quit-mid-batch-rolls-back ()
  ;; a draw stopped halfway (a quit, an error in a view's own step) is never confirmed: the next draw draws the region
  ;; whole, so the buffer is the rows again
  (view-sja-test--with
    (view-sja-test--reset view '("a" "b"))
    (drgnx-view-sja-draw-now)
    (view-sja-test--push view (list (list :replace (list (view-sja-test--row "a" "A" :props [[0 1 "drgnx-sja-test" 1]])
                                                         (view-sja-test--row "b" "B" :props [[0 1 "drgnx-sja-test" 1]]))))
                         :base 1 :version 2)
    (let ((calls 0))
      (setq-local drgnx-view-sja-prop-functions
                  (list (cons 'drgnx-sja-test (lambda (&rest _) (when (= (cl-incf calls) 2) (signal 'quit nil))))))
      ;; `should-error' catches only `error's: a quit is caught here
      (should (eq 'quit (condition-case nil (progn (drgnx-view-sja-draw-now) 'drawn) (quit 'quit)))))
    (setq-local drgnx-view-sja-prop-functions nil)
    (should (equal "A\nB\n" (view-sja-test--text)))))

(ert-deftest rows-sja/narrowed-buffer ()
  ;; a draw sees the whole buffer and leaves the narrowing as it was
  (view-sja-test--with
    (view-sja-test--reset view '("a" "b" "c"))
    (drgnx-view-sja-draw-now)
    (narrow-to-region (point-min) (drgnx-view-sja-row-start "b"))
    (view-sja-test--push view (list (list :replace (list (view-sja-test--row "c" "row C")))) :base 1 :version 2)
    (drgnx-view-sja-draw-now)
    (should (buffer-narrowed-p))
    (should (equal "row a\n" (buffer-substring-no-properties (point-min) (point-max))))
    (should (equal "row a\nrow b\nrow C\n" (view-sja-test--text)))))

(ert-deftest rows-sja/theme-change-re-resolves ()
  ;; a name that is no face yet is asked again at a redraw (a theme change, a face defined later); a style's face is
  ;; made again from the faces as they are.  The name is unknown on purpose: its count goes to a table of the test's
  ;; own, not the strict run's census of stale names (as view-patch-test's)
  (view-sja-test--with
    (let ((face 'drgnx-sja-test-later) (drgnx-view-unknown-faces (make-hash-table :test #'equal)))
      (unwind-protect
          (progn
            (view-sja-test--push view (list (list :reset (list (view-sja-test--row "a" "ab" :runs [[0 1 "drgnx-sja-test-later"]
                                                                                                   [1 2 "s:3"]]))))
                                 :styles (list (vector 3 (list :bold t))))
            (drgnx-view-sja-draw-now)
            (should-not (get-text-property (point-min) 'face))
            (should (get-text-property (1+ (point-min)) 'face))
            (custom-declare-face face '((t :inherit bold)) "A face defined after the first draw." :group 'drgnx)
            (drgnx-view-sja-redraw buf)
            (drgnx-view-sja-draw-now)
            (should (eq face (get-text-property (point-min) 'face)))
            (should (get-text-property (1+ (point-min)) 'face)))
        (put face 'face-defface-spec nil)))))

(ert-deftest rows-sja/a-gap-asks-once ()
  ;; a patch of a newer base asks the hub for a reset once; while it is outstanding another gap asks nothing
  (view-sja-test--with
    (view-sja-test--reset view '("a"))
    (should (eq 'resync (view-sja-test--push view nil :base 5 :version 6)))
    (should (eq 'quiet (view-sja-test--push view nil :base 7 :version 8)))
    (should (= 1 (length (view-sja-test--sent "view/resync"))))
    (should (equal 1 (plist-get (cdar (view-sja-test--sent "view/resync")) :version)))))

;; the user's Explorer, 2026-11-16: resets that held a key twice tripped the breaker, and the view stayed empty until
;; Emacs restarted
(ert-deftest rows-sja/a-broken-view-asks-for-a-reset-later ()
  ;; a broken store is started over once, a while after it broke (not on every push that finds it broken): its books
  ;; forgotten and a reset asked for from nothing
  (view-sja-test--with
    (let ((dup (lambda () (view-sja-test--push view (list (list :reset (list (view-sja-test--row "a" "1")
                                                                             (view-sja-test--row "a" "2"))))))))
      (funcall dup) (funcall dup)
      (should (eq 'broken (funcall dup)))
      (let ((key (cons 'drgnx-view-sja-revive buf)))
        (should (drgnx-timer-active-p key))
        (funcall dup)                                     ; broken again: the same pending timer, not a new one
        (should (drgnx-timer-active-p key))
        (setq view-sja-test--sent nil)
        (drgnx-view-sja--revive buf)
        (should (equal '(0) (mapcar (lambda (s) (plist-get (cdr s) :version)) (view-sja-test--sent "view/resync"))))
        (should-not (drgnx-view-patch-version drgnx-view-patch))))))

(ert-deftest rows-sja/paused-patches-apply-on-resume ()
  ;; a paused view keeps its patches in Sjá (nothing drawn or acknowledged); resuming draws them and acknowledges the last
  (view-sja-test--with
    (view-sja-test--reset view '("a"))
    (drgnx-view-sja-draw-now)
    (drgnx-view-patch-pause buf t)
    (should (eq 'paused (view-sja-test--push view (list (list :replace (list (view-sja-test--row "a" "A"))))
                                             :base 1 :version 2)))
    (should (equal "row a\n" (view-sja-test--text)))
    (setq view-sja-test--sent nil)
    (drgnx-view-patch-pause buf nil)
    (should (equal "A\n" (view-sja-test--text)))
    (should (equal '(2) (mapcar (lambda (s) (plist-get (cdr s) :version)) (view-sja-test--sent "view/ack"))))))

(ert-deftest rows-sja/the-env-says-where-the-rows-are ()
  ;; the pair's env asks the hub for the raw line (`rows_in_sja')
  (view-sja-test--with
    (should (drgnx-view-sja-held-p view "c"))
    (should-not (drgnx-view-sja-held-p view "other"))))

;;;; The generic layer: a view's code runs on rows Sjá holds

(require 'drgnx-view-nav)

(ert-deftest rows-sja/the-row-helpers-take-a-nil-view ()
  ;; a buffer whose rows Sjá holds has no `drgnx-view': the helpers a view's code calls answer from Sjá
  (view-sja-test--with
    (insert "head\n")
    (set-marker (drgnx-view-patch-beg drgnx-view-patch) (point))
    (view-sja-test--reset view '("a" "b"))
    (should (equal "head\nrow a\nrow b\n" (view-sja-test--text)))
    (should (= (drgnx-view-row-start nil "b") 12))
    (should (= (drgnx-view-row-end nil "b") 18))
    (should (equal (drgnx-view-key-at 13) "b"))
    (should-not (drgnx-view-key-at 2))
    (should-not (drgnx-view-row-start nil "z"))
    (should (eql (drgnx-view-draw-now nil) 0))))

(ert-deftest rows-sja/attach-with-sja-holds-the-rows-in-sja ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-rows) "nidhogg-view-rows")
  (let ((drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
        (drgnx-view-model--views (make-hash-table :test #'equal)))
    (with-temp-buffer
      (unwind-protect
          (progn
            (drgnx-view-patch-attach (format "sja-test-%d" (cl-incf view-sja-test--n)) "c" :sja t)
            (should (drgnx-view-sja-p))
            (should-not drgnx-view))
        (drgnx-view-patch-teardown)))))

(ert-deftest rows-sja/a-draw-tells-the-view-the-rows-and-nodes-it-drew ()
  ;; the view's own marks go back on the rows drawn; a node's spans come from Sjá, its chips (boxed runs) left out
  (view-sja-test--with
    (let (got)
      (add-hook 'drgnx-view-patch-patched-functions (lambda (v keys) (push (cons v keys) got)) nil t)
      (view-sja-test--reset view '("a" "b"))
      (view-sja-test--text)
      (should (equal (car got) '(nil "a" "b")))
      (view-sja-test--push view (list (list :replace (list (view-sja-test--row
                                                            "b" "chip id" :runs [[0 4 "drgnx-view-sja-test-chip"]]
                                                            :props [[0 7 "drgnx-work-id" "n1"]]))))
                           :base 1 :version 2)
      (view-sja-test--text)
      (should (equal (car got) '(nil "b")))
      (should (equal (drgnx-view-nav--sja-spans "n1" t) '((7 . 14))))
      (should (equal (drgnx-view-nav--sja-spans "n1") '((11 . 14)))))))

(defface drgnx-view-sja-test-chip '((t :box t)) "A boxed run, for the tests.")

;;;; The selection: the whole row (kit Task 10)

(require 'drgnx-view-nav)

(defconst view-sja-test--model
  (concat "{\"ops\":[{\"reset\":{\"descriptor\":{\"scheme\":\"links\",\"chain_kinds\":[\"link\"],"
          "\"match_fields\":[\"label\"],\"lists\":[\"all\"],\"classes\":[\"selected\"],\"start\":\"all\"},"
          "\"nodes\":[{\"id\":\"n1\",\"kind\":\"row\",\"nav\":{\"down\":\"n2\"},\"fields\":[[\"label\",\"a\"]]},"
          "{\"id\":\"n2\",\"kind\":\"row\",\"nav\":{\"up\":\"n1\"},\"fields\":[[\"label\",\"b\"]]}],"
          "\"edges\":[],\"lists\":[{\"name\":\"all\",\"ids\":[\"n1\",\"n2\"]}]}}]}")
  "Two list rows, n1 above n2, with the class `selected'.")

(defun view-sja-test--list (view)
  "VIEW's model and its two rows: n1 \"name chip Accept\" (a chip and a button boxed, its id over the whole row)
and n2 \"other\"."
  (drgnx-view-model-event (list :view view :hub 7 :base 0 :version 1 :reset t :model view-sja-test--model))
  (view-sja-test--push
   view (list (list :reset (list (view-sja-test--row "a" "name chip Accept"
                                                     :runs [[5 9 "drgnx-view-sja-test-chip"]
                                                            [10 16 "drgnx-view-sja-test-chip"]]
                                                     :props [[0 16 "drgnx-work-id" "n1"]])
                                 (view-sja-test--row "b" "other" :props [[0 5 "drgnx-work-id" "n2"]]))))
   :model 1)
  (view-sja-test--text))

(ert-deftest rows-sja/the-selection-is-its-whole-row-chips-and-all ()
  "Pattern D: on a terminal the selected list row is one overlay from its first character past its newline, over its
chip and button too (no hole, no edge where a boxed run starts); moved, the old row keeps none."
  (view-sja-test--with
    (switch-to-buffer buf)
    (view-sja-test--list view)
    (should (equal "n1" (drgnx-view-nav 'select "n1")))
    (let ((ovs (cl-remove-if-not (lambda (o) (eq (overlay-get o 'face) 'drgnx-view-selected))
                                 (overlays-in (point-min) (point-max)))))
      (should (= 1 (length ovs)))
      (should (equal (cons (overlay-start (car ovs)) (overlay-end (car ovs)))
                     (cons (point-min) (+ (point-min) 17)))))
    (should (equal "n2" (drgnx-view-nav 'select "n2")))
    (let ((ovs (cl-remove-if-not (lambda (o) (eq (overlay-get o 'face) 'drgnx-view-selected))
                                 (overlays-in (point-min) (point-max)))))
      (should (equal (mapcar (lambda (o) (cons (overlay-start o) (overlay-end o))) ovs)
                     (list (cons (+ (point-min) 17) (+ (point-min) 23))))))))

(ert-deftest rows-sja/the-selection-block-is-per-window ()
  "Pattern D: where Glitnir draws, the selected row is a `row' block of each window that shows the view: the full
selection in the selected window, the inactive one in the other; the buffer gone, no window keeps it."
  (view-sja-test--with
    (switch-to-buffer buf)
    (delete-other-windows)
    (let ((other (split-window)))
      (set-window-buffer other buf)
      (cl-letf (((symbol-function 'drgnx-view-nav-selection-style) (lambda () 'block))
                ;; the faces' backgrounds, which the blocks are filled with (unthemed in batch)
                ((symbol-function 'face-background)
                 (lambda (face &rest _) (pcase face ('drgnx-selected "#102030") ('drgnx-selected-inactive "#405060")))))
        (view-sja-test--list view)
        (should (equal "n1" (drgnx-view-nav 'select "n1")))
        (let ((b (car (window-parameter (selected-window) 'glitnir-blocks)))
              (o (car (window-parameter other 'glitnir-blocks))))
          (should (eq 'row (car b)))
          (should (equal (list (marker-position (nth 1 b)) (marker-position (nth 2 b)))
                         (list (point-min) (+ (point-min) 17))))
          (should (equal "#102030" (plist-get (nthcdr 3 b) :fill)))
          (should (equal "#405060" (plist-get (nthcdr 3 o) :fill))))
        ;; no class overlay draws it besides
        (should-not (cl-find 'drgnx-view-selected (overlays-in (point-min) (point-max))
                             :key (lambda (o) (overlay-get o 'face))))
        (select-window other)
        (run-hook-with-args 'window-selection-change-functions other)
        (should (equal "#102030" (plist-get (nthcdr 3 (car (window-parameter other 'glitnir-blocks))) :fill)))
        (view-sja-test--sel-clear buf)
        (should-not (window-parameter other 'glitnir-blocks))
        (should-not (window-parameter (next-window other) 'glitnir-blocks)))
      (delete-window other))))

(defun view-sja-test--sel-clear (buf)
  "What killing BUF does to the selection's blocks (`drgnx-view-nav--sel-clear')."
  (with-current-buffer buf (drgnx-view-nav--sel-clear)))

;;; view-sja-test.el ends here
