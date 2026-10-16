;;; daemon-test.el --- live tests: daemon sessions and new frames -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-ui)

(ert-deftest drgnx-live/daemon-session-and-new-frame ()
  (let* ((root (make-temp-file "drgnx-daemon" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "minimal" nil 30 t))
         (name (plist-get s :name))
         (sess (drgnx-ui-own-session name)))
    (unwind-protect
        (progn
          (should (eq (plist-get (plist-get s :ready) :init_error) :false))
          (should-error (drgnx-ui-screenshot sess (expand-file-name "none.png" root)) :type 'drgnx-ui-error)
          (let ((f (drgnx-ui-new-frame sess)))
            (should (eq (plist-get f :exit) 0))
            (should (< (plist-get f :visible_ms) 2000))
            (should (vectorp (plist-get f :hooks))))
          (should (file-exists-p (plist-get (drgnx-ui-screenshot sess (expand-file-name "f.png" root)) :path))))
      (drgnx-ui-stop name)
      (delete-directory root t))
    (should (equal (with-temp-buffer (call-process "pgrep" nil t nil "-f" "--" (concat "--wayland-display " name " "))
                                     (string-trim (buffer-string)))
                   ""))))
