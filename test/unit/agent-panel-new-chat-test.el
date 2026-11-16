;;; agent-panel-new-chat-test.el --- the agent panel with no session: a new chat (audit A1) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: pure.  No hub: the pane and the agent start are recorded.
;; The 2026-11-16 audit (A1): "Agents: Open the Agent Panel" with no session only echoed "No agent session to show";
;; VS Code's chat opens empty, with an input that starts one.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/agent-panel))

(defvar drgnx-agents--sessions)
(defvar drgnx-agent-panel--new-chat-hint)

(ert-deftest agent-panel-new-chat/opening-with-no-session-shows-an-empty-chat ()
  "With no session, opening the panel shows a new chat in the right dock, selected and empty, with a placeholder; what
is sent starts an agent of the default profile with that text, and the chat empties."
  (let ((drgnx-agents--sessions nil) shown asked)
    (cl-letf (((symbol-function 'drgnx-pane-show)
               (lambda (kind &rest args) (setq shown (list kind (plist-get args :buffer) (plist-get args :select)))))
              ((symbol-function 'drgnx-agents-session-ask) (lambda (text) (push text asked))))
      (unwind-protect
          (progn
            (call-interactively #'drgnx-agent-panel-open)
            (should (eq (nth 0 shown) 'agent-panel))
            (should (nth 2 shown))
            (with-current-buffer (nth 1 shown)
              (should (derived-mode-p 'drgnx-agent-panel-new-chat-mode))
              (should (string-search "New chat" (format "%s" header-line-format)))
              (should (string-search "Ask an agent" (format "%s" (overlay-get drgnx-agent-panel--new-chat-hint
                                                                              'after-string))))
              (should-error (drgnx-agent-panel-new-chat-send) :type 'user-error)          ; nothing typed
              (insert "  why does the build fail? ")
              (drgnx-agent-panel--new-chat-placeholder)
              (should-not (overlay-get drgnx-agent-panel--new-chat-hint 'after-string))
              (drgnx-agent-panel-new-chat-send)
              (should (equal asked '("why does the build fail?")))
              (should (= (point-min) (point-max)))))
        (when-let* ((b (get-buffer "*drgnx new chat*"))) (kill-buffer b))))))

(ert-deftest agent-panel-new-chat/the-dock-with-no-panel-shows-the-new-chat ()
  "The right dock's agent pane with no panel open shows the new chat, not a blank buffer."
  (unwind-protect
      (cl-letf (((symbol-function 'drgnx-agent-panel-buffers) #'ignore))
        (with-current-buffer (drgnx-agent-panel--current-buffer)
          (should (derived-mode-p 'drgnx-agent-panel-new-chat-mode))))
    (when-let* ((b (get-buffer "*drgnx new chat*"))) (kill-buffer b))))

(provide 'agent-panel-new-chat-test)
;;; agent-panel-new-chat-test.el ends here
