;;; wb-rules-test.el --- batch tests: where buffers go (the rules table) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-rules)

(defvar drgnx-rules-test--dirs nil "Temp dirs `drgnx-rules-test--file' made; `drgnx-rules-test--with' removes them.")

(defmacro drgnx-rules-test--with (&rest body)
  "BODY with the rules mode on, a two-section dock shown, one editor window and an empty unrouted log."
  `(let ((drgnx-wb--sections nil) (drgnx-signal--editor-window nil) (drgnx-wb-unrouted nil)
         (display-buffer-alist nil) (display-buffer-overriding-action '(nil)))
     (delete-other-windows)
     (drgnx-wb-define-section 'top :slot -1 :title "TOP" :buffer (lambda () (get-buffer-create "*drgnx-test-top*")))
     (drgnx-wb-define-section 'bottom :slot 0 :title "BOTTOM" :buffer (lambda () (get-buffer-create "*drgnx-test-bottom*")))
     (drgnx-rules-mode 1)
     (unwind-protect (progn (drgnx-wb-show-sidebar) ,@body)
       (while drgnx-rules-test--dirs (ignore-errors (delete-directory (pop drgnx-rules-test--dirs) t)))
       (drgnx-rules-mode -1)
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (dolist (b '("*drgnx-test-top*" "*drgnx-test-bottom*" "zz-unrouted" " *x*" "*t1*" "*t2*" "*t3*"))
         (when (get-buffer b) (kill-buffer b))))))

(defun drgnx-rules-test--file (name)
  (let* ((dir (make-temp-file "drgnx-rules" t))
         (f (expand-file-name name (car (push dir drgnx-rules-test--dirs)))))
    (write-region "x\n" nil f nil 'silent)
    (find-file-noselect f)))

(defun drgnx-rules-test--editors ()
  (seq-filter #'drgnx-signal-editor-window-p (window-list nil 'nomini)))

(ert-deftest drgnx-rules/a-file-goes-to-the-mru-editor-without-splitting ()
  (drgnx-rules-test--with
   ;; From a dock: the editor used last.  From an editor: that editor (the bus may not have seen it yet).
   (let* ((e1 (selected-window)) (e2 (split-window e1 nil 'right)) (b (drgnx-rules-test--file "a.txt")))
     (setq drgnx-signal--editor-window e2)
     (select-window (drgnx-wb-section-window 'top))
     (let ((n (length (window-list nil 'nomini))))
       (should (eq (display-buffer b) e2))
       (should (= n (length (window-list nil 'nomini)))))
     (select-window e1)
     (set-window-buffer e2 (get-buffer-create "*t1*"))
     (should (eq (display-buffer b) e1))
     (kill-buffer b))))

(ert-deftest drgnx-rules/a-shown-buffer-is-reused ()
  (drgnx-rules-test--with
   (let* ((e1 (selected-window)) (e2 (split-window e1 nil 'right)) (b (drgnx-rules-test--file "b.txt")))
     (set-window-buffer e1 b)
     (setq drgnx-signal--editor-window e2)
     (should (eq (display-buffer b) e1))
     (kill-buffer b))))

(ert-deftest drgnx-rules/never-into-a-dock ()
  (drgnx-rules-test--with
   (let ((editor (car (drgnx-rules-test--editors))) (b (drgnx-rules-test--file "c.txt"))
         (dock (drgnx-wb-section-window 'bottom)))
     (setq drgnx-signal--editor-window editor)
     (select-window dock)
     (pop-to-buffer b)
     (should (eq (window-buffer editor) b))
     (should (equal (buffer-name (window-buffer dock)) "*drgnx-test-bottom*"))
     (kill-buffer b))))

(ert-deftest drgnx-rules/unmatched-is-logged ()
  (drgnx-rules-test--with
   (let ((editor (car (drgnx-rules-test--editors))))
     (setq drgnx-signal--editor-window editor)
     (should (eq (display-buffer (get-buffer-create "zz-unrouted")) editor))
     (should (equal (plist-get (car drgnx-wb-unrouted) :buffer) "zz-unrouted"))
     (display-buffer (get-buffer-create " *x*"))
     (should (= 1 (length drgnx-wb-unrouted))))))

(ert-deftest drgnx-rules/later-rules-win-and-replace ()
  (let ((drgnx-rules--table nil))
    (drgnx-wb-place "\\`\\*t1\\*" 'current)
    (drgnx-wb-place "\\`\\*t1\\*" 'editor :x 1)
    (should (= 1 (length drgnx-rules--table)))
    (should (equal (drgnx-wb-rule-for "*t1*") '(editor :x 1)))
    (drgnx-wb-place "\\`\\*t" 'current)
    (should (eq (car (drgnx-wb-rule-for "*t1*")) 'current))))

(ert-deftest drgnx-rules/user-entries-win ()
  (drgnx-rules-test--with
   (push '("\\`\\*t2\\*" (display-buffer-in-side-window) (side . top)) display-buffer-alist)
   (let ((n (length (window-list nil 'nomini))))
     (display-buffer (get-buffer-create "*t2*"))
     (should (= (1+ n) (length (window-list nil 'nomini)))))
   (let ((n (length (window-list nil 'nomini)))
         (display-buffer-overriding-action '((display-buffer-in-side-window) (side . top) (slot . 1))))
     (display-buffer (get-buffer-create "*t3*"))
     (should (= (1+ n) (length (window-list nil 'nomini)))))))

(ert-deftest drgnx-rules/defaults-are-set-and-restored ()
  (let ((split-height-threshold 80) (split-width-threshold 160) (even-window-sizes 'width-only)
        (window-combination-resize nil) (switch-to-buffer-obey-display-actions nil)
        (resize-mini-windows 'grow-only) (window-sides-vertical nil) (message-truncate-lines nil)
        (eldoc-echo-area-use-multiline-p t) (display-buffer-alist nil))
    (drgnx-rules-mode 1)
    (unwind-protect
        (progn
          (should-not split-height-threshold)
          (should-not split-width-threshold)
          (should-not even-window-sizes)
          (should-not window-combination-resize)
          (should switch-to-buffer-obey-display-actions)
          (should-not resize-mini-windows)
          (should window-sides-vertical)
          (should message-truncate-lines)                ; the echo area stays one line (I4)
          (should-not eldoc-echo-area-use-multiline-p)
          (should (= 1 (length display-buffer-alist))))
      (drgnx-rules-mode -1))
    (should (= split-height-threshold 80))
    (should (= split-width-threshold 160))
    (should (eq even-window-sizes 'width-only))
    (should-not switch-to-buffer-obey-display-actions)
    (should (eq resize-mini-windows 'grow-only))
    (should (eq eldoc-echo-area-use-multiline-p t))
    (should-not display-buffer-alist)))

(ert-deftest drgnx-rules/delete-other-windows-keeps-the-dock ()
  (drgnx-rules-test--with
   (split-window (selected-window) nil 'right)
   (delete-other-windows)
   (should (drgnx-wb-section-window 'top))
   (should (drgnx-wb-section-window 'bottom))))

(ert-deftest drgnx-rules/files-and-lists-go-to-the-editor-unlogged ()
  (drgnx-rules-test--with
   (let ((editor (car (drgnx-rules-test--editors))) (f (drgnx-rules-test--file "notes.md")))
     (setq drgnx-signal--editor-window editor)
     (should (eq (display-buffer f) editor))
     (dolist (name (quote ("*Ibuffer*" "*Buffer List*" "*Customize Group: Editing*" "*Abbrevs*" "*scratch*")))
       (let* ((old (get-buffer name)) (b (get-buffer-create name)))   ; fundamental-mode when first displayed
         (should (eq (display-buffer b) editor))
         (unless old (kill-buffer b))))                  ; never the suite's own *scratch*
     (should-not drgnx-wb-unrouted)
     (kill-buffer f))))


(ert-deftest drgnx-rules/explicit-frame-and-no-window-actions-win ()
  ;; I3: C-x 5 b, `display-buffer-no-window': the caller's action is honoured.
  (drgnx-rules-test--with
   (let ((n (length (window-list nil 'nomini))))
     (should-not (display-buffer (get-buffer-create "*t1*") '(display-buffer-no-window (allow-no-window . t))))
     (should (= n (length (window-list nil 'nomini)))))
   (should-not (drgnx-rules--condition "*t1*" '(display-buffer-pop-up-frame)))
   (should-not (drgnx-rules--condition "*t1*" '((display-buffer-use-some-frame))))
   (should (drgnx-rules--condition "*t1*" '(display-buffer-same-window)))))

(ert-deftest drgnx-rules/inhibit-same-window-picks-another-editor ()
  ;; I3: C-x 4 b with two editors shows in the other one; with one editor, in it (never a split).
  (drgnx-rules-test--with
   (let* ((e1 (car (drgnx-rules-test--editors))) (e2 (split-window e1 nil 'right)))
     (select-window e1)
     (should (eq (display-buffer (get-buffer-create "*t1*") '(nil (inhibit-same-window . t))) e2))
     (delete-window e2)
     (should (eq (display-buffer (get-buffer-create "*t2*") '(nil (inhibit-same-window . t))) e1)))))

(ert-deftest drgnx-rules/a-dedicated-editor-is-left-alone ()
  ;; I8: C-x w d locks a window.
  (drgnx-rules-test--with
   (let* ((e1 (car (drgnx-rules-test--editors))) (e2 (split-window e1 nil 'right)) (b (drgnx-rules-test--file "d.txt")))
     (set-window-dedicated-p e1 t)
     (select-window e1)
     (should (eq (display-buffer b) e2))
     (should (eq (window-dedicated-p e1) t))
     (set-window-dedicated-p e1 nil)
     (kill-buffer b))))

(ert-deftest drgnx-rules/the-minibuffer-may-grow-while-reading ()
  ;; I12: the echo area stays one line, but icomplete-vertical / fido-vertical need room.
  (drgnx-rules-test--with
   (should (memq #'drgnx-rules--minibuffer-setup minibuffer-setup-hook))
   (with-temp-buffer
     (run-hooks 'minibuffer-setup-hook)
     (should (eq resize-mini-windows 'grow-only)))
   (should-not resize-mini-windows))
  (should-not (memq #'drgnx-rules--minibuffer-setup minibuffer-setup-hook)))

(ert-deftest drgnx-rules/report-says-entry-missing-after-a-setq ()
  ;; M3c-10 (d): a user `setq' of `display-buffer-alist' after startup drops drgnx's entry silently; the
  ;; session's report says so, and the doctor reads it.
  (drgnx-rules-test--with
   (should (eq (plist-get (drgnx-rules-report) :display-buffer-entry) t))
   (setq display-buffer-alist nil)
   (should (plist-member (drgnx-rules-report) :display-buffer-entry))
   (should-not (plist-get (drgnx-rules-report) :display-buffer-entry))))

(ert-deftest drgnx-rules/the-report-is-written-after-init-to-the-state-dir ()
  (let* ((state (make-temp-file "drgnx-rules-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
    (unwind-protect
        (drgnx-rules-test--with
         (should (memq #'drgnx-rules--write-report emacs-startup-hook))
         (drgnx-rules--write-report)
         (let ((file (expand-file-name "drgnx/wb-report.eld" state)))
           (should (file-readable-p file))
           (should (eq (plist-get (with-temp-buffer (insert-file-contents file) (read (current-buffer)))
                                  :display-buffer-entry)
                       t))
           (setq display-buffer-alist nil)
           (drgnx-rules--write-report)
           (should-not (plist-get (with-temp-buffer (insert-file-contents file) (read (current-buffer)))
                                  :display-buffer-entry))))
      (delete-directory state t))
    (should-not (memq #'drgnx-rules--write-report emacs-startup-hook))))
