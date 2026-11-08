;;; term-cells-test.el --- batch tests: a terminal's wide cells drawn to their two cells -*- lexical-binding: t -*-
;; test-class: det
;; The terminal's guard over a row's stops (`drgnx-term--cell-guard'), through the hub-fed rows' RENDER: a glyph wider
;; than its two cells (an emoji in a font that draws it at ~19 px over 2 × 8) is scaled down to them with a `height'
;; display, never cut to an ellipsis.  The measure is faked: 8 px a character, 19 px an emoji, 0 a joiner, each times
;; the `height' factor its text carries.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-view)
(load (expand-file-name "modules/tools/drgnx-term" drgnx-dir) nil t)

(defvar drgnx-term-cells-test--measures 0 "How many times the fake measure ran.")

(defun drgnx-term-cells-test--measure (s)
  "S's width: 8 px a character, 19 an emoji, 0 a joiner or selector, times the `(height F)' display it carries."
  (cl-incf drgnx-term-cells-test--measures)
  (let ((w 0))
    (dotimes (i (length s))
      (let* ((c (aref s i)) (d (get-text-property i 'display s))
             (f (if (eq (car-safe d) 'height) (cadr d) 1)))
        (setq w (+ w (* f (cond ((memq c '(#x200d #xfe0f)) 0) ((>= c #x1f000) 19) (t 8)))))))
    w))

(defmacro drgnx-term-cells-test--with (&rest body)
  "BODY in a hub-fed buffer with the terminal's guard, a cell of 8 px and the fake measure."
  (declare (indent 0))
  `(let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
         (drgnx-view-patch--hooked nil)
         (drgnx-view-patch-send-function #'ignore)
         (drgnx-term--cell-scales (make-hash-table :test #'equal))
         (drgnx-term-cell-width-function (lambda () 8))
         (drgnx-term-cell-measure-function #'drgnx-term-cells-test--measure)
         (drgnx-view-patch-measure-function (lambda (_) (error "The fit guard measured a terminal row")))
         (drgnx-term-cells-test--measures 0))
     (with-temp-buffer
       (let ((view (drgnx-view-patch-attach "v" "c" :epoch 1)))
         (setq-local drgnx-view-patch-guard-function #'drgnx-term--cell-guard)
         (unwind-protect (progn ,@body)
           (ignore view)
           (drgnx-view-patch-teardown)
           (drgnx-timer-cancel (cons 'drgnx-view (current-buffer))))))))

(defun drgnx-term-cells-test--show (&rest rows)
  "ROWS (each (KEY TEXT STOPS)) as one reset, drawn; the buffer's text."
  (drgnx-view-apply-patch
   (list :view "v" :class "c" :hub 7 :base 0 :version 1 :env_epoch 1
         :ops (list (list :reset (mapcar (lambda (r) (list :key (nth 0 r) :text (nth 1 r) :stops (nth 2 r))) rows)))))
  (drgnx-view-draw-now drgnx-view)
  (buffer-substring-no-properties (point-min) (point-max)))

(defun drgnx-term-cells-test--x (key i)
  "The fake measure of row KEY's text up to its character I, as drawn (its display properties)."
  (let ((s (drgnx-view-row-start drgnx-view key)))
    (drgnx-term-cells-test--measure (buffer-substring s (+ s i)))))

(ert-deftest drgnx-term-cells/emoji-is-drawn-to-its-two-cells ()
  "A leading emoji (cells 0-1, its stop at 16 px) and one after two letters (cells 2-3, stop at 32): both keep their
glyph, scaled to 16 px or less, and nothing becomes an ellipsis."
  (drgnx-term-cells-test--with
    (let ((text (drgnx-term-cells-test--show (list "a" (concat (string #x1f600) " |") '((1 16)))
                                             (list "b" (concat "ab" (string #x1f600) " |") '((3 32))))))
      (should (equal text (concat (string #x1f600) " |\nab" (string #x1f600) " |\n")))
      (should-not (string-search "…" text))
      (should (<= 15 (drgnx-term-cells-test--x "a" 1) 16))
      (should (<= 31 (drgnx-term-cells-test--x "b" 3) 32))
      (should (eq 'height (car (get-text-property (drgnx-view-row-start drgnx-view "a") 'display))))
      ;; the letters before the emoji keep their size
      (should-not (get-text-property (drgnx-view-row-start drgnx-view "b") 'display)))))

(ert-deftest drgnx-term-cells/a-joined-emoji-is-scaled-as-one ()
  "👩‍💻 in one wide cell (mode 2027): its three characters carry the same scale, so they stay one glyph."
  (drgnx-term-cells-test--with
    (let ((zwj (string #x1f469 #x200d #x1f4bb)))
      (drgnx-term-cells-test--show (list "a" (concat "x" zwj " |") '((4 24))))
      (let* ((s (drgnx-view-row-start drgnx-view "a")) (d (get-text-property (1+ s) 'display)))
        (should (eq 'height (car d)))
        (should (eq d (get-text-property (+ s 2) 'display)))
        (should (eq d (get-text-property (+ s 3) 'display)))
        (should-not (get-text-property s 'display))))))

(ert-deftest drgnx-term-cells/fitting-cells-are-left-alone ()
  "A CJK character the font draws in its two cells (8 px each here) gets no scale; the stops are the only displays."
  (drgnx-term-cells-test--with
    (drgnx-term-cells-test--show (list "a" (concat (string #x6f22) " " (string #x5b57) " |") '((1 16) (3 32))))
    (let ((s (drgnx-view-row-start drgnx-view "a")))
      (should-not (get-text-property s 'display))
      (should-not (get-text-property (+ s 2) 'display)))))

(ert-deftest drgnx-term-cells/each-cluster-is-measured-once ()
  "Thirty rows of the same emoji: the cluster is measured once (and once more to check its scale), not per row."
  (drgnx-term-cells-test--with
    (apply #'drgnx-term-cells-test--show
           (mapcar (lambda (i) (list (number-to-string i) (concat (string #x1f600) " x") '((1 16))))
                   (number-sequence 1 30)))
    (should (<= drgnx-term-cells-test--measures 3))))

(provide 'term-cells-test)
;;; term-cells-test.el ends here
