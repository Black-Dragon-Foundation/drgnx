;;; mod-extras-test.el --- batch tests: modules that need packages -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defconst drgnx-extras-test--modules
  '(("extra/drgnx-jump" extra/jump (avy) (go-jump))
    ("extra/drgnx-undo" extra/undo (vundo) (edit-undo-tree))
    ("extra/drgnx-wgrep" extra/wgrep (wgrep) (search-edit-results search-apply-edits))
    ("extra/drgnx-hunks" extra/hunks (diff-hl) (git-hunk-show git-hunk-revert git-hunk-stage))
    ("extra/drgnx-keycast" extra/keycast (keycast) (view-keycast))
    ("extra/drgnx-llm" extra/llm (gptel) (llm-menu llm-send))
    ("extra/drgnx-magit" extra/magit (magit) (scm-view))
    ("extra/drgnx-completion" extra/completion (vertico orderless marginalia corfu) ()))
  "FILE MODULE PACKAGES COMMANDS.")

(defconst drgnx-extras-test--elpa (expand-file-name (or (getenv "DRGNX_USER_ELPA") "~/.config/emacs/elpa"))
  "The user's ELPA, used read-only when present (as the benchmark does for treemacs).")

(defmacro drgnx-extras-test--fresh (&rest body)
  `(let* ((cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
     (unwind-protect
         (progn (pcase-dolist (`(,file . ,_) drgnx-extras-test--modules)
                  (load (expand-file-name (concat "modules/" file) drgnx-dir) nil t))
                ,@body)
       (delete-directory cfg t))))

(ert-deftest drgnx-extras/without-packages-they-wait ()
  (let ((load-path (seq-remove (lambda (d) (string-prefix-p drgnx-extras-test--elpa d)) load-path)))
    (drgnx-extras-test--fresh
     (let ((pkgs (seq-mapcat (lambda (m) (nth 2 m)) drgnx-extras-test--modules)) (orig (symbol-function 'featurep)))
       (cl-letf (((symbol-function 'locate-library) (lambda (&rest _) nil))
                 ((symbol-function 'featurep) (lambda (f &rest r) (and (not (memq f pkgs)) (apply orig f r)))))
         (drgnx-modules-run 'idle)))
     (pcase-dolist (`(,_ ,mod ,_ ,cmds) drgnx-extras-test--modules)
       (should (eq (plist-get (alist-get mod (drgnx-modules-report)) :status) 'missing-packages))
       (dolist (c cmds) (should-not (drgnx-commands-get c)))))))

(ert-deftest drgnx-extras/with-packages-they-run ()
  (skip-unless (file-directory-p drgnx-extras-test--elpa))
  (let ((load-path (append load-path (seq-filter #'file-directory-p (directory-files drgnx-extras-test--elpa t "\\`[^.]"))))
        ;; extra/llm points gptel at the `chat' role's OpenRouter step (a key: a fake one, never sent)
        (process-environment (cons "OPENROUTER_API_KEY=sk-or-fake" process-environment)))
    (drgnx-test-with-modules (mapcar #'cadr drgnx-extras-test--modules) :strict t
                             (pcase-dolist (`(,_ ,mod ,_ ,cmds) drgnx-extras-test--modules)
                               (should (equal (list mod (plist-get (alist-get mod (drgnx-modules-report)) :status)) (list mod 'ok)))
                               (dolist (c cmds) (should (drgnx-commands-get c)))))))

(ert-deftest drgnx-modules/later-stages-re-apply-the-keys ()
  ;; A module that runs at idle registers commands after the keys were applied.
  (let* ((drgnx-modules--table nil) (drgnx-modules--report nil) (seen nil)
         (drgnx-modules-after-stage-functions (list (lambda (stage) (push stage seen)))))
    (drgnx-module-define 'test/late :doc "l" :stage 'idle :setup #'ignore)
    (drgnx-modules-run 'idle)
    (should (equal seen '(idle)))))
