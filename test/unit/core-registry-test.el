;;; core-registry-test.el --- batch tests: the command registry -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)

(defmacro drgnx-test--fresh-registry (&rest body)
  `(let ((drgnx-commands--table (make-hash-table :test #'eq))
         (drgnx-commands--order nil)
         (drgnx-commands-problems nil))
     ,@body))

(defun drgnx-test--cmd () (interactive))

(ert-deftest drgnx-registry/define-and-get ()
  (drgnx-test--fresh-registry
   (drgnx-command-define 'demo :title "Demo" :category "Test" :command #'drgnx-test--cmd)
   (should (equal (drgnx-commands-label (drgnx-commands-get 'demo)) "Test: Demo"))
   (should (equal (mapcar #'drgnx-cmd-id (drgnx-commands-all)) '(demo)))))

(ert-deftest drgnx-registry/requires-fields ()
  (drgnx-test--fresh-registry
   (should-error (drgnx-command-define 'bad :category "Test" :command #'drgnx-test--cmd))
   (should-error (drgnx-command-define 'bad2 :title "x" :category "Test"))))

(ert-deftest drgnx-registry/keys-come-from-profiles ()
  ;; Commands are registered without keys (docs/guide/keys.md); the old :key and :native say so.
  (drgnx-test--fresh-registry
   (should (string-search "profiles"
                          (cadr (should-error (drgnx-command-define 'k :title "K" :category "Test"
                                                                    :command #'drgnx-test--cmd :key "C-c t")))))
   (should-error (drgnx-command-define 'n :title "N" :category "Test" :native "C-a"))
   (drgnx-command-define 'k :title "K" :category "Test" :command #'drgnx-test--cmd)
   (should (null (drgnx-cmd-bound (drgnx-commands-get 'k))))))

(ert-deftest drgnx-registry/scope ()
  (drgnx-test--fresh-registry
   (drgnx-command-define 'a :title "A" :category "Test" :command #'drgnx-test--cmd)
   (drgnx-command-define 'e :title "E" :category "Test" :command #'drgnx-test--cmd :scope 'editing)
   (should (eq (drgnx-cmd-scope (drgnx-commands-get 'a)) 'app))
   (should (eq (drgnx-cmd-scope (drgnx-commands-get 'e)) 'editing))
   (should-error (drgnx-command-define 'x :title "X" :category "Test" :command #'drgnx-test--cmd :scope 'nowhere))))

(ert-deftest drgnx-registry/redefine-replaces ()
  (drgnx-test--fresh-registry
   (drgnx-command-define 'a :title "A" :category "Test" :command #'drgnx-test--cmd)
   (drgnx-command-define 'a :title "A2" :category "Test" :command #'drgnx-test--cmd)
   (should (= 1 (length (drgnx-commands-all))))
   (should (equal (drgnx-cmd-title (drgnx-commands-get 'a)) "A2"))))

(ert-deftest drgnx-registry/availability ()
  (drgnx-test--fresh-registry
   (drgnx-command-define 'ok :title "Ok" :category "Test" :command #'drgnx-test--cmd)
   (drgnx-command-define 'gone :title "Gone" :category "Test" :command 'drgnx-test--no-such-command)
   (drgnx-command-define 'off :title "Off" :category "Test" :command #'drgnx-test--cmd :when (lambda () nil))
   (should (drgnx-commands-available-p (drgnx-commands-get 'ok)))
   (should-not (drgnx-commands-available-p (drgnx-commands-get 'gone)))
   (should-not (drgnx-commands-available-p (drgnx-commands-get 'off)))))

;;;; Undefining, and a module's teardown

(defmacro drgnx-registry-test--with-modules (&rest body)
  "BODY with a fresh registry, fresh module state and cleanup stacks, and a temp config dir."
  `(drgnx-test--fresh-registry
    (let* ((cfg (make-temp-file "drgnx-cfg" t))
           (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
           (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
           (drgnx-modules--stacks nil))
      (unwind-protect (progn ,@body) (delete-directory cfg t)))))

(defun drgnx-registry-test--module (name &rest setup)
  "Define module NAME whose setup runs the forms SETUP."
  (drgnx-module-define name :doc "test" :setup (lambda () (mapc #'funcall setup))))

(defun drgnx-registry-test--def (id title)
  (lambda () (drgnx-command-define id :title title :category "Test" :command #'drgnx-test--cmd)))

(defun drgnx-registry-test--title (id) (drgnx-cmd-title (drgnx-commands-get id)))

(ert-deftest drgnx-registry/undefine-removes-from-table-and-order ()
  (drgnx-test--fresh-registry
   (dolist (id '(a b c))
     (drgnx-command-define id :title "T" :category "Test" :command #'drgnx-test--cmd))
   (should (eq (drgnx-command-undefine 'b) 'b))
   (should-not (drgnx-commands-get 'b))
   (should (equal (mapcar #'drgnx-cmd-id (drgnx-commands-all)) '(a c)))
   (should-not (drgnx-command-undefine 'b))            ; already gone: nothing, no error
   (drgnx-command-define 'b :title "T" :category "Test" :command #'drgnx-test--cmd)
   (should (equal (mapcar #'drgnx-cmd-id (drgnx-commands-all)) '(a c b)))))

(ert-deftest drgnx-registry/teardown-removes-what-the-module-defined ()
  (drgnx-registry-test--with-modules
   (funcall (drgnx-registry-test--def 'core "Core"))           ; outside any setup: stays
   (drgnx-registry-test--module 'test/a (drgnx-registry-test--def 'one "One") (drgnx-registry-test--def 'two "Two"))
   (drgnx-modules-run 'startup)
   (should (equal (mapcar #'drgnx-cmd-id (drgnx-commands-all)) '(core one two)))
   (should-not (drgnx-module-teardown 'test/a))
   (should (equal (mapcar #'drgnx-cmd-id (drgnx-commands-all)) '(core)))))

(ert-deftest drgnx-registry/undefine-restores-only-its-own ()
  (drgnx-registry-test--with-modules
   (funcall (drgnx-registry-test--def 'x "Core X"))
   (funcall (drgnx-registry-test--def 'y "Core Y"))
   (drgnx-registry-test--module 'test/a (drgnx-registry-test--def 'x "A's X"))
   (drgnx-modules-run 'startup)
   (should (equal (drgnx-registry-test--title 'x) "A's X"))
   ;; The module replaced a core command: its teardown puts the core one back, in the same place.
   (drgnx-module-teardown 'test/a)
   (should (equal (drgnx-registry-test--title 'x) "Core X"))
   (should (equal (mapcar #'drgnx-cmd-id (drgnx-commands-all)) '(x y)))
   (should (equal (drgnx-registry-test--title 'y) "Core Y"))))

(ert-deftest drgnx-registry/a-later-definition-survives-the-earlier-teardown ()
  (drgnx-registry-test--with-modules
   (drgnx-registry-test--module 'test/a (drgnx-registry-test--def 'x "A's X"))
   (drgnx-registry-test--module 'test/b (drgnx-registry-test--def 'x "B's X"))
   (drgnx-modules-run 'startup)
   (should (equal (drgnx-registry-test--title 'x) "B's X"))
   ;; The first module goes: the second one's entry stays untouched ...
   (drgnx-module-teardown 'test/a)
   (should (equal (drgnx-registry-test--title 'x) "B's X"))
   ;; ... and when it goes too, A's definition does not come back from the dead.
   (drgnx-module-teardown 'test/b)
   (should-not (drgnx-commands-get 'x))
   (should-not (drgnx-commands-all))))

(ert-deftest drgnx-registry/teardown-in-the-other-order-restores-the-first ()
  (drgnx-registry-test--with-modules
   (drgnx-registry-test--module 'test/a (drgnx-registry-test--def 'x "A's X"))
   (drgnx-registry-test--module 'test/b (drgnx-registry-test--def 'x "B's X"))
   (drgnx-modules-run 'startup)
   (drgnx-module-teardown 'test/b)
   (should (equal (drgnx-registry-test--title 'x) "A's X"))
   (drgnx-module-teardown 'test/a)
   (should-not (drgnx-commands-get 'x))))

(ert-deftest drgnx-registry/a-user-redefinition-after-the-module-is-kept ()
  (drgnx-registry-test--with-modules
   (drgnx-registry-test--module 'test/a (drgnx-registry-test--def 'x "A's X"))
   (drgnx-modules-run 'startup)
   (funcall (drgnx-registry-test--def 'x "User's X"))          ; outside a setup
   (drgnx-module-teardown 'test/a)
   (should (equal (drgnx-registry-test--title 'x) "User's X"))))

(ert-deftest drgnx-registry/a-setup-that-fails-takes-its-commands-back ()
  (drgnx-registry-test--with-modules
   (drgnx-registry-test--module 'test/a (drgnx-registry-test--def 'x "A's X") (lambda () (error "boom")))
   (drgnx-modules-run 'startup)
   (should-not (drgnx-commands-get 'x))))

(ert-deftest drgnx-registry/a-library-loaded-by-a-setup-keeps-its-commands ()
  ;; The top level of a library a setup requires registers for itself (it stays loaded until restart).
  (drgnx-registry-test--with-modules
   (let ((lib (make-temp-file "drgnx-lib" nil ".el" "(drgnx-command-define 'lib :title \"Lib\" :category \"Test\" :command #'ignore)\n")))
     (unwind-protect
         (progn (drgnx-registry-test--module 'test/a (lambda () (load lib nil t)))
                (drgnx-modules-run 'startup)
                (drgnx-module-teardown 'test/a)
                (should (drgnx-commands-get 'lib)))
       (delete-file lib)))))

(defvar drgnx-registry-test-map (make-sparse-keymap))

(ert-deftest drgnx-registry/teardown-frees-the-keys ()
  ;; A module with one command and a profile key: after the teardown (and the keys applying again,
  ;; as `drgnx-modules-after-teardown-functions' does) the key is Emacs's own again.
  (drgnx-registry-test--with-modules
   (let* ((dir (make-temp-file "drgnx-keys" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir) (concat "XDG_STATE_HOME=" dir "/state"))
                                       process-environment))
          (drgnx-keys--applied nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
          (drgnx-keys--session-layers '((test app)))
          (drgnx-keys-profiles '((test :name "Test" :bind ((demo "C-c y") (other "C-c z")))))
          (before (keymap-lookup global-map "C-c y")))
     (unwind-protect
         (progn
           (drgnx-command-define 'other :title "Other" :category "Test" :command #'drgnx-test--cmd)
           (drgnx-registry-test--module 'test/a (lambda () (drgnx-command-define 'demo :title "Demo" :category "Test"
                                                                                 :command #'ignore)))
           (drgnx-modules-run 'startup)
           (drgnx-keys-apply)
           (should (eq (keymap-lookup global-map "C-c y") #'ignore))
           (should (eq (keymap-lookup global-map "C-c z") #'drgnx-test--cmd))
           (drgnx-module-teardown 'test/a)
           (run-hooks 'drgnx-modules-after-teardown-functions)
           (should (eq (keymap-lookup global-map "C-c y") before))
           (should (eq (keymap-lookup global-map "C-c z") #'drgnx-test--cmd))   ; another command's key stays
           (should-not (drgnx-commands-get 'demo)))
       (drgnx-keys--restore)
       (delete-directory dir t)))))

(ert-deftest drgnx-registry/keys-follow-a-teardown-from-the-core-hook ()
  (should (memq 'drgnx--after-teardown drgnx-modules-after-teardown-functions)))
