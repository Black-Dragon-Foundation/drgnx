;;; menubar-gui-test.el --- GUI tests: the menu bar in the title row (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; A real session on Nidhogg's native shell: the title row shows the eight menus, and File opens as Nidhogg's own
;; child-frame menu under its title, its rows the registry's titles with the profile's keys.  The menu reads its own
;; events, so the rows look at it from a timer while it is open and then answer it.

(require 'ert)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-menubar--repo               ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-menubar--repo)))
(require 'drgnx)
(require 'drgnx-state)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-menubar--repo) nil t)
(dolist (m '("ui/drgnx-face" "ui/drgnx-statusbar" "ui/drgnx-menubar" "ui/drgnx-topline"))
  (load (expand-file-name (concat "modules/" m) drgnx-ui-menubar--repo) nil t))
(declare-function nhwl-menu--live-frames "nhwl-menu")
(defvar nhwl-menu--frames)

(defvar drgnx-ui-menubar--ran nil "Non-nil once the stub New File ran.")
(defun drgnx-ui-menubar--new () (interactive) (setq drgnx-ui-menubar--ran t))

(defun drgnx-ui-menubar--seen ()
  "Each open menu frame as (X Y TEXT): where its popup hangs from the window (its `nhwl-popup' anchor) and what its
buffer shows."
  (mapcar (lambda (f)
            (let ((anchor (frame-parameter f 'nhwl-popup)))
              (list (nth 0 anchor) (nth 1 anchor)
                    (with-current-buffer (window-buffer (frame-root-window f)) (buffer-string)))))
          (nhwl-menu--live-frames)))

(defun drgnx-ui-menubar--open-and-look (id)
  "Open menu ID, look at it while it is open, choose its first row; what was seen."
  (let (seen)
    ;; a menu opened by a click has no row selected: Down selects the first, Enter runs it
    (run-at-time 0.8 nil (lambda ()
                           (setq seen (drgnx-ui-menubar--seen))
                           (setq unread-command-events (list 'down 'return))))
    (with-timeout (15 (error "The %s menu never closed" id))   ; a red fails, never hangs
      (drgnx-menubar-open id))
    (car (last seen))))

(drgnx-look-gui-deftest drgnx-ui-menubar/a-menu-opens-under-its-title-with-the-profiles-keys ()
  "The title row has File first and Help last; File opens as a child-frame menu whose first row is New File with the
key the profile gives it, and Enter on it runs the command; Edit, the second title, opens under its own left edge,
below the title row."
  (skip-unless (and (display-graphic-p) (fboundp 'nhwl-menu--live-frames)))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*menubar-gui*"))
        (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (switch-to-buffer buf)
    (unwind-protect
        (progn
          (drgnx-command-define 'file-new :title "New File" :category "File" :command #'drgnx-ui-menubar--new)
          (drgnx-command-define 'edit-undo :title "Undo" :category "Edit" :command #'drgnx-ui-menubar--new)
          (setf (drgnx-cmd-bound (drgnx-commands-get 'file-new)) '(("C-n" . nil)))
          (drgnx-menubar-setup)
          (drgnx-topline-setup)
          (drgnx-memo-forget 'topline)
          (force-mode-line-update t)
          (drgnx-test-wait-presented)
          (let* ((items (drgnx-topline--line))
                 (measure (drgnx-statusbar--measure-fn nil 'tab-bar))
                 (at (cl-position 'drgnx-topline-menu-edit (mapcar #'car items)))
                 (left (and at (drgnx-topline--width (seq-take items at) measure))))
            (should (eq (car (car items)) 'drgnx-topline-menu-file))   ; the row's first item
            (should (memq 'drgnx-topline-menu-help (mapcar #'car items)))
            (should (> left 0))
            ;; File: the profile's key on its row, Enter runs it
            (setq drgnx-ui-menubar--ran nil)
            (let ((file (drgnx-ui-menubar--open-and-look 'file)))
              (should file)
              (should (string-match-p "New File" (nth 2 file)))
              (should (string-match-p "C-n" (nth 2 file)))
              (should drgnx-ui-menubar--ran))
            ;; Edit: under its title, as the click on it left it
            (drgnx-menubar-note-click 'drgnx-topline-menu-edit left (selected-frame))
            (let ((edit (drgnx-ui-menubar--open-and-look 'edit)))
              (should edit)
              (should (string-match-p "Undo" (nth 2 edit)))
              (should (<= (abs (- (nth 0 edit) left)) 2))
              (should (>= (nth 1 edit) (tab-bar-height nil t))))))
      (drgnx-topline--off)
      (drgnx-menubar-off)
      ;; Nidhogg keeps its menu frames for the next menu: the row takes them back with it
      (mapc (lambda (f) (delete-frame f t)) (nhwl-menu--live-frames))
      (setq nhwl-menu--frames nil)
      (kill-buffer buf))))

(provide 'menubar-gui-test)
;;; menubar-gui-test.el ends here
