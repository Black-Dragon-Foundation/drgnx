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

(defconst drgnx-lint--raw-input-maps '(drgnx-live-driving-map)
  "Keymaps allowed to bind keyboard keys in code: they forward raw input (to a web page, like a terminal's raw map), so
their keys are not commands and have no registry entries.  Everything else gets its keys from the profiles.")

(defconst drgnx-lint--decode-maps '(input-decode-map key-translation-map)
  "The terminal's decoding maps: a key sequence computed in code there is what a terminal sends (bytes, CSI forms), not
a keyboard key of a command.")

(defconst drgnx-lint--decode-map-builders '(drgnx-tty-frames--mok-map drgnx-tty-frames--csi-u-map)
  "Functions that build a keymap for `input-decode-map' from the terminal's key encodings (modifyOtherKeys, CSI u).")

(defun drgnx-lint--names-mouse-p (key)
  "Does the computed KEY form name a mouse or wheel event (a quoted mouse-1, wheel-up…)?"
  (catch 'found
    (drgnx-lint--walk key (lambda (x) (when (and (symbolp x) (string-match-p "mouse\\|wheel" (symbol-name x))) (throw 'found t))))
    nil))

(ert-deftest drgnx-lint/computed-keys-only-in-raw-input-maps ()
  ;; A key computed in code (not a literal string, vector or (kbd "…")) slips past keys-come-from-the-profiles;
  ;; only the declared raw-input maps may do that (mouse events built in code, like (vector area 'mouse-1), are fine).
  (let (out)
    (dolist (f (drgnx-lint--files "wb" "modules"))
      (dolist (top (drgnx-lint--forms f))
        (unless (or (and (memq (car-safe top) '(defvar defconst defvar-keymap)) (memq (cadr top) drgnx-lint--raw-input-maps))
                    (and (eq (car-safe top) 'defun) (memq (cadr top) drgnx-lint--decode-map-builders)))
          (drgnx-lint--walk top (lambda (form)
                                  (pcase form
                                    (`(,(or 'define-key 'keymap-set 'keymap-local-set 'local-set-key) ,map ,key . ,_)
                                     (unless (or (stringp key) (vectorp key) (and (eq (car-safe key) 'kbd) (stringp (cadr key)))
                                                 (memq map drgnx-lint--decode-maps)
                                                 (drgnx-lint--names-mouse-p key))
                                       (push (format "%s: %S binds a computed key %S" (file-relative-name f drgnx-dir) (car form) key)
                                             out)))))))))
    (should (equal (nreverse out) nil))))

(ert-deftest drgnx-lint/every-face-has-a-group ()
  ;; Emacs 31 warns otherwise (the build must have no warnings).
  (should-not
   (drgnx-lint--violations
    (drgnx-lint--files "core" "wb" "modules")
    (lambda (form)
      (pcase form
        (`(defface ,name ,_spec ,_doc . ,args)
         (unless (plist-member args :group) (format "defface %s has no :group" name))))))))

(ert-deftest drgnx-lint/modules-never-install ()
  ;; Packages come only from drgnx sync (core/drgnx-pkg.el): no use-package :vc / :ensure, no
  ;; package-install in modules.
  (should (equal (drgnx-lint--violations (drgnx-lint--files "modules")
                                         (lambda (form)
                                           (pcase form
                                             (`(use-package ,name . ,args)
                                              (seq-some (lambda (k) (and (plist-member args k) (format "use-package %s %s" name k)))
                                                        '(:vc :ensure)))
                                             (`(,(and f (or 'package-install 'package-vc-install 'package-refresh-contents)) . ,_)
                                              (format "calls %s" f)))))
                 nil)))

(ert-deftest drgnx-lint/no-macros-obsolete-in-emacs-31 ()
  ;; `if-let' and `when-let' are obsolete as of 31.1 (warnings in every batch run); use the starred forms.
  (should (equal (drgnx-lint--violations (drgnx-lint--files "core" "wb" "harness" "init" "modules" "test")
                                         (lambda (form) (and (consp form) (memq (car form) '(if-let when-let)) (consp (cadr form))
                                                             (format "%s (use %s*)" (car form) (car form)))))
                 nil)))

(ert-deftest drgnx-lint/every-shipped-module-has-a-row-in-the-guide ()
  ;; docs/guide/modules.md's table lists every module with its stage
  (let ((doc (with-temp-buffer (insert-file-contents (expand-file-name "docs/guide/modules.md" drgnx-dir)) (buffer-string))))
    (should (equal (drgnx-lint--violations
                    (drgnx-lint--files "modules")
                    (lambda (form)
                      (pcase form
                        (`(drgnx-module-define (quote ,name) . ,args)
                         (let ((stage (eval (plist-get args :stage) t)))
                           (unless (string-match-p (format "^| `%s` | %s |" (regexp-quote (symbol-name name)) stage) doc)
                             (format "%s (%s) has no row in docs/guide/modules.md" name stage)))))))
                   nil))))

(defun drgnx-lint--wait-on-process-live-p (form)
  "A message when FORM is a `drgnx-test-wait' call whose PRED mentions `process-live-p'.
Only a literal PRED form is read: `(drgnx-test-wait #\\='my-pred)' is not followed into `my-pred'."
  (when (and (consp form) (eq (car form) 'drgnx-test-wait)
             (let (hit) (drgnx-lint--walk (cadr form) (lambda (f) (when (eq f 'process-live-p) (setq hit t)))) hit))
    "drgnx-test-wait on process-live-p (wait on the sentinel's done flag: process-live-p turns nil before it has run)"))

(ert-deftest drgnx-lint/test-waits-read-a-done-flag-not-process-live-p ()
  ;; fb4ee8c (M3b-19): `process-live-p' is nil before the sentinel has run, so a wait on it races the sentinel.
  (should (equal (drgnx-lint--violations (drgnx-lint--files "test") #'drgnx-lint--wait-on-process-live-p) nil))
  (let* ((dir (make-temp-file "drgnx-lint-wait" t))
         (bad (expand-file-name "bad.el" dir)) (good (expand-file-name "good.el" dir)))
    (unwind-protect
        (progn
          (with-temp-file bad (insert "(drgnx-test-wait (lambda () (not (process-live-p p))))"))
          (with-temp-file good (insert "(drgnx-test-wait (lambda () (process-get p :done)))"))
          (should (= (length (drgnx-lint--violations (list bad) #'drgnx-lint--wait-on-process-live-p)) 1))
          (should-not (drgnx-lint--violations (list good) #'drgnx-lint--wait-on-process-live-p)))
      (delete-directory dir t))))
