;;; drgnx-modules-test.el --- live: modules driven by real keys in a GUI session (config=drgnx) -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
(require 'ert)
(require 'drgnx-ui)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(load (expand-file-name "../fixtures/ratatoskr-fixture" (file-name-directory (macroexp-file-name))) nil t)

(defmacro drgnx-live-mod--with (sess &rest body)
  "BODY with SESS a session editing an elisp file (VS Code key profile)."
  (declare (indent 1))
  `(let* ((root (make-temp-file "drgnx-mod" t))
          (file (expand-file-name "f.el" root))
          (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
          (s (progn (write-region "(defun f ()\n  (list 1\n        2))\n" nil file nil 'silent)
                    (drgnx-ui-start "drgnx" (drgnx-ui-size-at-scale "1400x800") 30)))
          (,sess (drgnx-ui-own-session (plist-get s :name))))
     (unwind-protect
         (progn
           (drgnx-ui-call ,sess (format "(progn (find-file %S) (goto-char (point-min)) (drgnx-uitest--json (list :ok t)))" file))
           (drgnx-ui-measure ,sess nil)
           ,@body)
       (drgnx-ui-stop (plist-get s :name))
       (delete-directory root t))))

(defun drgnx-live-mod--q (sess form)
  (car (read-from-string (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form)) :v))))

(ert-deftest drgnx-live/fold-and-unfold-by-keys ()
  (drgnx-live-mod--with sess
    (drgnx-ui-measure sess (list (list :keys "C-{")))
    (should (drgnx-live-mod--q sess "(with-current-buffer (window-buffer (selected-window)) (and (invisible-p (line-end-position)) t))"))
    (drgnx-ui-measure sess (list (list :keys "C-}")))
    (should-not (drgnx-live-mod--q sess "(with-current-buffer (window-buffer (selected-window)) (and (invisible-p (line-end-position)) t))"))))

(ert-deftest drgnx-live/zen-by-keys-gives-the-layout-back ()
  (drgnx-live-mod--with sess
    (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "M-j")))
    (let ((before (drgnx-live-mod--q sess "(sort (mapcar #'window-pixel-edges (window-list nil 'nomini)) (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b))))))")))
      (drgnx-ui-measure sess (list (list :keys "C-k z")))
      ;; one editor window; the status bar is the frame's, not an area zen hides
      (should (= 1 (drgnx-live-mod--q sess "(length (seq-remove (lambda (w) (eq (window-parameter w 'drgnx-role) 'statusbar)) (window-list nil 'nomini)))")))
      (drgnx-ui-measure sess (list (list :keys "C-k z")))
      (should (equal before (drgnx-live-mod--q sess "(sort (mapcar #'window-pixel-edges (window-list nil 'nomini)) (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b))))))"))))))

(defun drgnx-live-mod--found (also)
  "A form for the session: the hub-fed Search view (the rows path) drew f.el's file row and ALSO (a form) holds."
  (format "(with-current-buffer (get-buffer drgnx-replace-buffer-name)
             (and %s (drgnx-replace--rows-p) (> (or (car drgnx-replace--hub-counts) 0) 0)
                  (save-excursion (goto-char (or drgnx-replace--results (point-min))) (re-search-forward \"\\\\_<f\\\\.el\\\\_>\" nil t))
                  t))" also))

(defun drgnx-live-mod--may-start-hub (sess)
  "Let SESS start a hub as an install does (a session has starting off, DRGNX_NO_HUB_START): Ratatoskr is the test's,
and the hub ends with the session.  Nothing is started here: the commands under test start it."
  (let ((bin (or (drgnx-test-ratatoskr-bin) (drgnx-test-no-hub))))
    (should (drgnx-live-mod--q sess (format "(progn (setenv \"DRGNX_NO_HUB_START\") (setenv \"DRGNX_RATATOSKR_BIN\" %S)
                                                     (setenv \"DRGNX_HUB_PARENT_PID\" (number-to-string (emacs-pid)))
                                                     (not (drgnx-hub-running-p)))"
                                            bin)))))

(defun drgnx-live-mod--search (sess secs)
  "In SESS, C-S-f (View: Search, VS Code's Ctrl+Shift+F: the Search view, the cursor in its Find field), \"list\" and
RET, after a git init makes the file's folder a project.  Waits up to SECS for f.el's results."
  ;; Emacs 31 caches "no project here" (the chrome asked when the file opened): forget it after git init.
  (drgnx-live-mod--q sess "(progn (call-process \"git\" nil nil nil \"-C\" (file-name-directory (buffer-file-name (window-buffer (drgnx-wb-editor-window)))) \"init\" \"-q\") (when (fboundp 'project--clear-cache) (project--clear-cache)) (select-window (drgnx-wb-editor-window)) t)")
  ;; the view's module sets up at startup, so the view exists when keys are sent back to back
  (drgnx-ui-measure sess (list (list :keys "C-S-f") (list :type "list") (list :keys "RET")))
  (should (eq (drgnx-live-mod--q sess "(drgnx-wb-sidebar-view)") 'search))
  ;; the search runs on the session's hub: its results are asked for until f.el's are in.  The hub-fed view keeps no
  ;; match list (its rows are the hub's), so f.el's file row is looked for in the drawn rows.
  (drgnx-test-wait (lambda () (drgnx-live-mod--q sess (drgnx-live-mod--found "(not (drgnx-replace--busy-p))")))
                   :secs secs :what "the search's results")
  (should (drgnx-live-mod--q sess (drgnx-live-mod--found "(equal (drgnx-replace--text 'find) \"list\")"))))

(ert-deftest drgnx-live/new-terminal-and-project-search-by-keys ()
  ;; No hub runs: New Terminal starts it (a command the user invoked), and its terminal opens on it.
  (drgnx-live-mod--with sess
    (drgnx-live-mod--may-start-hub sess)
    (drgnx-ui-measure sess (list (list :keys "C-S-`")))
    (should (equal (drgnx-live-mod--q sess "(list (eq (selected-window) (drgnx-wb-area-window 'panel)) (drgnx-wb-area-tab 'panel) (with-current-buffer (window-buffer (selected-window)) major-mode))")
                   '(t terminal drgnx-term-mode)))   ; drgnx's own terminal
    (drgnx-test-wait (lambda () (eq (drgnx-live-mod--q sess "(with-current-buffer (window-buffer (drgnx-wb-area-window 'panel)) drgnx-term--state)") 'open))
                     :secs 30 :what "the terminal opened on the hub New Terminal started")
    (drgnx-live-mod--search sess 10)
    (should (equal (drgnx-live-mod--q sess "drgnx-wb-unrouted") nil))))

(ert-deftest drgnx-live/project-search-starts-the-hub ()
  ;; No hub runs: the Search view's search (a command) starts it, and the results arrive.
  (drgnx-live-mod--with sess
    (drgnx-live-mod--may-start-hub sess)
    (drgnx-live-mod--search sess 30)
    (should (drgnx-live-mod--q sess "(drgnx-hub-running-p)"))))

(ert-deftest drgnx-live/the-explorer-starts-the-hub ()
  ;; No hub runs: View: Explorer (C-S-e, a command) starts it, and the hub lists the folder (on Nidhogg the Explorer is
  ;; the hub's view: without a hub it would only say it waits).
  (drgnx-live-mod--with sess
    (unless (drgnx-live-mod--q sess "(fboundp 'nidhogg-view--call)") (ert-skip "the Explorer lists in Lisp here (no Sjá)"))
    (drgnx-live-mod--may-start-hub sess)
    (drgnx-live-mod--q sess (format "(progn (drgnx-explorer-set-roots (list %S)) t)" root))
    (drgnx-ui-measure sess (list (list :keys "C-S-e")))
    (drgnx-test-wait (lambda () (drgnx-live-mod--q sess "(with-current-buffer drgnx-explorer-buffer-name
                                                           (and (drgnx-explorer--rows-p) (not drgnx-explorer--waiting)
                                                                (save-excursion (goto-char (point-min)) (search-forward \"f.el\" nil t))
                                                                t))"))
                     :secs 30 :what "the Explorer listed the folder on the hub its command started")
    (should (drgnx-live-mod--q sess "(drgnx-hub-running-p)"))))

(ert-deftest drgnx-live/project-search-without-a-hub-says-why ()
  ;; Starting off (DRGNX_NO_HUB_START): the status line says why there is no search, never "Waiting".
  (drgnx-live-mod--with sess
    (drgnx-live-mod--q sess "(progn (setenv \"DRGNX_NO_HUB_START\" \"1\") t)")
    (drgnx-ui-measure sess (list (list :keys "C-S-f") (list :type "list") (list :keys "RET")))
    (drgnx-test-wait (lambda () (drgnx-live-mod--q sess "(with-current-buffer (get-buffer drgnx-replace-buffer-name)
                                                           (and (string-search \"DRGNX_NO_HUB_START\" drgnx-replace--status) t))"))
                     :secs 10 :what "the status line says why")
    (should-not (drgnx-live-mod--q sess "(with-current-buffer (get-buffer drgnx-replace-buffer-name) drgnx-replace--waiting)"))))

(defun drgnx-live-mod--elpa ()
  "The user's ELPA (read-only): DRGNX_USER_ELPA, which the runner names before it swaps HOME, else ~/.config/emacs/elpa."
  (or (getenv "DRGNX_USER_ELPA") (expand-file-name "~/.config/emacs/elpa")))

(ert-deftest drgnx-live/package-modules-with-the-users-elpa ()
  ;; The user's ELPA, read-only, on the load path: the waiting modules run, their keys are bound, and
  ;; vertico's growing minibuffer gives the layout back.
  ;; the packages it checks in the user's ELPA, not merely the directory (CI's DRGNX_USER_ELPA holds only the pinned
  ;; evil and kkp): extra/jump's avy, extra/completion's vertico, orderless, marginalia and corfu
  (skip-unless (and (file-directory-p (drgnx-live-mod--elpa))
                    (seq-every-p (lambda (pkg) (directory-files (drgnx-live-mod--elpa) nil (format "\\`%s-[0-9]" pkg)))
                                 '("avy" "vertico" "orderless" "marginalia" "corfu"))))
  (drgnx-live-mod--with sess
    (drgnx-ui-call sess (format "(progn (dolist (d (directory-files %S t \"\\\\`[^.]\"))
                                   (when (file-directory-p d) (add-to-list 'load-path d t)))
                                 (drgnx-modules-run 'idle) (drgnx-uitest--json (list :ok t)))" (drgnx-live-mod--elpa)))
    (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "M-j")))
    (should (equal (drgnx-live-mod--q sess "(list (plist-get (alist-get 'extra/jump (drgnx-modules-report)) :status) (key-binding (kbd \"C-;\")) (and (boundp 'vertico-mode) vertico-mode))")
                   '(ok avy-goto-char-timer t)))
    (let ((before (drgnx-live-mod--q sess "(sort (mapcar #'window-pixel-edges (window-list nil 'nomini)) (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b))))))")))
      (drgnx-ui-measure sess (list (list :keys "M-x") (list :type "describe")))
      (drgnx-ui-measure sess (list (list :keys "C-g")))
      (should (equal before (drgnx-live-mod--q sess "(sort (mapcar #'window-pixel-edges (window-list nil 'nomini)) (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b))))))"))))))

(ert-deftest drgnx-live/gryphn-as-an-external-module ()
  ;; A gryphn checkout ($DRGNX_GRYPHN_DIR, read-only) as an external module: its board, runs, agents,
  ;; search and LLM commands in the registry, gryphn's keys in the VS Code profile; nothing installed.
  (skip-unless (and (getenv "DRGNX_GRYPHN_DIR") (file-directory-p (getenv "DRGNX_GRYPHN_DIR"))))
  (drgnx-live-mod--with sess
    (drgnx-ui-call sess (format "(progn (when (file-directory-p (expand-file-name \"~/.config/emacs/elpa\"))
                                   (dolist (d (directory-files (expand-file-name \"~/.config/emacs/elpa\") t \"\\\\`[^.]\"))
                                     (when (file-directory-p d) (add-to-list 'load-path d t))))
                                 (drgnx-modules-update-state (lambda (_) (list :external (list (list :name 'gryphn :path %S
                                                                     :features '(gryphn-org gryphn-run gryphn-board gryphn-board-ui gryphn-agents gryphn-search gryphn-llm))))))
                                 (drgnx-modules-load-external) (drgnx-modules-run 'idle)
                                 (drgnx-uitest--json (list :ok t)))" (getenv "DRGNX_GRYPHN_DIR")))
    (should (drgnx-live-mod--q sess "(assq 'external/gryphn/gryphn-board (drgnx-modules-report))"))
    (should (equal (drgnx-live-mod--q sess "(seq-filter (lambda (m) (and (string-prefix-p \"external/\" (symbol-name (car m))) (not (memq (plist-get (cdr m) :status) '(ok missing-packages))))) (drgnx-modules-report))") nil))
    (should (equal (drgnx-live-mod--q sess "(list (key-binding (kbd \"<f5>\")) (and (drgnx-commands-get 'agents-map) t))") '(gryphn-org-board-view t)))))
