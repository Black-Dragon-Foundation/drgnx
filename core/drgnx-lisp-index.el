;;; drgnx-lisp-index.el --- Settings: the static index of your Lisp files -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A static read of your Lisp files (design 8.1): which variable each file sets, on which line, and whether the form
;; is top-level or conditional; plus findings (a file that moves `custom-file' or `user-emacs-directory', uses
;; `user-emacs-directory', or `setq's an automatically buffer-local variable).  It reads the forms with positions and
;; never evaluates them.  The result per file is cached by file stamp in <cache>/lisp-index/, built at idle.
;; See docs/develop/settings.md, "The Lisp index".

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-timer)

(declare-function drgnx-user-dir "drgnx-paths" ())
(defvar drgnx-user-lisp-files)
(defvar read-eval)

(defconst drgnx-lisp-index--version 1 "The cache format; a cache of another version is rebuilt.")

(defvar drgnx-lisp-index--setters nil "Setters found so far in the file being indexed (newest first).")
(defvar drgnx-lisp-index--findings nil "Findings found so far in the file being indexed (newest first).")
(defvar drgnx-lisp-index--var-begs nil "Positions of setter variables, which are not `user-emacs-directory' uses.")

;;;; Reading with positions

(defun drgnx-lisp-index--skip ()
  "Skip whitespace and comments at point."
  (while (progn (skip-chars-forward " \t\n\r\f")
                (when (eq (char-after) ?\;) (forward-line 1) t))))

(defun drgnx-lisp-index--prefixed (beg len sym)
  "Read the form after a LEN-character reader prefix at BEG as (SYM FORM): a node."
  (goto-char (+ beg len))
  (let ((inner (drgnx-lisp-index--node)))
    (unless (consp inner) (error "Nothing after the prefix at %d" beg))
    (list (list sym (car inner)) beg (point)
          (list (list sym beg (+ beg len) nil) inner))))

(defun drgnx-lisp-index--list-node (beg)
  "Read the list that opens at BEG into a node; point ends after the closing parenthesis."
  (forward-char 1)
  (let (children tail)
    (catch 'done
      (while t
        (drgnx-lisp-index--skip)
        (when (and (eq (char-after) ?.) (memq (char-after (1+ (point))) '(?\s ?\t ?\n ?\) ?\()))
          (forward-char 1)
          (let ((n (drgnx-lisp-index--node)))
            (unless (consp n) (error "Bad dotted list at %d" beg))
            (setq tail (car n))
            (drgnx-lisp-index--skip)
            (unless (eq (char-after) ?\)) (error "Bad dotted list at %d" beg))))
        (let ((n (drgnx-lisp-index--node)))
          (cond ((eq n :close) (throw 'done nil))
                ((null n) (error "Unclosed list at %d" beg))
                (t (push n children))))))
    (setq children (nreverse children))
    (list (nconc (mapcar #'car children) tail) beg (point) children)))

(defun drgnx-lisp-index--node ()
  "Read the next form at point as a node (FORM BEG END CHILDREN); `:close' at a closing parenthesis; nil at the end.
CHILDREN are the nodes of a list's elements.  Nothing is evaluated (`read-eval' is off)."
  (drgnx-lisp-index--skip)
  (let ((beg (point)) (c (char-after)) (read-eval nil))
    (cond ((null c) nil)
          ((eq c ?\)) (forward-char 1) :close)
          ((eq c ?\() (drgnx-lisp-index--list-node beg))
          ((eq c ?') (drgnx-lisp-index--prefixed beg 1 'quote))
          ((eq c ?`) (drgnx-lisp-index--prefixed beg 1 '\`))
          ((eq c ?,) (if (eq (char-after (1+ beg)) ?@)
                         (drgnx-lisp-index--prefixed beg 2 '\,@)
                       (drgnx-lisp-index--prefixed beg 1 '\,)))
          ((and (eq c ?#) (eq (char-after (1+ beg)) ?')) (drgnx-lisp-index--prefixed beg 2 'function))
          (t (let ((form (read (current-buffer)))) (list form beg (point) nil))))))

;;;; Walking

(defun drgnx-lisp-index--line (pos) "The line of POS." (line-number-at-pos pos))

(defun drgnx-lisp-index--const (node)
  "(CONST-P . VALUE) for the value NODE: the literal value when it is a constant, else the form as written."
  (let ((f (car node)))
    (cond ((or (numberp f) (stringp f) (keywordp f) (null f) (eq f t) (vectorp f)) (cons t f))
          ((and (eq (car-safe f) 'quote) (= (length f) 2)) (cons t (cadr f)))
          ((and (eq (car-safe f) 'function) (symbolp (cadr f)) (= (length f) 2)) (cons t (cadr f)))
          (t (cons nil f)))))

(defun drgnx-lisp-index--setter (kind var-node beg end value-node ctx)
  "Record a setter of KIND for the symbol in VAR-NODE spanning BEG to END with VALUE-NODE; CTX is (TOP . COND)."
  (let ((var (car var-node)))
    (when (and var (symbolp var) (not (keywordp var)))
      (let ((c (and value-node (drgnx-lisp-index--const value-node))))
        (push (list :var var :kind kind :line (drgnx-lisp-index--line (cadr var-node)) :beg beg :end end
                    :top-level (car ctx) :conditional (cdr ctx) :const-p (car c) :value (cdr c))
              drgnx-lisp-index--setters))
      (push (cadr var-node) drgnx-lisp-index--var-begs)
      (drgnx-lisp-index--setter-findings kind var (cadr var-node) ctx))))

(defun drgnx-lisp-index--finding (kind pos)
  "Record a finding of KIND for the line of POS."
  (push (list :kind kind :line (drgnx-lisp-index--line pos)
              :text (save-excursion (goto-char pos) (string-trim (buffer-substring (line-beginning-position)
                                                                                   (line-end-position)))))
        drgnx-lisp-index--findings))

(defun drgnx-lisp-index--setter-findings (kind var pos ctx)
  "Findings that setting VAR (by KIND, at POS) makes."
  (cond ((eq var 'custom-file) (drgnx-lisp-index--finding 'custom-file pos))
        ((eq var 'user-emacs-directory) (drgnx-lisp-index--finding 'user-emacs-directory pos))
        ((and (eq kind 'setq) (car ctx) (not (cdr ctx)) (local-variable-if-set-p var))
         (drgnx-lisp-index--finding 'buffer-local-setq pos))))

(defun drgnx-lisp-index--pairs (kind children ctx)
  "Setters for the VAR VALUE pairs in CHILDREN (the nodes after the head of a `setq'-like form)."
  (while children
    (let* ((v (car children)) (val (cadr children)))
      (when (consp v)
        (drgnx-lisp-index--setter kind v (cadr v) (if val (nth 2 val) (nth 2 v)) val ctx))
      (setq children (cddr children)))))

(defun drgnx-lisp-index--quoted-symbol (node)
  "The node of the symbol in NODE when NODE is a quoted symbol, else nil."
  (and (eq (car-safe (car node)) 'quote) (symbolp (cadr (car node))) (cadr (nth 3 node))))

(defun drgnx-lisp-index--custom-entries (children ctx)
  "Setters for the `custom-set-variables' entries (quoted lists) in CHILDREN."
  (dolist (arg children)
    (let ((entry (if (eq (car-safe (car arg)) 'quote) (cadr (nth 3 arg)) arg)))
      (when (and entry (consp (car entry)) (nth 3 entry) (symbolp (car (car (nth 3 entry)))))
        (let ((parts (nth 3 entry)))
          (drgnx-lisp-index--setter 'custom-set-variables (car parts) (cadr entry) (nth 2 entry) (cadr parts) ctx))))))

(defun drgnx-lisp-index--body (nodes ctx)
  "Walk the form nodes NODES under CTX."
  (dolist (n nodes) (drgnx-lisp-index--walk n ctx)))

(defun drgnx-lisp-index--cond-ctx (ctx) "CTX for a form that may not run: not top-level, conditional." (ignore ctx) (cons nil t))

(defun drgnx-lisp-index--use-package (children ctx)
  "Walk a `use-package' form's :custom, :init and :config (CHILDREN include the head)."
  (let* ((rest (cddr children)) (conditional (cdr ctx)) demand key args groups)
    (while rest                         ; group the arguments by keyword
      (let ((n (pop rest)))
        (if (keywordp (car n))
            (progn (when key (push (cons key (nreverse args)) groups)) (setq key (car n) args nil))
          (when key (push n args)))))
    (when key (push (cons key (nreverse args)) groups))
    (setq groups (nreverse groups))
    (dolist (g groups)
      (when (memq (car g) '(:if :when :unless :requires)) (setq conditional t))
      (when (and (eq (car g) :demand) (cadr g) (not (null (car (cadr g))))) (setq demand t)))
    (dolist (g groups)
      (pcase (car g)
        (:custom (let ((cctx (cons nil conditional)))
                   (dolist (e (cdr g))
                     (let ((parts (nth 3 e)))
                       (when (and (consp (car e)) parts (symbolp (car (car parts))))
                         (drgnx-lisp-index--setter 'use-package-custom (car parts) (cadr e) (nth 2 e) (cadr parts)
                                                   cctx))))))
        (:init (drgnx-lisp-index--body (cdr g) (cons nil conditional)))
        (:config (drgnx-lisp-index--body (cdr g) (cons nil (or conditional (not demand)))))))))

(defun drgnx-lisp-index--walk (node ctx)
  "Find the setting forms in NODE.  CTX is (TOP-LEVEL . CONDITIONAL)."
  (let ((form (car node)) (children (nth 3 node)))
    (when (and (consp form) (symbolp (car form)) (proper-list-p form))
      (let ((head (car form)) (args (cdr children)))
        (pcase head
          ((or 'setq 'setq-default 'setopt) (drgnx-lisp-index--pairs head args ctx))
          ('customize-set-variable
           (when-let* ((inner (drgnx-lisp-index--quoted-symbol (car args))))
             (drgnx-lisp-index--setter head inner (cadr node) (nth 2 node) (cadr args) ctx)))
          ('custom-set-variables (drgnx-lisp-index--custom-entries args ctx))
          ('progn (drgnx-lisp-index--body args ctx))
          ((or 'when 'unless) (drgnx-lisp-index--body (cdr args) (drgnx-lisp-index--cond-ctx ctx)))
          ('if (drgnx-lisp-index--body (cdr args) (drgnx-lisp-index--cond-ctx ctx)))
          ('cond (dolist (clause args)
                   (when (consp (car clause))
                     (drgnx-lisp-index--body (cdr (nth 3 clause)) (drgnx-lisp-index--cond-ctx ctx)))))
          ('with-eval-after-load (drgnx-lisp-index--body (cdr args) (drgnx-lisp-index--cond-ctx ctx)))
          ('add-hook (dolist (a (cdr args)) (drgnx-lisp-index--lambda a)))
          ('use-package (drgnx-lisp-index--use-package children ctx)))))))

(defun drgnx-lisp-index--lambda (node)
  "Walk the body of NODE when it is a lambda (possibly inside `function')."
  (let ((f (car node)))
    (cond ((eq (car-safe f) 'lambda)
           (drgnx-lisp-index--body (nthcdr 2 (nth 3 node)) (cons nil t)))
          ((and (eq (car-safe f) 'function) (eq (car-safe (cadr f)) 'lambda))
           (drgnx-lisp-index--lambda (cadr (nth 3 node)))))))

(defun drgnx-lisp-index--scan-uses (node)
  "Findings for uses of `user-emacs-directory' and `locate-user-emacs-file' in NODE (quoted forms are skipped)."
  (let ((form (car node)))
    (cond ((and (memq form '(user-emacs-directory locate-user-emacs-file))
                (not (memq (cadr node) drgnx-lisp-index--var-begs)))
           (drgnx-lisp-index--finding 'emacs-dir-use (cadr node)))
          ((and (consp form) (not (memq (car-safe form) '(quote function))))
           (dolist (c (nth 3 node)) (drgnx-lisp-index--scan-uses c))))))

;;;; The public index

(defun drgnx-lisp-index-file (file)
  "Index FILE statically: (:setters LIST :findings LIST); nothing is evaluated.
A setter is (:var :kind :line :beg :end :top-level :conditional :const-p :value) for `setq' (each pair),
`setq-default', `setopt', `customize-set-variable', `custom-set-variables' (each entry, on its own line) and
`use-package' :custom (:kind `use-package-custom').  :beg and :end are positions in the file, :top-level is t for a form
at the top of the file (also inside a top-level `progn'), :conditional for one under `when', `unless', `if', `cond',
`with-eval-after-load', an `add-hook' lambda or a deferred `use-package' :config.  :const-p is t when :value is the
literal value, else :value is the form as written.  A finding is (:kind :line :text) with :kind `custom-file',
`user-emacs-directory', `emacs-dir-use' or `buffer-local-setq'.  A file that does not read or cannot be read gives what
was found before the problem.  See docs/develop/settings.md, \"The Lisp index\"."
  (let (drgnx-lisp-index--setters drgnx-lisp-index--findings drgnx-lisp-index--var-begs)
    (when (file-readable-p file)
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8) (inhibit-message t))
          (insert-file-contents file))
        (set-syntax-table emacs-lisp-mode-syntax-table)
        (goto-char (point-min))
        (condition-case nil
            (let (node)
              (while (consp (setq node (drgnx-lisp-index--node)))
                (drgnx-lisp-index--walk node (cons t nil))
                (drgnx-lisp-index--scan-uses node)))
          (error nil))))
    (list :setters (nreverse drgnx-lisp-index--setters)
          :findings (sort (nreverse drgnx-lisp-index--findings)
                          (lambda (a b) (< (plist-get a :line) (plist-get b :line)))))))

;;;; The cache

(defun drgnx-lisp-index--cache-file (file)
  "The cache file of FILE: <cache>/lisp-index/<sha1 of its truename>.eld."
  (expand-file-name (concat (secure-hash 'sha1 (file-truename file)) ".eld")
                    (expand-file-name "lisp-index" (drgnx-cache-dir))))

(defun drgnx-lisp-index--read-cache (cache stamp)
  "The index in CACHE when it is of this version and for STAMP, else nil."
  (when (file-readable-p cache)
    (let ((data (condition-case nil
                    (with-temp-buffer (insert-file-contents cache)
                                      (let ((read-eval nil)) (read (current-buffer))))
                  (error nil))))
      (and (eq (plist-get data :version) drgnx-lisp-index--version)
           (equal (plist-get data :stamp) stamp)
           (plist-get data :index)))))

(defun drgnx-lisp-index--write-cache (cache stamp index)
  "Write INDEX for STAMP to CACHE, through a temporary file renamed over it."
  (make-directory (file-name-directory cache) t)
  (let ((tmp (make-temp-file (concat cache ".")))
        (print-length nil) (print-level nil))
    (with-temp-file tmp
      (prin1 (list :version drgnx-lisp-index--version :stamp stamp :index index) (current-buffer)))
    (rename-file tmp cache t)))

(defun drgnx-lisp-index-get (file)
  "The index of FILE (see `drgnx-lisp-index-file'): from the cache when FILE's stamp is the cached one, else built
and cached.  Nil when FILE does not exist."
  (when-let* ((stamp (drgnx-file-stamp file)))
    (let ((cache (drgnx-lisp-index--cache-file file)))
      (or (drgnx-lisp-index--read-cache cache stamp)
          (let ((index (drgnx-lisp-index-file file)))
            (ignore-errors (drgnx-lisp-index--write-cache cache stamp index))
            index)))))

(defun drgnx-lisp-index-setters (var files)
  "The setters of the symbol VAR in FILES (a list of file names), through the cache: each a setter plist of
`drgnx-lisp-index-file' with :file added, in FILES' order and then file order."
  (let (found)
    (dolist (file files)
      (dolist (s (plist-get (drgnx-lisp-index-get file) :setters))
        (when (eq (plist-get s :var) var) (push (plist-put (copy-sequence s) :file file) found))))
    (nreverse found)))

;;;; Built at idle

(defun drgnx-lisp-index--default-files ()
  "Your Lisp files: custom.el, config.el and `drgnx-user-lisp-files' (each a name or a list starting with one)."
  (let ((dir (drgnx-user-dir)))
    (append (list (expand-file-name "custom.el" dir) (expand-file-name "config.el" dir))
            (delq nil (mapcar (lambda (e) (let ((f (if (consp e) (car e) e)))
                                            (and (stringp f) (expand-file-name f dir))))
                              (and (boundp 'drgnx-user-lisp-files) drgnx-user-lisp-files))))))

(defun drgnx-lisp-index-refresh (&optional files)
  "Bring the cached index of FILES (default: your Lisp files) up to date; return the number of files rebuilt."
  (let ((n 0))
    (dolist (file (or files (drgnx-lisp-index--default-files)))
      (when-let* ((stamp (drgnx-file-stamp file)))
        (unless (drgnx-lisp-index--read-cache (drgnx-lisp-index--cache-file file) stamp)
          (drgnx-lisp-index-get file)
          (setq n (1+ n)))))
    n))

(defun drgnx-lisp-index-schedule ()
  "Refresh the index at idle through `drgnx-timer' (key `lisp-index'), never on the main thread at start."
  (drgnx-timer-start 'lisp-index 1 #'drgnx-lisp-index-refresh :idle t))

(provide 'drgnx-lisp-index)
;;; drgnx-lisp-index.el ends here
