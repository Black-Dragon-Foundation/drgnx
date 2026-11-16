;;; title-row-gui-test.el --- GUI tests: the title row's menu button, project switcher and layout toggles (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Design docs/specs/drgnx/2026-11-16-title-bar-inbox-design.md (the org folder), "The title row" (mockup option B): logo,
;; the menu button, the project switcher (name and a chevron), the centred search box, the pill, three layout toggles
;; and the window controls.  A real pointer (mutter's virtual one, `drgnx-uitest-pointer-click') presses each button
;; and the registry command it carries runs; the narrow-window order is read from the row's items at several widths.

(require 'ert)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'seq)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-title-row--repo               ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-title-row--repo)))
(require 'drgnx)
(require 'drgnx-state)
(require 'drgnx-session)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-title-row--repo) nil t)
(dolist (m '("ui/drgnx-face" "ui/drgnx-statusbar" "ui/drgnx-menubar" "ui/drgnx-topline"))
  (load (expand-file-name (concat "modules/" m) drgnx-ui-title-row--repo) nil t))

(defvar drgnx-ui-title-row--ran nil "The commands the pointer's clicks ran, newest first.")

(defvar drgnx-ui-title-row--saved nil "(SYMBOL . DEFINITION) of what `drgnx-ui-title-row--stub' replaced, for the row's end.")

(defun drgnx-ui-title-row--stub (&rest names)
  "Define each of NAMES as a command that records its name in `drgnx-ui-title-row--ran' (put back at the row's end)."
  (dolist (n names)
    (let ((n n))
      (push (cons n (and (fboundp n) (symbol-function n))) drgnx-ui-title-row--saved)
      (fset n (lambda () (interactive) (push n drgnx-ui-title-row--ran))))))

(defmacro drgnx-ui-title-row--with-row (&rest body)
  "BODY in a bare frame whose title row is drawn by drgnx (as on GNOME), the row set up; undone after."
  (declare (indent 0))
  `(progn
     (drgnx-uitest-bare-frame)
     (let ((buf (get-buffer-create "*title-row*")) (frame (selected-frame)) (was drgnx-face-title-bar)
           (drgnx-ui-title-row--ran nil))
       ;; wide enough for the whole row (the design's 1440 logical pixels)
       (set-frame-size frame (round (* 1440 (drgnx-pixels-scale frame))) (round (* 600 (drgnx-pixels-scale frame))) t)
       (switch-to-buffer buf)
       (unwind-protect
           (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) (lambda (_f) (eq drgnx-face-title-bar 'drgnx))))
             (setq drgnx-face-title-bar 'drgnx)
             (drgnx-face--apply-title frame)
             (unless (drgnx-commands-get 'go-quick-open)
               (drgnx-command-define 'go-quick-open :title "Quick Open" :category "Go" :command #'ignore))
             (drgnx-menubar-setup)
             (drgnx-topline-setup)
             (drgnx-memo-forget 'topline)
             (drgnx-test-wait-presented)
             ,@body)
         (setq drgnx-face-title-bar was)
         (cl-letf (((symbol-function 'drgnx-face--drawn-wanted-p) #'ignore)) (drgnx-face--apply-title frame))
         (drgnx-topline--off)
         (drgnx-menubar-off)
         (drgnx-command-undefine 'go-quick-open)
         (pcase-dolist (`(,n . ,def) drgnx-ui-title-row--saved) (if def (fset n def) (fmakunbound n)))
         (setq drgnx-ui-title-row--saved nil)
         (kill-buffer buf)))))

(defun drgnx-ui-title-row--click (key)
  "A real pointer click in the middle of the title row's item KEY; non-nil once a command ran (`drgnx-ui-title-row--ran')."
  (let* ((frame (selected-frame)) (items (drgnx-topline--line)) (keys (mapcar #'car items))
         (measure (drgnx-statusbar--measure-fn nil 'tab-bar))
         (pos (cl-position key keys))
         (before (and pos (drgnx-topline--width (seq-take items pos) measure)))
         (own (and pos (drgnx-topline--width (list (nth pos items)) measure)))
         (x (and pos (+ before (/ own 2))))
         (y (/ (tab-bar-height frame t) 2))
         (n (length drgnx-ui-title-row--ran)))
    (should pos)
    (drgnx-uitest-pointer-click x y (lambda () (> (length drgnx-ui-title-row--ran) n)))))

(drgnx-look-gui-deftest drgnx-ui-title-row/the-row-has-the-menu-button-and-no-menu-words-or-branch ()
  "The row's items run: logo, menu button, project switcher, search, then the layout toggles and the window controls;
no menu word (File, Edit, …) and no branch chip."
  (skip-unless (display-graphic-p))
  (drgnx-ui-title-row--with-row
    (let ((keys (mapcar #'car (drgnx-topline--line))))
      (should (memq 'drgnx-topline-menu keys))
      (should-not (seq-filter (lambda (k) (string-prefix-p "drgnx-topline-menu-" (symbol-name k))) keys))
      (should-not (memq 'drgnx-topline-branch keys))
      (let ((order '(drgnx-topline-mark drgnx-topline-menu drgnx-topline-project drgnx-topline-search
                                        drgnx-topline-toggle-sidebar drgnx-topline-toggle-panel drgnx-topline-toggle-right
                                        drgnx-topline-minimize drgnx-topline-maximize drgnx-topline-close)))
        (should (equal (seq-filter (lambda (k) (memq k order)) keys) order))))))

(drgnx-look-gui-deftest drgnx-ui-title-row/the-menu-button-takes-a-real-click ()
  "A real pointer press on the menu button opens the list of menus (`drgnx-menubar-pick')."
  (skip-unless (display-graphic-p))
  (skip-unless (drgnx-uitest-pointer-available-p))
  (drgnx-ui-title-row--with-row
    (cl-letf (((symbol-function 'drgnx-menubar-pick) (lambda () (interactive) (push 'pick drgnx-ui-title-row--ran))))
      (should (eq t (drgnx-ui-title-row--click 'drgnx-topline-menu)))
      (should (memq 'pick drgnx-ui-title-row--ran)))))

(drgnx-look-gui-deftest drgnx-ui-title-row/the-project-switcher-lists-recent-folders-then-the-three-actions ()
  "The switcher's list is the recent folders (state/recent-folders.eld), then Open Folder…, Add Folder to Workspace…
and Close Folder; a real press on its name runs the switcher."
  (skip-unless (display-graphic-p))
  (skip-unless (drgnx-uitest-pointer-available-p))
  (let* ((dir (make-temp-file "title-row-recent" t))
         (a (file-name-as-directory (expand-file-name "alpha" dir)))
         (b (file-name-as-directory (expand-file-name "beta" dir)))
         (drgnx-session-recent-folders-file (expand-file-name "recent-folders.eld" dir)))
    (make-directory a) (make-directory b)
    (drgnx-file-write drgnx-session-recent-folders-file (list a b))
    (unwind-protect
        (drgnx-ui-title-row--with-row
          (should (equal (drgnx-topline-project-candidates)
                         (list a b "Open Folder…" "Add Folder to Workspace…" "Close Folder")))
          (cl-letf (((symbol-function 'drgnx-topline-project-switch)
                     (lambda () (interactive) (push 'switch drgnx-ui-title-row--ran))))
            (should (eq t (drgnx-ui-title-row--click 'drgnx-topline-project)))
            (should (memq 'switch drgnx-ui-title-row--ran))))
      (delete-directory dir t))))

(drgnx-look-gui-deftest drgnx-ui-title-row/each-layout-toggle-takes-a-real-click-and-fills-while-its-part-shows ()
  "A real press on each of the three toggles runs Toggle Primary Side Bar, Toggle Panel and Toggle Secondary Side Bar
\(the registry's `toggle-sidebar', `toggle-panel', `toggle-right-dock'); the icon is drawn filled while that part is
shown and plain while it is hidden."
  (skip-unless (display-graphic-p))
  (skip-unless (drgnx-uitest-pointer-available-p))
  (drgnx-ui-title-row--with-row
    (let ((cmds '((drgnx-topline-toggle-sidebar . toggle-sidebar) (drgnx-topline-toggle-panel . toggle-panel)
                  (drgnx-topline-toggle-right . toggle-right-dock)))
          (shown 0))
      (dolist (c cmds)
        (let ((id (cdr c)))
          (unless (drgnx-commands-get id)
            (drgnx-command-define id :title (symbol-name id) :category "View" :command (intern (format "drgnx-ui-title-row--%s" id))))
          (drgnx-ui-title-row--stub (drgnx-cmd-command (drgnx-commands-get id)))))
      (cl-letf (((symbol-function 'drgnx-topline--shown) (lambda (&optional _f) shown)))
        (let ((data (lambda (key)
                      (drgnx-memo-forget 'topline)
                      (let ((s (nth 2 (assq key (drgnx-topline--line)))) (pos 0) data)
                        (while (and (not data) pos (< pos (length s)))
                          (let ((d (get-text-property pos 'display s)))
                            (when (eq (car-safe d) 'image) (setq data (plist-get (cdr d) :data))))
                          (setq pos (next-single-property-change pos 'display s)))
                        data))))
          (cl-loop for (key . id) in cmds for bit = 1 then (* bit 2)
                   do (setq shown 0)
                   (let ((plain (funcall data key)))
                     (should-not (string-match-p "shown" plain))
                     (setq shown bit)
                     (should (string-match-p "shown" (funcall data key)))
                     (setq shown 0)
                     (drgnx-memo-forget 'topline)
                     (should (eq t (drgnx-ui-title-row--click key)))
                     (should (eq (drgnx-cmd-command (drgnx-commands-get id)) (car drgnx-ui-title-row--ran))))))))))

(defun drgnx-ui-title-row--items (pixels)
  "The row's items on a frame PIXELS wide (device pixels), a long project name, one thing waiting."
  (let ((drgnx-notice--needs-you 1))
    (cl-letf (((symbol-function 'drgnx-topline--project) (lambda (_b) "black-dragon-foundation-with-a-long-name")))
      (drgnx-topline--build-pixels (current-buffer) pixels t))))

(defun drgnx-ui-title-row--width (items key)
  "The pixels item KEY of ITEMS takes, or nil."
  (when-let* ((i (assq key items))) (drgnx-topline--known-px (nth 2 i))))

(drgnx-look-gui-deftest drgnx-ui-title-row/a-narrow-window-shrinks-the-search-then-cuts-the-project-name ()
  "As the window narrows the search box shrinks first (the project name whole), then the name is cut with … while the
search sits at its least; the menu button, the pill, the toggles and the controls never go."
  (skip-unless (display-graphic-p))
  (drgnx-ui-title-row--with-row
    (let* ((sc (drgnx-pixels-scale (selected-frame)))
           (wide (drgnx-ui-title-row--items (round (* sc 1700))))
           (mid (drgnx-ui-title-row--items (round (* sc 1050))))
           (tight (drgnx-ui-title-row--items (round (* sc 800))))
           (name (lambda (items) (substring-no-properties (nth 2 (assq 'drgnx-topline-project items))))))
      (should (> (drgnx-ui-title-row--width wide 'drgnx-topline-search) (drgnx-ui-title-row--width mid 'drgnx-topline-search)))
      (should (string-match-p "long-name" (funcall name wide)))
      (should (string-match-p "long-name" (funcall name mid)))
      (should-not (string-match-p "long-name" (funcall name tight)))
      (should (string-match-p "…" (funcall name tight)))
      (dolist (items (list wide mid tight))
        (dolist (k '(drgnx-topline-menu drgnx-topline-attention drgnx-topline-toggle-sidebar drgnx-topline-toggle-panel
                                        drgnx-topline-toggle-right drgnx-topline-minimize drgnx-topline-maximize
                                        drgnx-topline-close))
          (should (assq k items)))))))

(provide 'title-row-gui-test)
;;; title-row-gui-test.el ends here
