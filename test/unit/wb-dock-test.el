;;; wb-dock-test.el --- batch tests: window roles and the left dock -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-wb)

(defmacro drgnx-wb-test--with-sections (&rest body)
  "BODY with two dummy dock sections and a single editor window; the layout is reset after."
  `(let ((drgnx-wb--sections nil) (drgnx-signal--editor-window nil))
     (delete-other-windows)
     (drgnx-wb-define-section 'top :slot -1 :title "TOP" :buffer (lambda () (get-buffer-create "*drgnx-test-top*")))
     (drgnx-wb-define-section 'bottom :slot 0 :title "BOTTOM" :buffer (lambda () (get-buffer-create "*drgnx-test-bottom*")))
     (unwind-protect (progn ,@body)
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (dolist (b '("*drgnx-test-top*" "*drgnx-test-bottom*")) (when (get-buffer b) (kill-buffer b))))))

(ert-deftest drgnx-wb/sidebar-shows-sections-without-focus ()
  (drgnx-wb-test--with-sections
   (let ((editor (selected-window)))
     (drgnx-wb-show-sidebar)
     (should (eq (selected-window) editor))
     (should (drgnx-wb-sidebar-showing-p))
     (let ((top (drgnx-wb-section-window 'top)) (bottom (drgnx-wb-section-window 'bottom)))
       (should (window-live-p top))
       (should (window-live-p bottom))
       (should (eq (window-parameter top 'drgnx-role) 'dock))
       (should (eq (window-parameter top 'window-side) 'left))
       (should (string-search "TOP" (window-parameter top 'header-line-format)))
       ;; Buffers above the Explorer: the lower slot is on top.
       (should (< (cadr (window-edges top)) (cadr (window-edges bottom))))
       (should-not (drgnx-signal-editor-window-p top))))))

(ert-deftest drgnx-wb/show-hide-keeps-the-width ()
  (drgnx-wb-test--with-sections
   (drgnx-wb-show-sidebar)
   (let ((w (window-pixel-width (drgnx-wb-section-window 'top))))
     (dotimes (_ 10) (drgnx-wb-hide-sidebar) (drgnx-wb-show-sidebar))
     (should (= w (window-pixel-width (drgnx-wb-section-window 'top))))
     (drgnx-wb-hide-sidebar)
     (should-not (drgnx-wb-sidebar-showing-p))
     (should (= 1 (length (window-list nil 'nomini)))))))

(ert-deftest drgnx-wb/files-from-the-dock-go-to-the-editor ()
  (drgnx-wb-test--with-sections
   (let ((editor (selected-window)) (b (get-buffer-create "*drgnx-test-file*")))
     (unwind-protect
         (progn
           (drgnx-wb-show-sidebar)
           (select-window (drgnx-wb-section-window 'bottom))
           (let ((n (length (window-list nil 'nomini))))
             (drgnx-wb-show-in-editor b)
             (should (eq (window-buffer editor) b))
             (should (eq (selected-window) (drgnx-wb-section-window 'bottom)))   ; focus kept
             (should (= n (length (window-list nil 'nomini)))))                  ; no split
           (drgnx-wb-show-in-editor b t)
           (should (eq (selected-window) editor)))
       (kill-buffer b)))))

(ert-deftest drgnx-wb/focus-editor-and-sections ()
  (drgnx-wb-test--with-sections
   (let ((editor (selected-window)))
     (drgnx-wb-focus-section 'top)                  ; shows the sidebar if hidden
     (should (eq (selected-window) (drgnx-wb-section-window 'top)))
     (drgnx-wb-focus-editor)
     (should (eq (selected-window) editor))
     (drgnx-wb-toggle-sidebar)
     (should-not (drgnx-wb-sidebar-showing-p)))))

;;;; M12f A7: the ✕

(ert-deftest drgnx-wb/a-section-title-closes-the-sidebar ()
  (drgnx-wb-test--with-sections
   (drgnx-wb-show-sidebar)
   (dolist (section '(top bottom))
     (let* ((w (drgnx-wb-section-window section)) (title (window-parameter w 'header-line-format)))
       (should (stringp title))
       ;; the ✕ comes first (a long title cannot clip it), one space in from the frame's edge
       (should (string-prefix-p (concat " " (drgnx-wb-close-glyph)) title))
       (should (string-search (upcase (symbol-name section)) title))
       (should (equal (get-text-property 1 'help-echo title) "Close sidebar"))
       (should (eq (get-text-property 1 'mouse-face title) 'highlight))))
   (let* ((w (drgnx-wb-section-window 'bottom)) (title (window-parameter w 'header-line-format)) (i 1))
     (funcall (lookup-key (get-text-property i 'local-map title) [header-line mouse-1])
              (list 'mouse-1 (list w 'header-line '(0 . 0) 0 (cons title i))))
     (should-not (drgnx-wb-sidebar-showing-p))
     (should (= 1 (length (window-list nil 'nomini)))))))

(ert-deftest drgnx-wb/the-close-glyph-has-an-ascii-form ()
  (let ((drgnx-face-glyphs '((close "✕" . "x"))))
    (cl-letf (((symbol-function 'drgnx-face-glyph) (lambda (name &optional _) (cddr (assq name drgnx-face-glyphs)))))
      (should (equal (drgnx-wb-close-glyph) "x")))))
