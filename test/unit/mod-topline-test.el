;;; mod-topline-test.el --- batch tests: the top line — project, branch, the keys that open everything (M12f A6) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-chrome)                 ; the project cache the line reads
(require 'drgnx-signal)                 ; the editor-changed edge it subscribes to
(require 'drgnx-git)                    ; the git cache the branch comes from
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-dir) nil t)   ; the epochs the line is keyed on, as in a session
(load (expand-file-name "modules/ui/drgnx-topline" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/memo-alloc-fixture" drgnx-dir) nil t)
(defvar drgnx-chrome--root)

(defun drgnx-topline-test--activate ()
  "The setup of the tests' own `ui/face': what `drgnx-topline-setup' activates."
  (apply #'drgnx-memo-activate drgnx-topline--declared))

(defvar drgnx-topline-test--ran nil "The stub commands that ran (newest first).")
(defvar drgnx-topline-test--wcc 0 "Runs of `window-configuration-change-hook' counted by `drgnx-topline-test--count-wcc'.")
(defun drgnx-topline-test--count-wcc () (setq drgnx-topline-test--wcc (1+ drgnx-topline-test--wcc)))
(defun drgnx-topline-test-files () (interactive) (push 'files drgnx-topline-test--ran))
(defun drgnx-topline-test-palette () (interactive) (push 'palette drgnx-topline-test--ran))
(defun drgnx-topline-test-keys () (interactive) (push 'keys drgnx-topline-test--ran))

(defun drgnx-topline-test--bind (profile)
  "Give the three commands the keys the real PROFILE file (`keys/PROFILE.eld') gives them."
  (let ((entries (plist-get (alist-get profile (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))) :bind)))
    (dolist (id '(go-quick-open palette keys-sheet))
      (let ((keys (cdr (assq id entries))))
        (setf (drgnx-cmd-bound (drgnx-commands-get id))
              (unless (eq (car keys) :none)                 ; (ID :none "why"): no key in this profile
                (mapcar (lambda (k) (cons k nil)) keys)))))))

(defmacro drgnx-topline-test--with (profile &rest body)
  "BODY with a registry of its own holding the three commands the hint names, bound as PROFILE (a symbol) binds them,
the line's state and the tab bar's settings kept away from the rest of the test process, and the line showing the
buffer of the selected window (a temp buffer in project `proj', no git).  Faces and the project lookup are stubs.
`ui/face' is set up in a module table of the test's own (its timers start; the line's epochs watch and its memo is
owned) and torn down after (the watchers go, the memo empties)."
  (declare (indent 1))
  `(drgnx-test-with-state
     (let ((drgnx-modules--table (list (list 'ui/face :setup #'drgnx-topline-test--activate)))
           (drgnx-modules--report nil) (drgnx-modules--stacks nil) (drgnx-modules--runs nil)
           (drgnx-modules--features nil) (drgnx-modules--left nil))
       (drgnx-memo-forget 'topline)
       (drgnx-modules--run-one 'ui/face (alist-get 'ui/face drgnx-modules--table) 'startup)
       (unwind-protect (drgnx-topline-test--with-1 ,profile ,@body)
         (drgnx-module-teardown 'ui/face)))))

(defmacro drgnx-topline-test--with-1 (profile &rest body)
  "The inside of `drgnx-topline-test--with'."
  (declare (indent 1))
  `(progn
     (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
           (drgnx-topline-test--ran nil)
           (drgnx-topline--error nil) (drgnx-topline--error-at nil)
           (drgnx-topline--saved nil) (drgnx-topline--format nil) (drgnx-topline--active nil)
           (drgnx-topline drgnx-topline) (drgnx-topline-min-lines drgnx-topline-min-lines)
           (default-frame-alist (copy-alist default-frame-alist))
           (tab-bar-format (default-value 'tab-bar-format)) (tab-bar-show (default-value 'tab-bar-show))
           (tab-bar-auto-width (default-value 'tab-bar-auto-width))
           ;; what `--on' and `--fit' set on the frame, put back
           (lines (frame-parameter nil 'tab-bar-lines)) (decided (frame-parameter nil 'drgnx-topline-lines))
           (old (window-buffer (selected-window))))
       (cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _f) nil))   ; the batch terminal is not UTF-8
                 ;; whatever redisplay would reach for besides the buffer-local cache: a lookup is an error here
                 ((symbol-function 'project-current) (lambda (&rest _) (error "a project lookup"))))
         (drgnx-command-define 'go-quick-open :title "Quick Open" :category "Go" :command #'drgnx-topline-test-files)
         (drgnx-command-define 'palette :title "Command Palette" :category "View" :command #'drgnx-topline-test-palette)
         (drgnx-command-define 'keys-sheet :title "Keys" :category "Help" :command #'drgnx-topline-test-keys)
         (drgnx-topline-test--bind ,profile)
         (with-temp-buffer
           (setq-local drgnx-chrome--root (cons default-directory "/x/proj/"))   ; the breadcrumb's cache, filled
           (set-window-buffer (selected-window) (current-buffer))
           (unwind-protect (progn ,@body)
             (drgnx-topline--off)
             (set-frame-parameter nil 'tab-bar-lines lines)
             (set-frame-parameter nil 'drgnx-topline-lines decided)
             (set-window-buffer (selected-window) old)))))))

(defun drgnx-topline-test--text ()
  "What the line shows now, as plain text."
  (mapconcat (lambda (item) (substring-no-properties (nth 2 item))) (drgnx-topline--line) ""))

(defun drgnx-topline-test--item (key)
  "The line's item named KEY."
  (assq key (drgnx-topline--line)))

(ert-deftest drgnx-topline/faces-follow-the-theme-chrome-and-keep-the-text-colour ()
  ;; The strong text fell back to the tab bar's dim foreground: it takes the text colour, on the tab line's band.
  (dolist (f '(drgnx-topline drgnx-topline-strong))
    (let ((inh (face-attribute f :inherit nil nil)))
      (should (memq 'tab-line inh))
      (should-not (memq 'header-line inh))
      (should-not (memq 'tab-bar inh))))
  (should (memq 'bold (face-attribute 'drgnx-topline-strong :inherit nil nil))))

(ert-deftest drgnx-topline/shows-project-branch-and-the-three-keys ()
  (drgnx-topline-test--with 'vscode
    (setq-local vc-mode " Git-main")
    (let ((text (drgnx-topline-test--text)))
      (should (string-match-p "◆ proj · main" text))
      (should (string-match-p "⌕ C-p files · C-S-p commands · C-k C-r all keys" text))
      ;; in this order: the project at the left, the hint after it
      (should (< (string-match "proj" text) (string-match "C-p" text))))
    ;; no branch (no git): the project alone; no project: the name of the framework
    (setq-local vc-mode nil)
    (should (string-match-p "◆ proj +⌕" (drgnx-topline-test--text)))
    (setq-local drgnx-chrome--root nil)                    ; a cache miss
    (should (string-match-p "◆ drgnx +⌕" (drgnx-topline-test--text)))))

(ert-deftest drgnx-topline/emacs-profile-shows-its-keys ()
  (drgnx-topline-test--with 'emacs
    ;; Quick Open has no key of its own in this profile (`:none', Emacs's own C-x p f): a command without a key is
    ;; left out, and a stock Emacs key that runs the command is shown
    (let ((text (drgnx-topline-test--text)))
      (should (string-match-p "⌕ C-S-p commands · C-h C-k all keys" text))
      (should-not (string-match-p "files" text)))
    (setf (drgnx-cmd-command (drgnx-commands-get 'go-quick-open)) 'project-find-file)
    (should (string-match-p "⌕ C-x p f files · C-S-p commands · C-h C-k all keys" (drgnx-topline-test--text)))
    ;; no key for any: no hint at all, just the place
    (dolist (id '(go-quick-open palette keys-sheet))
      (setf (drgnx-cmd-bound (drgnx-commands-get id)) nil))
    (setf (drgnx-cmd-command (drgnx-commands-get 'go-quick-open)) #'drgnx-topline-test-files)
    (should-not (string-match-p "⌕" (drgnx-topline-test--text)))))

(ert-deftest drgnx-topline/a-users-tab-bar-format-is-kept ()
  (drgnx-topline-test--with 'vscode
    (let ((tab-bar-mode nil) (mine '(tab-bar-format-tabs tab-bar-format-add-tab)))
      (setq-default tab-bar-format mine)
      (drgnx-topline--apply)
      (should (equal (default-value 'tab-bar-format) mine))
      (should-not tab-bar-mode)
      (should-not drgnx-topline--saved)
      ;; theirs after ours: ours goes quietly and theirs stays
      (setq-default tab-bar-format (eval (car (get 'tab-bar-format 'standard-value)) t))
      (drgnx-topline--apply)
      (should (equal (default-value 'tab-bar-format) (drgnx-topline-format)))
      (should tab-bar-mode)
      (setq-default tab-bar-format mine)
      (drgnx-topline--off)
      (should (equal (default-value 'tab-bar-format) mine))
      (should-not tab-bar-mode))))

(ert-deftest drgnx-topline/turning-it-off-puts-back-what-it-changed ()
  (drgnx-topline-test--with 'vscode
    (let ((tab-bar-mode nil) (before (default-value 'tab-bar-format)))
      (drgnx-topline--apply)
      (should (equal (default-value 'tab-bar-format) (drgnx-topline-format)))
      (should (eq tab-bar-show t))
      (should tab-bar-mode)
      (drgnx-topline--apply)                               ; again: the same
      (should (equal (default-value 'tab-bar-format) (drgnx-topline-format)))
      (should (= 1 (cl-count #'drgnx-topline--fit (alist-get 'frame-added drgnx-state--idle))))
      (should (memq #'drgnx-topline--fit-all window-setup-hook))   ; a window's frame is made after init: fit it then
      (setq drgnx-topline--active t)
      (drgnx-topline--set 'drgnx-topline nil)               ; the setter applies it live
      (should (equal (default-value 'tab-bar-format) before))
      (should-not tab-bar-mode)
      (should-not (memq #'drgnx-topline--fit (alist-get 'frame-added drgnx-state--idle)))
      (should-not (memq #'drgnx-topline--fit (alist-get 'frame-resized drgnx-state--idle)))
      (should-not (memq #'drgnx-topline--resized (alist-get 'frame-resized drgnx-state--now)))
      (should-not (memq #'drgnx-topline--fit-all window-setup-hook))
      (should-not (memq #'drgnx-topline--fit-all emacs-startup-hook)))))

(ert-deftest drgnx-topline/window-controls-only-with-a-drawn-title ()
  (drgnx-topline-test--with 'vscode
    (should-not (string-match-p "[–▢×]" (drgnx-topline-test--text)))   ; A2 is not there yet: never
    (should-not (assq 'drgnx-topline-close (drgnx-topline--line)))
    (cl-letf (((symbol-function 'drgnx-face-drawn-title-p) (lambda (&optional _frame) t)))
      (let ((text (drgnx-topline-test--text)))
        (should (string-match-p "– ▢ ×" text))
        (should (eq (nth 3 (drgnx-topline-test--item 'drgnx-topline-minimize)) 'iconify-frame))
        (should (eq (nth 3 (drgnx-topline-test--item 'drgnx-topline-maximize)) 'toggle-frame-maximized))
        (should (eq (nth 3 (drgnx-topline-test--item 'drgnx-topline-close)) 'delete-frame))
        ;; the empty area drags the frame
        (should (eq (nth 3 (drgnx-topline-test--item 'drgnx-topline-gap-2)) 'mouse-drag-frame-move))
        (should (eq (nth 3 (drgnx-topline-test--item 'drgnx-topline-gap-1)) 'mouse-drag-frame-move))))
    ;; and gone again when the title is not drawn
    (should-not (assq 'drgnx-topline-close (drgnx-topline--line)))
    (should (eq (nth 3 (drgnx-topline-test--item 'drgnx-topline-gap-1)) 'ignore))))

(ert-deftest drgnx-topline/none-in-a-short-terminal ()
  (drgnx-topline-test--with 'vscode
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
      (cl-letf (((symbol-function 'frame-height) (lambda (&optional _) 18)))
        (should (= 0 (drgnx-topline--lines (selected-frame))))
        (drgnx-topline--on)
        (should (= 0 (frame-parameter nil 'tab-bar-lines))))
      (cl-letf (((symbol-function 'frame-height) (lambda (&optional _) 20)))   ; room again
        (drgnx-topline--fit)
        (should (= 1 (frame-parameter nil 'tab-bar-lines))))
      (cl-letf (((symbol-function 'frame-height) (lambda (&optional _) 18)))
        (drgnx-topline--fit)
        (should (= 0 (frame-parameter nil 'tab-bar-lines)))
        (let ((drgnx-topline-min-lines 10))                 ; the limit is a setting
          (should (= 1 (drgnx-topline--lines (selected-frame)))))))
    ;; a window always has it
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'frame-height) (lambda (&optional _) 5)))
      (should (= 1 (drgnx-topline--lines (selected-frame)))))))

(ert-deftest drgnx-topline/a-terminal-of-the-minimum-keeps-the-line ()
  ;; `frame-height' is one less while the line shows: a terminal of exactly the minimum must not lose it and win it back
  ;; on every size change (the frame resized itself between 19 and 20 lines, for ever)
  (drgnx-topline-test--with 'vscode
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil))
              ((symbol-function 'frame-height) (lambda (&optional _) 19))
              ((symbol-function 'frame-parameter)
               (let ((real (symbol-function 'frame-parameter)))
                 (lambda (frame param) (if (eq param 'tab-bar-lines) 1 (funcall real frame param))))))
      (should (= 1 (drgnx-topline--lines (selected-frame)))))))

(ert-deftest drgnx-topline/a-new-width-gives-items-that-are-not-equal ()
  ;; The tab bar redraws only when its items are not `equal', and `equal' ignores text properties: a gap made of one space
  ;; with an :align-to property left the hint centred for the old width on the screen after a resize.
  (drgnx-topline-test--with 'vscode
    (let ((width 80))
      (cl-letf (((symbol-function 'frame-text-cols) (lambda (&optional _) width)))
        (let ((narrow (copy-tree (drgnx-topline--line))))
          (setq width 120)
          (let ((wide (drgnx-topline--line)))
            (should-not (equal-including-properties narrow wide))
            (should-not (equal narrow wide))
            ;; centred: the hint starts where the same number of columns is left on both sides
            (let* ((text (mapconcat (lambda (i) (substring-no-properties (nth 2 i))) wide ""))
                   (start (string-match "⌕" text))
                   (hint-w (- (string-width (string-trim-right text)) start)))
              (should (<= (abs (- start (- width hint-w start))) 1)))))))))

(ert-deftest drgnx-topline/the-hint-runs-the-command ()
  (drgnx-topline-test--with 'vscode
    (dolist (spec '((drgnx-topline-go-quick-open . files) (drgnx-topline-palette . palette) (drgnx-topline-keys-sheet . keys)))
      (let ((item (drgnx-topline-test--item (car spec))))
        (should item)
        ;; what the tab bar's mouse command calls on a press
        (call-interactively (nth 3 item))
        (should (eq (car drgnx-topline-test--ran) (cdr spec)))))
    ;; the clickable text is the key and its label, nothing more
    (should (equal (substring-no-properties (nth 2 (drgnx-topline-test--item 'drgnx-topline-palette))) "C-S-p commands"))))

(ert-deftest drgnx-topline/a-terminal-shows-the-key-it-can-send ()
  (drgnx-topline-test--with 'vscode
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil))
              ((symbol-function 'drgnx-tty-sendable-key)
               (lambda (_frame key) (if (equal key "C-S-p") "M-P" key))))
      (should (string-match-p "M-P commands" (drgnx-topline-test--text))))
    (drgnx-memo-forget 'topline)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'drgnx-tty-sendable-key) (lambda (_frame _key) (error "not on a window"))))
      (should (string-match-p "C-S-p commands" (drgnx-topline-test--text))))))

(ert-deftest drgnx-topline/glyphs-have-an-ascii-form ()
  (drgnx-topline-test--with 'vscode
    (setq-local vc-mode " Git-main")
    (cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _f) t)))
      (should (string-match-p "\\`<> proj | main" (string-trim-left (drgnx-topline-test--text))))
      (should (string-match-p "/ C-p files | C-S-p commands" (drgnx-topline-test--text))))
    ;; the glyph table changed: made again
    (let ((drgnx-face-glyphs (cons '(diamond "X" . "x") drgnx-face-glyphs)))
      (should (string-match-p "X proj" (drgnx-topline-test--text))))))

(ert-deftest drgnx-topline/never-wider-than-its-frame ()
  (drgnx-topline-test--with 'vscode
    (setq-local vc-mode " Git-a-very-long-branch-name-that-goes-on-and-on")
    (dolist (w '(120 70 40 12))
      (cl-letf (((symbol-function 'frame-text-cols) (lambda (&optional _) w)))
        (let ((text (drgnx-topline-test--text)))
          (should (<= (string-width text) w))
          ;; the hint goes before the place is cut
          (when (< w 70) (should-not (string-match-p "⌕" text))))))))

(ert-deftest drgnx-topline/redisplay-never-looks-a-project-up ()
  ;; the first lookup for a directory walks the file system: it is the editor-changed edge's job, the line only reads
  ;; the breadcrumb's cache; a miss shows the framework's name
  (drgnx-topline-test--with 'vscode
    (setq-local drgnx-chrome--root nil)
    (should (string-match-p "◆ drgnx" (drgnx-topline-test--text)))   ; `project-current' is an error in this macro
    (should-not drgnx-topline--error)
    ;; the cache of another directory is not this buffer's project
    (setq-local drgnx-chrome--root (cons "/elsewhere/" "/x/other/"))
    (should (string-match-p "◆ drgnx" (drgnx-topline-test--text)))))

(ert-deftest drgnx-topline/the-editor-edge-fills-the-cache-and-redraws ()
  (drgnx-topline-test--with 'vscode
    (setq-local drgnx-chrome--root nil)
    (let ((updates 0) (asked nil))
      (cl-letf (((symbol-function 'project-current)
                 (lambda (&rest _) (setq asked default-directory) '(transient . "/x/proj/")))
                ((symbol-function 'force-mode-line-update) (lambda (&optional _) (setq updates (1+ updates)))))
        (should-not buffer-file-name)
        (drgnx-topline--note-editor (current-buffer))
        (should (equal asked default-directory))              ; a buffer without a file: its directory
        (should (= 1 updates))
        (should (string-match-p "◆ proj" (drgnx-topline-test--text)))
        ;; the same directory again: cached, so no lookup and no redraw
        (setq asked nil)
        (drgnx-topline--note-editor (current-buffer))
        (should-not asked)
        (should (= 1 updates))))))

(ert-deftest drgnx-topline/a-remote-directory-is-never-looked-up ()
  (drgnx-topline-test--with 'vscode
    (setq-local drgnx-chrome--root nil)
    (let ((default-directory "/ssh:nowhere:/home/"))
      (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (error "looked up a remote project")))
                ((symbol-function 'file-remote-p) (lambda (&rest _) "/ssh:nowhere:")))
        (drgnx-topline--note-editor (current-buffer))
        (should-not drgnx-chrome--root)))))

(ert-deftest drgnx-topline/the-editor-edge-is-subscribed-only-while-it-is-on ()
  (drgnx-topline-test--with 'vscode
    (let ((tab-bar-mode nil))
      (drgnx-topline--on)
      (should (memq #'drgnx-topline--note-editor (alist-get 'editor-changed drgnx-signal--subscribers)))
      (drgnx-topline--off)
      (should-not (memq #'drgnx-topline--note-editor (alist-get 'editor-changed drgnx-signal--subscribers))))))

(ert-deftest drgnx-topline/an-error-never-takes-the-line-away ()
  ;; with no items Emacs sets the tab bar's lines to 0, and the line flickers on and off with every redisplay.  Here the
  ;; failure is in the key the memo is made from, the part that used to be outside the guard.
  (drgnx-topline-test--with 'vscode
    (let ((before (current-message)) (now 100.0))
      (cl-letf (((symbol-function 'drgnx-topline--now) (lambda () now))
                ((symbol-function 'drgnx-face-drawn-title-p) (lambda (&optional _) (error "no title for you"))))
        (should (equal (substring-no-properties (nth 2 (car (drgnx-topline--line)))) " drgnx"))
        (should (equal drgnx-topline--error "no title for you"))
        (should (equal (current-message) before))             ; no message per redisplay
        ;; failing: the fallback, without trying again
        (cl-letf (((symbol-function 'drgnx-face-drawn-title-p) (lambda (&optional _) (error "tried again"))))
          (setq now 105.0)
          (should (eq (drgnx-topline--line) drgnx-topline--fallback))
          (should (equal drgnx-topline--error "no title for you")))
        ;; after the retry time and with the cause gone: the line is back
        (setq now 111.0))
      (should (string-match-p "◆ proj" (drgnx-topline-test--text)))
      (should-not drgnx-topline--error))))

(ert-deftest drgnx-topline/a-failing-line-never-resizes-the-windows ()
  ;; The loop that spun a session: the line failed, redisplay took the tab bar away (lines 0), the resize hook gave it back,
  ;; every cycle resized all windows and ran window-configuration-change-hook.  Redisplay is simulated: it sets the lines
  ;; to 0 whenever the format fails.
  (drgnx-topline-test--with 'vscode
    (let ((drgnx-topline-test--wcc 0) (frame (selected-frame)))
      (cl-letf (((symbol-function 'drgnx-topline--now) (lambda () 100.0))
                ((symbol-function 'drgnx-face-drawn-title-p) (lambda (&optional _) (error "no title for you"))))
        (add-hook 'window-configuration-change-hook #'drgnx-topline-test--count-wcc 90)
        (unwind-protect
            (progn
              (drgnx-topline--on)
              (let ((before drgnx-topline-test--wcc))
                (dotimes (_ 6)
                  (drgnx-topline--line)                       ; the tab bar asks for its items: it fails
                  (set-frame-parameter frame 'tab-bar-lines 0)   ; and takes the line away
                  (drgnx-topline--fit frame))                 ; the resize hook
                (should (= before drgnx-topline-test--wcc))
                (should (= 0 (frame-parameter frame 'tab-bar-lines)))))   ; not given back
          (remove-hook 'window-configuration-change-hook #'drgnx-topline-test--count-wcc))))))

(ert-deftest drgnx-topline/redisplay-is-not-fought-with ()
  ;; a terminal frame: the answer is decided when it changes; what redisplay did to the lines since stays
  (drgnx-topline-test--with 'vscode
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil))
              ((symbol-function 'frame-height) (lambda (&optional _) 30)))
      (let ((frame (selected-frame)) (sets 0))
        (drgnx-topline--on)
        (should (= 1 (frame-parameter frame 'tab-bar-lines)))
        (cl-letf* ((real (symbol-function 'set-frame-parameter))
                   ((symbol-function 'set-frame-parameter)
                    (lambda (f p v) (when (eq p 'tab-bar-lines) (setq sets (1+ sets))) (funcall real f p v))))
          (dolist (lines '(2 0 2))                           ; wrapped, taken away, wrapped
            (funcall real frame 'tab-bar-lines lines)
            (drgnx-topline--fit frame)
            (should (= lines (frame-parameter frame 'tab-bar-lines))))
          (should (= 0 sets)))))))

(ert-deftest drgnx-topline/a-graphical-frame-is-never-given-lines ()
  (drgnx-topline-test--with 'vscode
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'frame-height) (lambda (&optional _) 5)))
      (let ((frame (selected-frame)))
        (drgnx-topline--on)
        (set-frame-parameter frame 'tab-bar-lines 0)         ; redisplay took it
        (drgnx-topline--fit frame)
        (should (= 0 (frame-parameter frame 'tab-bar-lines)))
        (should-not (frame-parameter frame 'tab-bar-lines-keep-state))
        ;; what a text frame left on it (the frame made after init takes over the initial one's) is undone once
        (set-frame-parameter frame 'tab-bar-lines-keep-state t)
        (drgnx-topline--fit frame)
        (should-not (frame-parameter frame 'tab-bar-lines-keep-state))
        (should (= 1 (frame-parameter frame 'tab-bar-lines)))))))

(ert-deftest drgnx-topline/the-tab-bar-faces-spec-is-put-back ()
  ;; not stubbed: the real defface spec, changed while the line is on
  (drgnx-topline-test--with 'vscode
    (let ((tab-bar-mode nil) (spec (get 'tab-bar 'face-defface-spec)))
      (drgnx-topline--apply)
      (should-not (equal (get 'tab-bar 'face-defface-spec) spec))
      (should (equal (get 'tab-bar 'face-defface-spec) '((t :inherit tab-line :height 1.0 :box nil))))
      (drgnx-topline--off)
      (should (equal (get 'tab-bar 'face-defface-spec) spec)))))

(ert-deftest drgnx-topline/a-tab-bar-that-was-already-on-is-the-users ()
  (drgnx-topline-test--with 'vscode
    (let ((tab-bar-mode t) (before (default-value 'tab-bar-format)))
      (drgnx-topline--apply)
      (should (equal (default-value 'tab-bar-format) before))
      (should-not drgnx-topline--saved)
      (should-not (memq #'drgnx-topline--fit (alist-get 'frame-added drgnx-state--idle))))))

(ert-deftest drgnx-topline/reads-cached-state-only-and-is-memoized ()
  (drgnx-topline-test--with 'vscode
    (setq-local vc-mode " Git-main")
    (let ((first (drgnx-topline--line)))
      ;; nothing ran git or any process: and nothing is made again while nothing changed
      (cl-letf (((symbol-function 'call-process) (lambda (&rest _) (error "ran a process")))
                ((symbol-function 'process-file) (lambda (&rest _) (error "ran a process")))
                ((symbol-function 'start-process) (lambda (&rest _) (error "ran a process")))
                ((symbol-function 'drgnx-topline--build) (lambda (&rest _) (error "built again"))))
        (should (eq first (drgnx-topline--line))))
      ;; the branch changed, a new profile bound the keys, the frame got wider: made again
      (setq-local vc-mode " Git-other")
      (let ((second (drgnx-topline--line)))
        (should-not (eq first second))
        (should (string-match-p "other" (drgnx-topline-test--text)))
        (setf (drgnx-cmd-bound (drgnx-commands-get 'palette)) (list (cons "<f1>" nil)))
        (should-not (eq second (drgnx-topline--line)))
        (should (string-match-p "<f1> commands" (drgnx-topline-test--text)))
        (let ((third (drgnx-topline--line)))
          (cl-letf (((symbol-function 'frame-text-cols) (lambda (&optional _) 100)))
            (should-not (eq third (drgnx-topline--line)))))))))

(ert-deftest drgnx-topline/the-branch-comes-from-the-git-cache-the-status-bar-reads ()
  "An untracked file has no branch in `vc-mode'; the status bar shows it from drgnx's git cache, so does the line."
  (drgnx-topline-test--with 'vscode
    (let ((drgnx-git--roots (make-hash-table :test #'equal))
          (root "/tmp/drgnx-tl-repo/"))
      (drgnx-cache--clear 'git-status)
      (setq-local buffer-file-name "/tmp/drgnx-tl-repo/src/new.el")
      (setq-local vc-mode nil)
      (should (string-match-p "◆ proj +⌕" (drgnx-topline-test--text)))   ; the cache has not read it yet
      ;; the cache finds the repository, then a status run reads its branch (`drgnx-git-changed-functions', with the
      ;; status bar off the line's own hook moves the epoch `git'): the line is made again each time
      (puthash "/tmp/drgnx-tl-repo/src/" root drgnx-git--roots)
      (should (string-match-p "◆ proj +⌕" (drgnx-topline-test--text)))
      (drgnx-cache-put 'git-status root (list :branch (list :head "main")))
      (drgnx-topline--git-changed root)
      (should (string-match-p "◆ proj · main" (drgnx-topline-test--text)))
      (drgnx-cache-put 'git-status root (list :branch (list :head "feature")))
      (drgnx-topline--git-changed root)
      (should (string-match-p "◆ proj · feature" (drgnx-topline-test--text)))
      ;; `vc-mode' is only the fallback (the same as the status bar's)
      (setq-local vc-mode " Git-other")
      (should (string-match-p "· feature" (drgnx-topline-test--text)))
      (drgnx-cache-put 'git-status root (list :branch (list :head nil :detached t)))
      (drgnx-topline--git-changed root)
      (should (string-match-p "· (detached)" (drgnx-topline-test--text)))
      ;; no cache entry: vc-mode's branch
      (drgnx-cache-remove 'git-status root)
      (drgnx-topline--git-changed root)
      (should (string-match-p "· other" (drgnx-topline-test--text))))))

(ert-deftest drgnx-topline/a-memo-hit-allocates-nothing ()
  ;; the tab bar asks for the items about 40 times per keystroke in some flows
  (drgnx-topline-test--with 'vscode
    (setq-local vc-mode " Git-main")
    (drgnx-test-use-editor (selected-window))                ; as in a session: else the window is searched for
    (setq-local buffer-file-name "/tmp/drgnx-tl-repo/a.el")
    ;; the line and everything it calls on a hit, compiled (interpreted code conses for its own bookkeeping): nothing
    ;; at all is allocated, and the git cache is not read
    (let ((first (drgnx-topline--line)))
      (cl-letf (((symbol-function 'drgnx-git-branch) (lambda (_) (error "read the git cache")))
                ((symbol-function 'drgnx-git-cached-root) (lambda (_) (error "read the git cache"))))
        (should (= 0 (drgnx-memo-fixture-alloc #'drgnx-topline--line
                                               'drgnx-topline--line 'drgnx-topline--failing-p
                                               'drgnx-topline--drawn-title-p 'drgnx-face-drawn-title-p
                                               'drgnx-state-editor-window 'drgnx-state--record 'drgnx-commands-get
                                               'drgnx-cmd-command 'drgnx-cmd-bound 'drgnx-topline--hint-command
                                               'drgnx-topline--hint-bound 'drgnx-git-roots-known)))
        (should (eq first (drgnx-topline--line)))))))

(ert-deftest drgnx-topline/a-git-change-rebuilds-the-line ()
  "The branch is read when the epoch `git' moves, not per redisplay: a status run that read it moves the epoch (the
status bar's hook while it is on, only for a new branch; the line's own while it is off)."
  (drgnx-topline-test--with 'vscode
    (let ((drgnx-git--roots (make-hash-table :test #'equal))
          (root "/tmp/drgnx-tl-repo/"))
      (drgnx-cache--clear 'git-status)
      (setq-local buffer-file-name "/tmp/drgnx-tl-repo/a.el")
      (setq-local vc-mode nil)
      (puthash "/tmp/drgnx-tl-repo/" root drgnx-git--roots)
      (drgnx-cache-put 'git-status root (list :branch (list :head "main")))
      (drgnx-topline--git-changed root)
      (let* ((tab-bar-mode nil) (_ (drgnx-topline--on)) (first (drgnx-topline--line)))
        (should (string-match-p "· main" (drgnx-topline-test--text)))
        ;; the cache changed, nobody said so: the line is not made again (it does not read the cache)
        (drgnx-cache-put 'git-status root (list :branch (list :head "feature")))
        (should (eq first (drgnx-topline--line)))
        ;; the status bar is on: it moves the epoch, for a new branch only; the line's hook leaves it alone
        (let ((drgnx-statusbar-mode t) (before (drgnx-epoch 'git)))
          (run-hook-with-args 'drgnx-git-changed-functions root)
          (should (eq first (drgnx-topline--line)))
          (should (eql before (drgnx-epoch 'git))))
        ;; the status bar is off: the status run's hook moves the epoch, and the line shows the new branch
        (let ((drgnx-statusbar-mode nil))
          (run-hook-with-args 'drgnx-git-changed-functions root))
        (let ((second (drgnx-topline--line)))
          (should-not (eq first second))
          (should (string-match-p "· feature" (drgnx-topline-test--text)))
          ;; the bump the status bar makes rebuilds it too
          (drgnx-cache-put 'git-status root (list :branch (list :head "other")))
          (drgnx-epoch-bump 'git root)
          (should-not (eq second (drgnx-topline--line)))
          (should (string-match-p "· other" (drgnx-topline-test--text))))
        (drgnx-topline--off)
        (should-not (memq #'drgnx-topline--git-changed drgnx-git-changed-functions))))))

(ert-deftest drgnx-topline/a-vc-mode-change-rebuilds-the-line ()
  "`vc-mode' is not a key: setting it moves the epoch `buffer-look' of its buffer (a watcher), which rebuilds the
line."
  (drgnx-topline-test--with 'vscode
    (setq-local vc-mode " Git-main")
    (let ((first (drgnx-topline--line)))
      (should (string-match-p "· main" (drgnx-topline-test--text)))
      (should (eq first (drgnx-topline--line)))
      (setq-local vc-mode " Git-other")
      (let ((second (drgnx-topline--line)))
        (should-not (eq first second))
        (should (string-match-p "· other" (drgnx-topline-test--text)))
        ;; another buffer's `vc-mode' moves only that buffer's epoch
        (with-temp-buffer
          (setq-local vc-mode " Git-elsewhere"))
        (should (eq second (drgnx-topline--line)))))))

(ert-deftest drgnx-topline/the-tab-bar-sizes-no-tabs ()
  (drgnx-topline-test--with 'vscode
    (let ((tab-bar-mode nil) (standard (eval (car (get 'tab-bar-auto-width 'standard-value)) t)))
      (should (eq (default-value 'tab-bar-auto-width) standard))
      (drgnx-topline--apply)
      (should-not (default-value 'tab-bar-auto-width))
      (drgnx-topline--apply)                                 ; again: saved once, not overwritten with nil
      (drgnx-topline--off)
      (should (eq (default-value 'tab-bar-auto-width) standard)))
    ;; a value of the user's is left alone, then and when the line goes off
    (let ((tab-bar-mode nil) (tab-bar-auto-width 'mine))
      (drgnx-topline--apply)
      (should (eq (default-value 'tab-bar-auto-width) 'mine))
      (drgnx-topline--off)
      (should (eq (default-value 'tab-bar-auto-width) 'mine)))))

(ert-deftest drgnx-topline/a-width-change-redraws-and-never-touches-the-lines ()
  (drgnx-topline-test--with 'vscode
    (let ((updates 0) (width 80) (frame (selected-frame)) (param-sets 0))
      (cl-letf (((symbol-function 'frame-text-cols) (lambda (&optional _) width))
                ((symbol-function 'force-mode-line-update) (lambda (&optional _) (setq updates (1+ updates)))))
        (cl-letf* ((real (symbol-function 'set-frame-parameter))
                   ((symbol-function 'set-frame-parameter) (lambda (f p v) (setq param-sets (1+ param-sets)) (funcall real f p v))))
          (drgnx-topline--line)
          ;; taller only: the same columns
          (drgnx-topline--resized (list :frame frame :old (list :cols 80 :lines 30) :new (list :cols 80 :lines 40)))
          (should (= 0 updates))
          (setq width 100)
          (drgnx-topline--resized (list :frame frame :old (list :cols 80 :lines 40) :new (list :cols 100 :lines 40)))
          (should (= 1 updates))
          (drgnx-topline--line)                              ; the tab bar asked: made for 100
          (should (string-match-p "⌕" (drgnx-topline-test--text)))
          (should (= 0 param-sets)))))))

(ert-deftest drgnx-topline/the-mark-leaves-room-for-the-controls ()
  (drgnx-topline-test--with 'vscode
    (setq-local drgnx-chrome--root (cons default-directory "/x/a-very-long-project-name-for-the-cut-test/"))
    (cl-letf (((symbol-function 'frame-text-cols) (lambda (&optional _) 40))
              ((symbol-function 'drgnx-face-drawn-title-p) (lambda (&optional _) t)))
      (let* ((items (drgnx-topline--line))
             (text (mapconcat (lambda (i) (substring-no-properties (nth 2 i))) items "")))
        (should (<= (string-width text) 40))
        (should (string-match-p "– ▢ × *\\'" text))              ; the controls are whole at the right end
        ;; cut with Emacs's ellipsis: "…" where the terminal shows it, "..." in a C locale (CI's)
        (should (string-search (truncate-string-ellipsis) text))))))

(ert-deftest drgnx-topline/a-clock-that-went-back-does-not-keep-the-line-failing ()
  (drgnx-topline-test--with 'vscode
    (let ((drgnx-topline--error "x") (drgnx-topline--error-at 500.0))
      (cl-letf (((symbol-function 'drgnx-topline--now) (lambda () 100.0)))   ; before the error: not 400 s of failing
        (should-not (drgnx-topline--failing-p)))
      (cl-letf (((symbol-function 'drgnx-topline--now) (lambda () 505.0)))
        (should (drgnx-topline--failing-p)))
      (cl-letf (((symbol-function 'drgnx-topline--now) (lambda () 511.0)))
        (should-not (drgnx-topline--failing-p))))))

(defun drgnx-topline-test--first-note-timer-p (timer)
  "Non-nil when TIMER is the layer's timer of the key `topline-first-note'."
  (and (eq (timer--function timer) #'drgnx-timer--fire)
       (eq (drgnx-timer--entry-key (car (timer--args timer))) 'topline-first-note)))

(ert-deftest drgnx-topline/the-first-project-is-looked-up-once-when-idle ()
  (drgnx-topline-test--with 'vscode
    (let ((tab-bar-mode nil) (asked 0))
      (setq-local drgnx-chrome--root nil)
      (drgnx-topline--on)
      (should (drgnx-timer-active-p 'topline-first-note))
      (should (equal (seq-filter (lambda (e) (eq (car e) 'topline-first-note)) (drgnx-timer-pending))
                     '((topline-first-note ui/face start))))
      (cl-letf (((symbol-function 'project-current) (lambda (&rest _) (setq asked (1+ asked)) '(transient . "/x/proj/"))))
        (drgnx-topline--first-note)
        (should (= 1 asked))
        (should (string-match-p "◆ proj" (drgnx-topline-test--text))))
      (drgnx-topline--on)                                    ; again: one timer, not two
      ;; its own timers only: the bus's idle flush is a layer timer too (signal-flush)
      (should (= 1 (cl-count-if #'drgnx-topline-test--first-note-timer-p timer-idle-list)))
      (drgnx-topline--off)                                   ; the owner cancels it
      (should-not (drgnx-timer-active-p 'topline-first-note))
      (should-not (cl-find-if #'drgnx-topline-test--first-note-timer-p timer-idle-list)))))

(ert-deftest drgnx-topline/two-frames-do-not-make-each-other-start-again ()
  ;; each frame's tab bar is drawn with that frame selected: one memo for all would build the line at every redisplay
  (drgnx-topline-test--with 'vscode
    (let ((real (selected-frame)) (other (make-symbol "other-frame")) (current nil) (builds 0)
          (build (symbol-function 'drgnx-topline--build)))
      (setq current real)
      (cl-letf (((symbol-function 'selected-frame) (lambda () current))
                ((symbol-function 'frame-text-cols) (lambda (&optional _) 80))
                ((symbol-function 'drgnx-topline--build)
                 (lambda (&rest args) (setq builds (1+ builds)) (apply build args))))
        (let ((a (drgnx-topline--line)))
          (setq current other)
          (let ((b (drgnx-topline--line)))
            (setq current real)
            (should (eq a (drgnx-topline--line)))
            (setq current other)
            (should (eq b (drgnx-topline--line)))
            (should (= 2 builds))))))))

(ert-deftest drgnx-topline/a-resize-redraws-through-the-store ()
  (drgnx-topline-test--with 'vscode
    (let ((tab-bar-mode nil) (updates 0) (width 80) (frame (selected-frame)) (param-sets 0))
      (drgnx-topline--on)
      ;; the store is the only door: `now' lane, no hook of Emacs's
      (should (memq #'drgnx-topline--resized (alist-get 'frame-resized drgnx-state--now)))
      (should-not (memq #'drgnx-topline--resized (alist-get 'frame-resized drgnx-state--idle)))
      (should-not (memq #'drgnx-topline--resized window-size-change-functions))
      (should-not (memq #'drgnx-topline--fit window-size-change-functions))
      (should-not (memq #'drgnx-topline--fit after-make-frame-functions))
      (cl-letf (((symbol-function 'frame-text-cols) (lambda (&optional _) width))
                ((symbol-function 'force-mode-line-update) (lambda (&optional _) (setq updates (1+ updates)))))
        (cl-letf* ((real (symbol-function 'set-frame-parameter))
                   ((symbol-function 'set-frame-parameter) (lambda (f p v) (setq param-sets (1+ param-sets)) (funcall real f p v))))
          (drgnx-topline--line)
          (setq width 100)
          (drgnx-state--emit 'frame-resized (list :frame frame :old (list :cols 80) :new (list :cols 100)))   ; as the observer delivers it
          (should (= 1 updates))
          (should (= 0 param-sets))))))
  ;; off: nothing is called any more
  (drgnx-topline-test--with 'vscode
    (let ((tab-bar-mode nil))
      (drgnx-topline--on)
      (drgnx-topline--off)
      (should-not (memq #'drgnx-topline--resized (alist-get 'frame-resized drgnx-state--now))))))

(ert-deftest drgnx-topline/fit-is-on-the-idle-lane ()
  (drgnx-topline-test--with 'vscode
    (let ((tab-bar-mode nil))
      (drgnx-topline--on)
      ;; it may set `tab-bar-lines', which resizes windows: never on the `now' lane (I9)
      (dolist (event '(frame-added frame-resized))
        (should (memq #'drgnx-topline--fit (alist-get event drgnx-state--idle)))
        (should-not (memq #'drgnx-topline--fit (alist-get event drgnx-state--now))))
      ;; it takes the event's data as well as a frame, and leaves a child frame alone
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil))
                ((symbol-function 'frame-height) (lambda (&optional _) 18)))
        (drgnx-topline--fit (list :frame (selected-frame) :kind 'tty))
        (should (= 0 (frame-parameter nil 'tab-bar-lines)))
        (cl-letf (((symbol-function 'drgnx-state-frame-kind) (lambda (_f) 'child))
                  ((symbol-function 'frame-height) (lambda (&optional _) 30)))
          (drgnx-topline--fit (list :frame (selected-frame)))
          (should (= 0 (frame-parameter nil 'tab-bar-lines)))))
      (drgnx-topline--off)
      (dolist (event '(frame-added frame-resized))
        (should-not (memq #'drgnx-topline--fit (alist-get event drgnx-state--idle)))))))

(ert-deftest drgnx-topline/an-idle-frame-gets-its-line-back-after-an-error ()
  ;; M12f-A10-1: no command is run; the timer clears the failure and redraws every frame's tab bar
  (drgnx-topline-test--with 'vscode
    (drgnx-test-with-clock ()
      (let ((tab-bar-mode nil) (updates 0) (broken t))
        (drgnx-topline--on)
        (cl-letf (((symbol-function 'drgnx-face-drawn-title-p) (lambda (&optional _) (when broken (error "no title for you"))))
                  ((symbol-function 'force-mode-line-update) (lambda (&optional _) (setq updates (1+ updates)))))
          (should (eq (drgnx-topline--line) drgnx-topline--fallback))
          (should drgnx-topline--error)
          (should (equal (seq-filter (lambda (e) (eq (car e) 'topline-retry)) (drgnx-timer-pending))
                         '((topline-retry ui/face start))))
          (setq broken nil)
          (drgnx-test-advance (- drgnx-topline-retry-seconds 1))
          (should drgnx-topline--error)                      ; not yet
          (should (= 0 updates))
          (drgnx-test-advance 2)
          (should-not drgnx-topline--error)
          (should-not drgnx-topline--error-at)
          (should (>= updates 1))                            ; the tab bars were asked to redraw
          (should-not (drgnx-timer-active-p 'topline-retry))
          (should (string-match-p "◆ proj" (drgnx-topline-test--text))))
        (drgnx-topline--off)))))

(ert-deftest drgnx-topline/off-cancels-the-retry ()
  (drgnx-topline-test--with 'vscode
    (drgnx-test-with-clock ()
      (let ((tab-bar-mode nil))
        (drgnx-topline--on)
        (cl-letf (((symbol-function 'drgnx-face-drawn-title-p) (lambda (&optional _) (error "no title for you"))))
          (drgnx-topline--line))
        (should (drgnx-timer-active-p 'topline-retry))
        (drgnx-topline--off)
        (should-not (drgnx-timer-active-p 'topline-retry))
        (should-not timer-list)
        (should-not drgnx-topline--error)))))

;;; mod-topline-test.el ends here

(ert-deftest drgnx-topline/keys-come-from-the-label ()
  ;; the hint's keys are `drgnx-surfaces-key-label' of the starter list's ids (any key, the keymap kept)
  (drgnx-topline-test--with 'vscode
    (let (asked)
      (cl-letf (((symbol-function 'drgnx-surfaces-key-label)
                 (lambda (cmd &rest args) (push (cons (drgnx-cmd-id cmd) args) asked) (format "K-%s" (drgnx-cmd-id cmd)))))
        (let ((text (drgnx-topline-test--text)))
          (should (string-match-p "K-go-quick-open files · K-palette commands · K-keys-sheet all keys" text))))
      (should (equal (reverse asked)
                     (mapcar (lambda (row) (list (car row) :any t)) drgnx-surfaces-starter-commands))))
    (should-not (fboundp 'drgnx-topline--key))))
