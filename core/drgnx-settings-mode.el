;;; drgnx-settings-mode.el --- Settings: per-language overrides -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The `(:mode MODE …)' entries of settings.el (layer L1), set in a buffer from `change-major-mode-after-body-hook':
;; after the mode's own set-up and before your mode hooks, the workspace file and `.dir-locals.el'.  An entry never
;; breaks opening a buffer (one problem per variable per session) and nothing is loaded at mode time.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-config)
(require 'drgnx-file)
(require 'drgnx-settings-file)
(require 'drgnx-setting)
(require 'drgnx-settings-apply)

(defvar drgnx-settings-explain-functions)

(defvar drgnx-settings-mode--cache nil
  "(STAMP . ENTRIES) of the global settings.el last read: ENTRIES is an alist (MODE . ((VAR VALUE LINE)…)).")

(defvar drgnx-settings-mode--problems nil
  "Alist (VAR . TEXT): the one problem said per variable this session.")

(defun drgnx-settings-mode--table ()
  "The `(:mode …)' entries of the global settings.el as an alist (MODE . ((VAR VALUE LINE)…)), cached per stamp."
  (let* ((file (drgnx-config-file 'settings))
         (stamp (cons file (drgnx-file-stamp file))))
    (unless (equal (car drgnx-settings-mode--cache) stamp)
      (let (table)
        (dolist (e (drgnx-settings-doc-entries (drgnx-settings-file-read file 'drgnx-settings)))
          (let ((scope (drgnx-settings-entry-scope e)))
            (when (and (consp scope) (null (cdr scope)) (eq (caar scope) :mode))
              (let* ((mode (cdar scope)) (cell (assq mode table))
                     (item (list (drgnx-settings-entry-var e) (drgnx-settings-entry-value e)
                                 (drgnx-settings-entry-line e))))
                (if cell (setcdr cell (append (cdr cell) (list item))) (push (list mode item) table))))))
        (setq drgnx-settings-mode--cache (cons stamp table))))
    (cdr drgnx-settings-mode--cache)))

(defun drgnx-settings-mode-entries (mode)
  "The language overrides of settings.el for MODE: an alist (VAR . VALUE), in file order.
Cached per settings.el stamp; one `assq' per call once cached."
  (mapcar (lambda (i) (cons (car i) (cadr i))) (cdr (assq mode (drgnx-settings-mode--table)))))

(defun drgnx-settings-mode--modes ()
  "The current buffer's major mode and its parents, the most general first."
  (reverse (or (and (fboundp 'derived-mode-all-parents) (derived-mode-all-parents major-mode))
               (list major-mode))))

(defun drgnx-settings-mode--three-arg-p (fn)
  "Non-nil when setter FN is loaded and accepts three arguments."
  (and fn (not (autoloadp (indirect-function fn)))
       (let ((arity (func-arity fn)))
         (and (<= (car arity) 3) (or (eq (cdr arity) 'many) (>= (cdr arity) 3))))))

(defun drgnx-settings-mode--set (var value)
  "Give VAR the buffer-local VALUE in the current buffer: its `:set' with `buffer-local' when that takes three
arguments, else `setq-local'.  Never `setopt-local'; nothing is loaded."
  (let ((setter (and (symbolp var) (get var 'custom-set))))
    (if (drgnx-settings-mode--three-arg-p setter)
        (funcall setter var value 'buffer-local)
      (set (make-local-variable var) value))))

(defun drgnx-settings-mode--problem (var err)
  "Say ERR for VAR once this session."
  (unless (assq var drgnx-settings-mode--problems)
    (let ((text (format "settings.el: the language override of %s failed: %s" var (error-message-string err))))
      (push (cons var text) drgnx-settings-mode--problems)
      (message "%s" text))))

(defun drgnx-settings-mode--apply-mode-overrides ()
  "Set the current buffer's language overrides.  Run on `change-major-mode-after-body-hook'; never signals.
In safe mode and while package settings are off (`drgnx-settings-own-only-p'), only drgnx's own settings' overrides
apply; a buffer opened before Turn Off keeps the values it got."
  (condition-case err
      (let ((own-only (drgnx-settings-own-only-p)))
        (dolist (mode (drgnx-settings-mode--modes))
          (dolist (item (cdr (assq mode (drgnx-settings-mode--table))))
            (when (or (not own-only) (drgnx-setting-own-p (car item)))
              (condition-case err
                  (drgnx-settings-mode--set (car item) (copy-tree (cadr item)))
                (error (drgnx-settings-mode--problem (car item) err)))))))
    (error (drgnx-settings-mode--problem 'settings.el err))))

(defalias 'drgnx-settings--apply-mode-overrides #'drgnx-settings-mode--apply-mode-overrides)

(defun drgnx-settings-mode--layers (var buffer)
  "The L1 layers of VAR in BUFFER: a list of plists (:layer L1 :mode M :value V :file F :line N :source TEXT)."
  (with-current-buffer buffer
    (let (layers)
      (dolist (mode (drgnx-settings-mode--modes))
        (when-let* ((item (assq var (cdr (assq mode (drgnx-settings-mode--table))))))
          (let ((file (drgnx-config-file 'settings)))
            (push (list :layer 'L1 :mode mode :value (cadr item) :file file :line (nth 2 item)
                        :source (format "Settings (%s:%s, %s)" (file-name-nondirectory file) (nth 2 item) mode))
                  layers))))
      layers)))

(add-hook 'change-major-mode-after-body-hook #'drgnx-settings-mode--apply-mode-overrides)
(add-hook 'drgnx-settings-explain-functions #'drgnx-settings-mode--layers)

(provide 'drgnx-settings-mode)
;;; drgnx-settings-mode.el ends here
