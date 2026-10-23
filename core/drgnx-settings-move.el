;;; drgnx-settings-move.el --- Settings: Move into Settings, and back -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 28 (design §8.3): move one setting from your Lisp into settings.el, and back.  Besides Tidy
;; custom.el, these are the only commands that rewrite your Lisp, so they refuse whenever they cannot be sure:
;; - Move into Settings needs a source line provenance is certain of (`drgnx-settings-explain'), a top-level,
;;   unconditional `setq' (one pair of it), `setq-default', `setopt', `customize-set-variable', `custom-set-variables'
;;   entry or `use-package' `:custom' entry, the only setter of the variable in your Lisp (the static index), a value
;;   the data reader accepts, and the same value in effect before and after.  The form (or pair, or entry) is replaced
;;   by a comment line `;; VAR: moved to Settings (DATE)' and the entry goes into settings.el.
;; - Move to My Lisp appends `(setopt VAR \\='VALUE)' to config.el (or a file of yours) and takes the entry out.
;; Each shows the diff of both files and the value before and after, keeps a backup of your file beside it
;; (`drgnx-file-backup'), writes atomically, checks that nothing but its own change differs, and Settings: Undo Move
;; restores both files.  See docs/guide/settings.md, "Moving a setting".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-config)
(require 'drgnx-settings-file)
(require 'drgnx-lisp-index)
(require 'drgnx-settings-prov)
(require 'drgnx-settings-live)

(declare-function drgnx-settings-claims "drgnx-settings-resolve" (var))
(declare-function drgnx-settings-resolve--merge "drgnx-settings-resolve" (var claims entry))
(declare-function drgnx-setting-meta "drgnx-setting" (var))
(declare-function symbol-at-point "thingatpt" ())
(defvar read-eval)

(defconst drgnx-settings-move-undo-kept 20 "The most moves Settings: Undo Move remembers (this session).")

(defvar drgnx-settings-move--undo nil
  "The moves of this session, newest first, at most `drgnx-settings-move-undo-kept': their plans (see
`drgnx-settings-move-plan') with `:bak', the backup of the Lisp file.")

;;;; Small parts

(defun drgnx-settings-move--no (reason fmt &rest args)
  "Refuse the move: throw (:refused REASON :why TEXT) to `drgnx-settings-move--plan'."
  (throw 'drgnx-settings-move--no (list :refused reason :why (apply #'format-message fmt args))))

(defun drgnx-settings-move--today () "Today, as the comment line says it." (format-time-string "%Y-%m-%d"))

(defun drgnx-settings-move--shown (file) "FILE as messages show it." (drgnx-settings-file--shown file))

(defun drgnx-settings-move--settings-file () "settings.el." (drgnx-config-file 'settings))

(defun drgnx-settings-move--print (x) "X printed as data, whatever the print settings." (drgnx-settings-file--prin1 x))

(defun drgnx-settings-move--same-file-p (a b)
  "Non-nil when A and B name the same file (a .el and its .elc counted as one)."
  (drgnx-settings-prov--same-file-p a b))

(defun drgnx-settings-move--lisp-text (file)
  "FILE's text, nil when it is missing; a refusal when it cannot be read."
  (condition-case err (drgnx-file-read-bounded file)
    (file-error (drgnx-settings-move--no 'unreadable "%s cannot be read: %s" (drgnx-settings-move--shown file)
                                         (if (eq (car err) 'drgnx-file-refused) (nth 2 err)
                                           (error-message-string err))))))

;;;; Reading your Lisp with positions

(defun drgnx-settings-move--parse (text)
  "TEXT's top-level forms as nodes of the static index, (FORM BEG END CHILDREN), and its setters, in TEXT's
positions: (NODES . SETTERS).  Nothing is evaluated.  Signals when TEXT does not read to its end."
  (with-temp-buffer
    (insert text)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (goto-char (point-min))
    (let ((drgnx-lisp-index--setters nil) (drgnx-lisp-index--findings nil) (drgnx-lisp-index--var-begs nil)
          (nodes nil) (node nil))
      (while (consp (setq node (drgnx-lisp-index--node)))
        (push node nodes)
        (drgnx-lisp-index--walk node (cons t nil)))
      (when (eq node :close) (error "A closing parenthesis with no opening one at %d" (1- (point))))
      (cons (nreverse nodes) (nreverse drgnx-lisp-index--setters)))))

(defun drgnx-settings-move--parse-or-refuse (file text)
  "`drgnx-settings-move--parse' of FILE's TEXT, or a refusal: a file that does not read is never rewritten."
  (condition-case err (drgnx-settings-move--parse text)
    (error (drgnx-settings-move--no 'unreadable "%s does not read to its end (%s): it is not changed"
                                    (drgnx-settings-move--shown file) (error-message-string err)))))

(defun drgnx-settings-move--forms (text)
  "TEXT's top-level forms, read as data (`read-eval' off); signals when TEXT does not read."
  (with-temp-buffer
    (insert text)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (goto-char (point-min))
    (let ((read-eval nil) (read-circle nil) (forms nil))
      (while (progn (forward-comment (buffer-size)) (not (eobp)))
        (push (read (current-buffer)) forms))
      (nreverse forms))))

(defun drgnx-settings-move--chain (nodes pos)
  "The nodes among NODES (and their children) that hold POS, outermost first."
  (let (chain found)
    (while (setq found (cl-find-if (lambda (n) (and (<= (nth 1 n) pos) (< pos (nth 2 n)))) nodes))
      (push found chain)
      (setq nodes (nth 3 found)))
    (nreverse chain)))

(defun drgnx-settings-move--setter-facts (setters &optional except)
  "SETTERS as comparable lists (VAR KIND VALUE TOP-LEVEL CONDITIONAL), without those of the variable EXCEPT."
  (delq nil (mapcar (lambda (s) (unless (eq (plist-get s :var) except)
                                  (list (plist-get s :var) (plist-get s :kind) (plist-get s :value)
                                        (plist-get s :top-level) (plist-get s :conditional))))
                    setters)))

(defun drgnx-settings-move--check-lisp (old new var &optional appended)
  "Why NEW is not OLD with only VAR's setter taken out (with APPENDED: only the form APPENDED added at its end), as
text; nil when it is exactly that.  Every other top-level form must read the same, in the same order, and every
other setter must stay."
  (condition-case err
      (let ((a (drgnx-settings-move--forms (or old ""))) (b (drgnx-settings-move--forms new)))
        (if appended
            (unless (equal b (append a (list appended))) "the new text is not the old one with the form added")
          (let ((p 0) (s 0) (la (length a)) (lb (length b)))
            (while (and (< p la) (< p lb) (equal (nth p a) (nth p b))) (setq p (1+ p)))
            (while (and (< s (- la p)) (< s (- lb p)) (equal (nth (- la s 1) a) (nth (- lb s 1) b))) (setq s (1+ s)))
            (cond
             ((not (and (= (- la p s) 1) (<= (- lb p s) 1))) "more than the one form changed")
             ((let ((sa (cdr (drgnx-settings-move--parse (or old "")))) (sb (cdr (drgnx-settings-move--parse new))))
                (or (cl-some (lambda (x) (eq (plist-get x :var) var)) sb)
                    (not (equal (drgnx-settings-move--setter-facts sa var) (drgnx-settings-move--setter-facts sb var)))))
              "another setting changed, or the setting is still set")))))
    (error (format "the new text does not read (%s)" (error-message-string err)))))

;;;; Editing your Lisp (in a buffer holding its text)

(defun drgnx-settings-move--replace-form (beg end comment)
  "Replace the form at BEG..END of the current buffer by COMMENT; code that followed it on its line moves to the
next line, at the form's column."
  (let ((rest (save-excursion (goto-char end) (skip-chars-forward " \t") (not (or (eolp) (eq (char-after) ?\;)))))
        (col (save-excursion (goto-char beg) (current-column))))
    (delete-region beg end)
    (goto-char beg)
    (insert comment)
    (when rest
      (let ((p (point))) (skip-chars-forward " \t") (delete-region p (point)))
      (insert "\n" (make-string col ?\s)))))

(defun drgnx-settings-move--remove-span (beg end)
  "Take the elements at BEG..END out of the list around them in the current buffer, and the space they leave:
their own line when they had one, else the gap up to the next element or the closing parenthesis.  A comment is
never taken."
  (let* ((l (save-excursion (goto-char beg) (skip-chars-backward " \t") (point)))
         (r (save-excursion (goto-char end) (skip-chars-forward " \t") (point)))
         (bol (save-excursion (goto-char l) (bolp)))
         (eol (save-excursion (goto-char r) (eolp)))
         (close (eq (char-after r) ?\))))
    (cond ((and bol eol) (delete-region l (min (point-max) (1+ r))))
          ((and bol close)                  ; the paren joins the line above, unless that line ends in a comment
           (let ((p (save-excursion (goto-char l) (skip-chars-backward " \t\n") (point))))
             (delete-region (if (nth 4 (syntax-ppss p)) l p) r)))
          (close (delete-region l r))
          (eol                              ; the next element, on the next line, comes up to this one
           (let ((next (save-excursion (goto-char r) (skip-chars-forward " \t\n") (point))))
             (if (eq (char-after next) ?\;) (delete-region beg r)
               (delete-region l next)
               (goto-char l)
               (unless (eq (char-after) ?\)) (insert " ")))))
          (t (delete-region beg r)))))

(defun drgnx-settings-move--comment-above (pos comment)
  "Put COMMENT on a line of its own above the line of POS, at that line's indentation."
  (goto-char pos)
  (let ((indent (current-indentation)))
    (forward-line 0)
    (insert (make-string indent ?\s) comment "\n")))

(defun drgnx-settings-move--edit-into (file text var setter)
  "TEXT of FILE with SETTER of VAR (the static index's, found again in TEXT) taken out and the comment line left."
  (pcase-let* ((`(,nodes . ,setters) (drgnx-settings-move--parse-or-refuse file text))
               (kind (plist-get setter :kind))
               (here (cl-remove-if-not (lambda (s) (and (eq (plist-get s :var) var) (eq (plist-get s :kind) kind)
                                                        (eql (plist-get s :line) (plist-get setter :line))))
                                       setters))
               (comment (format ";; %s: moved to Settings (%s)" var (drgnx-settings-move--today))))
    (unless (= (length here) 1)
      (drgnx-settings-move--no 'unreadable "%s:%s does not set %s any more: run Move again"
                               (drgnx-settings-move--shown file) (plist-get setter :line) var))
    (let* ((s (car here)) (beg (plist-get s :beg)) (end (plist-get s :end))
           (chain (drgnx-settings-move--chain nodes beg)))
      (with-temp-buffer
        (insert text)
        (set-syntax-table emacs-lisp-mode-syntax-table)
        (pcase kind
          ((or 'setq 'setq-default 'setopt)
           (let ((form (car (last (cl-remove-if-not (lambda (n) (eq (car-safe (car n)) kind)) chain)))))
             (if (= (length (cdr (nth 3 form))) 2)
                 (drgnx-settings-move--replace-form (nth 1 form) (nth 2 form) comment)
               (drgnx-settings-move--remove-span beg end)
               (drgnx-settings-move--comment-above (nth 1 (car chain)) comment))))
          ('customize-set-variable (drgnx-settings-move--replace-form beg end comment))
          ('custom-set-variables
           (let* ((at (cl-position-if (lambda (n) (eq (car-safe (car n)) 'custom-set-variables)) chain))
                  (arg (nth (1+ at) chain)))
             (drgnx-settings-move--remove-span (nth 1 arg) (nth 2 arg))
             (drgnx-settings-move--comment-above (nth 1 (car chain)) comment)))
          ('use-package-custom
           (let* ((up (car (last (cl-remove-if-not (lambda (n) (eq (car-safe (car n)) 'use-package)) chain))))
                  (kids (nth 3 up))
                  (i (cl-position-if (lambda (n) (= (nth 1 n) beg)) kids))
                  (prev (and i (> i 0) (nth (1- i) kids))) (next (and i (nth (1+ i) kids)))
                  (alone (and prev (eq (car prev) :custom) (or (null next) (keywordp (car next))))))
             (drgnx-settings-move--remove-span (if alone (nth 1 prev) beg) end)
             (drgnx-settings-move--comment-above (nth 1 (car chain)) comment)))
          (_ (drgnx-settings-move--no 'conditional "a %s cannot move" kind)))
        (buffer-substring-no-properties (point-min) (point-max))))))

;;;; settings.el's side

(defun drgnx-settings-move--entry (doc var)
  "VAR's top-level entry in DOC, or nil."
  (drgnx-settings-file--find doc var nil))

(defun drgnx-settings-move--entry-state (var)
  "VAR's top-level entry in settings.el now: (VALUE MERGE), or nil when there is none."
  (let* ((doc (drgnx-settings-file-read (drgnx-settings-move--settings-file) 'drgnx-settings))
         (e (and (not (drgnx-settings-doc-failed doc)) (drgnx-settings-move--entry doc var))))
    (and e (list (drgnx-settings-entry-value e) (drgnx-settings-entry-merge e)))))

(defun drgnx-settings-move--settings-texts (var state)
  "settings.el's text now and with VAR's top-level entry made STATE ((VALUE MERGE), or nil: no entry), as the
writer would change it: (OLD-TEXT NEW-TEXT DOC).  A refusal when settings.el cannot be written."
  (let ((file (drgnx-settings-move--settings-file)))
    (condition-case err
        (let* ((doc (drgnx-settings-file-read file 'drgnx-settings))
               (base (drgnx-settings-file--base doc file 'drgnx-settings))
               (base-doc (drgnx-settings-file-parse base 'drgnx-settings))
               (e (drgnx-settings-move--entry base-doc var))
               (new (drgnx-settings-file--in-text base
                      (let ((dups (mapcar (lambda (d) (drgnx-settings-file--delete-edit (plist-get d :beg)
                                                                                        (plist-get d :end)))
                                          (drgnx-settings-file--dups base-doc var nil))))
                        (cond (state
                               (drgnx-settings-file--apply
                                (cons (if e (let ((beg (drgnx-settings-entry-beg e)))
                                              (list beg (drgnx-settings-entry-end e)
                                                    (drgnx-settings-file--entry-text var (car state) (cadr state)
                                                                                     (drgnx-settings-file--column beg))))
                                        (drgnx-settings-file--new-edit nil var (car state) (cadr state)))
                                      dups)))
                              ((or e dups)
                               (drgnx-settings-file--apply (append (and e (list (drgnx-settings-file--remove-edit e))) dups)))
                              (t (buffer-substring-no-properties (point-min) (point-max))))))))
          (list (drgnx-settings-doc-text doc) new doc))
      (drgnx-settings-refused (drgnx-settings-move--no 'settings-file "%s" (error-message-string err))))))

(defun drgnx-settings-move--set-entry (var state)
  "Make VAR's top-level entry in settings.el STATE ((VALUE MERGE), or nil: none), through the settings writer."
  (let ((file (drgnx-settings-move--settings-file)))
    (if state
        (drgnx-settings-file-put file 'drgnx-settings nil var (car state) :merge (cadr state))
      (drgnx-settings-file-remove file 'drgnx-settings nil var))))

;;;; The value in effect

(defun drgnx-settings-move--after-into (var value kind)
  "The value VAR would have at the next start once its setter (of KIND) is gone and settings.el holds VALUE:
\(VALUE . WHO).  A theme over drgnx's (Customize's saved value, a colour theme, `use-package''s) still wins; the
modules' claims merge with VALUE as the resolver merges them."
  (let* ((claims (and (fboundp 'drgnx-settings-claims) (drgnx-settings-claims var)))
         (ours (if claims
                   (car (drgnx-settings-resolve--merge
                         var claims (make-drgnx-settings-entry :var var :value value
                                                               :merge (plist-get (drgnx-setting-meta var) :merge))))
                 value))
         (others (cl-remove-if
                  (lambda (e)
                    (pcase (car e)
                      ((or 'drgnx 'changed) t)
                      ('user (or (null (get var 'saved-value)) (eq kind 'custom-set-variables)))
                      ('use-package (eq kind 'use-package-custom))))
                  (drgnx-settings-prov--theme-values var))))
    (if others
        (cons (cadr (car others)) (if (eq (caar others) 'user) "Customize's saved value"
                                    (format "theme %s" (caar others))))
      (cons ours "Settings"))))

(defun drgnx-settings-move--check-value (var value kind)
  "Refuse unless VAR's value in effect is VALUE and stays VALUE after the move: (BEFORE . AFTER)."
  (unless (default-boundp var)
    (drgnx-settings-move--no 'value-change "%s has no value in this Emacs: its line did not run" var))
  (let ((before (default-value var)))
    (unless (equal before value)
      (if (and (eq kind 'setq) (local-variable-if-set-p var))
          (drgnx-settings-move--no 'value-change "a `setq' of %s sets only the buffer it ran in, so its default is %s, \
not %s (did you mean `setq-default'?): moved, the value would change"
                                   var (drgnx-settings-move--print before) (drgnx-settings-move--print value))
        (drgnx-settings-move--no 'value-change "%s is %s now, not this line's %s: something after it sets it"
                                 var (drgnx-settings-move--print before) (drgnx-settings-move--print value))))
    (let ((after (drgnx-settings-move--after-into var value kind)))
      (unless (equal (car after) before)
        (drgnx-settings-move--no 'value-change "moved, %s would be %s (%s wins), not %s as now" var
                                 (drgnx-settings-move--print (car after)) (cdr after)
                                 (drgnx-settings-move--print before)))
      (cons before (car after)))))

(defun drgnx-settings-move--check-certain (var setter)
  "Refuse unless provenance names SETTER's line as the source of VAR's value, and is certain of it."
  (let ((e (drgnx-settings-explain var)))
    (unless (and (plist-get e :certain) (plist-get e :file)
                 (drgnx-settings-move--same-file-p (plist-get e :file) (plist-get setter :file))
                 (eql (plist-get e :line) (plist-get setter :line)))
      (drgnx-settings-move--no 'uncertain "where %s comes from is not certain (%s): Move needs that line" var
                               (or (plist-get e :source) "unknown")))))

;;;; Plans

(defun drgnx-settings-move--at (setter)
  "\"FILE:LINE\" of SETTER."
  (format "%s:%s" (file-name-nondirectory (plist-get setter :file)) (plist-get setter :line)))

(defun drgnx-settings-move--diff-lines (name old new)
  "A unified diff of OLD and NEW (texts; OLD nil: no file) for file NAME, two lines of context: one hunk, as a move
changes one place.  The empty string when they are equal."
  (if (equal old new) ""
    (let* ((a (and old (split-string old "\n"))) (b (split-string new "\n"))
           (la (length a)) (lb (length b)) (p 0) (s 0))
      (while (and (< p la) (< p lb) (equal (nth p a) (nth p b))) (setq p (1+ p)))
      (while (and (< s (- la p)) (< s (- lb p)) (equal (nth (- la s 1) a) (nth (- lb s 1) b))) (setq s (1+ s)))
      (let* ((from (max 0 (- p 2))) (ea (- la s)) (eb (- lb s))
             (ta (min la (+ ea 2))) (tb (min lb (+ eb 2)))
             (lines (lambda (list beg end prefix)
                      (mapconcat (lambda (l) (concat prefix l "\n")) (cl-subseq list beg end) ""))))
        (concat (if old (format "--- a/%s\n" name) "--- /dev/null\n") (format "+++ b/%s\n" name)
                (format "@@ -%d,%d +%d,%d @@\n" (if a (1+ from) 0) (- ta from) (1+ from) (- tb from))
                (funcall lines b from p " ") (funcall lines a p ea "-") (funcall lines b p eb "+")
                (funcall lines b eb tb " "))))))

(defun drgnx-settings-move--plan-into (var)
  "The plan of Move into Settings for VAR, or a refusal thrown."
  (let* ((setters (drgnx-settings-prov--setters var (drgnx-settings-prov--user-files)))
         (s (car setters)) (kind (plist-get s :kind)) (value (plist-get s :value)) (file (plist-get s :file)))
    (unless setters (drgnx-settings-move--no 'not-set "your Lisp does not set %s" var))
    (when (cdr setters)
      (drgnx-settings-move--no 'second-setter "your Lisp sets %s in %d places (%s): Move needs exactly one" var
                               (length setters) (mapconcat #'drgnx-settings-move--at setters ", ")))
    (when (or (plist-get s :conditional) (not (or (plist-get s :top-level) (eq kind 'use-package-custom))))
      (drgnx-settings-move--no 'conditional "%s sets %s only when something holds (`when', `unless', \
`with-eval-after-load', a hook, a deferred `use-package'): moved, it would always apply" (drgnx-settings-move--at s) var))
    (unless (and (plist-get s :const-p) (not (drgnx-settings-file--why-not value))
                 (eq (drgnx-settings-file--unquote value) value))
      (drgnx-settings-move--no 'computed "%s computes the value of %s (%s): only a constant moves into Settings"
                               (drgnx-settings-move--at s) var (drgnx-settings-move--print value)))
    (pcase-let* ((`(,before . ,after) (prog1 (drgnx-settings-move--check-value var value kind)
                                        (drgnx-settings-move--check-certain var s)))
                 (old (or (drgnx-settings-move--lisp-text file)
                          (drgnx-settings-move--no 'unreadable "%s is gone" (drgnx-settings-move--shown file))))
                 (new (drgnx-settings-move--edit-into file old var s))
                 (state-before (drgnx-settings-move--entry-state var))
                 (state-after (list value (cadr state-before)))
                 (`(,sold ,snew ,_) (drgnx-settings-move--settings-texts var state-after)))
      (when-let* ((why (drgnx-settings-move--check-lisp old new var)))
        (drgnx-settings-move--no 'unreadable "the edit of %s does not check (%s): nothing was changed"
                                 (drgnx-settings-move--shown file) why))
      (list :direction 'into :var var :value value :kind kind :line (plist-get s :line)
            :lisp-file file :lisp-old old :lisp-new new
            :settings-file (drgnx-settings-move--settings-file) :settings-old sold :settings-new snew
            :entry-before state-before :entry-after state-after :before before :after after))))

(defun drgnx-settings-move--plan-back (var file)
  "The plan of Move to My Lisp for VAR into FILE, or a refusal thrown."
  (let* ((sf (drgnx-settings-move--settings-file))
         (doc (drgnx-settings-file-read sf 'drgnx-settings))
         (e (and (not (drgnx-settings-doc-failed doc)) (drgnx-settings-move--entry doc var))))
    (when (drgnx-settings-doc-failed doc)
      (drgnx-settings-move--no 'settings-file "settings.el has a mistake: fix it first"))
    (unless e (drgnx-settings-move--no 'not-set "settings.el has no entry for %s" var))
    (unless (drgnx-settings-prov--user-file-p file)
      (drgnx-settings-move--no 'not-your-lisp "%s is not one of your Lisp files" (drgnx-settings-move--shown file)))
    (let* ((value (drgnx-settings-entry-value e))
           (form `(setopt ,var ',value))
           (old (drgnx-settings-move--lisp-text file)))
      (when (and (default-boundp var) (not (equal (default-value var) value)))
        (drgnx-settings-move--no 'value-change "%s is %s now, not settings.el's %s: moved to your Lisp, the value would \
change" var (drgnx-settings-move--print (default-value var)) (drgnx-settings-move--print value)))
      (when old (drgnx-settings-move--parse-or-refuse file old))
      (pcase-let* ((new (concat (or old (format ";;; %s --- my drgnx configuration -*- lexical-binding: t -*-\n"
                                                (file-name-nondirectory file)))
                                (if (or (null old) (string-empty-p old) (string-suffix-p "\n" old)) "" "\n")
                                (format "\n;; %s: moved from Settings (%s)\n(setopt %s '%s)\n" var
                                        (drgnx-settings-move--today) (drgnx-settings-move--print var)
                                        (drgnx-settings-move--print value))))
                   (`(,sold ,snew ,_) (drgnx-settings-move--settings-texts var nil)))
        (when-let* ((why (drgnx-settings-move--check-lisp old new var form)))
          (drgnx-settings-move--no 'unreadable "the edit of %s does not check (%s): nothing was changed"
                                   (drgnx-settings-move--shown file) why))
        (list :direction 'back :var var :value value :lisp-file file :lisp-old old :lisp-new new :form form
              :settings-file sf :settings-old sold :settings-new snew
              :entry-before (list value (drgnx-settings-entry-merge e)) :entry-after nil
              :before (if (default-boundp var) (default-value var) value) :after value)))))

(defun drgnx-settings-move-plan (var &optional direction file)
  "What a move of VAR would do now, nothing written: a plist.
DIRECTION `into' (the default): Move into Settings, from your Lisp into settings.el.  `back': Move to My Lisp,
from settings.el to the end of FILE (default config.el).  A refusal is (:refused REASON :why TEXT), REASON one of
`not-set', `second-setter', `conditional', `computed', `value-change', `uncertain', `unreadable', `settings-file' or
`not-your-lisp'.  Otherwise (:direction :var :value :lisp-file :lisp-old :lisp-new :settings-file :settings-old
:settings-new :entry-before :entry-after :before :after), the texts of both files now and after, VAR's settings.el
entry before and after ((VALUE MERGE) or nil), and its value in effect before and after (equal, or it is refused)."
  (let ((var (indirect-variable var)))
    (catch 'drgnx-settings-move--no
      (if (eq direction 'back)
          (drgnx-settings-move--plan-back var (or file (expand-file-name "config.el" (drgnx-user-dir))))
        (drgnx-settings-move--plan-into var)))))

(defun drgnx-settings-move-diff (plan)
  "The diff of both files PLAN changes, as text: your Lisp file, then settings.el."
  (concat (drgnx-settings-move--diff-lines (file-name-nondirectory (plist-get plan :lisp-file))
                                           (plist-get plan :lisp-old) (plist-get plan :lisp-new))
          (drgnx-settings-move--diff-lines "settings.el" (plist-get plan :settings-old) (plist-get plan :settings-new))))

;;;; Carrying it out

(defun drgnx-settings-move--visiting (file)
  "The buffer visiting FILE, or nil."
  (let ((file-name-handler-alist nil)) (find-buffer-visiting file)))

(defun drgnx-settings-move--with-lock (file fn)
  "Call FN holding FILE's drgnx lock (a busy lock refuses), after refusing a modified buffer visiting FILE."
  (when-let* ((b (drgnx-settings-move--visiting file)))
    (when (buffer-modified-p b)
      (user-error "Settings: %s has unsaved edits in a buffer; save or revert it first" (drgnx-settings-move--shown file))))
  (let ((held (condition-case nil (drgnx-file--lock (drgnx-file--target file) drgnx-settings-file-lock-timeout)
                (drgnx-file-busy (user-error "Settings: %s is being written by another drgnx; try again"
                                             (drgnx-settings-move--shown file))))))
    (unwind-protect (funcall fn) (drgnx-file--unlock held))))

(defun drgnx-settings-move--write-lisp (file text)
  "Write TEXT to your Lisp FILE atomically (nil: delete the file this move made)."
  (if text (drgnx-file-write-text file text) (delete-file file)))

(defun drgnx-settings-move--after (plan)
  "After both files of PLAN were written: a buffer visiting the Lisp file is reverted, settings.el applies again
\(`drgnx-settings-live-sync')."
  (when-let* ((b (drgnx-settings-move--visiting (plist-get plan :lisp-file))))
    (unless (buffer-modified-p b)
      (let ((inhibit-interaction t)) (ignore-errors (with-current-buffer b (revert-buffer t t t))))))
  (drgnx-settings-live-sync (plist-get plan :settings-file)))

(defun drgnx-settings-move--keep-value (var value)
  "Give VAR VALUE again with `setopt' when letting go of settings.el's entry took it away (Move to My Lisp: the
form it wrote would only run at the next start)."
  (unless (and (default-boundp var) (equal (default-value var) value))
    (condition-case err (eval `(setopt ,var ',value) t)
      (error (drgnx-settings-file--warn (format "%s could not be set to %s: %s" var (drgnx-settings-move--print value)
                                                (error-message-string err)))))))

(defun drgnx-settings-move-apply (plan)
  "Carry out PLAN of `drgnx-settings-move-plan' (not a refusal): the record Settings: Undo Move uses.
Both files must still be as PLAN read them, else nothing is written.  Under the Lisp file's lock: a backup of it
beside it (`drgnx-file-backup'), settings.el's entry through the settings writer, then the Lisp file's new text,
atomically; when that fails, the entry goes back.  Then settings.el applies again; Move to My Lisp sets the value with
its own `setopt' when letting go of the entry changed it."
  (when (plist-get plan :refused) (error "drgnx-settings-move-apply: a refused plan"))
  (let* ((file (plist-get plan :lisp-file)) (var (plist-get plan :var)) (record (copy-sequence plan)))
    (drgnx-settings-move--with-lock
     file
     (lambda ()
       (unless (and (equal (drgnx-settings-move--lisp-text file) (plist-get plan :lisp-old))
                    (equal (drgnx-settings-doc-text (drgnx-settings-file-read (plist-get plan :settings-file)
                                                                              'drgnx-settings))
                           (plist-get plan :settings-old)))
         (user-error "Settings: %s or settings.el changed since the preview; nothing was changed, run Move again"
                     (drgnx-settings-move--shown file)))
       (setq record (plist-put record :bak (and (plist-get plan :lisp-old) (drgnx-file-backup file))))
       (drgnx-settings-move--set-entry var (plist-get plan :entry-after))
       (condition-case err (drgnx-settings-move--write-lisp file (plist-get plan :lisp-new))
         (error (ignore-errors (drgnx-settings-move--set-entry var (plist-get plan :entry-before)))
                (signal (car err) (cdr err))))))
    (drgnx-settings-move--after plan)
    (when (eq (plist-get plan :direction) 'back) (drgnx-settings-move--keep-value var (plist-get plan :value)))
    (push record drgnx-settings-move--undo)
    (when (> (length drgnx-settings-move--undo) drgnx-settings-move-undo-kept)
      (setq drgnx-settings-move--undo (cl-subseq drgnx-settings-move--undo 0 drgnx-settings-move-undo-kept)))
    record))

(defun drgnx-settings-move-undo ()
  "Settings: Undo Move: put both files of the last move back as they were.
Refused when either changed since the move (the Lisp file's backup is named); nothing is written then.  Returns
the record undone."
  (interactive)
  (let* ((r (or (car drgnx-settings-move--undo) (user-error "Settings: there is no move to undo")))
         (file (plist-get r :lisp-file)) (var (plist-get r :var)))
    (drgnx-settings-move--with-lock
     file
     (lambda ()
       (unless (equal (drgnx-settings-move--lisp-text file) (plist-get r :lisp-new))
         (user-error "Settings: %s changed since the move; it was not changed%s" (drgnx-settings-move--shown file)
                     (if (plist-get r :bak) (format " (its copy from before: %s)" (plist-get r :bak)) "")))
       (unless (equal (drgnx-settings-move--entry-state var) (plist-get r :entry-after))
         (user-error "Settings: %s's entry in settings.el changed since the move; nothing was changed" var))
       (drgnx-settings-move--set-entry var (plist-get r :entry-before))
       (condition-case err (drgnx-settings-move--write-lisp file (plist-get r :lisp-old))
         (error (ignore-errors (drgnx-settings-move--set-entry var (plist-get r :entry-after)))
                (signal (car err) (cdr err))))))
    (pop drgnx-settings-move--undo)
    (drgnx-settings-move--after r)
    (when (eq (plist-get r :direction) 'into) (drgnx-settings-move--keep-value var (plist-get r :value)))
    (when (called-interactively-p 'any)
      (message "Settings: the move of %s is undone: %s and settings.el are as they were" var
               (file-name-nondirectory file)))
    r))

;;;; The commands

(defun drgnx-settings-move--var-at-point ()
  "The variable of the Lisp files page's row at point, or the symbol at point, or nil."
  (require 'thingatpt)
  (or (get-text-property (point) 'drgnx-settings-lisp-page-var)
      (let ((s (symbol-at-point))) (and s (boundp s) s))))

(defun drgnx-settings-move--read-var (prompt candidates)
  "The variable on the Lisp files page's row at point, else one read with PROMPT among CANDIDATES (symbols)."
  (or (get-text-property (point) 'drgnx-settings-lisp-page-var)
      (let ((default (drgnx-settings-move--var-at-point)))
        (intern (completing-read (format-prompt prompt default) (mapcar #'symbol-name candidates) nil nil nil nil
                                 (and default (symbol-name default)))))))

(defun drgnx-settings-move--preview (plan title)
  "Show PLAN's diff and its value before and after in a buffer, headed TITLE; the buffer."
  (let ((buf (get-buffer-create "*drgnx move*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert title "\n\n"
                (format "Value in effect now:  %s\n" (drgnx-settings-move--print (plist-get plan :before)))
                (format "After the move:       %s\n\n" (drgnx-settings-move--print (plist-get plan :after)))
                (drgnx-settings-move-diff plan))
        (goto-char (point-min)))
      (diff-mode)
      (setq buffer-read-only t))
    (display-buffer buf)
    buf))

(defun drgnx-settings-move--run (plan title question)
  "Preview PLAN under TITLE, ask QUESTION, and carry it out on yes: the record, or nil."
  (when (plist-get plan :refused) (user-error "Settings: %s" (plist-get plan :why)))
  (let ((buf (drgnx-settings-move--preview plan title)))
    (unwind-protect
        (when (y-or-n-p question)
          (prog1 (drgnx-settings-move-apply plan)
            (message "Settings: %s moved; Settings: Undo Move puts both files back" (plist-get plan :var))))
      (quit-windows-on buf))))

(defun drgnx-settings-move-into-settings (var)
  "Settings: Move into Settings: VAR's line in your Lisp becomes an entry of settings.el (design §8.3).
Only a certain line, a top-level unconditional setter, the only one of VAR in your Lisp, a constant value, and only
when the value in effect stays the same; the diff of both files is shown first.  On the Lisp files page, the row's
variable."
  (interactive (list (drgnx-settings-move--read-var
                      "Move into Settings"
                      (delete-dups (mapcar (lambda (s) (plist-get s :var))
                                           (apply #'append
                                                  (mapcar (lambda (f) (plist-get (ignore-errors (drgnx-lisp-index-get f))
                                                                                 :setters))
                                                          (drgnx-settings-prov--user-files))))))))
  (drgnx-settings-move--run (drgnx-settings-move-plan var 'into) (format "Move %s into Settings" var)
                            (format "Move %s into Settings? " var)))

(defun drgnx-settings-move-to-lisp (var &optional file)
  "Settings: Move to My Lisp: VAR's entry of settings.el becomes `(setopt VAR \\='VALUE)' at the end of config.el
\(with a prefix argument, a file of yours you choose); the diff of both files is shown first."
  (interactive
   (list (drgnx-settings-move--read-var
          "Move to my Lisp"
          (let ((doc (drgnx-settings-file-read (drgnx-settings-move--settings-file) 'drgnx-settings)))
            (cl-loop for e in (drgnx-settings-doc-entries doc)
                     unless (or (drgnx-settings-entry-scope e) (keywordp (drgnx-settings-entry-var e)))
                     collect (drgnx-settings-entry-var e))))
         (and current-prefix-arg (read-file-name "Into your Lisp file: " (drgnx-user-dir) nil t))))
  (let ((plan (drgnx-settings-move-plan var 'back file)))
    (drgnx-settings-move--run plan (format "Move %s to %s" var (if (plist-get plan :lisp-file)
                                                                   (file-name-nondirectory (plist-get plan :lisp-file))
                                                                 "your Lisp"))
                              (format "Move %s to your Lisp? " var))))

(provide 'drgnx-settings-move)
;;; drgnx-settings-move.el ends here
