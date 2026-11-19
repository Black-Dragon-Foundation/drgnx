;;; agents-side-test.el --- the Agents side: the compact conversation, the file chips, Ask from a right-click (Flow Task 24) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub and no GUI: the panel is fed by hand, the side's kind and the hub's presence answer are
;; stand-ins.  The rows draw with the kit (view/agents_side.rs); what stays here is the editor's half.  The plan's GUI
;; row `agents-side/ask-an-agent-from-right-click' (a real right-click on the buffer) joins with the implementation.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel-context-remove "drgnx-agent-panel-composer")
(declare-function drgnx-agents-side-open-conversation "drgnx-agent-panel-list" (session))
(declare-function drgnx-agents-side-back "drgnx-agent-panel-list" ())
(declare-function drgnx-agents-side-state "drgnx-agent-panel-list" ())
(declare-function drgnx-agents-side-file-chip "drgnx-agent-panel-list" (file &optional lines))
(declare-function drgnx-agents-side-on-file-chip "drgnx-agent-panel-list" (file agents))
(declare-function drgnx-agents-ask-about-this "drgnx-agents-ask" ())
(defvar drgnx-agent-panel--context)

(defmacro agents-side-test--with (&rest body)
  "BODY with the agent-panel module set up and the hub's calls swallowed."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
     (drgnx-test-with-modules '(tools/agent-panel) ,@body)))

(ert-deftest agents-side/card-opens-compact-conversation-with-back ()
  "A card's click shows its conversation in the side (the compact form: the panel's three windows), with a back arrow
to the cards; back is the cards again."
  (agents-side-test--with
    (let (shown)
      (cl-letf (((symbol-function 'drgnx-pane-show) (lambda (kind &rest args) (push (cons kind args) shown))))
        (let ((buf (drgnx-agent-panel-buffer "s1")))
          (unwind-protect
              (progn
                (should (eq 'cards (plist-get (drgnx-agents-side-state) :view)))
                (drgnx-agents-side-open-conversation "s1")
                (should (equal '(:view conversation :session "s1") (drgnx-agents-side-state)))
                (should (eq 'agents-side (car (car shown))))
                (should (eq buf (plist-get (cdr (car shown)) :buffer)))
                (drgnx-agents-side-back)
                (should (eq 'cards (plist-get (drgnx-agents-side-state) :view))))
            (when (buffer-live-p buf) (kill-buffer buf))))))))

(ert-deftest agents-side/file-chip-offered-and-removable ()
  "With a file shown in the frame's MRU editor the composer offers it as a removable chip: \"@ file\", or \"@ lines a–b\"
with a region; removing it leaves the composer's context as it was."
  (agents-side-test--with
    (should (equal '(:file "/p/a.txt") (drgnx-agents-side-file-chip "/p/a.txt")))
    (should (equal '(:file "/p/a.txt" :lines (3 . 7)) (drgnx-agents-side-file-chip "/p/a.txt" '(3 . 7))))
    (let ((buf (drgnx-agent-panel-buffer "s1")))
      (unwind-protect
          (with-current-buffer buf
            (drgnx-agent-panel-context-add (drgnx-agents-side-file-chip "/p/a.txt"))
            (should (equal '((:file "/p/a.txt")) drgnx-agent-panel--context))
            (drgnx-agent-panel-context-remove (drgnx-agents-side-file-chip "/p/a.txt"))
            (should-not drgnx-agent-panel--context))
        (kill-buffer buf)))))

(ert-deftest agents-side/agent-on-this-file-chip-does-not-switch ()
  "When an agent works on the shown file the side offers its conversation as a chip \"Sonnet is editing this file ›\",
and never switches to it by itself."
  (agents-side-test--with
    (let (shown)
      (cl-letf (((symbol-function 'drgnx-pane-show) (lambda (&rest args) (push args shown))))
        (should (equal "Sonnet is editing this file ›"
                       (plist-get (drgnx-agents-side-on-file-chip "/p/a.txt" '(("s1" . "Sonnet"))) :label)))
        (should (equal "s1" (plist-get (drgnx-agents-side-on-file-chip "/p/a.txt" '(("s1" . "Sonnet"))) :session)))
        (should-not (drgnx-agents-side-on-file-chip "/p/a.txt" nil))
        (should-not shown)))))

(ert-deftest agents-side/ask-an-agent-from-right-click ()
  "\"Ask an Agent About This\" (the menu item on a file's buffer) opens the conversation of the agent working on the file
in the side, with the file as a removable chip in its composer; it sends nothing."
  (agents-side-test--with
    (let (opened (file (make-temp-file "agents-side" nil ".txt")))
      (unwind-protect
          (with-temp-buffer
            (setq buffer-file-name file)
            (cl-letf (((symbol-function 'drgnx-agents-side-open-conversation)
                       (lambda (s) (setq opened s) (drgnx-agent-panel-buffer s)))
                      ((symbol-function 'drgnx-hub-call)
                       (lambda (method _p cb &rest _)
                         (when (equal method "agents/presence/get")
                           (funcall cb (list :entries (vector (list :session "s1"))) nil)))))
              (drgnx-agents-ask-about-this))
            (should (equal "s1" opened))
            (with-current-buffer (drgnx-agent-panel-buffer "s1")
              (should (member (list :file file) drgnx-agent-panel--context))))
        (when-let* ((b (get-buffer (format "*drgnx agent: %s*" "s1")))) (kill-buffer b))
        (delete-file file)))))

(provide 'agents-side-test)
;;; agents-side-test.el ends here
