;;; wb-area-empty-test.el --- batch tests: the panel's empty tabs, contextual tabs and the Output channel picker -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-area)

(defmacro wb-area-empty-test--with (&rest body)
  "BODY with rules on, one editor window, the panel hidden, fresh area state, a contextual tab defined."
  `(drgnx-test-with-state
     (let ((drgnx-wb-unrouted nil)
           (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
           (drgnx-wb--areas (copy-tree drgnx-wb--areas)))
       (delete-other-windows)
       (set-frame-parameter nil 'drgnx-wb-areas nil)
       (set-frame-parameter nil 'drgnx-wb-panel-px nil)
       (drgnx-rules-mode 1)
       (drgnx-wb-define-tab 'panel 'ctx-test :title "Context Test" :contextual t :empty "Nothing for the context test.")
       (unwind-protect (progn ,@body)
         (drgnx-rules-mode -1)
         (drgnx-wb-area-hide 'panel)
         (delete-other-windows)
         (dolist (b '("*ctx-content*")) (when (get-buffer b) (kill-buffer b)))))))

(defun wb-area-empty-test--text (area)
  "AREA's tab row as plain text."
  (substring-no-properties (format "%s" (drgnx-area--tab-row area))))

(ert-deftest drgnx-area-empty/a-tab-with-no-buffer-says-why ()
  "The Results and Help tabs show a line saying what appears there, not a blank buffer with a cursor box."
  (wb-area-empty-test--with
   (dolist (tab '(results help))
     (let* ((w (drgnx-wb-area-show 'panel tab)) (buf (window-buffer w)))
       (with-current-buffer buf
         (should (string-match-p "[A-Za-z]" (buffer-string)))
         (should-not cursor-type))))))

(ert-deftest drgnx-area-empty/output-and-problems-show-their-content-at-once ()
  "Showing the Output tab shows a channel (Messages when nothing else was logged), and Problems the view that lists the
problems (or says there are none): a click on either never lands on a blank page."
  (wb-area-empty-test--with
   (let ((b (window-buffer (drgnx-wb-area-show 'panel 'output))))
     (should (memq b (drgnx-wb-output-channels))))
   (when (require 'drgnx-problems (expand-file-name "modules/lang/drgnx-problems" drgnx-dir) t)
     (let ((b (window-buffer (drgnx-wb-area-show 'panel 'problems))))
       (should (eq (buffer-local-value 'major-mode b) 'drgnx-problems-mode))
       (should (string-match-p "No problems have been detected" (with-current-buffer b (buffer-string))))))))

(ert-deftest drgnx-area-empty/the-work-rules-tab-says-why ()
  (skip-unless (require 'drgnx-work-space nil t))
  (wb-area-empty-test--with
   (let ((b (drgnx-work-space--rules-buffer)))
     (unwind-protect
         (with-current-buffer b
           (should (string-match-p "[A-Za-z]" (buffer-string)))
           (should-not cursor-type))
       (unless (drgnx-work-flow-rules-buffers) (kill-buffer b))))))

(ert-deftest drgnx-area-empty/a-contextual-tab-shows-only-with-content ()
  "A contextual tab (Heap Graph, Branch Review, Research Trail, Rules) is in the row only while it is the shown tab
or has a buffer of its own: the row is the same whenever the modules that define them loaded."
  (wb-area-empty-test--with
   (drgnx-wb-area-show 'panel 'output)
   (should-not (string-match-p "Context Test" (wb-area-empty-test--text 'panel)))
   (should (string-match-p "Problems" (wb-area-empty-test--text 'panel)))
   (drgnx-wb-area-show 'panel 'ctx-test (get-buffer-create "*ctx-content*"))
   (should (string-match-p "Context Test" (wb-area-empty-test--text 'panel)))
   (drgnx-wb-area-show 'panel 'output)
   (should (string-match-p "Context Test" (wb-area-empty-test--text 'panel)))
   (kill-buffer "*ctx-content*")
   (should-not (string-match-p "Context Test" (wb-area-empty-test--text 'panel)))))

(ert-deftest drgnx-area-empty/the-trail-tab-is-named-in-words ()
  "The Work space's Trail pane is titled \"Research Trail\" (the word the command already uses)."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "modules/tools/drgnx-work-space.el" drgnx-dir))
    (should (search-forward "'work-trail :title \" Research Trail\"" nil t))))

(ert-deftest drgnx-area-empty/output-channels-are-listed-and-picked ()
  "Output: Select Channel lists the buffers the Output tab shows by name and shows the one picked."
  (wb-area-empty-test--with
   (get-buffer-create "*Messages*")
   (with-current-buffer (get-buffer-create "*Warnings*") (insert "w"))
   (let ((channels (drgnx-wb-output-channels)))
     (should (member "*Messages*" (mapcar #'buffer-name channels)))
     (should (member "*Warnings*" (mapcar #'buffer-name channels))))
   (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Warnings")))
     (drgnx-wb-output-select-channel))
   (should (eq (drgnx-wb-area-tab 'panel) 'output))
   (should (eq (window-buffer (drgnx-wb-area-window 'panel)) (get-buffer "*Warnings*")))
   ;; the tab's own piece names the channel
   (should (string-match-p "Warnings" (wb-area-empty-test--text 'panel)))))
