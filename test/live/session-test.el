;;; session-test.el --- live tests: real sessions through the controller -*- lexical-binding: t -*-
;; Run by `drgnx test --ui' in batch Emacs; each test starts real headless sessions.
(require 'ert)
(require 'drgnx-ui)

(defmacro drgnx-live--with-state (&rest body)
  "Run BODY with `root' bound to a fresh state root; stop its sessions afterwards."
  (declare (indent 0))
  `(let* ((root (make-temp-file "drgnx-ui-live" t))
          (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment)))
     (unwind-protect (progn ,@body)
       (seq-doseq (s (drgnx-ui-ls)) (drgnx-ui-stop (plist-get s :name)))
       (delete-directory root t))))

(defun drgnx-live--nonblank-p (png)
  (with-temp-buffer
    (call-process "magick" nil t nil png "-format" "%[fx:standard_deviation]" "info:")
    (> (string-to-number (buffer-string)) 0.01)))

(defun drgnx-live--processes (pattern)
  (with-temp-buffer
    (call-process "pgrep" nil t nil "-f" "--" pattern)
    (string-trim (buffer-string))))

(ert-deftest drgnx-live/start-drive-capture-stop ()
  (drgnx-live--with-state
    (let* ((s (drgnx-ui-start "minimal"))
           (name (plist-get s :name))
           (sess (drgnx-ui-own-session name)))
      (should (eq (plist-get (plist-get s :ready) :init_error) :false))
      (let ((r (drgnx-ui-measure sess (list (list :type "hello drgnx ✓")))))
        (should (eq (plist-get r :settled) t))
        (should (= (plist-get r :collateral_moves) 0)))
      (should (equal (plist-get (drgnx-ui-call sess "(with-current-buffer \"*scratch*\" (drgnx-uitest--json (list :s (buffer-string))))") :s)
                     "hello drgnx ✓"))
      (drgnx-ui-measure sess (list (list :buffer "*scratch*" :text "drgnx")))
      (let ((win (seq-find (lambda (w) (eq (plist-get w :selected) t))
                           (plist-get (drgnx-ui-state sess) :windows))))
        (should (= (plist-get win :point) 7)))            ; clicked on the "d" of "drgnx"
      (let ((shot (drgnx-ui-screenshot sess (expand-file-name "s.png" root))))
        (should (drgnx-live--nonblank-p (plist-get shot :path))))
      (drgnx-ui-stop name)
      (should-not (drgnx-ui-unit-active-p name))
      (should-not (file-exists-p (expand-file-name name (drgnx-ui-runtime-dir))))   ; mutter's Wayland socket
      (should (equal (drgnx-live--processes (concat "--wayland-display " name)) "")))))

(ert-deftest drgnx-live/init-error-still-ready ()
  (drgnx-live--with-state
    (let ((cfg (expand-file-name "broken" root)))
      (make-directory cfg)
      (write-region "(error \"broken config\")\n" nil (expand-file-name "init.el" cfg))
      (let ((s (drgnx-ui-start cfg)))
        (should (eq (plist-get (plist-get s :ready) :init_error) t))
        (drgnx-ui-stop (plist-get s :name))))))

(ert-deftest drgnx-live/deep-state-root-still-starts ()
  (drgnx-live--with-state
    (let* ((deep (expand-file-name (make-string 120 ?d) root))
           (process-environment (cons (concat "DRGNX_UI_STATE=" deep) process-environment))
           (s (drgnx-ui-start "minimal" nil 20)))
      (should (plist-get (drgnx-ui-state (drgnx-ui-own-session (plist-get s :name))) :windows))
      (drgnx-ui-stop (plist-get s :name)))))

(ert-deftest drgnx-live/detached-launcher-without-systemd ()
  (drgnx-live--with-state
    (let* ((process-environment (cons "DRGNX_UI_LAUNCHER=detached" process-environment))
           (s (drgnx-ui-start "minimal" nil 20))
           (name (plist-get s :name)))
      (should (equal (plist-get s :launcher) "detached"))
      (should-not (drgnx-ui-unit-active-p name))
      (should (drgnx-ui-alive-p (drgnx-ui-own-session name)))
      (should (eq (plist-get (drgnx-ui-measure (drgnx-ui-own-session name) (list (list :type "x"))) :settled) t))
      (drgnx-ui-stop name)
      (should (equal (drgnx-live--processes (concat "--wayland-display " name)) "")))))

(ert-deftest drgnx-live/stop-leaves-other-state-roots-alone ()
  (drgnx-live--with-state
    (let* ((s (drgnx-ui-start "minimal" nil 20))
           (name (plist-get s :name))
           (other (make-temp-file "drgnx-ui-other" t)))
      (unwind-protect
          (let ((process-environment (cons (concat "DRGNX_UI_STATE=" other) process-environment)))
            (drgnx-ui-prepare-run name)                  ; a stale dir with the same name elsewhere
            (should (eq (plist-get (aref (drgnx-ui-ls) 0) :active) :false))
            (drgnx-ui-stop name))
        (delete-directory other t))
      (should (drgnx-ui-alive-p s))
      (should (file-exists-p (expand-file-name name (drgnx-ui-runtime-dir))))
      (should (drgnx-ui-state (drgnx-ui-own-session name))))))

(ert-deftest drgnx-live/measure-resolves-each-action-after-the-previous-one ()
  (drgnx-live--with-state
    (let* ((s (drgnx-ui-start "minimal" nil 20))
           (sess (drgnx-ui-own-session (plist-get s :name))))
      (drgnx-ui-measure sess (list (list :keys "C-x 3") (list :x 1200 :y 40)))
      (let ((win (seq-find (lambda (w) (eq (plist-get w :selected) t)) (plist-get (drgnx-ui-state sess) :windows))))
        (should (> (aref (plist-get win :edges) 0) 700))))))

(ert-deftest drgnx-live/prompt-during-init-returns-and-can-be-answered ()
  (drgnx-live--with-state
    (let ((cfg (expand-file-name "prompting" root)) (t0 (float-time)))
      (make-directory cfg)
      (write-region "(setq drgnx-test-answer (read-string \"Name? \"))\n" nil (expand-file-name "init.el" cfg))
      (let* ((s (drgnx-ui-start cfg))
             (ready (plist-get s :ready))
             (sess (drgnx-ui-own-session (plist-get s :name))))
        (should (< (- (float-time) t0) 20))
        (should (eq (plist-get ready :init_running) t))
        (should (equal (plist-get ready :prompt) "Name? "))
        (drgnx-ui-measure sess (list (list :type "drgnx") (list :keys "RET")))
        (let ((deadline (+ (float-time) 10)))
          (while (and (not (file-exists-p (expand-file-name "ready.json" (plist-get s :run))))
                      (< (float-time) deadline))
            (sleep-for 0.1)))
        (should (file-exists-p (expand-file-name "ready.json" (plist-get s :run))))
        (should (equal (plist-get (drgnx-ui-call sess "(drgnx-uitest--json (list :a drgnx-test-answer))") :a)
                       "drgnx"))))))

(ert-deftest drgnx-live/config-that-moves-the-server-is-refused ()
  (drgnx-live--with-state
    (let ((cfg (expand-file-name "mover" root)))
      (make-directory cfg)
      (write-region "(setq server-name \"not-the-harness\")\n(server-start)\n" nil (expand-file-name "init.el" cfg))
      (let ((err (should-error (drgnx-ui-start cfg nil 20) :type 'drgnx-ui-error)))
        (should (string-search "moved" (error-message-string err))))
      (should (= (length (drgnx-ui-ls)) 0)))))
