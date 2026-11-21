;;; search-form-gui-test.el --- GUI test: the Search view's form is flat chips that fit the side bar (audit S1) -*- lexical-binding: t -*-
;; test-class: det
;; The Search view's form (mode chip, fields, toggles, scope chips) has no ASCII-bracket buttons, and no line of it is
;; wider than the side bar, at the run's scale (the harness runs it at 1 and 1.25 / 2).  Needs a Nidhogg with Sjá.
(require 'ert)
(load (expand-file-name "../fixtures/grid-on-fixture" (file-name-directory (macroexp-file-name))) nil t)
(drgnx-test-grid-on-for-file)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-search-form-test--repo                        ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-search-form-test--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-search-form-test--repo))
(require 'drgnx)
(require 'drgnx-wb)
(require 'drgnx-area)
(require 'drgnx-view)
(require 'drgnx-view-env)   ; the test binds its send function: a session of this file alone has not loaded it
(require 'drgnx-popup)
;; loaded before the rows stub `drgnx-hub--call-on': a library loaded mid-row that requires the client defined the real
;; function over the stub, so later calls went to the hub client (search/group was never seen; its expiry timer leaked)
(require 'drgnx-hub-client)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-search-form-test--repo) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-search-form-test--repo) nil t)

(defvar drgnx-hub--events)
(defvar drgnx-search-form-test--calls nil "The hub calls the view made, newest first: (METHOD . PARAMS).")
(defvar drgnx-search-form-test--version 0 "The last version handed to the view.")

(defun drgnx-search-form-test--shot (dir name)
  "Capture the root frame into DIR and keep it as NAME in the evidence folder (DRGNX_UI_EVIDENCE), else the session's
temp dir; print where."
  (redisplay t)
  (let ((shot (plist-get (drgnx-uitest-capture dir) :root))
        (out (expand-file-name name (or (getenv "DRGNX_UI_EVIDENCE") temporary-file-directory))))
    (should (file-exists-p shot))
    (copy-file shot out t)
    (message "search-view screenshot: %s" out)
    out))

(ert-deftest drgnx-ui-search-form/flat-chips-that-fit-the-side-bar ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (drgnx-test-with-state
    (let* ((root (drgnx-uitest-root-frame)) (shots (make-temp-file "drgnx-search-shot" t))
           (dir (make-temp-file "drgnx-search-repo" t)) (file (expand-file-name "src/parse.rs" dir))
           (drgnx-wb--sections nil) (drgnx-wb--areas (copy-tree drgnx-wb--areas))
           (drgnx-view-patch--buffers (make-hash-table :test #'equal))
           (drgnx-view-model--views (make-hash-table :test #'equal))
           (drgnx-view-patch--hooked nil)
           (drgnx-view-patch-send-function #'ignore) (drgnx-view-env-send-function #'ignore)
           (drgnx-hub--events nil) (drgnx-search-form-test--calls nil) (drgnx-search-form-test--version 0)
           (drgnx-replace-view "search-form-test")
           (display-buffer-alist nil) (display-buffer-overriding-action '(nil)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "fn parse(s: &str) -> Tree {\n    parse_all(s)\n}\n"))
      (cl-letf (((symbol-function 'drgnx-replace--hub-ready-p) (lambda () t))
                ((symbol-function 'drgnx-hub--call-on)
                 (lambda (_conn method params &optional _cb &rest _) (push (cons method params) drgnx-search-form-test--calls) nil)))
        (unwind-protect
            (with-selected-frame root
              (delete-other-windows)
              (dolist (p '(drgnx-wb-view drgnx-wb-areas drgnx-wb-panel-px drgnx-wb-right-px drgnx-wb-dock-px))
                (set-frame-parameter nil p nil))
              (drgnx-replace--define-section)
              (drgnx-replace--define-commands)
              (find-file file)
              (drgnx-test-use-editor (selected-window))
              (goto-char (point-min)) (search-forward "parse")
              (drgnx-wb-show-sidebar)
              (drgnx-replace-in-files)
              (should (eq (drgnx-wb-sidebar-view) 'search))
              (with-current-buffer (get-buffer drgnx-replace-buffer-name)
                (setq drgnx-replace--root (file-name-as-directory dir))
                (drgnx-replace--hub-attach)
                (let* ((win (get-buffer-window (current-buffer) t))
                       (form (buffer-substring-no-properties (point-min) drgnx-replace--lists-beg)))
                  (should win)
                  (redisplay t)
                  (drgnx-search-form-test--shot shots "search-form.png")
                  ;; no ASCII-bracket buttons: the only "[" the form may hold is none
                  (should-not (string-match-p "\\[" form))
                  ;; every line of the form fits the window
                  (save-excursion
                    (goto-char (point-min))
                    (while (< (point) drgnx-replace--lists-beg)
                      (let ((w (car (window-text-pixel-size win (line-beginning-position) (line-end-position)))))
                        (should (<= w (window-body-width win t))))
                      (forward-line 1)))
                  ;; the toggles are drawn with the chip faces, not the widget's own
                  (goto-char (point-min))
                  (should (search-forward "Aa" nil t))
                  (should (memq (get-char-property (match-beginning 0) 'face) '(drgnx-replace-chip drgnx-replace-chip-on))))))
          (ignore-errors (kill-buffer drgnx-replace-buffer-name))
          (delete-directory shots t) (delete-directory dir t))))))
