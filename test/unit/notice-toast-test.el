;;; notice-toast-test.el --- notices as toasts: the model, the buttons, the off path -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): which toasts show is a function of the notices offered; the drawing is not part of it, and a
;; frame with no Glitnir takes nothing, so the echo route stays as it was.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-notice-echo)
(require 'drgnx-notice-toast)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)

(defun notice-toast-test--notice (n &rest more)
  "A notice N for the model tests."
  (append (list :source 'config :id n :severity 'warn :life 'event :text (format "text %s" n)) more))

(defmacro notice-toast-test--with-model (&rest body)
  "BODY with an empty toast model and no drawing."
  (declare (indent 0))
  `(let ((drgnx-notice-toast--visible nil) (drgnx-notice-toast--waiting nil))
     (cl-letf (((symbol-function 'drgnx-notice-toast--sync) #'ignore))
       ,@body)))

(ert-deftest drgnx-notice-toast/at-most-three-rest-counted ()
  "Pattern D: five notices offered show three toasts, newest on top; the other two are counted, and come when one goes."
  (notice-toast-test--with-model
    (dotimes (i 5) (drgnx-notice-toast-admit (notice-toast-test--notice i)))
    (should (equal (mapcar (lambda (n) (plist-get n :id)) drgnx-notice-toast--visible) '(0 1 2)))
    (should (= 2 (drgnx-notice-toast-more-count)))
    (should (equal (drgnx-notice-toast-more-text) "+2"))
    (drgnx-notice-toast-expire (car drgnx-notice-toast--visible))
    (should (equal (mapcar (lambda (n) (plist-get n :id)) drgnx-notice-toast--visible) '(1 2 3)))
    (should (= 1 (drgnx-notice-toast-more-count)))
    (dotimes (_ 4) (drgnx-notice-toast-expire (car drgnx-notice-toast--visible)))
    (should (null drgnx-notice-toast--visible))
    (should (= 0 (drgnx-notice-toast-more-count)))
    (should (null (drgnx-notice-toast-more-text)))))

(ert-deftest drgnx-notice-toast/buttons-primary-first ()
  "Pattern D: the notice's own command is the first button; Show Notices and Dismiss follow; at most three."
  (cl-letf (((symbol-function 'drgnx-commands-get) (lambda (_) nil))
            ((symbol-function 'drgnx-surfaces-key-label) (lambda (id &rest _) (and (eq id 'notices) "C-c n"))))
    (let ((b (drgnx-notice-toast-buttons (notice-toast-test--notice 1 :command 'fix-it))))
      (should (equal (mapcar (lambda (x) (plist-get x :label)) b) '("fix-it" "Show Notices" "Dismiss")))
      (should (eq (plist-get (car b) :action) 'fix-it))
      (should (equal (plist-get (cadr b) :key) "C-c n"))
      (should (= 3 (length b))))
    (let ((b (drgnx-notice-toast-buttons (notice-toast-test--notice 2))))
      (should (equal (mapcar (lambda (x) (plist-get x :label)) b) '("Show Notices" "Dismiss"))))
    ;; a thing waiting on you is not dismissed from here
    (let ((b (drgnx-notice-toast-buttons '(:source agents :id 3 :severity needs-you :life attention :text "t" :command fix-it))))
      (should (equal (mapcar (lambda (x) (plist-get x :label)) b) '("fix-it" "Show Notices"))))))

(ert-deftest drgnx-notice-toast/echo-without-glitnir ()
  "Pattern D: with no Glitnir (style `auto') or style `echo', no toast is taken and the line goes to the echo queue;
with the float route on, the notice is taken and the echo queue stays empty."
  (drgnx-notice-test-with-model
    (let ((drgnx-notice--echo-pending nil) (drgnx-notice--echo-last nil) (drgnx-notice--echo-waiting nil)
          (taken nil))
      (cl-letf (((symbol-function 'drgnx-notice--can-echo-p) #'ignore)   ; held: lines wait in the queue
                ((symbol-function 'drgnx-notice-toast--sync) #'ignore))
        (let ((drgnx-notice-style 'auto))
          (should-not (drgnx-notice-toast-active-p))          ; batch: no Glitnir, no graphical frame
          (drgnx-notice--echo-enqueue 'problem (notice-toast-test--notice 1))
          (should (= 1 (length drgnx-notice--echo-pending))))
        (let ((drgnx-notice-style 'echo))
          (should-not (drgnx-notice-toast-active-p)))
        (setq drgnx-notice--echo-pending nil)
        (let ((drgnx-notice-toast--visible nil) (drgnx-notice-toast--waiting nil))
          (cl-letf (((symbol-function 'drgnx-notice-toast-active-p) (lambda () t)))
            (drgnx-notice--echo-enqueue 'problem (notice-toast-test--notice 2))
            (drgnx-notice--echo-enqueue 'line "a startup line")
            (setq taken (mapcar (lambda (n) (plist-get n :id)) drgnx-notice-toast--visible)))
          (should (equal taken '(2)))
          (should (equal drgnx-notice--echo-pending '((line . "a startup line")))))))))

(provide 'notice-toast-test)
;;; notice-toast-test.el ends here
