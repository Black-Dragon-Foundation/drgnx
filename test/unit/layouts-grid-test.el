;;; layouts-grid-test.el --- batch tests: layouts on the grid, per project, the built-ins and presets -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-groups)
(require 'drgnx-grid-frames)
(require 'drgnx-persist)
(load (expand-file-name "modules/tools/drgnx-layouts" drgnx-dir) nil t)

(defconst drgnx-layouts-grid-test--params
  '(drgnx-wb-view drgnx-layouts-state drgnx-layouts-current drgnx-layouts-previous drgnx-layouts-zen-return
                  drgnx-layouts-project))

(defmacro drgnx-layouts-grid-test--with (&rest body)
  "BODY in a 200×60 frame with the grid on, one editor on *drgnx-lg-code*, an Explorer section, the right area's Agents
tab, the pane kind `agent', a temp config dir (layouts.eld) and state dir (the projects' stores), the project
\"global\".  Prompts signal an error."
  (declare (indent 0))
  `(drgnx-test-with-state
     (let* ((dir (file-name-as-directory (make-temp-file "drgnx-layouts-grid" t)))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir "config")
                                               (concat "XDG_STATE_HOME=" dir "state"))
                                         process-environment))
            (drgnx-config--defs (copy-hash-table drgnx-config--defs))
            (drgnx-config--state (copy-hash-table drgnx-config--state))
            (drgnx-config--notified (copy-hash-table drgnx-config--notified))
            (drgnx-wb--sections nil)
            (drgnx-wb--areas (copy-tree drgnx-wb--areas))
            (drgnx-grid--stack nil)
            (display-buffer-alist nil) (display-buffer-overriding-action '(nil))
            (size (cons (frame-width) (frame-height))))
       (drgnx-layouts--define-config)
       (set-frame-size nil 200 60)
       (drgnx-grid-test--reset)
       (clrhash drgnx-layouts--project-ids)
       (dolist (p drgnx-layouts-grid-test--params) (set-frame-parameter nil p nil))
       (drgnx-wb-define-section 'files :slot 0 :title "EXPLORER"
                                :buffer (lambda () (get-buffer-create "*drgnx-lg-explorer*")))
       (drgnx-wb-define-tab 'right 'agents :title "Agents" :placeholder (lambda () (get-buffer-create "*drgnx-lg-agents*")))
       (drgnx-layouts-define-pane 'agent #'drgnx-layouts--fill-agent "Agent")
       (drgnx-rules-mode 1)
       (drgnx-chrome-mode 1)
       (drgnx-grid-mode 1)
       (switch-to-buffer (get-buffer-create "*drgnx-lg-code*"))
       (set-window-parameter nil 'drgnx-tabs nil)
       (unwind-protect
           (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (error "prompted")))
                     ((symbol-function 'read-string) (lambda (&rest _) (error "prompted")))
                     ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "prompted")))
                     ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "prompted"))))
             ,@body)
         (drgnx-timer-cancel '(layouts-save . "global"))
         (remove-hook 'window-size-change-functions #'drgnx-layouts--zen-resize)
         (drgnx-wb-hide-sidebar)
         (drgnx-wb-area-hide 'panel)
         (drgnx-wb-area-hide 'right)
         (drgnx-grid-mode -1)
         (drgnx-chrome-mode -1)
         (drgnx-rules-mode -1)
         (drgnx-pane-undefine-kind 'agent)
         (drgnx-grid-test--reset)
         (set-window-margins nil 0 0)
         (dolist (p drgnx-layouts-grid-test--params) (set-frame-parameter nil p nil))
         (set-frame-size nil (car size) (cdr size))
         (switch-to-buffer "*scratch*")
         (dolist (b (buffer-list))
           (when (string-match-p "\\`\\*drgnx-lg-\\|\\`\\*drgnx: no agent\\*\\|\\` \\*drgnx tile: " (buffer-name b))
             (when (get-buffer-process b) (delete-process (get-buffer-process b)))
             (with-current-buffer b (set-buffer-modified-p nil))
             (kill-buffer b)))
         (delete-directory dir t)))))

(defun drgnx-layouts-grid-test--leaves (&optional kind)
  "The selected frame's tree leaves (of KIND, `tile' or `editor')."
  (seq-filter (lambda (l) (or (null kind) (eq (car l) kind))) (drgnx-grid-tree-leaves (drgnx-grid-tree))))

(defun drgnx-layouts-grid-test--tile (kind)
  "The tree leaf of the tool tile showing KIND, or nil."
  (seq-find (lambda (l) (eq (plist-get (cdr l) :shown) kind)) (drgnx-layouts-grid-test--leaves 'tile)))

(defun drgnx-layouts-grid-test--dock (dock)
  "The tree leaf docked to DOCK, or nil."
  (seq-find (lambda (l) (eq (plist-get (cdr l) :dock) dock)) (drgnx-layouts-grid-test--leaves 'tile)))

(defun drgnx-layouts-grid-test--dock-window (dock)
  "The window of the tile docked to DOCK, or nil."
  (seq-find (lambda (w) (eq (window-parameter w 'drgnx-tile-dock) dock)) (drgnx-grid-tiles)))

(ert-deftest drgnx-layouts-grid/each-built-in-on-the-grid ()
  (drgnx-layouts-grid-test--with
    (dolist (name '(agent editor zen browser work code review))
      (ert-info ((format "%s" name))
        (should (eq (drgnx-layouts-apply name) name))
        (should (drgnx-grid-valid-tree-p (drgnx-grid-tree)))
        (should (= 1 (length (drgnx-grid-tiles nil 'editor))))
        (pcase name
          ('agent (should (drgnx-layouts-grid-test--dock 'left))
                  (should (drgnx-layouts-grid-test--tile 'agent))
                  (should (eq 'agents (plist-get (cdr (drgnx-layouts-grid-test--dock 'right)) :shown))))
          ('editor (should (drgnx-layouts-grid-test--dock 'left))
                   (should-not (drgnx-layouts-grid-test--tile 'agent))
                   (should-not (drgnx-layouts-grid-test--dock 'right)))
          ('zen (should (equal (mapcar #'car (drgnx-layouts-grid-test--leaves)) '(editor))))
          ;; tools/browser is off here: its shape is not defined, so the editor stays alone (its row: mod-browser-test)
          ('browser (should-not (drgnx-layouts-grid-test--tile 'browser))
                    (should-not (drgnx-layouts-grid-test--dock 'left)))
          ('work (should (drgnx-layouts-grid-test--dock 'left))
                 (should (eq 'work-detail (plist-get (cdr (drgnx-layouts-grid-test--dock 'right)) :shown))))
          ('code (should (drgnx-layouts-grid-test--dock 'left))
                 (should (eq 'agents-side (plist-get (cdr (drgnx-layouts-grid-test--dock 'right)) :shown))))
          ('review (should (drgnx-layouts-grid-test--tile 'review-screen))
                   (should (drgnx-layouts-grid-test--tile 'changes-by-task))))))))

(ert-deftest drgnx-layouts-grid/old-arrangements-are-read ()
  ;; a layouts.eld entry from before the grid (:windows, :px): its docks come back as tiles at their saved sizes
  (drgnx-layouts-grid-test--with
    (drgnx-config-update 'layouts (lambda (_) '((mine :left explorer :right agents :panel nil :editor one
                                                      :windows (leaf (buffer "*drgnx-lg-code*"))
                                                      :px (:left 30 :panel nil :right 40)))))
    (drgnx-layouts-apply 'mine)
    (should (drgnx-grid-valid-tree-p (drgnx-grid-tree)))
    (should (<= (abs (- 30 (window-pixel-width (drgnx-layouts-grid-test--dock-window 'left)))) 1))
    (should (<= (abs (- 40 (window-pixel-width (drgnx-layouts-grid-test--dock-window 'right)))) 1))
    (should (= 1 (length (drgnx-grid-tiles nil 'editor))))))

(ert-deftest drgnx-layouts-grid/agent-tile-is-a-tile-not-a-group ()
  (drgnx-layouts-grid-test--with
    (drgnx-layouts-apply 'agent)
    (should (= 1 (length (drgnx-groups-list))))
    (let ((w (seq-find (lambda (w) (memq 'agent (window-parameter w 'drgnx-pane-stack))) (drgnx-grid-tiles))))
      (should (window-live-p w))
      (should (drgnx-grid-tool-tile-p w))
      (should (equal (buffer-name (window-buffer w)) "*drgnx: no agent*")))
    ;; the next layout takes the tile away, never a group
    (drgnx-layouts-apply 'editor)
    (should-not (seq-find (lambda (w) (memq 'agent (window-parameter w 'drgnx-pane-stack))) (drgnx-grid-tiles)))
    (should (= 1 (length (drgnx-groups-list))))))

(ert-deftest drgnx-layouts-grid/per-project-file-round-trips ()
  (drgnx-layouts-grid-test--with
    (drgnx-layouts-apply 'agent)
    (let ((agent-tree (drgnx-grid-tree)))
      (drgnx-layouts-apply 'editor)
      (drgnx-layouts--save-all)
      (should (file-exists-p (drgnx-layouts-store-file "global")))
      ;; a new Emacs: the frame knows nothing; its project's file gives the layouts back
      (dolist (p drgnx-layouts-grid-test--params) (set-frame-parameter nil p nil))
      (drgnx-layouts--load-project)
      (should (eq (drgnx-layouts-current) 'editor))
      (should (assq 'agent (frame-parameter nil 'drgnx-layouts-state)))
      (drgnx-layouts-apply 'agent)
      (should (equal (mapcar (lambda (l) (list (car l) (plist-get (cdr l) :shown) (plist-get (cdr l) :dock)))
                             (drgnx-grid-tree-leaves (drgnx-grid-tree)))
                     (mapcar (lambda (l) (list (car l) (plist-get (cdr l) :shown) (plist-get (cdr l) :dock)))
                             (drgnx-grid-tree-leaves agent-tree)))))))

(ert-deftest drgnx-layouts-grid/two-projects-two-files ()
  (drgnx-layouts-grid-test--with
    (let ((project "workspace:aaaaaaaaaaaa"))
      (cl-letf (((symbol-function 'drgnx-layouts-project-id) (lambda (&optional _) project)))
        (drgnx-layouts-apply 'agent)
        (setq project "workspace:bbbbbbbbbbbb")
        (drgnx-layouts-apply 'zen)          ; switching project writes the first one's file
        (should-not (frame-parameter nil 'drgnx-layouts-previous))   ; B knew no layout before
        (drgnx-layouts--save-all)
        (let ((a (drgnx-layouts-store-file "workspace:aaaaaaaaaaaa"))
              (b (drgnx-layouts-store-file "workspace:bbbbbbbbbbbb")))
          (should-not (equal a b))
          (should (eq 'agent (plist-get (drgnx-layouts--read "workspace:aaaaaaaaaaaa") :layout)))
          (should (eq 'zen (plist-get (drgnx-layouts--read "workspace:bbbbbbbbbbbb") :layout))))
        ;; back in A: its layout and arrangements come back
        (setq project "workspace:aaaaaaaaaaaa")
        (drgnx-layouts--load-project)
        (should (eq (drgnx-layouts-current) 'agent))))))

(ert-deftest drgnx-layouts-grid/apply-pushes-a-snapshot ()
  (drgnx-layouts-grid-test--with
    (let ((before (drgnx-grid-tree)))
      (drgnx-layouts-apply 'agent)
      (should (eq 'preset (plist-get (car drgnx-grid--stack) :why)))
      (should (equal (plist-get (car (plist-get (car drgnx-grid--stack) :frames)) :tree) before))
      (drgnx-grid-restore-previous)
      (should (equal (mapcar #'car (drgnx-grid-tree-leaves (drgnx-grid-tree))) '(editor))))))

(ert-deftest drgnx-layouts-grid/apply-keeps-unsaved-terminal-and-agent ()
  :tags '(:cond)
  ;; Review Focus 1: every layout, and back: a file with unsaved changes, a terminal's process and an agent's chat stay,
  ;; and nothing asks (the fixture's prompts signal)
  (drgnx-layouts-grid-test--with
    (let ((file (get-buffer-create "*drgnx-lg-unsaved*")) (term (get-buffer-create "*drgnx-lg-term*"))
          (chat (get-buffer-create "*drgnx-lg-chat*")))
      (with-current-buffer file (insert "edit") (set-buffer-modified-p t))
      (let ((proc (start-process "drgnx-lg-cat" term "cat")))
        (set-process-query-on-exit-flag proc nil)
        (set-window-parameter (selected-window) 'drgnx-tabs (list (get-buffer "*drgnx-lg-code*") file term chat))
        (dolist (name (append (drgnx-layouts-names) '(editor)))
          (unless (eq name 'work-and-code)    ; two windows: the GUI rows
            (drgnx-layouts-apply name)))
        (should (buffer-live-p file))
        (should (buffer-modified-p file))
        (should (process-live-p proc))
        (should (buffer-live-p chat))
        (should (memq file (window-parameter (car (drgnx-grid-tiles nil 'editor)) 'drgnx-tabs)))))))

(ert-deftest drgnx-layouts-grid/placeholder-kinds-in-presets ()
  (drgnx-layouts-grid-test--with
    (drgnx-layouts-apply 'code)
    (let ((w (drgnx-layouts-grid-test--dock-window 'right)))
      (should (equal (buffer-name (window-buffer w)) " *drgnx tile: agents-side*")))
    (drgnx-layouts-apply 'review)
    (dolist (kind '(review-screen changes-by-task))
      (should (seq-find (lambda (w) (equal (buffer-name (window-buffer w)) (format " *drgnx tile: %s*" kind)))
                        (drgnx-grid-tiles))))))

(ert-deftest drgnx-layouts-grid/work-keeps-the-side-bar-and-an-editor ()
  ;; S1-1 (UX audit 2026-11-16) and the user's choice for Task 15 (2026-11-18): Work is a view in the editor, never a
  ;; full-window layout; the layout Work keeps the Explorer side bar and an editor, its Detail docked right
  (drgnx-layouts-grid-test--with
    (drgnx-layouts-apply 'work)
    (should (drgnx-wb-sidebar-showing-p))
    (should (drgnx-grid-tiles nil 'editor))
    (should (eq 'work-detail (plist-get (cdr (drgnx-layouts-grid-test--dock 'right)) :shown)))
    (should-not (memq 'work drgnx-layouts-returning))))

(ert-deftest drgnx-layouts-grid/work-and-code-makes-a-second-window ()
  ;; batch makes no second frame: the restore's frame is caught, and the second window's tree is Code's
  (drgnx-layouts-grid-test--with
    (let (made)
      (cl-letf (((symbol-function 'drgnx-grid-restore) (lambda (snap) (setq made snap) t)))
        (drgnx-layouts-apply 'work-and-code))
      (should (= 2 (length (plist-get made :frames))))
      (let ((main (car (plist-get made :frames))) (other (cadr (plist-get made :frames))))
        (should (eq 'aux (plist-get other :role)))
        (should (eq 'work-detail (plist-get (cdr (seq-find (lambda (l) (eq (plist-get (cdr l) :dock) 'right))
                                                           (drgnx-grid-tree-leaves (plist-get main :tree))))
                                            :shown)))
        (should (eq 'agents-side (plist-get (cdr (seq-find (lambda (l) (eq (plist-get (cdr l) :dock) 'right))
                                                           (drgnx-grid-tree-leaves (plist-get other :tree))))
                                            :shown)))))))
