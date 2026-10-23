;;; mod-shortcuts-test.el --- batch tests: the Keyboard Shortcuts editor -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(require 'drgnx-keys-edit)
(load (expand-file-name "modules/tools/drgnx-shortcuts" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)

(defvar drgnx-shortcuts-test-mode-map (make-sparse-keymap) "A view's keymap for the tests.")

(defconst drgnx-shortcuts-test--commands
  '((sc-a "Test" "Open Alpha") (sc-b "Other" "Beta View Thing") (sc-c "Test" "Gamma") (sc-d "Test" "Delta")
    (sc-e "Test" "Epsilon") (sc-f "Other" "Zeta") (sc-g "Test" "Eta") (sc-n "Test" "Native One")
    (sc-t "Test" "Theta") (sc-k "Test" "Kappa"))
  "(ID CATEGORY TITLE); each runs `drgnx-shortcuts-test-ID'.")

(dolist (c drgnx-shortcuts-test--commands)
  (defalias (intern (format "drgnx-shortcuts-test-%s" (car c))) (lambda () (interactive) nil)))

(defconst drgnx-shortcuts-test--profiles
  '((alpha :name "Alpha"
           :bind ((sc-a "C-c a") (sc-b "C-c b" :map drgnx-shortcuts-test-mode-map) (sc-c "C-c c") (sc-d :none "x")
                  (sc-e "C-c e C-x") (sc-f :none "y") (sc-g :none "z") (sc-n :none "native") (sc-t "C-S-t")
                  (sc-k "C-k C-q")))           ; over Emacs' kill-line (C-k): no conflict
    (beta :name "Beta"
          :bind ((sc-a "C-c z") (sc-b :none "x") (sc-c :none "x") (sc-d :none "x") (sc-e :none "x") (sc-f :none "x")
                 (sc-g :none "x") (sc-n :none "x") (sc-t :none "x") (sc-k :none "x"))
          :claims ((editing "C-c a" "beta's own C-c a"))))
  "Two small key profiles.")

(defmacro drgnx-shortcuts-test--with (&rest body)
  "BODY with a registry of the test commands, the alpha profile applied, temp config and state dirs (keys.eld and
the usage counts go there, never the user's), no usage counted, and every binding undone after."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "drgnx-shortcuts" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir "/config")
                                             (concat "XDG_STATE_HOME=" dir "/state"))
                                       process-environment))
          (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
          (drgnx-keys-profiles (copy-tree drgnx-shortcuts-test--profiles))
          (drgnx-keys--applied nil) (drgnx-keys--session-layers nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
          (drgnx-keys-presets '(("Alpha" . ((alpha app editing window))) ("Beta" . ((beta app editing window)))))
          (drgnx-surfaces--usage nil) (drgnx-surfaces--usage-dirty nil)
          (drgnx-settings-apply--entries nil)
          (drgnx-shortcuts-chord-wait 0.05))
     (drgnx-test-areas-reset)
     (unwind-protect
         (cl-letf* ((read-key (symbol-function 'read-key))
                    ;; a read with no key queued fails at once (batch would wait on stdin)
                    ((symbol-function 'read-key)
                     (lambda (&rest args) (if unread-command-events (apply read-key args) (error "No key queued"))))
                    ;; …and so does a question no test expects
                    ((symbol-function 'read-multiple-choice) (lambda (prompt &rest _) (error "Unexpected question: %s" prompt)))
                    ((symbol-function 'yes-or-no-p) (lambda (prompt) (error "Unexpected question: %s" prompt)))
                    ((symbol-function 'completing-read) (lambda (prompt &rest _) (error "Unexpected question: %s" prompt))))
           (make-directory (concat dir "/config") t)
           (pcase-dolist (`(,id ,category ,title) drgnx-shortcuts-test--commands)
             (drgnx-command-define id :category category :title title
                                   :command (intern (format "drgnx-shortcuts-test-%s" id))))
           (drgnx-keys-use '((alpha app editing window)))
           ,@body)
       (drgnx-keys--restore)
       (drgnx-test-areas-reset)
       (keymap-unset global-map "C-c 9" t)
       (when (get-buffer "*drgnx keyboard shortcuts*") (kill-buffer "*drgnx keyboard shortcuts*"))
       (drgnx-timer-cancel 'surfaces-usage)
       (delete-directory dir t))))

(defun drgnx-shortcuts-test--row (id) (seq-find (lambda (r) (eq (plist-get r :id) id)) (drgnx-shortcuts--rows)))

(defun drgnx-shortcuts-test--keys (id) (mapcar #'car (plist-get (drgnx-shortcuts-test--row id) :keys)))

(defun drgnx-shortcuts-test--line (id)
  "The editor's line for command ID, or nil when it is not shown."
  (with-current-buffer "*drgnx keyboard shortcuts*"
    (save-excursion
      (goto-char (point-min))
      (when-let* ((m (text-property-search-forward 'drgnx-shortcuts-id id (lambda (v x) (eq v x)))))
        (buffer-substring-no-properties (prop-match-beginning m) (prop-match-end m))))))

(defun drgnx-shortcuts-test--shown ()
  "The ids of the rows shown, in order."
  (with-current-buffer "*drgnx keyboard shortcuts*"
    (save-excursion
      (goto-char (point-min))
      (let (ids m)
        (while (setq m (text-property-search-forward 'drgnx-shortcuts-id nil (lambda (_ x) x)))
          (push (prop-match-value m) ids))
        (nreverse ids)))))

(defun drgnx-shortcuts-test--goto (id)
  (set-buffer "*drgnx keyboard shortcuts*")
  (goto-char (point-min))
  (let ((m (text-property-search-forward 'drgnx-shortcuts-id id (lambda (v x) (eq v x)))))
    (should m)
    (goto-char (prop-match-beginning m))))

(defun drgnx-shortcuts-test--user ()
  "keys.eld's :bind and :unbind."
  (let ((u (drgnx-keys-read-user))) (list (plist-get u :bind) (plist-get u :unbind))))

(defmacro drgnx-shortcuts-test--answering (choice &rest body)
  "BODY with every Replace / Keep both question answered CHOICE (?r, ?k or ?c); the questions asked are in `asked'."
  (declare (indent 1))
  `(let ((asked nil))
     (cl-letf (((symbol-function 'read-multiple-choice)
                (lambda (prompt choices &rest _) (push prompt asked) (assq ,choice choices))))
       ,@body)))

(ert-deftest drgnx-shortcuts/rows-show-source-and-where ()
  (drgnx-shortcuts-test--with
    (drgnx-keys-edit-bind 'sc-c "C-c q")
    (keymap-set global-map "C-c 9" #'drgnx-shortcuts-test-sc-n)   ; a key a package bound itself
    (drgnx-shortcuts)
    (with-current-buffer "*drgnx keyboard shortcuts*" (should (eq major-mode 'drgnx-shortcuts-mode)))
    (let ((a (drgnx-shortcuts-test--row 'sc-a)) (b (drgnx-shortcuts-test--row 'sc-b))
          (c (drgnx-shortcuts-test--row 'sc-c)) (n (drgnx-shortcuts-test--row 'sc-n)) (d (drgnx-shortcuts-test--row 'sc-d)))
      (should (equal (list (mapcar #'car (plist-get a :keys)) (plist-get a :source) (plist-get a :where))
                     '(("C-c a") "Alpha" "global")))
      (should (equal (list (plist-get b :source) (plist-get b :where)) '("Alpha" "shortcuts-test")))
      (should (equal (list (mapcar #'car (plist-get c :keys)) (plist-get c :source)) '(("C-c q") "keys.eld")))
      (should (equal (list (mapcar #'car (plist-get n :keys)) (plist-get n :source)) '(("C-c 9") "package")))
      (should (equal (list (plist-get d :keys) (plist-get d :source)) '(nil ""))))
    ;; one line per command: title, category, keys, source, where
    (should (string-match-p "Test: Open Alpha +C-c a +Alpha +global" (drgnx-shortcuts-test--line 'sc-a)))
    (should (string-match-p "Other: Beta View Thing +C-c b +Alpha +shortcuts-test" (drgnx-shortcuts-test--line 'sc-b)))
    (should (string-match-p "Test: Gamma +C-c q +keys\\.eld +global" (drgnx-shortcuts-test--line 'sc-c)))
    (should (string-match-p "Native One +C-c 9 +package" (drgnx-shortcuts-test--line 'sc-n)))
    (should (equal (length (drgnx-shortcuts-test--shown)) (length drgnx-shortcuts-test--commands)))))

(ert-deftest drgnx-shortcuts/where-names-the-modal-maps ()
  ;; The Vim profile's keys: the leader map reads where it works (not the keymap's name), the others as the modal
  ;; core names them; any other keymap as before.
  (should (equal (drgnx-shortcuts--where 'drgnx-modal-leader-map) "normal, visual, motion state and panels"))
  (should (equal (drgnx-shortcuts--where 'drgnx-modal-panel-map) "panels"))
  (should (equal (drgnx-shortcuts--where '(evil . evil-motion-state-map)) "motion state"))
  (should (equal (drgnx-shortcuts--where 'evil-normal-state-map) "normal state"))
  (should (equal (drgnx-shortcuts--where nil) "global"))
  (should (equal (drgnx-shortcuts--where 'drgnx-explorer-mode-map) "explorer")))

(ert-deftest drgnx-shortcuts/filters ()
  (drgnx-shortcuts-test--with
    (drgnx-keys-edit-bind 'sc-f "C-c a")                   ; Zeta takes Alpha's key: a conflict, changed by me
    (drgnx-shortcuts)
    (set-buffer "*drgnx keyboard shortcuts*")
    ;; typing filters by title or category, any case
    (drgnx-shortcuts-filter "alpha")
    (should (equal (drgnx-shortcuts-test--shown) '(sc-a)))
    (drgnx-shortcuts-filter "other")
    (should (equal (drgnx-shortcuts-test--shown) '(sc-b sc-f)))
    (drgnx-shortcuts-filter "")
    (should (= (length (drgnx-shortcuts-test--shown)) (length drgnx-shortcuts-test--commands)))
    ;; record keys: the rows with that key, or keys starting with it
    (let ((unread-command-events (list ?\C-c ?c))) (drgnx-shortcuts-record-filter))
    (should (equal (drgnx-shortcuts-test--shown) '(sc-c)))
    (drgnx-shortcuts-record-filter)                        ; off again
    (should (= (length (drgnx-shortcuts-test--shown)) (length drgnx-shortcuts-test--commands)))
    (let ((unread-command-events (list ?\C-c))) (drgnx-shortcuts-record-filter))
    (should (equal (drgnx-shortcuts-test--shown) '(sc-b sc-c sc-e sc-f)))   ; in any place (C-c b is in a view's map)
    (should (string-search "C-c" (buffer-string)))
    (drgnx-shortcuts-record-filter)
    ;; Conflicts, No key, Changed by me
    (drgnx-shortcuts-toggle-conflicts)
    (should (equal (drgnx-shortcuts-test--shown) '(sc-a sc-f)))
    (drgnx-shortcuts-toggle-conflicts)
    (drgnx-shortcuts-toggle-no-key)
    (should (equal (drgnx-shortcuts-test--shown) '(sc-a sc-d sc-g sc-n)))
    (drgnx-shortcuts-filter "delta")                       ; filters combine
    (should (equal (drgnx-shortcuts-test--shown) '(sc-d)))
    (drgnx-shortcuts-filter "")
    (drgnx-shortcuts-toggle-no-key)
    (drgnx-shortcuts-toggle-changed)
    (should (equal (drgnx-shortcuts-test--shown) '(sc-f)))))

(ert-deftest drgnx-shortcuts/record-a-chord ()
  (should (= (eval (car (get 'drgnx-shortcuts-chord-wait 'standard-value))) 1.0))
  (drgnx-shortcuts-test--with
    (drgnx-shortcuts)
    ;; RET on a row without a key: the first key, then a second one within the wait, is one chord
    (drgnx-shortcuts-test--goto 'sc-d)
    (let ((unread-command-events (list ?\C-c ?\C-d))) (drgnx-shortcuts-change))
    (should (equal (drgnx-shortcuts-test--user) '(((sc-d "C-c C-d")) nil)))
    (should (eq (keymap-lookup global-map "C-c C-d") #'drgnx-shortcuts-test-sc-d))
    (should (string-match-p "Delta +C-c C-d +keys\\.eld +global" (drgnx-shortcuts-test--line 'sc-d)))
    ;; nothing after the first key within the wait: that key alone
    (drgnx-shortcuts-test--goto 'sc-g)
    (let ((unread-command-events (list 'f9))) (drgnx-shortcuts-change))
    (should (equal (drgnx-shortcuts-test--keys 'sc-g) '("<f9>")))
    ;; RET on a row with a key changes that key (one write); Add keeps it
    (drgnx-shortcuts-test--goto 'sc-a)
    (let ((unread-command-events (list ?\C-c ?y))) (drgnx-shortcuts-change))
    (should (equal (drgnx-shortcuts-test--keys 'sc-a) '("C-c y")))
    (drgnx-shortcuts-test--goto 'sc-a)
    (let ((unread-command-events (list ?\C-c ?x))) (drgnx-shortcuts-add))
    (should (equal (drgnx-shortcuts-test--keys 'sc-a) '("C-c y" "C-c x")))
    (should (eq (keymap-lookup global-map "C-c x") #'drgnx-shortcuts-test-sc-a))
    ;; a key in a view's keymap stays in that keymap
    (drgnx-shortcuts-test--goto 'sc-b)
    (let ((unread-command-events (list ?\C-c ?v))) (drgnx-shortcuts-change))
    (should (equal (plist-get (drgnx-shortcuts-test--row 'sc-b) :keys) '(("C-c v" . drgnx-shortcuts-test-mode-map))))
    (should (eq (keymap-lookup drgnx-shortcuts-test-mode-map "C-c v") #'drgnx-shortcuts-test-sc-b))
    ;; point stays on the row it was on
    (should (eq (get-text-property (point) 'drgnx-shortcuts-id) 'sc-b))))

(ert-deftest drgnx-shortcuts/record-cancels-and-prefixes ()
  (drgnx-shortcuts-test--with
    (drgnx-shortcuts)
    (drgnx-shortcuts-test--goto 'sc-d)
    ;; C-g or ESC, first or second, cancels and never binds
    (dolist (events (list (list ?\C-g) (list ?\C-c ?\C-g) (list 'escape) (list ?\C-c 'escape)))
      (let ((unread-command-events events))
        (drgnx-shortcuts-test--answering ?k
          (drgnx-shortcuts-change)
          (should-not asked))))
    (should-not (file-exists-p (drgnx-config-file 'settings)))
    (should-not (drgnx-shortcuts-test--keys 'sc-d))
    ;; a key that is a prefix of another command's key in the same place is flagged: cancel leaves all as it was
    (drgnx-shortcuts-test--answering ?c
      (let ((unread-command-events (list ?\C-c ?e))) (drgnx-shortcuts-change))
      (should (string-search "C-c e C-x" (car asked)))
      (should (string-search "Epsilon" (car asked)))
      (should (string-search "prefix" (car asked))))
    (should-not (file-exists-p (drgnx-config-file 'settings)))
    ;; Keep both: bound, and the prefix conflict is listed on both rows
    (drgnx-shortcuts-test--answering ?k
      (let ((unread-command-events (list ?\C-c ?e))) (drgnx-shortcuts-change)))
    (should (equal (drgnx-shortcuts-test--user) '(((sc-d "C-c e")) nil)))
    (should (seq-find (lambda (c) (eq (plist-get c :kind) 'prefix)) (plist-get drgnx-keys-last :conflicts)))
    (should (plist-get (drgnx-shortcuts-test--row 'sc-d) :conflicts))
    (should (plist-get (drgnx-shortcuts-test--row 'sc-e) :conflicts))
    (should (string-prefix-p "!" (drgnx-shortcuts-test--line 'sc-e)))
    ;; a prefix of Emacs' own keys (M-g) is flagged too
    (drgnx-shortcuts-test--goto 'sc-g)
    (drgnx-shortcuts-test--answering ?c
      (let ((unread-command-events (list ?\M-g))) (drgnx-shortcuts-change))
      (should (string-search "prefix" (car asked))))
    ;; C-x, C-c and C-h alone in the global keymap are refused, nothing asked
    (dolist (k (list ?\C-x ?\C-c ?\C-h))
      (drgnx-shortcuts-test--answering ?k
        (let ((unread-command-events (list k)))
          (should-error (drgnx-shortcuts-change) :type 'user-error))
        (should-not asked)))
    (should-not (drgnx-shortcuts-test--keys 'sc-g))
    ;; a plain letter, also a capital one, RET or TAB would stop typing everywhere
    (dolist (k (list ?a ?A ?\r ?\t))
      (let ((unread-command-events (list k)))
        (should-error (drgnx-shortcuts-change) :type 'user-error)))
    (should-not (drgnx-shortcuts-test--keys 'sc-g))))

(ert-deftest drgnx-shortcuts/conflict-replace-or-keep ()
  (drgnx-shortcuts-test--with
    (drgnx-shortcuts)
    ;; taken in the same place: Replace takes it from the other command
    (drgnx-shortcuts-test--goto 'sc-d)
    (drgnx-shortcuts-test--answering ?r
      (let ((unread-command-events (list ?\C-c ?a))) (drgnx-shortcuts-change))
      (should (string-search "Open Alpha" (car asked)))
      (should (string-search "global" (car asked))))
    (should (equal (drgnx-shortcuts-test--keys 'sc-d) '("C-c a")))
    (should-not (drgnx-shortcuts-test--keys 'sc-a))
    (should (eq (keymap-lookup global-map "C-c a") #'drgnx-shortcuts-test-sc-d))
    (should-not (seq-filter (lambda (r) (plist-get r :conflicts)) (drgnx-shortcuts--rows)))
    ;; one Undo takes the whole Replace back: Alpha has its key again
    (drgnx-shortcuts-undo)
    (should (equal (drgnx-shortcuts-test--keys 'sc-a) '("C-c a")))
    (should-not (drgnx-shortcuts-test--keys 'sc-d))
    (should-not (drgnx-settings-area-has-entry-p 'drgnx-keys-bind))
    (drgnx-shortcuts-test--goto 'sc-d)
    (drgnx-shortcuts-test--answering ?r
      (let ((unread-command-events (list ?\C-c ?a))) (drgnx-shortcuts-change)))
    (should (equal (drgnx-shortcuts-test--keys 'sc-d) '("C-c a")))
    ;; the same key in another place (a view's keymap) is no conflict: nothing asked
    (drgnx-shortcuts-test--goto 'sc-g)
    (drgnx-shortcuts-test--answering ?c
      (let ((unread-command-events (list ?\C-c ?b))) (drgnx-shortcuts-change))
      (should-not asked))
    (should (equal (drgnx-shortcuts-test--keys 'sc-g) '("C-c b")))
    ;; Keep both: both keep it, the conflict is listed
    (drgnx-shortcuts-test--goto 'sc-f)
    (drgnx-shortcuts-test--answering ?k
      (let ((unread-command-events (list ?\C-c ?c))) (drgnx-shortcuts-change))
      (should (string-search "Gamma" (car asked))))
    (should (assq 'sc-f (car (drgnx-shortcuts-test--user))))
    (should-not (memq 'sc-c (cadr (drgnx-shortcuts-test--user))))
    (should (seq-find (lambda (c) (and (eq (plist-get c :kind) 'same-key) (equal (plist-get c :key) "C-c c")))
                      (plist-get drgnx-keys-last :conflicts)))
    (should (plist-get (drgnx-shortcuts-test--row 'sc-c) :conflicts))))

(ert-deftest drgnx-shortcuts/emacs-defaults-are-no-conflict ()
  (drgnx-shortcuts-test--with
    (drgnx-shortcuts)
    ;; a profile key over an Emacs default no layer claims: no conflict, said in the Where column's help
    (let ((k (drgnx-shortcuts-test--row 'sc-k)))
      (should-not (plist-get k :conflicts))
      (should (equal (plist-get k :over) '("kill-line (C-k)"))))
    (should-not (string-prefix-p "!" (drgnx-shortcuts-test--line 'sc-k)))
    (drgnx-shortcuts-test--goto 'sc-k)
    (should (string-search "Emacs' kill-line" (get-text-property (1- (pos-eol)) 'help-echo)))
    ;; a keys.eld chord under that prefix (the profile already made C-k one): nothing more is taken, no conflict
    (drgnx-keys-edit-bind 'sc-d "C-k C-d")
    (drgnx-shortcuts)
    (should-not (plist-get (drgnx-shortcuts-test--row 'sc-d) :conflicts))
    (should (equal (plist-get (drgnx-shortcuts-test--row 'sc-d) :over) '("kill-line (C-k)")))
    (should-not (string-prefix-p "!" (drgnx-shortcuts-test--line 'sc-d)))
    ;; a keys.eld chord under an Emacs default the profile left alone (C-a): a conflict
    (drgnx-keys-edit-bind 'sc-g "C-a C-9")
    (drgnx-shortcuts)
    (should (plist-get (drgnx-shortcuts-test--row 'sc-g) :conflicts))
    (should (string-prefix-p "!" (drgnx-shortcuts-test--line 'sc-g)))
    ;; a key an active layer claims: a conflict, also when the profile's key wins
    (drgnx-keys-use '((beta editing) (alpha app editing window)))
    (should (seq-find (lambda (c) (eq (plist-get c :kind) 'claim)) (plist-get drgnx-keys-last :conflicts)))
    (should (plist-get (drgnx-shortcuts-test--row 'sc-a) :conflicts))
    (should-not (plist-get (drgnx-shortcuts-test--row 'sc-k) :conflicts))))

(ert-deftest drgnx-shortcuts/filter-as-you-type ()
  (drgnx-shortcuts-test--with
    (drgnx-shortcuts)
    (set-buffer "*drgnx keyboard shortcuts*")
    ;; each change in the minibuffer redraws the list
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _)
                 (with-temp-buffer
                   (run-hooks 'minibuffer-setup-hook)
                   (insert "alp")
                   (should (equal (drgnx-shortcuts-test--shown) '(sc-a)))
                   (insert "ha-not")
                   (should-not (drgnx-shortcuts-test--shown))
                   (buffer-string)))))
      (call-interactively #'drgnx-shortcuts-filter))
    (should-not (drgnx-shortcuts-test--shown))
    ;; C-g puts back the filter it had
    (drgnx-shortcuts-filter "gamma")
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _)
                 (with-temp-buffer (run-hooks 'minibuffer-setup-hook) (insert "x") (signal 'quit nil)))))
      (should (eq (condition-case nil (call-interactively #'drgnx-shortcuts-filter) (quit 'quit)) 'quit)))
    (should (equal (drgnx-shortcuts-test--shown) '(sc-c)))))

(defmacro drgnx-shortcuts-test--on-terminal (caps &rest body)
  "BODY with the selected frame a terminal frame with CAPS (nil: a graphical frame); the active profile's fallback
table is the terminal's, as the layer would have put it there for a legacy terminal."
  (declare (indent 1))
  `(let ((params (make-hash-table :test #'equal)) (caps ,caps))
     (cl-flet ((rebuild (&rest _)               ; what the layer does at every key apply
                 (when (and caps (eq (plist-get caps :keys) 'legacy))
                   (puthash '(kx-sc . drgnx-tty-fallback-table)
                            (drgnx-tty-fallback-for-terminal (drgnx-tty-fallback-active-table) caps) params))))
       (when caps (puthash '(kx-sc . drgnx-tty-caps) caps params))
       (rebuild)
       ;; the layer's advice on `drgnx-keys-apply', here as the test's own (the real one is there only after ui/terminal's
       ;; setup ran in the session)
       (advice-add 'drgnx-keys-apply :after #'rebuild '((name . kx-sc-rebuild)))
       (unwind-protect
           (cl-letf (((symbol-function 'drgnx-tty-fallback-apply) #'rebuild)
                     ((symbol-function 'frame-terminal) (lambda (&optional _) 'kx-sc))
                     ((symbol-function 'display-graphic-p) (lambda (&optional _) (null caps)))
                     ((symbol-function 'terminal-parameter) (lambda (term p) (gethash (cons term p) params)))
                     ((symbol-function 'set-terminal-parameter) (lambda (term p v) (puthash (cons term p) v params))))
             ,@body)
         (advice-remove 'drgnx-keys-apply 'kx-sc-rebuild)))))

(defun drgnx-shortcuts-test--mark-echo (id)
  "The help-echo of the † on command ID's line, or nil without one."
  (with-current-buffer "*drgnx keyboard shortcuts*"
    (save-excursion
      (goto-char (point-min))
      (when-let* ((m (text-property-search-forward 'drgnx-shortcuts-id id #'eq))
                  (pos (progn (goto-char (prop-match-beginning m)) (search-forward "†" (prop-match-end m) t))))
        (get-text-property (1- pos) 'help-echo)))))

(ert-deftest drgnx-shortcuts/terminal-mark ()
  ;; a graphical frame (and batch's, which has no terminal caps): the static rule, a terminal without kkp
  (dolist (k '("C-S-p" "s-k" "C-/" "C-." "C-1" "C-x C-S-a" "H-a"))
    (should (equal (list k nil) (list k (drgnx-shortcuts-terminal-p k)))))
  (dolist (k '("C-c a" "C-k C-s" "M-x" "C-_" "C-@" "<f5>" "C-]" "RET" "S-<f4>"))
    (should (equal (list k t) (list k (drgnx-shortcuts-terminal-p k)))))
  (drgnx-shortcuts-test--with
    (drgnx-shortcuts)
    (should (string-match-p "C-S-t†" (drgnx-shortcuts-test--line 'sc-t)))
    (should-not (string-search "†" (drgnx-shortcuts-test--line 'sc-a)))
    (with-current-buffer "*drgnx keyboard shortcuts*"
      (should (string-search "a terminal cannot send" (buffer-string))))
    ;; a graphical frame says the same, and names no terminal key
    (drgnx-shortcuts-test--on-terminal nil
      (should-not (drgnx-shortcuts-terminal-p "C-S-t"))
      (drgnx-shortcuts--redraw)
      (should (string-match-p "C-S-t†" (drgnx-shortcuts-test--line 'sc-t)))
      (should (equal (drgnx-shortcuts-test--mark-echo 'sc-t) "A terminal cannot send this key (a graphical frame can)")))
    ;; a terminal frame whose terminal sends it (kkp): not marked
    (drgnx-shortcuts-test--on-terminal '(:id kitty :keys kkp :folded nil)
      (should (drgnx-shortcuts-terminal-p "C-S-t"))
      (should (drgnx-shortcuts-terminal-p "s-k"))      ; kkp sends it all but the keys the keyboard lacks
      (drgnx-shortcuts--redraw)
      (should-not (string-search "†" (drgnx-shortcuts-test--line 'sc-t))))
    ;; a legacy terminal: marked, and the mark names what to press here
    (drgnx-shortcuts-test--on-terminal '(:id vte :keys legacy :folded nil)
      (should-not (drgnx-shortcuts-terminal-p "C-S-t"))
      (should (drgnx-shortcuts-terminal-p "C-c a"))
      (drgnx-shortcuts--redraw)
      (should (string-match-p "C-S-t†" (drgnx-shortcuts-test--line 'sc-t)))
      (should-not (string-search "†" (drgnx-shortcuts-test--line 'sc-a)))
      (should (string-search "here: Alt+Shift+T" (drgnx-shortcuts-test--mark-echo 'sc-t)))
      ;; where Alt+Shift+T is taken, the F6 form
      (with-temp-buffer
        (use-local-map (let ((m (make-sparse-keymap))) (define-key m (key-parse "M-T") #'ignore) m))
        (should (string-search "here: F6 t" (drgnx-shortcuts--terminal-note "C-S-t"))))
      ;; without the layer the mark says there is nothing to press
      (let ((drgnx-tty-fallback nil))
        (should (string-search "no fallback" (drgnx-shortcuts--terminal-note "C-S-t")))))))

(ert-deftest drgnx-shortcuts/sets-the-terminal-fallback-of-a-marked-row ()
  (drgnx-shortcuts-test--with
    (drgnx-shortcuts)
    (drgnx-shortcuts-test--on-terminal '(:id vte :keys legacy :folded nil)
      (with-current-buffer "*drgnx keyboard shortcuts*"
        (goto-char (point-min))
        (goto-char (prop-match-beginning (text-property-search-forward 'drgnx-shortcuts-id 'sc-t #'eq)))
        (cl-letf (((symbol-function 'read-string) (lambda (prompt &rest _) (should (string-search "C-S-t" prompt)) "M-Z")))
          (drgnx-shortcuts-set-tty-fallback))
        (should (equal (plist-get (drgnx-keys-read-user) :tty-fallback) '(("C-S-t" . "M-Z"))))
        ;; the row now shows the key chosen (the layer rebuilt the terminal's table, as it does at every key apply)
        (should (string-search "here: Alt+Shift+Z" (drgnx-shortcuts-test--mark-echo 'sc-t)))
        ;; a key the layer cannot use is refused with its reason
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "M-x")))
          (should (string-search "reserved" (cadr (should-error (drgnx-shortcuts-set-tty-fallback) :type 'user-error)))))
        ;; a row whose keys a terminal can send has nothing to set
        (goto-char (point-min))
        (goto-char (prop-match-beginning (text-property-search-forward 'drgnx-shortcuts-id 'sc-a #'eq)))
        (should (string-search "nothing" (cadr (should-error (drgnx-shortcuts-set-tty-fallback) :type 'user-error))))))))

(ert-deftest drgnx-shortcuts/profile-switch ()
  (drgnx-shortcuts-test--with
    (drgnx-shortcuts)
    ;; an empty answer changes nothing
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should-error (drgnx-shortcuts-switch-profile) :type 'user-error))
    (should-not (file-exists-p (drgnx-config-file 'settings)))
    (with-current-buffer "*drgnx keyboard shortcuts*"
      (goto-char (point-min))
      (should (looking-at-p ".*Alpha"))
      ;; the header's button switches the stack now and keeps it in keys.eld
      (let ((b (next-button (point-min))))
        (should (string-search "Switch" (button-label b)))
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Beta")))
          (button-activate b)))
      (goto-char (point-min))
      (should (looking-at-p ".*Beta")))
    (should (equal (plist-get (drgnx-keys-read-user) :layers) '((beta app editing window))))
    (should (equal (drgnx-shortcuts-test--keys 'sc-a) '("C-c z")))
    (should (string-match-p "Open Alpha +C-c z +Beta" (drgnx-shortcuts-test--line 'sc-a)))
    (should (eq (keymap-lookup global-map "C-c z") #'drgnx-shortcuts-test-sc-a))
    (should-not (eq (keymap-lookup global-map "C-c a") #'drgnx-shortcuts-test-sc-a))))

(ert-deftest drgnx-shortcuts/every-command-has-keys-in-every-profile ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (drgnx-shortcuts--define-commands)
    (should (memq 'keyboard-shortcuts (mapcar #'drgnx-cmd-id (drgnx-commands-all))))
    (pcase-dolist (`(,profile . ,spec) profiles)
      (dolist (c (drgnx-commands-all))
        (should (equal (list profile (drgnx-cmd-id c) t)
                       (list profile (drgnx-cmd-id c) (and (assq (drgnx-cmd-id c) (plist-get spec :bind)) t))))))
    (should (equal (cdr (assq 'keyboard-shortcuts (plist-get (alist-get 'vscode profiles) :bind))) '("C-k C-s")))))

(ert-deftest drgnx-shortcuts/suggestion-from-usage ()
  (drgnx-shortcuts-test--with
    (keymap-set global-map "C-c 9" #'drgnx-shortcuts-test-sc-n)
    (let ((today (time-to-days nil)))
      (make-directory (file-name-directory (drgnx-shortcuts-usage-file)) t)
      (with-temp-file (drgnx-shortcuts-usage-file)
        (prin1 `((sc-a 60 (,today . 40))                       ; has a key
                 (sc-g 30 (,(- today 2) . 5) (,today . 5))     ; 10 this week, no key
                 (sc-d 99 (,(- today 10) . 90) (,today . 9))   ; 9 this week
                 (sc-n 15 (,today . 15)))                      ; a package's key
               (current-buffer))))
    (drgnx-shortcuts)
    (with-current-buffer "*drgnx keyboard shortcuts*"
      (should (string-match-p "You ran Test: Eta 10 times from the palette this week; give it a key\\?" (buffer-string)))
      (should-not (string-search "Delta 9" (buffer-string)))
      ;; its button records a key for it
      (goto-char (point-min))
      (let ((b (text-property-search-forward 'drgnx-shortcuts-suggest 'sc-g #'eq)))
        (should b)
        (let ((unread-command-events (list ?\C-c ?h))) (button-activate (button-at (prop-match-beginning b)))))
      (should (equal (drgnx-shortcuts-test--keys 'sc-g) '("C-c h")))
      (should-not (string-search "You ran" (buffer-string))))))

(ert-deftest drgnx-shortcuts/undo-reset-all ()
  (drgnx-shortcuts-test--with
    (drgnx-shortcuts)
    (drgnx-shortcuts-test--goto 'sc-d)
    (let ((unread-command-events (list ?\C-c ?\C-d))) (drgnx-shortcuts-change))
    (should (drgnx-shortcuts-test--keys 'sc-d))
    ;; u: back as it was (there was no entry for the bound keys)
    (drgnx-shortcuts-undo)
    (should-not (drgnx-shortcuts-test--keys 'sc-d))
    (should-not (drgnx-settings-area-has-entry-p 'drgnx-keys-bind))
    (should-not (keymap-lookup global-map "C-c C-d"))
    (should-error (drgnx-shortcuts-undo) :type 'user-error)
    ;; r: one command back to its profile key
    (drgnx-shortcuts-test--goto 'sc-a)
    (let ((unread-command-events (list ?\C-c ?y))) (drgnx-shortcuts-change))
    (drgnx-shortcuts-test--goto 'sc-g)
    (let ((unread-command-events (list ?\C-c ?\C-g ?\C-c ?w))) (drgnx-shortcuts-change) (drgnx-shortcuts-change))
    (should (equal (mapcar #'car (car (drgnx-shortcuts-test--user))) '(sc-a sc-g)))
    (drgnx-shortcuts-test--goto 'sc-a)
    (drgnx-shortcuts-reset)
    (should (equal (drgnx-shortcuts-test--keys 'sc-a) '("C-c a")))
    (should (equal (mapcar #'car (car (drgnx-shortcuts-test--user))) '(sc-g)))
    ;; Reset all asks first; no leaves everything
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))) (drgnx-shortcuts-reset-all))
    (should (equal (drgnx-shortcuts-test--keys 'sc-g) '("C-c w")))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))) (drgnx-shortcuts-reset-all))
    (should (equal (drgnx-shortcuts-test--user) '(nil nil)))
    (should-not (drgnx-shortcuts-test--keys 'sc-g))
    (should-not (keymap-lookup global-map "C-c w"))
    ;; and undo brings them back
    (drgnx-shortcuts-undo)
    (should (equal (drgnx-shortcuts-test--keys 'sc-g) '("C-c w")))
    (should (string-match-p "Eta +C-c w +keys\\.eld" (drgnx-shortcuts-test--line 'sc-g)))))

(ert-deftest drgnx-shortcuts/the-vim-profile-state-and-the-view-go-with-the-module ()
  ;; evil had loaded (the Vim profile): the initial state is set at once and put back by the module's undo; the
  ;; open view is killed by its :teardown.
  (let ((states (list (cons 'drgnx-shortcuts-mode 'normal))))
    (unwind-protect
        (cl-letf (((symbol-function 'evil-initial-state) (lambda (m &rest _) (alist-get m states)))
                  ((symbol-function 'evil-set-initial-state) (lambda (m s) (setf (alist-get m states) s))))
          (provide 'evil)
          (drgnx-test-with-modules '(tools/shortcuts) :strict t
                                   (should (eq (alist-get 'drgnx-shortcuts-mode states) 'emacs))
                                   (get-buffer-create drgnx-shortcuts--buffer))
          (should (eq (alist-get 'drgnx-shortcuts-mode states) 'normal))
          (should-not (get-buffer drgnx-shortcuts--buffer)))
      (setq features (delq 'evil features)))))


;;; mod-shortcuts-test.el ends here
