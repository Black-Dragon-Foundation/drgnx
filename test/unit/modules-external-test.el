;;; modules-external-test.el --- batch tests: the switch an external module reads -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-modules)

(defmacro drgnx-modules-ext-test--with-module (feature-source &rest body)
  "Run BODY with an external module `kx' whose one feature `kx-feat' has FEATURE-SOURCE; DIR is its directory."
  (declare (indent 1))
  `(let* ((cfg (make-temp-file "drgnx-cfg" t)) (st (make-temp-file "drgnx-st" t))
          (dir (make-temp-file "drgnx-ext" t))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" cfg) (concat "XDG_STATE_HOME=" st))
                                       process-environment))
          (drgnx-modules--table nil) (drgnx-modules--report nil)
          (load-path load-path))
     (unwind-protect
         (progn
           (write-region ,feature-source nil (expand-file-name "kx-feat.el" dir) nil 'silent)
           (drgnx-modules-update-state (lambda (_) `(:external ((:name kx :path ,dir :features (kx-feat))))))
           ,@body)
       (when (featurep 'kx-feat) (unload-feature 'kx-feat t))
       (delete-directory cfg t) (delete-directory st t) (delete-directory dir t))))

(ert-deftest drgnx-modules-external/the-flag-is-t-while-the-feature-loads-and-nil-after ()
  (defvar kx-saw 'unset)
  (drgnx-modules-ext-test--with-module "(setq kx-saw (list 'during (bound-and-true-p drgnx-loading-external)))\n(provide 'kx-feat)\n"
    (setq kx-saw 'unset)
    (should-not (bound-and-true-p drgnx-loading-external))
    (drgnx-modules-load-external)
    (should (equal kx-saw '(during t)))
    (should-not (bound-and-true-p drgnx-loading-external))
    (should (eq (plist-get (alist-get 'external/kx/kx-feat (drgnx-modules-report)) :status) 'ok))))

(ert-deftest drgnx-modules-external/the-flag-is-nil-again-after-a-failing-feature ()
  (drgnx-modules-ext-test--with-module "(error \"kaputt\")\n"
    (drgnx-modules-load-external)
    (should (eq (plist-get (alist-get 'external/kx/kx-feat (drgnx-modules-report)) :status) 'failed))
    (should-not (bound-and-true-p drgnx-loading-external))))

(ert-deftest drgnx-modules-external/a-fixture-that-sets-a-global-key-skips-it-under-the-flag ()
  (let ((src "(unless (bound-and-true-p drgnx-loading-external) (global-set-key (kbd \"C-c M-q\") 'ignore))\n(provide 'kx-feat)\n")
        (map (copy-keymap global-map)))
    (drgnx-modules-ext-test--with-module src
      (let ((orig (current-global-map)))
        (use-global-map map)
        (unwind-protect
            (progn
              (drgnx-modules-load-external)
              (should-not (lookup-key map (kbd "C-c M-q")))   ; skipped: the profiles own the keys
              ;; control: the same file loaded outside the external load does bind it
              (load (expand-file-name "kx-feat.el" dir) nil t)
              (should (eq (lookup-key map (kbd "C-c M-q")) 'ignore)))
          (use-global-map orig))))))

;;; modules-external-test.el ends here
