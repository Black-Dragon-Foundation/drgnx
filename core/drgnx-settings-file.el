;;; drgnx-settings-file.el --- Settings: settings files, read and written -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 6: a settings file's shape, read as data (never `load'ed), its writer and its printer
;; (docs/develop/settings.md, "The writer"; the design's §5.2 and §6).
;; - `drgnx-settings-file-parse' and `drgnx-settings-file-read' give a `drgnx-settings-doc': the file's meta, its
;;   entries with their scope paths and positions, and its problems.  A file that does not read (a syntax mistake, the
;;   wrong head, no `:version', a newer one) is `failed' with one problem; a malformed entry is a problem of its own
;;   and the rest stands.  The rules are `huginn''s (runtime/crates/huginn/src/form.rs), the Rust twin.
;; - `drgnx-settings-file-put', `-remove' and `-sort' change the file through `drgnx-file-update' (its lock, a fresh
;;   read): one entry is one span of text, a new one goes at its sorted place, comments go with their entry, and
;;   nothing else in the file moves.  The new text is read back before the rename: every other entry must be as it
;;   was.  `drgnx-settings-print' prints values the same way every time.
;; - `drgnx-settings-file-state' adds the config layer's last good copy of settings.el (config file `settings',
;;   shape `settings').
;; Nothing here prompts.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-file)
(require 'drgnx-config)

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))

;; A `file-error' too, as `drgnx-config-refused' is: its text prints as it is.
(define-error 'drgnx-settings-refused "" '(user-error file-error))

(defconst drgnx-settings-file-heads '(drgnx-settings drgnx-workspace-settings)
  "The heads of a settings file's one form: settings.el's, and a workspace file's.")

(defconst drgnx-settings-file-version 1
  "The format of settings files this drgnx reads and writes: their `:version'.")

(defconst drgnx-settings-file-max-bytes 1048576
  "The largest settings file read or written (1 MiB), as the config layer has it.")

(defconst drgnx-settings-file-shared-max-bytes 65536
  "The largest .drgnx/settings.el read or written (64 KiB): a repository's file is someone else's.")

(defconst drgnx-settings-print-width 100
  "The column up to which `drgnx-settings-print' keeps a value on one line.")

(defvar drgnx-settings-file-lock-timeout 1.0
  "Seconds a write waits for a settings file's lock before it is refused.")

(defvar drgnx-settings-file-written-functions nil
  "Functions called with (FILE BEFORE AFTER) after drgnx wrote settings file FILE: BEFORE and AFTER are its
`drgnx-settings-doc's.  They run with `inhibit-interaction' t; an error is one notice.")

(defconst drgnx-settings-file-global-header
  ";;; settings.el --- your settings  -*- lexical-binding: t; mode: lisp-data -*-
;; Written by drgnx Settings and by you. Kept sorted; a comment above an entry stays with it.
;; Values are data: write 80 or (a b), not '(a b). Code goes in config.el. drgnx reads this file; never load it.
"
  "The three lines a new settings.el starts with (design §5.2).")

(drgnx-config-define 'settings :file "settings.el" :shape 'settings :schema '(settings drgnx-settings)
                     :version drgnx-settings-file-version :default '(drgnx-settings :version 1)
                     :header drgnx-settings-file-global-header
                     :doc "Your settings, one entry per variable: written by the Settings page and by you, read as data")

(cl-defstruct (drgnx-settings-doc (:copier nil))
  "A settings file read: FILE (nil for a text), HEAD, META (a plist: `:version', `:roots', `:project'), ENTRIES (in
file order), PROBLEMS (plists :text :line :column, with :file, and :beg :end for a problem of the text), FAILED (t when
the file does not read: one problem says why), TEXT (nil when the file is missing) and STAMP (`drgnx-file-stamp')."
  file head meta entries problems failed text stamp)

(cl-defstruct (drgnx-settings-entry (:copier nil))
  "One entry: VAR, VALUE (one top-level `quote' or `function' dropped), MERGE (the `:merge' kind, or nil), SCOPE (a
scope path: nil, ((:mode . M)), ((:dir . \"D/\")) or ((:dir . \"D/\") (:mode . M))), BEG and END (positions in a
buffer that holds the doc's text from its start) and LINE.  An `(:eval FORM…)' section is an entry of VAR `:eval'
whose VALUE is the list of its forms."
  var value merge scope beg end line)

;;;; Reading

(defun drgnx-settings-file--check-head (head)
  "An `error' (the caller's bug) unless HEAD is a settings head."
  (unless (memq head drgnx-settings-file-heads) (error "drgnx-settings-file: %S is not a settings file's head" head)))

(defun drgnx-settings-file--name (file)
  "FILE, expanded with no file name handler."
  (let ((file-name-handler-alist nil)) (expand-file-name file)))

(defun drgnx-settings-file--default-max (file)
  "The size limit of FILE: 64 KiB in a .drgnx folder (a repository's), else 1 MiB."
  (if (equal (file-name-nondirectory (directory-file-name (file-name-directory (drgnx-settings-file--name file))))
             ".drgnx")
      drgnx-settings-file-shared-max-bytes
    drgnx-settings-file-max-bytes))

(defmacro drgnx-settings-file--in-text (text &rest body)
  "BODY in a temp buffer holding TEXT from its start, with the Lisp data syntax table, point at the start."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (insert ,text)
     (set-syntax-table lisp-data-mode-syntax-table)
     (goto-char (point-min))
     ,@body))

(defun drgnx-settings-file--dot-p ()
  "Whether point is at a dotted pair's dot (as `drgnx-file--scan' tells it from a symbol's)."
  (and (eq (char-after) ?.)
       (let ((next (char-after (1+ (point)))))
         (or (null next) (<= next 32) (memq next '(#xa0 ?\" ?\' ?\; ?\( ?\[ ?# ?? ?\` ?\,))))))

(defun drgnx-settings-file--elements (open)
  "The elements of the list whose open paren is at OPEN in the current buffer: ((DATUM BEG END)…) in order.
A dotted tail that is a list (or nil) joins the list, as `read' reads it; any other dotted tail is an `error'."
  (save-excursion
    (goto-char (1+ open))
    (let ((out nil) (depth 0) (read-circle nil) (read-symbol-shorthands nil))
      (catch 'done
        (while t
          (forward-comment (buffer-size))
          (cond ((eobp) (error "The list does not end"))
                ((eq (char-after) ?\))
                 (forward-char)
                 (if (zerop depth) (throw 'done nil) (setq depth (1- depth))))
                ((drgnx-settings-file--dot-p)
                 (forward-char)
                 (forward-comment (buffer-size))
                 (if (eq (char-after) ?\() (progn (forward-char) (setq depth (1+ depth)))
                   (when (read (current-buffer)) (error "A dotted list: write it as a plain list"))))
                (t (let ((beg (point)) (x (read (current-buffer))))
                     (push (list x beg (point)) out))))))
      (nreverse out))))

(defun drgnx-settings-file--unquote (value)
  "VALUE without one top-level `quote' or `function': \\='X and #\\='X mean X."
  (if (and (consp value) (memq (car value) '(quote function)) (consp (cdr value)) (null (cddr value)))
      (cadr value)
    value))

(defun drgnx-settings-file--failed (head text problem)
  "A failed doc of HEAD for TEXT, whose one PROBLEM says why."
  (make-drgnx-settings-doc :head head :text text :failed t :problems (list problem)))

(defun drgnx-settings-file--parse-form (text data head)
  "TEXT, which reads as the one data form DATA, as a settings doc of HEAD (file and stamp not set)."
  (drgnx-settings-file--in-text text
    (forward-comment (buffer-size))
    (let ((top (point)) (workspace (eq head 'drgnx-workspace-settings))
          (meta nil) (entries nil) (problems nil) (seen (make-hash-table :test 'equal)))
      (cl-labels
          ((fail (pos why) (throw 'failed (drgnx-settings-file--failed head text (drgnx-file--problem why pos))))
           (problem (beg end why &rest more)
             (push (append (drgnx-file--problem why beg) (list :beg beg :end end) more) problems))
           (inside (beg scope skip)
             (dolist (e (nthcdr skip (drgnx-settings-file--elements beg)))
               (item (car e) (nth 1 e) (nth 2 e) scope)))
           (item (x beg end scope)
             (cond ((not (and (consp x) (proper-list-p x))) (problem beg end "expected an entry (VARIABLE VALUE)"))
                   ((not (symbolp (car x))) (problem beg end "an entry starts with a variable name"))
                   ((eq (car x) :mode)
                    (cond ((assq :mode scope) (problem beg end ":mode cannot sit inside :mode"))
                          ((not (and (cdr x) (symbolp (cadr x)))) (problem beg end "(:mode MODE …) needs a mode name"))
                          ((or (keywordp (cadr x)) (memq (cadr x) '(nil t)))
                           (problem beg end (format "%s is not a mode name" (cadr x))))
                          (t (inside beg (append scope (list (cons :mode (cadr x)))) 2))))
                   ((eq (car x) :dir)
                    (cond ((not workspace) (problem beg end ":dir is only for workspace files"))
                          (scope (problem beg end ":dir cannot sit inside another section"))
                          ((not (stringp (cadr x))) (problem beg end "(:dir \"SUBDIR/\" …) needs a directory string"))
                          (t (inside beg (list (cons :dir (cadr x))) 2))))
                   ((eq (car x) :eval)
                    (if (not workspace) (problem beg end ":eval is only for workspace files")
                      (push (make-drgnx-settings-entry :var :eval :value (cdr x) :scope scope :beg beg :end end
                                                       :line (line-number-at-pos beg t))
                            entries)))
                   ((keywordp (car x)) (problem beg end (format "unknown section %s" (car x))))
                   ((memq (car x) '(nil t)) (problem beg end (format "%s is not a variable" (car x))))
                   (t (entry x beg end scope))))
           (entry (x beg end scope)
             (let ((var (car x)) (rest (cdr x)) (line (line-number-at-pos beg t)))
               (if (not (or (and rest (null (cdr rest)))
                            (and (= (length rest) 3) (eq (nth 1 rest) :merge) (symbolp (nth 2 rest)))))
                   (problem beg end (format "%s: an entry is (VARIABLE VALUE) or (VARIABLE VALUE :merge KIND)" var))
                 (let ((first (gethash (cons var scope) seen)))
                   (if first
                       (problem beg end (format "%s is set twice in the same place (lines %d and %d); the first stands"
                                                var first line)
                                :var var :scope scope)
                     (puthash (cons var scope) line seen)
                     (push (make-drgnx-settings-entry :var var :value (drgnx-settings-file--unquote (car rest))
                                                      :merge (nth 2 rest) :scope scope :beg beg :end end :line line)
                           entries)))))))
        (catch 'failed
          (unless (and (consp data) (proper-list-p data)) (fail top (format "expected (%s …)" head)))
          (unless (eq (car data) head) (fail top (format "expected the head %s" head)))
          (let ((els (condition-case err (cdr (drgnx-settings-file--elements top))
                       (error (fail top (error-message-string err)))))
                (version nil))
            (while (and els (keywordp (car (car els))))
              (let ((k (car els)))
                (if (null (cdr els))
                    (progn (problem (nth 1 k) (nth 2 k) (format "%s has no value" (car k))) (setq els nil))
                  (cond ((not (memq (car k) '(:version :roots :project)))
                         (problem (nth 1 k) (nth 2 k) (format "unknown meta key %s" (car k))))
                        ((plist-member meta (car k))
                         (problem (nth 1 k) (nth 2 k) (format "%s is given twice" (car k))))
                        (t (setq meta (append meta (list (car k) (car (cadr els)))))
                           (when (eq (car k) :version) (setq version (cadr els)))))
                  (setq els (cddr els)))))
            (let ((v (car version)))
              (cond ((null version) (fail top "the file has no :version"))
                    ((eql v drgnx-settings-file-version))
                    ((and (integerp v) (> v drgnx-settings-file-version))
                     (fail (nth 1 version) (format "version %d was written by a newer drgnx" v)))
                    (t (fail (nth 1 version) "unsupported :version"))))
            (condition-case err (dolist (e els) (item (car e) (nth 1 e) (nth 2 e) nil))
              (error (fail top (error-message-string err))))
            (make-drgnx-settings-doc :head head :meta meta :entries (nreverse entries) :problems (nreverse problems)
                                     :text text)))))))

(defun drgnx-settings-file-parse (text head)
  "TEXT, a settings file's text of head HEAD (`drgnx-settings' or `drgnx-workspace-settings'), as a
`drgnx-settings-doc'.  TEXT must be one data form, (HEAD :version 1 META… ENTRY… SECTION…), through the config
layer's token check (`drgnx-file--parse'): else the doc is `failed', with one problem naming the line and the
column.  An entry is (VAR VALUE) or (VAR VALUE :merge KIND), its VALUE never evaluated (one leading \\=' or #\\='
dropped).  A section is (:mode MODE ENTRY…), and in a workspace file (:dir \"SUBDIR/\" ENTRY…) and (:eval FORM…); a
`:mode' may sit inside a `:dir'.  A malformed entry or section, one in the wrong file and a second entry for a
variable in the same scope path (the first stands) are problems of their own; the rest stands."
  (drgnx-settings-file--check-head head)
  (let ((r (drgnx-file--parse text)))
    (pcase (car r)
      ('ok (drgnx-settings-file--parse-form text (cdr r) head))
      ('absent (drgnx-settings-file--failed head text (list :text "the file holds no form" :line 1 :column 1)))
      (_ (drgnx-settings-file--failed head text (cdr r))))))

(cl-defun drgnx-settings-file-read (file head &key max-bytes)
  "Settings FILE of head HEAD read as data: a `drgnx-settings-doc' (`drgnx-settings-file-parse'), never `load'ed.
A missing FILE gives an empty doc (no text).  MAX-BYTES defaults to 64 KiB for a .drgnx/settings.el and 1 MiB for
any other: a bigger file fails, never truncated.  Every problem names FILE."
  (drgnx-settings-file--check-head head)
  (let* ((name (drgnx-settings-file--name file))
         (r (drgnx-file-read name :max-bytes (or max-bytes (drgnx-settings-file--default-max name))))
         (text (plist-get r :text))
         (doc (pcase (plist-get r :status)
                ('ok (drgnx-settings-file--parse-form text (plist-get r :data) head))
                ('absent (if text (drgnx-settings-file-parse text head) (make-drgnx-settings-doc :head head)))
                (_ (drgnx-settings-file--failed head text (plist-get r :problem))))))
    (setf (drgnx-settings-doc-file doc) name
          (drgnx-settings-doc-stamp doc) (plist-get r :stamp)
          (drgnx-settings-doc-problems doc) (mapcar (lambda (p) (cons :file (cons name p)))
                                                    (drgnx-settings-doc-problems doc)))
    doc))

(defun drgnx-settings-file--config-name (file)
  "The config file of shape `settings' whose path is FILE, or nil."
  (let ((name (drgnx-settings-file--name file)))
    (cl-find-if (lambda (n) (and (eq (plist-get (drgnx-config-definition n) :shape) 'settings)
                                 (equal (drgnx-config-file n) name)))
                (drgnx-config-names '(config state)))))

(defun drgnx-settings-file-state (file head)
  "Settings FILE (head HEAD) and its fallback: (:doc DOC :last-good DOC-OR-NIL :problem P).
DOC is FILE read now; P the problem that fails it, or nil.  When FILE is a config file of shape `settings'
\(settings.el), the config layer's state is brought up to date (it keeps the last good copy of a file that reads,
and says a mistake once), and LAST-GOOD is that copy read, as a doc whose file is the copy, when it reads; else nil.
While FILE reads, the copy holds the same text."
  (let* ((doc (drgnx-settings-file-read file head))
         (name (drgnx-settings-file--config-name file))
         (good (when name
                 (drgnx-config-problem name)
                 (let ((copy (drgnx-config-last-good-file name)))
                   (when (file-exists-p copy)
                     (let ((g (drgnx-settings-file-read copy head
                                                        :max-bytes (plist-get (drgnx-config-definition name) :max-bytes))))
                       (and (drgnx-settings-doc-text g) (not (drgnx-settings-doc-failed g)) g)))))))
    (list :doc doc :last-good good
          :problem (and (drgnx-settings-doc-failed doc) (car (drgnx-settings-doc-problems doc))))))

;;;; Printing

(defmacro drgnx-settings-file--printing (&rest body)
  "BODY with every print variable that changes `prin1''s text bound, whatever the user set: no length or level
limit, no `#N=', no quote shorthand, newlines and control characters escaped, other characters as UTF-8 text."
  (declare (indent 0) (debug t))
  `(let ((print-length nil) (print-level nil) (print-circle nil) (print-quoted nil) (print-gensym nil)
         (print-escape-newlines t) (print-escape-control-characters t) (print-escape-nonascii nil)
         (print-escape-multibyte nil) (print-integers-as-characters nil) (float-output-format nil))
     ,@body))

(defun drgnx-settings-file--prin1 (x)
  "X's `prin1' text, under `drgnx-settings-file--printing'."
  (drgnx-settings-file--printing (prin1-to-string x)))

(defun drgnx-settings-file--why-not (value)
  "Why VALUE cannot be written to a settings file, as text; nil when it can.  Plain data only (the subset both readers
share, design §11.2): symbols, numbers, strings with no properties, lists, dotted pairs and vectors, no deeper than
`drgnx-file-max-depth', not circular; no unibyte or raw-byte string, no character UTF-8 cannot hold."
  (catch 'why
    (cl-labels ((walk (x depth)
                  (cond ((symbolp x))
                        ((or (numberp x) (stringp x))
                         (when-let* ((why (drgnx-file--walk x))) (throw 'why (drgnx-file--why-text why)))
                         (when (and (stringp x)
                                    (cl-some (lambda (c) (or (> c #x10ffff) (<= #xd800 c #xdfff))) x))
                           (throw 'why "a character UTF-8 cannot hold")))
                        ((>= depth drgnx-file-max-depth) (throw 'why (drgnx-file--why-text '(depth))))
                        ((vectorp x) (cl-loop for e across x do (walk e (1+ depth))))
                        ((consp x)
                         (when (and (not (proper-list-p x)) (consp (nthcdr (safe-length x) x)))
                           (throw 'why "a circular list"))
                         (while (consp x) (walk (car x) (1+ depth)) (setq x (cdr x)))
                         (walk x (1+ depth)))
                        (t (throw 'why (drgnx-file--why-text (list (type-of x))))))))
      (walk value 0)
      nil)))

(defun drgnx-settings-file--groups (list)
  "LIST's elements grouped into the lines of a broken list: one element per line, or, when LIST holds a keyword,
the elements before the first keyword, then each keyword with its value."
  (if (not (cl-some #'keywordp list)) (mapcar #'list list)
    (let ((groups nil) (head nil))
      (while (and list (not (keywordp (car list)))) (push (pop list) head))
      (when head (push (nreverse head) groups))
      (while list
        (let ((x (pop list)))
          (push (if (and (keywordp x) list (not (keywordp (car list)))) (list x (pop list)) (list x)) groups)))
      (nreverse groups))))

(defun drgnx-settings-file--layout (x column)
  "X's text starting at COLUMN, under `drgnx-settings-file--printing' (see `drgnx-settings-print')."
  (let ((flat (prin1-to-string x)))
    (if (or (<= (+ column (length flat)) drgnx-settings-print-width)
            (not (and (consp x) (cdr x) (proper-list-p x))))
        flat
      (let ((inner (1+ column)))
        (concat "("
                (mapconcat (lambda (group)
                             (let ((prefix (mapconcat #'prin1-to-string (butlast group) " ")))
                               (if (string-empty-p prefix) (drgnx-settings-file--layout (car group) inner)
                                 (concat prefix " " (drgnx-settings-file--layout (car (last group))
                                                                                 (+ inner (length prefix) 1))))))
                           (drgnx-settings-file--groups x)
                           (concat "\n" (make-string inner ?\s)))
                ")")))))

(defun drgnx-settings-print (value column)
  "VALUE's text in a settings file, starting at COLUMN (design §6): the same value always prints the same text.
On one line when it ends by column `drgnx-settings-print-width' (100); else a list breaks: before each keyword when
it holds one (a plist, or a list of plists element by element), per element otherwise (an alist), each line one
column in from its list's paren.  Strings use `prin1''s escapes (newlines and control characters escaped), other
characters as UTF-8 text; the user's print settings change nothing.  Signals `drgnx-settings-refused' for a value
that is not plain data (`drgnx-settings-file--why-not'): a buffer, a marker, a unibyte or raw-byte string, …"
  (when-let* ((why (drgnx-settings-file--why-not value)))
    (signal 'drgnx-settings-refused (list (format "the value is not data a settings file can hold: %s" why))))
  (drgnx-settings-file--printing (drgnx-settings-file--layout value column)))

(defun drgnx-settings-file--entry-text (var value merge column)
  "The text of the entry (VAR VALUE[ :merge MERGE]) starting at COLUMN: on one line when it fits, else VALUE on the
next line, one column in."
  (let* ((name (drgnx-settings-file--prin1 var))
         (tail (if merge (concat " :merge " (drgnx-settings-file--prin1 merge)) ""))
         (one (concat "(" name " " (drgnx-settings-print value (+ column 2 (length name))) tail ")")))
    (if (and (not (string-search "\n" one)) (<= (+ column (length one)) drgnx-settings-print-width)) one
      (concat "(" name "\n" (make-string (1+ column) ?\s) (drgnx-settings-print value (1+ column)) tail ")"))))

;;;; The text: containers, blocks and edits (in a buffer holding the text)

(defun drgnx-settings-file--first-on-line-p (pos)
  "Whether only blanks come before POS on its line."
  (save-excursion (goto-char pos) (skip-chars-backward " \t") (bolp)))

(defun drgnx-settings-file--column (pos)
  "POS's column."
  (save-excursion (goto-char pos) (current-column)))

(defun drgnx-settings-file--block (beg end)
  "The text an item at BEG..END owns: (START STOP COMMENT-P).  START is the first of the `;' lines directly above it
\(no blank line between) when it starts its line, else BEG; STOP is past the comment at the end of its last line,
if any (COMMENT-P), else END."
  (save-excursion
    (let ((start beg))
      (when (drgnx-settings-file--first-on-line-p beg)
        (goto-char beg)
        (while (and (zerop (forward-line -1))
                    (progn (skip-chars-forward " \t")
                           (and (eq (char-after) ?\;) (nth 4 (save-excursion (syntax-ppss (1+ (point))))))))
          (setq start (point))))
      (goto-char end)
      (skip-chars-forward " \t")
      (if (eq (char-after) ?\;) (list start (line-end-position) t) (list start end nil)))))

(defun drgnx-settings-file--back-skip (pos)
  "POS moved back over blanks, and over the newline before them unless a comment ends there."
  (save-excursion
    (goto-char pos)
    (skip-chars-backward " \t")
    (let ((p (point)))
      (when (and (bolp) (> p (point-min)) (not (nth 4 (save-excursion (syntax-ppss (1- p))))))
        (goto-char (1- p))
        (skip-chars-backward " \t")))
    (point)))

(defun drgnx-settings-file--delete-edit (beg end)
  "The edit (FROM TO \"\") taking the item at BEG..END out with its block: whole lines when it has its lines to
itself, else up to the next item (one before a close paren also takes the blanks before it)."
  (let ((block (drgnx-settings-file--block beg end)))
    (save-excursion
      (goto-char (nth 1 block))
      (skip-chars-forward " \t")
      (cond ((and (eolp) (drgnx-settings-file--first-on-line-p (car block)))
             (list (save-excursion (goto-char (car block)) (line-beginning-position))
                   (min (1+ (point)) (point-max)) ""))
            ((eq (char-after) ?\)) (list (drgnx-settings-file--back-skip (car block)) (point) ""))
            (t (list (car block) (point) ""))))))

(defun drgnx-settings-file--top ()
  "Where the current buffer's one form starts."
  (save-excursion (goto-char (point-min)) (forward-comment (buffer-size)) (point)))

(defun drgnx-settings-file--container (open top)
  "The list at OPEN as a container: (OPEN ELEMENTS CONTENT).  CONTENT is its entries and sections: after the head and
the meta pairs for the TOP form, after the kind and the name for a section."
  (let* ((els (drgnx-settings-file--elements open))
         (content (if (not top) (nthcdr 2 els)
                    (let ((e (cdr els)))
                      (while (and (cdr e) (keywordp (car (car e)))) (setq e (cddr e)))
                      e))))
    (list open els content)))

(defun drgnx-settings-file--section-p (x step)
  "Whether X is the section of the scope STEP, (:mode . M) or (:dir . D)."
  (and (consp x) (proper-list-p x) (eq (car x) (car step)) (cdr x) (equal (cadr x) (cdr step))))

(defun drgnx-settings-file--key (x)
  "X's sort key, (GROUP RANK NAME): entries by name, then sections by kind (`:mode', `:dir', `:eval') and name."
  (cond ((and (consp x) (car x) (symbolp (car x)) (not (keywordp (car x))) (not (eq (car x) t)))
         (list 0 0 (symbol-name (car x))))
        ((and (consp x) (memq (car x) '(:mode :dir :eval)))
         (list 1 (pcase (car x) (:mode 0) (:dir 1) (_ 2)) (if (eq (car x) :eval) "" (format "%s" (car-safe (cdr x))))))
        (t (list 2 0 ""))))

(defun drgnx-settings-file--key< (a b)
  "Whether sort key A comes before B."
  (cond ((/= (car a) (car b)) (< (car a) (car b)))
        ((/= (nth 1 a) (nth 1 b)) (< (nth 1 a) (nth 1 b)))
        (t (string< (nth 2 a) (nth 2 b)))))

(defun drgnx-settings-file--content-column (container top)
  "The column a new item of CONTAINER (TOP: the top form) goes at: its first item's, else the first meta key's (TOP),
else one in from its paren."
  (let ((content (nth 2 container)) (els (nth 1 container)))
    (cond (content (drgnx-settings-file--column (nth 1 (car content))))
          ((and top (cdr els)) (drgnx-settings-file--column (nth 1 (cadr els))))
          (t (1+ (drgnx-settings-file--column (car container)))))))

(defun drgnx-settings-file--insert-edit (container top key text-fn)
  "The edit putting a new item of sort KEY into CONTAINER (TOP: the top form), its text (funcall TEXT-FN COLUMN):
before the first item that sorts after it (above that item's comments), else after the last element, past the
comment on its line.  Nothing else moves."
  (let ((anchor (cl-find-if (lambda (e) (drgnx-settings-file--key< key (drgnx-settings-file--key (car e))))
                            (nth 2 container))))
    (if anchor
        (let* ((p (car (drgnx-settings-file--block (nth 1 anchor) (nth 2 anchor))))
               (col (drgnx-settings-file--column p)))
          (list p p (if (drgnx-settings-file--first-on-line-p p)
                        (concat (funcall text-fn col) "\n" (make-string col ?\s))
                      (concat (funcall text-fn col) " "))))
      (let* ((last (car (last (nth 1 container))))
             (col (drgnx-settings-file--content-column container top))
             (pos (save-excursion
                    (goto-char (nth 2 last))
                    (skip-chars-forward " \t")
                    (if (eq (char-after) ?\;) (line-end-position) (nth 2 last)))))
        (list pos pos (concat "\n" (make-string col ?\s) (funcall text-fn col)))))))

(defun drgnx-settings-file--apply (edits)
  "Apply EDITS, (FROM TO TEXT)…, to the current buffer, from its end to its start; its text.  Deletions (TEXT \"\")
that overlap or touch are joined first; at one place a deletion goes before an insertion."
  (let ((merged nil))
    (dolist (e (sort edits (lambda (a b) (or (< (car a) (car b)) (and (= (car a) (car b)) (< (nth 1 a) (nth 1 b)))))))
      (if (and merged (equal (nth 2 e) "") (equal (nth 2 (car merged)) "") (<= (car e) (nth 1 (car merged))))
          (setcar merged (list (car (car merged)) (max (nth 1 (car merged)) (nth 1 e)) ""))
        (push e merged)))
    (dolist (e merged)                                  ; from the end of the buffer to its start
      (goto-char (car e))
      (delete-region (car e) (nth 1 e))
      (insert (nth 2 e))))
  (buffer-substring-no-properties (point-min) (point-max)))

(defun drgnx-settings-file--find (doc var scope)
  "DOC's entry for VAR in SCOPE, or nil."
  (cl-find-if (lambda (e) (and (eq (drgnx-settings-entry-var e) var) (equal (drgnx-settings-entry-scope e) scope)))
              (drgnx-settings-doc-entries doc)))

(defun drgnx-settings-file--dups (doc var scope)
  "DOC's problems that are a second entry for VAR in SCOPE."
  (cl-remove-if-not (lambda (p) (and (plist-member p :var) (eq (plist-get p :var) var)
                                     (equal (plist-get p :scope) scope)))
                    (drgnx-settings-doc-problems doc)))

(defun drgnx-settings-file--new-edit (scope var value merge)
  "The edit adding the entry (VAR VALUE :merge MERGE) in SCOPE to the current buffer: into SCOPE's sections, the
missing ones made at their sorted places."
  (let ((container (drgnx-settings-file--container (drgnx-settings-file--top) t)) (top t) (steps scope))
    (while (and steps (let ((found (cl-find-if (lambda (e) (drgnx-settings-file--section-p (car e) (car steps)))
                                               (nth 2 container))))
                        (when found
                          (setq container (drgnx-settings-file--container (nth 1 found) nil) top nil steps (cdr steps))
                          t))))
    (let ((text-fn (lambda (col) (drgnx-settings-file--entry-text var value merge col)))
          (key (list 0 0 (symbol-name var))))
      (dolist (step (reverse steps))
        (let ((inner text-fn))
          (setq text-fn (lambda (col)
                          (concat "(" (symbol-name (car step)) " " (drgnx-settings-file--prin1 (cdr step)) "\n"
                                  (make-string (1+ col) ?\s) (funcall inner (1+ col)) ")"))
                key (drgnx-settings-file--key (list (car step) (cdr step))))))
      (drgnx-settings-file--insert-edit container top key text-fn))))

(defun drgnx-settings-file--remove-edit (entry)
  "The edit taking ENTRY out of the current buffer, with its block; a section it leaves empty goes too."
  (let* ((beg (drgnx-settings-entry-beg entry))
         (chain nil)
         (container (drgnx-settings-file--container (drgnx-settings-file--top) t)))
    ;; the sections ENTRY sits in, outermost first: (ELEMENT . ITS-CONTAINER)
    (dolist (step (drgnx-settings-entry-scope entry))
      (let ((found (cl-find-if (lambda (e) (and (drgnx-settings-file--section-p (car e) step)
                                                (<= (nth 1 e) beg) (< beg (nth 2 e))))
                               (nth 2 container))))
        (setq container (drgnx-settings-file--container (nth 1 found) nil))
        (push (cons found container) chain)))
    (let ((span (list beg (drgnx-settings-entry-end entry))))
      (while (and chain (= (length (nth 2 (cdar chain))) 1))
        (setq span (cdr (car (car chain))) chain (cdr chain)))
      (drgnx-settings-file--delete-edit (car span) (cadr span)))))

(defun drgnx-settings-file--sorted-p (container)
  "Whether CONTAINER's items are in sort order."
  (let ((keys (mapcar (lambda (e) (drgnx-settings-file--key (car e))) (nth 2 container))) (ok t))
    (while (and ok (cdr keys))
      (when (drgnx-settings-file--key< (cadr keys) (car keys)) (setq ok nil))
      (setq keys (cdr keys)))
    ok))

(defun drgnx-settings-file--unsorted ()
  "A container of the current buffer whose items are out of order, or nil."
  (let ((todo (list (drgnx-settings-file--container (drgnx-settings-file--top) t))) (found nil))
    (while (and todo (not found))
      (let ((c (pop todo)))
        (if (not (drgnx-settings-file--sorted-p c)) (setq found c)
          (dolist (e (nth 2 c))
            (when (and (consp (car e)) (proper-list-p (car e)) (memq (car (car e)) '(:mode :dir)))
              (push (drgnx-settings-file--container (nth 1 e) nil) todo))))))
    found))

(defun drgnx-settings-file--sort-container (container)
  "Put CONTAINER's items in sort order in the current buffer: each item's block (its comments with it) goes to the
slot of the item at its new place; the text between items stays where it is."
  (let* ((blocks (mapcar (lambda (e) (cons (drgnx-settings-file--key (car e))
                                           (drgnx-settings-file--block (nth 1 e) (nth 2 e))))
                         (nth 2 container)))
         (texts (mapcar (lambda (b) (list (car b) (buffer-substring-no-properties (nth 1 b) (nth 2 b)) (nth 3 b)))
                        blocks))
         (sorted (sort (copy-sequence texts) (lambda (a b) (drgnx-settings-file--key< (car a) (car b)))))
         (edits nil))
    (cl-mapc (lambda (slot moved)
               (let ((text (nth 1 moved)))
                 (when (and (nth 2 moved)       ; a comment at its end: what follows on the line goes to the next
                            (save-excursion (goto-char (nth 2 slot)) (skip-chars-forward " \t") (not (eolp))))
                   (setq text (concat text "\n" (make-string (drgnx-settings-file--column (nth 1 slot)) ?\s))))
                 (push (list (nth 1 slot) (nth 2 slot) text) edits)))
             blocks sorted)
    (drgnx-settings-file--apply edits)))

;;;; Writing

(defun drgnx-settings-file--header (file head)
  "The comment a new settings FILE of HEAD starts with: settings.el's three lines, or one line naming the workspace."
  (if (eq head 'drgnx-settings) drgnx-settings-file-global-header
    (let* ((dir (directory-file-name (file-name-directory file)))
           (shared (equal (file-name-nondirectory dir) ".drgnx")))
      (if shared
          (format ";; %s: drgnx workspace settings, shared with the repository  -*- mode: lisp-data -*-\n"
                  (file-name-nondirectory (directory-file-name (file-name-directory dir))))
        (format ";; %s: drgnx workspace settings, private to you  -*- mode: lisp-data -*-\n"
                (file-name-base file))))))

(defun drgnx-settings-file--shown (file)
  "FILE as a message shows it."
  (let ((file-name-handler-alist nil)) (abbreviate-file-name file)))

(defun drgnx-settings-file--refuse (text)
  "Signal `drgnx-settings-refused' with TEXT."
  (signal 'drgnx-settings-refused (list text)))

(defun drgnx-settings-file--base (doc file head)
  "The text a change of DOC (settings FILE of HEAD, read fresh) starts from: its text, the header and an empty form
for a missing file, the empty form after the comments of a file with no form.  Refuses a file that does not read."
  (let ((text (drgnx-settings-doc-text doc))
        (empty (format "(%s\n :version %d)\n" head drgnx-settings-file-version)))
    (cond ((null text) (concat (drgnx-settings-file--header file head) empty))
          ((eq (car (drgnx-file--parse text)) 'absent)
           (if (string-blank-p text) (concat (drgnx-settings-file--header file head) empty)
             (concat text (if (string-suffix-p "\n" text) "" "\n") empty)))
          ((drgnx-settings-doc-failed doc)
           (let ((p (car (drgnx-settings-doc-problems doc))))
             (drgnx-settings-file--refuse
              (if (string-search "newer drgnx" (plist-get p :text))
                  (format "%s was written by a newer drgnx: update drgnx here; it was not changed"
                          (drgnx-settings-file--shown file))
                (format "%s has a mistake at line %d: %s; fix it first; it was not changed"
                        (drgnx-settings-file--shown file) (plist-get p :line) (plist-get p :text))))))
          (t text))))

(defun drgnx-settings-file--visiting (file)
  "The buffer visiting FILE, or nil."
  (let ((file-name-handler-alist nil)) (find-buffer-visiting file)))

(defun drgnx-settings-file--warn (text)
  "A `warn' notice of source `config'.  Never signals."
  (condition-case failed
      (progn (require 'drgnx-notice) (drgnx-notify 'config 'warn text))
    (error (message "Settings: %s (not recorded: %s)" text (error-message-string failed)))))

(defun drgnx-settings-file--after-write (file before after)
  "After drgnx wrote FILE: an unmodified buffer visiting it is reverted, then the written hook runs."
  (let ((inhibit-interaction t))
    (when-let* ((b (drgnx-settings-file--visiting file)))
      (unless (buffer-modified-p b)
        (condition-case err (with-current-buffer b (revert-buffer t t t))
          (error (drgnx-settings-file--warn (format "%s was written, but its buffer was not reverted: %s"
                                                    (drgnx-settings-file--shown file) (error-message-string err)))))))
    (run-hook-wrapped 'drgnx-settings-file-written-functions
                      (lambda (fn)
                        (condition-case err (funcall fn file before after)
                          (error (drgnx-settings-file--warn (format "%s, run because %s was written, failed: %s" fn
                                                                    (drgnx-settings-file--shown file)
                                                                    (error-message-string err)))))
                        nil))))

(defun drgnx-settings-file--facts (doc &optional except)
  "DOC's entries as ((VAR SCOPE VALUE MERGE)…) in file order, without the entry for EXCEPT, (VAR . SCOPE)."
  (delq nil (mapcar (lambda (e)
                      (unless (and except (eq (drgnx-settings-entry-var e) (car except))
                                   (equal (drgnx-settings-entry-scope e) (cdr except)))
                        (list (drgnx-settings-entry-var e) (drgnx-settings-entry-scope e)
                              (drgnx-settings-entry-value e) (drgnx-settings-entry-merge e))))
                    (drgnx-settings-doc-entries doc))))

(defun drgnx-settings-file--write (file head change check)
  "Change settings FILE of HEAD under its lock: the doc after.
\(funcall CHANGE BASE-DOC) runs in a buffer holding the base text (`drgnx-settings-file--base') and gives the new
text, or nil for no change.  The new text is read back: it must read, and (funcall CHECK BASE-DOC NEW-DOC) must give
nil, else a reason, and nothing is written.  A modified buffer visiting FILE refuses the write; an unmodified one is
reverted after it.  Every refusal is `drgnx-settings-refused', and FILE is left as it was."
  (drgnx-settings-file--check-head head)
  (let* ((name (drgnx-settings-file--name file))
         (max (drgnx-settings-file--default-max name))
         (before nil) (new-text nil))
    (condition-case err
        (drgnx-file-update
         name
         (lambda (data)
           (let ((doc (drgnx-settings-file-read name head :max-bytes max)))
             (setq before doc)
             (when-let* ((b (drgnx-settings-file--visiting name)))
               (when (buffer-modified-p b)
                 (drgnx-settings-file--refuse (format "%s has unsaved edits in a buffer; save or revert it first"
                                                      (file-name-nondirectory name)))))
             (let* ((base (drgnx-settings-file--base doc name head))
                    (base-doc (drgnx-settings-file-parse base head))
                    (text (drgnx-settings-file--in-text base (funcall change base-doc))))
               (if (or (null text) (equal text (drgnx-settings-doc-text doc))) data
                 (let ((new (drgnx-settings-file-parse text head)))
                   (when-let* ((why (if (drgnx-settings-doc-failed new)
                                        (plist-get (car (drgnx-settings-doc-problems new)) :text)
                                      (funcall check base-doc new))))
                     (drgnx-settings-file--refuse (format "the new text of %s does not read back as meant (%s); nothing was written"
                                                          (drgnx-settings-file--shown name) why)))
                   (let ((new-data (cdr (drgnx-file--parse text))))
                     (unless (equal new-data data) (setq new-text text))
                     new-data))))))
         :timeout drgnx-settings-file-lock-timeout :max-bytes max
         :render (lambda (_old _data _new) new-text))
      (drgnx-settings-refused (signal (car err) (cdr err)))
      (drgnx-file-busy
       (drgnx-settings-file--refuse (format "%s is being written by another drgnx; it was not changed, try again"
                                            (drgnx-settings-file--shown name))))
      (file-error
       (let ((doc (ignore-errors (drgnx-settings-file-read name head :max-bytes max))))
         (when (and doc (drgnx-settings-doc-failed doc) (drgnx-settings-doc-text doc))
           (drgnx-settings-file--base doc name head))  ; says where its mistake is
         (drgnx-settings-file--refuse (format "%s was not changed: %s" (drgnx-settings-file--shown name)
                                              (if (eq (car err) 'drgnx-file-refused) (nth 2 err)
                                                (error-message-string err)))))))
    (if (not new-text) before
      (let ((after (drgnx-settings-file-read name head :max-bytes max)))
        (drgnx-settings-file--after-write name before after)
        after))))

(defun drgnx-settings-file--check-scope (head scope)
  "An `error' unless SCOPE is a scope path HEAD's file can hold."
  (unless (pcase scope
            ('nil t)
            (`((:mode . ,m)) (and m (symbolp m) (not (keywordp m)) (not (eq m t))))
            (`((:dir . ,d)) (and (stringp d) (eq head 'drgnx-workspace-settings)))
            (`((:dir . ,d) (:mode . ,m))
             (and (stringp d) (eq head 'drgnx-workspace-settings) m (symbolp m) (not (keywordp m)) (not (eq m t)))))
    (error "drgnx-settings-file: %S is not a scope path of a %s file" scope head)))

(cl-defun drgnx-settings-file-put (file head scope var value &key (merge nil merge-p))
  "Set VAR to VALUE in SCOPE (a scope path) of settings FILE of head HEAD; the doc after.
Under the file's lock, on a fresh read (`drgnx-file-update'): VAR's entry is replaced, its span only, its comments
kept; a new one goes at its sorted place, before the first item whose name sorts after it, its sections made as
needed.  A second entry for VAR in SCOPE goes.  MERGE sets the entry's `:merge' kind (nil: none); without it the
entry keeps its own.  A missing file starts with its header.  Nothing is written when nothing changes.  Signals
`drgnx-settings-refused' for a file that does not read or a newer one, a modified buffer visiting it, a value that is
not plain data (`drgnx-settings-print'), a text that does not read back as meant, a busy lock; FILE is left as it
was.  Then `drgnx-settings-file-written-functions' run."
  (drgnx-settings-file--check-head head)
  (drgnx-settings-file--check-scope head scope)
  (unless (and var (symbolp var) (not (keywordp var)) (not (eq var t)))
    (error "drgnx-settings-file: %S is not a variable" var))
  (when-let* ((why (drgnx-settings-file--why-not value)))
    (drgnx-settings-file--refuse (format "%s was not changed: the value of %s is not data a settings file can hold: %s"
                                         (drgnx-settings-file--shown (drgnx-settings-file--name file)) var why)))
  (unless (eq (drgnx-settings-file--unquote value) value)
    (drgnx-settings-file--refuse (format "%s was not changed: a value (%s …) would read as its argument"
                                         (drgnx-settings-file--shown (drgnx-settings-file--name file)) (car value))))
  (drgnx-settings-file--write
   file head
   (lambda (doc)
     (let* ((e (drgnx-settings-file--find doc var scope))
            (dups (drgnx-settings-file--dups doc var scope))
            (m (if merge-p merge (and e (drgnx-settings-entry-merge e)))))
       (unless (and e (null dups) (equal (drgnx-settings-entry-value e) value) (eq (drgnx-settings-entry-merge e) m))
         (drgnx-settings-file--apply
          (cons (if e (let ((beg (drgnx-settings-entry-beg e)))
                        (list beg (drgnx-settings-entry-end e)
                              (drgnx-settings-file--entry-text var value m (drgnx-settings-file--column beg))))
                  (drgnx-settings-file--new-edit scope var value m))
                (mapcar (lambda (d) (drgnx-settings-file--delete-edit (plist-get d :beg) (plist-get d :end))) dups))))))
   (lambda (old new)
     (let ((e (drgnx-settings-file--find new var scope)))
       (cond ((not (equal (drgnx-settings-doc-meta old) (drgnx-settings-doc-meta new))) "the meta changed")
             ((not (and e (equal (drgnx-settings-entry-value e) value)
                        (eq (drgnx-settings-entry-merge e) (if merge-p merge
                                                             (let ((o (drgnx-settings-file--find old var scope)))
                                                               (and o (drgnx-settings-entry-merge o)))))))
              (format "%s does not read as the new value" var))
             ((not (equal (drgnx-settings-file--facts old (cons var scope))
                          (drgnx-settings-file--facts new (cons var scope))))
              "another entry changed")
             ((> (length (drgnx-settings-doc-problems new)) (length (drgnx-settings-doc-problems old)))
              (plist-get (car (last (drgnx-settings-doc-problems new))) :text)))))))

(defun drgnx-settings-file-remove (file head scope var)
  "Take VAR's entry in SCOPE out of settings FILE of head HEAD, with its comments; the doc after.
A section it leaves empty goes too, and so does a second entry for VAR there.  Nothing else moves.  Refuses as
`drgnx-settings-file-put' does."
  (drgnx-settings-file--check-head head)
  (drgnx-settings-file--check-scope head scope)
  (drgnx-settings-file--write
   file head
   (lambda (doc)
     (let ((e (drgnx-settings-file--find doc var scope)) (dups (drgnx-settings-file--dups doc var scope)))
       (when (or e dups)
         (drgnx-settings-file--apply
          (append (and e (list (drgnx-settings-file--remove-edit e)))
                  (mapcar (lambda (d) (drgnx-settings-file--delete-edit (plist-get d :beg) (plist-get d :end))) dups))))))
   (lambda (old new)
     (cond ((not (equal (drgnx-settings-doc-meta old) (drgnx-settings-doc-meta new))) "the meta changed")
           ((drgnx-settings-file--find new var scope) (format "%s is still there" var))
           ((not (equal (drgnx-settings-file--facts old (cons var scope))
                        (drgnx-settings-file--facts new (cons var scope))))
            "another entry changed")))))

(defun drgnx-settings-file--sort-args ()
  "The file and head Settings: Sort File sorts: the settings file the current buffer visits, else settings.el."
  (let* ((file (and buffer-file-name (drgnx-settings-file--name buffer-file-name)))
         (dir (and file (file-name-nondirectory (directory-file-name (file-name-directory file))))))
    (cond ((null file) (list (drgnx-config-file 'settings) 'drgnx-settings))
          ((equal file (drgnx-config-file 'settings)) (list file 'drgnx-settings))
          ((or (equal dir ".drgnx") (equal dir "workspaces")) (list file 'drgnx-workspace-settings))
          (t (list (drgnx-config-file 'settings) 'drgnx-settings)))))

(defun drgnx-settings-file-sort (file head)
  "Sort settings FILE of head HEAD: in the file and in each section, entries by name, then sections by kind (`:mode',
`:dir', `:eval') and name.  Each item moves with its comments; the text between items stays.  Interactively, the
settings file the current buffer visits, else settings.el.  Refuses as `drgnx-settings-file-put' does; the doc after."
  (interactive (drgnx-settings-file--sort-args))
  (let ((doc (drgnx-settings-file--write
              file head
              (lambda (_doc)
                (let ((n 0) (c nil) (changed nil))
                  (while (and (< n 1000) (setq c (drgnx-settings-file--unsorted)))
                    (drgnx-settings-file--sort-container c)
                    (setq n (1+ n) changed t))
                  (and changed (buffer-substring-no-properties (point-min) (point-max)))))
              (lambda (old new)
                (let ((a (drgnx-settings-file--facts old)) (b (drgnx-settings-file--facts new)))
                  (cond ((not (equal (drgnx-settings-doc-meta old) (drgnx-settings-doc-meta new))) "the meta changed")
                        ((not (and (= (length a) (length b)) (cl-every (lambda (x) (member x b)) a)))
                         "the entries changed")
                        ((/= (length (drgnx-settings-doc-problems new)) (length (drgnx-settings-doc-problems old)))
                         "the problems changed")))))))
    (when (called-interactively-p 'interactive)
      (message "Settings: %s is sorted" (drgnx-settings-file--shown (drgnx-settings-file--name file))))
    doc))

(provide 'drgnx-settings-file)
;;; drgnx-settings-file.el ends here
