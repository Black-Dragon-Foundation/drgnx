;;; wb-views-test.el --- batch tests: the sidebar's views (Explorer | Search) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-wb)

(defmacro drgnx-wb-views-test--with-sections (&rest body)
  "BODY with two Explorer-view sections (no :view), one Search-view section and one editor window."
  `(let ((drgnx-wb--sections nil) (drgnx-signal--editor-window nil))
     (delete-other-windows)
     (set-frame-parameter nil 'drgnx-wb-view nil)
     (drgnx-wb-define-section 'top :slot -1 :title "TOP" :buffer (lambda () (get-buffer-create "*drgnx-views-top*")))
     (drgnx-wb-define-section 'bottom :slot 0 :title "BOTTOM" :buffer (lambda () (get-buffer-create "*drgnx-views-bottom*")))
     (drgnx-wb-define-section 'find :slot 0 :view 'search :title "FIND"
                              :buffer (lambda () (get-buffer-create "*drgnx-views-find*")))
     (unwind-protect (progn ,@body)
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (set-frame-parameter nil 'drgnx-wb-view nil)
       (dolist (b '("*drgnx-views-top*" "*drgnx-views-bottom*" "*drgnx-views-find*"))
         (when (get-buffer b) (kill-buffer b))))))

(ert-deftest drgnx-wb-views/only-the-view-s-sections-show ()
  (drgnx-wb-views-test--with-sections
   (drgnx-wb-show-view 'search)
   (should (eq (drgnx-wb-sidebar-view) 'search))
   (should (window-live-p (drgnx-wb-section-window 'find)))
   (should-not (drgnx-wb-section-window 'top))
   (should-not (drgnx-wb-section-window 'bottom))
   (drgnx-wb-show-view 'explorer)
   (should (eq (drgnx-wb-sidebar-view) 'explorer))
   (should (window-live-p (drgnx-wb-section-window 'top)))
   (should (window-live-p (drgnx-wb-section-window 'bottom)))
   (should-not (drgnx-wb-section-window 'find))))

(ert-deftest drgnx-wb-views/switching-keeps-width-and-focus ()
  (drgnx-wb-views-test--with-sections
   (let ((editor (selected-window)))
     (drgnx-wb-show-sidebar)
     (let ((window-resize-pixelwise t))
       (window-resize (drgnx-wb-section-window 'top) (* 3 (frame-char-width)) t nil t))
     (let ((px (window-pixel-width (drgnx-wb-section-window 'top))))
       (should (/= px (* drgnx-wb-dock-columns (frame-char-width))))   ; a width the user chose
       (drgnx-wb-show-view 'search)
       (should (= px (window-pixel-width (drgnx-wb-section-window 'find))))
       (should (eq (selected-window) editor))
       (drgnx-wb-show-view 'explorer)
       (should (= px (window-pixel-width (drgnx-wb-section-window 'top))))
       (should (eq (selected-window) editor))
       ;; Focus in the dock stays in the dock: on the new view's first section.
       (select-window (drgnx-wb-section-window 'bottom))
       (drgnx-wb-show-view 'search)
       (should (eq (selected-window) (drgnx-wb-section-window 'find)))))))

(ert-deftest drgnx-wb-views/hidden-sidebar-shows-the-view ()
  (drgnx-wb-views-test--with-sections
   (let ((editor (selected-window)))
     (should-not (drgnx-wb-sidebar-showing-p))
     (drgnx-wb-show-view 'search)
     (should (drgnx-wb-sidebar-showing-p))
     (should (window-live-p (drgnx-wb-section-window 'find)))
     (should (eq (selected-window) editor))
     ;; Hiding and toggling back shows the view it had.
     (drgnx-wb-toggle-sidebar)
     (should-not (drgnx-wb-sidebar-showing-p))
     (drgnx-wb-toggle-sidebar)
     (should (window-live-p (drgnx-wb-section-window 'find)))
     (should-not (drgnx-wb-section-window 'top)))))

(ert-deftest drgnx-wb-views/sections-without-a-view-are-explorer-s ()
  (drgnx-wb-views-test--with-sections
   (should (eq (drgnx-wb-sidebar-view) 'explorer))
   (drgnx-wb-show-sidebar)
   (should (window-live-p (drgnx-wb-section-window 'top)))
   (should (window-live-p (drgnx-wb-section-window 'bottom)))
   (should-not (drgnx-wb-section-window 'find))))
