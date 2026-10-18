;;; core-memo-test.el --- batch tests: epochs, memos and capped caches (core/drgnx-memo.el) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-memo)
(require 'drgnx-modules-fingerprint)

;;;; Fixtures: defined at the top level, in order, so that the literal names below expand

(drgnx-epoch-define 'drgnx-memo-test-g :doc "A global epoch.")
(drgnx-epoch-define 'drgnx-memo-test-b :per 'buffer)
(drgnx-epoch-define 'drgnx-memo-test-o :per 'object)
(drgnx-epoch-define 'drgnx-memo-test-r :redisplay t)
(drgnx-epoch-define 'drgnx-memo-test-rb :per 'buffer :redisplay t)

(defvar drgnx-memo-test-var 0 "A watched global variable.")
(defvar-local drgnx-memo-test-lvar 0 "A watched buffer-local variable.")
(drgnx-epoch-watch 'drgnx-memo-test-g '(drgnx-memo-test-var))
(drgnx-epoch-watch 'drgnx-memo-test-b '(drgnx-memo-test-lvar))

(drgnx-memo-define drgnx-memo-test-a :keys ((car object) (cdr object)) :doc "A global slot keyed on a cons.")
(drgnx-memo-define drgnx-memo-test-w :on window :keys ((window-start object) (drgnx-epoch 'drgnx-memo-test-g)))
(drgnx-memo-define drgnx-memo-test-buf :on buffer :keys ((buffer-chars-modified-tick) (drgnx-epoch 'drgnx-memo-test-b object)))
(drgnx-memo-define drgnx-memo-test-none :keys ())

(defvar drgnx-memo-test--builds 0 "How many times a memo's BUILD ran.")

(defvar byte-compile-warnings)
(defvar drgnx-memo-test--ticks 0)
(defun drgnx-memo-test--tick () (setq drgnx-memo-test--ticks (1+ drgnx-memo-test--ticks)))

(defun drgnx-memo-test--memo-and-delete-a-window ()
  (let ((w (split-window)))
    (drgnx-memo drgnx-memo-test-w w (list 1))
    (should (= 1 (drgnx-memo-test--size 'drgnx-memo-test-w)))
    (delete-window w)
    nil))

(defun drgnx-memo-test--compile-library ()
  "Byte-compile this library's functions in place: the tests run on source, and an interpreted call conses."
  (mapatoms (lambda (s)
              (when (and (fboundp s) (string-match-p "\\`drgnx-\\(memo\\|epoch\\|cache\\)" (symbol-name s))
                         (functionp (symbol-function s)) (not (compiled-function-p (symbol-function s))))
                (let ((byte-compile-warnings nil)) (byte-compile s))))))

(defun drgnx-memo-test--alloc (fn)
  "Conses, floats, vector cells, symbols, string chars, intervals and strings that calling the byte-compiled FN
allocates: the smallest delta of `memory-use-counts' over three warm runs, minus an empty call's own."
  (drgnx-memo-test--compile-library)
  (let* ((byte-compile-warnings nil)
         (fn (if (compiled-function-p fn) fn (byte-compile fn)))
         (empty (let ((e (lambda () nil))) (if (compiled-function-p e) e (byte-compile e)))) best)
    (cl-flet ((delta (f) (let* ((a (memory-use-counts)) (_ (funcall f)) (b (memory-use-counts)))
                           (apply #'+ (cl-mapcar #'- b a)))))
      (funcall fn) (funcall fn)
      (dotimes (_ 3)
        (let ((d (- (delta fn) (delta empty)))) (setq best (if best (min best d) d)))))
    best))

(defmacro drgnx-memo-test--with-cache (name opts &rest body)
  "BODY with a cache NAME defined (`drgnx-cache-define' with OPTS), undefined after."
  (declare (indent 2))
  `(unwind-protect (progn (apply #'drgnx-cache-define ,name ,opts) ,@body)
     (drgnx-memo--undefine (get ,name 'drgnx-cache--def))))

(defmacro drgnx-memo-test--with-module (spec &rest body)
  "BODY with a fresh module table holding `test/a' (SPEC: its keyword arguments)."
  (declare (indent 1))
  `(let ((drgnx-modules--table (list (cons 'test/a ,spec)))
         (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
         (drgnx-modules--features nil) (drgnx-modules--left nil))
     ,@body))

(defun drgnx-memo-test--on () (drgnx-modules--run-one 'test/a (alist-get 'test/a drgnx-modules--table) 'startup))

(defun drgnx-memo-test--size (name)
  (nth 2 (assq name (drgnx-memo-census))))

;;;; Epochs

(ert-deftest drgnx-memo/global-bump-and-read ()
  (let ((v (drgnx-epoch 'drgnx-memo-test-g)))
    (should (fixnump v))
    (should (= (1+ v) (drgnx-epoch-bump 'drgnx-memo-test-g)))
    (should (= (1+ v) (drgnx-epoch 'drgnx-memo-test-g)))
    (should (= (+ v 2) (drgnx-epoch-bump 'drgnx-memo-test-g)))))

(ert-deftest drgnx-memo/per-buffer-base-and-own ()
  (with-temp-buffer
    (let ((a (current-buffer)) (b (generate-new-buffer " *drgnx-memo-b*")))
      (unwind-protect
          (let ((a0 (drgnx-epoch 'drgnx-memo-test-b a)) (b0 (drgnx-epoch 'drgnx-memo-test-b b)))
            (drgnx-epoch-bump 'drgnx-memo-test-b a)               ; its own count
            (should (= (1+ a0) (drgnx-epoch 'drgnx-memo-test-b a)))
            (should (= b0 (drgnx-epoch 'drgnx-memo-test-b b)))
            (drgnx-epoch-bump 'drgnx-memo-test-b)                 ; the base: every buffer
            (should (= (+ a0 2) (drgnx-epoch 'drgnx-memo-test-b a)))
            (should (= (1+ b0) (drgnx-epoch 'drgnx-memo-test-b b)))
            ;; a global set of the watched buffer-local variable moves every buffer's epoch
            (setq-default drgnx-memo-test-lvar 5)
            (should (= (+ a0 3) (drgnx-epoch 'drgnx-memo-test-b a)))
            (should (= (+ b0 2) (drgnx-epoch 'drgnx-memo-test-b b)))
            ;; a local set moves only that buffer's
            (with-current-buffer a (setq drgnx-memo-test-lvar 9))
            (should (= (+ a0 4) (drgnx-epoch 'drgnx-memo-test-b a)))
            (should (= (+ b0 2) (drgnx-epoch 'drgnx-memo-test-b b))))
        (kill-buffer b)))))

(ert-deftest drgnx-memo/per-object-total-moves-with-any-object ()
  (let ((total (drgnx-epoch 'drgnx-memo-test-o))
        (x0 (drgnx-epoch 'drgnx-memo-test-o "x")) (y0 (drgnx-epoch 'drgnx-memo-test-o "y")))
    (drgnx-epoch-bump 'drgnx-memo-test-o "x")                     ; an equal string finds the same count
    (should (= (1+ x0) (drgnx-epoch 'drgnx-memo-test-o (copy-sequence "x"))))
    (should (= y0 (drgnx-epoch 'drgnx-memo-test-o "y")))
    (should (= (1+ total) (drgnx-epoch 'drgnx-memo-test-o)))
    (drgnx-epoch-bump 'drgnx-memo-test-o "y")
    (should (= (+ total 2) (drgnx-epoch 'drgnx-memo-test-o)))
    (drgnx-epoch-bump 'drgnx-memo-test-o)                          ; the base moves every object
    (should (= (+ x0 2) (drgnx-epoch 'drgnx-memo-test-o "x")))
    (should (= (+ y0 2) (drgnx-epoch 'drgnx-memo-test-o "y")))))

(ert-deftest drgnx-memo/redisplay-epoch-forces-a-mode-line-update ()
  (let ((calls nil))
    (cl-letf (((symbol-function 'force-mode-line-update)
               (lambda (&optional all) (push (cons (current-buffer) all) calls))))
      (drgnx-epoch-bump 'drgnx-memo-test-g)                        ; not a redisplay epoch
      (should-not calls)
      (drgnx-epoch-bump 'drgnx-memo-test-r)                        ; global: all windows
      (should (equal (list (cons (current-buffer) t)) calls))
      (setq calls nil)
      (let ((other (generate-new-buffer " *drgnx-memo-r*")))
        (unwind-protect
            (progn (drgnx-epoch-bump 'drgnx-memo-test-rb other)    ; a buffer bump: that buffer's windows
                   (should (equal (list (cons other nil)) calls))
                   (setq calls nil)
                   (drgnx-epoch-bump 'drgnx-memo-test-rb)          ; the base: all windows
                   (should (equal (list (cons (current-buffer) t)) calls)))
          (kill-buffer other))))))

(ert-deftest drgnx-memo/wraps-at-the-fixnum-limit ()
  (let ((saved (get 'drgnx-memo-test-g 'drgnx-epoch--value)))
    (unwind-protect
        (progn (put 'drgnx-memo-test-g 'drgnx-epoch--value most-positive-fixnum)
               (should (= 0 (drgnx-epoch-bump 'drgnx-memo-test-g)))
               (should (= 1 (drgnx-epoch-bump 'drgnx-memo-test-g))))
      (put 'drgnx-memo-test-g 'drgnx-epoch--value saved))))

(ert-deftest drgnx-memo/an-undefined-epoch-signals ()
  (should-error (eval '(drgnx-epoch 'drgnx-memo-test-nope) t))      ; a literal: at expansion
  (should-error (macroexpand-all '(drgnx-epoch 'drgnx-memo-test-nope)))
  (should-error (drgnx-epoch (identity 'drgnx-memo-test-nope)))     ; else at run time
  (should (equal "No epoch drgnx-memo-test-nope"
                 (cadr (should-error (drgnx-epoch (identity 'drgnx-memo-test-nope)))))))

;;;; Watchers

(ert-deftest drgnx-memo/watchers-bump-on-setq-and-makunbound ()
  (let ((v (drgnx-epoch 'drgnx-memo-test-g)))
    (setq drgnx-memo-test-var 1)
    (should (= (1+ v) (drgnx-epoch 'drgnx-memo-test-g)))
    (setq drgnx-memo-test-var 2)
    (should (= (+ v 2) (drgnx-epoch 'drgnx-memo-test-g)))
    (unwind-protect
        (progn (makunbound 'drgnx-memo-test-var)
               (should (= (+ v 3) (drgnx-epoch 'drgnx-memo-test-g))))
      (setq drgnx-memo-test-var 0))))

(ert-deftest drgnx-memo/watchers-ignore-let ()
  (let ((v (drgnx-epoch 'drgnx-memo-test-g)))
    (let ((drgnx-memo-test-var 7))
      (should (= v (drgnx-epoch 'drgnx-memo-test-g)))
      (with-temp-buffer
        (setq-local drgnx-memo-test-lvar 3)
        (let ((drgnx-memo-test-lvar 4)) (should (= 4 drgnx-memo-test-lvar)))))
    (should (= v (drgnx-epoch 'drgnx-memo-test-g)))))

(ert-deftest drgnx-memo/watch-is-undone-with-the-module ()
  (drgnx-memo-test--with-module
      (list :setup (lambda ()
                     (drgnx-epoch-define 'drgnx-memo-test-m)
                     (drgnx-epoch-watch 'drgnx-memo-test-m '(drgnx-memo-test-mvar drgnx-memo-test-var))))
    (drgnx-memo-test--on)
    (should (memq #'drgnx-memo--watcher (get-variable-watchers 'drgnx-memo-test-mvar)))
    (let ((v (drgnx-epoch 'drgnx-memo-test-g)))
      (should-not (drgnx-module-teardown 'test/a))
      (should-not (memq #'drgnx-memo--watcher (get-variable-watchers 'drgnx-memo-test-mvar)))
      ;; a variable another epoch still watches keeps its watcher
      (should (memq #'drgnx-memo--watcher (get-variable-watchers 'drgnx-memo-test-var)))
      (setq drgnx-memo-test-var 0)
      (should (= (1+ v) (drgnx-epoch 'drgnx-memo-test-g))))
    (should-error (drgnx-epoch (identity 'drgnx-memo-test-m)))
    (should-not (assq 'drgnx-memo-test-mvar drgnx-memo--watched))))

;;;; Memos

(ert-deftest drgnx-memo/a-hit-returns-the-stored-value ()
  (drgnx-memo-forget 'drgnx-memo-test-a)
  (let* ((obj (cons 1 2)) (built (list 'v))
         (first (drgnx-memo drgnx-memo-test-a obj built)))
    (should (eq built first))
    (should (eq built (drgnx-memo drgnx-memo-test-a obj (list 'other))))
    (should (eq built (drgnx-memo drgnx-memo-test-a (cons 1 2) (list 'other))))))

(ert-deftest drgnx-memo/a-changed-key-builds-again ()
  (drgnx-memo-forget 'drgnx-memo-test-a)
  (let ((obj (cons 1 2)))
    (should (equal '(a) (drgnx-memo drgnx-memo-test-a obj (list 'a))))
    (setcar obj 5)
    (should (equal '(b) (drgnx-memo drgnx-memo-test-a obj (list 'b))))
    (should (equal '(b) (drgnx-memo drgnx-memo-test-a obj (list 'c))))
    (setcdr obj 6)
    (should (equal '(d) (drgnx-memo drgnx-memo-test-a obj (list 'd))))))

(ert-deftest drgnx-memo/build-runs-once-per-change ()
  (drgnx-memo-forget 'drgnx-memo-test-a)
  (let ((obj (cons 1 2)) (n 0))
    (dotimes (_ 5) (drgnx-memo drgnx-memo-test-a obj (cl-incf n)))
    (should (= 1 n))
    (setcar obj 9)
    (dotimes (_ 5) (drgnx-memo drgnx-memo-test-a obj (cl-incf n)))
    (should (= 2 n))
    (drgnx-epoch-bump 'drgnx-memo-test-g)
    (drgnx-memo-forget 'drgnx-memo-test-a)
    (drgnx-memo drgnx-memo-test-a obj (cl-incf n))
    (should (= 3 n))))

(ert-deftest drgnx-memo/each-key-form-is-evaluated-once ()
  (setq drgnx-memo-test--ticks 0)
  (eval '(drgnx-memo-define drgnx-memo-test-once :keys ((drgnx-memo-test--tick) (drgnx-memo-test--tick))) t)
  (unwind-protect
      (progn (eval '(drgnx-memo drgnx-memo-test-once nil 1) t)
             (should (= 2 drgnx-memo-test--ticks)))
    (drgnx-memo--undefine (get 'drgnx-memo-test-once 'drgnx-memo--def))))

(ert-deftest drgnx-memo/a-memo-with-no-keys-builds-once ()
  (drgnx-memo-forget 'drgnx-memo-test-none)
  (let ((n 0))
    (dotimes (_ 3) (drgnx-memo drgnx-memo-test-none nil (cl-incf n)))
    (should (= 1 n))))

(ert-deftest drgnx-memo/a-memo-follows-its-epochs ()
  (let ((n 0))
    (with-temp-buffer
      (drgnx-memo drgnx-memo-test-buf (current-buffer) (cl-incf n))
      (drgnx-memo drgnx-memo-test-buf (current-buffer) (cl-incf n))
      (should (= 1 n))
      (drgnx-epoch-bump 'drgnx-memo-test-b (current-buffer))
      (drgnx-memo drgnx-memo-test-buf (current-buffer) (cl-incf n))
      (should (= 2 n))
      (insert "x")                                                   ; a plain key moves too
      (drgnx-memo drgnx-memo-test-buf (current-buffer) (cl-incf n))
      (should (= 3 n))
      (drgnx-memo-forget 'drgnx-memo-test-buf (current-buffer))
      (drgnx-memo drgnx-memo-test-buf (current-buffer) (cl-incf n))
      (should (= 4 n)))))

(ert-deftest drgnx-memo/an-undefined-memo-signals-at-expansion ()
  (should-error (eval '(drgnx-memo drgnx-memo-test-nope nil 1) t)))

(ert-deftest drgnx-memo/a-dead-window-drops-out ()
  (drgnx-memo-forget 'drgnx-memo-test-w)
  (should (= 0 (drgnx-memo-test--size 'drgnx-memo-test-w)))
  (drgnx-memo-test--memo-and-delete-a-window)           ; in a function of its own: no stack slot keeps the window
  (garbage-collect)
  (should (= 0 (drgnx-memo-test--size 'drgnx-memo-test-w))))

(ert-deftest drgnx-memo/a-hit-allocates-nothing ()
  (let ((obj (cons 1 2)) (w (selected-window)))
    (drgnx-memo drgnx-memo-test-a obj (list 'v))
    (drgnx-memo drgnx-memo-test-w w (list 'v))
    (should (= 0 (drgnx-memo-test--alloc (lambda () (drgnx-memo drgnx-memo-test-a obj (list 'other))))))
    (should (= 0 (drgnx-memo-test--alloc (lambda () (drgnx-memo drgnx-memo-test-w w (list 'other))))))
    (should (> (drgnx-memo-test--alloc (lambda () (drgnx-memo drgnx-memo-test-a (cons 3 4) (list 'other)))) 0))))

(ert-deftest drgnx-memo/an-epoch-read-allocates-nothing ()
  (with-temp-buffer
    (let ((b (current-buffer)))
      (drgnx-epoch-bump 'drgnx-memo-test-b b)
      (drgnx-epoch-bump 'drgnx-memo-test-o "x")
      (should (= 0 (drgnx-memo-test--alloc (lambda () (drgnx-epoch 'drgnx-memo-test-g)))))
      (should (= 0 (drgnx-memo-test--alloc (lambda () (drgnx-epoch 'drgnx-memo-test-b b)))))
      (should (= 0 (drgnx-memo-test--alloc (lambda () (drgnx-epoch 'drgnx-memo-test-b)))))
      (should (= 0 (drgnx-memo-test--alloc (lambda () (drgnx-epoch 'drgnx-memo-test-o "x")))))
      (should (= 0 (drgnx-memo-test--alloc (lambda () (drgnx-epoch 'drgnx-memo-test-o))))))))

;;;; Caches

(ert-deftest drgnx-memo/string-cache-evicts-the-oldest-at-its-cap ()
  (drgnx-memo-test--with-cache 'drgnx-memo-test-s (list :key 'string :cap 3)
    (drgnx-cache-put 'drgnx-memo-test-s "a" 1)
    (drgnx-cache-put 'drgnx-memo-test-s "b" 2)
    (drgnx-cache-put 'drgnx-memo-test-s "c" 3)
    (should (= 3 (drgnx-cache-size 'drgnx-memo-test-s)))
    (should (= 4 (drgnx-cache-put 'drgnx-memo-test-s "d" 4)))
    (should (= 3 (drgnx-cache-size 'drgnx-memo-test-s)))
    (should-not (drgnx-cache-get 'drgnx-memo-test-s "a"))
    (should (equal '(2 3 4) (mapcar (lambda (k) (drgnx-cache-get 'drgnx-memo-test-s k)) '("b" "c" "d"))))
    ;; the least recently got goes: "b" was got first of the three, then "c", then "d"
    (drgnx-cache-get 'drgnx-memo-test-s "d")
    (drgnx-cache-get 'drgnx-memo-test-s "b")
    (drgnx-cache-put 'drgnx-memo-test-s "e" 5)
    (should-not (drgnx-cache-get 'drgnx-memo-test-s "c"))
    (should (drgnx-cache-get 'drgnx-memo-test-s "b"))
    (should (= 3 (drgnx-cache-size 'drgnx-memo-test-s)))))

(ert-deftest drgnx-memo/a-get-refreshes-the-stamp ()
  (drgnx-memo-test--with-cache 'drgnx-memo-test-s (list :key 'string :cap 3)
    (dolist (k '("a" "b" "c")) (drgnx-cache-put 'drgnx-memo-test-s k k))
    (should (equal "a" (drgnx-cache-get 'drgnx-memo-test-s "a")))
    (drgnx-cache-put 'drgnx-memo-test-s "d" "d")
    (should (equal "a" (drgnx-cache-get 'drgnx-memo-test-s "a")))
    (should-not (drgnx-cache-get 'drgnx-memo-test-s "b"))
    ;; a put of a present key replaces the value, grows nothing and refreshes it too
    (drgnx-cache-put 'drgnx-memo-test-s "c" "C")
    (should (= 3 (drgnx-cache-size 'drgnx-memo-test-s)))
    (drgnx-cache-put 'drgnx-memo-test-s "e" "e")
    (should (equal "C" (drgnx-cache-get 'drgnx-memo-test-s "c")))
    (should-not (drgnx-cache-get 'drgnx-memo-test-s "d"))
    (drgnx-cache-remove 'drgnx-memo-test-s "c")
    (should (= 2 (drgnx-cache-size 'drgnx-memo-test-s)))))

(ert-deftest drgnx-memo/a-string-cache-get-allocates-nothing ()
  (drgnx-memo-test--with-cache 'drgnx-memo-test-s (list :key 'string :cap 3)
    (drgnx-cache-put 'drgnx-memo-test-s "a" 1)
    (should (= 0 (drgnx-memo-test--alloc (lambda () (drgnx-cache-get 'drgnx-memo-test-s "a")))))))

(ert-deftest drgnx-memo/an-object-cache-drops-a-killed-buffer ()
  (drgnx-memo-test--with-cache 'drgnx-memo-test-ob (list :key 'object)
    (let ((b (generate-new-buffer " *drgnx-memo-ob*")) (w (selected-window)))
      (drgnx-cache-put 'drgnx-memo-test-ob b 'x)
      (drgnx-cache-put 'drgnx-memo-test-ob w 'y)
      (should (eq 'x (drgnx-cache-get 'drgnx-memo-test-ob b)))
      (should (= 2 (drgnx-cache-size 'drgnx-memo-test-ob)))
      (kill-buffer b)
      (should-not (drgnx-cache-get 'drgnx-memo-test-ob b))
      (should (eq 'y (drgnx-cache-get 'drgnx-memo-test-ob w)))
      (should (= 1 (drgnx-cache-size 'drgnx-memo-test-ob))))))

(ert-deftest drgnx-memo/a-string-cache-needs-a-cap ()
  (should-error (drgnx-cache-define 'drgnx-memo-test-nocap :key 'string))
  (should-error (drgnx-cache-define 'drgnx-memo-test-nocap :key 'string :cap 0))
  (should-error (drgnx-cache-define 'drgnx-memo-test-nocap :key 'string :cap "3"))
  (should-error (drgnx-cache-define 'drgnx-memo-test-nocap :key 'symbol))
  (should-not (get 'drgnx-memo-test-nocap 'drgnx-cache--def))
  (should-error (drgnx-cache-get 'drgnx-memo-test-nocap "a")))

(ert-deftest drgnx-memo/census-lists-every-cache-with-its-size ()
  (drgnx-memo-test--with-cache 'drgnx-memo-test-s (list :key 'string :cap 3)
    (drgnx-memo-test--with-cache 'drgnx-memo-test-ob (list :key 'object)
      (drgnx-cache-put 'drgnx-memo-test-s "a" 1)
      (drgnx-cache-put 'drgnx-memo-test-s "b" 2)
      (drgnx-cache-put 'drgnx-memo-test-ob (selected-window) 1)
      (let ((census (drgnx-memo-census)))
        (should (equal '(drgnx-memo-test-s cache 2 3) (assq 'drgnx-memo-test-s census)))
        (should (equal '(drgnx-memo-test-ob cache 1 nil) (assq 'drgnx-memo-test-ob census)))
        (should (equal '(drgnx-memo-test-a memo 0 nil) (progn (drgnx-memo-forget 'drgnx-memo-test-a)
                                                              (assq 'drgnx-memo-test-a (drgnx-memo-census)))))
        (should-not (assq 'drgnx-memo-test-g census))))))             ; epochs are not listed

;;;; Ownership

(ert-deftest drgnx-memo/definitions-push-their-undo ()
  (drgnx-memo-test--with-module
      (list :setup (lambda ()
                     (drgnx-epoch-define 'drgnx-memo-test-own :per 'buffer)
                     (eval '(drgnx-memo-define drgnx-memo-test-own-memo :on buffer :keys ((point))) t)
                     (drgnx-cache-define 'drgnx-memo-test-own-cache :key 'string :cap 2)))
    (let ((labels '("epoch drgnx-memo-test-own" "memo drgnx-memo-test-own-memo" "cache drgnx-memo-test-own-cache")))
      (drgnx-memo-test--on)
      (should (equal labels (mapcar (lambda (l) (and (gethash l drgnx-memo--registry) l)) labels)))
      (should (equal labels (reverse (mapcar #'car (alist-get 'test/a drgnx-modules--stacks)))))
      (should (= 0 (drgnx-epoch 'drgnx-memo-test-own (current-buffer))))
      (drgnx-cache-put 'drgnx-memo-test-own-cache "k" 1)
      (should-not (drgnx-module-teardown 'test/a))
      (dolist (l labels) (should-not (gethash l drgnx-memo--registry)))
      (should-not (get 'drgnx-memo-test-own-memo 'drgnx-memo--def))
      (should-not (get 'drgnx-memo-test-own-cache 'drgnx-cache--def))
      (should-error (drgnx-epoch (identity 'drgnx-memo-test-own)))
      (should-error (drgnx-cache-get 'drgnx-memo-test-own-cache "k")))))

(ert-deftest drgnx-memo/an-undo-after-a-redefinition-leaves-the-new-definition ()
  (drgnx-memo-test--with-module
      (list :setup (lambda () (drgnx-cache-define 'drgnx-memo-test-redef :key 'string :cap 2)))
    (drgnx-memo-test--on)
    (let ((old (get 'drgnx-memo-test-redef 'drgnx-cache--def)))
      (drgnx-cache-define 'drgnx-memo-test-redef :key 'string :cap 5)   ; someone else redefines it
      (should-not (eq old (get 'drgnx-memo-test-redef 'drgnx-cache--def)))
      (drgnx-module-teardown 'test/a)
      (should (= 5 (nth 3 (assq 'drgnx-memo-test-redef (drgnx-memo-census)))))
      (drgnx-memo--undefine (get 'drgnx-memo-test-redef 'drgnx-cache--def)))))

(ert-deftest drgnx-memo/the-registry-joins-the-fingerprint ()
  (should (memq 'drgnx-memo--registry drgnx-modules-fingerprint-registries)))

;;; core-memo-test.el ends here
