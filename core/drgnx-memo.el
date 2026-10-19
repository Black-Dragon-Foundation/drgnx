;;; drgnx-memo.el --- Epochs, memos and capped caches: a read costs nothing -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Three small tools for code that must not redo work on redisplay or per keystroke.
;;
;; An EPOCH is a counter that a hook or a variable watcher bumps when something a result depends on changes.
;; A MEMO keeps the last result of a build, keyed on the `eq' values of a list of forms (epochs among them): when
;; every value is the same as last time the stored result is returned, and nothing is consed.  A CACHE keeps many
;; results by key, bounded: weak and liveness-checked when keyed by an object, an LRU with a cap when keyed by a
;; string.  Reads of an epoch or a memo hit allocate 0.
;;
;; A definition (`drgnx-epoch-define', `drgnx-memo-define', `drgnx-cache-define') is a DECLARATION, like `defvar':
;; made at the top level of a file, in core/ or modules/, never undone, listed in `drgnx-memo--registry' and in
;; `drgnx-memo-census' (which the soak checks against the caps).  What a module OWNS is what has a global effect:
;; `drgnx-memo-activate', called in its :setup, installs the variable watchers of the epochs it names and records
;; the undo that removes them again (and empties the memos and caches it names); the fingerprint reads the live
;; watches (`drgnx-memo--watched').  This file needs nothing but Emacs: the recorder is reached through `fboundp', so it loads in batch
;; processes that never load the modules.  See docs/develop/core.md, "Epochs, memos and caches".

;;; Code:
(eval-when-compile (require 'cl-lib))

(declare-function drgnx-modules-push-undo "drgnx-modules-record")

(cl-defstruct (drgnx-memo--def (:constructor drgnx-memo--make-def) (:copier nil))
  "One definition: an epoch, a memo or a cache."
  kind name doc
  per redisplay                   ; epoch
  on keys table slot              ; memo: ON, the key forms, the weak table (ON non-nil) or SLOT (ON nil)
  key cap (clock 0))              ; cache: KEY (`object' or `string'), CAP, the LRU stamp counter

(defvar drgnx-memo--registry (make-hash-table :test #'equal)
  "LABEL (\"epoch NAME\", \"memo NAME\" or \"cache NAME\") → the definition: declarations, not owned state.")

(defvar drgnx-memo--active nil
  "Alist EPOCH-NAME → how many `drgnx-memo-activate' calls hold its watchers.")

(defvar drgnx-memo--watched nil
  "Alist VARIABLE → the names of the epochs that `drgnx-memo--watcher' bumps when VARIABLE is set.")

(defvar drgnx-memo--compile-known nil
  "Epoch names that code being expanded or compiled defines with a literal name, before they exist at run time.")

(defun drgnx-memo--options (args allowed)
  "ARGS, a plist, checked: every key is in ALLOWED."
  (let ((rest args))
    (while rest
      (unless (and (memq (car rest) allowed) (cdr rest))
        (error "Unknown or incomplete option %S (allowed: %S)" (car rest) allowed))
      (setq rest (cddr rest)))
    args))

(defun drgnx-memo--label (kind name) (format "%s %s" kind name))

(defun drgnx-memo--register (prop def)
  "Make DEF the definition of its name under symbol property PROP, and list it."
  (let ((name (drgnx-memo--def-name def)) (kind (drgnx-memo--def-kind def)))
    (put name prop def)
    (puthash (drgnx-memo--label kind name) def drgnx-memo--registry)
    nil))

(defun drgnx-memo--undefine (def)
  "Remove DEF's definition, when it is still the one of its name (tests; a declaration is otherwise permanent).
An epoch loses its watchers and keeps its count for a later definition."
  (when def
    (let* ((name (drgnx-memo--def-name def)) (kind (drgnx-memo--def-kind def))
           (prop (pcase kind ('epoch 'drgnx-epoch--def) ('memo 'drgnx-memo--def) (_ 'drgnx-cache--def))))
      (when (eq (get name prop) def)
        (when (eq kind 'epoch)
          (dolist (entry (copy-sequence drgnx-memo--watched)) (drgnx-memo--unwatch (car entry) name))
          (setq drgnx-memo--active (assq-delete-all name drgnx-memo--active))
          (put name 'drgnx-epoch--last (get name 'drgnx-epoch--value))
          (put name 'drgnx-epoch--value nil))
        (put name prop nil)
        (when (eq (gethash (drgnx-memo--label kind name) drgnx-memo--registry) def)
          (remhash (drgnx-memo--label kind name) drgnx-memo--registry))))))

;;;; Epochs

(defconst drgnx-epoch--fixnum-limit most-positive-fixnum)

(defun drgnx-epoch--note-literal (form &rest _)
  "Compiler macro of `drgnx-epoch-define': a literal name is known to later forms of the file being expanded."
  (let ((name (nth 1 form)))
    (when (and (eq (car-safe name) 'quote) (not (memq (cadr name) drgnx-memo--compile-known)))
      (push (cadr name) drgnx-memo--compile-known))
    form))

(defun drgnx-epoch-define (name &rest args)
  "Define epoch NAME and return it.  ARGS: `:per' nil, `buffer' or `object'; `:watch' the variables whose
setting bumps it (`drgnx-epoch-watch'); `:redisplay' non-nil (a bump also
calls `force-mode-line-update': all windows for a global, object or base bump, that buffer's for a buffer's); `:doc'.
A global epoch is one counter.  A `buffer' epoch is a base counter plus one per buffer (weak on the buffer): its value
for a buffer is the base plus the buffer's own count, so either bump moves it.  An `object' epoch counts per object
\(an `equal' table: it grows by one fixnum per distinct object, so key it by ids, and it is never weak on the key — a
collected key would take its count back to 0 and repeat a value): its value for an object is the base plus the
object's count, and without an object it is the base plus the total of all the objects' bumps.  Counters wrap at the
fixnum limit.  A declaration: top level, never undone; the watchers start with `drgnx-memo-activate'.  A redefinition
goes on from the old count, so a memo never sees a value it already saw."
  (declare (compiler-macro drgnx-epoch--note-literal))
  (drgnx-memo--options args '(:per :redisplay :watch :doc))
  (let* ((per (plist-get args :per))
         (old (or (get name 'drgnx-epoch--value) (get name 'drgnx-epoch--last)))
         (start (cond ((fixnump old) old) ((vectorp old) (logand (+ (aref old 0) (aref old 1)) drgnx-epoch--fixnum-limit)) (t 0))))
    (unless (and name (symbolp name)) (signal 'wrong-type-argument (list 'symbolp name)))
    (unless (memq per '(nil buffer object)) (error "Epoch %s: :per is nil, buffer or object, not %S" name per))
    (put name 'drgnx-epoch--value
         (if per
             (vector start 0 (if (eq per 'buffer)
                                 (make-hash-table :test #'eq :weakness 'key)
                               (make-hash-table :test #'equal))
                     per)
           start))
    (put name 'drgnx-epoch--last nil)
    (put name 'drgnx-epoch--redisplay (and (plist-get args :redisplay) t))
    (drgnx-memo--register 'drgnx-epoch--def
                          (drgnx-memo--make-def :kind 'epoch :name name :per per
                                                :redisplay (plist-get args :redisplay) :doc (plist-get args :doc)))
    (when (plist-get args :watch) (drgnx-epoch-watch name (plist-get args :watch)))
    name))

(defun drgnx-epoch--read (name object)
  "The value of epoch NAME for OBJECT (see `drgnx-epoch').  Allocates nothing."
  (let ((s (get name 'drgnx-epoch--value)))
    (cond ((fixnump s) s)
          ((vectorp s)
           (cond (object (logand (+ (aref s 0) (gethash object (aref s 2) 0)) drgnx-epoch--fixnum-limit))
                 ((eq (aref s 3) 'object) (logand (+ (aref s 0) (aref s 1)) drgnx-epoch--fixnum-limit))
                 (t (aref s 0))))
          (t (error "No epoch %s" name)))))

(defmacro drgnx-epoch (name &optional object)
  "The value of epoch NAME (a fixnum) for OBJECT; allocates nothing.
Without OBJECT, a `buffer' epoch gives its base, and an `object' epoch the total of all bumps.  A global epoch
ignores OBJECT.  An undefined NAME signals `(error \"No epoch NAME\")': when NAME is a quoted literal, at expansion
\(so define the epoch with a literal name above its first use, or require the file that does), else at run time."
  (if (eq (car-safe name) 'quote)
      (let ((n (cadr name)))
        (unless (or (get n 'drgnx-epoch--def) (memq n drgnx-memo--compile-known))
          (error "No epoch %s" n))
        (if object
            `(let* ((o ,object) (s (get ',n 'drgnx-epoch--value)))
               (if (fixnump s) s (drgnx-epoch--read ',n o)))
          `(let ((s (get ',n 'drgnx-epoch--value)))
             (if (fixnump s) s (drgnx-epoch--read ',n nil)))))
    `(drgnx-epoch--read ,name ,object)))

(defsubst drgnx-epoch--wrap (n) (logand (1+ n) drgnx-epoch--fixnum-limit))

(defun drgnx-epoch--bump (name object)
  "Bump epoch NAME for OBJECT and return the new value, or nil when NAME is not defined.  Cheap: a watcher calls it."
  (let ((s (get name 'drgnx-epoch--value)) new)
    (when s
      (if (fixnump s)
          (setq new (put name 'drgnx-epoch--value (drgnx-epoch--wrap s)))
        (if object
            (let ((table (aref s 2)))
              (puthash object (drgnx-epoch--wrap (gethash object table 0)) table)
              (when (eq (aref s 3) 'object) (aset s 1 (drgnx-epoch--wrap (aref s 1)))))
          (aset s 0 (drgnx-epoch--wrap (aref s 0))))
        (setq new (drgnx-epoch--read name object)))
      (when (get name 'drgnx-epoch--redisplay)
        (if (and object (vectorp s) (eq (aref s 3) 'buffer) (buffer-live-p object))
            (with-current-buffer object (force-mode-line-update))
          (force-mode-line-update t)))
      new)))

(defun drgnx-epoch-bump (name &optional object)
  "Bump epoch NAME and return its new value.  With OBJECT, on a `buffer' or `object' epoch, bump OBJECT's own count;
without it, the base.  A global epoch has one counter.  A `:redisplay' epoch also calls `force-mode-line-update'."
  (or (drgnx-epoch--bump name object) (error "No epoch %s" name)))

;;;; Watchers: a set of a variable bumps its epochs

(defun drgnx-memo--same-p (symbol newval where)
  "Non-nil if setting SYMBOL (in buffer WHERE, else its default) to NEWVAL leaves the value it has now."
  (if where
      (and (buffer-live-p where) (buffer-local-boundp symbol where) (eq newval (buffer-local-value symbol where)))
    (and (default-boundp symbol) (eq newval (default-value symbol)))))

(defun drgnx-memo--watcher (symbol newval operation where)
  "Variable watcher: a `set', `makunbound' or `defvaralias' of SYMBOL bumps its epochs.
A `let' or `unlet' does not (a dynamic binding, undone at once).  Emacs reports some bindings as a `set' with WHERE
nil — the `let' of a per-buffer variable that is not local in the buffer binds the default — so a `set' of an atom
`eq' to the value it replaces does not bump either.  A `let' to a different value of such a variable does, and moves
every buffer.  For a buffer-local set WHERE is the buffer, whose own count moves; for a global set the base."
  (when (and (memq operation '(set makunbound defvaralias))
             (not (and (eq operation 'set) (atom newval) (drgnx-memo--same-p symbol newval where))))
    (dolist (name (cdr (assq symbol drgnx-memo--watched)))
      (drgnx-epoch--bump name where))))

(defun drgnx-memo--watch (variable name)
  "Epoch NAME starts watching VARIABLE."
  (let ((entry (assq variable drgnx-memo--watched)))
    (unless (memq name (cdr entry))
      (if entry (setcdr entry (cons name (cdr entry))) (push (list variable name) drgnx-memo--watched))
      (add-variable-watcher variable #'drgnx-memo--watcher))))

(defun drgnx-memo--unwatch (variable name)
  "Stop epoch NAME's watch of VARIABLE; the watcher leaves VARIABLE when no epoch watches it any more."
  (let ((entry (assq variable drgnx-memo--watched)))
    (when (memq name (cdr entry))
      (setcdr entry (delq name (cdr entry)))
      (unless (cdr entry)
        (setq drgnx-memo--watched (delq entry drgnx-memo--watched))
        (remove-variable-watcher variable #'drgnx-memo--watcher)))))

(defun drgnx-epoch-watch (name variables)
  "Declare that setting one of VARIABLES bumps epoch NAME (a `let' does not count: `drgnx-memo--watcher').
A declaration, like `:watch' of `drgnx-epoch-define': nothing is watched until `drgnx-memo-activate' names NAME."
  (unless (get name 'drgnx-epoch--def) (error "No epoch %s" name))
  (dolist (variable variables)
    (unless (memq variable (get name 'drgnx-epoch--watch))
      (put name 'drgnx-epoch--watch (append (get name 'drgnx-epoch--watch) (list variable)))
      (when (assq name drgnx-memo--active) (drgnx-memo--watch variable name))))
  nil)

(defun drgnx-memo--deactivate-epoch (name)
  "Undo one activation of epoch NAME; the last one removes its watchers."
  (let ((cell (assq name drgnx-memo--active)))
    (when cell
      (if (> (cdr cell) 1)
          (setcdr cell (1- (cdr cell)))
        (setq drgnx-memo--active (delq cell drgnx-memo--active))
        (dolist (variable (get name 'drgnx-epoch--watch)) (drgnx-memo--unwatch variable name))))))

(defun drgnx-memo-activate (&rest names)
  "Put the declared epochs, memos and caches NAMES to work for the module whose :setup calls this.
An epoch's variable watchers are installed (the first activation does it; an epoch several modules activate keeps
them until the last one is off).  A memo's and a cache's contents are emptied when the module is torn down.  Each
step pushes its undo (`drgnx-modules-push-undo'), so turning the module off leaves no watcher and no contents, and
turning it on again activates afresh.  Outside a setup nothing is undone: call it from a :setup.  A name that
declares nothing signals."
  (dolist (name names)
    (let ((found nil))
      (when (get name 'drgnx-epoch--def)
        (setq found t)
        (let ((cell (assq name drgnx-memo--active)))
          (if cell
              (setcdr cell (1+ (cdr cell)))
            (push (cons name 1) drgnx-memo--active)
            (dolist (variable (get name 'drgnx-epoch--watch)) (drgnx-memo--watch variable name))))
        (when (fboundp 'drgnx-modules-push-undo)
          (drgnx-modules-push-undo (drgnx-memo--label 'epoch name) (lambda () (drgnx-memo--deactivate-epoch name)))))
      (when (get name 'drgnx-memo--def)
        (setq found t)
        (when (fboundp 'drgnx-modules-push-undo)
          (drgnx-modules-push-undo (drgnx-memo--label 'memo name) (lambda () (drgnx-memo-forget name)))))
      (when (get name 'drgnx-cache--def)
        (setq found t)
        (when (fboundp 'drgnx-modules-push-undo)
          (drgnx-modules-push-undo (drgnx-memo--label 'cache name) (lambda () (drgnx-cache--clear name)))))
      (unless found (error "Nothing declared as %s" name))))
  nil)

;;;; Memos

(defun drgnx-memo--define (name on keys doc)
  "Define memo NAME (see `drgnx-memo-define')."
  (unless (and name (symbolp name)) (signal 'wrong-type-argument (list 'symbolp name)))
  (unless (memq on '(nil window buffer frame)) (error "Memo %s: :on is window, buffer, frame or nil, not %S" name on))
  (drgnx-memo--register 'drgnx-memo--def
                        (drgnx-memo--make-def :kind 'memo :name name :doc doc :on on :keys keys
                                              :table (and on (make-hash-table :test #'eq :weakness 'key))))
  name)

(defmacro drgnx-memo-define (name &rest args)
  "Define memo NAME (an unquoted symbol) for `drgnx-memo'.  ARGS: `:on' window, buffer, frame or nil (one global
slot); `:keys' a list of forms, evaluated where `drgnx-memo' is used, that may refer to the variable `object'; `:doc'.
The table is weak on the key.  The definition is made when the code is expanded or compiled too, so `drgnx-memo' can
read the key forms: put it at the top level of a file.  A declaration, never undone; a module's :setup
empties it on teardown with `drgnx-memo-activate'."
  (declare (indent 1))
  (drgnx-memo--options args '(:on :keys :doc))
  `(eval-and-compile
     (drgnx-memo--define ',name ',(plist-get args :on) ',(plist-get args :keys) ,(plist-get args :doc))))

(defun drgnx-memo--lookup (name object)
  "The stored vector (keys, then the value) of memo NAME for OBJECT, or nil.  Allocates nothing."
  (let ((def (get name 'drgnx-memo--def)))
    (and def (if (drgnx-memo--def-on def)
                 (gethash object (drgnx-memo--def-table def))
               (drgnx-memo--def-slot def)))))

(defun drgnx-memo--new (name object size)
  "A new stored vector of SIZE for memo NAME and OBJECT."
  (let ((def (or (get name 'drgnx-memo--def) (error "No memo %s" name))) (v (make-vector size nil)))
    (if (drgnx-memo--def-on def) (puthash object v (drgnx-memo--def-table def)) (setf (drgnx-memo--def-slot def) v))
    v))

(defmacro drgnx-memo (name object build)
  "The value of memo NAME (an unquoted symbol) for OBJECT, built by BUILD only when a key changed.
Evaluates each key form (`drgnx-memo-define') once, with the variable `object' bound to OBJECT.  When every value is
`eq' to the stored one, returns the stored value and conses nothing.  Otherwise evaluates BUILD, stores the values
into the vector of OBJECT (made on the first miss) with `aset', and returns BUILD's value.  A key that is a fresh
float, string or list never hits: use fixnums, symbols and objects.  An undefined NAME signals at expansion."
  (let* ((n (if (eq (car-safe name) 'quote) (cadr name) name))
         (def (or (get n 'drgnx-memo--def) (error "No memo %s" n)))
         (forms (drgnx-memo--def-keys def)) (count (length forms))
         (v (make-symbol "v")) (val (make-symbol "val"))
         (ks (mapcar (lambda (_) (make-symbol "k")) forms)) (i -1))
    `(let* ((object ,object) (,v (drgnx-memo--lookup ',n object))
            ,@(let ((fs forms)) (mapcar (lambda (k) (list k (pop fs))) ks)))
       (if (and ,v ,@(mapcar (lambda (k) `(eq ,k (aref ,v ,(setq i (1+ i))))) ks))
           (aref ,v ,count)
         (let ((,val ,build))
           (unless ,v (setq ,v (drgnx-memo--new ',n object ,(1+ count))))
           ,@(let ((j -1)) (mapcar (lambda (k) `(aset ,v ,(setq j (1+ j)) ,k)) ks))
           (aset ,v ,count ,val)
           ,val)))))

(defun drgnx-memo-forget (name &optional object)
  "Drop memo NAME's stored value for OBJECT, or for every object without one."
  (let ((def (get name 'drgnx-memo--def)))
    (when def
      (cond ((not (drgnx-memo--def-on def)) (setf (drgnx-memo--def-slot def) nil))
            (object (remhash object (drgnx-memo--def-table def)))
            (t (clrhash (drgnx-memo--def-table def)))))
    nil))

;;;; Caches

(defun drgnx-cache-define (name &rest args)
  "Define cache NAME and return it.  ARGS: `:key' `object' (a weak `eq' table: a get checks that a buffer, window,
frame or process is live and drops a dead entry) or `string' (an `equal' table with an LRU: a get stamps the entry,
a put past `:cap' evicts the oldest stamp); `:cap' a positive integer, required for `string'; `:doc'.
A declaration, never undone; a module's :setup empties it on
teardown with `drgnx-memo-activate'."
  (drgnx-memo--options args '(:key :cap :doc))
  (let ((key (plist-get args :key)) (cap (plist-get args :cap)))
    (unless (and name (symbolp name)) (signal 'wrong-type-argument (list 'symbolp name)))
    (unless (memq key '(object string)) (error "Cache %s: :key is object or string, not %S" name key))
    (when (eq key 'string)
      (unless (and (integerp cap) (> cap 0)) (error "Cache %s: a string cache needs :cap, a positive integer" name)))
    (drgnx-memo--register 'drgnx-cache--def
                          (drgnx-memo--make-def :kind 'cache :name name :doc (plist-get args :doc) :key key
                                                :cap (and (eq key 'string) cap)
                                                :table (if (eq key 'string)
                                                           (make-hash-table :test #'equal)
                                                         (make-hash-table :test #'eq :weakness 'key))))
    name))

(defun drgnx-cache--def (name) (or (get name 'drgnx-cache--def) (error "No cache %s" name)))

(defun drgnx-cache--live-p (k)
  "Non-nil unless K is a killed buffer, deleted window or frame, or a dead process."
  (cond ((bufferp k) (buffer-live-p k)) ((windowp k) (window-live-p k)) ((framep k) (frame-live-p k))
        ((processp k) (process-live-p k)) (t t)))

(defun drgnx-cache-get (name k)
  "The value of K in cache NAME, or nil.  A string hit stamps the entry (`setcdr': no allocation); a dead object
key drops its entry."
  (let* ((def (drgnx-cache--def name)) (table (drgnx-memo--def-table def)))
    (if (eq (drgnx-memo--def-key def) 'string)
        (let ((entry (gethash k table)))
          (when entry
            (setcdr entry (setf (drgnx-memo--def-clock def) (1+ (drgnx-memo--def-clock def))))
            (car entry)))
      (if (drgnx-cache--live-p k)
          (gethash k table)
        (remhash k table)
        nil))))

(defun drgnx-cache--evict (def)
  "Drop DEF's entry with the oldest stamp (a scan of the table: on put only)."
  (let ((table (drgnx-memo--def-table def)) oldest stamp)
    (maphash (lambda (k entry) (when (or (null stamp) (< (cdr entry) stamp)) (setq oldest k stamp (cdr entry)))) table)
    (when stamp (remhash oldest table))))

(defun drgnx-cache-put (name k v)
  "Store V under K in cache NAME and return V.  A string cache past its cap evicts the oldest stamp."
  (let* ((def (drgnx-cache--def name)) (table (drgnx-memo--def-table def)))
    (if (eq (drgnx-memo--def-key def) 'string)
        (let ((stamp (setf (drgnx-memo--def-clock def) (1+ (drgnx-memo--def-clock def)))) (entry (gethash k table)))
          (if entry
              (setcdr (progn (setcar entry v) entry) stamp)
            (puthash k (cons v stamp) table)
            (when (> (hash-table-count table) (drgnx-memo--def-cap def)) (drgnx-cache--evict def))))
      (puthash k v table))
    v))

(defun drgnx-cache--clear (name)
  "Empty cache NAME (a module's teardown)."
  (let ((def (get name 'drgnx-cache--def)))
    (when def (clrhash (drgnx-memo--def-table def)))
    nil))

(defun drgnx-cache-remove (name k)
  "Drop K from cache NAME."
  (remhash k (drgnx-memo--def-table (drgnx-cache--def name)))
  nil)

(defun drgnx-cache-size (name)
  "How many entries cache NAME holds (an object cache first drops its dead keys)."
  (let* ((def (drgnx-cache--def name)) (table (drgnx-memo--def-table def)))
    (when (eq (drgnx-memo--def-key def) 'object)
      (let (dead) (maphash (lambda (k _) (unless (drgnx-cache--live-p k) (push k dead))) table)
           (dolist (k dead) (remhash k table))))
    (hash-table-count table)))

(defun drgnx-cache-keys (name)
  "The keys cache NAME holds now, as a fresh list in no order (a pass over the table: not for redisplay paths).
A string cache's keys are not stamped; an object cache's dead keys are dropped first."
  (drgnx-cache-size name)
  (let (keys) (maphash (lambda (k _) (push k keys)) (drgnx-memo--def-table (drgnx-cache--def name))) keys))

;;;; Census

(defun drgnx-memo-census ()
  "Every memo and cache as (NAME KIND SIZE CAP), by name.  KIND is `memo' or `cache'; CAP is nil for a memo and for
an object cache.  `drgnx-perf-soak' prints it and fails when a cache's SIZE passes its CAP."
  (let (rows)
    (maphash (lambda (_ def)
               (pcase (drgnx-memo--def-kind def)
                 ('memo (push (list (drgnx-memo--def-name def) 'memo
                                    (if (drgnx-memo--def-on def)
                                        (hash-table-count (drgnx-memo--def-table def))
                                      (if (drgnx-memo--def-slot def) 1 0))
                                    nil)
                              rows))
                 ('cache (push (list (drgnx-memo--def-name def) 'cache (drgnx-cache-size (drgnx-memo--def-name def))
                                     (drgnx-memo--def-cap def))
                               rows))))
             drgnx-memo--registry)
    (sort rows (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b)))))))

(provide 'drgnx-memo)
;;; drgnx-memo.el ends here
