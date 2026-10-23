;;; drgnx-ai-test.el --- live: ghost text and inline edit in a GUI session, a mock model answering -*- lexical-binding: t -*-
;; Typing pauses, the suggestion shows as ghost text, Tab takes it; an inline edit opens a review, one of its two
;; hunks is applied with keys and Done puts only that one in the file's buffer.
(require 'ert)
(require 'drgnx-ui)
(load (expand-file-name "test/fixtures/mock-llm" drgnx-ui-repo-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-ui-repo-dir) nil t)

(defun drgnx-live-ai--q (sess form)
  (car (read-from-string (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form) 60) :v))))

(defun drgnx-live-ai--until (sess form secs)
  "Poll FORM in SESS until non-nil; its value (`drgnx-test-wait', at least 30 s or SECS)."
  (drgnx-test-wait (lambda () (drgnx-live-ai--q sess form)) :secs (max 30 secs) :what form))

(ert-deftest drgnx-live/ghost-text-takes-tab-and-an-inline-edit-is-reviewed-hunk-by-hunk ()
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-ai-live" t)))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root "ui") process-environment))
         (script (concat root "llm.eld"))
         (filler (mapconcat (lambda (i) (format ";; line %d\n" i)) (number-sequence 1 8) ""))
         (mock nil) (s nil) (sess nil))
    (make-directory (concat root "config") t)
    (with-temp-file script
      (prin1 `((:path "/api/tags" :body "{\"models\":[{\"name\":\"coder\"}]}")
               (:path "/api/generate" :body "{\"response\":\"sage \\\"hi %s\\\" name)\"}")
               (:path "/api/chat" :body ,(json-serialize
                                          (list :message (list :content (concat "```elisp\n(defun one () 10)\n" filler "(defun two () 20)\n```"))))))
             (current-buffer)))
    (write-region "(defun greet (name)\n  )\n" nil (concat root "a.el") nil 'silent)
    (write-region (concat "(defun one () 1)\n" filler "(defun two () 2)\n") nil (concat root "b.el") nil 'silent)
    (unwind-protect
        (progn
          (setq mock (drgnx-ai-test-mock-llm nil script))
          (with-temp-file (concat root "config/settings.el")
            (prin1 `(drgnx-settings :version 1
                                    (drgnx-ai-providers ((o :name "O" :kind ollama :url ,(format "http://127.0.0.1:%d" (process-get mock :port)) :caps (chat fim))))
                                    (drgnx-ai-roles ((complete (o . "coder")) (edit (o . "coder")))))
                   (current-buffer)))
          (setq s (drgnx-ui-start "drgnx" "1400x800" 30) sess (drgnx-ui-own-session (plist-get s :name)))
          ;; the session's providers: the mock, found running by the probe
          (drgnx-live-ai--q sess (format "(progn (setenv \"DRGNX_CONFIG_DIR\" %S) (drgnx-settings-apply-global) (drgnx-ai-probe nil) t)" (concat root "config")))
          (should (drgnx-live-ai--until sess "(drgnx-ai-usable-p 'o 'fim)" 10))
          ;; typing, then a pause: the suggestion shows; Tab takes it
          (drgnx-live-ai--q sess (format "(progn (find-file %S) (goto-char (point-min)) (forward-line 1) (back-to-indentation) drgnx-ai-ghost-mode)"
                                         (concat root "a.el")))
          (drgnx-ui-measure sess (list (list :type "mes")))
          ;; (a query runs in the server's buffer: it looks at the one on screen)
          (should (equal (drgnx-live-ai--until sess "(with-current-buffer (window-buffer (selected-window))
                                                       (and (drgnx-ai-ghost-text-shown) (substring-no-properties (drgnx-ai-ghost-text-shown))))"
                                               10)
                         "sage \"hi %s\" name)"))
          (drgnx-ui-measure sess (list (list :keys "TAB")))
          (should (equal (drgnx-live-ai--q sess "(with-current-buffer (window-buffer (selected-window)) (buffer-substring-no-properties (point-min) (point-max)))")
                         "(defun greet (name)\n  message \"hi %s\" name))\n"))   ; (the next pause asks again)
          ;; an inline edit of the whole of b.el: a review with two hunks; the second applied (keys), then Done
          (drgnx-live-ai--q sess (format "(progn (find-file %S) (drgnx-ai-edit \"bump\" (point-min) (point-max)) t)" (concat root "b.el")))
          (should (drgnx-live-ai--until sess "(and (get-buffer \"*AI edit: b.el*\") (get-buffer-window \"*AI edit: b.el*\")
                                                   (progn (select-window (get-buffer-window \"*AI edit: b.el*\")) (goto-char (point-min)) t))"
                                        10))
          (should (= (drgnx-live-ai--q sess "(with-current-buffer \"*AI edit: b.el*\" (how-many \"^@@\" (point-min) (point-max)))") 2))
          (drgnx-ui-measure sess (list (list :keys "n") (list :keys "n") (list :keys "C-c C-a")))
          (should (drgnx-live-ai--q sess "(eq (window-buffer (selected-window)) (get-buffer \"*AI edit: b.el*\"))"))   ; still the review
          (drgnx-ui-measure sess (list (list :keys "C-c C-c")))
          (should-not (drgnx-live-ai--q sess "(get-buffer \"*AI edit: b.el*\")"))
          (should (equal (drgnx-live-ai--q sess (format "(with-current-buffer (get-file-buffer %S) (buffer-string))" (concat root "b.el")))
                         (concat "(defun one () 1)\n" filler "(defun two () 20)\n")))
          (drgnx-ui-measure sess nil)
          (should (equal (drgnx-live-ai--q sess "(length drgnx-wb-unrouted)") 0)))
      (when s (drgnx-ui-stop (plist-get s :name)))
      (when mock (delete-process mock))
      (delete-directory root t))))

;;; drgnx-ai-test.el ends here
