;;; drgnx-build.el --- Byte-compile drgnx's own Lisp -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx build' byte-compiles core/, wb/ and modules/ in place (the .elc files are not
;; tracked).  Compiled drgnx is several times faster and makes far less garbage than
;; interpreted drgnx; when Emacs has native compilation, it compiles the .elc files natively
;; in the background as they load.  drgnx's init sets `load-prefer-newer', so a stale .elc
;; never shadows newer source.  install.sh runs the build.  See docs/core.md.

;;; Code:
(require 'bytecomp)
(require 'seq)

(defconst drgnx-build-dirs '("core" "wb" "modules") "What `drgnx build' compiles, under the checkout.")

(defun drgnx-build-files (root)
  "The .el files to compile under ROOT (a checkout)."
  (seq-mapcat (lambda (d) (let ((dir (expand-file-name d root)))
                            (and (file-directory-p dir) (directory-files-recursively dir "\\.el\\'"))))
              drgnx-build-dirs))

(defun drgnx-build (root)
  "Byte-compile drgnx's Lisp under ROOT; return (:compiled N :warnings LIST :errors LIST)."
  (let* ((files (drgnx-build-files root))
         (load-path (append (mapcar (lambda (d) (expand-file-name d root)) '("core" "wb")) load-path))
         (byte-compile-docstring-max-column 120)        ; the project's line length
         (load-prefer-newer t)                           ; a changed dependency, not its old .elc
         (warnings nil) (errors nil) (compiled 0))
    (dolist (f files)
      (let ((byte-compile-log-warning-function
             (lambda (string &optional _position _fill level)
               (push (format "%s: %s" (file-relative-name f root) string)
                     (if (eq level :error) errors warnings))
               t)))
        (condition-case err
            (if (byte-compile-file f) (setq compiled (1+ compiled))
              (push (format "%s: did not compile" (file-relative-name f root)) errors))
          (error (push (format "%s: %s" (file-relative-name f root) (error-message-string err)) errors)))))
    (list :compiled compiled :warnings (nreverse warnings) :errors (nreverse errors))))

(defun drgnx-build-cli ()
  "Batch entry: `drgnx build' — compile the checkout; exit 1 on errors."
  (let* ((root (file-name-directory (directory-file-name (file-name-directory (locate-library "drgnx-build")))))
         (r (drgnx-build root)))
    (dolist (w (plist-get r :warnings)) (princ (format "warning: %s\n" w)))
    (dolist (e (plist-get r :errors)) (princ (format "error: %s\n" e)))
    (princ (format "drgnx build: %d files compiled, %d warnings, %d errors\n" (plist-get r :compiled)
                   (length (plist-get r :warnings)) (length (plist-get r :errors))))
    (kill-emacs (if (plist-get r :errors) 1 0))))

(provide 'drgnx-build)
;;; drgnx-build.el ends here
