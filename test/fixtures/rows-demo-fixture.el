;;; rows-demo-fixture.el --- a hub-fed fixture view, its rows given by the hub's test method -*- lexical-binding: t -*-
;;
;; (drgnx-rows-demo-with BODY...)        BODY with a real hub (`drgnx-test-with-ratatoskr', a test-hooks build from
;;                                       DRGNX_RATATOSKR_BIN; skipped without it) and the inserter's state fresh
;; (drgnx-rows-demo-open [CLASS])        a buffer shown in the selected window, attached as the hub-fed view
;;                                       `rows-demo' and its env sent: by `drgnx-view-env' (its window's class), or
;;                                       with CLASS directly by `view/env' (a class of the test's own)
;; (drgnx-rows-demo-feed ROWS [IMAGES] [LABELS])  `__test_view_rows': the hub's fixture view shows ROWS (plists as
;;                                       `drgnx-rows-demo-row' makes), IMAGES ((ID SVG) ...) and LABELS ((KEY TEXT PX)
;;                                       ...: each fitted by the hub with the class's fonts, then a stop at PX)
;; (drgnx-rows-demo-settle BUFFER)       wait until BUFFER's view took the hub's last patch, then draw it
;;
;; The rule rows of the render offload (docs/develop/core.md, "Hub-fed views") run on this view; later areas call the
;; same helpers for theirs.  It needs only a drgnx checkout and the hub built with test hooks: no Linux harness, so the
;; GUI fit row runs on macOS too.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-view)
(require 'drgnx-view-env)
(load (expand-file-name "test/fixtures/ratatoskr-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-dir) nil t)

(defconst drgnx-rows-demo-view "rows-demo" "The fixture view's id.")

(defvar drgnx-rows-demo--buffers nil "The buffers `drgnx-rows-demo-open' made, killed after BODY.")

(defvar drgnx-rows-demo--hubs nil "The hubs `drgnx-rows-demo-restart-hub' started, ended after BODY.")

(defun drgnx-rows-demo--bin ()
  "The hub: DRGNX_RATATOSKR_BIN, else the checkout's own build (a GUI session does not inherit the variable), or nil."
  (or (getenv "DRGNX_RATATOSKR_BIN")
      (seq-find #'file-executable-p
                (mapcar (lambda (p) (expand-file-name p drgnx-dir))
                        '("runtime/target/debug/ratatoskr" "runtime/target/release/ratatoskr")))))

(defmacro drgnx-rows-demo-with (&rest body)
  "BODY with a real hub and this Emacs connected, the inserter's and the env's state fresh; torn down after."
  (declare (indent 0))
  `(let ((process-environment (let ((bin (drgnx-rows-demo--bin)))
                                (if bin (cons (concat "DRGNX_RATATOSKR_BIN=" bin) process-environment)
                                  process-environment)))
         (root (make-temp-file "drgnx-rows-demo" t))
         (drgnx-view-patch--buffers (make-hash-table :test #'equal)) (drgnx-view-patch--hooked nil)
         (drgnx-view-env--views (make-hash-table :test #'equal)) (drgnx-view-env--sent (make-hash-table :test #'equal))
         (drgnx-view-env--glyphs (make-hash-table :test #'equal)) (drgnx-view-env--hooked nil)
         (drgnx-rows-demo--buffers nil) (drgnx-rows-demo--hubs nil))
     (unwind-protect
         (drgnx-test-with-ratatoskr root
           (unwind-protect (save-window-excursion ,@body)
             (dolist (h drgnx-rows-demo--hubs)
               (when (process-live-p h) (drgnx-rows-demo--mark-ended h) (signal-process h 'term))
               (ignore-errors (drgnx-test-wait (lambda () (process-get h :ended)) :secs 10 :what "a restarted hub ends"))
               (when (process-live-p h) (signal-process h 'kill))
               (when (buffer-live-p (process-buffer h)) (kill-buffer (process-buffer h))))
             (drgnx-view-env-teardown)
             (drgnx-view-patch-teardown)
             (dolist (b drgnx-rows-demo--buffers)
               (when (buffer-live-p b)
                 (drgnx-timer-cancel (cons 'drgnx-view b))
                 (kill-buffer b)))))
       (delete-directory root t))))

(defun drgnx-rows-demo-call (method params)
  "METHOD with PARAMS on this Emacs's subscribed connection (the one the patches come back on); its result."
  (let ((done nil) (out nil))
    (drgnx-hub--call-on drgnx-hub--events method params (lambda (r e) (setq done t out (if e (list :error e) r))))
    (drgnx-test-wait (lambda () done) :secs 10 :what method)
    out))

(defun drgnx-rows-demo-row (key text &rest more)
  "A row plist for `drgnx-rows-demo-feed': KEY, TEXT and MORE (:runs :stops :images :height ...), vectors inside."
  (append (list :key key :text text) more))

(defun drgnx-rows-demo-feed (rows &optional images labels)
  "The hub's fixture view shows ROWS, may name IMAGES ((ID SVG) ...) and fits LABELS ((KEY TEXT PX) ...)."
  (drgnx-rows-demo-call "__test_view_rows"
                        (list :view drgnx-rows-demo-view :rows (vconcat rows)
                              :images (vconcat (mapcar #'vconcat images)) :labels (vconcat (mapcar #'vconcat labels)))))

(defun drgnx-rows-demo-env (class epoch &rest more)
  "Send `view/env' for (rows-demo, CLASS) at EPOCH directly (a terminal class of 1x1 cells unless MORE says), and
tell the inserter."
  (let ((params (list :view drgnx-rows-demo-view :class class :epoch epoch :display "tty" :scale 1.0
                      :fonts [] :cell [1 1] :width_px 80 :palette [] :tty_widths [] :tz "UTC" :reduced_motion :false)))
    (while more (setq params (plist-put params (pop more) (pop more))))
    (drgnx-rows-demo-call "view/env" params)
    (drgnx-view-patch-env-sent drgnx-rows-demo-view class epoch)))

(defun drgnx-rows-demo-open (&optional class)
  "A new buffer shown in the selected window, attached as the hub-fed view `rows-demo'; its env sent by
`drgnx-view-env' (the class of its window), or, with CLASS, directly at epoch 1.  Returns the buffer."
  (let ((b (generate-new-buffer " *rows-demo*")))
    (push b drgnx-rows-demo--buffers)
    (switch-to-buffer b)
    (if class
        (progn (drgnx-view-patch-attach drgnx-rows-demo-view class)
               (drgnx-rows-demo-env class 1))
      (let ((own (car (car (drgnx-rows-demo--envs-of b)))))
        (drgnx-view-patch-attach drgnx-rows-demo-view own)
        (drgnx-view-env-register drgnx-rows-demo-view b)))
    b))

(defun drgnx-rows-demo--envs-of (buffer)
  "The (CLASS . PARAMS) BUFFER would be sent as `rows-demo' now."
  (let ((drgnx-view-env--views (make-hash-table :test #'equal)))
    (puthash drgnx-rows-demo-view (list buffer) drgnx-view-env--views)
    (drgnx-view-env--envs drgnx-rows-demo-view)))

(defun drgnx-rows-demo-state (buffer) (buffer-local-value 'drgnx-view-patch buffer))

(defun drgnx-rows-demo-settle (buffer &optional what)
  "Wait until BUFFER's view holds a version, has no resync outstanding and the hub sent nothing more for 0.2 s;
then draw it.  WHAT names the wait."
  (let ((last nil) (since (float-time)))
    (drgnx-test-wait (lambda ()
                       (let* ((s (drgnx-rows-demo-state buffer)) (v (drgnx-view-patch-version s)))
                         (unless (equal v last) (setq last v since (float-time)))
                         (and v (not (drgnx-view-patch-resync s)) (> (- (float-time) since) 0.2))))
                     :secs 15 :what (or what "the hub's patches applied")))
  (with-current-buffer buffer (drgnx-view-draw-now drgnx-view))
  buffer)

(defun drgnx-rows-demo--mark-ended (proc)
  "Set PROC's `:ended' property once its sentinel has seen it end (a wait reads the flag, not `process-live-p')."
  (if (null proc)
      nil
    (add-function :after (process-sentinel proc)
                  (lambda (p _event) (unless (process-live-p p) (process-put p :ended t))))))

(defun drgnx-rows-demo-restart-hub ()
  "End the hub (its process: a crash, not a shutdown), wait for this Emacs to see it gone, start a new one on the
same runtime dir and connect again; return once `drgnx-hub-connected-functions' ran for the new hub."
  (let* ((old (or (car drgnx-rows-demo--hubs) drgnx-test-ratatoskr-process)) (up nil) (events drgnx-hub--events)
         (mark (lambda () (setq up t))))
    (drgnx-rows-demo--mark-ended old)
    (drgnx-rows-demo--mark-ended events)
    (signal-process old 'kill)
    (drgnx-test-wait (lambda () (process-get old :ended)) :secs 10 :what "the old hub gone")
    (drgnx-test-wait (lambda () (or (null events) (process-get events :ended))) :secs 10 :what "the subscription closed")
    (let ((new (make-process :name "ratatoskr-restarted" :noquery t :connection-type 'pipe
                             :buffer (generate-new-buffer " *ratatoskr restarted*")
                             :command (list (getenv "DRGNX_RATATOSKR_BIN") "serve" "--foreground"
                                            "--parent-pid" (number-to-string (emacs-pid))))))
      (push new drgnx-rows-demo--hubs)
      (drgnx-test-wait #'drgnx-hub-running-p :secs 30 :what "the new hub answers a ping")
      (add-hook 'drgnx-hub-connected-functions mark)
      (unwind-protect
          (progn (drgnx-hub-connect)
                 (drgnx-test-wait (lambda () (and up drgnx-hub--events)) :secs 30
                                  :what "subscribed to the new hub"))
        (remove-hook 'drgnx-hub-connected-functions mark)))))

(defun drgnx-rows-demo-text (buffer)
  (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(provide 'rows-demo-fixture)
;;; rows-demo-fixture.el ends here
