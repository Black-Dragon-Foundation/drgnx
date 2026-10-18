;;; core-surfaces-test.el --- batch tests: surfaces generated from the registry -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-surfaces)

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
