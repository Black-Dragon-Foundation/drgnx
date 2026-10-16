;;; drgnx-modules-test.el --- live: modules driven by real keys in a GUI session (config=drgnx) -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)

(defmacro drgnx-live-mod--with (sess &rest body)
  "BODY with SESS a session editing an elisp file (VS Code key profile)."
  (declare (indent 1))
  `(let* ((root (make-temp-file "drgnx-mod" t))
          (file (expand-file-name "f.el" root))
          (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
          (s (progn (write-region "(defun f ()\n  (list 1\n        2))\n" nil file nil 'silent)
                    (drgnx-ui-start "drgnx" "1400x800" 30)))
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
    (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-`")))
    (let ((before (drgnx-live-mod--q sess "(sort (mapcar #'window-pixel-edges (window-list nil 'nomini)) (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b))))))")))
      (drgnx-ui-measure sess (list (list :keys "C-k z")))
      (should (= 1 (drgnx-live-mod--q sess "(length (window-list nil 'nomini))")))
      (drgnx-ui-measure sess (list (list :keys "C-k z")))
      (should (equal before (drgnx-live-mod--q sess "(sort (mapcar #'window-pixel-edges (window-list nil 'nomini)) (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cadr a) (cadr b))))))"))))))

(ert-deftest drgnx-live/new-terminal-and-project-search-by-keys ()
  (drgnx-live-mod--with sess
    (drgnx-ui-measure sess (list (list :keys "C-S-`")))
    (should (equal (drgnx-live-mod--q sess "(list (eq (selected-window) (drgnx-wb-area-window 'panel)) (drgnx-wb-area-tab 'panel) (with-current-buffer (window-buffer (selected-window)) major-mode))")
                   '(t terminal eshell-mode)))
    (drgnx-live-mod--q sess "(progn (call-process \"git\" nil nil nil \"-C\" (file-name-directory (buffer-file-name (window-buffer (drgnx-wb-editor-window)))) \"init\" \"-q\") (select-window (drgnx-wb-editor-window)) t)")
    (drgnx-ui-measure sess (list (list :keys "C-S-f") (list :type "list") (list :keys "RET")))
    (should (eq (drgnx-live-mod--q sess "(drgnx-wb-area-tab 'panel)") 'results))
    (should (equal (drgnx-live-mod--q sess "drgnx-wb-unrouted") nil))))

(ert-deftest drgnx-live/package-modules-with-the-users-elpa ()
  ;; The user's ELPA, read-only, on the load path: the waiting modules run, their keys are bound, and
  ;; vertico's growing minibuffer gives the layout back.
  (skip-unless (file-directory-p (expand-file-name "~/.config/emacs/elpa")))
  (drgnx-live-mod--with sess
    (drgnx-ui-call sess "(progn (dolist (d (directory-files (expand-file-name \"~/.config/emacs/elpa\") t \"\\\\`[^.]\"))
                                   (when (file-directory-p d) (add-to-list 'load-path d t)))
                                 (drgnx-modules-run 'idle) (drgnx-uitest--json (list :ok t)))")
    (drgnx-ui-measure sess (list (list :keys "C-b") (list :keys "C-`")))
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
                                 (drgnx-modules-write-state (list :version 1 :external (list (list :name 'gryphn :path %S
                                                                     :features '(gryphn-org gryphn-run gryphn-board gryphn-board-ui gryphn-agents gryphn-search gryphn-llm)))))
                                 (drgnx-modules-load-external) (drgnx-modules-run 'idle)
                                 (drgnx-uitest--json (list :ok t)))" (getenv "DRGNX_GRYPHN_DIR")))
    (should (drgnx-live-mod--q sess "(assq 'external/gryphn/gryphn-board (drgnx-modules-report))"))
    (should (equal (drgnx-live-mod--q sess "(seq-filter (lambda (m) (and (string-prefix-p \"external/\" (symbol-name (car m))) (not (memq (plist-get (cdr m) :status) '(ok missing-packages))))) (drgnx-modules-report))") nil))
    (should (equal (drgnx-live-mod--q sess "(list (key-binding (kbd \"<f5>\")) (and (drgnx-commands-get 'agents-map) t))") '(gryphn-org-board-view t)))))
