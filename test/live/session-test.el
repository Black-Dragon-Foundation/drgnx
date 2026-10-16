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
