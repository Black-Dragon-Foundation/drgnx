;;; settings-mode-test.el --- batch tests: per-language overrides (L1) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Every test writes its settings.el under `drgnx-test-with-config' (a temp config folder); nothing touches ~.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-settings-mode)

(defvar drgnx-t10-seen nil "What the test setters and hooks saw.")
(defvar drgnx-t10-var 0 "A plain variable the overrides set.")
(defvar drgnx-t10-three 0 "A variable whose :set takes three arguments.")
(defvar drgnx-t10-bad 0 "A variable whose three-argument :set fails.")
(defvar drgnx-t10-unloaded 0 "A variable whose package is not loaded.")
(defvar drgnx-t10-after-hook nil "What `drgnx-t10-mode-hook' saw.")

(define-derived-mode drgnx-t10-mode text-mode "T10")

(defun drgnx-t10-three-set (sym value &optional where)
  "A setter taking three arguments."
  (push (list sym value where) drgnx-t10-seen)
  (set (make-local-variable sym) value))

(defun drgnx-t10-bad-set (_sym _value &optional _where)
  "A setter that fails."
  (error "boom"))

(put 'drgnx-t10-three 'custom-set #'drgnx-t10-three-set)
(put 'drgnx-t10-bad 'custom-set #'drgnx-t10-bad-set)

(defmacro drgnx-t10-with (text &rest body)
  "BODY with settings.el holding TEXT in a temp config folder."
  (declare (indent 1))
  `(drgnx-test-with-config
     (let ((drgnx-settings-mode--cache nil) (drgnx-settings-mode--problems nil) (drgnx-t10-seen nil))
       (make-directory (drgnx-user-dir) t)
       (write-region ,text nil (drgnx-config-file 'settings) nil 'silent)
       ,@body)))

(defmacro drgnx-t10-in-buffer (&rest body)
  "BODY in a fresh buffer with a plain name (a temp buffer's leading space gets no overrides), killed after."
  (declare (indent 0))
  `(let ((b (generate-new-buffer "drgnx-t10")))
     (unwind-protect (with-current-buffer b ,@body) (kill-buffer b))))

(defconst drgnx-t10-text
  "(drgnx-settings :version 1
 (:mode drgnx-t10-mode (fill-column 33) (drgnx-t10-var 7)))\n")

(ert-deftest drgnx-settings-mode/applies-before-mode-hooks ()
  (drgnx-t10-with drgnx-t10-text
    (let ((drgnx-t10-mode-hook (list (lambda () (setq drgnx-t10-after-hook fill-column)))))
      (drgnx-t10-in-buffer
        (drgnx-t10-mode)
        (should (= drgnx-t10-after-hook 33))
        (should (= fill-column 33))
        (should (= drgnx-t10-var 7))
        (should (local-variable-p 'drgnx-t10-var))
        (should (= (default-value 'drgnx-t10-var) 0))
        (should (equal (drgnx-settings-mode-entries 'drgnx-t10-mode) '((fill-column . 33) (drgnx-t10-var . 7))))))))

(ert-deftest drgnx-settings-mode/mode-hooks-win ()
  (drgnx-t10-with drgnx-t10-text
    (let ((drgnx-t10-mode-hook (list (lambda () (setq-local fill-column 44)))))
      (drgnx-t10-in-buffer
        (drgnx-t10-mode)
        (should (= fill-column 44))))))

(ert-deftest drgnx-settings-mode/dir-locals-win ()
  (drgnx-t10-with drgnx-t10-text
    (let* ((dir (file-name-as-directory (make-temp-file "drgnx-t10" t)))
           (file (expand-file-name "x.t10" dir))
           (auto-mode-alist (cons '("\\.t10\\'" . drgnx-t10-mode) auto-mode-alist))
           buf)
      (unwind-protect
          (progn
            (write-region "((nil . ((fill-column . 55))))" nil (expand-file-name ".dir-locals.el" dir) nil 'silent)
            (write-region "hi" nil file nil 'silent)
            (setq buf (find-file-noselect file))
            (with-current-buffer buf
              (should (eq major-mode 'drgnx-t10-mode))
              (should (= fill-column 55))
              (should (= drgnx-t10-var 7))))
        (when buf (kill-buffer buf))
        (delete-directory dir t)))))

(ert-deftest drgnx-settings-mode/a-failing-setter-still-opens-the-buffer ()
  (drgnx-t10-with "(drgnx-settings :version 1
 (:mode drgnx-t10-mode (drgnx-t10-bad 1) (fill-column 33)))\n"
    (let (messages)
      (cl-letf (((symbol-function 'message) (lambda (f &rest a) (push (apply #'format f a) messages))))
        (dotimes (_ 2)
          (drgnx-t10-in-buffer
            (drgnx-t10-mode)
            (should (eq major-mode 'drgnx-t10-mode))
            (should (= fill-column 33))))
        (should (= (length messages) 1))
        (should (string-match-p "drgnx-t10-bad" (car messages)))))))

(ert-deftest drgnx-settings-mode/nothing-loads-at-mode-time ()
  (drgnx-t10-with "(drgnx-settings :version 1
 (:mode drgnx-t10-mode (drgnx-t10-unloaded 9)))\n"
    (let (loads)
      (put 'drgnx-t10-unloaded 'custom-loads '("drgnx-t10-no-such-package"))
      (put 'drgnx-t10-unloaded 'custom-autoload t)
      (let ((load-fn (lambda (&rest a) (push a loads))))
        (advice-add 'load :before load-fn)
        (advice-add 'require :before load-fn)
        (unwind-protect
            (drgnx-t10-in-buffer
              (drgnx-t10-mode)
              (should (= drgnx-t10-unloaded 9))
              (should (local-variable-p 'drgnx-t10-unloaded)))
          (advice-remove 'load load-fn)
          (advice-remove 'require load-fn)))
      (should-not (cl-find "drgnx-t10-no-such-package" loads :key (lambda (a) (format "%s" (car a))) :test #'equal)))))

(ert-deftest drgnx-settings-mode/three-argument-setter-gets-buffer-local ()
  (drgnx-t10-with "(drgnx-settings :version 1
 (:mode drgnx-t10-mode (drgnx-t10-three 5)))\n"
    (drgnx-t10-in-buffer
      (drgnx-t10-mode)
      (should (equal drgnx-t10-seen '((drgnx-t10-three 5 buffer-local))))
      (should (= drgnx-t10-three 5)))))

(ert-deftest drgnx-settings-mode/parent-modes-apply-first ()
  (drgnx-t10-with "(drgnx-settings :version 1
 (:mode drgnx-t10-mode (fill-column 33))
 (:mode text-mode (fill-column 22) (drgnx-t10-var 3)))\n"
    (drgnx-t10-in-buffer
      (drgnx-t10-mode)
      (should (= fill-column 33))
      (should (= drgnx-t10-var 3)))))

(ert-deftest drgnx-settings-mode/own-only-in-safe-mode-and-with-package-settings-off ()
  ;; US-LANG-SAFE-MODE-1: safe mode and Turn Off Package Settings apply only drgnx's own settings' overrides
  (drgnx-t10-with drgnx-t10-text
    (let ((drgnx-setting--names (cons 'drgnx-t10-var drgnx-setting--names)))   ; drgnx-t10-var plays an own setting
      (let ((process-environment (cons "DRGNX_SAFE=1" process-environment)))
        (drgnx-t10-in-buffer
          (drgnx-t10-mode)
          (should (= drgnx-t10-var 7))
          (should (= fill-column (default-value 'fill-column)))))
      (let ((drgnx-settings-package-settings-off t))
        (drgnx-t10-in-buffer
          (drgnx-t10-mode)
          (should (= drgnx-t10-var 7))
          (should (= fill-column (default-value 'fill-column)))))
      (drgnx-t10-in-buffer                 ; turned on again: every override
        (drgnx-t10-mode)
        (should (= fill-column 33))))))

(ert-deftest drgnx-settings-mode/temp-buffers-get-no-overrides ()
  (drgnx-t10-with drgnx-t10-text
    (with-temp-buffer
      (drgnx-t10-mode)
      (should (= fill-column (default-value 'fill-column)))
      (should-not (local-variable-p 'drgnx-t10-var)))))

(ert-deftest drgnx-settings-mode/the-stamp-is-checked-once-per-command ()
  ;; interactive: settings.el's stamp is looked at once per command (`num-input-keys'), not per mode change
  (drgnx-t10-with drgnx-t10-text
    (let ((stamps 0) (noninteractive nil) (num-input-keys 100) (drgnx-settings-mode--tick nil)
          (real (symbol-function 'drgnx-file-stamp)))
      (cl-letf (((symbol-function 'drgnx-file-stamp) (lambda (f)
                                                       (when (equal f (drgnx-config-file 'settings)) (cl-incf stamps))
                                                       (funcall real f))))
        (drgnx-t10-in-buffer (drgnx-t10-mode) (should (= fill-column 33)))   ; the first read (the reader stamps too)
        (let ((first stamps))
          (should (> first 0))
          (dotimes (_ 2) (drgnx-t10-in-buffer (drgnx-t10-mode) (should (= fill-column 33))))
          (should (= stamps first))                                           ; the same command: no look at the disk
          (setq num-input-keys 101)
          (drgnx-t10-in-buffer (drgnx-t10-mode))
          (should (= stamps (1+ first))))))))                                 ; the next one: one stamp, no re-read

(provide 'settings-mode-test)
;;; settings-mode-test.el ends here
