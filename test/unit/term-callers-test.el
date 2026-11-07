;;; term-callers-test.el --- batch tests: drgnx's callers of the terminal (quit, key sheet, panel, input modes) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-terminal" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-term" drgnx-dir) nil t)

(defvar drgnx-modal-input-modes)
(defvar drgnx-close-input-modes)
(defvar drgnx-surfaces-cheatsheet-sections)

(ert-deftest drgnx-term-callers/quit-question-times-out-as-running ()
  ;; the hub does not answer `term/list' in time: every open terminal counts as running, so nothing stops unasked;
  ;; answered, a shell at its prompt is not named
  (let ((drgnx-term--buffers (make-hash-table :test #'equal)) (b (generate-new-buffer "*terminal*")))
    (unwind-protect
        (progn
          (with-current-buffer b (drgnx-term-mode) (setq drgnx-term--id "t1" drgnx-term--state 'open))
          (puthash "t1" b drgnx-term--buffers)
          (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                     (lambda (method _params timeout)
                       (should (equal method "term/list"))
                       (should (equal timeout drgnx-term-list-wait))
                       (error "The drgnx hub did not answer term/list"))))
            (should (equal (drgnx-term-running) (list (buffer-name b)))))
          (cl-letf (((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (list (list :id "t1" :running nil)))))
            (should-not (drgnx-term-running)))
          ;; a terminal that is not open (its command ended) is never asked about
          (with-current-buffer b (setq drgnx-term--state 'exited))
          (cl-letf (((symbol-function 'drgnx-hub-call-sync) (lambda (&rest _) (error "Not asked"))))
            (should-not (drgnx-term-running))))
      (kill-buffer b))))

(ert-deftest drgnx-term-callers/key-sheet-has-terminal-section-without-advice ()
  ;; the "In the terminal" section comes through core's sheet hook: the module advises nothing of the sheet's
  (drgnx-test-with-modules '(tools/terminal tools/term) :strict t
                           (should (memq 'drgnx-terminal-cheatsheet-section drgnx-surfaces-cheatsheet-sections))
                           (should-not (advice--p (advice--symbol-function 'drgnx-surfaces-cheatsheet)))
                           ;; no key profile is applied in batch: the split is given, the hook is what is tested
                           (cl-letf (((symbol-function 'drgnx-terminal-key-split)
                                      (lambda (&rest _) (list :to-drgnx '("C-S-p") :to-shell '("C-w")))))
                             (should (assoc "In the terminal" (drgnx-surfaces--sections)))))
  (should-not (memq 'drgnx-terminal-cheatsheet-section drgnx-surfaces-cheatsheet-sections)))

(ert-deftest drgnx-term-callers/terminal-buffer-goes-to-the-panel ()
  ;; by its mode, whatever its name (a temp buffer's name is internal, which only name rules take)
  (drgnx-test-with-modules '(core/workbench)
    (let ((b (generate-new-buffer "drgnx-term-callers")))
      (unwind-protect
          (with-current-buffer b
            (drgnx-term-mode)
            (let ((rule (drgnx-wb-rule-for b)))
              (should (eq (car rule) 'panel))
              (should (eq (plist-get (cdr rule) :tab) 'terminal))))
        (kill-buffer b)))))

(ert-deftest drgnx-term-callers/a-terminal-takes-typed-input ()
  ;; the modal engines start it in insert state, and Esc and q are the program's, never Close Pane
  (require 'drgnx-close (expand-file-name "modules/ui/drgnx-close" drgnx-dir))
  (should (memq 'drgnx-term-mode drgnx-modal-input-modes))
  (should (memq 'drgnx-term-mode drgnx-close-input-modes))
  (should-not (memq 'eat-mode drgnx-modal-input-modes)))

(provide 'term-callers-test)
;;; term-callers-test.el ends here
