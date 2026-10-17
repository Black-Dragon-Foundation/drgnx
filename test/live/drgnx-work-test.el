;;; drgnx-work-test.el --- live: the Work tab in a GUI session -*- lexical-binding: t -*-
;; The tab scans in another Emacs and fills in, sits in the right dock, a task opens its plan in the
;; editor at its line, the graph opens in the editor, nothing unrouted.
(require 'ert)
(require 'drgnx-ui)

(defun drgnx-live-wk--q (sess form)
  (car (read-from-string (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form) 60) :v))))

(defun drgnx-live-wk--until (sess form secs)
  "Poll FORM in SESS until non-nil (SECS at most); its value."
  (let ((deadline (+ (float-time) secs)) v)
    (while (and (not (setq v (drgnx-live-wk--q sess form))) (< (float-time) deadline)) (sleep-for 0.2))
    v))

(ert-deftest drgnx-live/the-work-tab-fills-in-and-opens-what-it-shows ()
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-work-live" t)))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root "ui") process-environment))
         (s nil) (sess nil))
    (make-directory (concat root "docs/specs") t) (make-directory (concat root "docs/plans") t)
    (write-region "# The Spec\n" nil (concat root "docs/specs/s.md") nil 'silent)
    (write-region "# Plan Alpha\n\n**Spec:** `../specs/s.md`\n\n### Task 1: first\n\n- [x] a\n\n### Task 2: second\n\n- [ ] b\n"
                  nil (concat root "docs/plans/alpha.md") nil 'silent)
    (unwind-protect
        (progn
          (setq s (drgnx-ui-start "drgnx" "1400x800" 30) sess (drgnx-ui-own-session (plist-get s :name)))
          (drgnx-live-wk--q sess (format "(progn (setenv \"DRGNX_DATA_DIR\" %S) (setq drgnx-work-roots (list %S) drgnx-projects-board-file %S)
                                                 (drgnx-work-ui-view) t)"
                                         (concat root "data") root (concat root "none.org")))
          (should (drgnx-live-wk--until sess "(with-current-buffer \"*drgnx Work*\" (string-search \"Plan Alpha\" (buffer-string)))" 60))
          (should (equal (drgnx-live-wk--q sess "(list (buffer-name (window-buffer (drgnx-wb-area-window 'right))) (drgnx-wb-area-tab 'right))")
                         '("*drgnx Work*" work)))
          ;; unfold the plan, open its second task: the plan, at that line, in an editor window
          (should (equal (drgnx-live-wk--q sess "(with-selected-window (drgnx-wb-area-window 'right)
                                                   (goto-char (point-min)) (search-forward \"Plan Alpha\") (drgnx-work-ui-toggle)
                                                   (goto-char (point-min)) (search-forward \"Task 2: second\")
                                                   (drgnx-work-ui-open)
                                                   (list (file-name-nondirectory (buffer-file-name)) (line-number-at-pos)
                                                         (and (drgnx-signal-editor-window-p (selected-window)) t)))")
                         '("alpha.md" 9 t)))
          (should (drgnx-live-wk--q sess "(progn (drgnx-work-ui-graph)
                                           (and (seq-find (lambda (w) (and (equal (buffer-name (window-buffer w)) \"*work graph*\") (drgnx-signal-editor-window-p w))) (window-list)) t))"))
          (drgnx-ui-measure sess nil)
          (should (equal (drgnx-live-wk--q sess "(length drgnx-wb-unrouted)") 0)))
      (when s (drgnx-ui-stop (plist-get s :name)))
      (delete-directory root t))))

;;; drgnx-work-test.el ends here
