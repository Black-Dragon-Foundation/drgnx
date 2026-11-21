;;; lint-chrome-scale-test.el --- lint: the Flow chrome's Lisp text uses canonical widths (Flow Task 29) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  Every Lisp text the Flow plan's chrome inserts into buffers (the conversation, the composer, the
;; Agents side, the shell's rail glue) uses canonical-character widths (spec §3.1) or the kit's per-frame pads
;; (`drgnx-ui-kit--pad'), never an absolute `(space :width (N))', which is right at one scale only.
;; Written before Tasks 19, 24 and 23's remaining parts: it guards the files they add and change, so it is green on a
;; base that has none of them wrong.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)

(defconst lint-chrome-scale-test--files
  '("modules/tools/drgnx-agent-panel.el" "modules/tools/drgnx-agent-panel-composer.el"
    "modules/tools/drgnx-agent-panel-header.el" "modules/tools/drgnx-agent-panel-list.el"
    "modules/tools/drgnx-agents-ask.el" "modules/ui/drgnx-rail.el" "wb/drgnx-frame-shell.el")
  "The Lisp files of this plan's chrome that insert text into buffers.")

(ert-deftest drgnx-lint-chrome-scale/no-absolute-space-width-in-our-inserted-text ()
  (let (bad)
    (dolist (f lint-chrome-scale-test--files)
      (let ((path (expand-file-name f drgnx-dir)))
        (when (file-exists-p path)
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (while (re-search-forward "(space :width (" nil t)
              (push (format "%s:%d" f (line-number-at-pos)) bad))))))
    (should-not bad)))

(ert-deftest drgnx-lint-chrome-scale/the-lint-sees-a-form-it-is-written-for ()
  "The scan finds the form in a file that has it: the lint is not blind."
  (with-temp-buffer
    (insert "(propertize \" \" 'display '(space :width (4)))")
    (goto-char (point-min))
    (should (re-search-forward "(space :width (" nil t))))

(provide 'lint-chrome-scale-test)
;;; lint-chrome-scale-test.el ends here
