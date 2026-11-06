;;; history-cards-gui-test.el --- GUI tests: the revert card and the merge card under both themes (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; The revert card (every section, a blocked revert, a finished worker) and the merge card are drawn in a window under
;; drgnx-dark and drgnx-light, and the picture is saved (to $DRGNX_TEST_SHOTS, else a temp folder) as
;; history-<card>-<theme>.png: the evidence of how the cards look at the session's scale.  Pattern D: each
;; picture is taken after `drgnx-test-wait-presented'.  The rows also read the cards' faces: they name no colour of their
;; own, and their text is readable against the window's background.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-history-cards--repo         ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-history-cards--repo)))
(require 'drgnx)
(require 'drgnx-history-revert)
(require 'drgnx-color)

(defconst drgnx-ui-history-cards--preview
  '(:preview_id 7 :session "worker-2" :seq 12 :files ("src/parser.rs" "src/lexer.rs") :non_overlapping_files ("README.md")
                :overlaps ((:path "src/lexer.rs" :reverted "agent text" :users "user text"))
                :effects (:pushed ((:commit "abc1234" :refs ("origin/main"))) :messages_read (1 2) :decisions_relied_on (4)
                                  :tasks_filed ("fix the build") :merges ("def5678 into main") :settings ("agents.profile")
                                  :spent (:cost_by_unit nil :tokens 183000) :jobs_running ("j1 (here)") :label "computed")
                :level "summary" :needs_message t :blocked ((:decision 4 :commit "def5678" :session "worker-3" :branch "job/lexer"))
                :skipped ((:path "build.rs" :reason "refused-by-hook"))
                :conversation (:state "not-restored" :label "conversation not restored: the agent has finished") :fork t)
  "A preview with every part of the card in it.")

(defun drgnx-ui-history-cards--shot (name theme)
  "Save the root frame's picture as history-NAME-THEME.png; its path."
  (let* ((dir (or (getenv "DRGNX_UI_EVIDENCE") (getenv "DRGNX_TEST_SHOTS") (make-temp-file "history-cards" t)))
         (shot (plist-get (drgnx-uitest-capture (make-temp-file "history-shot" t)) :root))
         (target (expand-file-name (format "history-%s-%s.png" name theme) dir)))
    (make-directory dir t)
    (copy-file shot target t)
    target))

(defun drgnx-ui-history-cards--readable-p (face)
  "Whether FACE's foreground differs enough from the default background to read (contrast ratio over 3)."
  (let ((fg (face-foreground face nil t)) (bg (face-background 'default nil t)))
    (when (member fg '(nil "unspecified-fg")) (setq fg (face-foreground 'default)))   ; a face that only inherits bold
    (and fg bg (>= (drgnx-color-contrast fg bg) 3.0))))

(ert-deftest drgnx-ui-history-cards/both-themes ()
  (drgnx-uitest-bare-frame)
  (let ((buffers nil))
    (unwind-protect
        (dolist (theme '(drgnx-dark drgnx-light))
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme theme t)
          (delete-other-windows)
          (let ((card (drgnx-history-revert--open drgnx-ui-history-cards--preview)))
            (push card buffers)
            (switch-to-buffer card)
            (delete-other-windows)
            (drgnx-test-wait-presented)
            (should (file-exists-p (drgnx-ui-history-cards--shot "revert" theme)))
            (dolist (face '(drgnx-history-heading drgnx-history-effect drgnx-history-label drgnx-ui-button))
              (should (drgnx-ui-history-cards--readable-p face))))
          (let* ((file (make-temp-file "card" nil ".txt" "disk text\n"))
                 (b (find-file-noselect file))
                 (drgnx-history-revert--waiting nil))
            (with-current-buffer b (goto-char (point-max)) (insert "an unsaved line\n"))
            (with-temp-file file (insert "reverted text\n"))
            (setq drgnx-history-revert--waiting (list (cons 1 b)))
            (drgnx-history-resolve-dirty 1)
            (delete-other-windows)
            (push (current-buffer) buffers)
            (drgnx-test-wait-presented)
            (should (file-exists-p (drgnx-ui-history-cards--shot "merge" theme)))
            (with-current-buffer b (set-buffer-modified-p nil))
            (kill-buffer b)
            (delete-file file)))
      (mapc #'disable-theme custom-enabled-themes)
      (dolist (b buffers) (when (buffer-live-p b) (kill-buffer b))))))

(provide 'history-cards-gui-test)
;;; history-cards-gui-test.el ends here
