;;; keys-layers-test.el --- batch tests: profile keys in other keymaps are layers, never writes -*- lexical-binding: t -*-
;; test-class: det
;; A profile key in a drgnx mode map sits in a layer between the map and its parent (child -> layer -> old parent);
;; one in a foreign map (a package's, wgrep's) sits in one global layer that is active while the buffer's local map is,
;; or inherits, the target map.  Neither writes into the map itself (docs/develop/core.md, "Key layers").
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)

(defun keys-lay-a () "Profile command A." (interactive))
(defun keys-lay-b () "Profile command B." (interactive))
(defun keys-lay-z () "A drgnx mode's own command." (interactive))
(defun keys-lay-own () "A package's own command." (interactive))

;; drgnx's own maps: a mode and one derived from it.  Never called as modes before the first apply, as in a session
;; where a module's mode has not run yet (`define-derived-mode' sets a parent when the mode first runs).
(defvar drgnx-keys-test-lbase-mode-map (let ((m (make-sparse-keymap))) (define-key m "z" #'keys-lay-z) m))
(define-derived-mode drgnx-keys-test-lbase-mode fundamental-mode "LB")
(define-derived-mode drgnx-keys-test-lder-mode drgnx-keys-test-lbase-mode "LD")

;; A package's map and modes: a major mode, one derived from it, and a map wgrep-style (parent: the mode's).
(defvar keys-lay-pkg-mode-map (let ((m (make-sparse-keymap))) (define-key m (kbd "C-c y o") #'keys-lay-own) m))
(define-derived-mode keys-lay-pkg-mode fundamental-mode "KP")
(define-derived-mode keys-lay-child-mode keys-lay-pkg-mode "KC")
(defvar keys-lay-edit-map (let ((m (make-sparse-keymap))) (set-keymap-parent m keys-lay-pkg-mode-map) m))
(defvar keys-lay-other-map (make-sparse-keymap) "A second package map.")
(defvar keys-lay-minor-mode-map (make-sparse-keymap))
(defvar keys-lay-minor-mode nil)

(defmacro keys-lay--with (bind &rest body)
  "BODY with a profile `lay' holding the entries BIND (`(COMMAND KEY :map MAP)'), commands lay-a and lay-b, and `lay'
applied on Linux; `lay-empty' is a profile with no keys.  Undone after."
  (declare (indent 1))
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
     (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
       (drgnx-test-with-areas
         (let* ((drgnx-keys-profiles (list (list 'lay :name "Lay" :bind ',bind) (list 'lay-empty :name "Empty" :bind nil)))
                (drgnx-keys--applied nil) (drgnx-keys--session-layers nil) (drgnx-keys-problems nil) (drgnx-keys-last nil))
           (set-keymap-parent drgnx-keys-test-lder-mode-map nil)
           (set-keymap-parent drgnx-keys-test-lbase-mode-map nil)
           (set-keymap-parent drgnx-keys-test-llate-mode-map nil)
           (drgnx-command-define 'lay-a :title "A" :category "Test" :command #'keys-lay-a :doc "t")
           (drgnx-command-define 'lay-b :title "B" :category "Test" :command #'keys-lay-b :doc "t")
           (unwind-protect (progn (drgnx-keys-use '((lay app editing window))) ,@body)
             (drgnx-keys--restore)))))))

(defun keys-lay--empty () (drgnx-keys-use '((lay-empty app editing window))))

(defun keys-lay--bound (key map)
  "What KEY is in a temp buffer whose local map is MAP."
  (with-temp-buffer (use-local-map map) (key-binding (kbd key))))

(defun keys-lay--own-p (map key)
  "Whether MAP itself, its parents left out, binds KEY to something."
  (let ((c (copy-keymap map)))
    (set-keymap-parent c nil)
    (let ((d (lookup-key c (kbd key)))) (and d (not (numberp d))))))

;;;; T7: parent layers for drgnx's own maps

(ert-deftest drgnx-keys/layers-a-derived-drgnx-mode-keeps-its-parents-map ()
  "The layer goes between the child and the parent the derived mode will take: its key works, the parent mode's own
key and the parent's profile key too, and the child map holds none of the profile's keys."
  (keys-lay--with ((lay-a "C-c y a" :map drgnx-keys-test-lder-mode-map)
                   (lay-b "C-c y b" :map drgnx-keys-test-lbase-mode-map))
    (should (null (plist-get drgnx-keys-last :problems)))
    (with-temp-buffer
      (drgnx-keys-test-lder-mode)
      (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a))
      (should (eq (key-binding (kbd "C-c y b")) #'keys-lay-b))
      (should (eq (key-binding (kbd "z")) #'keys-lay-z)))
    (should-not (keys-lay--own-p drgnx-keys-test-lder-mode-map "C-c y a"))
    (should-not (keys-lay--own-p drgnx-keys-test-lbase-mode-map "C-c y b"))
    (drgnx-keys-apply)
    (drgnx-keys-apply)
    (with-temp-buffer
      (drgnx-keys-test-lder-mode)
      (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a))
      (should (eq (key-binding (kbd "z")) #'keys-lay-z)))
    ;; the profile gone: its keys with it, the chain as the derived mode makes it
    (keys-lay--empty)
    (with-temp-buffer
      (drgnx-keys-test-lder-mode)
      (should-not (key-binding (kbd "C-c y a")))
      (should (eq (key-binding (kbd "z")) #'keys-lay-z)))
    (should (eq (keymap-parent drgnx-keys-test-lder-mode-map) drgnx-keys-test-lbase-mode-map))))

(ert-deftest drgnx-keys/layers-a-parent-set-by-someone-else-is-put-back-and-said ()
  "Someone calls `set-keymap-parent' on the child: the next apply puts the layer back above the new parent, and says so."
  (keys-lay--with ((lay-a "C-c y a" :map drgnx-keys-test-lbase-mode-map))
    (let ((other (make-sparse-keymap)))
      (define-key other "q" #'keys-lay-b)
      (set-keymap-parent drgnx-keys-test-lbase-mode-map other)
      (drgnx-keys-apply)
      (should (cl-some (lambda (p) (string-match-p "parent was replaced" p)) (plist-get drgnx-keys-last :problems)))
      (with-temp-buffer
        (drgnx-keys-test-lbase-mode)
        (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a))
        (should (eq (key-binding (kbd "q")) #'keys-lay-b))))))

;; A mode derived from one whose map is not loaded when the keys are applied.
(define-derived-mode keys-lay-lp-mode fundamental-mode "LP")
(define-derived-mode drgnx-keys-test-llate-mode keys-lay-lp-mode "LL")

(ert-deftest drgnx-keys/layers-a-parent-modes-map-that-loads-later-becomes-the-parent ()
  "The parent mode's library is not loaded at the apply: the layer has no parent yet, the mode's first run would see
the layer as its parent and never take the real one.  When the library loads, the layer gets it."
  (let ((file (make-temp-file "keys-lay-lp" nil ".el")) (old (and (boundp 'keys-lay-lp-mode-map) keys-lay-lp-mode-map)))
    (makunbound 'keys-lay-lp-mode-map)
    (unwind-protect
        (keys-lay--with ((lay-a "C-c y a" :map drgnx-keys-test-llate-mode-map))
          (should-not (keymap-parent (keymap-parent drgnx-keys-test-llate-mode-map)))
          (with-temp-file file
            (insert ";;; -*- lexical-binding: t -*-\n(defvar keys-lay-lp-mode-map (let ((m (make-sparse-keymap))) (define-key m \"w\" #'keys-lay-z) m))\n"))
          (load file nil t)
          (with-temp-buffer
            (drgnx-keys-test-llate-mode)
            (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a))
            (should (eq (key-binding (kbd "w")) #'keys-lay-z)))
          (should-not (memq 'drgnx-keys--complete-parents after-load-functions)))
      (delete-file file)
      (setq keys-lay-lp-mode-map old))))

(ert-deftest drgnx-keys/layers-lint-finds-a-profile-key-in-a-child-map ()
  "A profile key that also sits in the drgnx map itself is reported; none does after a plain apply."
  (keys-lay--with ((lay-a "C-c y a" :map drgnx-keys-test-lder-mode-map))
    (should (null (drgnx-keys-lint-children)))
    (define-key drgnx-keys-test-lder-mode-map (kbd "C-c y a") #'keys-lay-b)
    (should (equal (drgnx-keys-lint-children) '("drgnx-keys-test-lder-mode-map C-c y a")))))

;;;;; The terminal's raw keys give way to the layer

(ert-deftest drgnx-keys/layers-the-terminals-raw-keys-give-way-to-a-profile-key ()
  "`drgnx-term-mode-map' sends every key to the program: a profile key for it (terminal Paste on C-y) would be shadowed
by that raw binding in the map itself; `drgnx-term-apply-keys' frees the layer's events, and gives them back."
  (load (expand-file-name "modules/tools/drgnx-term" drgnx-dir) nil t)
  (keys-lay--with ((lay-a "C-y" :map (drgnx-term . drgnx-term-mode-map)))
    (drgnx-term-apply-keys)
    (should (eq (keys-lay--bound "C-y" drgnx-term-mode-map) #'keys-lay-a))
    (should-not (keys-lay--own-p drgnx-term-mode-map "C-y"))
    (keys-lay--empty)
    (drgnx-term-apply-keys)
    (should (eq (lookup-key drgnx-term-mode-map (kbd "C-y")) #'drgnx-term-send-event))))

;;;;; Every shipped profile key that names a drgnx map

(ert-deftest drgnx-keys/layers-no-shipped-profile-key-sits-in-a-drgnx-map-itself ()
  "Lint: a profile's key for a drgnx map is the layer's, so the map itself (its parents left out) holds none of them."
  (let ((bad nil) (checked 0)
        (profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (dolist (profile profiles)
      (dolist (entry (plist-get (cdr profile) :bind))
        (let* ((keys (seq-take-while #'stringp (cdr entry)))
               (spec (plist-get (seq-drop-while #'stringp (cdr entry)) :map))
               (feature (car-safe spec)) (sym (if (consp spec) (cdr spec) spec)))
          (when (and sym (drgnx-keys--own-map-p sym))
            (when-let* ((feature) ((not (featurep feature)))
                        (file (car (directory-files-recursively (expand-file-name "modules" drgnx-dir)
                                                                (format "\\`%s\\.el\\'" feature)))))
              (condition-case err (load file nil t) (error (push (format "%s: %S" feature err) bad))))
            (when (and (boundp sym) (keymapp (symbol-value sym)))
              (dolist (key keys)
                (cl-incf checked)
                (when (and (keys-lay--own-p (symbol-value sym) key)
                           ;; the terminal's raw keys give way to the layer in `drgnx-term-apply-keys' (below)
                           (not (eq (lookup-key (symbol-value sym) (kbd key)) #'drgnx-term-send-event)))
                  (push (format "%s %s (%s)" sym key (car profile)) bad))))))))
    (should (> checked 20))
    (should (null bad))))

;;;; T8: the foreign layer

(ert-deftest drgnx-keys/foreign-layer-is-active-only-under-the-target-map ()
  "The key works where the local map is the target, never writes into it, and is not there elsewhere."
  (keys-lay--with ((lay-a "C-c y a" :map keys-lay-pkg-mode-map))
    (should (eq (keys-lay--bound "C-c y a" keys-lay-pkg-mode-map) #'keys-lay-a))
    (should (eq (keys-lay--bound "C-c y o" keys-lay-pkg-mode-map) #'keys-lay-own))
    (should-not (keys-lay--bound "C-c y a" (make-sparse-keymap)))
    (should-not (lookup-key keys-lay-pkg-mode-map (kbd "C-c y a")))
    (should (eq (car (last minor-mode-map-alist)) drgnx-keys--foreign-entry))))

(ert-deftest drgnx-keys/foreign-layer-follows-the-local-map-not-the-mode ()
  "wgrep swaps the local map with `use-local-map' and keeps the major mode: the target is wgrep's own map, or
the major mode's map as the new map's parent; an unrelated map has neither.  A derived mode inherits."
  (keys-lay--with ((lay-a "C-c y a" :map keys-lay-pkg-mode-map) (lay-b "C-c y b" :map keys-lay-edit-map))
    (with-temp-buffer
      (keys-lay-pkg-mode)
      (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a))
      (should-not (key-binding (kbd "C-c y b")))
      (use-local-map keys-lay-edit-map)                  ; the swap: still keys-lay-pkg-mode
      (should (eq major-mode 'keys-lay-pkg-mode))
      (should (eq (key-binding (kbd "C-c y b")) #'keys-lay-b))
      (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a))
      (use-local-map (make-sparse-keymap))               ; an unrelated map: nothing of the mode's
      (should-not (key-binding (kbd "C-c y a")))
      (should-not (key-binding (kbd "C-c y b"))))
    (with-temp-buffer
      (keys-lay-child-mode)
      (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a))
      (should-not (key-binding (kbd "C-c y b"))))
    (with-temp-buffer
      (use-local-map (make-composed-keymap nil keys-lay-pkg-mode-map))
      (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a)))))

(ert-deftest drgnx-keys/foreign-layer-steps-below-other-minor-modes-and-stays-last ()
  "Another minor mode's key beats the layer's; the layer's alist entry is last after another mode pushes or
appends, and gone when no profile key needs it."
  (keys-lay--with ((lay-a "C-c y a" :map keys-lay-pkg-mode-map))
    (setf (alist-get 'keys-lay-minor-mode minor-mode-map-alist) keys-lay-minor-mode-map)
    (define-key keys-lay-minor-mode-map (kbd "C-c y a") #'keys-lay-b)
    (unwind-protect
        (with-temp-buffer
          (keys-lay-pkg-mode)
          (setq-local keys-lay-minor-mode t)
          (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-b))
          (setq-local keys-lay-minor-mode nil)
          (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a))
          (drgnx-keys-apply)
          (should (eq (car (last minor-mode-map-alist)) drgnx-keys--foreign-entry))
          (keys-lay--empty)
          (should-not (memq drgnx-keys--foreign-entry minor-mode-map-alist))
          (should-not (key-binding (kbd "C-c y a"))))
      (setq minor-mode-map-alist (assq-delete-all 'keys-lay-minor-mode minor-mode-map-alist)))))

(defvar keys-lay-m2-map (make-sparse-keymap) "The map of a minor mode whose keys a profile binds (as vlf's `vlf-prefix-map').")
(defvar keys-lay-m2-mode nil)

(ert-deftest drgnx-keys/foreign-layer-follows-a-minor-modes-map ()
  "A target that is a minor mode's map (vlf's `vlf-prefix-map'), or inherited by one, is active while the mode is on."
  (keys-lay--with ((lay-a "C-c y a" :map keys-lay-m2-map))
    (setf (alist-get 'keys-lay-m2-mode minor-mode-map-alist) (make-composed-keymap nil keys-lay-m2-map))
    (unwind-protect
        (with-temp-buffer
          (should-not (key-binding (kbd "C-c y a")))
          (setq-local keys-lay-m2-mode t)
          (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a))
          (setq-local keys-lay-m2-mode nil)
          (should-not (key-binding (kbd "C-c y a"))))
      (setq minor-mode-map-alist (assq-delete-all 'keys-lay-m2-mode minor-mode-map-alist)))))

(ert-deftest drgnx-keys/foreign-layer-follows-a-keymap-property-at-point ()
  "A text property's or an overlay's keymap (a button's) that is, or inherits, the target makes it active at point."
  (keys-lay--with ((lay-a "C-c y a" :map keys-lay-other-map))
    (with-temp-buffer
      (insert (propertize "x" 'keymap (make-composed-keymap nil keys-lay-other-map)) "y")
      (goto-char 1)
      (should (eq (key-binding (kbd "C-c y a")) #'keys-lay-a))
      (goto-char 2)
      (should-not (key-binding (kbd "C-c y a"))))))

(ert-deftest drgnx-keys/terminal-key-split-lists-the-keys-of-its-own-map ()
  "The profile's keys in the terminal's keymap (Paste on C-y) reach drgnx, not the program, and the split says so."
  (load (expand-file-name "modules/tools/drgnx-term" drgnx-dir) nil t)
  (keys-lay--with ((lay-a "C-y" :map (drgnx-term . drgnx-term-mode-map)))
    (let ((split (drgnx-terminal-key-split)))
      (should (member "C-y" (plist-get split :to-drgnx)))
      (should-not (member "C-y" (plist-get split :to-shell))))))

(ert-deftest drgnx-keys/foreign-layer-prefix-hides-nothing-where-it-is-inactive ()
  "A layer key under C-c does not turn a local command on C-c itself into a prefix in other buffers; two targets may
share a key."
  (keys-lay--with ((lay-a "C-c y a" :map keys-lay-pkg-mode-map) (lay-b "C-c y a" :map keys-lay-other-map))
    (let ((m (make-sparse-keymap)))
      (define-key m (kbd "C-c") #'keys-lay-z)
      (should (eq (keys-lay--bound "C-c" m) #'keys-lay-z)))
    (should (eq (keys-lay--bound "C-c y a" keys-lay-pkg-mode-map) #'keys-lay-a))
    (should (eq (keys-lay--bound "C-c y a" keys-lay-other-map) #'keys-lay-b))))

(ert-deftest drgnx-keys/foreign-layer-goes-with-the-restore ()
  "Restoring (a module's teardown) leaves no layer and no entry behind."
  (keys-lay--with ((lay-a "C-c y a" :map keys-lay-pkg-mode-map))
    (should drgnx-keys--foreign-on)
    (drgnx-keys--restore)
    (should-not drgnx-keys--foreign-on)
    (should-not (memq drgnx-keys--foreign-entry minor-mode-map-alist))
    (should-not (keys-lay--bound "C-c y a" keys-lay-pkg-mode-map))))

(provide 'keys-layers-test)
;;; keys-layers-test.el ends here
