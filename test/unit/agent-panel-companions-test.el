;;; agent-panel-companions-test.el --- the agent panel's companions across display classes and its buffer's kill -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the hub client's calls are recorded.  A display class's twin of the transcript (a terminal
;; frame beside a graphical one) gets the header's twin of that class above it, made once; killing the panel's buffer
;; kills its header, its composer and their twins.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-hub-client)
(require 'drgnx-modal)
(require 'drgnx-history-revert)          ; Fork's library, loaded first so a stub of it is not replaced mid-test
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(declare-function drgnx-agent-panel-buffer "drgnx-agent-panel")
(declare-function drgnx-agent-panel--companions "drgnx-agent-panel")
(declare-function drgnx-agent-panel--composer-of "drgnx-agent-panel-composer")
(declare-function drgnx-agent-panel--header-of "drgnx-agent-panel-header")
(declare-function drgnx-view-patch-class "drgnx-view")
(defvar drgnx-view-patch)
(defvar drgnx-view-patch-twin-function)
(defvar drgnx-view-patch-twin-of)

(defmacro drgnx-agent-panel-companions-test--with (&rest body)
  "BODY with the module set up, the hub's calls answered with nothing, and panel \"s1\" as `buf'."
  (declare (indent 0))
  `(let (buf)
     (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
       (drgnx-test-with-modules '(tools/agent-panel)
         (save-window-excursion
           (unwind-protect
               (progn (setq buf (drgnx-agent-panel-buffer "s1")) ,@body)
             (when (buffer-live-p buf) (kill-buffer buf))))))))

(defun drgnx-agent-panel-companions-test--twin (buffer class)
  "BUFFER's twin in display CLASS, made as the env's routing makes it."
  (let ((tw (with-current-buffer buffer (funcall drgnx-view-patch-twin-function class))))
    (with-current-buffer tw (setq-local drgnx-view-patch-twin-of buffer))
    tw))

(ert-deftest drgnx-agent-panel-companions/the-panel-has-its-header-and-composer ()
  (drgnx-agent-panel-companions-test--with
    (let ((parts (drgnx-agent-panel--companions buf)))
      (should (eq (car parts) (drgnx-agent-panel--header-of buf)))
      (should (eq (cadr parts) (drgnx-agent-panel--composer-of buf))))))

(ert-deftest drgnx-agent-panel-companions/a-twin-of-the-transcript-has-the-header-of-its-class ()
  "Above the transcript's twin in class C: the header's twin in C (made once, then found again), not the header the
other class draws; the composer is the panel's one."
  (drgnx-agent-panel-companions-test--with
    (let* ((header (drgnx-agent-panel--header-of buf))
           (tw (drgnx-agent-panel-companions-test--twin buf "tty-test"))
           (parts (drgnx-agent-panel--companions tw))
           (htw (car parts)))
      (should (buffer-live-p htw))
      (should-not (eq htw header))
      (should (eq header (buffer-local-value 'drgnx-view-patch-twin-of htw)))
      (should (equal "tty-test" (drgnx-view-patch-class (buffer-local-value 'drgnx-view-patch htw))))
      (should (eq (cadr parts) (drgnx-agent-panel--composer-of buf)))
      ;; asked again: the same twin
      (should (eq htw (car (drgnx-agent-panel--companions tw))))
      ;; the panel's own buffer still has the header itself
      (should (eq header (car (drgnx-agent-panel--companions buf)))))))

(ert-deftest drgnx-agent-panel-companions/killing-the-panel-kills-its-companions-and-their-twins ()
  (drgnx-agent-panel-companions-test--with
    (let* ((header (drgnx-agent-panel--header-of buf)) (composer (drgnx-agent-panel--composer-of buf))
           (tw (drgnx-agent-panel-companions-test--twin buf "tty-test"))
           (htw (car (drgnx-agent-panel--companions tw))))
      (kill-buffer buf)
      (should-not (buffer-live-p header))
      (should-not (buffer-live-p composer))
      (should-not (buffer-live-p tw))
      (should-not (buffer-live-p htw)))))

(provide 'agent-panel-companions-test)
;;; agent-panel-companions-test.el ends here
