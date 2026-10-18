;;; mod-evil-more-isolated.el --- batch tests (own Emacs, test/unit/modal-isolated-test.el): evil-collection per mode, insert-state keys by stack, multiple cursors -*- lexical-binding: t -*-
;; Needs the real evil and evil-collection: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it
;; those tests skip.  The macros come from mod-evil-isolated.el (its tests are defined too, never selected here).
;; Tests that need a process where evil-collection or a library is not loaded yet have their own files
;; (mod-evil-flag-isolated.el, mod-evil-lazy-isolated.el).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-modal)
(require 'drgnx-explorer)
(load (expand-file-name "test/unit/isolated/mod-evil-isolated" drgnx-dir) nil t)

(defvar evil-insert-state-map)
(defvar evil-collection-want-unimpaired-p)
(defvar global-evil-collection-unimpaired-mode)
(defvar drgnx-evil-collection-modes)
(declare-function dired "dired")
(declare-function multiple-cursors-mode "multiple-cursors-core")

(defun drgnx-evil-more-test--key (map key)
  "What KEY is in MAP itself (evil's own lookup: remaps and prefix maps included), nil when unbound."
  (let ((b (lookup-key map (kbd key))))
    (and b (not (numberp b)) b)))

(defun drgnx-evil-more-test--dir (name)
  "The directory of package NAME in the user's ELPA or the modal tests' one, nil when neither has it."
  (cl-some (lambda (elpa)
             (and elpa (file-directory-p elpa)
                  (car (directory-files elpa t (concat "\\`" (regexp-quote name) "-[0-9]")))))
           (list (getenv "DRGNX_USER_ELPA") drgnx-modal-test-elpa)))

;;;; evil-collection

(ert-deftest drgnx-evil-more/drgnx-modes-are-not-in-the-collection ()
  (drgnx-evil-test--running
    (should drgnx-evil-collection-modes)
    (dolist (m drgnx-evil-collection-modes)
      (should-not (string-prefix-p "drgnx-" (symbol-name (if (consp m) (car m) m)))))
    (require 'dired)
    (drgnx-evil-test--buffer b #'drgnx-explorer-mode
      (should (eq drgnx-modal-state 'emacs))
      (should (eq evil-state 'emacs)))))

(ert-deftest drgnx-evil-more/unimpaired-follows-the-engine ()
  (drgnx-evil-test--running
    (should (bound-and-true-p global-evil-collection-unimpaired-mode))
    (drgnx-evil-test--buffer b #'text-mode
      (should (eq (key-binding "]b") 'evil-next-buffer)))
    (should (null (drgnx-modal-sync-engine '((emacs)))))
    (should-not (bound-and-true-p global-evil-collection-unimpaired-mode))
    (drgnx-evil-test--buffer b #'text-mode
      (should-not (eq (key-binding "]b") 'evil-next-buffer)))
    (should (eq (drgnx-modal-sync-engine '((vim app editing window))) 'evil))
    (should (bound-and-true-p global-evil-collection-unimpaired-mode))
    (drgnx-evil-test--buffer b #'text-mode
      (should (eq (key-binding "]b") 'evil-next-buffer)))))

(ert-deftest drgnx-evil-more/unimpaired-stays-off-when-not-wanted ()
  (drgnx-evil-test--running
    (should (null (drgnx-modal-sync-engine '((emacs)))))
    (let ((evil-collection-want-unimpaired-p nil))
      (should (eq (drgnx-modal-sync-engine '((vim app editing window))) 'evil))
      (should-not (bound-and-true-p global-evil-collection-unimpaired-mode)))))

;;;; Insert-state keys

(ert-deftest drgnx-evil-more/insert-keys-only-in-the-pure-stack ()
  (drgnx-evil-test--running
    (should (eq (drgnx-evil-more-test--key evil-insert-state-map "C-w") 'evil-delete-backward-word))
    (should (eq (drgnx-evil-more-test--key evil-insert-state-map "C-r") 'evil-paste-from-register))
    ;; mixed: the other editor's keys (C-w, C-r …) are not evil's in insert state
    (should (eq (drgnx-modal-sync-engine '((vscode app window) (vim editing))) 'evil))
    (dolist (key '("C-w" "C-r" "C-v" "C-a" "C-e" "C-y" "C-t" "C-d"))
      (should-not (drgnx-evil-more-test--key evil-insert-state-map key)))
    ;; evil's escape and the toggle key stay
    (should (eq (drgnx-evil-more-test--key evil-insert-state-map "<escape>") 'evil-normal-state))
    ;; pure again: back as evil made them
    (should (eq (drgnx-modal-sync-engine '((vim app editing window))) 'evil))
    (should (eq (drgnx-evil-more-test--key evil-insert-state-map "C-w") 'evil-delete-backward-word))
    (should (eq (drgnx-evil-more-test--key evil-insert-state-map "C-r") 'evil-paste-from-register))))

(ert-deftest drgnx-evil-more/insert-keys-a-start-in-a-mixed-stack ()
  (drgnx-evil-test--running
    (should (null (drgnx-modal-sync-engine '((emacs)))))
    (should (eq (drgnx-modal-sync-engine '((vscode app window) (vim editing))) 'evil))
    (should-not (drgnx-evil-more-test--key evil-insert-state-map "C-w"))
    (should (eq (drgnx-modal-sync-engine '((vim app editing window))) 'evil))
    (should (eq (drgnx-evil-more-test--key evil-insert-state-map "C-w") 'evil-delete-backward-word))))

(ert-deftest drgnx-evil-more/a-key-the-user-rebound-stays ()
  (drgnx-evil-test--running
    (define-key evil-insert-state-map (kbd "C-w") #'kill-region)
    (unwind-protect
        (progn (drgnx-modal-sync-engine '((vscode app window) (vim editing)))
               (should (eq (drgnx-evil-more-test--key evil-insert-state-map "C-w") 'kill-region))
               (drgnx-modal-sync-engine '((vim app editing window)))
               (should (eq (drgnx-evil-more-test--key evil-insert-state-map "C-w") 'kill-region)))
      (define-key evil-insert-state-map (kbd "C-w") #'evil-delete-backward-word))))

;;;; Multiple cursors

(ert-deftest drgnx-evil-more/multiple-cursors-run-in-emacs-state ()
  (let ((dir (drgnx-evil-more-test--dir "multiple-cursors")))
    (skip-unless dir)
    (let ((load-path (cons dir load-path)))
      (drgnx-evil-test--running
        (require 'multiple-cursors)
        (drgnx-evil-test--buffer b #'text-mode
          (should (eq evil-state 'normal))
          (multiple-cursors-mode 1)
          (should (eq evil-state 'emacs))
          (should (eq drgnx-modal-state 'emacs))
          (multiple-cursors-mode 0)
          (should (eq evil-state 'normal))
          (should (eq drgnx-modal-state 'normal)))))))

(ert-deftest drgnx-evil-more/multiple-cursors-give-insert-state-back ()
  (let ((dir (drgnx-evil-more-test--dir "multiple-cursors")))
    (skip-unless dir)
    (let ((load-path (cons dir load-path)))
      (drgnx-evil-test--running
        (require 'multiple-cursors)
        (drgnx-evil-test--buffer b #'text-mode
          (evil-insert-state)
          (multiple-cursors-mode 1)
          (should (eq evil-state 'emacs))
          (multiple-cursors-mode 0)
          (should (eq evil-state 'insert))
          ;; the disabled hook also runs without the mode on (mc does that after a quit): nothing changes
          (run-hooks 'multiple-cursors-mode-disabled-hook)
          (should (eq evil-state 'insert)))))))

(ert-deftest drgnx-evil-more/multiple-cursors-hooks-need-the-engine ()
  (let ((dir (drgnx-evil-more-test--dir "multiple-cursors")))
    (skip-unless dir)
    (let ((load-path (cons dir load-path)))
      (drgnx-evil-test--running
        (require 'multiple-cursors)
        (should (null (drgnx-modal-sync-engine '((emacs)))))
        (should-not (memq 'drgnx-evil--mc-enter (bound-and-true-p multiple-cursors-mode-enabled-hook)))
        (should-not (memq 'drgnx-evil--mc-leave (bound-and-true-p multiple-cursors-mode-disabled-hook)))
        (should (eq (drgnx-modal-sync-engine '((vim app editing window))) 'evil))
        (should (memq 'drgnx-evil--mc-enter (bound-and-true-p multiple-cursors-mode-enabled-hook)))))))

(provide 'mod-evil-more-isolated)
;;; mod-evil-more-isolated.el ends here
