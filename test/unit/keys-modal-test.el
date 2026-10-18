;;; keys-modal-test.el --- batch tests: the Vim profile's leader map and additive modal keys -*- lexical-binding: t -*-
;; The shipped profiles, no evil: where a key goes (leader map, panel map, evil's state maps, global), what a
;; mixed stack keeps, what keys.eld does, the presets and the after-apply hook.
(require 'ert)
(require 'drgnx)
(require 'drgnx-keys-modal)

(defconst drgnx-keys-modal-test--profiles
  (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))
  "The shipped profiles.")

(defconst drgnx-keys-modal-test--defaults (copy-keymap global-map) "Emacs' own bindings.")

(defmacro drgnx-keys-modal-test--with-commands (&rest body)
  "BODY with a registry holding the core commands and the modules' startup stage, nothing else."
  (declare (indent 0))
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
         (find-file-hook find-file-hook))
     (drgnx--core-commands)
     (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
     (drgnx-modules-run 'startup)
     ,@body))

(defun drgnx-keys-modal-test--resolve (layers &rest args)
  (drgnx-keys-modal-test--with-commands
    (apply #'drgnx-keys-resolve :commands (drgnx-commands-all) :profiles drgnx-keys-modal-test--profiles
           :layers layers :defaults drgnx-keys-modal-test--defaults args)))

(defun drgnx-keys-modal-test--binds (r id)
  "Resolution R's bindings of command ID as (KEY . MAPSYM)."
  (delq nil (mapcar (lambda (b) (and (eq (plist-get b :id) id)
                                     (cons (plist-get b :key) (cdr (drgnx-commands--keymap-spec (plist-get b :map))))))
                    (plist-get r :bindings))))

(defun drgnx-keys-modal-test--modal ()
  (plist-get (alist-get 'vim drgnx-keys-modal-test--profiles) :modal))

(ert-deftest drgnx-keys-modal/leader-keys-go-to-the-leader-map ()
  (let ((r (drgnx-keys-modal-test--resolve '((vim app editing window)))))
    (should (equal (drgnx-keys-modal-test--binds r 'open-file) '(("SPC f f" . drgnx-modal-leader-map))))
    (should (equal (sort (copy-sequence (drgnx-keys-modal-test--binds r 'palette)) (lambda (a b) (string< (car a) (car b))))
                   '(("<f1>" . global-map) ("C-S-p" . global-map) ("SPC SPC" . drgnx-modal-leader-map))))))

(ert-deftest drgnx-keys-modal/other-vim-keys-keep-their-maps ()
  ;; The same resolution with the old profile map and no :modal is the baseline: every key that is not a leader key
  ;; is bound in the map it had; only the palette's two always-reachable keys are new.
  (let* ((modal (drgnx-keys-modal-test--modal))
         (old-profiles (mapcar (lambda (p)
                                 (if (eq (car p) 'vim)
                                     (cons 'vim (plist-put (plist-put (copy-sequence (cdr p)) :modal nil)
                                                           :map '(evil . evil-normal-state-map)))
                                   p))
                               drgnx-keys-modal-test--profiles))
         (layers '((vim app editing window)))
         (new (drgnx-keys-modal-test--resolve layers))
         (old (drgnx-keys-modal-test--with-commands
                (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles old-profiles :layers layers
                                    :defaults drgnx-keys-modal-test--defaults)))
         (non-leader (lambda (r)
                       (sort (delq nil (mapcar (lambda (b) (and (not (drgnx-keys-modal-leader-p (plist-get b :key) modal))
                                                                (format "%s %s %S" (plist-get b :id) (plist-get b :key)
                                                                        (plist-get b :map))))
                                               (plist-get r :bindings)))
                             #'string<))))
    (should (> (length (funcall non-leader old)) 50))
    (let ((want (append (funcall non-leader old) (list "palette C-S-p global-map" "palette <f1> global-map")))
          (got (funcall non-leader new)))
      (should (equal (list :missing (cl-set-difference want got :test #'equal)
                           :unexpected (cl-set-difference got want :test #'equal))
                     '(:missing nil :unexpected nil))))))

(ert-deftest drgnx-keys-modal/leader-keys-stay-in-the-mixed-stack ()
  (let ((r (drgnx-keys-modal-test--resolve '((vscode app window) (vim editing)))))
    ;; (open-file's C-o is Vim's claim "jump back" until Task 7 makes claims per state.)
    (should (equal (drgnx-keys-modal-test--binds r 'save-file)
                   '(("C-s" . global-map) ("SPC f s" . drgnx-modal-leader-map))))
    (should (member '("SPC f f" . drgnx-modal-leader-map) (drgnx-keys-modal-test--binds r 'open-file)))
    (should (equal (sort (mapcar #'car (drgnx-keys-modal-test--binds r 'palette)) #'string<)
                   '("<f1>" "C-S-p" "SPC SPC")))
    (should (member '("C-S-p" . global-map) (drgnx-keys-modal-test--binds r 'palette)))
    (should-not (seq-find (lambda (c) (and (eq (plist-get c :kind) 'same-key)
                                           (member (plist-get c :key) '("SPC f f" "SPC f s" "SPC SPC" "C-S-p" "<f1>" "C-s"))))
                          (plist-get r :conflicts)))))

(ert-deftest drgnx-keys-modal/non-modal-vim-keys-are-not-extra ()
  (let ((r (drgnx-keys-modal-test--resolve '((vscode app window) (vim editing)))))
    ;; the vim entry's "j" is in the Explorer's map, which no state of the modal profile covers
    (should-not (assoc "j" (drgnx-keys-modal-test--binds r 'explorer-next)))
    (should (assoc "<down>" (drgnx-keys-modal-test--binds r 'explorer-next)))
    ;; panel-next's "j" is in the panel map, which is modal
    (should (equal (drgnx-keys-modal-test--binds r 'panel-next) '(("j" . drgnx-modal-panel-map))))))

(ert-deftest drgnx-keys-modal/a-keys-eld-leader-key-goes-to-the-leader-map ()
  (let ((user '(:bind ((save-file "SPC x")))))
    (should (equal (drgnx-keys-modal-test--binds (drgnx-keys-modal-test--resolve '((vim app editing window)) :user user)
                                                 'save-file)
                   '(("SPC x" . drgnx-modal-leader-map))))
    (should (equal (drgnx-keys-modal-test--binds (drgnx-keys-modal-test--resolve '((vscode app editing window)) :user user)
                                                 'save-file)
                   '(("SPC x" . global-map))))
    ;; a user key that is not a leader key keeps the place it had in a modal stack too
    (should (equal (drgnx-keys-modal-test--binds
                    (drgnx-keys-modal-test--resolve '((vim app editing window)) :user '(:bind ((save-file "C-c x"))))
                    'save-file)
                   '(("C-c x" . global-map))))
    ;; and keys.eld replaces the profile's keys for the command, extras included
    (should (equal (drgnx-keys-modal-test--binds
                    (drgnx-keys-modal-test--resolve '((vscode app window) (vim editing)) :user user) 'save-file)
                   '(("SPC x" . drgnx-modal-leader-map))))))

(ert-deftest drgnx-keys-modal/vscode-and-emacs-stacks-touch-no-modal-map ()
  (let ((maps (mapcar (lambda (m) (cdr (drgnx-commands--keymap-spec (car m))))
                      (plist-get (drgnx-keys-modal-test--modal) :maps))))
    (should (memq 'drgnx-modal-leader-map maps))
    (dolist (layers '(((vscode app editing window)) ((emacs app editing window))))
      (let ((r (drgnx-keys-modal-test--resolve layers)))
        (should (> (length (plist-get r :bindings)) 50))
        (dolist (b (plist-get r :bindings))
          (should-not (memq (cdr (drgnx-commands--keymap-spec (plist-get b :map))) maps)))))))

(ert-deftest drgnx-keys-modal/presets ()
  (should (equal (cdr (assoc "Vim editing + VS Code app keys" drgnx-keys-presets))
                 '((vscode app window) (vim editing))))
  (should (equal (cdr (assoc "Vim" drgnx-keys-presets)) '((vim app editing window))))
  (should (equal (cdr (assoc "Emacs editing + VS Code app keys" drgnx-keys-presets))
                 '((emacs editing) (vscode app window))))
  (should (assoc "VS Code" drgnx-keys-presets))
  (should (assoc "Emacs" drgnx-keys-presets))
  (should-not (seq-find (lambda (p) (string-search "needs" (car p))) drgnx-keys-presets)))

(ert-deftest drgnx-keys-modal/apply-runs-the-hook ()
  (drgnx-keys-modal-test--with-commands
    (let* ((dir (make-temp-file "drgnx-keys-modal" t))
           (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir) (concat "XDG_STATE_HOME=" dir "/state"))
                                        process-environment))
           (drgnx-keys--applied nil) (drgnx-keys-profiles nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
           (drgnx-keys--session-layers '((vscode app window) (vim editing)))
           (seen nil)
           (drgnx-keys-after-apply-functions (list (lambda (layers) (push layers seen)))))
      (unwind-protect
          (progn (drgnx-keys-apply)
                 (should (equal seen '(((vscode app window) (vim editing)))))
                 ;; a failing function does not stop the others, nor the apply
                 (setq seen nil
                       drgnx-keys-after-apply-functions
                       (list (lambda (_) (error "boom")) (lambda (layers) (push layers seen))))
                 (drgnx-keys-apply)
                 (should (= (length seen) 1)))
        (drgnx-keys--restore)
        (delete-directory dir t)))))

(provide 'keys-modal-test)
;;; keys-modal-test.el ends here
