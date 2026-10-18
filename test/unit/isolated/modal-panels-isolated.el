;;; modal-panels-isolated.el --- batch tests (own Emacs, test/unit/modal-panels-test.el): panels under the Vim stack -*- lexical-binding: t -*-
;; Needs the real evil: DRGNX_MODAL_ELPA (docs/develop/harness.md, "Modal tests"); without it those tests skip.
;; The full registry and the startup modules run in a temp configuration (editor/evil chosen, the Vim stack applied),
;; so the keys are the shipped ones.  Keys are pressed with `execute-kbd-macro' in a panel buffer shown in the
;; selected window.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-modal)
(require 'drgnx-explorer)
(require 'drgnx-buffers)
(require 'drgnx-outline)
(require 'drgnx-modules)
(load (expand-file-name "test/fixtures/modal-elpa" drgnx-dir) nil t)

(defvar evil-state)
(defvar drgnx-close--here)
(declare-function evil-visual-char "evil-commands")
(declare-function drgnx-close-pane "drgnx-close")
(declare-function evil-normal-state "evil-states")
(declare-function evil-insert-state "evil-states")
(declare-function evil-emacs-state "evil-states")
(declare-function drgnx-evil-stop "drgnx-evil")
(declare-function drgnx-diff-mode "drgnx-diff")
(declare-function drgnx-review-mode "drgnx-review")
(declare-function drgnx-prs-mode "drgnx-prs")
(declare-function drgnx-work-mode "drgnx-work-ui")
(declare-function drgnx-agents-list-mode "drgnx-agents-ui")
(declare-function drgnx-onboard-mode "drgnx-onboard")

(defvar drgnx-modal-panels-test--calls nil "What the stubbed commands ran, newest first.")

(defmacro drgnx-modal-panels-test--with (&rest body)
  "BODY with evil running in the Vim stack, all startup modules run, in a temp configuration and state dir.
`find-file', `revert-buffer' and the focus commands are recorded in `drgnx-modal-panels-test--calls'; Emacs cannot quit."
  (declare (indent 0))
  `(drgnx-modal-test-with-evil
     (let* ((dir (file-name-as-directory (make-temp-file "drgnx-modal-panels" t)))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir "config")
                                               (concat "DRGNX_DATA_DIR=" dir "data")
                                               (concat "XDG_STATE_HOME=" dir "state")
                                               (concat "HOME=" dir "home"))
                                         process-environment))
            (drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
            (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
            (drgnx-modules--state nil) (drgnx-modal-engines nil) (drgnx-modal-running nil)
            (drgnx-keys--applied nil) (drgnx-keys-profiles nil) (drgnx-keys-problems nil) (drgnx-keys-last nil)
            (drgnx-keys--session-layers nil)
            (emulation-mode-map-alists emulation-mode-map-alists)
            (mode-line-saved (default-value 'mode-line-format))
            (drgnx-modal-panels-test--calls nil))
       (make-directory (concat dir "config") t)
       (make-directory (concat dir "home") t)
       (write-region "(:version 1 :enabled (editor/evil))\n" nil (concat dir "config/modules.eld") nil 'silent)
       (unwind-protect
           (progn
             (drgnx--core-commands)
             (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
             (drgnx-modules-run 'startup)
             (drgnx-keys-use '((vim app editing window)))
             (should (eq drgnx-modal-running 'evil))
             (cl-letf (((symbol-function 'kill-emacs) (lambda (&rest _) (ert-fail "kill-emacs was called")))
                       ((symbol-function 'save-buffers-kill-terminal) (lambda (&rest _) (ert-fail "Emacs was quit")))
                       ((symbol-function 'find-file)
                        (lambda (&rest args) (interactive) (push (cons 'find-file args) drgnx-modal-panels-test--calls)))
                       ((symbol-function 'drgnx-wb-focus-editor)
                        (lambda () (interactive) (push '(focus-editor) drgnx-modal-panels-test--calls)))
                       ((symbol-function 'drgnx-wb-focus-right)
                        (lambda () (interactive) (push '(focus-right) drgnx-modal-panels-test--calls)))
                       ((symbol-function 'revert-buffer)
                        (lambda (&rest _) (interactive) (push (list 'revert major-mode) drgnx-modal-panels-test--calls))))
               ,@body))
         (when (fboundp 'drgnx-evil-stop) (drgnx-evil-stop))
         (drgnx-keys--restore)
         (setq-default mode-line-format mode-line-saved)
         (delete-directory dir t)))))

(defun drgnx-modal-panels-test--calls ()
  "What the stubbed commands ran since the last call, oldest first."
  (prog1 (reverse drgnx-modal-panels-test--calls) (setq drgnx-modal-panels-test--calls nil)))

(defmacro drgnx-modal-panels-test--show (buffer &rest body)
  "BODY with BUFFER shown in the only window, selected and current; the layout is put back after."
  (declare (indent 1))
  `(save-window-excursion
     (delete-other-windows)
     (set-window-buffer (selected-window) ,buffer)
     (with-current-buffer ,buffer ,@body)))

(defmacro drgnx-modal-panels-test--explorer (root &rest body)
  "BODY with the Explorer rooted at a temp ROOT holding a.txt … z.txt, shown in the selected window."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-modal-explorer" t)))
          (drgnx-wb--sections nil) (drgnx-signal--editor-window nil) (drgnx-explorer--pressed nil)
          (drgnx-explorer--selection nil) (drgnx-explorer--anchor nil) (drgnx-explorer--focused-before nil)
          (drgnx-explorer--find nil) (drgnx-explorer-compact-folders nil))
     (unwind-protect
         (progn
           (dolist (c (number-sequence ?a ?z))
             (write-region "" nil (expand-file-name (format "%c.txt" c) ,root) nil 'silent))
           (make-directory (expand-file-name "sub" ,root) t)
           (write-region "" nil (expand-file-name "sub/in.txt" ,root) nil 'silent)
           (delete-other-windows)
           (drgnx-explorer-setup)
           (drgnx-explorer-set-roots (list ,root))
           (drgnx-modal-panels-test--show (drgnx-explorer--buffer) ,@body))
       (drgnx-explorer-set-roots nil)
       (when (get-buffer drgnx-explorer-buffer-name) (kill-buffer drgnx-explorer-buffer-name))
       (delete-directory ,root t))))

(defmacro drgnx-modal-panels-test--buffers (&rest body)
  "BODY with the Buffers panel listing three file buffers, shown in the selected window."
  (declare (indent 0))
  `(let ((drgnx-signal--subscribers nil) (drgnx-signal--state nil) (drgnx-signal--editor-window nil)
         (drgnx-wb--sections nil) (drgnx-buffers--order nil) (drgnx-buffers--signature nil)
         (extra nil) (dir (make-temp-file "drgnx-modal-buffers" t)))
     (unwind-protect
         (progn
           (delete-other-windows)
           (drgnx-buffers-setup)
           (drgnx-signal--flush)
           (drgnx-wb-show-sidebar)
           (dolist (n '("pa.txt" "pb.txt" "pc.txt"))
             (let ((f (expand-file-name n dir)))
               (write-region "x\n" nil f nil 'silent)
               (push (find-file-noselect f) extra)))
           (drgnx-signal--flush)
           (drgnx-modal-panels-test--show (get-buffer drgnx-buffers-buffer-name)
             (should (> (count-lines (point-min) (point-max)) 2))
             ,@body))
       (dolist (b extra) (with-current-buffer b (set-buffer-modified-p nil)) (kill-buffer b))
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (when (get-buffer drgnx-buffers-buffer-name) (kill-buffer drgnx-buffers-buffer-name))
       (delete-directory dir t))))

(defmacro drgnx-modal-panels-test--outline (&rest body)
  "BODY with the Outline of a four-definition elisp buffer, shown in the selected window."
  (declare (indent 0))
  `(let ((drgnx-wb--sections nil) (drgnx-signal--subscribers nil) (drgnx-signal--editor-window nil)
         (src (generate-new-buffer "outline-src.el")))
     (delete-other-windows)
     (with-current-buffer src
       (insert "(defun alpha () 1)\n(defvar beta 2)\n(defun gamma () 3)\n(defun delta () 4)\n")
       (emacs-lisp-mode))
     (switch-to-buffer src)
     (setq drgnx-signal--editor-window (selected-window))
     (drgnx-outline-setup)
     (drgnx-wb-show-sidebar)
     (unwind-protect
         (progn
           (drgnx-outline-refresh)
           (drgnx-modal-panels-test--show (get-buffer drgnx-outline-buffer-name) ,@body))
       (drgnx-wb-hide-sidebar)
       (delete-other-windows)
       (kill-buffer src)
       (when (get-buffer drgnx-outline-buffer-name) (kill-buffer drgnx-outline-buffer-name)))))

(defun drgnx-modal-panels-test--press (keys)
  "Press KEYS (a `kbd' string) in the selected window."
  (execute-kbd-macro (kbd keys)))

;;;; Panels, made the way their own tests make them

(defun drgnx-modal-panels-test--rows-buffer (name mode)
  "A new buffer NAME in MODE (a special-mode panel) holding five text rows."
  (let ((b (generate-new-buffer name)))
    (with-current-buffer b
      (funcall mode)
      (let ((inhibit-read-only t)) (insert "one\ntwo\nthree\nfour\nfive\n"))
      (goto-char (point-min)))
    b))

(defun drgnx-modal-panels-test--table-buffer (name mode)
  "A new buffer NAME in MODE (a tabulated-list panel) holding five rows."
  (let ((b (generate-new-buffer name)))
    (with-current-buffer b
      (funcall mode)
      (setq tabulated-list-format [("Name" 12 nil)]
            tabulated-list-entries (mapcar (lambda (n) (list n (vector n))) '("one" "two" "three" "four" "five")))
      (tabulated-list-init-header)
      (tabulated-list-print)
      (goto-char (point-min)))
    b))

(defun drgnx-modal-panels-test--jk (buffer)
  "In BUFFER shown in the selected window: j moves down one row and k back up; return nil, else what went wrong."
  (drgnx-modal-panels-test--show buffer
    (goto-char (point-min))
    (let ((l0 (line-number-at-pos)))
      (drgnx-modal-panels-test--press "j")
      (let ((l1 (line-number-at-pos)))
        (drgnx-modal-panels-test--press "k")
        (let ((l2 (line-number-at-pos)))
          (unless (and (= l1 (1+ l0)) (= l2 l0))
            (format "%s (%s state): rows %d -> %d -> %d" major-mode evil-state l0 l1 l2)))))))

(ert-deftest drgnx-modal-panels/jk-move-in-every-panel ()
  ;; Explorer, Buffers, Outline and Modules are the real panels.  Work, Agents, Diff, Review, PRs and Welcome are
  ;; their real modes holding rows, because their own renderers need git, a gateway or the network; the whole
  ;; panels on screen are Task 14's.
  (drgnx-modal-panels-test--with
    (let (bad)
      (cl-flet ((check (buffer) (when-let* ((e (drgnx-modal-panels-test--jk buffer))) (push e bad))))
        ;; Explorer
        (drgnx-modal-panels-test--explorer root (check (current-buffer)))
        ;; Buffers
        (drgnx-modal-panels-test--buffers (check (current-buffer)))
        ;; Outline
        (drgnx-modal-panels-test--outline (check (current-buffer)))
        ;; Modules
        (let ((b (drgnx-modules-list)))
          (unwind-protect (check b) (kill-buffer b)))
        ;; Work, Diff, Review: special-mode panels
        (dolist (cell '(("work" . drgnx-work-mode) ("diff" . drgnx-diff-mode) ("review" . drgnx-review-mode)))
          (let ((b (drgnx-modal-panels-test--rows-buffer (car cell) (cdr cell))))
            (unwind-protect (check b) (kill-buffer b))))
        ;; Agents list, PRs, Welcome: tabulated-list panels
        (dolist (cell '(("agents" . drgnx-agents-list-mode) ("prs" . drgnx-prs-mode) ("welcome" . drgnx-onboard-mode)))
          (let ((b (drgnx-modal-panels-test--table-buffer (car cell) (cdr cell))))
            (unwind-protect (check b) (kill-buffer b)))))
      (should-not bad))))

(ert-deftest drgnx-modal-panels/explorer-keeps-its-letters ()
  (drgnx-modal-panels-test--with
    (drgnx-modal-panels-test--explorer root
      (should (eq evil-state 'emacs))
      (cl-flet ((row-name () (file-name-nondirectory (directory-file-name (drgnx-explorer-node-at (point)))))
                (goto-row (name)
                  (goto-char (point-min))
                  (while (and (not (eobp))
                              (not (equal name (ignore-errors (file-name-nondirectory
                                                               (directory-file-name (drgnx-explorer-node-at (point))))))))
                    (forward-line 1))))
        ;; l expands a folder, h collapses it
        (goto-row "sub")
        (let ((before (count-lines (point-min) (point-max))))
          (drgnx-modal-panels-test--press "l")
          (should (> (count-lines (point-min) (point-max)) before))
          (goto-row "sub")
          (drgnx-modal-panels-test--press "h")
          (should (= (count-lines (point-min) (point-max)) before)))
        ;; / runs drgnx-explorer-find, and its minibuffer takes a space
        (drgnx-modal-panels-test--press "/ a SPC b RET")
        (should (equal (plist-get drgnx-explorer--find :query) "a b"))
        (drgnx-explorer-find-clear)
        ;; type-ahead: the first letter nothing binds (Explorer, panel and leader maps) jumps by name
        (let ((letter (cl-find-if (lambda (c)
                                    (let ((k (string c)))
                                      (and (eq (key-binding (kbd k)) 'drgnx-explorer-type)
                                           (not (keymap-lookup drgnx-modal-panel-map k))
                                           (not (keymap-lookup drgnx-modal-leader-map k))
                                           (not (keymap-lookup drgnx-explorer-mode-map k)))))
                                  (number-sequence ?a ?z))))
          (should letter)
          (goto-char (point-min))
          (drgnx-modal-panels-test--press (string letter))
          (should (string-prefix-p (string letter) (row-name))))))))

(ert-deftest drgnx-modal-panels/escape-is-dock-back ()
  (drgnx-modal-panels-test--with
    (drgnx-modal-panels-test--explorer root
      (drgnx-modal-panels-test--press "<escape>")
      (should (equal (drgnx-modal-panels-test--calls) '((focus-editor)))))))

(ert-deftest drgnx-modal-panels/close-and-quick-help-keys-beat-evil ()
  ;; M12f-A7-1, A-R2: quick help's and Close Pane's maps sit in front of evil's, quick help's first, so Esc and q
  ;; close a read-only pane in normal state too (evil's normal state took them); Esc in visual state stays evil's
  (drgnx-modal-panels-test--with
    (let ((pos (lambda (a) (or (cl-position a emulation-mode-map-alists) (ert-fail (list "not in the list" a))))))
      (should (< (funcall pos 'drgnx-quickhelp--emulation) (funcall pos 'drgnx-close--emulation)
                 (funcall pos 'evil-mode-map-alist))))
    (let ((b (generate-new-buffer "*drgnx-close-evil*")))
      (unwind-protect
          (drgnx-modal-panels-test--show b
            (insert "one\ntwo\n")
            (setq buffer-read-only t)
            (goto-char (point-min))
            (evil-normal-state)
            (let ((drgnx-close--here t))
              (should (eq (key-binding [escape]) #'drgnx-close-pane))
              (should (eq (key-binding "q") #'drgnx-close-pane))
              (evil-visual-char)
              (should (eq evil-state 'visual))
              (drgnx-modal-panels-test--press "<escape>")
              (should (eq evil-state 'normal))))
        (kill-buffer b)))))

(ert-deftest drgnx-modal-panels/g-refreshes-diff-review-prs ()
  ;; A-34: g is the mode's revert key, as without evil.
  (drgnx-modal-panels-test--with
    (dolist (cell '(("diff" drgnx-diff-mode drgnx-modal-panels-test--rows-buffer)
                    ("review" drgnx-review-mode drgnx-modal-panels-test--rows-buffer)
                    ("prs" drgnx-prs-mode drgnx-modal-panels-test--table-buffer)))
      (let ((b (funcall (nth 2 cell) (car cell) (nth 1 cell))))
        (unwind-protect
            (drgnx-modal-panels-test--show b
              (should (eq evil-state 'emacs))
              (drgnx-modal-panels-test--press "g")
              (should (equal (drgnx-modal-panels-test--calls) (list (list 'revert (nth 1 cell))))))
          (kill-buffer b))))))

(ert-deftest drgnx-modal-panels/leader-and-window-keys-in-panels ()
  (drgnx-modal-panels-test--with
    (drgnx-modal-panels-test--explorer root
      (drgnx-modal-panels-test--press "SPC f f")
      (should (equal (drgnx-modal-panels-test--calls) '((find-file))))
      (drgnx-modal-panels-test--press "C-w l")
      (should (equal (drgnx-modal-panels-test--calls) '((focus-right)))))))

(ert-deftest drgnx-modal-panels/live-driving-keys-reach-the-page ()
  ;; The Live view is a panel (leader and panel maps on); while you drive, SPC, j and C-w are the page's or Emacs's,
  ;; never the leader's; handing back gives the panel its keys again.
  (drgnx-modal-panels-test--with
    (require 'drgnx-live)
    (let ((b (generate-new-buffer " *live-driving*")))
      (unwind-protect
          (drgnx-modal-panels-test--show b
            (drgnx-live-mode)
            (should (eq evil-state 'emacs))
            (should (keymapp (key-binding " ")))
            (should (eq (key-binding "j") #'drgnx-modal-panel-next))
            (should (keymapp (key-binding (kbd "C-w"))))
            (drgnx-live-driving-mode 1)
            (should (eq (key-binding " ") #'drgnx-live-key))
            (should (eq (key-binding "j") #'drgnx-live-key))
            (should (eq (key-binding "k") #'drgnx-live-key))
            (should-not (keymapp (key-binding (kbd "C-w"))))
            (drgnx-live-driving-mode -1)
            (should (eq evil-state 'emacs))
            (should (keymapp (key-binding " ")))
            (should (eq (key-binding "j") #'drgnx-modal-panel-next)))
        (kill-buffer b)))))

(ert-deftest drgnx-modal-panels/no-cursor-box-in-any-state-change ()
  (drgnx-modal-panels-test--with
    (let ((cursors nil))
      (cl-flet ((walk ()
                  (dolist (fn (quote (evil-normal-state evil-insert-state evil-emacs-state)))
                    (funcall fn)
                    (push (cons fn cursor-type) cursors))))
        (drgnx-modal-panels-test--explorer root (walk))
        (drgnx-modal-panels-test--buffers (walk))
        (drgnx-modal-panels-test--outline (walk)))
      (should (= (length cursors) 9))
      (dolist (c cursors) (should (eq (cdr c) nil))))))

(provide 'modal-panels-isolated)
;;; modal-panels-isolated.el ends here
