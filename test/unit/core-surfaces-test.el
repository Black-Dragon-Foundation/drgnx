;;; core-surfaces-test.el --- batch tests: surfaces generated from the registry -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-file)
(require 'drgnx-surfaces)
(require 'drgnx-modules)
(require 'drgnx-modules-helpers)

(defun drgnx-test--surf-cmd () (interactive) (setq drgnx-test--ran t))
(defvar drgnx-test--ran nil)
(defvar drgnx-test-surf-map (make-sparse-keymap))

(defmacro drgnx-test--with-commands (&rest body)
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-surfaces-contexts nil))
     (drgnx-command-define 'b-cmd :title "Beta" :category "Zed" :command #'drgnx-test--surf-cmd
                           :map 'drgnx-test-surf-map :menu '("Tools" "Test") :doc "Beta does b")
     (drgnx-command-define 'a-cmd :title "Alpha" :category "Able" :command #'drgnx-test--surf-cmd
                           :context 'always :doc "Alpha | pipes")
     (drgnx-command-define 'gone :title "Gone" :category "Able" :command 'drgnx-test--missing)
     (drgnx-surfaces-define-context 'always (lambda (_) t))
     ;; Keys come from profiles (drgnx-keys); here they are set directly.
     (setf (drgnx-cmd-bound (drgnx-commands-get 'b-cmd)) (list (cons "C-c b" 'drgnx-test-surf-map)))
     (setf (drgnx-cmd-bound (drgnx-commands-get 'a-cmd)) (list (cons "<f19>" nil) (cons "C-c a" nil)))
     ,@body))

(ert-deftest drgnx-surfaces/the-export-is-atomic ()
  (drgnx-test--with-commands
   (let* ((dir (file-name-as-directory (make-temp-file "drgnx-export" t)))
          (file (concat dir "sub/keys.md"))
          (calls nil) (orig (symbol-function 'drgnx-file-write-text)))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'drgnx-file-write-text)
                      (lambda (f text &rest args) (push f calls) (apply orig f text args))))
             (should (equal (drgnx-surfaces-export-markdown file) file)))
           (should (equal calls (list file)))
           (should (string-search "Alpha" (with-temp-buffer (insert-file-contents file) (buffer-string))))
           (should (= (file-modes file) #o644))
           ;; a write that fails halfway leaves the old file whole and no temp file behind
           (with-temp-file file (insert "OLD\n"))
           (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "disk full"))))
             (should-error (drgnx-surfaces-export-markdown file)))
           (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "OLD\n"))
           (should (equal (directory-files (file-name-directory file) nil "\\`[^.]\\|\\`\\.[^.]") '("keys.md")))
           ;; an open stale buffer of FILE does not make the export ask anything
           (let ((buf (find-file-noselect file)) (inhibit-interaction t))
             (unwind-protect
                 (progn (with-current-buffer buf (insert "edit"))
                        (drgnx-surfaces-export-markdown file))
               (with-current-buffer buf (set-buffer-modified-p nil))
               (kill-buffer buf)))
           (should (string-search "Alpha" (with-temp-buffer (insert-file-contents file) (buffer-string)))))
       (delete-directory dir t)))))


(ert-deftest drgnx-surfaces/key-display ()
  (drgnx-test--with-commands
   (should (equal (drgnx-surfaces-key (drgnx-commands-get 'b-cmd)) "C-c b (in drgnx-test-surf)"))
   (should (equal (drgnx-surfaces-key (drgnx-commands-get 'a-cmd)) "<f19>"))))

(ert-deftest drgnx-surfaces/sheet-rows-sorted-and-available-only ()
  (drgnx-test--with-commands
   (should (equal (mapcar (lambda (r) (nth 2 r)) (drgnx-surfaces-sheet-rows)) '("Alpha" "Beta")))))

(ert-deftest drgnx-surfaces/markdown-escapes-pipes ()
  (drgnx-test--with-commands
   (let ((md (drgnx-surfaces-markdown)))
     (should (string-search "| `<f19>` | Alpha |" md))
     (should (string-search "Alpha \\| pipes" md)))))

(ert-deftest drgnx-surfaces/context-menu-adds-active-entries ()
  (drgnx-test--with-commands
   (let ((menu (drgnx-surfaces-context-menu (make-sparse-keymap) nil)))
     (should (lookup-key menu [a-cmd]))
     (should-not (lookup-key menu [b-cmd])))))

(ert-deftest drgnx-surfaces/run-and-tip ()
  ;; (Batch Emacs has no echo area, so the tip is checked through its return value.)
  (drgnx-test--with-commands
   (setq drgnx-test--ran nil)
   (let ((drgnx-surfaces-run-functions nil))   ; not the usage counter
     (drgnx-surfaces-run 'a-cmd))
   (should drgnx-test--ran)
   (should (string-search "Able: Alpha — next time: <f19>" (drgnx-surfaces-tip (drgnx-commands-get 'a-cmd))))))

(ert-deftest drgnx-surfaces/unbound-commands-show-no-key ()
  (drgnx-test--with-commands
   (drgnx-command-define 'free :title "Free" :category "Able" :command #'drgnx-test--surf-cmd)
   (should (equal (drgnx-surfaces-key (drgnx-commands-get 'free)) ""))
   (should (string-search "|  | Free |" (drgnx-surfaces-markdown)))))

(ert-deftest drgnx-surfaces/a-key-event-is-not-a-click ()
  ;; C-h m describes context-menu-mode-map, which runs the menu's filter with the last key as the
  ;; "click": point and the current buffer must stay (it errored in the buffer of the selected window).
  (with-temp-buffer
    (insert "some text")
    (let ((here (current-buffer)) (pt (point)))
      (drgnx-surfaces-context-menu (make-sparse-keymap) 'f11)
      (should (eq (current-buffer) here))
      (should (= (point) pt)))))

;;;; Undefining contexts and menu items, and a module's teardown

(defmacro drgnx-surfaces-test--with-modules (&rest body)
  "BODY with a fresh registry, contexts, menu records, module state and cleanup stacks."
  `(let* ((cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-surfaces-contexts nil) (drgnx-surfaces--menu-items (make-hash-table :test #'eq))
          (drgnx-surfaces--menu-created nil) (drgnx-module--claims (make-hash-table :test 'equal))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-modules--stacks nil))
     (unwind-protect (progn ,@body) (delete-directory cfg t))))

(ert-deftest drgnx-surfaces/undefine-context ()
  (drgnx-test--with-commands
   (should (eq (drgnx-surfaces-undefine-context 'always) 'always))
   (should-not (assq 'always drgnx-surfaces-contexts))
   (should-not (drgnx-surfaces-undefine-context 'always))
   (let ((menu (drgnx-surfaces-context-menu (make-sparse-keymap) nil)))   ; the command naming it no longer shows
     (should-not (lookup-key menu [a-cmd])))))

(ert-deftest drgnx-surfaces/a-module-context-goes-with-the-module ()
  (drgnx-surfaces-test--with-modules
   (drgnx-surfaces-define-context 'code (lambda (_) 'core))
   (let ((core (alist-get 'code drgnx-surfaces-contexts)))
     (drgnx-module-define 'test/a :doc "a"
                          :setup (lambda ()
                                   (drgnx-surfaces-define-context 'extra (lambda (_) t))
                                   (drgnx-surfaces-define-context 'code (lambda (_) 'module))))
     (drgnx-modules-run 'startup)
     (should (assq 'extra drgnx-surfaces-contexts))
     (should (eq (funcall (alist-get 'code drgnx-surfaces-contexts) nil) 'module))
     (drgnx-module-teardown 'test/a)
     (should-not (assq 'extra drgnx-surfaces-contexts))
     (should (eq (alist-get 'code drgnx-surfaces-contexts) core)))))

(ert-deftest drgnx-surfaces/a-context-changed-since-is-kept ()
  (drgnx-surfaces-test--with-modules
   (drgnx-module-define 'test/a :doc "a" :setup (lambda () (drgnx-surfaces-define-context 'extra (lambda (_) 'module))))
   (drgnx-modules-run 'startup)
   (drgnx-surfaces-define-context 'extra (lambda (_) 'user))     ; outside a setup
   (drgnx-module-teardown 'test/a)
   (should (eq (funcall (alist-get 'extra drgnx-surfaces-contexts) nil) 'user))))

(ert-deftest drgnx-surfaces/a-library-loaded-by-a-setup-keeps-its-contexts ()
  (drgnx-surfaces-test--with-modules
   (let ((lib (make-temp-file "drgnx-lib" nil ".el" "(drgnx-surfaces-define-context 'lib (lambda (_) t))\n")))
     (unwind-protect
         (progn (drgnx-module-define 'test/a :doc "a" :setup (lambda () (load lib nil t)))
                (drgnx-modules-run 'startup)
                (drgnx-module-teardown 'test/a)
                (should (assq 'lib drgnx-surfaces-contexts)))
       (delete-file lib)))))

(defun drgnx-surfaces-test--menu-bar () (copy-tree (lookup-key global-map [menu-bar])))

(defun drgnx-surfaces-test--menu-def (id title menu)
  (lambda () (drgnx-command-define id :title title :category "Test" :command #'drgnx-test--surf-cmd :menu menu)))

(ert-deftest drgnx-surfaces/teardown-leaves-the-menu-bar-as-it-was ()
  (drgnx-surfaces-test--with-modules
   ;; A foreign item the module's entry will replace, and one in a menu the module's entries create.
   (easy-menu-add-item (lookup-key global-map [menu-bar]) '("Tools") (vector "Replaced" #'ignore))
   (let ((before (drgnx-surfaces-test--menu-bar)))
     (unwind-protect
         (progn
           (drgnx-module-define
            'test/a :doc "a"
            :setup (lambda ()
                     (funcall (drgnx-surfaces-test--menu-def 'm1 "Replaced" '("Tools")))
                     (funcall (drgnx-surfaces-test--menu-def 'm2 "Nested" '("Tools" "Drgnx Test Sub")))
                     (funcall (drgnx-surfaces-test--menu-def 'm3 "Deep" '("Drgnx Test Top" "Level")))))
           (drgnx-modules-run 'startup)
           (drgnx-surfaces-build-menus)
           (should-not (equal (drgnx-surfaces-test--menu-bar) before))
           (should (easy-menu-item-present-p (lookup-key global-map [menu-bar]) '("Drgnx Test Top" "Level") "Deep"))
           (drgnx-surfaces-build-menus)                        ; idempotent: nothing doubles
           (drgnx-module-teardown 'test/a)
           (drgnx-surfaces-build-menus)
           (should (equal (drgnx-surfaces-test--menu-bar) before))
           (should (zerop (hash-table-count drgnx-surfaces--menu-items))))
       (easy-menu-remove-item (lookup-key global-map [menu-bar]) '("Tools") "Replaced")))))

(ert-deftest drgnx-surfaces/another-modules-menu-item-stays ()
  (drgnx-surfaces-test--with-modules
   (let ((bar (lookup-key global-map [menu-bar])))
     (drgnx-module-define 'test/a :doc "a" :setup (drgnx-surfaces-test--menu-def 'm1 "One" '("Drgnx Test Top")))
     (drgnx-module-define 'test/b :doc "b" :setup (drgnx-surfaces-test--menu-def 'm2 "Two" '("Drgnx Test Top")))
     (drgnx-modules-run 'startup)
     (drgnx-surfaces-build-menus)
     (drgnx-module-teardown 'test/a)
     (drgnx-surfaces-build-menus)
     (should-not (easy-menu-item-present-p bar '("Drgnx Test Top") "One"))
     (should (easy-menu-item-present-p bar '("Drgnx Test Top") "Two"))
     (drgnx-module-teardown 'test/b)
     (drgnx-surfaces-build-menus)
     ;; (`easy-menu-item-present-p' would make the missing submenu, so look the plain way.)
     (should-not (lookup-key global-map [menu-bar Drgnx\ Test\ Top])))))

(ert-deftest drgnx-surfaces/a-menu-item-replaced-by-someone-else-is-kept ()
  (drgnx-surfaces-test--with-modules
   (drgnx-module-define 'test/a :doc "a" :setup (drgnx-surfaces-test--menu-def 'm1 "Mine" '("Drgnx Test Top")))
   (drgnx-modules-run 'startup)
   (drgnx-surfaces-build-menus)
   (easy-menu-add-item (lookup-key global-map [menu-bar]) '("Drgnx Test Top") (vector "Mine" #'ignore))
   (drgnx-module-teardown 'test/a)
   (drgnx-surfaces-build-menus)
   (should (easy-menu-item-present-p (lookup-key global-map [menu-bar]) '("Drgnx Test Top") "Mine"))
   (easy-menu-remove-item (lookup-key global-map [menu-bar]) nil "Drgnx Test Top")))

(defun drgnx-surfaces-test--titles (path)
  "The titles of the items in the submenu PATH of the menu bar, in order."
  (let (out)
    (map-keymap (lambda (_ item) (when (eq (car-safe item) 'menu-item) (push (nth 1 item) out)))
                (drgnx-surfaces--menu-submenu (lookup-key global-map [menu-bar]) path))
    (nreverse out)))

(ert-deftest drgnx-surfaces/an-untouched-menu-item-keeps-its-place ()
  ;; Alpha, Beta, then an item someone else added: removing Alpha must not move Beta behind it.
  (drgnx-surfaces-test--with-modules
   (let ((bar (lookup-key global-map [menu-bar])))
     (funcall (drgnx-surfaces-test--menu-def 'a1 "Alpha" '("Drgnx Test Top")))
     (funcall (drgnx-surfaces-test--menu-def 'b1 "Beta" '("Drgnx Test Top")))
     (drgnx-surfaces-build-menus)
     (easy-menu-add-item bar '("Drgnx Test Top") (vector "Foreign" #'ignore))
     (should (equal (drgnx-surfaces-test--titles '("Drgnx Test Top")) '("Alpha" "Beta" "Foreign")))
     (drgnx-command-undefine 'a1)
     (drgnx-surfaces-build-menus)
     (should (equal (drgnx-surfaces-test--titles '("Drgnx Test Top")) '("Beta" "Foreign")))
     (drgnx-command-undefine 'b1)
     (drgnx-surfaces-build-menus)
     (should (equal (drgnx-surfaces-test--titles '("Drgnx Test Top")) '("Foreign")))
     (easy-menu-remove-item bar nil "Drgnx Test Top"))))

(ert-deftest drgnx-surfaces/two-commands-sharing-a-title-go-in-either-order ()
  (dolist (order '((test/a test/b) (test/b test/a)))
    (drgnx-surfaces-test--with-modules
     (easy-menu-add-item (lookup-key global-map [menu-bar]) '("Tools") (vector "Same" #'ignore))
     (let ((before (drgnx-surfaces-test--menu-bar)))
       (unwind-protect
           (progn
             (drgnx-module-define 'test/a :doc "a" :setup (drgnx-surfaces-test--menu-def 'm1 "Same" '("Tools")))
             (drgnx-module-define 'test/b :doc "b" :setup (drgnx-surfaces-test--menu-def 'm2 "Same" '("Tools")))
             (drgnx-modules-run 'startup)
             (drgnx-surfaces-build-menus)
             (drgnx-module-teardown (car order))
             (drgnx-surfaces-build-menus)
             ;; The other command's entry is still there under the shared title.
             (should (member "Same" (drgnx-surfaces-test--titles '("Tools"))))
             (drgnx-module-teardown (cadr order))
             (drgnx-surfaces-build-menus)
             (should (equal (drgnx-surfaces-test--menu-bar) before)))
         (easy-menu-remove-item (lookup-key global-map [menu-bar]) '("Tools") "Same"))))))

(ert-deftest drgnx-surfaces/two-modules-one-context-go-in-either-order ()
  (dolist (order '((test/a test/b) (test/b test/a)))
    (drgnx-surfaces-test--with-modules
     (drgnx-surfaces-define-context 'shared (lambda (_) 'core))
     (let ((core (alist-get 'shared drgnx-surfaces-contexts)))
       (drgnx-module-define 'test/a :doc "a" :setup (lambda () (drgnx-surfaces-define-context 'shared (lambda (_) 'a))))
       (drgnx-module-define 'test/b :doc "b" :setup (lambda () (drgnx-surfaces-define-context 'shared (lambda (_) 'b))))
       (drgnx-modules-run 'startup)
       (should (eq (funcall (alist-get 'shared drgnx-surfaces-contexts) nil) 'b))
       (drgnx-module-teardown (car order))
       (drgnx-module-teardown (cadr order))
       (should (eq (alist-get 'shared drgnx-surfaces-contexts) core))))))

(ert-deftest drgnx-surfaces/a-context-only-modules-defined-goes-in-either-order ()
  ;; Neither module's predicate may outlive both teardowns, even when both pass the same function.
  (dolist (order '((test/a test/b) (test/b test/a)))
    (drgnx-surfaces-test--with-modules
     (drgnx-module-define 'test/a :doc "a" :setup (lambda () (drgnx-surfaces-define-context 'extra #'ignore)))
     (drgnx-module-define 'test/b :doc "b" :setup (lambda () (drgnx-surfaces-define-context 'extra #'ignore)))
     (drgnx-modules-run 'startup)
     (drgnx-module-teardown (car order))
     (drgnx-module-teardown (cadr order))
     (should-not (assq 'extra drgnx-surfaces-contexts)))))

(ert-deftest drgnx-surfaces/a-user-context-over-two-modules-is-kept ()
  (drgnx-surfaces-test--with-modules
   (drgnx-module-define 'test/a :doc "a" :setup (lambda () (drgnx-surfaces-define-context 'extra (lambda (_) 'a))))
   (drgnx-module-define 'test/b :doc "b" :setup (lambda () (drgnx-surfaces-define-context 'extra (lambda (_) 'b))))
   (drgnx-modules-run 'startup)
   (drgnx-surfaces-define-context 'extra (lambda (_) 'user))     ; outside a setup
   (drgnx-module-teardown 'test/a)
   (drgnx-module-teardown 'test/b)
   (should (eq (funcall (alist-get 'extra drgnx-surfaces-contexts) nil) 'user))))

;;;; One key label (notices plan Task 3)

(ert-deftest drgnx-surfaces/key-label-contexts ()
  ;; nil is the frame's form, `menu' the form that is right in every buffer, `plain' the key as written
  (drgnx-test--with-commands
   (cl-letf (((symbol-function 'drgnx-surfaces--here) (lambda (key) (concat "here:" key)))
             ((symbol-function 'drgnx-surfaces--always) (lambda (key) (concat "always:" key))))
     (let ((cmd (drgnx-commands-get 'b-cmd)))
       (should (equal (drgnx-surfaces-key-label cmd) "here:C-c b (in drgnx-test-surf)"))
       (should (equal (drgnx-surfaces-key-label cmd :context 'menu) "always:C-c b (in drgnx-test-surf)"))
       (should (equal (drgnx-surfaces-key-label cmd :context 'plain) "C-c b (in drgnx-test-surf)"))
       (should (equal (drgnx-surfaces-key-label 'b-cmd :context 'plain) "C-c b (in drgnx-test-surf)"))))))

(ert-deftest drgnx-surfaces/key-label-rewrites-once ()
  ;; a terminal's key is rewritten once per label, whichever way the label is asked for
  (drgnx-test--with-commands
   (drgnx-command-define 'stock :title "Stock" :category "Able" :command #'save-buffer)
   (let ((calls 0))
     (cl-letf (((symbol-function 'drgnx-tty-sendable-key) (lambda (_frame key) (setq calls (1+ calls)) key)))
       (dolist (args '((b-cmd) (a-cmd :any t) (stock :any t) (stock :any t :short t) (b-cmd :short t :any t)))
         (setq calls 0)
         (should (apply #'drgnx-surfaces-key-label args))
         (should (= calls 1)))
       (setq calls 0)
       (drgnx-surfaces-key-label 'b-cmd :context 'plain)
       (should (= calls 0))))))

(ert-deftest drgnx-surfaces/key-label-any-falls-back ()
  (drgnx-test--with-commands
   (drgnx-command-define 'stock :title "Stock" :category "Able" :command #'save-buffer)
   (should-not (drgnx-surfaces-key-label 'stock))
   (should (equal (drgnx-surfaces-key-label 'stock :any t) (key-description (where-is-internal 'save-buffer nil t))))
   ;; a profile's key wins over the stock one
   (should (equal (drgnx-surfaces-key-label 'a-cmd :any t) "<f19>"))))

(ert-deftest drgnx-surfaces/key-label-short-drops-the-map ()
  (drgnx-test--with-commands
   (should (equal (drgnx-surfaces-key-label 'b-cmd) "C-c b (in drgnx-test-surf)"))
   (should (equal (drgnx-surfaces-key-label 'b-cmd :short t) "C-c b"))
   (should (equal (drgnx-surfaces-key-label 'a-cmd :short t) "<f19>"))))

(ert-deftest drgnx-surfaces/key-label-nil-without-a-key ()
  (drgnx-test--with-commands
   (drgnx-command-define 'free :title "Free" :category "Able" :command #'drgnx-test--surf-cmd)
   (should-not (drgnx-surfaces-key-label 'free))
   (should-not (drgnx-surfaces-key-label 'free :any t))
   (should-not (drgnx-surfaces-key-label 'no-such-command :any t))))

(ert-deftest drgnx-surfaces/key-is-a-wrapper ()
  ;; `drgnx-surfaces-key' is the label with "" for none, its PLAIN argument the label's context
  (drgnx-test--with-commands
   (drgnx-command-define 'free :title "Free" :category "Able" :command #'drgnx-test--surf-cmd)
   (cl-letf (((symbol-function 'drgnx-surfaces--here) (lambda (key) (concat "here:" key)))
             ((symbol-function 'drgnx-surfaces--always) (lambda (key) (concat "always:" key))))
     (dolist (context '(nil menu plain))
       (dolist (id '(b-cmd a-cmd free))
         (let ((cmd (drgnx-commands-get id)))
           (should (equal (drgnx-surfaces-key cmd context)
                          (or (drgnx-surfaces-key-label cmd :context context) ""))))))
     (should-not (fboundp 'drgnx-surfaces--any-key)))))

(ert-deftest drgnx-surfaces/starter-commands-are-one-list ()
  (should (equal (mapcar #'car drgnx-surfaces-starter-commands) '(go-quick-open palette keys-sheet)))
  (dolist (row drgnx-surfaces-starter-commands) (should (stringp (cadr row))))
  ;; the tip uses the same label: any key, without the keymap
  (drgnx-test--with-commands
   (should (string-search "next time: <f19>" (drgnx-surfaces-tip (drgnx-commands-get 'a-cmd))))
   (should (string-search "next time: C-c b" (drgnx-surfaces-tip (drgnx-commands-get 'b-cmd))))
   (should-not (string-search "(in " (drgnx-surfaces-tip (drgnx-commands-get 'b-cmd))))))
