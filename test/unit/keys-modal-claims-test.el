;;; keys-modal-claims-test.el --- batch tests: Vim's key claims per state -*- lexical-binding: t -*-
;; The shipped profiles, no evil: the hand-listed claims of keys/vim.eld with their states, the leader and panel
;; maps over other layers' keys, the snapshot of evil's maps when evil arrives.  The tests that need the real evil
;; are in test/unit/isolated/keys-modal-claims-isolated.el, run in their own Emacs by the last test here.
(require 'ert)
(require 'drgnx)
(require 'drgnx-keys-modal)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(defvar evil-normal-state-map)

(defconst drgnx-keys-claims-test--profiles
  (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))
  "The shipped profiles.")

(defconst drgnx-keys-claims-test--defaults (copy-keymap global-map) "Emacs' own bindings.")

(defconst drgnx-keys-claims-test--mixed '((vscode app window) (vim editing)) "The mixed preset.")

(defvar drgnx-keys-claims-test--more nil
  "Entries (PROFILE ENTRY…) added to the shipped profiles by `drgnx-keys-claims-test--with'; their commands are
registered as test commands of scope `window'.")

(defun drgnx-keys-claims-test--profiles ()
  "The shipped profiles plus `drgnx-keys-claims-test--more'."
  (mapcar (lambda (p)
            (if-let* ((more (alist-get (car p) drgnx-keys-claims-test--more)))
                (cons (car p) (plist-put (copy-sequence (cdr p)) :bind (append (plist-get (cdr p) :bind) more)))
              p))
          drgnx-keys-claims-test--profiles))

(defmacro drgnx-keys-claims-test--with (var layers &rest body)
  "BODY with VAR the resolution of LAYERS, in a registry holding the core commands and the startup modules."
  (declare (indent 2))
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
         (find-file-hook find-file-hook))
     (drgnx--core-commands)
     (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
     (drgnx-modules-run 'startup)
     (dolist (e (delete-dups (mapcar #'car (apply #'append (mapcar #'cdr drgnx-keys-claims-test--more)))))
       (drgnx-command-define e :category "Test" :title (format "Test %s" e) :command #'ignore :scope 'window :doc "test"))
     (let ((,var (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles (drgnx-keys-claims-test--profiles)
                                     :layers ,layers :defaults drgnx-keys-claims-test--defaults)))
       ,@body)))

(defun drgnx-keys-claims-test--binds (r id)
  "Resolution R's bindings of command ID as (KEY . MAPSYM)."
  (delq nil (mapcar (lambda (b) (and (eq (plist-get b :id) id)
                                     (cons (plist-get b :key) (cdr (drgnx-commands--keymap-spec (plist-get b :map))))))
                    (plist-get r :bindings))))

(defun drgnx-keys-claims-test--conflicts (r key &optional map)
  "Resolution R's conflicts on KEY (in MAP, a keymap symbol, when given)."
  (seq-filter (lambda (c) (and (equal (plist-get c :key) key) (or (null map) (eq (plist-get c :map) map))))
              (plist-get r :conflicts)))

(ert-deftest drgnx-keys-claims/a-snapshot-without-evil-maps-is-quiet ()
  ;; evil "arrives" with only its normal-state map: the snapshot holds that one, nothing fails.
  (should (assq 'evil after-load-alist))
  (let ((features features) (drgnx-keys-modal-snapshots nil)
        (evil-normal-state-map (make-sparse-keymap)))
    (keymap-set evil-normal-state-map "C-r" #'ignore)
    (provide 'evil)
    (should (equal (mapcar #'car drgnx-keys-modal-snapshots) '(evil-normal-state-map)))
    ;; a copy: what drgnx binds in evil's map later does not change it
    (keymap-set evil-normal-state-map "C-r" #'undo)
    (should (eq (keymap-lookup (cdar drgnx-keys-modal-snapshots) "C-r") #'ignore))))

(ert-deftest drgnx-keys-claims/mixed-stack-keeps-vscode-keys-outside-normal ()
  (drgnx-keys-claims-test--with r drgnx-keys-claims-test--mixed
    (should (member '("C-o" . global-map) (drgnx-keys-claims-test--binds r 'open-file)))
    (should (member '("SPC f f" . drgnx-modal-leader-map) (drgnx-keys-claims-test--binds r 'open-file)))
    ;; the other VS Code keys Vim claims in normal state: kept too, for insert state and panels
    (pcase-dolist (`(,id ,key) '((close-tab "C-w") (toggle-sidebar "C-b") (go-quick-open "C-p") (file-new "C-n")
                                 (go-symbol-project "C-t")))
      (should (equal (list id key t) (list id key (and (member (cons key 'global-map) (drgnx-keys-claims-test--binds r id)) t)))))
    (let* ((cs (drgnx-keys-claims-test--conflicts r "C-o")) (c (car cs)))
      (should (= (length cs) 1))
      (should (eq (plist-get c :kind) 'claim))
      (should (equal (plist-get c :states) '(normal visual motion)))
      (should (plist-get c :elsewhere))
      (should (equal (plist-get (plist-get c :winner) :claim) "Jump Back"))
      (should (eq (plist-get (plist-get c :winner) :layer) 'vim))
      (should (equal (drgnx-keys-conflict-text c)
                     ;; (the registry's title of open-file is "Open File…")
                     "C-o Jump Back (vim; normal, visual, motion state) over Open File… (vscode) [claim]; Open File… in insert state and panels")))
    ;; Vim's insert-state keys are off in a mixed stack: no claim on VS Code's C-x (Explorer's Cut is a panel key)
    (should-not (seq-find (lambda (c) (memq 'insert (plist-get c :states))) (plist-get r :conflicts)))))

(ert-deftest drgnx-keys-claims/leader-over-a-panel-key-is-reported ()
  (drgnx-keys-claims-test--with r drgnx-keys-claims-test--mixed
    (should (member '("SPC" . drgnx-explorer-mode-map) (drgnx-keys-claims-test--binds r 'explorer-preview)))
    (let* ((cs (drgnx-keys-claims-test--conflicts r "SPC" 'drgnx-explorer-mode-map)) (c (car cs)))
      (should (= (length cs) 1))
      (should (eq (plist-get c :kind) 'claim))
      (should (equal (plist-get c :states) '(panels)))
      (should (eq (plist-get (plist-get c :winner) :layer) 'vim))
      (should (equal (mapcar (lambda (p) (plist-get p :id)) (plist-get c :losers)) '(explorer-preview)))
      (should (string-search "[claim, in drgnx-explorer-mode-map]" (drgnx-keys-conflict-text c))))))

(ert-deftest drgnx-keys-claims/c-w-in-panels-over-close-tab ()
  ;; A window command on the C-w leader (Vim's C-w h, Focus Left), a window-scope command: in the mixed stack an extra key.
  (drgnx-keys-claims-test--with r drgnx-keys-claims-test--mixed
    (should (member '("C-w" . global-map) (drgnx-keys-claims-test--binds r 'close-tab)))
    (should (equal (drgnx-keys-claims-test--binds r 'focus-left) '(("C-w h" . drgnx-modal-leader-map))))
    (let* ((cs (drgnx-keys-claims-test--conflicts r "C-w" 'global-map)) (c (car cs)))
      (should (= (length cs) 1))
      (should (eq (plist-get c :kind) 'claim))
      (should (equal (plist-get c :states) '(normal visual motion panels)))
      (should (eq (plist-get (plist-get c :winner) :layer) 'vim))
      (should (equal (mapcar (lambda (p) (plist-get p :id)) (plist-get c :losers)) '(close-tab)))
      (should (string-suffix-p "; Close Tab in insert state" (drgnx-keys-conflict-text c))))))

(ert-deftest drgnx-keys-claims/no-modal-layer-no-state-claims ()
  (dolist (layers '(((vscode app editing window)) ((emacs app editing window)) ((emacs editing) (vscode app window))))
    (drgnx-keys-claims-test--with r layers
      (should-not (seq-find (lambda (c) (plist-member c :states)) (plist-get r :conflicts))))))

(ert-deftest drgnx-keys-claims/malformed-layers-are-a-problem-not-an-error ()
  (dolist (layers '(oops (vim) ((vim app) . tail) ((vim nosuchscope))))
    (drgnx-keys-claims-test--with r layers
      (should (seq-find (lambda (p) (string-prefix-p "key layers " p)) (plist-get r :problems)))
      (should-not (plist-get r :bindings)))))

(ert-deftest drgnx-keys-claims/evil-tests-in-their-own-emacs ()
  (should (null (drgnx-modal-test-isolated-result "test/unit/isolated/keys-modal-claims-isolated.el"
                                                  "^drgnx-keys-claims/"))))

(provide 'keys-modal-claims-test)
;;; keys-modal-claims-test.el ends here
