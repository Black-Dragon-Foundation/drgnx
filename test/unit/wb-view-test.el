;;; wb-view-test.el --- batch tests: views — types, marks, the draw pass (wb/drgnx-view.el) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-modules-fingerprint)
(require 'drgnx-signal)
(load (expand-file-name "test/fixtures/view-fixture" drgnx-dir) nil t)

;;;; Helpers

(defvar drgnx-view-test--model nil "KEY → its content, read by the test renderers.")
(defvar drgnx-view-test--order nil "The keys the test SYNC hands to `drgnx-view-sync-rows'.")

(defun drgnx-view-test--render (key) (format "%s: %s\n" key (gethash key drgnx-view-test--model "")))
(defun drgnx-view-test--render-body (key) (cons (format "%s: %s" key (gethash key drgnx-view-test--model "")) "\n"))
(defun drgnx-view-test--grow (key len) (substring (car (drgnx-view-test--render-body key)) len))
(defun drgnx-view-test--grow-nil (_key _len) nil)
(defun drgnx-view-test--sig (key) (gethash key drgnx-view-test--model))
(defun drgnx-view-test--vector-sig (key) (vector (gethash key drgnx-view-test--model) 'x))
(defun drgnx-view-test--sync (view) (drgnx-view-sync-rows view drgnx-view-test--order #'drgnx-view-test--sig))

(defmacro drgnx-view-test--with (spec &rest body)
  "SPEC: (VAR &rest ARGS).  BODY in a temp buffer with VAR a view of type `drgnx-view-test-t' (`drgnx-view-define'
with ARGS), attached at `point-min', and an empty model."
  (declare (indent 1))
  `(let ((drgnx-view-test--model (make-hash-table :test #'equal)) (drgnx-view-test--order nil))
     (drgnx-view-test-with-type ('drgnx-view-test-t ,@(cdr spec))
       (with-temp-buffer
         (let ((,(car spec) (drgnx-view-attach 'drgnx-view-test-t)))
           ,@body)))))

(defun drgnx-view-test--stat (view name) (plist-get (drgnx-view-stats view) name))

(defun drgnx-view-test--keys (view)
  (let (l) (dotimes (i (drgnx-view-row-count view)) (push (aref (drgnx-view--keys view) i) l)) (nreverse l)))

(defun drgnx-view-test--ok (view)
  "The view's starts are its rows and its text is a fresh render."
  (should-not (drgnx-view--check view))
  (should (equal (drgnx-view-test--expected view) (drgnx-view-test--text view))))

(defmacro drgnx-view-test--changes (var &rest body)
  "BODY with VAR a list, newest first, of each change's (INSERTED . DELETED) lengths in the current buffer."
  (declare (indent 1))
  `(let ((,var nil))
     (let ((record (lambda (beg end old) (push (cons (- end beg) old) ,var))))
       (add-hook 'after-change-functions record nil t)
       (unwind-protect (progn ,@body) (remove-hook 'after-change-functions record t)))))

;;;; Marks

(ert-deftest drgnx-view/append-draws-rows-in-order ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render)
    (drgnx-view-append v '(a b c))
    (should (drgnx-view-pending-p v))
    (should (equal "" (drgnx-view-test--text v)))      ; a mark draws nothing
    (should (= 3 (drgnx-view-draw-now v)))
    (should (equal "a: \nb: \nc: \n" (drgnx-view-test--text v)))
    (should-not (drgnx-view-pending-p v))
    (drgnx-view-append v '(d b))                ; b is shown already: it stays where it is
    (drgnx-view-draw-now v)
    (should (equal '(a b c d) (drgnx-view-test--keys v)))
    (should (= 4 (drgnx-view-test--stat v :appended)))
    (should (= 13 (drgnx-view-row-start v 'd)))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/insert-after-a-key ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render)
    (drgnx-view-append v '(a b c))
    (drgnx-view-draw-now v)
    (drgnx-view-insert v '(x y) :after 'a)
    (drgnx-view-insert v '(z) :after 'x)       ; after a pending key
    (drgnx-view-insert v '(q) :after 'gone)    ; neither drawn nor pending: appended
    (drgnx-view-draw-now v)
    (should (equal '(a x z y b c q) (drgnx-view-test--keys v)))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/insert-at-the-start ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render)
    (drgnx-view-append v '(a b))
    (drgnx-view-draw-now v)
    (drgnx-view-insert v '(x))
    (drgnx-view-insert v '(w) :after nil)
    (drgnx-view-draw-now v)
    (should (equal '(w x a b) (drgnx-view-test--keys v)))
    (should (= 1 (drgnx-view-row-start v 'w)))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/remove-takes-only-its-rows ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render)
    (dolist (k '(a b c d)) (puthash k (format "row %s" k) drgnx-view-test--model))
    (drgnx-view-append v '(a b c d))
    (drgnx-view-draw-now v)
    (let ((drawn (drgnx-view-test--stat v :rows-drawn)))
      (drgnx-view-append v '(e))
      (drgnx-view-insert v '(f) :after 'e)
      (drgnx-view-remove v '(b d e))           ; e was only pending: f takes its place
      (drgnx-view-test--changes changes
        (drgnx-view-draw-now v)
        (should (equal '(a c f) (drgnx-view-test--keys v)))
        (should (= 1 (- (drgnx-view-test--stat v :rows-drawn) drawn)))          ; f only
        (should (= 2 (drgnx-view-test--stat v :removed)))
        (should (equal '((0 . 9) (0 . 9)) (cl-remove-if (lambda (c) (= 0 (cdr c))) changes)))))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/dirty-redraws-only-its-rows ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render :key-test 'eq)
    (drgnx-view-append v (number-sequence 0 99))
    (drgnx-view-draw-now v)
    (let ((drawn (drgnx-view-test--stat v :rows-drawn)))
      (puthash 10 "changed" drgnx-view-test--model)
      (puthash 60 "also changed" drgnx-view-test--model)
      (drgnx-view-dirty v '(10 60))
      (should (= 2 (drgnx-view-draw-now v)))
      (should (= 2 (- (drgnx-view-test--stat v :rows-drawn) drawn))))
    (should (string-match-p "^60: also changed$" (drgnx-view-test--text v)))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/dirty-t-redraws-all-without-erasing ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render :key-test 'eq)
    (drgnx-view-append v (number-sequence 0 99))
    (drgnx-view-draw-now v)
    (dotimes (k 100) (puthash k "new" drgnx-view-test--model))
    (let ((drawn (drgnx-view-test--stat v :rows-drawn)))
      (drgnx-view-test--changes changes
        (drgnx-view-dirty v t)
        (drgnx-view-draw-now v)
        (should (= 100 (- (drgnx-view-test--stat v :rows-drawn) drawn)))
        (should (= 0 (drgnx-view-test--stat v :full-draws)))
        ;; each deletion is one row (at most "99: \n"), never the region
        (should (<= (apply #'max (mapcar #'cdr changes)) 5))))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/grow-inserts-only-the-new-text ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render-body :grow #'drgnx-view-test--grow)
    (puthash 'a "hello" drgnx-view-test--model)
    (drgnx-view-append v '(a b))
    (drgnx-view-draw-now v)
    (should (= (length "a: hello") (drgnx-view-body-length v 'a)))
    (puthash 'a "hello world" drgnx-view-test--model)
    (let ((drawn (drgnx-view-test--stat v :rows-drawn)))
      (drgnx-view-test--changes changes
        (drgnx-view-grow v 'a)
        (drgnx-view-draw-now v)
        (should (equal '((6 . 0)) changes)))
      (should (= 1 (drgnx-view-test--stat v :rows-grown)))
      (should (= 0 (- (drgnx-view-test--stat v :rows-drawn) drawn))))
    (should (= (length "a: hello world") (drgnx-view-body-length v 'a)))
    (should (= 16 (drgnx-view-row-start v 'b)))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/grow-nil-renders-again ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render-body :grow #'drgnx-view-test--grow-nil)
    (drgnx-view-append v '(a b))
    (drgnx-view-draw-now v)
    (puthash 'a "more" drgnx-view-test--model)
    (let ((drawn (drgnx-view-test--stat v :rows-drawn)))
      (drgnx-view-grow v 'a)
      (drgnx-view-draw-now v)
      (should (= 1 (- (drgnx-view-test--stat v :rows-drawn) drawn)))
      (should (= 0 (drgnx-view-test--stat v :rows-grown))))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/reset-swaps-the-row-set ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render)
    (drgnx-view-append v '(a b c))
    (drgnx-view-draw-now v)
    (drgnx-view-append v '(d))                 ; superseded by the reset
    (drgnx-view-reset v '(x a))
    (drgnx-view-draw-now v)
    (should (equal '(x a) (drgnx-view-test--keys v)))
    (should (= 3 (drgnx-view-test--stat v :removed)))
    (should (= 5 (drgnx-view-test--stat v :appended)))
    (should-not (drgnx-view-row-start v 'b))
    (drgnx-view-test--ok v)))

;;;; The invariant

(ert-deftest drgnx-view/starts-match-the-rows-after-every-mark ()
  "200 seeded random marks, drawn in batches of 1 to 3: after each draw the starts are the rows, the text is a
fresh render and the order is the one a plain list gets from the same marks."
  (drgnx-view-test--with (v :render #'drgnx-view-test--render-body :grow #'drgnx-view-test--grow :key-test 'eq)
    (let ((seed 20261019) (ref nil) (marks 0))
      (cl-labels ((rand (n) (setq seed (mod (+ (* seed 1103515245) 12345) 2147483648)) (mod (/ seed 65536) n))
                  (some-keys () (let (l) (dotimes (_ (1+ (rand 3))) (push (rand 30) l)) l))
                  (fresh (ks) (let (out) (dolist (k ks) (unless (or (memql k ref) (memql k out)) (push k out)))
                                   (nreverse out))))
        (while (< marks 200)
          (dotimes (_ (1+ (rand 3)))
            (let ((ks (some-keys)))
              (pcase (rand 10)
                ((or 0 1) (setq ref (append ref (fresh ks))) (drgnx-view-append v ks))
                ((or 2 3)
                 (let* ((after (and (> (rand 4) 0) (rand 30))) (tail (and after (memql after ref))) (new (fresh ks)))
                   (cond ((null after) (setq ref (append new ref)))
                         (tail (setcdr tail (append new (cdr tail))))
                         (t (setq ref (append ref new))))
                   (drgnx-view-insert v ks :after after)))
                ((or 4 5) (setq ref (cl-remove-if (lambda (k) (memql k ks)) ref)) (drgnx-view-remove v ks))
                (6 (dolist (k ks) (puthash k (format "v%d" (rand 1000)) drgnx-view-test--model))
                   (drgnx-view-dirty v ks))
                ((or 7 8) (let ((k (car ks)))
                            (when (memql k ref)
                              (puthash k (concat (gethash k drgnx-view-test--model "") "+") drgnx-view-test--model)
                              (drgnx-view-grow v k))))
                (_ (setq ref nil) (setq ref (fresh ks)) (drgnx-view-reset v ks))))
            (setq marks (1+ marks)))
          (drgnx-view-draw-now v)
          (should-not (drgnx-view--check v))
          (should (equal ref (drgnx-view-test--keys v)))
          (should (equal (drgnx-view-test--expected v) (drgnx-view-test--text v))))
        (should (> (drgnx-view-test--stat v :rows-grown) 0))))))

(defun drgnx-view-test--append-one-alloc (rows)
  "What appending and drawing one row allocates, on a view of ROWS rows."
  (drgnx-view-test--with (v :render #'drgnx-view-test--render :key-test 'eq)
    (drgnx-view-append v (number-sequence 1 rows))
    (drgnx-view-draw-now v)
    (let ((keys (drgnx-view--keys v)) (next rows))
      (prog1 (drgnx-view-test--alloc (lambda () (drgnx-view-append v (list (setq next (1+ next))))
                                       (drgnx-view-draw-now v)))
        (should (eq keys (drgnx-view--keys v)))       ; drawn in place: no fresh vectors
        (should (= (+ rows 5) (drgnx-view-row-count v)))
        (drgnx-view-test--ok v)))))

(ert-deftest drgnx-view/an-append-stays-in-place ()
  "Appending one row allocates the same on 1,000 rows as on 4,000: the vectors are not copied (review I2)."
  (let ((small (drgnx-view-test--append-one-alloc 1000)) (big (drgnx-view-test--append-one-alloc 4000)))
    (should (< (abs (- big small)) 64))))

(defun drgnx-view-test--fold-steps (v)
  "How many entries folding V's pending marks visits (`drgnx-view--ghost-p' is asked once per entry walked)."
  (let ((n 0) (orig (symbol-function 'drgnx-view--ghost-p)))
    (cl-letf (((symbol-function 'drgnx-view--ghost-p) (lambda (view i) (setq n (1+ n)) (funcall orig view i))))
      (drgnx-view--fold v))
    n))

(ert-deftest drgnx-view/an-append-folds-only-the-new-tail ()
  "Appends (also after a pending key) fold without walking the 4,000 rows; an insert before a drawn row still does."
  (drgnx-view-test--with (v :render #'drgnx-view-test--render :key-test 'eq)
    (drgnx-view-append v (number-sequence 1 4000))
    (drgnx-view-draw-now v)
    (drgnx-view-append v '(5001 5002))
    (drgnx-view-insert v '(5003) :after 5001)
    (should (= 0 (drgnx-view-test--fold-steps v)))
    (drgnx-view-draw-now v)
    (should (equal '(4000 5001 5003 5002) (last (drgnx-view-test--keys v) 4)))
    (drgnx-view-test--ok v)
    (drgnx-view-insert v '(6000) :after 10)
    (should (> (drgnx-view-test--fold-steps v) 4000))
    (drgnx-view-draw-now v)
    (should (equal '(10 6000 11) (take 3 (nthcdr 9 (drgnx-view-test--keys v)))))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/an-append-between-slices-keeps-the-rows-left-to-delete ()
  "A slice stopped with rows left to delete (and rows deleted, not compacted yet); an append then folds only its
tail, and the next draw finishes both."
  (drgnx-view-test--with (v :render #'drgnx-view-test--render :slice 0.004 :key-test 'eq)
    (drgnx-view-append v (number-sequence 1 100))
    (drgnx-view-draw-now v)
    (drgnx-view-remove v (number-sequence 1 50))
    (let ((now 0.0) (drgnx-view--deadline nil))
      (cl-letf (((symbol-function 'drgnx-timer-now) (lambda () (setq now (+ now 1.0)))))   ; every check is late
        (drgnx-view--draw v 0.004)))
    (should (drgnx-view--cut v))
    (should (= 8 (drgnx-view-test--stat v :removed)))
    (drgnx-view-append v '(200 201))
    (should (= 0 (drgnx-view-test--fold-steps v)))
    (should-not (drgnx-view--check v))
    (drgnx-view-draw-now v)
    (should (equal (append (number-sequence 51 100) '(200 201)) (drgnx-view-test--keys v)))
    (should (= 50 (drgnx-view-test--stat v :removed)))
    (drgnx-view-test--ok v)))

(defvar drgnx-view-test--clock 0.0
  "The clock `drgnx-timer-now' reads in the pass tests: each rendered row costs 2^-14 s (exact: sums never round).")
(defun drgnx-view-test--slow-render (key) (cl-incf drgnx-view-test--clock (/ 1.0 16384)) (drgnx-view-test--render key))

(ert-deftest drgnx-view/views-in-one-timer-pass-share-one-slice ()
  "The first view spends the pass's 4 ms slice (72 rows of 2^-14 s: the check after 64 is still in time); a second
view drawn in the same pass gets no slice of its own: it draws its first 8 rows and stops.  The next pass starts a
fresh slice."
  (drgnx-view-test--with (v :render #'drgnx-view-test--slow-render :slice 0.004 :key-test 'eq)
    (drgnx-view-append v (number-sequence 1 100))
    (with-temp-buffer
      (let ((w (drgnx-view-attach 'drgnx-view-test-t)) (drgnx-view-test--clock 0.0) (drgnx-view--deadline nil))
        (drgnx-view-append w (number-sequence 1 100))
        (unwind-protect
            (cl-letf (((symbol-function 'drgnx-timer-now) (lambda () drgnx-view-test--clock)))
              (should (= 72 (with-current-buffer (drgnx-view--buffer v) (drgnx-view--draw v 0.004))))
              (should (drgnx-timer-active-p 'drgnx-view-pass))
              (should (= 8 (drgnx-view--draw w 0.004)))                    ; same pass: the slice is spent
              (drgnx-view--pass-end)                                       ; what the key runs in the next pass
              (should (= 72 (drgnx-view--draw w 0.004))))
          (drgnx-timer-cancel 'drgnx-view-pass))))))

;;;; Sync

(ert-deftest drgnx-view/sync-rows-marks-appends-removals-and-dirty ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render :sync #'drgnx-view-test--sync)
    (dolist (k '(a b c d)) (puthash k (format "%s0" k) drgnx-view-test--model))
    (setq drgnx-view-test--order '(a b c d))
    (drgnx-view-touch v)
    (should (= 4 (drgnx-view-draw-now v)))
    (drgnx-view-touch v)
    (should (= 0 (drgnx-view-draw-now v)))     ; the same signatures: nothing to draw
    (puthash 'c "c1" drgnx-view-test--model)
    (puthash 'e "e0" drgnx-view-test--model)
    (setq drgnx-view-test--order '(a c d e))
    (let ((drawn (drgnx-view-test--stat v :rows-drawn)))
      (drgnx-view-touch v)
      (drgnx-view-draw-now v)
      (should (equal '(a c d e) (drgnx-view-test--keys v)))
      (should (= 2 (- (drgnx-view-test--stat v :rows-drawn) drawn)))           ; c patched, e new
      (should (= 1 (drgnx-view-test--stat v :removed))))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/sync-rows-a-vector-signature-is-compared-element-wise ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render)
    (dolist (k '(a b)) (puthash k (format "%s0" k) drgnx-view-test--model))
    (drgnx-view-sync-rows v '(a b) #'drgnx-view-test--vector-sig)
    (drgnx-view-draw-now v)
    (drgnx-view-sync-rows v '(a b) #'drgnx-view-test--vector-sig)   ; fresh vectors, `eq' elements
    (should (= 0 (drgnx-view-draw-now v)))
    (puthash 'b "b1" drgnx-view-test--model)
    (drgnx-view-sync-rows v '(a b) #'drgnx-view-test--vector-sig)
    (should (= 1 (drgnx-view-draw-now v)))
    (drgnx-view-test--ok v)))

(ert-deftest drgnx-view/sync-rows-a-big-reorder-is-a-reset ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render :key-test 'eq)
    (drgnx-view-sync-rows v (number-sequence 0 9) #'drgnx-view-test--sig)
    (drgnx-view-draw-now v)
    ;; one row moved: a remove plus an insert
    (drgnx-view-sync-rows v (append (number-sequence 1 9) '(0)) #'drgnx-view-test--sig)
    (should-not (assq 'reset (drgnx-view--pending v)))
    (drgnx-view-draw-now v)
    (should (equal (append (number-sequence 1 9) '(0)) (drgnx-view-test--keys v)))
    (should (= 1 (drgnx-view-test--stat v :removed)))
    ;; all reversed: more than half moved
    (drgnx-view-sync-rows v (number-sequence 9 0 -1) #'drgnx-view-test--sig)
    (should (assq 'reset (drgnx-view--pending v)))
    (drgnx-view-draw-now v)
    (should (equal (number-sequence 9 0 -1) (drgnx-view-test--keys v)))
    (should (= 11 (drgnx-view-test--stat v :removed)))
    (drgnx-view-test--ok v)))

;;;; Attach

(ert-deftest drgnx-view/undo-is-off ()
  (drgnx-view-test-with-type ('drgnx-view-test-t :render #'drgnx-view-test--render)
    (let ((b (get-buffer-create "drgnx-view-test-undo")) (drgnx-view-test--model (make-hash-table)))
      (unwind-protect
          (with-current-buffer b
            (should-not (eq t buffer-undo-list))
            (let ((v (drgnx-view-attach 'drgnx-view-test-t)))
              (should (eq t buffer-undo-list))
              (drgnx-view-append v '(a b))
              (drgnx-view-draw-now v)
              (should (eq t buffer-undo-list))
              (should-not (buffer-modified-p))))
        (kill-buffer b)))))

(ert-deftest drgnx-view/rows-are-read-only-but-text-above-start-is-not ()
  (drgnx-view-test-with-type ('drgnx-view-test-t :render #'drgnx-view-test--render)
    (let ((drgnx-view-test--model (make-hash-table)))
      (with-temp-buffer
        (insert "header\n")
        (let ((v (drgnx-view-attach 'drgnx-view-test-t :start (point-max))))
          (should-not buffer-read-only)
          (drgnx-view-append v '(a b))
          (drgnx-view-draw-now v)
          (goto-char 3)
          (insert "x")                          ; above START
          (should (equal "hexader\na: \nb: \n" (buffer-string)))
          ;; at START, between two rows, inside a row and after the last row: refused
          (dolist (pos (list (drgnx-view-row-start v 'a) (drgnx-view-row-start v 'b)
                             (1+ (drgnx-view-row-start v 'b)) (point-max)))
            (goto-char pos)
            (should-error (insert "y") :type 'text-read-only))
          (goto-char (1- (drgnx-view-row-start v 'a)))
          (insert "z")                          ; just above START
          (should (equal "hexaderz\na: \nb: \n" (buffer-string)))
          (should-not (drgnx-view--check v))))
      (with-temp-buffer
        (drgnx-view-attach 'drgnx-view-test-t)
        (should buffer-read-only)))))

(defvar drgnx-view-test--markers 0)
(defun drgnx-view-test--count-marker (&rest _) (setq drgnx-view-test--markers (1+ drgnx-view-test--markers)))

(ert-deftest drgnx-view/start-is-the-only-marker ()
  "Attaching and drawing 10,000 rows makes one marker (START): no Lisp call makes another."
  (let ((fns '(make-marker copy-marker point-marker point-min-marker point-max-marker))
        (drgnx-view-test--markers 0))
    (drgnx-view-test--with (v :render #'drgnx-view-test--render :key-test 'eq)
      (dolist (f fns) (advice-add f :before #'drgnx-view-test--count-marker))
      (unwind-protect
          (progn
            (setq v (drgnx-view-attach 'drgnx-view-test-t))
            (drgnx-view-append v (number-sequence 1 10000))
            (drgnx-view-draw-now v)
            (drgnx-view-dirty v t)
            (drgnx-view-draw-now v))
        (dolist (f fns) (advice-remove f #'drgnx-view-test--count-marker)))
      (should (= 10000 (drgnx-view-row-count v)))
      (should (= 1 drgnx-view-test--markers))
      (should (eq (current-buffer) (marker-buffer (drgnx-view--start v)))))))

;;;; Errors and checks

(ert-deftest drgnx-view/a-render-error-draws-a-line-and-is-recorded-once ()
  (let ((drgnx-signal-errors nil))
    (drgnx-view-test--with (v :render (lambda (key) (if (eq key 'bad) (error "boom") (format "%s\n" key))))
      (drgnx-view-append v '(a bad c))
      (drgnx-view-draw-now v)
      (should (equal "a\n⚠ bad: boom\nc\n" (drgnx-view-test--text v)))
      (should (eq 'error (get-text-property (drgnx-view-row-start v 'bad) 'face)))
      (should (equal '("view drgnx-view-test-t: boom") drgnx-signal-errors))
      (drgnx-view-dirty v t)
      (drgnx-view-draw-now v)
      (should (equal '("view drgnx-view-test-t: boom") drgnx-signal-errors))
      (drgnx-view-test--ok v))))

(ert-deftest drgnx-view/a-foreign-edit-resets-the-view ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render)
    (drgnx-view-append v '(a b c))
    (drgnx-view-draw-now v)
    (let ((inhibit-read-only t))
      (goto-char (1+ (drgnx-view-row-start v 'b)))
      (insert "junk"))
    (should (drgnx-view--check v))
    (drgnx-view-append v '(d))
    (drgnx-view-draw-now v)
    (should (= 1 (drgnx-view-test--stat v :full-draws)))
    (should (equal '(a b c d) (drgnx-view-test--keys v)))
    (drgnx-view-test--ok v)))

;;;; Reads

(ert-deftest drgnx-view/key-at-is-a-binary-search ()
  (drgnx-view-test--with (v :render #'drgnx-view-test--render :key-test 'eq)
    (dotimes (k 1000) (puthash k (make-string (mod (* k 7) 13) ?x) drgnx-view-test--model))
    (drgnx-view-append v (number-sequence 0 999))
    (drgnx-view-draw-now v)
    (dotimes (k 1000)
      (let ((beg (drgnx-view-row-start v k)) (end (or (drgnx-view-row-start v (1+ k)) (point-max))))
        (should (eq k (drgnx-view-key-at beg)))
        (should (eq k (drgnx-view-key-at (1- end))))
        (should (eq k (drgnx-view-key-at (/ (+ beg end) 2))))))
    (should-not (drgnx-view-key-at (point-max)))
    (goto-char (drgnx-view-row-start v 500))
    (should (eq 500 (drgnx-view-key-at)))
    (should (= 0 (drgnx-view-test--alloc (lambda () (drgnx-view-key-at 5000)))))))

(ert-deftest drgnx-view/stats-sum-over-views ()
  (let ((base (plist-get (drgnx-view-stats) :appended)))
    (drgnx-view-test--with (v1 :render #'drgnx-view-test--render)
      (drgnx-view-append v1 '(a b c))
      (drgnx-view-draw-now v1)
      (with-temp-buffer
        (let ((v2 (drgnx-view-attach 'drgnx-view-test-t)))
          (drgnx-view-append v2 '(a b c d))
          (drgnx-view-draw-now v2)
          (should (= 4 (drgnx-view-test--stat v2 :appended)))
          (should (= (+ base 7) (plist-get (drgnx-view-stats) :appended)))
          (should (equal '(:rows-drawn :rows-grown :appended :removed :slices :max-slice-rows :full-draws
                                       :stale-skips)
                         (cl-loop for (k _) on (drgnx-view-stats) by #'cddr collect k))))))))

;;;; Ownership

(ert-deftest drgnx-view/a-type-belongs-to-its-module ()
  (let ((drgnx-modules--table (list (list 'test/vw :doc "a module for the view tests")))
        (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
        (drgnx-modules--features nil))
    (should-not (drgnx-modules--run-setup
                 'test/vw (lambda () (drgnx-view-define 'drgnx-view-test-own :render #'drgnx-view-test--render))))
    (drgnx-modules--record 'test/vw 'startup 0 'ok)
    (should (assq 'drgnx-view-test-own drgnx-view--types))
    (should (equal '("view type drgnx-view-test-own") (mapcar #'car (alist-get 'test/vw drgnx-modules--stacks))))
    (should-not (drgnx-module-teardown 'test/vw))
    (should-not (assq 'drgnx-view-test-own drgnx-view--types))
    (should (memq 'drgnx-view--types drgnx-modules-fingerprint-registries))))

(ert-deftest drgnx-view/define-checks-its-arguments ()
  (should-error (drgnx-view-define 'drgnx-view-test-bad :render #'drgnx-view-test--render :slice 0.01))
  (should-error (drgnx-view-define 'drgnx-view-test-bad :render #'drgnx-view-test--render :key-test 'eql))
  (should-error (drgnx-view-define 'drgnx-view-test-bad))
  (should-not (assq 'drgnx-view-test-bad drgnx-view--types)))

;;; wb-view-test.el ends here
