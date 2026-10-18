;;; modules-helpers-test.el --- batch tests: options, alist keys, face specs, global-map remaps -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-modules)

(defvar drgnx-modules-helpers-test--opt 1 "A plain option.")
(defvar drgnx-modules-helpers-test--alist '((a . 1) (b . 2)) "An alist.")
(defvar drgnx-modules-helpers-test--log nil "What the custom setter was given, newest first.")
(defvar drgnx-modules-helpers-test--map (make-sparse-keymap) "A keymap the helpers bind in.")
(defvar drgnx-modules-helpers-test--parent (make-sparse-keymap) "The parent of the child map.")
(defvar drgnx-modules-helpers-test--child (make-sparse-keymap) "A map with a parent.")
(defvar drgnx-modules-helpers-test--unbound-opt)

(defcustom drgnx-modules-helpers-test--custom 10
  "An option with a setter."
  :type 'integer
  :set (lambda (sym val)
         (push val drgnx-modules-helpers-test--log)
         (set-default sym (* 2 val))))

(defmacro drgnx-modules-helpers-test--in-setup (&rest body)
  "BODY as the code of module test/h's running setup; the stack is fresh."
  `(let ((drgnx-modules--current 'test/h)
         (drgnx-modules--setup-load load-file-name)
         (drgnx-modules--stacks nil)
         (drgnx-module--claims (make-hash-table :test 'equal))
         (drgnx-module--releasers (make-hash-table :test 'equal)))
     ,@body))

(defmacro drgnx-modules-helpers-test--two-modules (&rest body)
  "BODY with fresh stacks and claims; run parts of it as a module with `--as'."
  `(let ((drgnx-modules--setup-load load-file-name)
         (drgnx-modules--stacks nil)
         (drgnx-module--claims (make-hash-table :test 'equal))
         (drgnx-module--releasers (make-hash-table :test 'equal)))
     ,@body))

(defmacro drgnx-modules-helpers-test--as (module &rest body)
  "BODY as the code of MODULE's running setup."
  (declare (indent 1))
  `(let ((drgnx-modules--current ,module)) ,@body))

(defun drgnx-modules-helpers-test--down (module)
  "Tear MODULE down: run its undos now; the problems must be nil."
  (should-not (drgnx-modules--unwind module)))

(defun drgnx-modules-helpers-test--undo ()
  "Run test/h's undos now; the problems must be nil."
  (should-not (drgnx-modules--unwind 'test/h)))

;;;; drgnx-module-set

(ert-deftest drgnx-module-set/set-and-undo ()
  (let ((drgnx-modules-helpers-test--opt 1))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-set 'drgnx-modules-helpers-test--opt 5)
     (should (= (default-value 'drgnx-modules-helpers-test--opt) 5))
     (should (= (length (alist-get 'test/h drgnx-modules--stacks)) 1))
     (drgnx-modules-helpers-test--undo)
     (should (= (default-value 'drgnx-modules-helpers-test--opt) 1)))))

(ert-deftest drgnx-module-set/outside-a-setup-sets-and-records-nothing ()
  (let ((drgnx-modules-helpers-test--opt 1) (drgnx-modules--stacks nil))
    (drgnx-module-set 'drgnx-modules-helpers-test--opt 7)
    (should (= (default-value 'drgnx-modules-helpers-test--opt) 7))
    (should-not drgnx-modules--stacks)))

(ert-deftest drgnx-module-set/leaves-a-value-the-user-changed ()
  (let ((drgnx-modules-helpers-test--opt 1))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-set 'drgnx-modules-helpers-test--opt 5)
     (set-default 'drgnx-modules-helpers-test--opt 99)
     (drgnx-modules-helpers-test--undo)
     (should (= (default-value 'drgnx-modules-helpers-test--opt) 99)))))

(ert-deftest drgnx-module-set/uses-the-custom-setter-both-ways ()
  (let ((drgnx-modules-helpers-test--custom 10) (drgnx-modules-helpers-test--log nil))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-set 'drgnx-modules-helpers-test--custom 4)
     (should (equal drgnx-modules-helpers-test--log '(4)))
     (should (= (default-value 'drgnx-modules-helpers-test--custom) 8))
     (drgnx-modules-helpers-test--undo)
     ;; the setter ran again with the old stored value (10), which it doubles
     (should (equal drgnx-modules-helpers-test--log '(10 4)))
     (should (= (default-value 'drgnx-modules-helpers-test--custom) 20)))))

(ert-deftest drgnx-module-set/an-unbound-option-is-unbound-again ()
  (makunbound 'drgnx-modules-helpers-test--unbound-opt)
  (drgnx-modules-helpers-test--in-setup
   (drgnx-module-set 'drgnx-modules-helpers-test--unbound-opt 3)
   (should (= (default-value 'drgnx-modules-helpers-test--unbound-opt) 3))
   (drgnx-modules-helpers-test--undo)
   (should-not (default-boundp 'drgnx-modules-helpers-test--unbound-opt))))

;;;; drgnx-module-alist-put

(ert-deftest drgnx-module-helpers/alist-put-adds-and-removes ()
  (let ((drgnx-modules-helpers-test--alist (list (cons 'a 1) (cons 'b 2))))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-alist-put 'drgnx-modules-helpers-test--alist 'c 3)
     (should (equal drgnx-modules-helpers-test--alist '((c . 3) (a . 1) (b . 2))))
     (drgnx-modules-helpers-test--undo)
     (should (equal drgnx-modules-helpers-test--alist '((a . 1) (b . 2)))))))

(ert-deftest drgnx-module-helpers/alist-put-restores-the-previous-value ()
  (let* ((drgnx-modules-helpers-test--alist (list (cons "x" 1) (cons "y" 2)))
         (before drgnx-modules-helpers-test--alist))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-alist-put 'drgnx-modules-helpers-test--alist "y" 20) ; a string key: compared with equal
     (should (equal drgnx-modules-helpers-test--alist '(("x" . 1) ("y" . 20))))
     (should (equal before '(("x" . 1) ("y" . 2))))                      ; the old list is never mutated
     (drgnx-modules-helpers-test--undo)
     (should (equal drgnx-modules-helpers-test--alist '(("x" . 1) ("y" . 2)))))))

(ert-deftest drgnx-module-helpers/alist-put-leaves-a-value-someone-else-set ()
  (let ((drgnx-modules-helpers-test--alist (list (cons 'a 1))))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-alist-put 'drgnx-modules-helpers-test--alist 'a 5)
     (drgnx-module-alist-put 'drgnx-modules-helpers-test--alist 'z 6)
     (setf (alist-get 'a drgnx-modules-helpers-test--alist) 77)
     (setq drgnx-modules-helpers-test--alist (assq-delete-all 'z drgnx-modules-helpers-test--alist))
     (drgnx-modules-helpers-test--undo)
     (should (equal drgnx-modules-helpers-test--alist '((a . 77)))))))

;;;; drgnx-module-face-spec

(defface drgnx-modules-helpers-test-face '((t :weight normal)) "A face the helper changes.")

(ert-deftest drgnx-module-helpers/face-spec-comes-back ()
  (let ((old (get 'drgnx-modules-helpers-test-face 'face-defface-spec))
        (new '((t :weight bold))))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-face-spec 'drgnx-modules-helpers-test-face new)
     (should (equal (get 'drgnx-modules-helpers-test-face 'face-defface-spec) new))
     (should (eq (face-attribute 'drgnx-modules-helpers-test-face :weight nil t) 'bold))
     (drgnx-modules-helpers-test--undo)
     (should (equal (get 'drgnx-modules-helpers-test-face 'face-defface-spec) old))
     (should (eq (face-attribute 'drgnx-modules-helpers-test-face :weight nil t) 'normal)))))

(ert-deftest drgnx-module-helpers/face-spec-a-theme-changed-stays ()
  (let ((new '((t :weight bold))) (theirs '((t :slant italic))))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-face-spec 'drgnx-modules-helpers-test-face new)
     (face-spec-set 'drgnx-modules-helpers-test-face theirs 'face-defface-spec)
     (drgnx-modules-helpers-test--undo)
     (should (equal (get 'drgnx-modules-helpers-test-face 'face-defface-spec) theirs)))
    (face-spec-set 'drgnx-modules-helpers-test-face '((t :weight normal)) 'face-defface-spec)))

;;;; drgnx-module-define-key

(ert-deftest drgnx-module-helpers/define-key-remap-comes-back ()
  (let ((drgnx-modules-helpers-test--map (make-sparse-keymap)))
    (define-key drgnx-modules-helpers-test--map [remap kill-line] #'ignore)
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-define-key 'drgnx-modules-helpers-test--map [remap kill-line] #'next-line)
     (drgnx-module-define-key 'drgnx-modules-helpers-test--map [remap yank] #'previous-line)
     (should (eq (lookup-key drgnx-modules-helpers-test--map [remap kill-line]) #'next-line))
     (drgnx-modules-helpers-test--undo)
     (should (eq (lookup-key drgnx-modules-helpers-test--map [remap kill-line]) #'ignore))
     (should-not (lookup-key drgnx-modules-helpers-test--map [remap yank]))
     ;; a key that had no binding has no entry left, not an explicit nil
     (should-not (assq 'yank (cdr (assq 'remap (cdr drgnx-modules-helpers-test--map))))))))

(ert-deftest drgnx-module-helpers/define-key-leaves-a-binding-someone-else-set ()
  (let ((drgnx-modules-helpers-test--map (make-sparse-keymap)))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-define-key 'drgnx-modules-helpers-test--map [remap kill-line] #'next-line)
     (define-key drgnx-modules-helpers-test--map [remap kill-line] #'previous-line)
     (drgnx-modules-helpers-test--undo)
     (should (eq (lookup-key drgnx-modules-helpers-test--map [remap kill-line]) #'previous-line)))))

(ert-deftest drgnx-module-helpers/define-key-keeps-the-keymap-object ()
  (let* ((drgnx-modules-helpers-test--map (make-sparse-keymap))
         (map drgnx-modules-helpers-test--map))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-define-key 'drgnx-modules-helpers-test--map [remap kill-line] #'next-line)
     (should (eq (symbol-value 'drgnx-modules-helpers-test--map) map))
     (should (eq (lookup-key map [remap kill-line]) #'next-line))
     (drgnx-modules-helpers-test--undo)
     (should (eq (symbol-value 'drgnx-modules-helpers-test--map) map)))))

(ert-deftest drgnx-module-helpers/define-key-does-not-copy-the-parents-binding ()
  (let ((drgnx-modules-helpers-test--parent (make-sparse-keymap))
        (drgnx-modules-helpers-test--child (make-sparse-keymap)))
    (define-key drgnx-modules-helpers-test--parent [remap kill-line] #'ignore)
    (set-keymap-parent drgnx-modules-helpers-test--child drgnx-modules-helpers-test--parent)
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-define-key 'drgnx-modules-helpers-test--child [remap kill-line] #'next-line)
     (drgnx-modules-helpers-test--undo)
     (should (eq (keymap-parent drgnx-modules-helpers-test--child) drgnx-modules-helpers-test--parent))
     (should-not (assq 'kill-line (cdr (assq 'remap (cdr drgnx-modules-helpers-test--child)))))
     (should (eq (lookup-key drgnx-modules-helpers-test--child [remap kill-line]) #'ignore)))))

(ert-deftest drgnx-module-helpers/define-key-mouse-and-chrome-events-are-allowed ()
  (let ((drgnx-modules-helpers-test--map (make-sparse-keymap)))
    (drgnx-modules-helpers-test--in-setup
     (dolist (key '([mouse-3] [C-down-mouse-1] [mode-line mouse-1] [header-line down-mouse-1]
                    [tab-bar mouse-1] [menu-bar tools] [remap menu-bar-open]))
       (drgnx-module-define-key 'drgnx-modules-helpers-test--map key #'ignore)
       (should (eq (lookup-key drgnx-modules-helpers-test--map key) #'ignore)))
     (drgnx-modules-helpers-test--undo)
     (dolist (key '([mouse-3] [C-down-mouse-1] [mode-line mouse-1] [header-line down-mouse-1]
                    [tab-bar mouse-1] [menu-bar tools] [remap menu-bar-open]))
       (should-not (lookup-key drgnx-modules-helpers-test--map key))))))

(ert-deftest drgnx-module-helpers/define-key-refuses-a-keyboard-key ()
  (let ((drgnx-modules-helpers-test--map (make-sparse-keymap)))
    (drgnx-modules-helpers-test--in-setup
     (dolist (key (list "\C-x\C-y" [?\C-c ?a] [f5] [C-return] [tab]))
       (should-error (drgnx-module-define-key 'drgnx-modules-helpers-test--map key #'ignore)))
     (should-not (cdr drgnx-modules-helpers-test--map))
     (should-not drgnx-modules--stacks))))

(ert-deftest drgnx-module-helpers/define-key-refuses-a-symbol-that-is-not-a-keymap ()
  (drgnx-modules-helpers-test--in-setup
   (should-error (drgnx-module-define-key 'drgnx-modules-helpers-test--opt [remap kill-line] #'ignore))
   (should-not drgnx-modules--stacks)))

;;;; Two modules, one target: teardown in either order

(ert-deftest drgnx-module-helpers/two-modules-set-either-order ()
  (dolist (order '((a b) (b a)))
    (let ((drgnx-modules-helpers-test--opt 0))
      (drgnx-modules-helpers-test--two-modules
       (drgnx-modules-helpers-test--as 'a (drgnx-module-set 'drgnx-modules-helpers-test--opt 1))
       (drgnx-modules-helpers-test--as 'b (drgnx-module-set 'drgnx-modules-helpers-test--opt 2))
       (drgnx-modules-helpers-test--down (car order))
       (should (= (default-value 'drgnx-modules-helpers-test--opt) (if (eq (car order) 'a) 2 1)))
       (drgnx-modules-helpers-test--down (cadr order))
       (should (= (default-value 'drgnx-modules-helpers-test--opt) 0))
       (should (zerop (hash-table-count drgnx-module--claims)))))))

(ert-deftest drgnx-module-helpers/two-modules-set-unbound-either-order ()
  (dolist (order '((a b) (b a)))
    (makunbound 'drgnx-modules-helpers-test--unbound-opt)
    (drgnx-modules-helpers-test--two-modules
     (drgnx-modules-helpers-test--as 'a (drgnx-module-set 'drgnx-modules-helpers-test--unbound-opt 1))
     (drgnx-modules-helpers-test--as 'b (drgnx-module-set 'drgnx-modules-helpers-test--unbound-opt 2))
     (mapc #'drgnx-modules-helpers-test--down order)
     (should-not (default-boundp 'drgnx-modules-helpers-test--unbound-opt)))))

(ert-deftest drgnx-module-helpers/two-modules-alist-put-either-order ()
  (dolist (order '((a b) (b a)))
    (dolist (existing '(nil t))
      (let* ((orig (if existing (list (cons 'k 0) (cons 'z 9)) (list (cons 'z 9))))
             (drgnx-modules-helpers-test--alist orig))
        (drgnx-modules-helpers-test--two-modules
         (drgnx-modules-helpers-test--as 'a (drgnx-module-alist-put 'drgnx-modules-helpers-test--alist 'k 1))
         (drgnx-modules-helpers-test--as 'b (drgnx-module-alist-put 'drgnx-modules-helpers-test--alist 'k 2))
         (drgnx-modules-helpers-test--down (car order))
         (should (= (alist-get 'k drgnx-modules-helpers-test--alist) (if (eq (car order) 'a) 2 1)))
         (drgnx-modules-helpers-test--down (cadr order))
         (should (equal drgnx-modules-helpers-test--alist (if existing '((k . 0) (z . 9)) '((z . 9)))))
         (should (zerop (hash-table-count drgnx-module--claims))))))))

(ert-deftest drgnx-module-helpers/two-modules-face-spec-either-order ()
  (dolist (order '((a b) (b a)))
    (let ((old (get 'drgnx-modules-helpers-test-face 'face-defface-spec)))
      (drgnx-modules-helpers-test--two-modules
       (drgnx-modules-helpers-test--as 'a (drgnx-module-face-spec 'drgnx-modules-helpers-test-face '((t :weight bold))))
       (drgnx-modules-helpers-test--as 'b (drgnx-module-face-spec 'drgnx-modules-helpers-test-face '((t :slant italic))))
       (drgnx-modules-helpers-test--down (car order))
       (should (equal (get 'drgnx-modules-helpers-test-face 'face-defface-spec)
                      (if (eq (car order) 'a) '((t :slant italic)) '((t :weight bold)))))
       (drgnx-modules-helpers-test--down (cadr order))
       (should (equal (get 'drgnx-modules-helpers-test-face 'face-defface-spec) old))
       (should (zerop (hash-table-count drgnx-module--claims)))))))

(ert-deftest drgnx-module-helpers/two-modules-define-key-either-order ()
  (dolist (order '((a b) (b a)))
    (dolist (existing '(nil t))
      (let ((drgnx-modules-helpers-test--map (make-sparse-keymap)))
        (when existing (define-key drgnx-modules-helpers-test--map [remap foo] #'ignore))
        (drgnx-modules-helpers-test--two-modules
         (drgnx-modules-helpers-test--as 'a (drgnx-module-define-key 'drgnx-modules-helpers-test--map [remap foo] #'next-line))
         (drgnx-modules-helpers-test--as 'b (drgnx-module-define-key 'drgnx-modules-helpers-test--map [remap foo] #'previous-line))
         (drgnx-modules-helpers-test--down (car order))
         (should (eq (lookup-key drgnx-modules-helpers-test--map [remap foo])
                     (if (eq (car order) 'a) #'previous-line #'next-line)))
         (drgnx-modules-helpers-test--down (cadr order))
         (should (eq (lookup-key drgnx-modules-helpers-test--map [remap foo]) (and existing #'ignore)))
         (should (zerop (hash-table-count drgnx-module--claims))))))))

(ert-deftest drgnx-module-helpers/two-modules-user-change-survives-both-orders ()
  (dolist (order '((a b) (b a)))
    (let ((drgnx-modules-helpers-test--opt 0))
      (drgnx-modules-helpers-test--two-modules
       (drgnx-modules-helpers-test--as 'a (drgnx-module-set 'drgnx-modules-helpers-test--opt 1))
       (drgnx-modules-helpers-test--as 'b (drgnx-module-set 'drgnx-modules-helpers-test--opt 2))
       (set-default 'drgnx-modules-helpers-test--opt 99)
       (mapc #'drgnx-modules-helpers-test--down order)
       (should (= (default-value 'drgnx-modules-helpers-test--opt) 99))))))

;;;; Outside a setup, an unloaded alist, a custom setter, a customized face

(ert-deftest drgnx-module-helpers/outside-a-setup-claims-nothing ()
  (let ((drgnx-modules-helpers-test--opt 0) (drgnx-modules-helpers-test--alist nil)
        (drgnx-modules-helpers-test--map (make-sparse-keymap))
        (drgnx-module--claims (make-hash-table :test 'equal)))
    (drgnx-module-set 'drgnx-modules-helpers-test--opt 1)
    (drgnx-module-alist-put 'drgnx-modules-helpers-test--alist 'k 1)
    (drgnx-module-define-key 'drgnx-modules-helpers-test--map [remap foo] #'ignore)
    (should (zerop (hash-table-count drgnx-module--claims)))))

(defvar drgnx-modules-helpers-test--late-alist)

(ert-deftest drgnx-module-helpers/alist-put-on-an-alist-that-is-not-loaded-yet ()
  (makunbound 'drgnx-modules-helpers-test--late-alist)
  (drgnx-modules-helpers-test--in-setup
   (drgnx-module-alist-put 'drgnx-modules-helpers-test--late-alist 'k 1)
   (should (equal drgnx-modules-helpers-test--late-alist '((k . 1))))
   (drgnx-modules-helpers-test--undo)
   (should-not drgnx-modules-helpers-test--late-alist)))

(defcustom drgnx-modules-helpers-test--sorted-alist nil
  "An alist option whose setter sorts by key."
  :type 'sexp
  :set (lambda (sym val)
         (push val drgnx-modules-helpers-test--log)
         (set-default sym (sort (copy-sequence val) (lambda (x y) (string< (car x) (car y)))))))

(ert-deftest drgnx-module-helpers/alist-put-uses-the-custom-setter ()
  (let ((drgnx-modules-helpers-test--sorted-alist (list (cons "b" 1)))
        (drgnx-modules-helpers-test--log nil))
    (drgnx-modules-helpers-test--in-setup
     (drgnx-module-alist-put 'drgnx-modules-helpers-test--sorted-alist "a" 2)
     (should (equal drgnx-modules-helpers-test--sorted-alist '(("a" . 2) ("b" . 1))))
     (should (= (length drgnx-modules-helpers-test--log) 1))
     (drgnx-modules-helpers-test--undo)
     (should (= (length drgnx-modules-helpers-test--log) 2))
     (should (equal drgnx-modules-helpers-test--sorted-alist '(("b" . 1)))))))

(ert-deftest drgnx-module-helpers/face-spec-a-customized-spec-survives ()
  ;; A customized spec overrides the default one, so it keeps showing and is never rewritten.
  (let ((old (get 'drgnx-modules-helpers-test-face 'face-defface-spec)))
    (unwind-protect
        (progn
          (custom-set-faces '(drgnx-modules-helpers-test-face ((t :underline t))))
          (let ((theme-spec (get 'drgnx-modules-helpers-test-face 'theme-face)))
            (drgnx-modules-helpers-test--in-setup
             (drgnx-module-face-spec 'drgnx-modules-helpers-test-face '((t :weight bold)))
             (should (equal (get 'drgnx-modules-helpers-test-face 'theme-face) theme-spec))
             (should (face-attribute 'drgnx-modules-helpers-test-face :underline nil t))
             (drgnx-modules-helpers-test--undo)
             (should (equal (get 'drgnx-modules-helpers-test-face 'theme-face) theme-spec))
             (should (face-attribute 'drgnx-modules-helpers-test-face :underline nil t))
             (should (equal (get 'drgnx-modules-helpers-test-face 'face-defface-spec) old)))))
      (put 'drgnx-modules-helpers-test-face 'theme-face nil)
      (face-spec-set 'drgnx-modules-helpers-test-face old 'face-defface-spec))))

;;;; drgnx-module-hook, drgnx-module-advice

(defvar drgnx-modules-helpers-test--hook nil "A hook the paired helpers add to.")
(defvar drgnx-modules-helpers-test--hook2 nil "A second hook.")
(defvar drgnx-modules-helpers-test--seen nil "Values the hook watcher saw `drgnx-module--in-helper' have.")

(defun drgnx-modules-helpers-test--target (x) "A function to advise." (list 'target x))

(defun drgnx-modules-helpers-test--on-hook-p (fn &optional hook)
  (and (memq fn (default-value (or hook 'drgnx-modules-helpers-test--hook))) t))

(defmacro drgnx-modules-helpers-test--clean (&rest body)
  "BODY with the test hooks empty and the target unadvised, restored afterwards."
  `(let ((drgnx-modules-helpers-test--hook nil) (drgnx-modules-helpers-test--hook2 nil))
     (unwind-protect (progn ,@body)
       (advice-mapc (lambda (f _) (advice-remove 'drgnx-modules-helpers-test--target f))
                    'drgnx-modules-helpers-test--target))))

(ert-deftest drgnx-module-hook/defines-a-named-function-and-adds-it ()
  (drgnx-modules-helpers-test--clean
   (drgnx-modules-helpers-test--in-setup
    (drgnx-module-hook 'drgnx-modules-helpers-test--hook greet (x) :module test/h (list 'hi x))
    (should (fboundp 'drgnx-test/h--greet))
    (should (equal (drgnx-test/h--greet 1) '(hi 1)))
    (should (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--greet))
    (should (= (length (alist-get 'test/h drgnx-modules--stacks)) 1)))))

(ert-deftest drgnx-module-hook/teardown-removes-it ()
  (drgnx-modules-helpers-test--clean
   (drgnx-modules-helpers-test--in-setup
    (drgnx-module-hook 'drgnx-modules-helpers-test--hook greet () :module test/h nil)
    (drgnx-modules-helpers-test--undo)
    (should-not (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--greet))
    (should-not (alist-get 'test/h drgnx-modules--stacks))
    (should (zerop (hash-table-count drgnx-module--claims))))))

(ert-deftest drgnx-module-hook/unhook-removes-early ()
  (drgnx-modules-helpers-test--clean
   (drgnx-modules-helpers-test--in-setup
    (drgnx-module-hook 'drgnx-modules-helpers-test--hook greet () :module test/h nil)
    (drgnx-module-unhook 'drgnx-modules-helpers-test--hook greet :module test/h)
    (should-not (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--greet))
    (should (zerop (hash-table-count drgnx-module--claims)))
    ;; The teardown later is quiet and changes nothing.
    (add-hook 'drgnx-modules-helpers-test--hook 'ignore)
    (drgnx-modules-helpers-test--undo)
    (should (equal drgnx-modules-helpers-test--hook '(ignore))))))

(ert-deftest drgnx-module-hook/twice-is-once ()
  (drgnx-modules-helpers-test--clean
   (drgnx-modules-helpers-test--in-setup
    (dotimes (_ 2)
      (drgnx-module-hook 'drgnx-modules-helpers-test--hook greet () :module test/h nil))
    (should (= (length drgnx-modules-helpers-test--hook) 1))
    (drgnx-modules-helpers-test--undo)
    (should-not drgnx-modules-helpers-test--hook)
    (should (zerop (hash-table-count drgnx-module--claims))))))

(ert-deftest drgnx-module-hook/a-list-of-hooks ()
  (drgnx-modules-helpers-test--clean
   (drgnx-modules-helpers-test--in-setup
    (drgnx-module-hook '(drgnx-modules-helpers-test--hook drgnx-modules-helpers-test--hook2)
        greet () :module test/h nil)
    (should (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--greet))
    (should (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--greet 'drgnx-modules-helpers-test--hook2))
    (drgnx-module-unhook 'drgnx-modules-helpers-test--hook2 greet :module test/h)
    (should (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--greet))
    (should-not (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--greet 'drgnx-modules-helpers-test--hook2))
    (drgnx-modules-helpers-test--undo)
    (should-not drgnx-modules-helpers-test--hook)
    (should-not drgnx-modules-helpers-test--hook2))))

(ert-deftest drgnx-module-hook/depth-is-passed ()
  (drgnx-modules-helpers-test--clean
   (let ((drgnx-modules-helpers-test--hook '(ignore)))
     (drgnx-modules-helpers-test--in-setup
      (drgnx-module-hook 'drgnx-modules-helpers-test--hook greet () :depth 90 :module test/h nil)
      (should (equal drgnx-modules-helpers-test--hook '(ignore drgnx-test/h--greet)))
      (drgnx-modules-helpers-test--undo)
      (should (equal drgnx-modules-helpers-test--hook '(ignore)))))))

(ert-deftest drgnx-module-hook/keeps-what-was-already-there ()
  (drgnx-modules-helpers-test--clean
   (defun drgnx-test/h--greet () nil)
   (add-hook 'drgnx-modules-helpers-test--hook 'drgnx-test/h--greet)
   (drgnx-modules-helpers-test--in-setup
    (drgnx-module-hook 'drgnx-modules-helpers-test--hook greet () :module test/h nil)
    (drgnx-modules-helpers-test--undo)
    (should (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--greet)))))

(ert-deftest drgnx-module-hook/outside-a-setup-adds-and-records-nothing ()
  (drgnx-modules-helpers-test--clean
   (let ((drgnx-modules--stacks nil) (drgnx-module--claims (make-hash-table :test 'equal)))
     (drgnx-module-hook 'drgnx-modules-helpers-test--hook greet () :module test/h nil)
     (should (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--greet))
     (should-not drgnx-modules--stacks)
     (should (zerop (hash-table-count drgnx-module--claims)))
     (drgnx-module-unhook 'drgnx-modules-helpers-test--hook greet :module test/h)
     (should-not drgnx-modules-helpers-test--hook))))

(ert-deftest drgnx-module-hook/two-modules-one-function-either-order ()
  (dolist (order '((a b) (b a)))
    (drgnx-modules-helpers-test--clean
     (drgnx-modules-helpers-test--two-modules
      (dolist (m '(a b))
        (drgnx-modules-helpers-test--as m
          (drgnx-module-hook 'drgnx-modules-helpers-test--hook shared () :module test/h nil)))
      (should (= (length drgnx-modules-helpers-test--hook) 1))
      (drgnx-modules-helpers-test--down (car order))
      (should (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--shared))
      (drgnx-modules-helpers-test--down (cadr order))
      (should-not drgnx-modules-helpers-test--hook)
      (should (zerop (hash-table-count drgnx-module--claims)))))))

(ert-deftest drgnx-module-hook/unhook-by-one-module-leaves-the-other ()
  (drgnx-modules-helpers-test--clean
   (drgnx-modules-helpers-test--two-modules
    (dolist (m '(a b))
      (drgnx-modules-helpers-test--as m
        (drgnx-module-hook 'drgnx-modules-helpers-test--hook shared () :module test/h nil)))
    (drgnx-modules-helpers-test--as 'a
      (drgnx-module-unhook 'drgnx-modules-helpers-test--hook shared :module test/h))
    (should (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--shared))
    (drgnx-modules-helpers-test--down 'a)          ; its undo already ran: nothing left to do
    (should (drgnx-modules-helpers-test--on-hook-p 'drgnx-test/h--shared))
    (drgnx-modules-helpers-test--down 'b)
    (should-not drgnx-modules-helpers-test--hook))))

(ert-deftest drgnx-module-hook/the-recording-net-is-told-to-skip-the-helper ()
  ;; `drgnx-module--in-helper' is non-nil exactly while the helper itself calls add-hook/advice-add.
  (drgnx-modules-helpers-test--clean
   (let ((drgnx-modules-helpers-test--seen nil))
     (add-variable-watcher 'drgnx-modules-helpers-test--hook
                           (lambda (&rest _) (push drgnx-module--in-helper drgnx-modules-helpers-test--seen)))
     (unwind-protect
         (drgnx-modules-helpers-test--in-setup
          (drgnx-module-hook 'drgnx-modules-helpers-test--hook greet () :module test/h nil)
          (should (equal drgnx-modules-helpers-test--seen '(t)))
          (should-not drgnx-module--in-helper))
       (dolist (w (get-variable-watchers 'drgnx-modules-helpers-test--hook))
         (remove-variable-watcher 'drgnx-modules-helpers-test--hook w))))))

;; A module file for the lookup tests: CONTENT written to a temp file, then BODY with it as the file being loaded.
(defmacro drgnx-modules-helpers-test--in-file (content &rest body)
  (declare (indent 1))
  `(let ((file (make-temp-file "drgnx-hook-test" nil ".el" ,content)))
     (unwind-protect (let ((load-file-name file)) ,@body)
       (delete-file file))))

(defun drgnx-modules-helpers-test--expanded-name (&optional form)
  "The function name the hook macro defines for FORM, expanded in the file being loaded."
  (cadr (cadr (macroexpand (or form '(drgnx-module-hook 'h greet () nil))))))

(ert-deftest drgnx-module-hook/the-module-comes-from-the-files-module-define ()
  (drgnx-modules-helpers-test--in-file "(drgnx-module-define 'editor/zed\n :doc \"x\")\n"
    (should (equal (cadr (macroexpand '(drgnx-module-hook 'h greet () nil)))
                   '(defun drgnx-editor/zed--greet () nil)))))

(ert-deftest drgnx-module-hook/the-module-ignores-comments-and-strings ()
  (drgnx-modules-helpers-test--in-file
      ";; (drgnx-module-define 'wrong/commented\n(defvar x \"(drgnx-module-define 'wrong/string\")\n(drgnx-module-define (quote editor/zed) :doc \"x\")\n"
    (should (equal (cadr (macroexpand '(drgnx-module-hook 'h greet () nil)))
                   '(defun drgnx-editor/zed--greet () nil)))))

(ert-deftest drgnx-module-hook/no-module-is-an-error ()
  (drgnx-modules-helpers-test--in-file ";; no module here\n(message \"(drgnx-module-define 'x)\")\n"
    (let ((err (should-error (macroexpand '(drgnx-module-hook 'h greet () nil)) :type 'error)))
      (should (string-match-p "Cannot tell the module" (error-message-string err))))))

(ert-deftest drgnx-module-hook/a-renamed-module-is-seen-after-the-file-changes ()
  (drgnx-modules-helpers-test--in-file "(drgnx-module-define 'editor/one)\n"
    (should (eq (drgnx-modules-helpers-test--expanded-name) 'drgnx-editor/one--greet))
    (with-temp-file load-file-name (insert "(drgnx-module-define 'editor/two)\n"))
    (set-file-times load-file-name (time-add (current-time) 5))
    (should (eq (drgnx-modules-helpers-test--expanded-name) 'drgnx-editor/two--greet))))

(ert-deftest drgnx-module-hook/the-same-name-twice-in-a-module-is-an-error ()
  (drgnx-modules-helpers-test--in-file
      "(drgnx-module-define 'editor/zed)\n(defun setup () (drgnx-module-hook 'a greet () 1) (drgnx-module-advice 'f :around greet (o) 2))\n"
    (should (string-match-p "more than one"
                            (error-message-string
                             (should-error (macroexpand '(drgnx-module-hook 'a greet () 1)) :type 'error))))
    (should (string-match-p "more than one"
                            (error-message-string
                             (should-error (macroexpand '(drgnx-module-advice 'f :around greet (o) 2)) :type 'error))))))

(ert-deftest drgnx-module-hook/different-names-in-a-module-are-fine ()
  (drgnx-modules-helpers-test--in-file
      "(drgnx-module-define 'editor/zed)\n(defun setup () (drgnx-module-hook 'a one () 1) (drgnx-module-hook 'a two () 2))\n"
    (should (eq (drgnx-modules-helpers-test--expanded-name '(drgnx-module-hook 'a one () 1))
                'drgnx-editor/zed--one))))

(ert-deftest drgnx-module-hook/a-quoted-name-is-an-error ()
  (should-error (macroexpand '(drgnx-module-hook 'h 'greet () :module test/h nil)) :type 'error))

(ert-deftest drgnx-module-hook/unhook-at-runtime-after-the-setup ()
  (drgnx-modules-helpers-test--clean
   (drgnx-modules-helpers-test--in-setup
    (drgnx-module-hook 'drgnx-modules-helpers-test--hook greet () :module test/h nil)
    (let ((drgnx-modules--current nil))             ; the setup is over
      (drgnx-module-unhook 'drgnx-modules-helpers-test--hook greet :module test/h))
    (should-not drgnx-modules-helpers-test--hook)
    (should (zerop (hash-table-count drgnx-module--claims)))
    (drgnx-modules-helpers-test--undo)
    (should-not drgnx-modules-helpers-test--hook))))

(ert-deftest drgnx-module-advice/is-named-and-removed ()
  (drgnx-modules-helpers-test--clean
   (drgnx-modules-helpers-test--in-setup
    (drgnx-module-advice 'drgnx-modules-helpers-test--target :filter-return wrap (r)
      :module test/h (list 'wrapped r))
    (should (equal (drgnx-modules-helpers-test--target 1) '(wrapped (target 1))))
    (should (advice-member-p 'drgnx-test/h--wrap 'drgnx-modules-helpers-test--target))
    (drgnx-modules-helpers-test--undo)
    (should-not (advice-member-p 'drgnx-test/h--wrap 'drgnx-modules-helpers-test--target))
    (should (equal (drgnx-modules-helpers-test--target 1) '(target 1)))
    (should (zerop (hash-table-count drgnx-module--claims))))))

(ert-deftest drgnx-module-advice/two-modules-one-name-keep-both ()
  ;; The advice name is the generated function name, so equal NAMEs of two modules do not replace each other.
  (drgnx-modules-helpers-test--clean
   (drgnx-modules-helpers-test--two-modules
    (drgnx-modules-helpers-test--as 'a
      (drgnx-module-advice 'drgnx-modules-helpers-test--target :filter-return refresh (r)
        :module test/a (list 'a r)))
    (drgnx-modules-helpers-test--as 'b
      (drgnx-module-advice 'drgnx-modules-helpers-test--target :filter-return refresh (r)
        :module test/b (list 'b r)))
    (should (advice-member-p 'drgnx-test/a--refresh 'drgnx-modules-helpers-test--target))
    (should (advice-member-p 'drgnx-test/b--refresh 'drgnx-modules-helpers-test--target))
    (drgnx-modules-helpers-test--down 'a)
    (should-not (advice-member-p 'drgnx-test/a--refresh 'drgnx-modules-helpers-test--target))
    (should (advice-member-p 'drgnx-test/b--refresh 'drgnx-modules-helpers-test--target)))))

(ert-deftest drgnx-module-advice/depth-is-refused ()
  (should-error (macroexpand '(drgnx-module-advice 'f :around wrap (o) :depth 50 :module test/h nil))
                :type 'error))

(ert-deftest drgnx-module-advice/unadvise-removes-early-and-twice-is-once ()
  (drgnx-modules-helpers-test--clean
   (drgnx-modules-helpers-test--in-setup
    (dotimes (_ 2)
      (drgnx-module-advice 'drgnx-modules-helpers-test--target :filter-return wrap (r)
        :module test/h (list 'wrapped r)))
    (drgnx-module-unadvise 'drgnx-modules-helpers-test--target wrap :module test/h)
    (should-not (advice-member-p 'drgnx-test/h--wrap 'drgnx-modules-helpers-test--target))
    (drgnx-modules-helpers-test--undo)
    (should (equal (drgnx-modules-helpers-test--target 1) '(target 1))))))

(ert-deftest drgnx-module-advice/two-modules-one-advice-either-order ()
  (dolist (order '((a b) (b a)))
    (drgnx-modules-helpers-test--clean
     (drgnx-modules-helpers-test--two-modules
      (dolist (m '(a b))
        (drgnx-modules-helpers-test--as m
          (drgnx-module-advice 'drgnx-modules-helpers-test--target :filter-return shared (r)
            :module test/h (list 'wrapped r))))
      (drgnx-modules-helpers-test--down (car order))
      (should (advice-member-p 'drgnx-test/h--shared 'drgnx-modules-helpers-test--target))
      (should (equal (drgnx-modules-helpers-test--target 1) '(wrapped (target 1))))
      (drgnx-modules-helpers-test--down (cadr order))
      (should-not (advice-member-p 'drgnx-test/h--shared 'drgnx-modules-helpers-test--target))
      (should (zerop (hash-table-count drgnx-module--claims)))))))

(ert-deftest drgnx-module-advice/keeps-advice-that-was-already-there ()
  (drgnx-modules-helpers-test--clean
   (defun drgnx-test/h--wrap (r) (list 'wrapped r))
   (advice-add 'drgnx-modules-helpers-test--target :filter-return 'drgnx-test/h--wrap)
   (drgnx-modules-helpers-test--in-setup
    (drgnx-module-advice 'drgnx-modules-helpers-test--target :filter-return wrap (r)
      :module test/h (list 'wrapped r))
    (drgnx-modules-helpers-test--undo)
    (should (advice-member-p 'drgnx-test/h--wrap 'drgnx-modules-helpers-test--target)))))
