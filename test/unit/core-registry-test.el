;;; core-registry-test.el --- batch tests: the command registry -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-registry)

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
  ;; Commands are registered without keys (docs/keys.md); the old :key and :native say so.
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
