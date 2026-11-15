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

(provide 'keys-layers-test)
;;; keys-layers-test.el ends here
