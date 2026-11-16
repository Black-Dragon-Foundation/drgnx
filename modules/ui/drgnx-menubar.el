;;; drgnx-menubar.el --- the menu bar: File Edit Selection View Go Run Terminal Help -*- lexical-binding: t -*-
;;
;; VS Code's eight menus, made from the registry: `etc/menus.eld' says which commands go where and in which order,
;; the registry gives their titles, the active key profile their keys (`drgnx-surfaces-key-label').  Each menu is
;; made when it opens, so a profile switch or a module turned on shows at the next open.
;;
;; Three front ends read the same menus:
;; - the title row (drgnx-topline.el) shows the eight titles at its left; a click opens the menu under its title with
;;   `x-popup-menu' (on Nidhogg's native shell a child-frame menu, on a terminal Emacs's text menu);
;; - `drgnx-menubar-mode' puts them in the menu bar keymap, for the macOS system menu bar (Naglfar reads it) and for
;;   Emacs's own menu bar where it is shown; Emacs's Options, Buffers and Tools menus are hidden while it is on;
;; - F10 and, in the VS Code profile, Alt+letter open a menu from the keyboard (`menu-bar-open-*').
;; Part of the module ui/face: set up by its setup, turned off by its teardown.  docs/guide/face.md, "The menu bar".

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-registry)
(require 'drgnx-notice)
(require 'drgnx-file)
(require 'drgnx-surfaces)

(defvar drgnx-dir)

(defgroup drgnx-menubar nil "The menu bar." :group 'drgnx)

(defun drgnx-menubar--set (sym value)
  "Set SYM to VALUE and redraw the title rows."
  (set-default sym value)
  (force-mode-line-update t))

(defcustom drgnx-menubar-visibility 'classic
  "Where the menu bar shows (VS Code's `window.menuBarVisibility').
`classic': the eight menus at the left of the title row, one button (≡) when the window is too narrow for them;
`compact': always the one button; `toggle' and `hidden': none in the title row (F10 and the menu keys still open
them).  On macOS the menus are in the system menu bar whatever this says."
  :type '(choice (const classic) (const compact) (const toggle) (const hidden))
  :set #'drgnx-menubar--set :group 'drgnx-menubar)

;;;; The layout

(defvar drgnx-menubar--layout nil "`etc/menus.eld' as read, or nil until it is read.")

(defun drgnx-menubar--layout ()
  "The layout file's menus, read once."
  (or drgnx-menubar--layout
      (setq drgnx-menubar--layout
            (let* ((file (expand-file-name "etc/menus.eld" drgnx-dir)) (r (drgnx-file-read file)))
              (unless (eq (plist-get r :status) 'ok)
                (error "%s does not read: %s" file (plist-get (plist-get r :problem) :text)))
              (plist-get r :data)))))

(defun drgnx-menubar-menus ()
  "The menus as (ID TITLE GROUP…), in order."
  (seq-remove (lambda (m) (keywordp (car m))) (drgnx-menubar--layout)))

(defun drgnx-menubar--also ()
  "The `:also' table: a `:menu' name → the title of the menu or submenu its commands join."
  (cdr (assq :also (drgnx-menubar--layout))))

(defun drgnx-menubar--layout-ids ()
  "Every command id the layout names."
  (let (ids)
    (dolist (m (drgnx-menubar-menus))
      (dolist (group (cddr m))
        (dolist (x group)
          (if (eq (car-safe x) :sub) (setq ids (append (cddr x) ids)) (push x ids)))))
    (nreverse ids)))

;;;; Making a menu

(defun drgnx-menubar--enabled-p (id)
  "Non-nil when command ID's `:when' holds (a menu item's `:enable')."
  (when-let* ((cmd (drgnx-commands-get id)))
    (or (null (drgnx-cmd-when cmd)) (ignore-errors (funcall (drgnx-cmd-when cmd))))))

(defun drgnx-menubar--shown-p (cmd)
  "Non-nil when CMD is shown: a command whose library exists (its `:when' only greys it)."
  (let ((c (drgnx-cmd-command cmd)))
    (cond ((keymapp c) nil)
          ((and (symbolp c) (autoloadp (symbol-function c))) (and (locate-library (cadr (symbol-function c))) t))
          (t (functionp c)))))

(defun drgnx-menubar--item (cmd)
  "The menu item for registry command CMD."
  `(menu-item ,(drgnx-cmd-title cmd) ,(drgnx-surfaces--item-command cmd)
              :enable (drgnx-menubar--enabled-p ',(drgnx-cmd-id cmd))
              :help ,(or (drgnx-cmd-doc cmd) "")
              :keys ,(drgnx-surfaces-key cmd 'menu)))

(defun drgnx-menubar--extra (title)
  "The registry commands whose `:menu' path names TITLE (directly or through the `:also' table), not in the layout."
  (let ((named (drgnx-menubar--layout-ids)) (also (drgnx-menubar--also)) out)
    (dolist (cmd (drgnx-commands-all))
      (let ((top (car (drgnx-cmd-menu cmd))))
        (when (and top (equal (or (cdr (assoc top also)) top) title)
                   (not (memq (drgnx-cmd-id cmd) named)))
          (push (drgnx-cmd-id cmd) out))))
    (nreverse out)))

(defun drgnx-menubar--fill (map ids)
  "Add to MAP the items of IDS (ids, or (:sub TITLE ID…)) that are shown; non-nil when one was added."
  (let (added)
    (dolist (x ids)
      (if (eq (car-safe x) :sub)
          (let ((sub (make-sparse-keymap (nth 1 x))))
            (when (drgnx-menubar--fill sub (append (cddr x) (drgnx-menubar--extra (nth 1 x))))
              (define-key-after map (vector (intern (concat "sub-" (downcase (nth 1 x)))))
                `(menu-item ,(nth 1 x) ,sub))
              (setq added t)))
        (when-let* ((cmd (drgnx-commands-get x))
                    ((drgnx-menubar--shown-p cmd)))
          (define-key-after map (vector x) (drgnx-menubar--item cmd))
          (setq added t))))
    added))

(defun drgnx-menubar-keymap (id)
  "Menu ID's keymap, made now: its groups with a separator between them, then the commands whose `:menu' names it."
  (let* ((menu (assq id (drgnx-menubar-menus)))
         (map (make-sparse-keymap))     ; no prompt: the dropdown hangs from its title, it repeats none
         (groups (cddr menu))
         (extra (drgnx-menubar--extra (nth 1 menu)))
         (n 0) (any nil))
    (when extra (setq groups (append groups (list extra))))
    (dolist (group groups)
      (let ((items (make-sparse-keymap)))
        (when (drgnx-menubar--fill items group)   ; a group with nothing to show adds no separator
          (when any (define-key-after map (vector (intern (format "sep-%d" (cl-incf n)))) '(menu-item "--")))
          (map-keymap (lambda (key binding) (define-key-after map (vector key) binding)) items)
          (setq any t))))
    map))

(defun drgnx-menubar--filter (id _binding)
  "A menu-bar item's `:filter': menu ID made now."
  (drgnx-menubar-keymap id))

;;;; Opening one

(defvar drgnx-menubar--titles-x (make-hash-table :test #'eq :weakness 'key)
  "Frame → the pixel x where the first menu title starts in its title row, learnt from the last click on a title
(`drgnx-menubar-note-click').  Weak on the frame: a deleted frame's entry goes with it.")

(defvar nhwl-menu-switch-function)      ; Nidhogg's menus (nhwl-menu.el): a row of menus
(defvar nhwl-menu-switched)
(declare-function drgnx-statusbar--measure-fn "drgnx-statusbar" (&optional frame face layout))

(defun drgnx-menubar--spans (frame)
  "Alist menu id → (LEFT . RIGHT), the pixels (columns on a terminal) its title spans in FRAME's title row."
  (let ((x (or (gethash frame drgnx-menubar--titles-x) 0))
        (measure (or (and (fboundp 'drgnx-statusbar--measure-fn)
                          (with-selected-frame frame (drgnx-statusbar--measure-fn frame 'tab-bar)))
                     #'string-width))
        out)
    (dolist (m (drgnx-menubar-menus) (nreverse out))
      (let ((w (funcall measure (drgnx-menubar--title-text (nth 1 m)))))
        (push (cons (car m) (cons x (+ x w))) out)
        (setq x (+ x w))))))

(defun drgnx-menubar--title-x (id frame)
  "The pixel x of menu ID's title in FRAME's title row."
  (or (cadr (assq id (drgnx-menubar--spans frame))) 0))

(defun drgnx-menubar--switch (id frame)
  "Where Nidhogg's open menu ID in FRAME moves (`nhwl-menu-switch-function'): Left and Right to the menu beside it,
around the ends; the pointer over another title to its menu."
  (lambda (how)
    (let* ((ids (mapcar #'car (drgnx-menubar-menus)))
           (at (or (cl-position id ids) 0)))
      (pcase how
        ('left (nth (mod (1- at) (length ids)) ids))
        ('right (nth (mod (1+ at) (length ids)) ids))
        (`(,x ,y ,f)
         (and (eq f frame) (>= y 0) (< y (if (display-graphic-p f) (tab-bar-height f t) 1))
              (let ((hit (seq-find (lambda (s) (and (>= x (cadr s)) (< x (cddr s))))
                                   (drgnx-menubar--spans frame))))
                (and hit (not (eq (car hit) id)) (car hit)))))))))

(defun drgnx-menubar--position (id)
  "Where menu ID opens: under its title in the selected frame's title row."
  (let* ((frame (selected-frame))
         (y (if (display-graphic-p frame)
                (or (cadr (window-pixel-edges (frame-root-window frame))) 0)
              (or (cadr (window-edges (frame-root-window frame))) 1))))
    (list (list (drgnx-menubar--title-x id frame) y) frame)))

(defun drgnx-menubar-open (id &optional position)
  "Open menu ID (a symbol of `drgnx-menubar-menus') at POSITION (default: under its title) and run what is chosen.
On Nidhogg, Left, Right and the pointer over another title move to that menu, under its title."
  (let ((frame (selected-frame)) (next id) binding)
    (while next
      (let* ((map (drgnx-menubar-keymap next))
             (nhwl-menu-switch-function (drgnx-menubar--switch next frame))
             (nhwl-menu-switched nil)
             (path (x-popup-menu (or position (drgnx-menubar--position next)) map)))
        (setq position nil
              binding (and path (lookup-key map (apply #'vector path)))
              next (and (not path) nhwl-menu-switched))))
    (when (and binding (commandp binding))
      (call-interactively binding))))

(defmacro drgnx-menubar--define-openers ()
  "One command per menu, `drgnx-menubar-open-ID', for the keys that open it."
  `(progn
     ,@(mapcar (lambda (id)
                 `(defun ,(intern (format "drgnx-menubar-open-%s" id)) ()
                    ,(format "Open the %s menu." (capitalize (symbol-name id)))
                    (interactive)
                    (drgnx-menubar-open ',id)))
               '(file edit selection view go run terminal help))))
(drgnx-menubar--define-openers)

(defun drgnx-menubar-toggle ()
  "Switch the title row's menu bar between the eight menus and one button (VS Code's View: Toggle Menu Bar)."
  (interactive)
  (customize-set-variable 'drgnx-menubar-visibility
                          (if (eq drgnx-menubar-visibility 'classic) 'compact 'classic))
  (message "Menu bar: %s" drgnx-menubar-visibility))

(defun drgnx-menubar-pick ()
  "The menu button (☰): every menu as one list, its submenus opening to the right.  Under the button where a click
named it, else under the title row's left."
  (interactive)
  (let* ((map (make-sparse-keymap "Menu")))
    (dolist (m (drgnx-menubar-menus))
      (define-key-after map (vector (car m)) `(menu-item ,(nth 1 m) ,(drgnx-menubar-keymap (car m)))))
    (let* ((path (x-popup-menu (drgnx-menubar--position 'file) map))
           (binding (and path (lookup-key map (apply #'vector path)))))
      (when (and binding (commandp binding)) (call-interactively binding)))))

(defun drgnx-menubar-help-documentation ()
  "Open drgnx's documentation (the docs index of this install)."
  (interactive)
  (find-file-read-only (expand-file-name "docs/index.md" drgnx-dir)))

(defun drgnx-menubar-help-about ()
  "Say which drgnx and which Emacs this is."
  (interactive)
  (drgnx-notify 'config 'info (format "drgnx (%s) on %s" (abbreviate-file-name drgnx-dir) (emacs-version))
                :id 'about :echo t))

;;;; The title row's items

(defun drgnx-menubar--mnemonic-p ()
  "Non-nil when the active profile opens File with an Alt key (the VS Code profile): the titles underline their
first letter."
  (when-let* ((cmd (drgnx-commands-get 'menu-bar-open-file)))
    (string-prefix-p "M-" (or (car (car (drgnx-cmd-bound cmd))) ""))))

(defun drgnx-menubar--title-text (title)
  "TITLE as the title row shows it: a space each side, the first letter underlined when Alt opens it."
  (let ((text (propertize (concat " " title " ") 'face 'drgnx-topline 'mouse-face 'drgnx-topline-hover)))
    (when (drgnx-menubar--mnemonic-p)
      (add-face-text-property 1 2 '(:underline t) nil text))
    text))

(defun drgnx-menubar-title-items (room &optional measure)
  "The title row's menu items for ROOM (columns, or pixels with MEASURE, a function of a string to its width):
one item per menu in `classic' when they all fit, else one button, none when `drgnx-menubar-visibility' hides
them.  Each item is (KEY menu-item TEXT COMMAND :help HELP), the title row's form."
  (let ((measure (or measure #'string-width)))
    (pcase drgnx-menubar-visibility
      ((or 'hidden 'toggle) nil)
      (vis
       (let ((items (mapcar (lambda (m)
                              `(,(intern (format "drgnx-topline-menu-%s" (car m))) menu-item
                                ,(drgnx-menubar--title-text (nth 1 m))
                                ,(intern (format "drgnx-menubar-open-%s" (car m)))
                                :help ,(format "The %s menu" (nth 1 m))))
                            (drgnx-menubar-menus))))
         (if (and (eq vis 'classic)
                  (<= (apply #'+ (mapcar (lambda (i) (funcall measure (nth 2 i))) items)) room))
             items
           (list `(drgnx-topline-menu menu-item ,(propertize " ≡ " 'face 'drgnx-topline 'mouse-face 'drgnx-topline-hover)
                                      drgnx-menubar-pick :help "The menus"))))))))

(defun drgnx-menubar-note-click (key x frame)
  "Remember that the title row's item KEY starts at pixel X in FRAME: its menu opens there, and the other titles sit
beside it."
  (if (eq key 'drgnx-topline-menu)
      (puthash frame x drgnx-menubar--titles-x)           ; the menu button: its list opens under it
    (when-let* ((name (symbol-name key))
                ((string-prefix-p "drgnx-topline-menu-" name))
                (id (intern (substring name 19))))
      (remhash frame drgnx-menubar--titles-x)
      (when-let* ((span (assq id (drgnx-menubar--spans frame))))
        (puthash frame (- x (cadr span)) drgnx-menubar--titles-x)))))

;;;; The menu bar keymap (macOS, Emacs's own menu bar, F10's text menu)

(defvar drgnx-menubar-mode-map (make-sparse-keymap)
  "The menu bar's eight menus (`help' replaces Emacs's Help menu where it stands, last), Options, Buffers and Tools
hidden.  Filled from the layout when the mode turns on.")

(defun drgnx-menubar--fill-mode-map ()
  "Put the layout's menus in `drgnx-menubar-mode-map', each made when it opens (a `:filter')."
  ;; menu-bar events, not keyboard keys: `define-key-after' keeps the layout's order
  (let ((bar (make-sparse-keymap)))
    (dolist (stock '(options buffer tools))
      (define-key-after bar (vector stock) 'undefined))
    (dolist (m (drgnx-menubar-menus))
      (define-key-after bar (vector (if (eq (car m) 'help) 'help-menu (car m)))
        `(menu-item ,(nth 1 m) (keymap) :filter ,(apply-partially #'drgnx-menubar--filter (car m)))))
    (setcdr drgnx-menubar-mode-map (list (cons 'menu-bar bar)))))

(define-minor-mode drgnx-menubar-mode
  "Put drgnx's eight menus in the menu bar (the macOS system menu bar, Emacs's own menu bar where it is shown)."
  :global t :group 'drgnx-menubar :keymap drgnx-menubar-mode-map
  (if drgnx-menubar-mode (drgnx-menubar--fill-mode-map) (setcdr drgnx-menubar-mode-map nil)))

;;;; Setup

(defun drgnx-menubar-setup ()
  "The menu bar's commands and mode (called by the module ui/face; its teardown turns the mode off)."
  (setq drgnx-menubar--layout nil)
  (dolist (m (drgnx-menubar-menus))
    (drgnx-command-define (intern (format "menu-bar-open-%s" (car m)))
                          :category "Menu" :title (format "Open the %s Menu" (nth 1 m))
                          :command (intern (format "drgnx-menubar-open-%s" (car m)))
                          :doc (format "Open the %s menu (in the VS Code profile, Alt+%s)"
                                       (nth 1 m) (substring (nth 1 m) 0 1))))
  (drgnx-command-define 'menu-bar-toggle :category "View" :title "Toggle Menu Bar" :command #'drgnx-menubar-toggle
                        :doc "Show the eight menus in the title row, or one button for them")
  (drgnx-command-define 'help-documentation :category "Help" :title "Documentation" :command #'drgnx-menubar-help-documentation
                        :doc "Open drgnx's documentation")
  (drgnx-command-define 'help-about :category "Help" :title "About" :command #'drgnx-menubar-help-about
                        :doc "Which drgnx and which Emacs this is")
  (drgnx-menubar-mode 1))

(defun drgnx-menubar-off ()
  "Turn the menu bar's mode off (the module's teardown)."
  (drgnx-menubar-mode -1)
  (clrhash drgnx-menubar--titles-x)
  (setq drgnx-menubar--layout nil))

(provide 'drgnx-menubar)
;;; drgnx-menubar.el ends here
