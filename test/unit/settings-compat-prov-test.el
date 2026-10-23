;;; settings-compat-prov-test.el --- compatibility rows C1b, C6, C23: the source drgnx shows -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Rows of the design's §15 matrix that check provenance.  Each runs in a child Emacs under a temp HOME, loading
;; config.el as the start does (`drgnx--load-user-config'), and asserts the row with `drgnx-settings-test-check-row'.

;;; Code:
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defun drgnx-settings-compat-prov--run (forms files &optional env)
  "Run FORMS in a child with FILES (and ENV); the values, or a failure with what the child said."
  (let ((r (drgnx-settings-test-child forms :files files :env env)))
    (unless (and (null (plist-get r :error)) (equal (plist-get r :exit) 0))
      (ert-fail (list :error (plist-get r :error) :output (plist-get r :output))))
    (plist-get r :values)))

(ert-deftest drgnx-settings-compat/c1b-a-setq-of-a-buffer-local-variable-leaves-the-default ()
  ;; R4: a `setq' of `fill-column' in config.el sets only the buffer that was current; the default stays, as in stock
  ;; Emacs, and the explanation names the likely bug (:buffer-local-only).
  (let* ((files '(("settings.el" . "(drgnx-settings :version 1\n (fill-column 90))\n")
                  ("config.el" . ";;; config.el -*- lexical-binding: t -*-\n(setq fill-column 100)\n")))
         (stock (car (drgnx-settings-compat-prov--run
                      '((progn (load (expand-file-name "config.el" (getenv "DRGNX_CONFIG_DIR")) nil t t)
                               (with-temp-buffer (drgnx-settings-test-answer 'fill-column))))
                      files '("DRGNX_SETTINGS_TEST_STOCK=1")))))
    (should (equal (car stock) 70))
    (should (equal (drgnx-settings-compat-prov--run
                    `((progn (drgnx--load-user-config) t)
                      (with-temp-buffer
                        (drgnx-settings-test-check-row 'fill-column :value 70 :source "default" :stock-equal ',stock))
                      (with-temp-buffer (plist-get (drgnx-settings-explain 'fill-column) :buffer-local-only)))
                    files)
                   '(t t t)))))

(ert-deftest drgnx-settings-compat/c6-a-deferred-setq-is-your-lisp-first-seen-during ()
  ;; use-package :config (deferred) and with-eval-after-load: your value when the package loads, "deferred, first
  ;; seen during" the require, with the body's own line from the static index (V1).
  (should (equal (drgnx-settings-compat-prov--run
                  '((progn (push (expand-file-name "lisp" (getenv "HOME")) load-path) t)
                    (progn (drgnx--load-user-config) t)
                    (drgnx-settings-test-check-row
                     'q-six-a :value 3
                     :source "your Lisp (config.el:4), deferred, first seen during config.el:8")
                    (drgnx-settings-test-check-row
                     'q-six-b :value 4
                     :source "your Lisp (config.el:6), deferred, first seen during config.el:8"))
                  '(("settings.el" . "(drgnx-settings :version 1\n (q-six-a 0)\n (q-six-b 0))\n")
                    ("config.el" . ";;; config.el -*- lexical-binding: t -*-
(require 'use-package)
(use-package q-six :defer t
  :config (setq q-six-a 3))
(with-eval-after-load 'q-six
  (setq q-six-b 4))

(require 'q-six)
")
                    ("~/lisp/q-six.el" . ";;; q-six.el -*- lexical-binding: t -*-
(defvar q-six-a 1)
(defvar q-six-b 1)
(provide 'q-six)
")))
                 '(t t t t))))

(ert-deftest drgnx-settings-compat/c23-a-setq-after-a-nested-load-is-the-outer-file ()
  ;; A nested `load' in config.el and a `setq' after it in the same form: recorded at the outer file (V1).
  (should (equal (drgnx-settings-compat-prov--run
                  '((progn (defvar q-23 0) (drgnx--load-user-config) t)
                    (drgnx-settings-test-check-row 'q-23 :value 2 :source "your Lisp (config.el:3)")
                    (let ((r (car (drgnx-settings-prov 'q-23))))
                      (list (file-name-nondirectory (plist-get r :file)) (plist-get r :line))))
                  '(("settings.el" . "(drgnx-settings :version 1\n (q-23 0))\n")
                    ("config.el" . ";;; config.el -*- lexical-binding: t -*-
(progn (load (expand-file-name \"q-23-inner.el\" (file-name-directory load-file-name)) nil t t)
       (setq q-23 2))
")
                    ("q-23-inner.el" . ";;; q-23-inner.el -*- lexical-binding: t -*-\n(setq q-23 1)\n")))
                 '(t t ("config.el" 2)))))

(provide 'settings-compat-prov-test)
;;; settings-compat-prov-test.el ends here
