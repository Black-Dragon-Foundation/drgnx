;;; monitors-fold-gui-test.el --- GUI test: a window on a monitor that goes away folds in and comes back (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; When a monitor goes away, each auxiliary window on it folds into the main window: its tabs join the main window's
;; editor, its tool panes the main window's docks, and the window closes; nothing is killed or asked.  When the
;; monitor returns, the window comes back where it was, with its buffers as they are now, and the main window gives
;; back what it took.  The monitors are faked (`display-monitor-attributes-list') in the rows without a tag; the
;; `:compositor' row unplugs a real one where the compositor lets a test do it (sway, `DRGNX_UI_MONITORS=2').

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(defconst drgnx-ui-monitors-fold--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST")
                                                         (file-name-directory (or load-file-name buffer-file-name))))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-monitors-fold--repo)))
(defvar drgnx-dir)
(setq drgnx-dir (or (bound-and-true-p drgnx-dir) drgnx-ui-monitors-fold--repo))
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-ui-monitors-fold--repo) nil t)
(require 'drgnx-grid)
(require 'drgnx-frames)
(require 'drgnx-grid-frames)
(require 'drgnx-monitors)

(defun drgnx-ui-monitors-fold--monitors (&rest names)
  "Monitors called NAMES, side by side, as `display-monitor-attributes-list' lists them."
  (let ((x 0))
    (mapcar (lambda (n) (prog1 (list (cons 'name n) (cons 'geometry (list x 0 1920 1080))
                                     (cons 'workarea (list x 0 1920 1080)))
                          (setq x (+ x 1920))))
            names)))

(defmacro drgnx-ui-monitors-fold--with (&rest body)
  "BODY with the grid fixture (its kinds: `g-chat' on the right), `drgnx-grid-mode' on, a main frame of its own,
monitors \"A\" and \"B\" (`monitors': set it to change them), nothing folded and prompts that signal; the frames BODY
made deleted after, the main role, the mode and the selected frame as they were."
  (declare (indent 0))
  `(progn
     (unless (display-graphic-p) (ert-skip "needs a graphical frame"))
     (let* ((frames (frame-list)) (selected (selected-frame)) (was drgnx-grid-mode)
            (old-main (drgnx-frames--main))
            (monitors (drgnx-ui-monitors-fold--monitors "A" "B"))
            (drgnx-grid--stack nil) (drgnx-monitors--folded nil) (drgnx-monitors--fold-seen nil))
       (unwind-protect
           (cl-letf (((symbol-function 'display-monitor-attributes-list) (lambda (&rest _) monitors))
                     ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "prompted")))
                     ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "prompted"))))
             (drgnx-grid-test--with
               (let ((main (make-frame '((width . 120) (height . 36)))))
                 (when old-main (set-frame-parameter old-main 'drgnx-frame-role nil))
                 (set-frame-parameter main 'drgnx-frame-role 'main)
                 (unless was (drgnx-grid-mode 1))
                 (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p main)) :secs 10 :what "the main frame mapped")
                 (select-frame main)
                 ,@body)))
         (drgnx-timer-cancel 'monitors-fold)
         (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
         (unless was (drgnx-grid-mode -1))
         (when (frame-live-p old-main) (set-frame-parameter old-main 'drgnx-frame-role 'main))
         (when (frame-live-p selected) (select-frame selected))))))

(defun drgnx-ui-monitors-fold--aux (buffers &optional kinds)
  "A new aux window on monitor \"B\": one editor holding BUFFERS as tabs (the last shown) and, with KINDS, a tool tile
of them to its right.  The selected frame stays."
  (let* ((id 50)
         (editor (list 'editor :id 1 :tabs (mapcar #'buffer-name buffers) :shown (buffer-name (car (last buffers)))
                       :point 1 :start 1))
         (tree (if kinds
                   (list 'row :px nil :share nil
                         (append (list 'editor :px 600 :share 0.6) (cdr editor))
                         (list 'tile :px 400 :share 0.4 :id 2 :kinds kinds :shown (car kinds) :dock nil :state nil))
                 editor))
         (snap (drgnx-grid-snapshot 'restore)))
    (plist-put snap :frames (append (plist-get snap :frames)
                                    (list (list :id id :role 'aux :tree tree :full nil))))
    (save-selected-window (drgnx-grid-restore snap))
    (let ((f (drgnx-grid--frame-by-id id)))
      (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p f)) :secs 10 :what "the aux frame mapped")
      (set-frame-parameter f 'drgnx-monitor (list :name "B" :geometry [1920 0 1920 1080]))
      f)))

(defun drgnx-ui-monitors-fold--main-tabs (main)
  (window-parameter (car (drgnx-grid-tiles main 'editor)) 'drgnx-tabs))

(ert-deftest drgnx-ui-monitors-fold/fold-moves-tabs-and-keeps-buffers ()
  (drgnx-ui-monitors-fold--with
    (let* ((a (get-buffer-create "*drgnx-fold-a*")) (b (get-buffer-create "*drgnx-fold-b*"))
           (aux (drgnx-ui-monitors-fold--aux (list a b))))
      (setq monitors (drgnx-ui-monitors-fold--monitors "A"))
      (drgnx-monitors--fold '(:name "B"))
      (should-not (frame-live-p aux))
      (should (buffer-live-p a))
      (should (buffer-live-p b))
      (should (memq a (drgnx-ui-monitors-fold--main-tabs main)))
      (should (memq b (drgnx-ui-monitors-fold--main-tabs main)))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest drgnx-ui-monitors-fold/fold-pushes-a-snapshot ()
  (drgnx-ui-monitors-fold--with
    (let* ((a (get-buffer-create "*drgnx-fold-a*")) (aux (drgnx-ui-monitors-fold--aux (list a))) (id (drgnx-grid-frame-id aux)))
      (setq monitors (drgnx-ui-monitors-fold--monitors "A"))
      (drgnx-monitors--fold '(:name "B"))
      (let ((snap (car drgnx-grid--stack)))
        (should (eq 'fold-in (plist-get snap :why)))
        (should (seq-find (lambda (s) (eql (plist-get s :id) id)) (plist-get snap :frames))))
      (kill-buffer a))))

(ert-deftest drgnx-ui-monitors-fold/fold-keeps-unsaved-and-returns ()
  ;; a modified buffer and a pane (the agent conversation's place: a tool tile) fold in and come back; nothing asks
  (drgnx-ui-monitors-fold--with
    (let* ((a (get-buffer-create "*drgnx-fold-a*"))
           (aux (progn (with-current-buffer a (insert "unsaved") (set-buffer-modified-p t))
                       (drgnx-ui-monitors-fold--aux (list a) '(g-chat))))
           (geometry (frame-position aux)))
      (setq monitors (drgnx-ui-monitors-fold--monitors "A"))
      (drgnx-monitors--fold '(:name "B"))
      (should-not (frame-live-p aux))
      (should (buffer-modified-p a))
      (should (memq a (drgnx-ui-monitors-fold--main-tabs main)))
      (should (drgnx-grid--tile-of 'g-chat main))                 ; the pane is on the main window's dock
      ;; the monitor returns: the window comes back, and the main window gives back its tab and pane
      (setq monitors (drgnx-ui-monitors-fold--monitors "A" "B"))
      (drgnx-monitors--unfold '(:name "B"))
      (let ((back (seq-find (lambda (f) (and (not (eq f main)) (not (memq f frames))
                                             (memq a (drgnx-grid--frame-buffers f))))
                            (frame-list))))
        (should (frame-live-p back))
        (should (drgnx-grid--tile-of 'g-chat back))
        (should-not (drgnx-grid--tile-of 'g-chat main))
        (should-not (memq a (drgnx-ui-monitors-fold--main-tabs main)))
        (should (buffer-modified-p a))
        (should (equal (car geometry) (car (frame-position back)))))
      (should-not drgnx-monitors--folded)
      (with-current-buffer a (set-buffer-modified-p nil))
      (kill-buffer a))))

(ert-deftest drgnx-ui-monitors-fold/return-brings-current-content ()
  (drgnx-ui-monitors-fold--with
    (let* ((a (get-buffer-create "*drgnx-fold-a*")))
      (drgnx-ui-monitors-fold--aux (list a))
      (setq monitors (drgnx-ui-monitors-fold--monitors "A"))
      (drgnx-monitors--fold '(:name "B"))
      (with-current-buffer a (insert "written while folded"))   ; edited in the main window meanwhile
      (setq monitors (drgnx-ui-monitors-fold--monitors "A" "B"))
      (drgnx-monitors--unfold '(:name "B"))
      (let* ((back (seq-find (lambda (f) (memq a (drgnx-grid--frame-buffers f)))
                             (remq main (frame-list))))
             (w (car (drgnx-grid-tiles back 'editor))))
        (should (eq (window-buffer w) a))
        (should (string-search "written while folded" (with-current-buffer (window-buffer w) (buffer-string)))))
      (kill-buffer a))))

(ert-deftest drgnx-ui-monitors-fold/fold-and-return ()
  ;; a real monitor unplugged and plugged back (sway: `swaymsg output NAME disable'), through the hook and its debounce
  :tags '(:compositor)
  (let ((monitors (display-monitor-attributes-list)))
    (unless (and (cdr monitors) (getenv "SWAYSOCK") (executable-find "swaymsg"))
      (ert-skip "needs sway with two monitors (DRGNX_UI_MONITORS=2)"))
    (let* ((second (alist-get 'name (cadr monitors)))
           (frames (frame-list)) (drgnx-monitors--folded nil) (drgnx-monitors--fold-seen nil)
           (a (get-buffer-create "*drgnx-fold-a*"))
           (aux (drgnx-frames--new a (list a))))
      (unwind-protect
          (progn
            (drgnx-test-wait (lambda () (redisplay t) (frame-visible-p aux)) :secs 10 :what "the aux window mapped")
            (set-frame-parameter aux 'drgnx-monitor (list :name second))
            (add-hook 'display-monitors-changed-functions #'drgnx-monitors--monitors-changed)
            (call-process "swaymsg" nil nil nil "output" second "disable")
            (drgnx-test-wait (lambda () (not (frame-live-p aux))) :secs 10 :what "the window folded in")
            (should (buffer-live-p a))
            (call-process "swaymsg" nil nil nil "output" second "enable")
            (drgnx-test-wait (lambda () (seq-find (lambda (f) (and (not (memq f frames)) (memq a (drgnx-grid--frame-buffers f))))
                                                  (frame-list)))
                             :secs 10 :what "the window back"))
        (call-process "swaymsg" nil nil nil "output" second "enable")
        (remove-hook 'display-monitors-changed-functions #'drgnx-monitors--monitors-changed)
        (drgnx-timer-cancel 'monitors-fold)
        (dolist (f (frame-list)) (unless (memq f frames) (delete-frame f t)))
        (kill-buffer a)))))

(provide 'monitors-fold-gui-test)
;;; monitors-fold-gui-test.el ends here
