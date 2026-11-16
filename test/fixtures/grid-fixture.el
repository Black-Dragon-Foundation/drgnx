;;; grid-fixture.el --- the grid tests' frame: the grid backend, one editor window and four kinds -*- lexical-binding: t -*-
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(require 'drgnx-grid)
(require 'drgnx-area)

(defun drgnx-grid-test--buffer (name)
  (lambda () (with-current-buffer (get-buffer-create name t) (special-mode) (current-buffer))))

(defun drgnx-grid-test--reset ()
  "Back to one editor window, no tiles, no grid memory."
  (let ((ignore-window-parameters t)) (delete-other-windows))
  (dolist (p '(drgnx-tile-id drgnx-role drgnx-pane-stack drgnx-tile-dock no-delete-other-windows delete-window
                             tab-line-format window-preserved-size))
    (set-window-parameter nil p nil))
  (set-window-dedicated-p nil nil)
  (dolist (p '(drgnx-grid-memory drgnx-grid-next-id drgnx-intent-by drgnx-wb-panel-px drgnx-wb-right-px
                                 drgnx-wb-dock-px drgnx-wb-areas))
    (set-frame-parameter nil p nil))
  (remhash (selected-frame) drgnx-grid--kinds))

(defmacro drgnx-grid-test--with (&rest body)
  "BODY with the grid backend, a 160 × 50 frame of one editor window and four kinds: `g-term' and `g-problems' at
the bottom, `g-chat' at the right, `g-tree' at the left."
  (declare (indent 0))
  `(drgnx-test-with-state
     (let ((drgnx-pane--kinds nil) (drgnx-pane-backend 'grid) (drgnx-state--kind-owners nil)
           (drgnx-wb--sections nil) (drgnx-wb--areas (copy-tree drgnx-wb--areas))
           (drgnx-rules--table (copy-sequence drgnx-rules--table))
           (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
           (window-min-width 2) (window-min-height 2))
       (set-frame-size nil 160 50)
       (drgnx-grid-test--reset)
       (drgnx-pane-define-kind 'g-term :title "Term" :home 'bottom :size 10
                               :placeholder (drgnx-grid-test--buffer " *drgnx g-term*"))
       (drgnx-pane-define-kind 'g-problems :title "Problems" :home 'bottom
                               :placeholder (drgnx-grid-test--buffer " *drgnx g-problems*"))
       (drgnx-pane-define-kind 'g-chat :title "Chat" :home 'right :size 40
                               :placeholder (drgnx-grid-test--buffer " *drgnx g-chat*"))
       (drgnx-pane-define-kind 'g-tree :title "Tree" :home 'left :size 30
                               :buffer (drgnx-grid-test--buffer " *drgnx g-tree*"))
       (drgnx-state-sync)
       (unwind-protect (progn ,@body)
         (drgnx-grid-test--reset)
         (dolist (b (buffer-list))
           (when (string-match-p "\\` \\*drgnx g-\\|\\`\\*g-" (buffer-name b)) (kill-buffer b)))))))

(defun drgnx-grid-test--edges (&optional except)
  "Alist WINDOW → pixel edges of every live window on the frame but EXCEPT."
  (mapcar (lambda (w) (cons w (window-pixel-edges w))) (remq except (window-list nil 'nomini))))

(provide 'drgnx-grid-fixture)
;;; grid-fixture.el ends here
