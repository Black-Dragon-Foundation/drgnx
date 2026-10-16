;;; drgnx-uitest.el --- Drive a drgnx harness session with paced synthetic input -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'cl-lib)

(defun drgnx-uitest-root-frame ()
  "The session's root frame: the first visible frame that is not a child frame."
  (or (cl-find-if (lambda (f) (and (null (frame-parent f)) (frame-visible-p f))) (frame-list))
      (selected-frame)))

(provide 'drgnx-uitest)
;;; drgnx-uitest.el ends here
