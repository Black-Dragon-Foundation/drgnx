;;; grid-persist-test.el --- batch tests: the grid survives a restart (format 3, the migration from 2, placeholders) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(require 'drgnx-persist)

(defun drgnx-grid-persist-test--gui (frame)
  "`drgnx-state-frame-kind' for these tests: batch Emacs's frames are graphical windows (they are `tty' for the store)."
  (and (framep frame) (frame-live-p frame) 'gui))

(defmacro drgnx-grid-persist-test--with (&rest body)
  "BODY in the grid fixture (`drgnx-grid-test--with') with a state file of its own."
  (declare (indent 0))
  `(drgnx-grid-test--with
     (let* ((dir (file-name-as-directory (make-temp-file "drgnx-grid-persist" t)))
            (drgnx-persist-file (expand-file-name "state.eld" dir))
            (drgnx-persist--pending nil))
       (cl-letf (((symbol-function 'drgnx-state-frame-kind) #'drgnx-grid-persist-test--gui))
         (unwind-protect (progn ,@body)
           (drgnx-timer-cancel 'persist-visit)
           (drgnx-persist--refit-done)
           (dolist (f (frame-list)) (unless (eq f (selected-frame)) (delete-frame f t)))
           (delete-directory dir t))))))

(defun drgnx-grid-persist-test--write (state)
  (with-temp-file drgnx-persist-file (let ((print-length nil) (print-level nil)) (prin1 state (current-buffer)))))

(defun drgnx-grid-persist-test--near (a b) (<= (abs (- a b)) 1))

(ert-deftest drgnx-persist-grid/save-and-restore-the-grid ()
  ;; a terminal tile moved right of the editor comes back there, at its size
  (drgnx-grid-persist-test--with
    (drgnx-pane-show 'g-term)
    (drgnx-grid-move (drgnx-pane-window 'g-term) (car (drgnx-grid-tiles nil 'editor)) 'right)
    (let ((edges (window-pixel-edges (drgnx-pane-window 'g-term)))
          (editor (window-pixel-edges (car (drgnx-grid-tiles nil 'editor)))))
      (should (> (nth 0 edges) (nth 0 editor)))
      (should (drgnx-persist-save))
      (drgnx-grid-test--reset)
      (should-not (drgnx-pane-window 'g-term))
      (should (drgnx-persist-restore))
      (let ((w (drgnx-pane-window 'g-term)))
        (should (window-live-p w))
        (should (cl-every #'drgnx-grid-persist-test--near (window-pixel-edges w) edges))
        (should (cl-every #'drgnx-grid-persist-test--near (window-pixel-edges (car (drgnx-grid-tiles nil 'editor)))
                          editor))))))

(defconst drgnx-grid-persist-test--v2
  '(:version 2 :frames ((:role main :left (:shown t :view explorer :px 30) :panel (:shown t :tab output :px 12)
                               :right (:shown t :tab nil :px 40) :roots nil :main nil
                               :groups ((:tabs nil :shown nil :px 78)) :extra nil)))
  "A state file as drgnx wrote it before the grid (format 2): the side bar, the panel and the right side shown.")

(ert-deftest drgnx-persist-grid/a-format-2-state-comes-back-as-a-grid ()
  (drgnx-grid-persist-test--with
    (drgnx-wb-define-section 'top :slot 0 :title "TOP" :buffer (drgnx-grid-test--buffer " *drgnx g-top*"))
    (drgnx-grid-persist-test--write drgnx-grid-persist-test--v2)
    (should (drgnx-persist-restore))
    (let ((left (seq-find (lambda (w) (eq (window-parameter w 'drgnx-tile-dock) 'left)) (window-list nil 'nomini))) (panel (drgnx-wb-area-window 'panel))
          (right (drgnx-wb-area-window 'right)))
      (should (window-live-p left))
      (should (drgnx-grid-persist-test--near (window-pixel-width left) 30))
      (should (window-live-p panel))
      (should (drgnx-grid-persist-test--near (window-pixel-height panel) 12))
      (should (eq (drgnx-wb-area-tab 'panel) 'output))
      (should (window-live-p right))
      (should (drgnx-grid-persist-test--near (window-pixel-width right) 40))
      ;; they are tiles of the grid, and its tree says so: the sizes came back as intent
      (should (equal (mapcar (lambda (l) (plist-get (cdr l) :dock)) (drgnx-grid-tree-leaves (drgnx-grid-tree)))
                     '(left nil bottom right)))
      (should (eql 30 (plist-get (drgnx-state-intent nil :sizes 'left) :px)))
      (should (eql 40 (plist-get (drgnx-state-intent nil :sizes 'right) :px))))
    ;; and the next save writes format 3
    (drgnx-persist-save)
    (should (eql 3 (plist-get (drgnx-persist--read drgnx-persist-file) :version)))))

(ert-deftest drgnx-persist-grid/unknown-kinds-wait-for-their-module ()
  (drgnx-grid-persist-test--with
    (drgnx-grid-persist-test--write
     '(:version 3 :frames ((:role main
                                  :tree (row :px nil :share nil
                                             (editor :px 100 :share 0.625 :id 1 :tabs nil :shown nil)
                                             (tile :px 60 :share 0.375 :id 2 :kinds (g-later) :shown g-later :dock nil
                                                   :state nil))))))
    (should (drgnx-persist-restore))
    (let ((w (drgnx-grid--tile-by-id 2 (selected-frame))))
      (should (window-live-p w))
      (should (equal (buffer-name (window-buffer w)) " *drgnx tile: g-later*"))
      (should (string-match-p "g-later · waits for its module"
                              (with-current-buffer (window-buffer w) (buffer-string))))
      ;; its module defines it: the tile fills in place
      (drgnx-pane-define-kind 'g-later :title "Later" :home 'right :buffer (drgnx-grid-test--buffer " *drgnx g-later*"))
      (should (eq (drgnx-grid--tile-by-id 2 (selected-frame)) w))
      (should (equal (buffer-name (window-buffer w)) " *drgnx g-later*")))))

(ert-deftest drgnx-persist-grid/a-crafted-tree-sets-nothing ()
  ;; junk, too deep, huge sizes, window parameters: nothing of it is built, the frame stays usable, one notice
  (drgnx-grid-persist-test--with
    (let ((deep '(editor :px 1 :share 1 :id 9)))
      (dotimes (_ 40) (setq deep (list 'row :px 10 :share 0.5 deep '(editor :px 1 :share 0.5))))
      (drgnx-grid-persist-test--write
       `(:version 3 :frames ((:role main :tree (row :px nil :share nil
                                                    (editor :px 99999999 :share 7 :id 1 :tabs ("x"))
                                                    (tile :px 10 :share 0.5 :id 2 :kinds ("not a symbol")
                                                          :state (:parameters ((delete-window . kill-emacs))))))
                             (:role aux :tree ,deep)
                             (:role aux :tree (window-state (parameters (delete-window . kill-emacs))))))))
    (drgnx-notice-clear 'wb 'workbench-tree)
    (should (drgnx-persist-restore))
    (should (= 1 (length (drgnx-grid-tiles nil 'editor))))
    (should-not (seq-some (lambda (w) (window-parameter w 'delete-window)) (window-list nil 'nomini)))
    (should (= 1 (length (seq-filter (lambda (n) (eq (plist-get n :id) 'workbench-tree)) (drgnx-notices :source 'wb)))))
    ;; usable: a split still works
    (should (window-live-p (drgnx-groups-split-right)))))

(ert-deftest drgnx-persist-grid/two-monitor-layout-on-one-monitor ()
  ;; Review Focus 2: saved on two monitors at scale 2 and 1; this session has one monitor at scale 1.  Until the fold
  ;; (Task 16) the second window is made where the window manager puts it, on the one monitor there is; each window's
  ;; shares come back.  Batch Emacs makes no second frame: the second window is restored into the same one, after.
  ;; Both trees are rows: a batch frame's 80 columns hold the shares to ±0.005, its few dozen lines do not.
  (drgnx-grid-persist-test--with
    (with-current-buffer (messages-buffer) (let ((inhibit-read-only t)) (erase-buffer)))
    (drgnx-grid-persist-test--write
     '(:version 3 :frames ((:role main :monitor ("eDP-1" "Laptop" 2) :geometry (0 0 1600 1000)
                                  :tree (row :px nil :share nil
                                             (editor :px 480 :share 0.6 :id 1 :tabs nil :shown nil)
                                             (tile :px 320 :share 0.4 :id 2 :kinds (g-chat) :shown g-chat :dock nil
                                                   :state nil)))
                           (:role aux :monitor ("HDMI-1" "Desk" 1) :geometry (1600 0 1920 1080)
                                  :tree (row :px nil :share nil
                                             (editor :px 480 :share 0.25 :id 1 :tabs nil :shown nil)
                                             (editor :px 1440 :share 0.75 :id 2 :tabs nil :shown nil))))))
    (let* ((shares nil) (restore (symbol-function 'drgnx-persist--restore-frame)))
      (cl-letf (((symbol-function 'make-frame) (lambda (&rest _) (selected-frame)))
                ((symbol-function 'select-frame-set-input-focus) #'ignore)
                ((symbol-function 'drgnx-persist--restore-frame)
                 (lambda (st) (prog1 (funcall restore st)
                                (push (mapcar (lambda (l) (plist-get (cdr l) :share))
                                              (drgnx-grid-tree-leaves (drgnx-grid-tree)))
                                      shares)))))
        (should (drgnx-persist-restore)))
      (setq shares (nreverse shares))
      (should (= 2 (length shares)))
      (should (cl-every (lambda (a b) (<= (abs (- a b)) 0.005)) (nth 0 shares) '(0.6 0.4)))
      (should (cl-every (lambda (a b) (<= (abs (- a b)) 0.005)) (nth 1 shares) '(0.25 0.75))))
    (should-not (string-match-p "rror" (with-current-buffer (messages-buffer) (buffer-string))))))

(defun drgnx-grid-persist-test--later-setup ()
  "A module's setup: the kind `g-later', a right kind with a buffer of its own."
  (drgnx-pane-define-kind 'g-later :title "Later" :home 'right :buffer (drgnx-grid-test--buffer " *drgnx g-later*")))

(ert-deftest drgnx-grid/a-module-off-leaves-a-placeholder-and-fills-again ()
  ;; Review Focus 5: the module of a kind whose tile is in the live layout and in a saved one goes off, then on
  (drgnx-test-with-modules nil
    (drgnx-grid-persist-test--with
      (setf (alist-get 'test/later drgnx-modules--table)
            (list :doc "test" :stage 'startup :setup #'drgnx-grid-persist-test--later-setup))
      (should-not (drgnx-modules--run-setup 'test/later #'drgnx-grid-persist-test--later-setup))
      (drgnx-modules--record 'test/later 'startup 0 'ok)
      (drgnx-pane-show 'g-later)
      (drgnx-grid-move (drgnx-pane-window 'g-later) (car (drgnx-grid-tiles nil 'editor)) 'below)
      (let* ((w (drgnx-pane-window 'g-later)) (tree (drgnx-grid-tree)) (saved (drgnx-grid-snapshot 'test)))
        (should (eq (window-buffer w) (get-buffer " *drgnx g-later*")))
        (should-not (drgnx-module-teardown 'test/later))
        (should-not (drgnx-pane-kind 'g-later))
        ;; the tile stays where it was, the tree and sizes as they were, and it waits as a placeholder
        (should (window-live-p w))
        (should (equal (drgnx-grid-tree) tree))
        (should (equal (buffer-name (window-buffer w)) " *drgnx tile: g-later*"))
        ;; the saved layout keeps the kind
        (should (member '(g-later) (mapcar (lambda (l) (plist-get (cdr l) :kinds))
                                           (drgnx-grid-tree-leaves (plist-get (car (plist-get saved :frames)) :tree)))))
        ;; on again: the placeholder fills
        (should-not (drgnx-modules--run-setup 'test/later #'drgnx-grid-persist-test--later-setup))
        (drgnx-modules--record 'test/later 'startup 0 'ok)
        (should (eq (window-buffer w) (get-buffer " *drgnx g-later*")))
        (should (equal (drgnx-grid-tree) tree))
        (drgnx-module-teardown 'test/later)))))

(provide 'grid-persist-test)
;;; grid-persist-test.el ends here
