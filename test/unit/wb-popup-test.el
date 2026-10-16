;;; wb-popup-test.el --- batch tests: the popup lane -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-popup)
(require 'which-key)

(defmacro drgnx-popup-test--with (&rest body)
  "BODY with rules on, one editor window, the panel hidden, fresh area state."
  `(let ((drgnx-signal--editor-window nil) (drgnx-wb-unrouted nil)
         (display-buffer-alist nil) (display-buffer-overriding-action '(nil)))
     (delete-other-windows)
     (set-frame-parameter nil 'drgnx-wb-areas nil)
     (set-frame-parameter nil 'drgnx-wb-panel-px nil)
     (drgnx-rules-mode 1)
     (unwind-protect (progn ,@body)
       (drgnx-rules-mode -1)
       (drgnx-wb-area-hide 'panel)
       (delete-other-windows)
       (dolist (b '("*Calendar*" " *transient*" "*drgnx-results*" " *which-key*"))
         (when (get-buffer b) (kill-buffer b))))))

(defun drgnx-popup-test--panel-on-results ()
  "Show the panel's Results tab scrolled to line 40; return (WINDOW BUFFER START POINT HEIGHT HEADER)."
  (let ((b (with-current-buffer (get-buffer-create "*drgnx-results*")
             (erase-buffer) (dotimes (i 100) (insert (format "line %d\n" i))) (current-buffer))))
    (let ((w (drgnx-wb-area-show 'panel 'results b)))
      (with-selected-window w (goto-char (point-min)) (forward-line 40) (recenter 0))
      (list w b (window-start w) (window-point w) (window-pixel-height w) (window-parameter w 'header-line-format)))))

(defun drgnx-popup-test--panel-back-p (saved)
  (pcase-let ((`(,w ,b ,start ,pt ,h ,header) saved))
    (and (window-live-p w) (eq (drgnx-wb-area-window 'panel) w) (eq (window-buffer w) b)
         (= (window-start w) start) (= (window-point w) pt) (= (window-pixel-height w) h)
         (equal (window-parameter w 'header-line-format) header)
         (not (drgnx-popup-active-p)))))

(defun drgnx-popup-test--edges ()
  (mapcar #'window-pixel-edges (window-list nil 'nomini)))

(ert-deftest drgnx-popup/borrows-and-restores-the-panel ()
  (drgnx-popup-test--with
   (let* ((saved (drgnx-popup-test--panel-on-results)) (n (length (window-list nil 'nomini)))
          (w (display-buffer (get-buffer-create "*Calendar*"))))
     (should (eq w (car saved)))                          ; the panel's window, borrowed
     (should (= n (length (window-list nil 'nomini))))
     (should (drgnx-popup-active-p))
     (delete-window w)
     (should (drgnx-popup-test--panel-back-p saved)))))

(ert-deftest drgnx-popup/without-a-panel-leaves-no-trace ()
  (drgnx-popup-test--with
   (let ((edges (drgnx-popup-test--edges)) (n (length (window-list nil 'nomini))))
     (display-buffer (get-buffer-create "*Calendar*"))
     (should (= (1+ n) (length (window-list nil 'nomini))))
     (quit-windows-on "*Calendar*")
     (should (equal edges (drgnx-popup-test--edges)))
     (should-not (drgnx-popup-active-p)))))

(ert-deftest drgnx-popup/killing-the-popup-buffer-restores ()
  (drgnx-popup-test--with
   (let ((saved (drgnx-popup-test--panel-on-results)))
     (display-buffer (get-buffer-create "*Calendar*"))
     (kill-buffer "*Calendar*")
     (should (drgnx-popup-test--panel-back-p saved)))))

(ert-deftest drgnx-popup/a-second-popup-replaces-the-first ()
  (drgnx-popup-test--with
   (let ((saved (drgnx-popup-test--panel-on-results)))
     (display-buffer (get-buffer-create "*Calendar*"))
     (let ((w (display-buffer (get-buffer-create " *transient*"))))
       (should (eq w (car saved)))
       (should (eq (window-buffer w) (get-buffer " *transient*")))
       (delete-window w))
     (should (drgnx-popup-test--panel-back-p saved)))))

(ert-deftest drgnx-popup/a-popup-that-resizes-its-window-is-undone ()
  (drgnx-popup-test--with
   (let* ((saved (drgnx-popup-test--panel-on-results)) (w (display-buffer (get-buffer-create "*Calendar*"))))
     (ignore-errors (window-resize w 3))
     (delete-window w)
     (should (drgnx-popup-test--panel-back-p saved)))))

(ert-deftest drgnx-popup/which-key-side-window-is-contained ()
  (drgnx-popup-test--with
   (let ((which-key--buffer (get-buffer-create " *which-key*")))
     (with-current-buffer which-key--buffer (insert "a → b\n"))
     ;; Panel hidden: a temporary window, gone after.
     (let ((edges (drgnx-popup-test--edges)))
       (which-key--show-buffer-side-window '(5 . 40))
       (should (drgnx-popup-active-p))
       (which-key--hide-buffer-side-window)
       (should (equal edges (drgnx-popup-test--edges))))
     ;; Panel shown: borrowed, then back.
     (let ((saved (drgnx-popup-test--panel-on-results)))
       (which-key--show-buffer-side-window '(5 . 40))
       (should (eq (window-buffer (car saved)) which-key--buffer))
       (which-key--hide-buffer-side-window)
       (should (drgnx-popup-test--panel-back-p saved))))))

(ert-deftest drgnx-popup/the-panel-used-meanwhile-ends-the-popup ()
  ;; Hiding the panel or switching its tab while a popup borrows it: the popup ends first, and
  ;; the tab never remembers the popup's buffer.
  (drgnx-popup-test--with
   (let ((saved (drgnx-popup-test--panel-on-results)))
     (display-buffer (get-buffer-create "*Calendar*"))
     (drgnx-wb-area-hide 'panel)
     (should-not (drgnx-popup-active-p))
     (should (eq (window-buffer (drgnx-wb-area-show 'panel 'results)) (nth 1 saved)))
     (display-buffer (get-buffer-create "*Calendar*"))
     (drgnx-wb-area-show 'panel 'output)
     (should-not (drgnx-popup-active-p))
     (should (eq (window-buffer (drgnx-wb-area-show 'panel 'results)) (nth 1 saved))))))

(ert-deftest drgnx-popup/after-the-popup-the-panel-hides-on-delete ()
  (drgnx-popup-test--with
   (let ((saved (drgnx-popup-test--panel-on-results)))
     (delete-window (display-buffer (get-buffer-create "*Calendar*")))
     (should (drgnx-popup-test--panel-back-p saved))
     (window-resize (car saved) 3)                       ; the user dragged it taller
     (let ((h (window-pixel-height (car saved))))
       (delete-window (car saved))                       ; a package deleting the window it had
       (should-not (drgnx-wb-area-window 'panel))
       (should (= h (window-pixel-height (drgnx-wb-area-show 'panel 'results))))))))

(ert-deftest drgnx-popup/a-borrowed-panel-is-not-fitted ()
  ;; transient and which-key fit their window to their buffer: the panel keeps its height.
  (drgnx-popup-test--with
   (let* ((saved (drgnx-popup-test--panel-on-results)) (w (display-buffer (get-buffer-create "*Calendar*"))))
     (with-current-buffer "*Calendar*" (erase-buffer) (insert "one line"))
     (fit-window-to-buffer w nil 1)
     (should (= (nth 4 saved) (window-pixel-height w)))
     (delete-window w))))

(ert-deftest drgnx-popup/the-callers-body-function-runs ()
  ;; C1: *Completions* is filled by its `body-function'.
  (drgnx-popup-test--with
   (dolist (panel '(nil t))
     (when panel (drgnx-popup-test--panel-on-results))
     (let ((b (get-buffer-create "*Completions*")))
       (with-current-buffer b (erase-buffer))
       (display-buffer b `(nil (body-function . ,(lambda (w) (with-current-buffer (window-buffer w) (insert "cands"))))))
       (should (equal (with-current-buffer b (buffer-string)) "cands"))
       (kill-buffer b)))))

(ert-deftest drgnx-popup/never-borrows-the-window-you-type-in ()
  ;; C2: ielm in the panel, TAB: the panel keeps showing ielm.
  (drgnx-popup-test--with
   (let* ((saved (drgnx-popup-test--panel-on-results)) (w (car saved)))
     (select-window w)
     (let ((lane (display-buffer (get-buffer-create "*Completions*"))))
       (should-not (eq lane w))
       (should (eq (window-buffer w) (nth 1 saved)))
       (should (eq (selected-window) w))
       (delete-window lane))
     (should (drgnx-popup-test--panel-back-p saved)))))

(ert-deftest drgnx-popup/burying-ends-a-borrowed-popup ()
  ;; I4: `minibuffer-hide-completions' buries; the lane must still be dedicated for that to end it.
  (drgnx-popup-test--with
   (let ((saved (drgnx-popup-test--panel-on-results)))
     (describe-function 'car)
     (setq saved (drgnx-popup-test--panel-on-results))    ; after a tab switch
     (let ((w (display-buffer (get-buffer-create "*Completions*"))))
       (with-selected-window w (bury-buffer)))
     (should (drgnx-popup-test--panel-back-p saved)))))

(ert-deftest drgnx-popup/a-restored-configuration-ends-the-popup ()
  ;; I5: leaving the minibuffer restores the window configuration under the popup's feet.
  (drgnx-popup-test--with
   (let* ((saved (drgnx-popup-test--panel-on-results)) (conf (current-window-configuration)))
     (display-buffer (get-buffer-create "*Completions*"))
     (set-window-configuration conf)
     (drgnx-popup-check)
     (should (drgnx-popup-test--panel-back-p saved)))))
