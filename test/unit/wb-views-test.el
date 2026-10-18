;;; wb-views-test.el --- batch tests: the sidebar's views (Explorer | Search) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx)
(require 'drgnx-wb)

(defmacro drgnx-wb-views-test--with-sections (&rest body)
  "BODY with two Explorer-view sections (no :view), one Search-view section and one editor window."
  `(drgnx-test-with-state
     (let ((drgnx-wb--sections nil))
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
           (when (get-buffer b) (kill-buffer b)))))))

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

(ert-deftest drgnx-wb-views/a-view-without-sections-changes-nothing ()
  (drgnx-wb-views-test--with-sections
   (drgnx-wb-show-sidebar)
   (let ((px (window-pixel-width (drgnx-wb-section-window 'top))))
     (should-error (drgnx-wb-show-view 'ghost) :type 'user-error)
     (should (eq (drgnx-wb-sidebar-view) 'explorer))
     (should (window-live-p (drgnx-wb-section-window 'top)))
     (should (= px (window-pixel-width (drgnx-wb-section-window 'top))))
     (drgnx-wb-hide-sidebar)
     (should-error (drgnx-wb-show-view 'ghost) :type 'user-error)
     (should-not (drgnx-wb-sidebar-showing-p)))))

(ert-deftest drgnx-wb-views/a-stale-view-falls-back-to-the-explorer ()
  (drgnx-wb-views-test--with-sections
   (set-frame-parameter nil 'drgnx-wb-view 'ghost)
   (should (eq (drgnx-wb-sidebar-view) 'explorer))
   (drgnx-wb-show-sidebar)
   (should (window-live-p (drgnx-wb-section-window 'top)))
   (should-not (drgnx-wb-section-window 'find))))

;;;; The keys that open a view also focus it (VS Code's Ctrl+Shift+E / Ctrl+Shift+F)

(defun drgnx-wb-views-test--vscode-key-runs (key)
  "The command ID the VS Code profile binds to KEY."
  (let ((bind (plist-get (cdr (assq 'vscode (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))) :bind)))
    (car (seq-find (lambda (b) (member key (seq-filter #'stringp (cdr b)))) bind))))

(defmacro drgnx-wb-views-test--with-real-names (&rest body)
  "BODY with sections named like the real ones: `buffers' and `explorer' (Explorer view), `search' (Search view)."
  `(drgnx-test-with-state
     (let ((drgnx-wb--sections nil))
       (delete-other-windows)
       (set-frame-parameter nil 'drgnx-wb-view nil)
       (drgnx-wb-define-section 'buffers :slot -1 :title "BUFFERS" :buffer (lambda () (get-buffer-create "*drgnx-views-buffers*")))
       (drgnx-wb-define-section 'explorer :slot 0 :title "EXPLORER" :buffer (lambda () (get-buffer-create "*drgnx-views-explorer*")))
       (drgnx-wb-define-section 'search :slot 0 :view 'search :title "SEARCH"
                                :buffer (lambda () (get-buffer-create "*drgnx-views-search*")))
       (unwind-protect (progn ,@body)
         (drgnx-wb-hide-sidebar)
         (delete-other-windows)
         (set-frame-parameter nil 'drgnx-wb-view nil)
         (dolist (b '("*drgnx-views-buffers*" "*drgnx-views-explorer*" "*drgnx-views-search*"))
           (when (get-buffer b) (kill-buffer b)))))))

(ert-deftest drgnx-wb-views/vscode-c-s-e-leaves-focus-in-the-explorer ()
  (drgnx-wb-views-test--with-real-names
   (let ((id (drgnx-wb-views-test--vscode-key-runs "C-S-e")))
     (should (eq id 'view-explorer))
     ;; From the editor with the sidebar hidden.
     (call-interactively #'drgnx-wb-view-explorer)
     (should (eq (selected-window) (drgnx-wb-section-window 'explorer)))
     ;; From the editor while the Search view is shown.
     (select-window (drgnx-wb-editor-window))
     (drgnx-wb-show-view 'search)
     (call-interactively #'drgnx-wb-view-explorer)
     (should (eq (drgnx-wb-sidebar-view) 'explorer))
     (should (eq (selected-window) (drgnx-wb-section-window 'explorer)))
     ;; From inside the Search view: the Explorer's tree, not the first section.
     (select-window (drgnx-wb-section-window 'explorer))
     (drgnx-wb-show-view 'search)
     (call-interactively #'drgnx-wb-view-explorer)
     (should (eq (selected-window) (drgnx-wb-section-window 'explorer))))))

(ert-deftest drgnx-wb-views/vscode-c-s-f-leaves-focus-in-the-search-view ()
  (drgnx-wb-views-test--with-real-names
   (should (eq (drgnx-wb-views-test--vscode-key-runs "C-S-f") 'view-search))
   (call-interactively #'drgnx-wb-view-search)
   (should (eq (drgnx-wb-sidebar-view) 'search))
   (should (eq (selected-window) (drgnx-wb-section-window 'search)))))

(ert-deftest drgnx-wb-views/choosing-a-view-without-the-key-keeps-focus ()
  ;; Clicking a sidebar tab is `drgnx-wb-show-view': focus stays (Task 1's design).
  (drgnx-wb-views-test--with-real-names
   (let ((editor (selected-window)))
     (drgnx-wb-show-view 'search)
     (should (eq (selected-window) editor)))))

(ert-deftest drgnx-wb-views/focusing-a-section-of-another-view-switches-to-it ()
  ;; Focus Explorer while the Search view shows: the Explorer view comes back, its tree focused (no error).
  (drgnx-wb-views-test--with-real-names
   (drgnx-wb-show-view 'search)
   (drgnx-wb-focus-section 'explorer)
   (should (eq (drgnx-wb-sidebar-view) 'explorer))
   (should (eq (selected-window) (drgnx-wb-section-window 'explorer)))
   ;; and back, with the sidebar hidden first
   (drgnx-wb-hide-sidebar)
   (drgnx-wb-focus-section 'search)
   (should (eq (drgnx-wb-sidebar-view) 'search))
   (should (eq (selected-window) (drgnx-wb-section-window 'search)))))

(ert-deftest drgnx-wb-views/a-section-s-on-focus-runs-when-it-is-focused ()
  (drgnx-wb-views-test--with-real-names
   (let ((seen nil))
     (drgnx-wb-define-section 'search :slot 0 :view 'search :title "SEARCH"
                              :buffer (lambda () (get-buffer-create "*drgnx-views-search*"))
                              :on-focus (lambda (w) (push w seen)))
     (drgnx-wb-show-view 'search)
     (should-not seen)                                  ; showing is not focusing
     (call-interactively #'drgnx-wb-view-search)
     (should (equal seen (list (drgnx-wb-section-window 'search)))))))

(ert-deftest drgnx-wb-views/a-view-not-set-up-yet-is-set-up-when-asked-for ()
  ;; A module that sets up at idle can provide its view at once: the first View: Search before then sets it up.
  (drgnx-wb-views-test--with-real-names
   (setq drgnx-wb--sections (assq-delete-all 'search drgnx-wb--sections))
   (let ((drgnx-wb-view-providers
          (list (cons 'search (lambda () (drgnx-wb-define-section 'search :slot 0 :view 'search :title "SEARCH"
                                                                  :buffer (lambda () (get-buffer-create "*drgnx-views-search*"))))))))
     (call-interactively #'drgnx-wb-view-search)
     (should (eq (drgnx-wb-sidebar-view) 'search))
     (should (eq (selected-window) (drgnx-wb-section-window 'search)))
     (should-error (drgnx-wb-show-view 'ghost) :type 'user-error))))
