;;; grid-snapshot-test.el --- batch tests: the layout snapshot across frames and the undo stack -*- lexical-binding: t -*-
;; test-class: det
;; `drgnx-grid-snapshot' records every workbench frame (role, monitor, place, tree, full size); `drgnx-grid-restore'
;; puts a snapshot back, making and deleting auxiliary frames (no buffer killed); `drgnx-grid-push' keeps them on a
;; capped stack that Restore Previous Layout walks back.  Batch cannot make a second frame (the initial terminal is no
;; real one), so the rows with aux frames are GUI rows (test/ui/grid-snapshot-gui-test.el); these use the one frame.
;; HOME and the XDG directories are a temp directory.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)
(require 'drgnx-groups)
(require 'drgnx-grid-frames)

(defmacro drgnx-grid-snapshot-test--with (&rest body)
  "BODY on the grid fixture with an empty stack, a temp HOME, the selected frame the main one, its editor's tabs
holding its buffer (as a session's editors do: a restored editor has its tabs)."
  (declare (indent 0))
  `(let* ((home (make-temp-file "drgnx-grid-snapshot" t))
          (process-environment (append (list (concat "HOME=" home) (concat "XDG_STATE_HOME=" home "/state")
                                             (concat "XDG_CONFIG_HOME=" home "/config"))
                                       process-environment))
          (drgnx-grid--stack nil)
          (main (selected-frame)))
     (unwind-protect
         (drgnx-grid-test--with
           (set-frame-parameter main 'drgnx-frame-role 'main)
           (set-window-parameter nil 'drgnx-tabs (list (window-buffer)))
           ,@body)
       (set-frame-parameter main 'drgnx-frame-role nil)
       (delete-directory home t))))

(ert-deftest drgnx-grid-snapshot/stack-is-capped-and-pops-in-order ()
  (drgnx-grid-snapshot-test--with
    (let ((drgnx-grid-stack-max 3))
      (dotimes (i 4)
        (drgnx-grid-push 'move)
        ;; each push a different layout: one more group, right and down by turns
        (if (cl-evenp i) (drgnx-groups-split-right) (drgnx-groups-split-down)))
      (should (= (length drgnx-grid--stack) 3))
      (let ((counts (mapcar (lambda (s) (length (drgnx-grid-tree-leaves (plist-get (car (plist-get s :frames)) :tree))))
                            drgnx-grid--stack)))
        ;; newest first: the pushes before the 4th, 3rd and 2nd splits
        (should (equal counts '(4 3 2)))))))

(ert-deftest drgnx-grid-snapshot/equal-snapshots-push-once ()
  (drgnx-grid-snapshot-test--with
    (drgnx-grid-push 'move)
    (drgnx-grid-push 'move)
    (drgnx-grid-push 'preset)
    (should (= (length drgnx-grid--stack) 1))
    (drgnx-groups-split-right)
    (drgnx-grid-push 'move)
    (should (= (length drgnx-grid--stack) 2))))

(ert-deftest drgnx-grid-snapshot/restore-previous-walks-back-three-changes ()
  ;; three changes, each pushed before it as the grid's commands do: three Restore Previous Layout go back through them
  (drgnx-grid-snapshot-test--with
    (let ((trees nil))
      (dolist (change (list #'drgnx-groups-split-right (lambda () (drgnx-pane-show 'g-term)) #'drgnx-groups-split-down))
        (push (drgnx-grid-tree) trees)
        (drgnx-grid-push 'move)
        (funcall change))
      (should-not (equal (drgnx-grid-tree) (car trees)))
      (dolist (want trees)
        (drgnx-grid-restore-previous)
        (should (equal (drgnx-grid-tree) want)))
      (should-not drgnx-grid--stack))))

(ert-deftest drgnx-grid-snapshot/a-foreign-collapse-is-undoable ()
  (drgnx-grid-snapshot-test--with
    (drgnx-grid-mode 1)
    (unwind-protect
        (let ((one (current-window-configuration)))
          (dolist (k '(g-tree g-term g-chat)) (drgnx-pane-show k))
          (drgnx-state-sync)
          (let ((tree (drgnx-grid-tree)))
            (setq drgnx-grid--stack nil)
            (set-window-configuration one)
            (let ((ignore-window-parameters t)) (delete-other-windows))
            (drgnx-state-sync)
            (should (eq (plist-get (car drgnx-grid--stack) :why) 'foreign))
            (drgnx-grid-restore-previous)
            (should (equal (drgnx-grid-tree) tree))))
      (drgnx-grid-mode -1))))

(ert-deftest drgnx-grid-snapshot/a-junk-snapshot-is-ignored-with-a-notice ()
  (drgnx-grid-snapshot-test--with
    (drgnx-groups-split-right)
    (let ((before (drgnx-grid-tree)) (frames (frame-list)) said)
      (cl-letf (((symbol-function 'drgnx-notify) (lambda (_source _severity text &rest _) (push text said))))
        (dolist (junk (list nil 42 '(:frames 7) '(:frames ((:role main :tree (bogus)))) (list :frames (list (list :role 'aux :tree (list 'editor :id (current-buffer)))))))
          (should-not (drgnx-grid-restore junk))))
      (should (equal (drgnx-grid-tree) before))
      (should (equal (frame-list) frames))
      (should (= (length said) 5))
      ;; an empty stack says so
      (let (msg)
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
          (drgnx-grid-restore-previous))
        (should (equal msg "No earlier layout"))))))

(provide 'grid-snapshot-test)
;;; grid-snapshot-test.el ends here
