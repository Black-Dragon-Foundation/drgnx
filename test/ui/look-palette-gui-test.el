;;; look-palette-gui-test.el --- GUI tests: the echo area on the gap (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det

;; Pattern D: every picture is taken after `drgnx-test-wait-presented'.  The echo area's window is probed at its far
;; right, where no text is: while a message shows, with none, and after a prompt has come and gone (Emacs puts the
;; minibuffer it leaves in `minibuffer-inactive-mode', which resets its buffer-local variables).

(require 'ert)
(require 'cl-lib)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-ui-look-palette--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-look-palette--repo)))
(require 'drgnx)
(require 'drgnx-color)
(load (expand-file-name "themes/drgnx-theme-gen" drgnx-ui-look-palette--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-ui-look-palette--repo) nil t)

(defun drgnx-ui-look-palette--argb (hex)
  "HEX as the (A R G B) a snapshot pixel is."
  (cons 255 (mapcar (lambda (c) (round (* 255 c))) (drgnx-color-rgb hex))))

(defun drgnx-ui-look-palette--echo-pixel ()
  "The pixel of the echo area's window near its right end, half way down (device pixels)."
  (pcase-let* ((w (minibuffer-window)) (s (drgnx-uitest-device-scale (window-frame w)))
               (`(,l ,tp ,r ,b) (mapcar (lambda (e) (round (* s e))) (window-pixel-edges w))))
    (drgnx-uitest-pixel (drgnx-uitest-snapshot) (+ l (floor (* 0.97 (- r l)))) (+ tp (floor (* 0.5 (- b tp)))))))

(ert-deftest drgnx-ui-look-palette/echo-area-on-the-gap ()
  "Pattern D: with the echo area on the gap, the empty part of the echo area's window is the `gap' token under the
dark theme while a message shows, with none, and after a prompt has come and gone."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (delete-other-windows)
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme 'drgnx-dark t)
  (unwind-protect
      (let ((gap (drgnx-ui-look-palette--argb (drgnx-look-token 'gap 'dark)))
            (editor (drgnx-ui-look-palette--argb (drgnx-look-token 'editor 'dark))))
        (should-not (equal gap editor))
        (drgnx-look-echo-area-on)
        (dolist (step '(message empty after-a-prompt))
          (pcase step
            ('message (message "a message"))
            ('empty (message nil))
            ('after-a-prompt
             (let ((unread-command-events (listify-key-sequence (kbd "a RET")))) (read-string "Prompt: "))
             (message nil)))
          (drgnx-test-wait-presented)
          (let ((px (drgnx-ui-look-palette--echo-pixel)) (b (window-buffer (minibuffer-window))))
            (unless (equal gap px)
              (ert-fail (list step 'want gap 'got px 'editor editor 'window-buffer (buffer-name b)
                              'remap (buffer-local-value 'face-remapping-alist b)
                              'echo-remap (mapcar (lambda (n) (and (get-buffer n)
                                                                   (buffer-local-value 'face-remapping-alist (get-buffer n))))
                                                  '(" *Echo Area 0*" " *Echo Area 1*"))))))))
    (drgnx-look-echo-area-off)
    (mapc #'disable-theme custom-enabled-themes)))

(provide 'look-palette-gui-test)
;;; look-palette-gui-test.el ends here
