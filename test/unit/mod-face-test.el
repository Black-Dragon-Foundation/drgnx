;;; mod-face-test.el --- batch tests: the ui/face module — the frame and the buffers -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/core/drgnx-basics" drgnx-dir) nil t)   ; New Untitled
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(defvar drgnx-untitled-p)

(defvar drgnx-face-test--state nil "The temp directory that is the state directory while a test runs.")

(defmacro drgnx-face-test--settings (&rest body)
  "BODY with ui/face's settings let-bound (a `setopt' stays in the test) and face.eld in a temp directory, never ~."
  (declare (indent 0))
  `(let* ((drgnx-face-test--state (make-temp-file "drgnx-face-test" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" drgnx-face-test--state) process-environment))
          (drgnx-face-dividers drgnx-face-dividers) (drgnx-face-divider-width drgnx-face-divider-width)
          (drgnx-face-title-bar drgnx-face-title-bar) (drgnx-face-gtk-theme drgnx-face-gtk-theme)
          (drgnx-face--wm-noted nil)
          (drgnx-face-menu-bar drgnx-face-menu-bar) (drgnx-face-scroll-bars drgnx-face-scroll-bars)
          (drgnx-face-line-spacing drgnx-face-line-spacing) (drgnx-face-line-wrap drgnx-face-line-wrap)
          (drgnx-face-frame-title drgnx-face-frame-title)
          (drgnx-face-line-numbers-modes drgnx-face-line-numbers-modes)
          (drgnx-face-inline-problems drgnx-face-inline-problems))
     (unwind-protect (progn ,@body)
       (delete-directory drgnx-face-test--state t))))

(defmacro drgnx-face-test--with (&rest body)
  "BODY with the module ui/face set up for real — its status bar, top line, quick help, start page and Close Pane
too, no stubs — and turned off after, strictly: the state after equals the state before (`drgnx-test-with-modules')."
  (declare (indent 0))
  `(drgnx-face-test--settings (drgnx-test-with-modules '(ui/face) :strict t ,@body)))

(defmacro drgnx-face-test--file-buffer (file &rest body)
  "BODY in a buffer visiting FILE's name (nothing on disk), its major mode chosen by `set-auto-mode'."
  (declare (indent 1))
  `(with-temp-buffer
     (setq buffer-file-name (expand-file-name ,file temporary-file-directory))
     (set-auto-mode)
     ,@body))

(defconst drgnx-face-test--faces
  '(window-divider window-divider-first-pixel window-divider-last-pixel vertical-border tab-bar)
  "The faces whose default spec ui/face (and its top line) set.")

(defconst drgnx-face-test--defaults
  '(window-divider-default-places window-divider-default-right-width window-divider-default-bottom-width
                                  tab-bar-format tab-bar-show line-spacing word-wrap truncate-lines
                                  truncate-partial-width-windows frame-title-format)
  "Default values ui/face (and its top line) set.")

(ert-deftest drgnx-face/setup-and-teardown-leave-nothing ()
  ;; ui/face set up for real (no stubs) and turned off: what the fingerprint does not read is put back too
  (let* ((specs (mapcar (lambda (f) (cons f (get f 'face-defface-spec))) drgnx-face-test--faces))
         (values (mapcar (lambda (v) (cons v (default-value v))) drgnx-face-test--defaults))
         (frame (mapcar (lambda (p) (cons p (frame-parameter nil p))) '(menu-bar-lines vertical-scroll-bars)))
         (frame-alist (copy-alist default-frame-alist))
         (remap (lookup-key global-map [remap menu-bar-open])))
    (should-not tab-bar-mode)
    (drgnx-face-test--settings
      (drgnx-test-with-modules '(ui/face) :strict t
                               (let ((b (generate-new-buffer "x.el")))
                                 (unwind-protect
                                     (progn
                                       (with-current-buffer b
                                         (setq buffer-file-name (expand-file-name "x.el" temporary-file-directory))
                                         (set-auto-mode)
                                         (should display-line-numbers-mode))
                                       ;; settings changed while it is on are undone with it (set as the module)
                                       (setopt drgnx-face-line-spacing 2 drgnx-face-scroll-bars 'native drgnx-face-divider-width 3)
                                       (should (eq (lookup-key global-map [remap menu-bar-open]) 'drgnx-face-menu))
                                       (should (and tab-bar-mode drgnx-statusbar-mode drgnx-close-mode window-divider-mode))
                                       (should drgnx-quickhelp--active)
                                       (should (drgnx-timer-active-p 'quickhelp-hover))
                                       (should (equal (get 'window-divider 'face-defface-spec) '((t :inherit shadow))))
                                       (should (eql (default-value 'line-spacing) 2))
                                       (should (eq (alist-get 'vertical-scroll-bars default-frame-alist) 'right))
                                       (should (eql (default-value 'window-divider-default-right-width) 3))
                                       (should-not (drgnx-module-teardown 'ui/face))
                                       (should-not (buffer-local-value 'display-line-numbers-mode b))
                                       (should-not (or tab-bar-mode drgnx-statusbar-mode drgnx-close-mode window-divider-mode))
                                       (should-not (or drgnx-face--active drgnx-quickhelp--active drgnx-topline--active))
                                       (should-not (drgnx-timer-active-p 'quickhelp-hover))
                                       (should (equal (lookup-key global-map [remap menu-bar-open]) remap))
                                       (should (equal (mapcar (lambda (f) (cons f (get f 'face-defface-spec))) drgnx-face-test--faces) specs))
                                       (should (equal (mapcar (lambda (v) (cons v (default-value v))) drgnx-face-test--defaults) values))
                                       (should (equal (mapcar (lambda (p) (cons p (frame-parameter nil p))) '(menu-bar-lines vertical-scroll-bars))
                                                      frame))
                                       (should (equal default-frame-alist frame-alist)))
                                   (kill-buffer b)))))))

(ert-deftest drgnx-face/on-again-sets-up-what-it-did-first ()
  ;; the flags a teardown clears: on again, the module waits for flymake again and owns the dividers again
  (drgnx-face-test--with
    (let ((waiting drgnx-face--flymake-waiting) (owned drgnx-face--dividers-owned))
      (drgnx-module-teardown 'ui/face)
      (should-not (or drgnx-face--flymake-waiting drgnx-face--dividers-owned))
      (drgnx-modules--run-one 'ui/face (cdr (assq 'ui/face drgnx-modules--table)) 'startup)
      (should (eq drgnx-face--flymake-waiting waiting))
      (should (eq drgnx-face--dividers-owned owned)))))

(ert-deftest drgnx-face/no-menu-bar-and-no-scroll-bars-by-default ()
  (let ((system-type 'gnu/linux))       ; a Mac keeps its menu bar (drgnx-face/a-mac-keeps-its-system-menu-bar)
    (drgnx-face-test--with
      (should-not drgnx-face-menu-bar)
      (should (eq drgnx-face-scroll-bars 'none))
      ;; new frames: the alist (early-init.el also has them before the first frame exists)
      (should (eql (alist-get 'menu-bar-lines default-frame-alist) 0))
      (should (assq 'vertical-scroll-bars default-frame-alist))
      (should-not (alist-get 'vertical-scroll-bars default-frame-alist))
      ;; live frames and later ones: the parameters
      (let (seen)
        (cl-letf (((symbol-function 'modify-frame-parameters) (lambda (_f params) (setq seen params))))
          (drgnx-face-apply-frame (selected-frame)))
        (should (eql (alist-get 'menu-bar-lines seen) 0))
        (should (assq 'vertical-scroll-bars seen))
        (should-not (alist-get 'vertical-scroll-bars seen)))
      (should (memq #'drgnx-face-apply-frame after-make-frame-functions)))))

(ert-deftest drgnx-face/a-mac-keeps-its-system-menu-bar ()
  (drgnx-face-test--settings
    (let ((system-type 'darwin))
      (should-not (assq 'menu-bar-lines (drgnx-face--frame-params)))
      (should (assq 'vertical-scroll-bars (drgnx-face--frame-params))))))

(ert-deftest drgnx-face/native-scroll-bars-are-on-the-right ()
  (drgnx-face-test--with
    (let (seen)
      (setopt drgnx-face-scroll-bars 'native)
      (cl-letf (((symbol-function 'modify-frame-parameters) (lambda (_f params) (setq seen params))))
        (drgnx-face-apply-frame (selected-frame)))
      (should (eq (alist-get 'vertical-scroll-bars seen) 'right))
      (should (eq (alist-get 'vertical-scroll-bars default-frame-alist) 'right)))))

(ert-deftest drgnx-face/setopt-brings-the-menu-bar-back ()
  (drgnx-face-test--with
    (let ((frames (list 'a 'b)) (calls nil)
          (system-type 'gnu/linux))     ; a Mac keeps its menu bar (drgnx-face/a-mac-keeps-its-system-menu-bar)
      (cl-letf (((symbol-function 'frame-list) (lambda () frames))
                ((symbol-function 'frame-parent) (lambda (_f) nil))
                ((symbol-function 'frame-live-p) (lambda (_f) t))
                ((symbol-function 'modify-frame-parameters)
                 (lambda (f params) (push (cons f (alist-get 'menu-bar-lines params)) calls))))
        (setq calls nil)
        (setopt drgnx-face-menu-bar t)
        (should (equal (sort (mapcar (lambda (c) (format "%s%s" (car c) (cdr c))) calls) #'string<) '("a1" "b1")))
        (should (eql (alist-get 'menu-bar-lines default-frame-alist) 1))
        (setq calls nil)
        (setopt drgnx-face-menu-bar nil)
        (should (equal (sort (mapcar (lambda (c) (format "%s%s" (car c) (cdr c))) calls) #'string<) '("a0" "b0")))))))

(ert-deftest drgnx-face/line-numbers-in-code-not-in-prose ()
  (drgnx-face-test--with
    (drgnx-face-test--file-buffer "x.el"
      (should (bound-and-true-p display-line-numbers-mode))
      (should (eq display-line-numbers-width-start t))      ; the number column never grows while typing
      (should (eq display-line-numbers-grow-only t)))
    (drgnx-face-test--file-buffer "x.conf"
      (should (bound-and-true-p display-line-numbers-mode)))
    (drgnx-face-test--file-buffer "x.txt"
      (should-not (bound-and-true-p display-line-numbers-mode)))
    (with-temp-buffer                                      ; code that visits no file (*scratch*)
      (emacs-lisp-mode)
      (should-not (bound-and-true-p display-line-numbers-mode)))
    (with-current-buffer (get-buffer-create "*scratch*")
      (lisp-interaction-mode)
      (should-not (bound-and-true-p display-line-numbers-mode)))))

(ert-deftest drgnx-face/line-numbers-in-yaml ()
  (skip-unless (and (fboundp 'yaml-ts-mode) (fboundp 'treesit-language-available-p) (treesit-language-available-p 'yaml)))
  (require 'yaml-ts-mode)                  ; its own `auto-mode-alist' entry is the library's, not the module's
  (drgnx-face-test--with
    (with-temp-buffer                                      ; (-Q has no auto-mode entry for yaml-ts-mode)
      (setq buffer-file-name (expand-file-name "x.yml" temporary-file-directory))
      (yaml-ts-mode)
      (should (bound-and-true-p display-line-numbers-mode)))))

(ert-deftest drgnx-face/an-untitled-buffer-has-line-numbers-in-any-language ()
  "New Untitled (VS Code's New File) numbers its lines like a file, before and after Change Language Mode."
  (require 'python)                        ; what python.el registers when it loads is its own
  (drgnx-face-test--with
    (let ((b (save-window-excursion (drgnx-basics-new-untitled))))
      (unwind-protect
          (with-current-buffer b
            (should-not buffer-file-name)
            (should (bound-and-true-p display-line-numbers-mode))
            (python-mode)                                ; Change Language Mode: the buffer is still Untitled
            (should drgnx-untitled-p)
            (should (bound-and-true-p display-line-numbers-mode))
            (text-mode)                                  ; prose too: VS Code numbers every Untitled editor
            (should (bound-and-true-p display-line-numbers-mode)))
        (kill-buffer b)))))

(ert-deftest drgnx-face/line-numbers-modes-is-a-setting ()
  (drgnx-face-test--with
    (let ((drgnx-face-line-numbers-modes '(text-mode)))
      (drgnx-face-test--file-buffer "x.txt"
        (should (bound-and-true-p display-line-numbers-mode)))
      (drgnx-face-test--file-buffer "x.el"
        (should-not (bound-and-true-p display-line-numbers-mode))))))

(ert-deftest drgnx-face/changing-the-modes-reaches-open-buffers ()
  (drgnx-face-test--with
    (drgnx-face-test--file-buffer "x.el"
      (should (bound-and-true-p display-line-numbers-mode))
      (setopt drgnx-face-line-numbers-modes '(conf-mode))
      (should-not (bound-and-true-p display-line-numbers-mode))
      (setopt drgnx-face-line-numbers-modes '(prog-mode conf-mode))
      (should (bound-and-true-p display-line-numbers-mode)))))

(ert-deftest drgnx-face/inline-problems-follow-the-setting ()
  (skip-unless (progn (require 'flymake) (boundp 'flymake-show-diagnostics-at-end-of-line)))
  (let ((before flymake-show-diagnostics-at-end-of-line))
    (drgnx-face-test--with
      (should (eq flymake-show-diagnostics-at-end-of-line 'short))
      (setopt drgnx-face-inline-problems nil)
      (should-not flymake-show-diagnostics-at-end-of-line)
      (setopt drgnx-face-inline-problems t)
      (should (eq flymake-show-diagnostics-at-end-of-line t)))
    (should (eq flymake-show-diagnostics-at-end-of-line before))))   ; flymake's own again, with the module off

(ert-deftest drgnx-face/line-spacing-follows-the-setting ()
  (let ((line-spacing nil))
    (drgnx-face-test--with
      (should-not (default-value 'line-spacing))
      (setopt drgnx-face-line-spacing 2)
      (should (eql (default-value 'line-spacing) 2))
      (setopt drgnx-face-line-spacing nil)
      (should-not (default-value 'line-spacing)))))

(ert-deftest drgnx-face/line-spacing-nil-gives-back-the-users-own ()
  (let ((line-spacing 5))                                 ; the user's own, before drgnx
    (drgnx-face-test--with
      (should (eql (default-value 'line-spacing) 5))      ; nil leaves it alone
      (setopt drgnx-face-line-spacing 2)
      (should (eql (default-value 'line-spacing) 2))
      (setopt drgnx-face-line-spacing 3)                  ; changing it again still remembers the first value
      (should (eql (default-value 'line-spacing) 3)))
    (should (eql (default-value 'line-spacing) 5))))      ; and the module turned off gives it back

(ert-deftest drgnx-face/long-lines-wrap-at-a-word-in-every-window ()
  ;; one policy: Emacs cuts below 50 columns and breaks mid-word above; drgnx wraps at words everywhere
  (let ((word-wrap nil) (truncate-lines nil) (truncate-partial-width-windows 50))
    (drgnx-face-test--with
      (should (eq (default-value 'word-wrap) t))
      (should-not (default-value 'truncate-lines))
      (should-not (default-value 'truncate-partial-width-windows))
      (setopt drgnx-face-line-wrap 'truncate)
      (should (default-value 'truncate-lines))
      (should-not (default-value 'truncate-partial-width-windows))
      (setopt drgnx-face-line-wrap nil)                     ; Emacs's own again
      (should-not (default-value 'word-wrap))
      (should-not (default-value 'truncate-lines))
      (should (eql (default-value 'truncate-partial-width-windows) 50)))))

(ert-deftest drgnx-face/toggle-word-wrap-flips-one-buffer ()
  (drgnx-face-test--with
    (should (drgnx-commands-get 'face-toggle-wrap))
    (with-temp-buffer
      (should-not truncate-lines)
      (call-interactively (drgnx-cmd-command (drgnx-commands-get 'face-toggle-wrap)))
      (should truncate-lines)
      (call-interactively (drgnx-cmd-command (drgnx-commands-get 'face-toggle-wrap)))
      (should-not truncate-lines)
      (should word-wrap))
    (should-not (default-value 'truncate-lines))))              ; other buffers keep the policy

(ert-deftest drgnx-face/the-wrap-toggle-is-in-every-profile ()
  (dolist (p '("vscode" "emacs" "vim"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name (format "keys/%s.eld" p) drgnx-dir))
      (should (search-forward "(face-toggle-wrap " nil t)))))

(ert-deftest drgnx-face/the-frame-title-is-file-project-drgnx ()
  (with-temp-buffer
    (setq buffer-file-name "/x/proj/src/main.rs" default-directory "/x/proj/src/")
    (setq-local drgnx-chrome--root (cons "/x/proj/src/" "/x/proj/"))   ; the breadcrumb's cache
    (should (equal (drgnx-face-frame-title) "main.rs — proj — drgnx"))
    (setq-local drgnx-chrome--root (cons "/elsewhere/" "/x/proj/"))    ; a stale cache is not trusted
    (should (equal (drgnx-face-frame-title) "main.rs — drgnx")))
  (with-temp-buffer
    (rename-buffer " *scratch-test*" t)
    (should (string-suffix-p " — drgnx" (drgnx-face-frame-title))))
  (with-temp-buffer
    (setq major-mode 'drgnx-start-mode)
    (should (equal (drgnx-face-frame-title) "drgnx"))))

(ert-deftest drgnx-face/the-frame-title-setting-leaves-your-own-alone ()
  (let ((frame-title-format drgnx-face--stock-title))
    (drgnx-face-test--with
      (should (equal (default-value 'frame-title-format) drgnx-face--frame-title-construct))
      (setopt drgnx-face-frame-title nil)                     ; back to Emacs's standard one
      (should (drgnx-face--stock-title-p (default-value 'frame-title-format)))
      (setq-default frame-title-format "mine")
      (setopt drgnx-face-frame-title t)
      (should (equal (default-value 'frame-title-format) "mine")))))

(ert-deftest drgnx-face/dividers-are-thin-and-inherit-the-theme ()
  (drgnx-face-test--with
    (should (eq window-divider-default-places t))
    (should (eql window-divider-default-right-width 1))
    (should (eql window-divider-default-bottom-width 1))
    (should window-divider-mode)
    (dolist (f '(window-divider window-divider-first-pixel window-divider-last-pixel vertical-border))
      (should (equal (get f 'face-defface-spec) '((t :inherit shadow)))))
    (setopt drgnx-face-divider-width 3)                   ; the width is a setting, applied at once
    (should (eql window-divider-default-right-width 3))
    (should (eql window-divider-default-bottom-width 3))))

(ert-deftest drgnx-face/dividers-off-only-when-drgnx-turned-them-on ()
  ;; drgnx turned the mode on: nil turns it off again
  (should-not window-divider-mode)
  (drgnx-face-test--with
    (should drgnx-face--dividers-owned)
    (should window-divider-mode)
    (setopt drgnx-face-dividers nil)
    (should-not window-divider-mode)
    (should-not drgnx-face--dividers-owned)
    (setopt drgnx-face-dividers nil)                      ; again: nothing left to turn off
    (should-not window-divider-mode))
  ;; the user had the mode on already: nil leaves it on, and so does the module turned off
  (window-divider-mode 1)
  (unwind-protect
      (progn
        (drgnx-face-test--with
          (should-not drgnx-face--dividers-owned)
          (setopt drgnx-face-dividers nil)
          (should window-divider-mode))
        (should window-divider-mode))
    (window-divider-mode -1)))

(ert-deftest drgnx-face/dividers-nil-from-the-start-touches-nothing ()
  (let ((specs (mapcar (lambda (f) (get f 'face-defface-spec)) drgnx-face-test--faces)))
    (drgnx-face-test--with
      ;; set up again with the setting nil (set before the fixture, loading the module file would reset it)
      (drgnx-module-teardown 'ui/face)
      (setq drgnx-face-dividers nil)
      (drgnx-modules--run-one 'ui/face (cdr (assq 'ui/face drgnx-modules--table)) 'startup)
      (should drgnx-face--active)
      (should-not window-divider-mode)
      (should-not drgnx-face--dividers-owned)
      (should (equal (butlast (mapcar (lambda (f) (get f 'face-defface-spec)) drgnx-face-test--faces))
                     (butlast specs))))))           ; the dividers' (the top line's `tab-bar' is its own)

(ert-deftest drgnx-face/inline-problems-wait-for-flymake-once ()
  ;; flymake not loaded yet: one after-load hook however often the setting changes
  (let ((hooks 0) (drgnx-face--flymake-waiting nil))
    (cl-letf (((symbol-function 'drgnx-face--flymake-ready-p) (lambda () nil))
              ((symbol-function 'eval-after-load) (lambda (&rest _) (cl-incf hooks))))
      (dotimes (_ 3) (drgnx-face--apply-inline-problems))
      (should (eql hooks 1)))))

(ert-deftest drgnx-face/glyphs-fall-back-to-ascii ()
  (let ((tty (make-symbol "tty")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional f) (not (eq f tty))))
              ((symbol-function 'frame-terminal) (lambda (&optional _f) 'term))
              ((symbol-function 'terminal-coding-system) (lambda (&optional _t) 'iso-latin-1)))
      (should (equal (drgnx-face-glyph 'close tty) "x"))
      ;; × (U+00D7) is in every monospace font: the ✕ of a fallback font looked heavier than the tabs' mark
      (should (equal (drgnx-face-glyph 'close) "×"))
      (should (equal (drgnx-face-glyph 'close 'gui) "×")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _f) nil))
              ((symbol-function 'frame-terminal) (lambda (&optional _f) 'term))
              ((symbol-function 'terminal-coding-system) (lambda (&optional _t) 'utf-8-unix)))
      (should (equal (drgnx-face-glyph 'close tty) "×")))))

(ert-deftest drgnx-face/every-glyph-has-both-forms ()
  (dolist (n '(handle close branch warning ok busy waiting paused ahead behind dot circle sep flag))
    (let ((g (alist-get n drgnx-face-glyphs)))
      (should (and (stringp (car g)) (stringp (cdr g))))
      (should (string-match-p "\\`[[:ascii:]]+\\'" (cdr g)))))
  ;; no two glyphs share an ASCII form: on a terminal that is not UTF-8 each still says which it is
  ;; (the meanings the UI kit added -- fail, stopped, dismiss, unqueue, info, warn -- may look like an older one)
  (let ((ascii (mapcar #'cddr (seq-remove (lambda (g) (memq (car g) '(fail stopped dismiss unqueue info warn)))
                                          (default-value 'drgnx-face-glyphs)))))
    (should (= (length ascii) (length (delete-dups (copy-sequence ascii))))))
  (should (equal (cdr (alist-get 'flag drgnx-face-glyphs)) "#"))
  (should-not (drgnx-face-glyph 'no-such-glyph)))

(ert-deftest drgnx-face/a-glyph-the-user-changed-wins ()
  (let ((drgnx-face-glyphs (cons '(close "X" . "#") drgnx-face-glyphs)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _f) t)))
      (should (equal (drgnx-face-glyph 'close) "X")))))

(ert-deftest drgnx-face/no-colour-literals ()
  ;; faces only inherit theme faces: the specs of the module's `defface' and `face-spec-set' forms (anywhere in the
  ;; source, inside a function or a loop too) have only :inherit, and no file of the module writes a colour
  (let ((specs 0))
    (dolist (file (directory-files (expand-file-name "modules/ui" drgnx-dir) t "\\`drgnx-face.*\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let (form)
          (condition-case nil
              (while (setq form (read (current-buffer)))
                (dolist (spec (drgnx-face-test--face-specs form))
                  (cl-incf specs)
                  (dolist (clause spec)
                    (let ((plist (cdr clause)))
                      (while plist
                        (should (eq (car plist) :inherit))
                        (setq plist (cddr plist)))))))
            (end-of-file nil)))
        (goto-char (point-min))
        (should-not (re-search-forward "\"#[0-9a-fA-F]\\{3,\\}\"" nil t))
        (goto-char (point-min))
        (should-not (re-search-forward ":\\(foreground\\|background\\)[ \n]+\"" nil t))))
    (should (>= specs 1))))   ; the scan found the divider faces' `drgnx-module-face-spec'

(defun drgnx-face-test--face-specs (form)
  "The face specs of every `defface', `face-spec-set' and `drgnx-module-face-spec' call inside FORM (a quoted spec is unquoted)."
  (when (consp form)
    (append
     (pcase form
       (`(defface ,_ ,spec . ,_) (list (drgnx-face-test--unquote spec)))
       (`(face-spec-set ,_ ,spec . ,_) (list (drgnx-face-test--unquote spec)))
       (`(drgnx-module-face-spec ,_ ,spec) (list (drgnx-face-test--unquote spec))))
     (when (proper-list-p form) (seq-mapcat #'drgnx-face-test--face-specs form)))))

(defun drgnx-face-test--unquote (x) (if (eq (car-safe x) 'quote) (cadr x) x))

(ert-deftest drgnx-face/menu-bar-toggle-is-in-every-profile ()
  (dolist (p '("vscode" "emacs" "vim"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name (format "keys/%s.eld" p) drgnx-dir))
      (should (search-forward "(face-toggle-menu-bar " nil t)))))

(ert-deftest drgnx-face/f10-opens-the-menu-as-text-while-the-bar-is-hidden ()
  (drgnx-face-test--with
    (should (drgnx-commands-get 'face-menu))
    (should (eq (key-binding (kbd "<f10>")) 'drgnx-face-menu))   ; the remap of `menu-bar-open'
    (let ((lines 0) (calls nil))
      (cl-letf (((symbol-function 'frame-parameter) (lambda (_f p) (and (eq p 'menu-bar-lines) lines)))
                ((symbol-function 'tmm-menubar) (lambda (&rest _) (interactive) (push 'tmm calls)))
                ((symbol-function 'menu-bar-open) (lambda (&rest _) (interactive) (push 'open calls))))
        (call-interactively (key-binding (kbd "<f10>")))
        (should (equal calls '(tmm)))
        (setq lines 1 calls nil)
        (call-interactively (key-binding (kbd "<f10>")))
        (should (equal calls '(open)))))))

(ert-deftest drgnx-face/the-menu-command-is-in-every-profile ()
  (dolist (p '("vscode" "emacs" "vim"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name (format "keys/%s.eld" p) drgnx-dir))
      (should (search-forward "(face-menu :none \"F10 (remap of menu-bar-open)\")" nil t)))))

(ert-deftest drgnx-face/the-toggle-command-flips-the-menu-bar ()
  (drgnx-face-test--with
    (cl-letf (((symbol-function 'frame-list) (lambda () nil)))
      (should (drgnx-commands-get 'face-toggle-menu-bar))
      (should-not drgnx-face-menu-bar)
      (call-interactively (drgnx-cmd-command (drgnx-commands-get 'face-toggle-menu-bar)))
      (should drgnx-face-menu-bar)
      (call-interactively (drgnx-cmd-command (drgnx-commands-get 'face-toggle-menu-bar)))
      (should-not drgnx-face-menu-bar))))

(ert-deftest drgnx-face/preferences-opens-the-group ()
  (drgnx-face-test--with
    (let ((cmd (drgnx-commands-get 'face-preferences)) (calls nil))
      (should cmd)
      (should (equal (drgnx-cmd-category cmd) "Preferences"))
      (should (equal (drgnx-cmd-title cmd) "Look and Layout Settings…"))
      (cl-letf (((symbol-function 'customize-group) (lambda (&rest args) (push args calls))))
        (call-interactively (drgnx-cmd-command cmd)))
      (should (equal calls '((drgnx-face))))))
  (dolist (p '("vscode" "emacs" "vim"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name (format "keys/%s.eld" p) drgnx-dir))
      (should (search-forward "(face-preferences :none \"the palette\")" nil t)))))

(ert-deftest drgnx-face/early-init-starts-without-a-menu-bar-or-scroll-bar ()
  (with-temp-buffer
    (insert-file-contents (expand-file-name "init/early-init.el" drgnx-dir))
    (should (search-forward "(unless (eq system-type 'darwin)" nil t))     ; not on a Mac: its menu bar is the system's
    (should (search-forward "(push '(menu-bar-lines . 0) default-frame-alist)" nil t))
    (should (search-forward "(push '(vertical-scroll-bars . nil) default-frame-alist)" nil t))))

;;;; The title bar

(defmacro drgnx-face-test--frame (system mode &rest body)
  "BODY with the selected frame a graphical frame of window system SYSTEM (nil: a terminal) whose background is MODE.
The frame is the batch one; its parameters are put back afterwards."
  (declare (indent 2))
  `(let ((old-mode (frame-parameter nil 'background-mode)))
     (cl-letf (((symbol-function 'drgnx-face--gui-system) (lambda (_f) ,system)))
       (set-frame-parameter nil 'background-mode ,mode)
       (unwind-protect (progn ,@body)
         (modify-frame-parameters nil `((background-mode . ,old-mode) (ns-appearance) (ns-transparent-titlebar)
                                        (undecorated) (drgnx-face-gtk-variant) (drgnx-face-ns-variant)))
         (clrhash drgnx-face--drawn)))))

(ert-deftest drgnx-face/title-follows-the-theme ()
  (drgnx-face-test--settings
    (drgnx-face-test--frame 'pgtk 'dark
      (should (eq drgnx-face-title-bar 'dark))
      (should (eq (drgnx-face-title-variant) 'dark))
      (set-frame-parameter nil 'background-mode 'light)
      (should (eq (drgnx-face-title-variant) 'light))
      (should (eq (drgnx-face-title-variant (selected-frame)) 'light))
      (let ((drgnx-face-title-bar 'system)) (should-not (drgnx-face-title-variant)))
      (let ((drgnx-face-title-bar 'drgnx)) (should (eq (drgnx-face-title-variant) 'light))))))

(ert-deftest drgnx-face/x11-sets-the-gtk-variant ()
  (drgnx-face-test--settings
    (drgnx-face-test--frame 'x 'dark
      (let (calls)
        (cl-letf (((symbol-function 'x-change-window-property)
                   (lambda (&rest args) (push args calls)))
                  ((symbol-function 'x-delete-window-property)
                   (lambda (&rest args) (push (cons 'delete args) calls))))
          (drgnx-face-apply-frame (selected-frame))
          (should (equal (car calls) (list "_GTK_THEME_VARIANT" "dark" (selected-frame) 'UTF8_STRING 8 t)))
          ;; a light theme: the light variant
          (set-frame-parameter nil 'background-mode 'light)
          (drgnx-face-apply-frame (selected-frame))
          (should (equal (nth 1 (car calls)) "light"))
          ;; `system' takes it away again, once
          (setq calls nil)
          (let ((drgnx-face-title-bar 'system))
            (drgnx-face-apply-frame (selected-frame))
            (should (equal calls (list (list 'delete "_GTK_THEME_VARIANT" (selected-frame)))))
            (setq calls nil)
            (drgnx-face-apply-frame (selected-frame))
            (should-not calls)))))))

(ert-deftest drgnx-face/pgtk-and-terminals-set-nothing-at-run-time ()
  (drgnx-face-test--settings
    (let (calls)
      (cl-letf (((symbol-function 'x-change-window-property) (lambda (&rest args) (push args calls))))
        (drgnx-face-test--frame 'pgtk 'dark          ; GTK reads GTK_THEME once, at launch
          (drgnx-face-apply-frame (selected-frame))
          (should-not (frame-parameter nil 'ns-appearance)))
        (drgnx-face-test--frame nil 'dark
          (drgnx-face-apply-frame (selected-frame))
          (should-not (frame-parameter nil 'ns-appearance)))
        (should-not calls)))))

(ert-deftest drgnx-face/macos-sets-ns-appearance ()
  (drgnx-face-test--settings
    (drgnx-face-test--frame 'ns 'dark
      (drgnx-face-apply-frame (selected-frame))
      (should (eq (frame-parameter nil 'ns-appearance) 'dark))
      (should (eq (frame-parameter nil 'ns-transparent-titlebar) t))
      (set-frame-parameter nil 'background-mode 'light)
      (drgnx-face-apply-frame (selected-frame))
      (should (eq (frame-parameter nil 'ns-appearance) 'light))
      (let ((drgnx-face-title-bar 'system))
        (drgnx-face-apply-frame (selected-frame))
        (should-not (frame-parameter nil 'ns-appearance))
        (should-not (frame-parameter nil 'ns-transparent-titlebar))))))

(ert-deftest drgnx-face/macos-system-leaves-the-users-own-appearance ()
  (drgnx-face-test--settings
    (drgnx-face-test--frame 'ns 'dark
      (set-frame-parameter nil 'ns-appearance 'light)        ; not this module's
      (let ((drgnx-face-title-bar 'system))
        (drgnx-face-apply-frame (selected-frame))
        (should (eq (frame-parameter nil 'ns-appearance) 'light))))))

(ert-deftest drgnx-face/drawn-title-never-under-a-tiling-wm ()
  (drgnx-face-test--settings
    (let ((drgnx-face-title-bar 'drgnx))
      (dolist (wm '(sway i3 hyprland niri))
        (drgnx-face-test--frame 'pgtk 'dark
          (cl-letf (((symbol-function 'drgnx-platform-wm) (lambda (&optional _f) wm))
                    ((symbol-function 'x-change-window-property) #'ignore))
            (drgnx-face-apply-frame (selected-frame))
            (should-not (drgnx-face-drawn-title-p))
            (should-not (frame-parameter nil 'undecorated)))))
      ;; a stacking one: the frame is undecorated and says so
      (drgnx-face-test--frame 'pgtk 'dark
        (cl-letf (((symbol-function 'drgnx-platform-wm) (lambda (&optional _f) 'gnome)))
          (drgnx-face-apply-frame (selected-frame))
          (should (drgnx-face-drawn-title-p))
          (should (drgnx-face-drawn-title-p (selected-frame)))
          (should (eq (frame-parameter nil 'undecorated) t))
          ;; back to the system's: decorated again
          (let ((drgnx-face-title-bar 'dark))
            (drgnx-face-apply-frame (selected-frame))
            (should-not (drgnx-face-drawn-title-p))
            (should-not (frame-parameter nil 'undecorated)))))
      ;; a terminal has no title bar to draw
      (drgnx-face-test--frame nil 'dark
        (cl-letf (((symbol-function 'drgnx-platform-wm) (lambda (&optional _f) 'gnome)))
          (drgnx-face-apply-frame (selected-frame))
          (should-not (drgnx-face-drawn-title-p)))))))

(ert-deftest drgnx-face/drawn-title-needs-a-known-stacking-wm ()
  ;; nil, none, tty, x11, other-wayland and a name nobody listed are all "not known": dark, said once
  (drgnx-face-test--settings
    (let ((drgnx-face-title-bar 'drgnx))
      (dolist (wm '(nil none tty x11 other-wayland some-new-wm))
        (let ((said nil) (drgnx-face--wm-noted nil))
          (drgnx-face-test--frame 'pgtk 'dark
            (cl-letf (((symbol-function 'drgnx-platform-wm) (lambda (&optional _f) wm))
                      ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) said))))
              (drgnx-face-apply-frame (selected-frame))
              (drgnx-face-apply-frame (selected-frame))
              (should-not (drgnx-face-drawn-title-p))
              (should-not (frame-parameter nil 'undecorated))
              (should (= 1 (length said)))))))
      (dolist (wm '(gnome kwin))
        (drgnx-face-test--frame 'pgtk 'dark
          (cl-letf (((symbol-function 'drgnx-platform-wm) (lambda (&optional _f) wm)))
            (drgnx-face-apply-frame (selected-frame))
            (should (drgnx-face-drawn-title-p))))))))

(ert-deftest drgnx-face/drawn-title-needs-the-wm-known ()
  (drgnx-face-test--settings
    (let ((drgnx-face-title-bar 'drgnx) (messages nil))
      (drgnx-face-test--frame 'x 'dark
        (cl-letf (((symbol-function 'drgnx-platform-wm) nil)
                  ((symbol-function 'x-change-window-property) (lambda (&rest a) (push a messages)))
                  ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
          (should-not (fboundp 'drgnx-platform-wm))
          (drgnx-face-apply-frame (selected-frame))
          (drgnx-face-apply-frame (selected-frame))
          (should-not (drgnx-face-drawn-title-p))
          (should-not (frame-parameter nil 'undecorated))
          ;; dark is used instead, and the reason is said once
          (should (= 2 (cl-count-if (lambda (m) (equal (car-safe m) "_GTK_THEME_VARIANT")) messages)))
          (let ((said (seq-filter #'stringp messages)))
            (should (= 1 (length said)))
            (should (string-match-p "window manager" (car said)))))))))

(ert-deftest drgnx-face/drawn-title-is-read-from-the-frame-never-worked-out ()
  ;; the top line asks on every redisplay: no window manager lookup, no message
  (drgnx-face-test--settings
    (drgnx-face-test--frame 'pgtk 'dark
      (cl-letf (((symbol-function 'drgnx-platform-wm) (lambda (&optional _) (error "asked the window manager")))
                ((symbol-function 'message) (lambda (&rest _) (error "said something"))))
        (let ((drgnx-face-title-bar 'drgnx))
          (should-not (drgnx-face-drawn-title-p)))
        (puthash (selected-frame) t drgnx-face--drawn)
        (should (drgnx-face-drawn-title-p))))))

(ert-deftest drgnx-face/the-theme-and-the-setting-write-the-state-and-reapply ()
  ;; the frame is made graphical inside the module run: setting the module up loads its file again (its functions too)
  (drgnx-face-test--settings
    (drgnx-test-with-modules '(ui/face) :strict t
                             (let (props)
                               (drgnx-face-test--frame 'x 'dark
                                 (cl-letf (((symbol-function 'x-change-window-property) (lambda (_p v &rest _) (push v props)))
                                           ((symbol-function 'x-delete-window-property) #'ignore))
                                   (should (memq #'drgnx-face--on-theme enable-theme-functions))
                                   (drgnx-face-state-write '(:start-dismissed t))                       ; another key in face.eld
                                   (run-hook-with-args 'enable-theme-functions 'some-theme)
                                   (let ((state (drgnx-face-state-read)))             ; what the module wrote, beside what was there
                                     (should (eq (plist-get state :variant) 'dark))
                                     (should (equal (plist-get state :gtk-theme) "Adwaita"))
                                     (should (plist-get state :start-dismissed)))
                                   (should (equal (car props) "dark"))
                                   (should (equal (drgnx-face-state-gtk-theme) "Adwaita:dark"))
                                   ;; a light theme
                                   (set-frame-parameter nil 'background-mode 'light)
                                   (run-hook-with-args 'enable-theme-functions 'some-theme)
                                   (should (equal (car props) "light"))
                                   (should (equal (drgnx-face-state-gtk-theme) "Adwaita:light"))
                                   ;; the setting
                                   (setopt drgnx-face-title-bar 'system)
                                   (should-not (drgnx-face-state-gtk-theme))
                                   (should (plist-get (drgnx-face-state-read) :start-dismissed))
                                   (setopt drgnx-face-title-bar 'dark drgnx-face-gtk-theme "Adwaita-dark")
                                   (should (equal (drgnx-face-state-gtk-theme) "Adwaita-dark:light"))))))))

(ert-deftest drgnx-face/a-terminal-never-writes-the-title-state ()
  (drgnx-face-test--settings
    (drgnx-test-with-modules '(ui/face) :strict t
                             (drgnx-face-test--frame nil 'dark
                               (setopt drgnx-face-title-bar 'system)
                               (setopt drgnx-face-title-bar 'dark)
                               (should-not (file-exists-p (drgnx-face-state-file)))))))

(ert-deftest drgnx-face/the-title-settings-are-reachable ()
  (should (custom-variable-p 'drgnx-face-title-bar))
  (should (custom-variable-p 'drgnx-face-gtk-theme))
  (let ((settings (plist-get (alist-get 'ui/face drgnx-modules--table) :settings)))
    (should (assq 'drgnx-face-title-bar settings))
    (should (assq 'drgnx-face-gtk-theme settings))))

;;; mod-face-test.el ends here
