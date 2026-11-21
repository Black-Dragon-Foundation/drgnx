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
(dolist (m '("ui/drgnx-look-density" "ui/drgnx-face" "ui/drgnx-statusbar" "ui/drgnx-menubar" "ui/drgnx-topline"))
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
  "Open menu ID, look at it while it is open, choose its first row; what was seen.  The menu's own reads get the
keys: the first, once the menu is drawn, looks at it; a menu that reads on past its keys is a failure, never a hang."
  (let ((seen nil) (keys (list 'down 'return)) (idle 0))
    ;; a menu opened by a click has no row selected: Down selects the first, Enter runs it
    (cl-letf (((symbol-function 'read-event)
               (lambda (&rest _)
                 (cond (keys (unless seen (redisplay t) (setq seen (drgnx-ui-menubar--seen)))
                             (pop keys))
                       ((< (cl-incf idle) 50) nil)   ; "nothing came": the drain after the menu closes
                       (t (error "The %s menu read on past its keys" id))))))
      (drgnx-menubar-open id))
    (car (last seen))))

(drgnx-look-gui-deftest drgnx-ui-menubar/a-menu-opens-under-its-title-with-the-profiles-keys ()
  "The title row has the menu button after the logo and no menu words; File opens as a child-frame menu whose first row is New File with the
key the profile gives it, and Enter on it runs the command; a menu opened after a click on the menu button opens under
the button's left edge, below the title row."
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
                 (at (cl-position 'drgnx-topline-menu (mapcar #'car items)))
                 (left (and at (drgnx-topline--width (seq-take items at) measure))))
            (should (eq (car (cadr items)) 'drgnx-topline-menu))   ; the logo, then the menu button
            (should-not (memq 'drgnx-topline-menu-help (mapcar #'car items)))   ; no menu words
            (should (> left 0))
            ;; File: the profile's key on its row, Enter runs it
            (setq drgnx-ui-menubar--ran nil)
            (let ((file (drgnx-ui-menubar--open-and-look 'file)))
              (should file)
              (should (string-match-p "New File" (nth 2 file)))
              (should (string-match-p "C-n" (nth 2 file)))
              (should drgnx-ui-menubar--ran))
            ;; Edit, opened as the menu button's list opens a menu: under the button, as the click on it left it
            (drgnx-menubar-note-click 'drgnx-topline-menu left (selected-frame))
            (let ((edit (drgnx-ui-menubar--open-and-look 'file)))
              (should edit)
              (should (string-match-p "New File" (nth 2 edit)))
              (should (<= (abs (- (nth 0 edit) left)) 2))
              (should (>= (nth 1 edit) (tab-bar-height nil t))))))
      (drgnx-topline--off)
      (drgnx-menubar-off)
      ;; Nidhogg keeps its menu frames for the next menu: the row takes them back with it
      (mapc (lambda (f) (delete-frame f t)) (nhwl-menu--live-frames))
      (setq nhwl-menu--frames nil)
      (kill-buffer buf))))

(defun drgnx-ui-menubar--menu-look-on ()
  "ui/face's part for Nidhogg's menus (drgnx-menu-look.el), set up as the test's own module."
  (let ((drgnx-modules--current 'test/menu-look) (drgnx-modules--setup-load load-file-name))
    (drgnx-menu-look-setup)))

(defun drgnx-ui-menubar--menu-look-off ()
  "Tear down what `drgnx-ui-menubar--menu-look-on' set up."
  (should-not (drgnx-modules--unwind 'test/menu-look)))

(defun drgnx-ui-menubar--measure (id)
  "Open menu ID, measure its card while it is open (as `drgnx-ui-menubar--open-and-look'), close it by Esc: a plist of
the menu text's face family, its first row's height and its frame's ring, in the menu frame's pixels."
  (let ((seen nil) (keys (list 'down 'escape)) (idle 0))
    (cl-letf (((symbol-function 'read-event)
               (lambda (&rest _)
                 (cond (keys (unless seen
                               (redisplay t)
                               (let* ((f (car (last (nhwl-menu--live-frames)))) (win (frame-root-window f)))
                                 (setq seen
                                       (with-current-buffer (window-buffer win)
                                         (list :family (face-attribute 'nhwl-menu :family f t)
                                               :height (face-attribute 'nhwl-menu :height f t)
                                               :row (cdr (window-text-pixel-size win (point-min)
                                                                                 (save-excursion (goto-char (point-min)) (line-end-position))))
                                               :ring (frame-parameter f 'child-frame-border-width)
                                               :frame f)))))
                             (pop keys))
                       ((< (cl-incf idle) 50) nil)
                       (t (error "The %s menu read on past its keys" id))))))
      (drgnx-menubar-open id))
    seen))

(drgnx-look-gui-deftest drgnx-ui-menubar/the-menus-follow-the-look ()
  "The menu cards (the menu button's list, the context menus) are the look's: the UI sans at the UI size, rows at least
the density's tree row high; not the stock fixed-pitch 13 px with rows one text line high."
  (skip-unless (and (display-graphic-p) (fboundp 'nhwl-menu--live-frames)))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*menubar-look*")) (main (selected-frame))
        (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (switch-to-buffer buf)
    (unwind-protect
        (progn
          (drgnx-command-define 'file-new :title "New File" :category "File" :command #'drgnx-ui-menubar--new)
          (drgnx-menubar-setup)
          (drgnx-ui-menubar--menu-look-on)
          (drgnx-topline-setup)
          (drgnx-test-wait-presented)
          (let ((m (drgnx-ui-menubar--measure 'file)))
            (should m)
            (should (equal (plist-get m :family) (face-attribute 'drgnx-ui-text :family main t)))
            (should (>= (plist-get m :row) (1- (drgnx-px 26 main))))))
      (drgnx-ui-menubar--menu-look-off)
      (drgnx-topline--off)
      (drgnx-menubar-off)
      (mapc (lambda (f) (delete-frame f t)) (nhwl-menu--live-frames))
      (setq nhwl-menu--frames nil)
      (kill-buffer buf))))

;;; The kit feeds the menu (drgnx-ui-kit-menu-values, modules/ui/drgnx-menu-look.el)

(defun drgnx-ui-menubar--kit-look (id)
  "Open menu ID, select its first row with Down and look at it, close it by Esc: a plist of the frame's width, its rows'
heights, where each key hint ends and its family, and the selected row's background, in the menu frame's pixels."
  (let ((seen nil) (keys (list 'down 'escape)) (idle 0))
    (cl-letf (((symbol-function 'read-event)
               (lambda (&rest _)
                 (cond (keys (when (and (null seen) (eq (car keys) 'escape))   ; Down was read: a row is selected
                               (redisplay t)
                               (let* ((f (car (last (nhwl-menu--live-frames)))) (win (frame-root-window f)))
                                 (setq seen
                                       (with-current-buffer (window-buffer win)
                                         (let ((rows nil) (ends nil) (family nil))
                                           (save-excursion
                                             (goto-char (point-min))
                                             (while (not (eobp))
                                               (push (cdr (window-text-pixel-size win (point) (pos-eol))) rows)
                                               (let ((key (text-property-any (pos-bol) (pos-eol) 'face 'nhwl-menu-key)))
                                                 (when key
                                                   (push (car (window-text-pixel-size
                                                               win (pos-bol) (next-single-property-change key 'face nil (pos-eol))))
                                                         ends)
                                                   (setq family (face-attribute 'nhwl-menu-key :family f t))))
                                               (forward-line 1)))
                                           (list :width (frame-pixel-width f) :rows (nreverse rows) :ends ends
                                                 :family family :body (window-body-width win t)
                                                 :selected (face-background 'nhwl-menu-selected f t)))))))
                             (pop keys))
                       ((< (cl-incf idle) 50) nil)
                       (t (error "The %s menu read on past its keys" id))))))
      (drgnx-menubar-open id))
    seen))

(drgnx-look-gui-deftest drgnx-menu/kit-feeds-the-menu ()
  "The ☰ menu at comfortable density is the kit's: at least 220 logical pixels wide, its item rows 26 high, the selected
row in the state table's selection (the `sel' token, `drgnx-selected'), the separator a 9 px row, the key hints in the code font, right-aligned to
one column 12 px from the right edge."
  (skip-unless (and (display-graphic-p) (fboundp 'nhwl-menu--live-frames) (boundp 'nhwl-menu-row-padding)))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*menubar-kit*")) (main (selected-frame))
        (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (switch-to-buffer buf)
    (unwind-protect
        (progn
          (drgnx-command-define 'file-new :title "New File" :category "File" :command #'drgnx-ui-menubar--new)
          (drgnx-command-define 'open-file :title "Open File…" :category "File" :command #'drgnx-ui-menubar--new)
          (setf (drgnx-cmd-bound (drgnx-commands-get 'file-new)) '(("C-n" . nil)))
          (setf (drgnx-cmd-bound (drgnx-commands-get 'open-file)) '(("C-x C-f" . nil)))
          (drgnx-menubar-setup)
          (drgnx-ui-menubar--menu-look-on)
          (drgnx-topline-setup)
          (drgnx-test-wait-presented)
          (let ((m (drgnx-ui-menubar--kit-look 'file)))
            (should m)
            (should (>= (plist-get m :width) (drgnx-px 220 main)))
            (should (member (drgnx-px 26 main) (plist-get m :rows)))
            (should (member (drgnx-px 9 main) (plist-get m :rows)))   ; the groups' separator: a thin rule's row
            (should (equal (plist-get m :selected) (face-background 'drgnx-selected main t)))
            (should (equal (plist-get m :family) (face-attribute 'drgnx-code-small :family main t)))
            ;; one right edge for every key hint, 12 px in from the frame's
            (should (= 2 (length (plist-get m :ends))))
            (should (= 1 (length (delete-dups (copy-sequence (plist-get m :ends))))))
            (should (<= (abs (- (car (plist-get m :ends)) (- (plist-get m :body) (drgnx-px 12 main)))) 1))))
      (drgnx-ui-menubar--menu-look-off)
      (drgnx-topline--off)
      (drgnx-menubar-off)
      (mapc (lambda (f) (delete-frame f t)) (nhwl-menu--live-frames))
      (setq nhwl-menu--frames nil)
      (kill-buffer buf))))

(defvar drgnx-scrollbar-mode)
(declare-function drgnx-scrollbar-mode "drgnx-ruler" (&optional arg))
(declare-function drgnx-ruler-available-p "drgnx-ruler" ())

(drgnx-look-gui-deftest drgnx-menu/the-scroll-bar-leaves-the-menus-alone ()
  "With the scroll bar on every surface, a menu's window keeps its whole frame: the scroll bar's strip (a wider right
fringe) would narrow it after Nidhogg sized the frame to the rows, and truncate every row."
  (skip-unless (and (display-graphic-p) (fboundp 'nhwl-menu--live-frames) (boundp 'nhwl-menu-row-padding)
                    (require 'drgnx-ruler nil t) (drgnx-ruler-available-p)))
  (drgnx-uitest-bare-frame)
  (let ((buf (get-buffer-create "*menubar-ruler*"))
        (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (switch-to-buffer buf)
    (unwind-protect
        (progn
          (drgnx-command-define 'file-new :title "New File" :category "File" :command #'drgnx-ui-menubar--new)
          (drgnx-menubar-setup)
          (drgnx-ui-menubar--menu-look-on)
          (drgnx-scrollbar-mode 1)
          (drgnx-test-wait-presented)
          (let ((m (drgnx-ui-menubar--kit-look 'file)))
            (should m)
            (should (= (plist-get m :body) (plist-get m :width)))))
      (drgnx-scrollbar-mode -1)
      ;; the strip is gone, but Glitnir drops what it derived from it (`glitnir--ruler', `glitnir--ruler-key') only
      ;; when the frame next publishes
      (drgnx-test-wait-presented)
      (drgnx-ui-menubar--menu-look-off)
      (drgnx-menubar-off)
      (mapc (lambda (f) (delete-frame f t)) (nhwl-menu--live-frames))
      (setq nhwl-menu--frames nil)
      (kill-buffer buf))))

(provide 'menubar-gui-test)
;;; menubar-gui-test.el ends here
