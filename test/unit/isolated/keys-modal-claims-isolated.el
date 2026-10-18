;;; keys-modal-claims-isolated.el --- batch tests (own Emacs, test/unit/keys-modal-claims-test.el): Vim's claims read from evil's maps -*- lexical-binding: t -*-
;; Needs the real evil: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it those tests skip.
;; Evil is loaded, not started (no engine): what is tested is the key resolution and evil's keymaps.  Every apply runs
;; in a temp configuration and state dir and is undone after.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-keys-modal)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(defvar evil-want-keybinding)
(defvar evil-normal-state-map)
(defvar evil-motion-state-map)
(defvar evil-visual-state-map)
(defvar evil-insert-state-map)

(defconst drgnx-keys-claims-evil-test--profiles
  (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))
  "The shipped profiles.")

(defconst drgnx-keys-claims-evil-test--mixed '((vscode app window) (vim editing)) "The mixed preset.")

(defmacro drgnx-keys-claims-evil-test--with (&rest body)
  "BODY with evil loaded (not started) and a registry holding the core commands and the startup modules."
  (declare (indent 0))
  `(drgnx-modal-test-with-evil
     (setq evil-want-keybinding nil)
     (require 'evil)
     (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
           (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
           (find-file-hook find-file-hook))
       (drgnx--core-commands)
       (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
       (drgnx-modules-run 'startup)
       ,@body)))

(defmacro drgnx-keys-claims-evil-test--live (&rest body)
  "BODY in a temp configuration and state dir, where `drgnx-keys-apply' binds for real; undone after.  No engine is
started by an apply (the after-apply functions are off)."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "drgnx-keys-claims" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir) (concat "XDG_STATE_HOME=" dir "/state"))
                                       process-environment))
          (drgnx-keys--applied nil) (drgnx-keys-profiles nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
          (drgnx-keys--session-layers nil) (drgnx-keys-after-apply-functions nil))
     (unwind-protect (progn ,@body)
       (drgnx-keys--restore)
       (delete-directory dir t))))

(defun drgnx-keys-claims-evil-test--user (plist)
  "Write PLIST as keys.eld of the temp configuration."
  (write-region (format "%S\n" plist) nil (drgnx-keys-file) nil 'silent))

(defun drgnx-keys-claims-evil-test--resolve (layers &rest args)
  (apply #'drgnx-keys-resolve :commands (drgnx-commands-all) :layers layers
         :defaults drgnx-keys--defaults (append args (list :profiles drgnx-keys-claims-evil-test--profiles))))

(defun drgnx-keys-claims-evil-test--leaves (map &optional prefix)
  "Every key sequence under MAP (prefix maps followed, three events deep at most), as vectors."
  (let (out)
    (map-keymap (lambda (ev def)
                  (unless (consp ev)    ; a char-table range
                    (let ((k (vconcat prefix (vector ev))))
                      (if (and (keymapp def) (not (symbolp def)) (< (length k) 3))
                          (setq out (append (drgnx-keys-claims-evil-test--leaves def k) out))
                        (push k out)))))
                map)
    out))

(defun drgnx-keys-claims-evil-test--record ()
  "What evil's four state maps bind on every key of the snapshots: ((MAPSYM KEY . DEF)…)."
  (let (out)
    (pcase-dolist (`(,sym . ,snap) drgnx-keys-modal-snapshots)
      (dolist (k (drgnx-keys-claims-evil-test--leaves snap))
        (let ((def (lookup-key (symbol-value sym) k)))
          (push (cons sym (cons k (if (keymapp def) 'prefix def))) out))))
    (nreverse out)))

(ert-deftest drgnx-keys-claims/snapshots-replace-the-hand-list ()
  (drgnx-keys-claims-evil-test--with
    (should (equal (sort (mapcar #'car drgnx-keys-modal-snapshots) #'string<)
                   '(evil-insert-state-map evil-motion-state-map evil-normal-state-map evil-visual-state-map)))
    (let* ((modal (plist-get (alist-get 'vim drgnx-keys-claims-evil-test--profiles) :modal))
           (b (list :id 'toggle-sidebar :key "C-b" :map 'global-map :layer 'vscode :rank 1))
           (cls (drgnx-keys-modal-claims (list b) modal 'vim 2 drgnx-keys-modal-snapshots nil)))
      ;; C-b is evil's in its motion map (Task 1's recon), and only there
      (should (equal (mapcar (lambda (c) (cdr (drgnx-commands--keymap-spec (plist-get c :map)))) cls)
                     '(evil-motion-state-map)))
      (should (equal (plist-get (car cls) :states) '(normal visual motion))))
    ;; The mixed preset read from evil's maps: VS Code's six Ctrl keys stay global; C-p is evil's in its normal map,
    ;; which evil's visual state enables too.
    (let ((r (drgnx-keys-claims-evil-test--resolve drgnx-keys-claims-evil-test--mixed
                                                   :snapshots drgnx-keys-modal-snapshots)))
      (pcase-dolist (`(,id ,key) '((open-file "C-o") (close-tab "C-w") (toggle-sidebar "C-b") (go-quick-open "C-p")
                                   (file-new "C-n") (go-symbol-project "C-t")))
        (should (equal (list id key t)
                       (list id key (and (seq-find (lambda (b) (and (eq (plist-get b :id) id) (equal (plist-get b :key) key)
                                                                    (memq (plist-get b :map) '(nil global-map))))
                                                   (plist-get r :bindings))
                                         t)))))
      (should (equal (plist-get (seq-find (lambda (c) (and (equal (plist-get c :key) "C-p") (plist-get c :states)))
                                          (plist-get r :conflicts))
                                :states)
                     '(normal visual))))
    ;; With no hand list at all, the snapshot still claims C-b; without the snapshot, nothing does.
    (let ((bare (mapcar (lambda (p) (if (eq (car p) 'vim) (cons 'vim (plist-put (copy-sequence (cdr p)) :claims nil)) p))
                        drgnx-keys-claims-evil-test--profiles)))
      (cl-flet ((claim-on (r key) (seq-find (lambda (c) (and (equal (plist-get c :key) key) (plist-get c :states)))
                                            (plist-get r :conflicts))))
        (let ((with (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles bare
                                        :layers drgnx-keys-claims-evil-test--mixed :defaults drgnx-keys--defaults
                                        :snapshots drgnx-keys-modal-snapshots))
              (without (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles bare
                                           :layers drgnx-keys-claims-evil-test--mixed :defaults drgnx-keys--defaults)))
          (should (equal (plist-get (claim-on with "C-b") :states) '(normal visual motion)))
          (should-not (claim-on without "C-b")))))
    ;; A key the hand list lacks (C-^, evil-buffer in the motion map), bound by a lower layer: a state conflict.
    (drgnx-command-define 'test-caret :category "Test" :title "Test Caret" :command #'ignore :scope 'app :doc "test")
    (let* ((profiles (mapcar (lambda (p)
                               (cons (car p) (plist-put (copy-sequence (cdr p)) :bind
                                                        (append (plist-get (cdr p) :bind)
                                                                (list (if (eq (car p) 'vscode) '(test-caret "C-^")
                                                                        '(test-caret :none "test")))))))
                             drgnx-keys-claims-evil-test--profiles))
           (r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles profiles
                                  :layers drgnx-keys-claims-evil-test--mixed :defaults drgnx-keys--defaults
                                  :snapshots drgnx-keys-modal-snapshots))
           (c (seq-find (lambda (c) (equal (plist-get c :key) "C-^")) (plist-get r :conflicts))))
      (should (seq-find (lambda (b) (and (eq (plist-get b :id) 'test-caret) (equal (plist-get b :key) "C-^")))
                        (plist-get r :bindings)))
      (should (eq (plist-get c :kind) 'claim))
      (should (memq 'motion (plist-get c :states)))
      (should (eq (plist-get (plist-get c :winner) :layer) 'vim)))))

(defun drgnx-keys-claims-evil-test--mine ()
  "A command the user binds in evil's normal-state map (config.el)."
  (interactive))

(ert-deftest drgnx-keys-claims/your-own-key-in-evils-map-is-kept ()
  ;; config.el bound C-p in evil's normal-state map after evil loaded: a winning key is not bound over it; it is said.
  (drgnx-keys-claims-evil-test--with
    (drgnx-keys-claims-evil-test--live
      (keymap-set evil-normal-state-map "C-p" #'drgnx-keys-claims-evil-test--mine)
      (unwind-protect
          (progn
            (drgnx-keys-claims-evil-test--user '(:layers ((vim app editing window)) :bind ((go-quick-open "C-p"))))
            (drgnx-keys-apply)
            (should (eq (keymap-lookup evil-normal-state-map "C-p") #'drgnx-keys-claims-evil-test--mine))
            (should (eq (keymap-lookup evil-insert-state-map "C-p") #'project-find-file))   ; evil's own: replaced
            (should (eq (keymap-lookup global-map "C-p") #'project-find-file))
            (should-not (member '("C-p" . (evil . evil-normal-state-map))
                                (drgnx-cmd-bound (drgnx-commands-get 'go-quick-open))))
            (let ((c (seq-find (lambda (c) (and (equal (plist-get c :key) "C-p") (eq (plist-get c :map) 'evil-normal-state-map)))
                               (plist-get drgnx-keys-last :conflicts))))
              (should (equal (drgnx-keys-conflict-text c)
                             "C-p drgnx-keys-claims-evil-test--mine (your own binding, kept) over Quick Open (user) [claim, in evil-normal-state-map]")))
            (drgnx-keys--restore)
            (should (eq (keymap-lookup evil-normal-state-map "C-p") #'drgnx-keys-claims-evil-test--mine)))
        (keymap-set evil-normal-state-map "C-p" #'evil-paste-pop)))))

(ert-deftest drgnx-keys-claims/user-key-wins-in-evils-map ()
  (drgnx-keys-claims-evil-test--with
    (drgnx-keys-claims-evil-test--live
      (drgnx-keys-claims-evil-test--user '(:layers ((vim app editing window)) :bind ((go-quick-open "C-p"))))
      (should (eq (keymap-lookup evil-normal-state-map "C-p") 'evil-paste-pop))
      (drgnx-keys-apply)
      (should (eq (keymap-lookup evil-normal-state-map "C-p") #'project-find-file))
      (should (eq (keymap-lookup global-map "C-p") #'project-find-file))
      (should (member '("C-p" . (evil . evil-normal-state-map)) (drgnx-cmd-bound (drgnx-commands-get 'go-quick-open))))
      (let ((c (seq-find (lambda (c) (and (equal (plist-get c :key) "C-p") (plist-get c :states)))
                         (plist-get drgnx-keys-last :conflicts))))
        (should (eq (plist-get (plist-get c :winner) :layer) 'user))
        (should (memq 'normal (plist-get c :states)))
        (should (string-search "Quick Open (user) over" (drgnx-keys-conflict-text c))))
      (drgnx-keys--restore)
      (should (eq (keymap-lookup evil-normal-state-map "C-p") 'evil-paste-pop)))))

(ert-deftest drgnx-keys-claims/switches-restore-evils-maps ()
  (drgnx-keys-claims-evil-test--with
    (drgnx-keys-claims-evil-test--live
      (let ((record (drgnx-keys-claims-evil-test--record))
            (changed (lambda (record) (seq-remove (lambda (e) (member e record)) (drgnx-keys-claims-evil-test--record)))))
        (should (> (length record) 100))
        (drgnx-keys-claims-evil-test--user '(:bind ((go-quick-open "C-p"))))
        (drgnx-keys-use '((vim app editing window)))
        (should (eq (keymap-lookup evil-normal-state-map "C-p") #'project-find-file))
        (should (eq (keymap-lookup evil-insert-state-map "C-p") #'project-find-file))
        ;; VS Code: nothing of drgnx's is left in evil's maps or the leader map
        (drgnx-keys-use '((vscode app editing window)))
        (should (equal (funcall changed record) nil))
        (should-not (seq-filter (lambda (k) (let ((def (lookup-key drgnx-modal-leader-map k)))
                                              (and def (not (numberp def)) (not (keymapp def)))))
                                (drgnx-keys-claims-evil-test--leaves drgnx-modal-leader-map)))
        (drgnx-keys-use drgnx-keys-claims-evil-test--mixed)
        (drgnx-keys-claims-evil-test--user '(:bind ()))
        (drgnx-keys-use '((vim app editing window)))
        (should (eq (keymap-lookup evil-normal-state-map "C-p") 'evil-paste-pop))
        (drgnx-keys--restore)
        (should (equal (funcall changed record) nil))))))

(provide 'keys-modal-claims-isolated)
;;; keys-modal-claims-isolated.el ends here
