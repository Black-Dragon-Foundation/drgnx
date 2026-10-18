;;; modal-core-test.el --- batch tests: the engine-neutral modal core (leader and panel maps, state, indicator, engines) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-outline)
(require 'drgnx-modal)

(defconst drgnx-modal-test--profiles
  (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))
  "The shipped key profiles.")

(defvar drgnx-modal-test--count 0)

(defun drgnx-modal-test-cmd ()
  "A command bound at SPC t t in the leader map by the tests."
  (interactive)
  (cl-incf drgnx-modal-test--count))

(defun drgnx-modal-test-down ()
  (interactive)
  (cl-incf drgnx-modal-test--count 10))

(define-derived-mode drgnx-modal-test-panel-mode drgnx-outline-mode "TestPanel")
(define-derived-mode drgnx-modal-test-form-mode nil "TestForm")

(defmacro drgnx-modal-test--with-leader (&rest body)
  "BODY with SPC t t bound in the leader map and the alists in place; both maps restored after."
  (declare (indent 0))
  `(let ((leader-saved (copy-tree drgnx-modal-leader-map))
         (panel-saved (copy-tree drgnx-modal-panel-map))
         (emulation-mode-map-alists emulation-mode-map-alists)
         (drgnx-modal-test--count 0))
     (unwind-protect
         (progn (keymap-set drgnx-modal-leader-map "SPC t t" #'drgnx-modal-test-cmd)
                (drgnx-modal-order-alists)
                ,@body)
       (setcdr drgnx-modal-leader-map (cdr leader-saved))
       (setcdr drgnx-modal-panel-map (cdr panel-saved)))))

(defun drgnx-modal-test--leader-p ()
  (eq (keymap-lookup nil "SPC t t") #'drgnx-modal-test-cmd))

(defun drgnx-modal-test--panel-key-p ()
  (eq (keymap-lookup nil "j") #'drgnx-modal-test-cmd))

(ert-deftest drgnx-modal/leader-is-on-in-normal-and-panels-only ()
  (drgnx-modal-test--with-leader
    (with-temp-buffer
      (fundamental-mode)
      (dolist (state '(normal visual-line motion visual visual-block))
        (drgnx-modal-set-state state)
        (should (drgnx-modal-test--leader-p)))
      (dolist (state '(insert emacs replace operator nil))
        (drgnx-modal-set-state state)
        (should-not (drgnx-modal-test--leader-p))))
    (keymap-set drgnx-modal-panel-map "j" #'drgnx-modal-test-cmd)
    (with-temp-buffer
      (drgnx-modal-test-panel-mode)
      (should (drgnx-modal-panel-p))
      (should (eq (drgnx-modal-set-state 'emacs) 'emacs))
      (should (drgnx-modal-test--leader-p))
      (should (drgnx-modal-test--panel-key-p)))
    (with-temp-buffer
      (fundamental-mode)
      (drgnx-modal-set-state 'emacs)
      (should-not (drgnx-modal-test--panel-key-p))
      (drgnx-modal-set-state 'normal)
      (should-not (drgnx-modal-test--panel-key-p)))))

(ert-deftest drgnx-modal/forms-get-no-modal-keys ()
  (drgnx-modal-test--with-leader
    (keymap-set drgnx-modal-panel-map "j" #'drgnx-modal-test-cmd)
    (let ((drgnx-modal-form-modes '(drgnx-modal-test-form-mode)))
      (with-temp-buffer
        (drgnx-modal-test-form-mode)
        (should (drgnx-modal-form-p))
        (should-not (drgnx-modal-panel-p))
        (drgnx-modal-set-state 'emacs)
        (should-not (drgnx-modal-test--leader-p))
        (should-not (drgnx-modal-test--panel-key-p))))))

(ert-deftest drgnx-modal/mode-lists-use-derived-mode ()
  (with-temp-buffer
    (should-not (drgnx-modal-input-p))
    (let ((drgnx-modal-input-modes '(fundamental-mode)))
      (should (drgnx-modal-input-p)))
    (should (memq 'drgnx-explorer-mode drgnx-modal-panel-modes))
    (should (memq 'drgnx-replace-bar-mode drgnx-modal-form-modes))
    (should (memq 'eshell-mode drgnx-modal-input-modes))))

(ert-deftest drgnx-modal/where-names-the-map ()
  (should (equal (drgnx-modal-where 'drgnx-modal-leader-map) ""))
  (should (equal (drgnx-modal-where 'drgnx-modal-panel-map) "panels"))
  (should (equal (drgnx-modal-where 'evil-normal-state-map) "normal state"))
  (should (equal (drgnx-modal-where '(evil . evil-visual-state-map)) "visual state"))
  (should (equal (drgnx-modal-where 'evil-motion-state-map) "motion state"))
  (should (equal (drgnx-modal-where 'evil-insert-state-map) "insert state"))
  (should (null (drgnx-modal-where 'global-map))))

(ert-deftest drgnx-modal/mode-line-names-and-faces ()
  (pcase-dolist (`(,state ,text ,face)
                 '((normal " NORMAL " drgnx-modal-normal) (insert " INSERT " drgnx-modal-insert)
                   (visual " VISUAL " drgnx-modal-visual) (visual-line " V-LINE " drgnx-modal-visual)
                   (visual-block " V-BLOCK " drgnx-modal-visual) (replace " REPLACE " drgnx-modal-visual)
                   (motion " MOTION " drgnx-modal-normal) (emacs " EMACS " drgnx-modal-emacs)
                   (operator " NORMAL " drgnx-modal-normal)))
    (with-temp-buffer
      (drgnx-modal-set-state state)
      (let ((s (drgnx-modal-mode-line)))
        (should (equal (substring-no-properties s) text))
        (should (eq (get-text-property 0 'face s) face)))))
  (with-temp-buffer
    (should (equal (drgnx-modal-mode-line) "")))
  (dolist (face '(drgnx-modal-normal drgnx-modal-insert drgnx-modal-visual drgnx-modal-emacs))
    (should (memq (face-attribute face :inherit nil nil) '(mode-line-emphasis success warning shadow)))
    (should (eq (face-attribute face :foreground nil nil) 'unspecified))
    (should (eq (face-attribute face :background nil nil) 'unspecified)))
  (should (eq (face-attribute 'drgnx-modal-normal :inherit) 'mode-line-emphasis))
  (should (eq (face-attribute 'drgnx-modal-insert :inherit) 'success))
  (should (eq (face-attribute 'drgnx-modal-visual :inherit) 'warning))
  (should (eq (face-attribute 'drgnx-modal-emacs :inherit) 'shadow)))

(ert-deftest drgnx-modal/indicator-on-off-is-idempotent ()
  (let ((before (default-value 'mode-line-format)) (entry '(:eval (drgnx-modal-mode-line))))
    (unwind-protect
        (progn
          (drgnx-modal-indicator-on)
          (drgnx-modal-indicator-on)
          (should (= 1 (seq-count (lambda (e) (equal e entry)) (default-value 'mode-line-format))))
          (should (equal (car (default-value 'mode-line-format)) entry))
          (should (equal (cdr (default-value 'mode-line-format)) (remove entry before)))
          (drgnx-modal-indicator-off)
          (should-not (member entry (default-value 'mode-line-format)))
          (should (equal (default-value 'mode-line-format) before)))
      (setq-default mode-line-format before))))

(ert-deftest drgnx-modal/alists-order ()
  (let ((emulation-mode-map-alists '(evil-mode-map-alist drgnx-ai-ghost--emulation other drgnx-modal--leader-alist)))
    (drgnx-modal-order-alists)
    (should (equal emulation-mode-map-alists
                   '(drgnx-modal--leader-alist drgnx-modal--panel-alist drgnx-ai-ghost--emulation
                                               evil-mode-map-alist other)))
    (drgnx-modal-order-alists)
    (should (equal emulation-mode-map-alists
                   '(drgnx-modal--leader-alist drgnx-modal--panel-alist drgnx-ai-ghost--emulation
                                               evil-mode-map-alist other))))
  (let ((emulation-mode-map-alists '(evil-mode-map-alist drgnx-keys--everywhere-alist)))
    (drgnx-modal-order-alists)
    (should (equal emulation-mode-map-alists
                   '(drgnx-keys--everywhere-alist drgnx-modal--leader-alist drgnx-modal--panel-alist
                                                  evil-mode-map-alist)))))

(ert-deftest drgnx-modal/selection-prefers-the-engine ()
  (with-temp-buffer
    (insert "0123456789")
    (let ((drgnx-modal-selection-function (lambda () (cons 3 9))))
      (should (equal (drgnx-modal-selection) '(3 . 9))))
    (let ((drgnx-modal-selection-function nil))
      (should (null (drgnx-modal-selection)))
      (transient-mark-mode 1)
      (set-mark 2)
      (goto-char 5)
      (activate-mark)
      (should (equal (drgnx-modal-selection) '(2 . 5))))))

(ert-deftest drgnx-modal/engine-for-layers ()
  (should (eq (drgnx-modal-engine-for '((vscode app window) (vim editing)) drgnx-modal-test--profiles) 'evil))
  (should (null (drgnx-modal-engine-for '((vscode app editing window)) drgnx-modal-test--profiles))))

(ert-deftest drgnx-modal/shipped-vim-profile-describes-the-modal-keys ()
  (let ((modal (plist-get (alist-get 'vim drgnx-modal-test--profiles) :modal)))
    (should (eq (plist-get modal :engine) 'evil))
    (should (equal (plist-get modal :leader) '("SPC" "C-w")))
    (should (equal (plist-get modal :default-map) '(evil . evil-normal-state-map)))
    (should (equal (assq 'drgnx-modal-panel-map (plist-get modal :maps)) '(drgnx-modal-panel-map panels)))))

(ert-deftest drgnx-modal/sync-starts-and-stops-once ()
  (let ((drgnx-modal-engines nil) (drgnx-modal-running nil) (drgnx-keys-profiles drgnx-modal-test--profiles)
        (log nil))
    (drgnx-modal-define-engine 'evil :module "editor/evil" :start (lambda () (push 'start log))
                               :stop (lambda () (push 'stop log)))
    (should (eq (drgnx-modal-sync-engine '((vscode app window) (vim editing))) 'evil))
    (should (eq (drgnx-modal-sync-engine '((vscode app window) (vim editing))) 'evil))
    (should (equal log '(start)))
    (should (eq drgnx-modal-running 'evil))
    (should (null (drgnx-modal-sync-engine '((vscode app editing window)))))
    (should (equal log '(stop start)))
    (should (null drgnx-modal-running))
    (should (null (drgnx-modal-sync-engine '((vscode app editing window)))))
    (should (equal log '(stop start)))))

(ert-deftest drgnx-modal/sync-without-a-registered-engine-is-quiet ()
  (let ((drgnx-modal-engines nil) (drgnx-modal-running nil) (drgnx-keys-profiles drgnx-modal-test--profiles))
    (should (null (drgnx-modal-sync-engine '((vim editing)))))
    (should (null drgnx-modal-running))))

(ert-deftest drgnx-modal/current-layers-order ()
  (let ((drgnx-keys--session-layers '((vim editing))) (drgnx-keys-layers '((vscode app))))
    (should (equal (drgnx-modal-current-layers) '((vim editing)))))
  (let ((drgnx-keys--session-layers nil) (drgnx-keys-layers '((vscode app))))
    (cl-letf (((symbol-function 'drgnx-keys-read-user) (lambda () '(:layers ((emacs editing))))))
      (should (equal (drgnx-modal-current-layers) '((emacs editing)))))
    (cl-letf (((symbol-function 'drgnx-keys-read-user) (lambda () nil)))
      (should (equal (drgnx-modal-current-layers) '((vscode app)))))))

(ert-deftest drgnx-modal/panel-next-runs-the-panels-down ()
  (let ((drgnx-modal-test--count 0))
    (with-temp-buffer
      (drgnx-modal-test-panel-mode)
      (use-local-map (let ((m (make-sparse-keymap))) (set-keymap-parent m (current-local-map))
                          (keymap-set m "<down>" #'drgnx-modal-test-down)
                          (keymap-set m "<up>" #'drgnx-modal-test-cmd)
                          m))
      (drgnx-modal-panel-next)
      (should (= drgnx-modal-test--count 10))
      (drgnx-modal-panel-previous)
      (should (= drgnx-modal-test--count 11)))
    (with-temp-buffer
      (insert "a\nb\nc")
      (goto-char (point-min))
      (drgnx-modal-panel-next)
      (should (= (line-number-at-pos) 2))
      (drgnx-modal-panel-previous)
      (should (= (line-number-at-pos) 1)))))

(ert-deftest drgnx-modal/leader-menu-reads-the-leader ()
  (drgnx-modal-test--with-leader
    (drgnx-modal-leader-menu)
    (execute-kbd-macro "tt")
    (should (= drgnx-modal-test--count 1))))

(ert-deftest drgnx-modal/commands-are-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-modal-register-commands)
    (should (eq (drgnx-cmd-command (drgnx-commands-get 'modal-leader)) #'drgnx-modal-leader-menu))
    (should (equal (drgnx-cmd-title (drgnx-commands-get 'modal-leader)) "Leader Menu"))
    (should (equal (drgnx-cmd-title (drgnx-commands-get 'panel-next)) "Next Row"))
    (should (equal (drgnx-cmd-title (drgnx-commands-get 'panel-previous)) "Previous Row"))
    (should (eq (drgnx-cmd-map (drgnx-commands-get 'panel-next)) 'drgnx-modal-panel-map))
    (should (eq (drgnx-cmd-map (drgnx-commands-get 'panel-previous)) 'drgnx-modal-panel-map))
    (should (eq (drgnx-cmd-scope (drgnx-commands-get 'panel-next)) 'app))))

(provide 'modal-core-test)
;;; modal-core-test.el ends here
