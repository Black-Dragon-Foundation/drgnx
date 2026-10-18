;;; wb-state-test.el --- batch tests: the workbench state store (classifier, roles, records, observer, reads) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'bytecomp)
(require 'drgnx-paths)
(require 'drgnx-modules)
(require 'drgnx-signal)
(require 'drgnx-panes)                                 ; `drgnx-pane--last': editor kinds
(require 'drgnx-run-ert "run-ert")                     ; `drgnx-run-ert-time-factor'
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)

;;;; Windows for the tests

(defun drgnx-state-test--clean ()
  "One plain window on the selected frame, without drgnx parameters; the test buffers killed."
  (let ((ignore-window-parameters t))
    (when-let* ((main (seq-find (lambda (w) (not (window-parameter w 'window-side))) (window-list nil 'nomini))))
      (select-window main))
    (dolist (w (window-list nil 'nomini))
      (when (and (window-live-p w) (window-parameter w 'window-side)) (delete-window w)))
    (delete-other-windows))
  (dolist (p '(drgnx-role drgnx-popup drgnx-section drgnx-layouts-pane))
    (set-window-parameter nil p nil))
  (set-window-dedicated-p nil nil)
  (dolist (p '(drgnx-wb-areas drgnx-frame-role drgnx-monitor))
    (set-frame-parameter nil p nil))
  (dolist (b (buffer-list))
    (when (string-prefix-p " *st-" (buffer-name b)) (kill-buffer b)))
  (switch-to-buffer "*scratch*"))

(defmacro drgnx-state-test--with (&rest body)
  "BODY with a fresh store and bus (`drgnx-test-with-state') and one plain window, cleaned up after."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-state
     (unwind-protect (progn (drgnx-state-test--clean) ,@body)
       (drgnx-state-test--clean))))

(defun drgnx-state-test--buffer (name)
  (get-buffer-create (format " *st-%s*" name)))

(defun drgnx-state-test--side (buffer side slot params &optional size)
  "Show BUFFER in a side window on SIDE at SLOT with window PARAMS; return the window."
  (display-buffer-in-side-window
   buffer `((side . ,side) (slot . ,slot)
            (,(if (memq side '(left right)) 'window-width 'window-height) . ,(or size 6))
            (window-parameters . ,params))))

(defun drgnx-state-test--workbench ()
  "The spec's 7-window frame: 3 dock sections, 2 editor groups, the panel and the right dock.
Returns an alist NAME → window, NAME one of buffers explorer outline g1 g2 panel right."
  (let* ((g1 (selected-window))
         (docks (cl-loop for name in '(buffers explorer outline) for slot from 0
                         collect (cons name (drgnx-state-test--side
                                             (drgnx-state-test--buffer name) 'left slot
                                             `((drgnx-role . dock) (drgnx-section . ,name)) 22))))
         (panel (drgnx-state-test--side (drgnx-state-test--buffer "terminal") 'bottom 0 '((drgnx-role . panel)) 6))
         (right (drgnx-state-test--side (drgnx-state-test--buffer "agents") 'right 0 '((drgnx-role . right)) 16))
         (g2 (split-window g1 nil 'right)))
    (set-window-buffer g1 (drgnx-state-test--buffer "a.txt"))
    (set-window-buffer g2 (drgnx-state-test--buffer "b.txt"))
    (set-frame-parameter nil 'drgnx-wb-areas '((panel :tab terminal) (right :tab agents)))
    (append docks (list (cons 'g1 g1) (cons 'g2 g2) (cons 'panel panel) (cons 'right right)))))

(defun drgnx-state-test--record (frame)
  "Observe FRAME (`drgnx-state-sync') and return the store's own record of it (sync returns a copy)."
  (drgnx-state-sync frame)
  (gethash frame drgnx-state--frames))

(defun drgnx-state-test--edges (w)
  (list (window-pixel-left w) (window-pixel-top w) (window-pixel-width w) (window-pixel-height w)))

(defconst drgnx-state-test--hot
  '(drgnx-state--observe drgnx-state--same-p drgnx-state--same-windows-p drgnx-state--classify
                         drgnx-state-frame-kind drgnx-state-workbench-frame-p)
  "The functions a keystroke that changes no window runs.")

(defun drgnx-state-test--compile ()
  "Byte-compile the per-keystroke functions (the tests load drgnx from source): measure what users run."
  (dolist (f drgnx-state-test--hot)
    (unless (compiled-function-p (symbol-function f))
      (let ((byte-compile-warnings nil)) (byte-compile f)))))

;;;; The frame classifier

(ert-deftest drgnx-state/frame-kinds ()
  (let ((f (selected-frame)))
    (should (eq 'tty (drgnx-state-frame-kind f)))       ; batch: "initial_terminal", but noninteractive
    (should (drgnx-state-workbench-frame-p f))
    (cl-letf (((symbol-function 'frame-parent) (lambda (&optional _) f)))
      (should (eq 'child (drgnx-state-frame-kind f)))
      (should-not (drgnx-state-workbench-frame-p f)))
    (let ((noninteractive nil))
      (should (eq 'initial (drgnx-state-frame-kind f)))
      (should-not (drgnx-state-workbench-frame-p f)))
    (cl-letf (((symbol-function 'terminal-name) (lambda (&optional _) "/dev/pts/3")))
      (should (eq 'tty (drgnx-state-frame-kind f)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t)))
        (should (eq 'gui (drgnx-state-frame-kind f)))
        (should (drgnx-state-workbench-frame-p f)))
      ;; a minibuffer-only frame: its root window is its minibuffer window
      (cl-letf (((symbol-function 'frame-root-window) (lambda (&optional _) (minibuffer-window f))))
        (should (eq 'other (drgnx-state-frame-kind f)))
        (should-not (drgnx-state-workbench-frame-p f))))
    (should-not (drgnx-state-frame-kind 'not-a-frame))
    (cl-letf (((symbol-function 'frame-live-p) #'ignore))
      (should-not (drgnx-state-frame-kind f)))))

;;;; The snapshot

(ert-deftest drgnx-state/snapshot-of-a-workbench ()
  (drgnx-state-test--with
    (let* ((ws (drgnx-state-test--workbench)) (f (selected-frame)) (rec (drgnx-state-sync f)))
      (should rec)
      (should (= 7 (length (drgnx-state-windows f))))
      (should (equal (window-list f 'nomini (frame-first-window f)) (drgnx-state-windows f)))
      (pcase-dolist (`(,name ,role ,kind) '((buffers dock buffers) (explorer dock explorer) (outline dock outline)
                                            (g1 editor nil) (g2 editor nil) (panel panel terminal) (right right agents)))
        (let ((w (alist-get name ws)))
          (should (eq role (drgnx-state-window-role w)))
          (should (equal (drgnx-state-test--edges w) (drgnx-state-edges w)))
          (when kind (should (eq w (drgnx-state-pane-window kind f))))))
      (let ((kinds '(buffers explorer outline terminal agents)))
        (should (equal kinds (sort (copy-sequence (drgnx-state-shown-kinds f))
                                   (lambda (a b) (< (cl-position a kinds) (cl-position b kinds)))))))
      (should (drgnx-state-pane-shown-p 'terminal f))
      (should-not (drgnx-state-pane-shown-p 'problems f))
      (should (equal (list (alist-get 'buffers ws) (alist-get 'explorer ws) (alist-get 'outline ws))
                     (sort (drgnx-state-windows f 'dock)
                           (lambda (a b) (< (window-pixel-top a) (window-pixel-top b))))))
      (should (equal (list (alist-get 'g1 ws) (alist-get 'g2 ws)) (drgnx-state-windows f 'editor)))
      (should (eq (selected-window) (drgnx-state-selected-window f)))
      (should (eq (alist-get 'g1 ws) (drgnx-state-editor-window f)))
      (should (equal (list :cols (frame-text-cols f) :lines (frame-text-lines f)
                           :width (frame-pixel-width f) :height (frame-pixel-height f))
                     (drgnx-state-frame-size f)))
      (should (equal (list f) (drgnx-state-frames)))
      (should (equal (list f) (drgnx-state-frames 'tty)))
      (should-not (drgnx-state-frames 'gui))
      (should-not (drgnx-state-main-frame))
      (set-frame-parameter f 'drgnx-frame-role 'main)
      (drgnx-state-sync f)
      (should (eq f (drgnx-state-main-frame))))))

(ert-deftest drgnx-state/roles-come-from-the-table ()
  (drgnx-state-test--with
    (let* ((w (selected-window)) (strip (split-window w nil 'below)))
      (set-window-parameter strip 'drgnx-role 'st-strip)
      (drgnx-state-sync)
      (should (eq 'editor (drgnx-state-window-role strip)))   ; a role nobody defined is an editor's
      (should (eq 'st-strip (drgnx-state-define-role 'st-strip :chrome 'lane)))
      (should (eq 'lane (drgnx-state-role-chrome 'st-strip)))
      (drgnx-state-sync)
      (should (eq 'st-strip (drgnx-state-window-role strip)))
      (should (equal (list w) (drgnx-state-windows (selected-frame) 'editor)))
      (should (eq 'dock (drgnx-state-role-chrome 'dock)))
      (should (eq 'area (drgnx-state-role-chrome 'panel)))
      (should (eq 'area (drgnx-state-role-chrome 'right)))
      (should (eq 'lane (drgnx-state-role-chrome 'popup)))
      (should-error (drgnx-state-define-role 'st-bad :chrome 'nowhere))
      (should (drgnx-state-undefine-role 'st-strip))
      (should-not (assq 'st-strip drgnx-state--roles))
      (drgnx-state-sync)
      (should (eq 'editor (drgnx-state-window-role strip))))))

(ert-deftest drgnx-state/a-side-window-without-a-role-is-side ()
  (drgnx-state-test--with
    (let ((side (drgnx-state-test--side (drgnx-state-test--buffer "help") 'bottom 0 nil)))
      (drgnx-state-sync)
      (should (eq 'side (drgnx-state-window-role side)))
      (should-not (memq side (drgnx-state-windows (selected-frame) 'editor)))
      ;; the minibuffer has no role, and a window of a frame not observed yet is classified live
      (should-not (drgnx-state-window-role (minibuffer-window)))
      (clrhash drgnx-state--frames)
      (should (eq 'side (drgnx-state-window-role side)))
      (should (eq 'editor (drgnx-state-window-role (selected-window)))))))

(ert-deftest drgnx-state/a-borrowed-panel-reads-as-popup ()
  (drgnx-state-test--with
    (let ((ws (drgnx-state-test--workbench)) (f (selected-frame)))
      (drgnx-state-sync)
      (should (drgnx-state-pane-shown-p 'terminal f))
      ;; a popup borrows the panel: the window keeps its `drgnx-role' and carries `drgnx-popup'
      (let ((panel (alist-get 'panel ws)))
        (set-window-parameter panel 'drgnx-popup (list :borrowed t :popup (current-buffer)))
        (set-window-buffer panel (drgnx-state-test--buffer "grep"))
        (drgnx-state-sync)
        (should (eq 'popup (drgnx-state-window-role panel)))
        (should (equal (list panel) (drgnx-state-windows f 'popup)))
        (should-not (drgnx-state-pane-shown-p 'terminal f))))))

;;;; Ownership: roles defined by a module go with it

(defmacro drgnx-state-test--with-modules (&rest body)
  "BODY with fresh module tables and claims, and an empty config dir (fake modules only)."
  (declare (indent 0) (debug t))
  `(let* ((cfg (make-temp-file "drgnx-cfg" t))
          (process-environment (cons (concat "DRGNX_CONFIG_DIR=" cfg) process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil) (drgnx-modules--state nil)
          (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
          (drgnx-module--claims (make-hash-table :test 'equal)))
     (unwind-protect (progn ,@body) (delete-directory cfg t))))

(defun drgnx-state-test--setup (name setup)
  "Run SETUP as fake module NAME's, through the recorder, and mark it running."
  (setf (alist-get name drgnx-modules--table) (list :doc "test" :stage 'startup :setup setup))
  (should-not (drgnx-modules--run-setup name setup))
  (drgnx-modules--record name 'startup 0 'ok))

(ert-deftest drgnx-state/define-role-pushes-its-undo ()
  (drgnx-state-test--with
    (drgnx-state-test--with-modules
      (drgnx-state-test--setup 'test/state-a (lambda () (drgnx-state-define-role 'st-role :chrome 'lane)))
      (should (equal '("state role st-role") (mapcar #'car (alist-get 'test/state-a drgnx-modules--stacks))))
      (should (eq 'lane (drgnx-state-role-chrome 'st-role)))
      (should-not (drgnx-module-teardown 'test/state-a))
      (should-not (assq 'st-role drgnx-state--roles))
      ;; a module that redefines a built-in role gives it back
      (drgnx-state-test--setup 'test/state-b (lambda () (drgnx-state-define-role 'dock :chrome 'lane)))
      (should (eq 'lane (drgnx-state-role-chrome 'dock)))
      (should-not (drgnx-module-teardown 'test/state-b))
      (should (eq 'dock (drgnx-state-role-chrome 'dock)))
      ;; a role defined outside a setup (at load) records nothing
      (drgnx-state-define-role 'st-core :chrome nil)
      (should-not drgnx-modules--stacks))))

(ert-deftest drgnx-state/a-role-another-module-redefined-stays ()
  (drgnx-state-test--with
    (drgnx-state-test--with-modules
      (drgnx-state-test--setup 'test/state-a (lambda () (drgnx-state-define-role 'st-role :chrome 'lane)))
      (drgnx-state-test--setup 'test/state-b (lambda () (drgnx-state-define-role 'st-role :chrome 'area)))
      (should-not (drgnx-module-teardown 'test/state-a))  ; the older one first: b's stays
      (should (eq 'area (drgnx-state-role-chrome 'st-role)))
      (should-not (drgnx-module-teardown 'test/state-b))  ; then nothing: there was none before a
      (should-not (assq 'st-role drgnx-state--roles))
      ;; the other order
      (drgnx-state-test--setup 'test/state-a (lambda () (drgnx-state-define-role 'st-role :chrome 'lane)))
      (drgnx-state-test--setup 'test/state-b (lambda () (drgnx-state-define-role 'st-role :chrome 'area)))
      (should-not (drgnx-module-teardown 'test/state-b))
      (should (eq 'lane (drgnx-state-role-chrome 'st-role)))
      (should-not (drgnx-module-teardown 'test/state-a))
      (should-not (assq 'st-role drgnx-state--roles))
      ;; a role changed by hand since is left alone by the undo
      (drgnx-state-test--setup 'test/state-a (lambda () (drgnx-state-define-role 'st-role :chrome 'lane)))
      (drgnx-state-define-role 'st-role :chrome 'dock)
      (should-not (drgnx-module-teardown 'test/state-a))
      (should (eq 'dock (drgnx-state-role-chrome 'st-role))))))

;;;; The MRU editor

(ert-deftest drgnx-state/mru-editor-rule ()
  (drgnx-state-test--with
    (let* ((a (selected-window)) (b (split-window a nil 'right)) (c (split-window b nil 'right))
           (dock (drgnx-state-test--side (drgnx-state-test--buffer "explorer") 'left 0
                                         '((drgnx-role . dock) (drgnx-section . explorer)) 12))
           (f (selected-frame)))
      ;; 1. the selected window, when it is an editor
      (select-window c) (drgnx-state-sync)
      (should (eq c (drgnx-state-editor-window f)))
      (select-window b) (drgnx-state-sync)
      (should (eq b (drgnx-state-editor-window f)))
      ;; 2. the dock is selected: the previous editor, while it lives — even when another one (b) was used later
      (select-window dock) (drgnx-state-sync)
      (should (eq b (drgnx-state-editor-window f)))
      (drgnx-state-use-editor c)
      (set-window-buffer a (drgnx-state-test--buffer "other")) ; a change: the record is taken anew
      (should (drgnx-state--observe f))
      (should (eq c (drgnx-state-editor-window f)))
      ;; 3. it was deleted: the editor used most recently (b), not the first one (a)
      (delete-window c) (drgnx-state-sync)
      (should (eq b (drgnx-state-editor-window f)))
      ;; 4. no editor window at all
      (set-window-parameter a 'drgnx-role 'panel)
      (set-window-parameter b 'drgnx-role 'right)
      (drgnx-state-sync)
      (should-not (drgnx-state-editor-window f)))))

(ert-deftest drgnx-state/use-editor-sets-without-selecting ()
  (drgnx-state-test--with
    (let* ((ws (drgnx-state-test--workbench)) (f (selected-frame))
           (g1 (alist-get 'g1 ws)) (g2 (alist-get 'g2 ws)) (dock (alist-get 'explorer ws)))
      (select-window dock)
      (drgnx-state-sync)
      (should (eq g1 (drgnx-state-editor-window f)))
      (should (eq g2 (drgnx-state-use-editor g2)))
      (should (eq dock (selected-window)))
      (should (eq g2 (drgnx-state-editor-window f)))
      (should (eq g2 (drgnx-state-editor-window f)))      ; the next observation keeps it
      (drgnx-state-sync)
      (should (eq g2 (drgnx-state-editor-window f)))
      ;; not an editor: nil, nothing changes
      (should-not (drgnx-state-use-editor (alist-get 'panel ws)))
      (should-not (drgnx-state-use-editor (minibuffer-window)))
      (should (eq g2 (drgnx-state-editor-window f)))
      ;; the fixture helper does the same (and, until the bus moves, sets its variable)
      (should (eq g1 (drgnx-test-use-editor g1)))
      (should (eq g1 (drgnx-state-editor-window f)))
      (should (eq g1 drgnx-signal--editor-window)))))

(ert-deftest drgnx-state/same-buffer-other-window-is-a-new-editor ()
  (drgnx-state-test--with
    (let* ((a (selected-window)) (b (split-window a nil 'right)) (f (selected-frame)))
      (should (eq (window-buffer a) (window-buffer b)))
      (drgnx-state-sync)
      (should (eq a (drgnx-state-editor-window f)))
      (select-window b)
      (should (drgnx-state--observe f))                ; the selected window changed: rebuilt
      (should (eq b (drgnx-state-editor-window f)))
      (should (eq b (drgnx-state-selected-window f))))))

;;;; The observer

(ert-deftest drgnx-state/a-role-set-on-an-existing-window-is-seen ()
  (drgnx-state-test--with
    (let* ((a (selected-window)) (b (split-window a nil 'below)))
      (drgnx-state-sync)
      (should (eq 'editor (drgnx-state-window-role b)))
      (set-window-parameter b 'drgnx-role 'panel)       ; no window state change: only the in-place check sees it
      (drgnx-state-sync)
      (should (eq 'panel (drgnx-state-window-role b)))
      (set-window-parameter b 'drgnx-popup '(:borrowed t))
      (drgnx-state-sync)
      (should (eq 'popup (drgnx-state-window-role b))))))

(ert-deftest drgnx-state/frame-parameters-are-compared-at-sync ()
  ;; `frame-parameter' copies every parameter of the frame to read one of ours: the per-command check skips
  ;; them; their writers call `drgnx-state-sync', which compares them.
  (drgnx-state-test--with
    (let* ((f (selected-frame)) (rec (drgnx-state-test--record f)))
      (set-frame-parameter f 'drgnx-frame-role 'main)
      (should-not (drgnx-state--observe f))
      (should (eq rec (gethash f drgnx-state--frames)))
      (should-not (drgnx-state-main-frame))
      (should-not (eq rec (drgnx-state-test--record f)))
      (should (eq f (drgnx-state-main-frame)))
      (set-frame-parameter f 'drgnx-monitor '(:name "DP-1"))
      (should (equal '(:name "DP-1") (drgnx-state--fr-monitor (drgnx-state-sync f)))))))

(ert-deftest drgnx-state/the-in-place-check-sees-dedication-and-kinds ()
  ;; none of these is a window state change for Emacs, and none changes a buffer
  (drgnx-state-test--with
    (let* ((ws (drgnx-state-test--workbench)) (f (selected-frame))
           (g1 (alist-get 'g1 ws)) (g2 (alist-get 'g2 ws)) (dock (alist-get 'outline ws)))
      (drgnx-state-sync f)
      (set-window-dedicated-p g1 t)
      (should (drgnx-state--observe f))
      (set-window-parameter dock 'drgnx-section 'st-symbols)
      (should (drgnx-state--observe f))
      (should (eq dock (drgnx-state-pane-window 'st-symbols f)))
      (should-not (drgnx-state-pane-window 'outline f))
      (set-window-parameter g1 'drgnx-layouts-pane 'agent)
      (should (drgnx-state--observe f))
      (should (eq g1 (drgnx-state-pane-window 'agent f)))
      (unwind-protect
          (progn
            (puthash f (list (cons 'st-notes (window-buffer g2))) drgnx-pane--last)
            (should (drgnx-state--observe f))
            (should (eq g2 (drgnx-state-pane-window 'st-notes f))))
        (remhash f drgnx-pane--last))
      (should (drgnx-state--observe f))
      (should-not (drgnx-state-pane-window 'st-notes f))
      (should-not (drgnx-state--observe f)))))

(defvar drgnx-state-test--puts nil "(OLD-EDITOR NEW-EDITOR) per record replaced, newest first.")

(defun drgnx-state-test--note-put (_frame old new)
  (push (list (and old (drgnx-state--fr-editor old)) (drgnx-state--fr-editor new)) drgnx-state-test--puts))

(ert-deftest drgnx-state/records-are-replaced-in-one-place ()
  (drgnx-state-test--with
    (setq drgnx-state-test--puts nil)
    (advice-add 'drgnx-state--put :before #'drgnx-state-test--note-put)
    (unwind-protect
        (let* ((a (selected-window)) (b (split-window a nil 'right)) (f (selected-frame))
               (dock (drgnx-state-test--side (drgnx-state-test--buffer "explorer") 'left 0
                                             '((drgnx-role . dock) (drgnx-section . explorer)) 12)))
          (drgnx-state-sync f)                           ; a rebuild
          (should (equal (list (list nil a)) drgnx-state-test--puts))
          (select-window dock)
          (drgnx-state-sync f)
          (should (equal (list (list a a) (list nil a)) drgnx-state-test--puts))
          (setq drgnx-state-test--puts nil)
          (should (eq b (drgnx-state-use-editor b)))      ; the use-editor write goes through it too
          (should (equal (list (list a b)) drgnx-state-test--puts)))
      (advice-remove 'drgnx-state--put #'drgnx-state-test--note-put))))

(ert-deftest drgnx-state/use-editor-during-an-observation ()
  (drgnx-state-test--with
    (let* ((a (selected-window)) (b (split-window a nil 'right)) (f (selected-frame)))
      ;; no record yet, and an observation runs: nothing can be set, so nil
      (let ((drgnx-state--observing t))
        (should-not (drgnx-state-use-editor b)))
      (should-not (gethash f drgnx-state--frames))
      ;; with a record, the choice is set even during an observation (a `now' subscriber's)
      (drgnx-state-sync f)
      (let ((drgnx-state--observing t))
        (should (eq b (drgnx-state-use-editor b))))
      (should (eq b (drgnx-state-editor-window f))))))

(ert-deftest drgnx-state/sync-returns-a-copy ()
  (drgnx-state-test--with
    (let* ((f (selected-frame)) (copy (drgnx-state-sync f)) (rec (gethash f drgnx-state--frames)))
      (should (equal copy rec))
      (should-not (eq copy rec))
      (aset copy 0 'st-changed)
      (should (eq 'tty (drgnx-state--fr-kind (gethash f drgnx-state--frames)))))))

(ert-deftest drgnx-state/dead-window-and-frame-read-nil ()
  (drgnx-state-test--with
    (let* ((ws (drgnx-state-test--workbench)) (f (selected-frame)) (g2 (alist-get 'g2 ws)))
      (drgnx-state-use-editor g2)
      (drgnx-state-sync)
      (should (eq g2 (drgnx-state-editor-window f)))
      (delete-window g2)
      ;; dead before any observation: the reads still say nil
      (should-not (drgnx-state-window-role g2))
      (should-not (drgnx-state-edges g2))
      (should-not (drgnx-state-editor-window f))
      (drgnx-state-sync)
      (should-not (memq g2 (drgnx-state-windows f)))      ; dropped at the observation
      (should (eq (alist-get 'g1 ws) (drgnx-state-editor-window f)))
      ;; a frame that is not live reads nil everywhere
      (cl-letf (((symbol-function 'frame-live-p) #'ignore))
        (should-not (drgnx-state-editor-window f))
        (should-not (drgnx-state-selected-window f))
        (should-not (drgnx-state-windows f))
        (should-not (drgnx-state-pane-window 'terminal f))
        (should-not (drgnx-state-pane-shown-p 'terminal f))
        (should-not (drgnx-state-shown-kinds f))
        (should-not (drgnx-state-frame-size f))
        (should-not (drgnx-state-frames))
        (should-not (drgnx-state-sync f)))
      ;; a deleted frame's record goes (from `delete-frame-functions')
      (drgnx-state--frame-deleted f)
      (should-not (gethash f drgnx-state--frames))
      (should-not (memq f drgnx-state--order))
      (should-not (drgnx-state-frames)))))

(defvar drgnx-state-test--reentered 'unset "What a nested observation returned.")

(defun drgnx-state-test--split-during (&rest _)
  "After a rebuild: change the windows and observe again, as a `now' subscriber must not."
  (advice-remove 'drgnx-state--rebuild #'drgnx-state-test--split-during)
  (split-window (frame-first-window) nil 'below)
  (setq drgnx-state-test--reentered (drgnx-state--observe (selected-frame))))

(ert-deftest drgnx-state/a-change-during-observation-waits ()
  (drgnx-state-test--with
    (setq drgnx-state-test--reentered 'unset)
    (advice-add 'drgnx-state--rebuild :after #'drgnx-state-test--split-during)
    (unwind-protect
        (let ((f (selected-frame)))
          (drgnx-state-sync f)
          (should-not drgnx-state-test--reentered)       ; the nested observation did nothing
          (should (= 1 (length (drgnx-state-windows f)))) ; the split is not in the record yet
          (should (= 2 (length (window-list f 'nomini))))
          (drgnx-state-sync f)                             ; the next observation sees it
          (should (= 2 (length (drgnx-state-windows f)))))
      (advice-remove 'drgnx-state--rebuild #'drgnx-state-test--split-during))))

(defconst drgnx-state-test--writers
  '(split-window delete-window delete-other-windows select-window select-frame delete-frame window-resize
                 set-frame-parameter modify-frame-parameters set-window-configuration with-selected-window
                 with-selected-frame enlarge-window shrink-window balance-windows fit-window-to-buffer
                 make-frame-visible make-frame-invisible iconify-frame raise-frame lower-frame
                 select-frame-set-input-focus)
  "Functions that move windows or write window and frame state; any `set-window-*' and `set-frame-*' too.")

(defun drgnx-state-test--symbols (form)
  "Every symbol in FORM."
  (let (out)
    (cl-labels ((walk (x) (cond ((symbolp x) (push x out))
                                ((consp x) (walk (car x)) (walk (cdr x)))
                                ((vectorp x) (mapc #'walk x)))))
      (walk form))
    out))

(ert-deftest drgnx-state/the-observer-calls-no-window-writer ()
  (let* ((observer '(drgnx-state--observe drgnx-state--same-p drgnx-state--same-windows-p drgnx-state--classify
                                          drgnx-state--rebuild drgnx-state--kind drgnx-state--area-front
                                          drgnx-state--editor-kind drgnx-state--mru-editor drgnx-state--note-frame
                                          drgnx-state--on-window-state-change drgnx-state--post-command
                                          drgnx-state--pre-command drgnx-state--frame-made drgnx-state--frame-deleted
                                          drgnx-state-sync drgnx-state-frame-kind drgnx-state-workbench-frame-p
                                          drgnx-state--put drgnx-state--error))
         (defs (let (acc)
                 (dolist (file '("wb/drgnx-state.el" "core/drgnx-frame-kind.el") acc)
                   (with-temp-buffer
                     (insert-file-contents (expand-file-name file drgnx-dir))
                     (condition-case nil
                         (while t
                           (let ((form (read (current-buffer))))
                             (when (and (consp form) (memq (car form) '(defun defsubst cl-defun)))
                               (push (cons (nth 1 form) (nthcdr 2 form)) acc))))
                       (end-of-file nil)))))))
    (dolist (fn observer)
      (let ((def (assq fn defs)))
        (should def)                                    ; a renamed function must be renamed here too
        (dolist (s (drgnx-state-test--symbols (cdr def)))
          (should-not (and (or (memq s drgnx-state-test--writers)
                               (string-prefix-p "set-window-" (symbol-name s))
                               (string-prefix-p "set-frame-" (symbol-name s)))
                           (list fn s))))))))

(ert-deftest drgnx-state/in-place-check-builds-nothing ()
  (drgnx-state-test--with
    (drgnx-state-test--workbench)
    (drgnx-state-test--compile)
    (let* ((f (selected-frame)) (rec (drgnx-state-test--record f))
           (once (byte-compile (lambda (frame) (drgnx-state--observe frame))))
           (nothing (byte-compile (lambda (_frame) nil))))
      (should-not (drgnx-state--observe f))
      (should (eq rec (drgnx-state-test--record f)))
      (should (eq rec (gethash f drgnx-state--frames)))
      ;; (CONSES FLOATS VECTOR-CELLS SYMBOLS STRING-CHARS INTERVALS STRINGS) beyond what `memory-use-counts' takes itself
      (let* ((c0 (let ((b (memory-use-counts))) (funcall nothing f) (cl-mapcar #'- (memory-use-counts) b)))
             (c1 (let ((b (memory-use-counts))) (funcall once f) (cl-mapcar #'- (memory-use-counts) b)))
             (used (cl-mapcar #'- c1 c0)))
        (message "in-place check allocates %S" used)
        (should (<= (car used) 8))
        (should (equal '(0 0 0 0 0 0) (mapcar (lambda (n) (max n 0)) (cdr used))))))))

(ert-deftest drgnx-state/unchanged-check-is-cheap ()
  :tags '(:timing)
  (drgnx-state-test--with
    (drgnx-state-test--workbench)
    (drgnx-state-test--compile)
    (let* ((f (selected-frame)) (rec (drgnx-state-test--record f)) (n 2000)
           (loop (byte-compile (lambda (frame n) (dotimes (_ n) (drgnx-state--observe frame)))))
           (runs (sort (cl-loop repeat 21
                                collect (let ((t0 (float-time)))
                                          (funcall loop f n)
                                          (/ (* 1e6 (- (float-time) t0)) n)))
                       #'<))
           (median (nth 10 runs)))
      (message "in-place check, 7 windows: %.2f µs (median of 21 × %d)" median n)
      (should (eq rec (gethash f drgnx-state--frames)))
      (should (= 7 (length (drgnx-state-windows f))))
      (should (<= median (* 5 (drgnx-run-ert-time-factor)))))))

;;;; The mode and the fixture

(defconst drgnx-state-test--mode-hooks
  '((window-state-change-functions . drgnx-state--on-window-state-change)
    (post-command-hook . drgnx-state--post-command) (pre-command-hook . drgnx-state--pre-command)
    (after-make-frame-functions . drgnx-state--frame-made) (delete-frame-functions . drgnx-state--frame-deleted)))

(ert-deftest drgnx-state/mode-adds-and-removes-five-named-hooks ()
  (drgnx-state-test--with
    (unwind-protect
        (progn
          (drgnx-state-mode 1)
          (pcase-dolist (`(,hook . ,fn) drgnx-state-test--mode-hooks)
            (should (memq fn (default-value hook))))
          (let ((depths (get 'post-command-hook 'hook--depth-alist)))   ; Emacs 30: a symbol holding the alist
            (should (= -90 (alist-get 'drgnx-state--post-command (if (symbolp depths) (default-value depths) depths)))))
          (should (gethash (selected-frame) drgnx-state--frames))   ; on: every workbench frame observed
          (should (equal (list (selected-frame)) drgnx-state--order))
          (drgnx-state-mode 1)                                       ; idempotent
          (should (= 1 (cl-count 'drgnx-state--post-command (default-value 'post-command-hook))))
          ;; in a command: `user'; outside: `auto'
          (should (eq 'auto (drgnx-state-default-by)))
          (drgnx-state--pre-command)
          (should (eq 'user (drgnx-state-default-by)))
          (drgnx-state--post-command)
          (should (eq 'auto (drgnx-state-default-by)))
          (drgnx-state-mode -1)
          (pcase-dolist (`(,hook . ,fn) drgnx-state-test--mode-hooks)
            (should-not (memq fn (default-value hook))))
          (should (zerop (hash-table-count drgnx-state--frames)))
          (should-not drgnx-state--order))
      (drgnx-state-mode -1))))

(ert-deftest drgnx-state/with-write-binds-who-asked-and-syncs ()
  (drgnx-state-test--with
    (let* ((f (selected-frame)) seen
           (value (drgnx-state-with-write (f 'layout)
                    (setq seen drgnx-state--writing)
                    (split-window nil nil 'right)
                    42)))
      (should (= 42 value))
      (should (equal '(:by layout) seen))
      (should-not drgnx-state--writing)
      (should (= 2 (length (drgnx-state-windows f))))    ; synced at the end
      (drgnx-state-with-write (f) (setq seen drgnx-state--writing))
      (should (equal '(:by auto) seen)))))

(ert-deftest drgnx-state/the-fixture-restores-by-value ()
  (drgnx-test-with-state                                 ; outer: the suite's own state stays untouched
    (unwind-protect
        (let (tbl rec timer)
          (drgnx-state-mode 1)
          (setq tbl drgnx-state--frames rec (drgnx-state-test--record (selected-frame)))
          (setq drgnx-signal--subscribers '((st-event st-fn)) drgnx-signal-errors '("old"))
          (drgnx-test-with-state
            (pcase-dolist (`(,hook . ,fn) drgnx-state-test--mode-hooks)
              (should-not (memq fn (default-value hook))))     ; inside: the mode's hooks are off
            (should-not (eq tbl drgnx-state--frames))
            (should (zerop (hash-table-count drgnx-state--frames)))
            (should-not drgnx-signal--subscribers)
            (should-not drgnx-signal-errors)
            (should (assq 'dock drgnx-state--roles))           ; the roles defined so far stay
            (drgnx-state-define-role 'st-inside :chrome nil)
            (drgnx-state-sync)
            (setq drgnx-signal--subscribers '((other g)) drgnx-signal-errors '("new"))
            (setq timer (run-with-idle-timer 60 nil #'ignore) drgnx-signal--timer timer))
          (should (eq tbl drgnx-state--frames))
          (should (eq rec (gethash (selected-frame) drgnx-state--frames)))
          (should (equal '((st-event st-fn)) drgnx-signal--subscribers))
          (should (equal '("old") drgnx-signal-errors))
          (should-not (assq 'st-inside drgnx-state--roles))
          (should-not (memq timer timer-idle-list))          ; the timer armed inside was cancelled
          (should-not drgnx-signal--timer)
          (pcase-dolist (`(,hook . ,fn) drgnx-state-test--mode-hooks)
            (should (memq fn (default-value hook)))))        ; and the hooks are back
      (drgnx-state-mode -1))))

(provide 'wb-state-test)
;;; wb-state-test.el ends here
