;;; packs-gui-test.el --- GUI tests: each language pack's sample, highlighted, in both themes -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Needs grammars the pack job built: the file test/ui/.packs-live-data names a folder with data/, config/ and state/ of a
;; `drgnx packs sync' (test/packs/live.sh with DRGNX_PACKS_LIVE_KEEP; test/packs/gui.sh runs both).  Without it the
;; test skips.  Screenshots go to DRGNX_UI_EVIDENCE, one folder name per pack and theme.
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)
(defvar drgnx-dir)
(defvar treesit-extra-load-path)
(defconst drgnx-packs-gui--root (expand-file-name "../.." (file-name-directory (macroexp-file-name))) "The checkout.")
(unless (boundp 'drgnx-dir) (setq drgnx-dir (file-name-as-directory drgnx-packs-gui--root)))   ; the minimal session has no drgnx loaded
(dolist (d '("core" "wb" "modules/lang")) (add-to-list 'load-path (expand-file-name d drgnx-packs-gui--root)))
(require 'drgnx-packs)

(defconst drgnx-packs-gui--marker (expand-file-name ".packs-live-data" (file-name-directory (macroexp-file-name)))
  "A file holding the folder of the built data (test/packs/gui.sh writes it; the session has no environment of its own).")

(defconst drgnx-packs-gui--evidence (expand-file-name ".packs-live-evidence" (file-name-directory (macroexp-file-name)))
  "A file holding the folder the pictures are copied to, when it exists (the session has no environment of its own).")

(defvar drgnx-packs-gui--samples
  '(("kotlin" "Sample.kt" drgnx-pack-ts-mode) ("swift" "Sample.swift" drgnx-pack-ts-mode)
    ("zig" "sample.zig" drgnx-pack-ts-mode) ("sql" "sample.sql" drgnx-pack-ts-mode)
    ("php" "sample.php" php-ts-mode) ("elixir" "sample.ex" elixir-ts-mode))
  "Pack, sample file and the mode the module gives it (the module itself is tested in batch: mod-lang-packs-test.el).")

(add-to-list 'custom-theme-load-path (expand-file-name "themes" drgnx-packs-gui--root))
(defun drgnx-packs-gui--theme (theme)
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme theme t)
  (redisplay t))

(ert-deftest drgnx-packs-gui/every-sample-is-highlighted-in-light-and-dark ()
  (skip-unless (file-exists-p drgnx-packs-gui--marker))
  (let* ((data (string-trim (with-temp-buffer (insert-file-contents drgnx-packs-gui--marker) (buffer-string))))
         (process-environment (append (list (concat "DRGNX_DATA_DIR=" data "/data") (concat "DRGNX_CONFIG_DIR=" data "/config")
                                            (concat "XDG_STATE_HOME=" data "/state"))
                                      process-environment)))
    (require 'drgnx-lang-packs (expand-file-name "modules/lang/drgnx-lang-packs" drgnx-packs-gui--root))
    (should (drgnx-packs-active))
    (dolist (p (plist-get (drgnx-packs-active) :packs))   ; what lang/packs puts on the load path
      (dolist (g (plist-get (cdr p) :grammars)) (add-to-list 'treesit-extra-load-path (cdr g))))
    (dolist (theme '(drgnx-light drgnx-dark))
      (drgnx-packs-gui--theme theme)
      (dolist (s drgnx-packs-gui--samples)
        (let* ((dir (make-temp-file (format "%s-%s-" (car s) theme) t))
               (buf (find-file-noselect (expand-file-name (format "packs/%s/test/samples/%s" (car s) (cadr s)) drgnx-packs-gui--root))))
          (unwind-protect
              (progn
                (set-window-buffer (selected-window) buf)
                (with-current-buffer buf
                  (funcall (nth 2 s))
                  (font-lock-mode 1)
                  (font-lock-ensure)
                  (should (> (point-max) 1))
                  ;; highlighted: more than one face run in the text
                  (let ((faces nil) (pos (point-min)))
                    (while (< pos (point-max))
                      (cl-pushnew (get-text-property pos 'face) faces :test #'equal)
                      (setq pos (or (next-single-property-change pos 'face) (point-max))))
                    (unless (>= (length (delq nil faces)) 3)
                      (error "%s %s: mode %s, faces %S, grammar ready %S, packs %S, auto-mode %S, entries %S, table %S, translated %S" (car s) theme major-mode faces
                             (ignore-errors (treesit-language-available-p (intern (car s))))
                             (mapcar #'car (plist-get (drgnx-packs-active) :packs)) (buffer-file-name)
                             (seq-filter (lambda (e) (memq (cdr e) '(drgnx-pack-ts-mode python-ts-mode))) auto-mode-alist)
                             (mapcar #'car drgnx-modules--table)
                             (mapcar (lambda (p) (let ((f (plist-get (cdr p) :translated))) (and f (file-exists-p f)))) (plist-get (drgnx-packs-active) :packs))))))
                (redisplay t)
                (drgnx-test-wait-presented)
                (let ((root (plist-get (drgnx-uitest-capture dir) :root)))
                  (should (file-exists-p root))
                  ;; the evidence folder (test/packs/gui.sh): one picture per pack and theme
                  (when (file-exists-p drgnx-packs-gui--evidence)
                    (let ((out (string-trim (with-temp-buffer (insert-file-contents drgnx-packs-gui--evidence) (buffer-string)))))
                      (when (file-directory-p out)
                        (copy-file root (expand-file-name (format "%s-%s.png" (car s) theme) out) t))))))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)
            (delete-directory dir t)))))))

(provide 'packs-gui-test)
;;; packs-gui-test.el ends here
