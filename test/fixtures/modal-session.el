;;; modal-session.el --- for the live modal tests: a drgnx session with evil, driven by real key events -*- lexical-binding: t -*-

;; The GUI and daemon tests of Vim keys (test/live/drgnx-modal-*-test.el) start a session of config drgnx (the
;; checkout's own init), load evil there from DRGNX_MODAL_ELPA (which the session inherits, `drgnx-ui-keep-env'),
;; start the engine and apply a key stack, then press keys through the harness queue (one event per 40 ms tick, the
;; normal command loop).  Without evil in DRGNX_MODAL_ELPA the tests skip (docs/develop/harness.md, "Modal tests").

(require 'ert)
(require 'cl-lib)
(require 'drgnx-ui)

(defconst drgnx-modal-session-skip "evil not installed: see docs/develop/harness.md \"Modal tests\""
  "Why a modal session test skips.")

(defun drgnx-modal-session-elpa ()
  "The package directory DRGNX_MODAL_ELPA names when it has evil, goto-chg and evil-collection, else nil."
  (let ((dir (getenv "DRGNX_MODAL_ELPA")))
    (when (and dir (not (string-empty-p dir)) (file-directory-p dir))
      (let ((dir (expand-file-name dir)))
        (and (cl-every (lambda (p) (directory-files dir nil (concat "\\`" p "-[0-9]")))
                       '("evil" "goto-chg" "evil-collection"))
             dir)))))

(defvar drgnx-modal-session--reports nil "The jank reports of the current test's key presses, newest first.")

(defun drgnx-modal-session-eval (sess form)
  "FORM's value in SESS (printed there, read back here), with the selected window's buffer current."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json
                                                  (list :v (prin1-to-string
                                                            (with-current-buffer (window-buffer (selected-window)) %S))))"
                                               form)
                                  30)
                   :v))))

(defun drgnx-modal-session-start (sess layers)
  "In SESS: evil's packages on `load-path', the module editor/evil on, the engine started, the key stack LAYERS."
  (should (equal (drgnx-modal-session-eval
                  sess `(progn
                          (dolist (d (directory-files ,(drgnx-modal-session-elpa) t
                                                      "\\`\\(evil\\|goto-chg\\|evil-collection\\|annalist\\)-[0-9]"))
                            (add-to-list 'load-path d))
                          (drgnx-modules-set-enabled 'editor/evil t)
                          (list (drgnx-modal-engine-start-now 'evil)
                                (progn (drgnx-keys-use ',layers) drgnx-modal-running))))
                 '(t evil))))

(defun drgnx-modal-session-act (sess &rest actions)
  "Deliver ACTIONS in SESS — strings are keys (`kbd' syntax), (:type TEXT) typed text — and wait until it settles.
The jank report is kept for `drgnx-modal-session-jank'."
  (let ((r (drgnx-ui-measure sess (mapcar (lambda (a) (if (stringp a) (list :keys a) a)) actions))))
    (push (cons actions r) drgnx-modal-session--reports)
    r))

(defun drgnx-modal-session-until (sess form &optional secs)
  "Poll SESS until FORM is non-nil there (at most SECS, default 10); its last value."
  (let ((deadline (+ (float-time) (or secs 10))) v)
    (while (and (not (setq v (drgnx-modal-session-eval sess form))) (< (float-time) deadline))
      (sleep-for 0.1))
    v))

(defun drgnx-modal-session-prompt (sess)
  "The active minibuffer prompt in SESS, or nil."
  (let ((p (plist-get (drgnx-ui-call sess "(drgnx-uitest-api-boot-status)") :prompt)))
    (and (stringp p) p)))

(defun drgnx-modal-session-shot (sess name)
  "A screenshot of SESS as NAME in $DRGNX_TEST_SHOTS (kept: the UI evidence of a run), else in the temp dir; its path."
  (let* ((dir (or (getenv "DRGNX_TEST_SHOTS") temporary-file-directory))
         (path (plist-get (progn (make-directory dir t) (drgnx-ui-screenshot sess (expand-file-name name dir))) :path)))
    (should (file-exists-p path))
    (message "modal screenshot: %s" path)
    path))

(defun drgnx-modal-session-jank (test)
  "Print one line summing the jank reports of TEST's key presses."
  (let ((rs (mapcar #'cdr drgnx-modal-session--reports)))
    (message "jank %s: %d inputs, settle max %s ms, layout %d, collateral %d, oscillations %d, guard %d, unsettled %d"
             test (length rs)
             (apply #'max 0 (mapcar (lambda (r) (or (plist-get r :settle_ms) 0)) rs))
             (apply #'+ (mapcar (lambda (r) (or (plist-get r :layout_changes) 0)) rs))
             (apply #'+ (mapcar (lambda (r) (or (plist-get r :collateral_moves) 0)) rs))
             (apply #'+ (mapcar (lambda (r) (or (plist-get r :oscillations) 0)) rs))
             (apply #'+ (mapcar (lambda (r) (or (plist-get r :guard_violations) 0)) rs))
             (cl-count-if (lambda (r) (eq (plist-get r :settled) :false)) rs))))

(defmacro drgnx-modal-session-with (spec &rest body)
  "SPEC is (SESS &key DAEMON LAYERS): BODY with SESS a fresh drgnx session (a daemon when DAEMON) in a temp state
root, evil running and the key stack LAYERS (default Vim) applied.  Skips without evil; the session is stopped and
its root removed after."
  (declare (indent 1))
  (let ((sess (car spec)) (daemon (plist-get (cdr spec) :daemon))
        (layers (or (plist-get (cdr spec) :layers) ''((vim app editing window)))))
    `(progn
       (unless (drgnx-modal-session-elpa) (ert-skip drgnx-modal-session-skip))
       (let* ((root (make-temp-file "drgnx-modal-live" t))
              (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
              (drgnx-modal-session--reports nil)
              (name (plist-get (drgnx-ui-start "drgnx" "1400x800" 60 ,daemon) :name))
              (,sess (drgnx-ui-own-session name)))
         (unwind-protect
             (progn (drgnx-modal-session-start ,sess ,layers)
                    ,@body
                    (drgnx-modal-session-jank (ert-test-name (ert-running-test))))
           (drgnx-ui-stop name)
           (delete-directory root t))))))

(provide 'modal-session)
;;; modal-session.el ends here
