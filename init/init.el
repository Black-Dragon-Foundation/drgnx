;;; init.el --- drgnx: boot from the checkout -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(let ((checkout (file-name-directory
                 (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))))
  (add-to-list 'load-path (expand-file-name "core" checkout))
  (add-to-list 'load-path (expand-file-name "wb" checkout)))
(require 'drgnx)
(drgnx-init)
(drgnx-session-start-server)    ; not a daemon (whose --daemon=drgnx names its server): `drgnx PATH' still opens here

;;; init.el ends here
