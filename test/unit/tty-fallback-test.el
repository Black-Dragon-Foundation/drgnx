;;; tty-fallback-test.el --- batch tests: the fallback layer for legacy terminals (Alt+Shift, F6) -*- lexical-binding: t -*-
;; Batch Emacs has no terminal: terminals and their parameters are stubbed (the batch frame's own
;; `input-decode-map' takes the layer's entries, which each test takes off again); the tty tier
;; (test/tty/fallback-test.el) sends the real bytes.
(require 'ert)
(require 'drgnx)
(require 'drgnx-tty-fallback)
(require 'drgnx-tty-recommend)          ; `drgnx-tty--fallback-hint': the recommendation says the same keys
(load (expand-file-name "modules/ui/drgnx-tty-frames" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-tty-fallback-layer" drgnx-dir) nil t)

(defconst tty-fallback-test--profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))
(defconst tty-fallback-test--defaults (copy-keymap global-map) "Emacs's own bindings, as `drgnx-keys' keeps them.")
(defvar tty-fallback-test--resolved (make-hash-table :test #'equal) "Preset name → its resolved bindings.")

(defun tty-fallback-test--bindings (preset &optional platform)
  "The bindings (plists) of PRESET (a name of `drgnx-keys-presets'), resolved once with every module's commands."
  (let ((k (cons preset platform)))
    (or (gethash k tty-fallback-test--resolved)
        (puthash k (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
                         (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
                         (ring-bell-function ring-bell-function) (use-dialog-box use-dialog-box)
                         (use-short-answers use-short-answers) (inhibit-startup-screen inhibit-startup-screen))
                     (drgnx--core-commands)
                     (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
                     (drgnx-modules-run 'startup)
                     (drgnx-modules-run 'idle)   ; tools/replace (C-S-h) and the other idle modules define commands too
                     (plist-get (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles tty-fallback-test--profiles
                                                    :layers (cdr (assoc preset drgnx-keys-presets))
                                                    :defaults tty-fallback-test--defaults :platform platform)
                                :bindings))
                 tty-fallback-test--resolved))))

(defun tty-fallback-test--keys (preset &optional platform)
  (seq-uniq (mapcar (lambda (b) (plist-get b :key)) (tty-fallback-test--bindings preset platform))))

(defun tty-fallback-test--table (preset &rest args)
  (let ((keys (tty-fallback-test--keys preset)))
    (apply #'drgnx-tty-fallback-table keys :global tty-fallback-test--defaults :profile keys :prefix "<f6>" args)))

(defun tty-fallback-test--row (table chord) (cdr (assoc chord table)))

;;;; A fake terminal

(defvar tty-fallback-test--term 'kx-a "The terminal `frame-terminal' answers.")
(defvar tty-fallback-test--graphic nil "What `display-graphic-p' answers.")

(defmacro tty-fallback-test--with-terminal (params env &rest body)
  "BODY with fake terminals (kx-a, or `tty-fallback-test--term') holding PARAMS (an alist) on the batch frame,
whose client environment is ENV, a temp state dir and config dir, no terminal to ask, no prompt possible, and
`messages' collecting what was said.  The layer's entries in the batch frame's `input-decode-map' and the prefix
binding are taken off afterwards."
  (declare (indent 2))
  `(let* ((table (make-hash-table :test #'equal))
          (drgnx-tty-frames--cache (make-hash-table :test #'equal))
          (tty-fallback-test--term 'kx-a)
          (tty-fallback-test--graphic nil)
          (state (make-temp-file "drgnx-state" t))
          (cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (append (list (concat "XDG_STATE_HOME=" state) (concat "DRGNX_CONFIG_DIR=" cfg))
                                       process-environment))
          (real-frame-parameter (symbol-function 'frame-parameter))
          (drgnx-keys--defaults tty-fallback-test--defaults)
          (drgnx-tty-fallback t) (drgnx-tty-fallback-hint t) (drgnx-tty-chord-prefix "<f6>")
          (drgnx-tty-fallback--cache nil)
          (drgnx-hooks-problems nil)
          (messages nil))
     (pcase-dolist (`(,k . ,v) ,params) (puthash (cons 'kx-a k) v table))
     (unwind-protect
         (cl-letf (((symbol-function 'frame-parameter)
                    (lambda (f p) (if (eq p 'environment) ,env (funcall real-frame-parameter f p))))
                   ((symbol-function 'frame-terminal) (lambda (&optional _) tty-fallback-test--term))
                   ((symbol-function 'terminal-name) (lambda (&optional term) (symbol-name term)))
                   ((symbol-function 'terminal-live-p) (lambda (_term) t))
                   ;; the editor tabs' close glyph (drgnx-face-glyph) asks the terminal for its coding system; a
                   ;; fake terminal has none, and the failure left core/workbench unset-up (a table of 27 chords, not 37)
                   ((symbol-function 'terminal-coding-system) (lambda (&optional _) 'utf-8-unix))
                   ((symbol-function 'display-graphic-p) (lambda (&optional _) tty-fallback-test--graphic))
                   ((symbol-function 'terminal-parameter)
                    (lambda (term p) (gethash (cons (or term tty-fallback-test--term) p) table)))
                   ((symbol-function 'set-terminal-parameter)
                    (lambda (term p v) (puthash (cons (or term tty-fallback-test--term) p) v table)))
                   ((symbol-function 'drgnx-tty-frames--ask) (lambda (_frame) nil))
                   ((symbol-function 'display-color-cells) (lambda (&optional _) 256))
                   ;; the hint waits for the server's own message: at once here
                   ((symbol-function 'run-with-timer) (lambda (_secs _repeat fn &rest args) (apply fn args)))
                   ((symbol-function 'message)
                    (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) messages))))
                   ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked")))
                   ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Asked")))
                   ((symbol-function 'read-string) (lambda (&rest _) (error "Asked")))
                   ((symbol-function 'read-from-minibuffer) (lambda (&rest _) (error "Asked")))
                   ((symbol-function 'completing-read) (lambda (&rest _) (error "Asked"))))
           ,@body)
       (dolist (term '(kx-a kx-b))
         (pcase-dolist (`(,bytes . ,ours) (gethash (cons term 'drgnx-tty-fallback-installed) table))
           (when (eq (lookup-key input-decode-map bytes) ours) (define-key input-decode-map bytes nil t))))
       (drgnx-tty-fallback--unbind-prefix)
       (delete-directory state t)
       (delete-directory cfg t))))

(defun tty-fallback-test--report ()
  (with-temp-buffer (insert-file-contents (drgnx-tty-frames--report-file)) (read (current-buffer))))

(defconst tty-fallback-test--legacy '(:id vte :outer nil :version "7800" :keys legacy :c-g always :folded nil
                                          :osc52 nil :colors 256 :mouse t))

;;;; The rules

(ert-deftest drgnx-tty-fallback/f6-is-free-everywhere ()
  (should (equal drgnx-tty-chord-prefix "<f6>"))
  (should-not (keymap-lookup tty-fallback-test--defaults "<f6>"))
  (dolist (preset (mapcar #'car drgnx-keys-presets))
    (should (equal (list preset nil)
                   (list preset (seq-filter (lambda (k) (seq-contains-p (key-parse k) 'f6)) (tty-fallback-test--keys preset)))))
    ;; and none of the profile files names it at all (M12d, Vim, treats F6 as taken)
    (dolist (spec tty-fallback-test--profiles)
      (should-not (string-match-p "f6>" (format "%S" (plist-get (cdr spec) :bind))))))
  (dolist (row drgnx-tty-terminals)
    (should-not (seq-find (lambda (k) (equal (key-parse k) [f6])) (plist-get row :takes))))
  (should (drgnx-tty-key-sendable-p "<f6>" 'legacy)))

(ert-deftest drgnx-tty-fallback/c-s-letters-map-to-alt-shift ()
  (let ((table (tty-fallback-test--table "VS Code")))
    ;; C-S-p: its Alt+Shift+P is ESC P, the start of a terminal's reply (DCS): the prefix only
    (should (equal (tty-fallback-test--row table "C-S-p") '(:alt nil :prefix "<f6> p")))
    (should (equal (tty-fallback-test--row table "C-S-f") '(:alt "M-F" :prefix "<f6> f")))
    (should (equal (tty-fallback-test--row table "C-S-e") '(:alt "M-E" :prefix "<f6> e")))))

(ert-deftest drgnx-tty-fallback/never-a-reserved-key ()
  (should (member "M-P" drgnx-tty-fallback-never))
  (dolist (preset (mapcar #'car drgnx-keys-presets))
    (pcase-dolist (`(,_ . ,row) (tty-fallback-test--table preset))
      (should-not (member (plist-get row :alt) drgnx-tty-fallback-never))))
  (let ((table (tty-fallback-test--table "VS Code")))
    ;; C-. would be M-> (end of buffer), C-` M-~ (bound): no ALT, no second guess
    (should (equal (tty-fallback-test--row table "C-.") '(:alt nil :prefix "<f6> .")))
    (should (equal (tty-fallback-test--row table "C-`") '(:alt nil :prefix "<f6> `")))
    (should (equal (tty-fallback-test--row table "C-S-`") '(:alt nil :prefix "<f6> ~")))
    (should (equal (tty-fallback-test--row table "C-<return>") '(:alt nil :prefix "<f6> RET")))
    (should (equal (tty-fallback-test--row table "C-S-<return>") '(:alt nil :prefix "<f6> M-RET")))
    (should (equal (tty-fallback-test--row table "C-<tab>") '(:alt nil :prefix "<f6> TAB")))
    (should (equal (tty-fallback-test--row table "C-SPC") '(:alt nil :prefix "<f6> C-@")))   ; Ctrl+Space sends C-@
    (should (equal (tty-fallback-test--row table "C-S-SPC") '(:alt nil :prefix "<f6> SPC")))))

(ert-deftest drgnx-tty-fallback/no-clash-with-emacs-or-any-profile ()
  (dolist (preset (mapcar #'car drgnx-keys-presets))
    (let* ((keys (tty-fallback-test--keys preset))
           (table (tty-fallback-test--table preset))
           (alts (delq nil (mapcar (lambda (r) (plist-get (cdr r) :alt)) table)))
           (prefixes (mapcar (lambda (r) (plist-get (cdr r) :prefix)) table)))
      (should (equal (list preset nil)
                     (list preset (drgnx-tty-fallback-clashes table :global tty-fallback-test--defaults :profile keys))))
      (dolist (alt alts)
        (should-not (keymap-lookup tty-fallback-test--defaults alt))
        (should-not (seq-find (lambda (k) (equal (aref (key-parse k) 0) (aref (key-parse alt) 0))) keys)))
      (should (equal alts (seq-uniq alts)))
      (should (equal prefixes (seq-uniq prefixes)))))
  ;; the checks find a clash when there is one
  (should (equal (mapcar #'car (drgnx-tty-fallback-clashes '(("C-S-p" :alt "M-P") ("C-." :alt "M-x") ("C-S-f" :alt "M-F")
                                                             ("C-S-g" :alt "M-F"))
                                                           :global tty-fallback-test--defaults))
                 '("C-S-p" "C-." "C-S-g"))))

(ert-deftest drgnx-tty-fallback/taken-keys-get-sendable-fallbacks ()
  (let* ((takes (plist-get (drgnx-tty-terminal 'vte) :takes))
         (keys (tty-fallback-test--keys "VS Code"))
         (chords '("C-S-c" "C-S-v" "C-S-t" "C-S-n" "C-S-w" "C-S-f"))
         (table (drgnx-tty-fallback-table chords :global tty-fallback-test--defaults :profile keys :takes takes
                                          :prefix "<f6>")))
    (dolist (chord chords)
      (should (member chord takes))
      (let ((row (tty-fallback-test--row table chord)))
        (should (plist-get row :prefix))
        (should (drgnx-tty-key-sendable-p (plist-get row :prefix) 'legacy))
        (should-not (member (plist-get row :prefix) takes))
        (when-let* ((alt (plist-get row :alt)))
          (should (drgnx-tty-key-sendable-p alt 'legacy))
          (should-not (member alt takes)))))
    (should (equal (plist-get (tty-fallback-test--row table "C-S-f") :alt) "M-F"))))

(ert-deftest drgnx-tty-fallback/every-chord-has-a-route ()
  (dolist (preset (mapcar #'car drgnx-keys-presets))
    (let* ((keys (tty-fallback-test--keys preset))
           (table (tty-fallback-test--table preset)))
      ;; every chord the profile binds that a legacy terminal cannot send is in the table…
      (dolist (key (drgnx-tty-unsendable keys 'legacy))
        (dolist (ev (append (key-parse key) nil))
          ;; (S-<return> and C-M-<return>, the Replace bar's, have no F6 form: their commands have other keys)
          (unless (or (drgnx-tty-key-sendable-p (vector ev) 'legacy) (not (drgnx-tty-fallback--prefix-of ev "<f6>")))
            (should (seq-find (lambda (r) (equal (key-parse (car r)) (vector ev))) table)))))
      ;; …with a prefix form a legacy terminal can type
      (pcase-dolist (`(,chord . ,row) table)
        (should (equal (list chord t) (list chord (and (plist-get row :prefix)
                                                       (drgnx-tty-key-sendable-p (plist-get row :prefix) 'legacy)
                                                       t)))))))
  ;; the ones with no Alt+Shift key (docs/guide/terminal.md lists them)
  (let ((no-alt (mapcar #'car (seq-remove (lambda (r) (plist-get (cdr r) :alt)) (tty-fallback-test--table "VS Code")))))
    (should (member "C-S-p" no-alt))
    (should (member "C-." no-alt))
    (should-not (member "C-S-f" no-alt))))

(ert-deftest drgnx-tty-fallback/macos-cmd-keys-map-like-their-ctrl-form ()
  (let* ((keys (tty-fallback-test--keys "VS Code" 'macos))
         (table (drgnx-tty-fallback-table keys :global tty-fallback-test--defaults :profile keys :prefix "<f6>")))
    (should (equal (tty-fallback-test--row table "s-P") '(:alt nil :prefix "<f6> p")))
    (should (equal (plist-get (tty-fallback-test--row table "s-F") :alt) "M-F"))
    (should (equal (plist-get (tty-fallback-test--row table "s-p") :prefix) "<f6> C-p"))))

(ert-deftest drgnx-tty-fallback/keys-eld-overrides-a-fallback ()
  ;; M-j is bound in the VS Code profile: not used, and said so
  (let ((table (tty-fallback-test--table "VS Code" :overrides '(("C-S-p" . "M-j")))))
    (should (null (plist-get (tty-fallback-test--row table "C-S-p") :alt)))
    (should (equal (car (plist-get (tty-fallback-test--row table "C-S-p") :rejected)) "M-j")))
  ;; M-Z is free: C-S-p takes it, and C-S-z, whose own Alt+Shift key it was, keeps only its prefix
  (let ((table (tty-fallback-test--table "VS Code" :overrides '(("C-S-p" . "M-Z")))))
    (should (equal (tty-fallback-test--row table "C-S-p") '(:alt "M-Z" :prefix "<f6> p")))
    (should (equal (tty-fallback-test--row table "C-S-z") '(:alt nil :prefix "<f6> z")))
    (should-not (drgnx-tty-fallback-problems table)))
  ;; read from keys.eld
  (let* ((dir (make-temp-file "drgnx-cfg" t))
         (process-environment (cons (concat "DRGNX_CONFIG_DIR=" dir) process-environment))
         (drgnx-keys-last (list :bindings (tty-fallback-test--bindings "VS Code")))
         (drgnx-keys--defaults tty-fallback-test--defaults)
         (drgnx-tty-fallback--cache nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "keys.eld" dir) (insert "(:tty-fallback ((\"C-S-p\" . \"M-Z\")))\n"))
          (should (equal (plist-get (tty-fallback-test--row (drgnx-tty-fallback-active-table) "C-S-p") :alt) "M-Z")))
      (delete-directory dir t))))

(ert-deftest drgnx-tty-fallback/a-clashing-override-is-a-problem ()
  ;; bound in the profile, reserved, not sendable either, Emacs's own (not-modified)
  ;; …and anything but Alt with a character key: a function key, Alt with a named key, Shift with one
  (dolist (override '(("C-S-p" . "M-j") ("C-S-p" . "M-x") ("C-S-p" . "C-S-z") ("C-S-p" . "M-~")
                      ("C-S-p" . "<f7>") ("C-S-p" . "M-<f5>") ("C-S-p" . "M-<up>") ("C-S-p" . "S-<f7>")))
    (let* ((table (tty-fallback-test--table "VS Code" :overrides (list override)))
           (problems (drgnx-tty-fallback-problems table)))
      (should (equal (list override 1) (list override (length problems))))
      (should (string-match-p (regexp-quote (format "C-S-p → %s" (cdr override))) (car problems)))
      (should-not (plist-get (tty-fallback-test--row table "C-S-p") :alt))))
  ;; two chords asking for one key: the second is not given it
  (let ((table (tty-fallback-test--table "VS Code" :overrides '(("C-S-p" . "M-Z") ("C-S-e" . "M-Z")))))
    (should (equal (plist-get (tty-fallback-test--row table "C-S-p") :alt) "M-Z"))
    (should (equal (plist-get (tty-fallback-test--row table "C-S-e") :alt) "M-E"))
    (should (string-match-p "C-S-e → M-Z not used: M-Z is already the fallback of C-S-p"
                            (car (drgnx-tty-fallback-problems table)))))
  ;; entries that are not (CHORD . KEY), or name a chord the profile needs no fallback for, are said too
  (let* ((overrides '(("C-S-p") "junk" ("C-p" . "M-Z") ("C-S-q" . "M-Q")))
         (problems (drgnx-tty-fallback-problems (tty-fallback-test--table "VS Code" :overrides overrides) overrides)))
    (should (= (length problems) 4))
    (dolist (text '("C-S-p" "junk" "C-p" "C-S-q"))
      (should (seq-find (lambda (p) (string-search text p)) problems))))
  ;; the problem reaches the terminal's report entry
  (tty-fallback-test--with-terminal '((drgnx-tty-set-up . t)) '("TERM=xterm-256color" "VTE_VERSION=7800")
    (let ((drgnx-tty-fallback--cache nil)
          (drgnx-keys-last (list :bindings (tty-fallback-test--bindings "VS Code"))))
      (cl-letf (((symbol-function 'drgnx-tty-fallback--overrides) (lambda () '(("C-S-p" . "M-j") ("C-p" . "M-Z")))))
        (drgnx-tty-frames-write-report (selected-frame))
        (let ((problems (plist-get (cdr (assoc "kx-a" (plist-get (tty-fallback-test--report) :terminals)))
                                   :fallback-problems)))
          (should (= (length problems) 2))
          (should (string-match-p "M-j" (car problems)))
          (should (string-match-p "C-p" (cadr problems))))))))

(ert-deftest drgnx-tty-fallback/a-bad-row-never-breaks-the-layer ()
  ;; a row whose key has no bytes (it cannot come from the table any more) is skipped: the rest is installed, the
  ;; prefix is bound, and everything installed comes off again
  (tty-fallback-test--with-terminal nil '("TERM=xterm-256color")
    (let ((drgnx-keys-last (list :bindings (tty-fallback-test--bindings "VS Code"))))
      (cl-letf (((symbol-function 'drgnx-tty-fallback-for-terminal)
                 (lambda (&rest _) '(("C-S-f" :alt "M-F" :prefix "<f6> f") ("C-S-e" :alt "M-<f5>" :prefix "<f6> e")
                                     ("C-S-b" :alt "M-B" :prefix "<f6> b")))))
        (should (drgnx-tty-fallback-install (selected-frame) tty-fallback-test--legacy)))
      (should (eq (lookup-key key-translation-map [f6]) #'drgnx-tty-fallback--prefix))
      (should (functionp (lookup-key input-decode-map "\eF")))
      (should (functionp (lookup-key input-decode-map "\eB")))
      (drgnx-tty-fallback-remove 'kx-a)
      (should-not (functionp (lookup-key input-decode-map "\eF")))
      (should-not (functionp (lookup-key input-decode-map "\eB"))))))

;;;; Per frame

(ert-deftest drgnx-tty-fallback/decode-at-key-time ()
  (let ((asked nil))
    (cl-flet ((bindings (alt chord) (lambda (key &rest args)
                                      (push (cons key args) asked)
                                      (if (equal key (key-parse "M-F")) alt chord))))
      ;; M-F free, C-S-f a command: the chord
      (cl-letf (((symbol-function 'key-binding) (bindings nil 'drgnx-search-project)))
        (should (equal (drgnx-tty-fallback--decode "M-F" "C-S-f") (key-parse "C-S-f"))))
      ;; M-F bound here: M-F, for the mode
      (cl-letf (((symbol-function 'key-binding) (bindings 'some-mode-command 'drgnx-search-project)))
        (should (equal (drgnx-tty-fallback--decode "M-F" "C-S-f") (key-parse "M-F"))))
      ;; a key too long for a binding (a prefix of it is a command) is free
      (cl-letf (((symbol-function 'key-binding) (bindings 1 'drgnx-search-project)))
        (should (equal (drgnx-tty-fallback--decode "M-F" "C-S-f") (key-parse "C-S-f"))))
      ;; the chord does nothing here: Alt+Shift stays what Emacs makes of it
      (cl-letf (((symbol-function 'key-binding) (bindings nil nil)))
        (should (equal (drgnx-tty-fallback--decode "M-F" "C-S-f") (key-parse "M-F"))))
      ;; default bindings count (a keymap that takes every key)
      (should (seq-every-p (lambda (call) (eq (cadr call) t)) asked))))
  ;; for real: a buffer whose mode binds M-F keeps it (the current buffer, where Emacs then looks the key up)
  (with-temp-buffer
    (use-local-map (let ((m (make-sparse-keymap))) (define-key m (key-parse "C-S-f") #'ignore) m))
    (should (equal (drgnx-tty-fallback--decode "M-F" "C-S-f") (key-parse "C-S-f")))
    (define-key (current-local-map) (key-parse "M-F") #'ignore)
    (should (equal (drgnx-tty-fallback--decode "M-F" "C-S-f") (key-parse "M-F")))
    ;; a mode map with a default binding takes M-F too
    (use-local-map (let ((m (make-sparse-keymap))) (define-key m [t] #'ignore) (define-key m (key-parse "C-S-f") #'ignore) m))
    (should (equal (drgnx-tty-fallback--decode "M-F" "C-S-f") (key-parse "M-F")))))

(ert-deftest drgnx-tty-fallback/sendable-key-answers-per-frame ()
  (tty-fallback-test--with-terminal nil '("TERM=xterm-256color")
    (let ((drgnx-keys-last (list :bindings (tty-fallback-test--bindings "VS Code"))))
      ;; a graphical frame, and a terminal not set up: as it is
      (let ((tty-fallback-test--graphic t))
        (should (equal (drgnx-tty-sendable-key (selected-frame) "C-S-p") "C-S-p")))
      (should (equal (drgnx-tty-sendable-key (selected-frame) "C-S-p") "C-S-p"))
      ;; kkp
      (drgnx-tty-fallback-install (selected-frame) (plist-put (copy-sequence tty-fallback-test--legacy) :keys 'kkp))
      (set-terminal-parameter nil 'drgnx-tty-caps (plist-put (copy-sequence tty-fallback-test--legacy) :keys 'kkp))
      (should (equal (drgnx-tty-sendable-key (selected-frame) "C-S-p") "C-S-p"))
      ;; legacy with the layer
      (set-terminal-parameter nil 'drgnx-tty-caps tty-fallback-test--legacy)
      (should (drgnx-tty-fallback-install (selected-frame)))
      (with-temp-buffer
        (should (equal (drgnx-tty-sendable-key (selected-frame) "C-S-f") "M-F"))
        (should (equal (drgnx-tty-sendable-key (selected-frame) "C-S-p") "<f6> p"))
        (should (equal (drgnx-tty-sendable-key (selected-frame) "C-.") "<f6> ."))
        (should (equal (drgnx-tty-sendable-key (selected-frame) "C-k C-s") "C-k C-s"))
        (should (equal (drgnx-tty-sendable-key (selected-frame) "<f1>") "<f1>"))
        ;; in a buffer whose mode binds M-F: the prefix form
        (use-local-map (let ((m (make-sparse-keymap))) (define-key m (key-parse "M-F") #'ignore) m))
        (should (equal (drgnx-tty-sendable-key (selected-frame) "C-S-f") "<f6> f")))
      ;; the layer off: unchanged, and not sendable here
      (let ((drgnx-tty-fallback nil))
        (should (equal (drgnx-tty-sendable-key (selected-frame) "C-S-p") "C-S-p"))
        (should-not (drgnx-tty-frame-sends-p (selected-frame) "C-S-p"))
        (should (drgnx-tty-frame-sends-p (selected-frame) "C-p"))))))

(ert-deftest drgnx-tty-fallback/installed-only-on-legacy-terminals ()
  (tty-fallback-test--with-terminal nil '("TERM=xterm-256color")
    (let ((drgnx-keys-last (list :bindings (tty-fallback-test--bindings "VS Code"))))
      ;; kkp, modifyOtherKeys (WezTerm), a graphical frame: nothing
      (dolist (caps (list (plist-put (copy-sequence tty-fallback-test--legacy) :keys 'kkp)
                          (plist-put (plist-put (copy-sequence tty-fallback-test--legacy) :keys 'mok) :id 'wezterm)))
        (should-not (drgnx-tty-fallback-install (selected-frame) caps))
        (should-not (terminal-parameter nil 'drgnx-tty-fallback))
        (should-not (functionp (lookup-key input-decode-map "\eF"))))
      (let ((tty-fallback-test--graphic t))
        (should-not (drgnx-tty-fallback-install (selected-frame) tty-fallback-test--legacy)))
      (should-not (lookup-key key-translation-map [f6]))
      ;; legacy: the Alt+Shift keys are decoded on that terminal, the prefix is bound
      (should (drgnx-tty-fallback-install (selected-frame) tty-fallback-test--legacy))
      (should (terminal-parameter nil 'drgnx-tty-fallback))
      (should (functionp (lookup-key input-decode-map "\eF")))
      (should-not (functionp (lookup-key input-decode-map "\eP")))          ; ESC P starts a terminal reply
      (with-temp-buffer
        (use-local-map (let ((m (make-sparse-keymap))) (define-key m (key-parse "C-S-f") #'ignore) m))   ; Search's key
        (should (equal (funcall (lookup-key input-decode-map "\eF") nil) (key-parse "C-S-f"))))
      (should (eq (lookup-key key-translation-map [f6]) #'drgnx-tty-fallback--prefix))
      ;; kkp turned on later: the layer goes
      (should-not (drgnx-tty-fallback-install (selected-frame) (plist-put (copy-sequence tty-fallback-test--legacy) :keys 'kkp)))
      (should-not (functionp (lookup-key input-decode-map "\eF")))
      (should-not (terminal-parameter nil 'drgnx-tty-fallback-table))
      ;; tmux at modifyOtherKeys level 1: only the chords it folds
      (let ((tmux (list :id 'tmux :keys 'mok :folded drgnx-tty-tmux-folded-chords)))
        (should (drgnx-tty-fallback-install (selected-frame) tmux))
        (let ((rows (terminal-parameter nil 'drgnx-tty-fallback-table)))
          (should (assoc "C-S-f" rows))
          (should (assoc "C-`" rows))
          (should-not (assoc "C-." rows))))           ; modifyOtherKeys sends it
      (drgnx-tty-fallback-remove 'kx-a)
      (should-not (functionp (lookup-key input-decode-map "\eF"))))))

(ert-deftest drgnx-tty-fallback/never-over-someone-elses-decoding ()
  (tty-fallback-test--with-terminal nil '("TERM=xterm-256color")
    (let ((drgnx-keys-last (list :bindings (tty-fallback-test--bindings "VS Code")))
          (theirs (lambda (_) [?x])))
      (define-key input-decode-map "\eF" theirs)
      (unwind-protect
          (progn
            (should (drgnx-tty-fallback-install (selected-frame) tty-fallback-test--legacy))
            (should (eq (lookup-key input-decode-map "\eF") theirs))
            (drgnx-tty-fallback-remove 'kx-a)
            (should (eq (lookup-key input-decode-map "\eF") theirs)))
        (define-key input-decode-map "\eF" nil t)))))

(ert-deftest drgnx-tty-fallback/off-removes-it-everywhere ()
  (tty-fallback-test--with-terminal '((drgnx-tty-set-up . t)) '("TERM=xterm-256color" "VTE_VERSION=7800")
    (let ((drgnx-keys-last (list :bindings (tty-fallback-test--bindings "VS Code"))))
      (drgnx-tty-frames-write-report (selected-frame))
      (should (terminal-parameter nil 'drgnx-tty-fallback))
      (should (functionp (lookup-key input-decode-map "\eF")))
      (let ((entry (cdr (assoc "kx-a" (plist-get (tty-fallback-test--report) :terminals)))))
        (should (eq (plist-get entry :fallback) t))
        (should (member '("C-S-f" nil "M-F" "<f6> f") (plist-get entry :fallbacks)))
        (should (member '("C-S-p" nil nil "<f6> p") (plist-get entry :fallbacks))))
      (customize-set-variable 'drgnx-tty-fallback nil)
      (should-not (terminal-parameter nil 'drgnx-tty-fallback))
      (should-not (functionp (lookup-key input-decode-map "\eF")))
      (should-not (lookup-key key-translation-map [f6]))
      (let ((entry (cdr (assoc "kx-a" (plist-get (tty-fallback-test--report) :terminals)))))
        (should (eq (plist-get entry :fallback) nil))
        (should (member '("C-S-f" nil nil nil) (plist-get entry :fallbacks))))
      (should-not drgnx-hooks-problems))))

(ert-deftest drgnx-tty-fallback/profile-switch-rebuilds-it ()
  ;; a real switch (`drgnx-keys-use', the Keyboard Profile command's), with the core and module commands; the
  ;; modules are loaded before the terminal is faked (loading them defines the functions the fake replaces)
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
        (ring-bell-function ring-bell-function) (use-dialog-box use-dialog-box)
        (use-short-answers use-short-answers) (inhibit-startup-screen inhibit-startup-screen)
        (drgnx-keys--applied nil) (drgnx-keys--session-layers nil) (drgnx-keys-profiles nil)
        (drgnx-keys-problems nil) (drgnx-keys-last nil))
    (drgnx--core-commands)
    (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
    (drgnx-modules-run 'startup)            ; ui/terminal's setup adds the rebuild after every key apply
    (unwind-protect
        (tty-fallback-test--with-terminal '((drgnx-tty-set-up . t)) '("TERM=xterm-256color" "VTE_VERSION=7800")
          (should (advice-member-p #'drgnx-tty-fallback-apply 'drgnx-keys-apply))
          (drgnx-keys-use '((vscode app editing window)))
          (should (terminal-parameter nil 'drgnx-tty-fallback))
          (should (functionp (lookup-key input-decode-map "\eF")))
          ;; the Emacs profile: only C-S-p is left, and it has no Alt+Shift key
          (drgnx-keys-use '((emacs app editing window)))
          (should-not (functionp (lookup-key input-decode-map "\eF")))
          (should (equal (terminal-parameter nil 'drgnx-tty-fallback-table) '(("C-S-p" :alt nil :prefix "<f6> p"))))
          (should-not drgnx-hooks-problems))
      (drgnx-keys--restore))))

(ert-deftest drgnx-tty-fallback/the-hint-once-per-terminal-type ()
  (let ((hint "This terminal can't send Ctrl+Shift keys: use Alt+Shift (or F6 then the key). drgnx doctor has details."))
    (should (equal (drgnx-tty-fallback-hint-text) hint))
    (tty-fallback-test--with-terminal nil '("TERM=xterm-256color" "VTE_VERSION=7800")
      (let ((drgnx-keys-last (list :bindings (tty-fallback-test--bindings "VS Code"))))
        ;; two VTE clients: one message
        (drgnx-tty-frames-write-report (selected-frame))
        (let ((tty-fallback-test--term 'kx-b))
          (puthash '(kx-b . drgnx-tty-set-up) t table)
          (drgnx-tty-frames-write-report (selected-frame)))
        (should (= (seq-count (lambda (m) (equal m hint)) messages) 1))
        (should (equal (plist-get (tty-fallback-test--report) :hinted) '(vte)))
        ;; the report keeps it through later writes; a capable terminal gets none
        (drgnx-tty-frames-write-report (selected-frame))
        (should (equal (plist-get (tty-fallback-test--report) :hinted) '(vte)))
        (should (= (seq-count (lambda (m) (equal m hint)) messages) 1))))
    ;; a profile whose chords that terminal sends (nothing to type another way): nothing said, nothing remembered
    (tty-fallback-test--with-terminal nil '("TERM=xterm-256color" "VTE_VERSION=7800")
      (let ((drgnx-keys-last '(:bindings ((:id open-file :key "C-o") (:id palette :key "<f1>")))))
        (drgnx-tty-frames-write-report (selected-frame))
        (should-not (terminal-parameter nil 'drgnx-tty-fallback-table))
        (should-not (member hint messages))
        (should-not (plist-get (tty-fallback-test--report) :hinted))))
    ;; the hint off: nothing said, nothing remembered
    (tty-fallback-test--with-terminal nil '("TERM=xterm-256color" "VTE_VERSION=7800")
      (let ((drgnx-keys-last (list :bindings (tty-fallback-test--bindings "VS Code")))
            (drgnx-tty-fallback-hint nil))
        (drgnx-tty-frames-write-report (selected-frame))
        (should (terminal-parameter nil 'drgnx-tty-fallback))
        (should-not (member hint messages))
        (should-not (plist-get (tty-fallback-test--report) :hinted))))))

(ert-deftest drgnx-tty-fallback/no-hint-when-kkp-comes-before-it ()
  ;; a kitty is legacy at the moment its frame is set up and kkp a moment later (kkp's answer comes
  ;; asynchronously; the exit test in a real kitty saw it): by the time the hint is due the layer is off again, so
  ;; nothing is said and nothing remembered.  The bindings first: resolving them loads the modules, which would
  ;; replace the fakes below
  (let ((bindings (tty-fallback-test--bindings "VS Code")))
    (tty-fallback-test--with-terminal nil '("TERM=xterm-kitty" "KITTY_WINDOW_ID=1")
      (let ((drgnx-keys-last (list :bindings bindings))
            (timers nil))
        (cl-letf (((symbol-function 'run-with-timer) (lambda (_secs _repeat fn &rest args) (push (cons fn args) timers))))
          (drgnx-tty-frames-write-report (selected-frame))
          (should (terminal-parameter nil 'drgnx-tty-fallback))
          (set-terminal-parameter nil 'drgnx-tty-kkp t)
          (drgnx-tty-frames-write-report (selected-frame))
          (should-not (terminal-parameter nil 'drgnx-tty-fallback))
          (should timers)
          (pcase-dolist (`(,fn . ,args) timers) (apply fn args)))
        (should-not (member (drgnx-tty-fallback-hint-text) messages))
        (should-not (plist-get (tty-fallback-test--report) :hinted))))))

;;;; The prefix

(defmacro tty-fallback-test--reading (events &rest body)
  "BODY where `read-event' returns EVENTS one by one (then nil, as a timeout), and the terminal decodes F6."
  (declare (indent 1))
  `(let ((queue ,events) (prompts nil)
         (input-decode-map (let ((m (make-sparse-keymap))) (define-key m "\e[17~" [f6]) m))
         (local-function-key-map (let ((m (make-sparse-keymap))) (define-key m "\e[Z" [backtab]) m)))
     (cl-letf (((symbol-function 'read-event) (lambda (&optional prompt &rest _) (push prompt prompts) (pop queue))))
       ,@body)))

(ert-deftest drgnx-tty-fallback/the-prefix-then-the-key ()
  (tty-fallback-test--with-terminal nil '("TERM=xterm-256color")
    (let ((drgnx-keys-last (list :bindings (tty-fallback-test--bindings "VS Code"))))
      ;; not a terminal with the layer: F6 is F6
      (should (equal (drgnx-tty-fallback--prefix nil) [f6]))
      (drgnx-tty-fallback-install (selected-frame) tty-fallback-test--legacy)
      (pcase-dolist (`(,events . ,chord)
                     `(((?p) . "C-S-p") ((?.) . "C-.") ((?`) . "C-`") ((?~) . "C-S-`") ((13) . "C-<return>")
                       ((?\e 13) . "C-S-<return>") ((9) . "C-<tab>") ((?\e ?\[ ?Z) . "C-S-<tab>") ((?\s) . "C-S-SPC")
                       ((0) . "C-SPC") ((?=) . "C-=") ((?+) . "C-+") ((?\e ?c) . "C-M-S-c") ((?P) . "C-S-p")
                       ((?x) . "C-S-x") ((?1) . "C-1")))
        (tty-fallback-test--reading events
          (should (equal (cons events (drgnx-tty-fallback--prefix nil)) (cons events (key-parse chord))))
          (should (equal (car (last prompts)) "Ctrl+Shift+…"))))
      ;; twice: F6 itself; ESC alone: nothing; C-g: C-g, so a pending prefix (C-x F6 C-g) quits too
      (tty-fallback-test--reading (list ?\e ?\[ ?1 ?7 ?~)
        (should (equal (drgnx-tty-fallback--prefix nil) [f6])))
      (tty-fallback-test--reading (list ?\C-g)
        (should (equal (drgnx-tty-fallback--prefix nil) [?\C-g])))
      (tty-fallback-test--reading (list ?\e)
        (should (equal (drgnx-tty-fallback--prefix nil) [])))
      ;; a click, a paste or a focus report after F6 is no key: F6 is dropped, and what was read of the
      ;; sequence goes back to the input in order, where Emacs decodes it whole (with the rest still unread)
      (pcase-dolist (`(,read ,rest) '(((?\e ?\[ ?<) (?0 ?\; ?5 ?\; ?5 ?M))              ; SGR mouse press
                                      ((?\e ?\[ ?2 ?0 ?0 ?~) (?h ?i ?\e ?\[ ?2 ?0 ?1 ?~)) ; bracketed paste
                                      ((?\e ?\[ ?I) ())                                ; focus in
                                      ((?\e ?\[ ?Q) ())))                              ; something unknown
        (tty-fallback-test--reading (append read rest)
          (let ((input-decode-map input-decode-map) (unread-command-events nil))
            (dolist (seq '("\e[<" "\e[200~" "\e[I")) (define-key input-decode-map seq (lambda (_) [ignore])))
            (should (equal (cons read (drgnx-tty-fallback--prefix nil)) (cons read [])))
            (should (equal unread-command-events read))
            (should (equal queue rest))))))))

;;;; Words

(ert-deftest drgnx-tty-fallback/keys-in-words ()
  (should (equal (mapcar #'drgnx-tty-fallback-label '("M-F" "<f6> p" "C-S-p" "M-#" "<f6> M-RET" "C-<return>" "<f6> C-@"))
                 '("Alt+Shift+F" "F6 p" "Ctrl+Shift+P" "Alt+Shift+3" "F6 Alt+Enter" "Ctrl+Enter" "F6 Ctrl+Space")))
  ;; the recommendation (core/drgnx-tty-recommend.el) says the same keys
  (should (string-match-p "Alt\\+Shift or F6 then the key (F6 p for Ctrl\\+Shift\\+P)" (drgnx-tty--fallback-hint)))
  (let ((drgnx-tty-chord-prefix "<f7>"))
    (should (string-match-p "or F7 then the key (F7 p" (drgnx-tty--fallback-hint)))
    (should (string-match-p "or F7 then the key" (drgnx-tty-fallback-hint-text)))))

(ert-deftest drgnx-tty-fallback/the-guide-has-the-table ()
  ;; docs/guide/terminal.md's VS Code table is the computed one: a row per chord, its Alt+Shift key and F6 form
  (let* ((doc (with-temp-buffer (insert-file-contents (expand-file-name "docs/guide/terminal.md" drgnx-dir)) (buffer-string)))
         (section (substring doc (string-search "## Legacy terminals: Alt+Shift and F6" doc)
                             (string-search "\n## SSH" doc)))
         (md (lambda (s) (if (string-search "`" s) (format "`` %s ``" s) (format "`%s`" s))))
         (table (tty-fallback-test--table "VS Code")))
    (pcase-dolist (`(,chord . ,row) table)
      (should (equal (list chord t)
                     (list chord (and (string-match-p
                                       (format "^| %s | [^|\n]+ | %s | %s |$" (regexp-quote (funcall md chord))
                                               (regexp-quote (if (plist-get row :alt) (funcall md (drgnx-tty-fallback-label (plist-get row :alt))) "—"))
                                               (regexp-quote (funcall md (drgnx-tty-fallback-label (plist-get row :prefix)))))
                                       section)
                                      t)))))
    (should (= (length table) (with-temp-buffer (insert section) (how-many "^| `" (point-min) (point-max)))))))

(ert-deftest drgnx-tty-fallback/facts-for-the-doctor ()
  (let ((report '(:terminals (("/dev/pts/3" :caps (:id vte :keys legacy) :fallback t
                               :fallbacks (("C-S-f" nil "M-F" "<f6> f") ("C-S-p" nil nil "<f6> p"))
                               :fallback-problems ("keys.eld :tty-fallback C-S-p → M-j not used: …"))
                              ("/dev/pts/4" :caps (:id kitty :keys kkp) :fallback nil
                               :fallbacks (("C-S-f" t nil nil))))
                             :hinted (vte))))
    (should (equal (drgnx-tty-fallback-facts report)
                   '((:tty "/dev/pts/3" :id vte :keys legacy :layer t
                           :rows (("C-S-f" nil "M-F" "<f6> f") ("C-S-p" nil nil "<f6> p"))
                           :problems ("keys.eld :tty-fallback C-S-p → M-j not used: …"))
                     (:tty "/dev/pts/4" :id kitty :keys kkp :layer nil :rows (("C-S-f" t nil nil)) :problems nil))))))

(provide 'tty-fallback-test)
;;; tty-fallback-test.el ends here
