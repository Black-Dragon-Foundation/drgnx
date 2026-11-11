;;; view-model-hub-test.el --- a view's model from the real Ratatoskr, unparsed on both hub paths -*- lexical-binding: t -*-
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

(defvar drgnx-view-model-hub-test--models nil
  "The `view-model' lines that reached the model, newest first: a string (unframed), or (:pushed . SJÁ'S-ANSWER) for
one Nidhogg's reader pushed to Sjá itself (framed).")
(defvar drgnx-view-model-hub-test--events nil "The `view-model' events the event hook saw (none, ever).")
(defvar drgnx-view-model-hub-test--parsed 0 "Calls of `json-parse-string' on a `view-model' line.")

(defun drgnx-view-model-hub-test--event (event data)
  (when (equal event "view-model") (push data drgnx-view-model-hub-test--events)))

(defun drgnx-view-model-hub-test--line (line)
  (push line drgnx-view-model-hub-test--models))

(defun drgnx-view-model-hub-test--pushed (r)
  (push (cons :pushed r) drgnx-view-model-hub-test--models))

(defun drgnx-view-model-hub-test--count-parse (fn string &rest args)
  (when (string-prefix-p "{\"event\":\"view-model\"" string) (cl-incf drgnx-view-model-hub-test--parsed))
  (apply fn string args))

(defmacro drgnx-view-model-hub-test--with (framing &rest body)
  "BODY with Ratatoskr serving a temp root, this Emacs connected with `nidhogg-workers-framing' FRAMING, and its
`view-model' events recorded."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-vm" t)))
          (nidhogg-workers-framing ,framing)
          (drgnx-view-model-hub-test--models nil) (drgnx-view-model-hub-test--events nil)
          (drgnx-view-model-hub-test--parsed 0)
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "XDG_RUNTIME_DIR=" root "run")
                                             (concat "XDG_DATA_HOME=" root "xdg-data") (concat "XDG_CONFIG_HOME=" root "xdg-config")
                                             (concat "XDG_CACHE_HOME=" root "cache") (concat "HOME=" root "home")
                                             "OPENROUTER_API_KEY" "DRGNX_JOBS_LAUNCHER=detached" "DRGNX_NO_HUB_START")
                                       process-environment))
          (drgnx-hub--asked-disconnect nil) (drgnx-hub--resubscribe-since nil) (drgnx-hub--resubscribe-delay 1)
          (drgnx-hub--presence-sent :unknown) (drgnx-hub-editor-token-hook nil))
     (dolist (d '("run" "home" "config" "data" "work")) (with-file-modes #o700 (make-directory (concat root d) t)))
     (advice-add 'drgnx-view-model-line :before #'drgnx-view-model-hub-test--line)
     (advice-add 'drgnx-view-model--pushed :before #'drgnx-view-model-hub-test--pushed)
     (advice-add 'json-parse-string :around #'drgnx-view-model-hub-test--count-parse)
     (unwind-protect
         (drgnx-test-with-ratatoskr root
           (add-hook 'drgnx-hub-event-functions #'drgnx-view-model-hub-test--event)
           (unwind-protect (progn ,@body)
             (remove-hook 'drgnx-hub-event-functions #'drgnx-view-model-hub-test--event)))
       (advice-remove 'drgnx-view-model-line #'drgnx-view-model-hub-test--line)
       (advice-remove 'drgnx-view-model--pushed #'drgnx-view-model-hub-test--pushed)
       (advice-remove 'json-parse-string #'drgnx-view-model-hub-test--count-parse)
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

(defun drgnx-view-model-hub-test--unparsed (framing)
  "With FRAMING, the subscribe's `view-model' line reaches Sjá whole, never parsed in Lisp nor seen as an event:
framed, Nidhogg's reader pushes it and only Sjá's answer for view \"vm\" comes to Lisp; unframed, the filter hands
the line (the event first, the model an object) to the model."
  (drgnx-view-model-hub-test--with framing
    (if framing
        (should (nidhogg-process-framing drgnx-hub--events))
      (should-not (and (fboundp 'nidhogg-process-framing) (nidhogg-process-framing drgnx-hub--events))))
    (drgnx-view-model-hub-test--subscribe root)
    (drgnx-test-wait (lambda () drgnx-view-model-hub-test--models) :secs 30 :what "the map's first view-model")
    (let ((line (car (last drgnx-view-model-hub-test--models))))
      (if framing
          (progn (should (eq :pushed (car-safe line))) (should (equal "vm" (nth 1 line)))
                 (should-not (cl-some #'stringp drgnx-view-model-hub-test--models)))
        (should (stringp line))
        (should (string-prefix-p "{\"event\":\"view-model\",\"data\":{" line))
        (should (string-search "\"model\":{\"ops\":[" line))
        (should (string-search "\"view\":\"vm\"" line))))
    (should-not drgnx-view-model-hub-test--events)
    (should (= 0 drgnx-view-model-hub-test--parsed))))

(ert-deftest drgnx-view-model/reaches-sja-unparsed-framed ()
  (skip-unless (drgnx-test-ratatoskr-bin))
  ;; the reader's push to Sjá (`:raw-to-sja') came with `nidhogg-view--pushed': an older nh-io refuses the keyword and
  ;; the client stays unframed
  (require 'nidhogg-views nil t)
  (drgnx-test-require-nidhogg (and (fboundp 'nidhogg-set-process-framing) (fboundp 'nidhogg-view--pushed))
                              ":raw-to-sja framing (nidhogg-view--pushed)")
  (drgnx-view-model-hub-test--unparsed t))

(ert-deftest drgnx-view-model/reaches-sja-unparsed-unframed ()
  (skip-unless (drgnx-test-ratatoskr-bin))
  (drgnx-view-model-hub-test--unparsed nil))

;;; view-model-hub-test.el ends here
