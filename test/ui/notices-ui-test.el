;;; notices-ui-test.el --- GUI tests: the status bar reads the two notice counts (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; A module that fails shows in the bar and the echo area at once; a click on the needs-you count runs the command
;; of the newest item.  The notice model is a fresh one for each test and the session's comes back after.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-notice-ui-test--repo                    ; the session runs the repository's test/ui
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb"))
  (add-to-list 'load-path (expand-file-name d drgnx-notice-ui-test--repo)))
(require 'drgnx)
(require 'drgnx-notices)
(require 'drgnx-notice-echo)
(load (expand-file-name "modules/ui/drgnx-statusbar" drgnx-notice-ui-test--repo) nil t)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-notice-ui-test--repo) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-notice-ui-test--repo) nil t)

(defvar drgnx-notice-ui-test--ran nil "What the clicked item's command was called with.")

(defun drgnx-notice-ui-test--run (what)
  "The command of a needs-you item: record WHAT."
  (setq drgnx-notice-ui-test--ran what))

(defun drgnx-notice-ui-test--bar ()
  "The bar of the root frame's selected window with only the two notice segments, as redisplay would build it."
  (let ((drgnx-statusbar--segments (make-hash-table :test #'eq)) (drgnx-statusbar--errors nil))
    (drgnx-statusbar--define-defaults)
    (let ((drgnx-statusbar-left '(needs-you drgnx)) (drgnx-statusbar-right nil)
          (drgnx-statusbar--window (selected-window)))
      (drgnx-statusbar-render 120))))

(defun drgnx-notice-ui-test--click (bar text)
  "Click the segment of BAR that shows TEXT, as the mouse would."
  (let ((pos (string-search text bar)))
    (should pos)
    (let ((drgnx-statusbar--segments (make-hash-table :test #'eq)))
      (drgnx-statusbar--define-defaults)
      (drgnx-statusbar-click (list 'mouse-1 (list (selected-window) 'mode-line '(0 . 0) 0 (cons bar pos)))))))

(ert-deftest drgnx-notice-ui/a-failed-module-shows-at-startup ()
  ;; modules.eld lists the fixture as :external; its module's setup signals.  Startup ends: the bar has the failure,
  ;; the echo area one line naming the module, and a click opens the Notices list with the module's row.
  (let ((dir (expand-file-name "test/fixtures/notice-module" drgnx-notice-ui-test--repo))
        (echo-was drgnx-notice-echo-mode))
    (with-selected-frame (drgnx-uitest-root-frame)
      (drgnx-notice-test-with-model
        (drgnx-test-with-modules nil
          (let ((drgnx-notice--echo-pending nil) (drgnx-notice--echo-last nil) (drgnx-notice--echo-waiting nil)
                (drgnx-notice--started nil) (this-command nil))
            (unwind-protect
                (cl-letf (((symbol-function 'drgnx-notice--can-echo-p) (lambda () t))
                          ((symbol-function 'drgnx-modules-read-state)
                           (lambda () (list :external (list (list :name 'notice-fixture :path dir
                                                                  :features '(drgnx-notice-fixture)))))))
                  (drgnx-notice-echo-mode -1)
                  (let ((after-init-time nil)) (drgnx-notice-echo-mode 1))   ; startup is not over: lines wait for it
                  (drgnx-modules-load-external)
                  (should (assq 'test/fails drgnx-modules--table))
                  (drgnx-modules--run-one 'test/fails (alist-get 'test/fails drgnx-modules--table) 'startup)
                  (with-current-buffer (get-buffer-create "*Messages*") (let ((inhibit-read-only t)) (erase-buffer)))
                  (message nil)
                  (drgnx-notice--startup-done)
                  (let* ((bar (drgnx-notice-ui-test--bar))
                         (fail (format "%s 1" (drgnx-face-glyph 'fail))))
                    (should (string-search fail (substring-no-properties bar)))
                    (should (= 1 (with-current-buffer "*Messages*"
                                   (cl-count-if (lambda (l) (string-prefix-p "drgnx: 1 module did not start (test/fails)" l))
                                                (split-string (buffer-string) "\n")))))
                    (drgnx-notice-ui-test--click bar fail)
                    (let ((list (get-buffer drgnx-notices-buffer-name)))
                      (should list)
                      (with-current-buffer list
                        (should (string-search "test/fails" (buffer-string)))
                        (should (string-search (drgnx-notices--command-title 'preferences-modules) (buffer-string)))))))
              (drgnx-notice-echo-mode (if echo-was 1 -1))
              (when (get-buffer drgnx-notices-buffer-name) (kill-buffer drgnx-notices-buffer-name)))))))))

(ert-deftest drgnx-notice-ui/a-needs-you-click-opens-the-newest ()
  ;; one source holds the item: the click does what its command says
  (setq drgnx-notice-ui-test--ran nil)
  (with-selected-frame (drgnx-uitest-root-frame)
    (drgnx-notice-test-with-model
      (drgnx-notice-define-source 'jobs :title "Jobs")
      (drgnx-notice-set 'jobs (list (list :id 'card-1 :text "Card 1?"
                                          :command '(drgnx-notice-ui-test--run "card-1"))))
      (let* ((bar (drgnx-notice-ui-test--bar))
             (text (format "%s 1 waiting on you" (drgnx-face-glyph 'waiting))))
        (should (string-search text (substring-no-properties bar)))
        (drgnx-notice-ui-test--click bar text)
        (should (equal drgnx-notice-ui-test--ran "card-1"))))))

(provide 'notices-ui-test)
;;; notices-ui-test.el ends here
