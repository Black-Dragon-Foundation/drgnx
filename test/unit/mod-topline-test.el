;;; mod-topline-test.el --- batch tests: the top line — project, branch, the keys that open everything (M12f A6) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-face" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-topline" drgnx-dir) nil t)
(defvar drgnx-signal--editor-window)

(defvar drgnx-topline-test--ran nil "The stub commands that ran (newest first).")
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
buffer of the selected window (a temp buffer in project `proj', no git).  Faces and the project lookup are stubs."
  (declare (indent 1))
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-topline-test--ran nil)
         (drgnx-topline--memo nil) (drgnx-topline--saved nil) (drgnx-topline--format nil) (drgnx-topline--active nil)
         (drgnx-topline drgnx-topline) (drgnx-topline-min-lines drgnx-topline-min-lines)
         (drgnx-signal--editor-window nil)
         (default-frame-alist (copy-alist default-frame-alist))
         (tab-bar-format (default-value 'tab-bar-format)) (tab-bar-show (default-value 'tab-bar-show))
         (old (window-buffer (selected-window))))
     (cl-letf (((symbol-function 'drgnx-face--ascii-frame-p) (lambda (_frame) nil))   ; the batch terminal is not UTF-8
               ((symbol-function 'drgnx-chrome--project-root) (lambda (_file) "/x/proj/"))
               ((symbol-function 'face-spec-set) #'ignore))
       (drgnx-command-define 'go-quick-open :title "Quick Open" :category "Go" :command #'drgnx-topline-test-files)
       (drgnx-command-define 'palette :title "Command Palette" :category "View" :command #'drgnx-topline-test-palette)
       (drgnx-command-define 'keys-sheet :title "Keys" :category "Help" :command #'drgnx-topline-test-keys)
       (drgnx-topline-test--bind ,profile)
       (with-temp-buffer
         (set-window-buffer (selected-window) (current-buffer))
         (unwind-protect (progn ,@body)
           (drgnx-topline--off)
           (set-window-buffer (selected-window) old))))))

(defun drgnx-topline-test--text ()
  "What the line shows now, as plain text."
  (mapconcat (lambda (item) (substring-no-properties (nth 2 item))) (drgnx-topline--line) ""))

(defun drgnx-topline-test--item (key)
  "The line's item named KEY."
  (assq key (drgnx-topline--line)))

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
    (cl-letf (((symbol-function 'drgnx-chrome--project-root) (lambda (_file) nil)))
      (setq drgnx-topline--memo nil)
      (should (string-match-p "◆ drgnx +⌕" (drgnx-topline-test--text))))))

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
      (should (= 1 (cl-count #'drgnx-topline--fit window-size-change-functions)))
      (should (memq #'drgnx-topline--fit-all window-setup-hook))   ; a window's frame is made after init: fit it then
      (setq drgnx-topline--active t)
      (drgnx-topline--set 'drgnx-topline nil)               ; the setter applies it live
      (should (equal (default-value 'tab-bar-format) before))
      (should-not tab-bar-mode)
      (should-not (memq #'drgnx-topline--fit window-size-change-functions))
      (should-not (memq #'drgnx-topline--fit after-make-frame-functions))
      (should-not (memq #'drgnx-topline--fit-all window-setup-hook))
      (should-not (memq #'drgnx-topline--fit-all emacs-startup-hook)))))

(ert-deftest drgnx-topline/window-controls-only-with-a-drawn-title ()
  (drgnx-topline-test--with 'vscode
    (should-not (string-match-p "[–▢✕]" (drgnx-topline-test--text)))   ; A2 is not there yet: never
    (should-not (assq 'drgnx-topline-close (drgnx-topline--line)))
    (cl-letf (((symbol-function 'drgnx-face-drawn-title-p) (lambda (&optional _frame) t)))
      (let ((text (drgnx-topline-test--text)))
        (should (string-match-p "– ▢ ✕" text))
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

(ert-deftest drgnx-topline/a-new-width-makes-the-tab-bar-ask-again ()
  ;; the hint is centred for the width it was made for; the tab bar does not ask for its items on a resize alone
  (drgnx-topline-test--with 'vscode
    (let ((updates 0) (width 80))
      (cl-letf (((symbol-function 'force-mode-line-update) (lambda (&optional _all) (setq updates (1+ updates))))
                ((symbol-function 'frame-width) (lambda (&optional _) width)))
        (drgnx-topline--on)
        (let ((n updates))
          (drgnx-topline--fit)                              ; the same width: nothing to redo
          (should (= n updates))
          (setq width 120)
          (drgnx-topline--fit)
          (should (= (1+ n) updates))
          (drgnx-topline--fit)
          (should (= (1+ n) updates)))))))

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
    (setq drgnx-topline--memo nil)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) t))
              ((symbol-function 'drgnx-tty-sendable-key) (lambda (_frame _key) (error "not on a window"))))
      (should (string-match-p "C-S-p commands" (drgnx-topline-test--text))))))

(ert-deftest drgnx-topline/glyphs-have-an-ascii-form ()
  (drgnx-topline-test--with 'vscode
    (setq-local vc-mode " Git-main")
    (cl-letf (((symbol-function 'drgnx-face--ascii-frame-p) (lambda (_frame) t)))
      (should (string-match-p "\\`<> proj | main" (string-trim-left (drgnx-topline-test--text))))
      (should (string-match-p "/ C-p files | C-S-p commands" (drgnx-topline-test--text))))
    (should (string-match-p "◆" (drgnx-topline-test--text)))))

(ert-deftest drgnx-topline/never-wider-than-its-frame ()
  (drgnx-topline-test--with 'vscode
    (setq-local vc-mode " Git-a-very-long-branch-name-that-goes-on-and-on")
    (dolist (w '(120 70 40 12))
      (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) w)))
        (let ((text (drgnx-topline-test--text)))
          (should (<= (string-width text) w))
          ;; the hint goes before the place is cut
          (when (< w 70) (should-not (string-match-p "⌕" text))))))))

(ert-deftest drgnx-topline/a-buffer-without-a-file-asks-for-its-directory ()
  ;; the breadcrumb's lookup asks `file-remote-p' about what it is given: a scratch buffer must not give it nil
  (drgnx-topline-test--with 'vscode
    (let (asked)
      (cl-letf (((symbol-function 'drgnx-chrome--project-root) (lambda (file) (setq asked file) "/x/proj/")))
        (should-not buffer-file-name)
        (should (string-match-p "◆ proj" (drgnx-topline-test--text)))
        (should (equal asked default-directory))))))

(ert-deftest drgnx-topline/an-error-never-takes-the-line-away ()
  ;; with no items Emacs sets the tab bar's lines to 0, and the line flickers on and off with every redisplay
  (drgnx-topline-test--with 'vscode
    (let ((drgnx-topline--error nil) (before (current-message)))
      (cl-letf (((symbol-function 'drgnx-chrome--project-root) (lambda (_file) (error "no project for you"))))
        (should (equal (substring-no-properties (nth 2 (car (drgnx-topline--line)))) " drgnx"))
        (should (equal drgnx-topline--error "no project for you"))
        (should (equal (current-message) before))))))                 ; no message per redisplay

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
          (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 100)))
            (should-not (eq third (drgnx-topline--line)))))))))

;;; mod-topline-test.el ends here
