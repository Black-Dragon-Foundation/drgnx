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

(defun drgnx-module-set (var value)
  "Set option VAR to VALUE; the module's undo puts the old value back.
Both ways go through VAR's custom `:set' function when it has one (else `set-default'), so a
setter that does more than store runs again on the way back.  The undo runs only while VAR's
default value is still the one this call set."
  (let* ((had (default-boundp var))
         (old (and had (default-value var))))
    (drgnx-module--set-option var value)
    (let ((ours (default-value var)))      ; what a setter stored, which may differ from VALUE
      (drgnx-modules-push-undo
       (format "option %s" var)
       (lambda ()
         (when (and (default-boundp var) (equal (default-value var) ours))
           (if had (drgnx-module--set-option var old) (makunbound var))))))))

(defun drgnx-module-alist-put (var key value)
  "Set KEY to VALUE in the alist that is VAR's default value; the module's undo puts it back.
KEY is compared with `equal' (an `auto-mode-alist' key is a string).  The alist is replaced,
never mutated.  The undo puts the old entry back, or removes KEY when there was none, only while
KEY still holds VALUE."
  (let* ((alist (default-value var))
         (old (assoc key alist))
         (new (cons key value)))
    (set-default var (if old
                         (mapcar (lambda (cell) (if (eq cell old) new cell)) alist)
                       (cons new alist)))
    (drgnx-modules-push-undo
     (format "alist %s key %S" var key)
     (lambda ()
       (let* ((alist (default-value var)) (cell (assoc key alist)))
         (when (and cell (equal (cdr cell) value))
           (set-default var (if old
                                (mapcar (lambda (c) (if (eq c cell) old c)) alist)
                              (remq cell alist)))))))))

(defun drgnx-module-face-spec (face spec)
  "Give FACE the default spec SPEC (`face-defface-spec'); the module's undo puts the old one back.
The undo runs only while the face's default spec is still SPEC, so a spec changed since, or
user customization and themes (kept apart from the default spec), stay."
  (let ((old (get face 'face-defface-spec)))
    (face-spec-set face spec 'face-defface-spec)
    (drgnx-modules-push-undo
     (format "face %s" face)
     (lambda ()
       (when (equal (get face 'face-defface-spec) spec)
         (face-spec-set face old 'face-defface-spec))))))

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
in the map, and removes the entry when the map had none."
  (let ((map (and (boundp map-symbol) (symbol-value map-symbol))))
    (unless (keymapp map) (error "%S is not a keymap variable" map-symbol))
    (unless (drgnx-module--chrome-key-p key)
      (error "Keyboard key %S: bind it through the key profiles; helpers take remaps and mouse/chrome events" key))
    (let ((old (drgnx-module--own-binding map key)))
      (define-key map key def)
      (drgnx-modules-push-undo
       (format "key %S in %s" key map-symbol)
       (lambda ()
         (when (equal (drgnx-module--own-binding map key) def)
           (define-key map key old (null old))))))))

(provide 'drgnx-modules-helpers)
;;; drgnx-modules-helpers.el ends here
