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

(ert-deftest drgnx-look-scenes/size-is-in-device-pixels ()
  "1500x1000 logical pixels: the device size grows with the scale."
  (should (equal (drgnx-look-scenes--size 1) "1500x1000"))
  (should (equal (drgnx-look-scenes--size 2) "3000x2000"))
  (should (equal (drgnx-look-scenes--size 1.5) "2250x1500")))

(ert-deftest drgnx-look-scenes/the-project-has-the-audits-git-state ()
  "Two files modified, one untracked, the shell script with a heredoc, on branch main."
  (let ((dir (make-temp-file "look-scenes" t)))
    (unwind-protect
        (let* ((proj (drgnx-look-scenes-project dir))
               (default-directory proj)
               (status (with-temp-buffer (call-process "git" nil t nil "status" "--porcelain") (buffer-string))))
          (should (string-match-p "^ M core/drgnx-palette\\.el$" status))
          (should (string-match-p "^ M core/drgnx-palette-frame\\.el$" status))
          (should (string-match-p "^\\?\\? " status))
          (should (string-match-p "<<PY" (with-temp-buffer (insert-file-contents "p2-verify.sh") (buffer-string))))
          (should (equal "main" (string-trim (with-temp-buffer (call-process "git" nil t nil "branch" "--show-current")
                                                               (buffer-string))))))
      (delete-directory dir t))))

(ert-deftest drgnx-look-scenes/the-cli-knows-the-command ()
  (require 'drgnx-ui (expand-file-name "harness/drgnx-ui" drgnx-dir))
  (should (string-match-p "look-scenes" drgnx-ui-usage)))

(provide 'look-scenes-test)
;;; look-scenes-test.el ends here
