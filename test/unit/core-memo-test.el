;;; core-memo-test.el --- batch tests: epochs, memos and capped caches (core/drgnx-memo.el) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-memo)
(require 'drgnx-modules-fingerprint)

;;;; Fixtures: defined at the top level, in order, so that the literal names below expand

(drgnx-epoch-define 'drgnx-memo-test-g :doc "A global epoch." :watch '(drgnx-memo-test-var))
(drgnx-epoch-define 'drgnx-memo-test-b :per 'buffer :watch '(drgnx-memo-test-lvar))
(drgnx-epoch-define 'drgnx-memo-test-look :per 'buffer :watch '(tab-width indent-tabs-mode))
(drgnx-epoch-define 'drgnx-memo-test-own :per 'buffer :watch '(drgnx-memo-test-ownvar))
(drgnx-epoch-define 'drgnx-memo-test-al :watch '(drgnx-memo-test-av))
(drgnx-epoch-define 'drgnx-memo-test-o :per 'object)
(drgnx-epoch-define 'drgnx-memo-test-r :redisplay t)
(drgnx-epoch-define 'drgnx-memo-test-rb :per 'buffer :redisplay t)

(defvar drgnx-memo-test-var 0 "A watched global variable.")
(defvar-local drgnx-memo-test-lvar 0 "A watched buffer-local variable.")
(defvar drgnx-memo-test-ownvar 0)
(defvar drgnx-memo-test-av 0)
(defvar drgnx-memo-test-base 0)
(drgnx-cache-define 'drgnx-memo-test-own-cache :key 'string :cap 2)

(drgnx-memo-define drgnx-memo-test-a :keys ((car object) (cdr object)) :doc "A global slot keyed on a cons.")
(drgnx-memo-define drgnx-memo-test-w :on window :keys ((window-start object) (drgnx-epoch 'drgnx-memo-test-g)))
(drgnx-memo-define drgnx-memo-test-buf :on buffer :keys ((buffer-chars-modified-tick) (drgnx-epoch 'drgnx-memo-test-b object)))
(drgnx-memo-define drgnx-memo-test-none :keys ())

(defvar drgnx-memo-test--builds 0 "How many times a memo's BUILD ran.")

(require 'bytecomp)                                  ; `byte-compile-warnings' is let-bound below
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

(defmacro drgnx-memo-test--active (names &rest body)
  "BODY with the declared NAMES (a form giving a list) activated by a module's setup, which is torn down after."
  (declare (indent 1))
  `(drgnx-memo-test--with-module (list :setup (lambda () (apply #'drgnx-memo-activate ,names)))
     (drgnx-memo-test--on)
     (unwind-protect (progn ,@body) (drgnx-module-teardown 'test/a))))

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
  (drgnx-memo-test--active '(drgnx-memo-test-b)
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
          (kill-buffer b))))))

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
  (drgnx-memo-test--active '(drgnx-memo-test-g)
    (let ((v (drgnx-epoch 'drgnx-memo-test-g)))
      (setq drgnx-memo-test-var 1)
      (should (= (1+ v) (drgnx-epoch 'drgnx-memo-test-g)))
      (setq drgnx-memo-test-var 2)
      (should (= (+ v 2) (drgnx-epoch 'drgnx-memo-test-g)))
      (unwind-protect
          (progn (makunbound 'drgnx-memo-test-var)
                 (should (= (+ v 3) (drgnx-epoch 'drgnx-memo-test-g))))
        (setq drgnx-memo-test-var 0)))))

(ert-deftest drgnx-memo/a-set-to-the-value-it-has-does-not-bump ()
  (drgnx-memo-test--active '(drgnx-memo-test-g)
    (setq drgnx-memo-test-var 4)
    (let ((v (drgnx-epoch 'drgnx-memo-test-g)))
      (setq drgnx-memo-test-var 4)
      (should (= v (drgnx-epoch 'drgnx-memo-test-g)))
      (setq drgnx-memo-test-var (list 4))                         ; a new cons is a change
      (should (= (1+ v) (drgnx-epoch 'drgnx-memo-test-g)))
      (setq drgnx-memo-test-var (cons 1 2))                       ; and a cons is never skipped
      (should (= (+ v 2) (drgnx-epoch 'drgnx-memo-test-g)))
      (setq drgnx-memo-test-var 0))))

(ert-deftest drgnx-memo/watchers-ignore-let ()
  (drgnx-memo-test--active '(drgnx-memo-test-g drgnx-memo-test-b drgnx-memo-test-look)
    (let ((other (generate-new-buffer " *drgnx-memo-other*")))
      (unwind-protect
          (with-temp-buffer
            (let ((here (current-buffer)))
              ;; a global variable
              (let ((g (drgnx-epoch 'drgnx-memo-test-g)))
                (let ((drgnx-memo-test-var 7)) (should (= g (drgnx-epoch 'drgnx-memo-test-g))))
                (should (= g (drgnx-epoch 'drgnx-memo-test-g))))
              ;; a per-buffer variable already local in the buffer: let and unlet
              (setq-local drgnx-memo-test-lvar 3)
              (let ((b (drgnx-epoch 'drgnx-memo-test-b here)))
                (let ((drgnx-memo-test-lvar 4)) (should (= 4 drgnx-memo-test-lvar)))
                (should (= b (drgnx-epoch 'drgnx-memo-test-b here))))
              ;; per-buffer variables NOT local in a buffer, bound to the value they have: Emacs reports these as a
              ;; `set' with WHERE nil; the epoch of neither buffer moves
              (dolist (buf (list here other))
                (with-current-buffer buf (kill-local-variable 'drgnx-memo-test-lvar)))
              (let ((b1 (drgnx-epoch 'drgnx-memo-test-b here)) (b2 (drgnx-epoch 'drgnx-memo-test-b other))
                    (l1 (drgnx-epoch 'drgnx-memo-test-look here)) (l2 (drgnx-epoch 'drgnx-memo-test-look other)))
                (dolist (buf (list here other))
                  (with-current-buffer buf
                    (let ((drgnx-memo-test-lvar (default-value 'drgnx-memo-test-lvar))) nil)
                    (let ((tab-width tab-width)) nil)
                    (let ((indent-tabs-mode indent-tabs-mode)) nil)))
                (should (= b1 (drgnx-epoch 'drgnx-memo-test-b here)))
                (should (= b2 (drgnx-epoch 'drgnx-memo-test-b other)))
                (should (= l1 (drgnx-epoch 'drgnx-memo-test-look here)))
                (should (= l2 (drgnx-epoch 'drgnx-memo-test-look other)))
                ;; a real change still moves it: a local set only that buffer, the default every buffer
                (with-current-buffer here (setq-local tab-width (+ 3 tab-width)))
                (should (= (1+ l1) (drgnx-epoch 'drgnx-memo-test-look here)))
                (should (= l2 (drgnx-epoch 'drgnx-memo-test-look other))))))
        (kill-buffer other)))))

(ert-deftest drgnx-memo/defvaralias-bumps ()
  (drgnx-memo-test--active '(drgnx-memo-test-al)
    (let ((v (drgnx-epoch 'drgnx-memo-test-al)))
      (defvaralias 'drgnx-memo-test-av 'drgnx-memo-test-base)
      (should (= (1+ v) (drgnx-epoch 'drgnx-memo-test-al))))))

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

(ert-deftest drgnx-memo/cache-keys-lists-the-keys-without-stamping ()
  (drgnx-memo-test--with-cache 'drgnx-memo-test-s (list :key 'string :cap 3)
    (should-not (drgnx-cache-keys 'drgnx-memo-test-s))
    (dolist (k '("a" "b" "c")) (drgnx-cache-put 'drgnx-memo-test-s k k))
    (should (equal '("a" "b" "c") (sort (drgnx-cache-keys 'drgnx-memo-test-s) #'string<)))
    (drgnx-cache-put 'drgnx-memo-test-s "d" "d")                       ; "a" is still the oldest: listing stamped nothing
    (should (equal '("b" "c" "d") (sort (drgnx-cache-keys 'drgnx-memo-test-s) #'string<)))))

(ert-deftest drgnx-memo/a-peek-reads-without-stamping ()
  (drgnx-memo-test--with-cache 'drgnx-memo-test-s (list :key 'string :cap 3)
    (dolist (k '("a" "b" "c")) (drgnx-cache-put 'drgnx-memo-test-s k k))
    (should (equal "a" (drgnx-cache-peek 'drgnx-memo-test-s "a")))
    (should-not (drgnx-cache-peek 'drgnx-memo-test-s "z"))
    (drgnx-cache-put 'drgnx-memo-test-s "d" "d")                       ; "a" is still the oldest: the peek stamped nothing
    (should-not (drgnx-cache-peek 'drgnx-memo-test-s "a"))
    (should (equal "b" (drgnx-cache-peek 'drgnx-memo-test-s "b")))))

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

(ert-deftest drgnx-memo/a-module-turned-off-leaves-no-watcher-and-no-contents ()
  (drgnx-memo-forget 'drgnx-memo-test-a)
  (let ((obj (cons 1 2)) (labels '("cache drgnx-memo-test-own-cache" "memo drgnx-memo-test-a" "epoch drgnx-memo-test-own")))
    (drgnx-memo-test--with-module
        (list :setup (lambda ()
                       (drgnx-memo-activate 'drgnx-memo-test-own 'drgnx-memo-test-a 'drgnx-memo-test-own-cache)))
      (dotimes (round 2)                                       ; on, off, and on again
        (let ((v (drgnx-epoch 'drgnx-memo-test-own)))
          (should-not (memq #'drgnx-memo--watcher (get-variable-watchers 'drgnx-memo-test-ownvar)))
          (drgnx-memo-test--on)
          (should (equal labels (mapcar #'car (alist-get 'test/a drgnx-modules--stacks))))
          (should (memq #'drgnx-memo--watcher (get-variable-watchers 'drgnx-memo-test-ownvar)))
          (should (assq 'drgnx-memo-test-ownvar drgnx-memo--watched))   ; what the fingerprint reads
          (setq drgnx-memo-test-ownvar (+ 10 round))               ; a different value each round: a change
          (should (= (1+ v) (drgnx-epoch 'drgnx-memo-test-own)))
          (should (equal '(a) (drgnx-memo drgnx-memo-test-a obj (list 'a))))
          (drgnx-cache-put 'drgnx-memo-test-own-cache "k" 1)
          (should (= 1 (drgnx-memo-test--size 'drgnx-memo-test-a)))
          (should-not (drgnx-module-teardown 'test/a))
          (should-not (memq #'drgnx-memo--watcher (get-variable-watchers 'drgnx-memo-test-ownvar)))
          (should-not (assq 'drgnx-memo-test-ownvar drgnx-memo--watched))
          (should-not (assq 'drgnx-memo-test-own drgnx-memo--active))
          (setq drgnx-memo-test-ownvar 99)                        ; no longer watched
          (should (= (1+ v) (drgnx-epoch 'drgnx-memo-test-own)))
          (should (= 0 (drgnx-memo-test--size 'drgnx-memo-test-a)))
          (should (= 0 (drgnx-cache-size 'drgnx-memo-test-own-cache)))
          (should (equal '(b) (drgnx-memo drgnx-memo-test-a obj (list 'b))))   ; built again
          (drgnx-memo-forget 'drgnx-memo-test-a))))))

(ert-deftest drgnx-memo/an-epoch-two-activations-hold-until-the-last-is-off ()
  (drgnx-memo-test--with-module
      (list :setup (lambda () (drgnx-memo-activate 'drgnx-memo-test-own) (drgnx-memo-activate 'drgnx-memo-test-own)))
    (drgnx-memo-test--on)
    (should (= 2 (cdr (assq 'drgnx-memo-test-own drgnx-memo--active))))
    (should-not (drgnx-module-teardown 'test/a))
    (should-not (get-variable-watchers 'drgnx-memo-test-ownvar))
    (should-not drgnx-memo--active)))

(ert-deftest drgnx-memo/activating-what-is-not-declared-signals ()
  (should-error (drgnx-memo-activate 'drgnx-memo-test-nothing-declared)))

(ert-deftest drgnx-memo/definitions-are-declarations-not-owned ()
  (drgnx-memo-test--with-module
      (list :setup (lambda ()
                     (drgnx-epoch-define 'drgnx-memo-test-decl :per 'buffer)
                     (drgnx-cache-define 'drgnx-memo-test-decl-cache :key 'string :cap 2)))
    (drgnx-memo-test--on)
    (unwind-protect
        (progn (should-not (alist-get 'test/a drgnx-modules--stacks))   ; nothing recorded
               (should-not (drgnx-module-teardown 'test/a))
               (should (get 'drgnx-memo-test-decl 'drgnx-epoch--def))     ; and still declared
               (should (gethash "cache drgnx-memo-test-decl-cache" drgnx-memo--registry)))
      (drgnx-memo--undefine (get 'drgnx-memo-test-decl 'drgnx-epoch--def))
      (drgnx-memo--undefine (get 'drgnx-memo-test-decl-cache 'drgnx-cache--def)))))

(ert-deftest drgnx-memo/the-live-watches-join-the-fingerprint ()
  (should (memq 'drgnx-memo--watched drgnx-modules-fingerprint-registries))
  (should-not (memq 'drgnx-memo--registry drgnx-modules-fingerprint-registries)))

;;; core-memo-test.el ends here
