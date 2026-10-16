;;; core-surfaces-test.el --- batch tests: surfaces generated from the registry -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-surfaces)

(defun drgnx-test--surf-cmd () (interactive) (setq drgnx-test--ran t))
(defvar drgnx-test--ran nil)
(defvar drgnx-test-surf-map (make-sparse-keymap))

(defmacro drgnx-test--with-commands (&rest body)
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-commands-problems nil) (drgnx-surfaces-contexts nil))
     (drgnx-command-define 'b-cmd :title "Beta" :category "Zed" :command #'drgnx-test--surf-cmd :key "C-c b"
                           :map 'drgnx-test-surf-map :menu '("Tools" "Test") :doc "Beta does b")
     (drgnx-command-define 'a-cmd :title "Alpha" :category "Able" :command #'drgnx-test--surf-cmd :key "<f19>"
                           :context 'always :doc "Alpha | pipes")
     (drgnx-command-define 'gone :title "Gone" :category "Able" :command 'drgnx-test--missing)
     (drgnx-surfaces-define-context 'always (lambda (_) t))
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
   (drgnx-surfaces-run 'a-cmd)
   (should drgnx-test--ran)
   (should (string-search "Able: Alpha — next time: <f19>" (drgnx-surfaces-tip (drgnx-commands-get 'a-cmd))))))
