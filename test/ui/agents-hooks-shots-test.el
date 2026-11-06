;;; agents-hooks-shots-test.el --- a refused step, the context breakdown and the approval screen on screen -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Each view is drawn from fixture state (no hub) in the selected window and captured under a dark and a light theme.
;; The evidence folder (DRGNX_UI_EVIDENCE) keeps the PNGs.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-hooks-shots--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-hooks-shots--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-hooks-shots--repo))
(add-to-list 'load-path (expand-file-name "modules/ui" drgnx-hooks-shots--repo))
(require 'drgnx)
(require 'drgnx-agents)
(require 'drgnx-agents-hooks)
(load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-hooks-shots--repo) nil t)
(load (expand-file-name "modules/tools/drgnx-plugins-ui" drgnx-hooks-shots--repo) nil t)

(defun drgnx-hooks-shots--session ()
  "A hub session with a refused step, a changed one, a note, hooked marks and a breakdown."
  (drgnx-agents--make
   :name "claude · demo" :remote "h1" :status 'busy
   :hooked '(:unhooked ("read" "fetch") :by_adapter ("edit") :why "the agent runs them without asking")
   :plugins-changed t
   :panel '(:features ("context" "drop" "pin" "compact-preview")
                      :context (:used 84000 :size 200000 :compact_frees 31000
                                      :parts ((:kind "system" :tokens 9000)
                                              (:kind "tools" :tokens 14000)
                                              (:kind "files" :tokens 31000
                                                     :items ((:id "f1" :label "src/lib.rs" :tokens 18000)
                                                             (:id "f2" :label "Cargo.lock" :tokens 13000)))
                                              (:kind "tool-output" :tokens 12000)
                                              (:kind "conversation" :tokens 18000))))
   :hooks (list (list 4 "t1" '((:point "before-tool" :at "seam" :tool "Bash" :step 4 :outcome "deny"
                                       :records ((:source "plugin:deny-rm@0.1#ab12" :verdict "deny" :ms 3
                                                          :reason "rm outside the worktree")))))
                (list 6 "t2" '((:point "before-tool" :at "hub-server" :tool "mcp__drgnx__commit" :step 6 :outcome "change"
                                       :records ((:source "plugin:rewrite-commit-msg@1.0#cd34" :verdict "change" :ms 2))))))
   :entries (list '(:type user :text "clean up the build folder")
                  '(:type tool :id "t1" :title "Bash: rm -rf /tmp/build ../other" :status "failed")
                  '(:type tool :id "t2" :title "commit" :status "completed")
                  '(:type note :source "plugin:annotate-edit@1#aa" :text "touches the lockfile" :step 5)
                  '(:type agent :text "The first command was refused, so I kept to the worktree."))))

(defun drgnx-hooks-shots--rows ()
  (list (list :name "deny-rm" :version "0.1" :hash (make-string 64 ?a) :state "unapproved"
              :abilities '("rm_check")
              :hooks '((:point "before-tool" :verdicts ("allow" "deny" "change") :tool_kinds ("execute") :tools ("Bash"))
                       (:point "after-edit" :verdicts ("annotate" "change") :paths ("src/**")))
              :hosts '("api.example.com:443") :kv_bytes 65536)))

(defun drgnx-hooks-shots--shoot (name show)
  "Show the buffer SHOW returns in the selected window, capture the root frame and keep it as NAME.png."
  (let ((buf (funcall show)))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (delete-other-windows)
          (goto-char (point-min))
          (redisplay t)
          (let* ((dir (make-temp-file "hooks-shots" t))
                 (shot (plist-get (drgnx-uitest-capture dir) :root))
                 (out (expand-file-name (format "%s.png" name) temporary-file-directory)))
            (should (file-exists-p shot))
            (copy-file shot out t)
            (drgnx-uitest--evidence out)
            (message "hooks screenshot: %s" out)))
      (kill-buffer buf))))

(defun drgnx-hooks-shots--views (theme)
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme theme t)
  (let ((tag (if (eq theme 'modus-vivendi) "dark" "light")) (s (drgnx-hooks-shots--session)))
    (drgnx-hooks-shots--shoot
     (format "refused-step-%s" tag)
     (lambda ()
       (with-current-buffer (generate-new-buffer " *hooks-shot*")
         (special-mode)
         (let ((inhibit-read-only t)) (drgnx-agents-ui-render s))
         (current-buffer))))
    (drgnx-hooks-shots--shoot (format "context-breakdown-%s" tag)
                              (lambda () (drgnx-agents-hooks-context-buffer s)))
    (drgnx-hooks-shots--shoot
     (format "approval-%s" tag)
     (lambda ()
       (let ((drgnx-plugins--rows (drgnx-hooks-shots--rows)))
         (with-current-buffer (generate-new-buffer " *hooks-shot*")
           (drgnx-plugins-page-mode)
           (drgnx-plugins--render)
           (current-buffer)))))
    (disable-theme theme)))

(ert-deftest drgnx-hooks-shots/dark-and-light ()
  (drgnx-hooks-shots--views 'modus-vivendi)
  (drgnx-hooks-shots--views 'modus-operandi))

(provide 'agents-hooks-shots-test)
;;; agents-hooks-shots-test.el ends here
