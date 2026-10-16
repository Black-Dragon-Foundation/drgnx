;;; core-registry-test.el --- batch tests: the command registry -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-registry)

(defmacro drgnx-test--fresh-registry (&rest body)
  `(let ((drgnx-commands--table (make-hash-table :test #'eq))
         (drgnx-commands--order nil)
         (drgnx-commands-problems nil))
     ,@body))

(defun drgnx-test--cmd () (interactive))
(defvar drgnx-test-map (make-sparse-keymap))

(ert-deftest drgnx-registry/define-and-get ()
  (drgnx-test--fresh-registry
   (drgnx-command-define 'demo :title "Demo" :category "Test" :command #'drgnx-test--cmd)
   (should (equal (drgnx-commands-label (drgnx-commands-get 'demo)) "Test: Demo"))
   (should (equal (mapcar #'drgnx-cmd-id (drgnx-commands-all)) '(demo)))))

(ert-deftest drgnx-registry/requires-fields ()
  (drgnx-test--fresh-registry
   (should-error (drgnx-command-define 'bad :category "Test" :command #'drgnx-test--cmd))
   (should-error (drgnx-command-define 'bad2 :title "x" :category "Test"))))

(ert-deftest drgnx-registry/binds-in-keymap ()
  (drgnx-test--fresh-registry
   (drgnx-command-define 'k :title "K" :category "Test" :command #'drgnx-test--cmd
                         :key "C-c t" :map 'drgnx-test-map)
   (should (eq (keymap-lookup drgnx-test-map "C-c t") #'drgnx-test--cmd))))

(ert-deftest drgnx-registry/deferred-binding ()
  (drgnx-test--fresh-registry
   (defvar drgnx-test-late-map (make-sparse-keymap))
   (drgnx-command-define 'late :title "Late" :category "Test" :command #'drgnx-test--cmd
                         :key "C-c l" :map '(drgnx-test-late-feature . drgnx-test-late-map))
   (should-not (eq (keymap-lookup drgnx-test-late-map "C-c l") #'drgnx-test--cmd))
   (provide 'drgnx-test-late-feature)
   (should (eq (keymap-lookup drgnx-test-late-map "C-c l") #'drgnx-test--cmd))))

(ert-deftest drgnx-registry/native-not-bound ()
  (drgnx-test--fresh-registry
   (let ((map (make-sparse-keymap)))
     (defvar drgnx-test-native-map map)
     (drgnx-command-define 'n :title "N" :category "Test" :native "C-a" :map 'drgnx-test-native-map)
     (should-not (keymap-lookup drgnx-test-native-map "C-a")))))

(ert-deftest drgnx-registry/conflicts-found ()
  (drgnx-test--fresh-registry
   (drgnx-command-define 'a :title "A" :category "Test" :command #'drgnx-test--cmd :key "C-c x" :map 'drgnx-test-map)
   (drgnx-command-define 'b :title "B" :category "Test" :command #'drgnx-test--cmd :key "C-c x" :map 'drgnx-test-map)
   (should (equal (drgnx-commands-conflicts) '((drgnx-test-map "C-c x" a b))))))

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

(ert-deftest drgnx-registry/bad-key-recorded-not-fatal ()
  (drgnx-test--fresh-registry
   (drgnx-command-define 'bad :title "Bad" :category "Test" :command #'drgnx-test--cmd
                         :key "S-M-<down>" :map 'drgnx-test-map)
   (should (seq-some (lambda (m) (string-match-p "S-M-<down>" m)) drgnx-commands-problems))))
