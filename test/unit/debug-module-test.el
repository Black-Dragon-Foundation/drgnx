;;; debug-module-test.el --- batch tests: the extra/debug module, its commands and session keys -*- lexical-binding: t -*-
;; test-class: det
;; The hub's answers are scripted (`drgnx-hub-call' and `drgnx-hub-call-sync' replaced): what is tested is what the
;; editor sends.  Sessions come from `debug-state' events, fed to the module's handler as the hub would send them.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defmacro debug-module-test--with (sessions &rest body)
  "BODY in a project at /p with the hub's `debug-state' saying SESSIONS; `calls' holds (METHOD . PARAMS) of each call."
  (declare (indent 1))
  `(let ((calls nil) (drgnx-debug--sessions nil))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params _cb &rest _) (setq calls (append calls (list (cons method params))))))
               ((symbol-function 'drgnx-debug-launch-root) (lambda () "/p")))
       (unwind-protect
           (progn (drgnx-debug--event "debug-state" (list :sessions (vconcat ,sessions)))
                  ,@body)
         (drgnx-debug-session-mode -1)))))

(ert-deftest drgnx-debug/the-module-needs-no-package ()
  (drgnx-test-with-modules '(extra/debug) :strict t
                           (should (eq (plist-get (alist-get 'extra/debug (drgnx-modules-report)) :status) 'ok))
                           (dolist (c '(debug-start debug-breakpoint debug-step-over debug-step-in debug-step-out debug-stop
                                                    debug-breakpoint-conditional debug-logpoint debug-breakpoint-enable debug-run-to-cursor
                                                    debug-install-adapter debug-convert-dape))
                             (should (drgnx-commands-get c)))
                           (should (memq #'drgnx-debug--event drgnx-hub-event-functions)))
  (should-not (memq #'drgnx-debug--event drgnx-hub-event-functions)))

(ert-deftest drgnx-debug/start-or-continue ()
  "A stopped session of the project continues; with none, a configuration is picked and started."
  (debug-module-test--with '((:id "s1" :root "/p" :state "stopped") (:id "o" :root "/other" :state "stopped"))
    (drgnx-debug-start-or-continue)
    (should (equal calls '(("debug/control" :session "s1" :op "continue")))))
  (let (started)
    (debug-module-test--with '((:id "o" :root "/other" :state "stopped") (:id "r" :root "/p" :state "running"))
      (cl-letf (((symbol-function 'drgnx-debug-launch-read-config) (lambda (root) (concat root ":launch:0")))
                ((symbol-function 'drgnx-debug-launch-start) (lambda (root config) (setq started (list root config)))))
        (drgnx-debug-start-or-continue)
        (should-not calls)
        (should (equal started '("/p" "/p:launch:0")))))))

(ert-deftest drgnx-debug/steps-go-to-the-stopped-session ()
  "Steps and Stop act on the project's stopped session (a child before its running parent); none is an error."
  (debug-module-test--with '((:id "parent" :root "/p" :state "running") (:id "child" :root "/p" :state "stopped"))
    (drgnx-debug-step-over) (drgnx-debug-step-in) (drgnx-debug-step-out) (drgnx-debug-stop)
    (should (equal (mapcar (lambda (c) (list (plist-get (cdr c) :session) (plist-get (cdr c) :op))) calls)
                   '(("child" "next") ("child" "step-in") ("child" "step-out") ("child" "stop")))))
  (debug-module-test--with nil
    (should-error (drgnx-debug-step-over) :type 'user-error)))

(ert-deftest drgnx-debug/session-keys-only-while-debugging ()
  ;; F11 is Zen Mode in the VS Code profile, Step Into while a session runs (as in VS Code)
  (debug-module-test--with '((:id "s" :root "/q" :state "running"))
    (should drgnx-debug-session-mode)
    (drgnx-debug--event "debug-state" (list :sessions []))
    (should-not drgnx-debug-session-mode)
    (drgnx-debug--event "debug-frame" (list :session "x"))
    (should-not drgnx-debug-session-mode)))

(ert-deftest drgnx-debug/keys-in-every-profile ()
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((text (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir)) (buffer-string))))
      (dolist (c '(debug-start debug-breakpoint debug-step-over debug-step-in debug-step-out debug-stop
                               debug-breakpoint-conditional debug-logpoint debug-breakpoint-enable debug-run-to-cursor))
        (should (string-search (format "(%s " c) text)))))
  (let ((vs (with-temp-buffer (insert-file-contents (expand-file-name "keys/vscode.eld" drgnx-dir)) (buffer-string)))
        (em (with-temp-buffer (insert-file-contents (expand-file-name "keys/emacs.eld" drgnx-dir)) (buffer-string))))
    (should (string-search "(debug-start \"<f5>\")" vs))
    (should (string-search "(debug-step-in \"<f11>\" :map drgnx-debug-session-map)" vs))
    (should (string-search "(debug-run-to-cursor \"C-<f10>\")" vs))
    ;; GUD's prefix, in the module's own map so a loaded gud's global C-x C-a loses to it (spec §14)
    (should (string-search "(debug-breakpoint \"C-x C-a C-b\" :map drgnx-debug-mode-map)" em))))

(ert-deftest drgnx-debug/the-mode-gives-file-buffers-the-column ()
  (let* ((dir (make-temp-file "dm" t)) (f (expand-file-name "a.py" dir)) b)
    (with-temp-file f (insert "x = 1\n"))
    (cl-letf (((symbol-function 'drgnx-hub-call) #'ignore)
              ((symbol-function 'drgnx-debug-launch-root) (lambda () dir)))
      (unwind-protect
          (progn
            (setq b (find-file-noselect f))
            (drgnx-debug-mode 1)
            (should (buffer-local-value 'drgnx-debug-gutter-mode b))
            (with-temp-buffer (should-not drgnx-debug-gutter-mode))   ; no file, no column
            (let ((c (find-file-noselect (expand-file-name "b.py" dir))))
              (should (buffer-local-value 'drgnx-debug-gutter-mode c))
              (kill-buffer c))
            (drgnx-debug-mode -1)
            (should-not (buffer-local-value 'drgnx-debug-gutter-mode b)))
        (drgnx-debug-mode -1)
        (when (buffer-live-p b) (kill-buffer b))
        (delete-directory dir t)))))

(ert-deftest drgnx-debug/a-debug-terminal-event-opens-its-tab ()
  (let ((seen nil))
    (cl-letf (((symbol-function 'drgnx-debug-launch-show-terminal) (lambda (d) (push d seen))))
      (drgnx-debug--event "debug-terminal" (list :term "t1")))
    (should (equal seen '((:term "t1"))))))

;;;; The spec's §14 commands not covered above

(ert-deftest drgnx-debug/run-without-debugging-starts-with-no-debug ()
  (let (started)
    (debug-module-test--with nil
      (cl-letf (((symbol-function 'drgnx-debug-launch-read-config) (lambda (root) (concat root ":launch:0")))
                ((symbol-function 'drgnx-debug-launch-start)
                 (lambda (root config &optional no-debug) (setq started (list root config no-debug)))))
        (drgnx-debug-run-no-debug)
        (should (equal started '("/p" "/p:launch:0" t)))))))

(ert-deftest drgnx-debug/a-selected-configuration-starts-without-asking ()
  (let ((started nil) (asked 0))
    (debug-module-test--with nil
      (cl-letf (((symbol-function 'drgnx-debug-launch-read-config) (lambda (_root) (cl-incf asked) "launch:1"))
                ((symbol-function 'drgnx-debug-launch-start)
                 (lambda (root config &optional _) (push (list root config) started))))
        (unwind-protect
            (progn (drgnx-debug-select-config)
                   (drgnx-debug-start-or-continue)
                   (drgnx-debug-start-or-continue))
          (drgnx-debug-select-config-forget))
        (should (= asked 1))
        (should (equal started '(("/p" "launch:1") ("/p" "launch:1"))))))))

(ert-deftest drgnx-debug/toggle-all-and-function-breakpoints-go-to-the-hub ()
  (debug-module-test--with nil
    (drgnx-debug-breakpoints-toggle-all)
    (drgnx-debug-function-breakpoint "main")
    (should (equal calls '(("debug/breakpoints" :root "/p" :op (:op "toggle-all"))
                           ("debug/breakpoints" :root "/p" :op (:op "add-function" :name "main")))))))

(ert-deftest drgnx-debug/evaluate-sends-the-selection-to-the-console ()
  ;; the console's own evaluate (drgnx-debug-console.el), the tab shown without the focus
  (let (sent)
    (debug-module-test--with '((:id "s1" :root "/p" :state "stopped"))
      (cl-letf (((symbol-function 'drgnx-debug-console-evaluate)
                 (lambda (expr &optional select) (push (list expr select) sent))))
        (with-temp-buffer
          (insert "x = items[0] + 1")
          (transient-mark-mode 1)
          (goto-char 5) (push-mark (point) t t) (goto-char 13)
          (drgnx-debug-evaluate (drgnx-debug--expression-at-point))
          (deactivate-mark)
          (goto-char 7)
          (drgnx-debug-evaluate (drgnx-debug--expression-at-point)))))
    (should (equal (nreverse sent) '(("items[0]" nil) ("items" nil))))))

(ert-deftest drgnx-debug/show-value-evaluates-the-expression-at-point ()
  (let ((shown nil) (asked nil))
    (debug-module-test--with '((:id "s1" :root "/p" :state "stopped"))
      (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                 (lambda (m p &rest _) (setq asked (cons m p)) '(:result "[1, 2]" :type "list")))
                ((symbol-function 'message) (lambda (f &rest a) (setq shown (apply #'format f a)))))
        (with-temp-buffer
          (insert "print(self.items)")
          (goto-char 13)
          (drgnx-debug-show-value))))
    (should (equal asked '("debug/evaluate" :session "s1" :expr "self.items" :context "hover")))
    (should (string-match-p "self\\.items.*\\[1, 2\\]" shown))))

(ert-deftest drgnx-debug/open-launch-json-makes-one-when-there-is-none ()
  (let ((dir (file-name-as-directory (make-temp-file "dl" t))))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-debug-launch-root) (lambda () dir)))
          (drgnx-debug-open-launch-json)
          (should (equal buffer-file-name (expand-file-name ".vscode/launch.json" dir)))
          (should (string-search "\"configurations\": [" (buffer-string)))
          (should (file-exists-p buffer-file-name))
          (kill-buffer))
      (delete-directory dir t))))

(ert-deftest drgnx-debug/every-spec-command-has-its-keys ()
  ;; spec §14: the table's keys, each profile
  (pcase-dolist (`(,profile . ,entries)
                 '(("vscode" "(debug-run-no-debug \"C-<f5>\")" "(debug-view \"C-S-d\")" "(debug-console \"C-S-y\")")
                   ("emacs" "(debug-start \"C-x C-a C-a\" \"C-x C-a C-r\" :map drgnx-debug-mode-map)"
                    "(debug-run-no-debug \"C-x C-a C-x\" :map drgnx-debug-mode-map)"
                    "(debug-pause \"C-x C-a C-z\" :map drgnx-debug-mode-map)"
                    "(debug-evaluate \"C-x C-a C-p\" :map drgnx-debug-mode-map)"
                    "(debug-show-value \"C-x C-a C-h\" :map drgnx-debug-mode-map)"
                    "(debug-remove-all-breakpoints \"C-x C-a C-k\" :map drgnx-debug-mode-map)")
                   ("vim" "(debug-start \"SPC d d\" \"<f5>\")" "(debug-run-no-debug \"SPC d D\")" "(debug-evaluate \"SPC d E\")"
                    "(debug-show-value \"SPC d h\")" "(debug-step-in \"SPC d i\" \"<f11>\" :key-map ((\"<f11>\" drgnx-debug-session-map)))")))
    (let ((text (with-temp-buffer (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                                  (buffer-string))))
      (dolist (e entries) (should (string-search e text)))
      (dolist (c '(debug-run-no-debug debug-breakpoints-toggle-all debug-function-breakpoint debug-evaluate
                                      debug-show-value debug-select-config debug-open-launch-json))
        (should (string-search (format "(%s " c) text))))))

(ert-deftest drgnx-debug/the-debug-keys-conflict-with-nothing ()
  ;; every profile with the module's commands: no problem and no conflict names a debug command
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir)))
        (defaults (copy-keymap global-map)))
    (drgnx-test-with-modules '(extra/debug)
      (dolist (layers '(((vscode app editing window)) ((emacs app editing window))
                        ((vscode app window) (vim editing))))
        (let ((r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles profiles :layers layers
                                     :platform 'linux :defaults defaults)))
          (should-not (seq-filter (lambda (p) (string-search "debug-" (format "%S" p))) (plist-get r :problems)))
          (should-not (seq-filter (lambda (c) (string-search "debug-" (format "%S" c))) (plist-get r :conflicts))))))))
