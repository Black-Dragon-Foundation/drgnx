;;; keys-evil-test.el --- batch tests: a profile's keys in evil's states, and yours -*- lexical-binding: t -*-
;; test-class: det
;; drgnx never writes evil's state maps.  A profile's key for a state sits in the profile map's auxiliary keymap for that
;; state ([normal-state] in `drgnx-keys--profile-map'), your evil writes in your map's (`drgnx-keys-user-map'), so evil
;; finds them as the global map's auxiliary keymaps: below every mode's (evil-collection's keys win), above evil's own
;; state maps (docs/develop/key-layers.md, "evil").  Needs DRGNX_MODAL_ELPA (evil, evil-collection); skipped without.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(defvar evil-want-keybinding)
(defvar evil-normal-state-map)
(defvar evil-motion-state-map)
(defvar dired-mode-map)
(declare-function evil-local-mode "evil-core")
(declare-function evil-normal-state "evil-states")
(declare-function evil-motion-state "evil-states")
(declare-function evil-global-set-key "evil-core")
(declare-function evil-define-key* "evil-core")
(declare-function evil-auxiliary-keymap-p "evil-core")
(declare-function evil-get-auxiliary-keymap "evil-core")
(declare-function evil-collection-init "evil-collection")

(defun keys-ev-a () "Profile command A." (interactive))
(defun keys-ev-mine () "Your command." (interactive))
(defun keys-ev-pkg () "A package's command." (interactive))

;; A package's mode map and a drgnx one, for the profile's keys in a mode map under evil.
(defvar keys-ev-pkg-mode-map (make-sparse-keymap))
(defvar drgnx-keys-test-evown-mode-map (make-sparse-keymap))
(define-derived-mode drgnx-keys-test-evown-mode fundamental-mode "EO")

(defmacro keys-ev--with (bind &rest body)
  "BODY with evil loaded and a profile `ev' holding the entries BIND (`(COMMAND KEY :map MAP)'), command ev-a,
applied on Linux; `ev-empty' is a profile with no keys.  Your keys and the profile's are undone after."
  (declare (indent 1))
  `(drgnx-modal-test-with-evil
     (setq evil-want-keybinding nil)
     (require 'evil)
     (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
       (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
         (drgnx-test-with-areas
           (let* ((drgnx-keys-profiles (list (list 'ev :name "Ev" :bind ',bind) (list 'ev-empty :name "Empty" :bind nil)))
                  (drgnx-keys--session-layers nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
                  (drgnx-keys--yours-in-maps (make-hash-table :test #'equal)) (drgnx-keys--yours-everywhere nil))
             (drgnx-command-define 'ev-a :title "A" :category "Test" :command #'keys-ev-a :doc "t")
             (unwind-protect (progn (drgnx-keys-use '((ev app editing window))) ,@body)
               (drgnx-keys-forget-yours)
               (drgnx-keys--restore))))))))

(defmacro keys-ev--as-you (&rest body)
  "BODY as a keyboard command of yours (M-:): its key writes are yours."
  `(let ((this-command 'eval-expression)) ,@body))

(defmacro keys-ev--in (state &rest body)
  "BODY in a temp buffer with evil on, in STATE (normal or motion)."
  (declare (indent 1))
  `(with-temp-buffer
     (evil-local-mode 1)
     (if (eq ,state 'motion) (evil-motion-state) (evil-normal-state))
     ,@body))

(defun keys-ev--in-evils-maps-p (key)
  "Whether KEY runs a drgnx test command in evil's own normal or motion state map."
  (memq (lookup-key evil-normal-state-map (kbd key)) '(keys-ev-a keys-ev-mine)))

(ert-deftest drgnx-keys/evil-a-profile-key-sits-in-the-profiles-aux-map ()
  "A profile's key in evil's normal state works there, from the profile map's normal-state auxiliary keymap; evil's
own map is not written."
  (keys-ev--with ((ev-a "g d" :map (evil . evil-normal-state-map)))
    (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'keys-ev-a)))
    (should-not (keys-ev--in-evils-maps-p "g d"))
    (should (eq (lookup-key evil-motion-state-map (kbd "g d")) #'evil-goto-definition))
    (should (evil-auxiliary-keymap-p (lookup-key drgnx-keys--profile-map [normal-state])))))

(ert-deftest drgnx-keys/evil-a-profile-switch-gives-evils-key-back ()
  "Switching to a profile without the key: evil's own key is back, nothing of the profile's left in evil's maps."
  (keys-ev--with ((ev-a "g d" :map (evil . evil-normal-state-map)))
    (let ((aux (lookup-key drgnx-keys--profile-map [normal-state])))
      (drgnx-keys-use '((ev-empty app editing window)))
      (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'evil-goto-definition)))
      (drgnx-keys-use '((ev app editing window)))
      (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'keys-ev-a)))
      ;; the same auxiliary keymap, emptied and filled in place: evil's buffers never have to take a new one in
      (should (eq (lookup-key drgnx-keys--profile-map [normal-state]) aux)))))

(ert-deftest drgnx-keys/evil-a-motion-key-works-in-normal-and-motion-state ()
  "A profile key for evil's motion state works in motion state and in normal state (which takes motion keys in)."
  (keys-ev--with ((ev-a "g d" :map (evil . evil-motion-state-map)))
    (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'keys-ev-a)))
    (keys-ev--in 'motion (should (eq (key-binding (kbd "g d")) #'keys-ev-a)))
    (should (eq (lookup-key evil-motion-state-map (kbd "g d")) #'evil-goto-definition))))

(ert-deftest drgnx-keys/evil-your-key-beats-the-profiles-and-gives-it-back ()
  "Your `evil-global-set-key' goes to your map's normal-state auxiliary keymap and beats the profile's key, after an
apply too; take it away and the profile's key is back.  evil's own map is never written."
  (keys-ev--with ((ev-a "g d" :map (evil . evil-normal-state-map)))
    (keys-ev--as-you (evil-global-set-key 'normal (kbd "g d") #'keys-ev-mine))
    (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'keys-ev-mine)))
    (should-not (keys-ev--in-evils-maps-p "g d"))
    (should (gethash "<normal-state> g d" drgnx-keys--yours))
    (drgnx-keys-apply)
    (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'keys-ev-mine)))
    (keys-ev--as-you (define-key evil-normal-state-map (kbd "g d") nil t))
    (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'keys-ev-a)))))

(ert-deftest drgnx-keys/evil-your-nil-takes-the-profiles-key-away ()
  "Your nil on a key in a state (`evil-define-key' … nil) takes the profile's key off that state, after an apply too:
the key is evil's own again, as with no profile."
  (keys-ev--with ((ev-a "g d" :map (evil . evil-normal-state-map)))
    (keys-ev--as-you (evil-define-key* 'normal 'global (kbd "g d") nil))
    (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'evil-goto-definition)))
    (drgnx-keys-apply)
    (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'evil-goto-definition)))
    (should (gethash "<normal-state> g d" drgnx-keys--yours))))

(ert-deftest drgnx-keys/evil-a-packages-write-stays-in-evils-map-below-the-profile ()
  "A package's write into evil's normal state map stays there, below the profile's key."
  (keys-ev--with ((ev-a "g d" :map (evil . evil-normal-state-map)))
    (unwind-protect
        (progn (let ((this-command nil)) (evil-global-set-key 'normal (kbd "g d") #'keys-ev-pkg))
               (should (eq (lookup-key evil-normal-state-map (kbd "g d")) #'keys-ev-pkg))
               (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'keys-ev-a))))
      (let ((nidhogg-define-key-redirect-function nil)) (define-key evil-normal-state-map (kbd "g d") nil t)))))

(ert-deftest drgnx-keys/evil-an-aux-map-made-late-reaches-a-buffer-already-in-normal-state ()
  "A buffer in normal state before the profile's first key for that state, or before your first evil key: both
work there at once (evil's buffers take the new auxiliary keymaps in)."
  (keys-ev--with ((ev-a "g d" :map (evil . evil-normal-state-map)))
    (drgnx-keys-use '((ev-empty app editing window)))
    (let ((nidhogg-define-key-redirect-function nil))   ; as in a session that never had these auxiliary keymaps
      (setcdr drgnx-keys--profile-map nil)
      (setcdr drgnx-keys-user-map nil))
    (keys-ev--in 'normal
      (drgnx-keys-use '((ev app editing window)))
      (should (eq (key-binding (kbd "g d")) #'keys-ev-a))
      (keys-ev--as-you (evil-global-set-key 'normal (kbd "g y") #'keys-ev-mine))
      (should (eq (key-binding (kbd "g y")) #'keys-ev-mine)))))

(ert-deftest drgnx-keys/evil-collections-dired-keys-beat-the-profiles ()
  "In dired, evil-collection's keys (its gx too) beat the profile's key for normal state; elsewhere the profile's key
works."
  (keys-ev--with ((ev-a "g x" :map (evil . evil-normal-state-map)))
    (require 'evil-collection)
    (evil-collection-init '(dired))
    (require 'dired)
    (let* ((aux (evil-get-auxiliary-keymap dired-mode-map 'normal)) (theirs (and aux (lookup-key aux (kbd "g x")))))
      (should (commandp theirs))
      (let ((d (dired-noselect temporary-file-directory)))
        (unwind-protect
            (with-current-buffer d
              (evil-local-mode 1) (evil-normal-state)
              (should (eq (key-binding (kbd "g x")) theirs)))
          (kill-buffer d))))
    (keys-ev--in 'normal (should (eq (key-binding (kbd "g x")) #'keys-ev-a)))))

(ert-deftest drgnx-keys/evil-a-profile-key-in-a-packages-mode-map-beats-evils-state-map ()
  "A profile key in a package's mode map works in normal state over evil's own key there, without a write into the
package's map (no auxiliary keymap made in it)."
  (keys-ev--with ((ev-a "g d" :map keys-ev-pkg-mode-map))
    (with-temp-buffer
      (use-local-map keys-ev-pkg-mode-map)
      (evil-local-mode 1) (evil-normal-state)
      (should (eq (key-binding (kbd "g d")) #'keys-ev-a)))
    (keys-ev--in 'normal (should (eq (key-binding (kbd "g d")) #'evil-goto-definition)))
    (should-not (lookup-key keys-ev-pkg-mode-map [normal-state]))))

(ert-deftest drgnx-keys/evil-a-profile-key-in-a-drgnx-mode-map-beats-evils-state-map ()
  "A profile key in a drgnx mode map works in normal state over evil's own key there, from the map's layer: the map
itself holds no auxiliary keymap."
  (keys-ev--with ((ev-a "g d" :map drgnx-keys-test-evown-mode-map))
    (with-temp-buffer
      (drgnx-keys-test-evown-mode)
      (evil-local-mode 1) (evil-normal-state)
      (should (eq (key-binding (kbd "g d")) #'keys-ev-a)))
    (let ((own (copy-keymap drgnx-keys-test-evown-mode-map)))
      (set-keymap-parent own nil)
      (should-not (lookup-key own [normal-state])))))

(ert-deftest drgnx-keys/evil-your-key-in-a-packages-mode-map-beats-the-profiles ()
  "Your `evil-define-key' in a package's mode map (its normal-state auxiliary keymap) beats the profile's key for
that map; take it away and the profile's key is back."
  (keys-ev--with ((ev-a "g d" :map keys-ev-pkg-mode-map))
    (unwind-protect
        (progn
          (keys-ev--as-you (evil-define-key* 'normal keys-ev-pkg-mode-map (kbd "g d") #'keys-ev-mine))
          (with-temp-buffer
            (use-local-map keys-ev-pkg-mode-map)
            (evil-local-mode 1) (evil-normal-state)
            (should (eq (key-binding (kbd "g d")) #'keys-ev-mine))
            (keys-ev--as-you (define-key (evil-get-auxiliary-keymap keys-ev-pkg-mode-map 'normal) (kbd "g d") nil t))
            (should (eq (key-binding (kbd "g d")) #'keys-ev-a))))
      (let ((nidhogg-define-key-redirect-function nil)) (define-key keys-ev-pkg-mode-map [normal-state] nil t)))))

(provide 'keys-evil-test)
;;; keys-evil-test.el ends here
