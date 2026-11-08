;;; look-scenes-test.el --- the look's scenes: one per mockup, a project with the audit's git state -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure) for the scene table and the size; the project is made with git in a temp directory.  The scenes
;; themselves are drawn by `drgnx ui look-scenes' in a session (docs/develop/harness.md, "Look scenes"); no pixel is
;; asserted anywhere: the pictures are looked at beside the mockups.
(require 'ert)
(require 'drgnx)
(require 'drgnx-look-scenes (expand-file-name "harness/drgnx-look-scenes" drgnx-dir))
(load (expand-file-name "harness/drgnx-look-scenes-session" drgnx-dir) nil t)

(ert-deftest drgnx-look-scenes/one-scene-per-mockup ()
  "Every mockup the look was approved on has a scene of the same name, and every scene has its setup function."
  (dolist (mockup '(window-dark window-light window-hc palette agent-panel magit))
    (should (assq mockup drgnx-look-scenes)))
  (dolist (scene drgnx-look-scenes)
    (should (fboundp (intern (format "drgnx-look-scene-%s" (car scene)))))))

(ert-deftest drgnx-look-scenes/size-is-the-mockups-window ()
  "The mockups' window is 1440x900 logical pixels: the device size grows with the scale."
  (should (equal (drgnx-look-scenes--size 1) "1440x900"))
  (should (equal (drgnx-look-scenes--size 2) "2880x1800")))

(ert-deftest drgnx-look-scenes/the-project-is-the-mockups ()
  "The mockups' project: drgnx-gateway.el and gateway-test.el modified, jobs-test.el untracked, the lock file
ignored, on main two commits ahead of its remote; drgnx-gateway.el's line 216 is the mockup's, and the shell script has its heredoc."
  (let ((dir (make-temp-file "look-scenes" t)))
    (unwind-protect
        (let* ((proj (drgnx-look-scene-project (expand-file-name "drgnx" dir)))
               (default-directory proj)
               (status (with-temp-buffer (call-process "git" nil t nil "status" "--porcelain" "--ignored")
                                         (buffer-string))))
          (should (string-match-p "^ M core/drgnx-gateway\\.el$" status))
          (should (string-match-p "^ M test/unit/gateway-test\\.el$" status))
          (should (string-match-p "^\\?\\? test/unit/jobs-test\\.el$" status))
          (should (string-match-p "^!! drgnx\\.lock\\.eld$" status))
          (with-temp-buffer
            (insert-file-contents "core/drgnx-gateway.el")
            (forward-line 215)
            (should (equal (buffer-substring (point) (line-end-position)) "      (process-send-string p reply)"))
            (forward-line -15)
            (should (equal (buffer-substring (point) (line-end-position)) ";;;; Replies")))
          (should (string-match-p "<<PY" (with-temp-buffer (insert-file-contents "docs/p2-verify.sh") (buffer-string))))
          (should (string-match-p "\\`## main\\.\\.\\.origin/main \\[ahead 2\\]"
                                  (with-temp-buffer (call-process "git" nil t nil "status" "-sb") (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest drgnx-look-scenes/a-limit-is-named-not-hidden ()
  "What the line cannot show of a mockup is written to the scene's facts."
  (should (assq 'window-dark drgnx-look-scene-limits)))

(ert-deftest drgnx-look-scenes/the-cli-knows-the-command ()
  (require 'drgnx-ui (expand-file-name "harness/drgnx-ui" drgnx-dir))
  (should (string-match-p "look-scenes" drgnx-ui-usage)))

(provide 'look-scenes-test)
;;; look-scenes-test.el ends here
