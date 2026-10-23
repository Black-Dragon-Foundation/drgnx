;;; drgnx-settings-prov.el --- Settings: provenance (who set this) and drgnx-settings-explain -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Unified-settings Task 11 (design §4.5): which form of your Lisp set a variable, and `drgnx-settings-explain' over
;; every layer.  `drgnx--load-user-config' wraps its load in `drgnx-settings-prov-with-load', which, while your Lisp
;; loads, notes the line each form starts at per file (`load-read-function'), marks a `defcustom''s own
;; initialisation (`custom-declare-variable') and a deferred body (`do-after-load-evaluation'), and installs variable
;; watchers on the managed variables (those with a value in a drgnx layer, and those settings.el names).  After start
;; the watchers stay, and a write by anything but drgnx's applier only marks "changed this session".  Provenance
;; explains; it never decides what is applied.  See docs/develop/settings.md, "Provenance".

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-config)
(require 'drgnx-settings-file)
(require 'drgnx-lisp-index)

(declare-function drgnx-settings-claim-modules "drgnx-settings-resolve" (var))
(declare-function drgnx-settings-resolve--direct-value "drgnx-settings-resolve" (var))

(defvar drgnx-settings-explain-functions nil
  "Functions that give the buffer layers of a variable (language overrides, workspace files …).
Each is called with (VAR BUFFER) and returns a list of layer plists: `:layer' (`L1', `W1', `W2' or another
symbol), `:value', and optionally `:file', `:line', `:source' (the text the UI shows) and keys of its own.
`drgnx-settings-explain' calls them only when VAR has a local value in BUFFER.")

(defvar drgnx-settings-prov-applying nil
  "Non-nil while drgnx's applier writes a variable: the write is drgnx's own, not \"changed this session\".")

(defconst drgnx-settings-prov-max-records 8 "The most writes remembered per variable (newest first).")

(defvar drgnx-settings-prov--records (make-hash-table :test 'eq)
  "Variable -> its writes, newest first, at most `drgnx-settings-prov-max-records': plists with `:kind' (`lisp',
`package', `deferred', `session', `definition', `drgnx'), `:value', and as known `:file' `:line' `:beg' `:end'
\(the form's span in the file) `:during' (FILE . LINE) `:where' (the buffer of a buffer-local write).")

(defvar drgnx-settings-prov--watched (make-hash-table :test 'eq) "The variables watched (managed variables).")

(defvar drgnx-settings-prov--user-files nil "Files `drgnx-settings-prov-with-load' loaded: your Lisp (truenames).")

(defvar drgnx-settings-prov--loading nil "Non-nil while `drgnx-settings-prov-with-load' runs its body.")

(defvar drgnx-settings-prov--forms nil
  "While your Lisp loads: per file being read, (FILE BEG END LINE TICK) of the form read last in it.
Keyed by `load-file-name', so a nested `load' never overwrites the outer file's entry.")

(defvar drgnx-settings-prov--tick 0 "Counts the forms read while loading.")
(defvar drgnx-settings-prov--declaring nil "The variable `custom-declare-variable' initialises now.")
(defvar drgnx-settings-prov--deferred nil "Inside an after-load body: (FILE . LINE) of the form that loaded it.")

;;;; Recording

(defun drgnx-settings-prov--same-file-p (a b)
  "Non-nil when the file names A and B name the same file, its .el and .elc counted as one."
  (and a b (equal (file-name-sans-extension (file-truename a)) (file-name-sans-extension (file-truename b)))))

(defun drgnx-settings-prov--user-file-p (file)
  "Non-nil when FILE is one of your Lisp files: in your config dir, loaded by `drgnx-settings-prov-with-load', or
listed (design §8.1)."
  (or (file-in-directory-p file (drgnx-user-dir))
      (cl-some (lambda (f) (drgnx-settings-prov--same-file-p file f))
               (append drgnx-settings-prov--user-files (ignore-errors (drgnx-lisp-index--default-files))))))

(defun drgnx-settings-prov--read (stream)
  "`load-read-function' while your Lisp loads: read a form from STREAM, noting where it starts in `load-file-name'."
  (let ((beg (and (bufferp stream) (with-current-buffer stream (point)))))
    (prog1 (read stream)
      (when load-file-name
        (condition-case nil
            (let ((entry (assoc load-file-name drgnx-settings-prov--forms))
                  (data (list (and beg (with-current-buffer stream (line-number-at-pos beg t)))
                              beg (and beg (with-current-buffer stream (point)))
                              (cl-incf drgnx-settings-prov--tick))))
              (if entry
                  (setcdr entry data)
                (push (cons load-file-name data) drgnx-settings-prov--forms)))
          (error nil))))))

(defun drgnx-settings-prov--form (file)
  "(LINE BEG END TICK) of the form being read in FILE, or nil."
  (cdr (assoc file drgnx-settings-prov--forms)))

(defun drgnx-settings-prov--trigger (finished)
  "(FILE . LINE) of the form that loaded FINISHED (a file whose after-load bodies run now), or nil."
  (if (and load-file-name (not (drgnx-settings-prov--same-file-p load-file-name finished)))
      (cons load-file-name (car (drgnx-settings-prov--form load-file-name)))
    ;; A compiled file runs its after-load bodies with its own name bound: take the form read last elsewhere.
    (let (best)
      (dolist (e drgnx-settings-prov--forms)
        (when (and (not (drgnx-settings-prov--same-file-p (car e) finished))
                   (or (null best) (> (nth 4 e) (nth 4 best))))
          (setq best e)))
      (and best (cons (car best) (nth 1 best))))))

(defun drgnx-settings-prov--after-load (fn file)
  "Around `do-after-load-evaluation' (FN, for FILE): its bodies' writes are deferred, first seen during the trigger."
  (let ((drgnx-settings-prov--deferred (or (ignore-errors (drgnx-settings-prov--trigger file)) (list file))))
    (funcall fn file)))

(defun drgnx-settings-prov--declare (fn symbol &rest args)
  "Around `custom-declare-variable' (FN): SYMBOL's initialisation is its `defcustom''s, not the loading file's."
  (let ((drgnx-settings-prov--declaring symbol))
    (apply fn symbol args)))

(defun drgnx-settings-prov--theme-values (var)
  "VAR's `theme-value' with each entry's expression evaluated: ((THEME VALUE)…).  A theme holds an expression
\(`custom-quote' makes a list `(quote …)'); one that does not evaluate stays as it is."
  (mapcar (lambda (e) (list (car e) (condition-case nil (eval (cadr e) t) (error (cadr e)))))
          (get var 'theme-value)))

(defun drgnx-settings-prov--theme-value (var theme)
  "The value THEME holds for VAR in its `theme-value', as (VALUE), or nil."
  (when-let* ((e (assq theme (drgnx-settings-prov--theme-values var)))) (list (cadr e))))

(defun drgnx-settings-prov--record (var value where)
  "The record of a write of VALUE to VAR (buffer WHERE for a buffer-local write), or nil to ignore it."
  (cond
   (drgnx-settings-prov-applying (list :kind 'drgnx :value value))
   ((eq drgnx-settings-prov--declaring var)
    (list :kind (if (equal (drgnx-settings-prov--theme-value var 'drgnx) (list value)) 'drgnx 'definition)
          :value value :file load-file-name))
   ((and (null where) (not (default-boundp var))) (list :kind 'definition :value value :file load-file-name))
   ((not drgnx-settings-prov--loading) (and (null where) (list :kind 'session :value value)))
   (drgnx-settings-prov--deferred
    (list :kind 'deferred :value value :during drgnx-settings-prov--deferred :where where))
   (load-file-name
    (pcase-let ((`(,line ,beg ,end ,_tick) (drgnx-settings-prov--form load-file-name)))
      (list :kind (if (drgnx-settings-prov--user-file-p load-file-name) 'lisp 'package) :value value
            :file load-file-name :line line :beg beg :end end :where where)))
   (t (list :kind 'session :value value :where where))))

(defun drgnx-settings-prov--watch (symbol newval operation where)
  "The variable watcher of a managed variable: record a `set' of SYMBOL to NEWVAL (in WHERE); never signals."
  (when (eq operation 'set)
    (condition-case nil
        (let* ((var (indirect-variable symbol))
               (r (drgnx-settings-prov--record var newval where)))
          (when r
            (let ((old (gethash var drgnx-settings-prov--records)))
              (puthash var (cons r (if (>= (length old) drgnx-settings-prov-max-records)
                                       (butlast old (1+ (- (length old) drgnx-settings-prov-max-records)))
                                     old))
                       drgnx-settings-prov--records))))
      (error nil))))

(defun drgnx-settings-prov-watch (var)
  "Watch VAR (an alias is resolved) as a managed variable: who sets it is recorded from now on."
  (let ((var (indirect-variable var)))
    (unless (gethash var drgnx-settings-prov--watched)
      (add-variable-watcher var #'drgnx-settings-prov--watch)
      (puthash var t drgnx-settings-prov--watched))
    var))

(defun drgnx-settings-prov--settings-doc ()
  "settings.el read as data, or nil."
  (ignore-errors (drgnx-settings-file-read (drgnx-config-file 'settings) 'drgnx-settings)))

(defun drgnx-settings-prov--managed ()
  "The managed variables now: those theme `drgnx' holds a value for, and those settings.el names."
  (let (vars)
    (dolist (s (get 'drgnx 'theme-settings))
      (when (eq (car s) 'theme-value) (push (nth 1 s) vars)))
    (when-let* ((doc (drgnx-settings-prov--settings-doc)))
      (dolist (e (drgnx-settings-doc-entries doc))
        (let ((v (drgnx-settings-entry-var e)))
          (when (and (symbolp v) (not (keywordp v))) (push v vars)))))
    (delete-dups vars)))

(defun drgnx-settings-prov--call-with-load (file body)
  "Run BODY (a function) that loads FILE, recording who sets which variable (`drgnx-settings-prov-with-load')."
  (if drgnx-settings-prov--loading
      (funcall body)
    (condition-case nil
        (progn
          (when (stringp file) (cl-pushnew (file-truename file) drgnx-settings-prov--user-files :test #'equal))
          (mapc #'drgnx-settings-prov-watch (drgnx-settings-prov--managed))
          (advice-add 'custom-declare-variable :around #'drgnx-settings-prov--declare)
          (advice-add 'do-after-load-evaluation :around #'drgnx-settings-prov--after-load))
      (error nil))
    (unwind-protect
        (let ((drgnx-settings-prov--loading t)
              (drgnx-settings-prov--forms nil)
              (load-read-function #'drgnx-settings-prov--read))
          (funcall body))
      (advice-remove 'custom-declare-variable #'drgnx-settings-prov--declare)
      (advice-remove 'do-after-load-evaluation #'drgnx-settings-prov--after-load))))

(defmacro drgnx-settings-prov-with-load (file &rest body)
  "Run BODY, which loads FILE (your Lisp), recording who sets which variable while it runs (design §4.5).
Each form's start line is noted per file being loaded, a `defcustom''s initialisation and an after-load body are
marked, and the managed variables are watched (they stay watched after BODY).  Nothing here signals or prompts."
  (declare (indent 1) (debug (form body)))
  `(drgnx-settings-prov--call-with-load ,file (lambda () ,@body)))

;;;; Reading the record

(defun drgnx-settings-prov--user-files ()
  "Your Lisp files, for the static index: those loaded with provenance and those listed (truenames, once each)."
  (delete-dups (mapcar #'file-truename (append drgnx-settings-prov--user-files
                                               (ignore-errors (drgnx-lisp-index--default-files))))))

(defun drgnx-settings-prov--setters (var files)
  "The index's setters of VAR in FILES, each with `:file', a setter through an alias of VAR included."
  (let (found)
    (dolist (file files)
      (dolist (s (plist-get (ignore-errors (drgnx-lisp-index-get file)) :setters))
        (let ((v (plist-get s :var)))
          (when (and (symbolp v) (eq (indirect-variable v) var))
            (push (plist-put (copy-sequence s) :file file) found)))))
    (nreverse found)))

(defun drgnx-settings-prov--source-file (file)
  "The source of FILE: its .el beside a compiled file when there is one."
  (let ((el (concat (file-name-sans-extension file) ".el")))
    (if (and (not (equal el file)) (file-exists-p el)) el file)))

(defun drgnx-settings-prov--candidates (setters)
  "SETTERS (of the index) as candidates (:file :line)."
  (mapcar (lambda (s) (list :file (plist-get s :file) :line (plist-get s :line))) setters))

(defun drgnx-settings-prov--resolve (var r)
  "Record R of VAR with `:certain' and `:candidates' from the static index; a confirmed `:setter-line'."
  (let ((r (copy-sequence r)))
    (pcase (plist-get r :kind)
      ((or 'lisp 'deferred)
       (let* ((deferred (eq (plist-get r :kind) 'deferred))
              (file (and (plist-get r :file) (drgnx-settings-prov--source-file (plist-get r :file))))
              (all (drgnx-settings-prov--setters var (if file (list file) (drgnx-settings-prov--user-files))))
              (beg (plist-get r :beg)) (end (plist-get r :end))
              (in (cond (deferred (cl-remove-if-not (lambda (s) (plist-get s :conditional)) all))
                        ((and beg end)      ; the setters inside the form that was running
                         (cl-remove-if-not (lambda (s) (and (<= beg (plist-get s :beg)) (< (plist-get s :beg) end)))
                                           all))
                        (t all))))
         (if (= (length in) 1)
             (setq r (plist-put (plist-put (plist-put r :certain t) :setter-line (plist-get (car in) :line))
                                :file (or (plist-get r :file) (plist-get (car in) :file))))
           (setq r (plist-put (plist-put r :certain nil) :candidates
                              (drgnx-settings-prov--candidates (if in in all)))))
         (when (and deferred (= (length in) 1)) (setq r (plist-put r :file (plist-get (car in) :file))))
         r))
      (_ (plist-put r :certain (and (or (plist-get r :line) (memq (plist-get r :kind) '(session drgnx definition)))
                                    t))))))

(defun drgnx-settings-prov (var)
  "Who set VAR, newest first: a list of plists (:kind :file :line :certain :candidates …).
`:kind' is `lisp' (your Lisp file), `package' (another file being loaded), `deferred' (an after-load body;
`:during' is (FILE . LINE) of the form that loaded the package), `session' (changed after start, or outside a
load), `definition' (a `defvar''s first value or a `defcustom''s own) or `drgnx' (drgnx's applier, or a
`defcustom' taking the value of theme `drgnx').  `:line' is where the form being loaded starts (a compiled file
has none); `:certain' is t when the static index confirms one setter there (its line is `:setter-line'),
else `:candidates' lists the index's setters (:file :line).  Only `set' writes count; an alias is resolved."
  (let ((var (indirect-variable var)))
    (mapcar (lambda (r) (drgnx-settings-prov--resolve var r)) (gethash var drgnx-settings-prov--records))))

;;;; Explaining

(defun drgnx-settings-prov--name (file) "FILE's name without its directory." (and file (file-name-nondirectory file)))

(defun drgnx-settings-prov--at (file line)
  "\"FILE:LINE\", or \"FILE, line unknown\"."
  (if line (format "%s:%s" (drgnx-settings-prov--name file) line)
    (format "%s, line unknown" (drgnx-settings-prov--name file))))

(defun drgnx-settings-prov--default-layer (var)
  "G0: VAR's standard value, from its definition."
  (let ((file (ignore-errors (symbol-file var 'defvar))))
    (list :layer 'G0 :kind 'default
          :value (let ((sv (get var 'standard-value))) (if sv (ignore-errors (eval (car sv) t)) (default-value var)))
          :file file :line nil :certain t
          :source (if file (format "default (package %s)" (file-name-base file)) "default"))))

(defun drgnx-settings-prov--module-layer (var value)
  "G1: VALUE as the drgnx modules' that claim VAR (`drgnx-settings-claim-modules'), named in `:source'."
  (let ((modules (and (fboundp 'drgnx-settings-claim-modules) (drgnx-settings-claim-modules var))))
    (list :layer 'G1 :kind 'module :value value :modules modules :certain t
          :source (if modules (format "module %s" (mapconcat #'symbol-name modules ", ")) "a drgnx module"))))

(defun drgnx-settings-prov--settings-layer (var)
  "G1 or G2: VAR's value in theme `drgnx', with its settings.el entry when there is one; the value drgnx's modules
set directly (no theme value); or nil."
  (let* ((tv (drgnx-settings-prov--theme-value var 'drgnx))
         (doc (drgnx-settings-prov--settings-doc))
         (entry (and doc (cl-find-if (lambda (e) (and (eq (drgnx-settings-entry-var e) var)
                                                      (null (drgnx-settings-entry-scope e))))
                                     (drgnx-settings-doc-entries doc)))))
    (cond (entry
           (let ((file (drgnx-settings-doc-file doc)) (line (drgnx-settings-entry-line entry)))
             (list :layer 'G2 :kind 'settings :value (if tv (car tv) (drgnx-settings-entry-value entry))
                   :file file :line line :certain t
                   :source (format "Settings (%s)" (drgnx-settings-prov--at file line)))))
          (tv (drgnx-settings-prov--module-layer var (car tv)))
          ((fboundp 'drgnx-settings-resolve--direct-value)
           (when-let* ((d (drgnx-settings-resolve--direct-value var)))
             (drgnx-settings-prov--module-layer var (car d)))))))

(defun drgnx-settings-prov--theme-layer (var theme value)
  "The layer of THEME's VALUE for VAR (not theme `drgnx')."
  (pcase theme
    ('user
     (if (get var 'saved-value)
         (let* ((cf (or (bound-and-true-p custom-file) (expand-file-name "custom.el" (drgnx-user-dir))))
                (s (ignore-errors (cl-remove-if-not (lambda (s) (eq (plist-get s :kind) 'custom-set-variables))
                                                    (drgnx-settings-prov--setters var (list cf)))))
                (line (and (= (length s) 1) (plist-get (car s) :line))))
           (list :layer 'G3 :kind 'customize :value value :file cf :line line :certain (and line t)
                 :source (format "Customize (%s)" (drgnx-settings-prov--at cf line))))
       (list :layer 'G3 :kind 'customize :value value :certain t :source "Customize, this session only")))
    ('use-package (list :layer 'G4 :kind 'use-package :value value :certain nil :theme theme
                        :source "your Lisp (use-package :custom)"))
    ('changed (list :layer 'session :kind 'session :value value :certain t :source "changed this session"))
    (_ (list :layer 'theme :kind 'theme :theme theme :value value :certain t
             :source (format "theme %s" theme)))))

(defun drgnx-settings-prov--record-layer (var r)
  "The layer of the resolved record R of VAR."
  (let ((line (or (plist-get r :setter-line) (and (not (memq (plist-get r :kind) '(lisp deferred)))
                                                  (plist-get r :line))))
        (file (and (plist-get r :file) (drgnx-settings-prov--source-file (plist-get r :file)))))
    (pcase (plist-get r :kind)
      ('lisp (list :layer 'G4 :kind 'lisp :value (plist-get r :value) :file file :line line
                   :certain (plist-get r :certain) :candidates (plist-get r :candidates)
                   :source (format "your Lisp (%s)" (drgnx-settings-prov--at file line))))
      ('deferred
       (let ((during (plist-get r :during)))
         (list :layer 'G4 :kind 'deferred :value (plist-get r :value) :file file :line line :during during
               :certain (plist-get r :certain) :candidates (plist-get r :candidates)
               :source (concat (if file (format "your Lisp (%s), deferred" (drgnx-settings-prov--at file line))
                                 "your Lisp, deferred")
                               (if (car during)
                                   (format ", first seen during %s" (drgnx-settings-prov--at (car during) (cdr during)))
                                 "")))))
      ('package (list :layer 'package :kind 'package :value (plist-get r :value) :file file :line line
                      :certain (and line t)
                      :source (format "package file (%s)" (drgnx-settings-prov--at file line))))
      ('definition (let ((d (drgnx-settings-prov--default-layer var)))
                     (if file (plist-put (plist-put d :file file) :source
                                         (format "default (package %s)" (file-name-base file)))
                       d)))
      ('drgnx (or (drgnx-settings-prov--settings-layer var)
                  (drgnx-settings-prov--module-layer var (plist-get r :value))))
      (_ (list :layer 'session :kind 'session :value (plist-get r :value) :certain t
               :source "changed this session")))))

(defun drgnx-settings-prov--global (var value records)
  "The global layers of VAR (lowest first) and the one that explains VALUE: (WINNER . LAYERS).
RECORDS are VAR's resolved global writes, newest first."
  (let* ((tvs (drgnx-settings-prov--theme-values var))
         (top (car tvs))
         (g0 (drgnx-settings-prov--default-layer var))
         (g12 (drgnx-settings-prov--settings-layer var))
         (themes (mapcar (lambda (e) (drgnx-settings-prov--theme-layer var (car e) (cadr e)))
                         (reverse (cl-remove-if (lambda (e) (eq (car e) 'drgnx)) tvs))))
         (r (car records))
         (rl (and r (drgnx-settings-prov--record-layer var r)))
         (top-layer (and top (if (eq (car top) 'drgnx)
                                 (or g12 (drgnx-settings-prov--module-layer var (cadr top)))
                               (drgnx-settings-prov--theme-layer var (car top) (cadr top)))))
         (winner
          (cond
           ((and r (equal (plist-get r :value) value))
            (pcase (plist-get r :kind)
              ('session (if (and top (equal (cadr top) value)) top-layer rl))
              ;; Your Lisp's `custom-set-variables' (custom.el) is Customize's, at that entry's line.
              ('lisp (if (and top (eq (car top) 'user) (equal (cadr top) value) (get var 'saved-value))
                         (let ((c (drgnx-settings-prov--theme-layer var 'user value))
                               (file (plist-get rl :file)) (line (plist-get rl :line)))
                           (if (and line (plist-get rl :certain))
                               (append (list :file file :line line
                                             :source (format "Customize (%s)" (drgnx-settings-prov--at file line)))
                                       c)
                             c))
                       rl))
              (_ rl)))
           ((and top (equal (cadr top) value)) top-layer)
           ;; a value drgnx's modules set directly (an alist key, a plain variable): no theme entry to find it by
           ((and g12 (not top) (eq (plist-get g12 :layer) 'G1) (equal (plist-get g12 :value) value)) g12)
           ((equal (plist-get g0 :value) value) g0)
           (t (let ((cands (drgnx-settings-prov--setters var (drgnx-settings-prov--user-files))))
                (list :layer nil :kind 'unknown :value value :certain nil
                      :candidates (drgnx-settings-prov--candidates cands)
                      :source (if cands "set by your Lisp, line unknown" "unknown")))))))
    (cons winner (delq nil (append (list g0 g12) themes
                                   (and rl (not (memq (plist-get rl :kind) '(default module settings))) (list rl)))))))

(defconst drgnx-settings-prov--buffer-rank '((L1 . 1) (buffer . 2) (W1 . 3) (dir-local . 4) (W2 . 5) (file-local . 6))
  "The order of a buffer's layers, lowest first (design §4.1); a layer not named ranks with `buffer'.")

(defun drgnx-settings-prov--buffer (var value buffer records)
  "The buffer layers of VAR in BUFFER, lowest first, and the one that explains VALUE: (WINNER . LAYERS)."
  (let ((layers (apply #'append (mapcar (lambda (fn) (ignore-errors (funcall fn var buffer)))
                                        (ignore-errors (delq t (copy-sequence drgnx-settings-explain-functions)))))))
    (with-current-buffer buffer
      (when-let* ((d (assq var (and (boundp 'dir-local-variables-alist) dir-local-variables-alist))))
        (unless (cl-some (lambda (l) (memq (plist-get l :layer) '(W1 W2))) layers)
          (push (list :layer 'dir-local :kind 'dir-local :value (cdr d) :certain t :source "directory-local") layers)))
      (when-let* ((f (assq var file-local-variables-alist)))
        (push (list :layer 'file-local :kind 'file-local :value (cdr f) :file buffer-file-name :certain t
                    :source "file-local variable")
              layers)))
    (when-let* ((r (cl-find-if (lambda (r) (eq (plist-get r :where) buffer)) records)))
      (push (plist-put (plist-put (drgnx-settings-prov--record-layer var r) :layer 'buffer) :where buffer) layers))
    (let* ((rank (lambda (l) (or (alist-get (plist-get l :layer) drgnx-settings-prov--buffer-rank) 2)))
           (sorted (sort layers (lambda (a b) (< (funcall rank a) (funcall rank b)))))
           (winner (or (cl-find-if (lambda (l) (equal (plist-get l :value) value)) (reverse sorted))
                       (list :layer 'buffer :kind 'buffer :value value :certain nil :source "set in this buffer"))))
      (cons winner sorted))))

(defun drgnx-settings-explain (var &optional buffer)
  "Explain VAR's value in BUFFER (default the current buffer): where Emacs's value comes from.
Returns (:value :layer :source :file :line :certain :candidates :kind :layers :changed-this-session
:buffer-local-only).  `:value' is VAR's value in BUFFER (`symbol-value' there).  Where VAR has no local value in
BUFFER, the global layers explain it: the default (G0), theme `drgnx' and settings.el (G1, G2), Customize (G3),
your Lisp (G4) and other themes, from `theme-value', `standard-value', `symbol-file', the provenance record and
the static index.  Where it has one, the buffer layers do: `drgnx-settings-explain-functions',
`dir-local-variables-alist' and `file-local-variables-alist'.  `:layers' lists them lowest first; the winner's
`:layer', `:source' (the text the UI shows), `:file' and `:line' are the layer whose value is Emacs's.  A dynamic
record the index cannot confirm is `:certain' nil with `:candidates' (:file :line).  `:changed-this-session' is t
after a write since start; `:buffer-local-only' when your Lisp's latest write set only a buffer's value (a `setq'
of an automatically buffer-local variable).  It never computes a value Emacs does not have."
  (let* ((var (indirect-variable var))
         (buffer (or buffer (current-buffer)))
         (records (drgnx-settings-prov var))
         (global-records (cl-remove-if (lambda (r) (plist-get r :where)) records))
         (local (and (boundp var) (local-variable-p var buffer)))
         (value (cond (local (buffer-local-value var buffer)) ((default-boundp var) (default-value var))))
         (result (if local (drgnx-settings-prov--buffer var value buffer records)
                   (if (default-boundp var) (drgnx-settings-prov--global var value global-records)
                     (list (list :layer nil :kind 'void :value nil :certain t :source "not defined")))))
         (winner (car result))
         (latest-lisp (cl-find-if (lambda (r) (memq (plist-get r :kind) '(lisp package deferred))) records)))
    (list :value value
          :layer (plist-get winner :layer) :kind (plist-get winner :kind) :source (plist-get winner :source)
          :file (plist-get winner :file) :line (plist-get winner :line) :certain (plist-get winner :certain)
          :candidates (plist-get winner :candidates)
          :layers (cdr result)
          :changed-this-session (and (cl-some (lambda (r) (eq (plist-get r :kind) 'session)) global-records) t)
          :buffer-local-only (and latest-lisp (plist-get latest-lisp :where) (not local) t))))

(provide 'drgnx-settings-prov)
;;; drgnx-settings-prov.el ends here
