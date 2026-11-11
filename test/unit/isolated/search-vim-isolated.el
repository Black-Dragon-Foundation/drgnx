;;; search-vim-isolated.el --- batch tests (own Emacs, test/unit/modal-isolated-test.el): Vim's state keys of the Search view and Edit Results -*- lexical-binding: t -*-
;; Needs the real evil: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it those tests skip.
;; The full registry and the startup modules run in a temp configuration (editor/evil chosen, the Vim stack applied), so
;; the keys are the shipped ones, driven through evil's keymaps (execute-kbd-macro, `evil-ex-execute'); nothing asks.
;; The hub is a stub that answers each method from a table and records the calls.
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-modal)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(defvar evil-state)
(declare-function evil-ex-execute "evil-ex")
(declare-function evil-normal-state "evil-states")
(declare-function evil-insert-state "evil-states")
(declare-function drgnx-evil-stop "drgnx-evil")
(defvar drgnx-search-edit--marked)
(defvar drgnx-search-edit--lines)
(defvar drgnx-search-edit-mode-map)
(defvar drgnx-search-edit-normal-state-map)
(defvar drgnx-replace-mode-map)
(defvar drgnx-replace--find-field-map)
(declare-function drgnx-search-edit--open "drgnx-search-edit")
(declare-function drgnx-search-edit--line-start "drgnx-search-edit")
(declare-function drgnx-search-edit--line-id "drgnx-search-edit")
(declare-function drgnx-search-edit--line-state "drgnx-search-edit")
(declare-function drgnx-search-edit--text "drgnx-search-edit")
(declare-function drgnx-replace-mode "drgnx-replace")

(defconst drgnx-search-vim-test--doc
  '(:lines ((:line_id "l:0" :path "/r/a.el" :line 1 :text "(defvar one 1)" :kind "match" :eol t)
            (:line_id "l:1" :path "/r/a.el" :line 2 :text ";; between" :kind "context" :eol t)
            (:line_id "l:2" :path "/r/a.el" :line 3 :text "(defvar two 2)" :kind "match" :eol t))
           :total 3)
  "The hub's `search/edit-doc' answer.")

(defvar drgnx-search-vim-test--calls nil "The hub calls and recorded commands, newest first.")

(defmacro drgnx-search-vim-test--with (&rest body)
  "BODY with evil running in the Vim stack, all startup modules run, in a temp configuration and state dir; the hub
answers `search/edits' and `search/apply' and records every call in `drgnx-search-vim-test--calls'."
  (declare (indent 0))
  `(drgnx-modal-test-with-evil
     (let* ((dir (file-name-as-directory (make-temp-file "drgnx-search-vim" t)))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir "config")
                                               (concat "DRGNX_DATA_DIR=" dir "data")
                                               (concat "XDG_STATE_HOME=" dir "state")
                                               (concat "HOME=" dir "home"))
                                         process-environment))
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
            (drgnx-modules--table nil) (drgnx-modules--report nil)
            (drgnx-modules--state nil) (drgnx-modal-engines nil) (drgnx-modal-running nil)
            (drgnx-keys--applied nil) (drgnx-keys-profiles nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
            (drgnx-keys--session-layers nil)
            (emulation-mode-map-alists emulation-mode-map-alists)
            (mode-line-saved (default-value 'mode-line-format))
            (drgnx-search-vim-test--calls nil))
       (make-directory (concat dir "config") t)
       (make-directory (concat dir "home") t)
       (load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)
       (drgnx-test-areas-put-old 'modules "(:version 1 :enabled (editor/evil))\n")
       (unwind-protect
           (progn
             (drgnx--core-commands)
             (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
             (drgnx-modules-run 'startup)
             (drgnx-keys-use '((vim app editing window)))
             (should (eq drgnx-modal-running 'evil))
             (cl-letf (((symbol-function 'kill-emacs) (lambda (&rest _) (ert-fail "kill-emacs was called")))
                       ((symbol-function 'drgnx-hub--call-on)
                        (lambda (_conn method params cb &rest _)
                          (push (list method params) drgnx-search-vim-test--calls)
                          (funcall cb (pcase method
                                        ("search/edits" '(:change 1 :files nil :skipped nil))
                                        (_ t))
                                   nil)))
                       ((symbol-function 'drgnx-replace--open-paths) (lambda () []))
                       ((symbol-function 'drgnx-wb-show-in-editor) #'ignore))
               ,@body))
         (when (fboundp 'drgnx-evil-stop) (drgnx-evil-stop))
         (drgnx-keys--restore)
         (setq-default mode-line-format mode-line-saved)
         (delete-directory dir t)))))

(defmacro drgnx-search-vim-test--edit-results (&rest body)
  "BODY in an Edit Results buffer of the document above, shown in the selected window in the state evil gives it."
  (declare (indent 0))
  `(let ((buf (drgnx-search-edit--open "s" "one" "/r/" drgnx-search-vim-test--doc)))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer buf)
           (with-current-buffer buf ,@body))
       (when (buffer-live-p buf)
         (with-current-buffer buf (clrhash drgnx-search-edit--marked) (set-buffer-modified-p nil))
         (kill-buffer buf)))))

(defun drgnx-search-vim-test--line (id)
  "Line ID's record in this Edit Results buffer."
  (cl-find id drgnx-search-edit--lines :key #'drgnx-search-edit--line-id :test #'equal))

(defun drgnx-search-vim-test--goto (id)
  "Point at the start of line ID's text."
  (goto-char (drgnx-search-edit--line-start (drgnx-search-vim-test--line id))))

(defun drgnx-search-vim-test--sent (method)
  "The params of the last call of METHOD."
  (cadr (assoc method drgnx-search-vim-test--calls)))

(ert-deftest drgnx-search-vim/edit-results-keys ()
  ;; d d marks the line for deletion, d w is still evil's delete, :w saves the edited lines, Z Q discards and closes.
  (drgnx-search-vim-test--with
    (drgnx-search-vim-test--edit-results
      (should (eq evil-state 'normal))
      (drgnx-search-vim-test--goto "l:1")
      (execute-kbd-macro (kbd "d d"))
      (should (eq (drgnx-search-edit--line-state (drgnx-search-vim-test--line "l:1")) 'deleted))
      (drgnx-search-vim-test--goto "l:2")
      (forward-char 1)
      (execute-kbd-macro (kbd "d w"))                     ; evil's operator: "defvar " goes
      (should (equal (drgnx-search-edit--text (drgnx-search-vim-test--line "l:2")) "(two 2)"))
      (should (eq (drgnx-search-edit--line-state (drgnx-search-vim-test--line "l:2")) 'edited))
      (evil-ex-execute "w")
      (should (equal (mapcar (lambda (l) (plist-get l :line_id))
                             (plist-get (drgnx-search-vim-test--sent "search/edits") :lines))
                     '("l:1" "l:2")))
      (should (equal (plist-get (drgnx-search-vim-test--sent "search/apply") :change) 1))
      (drgnx-search-vim-test--goto "l:0")
      (execute-kbd-macro (kbd "x"))                       ; an unsaved edit: Z Q drops it without asking
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Asked"))))
        (execute-kbd-macro (kbd "Z Q")))
      (should-not (buffer-live-p buf)))))

(ert-deftest drgnx-search-vim/z-z-is-still-evils ()
  ;; Z Q binds Z as a prefix in Edit Results: Z Z still reaches evil's own save-and-close.
  (drgnx-search-vim-test--with
    (drgnx-search-vim-test--edit-results
      (cl-letf (((symbol-function 'evil-save-modified-and-close)
                 (lambda (&rest _) (interactive) (push '(evil-zz) drgnx-search-vim-test--calls))))
        (execute-kbd-macro (kbd "Z Z")))
      (should (assoc 'evil-zz drgnx-search-vim-test--calls)))))

(ert-deftest drgnx-search-vim/search-view-keys ()
  ;; The view starts in Emacs state; in normal state (C-z) i is Edit Results; in the Find field's insert state C-p and
  ;; C-n walk the history, elsewhere they stay evil's.
  (drgnx-search-vim-test--with
    (let ((buf (generate-new-buffer "search-vim-view")))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buf)
            (with-current-buffer buf
              (drgnx-replace-mode)
              (should (eq evil-state 'emacs))
              (insert "Find: ")
              (insert (propertize "word" 'keymap drgnx-replace--find-field-map))
              (insert "\nrows\n")
              (evil-normal-state)
              (cl-letf (((symbol-function 'drgnx-search-edit-results)
                         (lambda () (interactive) (push '(edit-results) drgnx-search-vim-test--calls))))
                (execute-kbd-macro (kbd "i")))
              (should (assoc 'edit-results drgnx-search-vim-test--calls))
              (goto-char (point-max))
              (evil-insert-state)
              (should-not (eq (key-binding (kbd "C-p")) 'drgnx-replace-search-history-prev))
              (evil-normal-state)
              (goto-char 9)                                ; in Find
              (evil-insert-state)
              (should (eq (key-binding (kbd "C-p")) 'drgnx-replace-search-history-prev))
              (should (eq (key-binding (kbd "C-n")) 'drgnx-replace-search-history-next))))
        (kill-buffer buf)))))

(ert-deftest drgnx-search-vim/module-off-takes-the-maps-out ()
  ;; Turning tools/replace off takes evil's auxiliary maps it made out of the modes' maps, and its after-apply hook.
  (drgnx-search-vim-test--with
    (should (keymapp (lookup-key drgnx-search-edit-mode-map [normal-state])))
    (should (keymapp (lookup-key drgnx-replace-mode-map [normal-state])))
    (should (keymapp (lookup-key drgnx-replace--find-field-map [insert-state])))
    (drgnx-module-teardown 'tools/replace)
    (should-not (lookup-key drgnx-search-edit-mode-map [normal-state]))
    (should-not (lookup-key drgnx-replace-mode-map [normal-state]))
    (should-not (lookup-key drgnx-replace--find-field-map [insert-state]))
    (should-not (memq 'drgnx-search-edit--refresh-vim-prefixes (default-value 'drgnx-keys-after-apply-functions)))))

(provide 'search-vim-isolated)
;;; search-vim-isolated.el ends here
