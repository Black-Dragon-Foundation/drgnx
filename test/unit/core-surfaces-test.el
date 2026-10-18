;;; core-surfaces-test.el --- batch tests: surfaces generated from the registry -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-surfaces)
(require 'drgnx-modules)

(defun drgnx-test--surf-cmd () (interactive) (setq drgnx-test--ran t))
(defvar drgnx-test--ran nil)
(defvar drgnx-test-surf-map (make-sparse-keymap))

(defmacro drgnx-test--with-commands (&rest body)
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-commands-problems nil) (drgnx-surfaces-contexts nil))
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
          (drgnx-commands-problems nil) (drgnx-surfaces-contexts nil) (drgnx-surfaces--menu-items nil)
          (drgnx-surfaces--menu-created nil)
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
           (should-not drgnx-surfaces--menu-items))
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
