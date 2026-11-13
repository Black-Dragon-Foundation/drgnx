;;; packs-gui-test.el --- GUI tests: each language pack's sample, highlighted, in both themes -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Needs grammars the pack job built: DRGNX_PACKS_LIVE_DATA names a folder with data/, config/ and state/ of a
;; `drgnx packs sync' (test/packs/live.sh with DRGNX_PACKS_LIVE_KEEP; test/packs/gui.sh runs both).  Without it the
;; test skips.  Screenshots go to DRGNX_UI_EVIDENCE, one folder name per pack and theme.
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(require 'drgnx-packs)

(defvar drgnx-packs-gui--samples
  '(("kotlin" "Sample.kt") ("swift" "Sample.swift") ("zig" "sample.zig") ("sql" "sample.sql")
    ("php" "sample.php") ("elixir" "sample.ex")))

(defun drgnx-packs-gui--theme (theme)
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme theme t)
  (redisplay t))

(ert-deftest drgnx-packs-gui/every-sample-is-highlighted-in-light-and-dark ()
  (skip-unless (getenv "DRGNX_PACKS_LIVE_DATA"))
  (let* ((data (getenv "DRGNX_PACKS_LIVE_DATA"))
         (process-environment (append (list (concat "DRGNX_DATA_DIR=" data "/data") (concat "DRGNX_CONFIG_DIR=" data "/config")
                                            (concat "XDG_STATE_HOME=" data "/state"))
                                      process-environment)))
    (require 'drgnx-lang-packs (expand-file-name "modules/lang/drgnx-lang-packs" drgnx-dir))
    (should (drgnx-packs-active))
    (drgnx-lang-packs-refresh)
    (dolist (theme '(drgnx-light drgnx-dark))
      (drgnx-packs-gui--theme theme)
      (dolist (s drgnx-packs-gui--samples)
        (let* ((dir (make-temp-file (format "%s-%s-" (car s) theme) t))
               (buf (find-file-noselect (expand-file-name (format "packs/%s/test/samples/%s" (car s) (cadr s)) drgnx-dir))))
          (unwind-protect
              (progn
                (set-window-buffer (selected-window) buf)
                (with-current-buffer buf
                  (font-lock-ensure)
                  (should (> (point-max) 1))
                  ;; highlighted: more than one face run in the text
                  (let ((faces nil) (pos (point-min)))
                    (while (< pos (point-max))
                      (cl-pushnew (get-text-property pos 'face) faces :test #'equal)
                      (setq pos (or (next-single-property-change pos 'face) (point-max))))
                    (should (>= (length (delq nil faces)) 3))))
                (redisplay t)
                (drgnx-test-wait-presented)
                (should (file-exists-p (plist-get (drgnx-uitest-capture dir) :root))))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)
            (delete-directory dir t)))))))

(provide 'packs-gui-test)
;;; packs-gui-test.el ends here
