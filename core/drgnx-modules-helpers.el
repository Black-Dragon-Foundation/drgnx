;;; drgnx-modules-helpers.el --- Options, alist keys, face specs and remaps that undo themselves -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A module's setup changes global state in a few ways a hook or advice helper does not cover.
;; Each function here makes the change and pushes its own undo (`drgnx-modules-push-undo'); the
;; undo changes nothing unless the state is still what this module set, so it never removes what
;; someone else (the user, a theme, another module) put there since.  Outside a setup they only
;; make the change.  See docs/develop/core.md, "Modules".

;;; Code:
(require 'drgnx-modules-record)

(defun drgnx-module--set-option (var value)
  "Set the default value of VAR to VALUE through its custom setter, else `set-default'."
  (funcall (or (get var 'custom-set) #'set-default) var value))

;;; Claims: two modules may change the same target

(defvar drgnx-module--claims (make-hash-table :test 'equal)
  "Target → list of boxes (OLD), newest first: who changed it and what each found there.
A target is (option VAR), (alist VAR KEY), (face FACE) or (key MAP-SYMBOL KEY).")

(defun drgnx-module--claim (target old)
  "Claim TARGET, which held OLD; return the box that stands for the claim."
  (let ((box (list old)))
    (push box (gethash target drgnx-module--claims))
    box))

(defun drgnx-module--release (target box ours-p restore)
  "Give up BOX's claim on TARGET (the undo of a helper).
The newest claim restores: when (funcall OURS-P) says the state is still what it set, it calls
RESTORE with the old state in the box.  An older claim, released while newer ones stand, leaves the
live state alone and hands its old state to the claim just above it, so the target ends where it
started whichever module is torn down first."
  (let* ((stack (gethash target drgnx-module--claims))
         (tail (memq box stack)))
    (when tail
      (if (eq tail stack)
          (progn
            (if (cdr stack) (puthash target (cdr stack) drgnx-module--claims) (remhash target drgnx-module--claims))
            (when (funcall ours-p) (funcall restore (car box))))
        (let ((above stack))
          (while (not (eq (cdr above) tail)) (setq above (cdr above)))
          (setcar (car above) (car box))
          (setcdr above (cdr tail)))))))

;;; Helpers

(defun drgnx-module-set (var value)
  "Set option VAR to VALUE; the module's undo puts the old value back.
Both ways go through VAR's custom `:set' function when it has one (else `set-default'), so a
setter that does more than store runs again on the way back.  The undo runs only while VAR's
default value is still the one this call set; a list that is stored by reference and changed
in place later still counts as ours, so the undo overwrites that change.  Two modules that set
the same VAR may be torn down in either order."
  (let* ((rec (drgnx-modules--recording-p))
         (had (and rec (default-boundp var)))
         (old (and had (default-value var))))
    (drgnx-module--set-option var value)
    (when rec
      (let* ((ours (default-value var))   ; what a setter stored, which may differ from VALUE
             (target (list 'option var))
             (box (drgnx-module--claim target (cons had old))))
        (drgnx-modules-push-undo
         (format "option %s" var)
         (lambda ()
           (drgnx-module--release
            target box
            (lambda () (and (default-boundp var) (equal (default-value var) ours)))
            (lambda (prev)
              (if (car prev) (drgnx-module--set-option var (cdr prev)) (makunbound var))))))))))

(defun drgnx-module-alist-put (var key value)
  "Set KEY to VALUE in the alist that is VAR's default value; the module's undo puts it back.
KEY is compared with `equal' (an `auto-mode-alist' key is a string).  The alist is replaced,
never mutated, and stored through VAR's custom `:set' function when it has one.  VAR need not be
bound yet (the alist is then empty).  The undo puts the old entry back, or removes KEY when there
was none, only while KEY still holds VALUE.  Two modules that put the same KEY may be torn down in
either order."
  (let* ((rec (drgnx-modules--recording-p))
         (alist (and (default-boundp var) (default-value var)))
         (old (assoc key alist))
         (new (cons key value)))
    (drgnx-module--set-option var (if old
                                      (mapcar (lambda (cell) (if (eq cell old) new cell)) alist)
                                    (cons new alist)))
    (when rec
      (let* ((target (list 'alist var key))
             (box (drgnx-module--claim target old)))
        (drgnx-modules-push-undo
         (format "alist %s key %S" var key)
         (lambda ()
           (drgnx-module--release
            target box
            (lambda ()
              (let ((cell (and (default-boundp var) (assoc key (default-value var)))))
                (and cell (equal (cdr cell) value))))
            (lambda (prev)
              (let* ((alist (default-value var)) (cell (assoc key alist)))
                (drgnx-module--set-option var (if prev
                                                  (mapcar (lambda (c) (if (eq c cell) prev c)) alist)
                                                (remq cell alist))))))))))))

(defun drgnx-module-face-spec (face spec)
  "Give FACE the default spec SPEC (`face-defface-spec'); the module's undo puts the old one back.
The undo runs only while the face's default spec is still SPEC, so a spec changed since, and
what the user customized or a theme set (kept apart from the default spec), stay.  Note that
`face-spec-set' recalculates the face: an attribute set directly with `set-face-attribute' is
wiped.  Two modules that set the same FACE may be torn down in either order."
  (let ((rec (drgnx-modules--recording-p))
        (old (get face 'face-defface-spec)))
    (face-spec-set face spec 'face-defface-spec)
    (when rec
      (let* ((target (list 'face face))
             (box (drgnx-module--claim target old)))
        (drgnx-modules-push-undo
         (format "face %s" face)
         (lambda ()
           (drgnx-module--release
            target box
            (lambda () (equal (get face 'face-defface-spec) spec))
            (lambda (prev) (face-spec-set face prev 'face-defface-spec)))))))))

(defconst drgnx-module--pointer-event-regexp
  "\\`\\(?:[ACHMSs]-\\)*\\(?:down-\\|drag-\\|double-\\|triple-\\)?\\(?:mouse\\|wheel\\)-"
  "Matches the name of a mouse or wheel event symbol (mouse-1, C-down-mouse-3, wheel-up).")

(defconst drgnx-module--chrome-prefixes
  '(remap menu-bar tool-bar tab-bar tab-line header-line mode-line vertical-scroll-bar
          horizontal-scroll-bar left-fringe right-fringe)
  "First events of a key that is not typed: remaps and the parts of the frame and window chrome.")

(defun drgnx-module--chrome-key-p (key)
  "Non-nil if KEY, a vector, is a remap or a mouse/chrome event, not a typed key."
  (and (vectorp key) (> (length key) 0)
       (or (memq (aref key 0) drgnx-module--chrome-prefixes)
           (let ((last (aref key (1- (length key)))))
             (and (symbolp last) (string-match-p drgnx-module--pointer-event-regexp (symbol-name last)))))))

(defun drgnx-module--own-binding (map key)
  "The binding of KEY in MAP itself, ignoring its parent keymap; nil if none."
  (let ((parent (keymap-parent map)))
    (set-keymap-parent map nil)
    (unwind-protect (let ((b (lookup-key map key))) (and (not (numberp b)) b))
      (set-keymap-parent map parent))))

(defun drgnx-module-define-key (map-symbol key def)
  "Bind KEY to DEF in the keymap that is the value of MAP-SYMBOL; the module's undo puts back the old binding.
For remaps (`[remap CMD]') and mouse and chrome events (`[mode-line mouse-1]', `[menu-bar ...]')
only: keyboard keys come from the profiles (`keys/*.eld'), so a keyboard key signals an error.
The map object is changed in place, never rebound.  The undo runs only while KEY still holds DEF
in the map, and removes the entry when the map had none.  Two modules that bind the same KEY may
be torn down in either order."
  (let ((map (and (boundp map-symbol) (symbol-value map-symbol))))
    (unless (keymapp map) (error "%S is not a keymap variable" map-symbol))
    (unless (drgnx-module--chrome-key-p key)
      (error "Keyboard key %S: bind it through the key profiles; helpers take remaps and mouse/chrome events" key))
    (let ((rec (drgnx-modules--recording-p))
          (old (drgnx-module--own-binding map key)))
      (define-key map key def)
      (when rec
        (let* ((target (list 'key map-symbol key))
               (box (drgnx-module--claim target old)))
          (drgnx-modules-push-undo
           (format "key %S in %s" key map-symbol)
           (lambda ()
             (drgnx-module--release
              target box
              (lambda () (equal (drgnx-module--own-binding map key) def))
              (lambda (prev) (define-key map key prev (null prev)))))))))))

(provide 'drgnx-modules-helpers)
;;; drgnx-modules-helpers.el ends here
