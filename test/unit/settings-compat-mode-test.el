;;; settings-compat-mode-test.el --- compatibility rows C12 and C21: language overrides in a child Emacs -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Each row runs in a child Emacs under a temp HOME.  The explained-winner check of `drgnx-settings-test-check-row'
;; needs Task 11's `drgnx-settings-explain', so these rows assert the values and states directly until it is merged.

;;; Code:
(require 'ert)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defconst drgnx-settings-compat-mode--files
  '(("settings.el" . "(drgnx-settings :version 1
 (:mode text-mode (fill-column 66) (drgnx-c12-var 5) (drgnx-c21-three 8) (drgnx-c21-two 9)))\n")))

(defconst drgnx-settings-compat-mode--setup
  '(progn
     (require 'drgnx-settings-mode)
     (defvar drgnx-c12-var 0)
     (defvar drgnx-c21-three 0)
     (defvar drgnx-c21-two 0)
     (defvar drgnx-c21-log nil)
     (put 'drgnx-c21-three 'custom-set
          (lambda (s v &optional where) (push (list s where) drgnx-c21-log) (set (make-local-variable s) v)))
     (put 'drgnx-c21-two 'custom-set (lambda (s v) (push (list s 'two) drgnx-c21-log) (set-default s v)))
     t))

(ert-deftest drgnx-settings-compat/c12-packages-read-their-variables-as-stock ()
  ;; symbol-value in the buffer, default-value untouched, mode hooks beat L1 (dir-locals beat both: the
  ;; settings-mode/dir-locals-win test).
  (let ((r (drgnx-settings-test-child
            (list drgnx-settings-compat-mode--setup
                  '(with-temp-buffer (text-mode) (list fill-column drgnx-c12-var (default-value 'drgnx-c12-var)))
                  '(let ((text-mode-hook (list (lambda () (setq-local fill-column 77)))))
                     (with-temp-buffer (text-mode) fill-column)))
            :files drgnx-settings-compat-mode--files)))
    (should-not (plist-get r :error))
    (should (equal (nth 1 (plist-get r :values)) '(66 5 0)))
    (should (equal (nth 2 (plist-get r :values)) 77))))

(ert-deftest drgnx-settings-compat/c21-buffer-local-setters ()
  ;; three arguments: the setter runs with buffer-local; two: setq-local, the buffer opens, no error.
  (let ((r (drgnx-settings-test-child
            (list drgnx-settings-compat-mode--setup
                  '(with-temp-buffer (text-mode)
                                     (list drgnx-c21-three drgnx-c21-two (local-variable-p 'drgnx-c21-two)
                                           (default-value 'drgnx-c21-two) drgnx-c21-log)))
            :files drgnx-settings-compat-mode--files)))
    (should-not (plist-get r :error))
    (should (equal (nth 1 (plist-get r :values)) '(8 9 t 0 ((drgnx-c21-three buffer-local)))))))

(provide 'settings-compat-mode-test)
;;; settings-compat-mode-test.el ends here
