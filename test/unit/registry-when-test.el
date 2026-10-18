;;; registry-when-test.el --- batch tests: palette-only view commands never act on the buffer they are run from -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-agents)
(load (expand-file-name "modules/tools/drgnx-diff" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-review" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-prs" drgnx-dir) nil t)

(defconst drgnx-registry-when-test--anywhere
  '(diff-working diff-staged diff-branch review-branch review-view review-refresh prs-view prs-fetch)
  "The diff-*, review-* and prs-* commands that start from any buffer (they open a view, ask git or the forge).
Every other command of those families belongs to a view and must refuse to act anywhere else.")

(defun drgnx-registry-when-test--view-commands ()
  "The registered view-only commands of the diff, review and Pull Requests modules."
  (dolist (m '(tools/diff tools/review tools/prs))        ; the modules' setups register them (their hooks are not wanted)
    (cl-letf (((symbol-function 'add-hook) #'ignore))
      (funcall (plist-get (cdr (assq m drgnx-modules--table)) :setup))))
  (seq-filter (lambda (cmd)
                (and (string-match-p "\\`\\(diff\\|review\\|prs\\)-" (symbol-name (drgnx-cmd-id cmd)))
                     (not (memq (drgnx-cmd-id cmd) drgnx-registry-when-test--anywhere))))
              (drgnx-commands-all)))

(ert-deftest drgnx-registry-when/view-commands-refuse-a-file-buffer ()
  ;; M11b-14: run from the palette in a file buffer, a view's command is a user-error and the buffer is untouched
  (let ((cmds (drgnx-registry-when-test--view-commands)) (drgnx-review--current nil))
    (when (get-buffer "*drgnx pull requests*") (kill-buffer "*drgnx pull requests*"))
    (should (>= (length cmds) 9))                           ; the families are found, not an empty loop
    (dolist (cmd cmds)
      (with-temp-buffer
        (emacs-lisp-mode)
        (insert "(keep me)")
        (let ((before (list (buffer-string) (point) major-mode (buffer-modified-p))))
          (should-error (funcall (drgnx-cmd-command cmd)) :type 'user-error)
          (should (equal before (list (buffer-string) (point) major-mode (buffer-modified-p)))))))))

;;; registry-when-test.el ends here
