;;; look-palette-test.el --- the palette: recent commands first, keycaps from the profile, the echo area on the gap -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the recent-command history runs on the manual clock with the state directory in a temporary
;; folder; keycaps are a function of a key string; the echo-area remap is read from the buffers' remapping lists.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-palette)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)

(defmacro drgnx-look-palette-test--with-state (&rest body)
  "BODY with the state directory in a temporary folder and no history read yet."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "look-palette" t)))
          (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
          (drgnx-palette--history :unloaded))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(ert-deftest drgnx-look-palette/recent-first ()
  "Pattern D, on the manual clock: the command used last ranks first, with its age as text; the history is kept in
the state directory and read back."
  (drgnx-look-palette-test--with-state
    (drgnx-test-with-clock ()
      (drgnx-palette-record 'a)
      (drgnx-test-advance 60)
      (drgnx-palette-record 'b)
      (drgnx-test-advance 120)
      (unless (eql 0 (drgnx-palette-recent-rank 'b))
        (ert-fail (list 'in-memory drgnx-palette--history)))
      (should (= 0 (drgnx-palette-recent-rank 'b)))
      (should (= 1 (drgnx-palette-recent-rank 'a)))
      (should-not (drgnx-palette-recent-rank 'never))
      (should (equal "used 2 min ago" (drgnx-palette-recent-age 'b)))
      (should (equal "used 3 min ago" (drgnx-palette-recent-age 'a)))
      (should-not (drgnx-palette-recent-age 'never))
      (setq drgnx-palette--history :unloaded)                         ; read back from the file
      (unless (eql 0 (drgnx-palette-recent-rank 'b))
        (ert-fail (list 'read-back drgnx-palette--history (drgnx-palette--history-file)
                        (file-exists-p (drgnx-palette--history-file)))))
      (should (= 0 (drgnx-palette-recent-rank 'b)))
      (should (equal '("Y: B" "X: A" "Z: C")
                     (drgnx-palette-sort '("X: A" "Y: B" "Z: C") '(("X: A" . a) ("Y: B" . b) ("Z: C" . c))))))))

(ert-deftest drgnx-look-palette/keycaps-from-the-profile ()
  "Pattern D: the palette's own key in each profile, as keycaps: Ctrl Shift P for vscode and Emacs, Space Space for
Vim; a chord is one cap a key, a function key its number."
  (unless drgnx-keys-profiles
    (setq drgnx-keys-profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
  (let ((first-key (lambda (p) (seq-find #'stringp (cdr (assq 'palette (plist-get (alist-get p drgnx-keys-profiles) :bind)))))))
    (should (equal '("Ctrl" "Shift" "P") (drgnx-palette-keycap-names (funcall first-key 'vscode))))
    (should (equal '("Ctrl" "Shift" "P") (drgnx-palette-keycap-names (funcall first-key 'emacs))))
    (should (equal '("Space" "Space") (drgnx-palette-keycap-names (funcall first-key 'vim)))))
  (should (equal '("F1") (drgnx-palette-keycap-names "<f1>")))
  (should (equal '("Alt" "X") (drgnx-palette-keycap-names "M-x")))
  (should (equal '("Space" "F" "F") (drgnx-palette-keycap-names "SPC f f")))
  (let ((caps (drgnx-palette-keycaps "C-S-p")))
    (should (equal "Ctrl Shift P" (substring-no-properties caps)))
    (should (eq 'drgnx-keycap (get-text-property 0 'face caps)))))

(ert-deftest drgnx-look-palette/echo-area-remap-on-and-off ()
  "Pattern D: the echo area's buffer and every minibuffer draw `default' as the gap surface while the module is on;
off, the buffers have no such entry and the hook is gone."
  (let ((echo (get-buffer-create " *Echo Area 0*")) (mini (get-buffer-create " *Minibuf-look-test*")))
    (unwind-protect
        (progn
          (drgnx-look-echo-area-on)
          (should (memq 'drgnx-look--minibuffer-gap minibuffer-setup-hook))
          (with-current-buffer echo (should (eq 'drgnx-surface-gap (cadr (assq 'default face-remapping-alist)))))
          (with-current-buffer mini (drgnx-look--minibuffer-gap)
                               (should (eq 'drgnx-surface-gap (cadr (assq 'default face-remapping-alist)))))
          (drgnx-look-echo-area-off)
          (should-not (memq 'drgnx-look--minibuffer-gap minibuffer-setup-hook))
          (with-current-buffer echo (should-not (assq 'default face-remapping-alist))))
      (drgnx-look-echo-area-off)
      (kill-buffer mini))))

(provide 'look-palette-test)
;;; look-palette-test.el ends here
