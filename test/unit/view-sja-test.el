;;; view-sja-test.el --- batch tests: hub-fed rows held in Sjá, drawn from its edits (wb/drgnx-view-sja.el) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-view-sja)

(defvar view-sja-test--sent nil "What the buffer sent the hub, newest first: (METHOD . PARAMS).")
(defvar view-sja-test--n 0 "A counter for each test's own view name (Sjá's views are the process's).")

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

(cl-defun view-sja-test--push (view ops &key (base 0) (version 1) styles)
  "A row patch of VIEW (OPS: a list of op plists) from BASE to VERSION, on the hub's `view-model' line; returns Sjá's
decision."
  (drgnx-view-model-line
   (json-serialize
    (list :event "view-model"
          :data (list :view view
                      :rows (append (list :view view :class "c" :hub 7 :base base :version version :env_epoch 0
                                          :ops (vconcat (mapcar (lambda (op) (view-sja-test--op op)) ops)))
                                    (and styles (list :styles (vconcat styles)))))))))

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
  ;; made again from the faces as they are
  (view-sja-test--with
    (let ((face 'drgnx-sja-test-later))
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

;;; view-sja-test.el ends here
