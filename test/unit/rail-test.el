;;; rail-test.el --- batch tests: the layout A rail -*- lexical-binding: t -*-
;; test-class: det
;; The rail's places and their commands, what a click on the current place does, the dot's label, the rail window beside
;; the status bar across the frame, and its teardown.  The rail's width in px at every scale is a GUI row
;; (test/ui/rail-gui-test.el).
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-chrome)
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-rail" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)
(require 'drgnx-notices)

(defvar drgnx-rail-test--log nil "What the stubbed side bar and commands were asked, newest first.")

(defmacro drgnx-rail-test--sidebar (showing view &rest body)
  "BODY with the side bar stubbed: SHOWING (a form) whether it shows, VIEW (a form) its view; every show, hide and
command is logged in `drgnx-rail-test--log'."
  (declare (indent 2))
  `(let ((drgnx-rail-test--log nil))
     (cl-letf (((symbol-function 'drgnx-wb-sidebar-showing-p) (lambda (&optional _) ,showing))
               ((symbol-function 'drgnx-wb-sidebar-view) (lambda (&optional _) ,view))
               ((symbol-function 'drgnx-wb-show-view) (lambda (v) (push (list 'show v) drgnx-rail-test--log)))
               ((symbol-function 'drgnx-wb-hide-sidebar) (lambda () (push '(hide) drgnx-rail-test--log)))
               ((symbol-function 'drgnx-ui-kit-run) (lambda (c) (push (list 'run c) drgnx-rail-test--log))))
       (set-frame-parameter nil 'drgnx-rail-place nil)
       (unwind-protect (progn ,@body)
         (set-frame-parameter nil 'drgnx-rail-place nil)))))

(ert-deftest drgnx-rail/places-in-order-and-registered ()
  (should (equal '(work files search changes run machines extensions) (mapcar #'car drgnx-rail-places)))
  (should (equal '(place-work place-files place-search place-changes place-run place-machines place-extensions)
                 (mapcar (lambda (p) (nth 3 p)) drgnx-rail-places)))
  (unwind-protect
      (progn
        (drgnx-rail-define-commands)
        (dolist (p drgnx-rail-places)
          (let ((cmd (gethash (nth 3 p) drgnx-commands--table)))
            (should cmd)
            (should (commandp (drgnx-cmd-command cmd)))
            (should (equal "View" (drgnx-cmd-category cmd)))
            (should (string-prefix-p "Go to " (drgnx-cmd-title cmd))))))
    (dolist (p drgnx-rail-places) (drgnx-command-undefine (nth 3 p)))))

(ert-deftest drgnx-rail/current-place-click-toggles-the-side-bar ()
  ;; a place whose view is not shown shows it; the current place, with its view shown, hides the side bar
  (drgnx-rail-test--sidebar nil 'explorer
    (drgnx-rail-go 'files)
    (should (equal '((run view-explorer)) drgnx-rail-test--log)))
  (drgnx-rail-test--sidebar t 'explorer
    (should (eq 'files (drgnx-rail-current)))
    (drgnx-rail-go 'files)
    (should (equal '((hide)) drgnx-rail-test--log)))
  ;; another place while the side bar shows Files: that place's view, not a toggle
  (drgnx-rail-test--sidebar t 'explorer
    (drgnx-rail-go 'search)
    (should (equal '((run view-search)) drgnx-rail-test--log)))
  ;; Run has only its view
  (drgnx-rail-test--sidebar t 'explorer
    (drgnx-rail-go 'run)
    (should (equal '((show debug)) drgnx-rail-test--log)))
  ;; Work is no side bar view: it opens in the editor area and is current until another place is chosen; again, it
  ;; opens again (nothing to hide)
  (drgnx-rail-test--sidebar t 'explorer
    (drgnx-rail-go 'work)
    (should (equal '((run work-view)) drgnx-rail-test--log))
    (should (eq 'work (drgnx-rail-current)))
    (drgnx-rail-go 'files)
    (should (eq 'files (drgnx-rail-current)))))

(ert-deftest drgnx-rail/changed-dot-is-labelled ()
  (let ((drgnx-rail--changed nil))
    (cl-letf (((symbol-function 'drgnx-rail-refresh) #'ignore))
      (drgnx-rail-mark-changed 'changes))
    (should (equal '(changes) drgnx-rail--changed))
    (let ((dot (drgnx-ui-kit-rail-item 'changes 'git-branch "Changes" 'rest t 'text))
          (plain (drgnx-ui-kit-rail-item 'changes 'git-branch "Changes" 'rest nil 'text)))
      (should (equal "Changes, changed" (get-text-property 0 'help-echo dot)))
      (should (equal "Changes" (get-text-property 0 'help-echo plain)))
      (should (cl-some (lambda (i) (memq 'drgnx-kit-rail-item-dot (ensure-list (get-text-property i 'face dot))))
                       (number-sequence 0 (1- (length dot)))))
      (should-not (cl-some (lambda (i) (memq 'drgnx-kit-rail-item-dot (ensure-list (get-text-property i 'face plain))))
                           (number-sequence 0 (1- (length plain))))))
    ;; going to the place takes the dot off
    (drgnx-rail-test--sidebar nil nil
      (cl-letf (((symbol-function 'drgnx-rail-refresh) #'ignore))
        (drgnx-rail-go 'changes))
      (should-not drgnx-rail--changed))))

(defmacro drgnx-rail-test--with-frame (&rest body)
  "BODY with the grid backend, the bar across the frame (in batch too) and the rail on, everything put back after."
  (declare (indent 0))
  `(drgnx-grid-test--with
     (let ((drgnx-statusbar-place 'frame) (drgnx-statusbar--frame-in-batch t)
           (drgnx-statusbar--segments (make-hash-table :test #'eq)) (drgnx-statusbar--texts (make-hash-table :test #'eq))
           (drgnx-statusbar--errors nil) (drgnx-statusbar-left nil) (drgnx-statusbar-right nil) (drgnx-statusbar-other nil)
           (drgnx-statusbar--window nil) (was drgnx-statusbar-mode))
       (drgnx-state-define-role 'statusbar)
       (unwind-protect (progn (drgnx-statusbar-mode 1) ,@body)
         (drgnx-rail-mode -1)
         (drgnx-statusbar-mode (if was 1 -1))
         (dolist (w (window-list nil 'nomini))
           (when (memq (window-parameter w 'drgnx-role) '(statusbar rail)) (ignore-errors (delete-window w))))))))

(defun drgnx-rail-test--role (role)
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-role) role)) (window-list nil 'nomini)))

(ert-deftest drgnx-rail/the-rail-and-the-bar-split-the-frame-together ()
  ;; the rail is a left side window outside the grid; the bar is still the root's last child, as wide as the frame, under
  ;; it; the grid's root is the editor area between them (geometry has two owners: the bar's root split and the side
  ;; window, `drgnx-statusbar--side-window')
  (drgnx-rail-test--with-frame
    (drgnx-rail-mode 1)
    (let ((rail (drgnx-rail-test--role 'rail)) (bar (drgnx-rail-test--role 'statusbar)))
      (should rail)
      (should bar)
      (should (eq 'left (window-parameter rail 'window-side)))
      (should (= 0 (nth 0 (window-edges rail))))
      (should (= 3 (window-body-width rail)))             ; a terminal's: 3 columns
      ;; the bar spans the frame and is the root's last child, under the rail
      (should (eq (window-parent bar) (frame-root-window)))
      (should (null (window-next-sibling bar)))
      (should (= (window-total-width bar) (window-total-width (frame-root-window))))
      (should (<= (nth 3 (window-edges rail)) (nth 1 (window-edges bar))))
      ;; the grid's root is right of the rail, above the bar
      (let ((root (drgnx-grid-root)))
        (should (>= (nth 0 (window-edges root)) (nth 2 (window-edges rail))))
        (should (<= (nth 3 (window-edges root)) (nth 1 (window-edges bar)))))
      ;; once: drawing again changes nothing
      (drgnx-rail--ensure (selected-frame))
      (drgnx-statusbar--frame-ensure (selected-frame))
      (should (= 1 (cl-count-if (lambda (w) (eq (window-parameter w 'drgnx-role) 'rail)) (window-list nil 'nomini))))
      (should (= 1 (cl-count-if (lambda (w) (eq (window-parameter w 'drgnx-role) 'statusbar)) (window-list nil 'nomini)))))))

(ert-deftest drgnx-rail/a-hidden-frame-has-no-rail ()
  (drgnx-rail-test--with-frame
    (drgnx-rail-mode 1)
    (should (drgnx-rail-test--role 'rail))
    (set-frame-parameter nil 'drgnx-rail 'hidden)
    (unwind-protect
        (progn (drgnx-rail--ensure (selected-frame))
               (should-not (drgnx-rail-test--role 'rail)))
      (set-frame-parameter nil 'drgnx-rail nil))
    (drgnx-rail--ensure (selected-frame))
    (should (drgnx-rail-test--role 'rail))))

(ert-deftest drgnx-rail/teardown-removes-the-rail ()
  (drgnx-rail-test--with-frame
    (drgnx-rail-mode 1)
    (should (drgnx-rail-test--role 'rail))
    (should (memq #'drgnx-rail--scale-changed drgnx-look-density-changed-hook))
    (should (cl-some (lambda (b) (string-prefix-p drgnx-rail-buffer-prefix (buffer-name b))) (buffer-list)))
    (drgnx-rail-mode -1)
    (should-not (drgnx-rail-test--role 'rail))
    (should-not (memq #'drgnx-rail--scale-changed drgnx-look-density-changed-hook))
    (should-not (cl-some (lambda (b) (string-prefix-p drgnx-rail-buffer-prefix (buffer-name b))) (buffer-list)))
    (should-not (drgnx-state--lane-of 'windows-changed #'drgnx-rail--windows-changed))))

(provide 'rail-test)
;;; rail-test.el ends here
