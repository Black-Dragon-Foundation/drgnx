;;; drgnx-pack-ts-mode.el --- The generic tree-sitter mode of language packs -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A pack with `:mode (:generic t)' (Kotlin, Swift, Zig, SQL) has no Emacs mode of its own.  `drgnx-pack-ts-mode' is
;; the one mode they share: the pack of the buffer's file gives its grammar, its highlighting (the queries
;; `ratatoskr packs translate' wrote when the pack was installed, `drgnx-packs-translated'), its navigation (the node
;; kinds of its `tags.scm') and its indentation (the previous line's, plus the pack's `:indent' rules).
;; Nothing here runs a process or prompts: a buffer whose pack is not installed, or whose grammar does not load, stays
;; in `fundamental-mode'-like `prog-mode'.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'prog-mode)
(require 'drgnx-packs)
(require 'treesit)
(declare-function treesit-ready-p "treesit")

(defvar-local drgnx-pack-ts-pack nil "The pack (a name string) this buffer's mode took its language from, or nil.")

(defvar drgnx-pack-ts--preds nil
  "The `#pred?' functions defined so far (symbols): at most those of the installed generic packs.  Removed with the module.")

(defconst drgnx-pack-ts-feature-list
  '((comment keyword string) (type constant number function escape-sequence attribute) (variable property operator delimiter bracket))
  "`treesit-font-lock-feature-list' of a pack: what `ratatoskr packs translate' groups its patterns by, by level.")

(defun drgnx-pack-ts--define-preds (preds)
  "Define the functions of PREDS (plists :name :kind :arg), the `#pred?' predicates a translated pack's queries name."
  (dolist (p preds)
    (let* ((name (intern (plist-get p :name))) (arg (plist-get p :arg))
           (fn (pcase (plist-get p :kind)
                 ('not-eq (lambda (node) (not (equal (treesit-node-text node t) arg))))
                 ('not-match (lambda (node) (not (string-match-p arg (treesit-node-text node t)))))
                 ('not-eq-nodes (lambda (a b) (not (equal (treesit-node-text a t) (treesit-node-text b t))))))))
      (when fn
        (fset name fn)
        (cl-pushnew name drgnx-pack-ts--preds)))))

(defun drgnx-pack-ts-forget-preds ()
  "Undefine the predicate functions `drgnx-pack-ts--define-preds' made."
  (dolist (s drgnx-pack-ts--preds) (fmakunbound s))
  (setq drgnx-pack-ts--preds nil))

(defun drgnx-pack-ts--active-entry (pack)
  "PACK's entry of `active.eld', (NAME :manifest … :grammars … :translated …), or nil."
  (assq (intern pack) (plist-get (drgnx-packs-active) :packs)))

(defun drgnx-pack-ts--main-language (manifest)
  "The language of MANIFEST's main grammar: the first one it pins itself and requires."
  (plist-get (seq-find (lambda (g) (and (plist-get g :required) (plist-get g :repo))) (plist-get manifest :grammars)) :name))

(defun drgnx-pack-ts--for-buffer ()
  "(PACK-NAME MANIFEST TRANSLATED-DATA ENTRY) for this buffer's file, when a generic pack installed here owns it."
  (when-let* ((p (and buffer-file-name (seq-find (lambda (p) (plist-get (plist-get (cdr p) :mode) :generic))
                                                 (seq-filter (lambda (p) (drgnx-lang-packs--file-of-pack-p p buffer-file-name))
                                                             (drgnx-packs-builtins)))))
              (entry (drgnx-pack-ts--active-entry (car p)))
              (file (plist-get (cdr entry) :translated))
              (data (and (file-exists-p file) (with-temp-buffer (insert-file-contents file) (let ((read-eval nil)) (read (current-buffer)))))))
    (list (car p) (cdr p) data entry)))

(defun drgnx-pack-ts--indent-rules (lang manifest)
  "`treesit-simple-indent-rules' for LANG: the pack's `:indent' offsets from the parent's line, else the previous line's."
  (list (cons lang (append (mapcar (lambda (r) `((parent-is ,(symbol-name (car r))) parent-bol ,(cdr r)))
                                   (plist-get (plist-get manifest :mode) :indent))
                           '((catch-all prev-line 0))))))

;;;###autoload
(define-derived-mode drgnx-pack-ts-mode prog-mode "Pack"
  "Major mode of the language packs that have no mode of their own: tree-sitter highlighting, navigation and
indentation from the pack of the file (Kotlin, Swift, Zig, SQL)."
  (when-let* ((found (drgnx-pack-ts--for-buffer))
              (lang (drgnx-pack-ts--main-language (nth 1 found)))
              ((treesit-ready-p lang t)))
    (pcase-let ((`(,name ,manifest ,data . ,_) found))
      (setq drgnx-pack-ts-pack name)
      (drgnx-pack-ts--define-preds (plist-get data :preds))
      (treesit-parser-create lang)
      (setq-local treesit-font-lock-settings
                  (apply #'append (mapcar (lambda (r) (treesit-font-lock-rules :language lang :override t :feature (intern (plist-get r :feature))
                                                                               (plist-get r :query)))
                                          (plist-get data :rules))))
      (setq-local treesit-font-lock-feature-list drgnx-pack-ts-feature-list)
      (setq-local treesit-simple-indent-rules (drgnx-pack-ts--indent-rules lang manifest))
      (when-let* ((kinds (plist-get data :defuns)))
        (let ((re (concat "\\`" (regexp-opt kinds) "\\'")))
          (setq-local treesit-defun-type-regexp re)
          (setq-local treesit-defun-name-function
                      (lambda (node) (when-let* ((n (or (treesit-node-child-by-field-name node "name")
                                                        (treesit-search-subtree node (lambda (c) (string-suffix-p "identifier" (treesit-node-type c))) nil nil 2))))
                                       (treesit-node-text n t))))
          (setq-local treesit-simple-imenu-settings (list (list nil re nil nil)))))
      (treesit-major-mode-setup))))

(declare-function drgnx-lang-packs--file-of-pack-p "drgnx-lang-packs" (pack file))

(provide 'drgnx-pack-ts-mode)
;;; drgnx-pack-ts-mode.el ends here
