;;; mod-close-test.el --- batch tests: Esc and q close help panes, popups and side panes (M12f A7) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'comint)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-close" drgnx-dir) nil t)

(defvar drgnx-close-test--emulation nil "The test's own emulation alist (special: Emacs reads it by name).")

(define-derived-mode drgnx-close-test-term-mode comint-mode "TestTerm" "A buffer you type into.")

(defmacro drgnx-close-test--with (&rest body)
  "BODY with rules on, one editor window, the panel hidden, fresh area state, and the close keys in a map of
their own (a test never changes the shipped map or `emulation-mode-map-alists')."
  (declare (indent 0))
  `(let* ((drgnx-signal--editor-window nil) (drgnx-wb-unrouted nil)
          (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
          (drgnx-close--here nil) (drgnx-wb--sections nil)
          (map (make-sparse-keymap))
          (drgnx-close-test--emulation (list (cons 'drgnx-close--here map)))
          (emulation-mode-map-alists '(drgnx-close-test--emulation)))
     (ignore map)
     (define-key map [escape] #'drgnx-close-pane)
     (define-key map "q" #'drgnx-close-pane)
     (delete-other-windows)
     (set-frame-parameter nil 'drgnx-wb-areas nil)
     (set-frame-parameter nil 'drgnx-wb-panel-px nil)
     (drgnx-rules-mode 1)
     (unwind-protect (progn ,@body)
       (drgnx-rules-mode -1)
       (drgnx-wb-hide-sidebar)
       (drgnx-wb-area-hide 'panel)
       (delete-other-windows)
       (dolist (b '("*drgnx-results*" "*Calendar*" "*notes*" "*drgnx-test-top*" "*drgnx-test-term*"))
         (when (get-buffer b) (kill-buffer b))))))

(defun drgnx-close-test--results ()
  "The panel's Results tab, 100 read-only lines, scrolled to line 40.  Returns (WINDOW BUFFER START POINT HEIGHT)."
  (let ((b (with-current-buffer (get-buffer-create "*drgnx-results*")
             (let ((inhibit-read-only t)) (erase-buffer) (dotimes (i 100) (insert (format "line %d\n" i))))
             (special-mode)
             (current-buffer))))
    (let ((w (drgnx-wb-area-show 'panel 'results b)))
      (with-selected-window w (goto-char (point-min)) (forward-line 40) (recenter 0))
      (list w b (window-start w) (window-point w) (window-pixel-height w)))))

(defun drgnx-close-test--read-only (name)
  "The buffer NAME in `special-mode', as a popup's buffer is."
  (with-current-buffer (get-buffer-create name) (special-mode) (current-buffer)))

(defun drgnx-close-test--press (key)
  "Select nothing; run what KEY (`escape' or ?q) does in the selected window now, as the keyboard would."
  (drgnx-close--update)
  (let ((cmd (key-binding (vector key) t)) (last-command-event key))
    (when (commandp cmd) (setq this-command cmd) (call-interactively cmd))
    cmd))

(ert-deftest drgnx-close/esc-closes-the-panel-q-too ()
  (dolist (key (list 'escape ?q))
    (drgnx-close-test--with
      (let ((editor (selected-window)))
        (drgnx-close-test--results)
        (select-window (drgnx-wb-area-window 'panel))
        (drgnx-close--update)
        (should drgnx-close--here)
        (should (eq (drgnx-close-test--press key) #'drgnx-close-pane))
        (should-not (drgnx-wb-area-window 'panel))
        (should (eq (selected-window) editor))))))

(ert-deftest drgnx-close/esc-ends-a-popup-and-gives-the-panel-back ()
  (drgnx-close-test--with
    (pcase-let ((`(,w ,b ,start ,pt ,h) (drgnx-close-test--results)))
      (let ((lane (display-buffer (drgnx-close-test--read-only "*Calendar*"))))
        (should (eq lane w))
        (should (drgnx-popup-active-p))
        (select-window lane)
        (drgnx-close-test--press 'escape)
        (should-not (drgnx-popup-active-p))
        (should (eq (drgnx-wb-area-window 'panel) w))
        (should (eq (window-buffer w) b))
        (should (= (window-start w) start))
        (should (= (window-point w) pt))
        (should (= (window-pixel-height w) h)))))
  ;; a temporary lane (no panel): the window is gone and the editor is as before
  (drgnx-close-test--with
    (let ((edges (mapcar #'window-pixel-edges (window-list nil 'nomini))))
      (select-window (display-buffer (drgnx-close-test--read-only "*Calendar*")))
      (drgnx-close-test--press ?q)
      (should-not (drgnx-popup-active-p))
      (should (equal edges (mapcar #'window-pixel-edges (window-list nil 'nomini)))))))

(ert-deftest drgnx-close/q-in-a-writable-buffer-types-q ()
  (drgnx-close-test--with
    (let ((b (get-buffer-create "*notes*")) (left nil))
      (with-current-buffer b
        (local-set-key [escape] (lambda () (interactive) (setq left t))))   ; what leaves Vim's insert state
      (drgnx-wb-area-show 'panel 'output b)
      (select-window (drgnx-wb-area-window 'panel))
      (drgnx-close--update)
      (should drgnx-close--here)
      (drgnx-close-test--press ?q)
      (should (equal (with-current-buffer b (buffer-string)) "q"))
      (should (drgnx-wb-area-window 'panel))
      (drgnx-close-test--press 'escape)
      (should left)
      (should (drgnx-wb-area-window 'panel)))))

(ert-deftest drgnx-close/not-in-a-terminal-tab ()
  (drgnx-close-test--with
    (let ((b (get-buffer-create "*drgnx-test-term*")))
      (with-current-buffer b (drgnx-close-test-term-mode))
      (drgnx-wb-area-show 'panel 'terminal b)
      (select-window (drgnx-wb-area-window 'panel))
      (drgnx-close--update)
      (should-not drgnx-close--here)
      (should-not (eq (key-binding [escape] t) #'drgnx-close-pane))
      (should-not (eq (key-binding "q" t) #'drgnx-close-pane))
      (should (drgnx-wb-area-window 'panel)))))

(ert-deftest drgnx-close/never-in-the-minibuffer ()
  (drgnx-close-test--with
    (drgnx-close-test--results)
    (select-window (minibuffer-window))
    (drgnx-close--update)
    (should-not drgnx-close--here)
    (should-not (eq (key-binding [escape] t) #'drgnx-close-pane))
    (select-window (selected-window))
    (select-window (car (window-list nil 'nomini)))
    (drgnx-close--update)
    (should-not drgnx-close--here)))            ; an editor window never

(ert-deftest drgnx-close/a-dock-section-keeps-its-esc-and-close-pane-hides-the-sidebar ()
  ;; Esc in the sidebar goes back to the editor (dock-back, invariant I1): the sidebar closes with its ✕ or the palette
  (drgnx-close-test--with
    (drgnx-wb-define-section 'top :slot -1 :title " TOP"
                             :buffer (lambda () (with-current-buffer (get-buffer-create "*drgnx-test-top*")
                                                  (special-mode) (current-buffer))))
    (let ((editor (selected-window)))
      (drgnx-wb-show-sidebar)
      (select-window (drgnx-wb-section-window 'top))
      (drgnx-close--update)
      (should-not drgnx-close--here)
      (should-not (eq (key-binding [escape] t) #'drgnx-close-pane))
      (let ((last-command-event ?\r)) (drgnx-close-pane))       ; Close Pane from the palette
      (should-not (drgnx-wb-sidebar-showing-p))
      (should (eq (selected-window) editor)))))

(ert-deftest drgnx-close/the-mode-owns-its-hooks-and-map ()
  (let ((emulation-mode-map-alists emulation-mode-map-alists) (drgnx-close-mode nil))
    (unwind-protect
        (progn
          (drgnx-close-mode 1) (drgnx-close-mode 1)       ; idempotent
          (should (= 1 (cl-count 'drgnx-close--emulation emulation-mode-map-alists)))
          (should (eq (cdr (car drgnx-close--emulation)) drgnx-close-mode-map))
          (should (eq (car (car drgnx-close--emulation)) 'drgnx-close--here))
          (should (memq #'drgnx-close--update window-selection-change-functions))
          (should (memq #'drgnx-close--update window-buffer-change-functions))
          (drgnx-close-mode -1)
          (should-not (memq 'drgnx-close--emulation emulation-mode-map-alists))
          (should-not (memq #'drgnx-close--update window-selection-change-functions))
          (should-not (memq #'drgnx-close--update window-buffer-change-functions)))
      (drgnx-close-mode -1))))

(ert-deftest drgnx-close/the-shipped-map-is-on-only-where-here-is ()
  ;; with the mode on and the real map bound, an editor keeps its Esc and q
  (let ((emulation-mode-map-alists emulation-mode-map-alists) (drgnx-close-mode nil))
    (unwind-protect
        (progn
          (define-key drgnx-close-mode-map [escape] #'drgnx-close-pane)
          (define-key drgnx-close-mode-map "q" #'drgnx-close-pane)
          (drgnx-close-mode 1)
          (should-not (assq 'drgnx-close-mode minor-mode-map-alist))
          (should-not drgnx-close--here)
          (should-not (eq (key-binding [escape] t) #'drgnx-close-pane))
          (should-not (eq (key-binding "q" t) #'drgnx-close-pane))
          (let ((drgnx-close--here t))
            (should (eq (key-binding [escape] t) #'drgnx-close-pane))
            (should (eq (key-binding "q" t) #'drgnx-close-pane))))
      (drgnx-close-mode -1)
      (define-key drgnx-close-mode-map [escape] nil)
      (define-key drgnx-close-mode-map "q" nil))))

(ert-deftest drgnx-close/every-profile-binds-the-two-keys ()
  (dolist (profile '("vscode" "emacs" "vim"))
    (let* ((spec (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                                   (goto-char (point-min)) (read (current-buffer))))
           (row (assq 'close-pane (plist-get spec :bind))))
      (should (equal (cl-subseq row 1 3) '("<escape>" "q")))
      (should (eq (plist-get (cdddr row) :map) 'drgnx-close-mode-map)))))

(provide 'mod-close-test)
;;; mod-close-test.el ends here
