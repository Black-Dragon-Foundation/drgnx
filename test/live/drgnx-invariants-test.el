;;; drgnx-invariants-test.el --- live: the workbench invariants I1–I10 (config=drgnx) -*- lexical-binding: t -*-
;; Each test drives a GUI session with real input (VS Code key profile), the jank guard on.
;; The invariants are listed in docs/workbench.md.
(require 'ert)
(require 'seq)
(require 'drgnx-ui)

(defconst drgnx-inv--probe
  "(drgnx-uitest--json
     (let ((p (drgnx-wb-area-window 'panel)) (r (drgnx-wb-area-window 'right)) (e (drgnx-wb-section-window 'explorer)))
       (list :geometry (format \"%S\" (sort (mapcar #'window-pixel-edges (window-list nil 'nomini))   ; any order
                                            (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b)))))))
             :frames (length (frame-list))
             :editors (length (seq-filter #'drgnx-signal-editor-window-p (window-list nil 'nomini)))
             :panel (if p (window-pixel-height p) 0) :right (if r (window-pixel-width r) 0)
             :left (if e (window-pixel-width e) 0)
             :root (window-pixel-height (frame-root-window))
             :body (window-body-height (drgnx-wb-editor-window) t)
             :unrouted (vconcat (mapcar (lambda (u) (format \"%s (%s)\" (plist-get u :buffer) (plist-get u :mode))) drgnx-wb-unrouted))
             :guard (length drgnx-jank-guard-log)
             :editor-ok (with-current-buffer (window-buffer (drgnx-wb-editor-window))
                          (if (or buffer-file-name
                                  (derived-mode-p 'dired-mode 'Buffer-menu-mode 'ibuffer-mode 'Custom-mode 'proced-mode
                                                  'edit-abbrevs-mode 'bookmark-bmenu-mode 'command-history-mode 'lisp-interaction-mode))
                              t (format \"%s (%s)\" (buffer-name) major-mode))))))"
  "The layout facts the invariants are about.")

(defmacro drgnx-inv--with (sess &rest body)
  "BODY with SESS a fresh GUI session (config=drgnx) whose editor shows a fixture project's file."
  (declare (indent 1))
  `(let* ((root (make-temp-file "drgnx-inv" t))
          (project (file-name-as-directory (expand-file-name "project" root)))
          (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
          (s (progn
               (dolist (f '("src/app/main.py" "src/app/util.py" "src/lib/a.py" "docs/guide.md" "README.md"))
                 (make-directory (file-name-directory (expand-file-name f project)) t)
                 (write-region (format "%s\n" f) nil (expand-file-name f project) nil 'silent))
               (make-directory (expand-file-name ".git" project))
               (drgnx-ui-start "drgnx" "1400x800" 30)))
          (,sess (drgnx-ui-own-session (plist-get s :name))))
     (unwind-protect
         (progn
           (drgnx-ui-call ,sess (format "(progn (find-file %S) (drgnx-explorer-set-roots (list %S))
                                                (drgnx-uitest--json (list :ok t)))"
                                        (expand-file-name "README.md" project) project))
           (drgnx-ui-measure ,sess nil)
           ,@body)
       (drgnx-ui-stop (plist-get s :name))
       (delete-directory root t))))

(defun drgnx-inv--probe (sess) (drgnx-ui-call sess drgnx-inv--probe))

(defun drgnx-inv--clean-report-p (r)
  "I1, I9, I10 for one measured step: no collateral move, no oscillation, no guard violation,
settled within 250 ms."
  (and (eq (plist-get r :settled) t)
       (= 0 (plist-get r :collateral_moves)) (= 0 (plist-get r :oscillations))
       (= 0 (plist-get r :guard_violations)) (<= (plist-get r :settle_ms) 250)))

(ert-deftest drgnx-inv/i1-i9-i10-explorer-and-buffers-flows ()
  (drgnx-inv--with sess
    (drgnx-ui-measure sess (list (list :keys "C-b")))
    (let (bad)
      (dolist (steps (list (list (list :keys "C-S-e"))
                           (list (list :keys "<down>")) (list (list :keys "<down>")) (list (list :keys "<right>"))
                           (list (list :keys "<down>")) (list (list :keys "<down>")) (list (list :keys "<up>"))
                           (list (list :keys "SPC"))            ; open, stay in the Explorer
                           (list (list :keys "C-k e"))          ; focus Buffers
                           (list (list :keys "<down>")) (list (list :keys "RET"))
                           (list (list :keys "C-S-e")) (list (list :keys "<escape>"))))
        (let ((r (drgnx-ui-measure sess steps)))
          (unless (drgnx-inv--clean-report-p r)
            (push (list steps :collateral (plist-get r :collateral) :osc (plist-get r :oscillations)
                        :settle (plist-get r :settle_ms) :guard (plist-get r :guard))
                  bad))))
      (should-not bad)
      ;; The flow did happen: the last steps went Buffers → RET (an editor) → Explorer → Escape (an editor).
      (should (equal (plist-get (drgnx-ui-call sess "(drgnx-uitest--json (list :role (format \"%s\" (window-parameter (selected-window) 'drgnx-role)) :mru (if (eq (selected-window) (drgnx-wb-editor-window)) t :false)))") :mru)
                     t)))))

(ert-deftest drgnx-inv/i2-every-area-keeps-its-size ()
  (drgnx-inv--with sess
    (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-`") (list :keys "C-M-b")))
    (drgnx-ui-call sess "(progn (require 'transient)
                                (transient-define-prefix drgnx-inv-tr () [(\"a\" \"Do A\" ignore)])
                                (keymap-global-set \"<f19>\" #'drgnx-inv-tr) (drgnx-uitest--json (list :ok t)))")
    (let ((first (drgnx-inv--probe sess)))
      (should (> (plist-get first :panel) 0))
      (dotimes (_ 10)
        (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-b") (list :keys "C-`") (list :keys "C-`")
                                     (list :keys "C-M-b") (list :keys "C-M-b"))))
      (drgnx-ui-measure sess (list (list :keys "C-h f") (list :type "car") (list :keys "RET")))   ; a tab switch
      (drgnx-ui-measure sess (list (list :keys "<f19>")))                                       ; a popup
      (let ((open (drgnx-inv--probe sess)))
        (should (equal (plist-get open :geometry) (plist-get first :geometry))))
      (drgnx-ui-measure sess (list (list :keys "C-g")))
      (let ((after (drgnx-inv--probe sess)))
        (dolist (k '(:left :panel :right :geometry))
          (should (equal (plist-get after k) (plist-get first k))))
        (should (= 0 (plist-get after :guard)))))))

(ert-deftest drgnx-inv/i4-buffer-switches-and-messages-keep-the-rows ()
  (drgnx-inv--with sess
    (drgnx-ui-measure sess (list (list :keys "C-`")))
    (drgnx-ui-call sess "(progn (find-file-noselect (expand-file-name \"docs/guide.md\" (car drgnx-explorer--roots)))
                                (drgnx-uitest--json (list :ok t)))")
    (let ((first (drgnx-inv--probe sess)))
      (dotimes (_ 20) (drgnx-ui-measure sess (list (list :keys "C-x b") (list :keys "RET"))))
      (let ((after (drgnx-inv--probe sess)))
        (should (= (plist-get after :body) (plist-get first :body)))
        (should (= (plist-get after :root) (plist-get first :root))))
      (drgnx-ui-call sess "(progn (message \"one\\ntwo\\nthree\") (drgnx-uitest--json (list :ok t)))")
      (drgnx-ui-measure sess nil)
      (let ((after (drgnx-inv--probe sess)))
        (should (equal (plist-get after :geometry) (plist-get first :geometry)))))))

(ert-deftest drgnx-inv/i5-which-key-leaves-no-trace ()
  (drgnx-inv--with sess
    (drgnx-ui-call sess "(progn (setq which-key-idle-delay 0.1) (which-key-mode 1) (drgnx-uitest--json (list :ok t)))")
    (dolist (panel '(nil t))
      (when panel (drgnx-ui-measure sess (list (list :keys "C-`"))))
      (let ((before (drgnx-inv--probe sess)))
        (drgnx-ui-measure sess (list (list :keys "C-x")) 400)
        (should (eq t (plist-get (drgnx-ui-call sess "(drgnx-uitest--json (list :shown (if (get-buffer-window \" *which-key*\") t :false)))") :shown)))
        (drgnx-ui-measure sess (list (list :keys "C-g")))
        (should (equal (plist-get (drgnx-inv--probe sess) :geometry) (plist-get before :geometry)))))))

(defconst drgnx-inv--fuzz-file
  (expand-file-name "../fixtures/fuzz-commands.eld" (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest drgnx-inv/i8-fuzz-of-fifty-commands ()
  ;; No window splits or resizes, no frame appears, every buffer routed (the "day in the life" run).
  (let ((forms (with-temp-buffer (insert-file-contents drgnx-inv--fuzz-file) (read (current-buffer)))))
    (should (= 50 (length forms)))
    (drgnx-inv--with sess
      (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-`") (list :keys "C-M-b")))
      (drgnx-ui-call sess (format "(progn (setq drgnx-inv--forms '%S)
                                          (setq drgnx-inv--errors nil)
                                          (keymap-global-set \"<f11>\" (lambda () (interactive)
                                            (let ((form (pop drgnx-inv--forms)))
                                              (condition-case err (eval form t)
                                                (error (push (format \"%%S: %%S\" form err) drgnx-inv--errors))))))
                                          (drgnx-uitest--json (list :ok t)))"
                                  forms))
      (let ((first (drgnx-inv--probe sess)) bad)
        (dolist (form forms)
          (let* ((r (drgnx-ui-measure sess (list (list :keys "<f11>"))))
                 (after (progn
                          ;; A popup (the calendar) stays until dismissed: dismiss it, as a user would;
                          ;; it must leave no trace (I5).
                          (drgnx-ui-call sess "(progn (when (drgnx-popup-active-p) (delete-window (drgnx-popup--window)))
                                                      (drgnx-uitest--json (list :ok t)))")
                          (drgnx-inv--probe sess))))
            (unless (and (equal (plist-get after :geometry) (plist-get first :geometry))
                         (= (plist-get after :frames) (plist-get first :frames))
                         (= (plist-get after :editors) 1)
                         (eq (plist-get after :editor-ok) t)        ; only files and their kind in the editor
                         (= 0 (plist-get r :guard_violations)))
              (push (list form :geometry (plist-get after :geometry) :editor (plist-get after :editor-ok)
                          :guard (plist-get r :guard))
                    bad))))
        (should-not bad)
        (should (equal (plist-get (drgnx-ui-call sess "(drgnx-uitest--json (list :errors (vconcat drgnx-inv--errors)))") :errors)
                       []))                                      ; every form ran
        (should (equal (plist-get (drgnx-inv--probe sess) :unrouted) []))
        (should (= 0 (plist-get (drgnx-inv--probe sess) :guard)))))))

(ert-deftest drgnx-inv/i3-chrome-height-depends-on-the-role-only ()
  ;; The editor shows a file, then ibuffer (its own header line), then *scratch*: same chrome heights.
  (drgnx-inv--with sess
    (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-`")))
    (let* ((q "(drgnx-uitest--json (let ((e (drgnx-wb-editor-window)) (p (drgnx-wb-area-window 'panel)))
                 (list :editor (vector (window-tab-line-height e) (window-header-line-height e) (window-mode-line-height e))
                       :panel (vector (window-tab-line-height p) (window-header-line-height p) (window-mode-line-height p)))))")
           (first (drgnx-ui-call sess q)))
      (should (seq-every-p #'cl-plusp (plist-get first :editor)))
      (should (= 0 (aref (plist-get first :panel) 2)))                  ; no mode line in the panel
      (dolist (form '("(ibuffer)" "(switch-to-buffer \"*scratch*\")"))
        (drgnx-ui-call sess (format "(progn (select-window (drgnx-wb-editor-window)) %s (drgnx-uitest--json (list :ok t)))" form))
        (drgnx-ui-measure sess nil)
        (should (equal (drgnx-ui-call sess q) first))))))

(ert-deftest drgnx-inv/i2-sizes-survive-a-restart ()
  ;; Session A: dock, panel and right dock shown and resized; it exits (the exit hook saves).
  ;; Session B restores the same file: identical pixel sizes, the panel on the same tab.
  (let* ((root (make-temp-file "drgnx-restart" t))
         (file (expand-file-name "workbench.eld" root))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (q "(drgnx-uitest--json (let ((d (car (drgnx-wb--dock-windows))) (p (drgnx-wb-area-window 'panel)) (r (drgnx-wb-area-window 'right)))
               (list :left (if d (window-pixel-width d) 0) :panel (if p (window-pixel-height p) 0) :right (if r (window-pixel-width r) 0)
                     :tab (format \"%s\" (drgnx-wb-area-tab 'panel)))))")
         first)
    (unwind-protect
        (let* ((s (drgnx-ui-start "drgnx" "1400x800" 30)) (sess (drgnx-ui-own-session (plist-get s :name))))
          (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-`") (list :keys "C-M-b")))
          (drgnx-ui-call sess (format "(let ((window-resize-pixelwise t))
                                         (setq drgnx-persist-file %S)
                                         (window-resize (car (drgnx-wb--dock-windows)) 37 t nil t)
                                         (window-resize (drgnx-wb-area-window 'panel) 23 nil nil t)
                                         (drgnx-wb-area-show 'panel 'results)
                                         (drgnx-uitest--json (list :ok t)))" file))
          (drgnx-ui-measure sess nil)
          (setq first (drgnx-ui-call sess q))
          (drgnx-ui-stop (plist-get s :name))
          (should (file-exists-p file))
          (let* ((s2 (drgnx-ui-start "drgnx" "1400x800" 30)) (sess2 (drgnx-ui-own-session (plist-get s2 :name))))
            (unwind-protect
                (progn
                  (drgnx-ui-call sess2 (format "(progn (setq drgnx-persist-file %S) (drgnx-persist-restore) (drgnx-uitest--json (list :ok t)))" file))
                  (drgnx-ui-measure sess2 nil)
                  (should (equal (drgnx-ui-call sess2 q) first)))
              (drgnx-ui-stop (plist-get s2 :name)))))
      (delete-directory root t))))

(ert-deftest drgnx-inv/two-monitors ()
  ;; A two-monitor session, a window on each frame: chrome by role (I3), the sidebar ±0 px over five
  ;; toggles (I2), keys with no collateral move and no guard violation (I1, I9), on both windows.
  (let* ((root (make-temp-file "drgnx-2mon" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" "1280x800" 30 nil 2))
         (sess (drgnx-ui-own-session (plist-get s :name))))
    (unwind-protect
        (progn
          (should (= 2 (plist-get (drgnx-ui-call sess "(drgnx-uitest--json (list :n (length (display-monitor-attributes-list))))") :n)))
          (drgnx-ui-call sess "(progn (defvar kx-frames (list (selected-frame) (make-frame))) (drgnx-uitest--json (list :ok t)))")
          (drgnx-ui-measure sess nil)
          (dotimes (i 2)
            (drgnx-ui-call sess (format "(progn (select-frame-set-input-focus (nth %d kx-frames)) (drgnx-uitest--json (list :ok t)))" i))
            (drgnx-ui-measure sess (list (list :keys "C-b")))
            (let* ((q "(drgnx-uitest--json (let* ((f (selected-frame)) (e (car (drgnx-groups-list f))) (d (car (drgnx-wb--dock-windows f))))
                         (list :editor (vector (window-tab-line-height e) (window-header-line-height e) (window-mode-line-height e))
                               :dock (if d (window-pixel-width d) 0))))")
                   (first (drgnx-ui-call sess q)))
              (should (seq-every-p #'cl-plusp (plist-get first :editor)))
              (should (> (plist-get first :dock) 0))
              (dotimes (_ 5) (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-b"))))
              (should (equal (drgnx-ui-call sess q) first))
              (let ((r (drgnx-ui-measure sess (list (list :keys "C-S-e") (list :keys "<down>") (list :keys "<escape>")))))
                (should (equal (list i (plist-get r :collateral)) (list i [])))
                (should (= 0 (plist-get r :guard_violations)))))))
      (drgnx-ui-stop (plist-get s :name))
      (delete-directory root t))))
