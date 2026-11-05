;;; work-space-shots-test.el --- the Work space on screen, dark and light: a screenshot set -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The map buffer is drawn from the fixture frame (no hub), shown in the selected window and captured under a dark and
;; a light theme.  The evidence folder (DRGNX_UI_EVIDENCE) keeps the PNGs; run once per display scale (DRGNX_UI_SCALE).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-work-shots--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(add-to-list 'load-path (expand-file-name "core" drgnx-work-shots--repo))
(add-to-list 'load-path (expand-file-name "wb" drgnx-work-shots--repo))
(add-to-list 'load-path (expand-file-name "modules/ui" drgnx-work-shots--repo))
(require 'drgnx)
(require 'drgnx-work-client)
(load (expand-file-name "test/fixtures/work-space-fixture" drgnx-work-shots--repo) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-work-shots--repo) nil t)

(defvar drgnx-work-space--view)
(defvar drgnx-work-map--outline)
(defvar drgnx-view)
(declare-function drgnx-work-map-mode "drgnx-work-map")
(declare-function drgnx-view-attach "drgnx-view")
(declare-function drgnx-view-touch "drgnx-view")
(declare-function drgnx-view-draw-now "drgnx-view")

(defun drgnx-work-shots--shoot (theme name)
  "Load THEME, show the fixture map in the selected window, capture the root frame and keep it as NAME."
  (let* ((id (format "work-shots-%s" name))
         (drgnx-work-client--views (make-hash-table :test #'equal))
         (drgnx-work-client-change-functions '(drgnx-work-map--changed))
         (buf (generate-new-buffer " *work-shots*")))
    (mapc #'disable-theme custom-enabled-themes)
    (load-theme theme t)
    (puthash id (drgnx-work-client--make-view :id id :state (drgnx-work-client-init (drgnx-work-fixture-frame))
                                              :status 'live)
             drgnx-work-client--views)
    (unwind-protect
        (with-current-buffer buf
          (drgnx-work-map-mode)
          (setq drgnx-work-space--view id drgnx-work-map--outline 'off)
          (drgnx-view-attach 'work-map)
          (drgnx-view-touch drgnx-view)
          (switch-to-buffer buf)
          (delete-other-windows)
          (drgnx-view-draw-now drgnx-view)
          (redisplay t)
          (let* ((dir (make-temp-file "work-shots" t))
                 (shot (plist-get (drgnx-uitest-capture dir) :root))
                 (out (expand-file-name (format "work-space-%s.png" name) temporary-file-directory)))
            (should (file-exists-p shot))
            (copy-file shot out t)
            (drgnx-uitest--evidence out)
            (message "work-space screenshot: %s (scale %s)" out (frame-scale-factor))))
      (kill-buffer buf)
      (disable-theme theme))))

(ert-deftest drgnx-work-shots/dark-and-light ()
  (require 'drgnx-modules)
  (drgnx-test-with-modules '(tools/work-space)
    (drgnx-work-shots--shoot 'modus-vivendi (format "dark-s%s" (round (frame-scale-factor))))
    (drgnx-work-shots--shoot 'modus-operandi (format "light-s%s" (round (frame-scale-factor))))))

(provide 'work-space-shots-test)
;;; work-space-shots-test.el ends here
