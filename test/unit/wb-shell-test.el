;;; wb-shell-test.el --- batch tests: each window's shell -*- lexical-binding: t -*-
;; test-class: det
;; `drgnx-shell-defaults' from a frame's tree (no rail for Work and its Detail, or one conversation), the right side by
;; place, and the shell kept as the frame's own parameter.  A second frame needs a GUI session: the toggle that leaves
;; the other windows alone is a GUI row (test/ui/tiling-frames-gui-test.el, `torn-out-frame-has-its-own-shell').
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)
(require 'drgnx-frame-shell)

(defmacro drgnx-shell-test--with-work (buffer &rest body)
  "BODY with BUFFER a Work map (its mode one of `drgnx-shell-focus-modes', here `text-mode')."
  (declare (indent 1))
  `(let ((drgnx-shell-focus-modes '(text-mode)) (,buffer (get-buffer-create "*g-work*")))
     (unwind-protect (progn (with-current-buffer ,buffer (text-mode)) ,@body)
       (kill-buffer ,buffer))))

(ert-deftest drgnx-shell/defaults-per-frame-kind ()
  (drgnx-shell-test--with-work work
    (let ((editor (list 'editor :id 1 :tabs (list (buffer-name work)) :shown (buffer-name work) :point 1 :start 1))
          (scratch '(editor :id 1 :tabs ("*scratch*") :shown "*scratch*" :point 1 :start 1))
          (detail '(tile :px 40 :share 0.25 :id 2 :kinds (work-detail) :shown work-detail :dock right :state nil))
          (chat '(tile :px 40 :share 0.25 :id 2 :kinds (g-chat) :shown g-chat :dock right :state nil)))
      ;; Work and its Detail: no rail
      (should-not (plist-get (drgnx-shell-defaults `(row :px nil :share nil ,(append editor '(:px 120 :share 0.75)) ,detail)) :rail))
      (should-not (plist-get (drgnx-shell-defaults editor) :rail))
      ;; one conversation, an instance or the kind: no rail
      (should-not (plist-get (drgnx-shell-defaults '(tile :id 1 :kinds ((agent-panel . "s1")) :shown (agent-panel . "s1") :dock nil :state nil)) :rail))
      ;; anything else: the rail
      (should (plist-get (drgnx-shell-defaults scratch) :rail))
      (should (plist-get (drgnx-shell-defaults `(row :px nil :share nil ,(append editor '(:px 120 :share 0.75)) ,chat)) :rail))
      (should (plist-get (drgnx-shell-defaults '(row :px nil :share nil (tile :px 40 :share 0.5 :id 1 :kinds (agent-panel) :shown agent-panel :dock nil :state nil) (tile :px 40 :share 0.5 :id 2 :kinds (agent-panel) :shown agent-panel :dock nil :state nil))) :rail))
      (should (equal (drgnx-shell-defaults scratch) '(:title t :rail t :right t :place nil))))))

(ert-deftest drgnx-shell/toggle-affects-only-its-frame ()
  ;; batch has one frame: the shell is that frame's parameter, the rail writes the kit's `drgnx-rail' on it alone, and
  ;; a key that is not the shell's is refused (the GUI row checks a second frame is left alone)
  (drgnx-grid-test--with
    (unwind-protect
        (progn
          (should (drgnx-shell-get nil :rail))
          (should-not (frame-parameter nil 'drgnx-rail))
          (drgnx-shell-toggle-rail)
          (should-not (drgnx-shell-get nil :rail))
          (should (eq (frame-parameter nil 'drgnx-rail) 'hidden))
          (should (equal (frame-parameter nil 'drgnx-shell) '(:title t :rail nil :right t :place nil)))
          (drgnx-shell-toggle-rail)
          (should-not (frame-parameter nil 'drgnx-rail))
          (should-error (drgnx-shell-set nil :colour 'red)))
      (set-frame-parameter nil 'drgnx-shell nil)
      (set-frame-parameter nil 'drgnx-rail nil))))

(ert-deftest drgnx-shell/right-side-by-place ()
  (should (eq (drgnx-shell-right-for 'work) 'work-detail))
  (dolist (place '(home agents editor nil))
    (should (eq (drgnx-shell-right-for place) 'agents-side))))

(provide 'wb-shell-test)
;;; wb-shell-test.el ends here
