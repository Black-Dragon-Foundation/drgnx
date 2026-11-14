;;; wb-outline-edge-test.el --- batch tests: the Outline section, edge cases -*- lexical-binding: t -*-
;; test-class: det
;; The section with no hub (its rows come from one: wb-outline-test.el): it says it waits, and it follows the editor's
;; saves only while shown.
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-outline)

(defmacro drgnx-outline-edge-test--with (src &rest body)
  "BODY with SRC an Emacs Lisp buffer in the editor, no hub (a batch Emacs never connects one), and the Outline shown in the dock."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let ((drgnx-wb--sections nil) (drgnx-wb--collapsed (list (cons 'outline nil)))   ; open: not its fold
           (drgnx-outline--source nil) (drgnx-outline--sent :none) (drgnx-outline--reveal nil)
           (drgnx-outline--mark nil) (drgnx-outline--waiting nil)
           (,src (generate-new-buffer "outline-edge-src.el")))
       (delete-other-windows)
       (with-current-buffer ,src
         (insert "(defun alpha () 1)\n")
         (emacs-lisp-mode))
       (switch-to-buffer ,src)
       (drgnx-test-use-editor (selected-window))
       (drgnx-outline-setup)
       (drgnx-wb-show-sidebar)
       (unwind-protect (progn (drgnx-outline-refresh) ,@body)
         (drgnx-outline--watch nil)
         (drgnx-wb-hide-sidebar)
         (delete-other-windows)
         (kill-buffer ,src)
         (when (get-buffer drgnx-outline-buffer-name) (kill-buffer drgnx-outline-buffer-name))))))

(defun drgnx-outline-edge-test--watched-p (buffer)
  (memq #'drgnx-outline--saved (buffer-local-value 'after-save-hook buffer)))

(ert-deftest drgnx-outline-edge/with-the-hub-down-it-says-it-waits ()
  (drgnx-outline-edge-test--with src
    (with-current-buffer drgnx-outline-buffer-name
      (should (overlayp drgnx-outline--waiting))
      (should (string-match-p "Waiting for the hub" (overlay-get drgnx-outline--waiting 'before-string))))
    (should (eq drgnx-outline--source src))))

(ert-deftest drgnx-outline-edge/a-hidden-outline-stops-watching-saves ()
  "Hidden, the Outline lets go of the source's `after-save-hook'; shown again, it follows it again."
  (drgnx-outline-edge-test--with src
    (should (drgnx-outline-edge-test--watched-p src))
    (drgnx-wb-hide-sidebar)
    (drgnx-outline-refresh)                        ; the bus's editor-changed edge
    (should-not (drgnx-outline-edge-test--watched-p src))
    (should-not drgnx-outline--source)
    (drgnx-wb-show-sidebar)                        ; :on-show watches again
    (should (drgnx-outline-edge-test--watched-p src))))

(ert-deftest drgnx-outline-edge/no-keystroke-goes-anywhere ()
  "The Outline adds nothing to the source's edits: no change hook (the hub reads unsaved text from the edit history)."
  (drgnx-outline-edge-test--with src
    (should-not (seq-find (lambda (f) (and (symbolp f) (string-prefix-p "drgnx-outline" (symbol-name f))))
                          (buffer-local-value 'after-change-functions src)))))

(ert-deftest drgnx-outline-edge/ret-is-a-registry-command ()
  ;; I10: keys come from the profiles, never a direct `define-key'.
  (should-not (lookup-key (let ((m (copy-keymap drgnx-outline-mode-map))) (set-keymap-parent m nil) m) (kbd "RET"))))

;;; wb-outline-edge-test.el ends here
