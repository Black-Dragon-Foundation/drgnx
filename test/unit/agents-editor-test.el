;;; agents-editor-test.el --- the editor module: it watches what windows show and leaves nothing when off -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the hub client's call is replaced by a recorder of what would have been asked.  The same
;; rows against a real hub (agents-editor-hub-test.el) land with the hub's buffer view.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agents-in-editor))

(declare-function drgnx-agents-editor-sync-windows "drgnx-agents-editor")
(declare-function drgnx-agents-editor-frame "drgnx-agents-editor")
(declare-function drgnx-agents-editor-watched-buffers "drgnx-agents-editor")
(defvar drgnx-agents-editor-apply-functions)
(defvar drgnx-agent-identity-watched-function)

(defvar drgnx-agents-editor-test--calls nil)

(defmacro drgnx-agents-editor-test--with (&rest body)
  "BODY with the module set up and the hub's calls recorded in `drgnx-agents-editor-test--calls' (METHOD . PARAMS)."
  (declare (indent 0))
  `(let ((drgnx-agents-editor-test--calls nil) (dir (make-temp-file "agents-editor" t)))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub-call)
                    (lambda (method params _cb &rest _) (push (cons method params) drgnx-agents-editor-test--calls) 1)))
           (drgnx-test-with-modules '(tools/agents-in-editor)
             (save-window-excursion
               ,@body)))
       (delete-directory dir t))))

(defun drgnx-agents-editor-test--file (dir name)
  (let ((f (expand-file-name name dir)))
    (write-region "x\n" nil f nil 'silent)
    (find-file-noselect f)))

(defun drgnx-agents-editor-test--methods ()
  (mapcar #'car (reverse drgnx-agents-editor-test--calls)))

(ert-deftest drgnx-agents-editor/watch-follows-window-changes ()
  (drgnx-agents-editor-test--with
    (delete-other-windows)
    (let ((a (drgnx-agents-editor-test--file dir "a.txt")) (b (drgnx-agents-editor-test--file dir "b.txt")))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) a)
            (drgnx-agents-editor-sync-windows)
            (should (equal (list a) (drgnx-agents-editor-watched-buffers)))
            (set-window-buffer (selected-window) b)
            (drgnx-agents-editor-sync-windows)
            (should (equal (list b) (drgnx-agents-editor-watched-buffers)))
            ;; the setup asks for the sessions' identities first
            (should (equal '("agents/list" "agents/buffer/watch" "agents/buffer/unwatch" "agents/buffer/watch")
                           (drgnx-agents-editor-test--methods)))
            ;; a window with a buffer that has no file is never watched
            (set-window-buffer (selected-window) (get-buffer-create "*agents-editor-scratch*"))
            (drgnx-agents-editor-sync-windows)
            (should-not (drgnx-agents-editor-watched-buffers)))
        (kill-buffer a) (kill-buffer b) (kill-buffer "*agents-editor-scratch*")))))

(ert-deftest drgnx-agents-editor/hidden-buffers-cost-nothing ()
  ;; a frame for a buffer no window shows is ignored: no apply, no cached frame, no overlay
  (drgnx-agents-editor-test--with
    (delete-other-windows)
    (let ((a (drgnx-agents-editor-test--file dir "a.txt")) (applied 0) (b (drgnx-agents-editor-test--file dir "b.txt")))
      (unwind-protect
          (let ((drgnx-agents-editor-apply-functions (list (lambda (&rest _) (cl-incf applied)))))
            (set-window-buffer (selected-window) a)
            (drgnx-agents-editor-sync-windows)
            (let ((view (buffer-local-value 'drgnx-agents-editor--view a)))
              (set-window-buffer (selected-window) b)
              (drgnx-agents-editor-sync-windows)
              (drgnx-agents-editor--event "agent-buffer" (list :view view :full t :version 1 :agents '((:ordinal 1)))))
            (should (= applied 0))
            (should-not (drgnx-agents-editor-frame a))
            (should-not (overlays-in (point-min) (point-max))))
        (kill-buffer a) (kill-buffer b)))))

(ert-deftest drgnx-agents-editor/off-unwatches-and-leaves-nothing ()
  (let ((before (list window-buffer-change-functions window-size-change-functions drgnx-hub-event-functions
                      drgnx-hub-connected-functions)))
    (let ((calls nil) (dir (make-temp-file "agents-editor" t)) buf)
      (unwind-protect
          (cl-letf (((symbol-function 'drgnx-hub-call)
                     (lambda (method params _cb &rest _) (push (cons method params) calls) 1)))
            (drgnx-test-with-modules '(tools/agents-in-editor)
              (save-window-excursion
                (delete-other-windows)
                (setq buf (drgnx-agents-editor-test--file dir "a.txt"))
                (set-window-buffer (selected-window) buf)
                (drgnx-agents-editor-sync-windows)
                (should (equal (list buf) (drgnx-agents-editor-watched-buffers)))
                (should drgnx-agent-identity-watched-function)))
            ;; after the module is off
            (should (equal '("agents/list" "agents/buffer/unwatch")
                           (cl-remove "agents/buffer/watch" (mapcar #'car (reverse calls)) :test #'equal)))
            (should-not drgnx-agent-identity-watched-function)
            (should-not (buffer-local-value 'drgnx-agents-editor--view buf))
            (should (equal before (list window-buffer-change-functions window-size-change-functions
                                        drgnx-hub-event-functions drgnx-hub-connected-functions))))
        (when buf (kill-buffer buf))
        (delete-directory dir t)))))

(provide 'agents-editor-test)
;;; agents-editor-test.el ends here
