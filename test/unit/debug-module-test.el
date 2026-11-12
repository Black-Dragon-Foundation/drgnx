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
