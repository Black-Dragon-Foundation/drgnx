;;; agent-panel-edits-gui-test.el --- GUI test: an agent in your checkout never claims your changes (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; S1-2 of the UX audit (2026-11-16): a real hub, a mock agent working in a checkout that holds your uncommitted line
;; and your untracked file, and the agent panel open on it.  The panel's edits ledger lists only the agent's own hunk,
;; never your file, and its Reject takes back only the agent's line: yours stays.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-panel-edits--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-panel-edits--repo)))
(require 'drgnx-keys)   ; loaded before the leak check's snapshot, as the other panel rows do
(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-ui-panel-edits--repo) nil t)

(defvar drgnx-panel-replay-prefix)
(defvar drgnx-panel-replay-project)
(defvar drgnx-view-patch--buffers)
(defvar drgnx-view-patch--hooked)
(defvar drgnx-view-env--views)
(defvar drgnx-view-env--sent)
(defvar drgnx-view-env--glyphs)
(defvar drgnx-view-env--hooked)
(declare-function drgnx-panel-replay-up "panel-replay-fixture" (bin))
(declare-function drgnx-panel-replay-down "panel-replay-fixture" ())
(declare-function drgnx-panel-replay-program "panel-replay-fixture" ())
(declare-function drgnx-rows-demo--bin "rows-demo-fixture" ())
(declare-function drgnx-view-env-teardown "drgnx-view-env" ())
(declare-function drgnx-view-patch-teardown "drgnx-view" ())
(declare-function drgnx-agent-panel-ledger "drgnx-agent-panel-cards" ())
(declare-function drgnx-agent-panel-reject "drgnx-agent-panel-cards" ())

(defun drgnx-ui-panel-edits--git (dir &rest args)
  (let ((default-directory (file-name-as-directory dir)))
    (unless (zerop (apply #'call-process "git" nil nil nil "-c" "user.name=t" "-c" "user.email=t@localhost"
                          "-c" "commit.gpgsign=false" args))
      (error "git %S failed" args))))

(defun drgnx-ui-panel-edits--text (panel)
  "The panel's text (its transcript window), without properties."
  (with-current-buffer panel (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest drgnx-ui-panel-edits/your-changes-are-never-the-agents ()
  "Your uncommitted line and untracked file are not in the agent's edits ledger; its Reject keeps your line."
  (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-view-rows)))
  (load (expand-file-name "test/fixtures/panel-replay-fixture" drgnx-ui-panel-edits--repo) nil t)
  (let* ((project (make-temp-file "drgnx-panel-edits" t))
         (a (expand-file-name "a.txt" project)) (notes (expand-file-name "NOTES.txt" project))
         (load-path (cons (expand-file-name "modules/tools" drgnx-ui-panel-edits--repo) load-path))
         (drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
         (drgnx-view-env--views (make-hash-table :test #'equal)) (drgnx-view-env--sent (make-hash-table :test #'equal))
         (drgnx-view-env--glyphs (make-hash-table :test #'equal)) (drgnx-view-env--hooked nil)
         (drgnx-panel-replay-prefix 0) (drgnx-panel-replay-project project) (panel nil))
    ;; your checkout: a commit, then your own uncommitted line and an untracked file
    (with-temp-file a (insert "one\ntwo\n"))
    (drgnx-ui-panel-edits--git project "init" "-q" "-b" "main")
    (drgnx-ui-panel-edits--git project "add" "a.txt")
    (drgnx-ui-panel-edits--git project "commit" "-q" "-m" "init")
    (with-temp-file a (insert "one\ntwo\nmine\n"))
    (with-temp-file notes (insert "new\n"))
    (unwind-protect
        ;; the agent's one turn: it reads, then appends its own line to a.txt (the audit's repro)
        (cl-letf (((symbol-function 'drgnx-panel-replay-program)
                   (lambda () "say looking\\ntool:edit a.txt\\nsay done")))
          (save-window-excursion
            (setq panel (drgnx-panel-replay-up (drgnx-rows-demo--bin)))
            (drgnx-test-wait (lambda () (with-temp-buffer (insert-file-contents a)
                                                          (string-search "edited by ratatoskr-mock" (buffer-string))))
                             :secs 30 :what "the agent's edit of a.txt")
            ;; the ledger opens and lists the agent's hunk in a.txt only
            (drgnx-test-wait (lambda () (string-search "Edits ·" (drgnx-ui-panel-edits--text panel)))
                             :secs 30 :what "the panel's Edits card")
            (with-current-buffer panel
              (goto-char (point-min)) (search-forward "Edits ·") (drgnx-agent-panel-ledger))
            (drgnx-test-wait (lambda () (with-current-buffer panel
                                          (next-single-property-change (point-min) 'drgnx-agent-panel-op-hunk)))
                             :secs 15 :what "the ledger's hunk rows")
            (let ((text (drgnx-ui-panel-edits--text panel)))
              (should (string-search "Edits · 1 file" text))
              (should-not (string-search "NOTES.txt" text))
              (should (string-match-p "a\\.txt  4–4" text)))
            ;; Reject on the hunk's line: the agent's line goes, yours stays, your untracked file is untouched
            (with-current-buffer panel
              (goto-char (next-single-property-change (point-min) 'drgnx-agent-panel-op-hunk))
              (drgnx-agent-panel-reject))
            (drgnx-test-wait (lambda () (equal "one\ntwo\nmine\n"
                                               (with-temp-buffer (insert-file-contents a) (buffer-string))))
                             :secs 15 :what "the Reject taking back only the agent's line")
            (should (file-exists-p notes))))
      (drgnx-panel-replay-down)
      (drgnx-view-env-teardown)
      (drgnx-view-patch-teardown)
      (delete-directory project t))))

;;; agent-panel-edits-gui-test.el ends here
