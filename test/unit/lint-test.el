;;; lint-test.el --- lints over drgnx's own code: colours, keys, faces -*- lexical-binding: t -*-
;; The forms are read with the Lisp reader, so comments never count; docstrings are strings
;; like any other and are checked only for hex colours.
(require 'ert)
(require 'seq)
(require 'drgnx-paths)

(defun drgnx-lint--files (&rest dirs)
  (seq-mapcat (lambda (d) (directory-files-recursively (expand-file-name d drgnx-dir) "\\.el\\'")) dirs))

(defun drgnx-lint--forms (file)
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil (while t (push (read (current-buffer)) forms)) (end-of-file nil))
      (nreverse forms))))

(defun drgnx-lint--walk (form fn)
  "Call FN on FORM and every list and atom inside it."
  (funcall fn form)
  (cond ((consp form)
         (let ((x form))
           (while (consp x) (drgnx-lint--walk (car x) fn) (setq x (cdr x)))
           (when x (drgnx-lint--walk x fn))))
        ((and (vectorp form) (not (stringp form))) (mapc (lambda (e) (drgnx-lint--walk e fn)) form))))

(defun drgnx-lint--violations (files check)
  "Run CHECK (FORM → message or nil) over every form of FILES; return \"file: message\" strings."
  (let (out)
    (dolist (f files)
      (dolist (top (drgnx-lint--forms f))
        (drgnx-lint--walk top (lambda (form) (when-let* ((m (funcall check form)))
                                               (push (format "%s: %s" (file-relative-name f drgnx-dir) m) out))))))
    (nreverse out)))

(defconst drgnx-lint--hex "\\`#\\([0-9a-fA-F]\\{3\\}\\)\\{1,2\\}\\'")

(ert-deftest drgnx-lint/no-hard-coded-colours ()
  ;; Faces inherit theme faces: a hex colour, or a colour name after :foreground/:background, is a bug.
  (should-not
   (drgnx-lint--violations
    (drgnx-lint--files "core" "wb" "modules")
    (lambda (form)
      (cond ((and (stringp form) (string-match-p drgnx-lint--hex form)) (format "hex colour %s" form))
            ((and (consp form) (proper-list-p form))
             (cl-loop for (k v) on form
                      when (and (memq k '(:foreground :background :color :distant-foreground)) (stringp v))
                      return (format "%s %S" k v))))))))

(defun drgnx-lint--keyboard-key-p (key)
  "KEY (a string, `kbd' form or vector) is a keyboard key — not a mouse, header-line, tab-line or remap event."
  (let ((k (pcase key
             (`(kbd ,s) s)
             ((pred stringp) key)
             ((pred vectorp) key))))
    (cond ((stringp k) (not (string-match-p "mouse\\|wheel\\|\\`<remap>" k)))
          ((vectorp k)
           (let ((first (and (> (length k) 0) (aref k 0))))
             (not (or (memq first '(remap header-line tab-line mode-line left-fringe right-fringe))
                      (and (symbolp first) (string-match-p "mouse\\|wheel" (symbol-name first))))))))))

(ert-deftest drgnx-lint/the-key-check-tells-keys-from-mouse ()
  (should (drgnx-lint--keyboard-key-p '(kbd "RET")))
  (should (drgnx-lint--keyboard-key-p "C-c a"))
  (should (drgnx-lint--keyboard-key-p [?a]))
  (should-not (drgnx-lint--keyboard-key-p "<mouse-1>"))
  (should-not (drgnx-lint--keyboard-key-p "<remap> <self-insert-command>"))
  (should-not (drgnx-lint--keyboard-key-p [header-line mouse-1]))
  (should-not (drgnx-lint--keyboard-key-p [remap kill-line])))

(ert-deftest drgnx-lint/keys-come-from-the-profiles ()
  ;; Keyboard keys are registry entries in keys/*.eld; code binds only mouse and chrome events.
  (should-not
   (drgnx-lint--violations
    (drgnx-lint--files "wb" "modules")
    (lambda (form)
      (pcase form
        (`(,(or 'define-key 'keymap-set 'keymap-local-set 'local-set-key) ,_ ,key . ,_)
         (when (drgnx-lint--keyboard-key-p key) (format "%S binds a keyboard key" (car form))))
        (`(,(or 'global-set-key 'keymap-global-set) . ,_) (format "%S" (car form))))))))

(ert-deftest drgnx-lint/every-face-has-a-group ()
  ;; Emacs 31 warns otherwise (the build must have no warnings).
  (should-not
   (drgnx-lint--violations
    (drgnx-lint--files "core" "wb" "modules")
    (lambda (form)
      (pcase form
        (`(defface ,name ,_spec ,_doc . ,args)
         (unless (plist-member args :group) (format "defface %s has no :group" name))))))))

(ert-deftest drgnx-lint/no-macros-obsolete-in-emacs-31 ()
  ;; `if-let' and `when-let' are obsolete as of 31.1 (warnings in every batch run); use the starred forms.
  (should (equal (drgnx-lint--violations (drgnx-lint--files "core" "wb" "harness" "init" "modules" "test")
                                         (lambda (form) (and (consp form) (memq (car form) '(if-let when-let)) (consp (cadr form))
                                                             (format "%s (use %s*)" (car form) (car form)))))
                 nil)))

