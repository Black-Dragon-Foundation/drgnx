;;; grid-atoms-test.el --- batch tests: atomic tiles (the conversation, the side bar) and the old dock APIs on the grid -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-grid)
(require 'drgnx-area)

(defun drgnx-grid-atoms-test--buffer (name)
  (lambda () (with-current-buffer (get-buffer-create name t) (special-mode) (current-buffer))))

(defun drgnx-grid-atoms-test--reset ()
  (let ((ignore-window-parameters t)) (delete-other-windows))
  (dolist (p '(drgnx-tile-id drgnx-role drgnx-tile-dock drgnx-tile-part no-delete-other-windows delete-window
                             window-atom window-preserved-size))
    (set-window-parameter nil p nil))
  (set-window-dedicated-p nil nil)
  (dolist (p '(drgnx-grid-memory drgnx-grid-next-id drgnx-intent-by drgnx-wb-panel-px drgnx-wb-right-px
                                 drgnx-wb-dock-px drgnx-wb-areas drgnx-wb-view))
    (set-frame-parameter nil p nil)))

(defmacro drgnx-grid-atoms-test--with (&rest body)
  "BODY with the grid on, a 160 × 50 frame of one editor window, and fresh kinds, sections and areas."
  (declare (indent 0))
  `(drgnx-test-with-state
     (let ((drgnx-pane--kinds nil) (drgnx-pane-backend 'grid) (drgnx-state--kind-owners nil)
           (drgnx-wb--sections nil) (drgnx-wb--areas (copy-tree drgnx-wb--areas))
           (drgnx-rules--table (copy-sequence drgnx-rules--table))
           (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
           (drgnx-wb-dock-columns 30) (window-min-width 2) (window-min-height 2))
       (set-frame-size nil 160 50)
       (drgnx-grid-atoms-test--reset)
       (unwind-protect (progn ,@body)
         (drgnx-grid-atoms-test--reset)
         (dolist (b (buffer-list))
           (when (string-match-p "\\` \\*drgnx a-\\|\\`\\*a-" (buffer-name b)) (kill-buffer b)))))))

(defun drgnx-grid-atoms-test--conversation ()
  "Define the right kind `a-conv' whose buffer has a header above and a composer below; show it."
  (let ((header (get-buffer-create "*a-header*")) (composer (get-buffer-create "*a-composer*")))
    (with-current-buffer header (insert "header\n"))
    (with-current-buffer composer (insert "composer\n"))
    (drgnx-pane-define-kind 'a-conv :title "Chat" :home 'right
                            :companions (lambda (_) (list header composer)))
    (drgnx-pane-show 'a-conv :buffer (get-buffer-create "*a-transcript*"))))

(ert-deftest drgnx-grid-atoms/conversation-is-one-tile ()
  (drgnx-grid-atoms-test--with
    (let* ((transcript (drgnx-grid-atoms-test--conversation))
           (parts (drgnx-area--companion-windows 'right))
           (root (window-atom-root transcript)))
      (should (= 2 (length parts)))
      (should (and root (not (window-live-p root))))
      (dolist (w (cons transcript parts))
        (should (eq (window-atom-root w) root))
        (should-not (window-parameter w 'window-side)))
      (should (equal (mapcar #'window-buffer (drgnx-grid--leaves root))
                     (list (get-buffer "*a-header*") (get-buffer "*a-transcript*") (get-buffer "*a-composer*"))))
      ;; the tile is one: a split from the transcript goes beside the whole atom
      (let ((new (split-window transcript nil 'left)))
        (should-not (window-atom-root new))
        (should (eq (window-parent new) (window-parent root)))
        (let ((ignore-window-parameters t)) (delete-window new)))
      ;; and C-x 0 on the composer hides the whole tile
      (delete-window (cadr parts))
      (should-not (drgnx-pane-window 'a-conv))
      (should-not (seq-some #'window-live-p (cons transcript parts)))
      ;; it comes back as one, at its width
      (let ((again (drgnx-pane-show 'a-conv)))
        (should (= 2 (length (drgnx-area--companion-windows 'right))))
        (should (window-atom-root again))))))

(ert-deftest drgnx-grid-atoms/side-bar-keeps-its-width-across-places ()
  (drgnx-grid-atoms-test--with
    (drgnx-wb-define-section 'a-files :slot 0 :title "Files" :buffer (drgnx-grid-atoms-test--buffer " *drgnx a-files*"))
    (drgnx-wb-define-section 'a-open :slot 1 :title "Open" :buffer (drgnx-grid-atoms-test--buffer " *drgnx a-open*"))
    (drgnx-wb-define-section 'a-find :slot 0 :title "Find" :view 'search
                             :buffer (drgnx-grid-atoms-test--buffer " *drgnx a-find*"))
    (drgnx-wb-show-sidebar)
    (let* ((first (car (drgnx-wb--dock-windows))) (edges (window-pixel-edges first))
           (editor (car (drgnx-grid-tiles nil 'editor))) (editor-edges (window-pixel-edges editor)))
      (should (= 2 (length (drgnx-wb--dock-windows))))
      (should (window-atom-root first))
      (should (eq (drgnx-grid-dock 'left) first))
      (drgnx-wb-show-view 'search)
      (let ((find (drgnx-wb-section-window 'a-find)))
        (should (= 1 (length (drgnx-wb--dock-windows))))
        (should (= (nth 0 edges) (nth 0 (window-pixel-edges find))))
        (should (= (nth 2 edges) (nth 2 (window-pixel-edges find))))
        (should (equal editor-edges (window-pixel-edges editor))))
      (drgnx-wb-show-view 'explorer)
      (should (= (nth 2 edges) (nth 2 (window-pixel-edges (car (drgnx-wb--dock-windows))))))
      (should (equal editor-edges (window-pixel-edges editor))))))

(ert-deftest drgnx-grid-atoms/a-section-keeps-its-height-share ()
  (drgnx-grid-atoms-test--with
    (drgnx-wb-define-section 'a-files :slot 0 :title "Files" :buffer (drgnx-grid-atoms-test--buffer " *drgnx a-files*"))
    (drgnx-wb-define-section 'a-outline :slot 1 :title "Outline" :height 0.3
                             :buffer (drgnx-grid-atoms-test--buffer " *drgnx a-outline*"))
    (drgnx-wb-show-sidebar)
    (let* ((total (window-pixel-height (window-atom-root (car (drgnx-wb--dock-windows)))))
           (outline (window-pixel-height (drgnx-wb-section-window 'a-outline))))
      (should (<= (abs (- outline (round (* 0.3 total)))) 1))
      (dotimes (_ 3)
        (drgnx-wb-hide-sidebar)
        (should-not (drgnx-wb--dock-windows))
        (drgnx-wb-show-sidebar)
        (should (= outline (window-pixel-height (drgnx-wb-section-window 'a-outline))))))))

(ert-deftest drgnx-grid-atoms/focus-section-runs-on-focus ()
  (drgnx-grid-atoms-test--with
    (let (focused)
      (drgnx-wb-define-section 'a-find :slot 0 :title "Find" :view 'search
                               :buffer (drgnx-grid-atoms-test--buffer " *drgnx a-find*")
                               :on-focus (lambda (w) (setq focused w)))
      (drgnx-wb-focus-section 'a-find)
      (should (eq focused (drgnx-wb-section-window 'a-find)))
      (should (eq (selected-window) focused))
      (should (window-parameter focused 'drgnx-tile-dock)))))

(ert-deftest drgnx-grid-atoms/the-old-area-api-still-works ()
  (drgnx-grid-atoms-test--with
    (drgnx-wb-define-tab 'panel 'a-term :title "Term" :placeholder (drgnx-grid-atoms-test--buffer " *drgnx a-term*"))
    (let ((editor (selected-window)) (w (drgnx-wb-area-show 'panel 'a-term)))
      (should (eq (window-parameter w 'drgnx-tile-dock) 'bottom))
      (should-not (window-parameter w 'window-side))
      (should (eq (drgnx-wb-area-window 'panel) w))
      (should (eq (drgnx-wb-area-tab 'panel) 'a-term))
      (should (eq (selected-window) editor))
      (let ((b (get-buffer-create "*a-other*")))
        (drgnx-wb-set-area-buffer w b)
        (should (eq (window-buffer w) b))
        (should (eq (window-dedicated-p w) 'drgnx)))
      (drgnx-wb-area-toggle 'panel)
      (should-not (drgnx-wb-area-window 'panel))
      (drgnx-wb-area-toggle 'panel)
      (should (drgnx-wb-area-window 'panel))
      (drgnx-wb-area-hide 'panel)
      (should (eq (drgnx-wb-area-focus 'panel) (selected-window)))
      (should (eq (window-parameter (selected-window) 'drgnx-tile-dock) 'bottom)))))

(ert-deftest drgnx-grid-atoms/the-side-bar-kind-is-the-whole-dock ()
  (drgnx-grid-atoms-test--with
    (drgnx-pane-define-kind 'a-side :title "Side Bar" :home 'left :sidebar t)
    (drgnx-wb-define-section 'a-files :slot 0 :title "Files" :buffer (drgnx-grid-atoms-test--buffer " *drgnx a-files*"))
    (should-not (assq 'a-side drgnx-wb--sections))
    (let ((w (drgnx-pane-show 'a-side)))
      (should (eq w (drgnx-wb-section-window 'a-files)))
      (should (eq (drgnx-pane-window 'a-side) w))
      (drgnx-pane-hide 'a-side)
      (should-not (drgnx-wb--dock-windows)))))

(provide 'grid-atoms-test)
;;; grid-atoms-test.el ends here
