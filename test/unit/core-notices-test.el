;;; core-notices-test.el --- batch tests: the Notices list and the mode-line pair -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx)
(require 'drgnx-notices)
(require 'drgnx-signal)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(dolist (f '("core/drgnx-workbench"))
  (mapc #'require (drgnx-test-modules--requires (expand-file-name (concat "modules/" f ".el") drgnx-dir))))

(defvar drgnx-notices-test--ran nil "What the test command buttons ran, newest first.")

(defun drgnx-notices-test--open (&rest args)
  "A command a notice can name."
  (interactive)
  (push (cons 'open args) drgnx-notices-test--ran))

(defmacro drgnx-notices-test--with (&rest body)
  "BODY on a fresh notice model and virtual time, a registry holding one command (`thing', titled \"Open Thing\"),
and no list buffer; the list's buffer, view type and hook are gone after."
  (declare (indent 0) (debug t))
  `(drgnx-notice-test-with-model
     (drgnx-test-with-clock ()
       (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
             (drgnx-commands-problems nil) (drgnx-notices-test--ran nil))
         (drgnx-command-define 'thing :category "Test" :title "Open Thing" :command #'drgnx-notices-test--open
                               :doc "test")
         (unwind-protect (progn ,@body)
           (when-let* ((b (get-buffer drgnx-notices-buffer-name))) (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
           (remove-hook 'drgnx-notice-functions #'drgnx-notices--changed)
           (drgnx-timer-cancel 'notices-list)
           (drgnx-view--undefine 'notices-list))))))

(defun drgnx-notices-test--text ()
  "The list buffer's text, without properties."
  (with-current-buffer drgnx-notices-buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

(defun drgnx-notices-test--button (label)
  "The keymap of the button labelled LABEL in the list buffer."
  (with-current-buffer drgnx-notices-buffer-name
    (save-excursion
      (goto-char (point-min))
      (search-forward label)
      (get-text-property (match-beginning 0) 'keymap))))

(defun drgnx-notices-test--press (label)
  "Press the button LABEL in the list as RET would."
  (funcall (lookup-key (drgnx-notices-test--button label) (kbd "RET"))))

(defun drgnx-notices-test--show ()
  (save-window-excursion (drgnx-notices-show)))

;;;; The list

(ert-deftest drgnx-notices/three-sections ()
  (drgnx-notices-test--with
    (drgnx-notify 'config 'fail "bad value" :id 'a :life 'condition)
    (drgnx-notify 'config 'warn "odd value" :id 'b :life 'condition)
    (drgnx-notify 'hooks 'info "did a thing")
    (drgnx-notice-set 'agents (list (list :id 'q :text "s1 asks: run make?")))
    (drgnx-notices-test--show)
    (let ((text (drgnx-notices-test--text)))
      (should (eq (buffer-local-value 'major-mode (get-buffer drgnx-notices-buffer-name)) 'drgnx-notices-mode))
      (should (string-match "Needs you (1)\n.* agents  s1 asks: run make\\?\n" text))
      (should (string-match (format "Problems (%s 1 %s 1)" (drgnx-face-glyph 'fail) (drgnx-face-glyph 'warn)) text))
      (should (< (string-search "Needs you" text) (string-search "Problems" text) (string-search "Recent" text)))
      (should (< (string-search "Recent" text) (string-search "did a thing" text)))
      (should-not (string-search "Nothing here." text)))))

(ert-deftest drgnx-notices/an-empty-section-says-so ()
  (drgnx-notices-test--with
    (drgnx-notify 'hooks 'info "did a thing")
    (drgnx-notices-test--show)
    (let ((text (drgnx-notices-test--text)))
      (should (string-match "Needs you (0)\n+[ ]*Nothing here\\." text))
      (should (string-match "Problems (.*)\n+[ ]*Nothing here\\." text))
      (should (= 3 (length (split-string text "Nothing here\\.")))))))

(ert-deftest drgnx-notices/rows-have-status-source-text-fix-command-dismiss ()
  (drgnx-notices-test--with
    (drgnx-notify 'config 'fail "bad value" :id 'a :life 'condition :fix "Run drgnx doctor" :command 'thing)
    (drgnx-notify 'config 'fail "bad value" :id 'a :life 'condition)       ; a repeat: x2
    (drgnx-notices-test--show)
    (with-current-buffer drgnx-notices-buffer-name
      (goto-char (point-min))
      (search-forward "Problems")
      (search-forward (drgnx-face-glyph 'fail) nil nil 2)          ; the heading's, then the row's
      (should (eq (get-text-property (match-beginning 0) 'face) 'drgnx-status-fail))
      (search-forward "config")
      (should (eq (get-text-property (match-beginning 0) 'face) 'shadow))
      (search-forward "bad value")
      (should (looking-at " *×2"))
      (search-forward "\n")
      (should (looking-at " *Run drgnx doctor"))
      (search-forward "Run drgnx doctor")
      (should (eq (get-text-property (match-beginning 0) 'face) 'drgnx-status-info))
      (let ((open (progn (search-forward "Open Thing") (match-beginning 0))))
        (should (eq (get-text-property open 'face) 'drgnx-ui-button))
        (should (get-text-property open 'keymap)))
      (let ((dismiss (progn (search-forward "Dismiss") (match-beginning 0))))
        (should (get-text-property dismiss 'keymap))))))

(ert-deftest drgnx-notices/attention-rows-have-no-dismiss ()
  (drgnx-notices-test--with
    (drgnx-notice-set 'agents (list (list :id 'q :text "s1 asks: run make?" :command 'thing)))
    (drgnx-notices-test--show)
    (let ((text (drgnx-notices-test--text)))
      (should (string-search "Open Thing" text))
      (should-not (string-search "Dismiss" text)))
    (with-current-buffer drgnx-notices-buffer-name
      (goto-char (point-min))
      (search-forward "s1 asks")
      (should-error (drgnx-notices-dismiss-at-point) :type 'user-error))))

(ert-deftest drgnx-notices/dismiss-hides-the-row ()
  (drgnx-notices-test--with
    (drgnx-notify 'config 'fail "bad value" :id 'a :life 'condition)
    (drgnx-notify 'hooks 'info "did a thing")
    (drgnx-notices-test--show)
    (should (string-search "bad value" (drgnx-notices-test--text)))
    (drgnx-notices-test--press "Dismiss")               ; the condition's (the first Dismiss)
    (drgnx-test-idle 0.2)
    (drgnx-view-draw-now (buffer-local-value 'drgnx-view (get-buffer drgnx-notices-buffer-name)))
    (should-not (string-search "bad value" (drgnx-notices-test--text)))
    (should (string-search "did a thing" (drgnx-notices-test--text)))
    ;; the command does the same at point
    (with-current-buffer drgnx-notices-buffer-name
      (goto-char (point-min))
      (search-forward "did a thing")
      (drgnx-notices-dismiss-at-point))
    (drgnx-test-idle 0.2)
    (drgnx-view-draw-now (buffer-local-value 'drgnx-view (get-buffer drgnx-notices-buffer-name)))
    (should-not (string-search "did a thing" (drgnx-notices-test--text)))))

(ert-deftest drgnx-notices/the-command-button-runs-its-action ()
  (drgnx-notices-test--with
    (drgnx-notify 'config 'warn "odd" :id 'a :life 'condition :command '(drgnx-notices-test--open "arg" 2))
    (drgnx-notify 'config 'fail "bad" :id 'b :life 'condition :command 'thing)
    (drgnx-notices-test--show)
    (let ((text (drgnx-notices-test--text)))
      (should (string-search "drgnx-notices-test--open" text))           ; no registry title: the command's name
      (should (string-search "Open Thing" text)))
    (drgnx-notices-test--press "drgnx-notices-test--open")
    (should (equal drgnx-notices-test--ran '((open "arg" 2))))
    (drgnx-notices-test--press "Open Thing")
    (should (equal drgnx-notices-test--ran '((open) (open "arg" 2))))
    (drgnx-timer-cancel 'surfaces-usage)))              ; the registry button's use count is saved by a timer

(ert-deftest drgnx-notices/redraws-after-a-change-while-live ()
  (drgnx-notices-test--with
    (drgnx-notices-test--show)
    (should (string-search "Nothing here." (drgnx-notices-test--text)))
    (drgnx-notify 'config 'fail "arrived later" :id 'a :life 'condition)
    (drgnx-view-draw-now (buffer-local-value 'drgnx-view (get-buffer drgnx-notices-buffer-name)))
    (should-not (string-search "arrived later" (drgnx-notices-test--text)))   ; the change only starts a timer
    (drgnx-test-idle 0.2)
    (drgnx-view-draw-now (buffer-local-value 'drgnx-view (get-buffer drgnx-notices-buffer-name)))
    (should (string-search "arrived later" (drgnx-notices-test--text)))
    ;; the buffer killed: the list stops following the model
    (kill-buffer drgnx-notices-buffer-name)
    (should-not (memq #'drgnx-notices--changed drgnx-notice-functions))
    (drgnx-notify 'config 'fail "nobody listens" :id 'b :life 'condition)
    (should-not (drgnx-timer-active-p 'notices-list))))

(ert-deftest drgnx-notices/g-redraws ()
  (drgnx-notices-test--with
    (drgnx-notices-test--show)
    (drgnx-notify 'config 'fail "arrived later" :id 'a :life 'condition)
    (with-current-buffer drgnx-notices-buffer-name (revert-buffer))
    (should (string-search "arrived later" (drgnx-notices-test--text)))))

(ert-deftest drgnx-notices/the-command-and-its-keys-rows ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-commands-problems nil))
    (drgnx--core-commands)
    (let ((show (drgnx-commands-get 'notices)) (dismiss (drgnx-commands-get 'notices-dismiss)))
      (should (equal (drgnx-cmd-title show) "Show Notices"))
      (should (eq (drgnx-cmd-command show) #'drgnx-notices-show))
      (should (equal (drgnx-cmd-category show) "View"))
      (should (equal (drgnx-cmd-title dismiss) "Dismiss Notice"))
      (should (eq (drgnx-cmd-command dismiss) #'drgnx-notices-dismiss-at-point))
      (should (eq (drgnx-cmd-map dismiss) 'drgnx-notices-mode-map))))
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((text (with-temp-buffer
                  (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir)) (buffer-string))))
      (dolist (row '("(notices :none \"the status bar's counts and the echo line; the palette\")"
                     "(notices-dismiss :none \"the Dismiss button on each row; the palette\")"))
        (should (string-search row text))))))

(ert-deftest drgnx-notices/opens-in-the-panel ()
  (drgnx-test-with-modules '(core/workbench)
    (should (eq (car (drgnx-wb-rule-for drgnx-notices-buffer-name)) 'panel))))

;;;; The mode-line pair

(ert-deftest drgnx-notice-mode-line/two-texts-in-global-mode-string ()
  (let ((global-mode-string (copy-sequence global-mode-string)) (drgnx-notice-functions nil))
    (unwind-protect
        (progn
          (drgnx-notice-mode-line-mode 1)
          (should (member '(:eval (drgnx-notice-mode-line)) global-mode-string))
          (should (memq #'drgnx-notice--mode-line-changed drgnx-notice-functions))
          (drgnx-notice-mode-line-mode 1)                     ; idempotent
          (should (= 1 (cl-count '(:eval (drgnx-notice-mode-line)) global-mode-string :test #'equal))))
      (drgnx-notice-mode-line-mode -1))
    (should-not (member '(:eval (drgnx-notice-mode-line)) global-mode-string))
    (should-not (memq #'drgnx-notice--mode-line-changed drgnx-notice-functions))))

(ert-deftest drgnx-notice-mode-line/texts ()
  (drgnx-notice-test-with-model
    (should-not (drgnx-notice-needs-you-text))
    (should-not (drgnx-notice-problems-text))
    (should-not (drgnx-notice-mode-line))
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?") (list :id 'b :text "b?")))
    (should (equal (drgnx-notice-needs-you-text) (format "%s 2 waiting on you" (drgnx-face-glyph 'waiting))))
    (should (eq (get-text-property 0 'face (drgnx-notice-needs-you-text)) 'drgnx-status-needs-you))
    (drgnx-notify 'config 'info "fyi" :id 'i :life 'condition)
    (should-not (drgnx-notice-problems-text))             ; info conditions are not shown
    (drgnx-notify 'config 'fail "bad" :id 'f :life 'condition)
    (should (equal (drgnx-notice-problems-text) (format "%s 1" (drgnx-face-glyph 'fail))))
    (should (eq (get-text-property 0 'face (drgnx-notice-problems-text)) 'drgnx-status-fail))
    (drgnx-notify 'config 'warn "odd" :id 'w :life 'condition)
    (drgnx-notify 'config 'warn "odder" :id 'w2 :life 'condition)
    (should (equal (drgnx-notice-problems-text)
                   (format "%s 1 %s 2" (drgnx-face-glyph 'fail) (drgnx-face-glyph 'warn))))
    (drgnx-notice-clear 'config 'f)
    (should (equal (drgnx-notice-problems-text) (format "%s 2" (drgnx-face-glyph 'warn))))
    (should (eq (get-text-property 0 'face (drgnx-notice-problems-text)) 'drgnx-status-warn))
    (let ((line (drgnx-notice-mode-line)))
      (should (equal (substring-no-properties line)
                     (format "%s 2 waiting on you %s 2" (drgnx-face-glyph 'waiting) (drgnx-face-glyph 'warn))))
      (should (get-text-property 0 'mouse-face line))
      (should (get-text-property 0 'local-map line))
      (should (get-text-property (1- (length line)) 'local-map line)))))

(ert-deftest drgnx-notice-mode-line/memoised-on-the-tick ()
  (drgnx-notice-test-with-model
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?")))
    (drgnx-notify 'config 'fail "bad" :id 'f :life 'condition)
    (let ((line (drgnx-notice-mode-line)) (needs (drgnx-notice-needs-you-text)) (problems (drgnx-notice-problems-text)))
      (should (eq line (drgnx-notice-mode-line)))
      (should (eq needs (drgnx-notice-needs-you-text)))
      (should (eq problems (drgnx-notice-problems-text)))
      (should (= 0 (drgnx-notice-test--alloc (drgnx-notice-mode-line) (drgnx-notice-needs-you-text)
                                             (drgnx-notice-problems-text))))
      (drgnx-notice-set 'agents (list (list :id 'a :text "a?") (list :id 'b :text "b?")))
      (should-not (eq line (drgnx-notice-mode-line)))
      (should-not (eq needs (drgnx-notice-needs-you-text)))
      (should (equal problems (drgnx-notice-problems-text))))))

(ert-deftest drgnx-notice-mode-line/needs-you-click-runs-the-newest-when-one-source-holds-all ()
  (drgnx-notices-test--with
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?" :command '(drgnx-notices-test--open "old"))))
    (drgnx-test-advance 1)
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?" :command '(drgnx-notices-test--open "old"))
                                    (list :id 'b :text "b?" :command '(drgnx-notices-test--open "new"))))
    (drgnx-notice-needs-you-click)
    (should (equal drgnx-notices-test--ran '((open "new"))))))

(ert-deftest drgnx-notice-mode-line/else-it-opens-the-list ()
  (drgnx-notices-test--with
    (drgnx-notice-set 'agents (list (list :id 'a :text "a?" :command '(drgnx-notices-test--open "agents"))))
    (drgnx-notice-set 'hub (list (list :id 'b :text "b?" :command '(drgnx-notices-test--open "hub"))))
    (save-window-excursion
      (drgnx-notice-needs-you-click)
      (should (get-buffer drgnx-notices-buffer-name))
      (should-not drgnx-notices-test--ran))))

;;;; The bus

(ert-deftest drgnx-signal/notices-changed-is-posted ()
  (drgnx-notice-test-with-model
    (drgnx-test-with-clock ()
      (drgnx-test-with-state
        (let ((got nil))
          (unwind-protect
              (progn
                (drgnx-signal-mode 1)
                (should (memq #'drgnx-signal--notices-changed drgnx-notice-functions))
                (drgnx-signal-subscribe 'notices-changed (lambda (_) (push t got)))
                (drgnx-signal--flush)
                (setq got nil)
                (drgnx-notify 'config 'fail "bad" :id 'a :life 'condition)
                (drgnx-signal--flush)
                (should (equal got '(t)))
                (drgnx-signal-mode -1)
                (should-not (memq #'drgnx-signal--notices-changed drgnx-notice-functions)))
            (drgnx-signal-mode -1)))))))

(provide 'core-notices-test)
;;; core-notices-test.el ends here
