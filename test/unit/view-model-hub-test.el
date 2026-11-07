;;; view-model-hub-test.el --- a view's model from the real Ratatoskr: one string on both hub paths -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The hub is the real binary (DRGNX_RATATOSKR_BIN, skipped without it).  Every wait is on what the hub announces
;; (the subscription's answer, the `view-model' event itself), never on a clock.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-timer)
(require 'drgnx-hub-client)
(require 'drgnx-view)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)

(defvar nidhogg-workers-framing)
(declare-function nidhogg-process-framing "nidhogg-io.c")

(defvar drgnx-view-model-hub-test--models nil "The `view-model' events' data this test saw, newest first.")

(defun drgnx-view-model-hub-test--event (event data)
  (when (equal event "view-model") (push data drgnx-view-model-hub-test--models)))

(defmacro drgnx-view-model-hub-test--with (framing &rest body)
  "BODY with Ratatoskr serving a temp root, this Emacs connected with `nidhogg-workers-framing' FRAMING, and its
`view-model' events recorded."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-vm" t)))
          (nidhogg-workers-framing ,framing)
          (drgnx-view-model-hub-test--models nil)
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "XDG_RUNTIME_DIR=" root "run")
                                             (concat "XDG_DATA_HOME=" root "xdg-data") (concat "XDG_CONFIG_HOME=" root "xdg-config")
                                             (concat "XDG_CACHE_HOME=" root "cache") (concat "HOME=" root "home")
                                             "OPENROUTER_API_KEY" "DRGNX_JOBS_LAUNCHER=detached" "DRGNX_NO_HUB_START")
                                       process-environment))
          (drgnx-hub--asked-disconnect nil) (drgnx-hub--resubscribe-since nil) (drgnx-hub--resubscribe-delay 1)
          (drgnx-hub--presence-sent :unknown) (drgnx-hub-editor-token-hook nil))
     (dolist (d '("run" "home" "config" "data" "work")) (with-file-modes #o700 (make-directory (concat root d) t)))
     (unwind-protect
         (drgnx-test-with-ratatoskr root
           (add-hook 'drgnx-hub-event-functions #'drgnx-view-model-hub-test--event)
           ,@body)
       (delete-directory root t))))

(defun drgnx-view-model-hub-test--subscribe (root)
  "Subscribe the rows map view \"vm\" of a workspace on ROOT/work on the events connection; wait for its answer."
  (let ((answer nil))
    (drgnx-hub--call-on drgnx-hub--events "work/map/subscribe"
                        (list :view "vm" :workspace (list :id "workspace:000000000000" :roots (vector (concat root "work")))
                              :width_units 250 :rows t)
                        (lambda (r e) (setq answer (list r e))))
    (drgnx-test-wait (lambda () answer) :secs 30 :what "the map subscription's answer")
    (should-not (nth 1 answer))))

(defun drgnx-view-model-hub-test--one-string (framing)
  "With FRAMING, the subscribe's `view-model' arrives as four scalars, `reset' and one string, never Lisp data."
  (drgnx-view-model-hub-test--with framing
    (if framing
        (should (nidhogg-process-framing drgnx-hub--events))
      (should-not (and (fboundp 'nidhogg-process-framing) (nidhogg-process-framing drgnx-hub--events))))
    (drgnx-view-model-hub-test--subscribe root)
    (drgnx-test-wait (lambda () drgnx-view-model-hub-test--models) :secs 30 :what "the map's first view-model")
    (let ((data (car (last drgnx-view-model-hub-test--models))))
      (should (equal "vm" (plist-get data :view)))
      (should (stringp (plist-get data :model)))
      (should (string-prefix-p "{" (plist-get data :model)))
      (should (eq t (plist-get data :reset)))
      (should (eql 0 (plist-get data :base)))
      (should (eql 1 (plist-get data :version)))
      (cl-loop for (k v) on data by #'cddr
               do (should (memq k '(:view :hub :base :version :reset :model)))
               do (should (or (stringp v) (integerp v) (eq v t)))))))

(ert-deftest drgnx-view-model/is-one-string-framed ()
  (skip-unless (and (drgnx-test-ratatoskr-bin) (fboundp 'nidhogg-set-process-framing)))
  (drgnx-view-model-hub-test--one-string t))

(ert-deftest drgnx-view-model/is-one-string-unframed ()
  (skip-unless (drgnx-test-ratatoskr-bin))
  (drgnx-view-model-hub-test--one-string nil))

;;; view-model-hub-test.el ends here
