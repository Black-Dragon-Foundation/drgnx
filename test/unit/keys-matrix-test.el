;;; keys-matrix-test.el --- batch tests: the key rules as a property over a seeded matrix of cases -*- lexical-binding: t -*-
;; test-class: det
;; The rules of docs/guide/keys.md ("Your own bindings always win", the profile over packages' global keys, packages'
;; mode maps over global keys) checked over ~600 cases drawn from a fixed seed.  Each case: a profile key in one place
;; (global, a chord under the profile's prefix, `:everywhere', a package's mode map, under C-x), an action of yours
;; done one way (config.el, its `with-eval-after-load', a keyboard command, M-:, emacsclient --eval, or a hook — which is not yours),
;; a package that loads and writes, and applies (some while another global map is current, as in `read-key'), a config
;; reload and a profile switch in a random order.  Actions include a `[remap]' of the profile's command.  After it,
;; `key-binding' in a plain buffer, in the package's mode, in a mode derived from it, under a local map whose parent is
;; the mode's and under an unrelated local map (wgrep's `use-local-map') must equal what `keys-matrix--expect' says; the sheet has at most one line
;; for the key; more applies change nothing.  The model is written from the rules alone and shares no code with
;; drgnx-keys.  A failing case prints its seed and its plan.  Between cases everything is reset, and the reset is
;; checked against the state at the start.  Three child Emacsen run more cases, one per load order (the package
;; first; right after your action) and one with subr trampolines off; `kmacro-bind-to-key' has a row of its own.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'kmacro)
(require 'drgnx)
(load (expand-file-name "test/fixtures/areas-fixture" drgnx-dir) nil t)

(defconst keys-matrix--pkg-file (expand-file-name "test/fixtures/keys-matrix/keys-matrix-pkg.el" drgnx-dir))

(defvar keys-matrix-pkg-global)
(defvar keys-matrix-pkg-mode-keys)
(defvar keys-matrix-pkg-mode-map)
(declare-function keys-matrix-pkg-mode "keys-matrix-pkg")
(declare-function keys-matrix-pkg-child-mode "keys-matrix-pkg")
(declare-function drgnx-settings-test-child "settings-child" (forms &key files env))

;;;; The profile and the commands

(defun keys-matrix-cmd-a () (interactive))
(defun keys-matrix-cmd-b () (interactive))
(defun keys-matrix-cmd-c () (interactive))
(defun keys-matrix-cmd-d () (interactive))
(defun keys-matrix-cmd-e () (interactive))
(defun keys-matrix-yours () "Your own command." (interactive))
(defun keys-matrix-hook-cmd () "A command a hook function binds (not yours)." (interactive))

(defconst keys-matrix--slots
  ;; SLOT  KEY  PROFILE-COMMAND  PLACE
  '((global "C-o" keys-matrix-cmd-a global)
    (chord "C-k C-r" keys-matrix-cmd-b global)
    (everywhere "C-j" keys-matrix-cmd-c everywhere)
    (foreign "C-c C-p" keys-matrix-cmd-d foreign)
    (ctlx "C-x g" keys-matrix-cmd-e global))
  "Where the profile `mx' has a key: global, a chord under its own C-k prefix (over Emacs's kill-line), an
`:everywhere' key, a key in the package's mode map (a profile `:map'), and a key under Emacs's C-x prefix.")

(defconst keys-matrix--profiles
  `((mx :name "Matrix" :bind ((mx-a "C-o") (mx-b "C-k C-r") (mx-c "M-J" :everywhere "C-j")
                              (mx-d "C-c C-p" :map (keys-matrix-pkg . keys-matrix-pkg-mode-map))
                              (mx-e "C-x g")))
    (mx-empty :name "Empty" :bind ()))
  "A profile with one key in each slot, and one with none (the switch away and back).")

(defconst keys-matrix--stack '((mx app editing window)))

(defun keys-matrix--register ()
  (dolist (c '((mx-a . keys-matrix-cmd-a) (mx-b . keys-matrix-cmd-b) (mx-c . keys-matrix-cmd-c)
               (mx-d . keys-matrix-cmd-d) (mx-e . keys-matrix-cmd-e)))
    (drgnx-command-define (car c) :title (symbol-name (car c)) :category "Matrix" :command (cdr c) :doc "test")))

;;;; The model: the rules, from docs/guide/keys.md and the redesign's R-table, alone

(defun keys-matrix--expect (key buffer state)
  "The command KEY runs in BUFFER (`plain' or `pkg', the package's mode), from STATE: a plist of
:yours ((MAP . KEY) . DEF) — your bindings, MAP `global' or `pkg' (DEF nil: you unbound it);
:pkg-global (KEY . DEF) — writes into the global map that are not yours (packages, hooks), the last one standing;
:pkg-mode — keys the package's mode map binds itself;
:profile (KEY COMMAND PLACE) — the profile's keys, PLACE `global', `everywhere' or `foreign';
:default — Emacs's own command for KEY.
BUFFER may also be `pkg-child' (a mode derived from the package's), `pkg-sub' (the mode, with a local map whose parent
is the mode's map) or `pkg-wgrep' (the mode, with an unrelated local map, as wgrep does: nothing of the mode's).
A `[remap C]' of yours, else one in the global map, turns the command C found into its own.
The order: yours; then an `:everywhere' key; then the maps of the buffer's mode (the profile's `:map' key in it, then
the package's own); then the global map: the profile's key, a package's, Emacs's.  A key under a command of yours on
its prefix runs nothing; a prefix of a profile key reads `prefix'."
  (when (eq buffer 'pkg-wgrep) (setq buffer 'plain))        ; the mode on, its map replaced: nothing of the mode's
  (when (memq buffer '(pkg-child pkg-sub)) (setq buffer 'pkg)) ; a derived mode's map, or a local map under the mode's
  (let* ((yours (plist-get state :yours))
         (prefix-cmd (seq-find (lambda (y) (and (eq (caar y) 'global) (cdr y) (not (equal (cdar y) key))
                                                (string-prefix-p (concat (cdar y) " ") key)))
                               yours))
         (y-global (assoc (cons 'global key) yours))
         (y-pkg (and (eq buffer 'pkg) (assoc (cons 'pkg key) yours)))
         (prof (assoc key (plist-get state :profile)))
         (place (nth 2 prof)))
    (keys-matrix--remapped
     state
     (cond
      ;; yours in the buffer's mode map: a command, or nil (you unbound it there: nothing runs)
      (y-pkg (cdr y-pkg))
      ;; an :everywhere key, in every buffer, unless you bound the key yourself or a command of yours sits on its
      ;; prefix (then it steps aside: the mode maps, then your global binding, decide)
      ((and (eq place 'everywhere) (not y-global) (not prefix-cmd)) (nth 1 prof))
      ;; the buffer's mode: the profile's :map key, unless you took it back; then the package's own, and a prefix
      ;; of the package's own key (a mode map is above the global map, yours included, as in any Emacs)
      ((and (eq buffer 'pkg) (eq place 'foreign) (not y-pkg)) (nth 1 prof))
      ((and (eq buffer 'pkg) (member key (plist-get state :pkg-mode))) 'keys-matrix-pkg-own)
      ((and (eq buffer 'pkg) (seq-find (lambda (k) (string-prefix-p (concat key " ") k)) (plist-get state :pkg-mode)))
       'prefix)
      ;; the global map: a command of yours on the key's prefix leaves the key unreachable there
      (prefix-cmd nil)
      (y-global (cdr y-global))
      ((eq place 'global) (nth 1 prof))
      ;; a prefix of a profile key is the profile's prefix: a package's or hook's command there is below it
      ((seq-find (lambda (p) (and (memq (nth 2 p) '(global everywhere)) (string-prefix-p (concat key " ") (car p))))
                 (plist-get state :profile))
       'prefix)
      ((assoc key (plist-get state :pkg-global)) (cdr (assoc key (plist-get state :pkg-global))))
      (t (cdr (assoc key (plist-get state :default))))))))

(defun keys-matrix--remapped (state command)
  "COMMAND after the `[remap COMMAND]' in STATE: yours first, then one in the global map that is not yours."
  (let ((rk (and command (symbolp command) (not (eq command 'prefix)) (format "<remap> <%s>" command))))
    (cond ((null rk) command)
          ((assoc (cons 'global rk) (plist-get state :yours)) (cdr (assoc (cons 'global rk) (plist-get state :yours))))
          ((assoc rk (plist-get state :pkg-global)) (cdr (assoc rk (plist-get state :pkg-global))))
          (t command))))

;;;; Cases

(defvar keys-matrix--seed 0)

(defun keys-matrix--rand (n)
  "A number below N from the seeded sequence (a 31-bit LCG; the same seed, the same cases)."
  (setq keys-matrix--seed (mod (+ (* keys-matrix--seed 1103515245) 12345) 2147483648))
  (mod (/ keys-matrix--seed 65536) n))

(defun keys-matrix--pick (list) (nth (keys-matrix--rand (length list)) list))

(defconst keys-matrix--actions '(none bind-other bind-same unbind-nil unset-remove prefix-under command-on-prefix remap))
(defconst keys-matrix--hows '(config after-load interactive eval server hook))
(defconst keys-matrix--pkgs '(none define-key current-global-map global-set-key mode-map))

(defun keys-matrix--case (slot action how pkg)
  "A case: SLOT, ACTION, HOW, PKG, the STYLE of your global writes (0 `keymap-global-set', 1 `global-set-key',
2 `define-key' on `global-map') and a random order of its events.  A package never writes the chord: under C-k,
which `global-map' binds to `kill-line', its `define-key' fails in any Emacs."
  (when (and (eq slot 'chord) (memq pkg '(define-key current-global-map global-set-key))) (setq pkg 'none))
  (let* ((style (keys-matrix--rand 3))
         (applies (keys-matrix--rand 4))
         (events (append (list 'action) (and (or (not (eq pkg 'none)) (eq how 'after-load) (eq slot 'foreign)) '(pkg-load))
                         ;; an apply while another global map is current, as during `read-key'
                         (mapcar (lambda (_) (if (= 0 (keys-matrix--rand 4)) 'apply-swapped 'apply)) (make-list applies nil))
                         (and (= 0 (keys-matrix--rand 2)) '(switch))
                         (and (memq how '(config after-load)) (= 0 (keys-matrix--rand 2)) '(reload))))
         (order (vconcat events)))
    (cl-loop for i downfrom (1- (length order)) to 1   ; Fisher-Yates on the seeded sequence
             do (let ((j (keys-matrix--rand (1+ i)))) (cl-rotatef (aref order i) (aref order j))))
    (setq order (append order nil))
    ;; your write into the package's map needs the map: after its load (with-eval-after-load waits by itself)
    (when (and (eq slot 'foreign) (not (eq how 'after-load)) (memq 'pkg-load order))
      (setq order (cons 'pkg-load (remq 'pkg-load order))))
    (list :slot slot :action action :how how :pkg pkg :style style :order order)))

(defun keys-matrix--cases (n)
  (let (out)
    (dotimes (_ n)
      (push (keys-matrix--case (keys-matrix--pick (mapcar #'car keys-matrix--slots)) (keys-matrix--pick keys-matrix--actions)
                               (keys-matrix--pick keys-matrix--hows) (keys-matrix--pick keys-matrix--pkgs))
            out))
    (nreverse out)))

;;;; Running a case

(defvar keys-matrix--interactive-form nil "What the keyboard command `keys-matrix--do' evaluates.")
(defvar keys-matrix--action-error nil "An error your action signalled where the command loop or a filter would swallow it.")
(defun keys-matrix--do () "A command you run from the keyboard." (interactive)
       (condition-case err (eval keys-matrix--interactive-form t) (error (setq keys-matrix--action-error err))))
(defvar keys-matrix-trigger-map (let ((m (make-sparse-keymap))) (define-key m (kbd "<f35>") #'keys-matrix--do) m))
(define-minor-mode keys-matrix-trigger-mode "The test's trigger key." :global t :keymap keys-matrix-trigger-map)
(defvar keys-matrix-late-hook nil "A hook of yours that binds a key later, outside any of your scopes.")

(defun keys-matrix--forms (slot action &optional style)
  "The forms of your ACTION on SLOT's key, and the bindings they leave: (FORMS . WRITES), WRITES a list of
\((MAP . KEY) . DEF) or ((MAP . KEY) . :remove), in order."
  (let* ((s (assq slot keys-matrix--slots)) (key (nth 1 s)) (cmd (nth 2 s))
         (pkgmap (eq slot 'foreign))
         (map (if pkgmap 'pkg 'global))
         (set (lambda (k def)
                (cond (pkgmap `(keymap-set keys-matrix-pkg-mode-map ,k #',def))
                      ((eq slot 'ctlx) `(define-key ctl-x-map ,(substring k 4) ,(and def `#',def)))
                      (t (pcase (or style 0)
                           (0 `(keymap-global-set ,k ,(and def `#',def)))
                           (1 `(global-set-key (kbd ,k) ,(and def `#',def)))
                           (_ `(define-key global-map (kbd ,k) ,(and def `#',def))))))))
         (unset (lambda (k) (if pkgmap `(keymap-unset keys-matrix-pkg-mode-map ,k t)
                              (if (eq slot 'ctlx) `(define-key ctl-x-map ,(substring k 4) nil t)
                                `(keymap-global-unset ,k t)))))
         (chord (eq slot 'chord)))
    (pcase action
      ('none (cons nil nil))
      ('remap (let ((rk (format "<remap> <%s>" cmd)))
                (cons (list `(keymap-global-set ,rk #'keys-matrix-yours)) (list (cons (cons 'global rk) 'keys-matrix-yours)))))
      ('bind-other (cons (list (funcall set key 'keys-matrix-yours)) (list (cons (cons map key) 'keys-matrix-yours))))
      ('bind-same (cons (list (funcall set key cmd)) (list (cons (cons map key) cmd))))
      ('unbind-nil (cons (list (if pkgmap `(keymap-set keys-matrix-pkg-mode-map ,key nil) (funcall set key nil)))
                         (list (cons (cons map key) nil))))
      ('unset-remove (cons (list (funcall set key 'keys-matrix-yours) (funcall unset key))
                           (list (cons (cons map key) 'keys-matrix-yours) (cons (cons map key) :remove))))
      ('prefix-under (if chord (cons (list (funcall set "C-k x" 'keys-matrix-yours))
                                     (list (cons (cons 'global "C-k x") 'keys-matrix-yours)))
                       (keys-matrix--forms slot 'bind-other style)))
      ('command-on-prefix (if chord (cons (list (funcall set "C-k" 'keys-matrix-yours))
                                          (list (cons (cons 'global "C-k") 'keys-matrix-yours)))
                            (keys-matrix--forms slot 'bind-other style))))))

(defvar keys-matrix--dir nil "The case's temp folder (config.el is there).")

(defun keys-matrix--run-action (how forms)
  (setq keys-matrix--action-error nil)
  (pcase how
    ('config (let ((f (expand-file-name "config.el" keys-matrix--dir)))
               (with-temp-file f (insert ";;; -*- lexical-binding: t -*-\n") (dolist (x forms) (prin1 x (current-buffer)) (insert "\n")))
               (drgnx--load-user-config f)))
    ('after-load (let ((f (expand-file-name "config.el" keys-matrix--dir)))
                   (with-temp-file f (insert ";;; -*- lexical-binding: t -*-\n")
                                   (prin1 `(with-eval-after-load 'keys-matrix-pkg ,@forms) (current-buffer)))
                   (drgnx--load-user-config f)))
    ('interactive (setq keys-matrix--interactive-form (cons 'progn forms))
                  (execute-kbd-macro (kbd "<f35>")))
    ('eval (dolist (x forms)
             (execute-kbd-macro (vconcat (kbd "M-:")
                                         (string-to-vector
                                          (prin1-to-string `(condition-case err ,x (error (setq keys-matrix--action-error err)))))
                                         (kbd "RET")))))
    ;; emacsclient --eval: the server evaluates it in its process filter, between commands (no command, no file
    ;; being loaded); what a filter sees of that is `this-command' nil
    ('server (require 'server)
             (let ((this-command nil))
               (condition-case err
                   (dolist (x forms) (server-eval-and-print (prin1-to-string x) nil))
                 (error (setq keys-matrix--action-error err)))))
    ('hook (setq keys-matrix-late-hook (list (lambda () (dolist (x forms) (eval x t)))))
           (run-hooks 'keys-matrix-late-hook)))
  (when-let* ((err keys-matrix--action-error))
    (setq keys-matrix--action-error nil)
    (signal (car err) (cdr err))))

(defun keys-matrix--keys-of (c)
  "The keys case C checks."
  (let ((key (nth 1 (assq (plist-get c :slot) keys-matrix--slots))))
    (append (list key)
            (and (eq (plist-get c :slot) 'chord)
                 (pcase (plist-get c :action) ('prefix-under '("C-k x")) ('command-on-prefix '("C-k")))))))

(defun keys-matrix--expect-error-p (c writes)
  "Whether case C's action must fail: a write that is not yours (a hook's) under C-k, which the profile makes a prefix
but `global-map' binds to `kill-line', fails as it would in any Emacs; the write then never happened."
  (and (eq (plist-get c :how) 'hook)
       (seq-some (lambda (w) (and (eq (caar w) 'global) (string-prefix-p "C-k " (cdar w)))) writes)))

(defun keys-matrix--state (c writes default)
  "The model's STATE (`keys-matrix--expect') once case C ran with your WRITES (in order)."
  (let* ((yours-p (not (eq (plist-get c :how) 'hook)))
         (pkg (plist-get c :pkg)) (slot (plist-get c :slot))
         (key (nth 1 (assq slot keys-matrix--slots)))
         (yours nil) (pkg-global nil))
    ;; the package's global write and a hook's write are both "not yours": the later one stands
    (let ((pkg-writes (and (memq pkg '(define-key current-global-map global-set-key)) (not (eq slot 'foreign))
                           (list (cons key 'keys-matrix-pkg-glob))))
          (hook-writes (and (not yours-p) (not (keys-matrix--expect-error-p c writes))
                            (delq nil (mapcar (lambda (w) (and (eq (caar w) 'global)
                                                               (cons (cdar w) (if (eq (cdr w) :remove) :remove (cdr w)))))
                                              writes)))))
      (dolist (w (if (< (cl-position 'action (plist-get c :order)) (or (cl-position 'pkg-load (plist-get c :order)) -1))
                     (append hook-writes pkg-writes) (append pkg-writes hook-writes)))
        (if (eq (cdr w) :remove)
            (setq pkg-global (assoc-delete-all (car w) pkg-global))
          (setf (alist-get (car w) pkg-global nil nil #'equal) (cdr w)))))
    (when yours-p
      (dolist (w writes)
        (if (eq (cdr w) :remove)
            (setq yours (assoc-delete-all (car w) yours))
          (setf (alist-get (car w) yours nil nil #'equal) (cdr w)))))
    (list :yours yours :pkg-global pkg-global
          :pkg-mode (and (eq pkg 'mode-map) (list key))
          :profile (mapcar (lambda (s) (list (nth 1 s) (nth 2 s) (nth 3 s))) keys-matrix--slots)
          :default default)))

(defun keys-matrix--binding (key buffer)
  (with-temp-buffer
    (pcase buffer
      ('pkg (keys-matrix-pkg-mode))
      ('pkg-child (keys-matrix-pkg-child-mode))
      ('pkg-sub (keys-matrix-pkg-mode) (use-local-map (make-composed-keymap nil (current-local-map))))
      ('pkg-wgrep (keys-matrix-pkg-mode) (use-local-map (make-sparse-keymap))))
    (let ((b (key-binding (kbd key))))
      (cond ((numberp b) nil) ((keymapp b) 'prefix) (t b)))))

(defun keys-matrix--sheet-lines (key)
  "The sheet's lines about KEY itself: not those of a longer key under it, nor a prefix group's line."
  (let ((longer (seq-filter (lambda (k) (string-prefix-p (concat key " ") k)) keys-matrix--all-keys)))
    (seq-filter (lambda (l) (and (string-prefix-p (concat key " ") l)
                                 (not (seq-some (lambda (k) (string-prefix-p (concat k " ") l)) longer))
                                 (not (string-match-p " keys over " l))))
                (drgnx-keys-conflict-lines))))

(defun keys-matrix--verdict-disagreements ()
  "The sheet's verdicts (`:verdict' of the last apply's conflicts in the global map) that `key-binding' in a plain
buffer does not answer: (KEY SHEET-SAYS KEY-BINDING-SAYS) each."
  (let (bad)
    (dolist (c (plist-get drgnx-keys-last :conflicts))
      (when-let* ((v (plist-get c :verdict)))
        (let* ((b (with-temp-buffer (key-binding (key-parse (plist-get c :key)) nil t)))   ; a [remap] is its own row
               (says (drgnx-keys--def-text (and (not (numberp b)) b))))
          (unless (equal v says) (push (list (plist-get c :key) v says) bad)))))
    (nreverse bad)))

(defconst keys-matrix--all-keys
  (append '("C-o" "C-k C-r" "C-k x" "C-k" "C-j" "C-c C-p" "C-x g")
          (mapcar (lambda (s) (format "<remap> <%s>" (nth 2 s))) keys-matrix--slots))
  "Every key a case may change; the reset puts each back.")

(defun keys-matrix--snapshot ()
  "The fixture keys' bindings in the global map and `ctl-x-map', and in a plain buffer."
  (list :global (mapcar (lambda (k) (let ((d (lookup-key global-map (kbd k)))) (cons k (and (not (numberp d)) d))))
                        keys-matrix--all-keys)
        :ctlx (lookup-key ctl-x-map "g")
        :plain (mapcar (lambda (k) (cons k (keys-matrix--binding k 'plain))) keys-matrix--all-keys)))

(defvar keys-matrix--fresh nil "`keys-matrix--snapshot' at the start of the run.")

(defun keys-matrix--reset ()
  "Undo a case: the empty profile, the fixture keys back in the global map and `ctl-x-map', no package, no record
of yours."
  (drgnx-keys-use '((mx-empty app editing window)))
  (when (fboundp 'drgnx-keys-forget-yours) (drgnx-keys-forget-yours))
  (when (boundp 'drgnx-keys--kept) (set 'drgnx-keys--kept nil))
  (pcase-dolist (`(,k . ,def) (plist-get keys-matrix--fresh :global))
    (if def (define-key global-map (kbd k) def)
      (ignore-errors (define-key global-map (kbd k) nil t))))
  (define-key ctl-x-map "g" (plist-get keys-matrix--fresh :ctlx) (null (plist-get keys-matrix--fresh :ctlx)))
  (setq features (delq 'keys-matrix-pkg features)
        after-load-alist (seq-remove (lambda (e) (eq (car e) 'keys-matrix-pkg)) after-load-alist))
  ;; both maps afresh at the next load (`defvar' keeps a bound one: the derived mode's map would keep the old parent)
  (dolist (v '(keys-matrix-pkg-mode-map keys-matrix-pkg-child-mode-map)) (when (boundp v) (makunbound v)))
  (when keys-matrix--dir (ignore-errors (delete-file (expand-file-name "config.el" keys-matrix--dir))))
  (setq keys-matrix-late-hook nil))

(cl-defun keys-matrix--run (c)
  "Run case C; nil when it holds, else a description of what is off."
  (keys-matrix--reset)
  (let ((after-reset (keys-matrix--snapshot)))
    (unless (equal after-reset keys-matrix--fresh)
      (cl-return-from keys-matrix--run (list :reset-differs after-reset :fresh keys-matrix--fresh))))
  (let* ((fa (keys-matrix--forms (plist-get c :slot) (plist-get c :action) (plist-get c :style)))
         (expect-error (keys-matrix--expect-error-p c (cdr fa)))
         (action-failed nil)
         (default (plist-get keys-matrix--fresh :plain))
         (problems nil))
    (setq keys-matrix-pkg-global (and (memq (plist-get c :pkg) '(define-key current-global-map global-set-key))
                                      (not (eq (plist-get c :slot) 'foreign))
                                      (list (list (plist-get c :pkg) (nth 1 (assq (plist-get c :slot) keys-matrix--slots)))))
          keys-matrix-pkg-mode-keys (and (eq (plist-get c :pkg) 'mode-map)
                                         (list (nth 1 (assq (plist-get c :slot) keys-matrix--slots)))))
    (drgnx-keys-use keys-matrix--stack)                       ; the start: the profile on
    (dolist (e (plist-get c :order))
      ;; each event at the command loop's top level, which sets `this-command' to nil before reading the next
      ;; command (a batch kbd macro leaves the last one set)
      (setq this-command nil)
      (condition-case err
          (pcase e
            ('action (condition-case err (keys-matrix--run-action (plist-get c :how) (car fa))
                       (error (if expect-error (setq action-failed t) (signal (car err) (cdr err))))))
            ('pkg-load (load keys-matrix--pkg-file nil t))
            ('apply (drgnx-keys-apply))
            ('apply-swapped (let ((g (current-global-map)))
                              (unwind-protect (progn (use-global-map (make-sparse-keymap)) (drgnx-keys-apply))
                                (use-global-map g))))
            ('reload (let ((f (expand-file-name "config.el" keys-matrix--dir)))
                       (when (file-exists-p f) (drgnx--load-user-config f))))
            ('switch (drgnx-keys-use '((mx-empty app editing window))) (drgnx-keys-use keys-matrix--stack)))
        (error (push (list :event e :error (error-message-string err)) problems))))
    (when (and expect-error (memq 'action (plist-get c :order)) (not action-failed))
      (push (list :action-should-fail (car fa)) problems))
    (unless (featurep 'keys-matrix-pkg) (load keys-matrix--pkg-file nil t))   ; the mode, to look in its buffers
    (let ((state (keys-matrix--state c (cdr fa) default)))
      (dolist (round '(after more-applies))
        (when (eq round 'more-applies) (drgnx-keys-apply) (drgnx-keys-apply))
        (dolist (key (keys-matrix--keys-of c))
          (dolist (buffer '(plain pkg pkg-child pkg-sub pkg-wgrep))
            (let ((want (keys-matrix--expect key buffer state)) (got (keys-matrix--binding key buffer)))
              (unless (eq want got)
                (push (list round key buffer :want want :got got) problems))))
          (let ((lines (keys-matrix--sheet-lines key)))
            (when (cdr lines) (push (list round key :sheet-lines lines) problems))))
        (dolist (d (keys-matrix--verdict-disagreements)) (push (list round :sheet-verdict d) problems))))
    (and problems (list :case c :problems (nreverse problems)))))

(defmacro keys-matrix--with (&rest body)
  "BODY with only the matrix's commands and profiles, a temp config folder, Linux, the trigger key on; undone after."
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
     (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
       (drgnx-test-with-areas
         (let* ((drgnx-keys-profiles (copy-tree keys-matrix--profiles))
                (drgnx-keys--session-layers nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
                (keys-matrix--dir (make-temp-file "keys-matrix" t))
                (keys-matrix-pkg-global nil) (keys-matrix-pkg-mode-keys nil))
           (keys-matrix--register)
           (keys-matrix-trigger-mode 1)
           (unwind-protect
               (progn (drgnx-keys-use '((mx-empty app editing window)))
                      (setq keys-matrix--fresh (keys-matrix--snapshot))
                      ,@body)
             (keys-matrix--reset)
             (keys-matrix-trigger-mode -1)
             (when (fboundp 'drgnx-keys--restore) (drgnx-keys--restore))
             (delete-directory keys-matrix--dir t)))))))

(defun keys-matrix--check (cases)
  "Run CASES; fail with the failing ones (the first 15) and a count by slot × action × how."
  (let ((bad nil) (tally (make-hash-table :test #'equal)))
    (dolist (c cases)
      (when-let* ((p (keys-matrix--run c)))
        (push p bad)
        (let ((cell (list (plist-get c :slot) (plist-get c :action) (plist-get c :how) (plist-get c :pkg))))
          (when (zerop (gethash cell tally 0))
            (let ((print-length nil) (print-level nil))
              (message "keys-matrix: first of %S: %S" cell p)))
          (cl-incf (gethash cell tally 0)))))
    (when bad
      (let (cells)
        (maphash (lambda (k v) (push (cons k v) cells)) tally)
        (message "keys-matrix: %d of %d cases fail; failing cells (slot action how pkg): %S"
                 (length bad) (length cases) (sort cells (lambda (a b) (> (cdr a) (cdr b)))))
        (ert-fail (list :failing (length bad) :of (length cases) :first (seq-take (nreverse bad) 15)))))))

;;;; The tests

(ert-deftest keys-matrix/seeded-600 ()
  "600 cases from seed 20261115."
  (keys-matrix--with
   (setq keys-matrix--seed 20261115)
   (keys-matrix--check (keys-matrix--cases 600))))

(ert-deftest keys-matrix/every-global-cell ()
  "Every slot × action × how, with no package and the default order (action, then an apply; for bind-other and
unbind-nil also with no apply), the write styles in turn."
  (keys-matrix--with
   (let (cases)
     (dolist (slot (mapcar #'car keys-matrix--slots))
       (dolist (action keys-matrix--actions)
         (dolist (how keys-matrix--hows)
           (dolist (applies (if (memq action '(bind-other unbind-nil)) '((apply) ()) '((apply))))
             (push (list :slot slot :action action :how how :style (mod (length cases) 3)
                         :pkg (if (or (eq how 'after-load) (eq slot 'foreign)) 'mode-map 'none)
                         :order (append (and (or (eq how 'after-load) (eq slot 'foreign)) '(pkg-load)) '(action) applies))
                   cases)))))
     (setq keys-matrix--seed 7)
     (keys-matrix--check (nreverse cases)))))

;; One Emacs per load order: the package loaded before everything else in one child, after your action in another, and
;; a third with subr trampolines off (a native-compiled `keymap-set' or `global-set-key' then calls `define-key'
;; without any advice on it), each running its cases with a reset between them.

(defun keys-matrix--in-order (cases order)
  "CASES with ORDER forced: `pkg-first' (the package loads before anything else) or `pkg-last' (after your action;
a write into the package's map waits for it only through `with-eval-after-load', so those cases are left out)."
  (delq nil
        (mapcar (lambda (c)
                  (let ((o (remq 'pkg-load (plist-get c :order))))
                    (cond ((not (memq 'pkg-load (plist-get c :order))) c)
                          ((eq order 'pkg-first) (plist-put (copy-sequence c) :order (cons 'pkg-load o)))
                          ((and (eq (plist-get c :slot) 'foreign) (not (eq (plist-get c :how) 'after-load))) nil)
                          (t (let ((i (1+ (cl-position 'action o))))
                               (plist-put (copy-sequence c) :order (append (seq-take o i) '(pkg-load) (nthcdr i o))))))))
                cases)))

(defun keys-matrix-child-run (order seed n)
  "In a child Emacs: N cases from SEED in ORDER (`keys-matrix--in-order', or nil for the drawn order).
\(:held COUNT) when all hold; a failing case fails the test."
  (keys-matrix--with
   (setq keys-matrix--seed seed)
   (let ((cases (keys-matrix--cases n)))
     (when order (setq cases (keys-matrix--in-order cases order)))
     (keys-matrix--check cases)
     (list :held (length cases)))))

(defun keys-matrix--child (order seed n &optional no-trampolines)
  (load (expand-file-name "test/settings-child" drgnx-dir) nil t)
  (let ((r (drgnx-settings-test-child
            `(,@(and no-trampolines '((setq native-comp-enable-subr-trampolines nil)))
              (require 'drgnx)
              (load ,(expand-file-name "test/unit/keys-matrix-test" drgnx-dir) nil t)
              (keys-matrix-child-run ',order ,seed ,n))
            :env '("DRGNX_SETTINGS_TEST_STOCK=1"))))
    (unless (let ((v (car (last (plist-get r :values))))) (and (eq (car-safe v) :held) (> (cadr v) 100)))
      (ert-fail (list :order order :no-trampolines no-trampolines :error (plist-get r :error)
                      :cells (seq-filter (lambda (l) (string-prefix-p "keys-matrix: " l))
                                         (split-string (plist-get r :output) "\n")))))))

(ert-deftest keys-matrix/package-first ()
  "300 cases in a child Emacs, the package loaded before anything else in each."
  :tags '(:cond)                                       ; a child Emacs, waited for
  (keys-matrix--child 'pkg-first 4242 300))

(ert-deftest keys-matrix/package-last ()
  "300 cases in a child Emacs, the package loaded right after your action in each."
  :tags '(:cond)                                       ; a child Emacs, waited for
  (keys-matrix--child 'pkg-last 4243 300))

(ert-deftest keys-matrix/trampolines-off ()
  "300 cases in a child Emacs with `native-comp-enable-subr-trampolines' nil from the start."
  :tags '(:cond)                                       ; a child Emacs, waited for
  (keys-matrix--child nil 4244 300 t))

(ert-deftest keys-matrix/kmacro-bind-to-key ()
  "`kmacro-bind-to-key' run from the keyboard is yours: its macro on C-o wins over the profile's key, through applies
and a profile switch.  (It writes `global-map' itself, and refuses inside a keyboard macro, so it is called as the
command loop would.)"
  (keys-matrix--with
   (keys-matrix--reset)
   (drgnx-keys-use keys-matrix--stack)
   (should (eq (keys-matrix--binding "C-o" 'plain) 'keys-matrix-cmd-a))
   (let ((last-kbd-macro "x") (kmacro-ring nil)
         (unread-command-events (listify-key-sequence (kbd "C-o")))
         (this-command 'kmacro-bind-to-key) (real-this-command 'kmacro-bind-to-key))
     (cl-letf (((symbol-function 'yes-or-no-p) #'always))
       (call-interactively #'kmacro-bind-to-key)))
   (dolist (step '(nil apply switch))
     (pcase step
       ('apply (drgnx-keys-apply))
       ('switch (drgnx-keys-use '((mx-empty app editing window))) (drgnx-keys-use keys-matrix--stack)))
     (should (kmacro-p (keys-matrix--binding "C-o" 'plain))))))

(ert-deftest keys-matrix/the-model-states-the-rules ()
  "The model itself, on hand-picked states (so a wrong model cannot pass the matrix by agreeing with the code)."
  (let ((prof (mapcar (lambda (s) (list (nth 1 s) (nth 2 s) (nth 3 s))) keys-matrix--slots))
        (default '(("C-o" . open-line) ("C-j" . electric-newline-and-maybe-indent) ("C-c C-p") ("C-x g"))))
    (cl-flet ((st (&rest kv) (append kv (list :profile prof :default default))))
      ;; yours over the profile, in every buffer; nil does nothing
      (should (eq 'keys-matrix-cmd-a (keys-matrix--expect "C-o" 'plain (st))))
      (should (eq 'keys-matrix-yours (keys-matrix--expect "C-o" 'plain (st :yours '(((global . "C-o") . keys-matrix-yours))))))
      (should (null (keys-matrix--expect "C-o" 'plain (st :yours '(((global . "C-o")))))))
      ;; the profile over a package's global key; a package's mode map over the profile's global key
      (should (eq 'keys-matrix-cmd-a (keys-matrix--expect "C-o" 'plain (st :pkg-global '(("C-o" . keys-matrix-pkg-glob))))))
      (should (eq 'keys-matrix-pkg-own (keys-matrix--expect "C-o" 'pkg (st :pkg-mode '("C-o")))))
      ;; :everywhere over the package's mode map, yours over :everywhere
      (should (eq 'keys-matrix-cmd-c (keys-matrix--expect "C-j" 'pkg (st :pkg-mode '("C-j")))))
      (should (eq 'keys-matrix-yours (keys-matrix--expect "C-j" 'pkg (st :yours '(((global . "C-j") . keys-matrix-yours))))))
      ;; a profile :map key over the package's own key; yours there over both; your nil there gives the map back
      (should (eq 'keys-matrix-cmd-d (keys-matrix--expect "C-c C-p" 'pkg (st :pkg-mode '("C-c C-p")))))
      (should (eq 'keys-matrix-yours (keys-matrix--expect "C-c C-p" 'pkg (st :yours '(((pkg . "C-c C-p") . keys-matrix-yours))))))
      (should (null (keys-matrix--expect "C-c C-p" 'pkg (st :pkg-mode '("C-c C-p") :yours '(((pkg . "C-c C-p")))))))
      ;; your global binding of an :everywhere key: the :everywhere key steps aside, a mode map still wins over yours
      (should (eq 'keys-matrix-pkg-own (keys-matrix--expect "C-j" 'pkg (st :pkg-mode '("C-j") :yours '(((global . "C-j") . keys-matrix-yours))))))
      (should (null (keys-matrix--expect "C-c C-p" 'plain (st))))
      ;; a prefix of a profile key is the profile's, over a command a package or hook put there
      (should (eq 'prefix (keys-matrix--expect "C-k" 'plain (st :pkg-global '(("C-k" . keys-matrix-hook-cmd))))))
      ;; your remap turns the profile's command into yours; a derived mode is the package's mode; wgrep's map is not
      (should (eq 'keys-matrix-yours (keys-matrix--expect "C-o" 'plain (st :yours '(((global . "<remap> <keys-matrix-cmd-a>") . keys-matrix-yours))))))
      (should (eq 'keys-matrix-cmd-d (keys-matrix--expect "C-c C-p" 'pkg-child (st))))
      (should (null (keys-matrix--expect "C-c C-p" 'pkg-wgrep (st :pkg-mode '("C-c C-p")))))
      ;; a command of yours on the profile's prefix: the chord under it runs nothing
      (should (null (keys-matrix--expect "C-k C-r" 'plain (st :yours '(((global . "C-k") . keys-matrix-yours))))))
      ;; but the package's mode map is above the global map, yours included: its chord and its prefix stay
      (let ((s (st :yours '(((global . "C-k") . keys-matrix-yours)) :pkg-mode '("C-k C-r"))))
        (should (eq 'keys-matrix-pkg-own (keys-matrix--expect "C-k C-r" 'pkg s)))
        (should (eq 'prefix (keys-matrix--expect "C-k" 'pkg s)))
        (should (eq 'keys-matrix-yours (keys-matrix--expect "C-k" 'plain s)))))))

;;; keys-matrix-test.el ends here
