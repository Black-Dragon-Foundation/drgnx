;;; drgnx-heap.el --- The heap audit: what keeps the live Lisp heap large, and who owns it -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A collection's pause grows with the live Lisp heap, not with the process's size.  The heap audit (Help → Heap Audit)
;; says what keeps that heap large: one collection of its own (origin `audit'), the live heap by type, what is not the
;; Lisp heap (RSS, buffer text, the image cache), and the retainers — global variables and symbol plists, buffers (their
;; text properties, overlays and local variables; the undo list on its own), processes, timers — each sized with
;; `memory-report''s walk over ONE table of what was counted, so a structure two owners reach is counted once, by the
;; first owner in a fixed order: drgnx, then Emacs, then packages.  An owner comes from the file that defined the
;; variable (one pass over `load-history') through `drgnx-owner-of-file'.  On request the memory profiler also records
;; who allocates (churn) for a while of normal use; churn sets how often a collection runs, not how long, so it is
;; kept apart from the retainers.
;;
;; The audit walks the whole heap, a stall of seconds on a large one, so it runs only when the user asks: the command
;; says first how long Emacs will not respond and asks; called from Lisp it never asks.  Nothing here runs on its own.
;; Each audit writes a snapshot, heap-YYYY-MM-DD.json beside the GC census's day files (sizes and names, never
;; contents), so audits compare over days.  `drgnx-heap-budgets' is the table of caps the doctor will judge
;; (`drgnx-heap-check'); its values are set from the first audits' numbers.  See docs/guide/speed.md.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'memory-report)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-gc)
(require 'drgnx-gc-census)
(require 'drgnx-owner)
(require 'drgnx-timer)

(declare-function timer--function "timer")
(declare-function timer--args "timer")

(defconst drgnx-heap-buffer-name "*Heap Audit*" "The audit's view.")

(defconst drgnx-heap--mib 1048576.0 "Bytes in the MB the audit shows (MiB, as the GC census).")

(defvar drgnx-heap-top 40 "How many retainers, the largest, a snapshot keeps.")

(defvar drgnx-heap-churn-seconds 120
  "How long the memory profiler records allocation (churn) after an audit that asks for it.")

(defvar drgnx-heap-near-share 0.9 "A measure at this share of its cap or more is `near' it.")

(defvar drgnx-heap-budgets nil
  "The heap budgets: a list of rows (:owner OWNER :measure MEASURE :cap MB :setting SYMBOL :fix TEXT).
MEASURE is `live' (the whole live Lisp heap; OWNER is \"total\"), `owner' (OWNER's retainers, OWNER a package,
\"emacs\" or \"drgnx\") or `sink' (a named sink, OWNER its label, e.g. \"kill ring\").  CAP is in MB (nil: not set
yet); SETTING is what enforces it; FIX is the doctor's fix line.  The values come from the first audits' numbers.")

(defvar drgnx-heap-sinks
  '((variable kill-ring "kill ring")
    (variable recentf-list "recent files")
    (variable-suffix "-history" "minibuffer history")
    (buffer-name "\\`\\*Messages\\*\\'" "messages")
    (buffer-name "\\`\\*EGLOT .* events\\*\\'" "language server events")
    (buffer-name "\\`\\*.* events\\*\\'" "jsonrpc events")
    (buffer-mode drgnx-agents-transcript-mode "agent transcript"))
  "Well-known sinks the audit names: a list of (variable SYMBOL LABEL), (variable-suffix SUFFIX LABEL),
\(buffer-name REGEXP LABEL) or (buffer-mode MODE LABEL); the first that matches gives a retainer its label.")

(defvar drgnx-heap--last nil "The last snapshot this Emacs took, or nil.")

;;;; Owners

(cl-defstruct (drgnx-heap--ctx (:constructor drgnx-heap--ctx-make) (:copier nil))
  "One audit's lookup tables."
  (vars (make-hash-table :test #'eq :size 32768) :documentation "Variable → the file that defined it.")
  (funs (make-hash-table :test #'eq :size 32768) :documentation "Function → the file that defined it.")
  (files (make-hash-table :test #'equal) :documentation "File → its owner (memo of `drgnx-owner-of-file').")
  (rows (make-hash-table :test #'equal) :documentation "(KIND NAME OWNER) → row.")
  (skipped 0 :documentation "Retainers whose walk failed (counted as 0)."))

(defun drgnx-heap--definitions (ctx)
  "Fill CTX's variable and function tables from one pass over `load-history' (the newest load first, as
`symbol-file')."
  (let ((vars (drgnx-heap--ctx-vars ctx)) (funs (drgnx-heap--ctx-funs ctx)))
    (dolist (entry load-history)
      (let ((file (car entry)))
        (when (stringp file)
          (dolist (item (cdr entry))
            (cond ((symbolp item) (unless (gethash item vars) (puthash item file vars)))
                  ((eq (car-safe item) 'defun)
                   (let ((f (cdr item))) (when (and (symbolp f) (not (gethash f funs))) (puthash f file funs)))))))))))

(defun drgnx-heap--file-owner (ctx file)
  "(OWNER . DETAIL) of FILE, memoized in CTX; (\"unknown\") when nobody owns it."
  (let ((memo (drgnx-heap--ctx-files ctx)))
    (or (gethash file memo)
        (puthash file (or (drgnx-owner-of-file file) (list "unknown")) memo))))

(defconst drgnx-heap--emacs "emacs" "The owner name of what Emacs's C core holds (an owner, never a program).")

(defun drgnx-heap--var-owner (ctx symbol)
  "(OWNER . DETAIL) of the variable SYMBOL: its defining file's owner; with no file, \"emacs\" for a special variable
\(the C core's), else \"unknown\"."
  (let ((file (gethash symbol (drgnx-heap--ctx-vars ctx))))
    (cond (file (drgnx-heap--file-owner ctx file))
          ((special-variable-p symbol) (list drgnx-heap--emacs))
          (t (list "unknown")))))

(defun drgnx-heap--fun-owner (ctx function)
  "(OWNER . DETAIL) of the function symbol FUNCTION: its defining file's owner; \"emacs\" for a primitive."
  (let ((file (and (symbolp function) (gethash function (drgnx-heap--ctx-funs ctx)))))
    (cond (file (drgnx-heap--file-owner ctx file))
          ((and (symbolp function) (fboundp function) (subr-primitive-p (symbol-function function))) (list drgnx-heap--emacs))
          (t (list "unknown")))))

(defun drgnx-heap--generic-p (owner)
  "Whether OWNER (OWNER . DETAIL) says nothing about who made something: \"emacs\" or \"unknown\"."
  (member (car owner) (list drgnx-heap--emacs "unknown")))

(defun drgnx-heap--symbol-owner (ctx symbol)
  "The owner of SYMBOL's plist: its function's file, else its variable's."
  (let ((fo (drgnx-heap--fun-owner ctx symbol)))
    (if (equal (car fo) "unknown") (drgnx-heap--var-owner ctx symbol) fo)))

(defun drgnx-heap--process-owner (ctx process)
  "The owner of PROCESS: its filter's or sentinel's (a named function), else its buffer's major mode's, else \"emacs\"."
  (or (seq-find (lambda (o) (not (drgnx-heap--generic-p o)))
                (mapcar (lambda (f) (drgnx-heap--fun-owner ctx f))
                        (seq-filter #'symbolp (list (process-filter process) (process-sentinel process)))))
      (let ((b (process-buffer process)))
        (and (buffer-live-p b)
             (let ((mo (drgnx-heap--fun-owner ctx (buffer-local-value 'major-mode b))))
               (and (not (drgnx-heap--generic-p mo)) mo))))
      (list drgnx-heap--emacs)))

(defun drgnx-heap--buffer-owner (ctx buffer)
  "The owner of BUFFER: its major mode's package, else (for a mode of Emacs's) its process's."
  (let ((mo (drgnx-heap--fun-owner ctx (buffer-local-value 'major-mode buffer))))
    (or (and (drgnx-heap--generic-p mo)
             (let ((p (get-buffer-process buffer)))
               (and p (let ((po (drgnx-heap--process-owner ctx p))) (and (not (drgnx-heap--generic-p po)) po)))))
        mo)))

(defun drgnx-heap--rank (owner)
  "The order owners are walked in: drgnx, then Emacs, then packages (and the rest)."
  (pcase (car owner) ("drgnx" 0) ("emacs" 1) (_ 2)))

;;;; Sinks

(defun drgnx-heap--variable-sink (symbol)
  "The label of the sink the variable SYMBOL is, or nil."
  (seq-some (lambda (s)
              (pcase s
                (`(variable ,v ,label) (and (eq v symbol) label))
                (`(variable-suffix ,suffix ,label) (and (string-suffix-p suffix (symbol-name symbol)) label))))
            drgnx-heap-sinks))

(defun drgnx-heap--buffer-sink (buffer)
  "The label of the sink BUFFER is, or nil."
  (seq-some (lambda (s)
              (pcase s
                (`(buffer-name ,re ,label) (and (string-match-p re (buffer-name buffer)) label))
                (`(buffer-mode ,mode ,label)
                 (and (provided-mode-derived-p (buffer-local-value 'major-mode buffer) mode) label))))
            drgnx-heap-sinks))

;;;; Sizes

(defun drgnx-heap--closure-size (counted closure)
  "CLOSURE's bytes not in COUNTED: its header, code and captured values (`memory-report' counts a closure as 0)."
  (if (gethash closure counted) 0
    (puthash closure t counted)
    (+ (memory-report--size 'vector) (* 6 (memory-report--size 'object))
       (memory-report--object-size counted (ignore-errors (aref closure 1)))
       (memory-report--object-size counted (ignore-errors (aref closure 2))))))

(defun drgnx-heap--size (counted object)
  "OBJECT's bytes not counted yet in COUNTED, by `memory-report''s walk; closures, which that walk counts as nothing,
are opened one level: OBJECT itself, or one that a list (a hook) or a vector OBJECT holds directly."
  (let ((n 0))
    (cond ((closurep object) (setq n (drgnx-heap--closure-size counted object)))
          ((and (consp object) (proper-list-p object))
           (dolist (x object) (when (closurep x) (cl-incf n (drgnx-heap--closure-size counted x)))))
          ((vectorp object)
           (dotimes (i (length object))
             (let ((x (aref object i))) (when (closurep x) (cl-incf n (drgnx-heap--closure-size counted x)))))))
    (+ n (memory-report--object-size counted object))))

(defun drgnx-heap--sizable-p (value)
  "Whether VALUE can hold more than its own word: a cons, string, vector, record, hash table or closure."
  (or (consp value) (stringp value) (vectorp value) (recordp value) (hash-table-p value) (closurep value)
      (bool-vector-p value) (char-table-p value)))

(defun drgnx-heap--buffer-props (counted buffer)
  "BUFFER's text properties and overlays, in bytes not counted yet in COUNTED (its text is not the Lisp heap)."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (let ((n (memory-report--interval-size counted (object-intervals buffer))))
        (dolist (ov (overlays-in (point-min) (point-max)))
          (cl-incf n (+ (memory-report--size 'vector) (memory-report--object-size counted (overlay-properties ov)))))
        n))))

(defun drgnx-heap--buffer-text-bytes ()
  "Bytes of every buffer's text and gap: in RSS, but not walked by a collection."
  (let ((n 0))
    (dolist (b (buffer-list) n)
      (with-current-buffer b
        (save-restriction
          (widen)
          (cl-incf n (+ (- (position-bytes (point-max)) (position-bytes (point-min))) (gap-size))))))))

;;;; The walk

(defun drgnx-heap--root (owner kind name &optional sink value thunk)
  "A retainer to walk: [RANK KIND NAME OWNER SINK VALUE THUNK]; THUNK, when given, is called with the counted table."
  (vector (drgnx-heap--rank owner) kind name owner sink value thunk))

(defun drgnx-heap--roots (ctx)
  "Every retainer to walk, unsorted."
  (let (roots)
    (mapatoms
     (lambda (sym)
       (when (and (not (keywordp sym)) (default-boundp sym))
         (let ((v (ignore-errors (default-value sym))))
           (when (drgnx-heap--sizable-p v)
             (push (drgnx-heap--root (drgnx-heap--var-owner ctx sym) 'variable (symbol-name sym)
                                     (drgnx-heap--variable-sink sym) v)
                   roots))))
       (when-let* ((plist (symbol-plist sym)))
         (push (drgnx-heap--root (drgnx-heap--symbol-owner ctx sym) 'plist "symbol plists" nil plist) roots))))
    (dolist (b (buffer-list))
      (let ((name (buffer-name b)) (owner (drgnx-heap--buffer-owner ctx b)) (sink (drgnx-heap--buffer-sink b)))
        (push (drgnx-heap--root owner 'buffer name sink nil (lambda (counted) (drgnx-heap--buffer-props counted b)))
              roots)
        (dolist (local (buffer-local-variables b))
          (when (and (consp local) (not (eq (car local) 'buffer-undo-list)) (drgnx-heap--sizable-p (cdr local)))
            (let ((vo (drgnx-heap--var-owner ctx (car local))))
              (push (drgnx-heap--root (if (drgnx-heap--generic-p vo) owner vo) 'buffer name sink (cdr local)) roots))))
        (let ((undo (buffer-local-value 'buffer-undo-list b)))
          (when (consp undo) (push (drgnx-heap--root owner 'undo name sink undo) roots)))))
    (dolist (p (process-list))
      (push (drgnx-heap--root (drgnx-heap--process-owner ctx p) 'process (process-name p) nil
                              (list (process-plist p) (process-filter p) (process-sentinel p)))
            roots))
    (dolist (tm (append timer-list timer-idle-list))
      (let ((fn (timer--function tm)))
        (push (drgnx-heap--root (if (and fn (symbolp fn)) (drgnx-heap--fun-owner ctx fn) (list "unknown"))
                                'timer (if (and fn (symbolp fn)) (symbol-name fn) "<lambda>") nil nil
                                (lambda (counted)
                                  (+ (drgnx-heap--size counted fn) (drgnx-heap--size counted (timer--args tm))
                                     (drgnx-heap--size counted tm))))
              roots)))
    roots))

(defun drgnx-heap--walk (ctx)
  "Size every retainer with one counted table, drgnx's first, then Emacs's, then the packages'; fill CTX's rows."
  (let ((counted (make-hash-table :test #'eq :size 65536))
        (rows (drgnx-heap--ctx-rows ctx)))
    (dolist (root (cl-stable-sort (drgnx-heap--roots ctx) #'< :key (lambda (r) (aref r 0))))
      (let* ((owner (aref root 3))
             (bytes (condition-case nil
                        (if (aref root 6) (funcall (aref root 6) counted) (drgnx-heap--size counted (aref root 5)))
                      (error (cl-incf (drgnx-heap--ctx-skipped ctx)) 0)))
             (key (list (aref root 1) (aref root 2) (car owner)))
             (row (gethash key rows)))
        (if row
            (plist-put row :bytes (+ (plist-get row :bytes) bytes))
          (puthash key (list :kind (aref root 1) :name (aref root 2) :owner (car owner) :detail (cdr owner)
                             :bytes bytes :sink (aref root 4))
                   rows))))))

;;;; The snapshot

(defun drgnx-heap--mb (bytes)
  "BYTES in MB, two decimals."
  (/ (round (* 100 (/ bytes drgnx-heap--mib))) 100.0))

(defun drgnx-heap--live-bytes (heapsize)
  "The live bytes of HEAPSIZE, a list of (NAME SIZE USED [FREE]) as `garbage-collect' returns."
  (let ((n 0)) (dolist (e heapsize n) (cl-incf n (* (nth 1 e) (nth 2 e))))))

(defun drgnx-heap--by-type (heapsize)
  "HEAPSIZE as the census's heap: (:live-mb :free-mb :NAME-mb …), the types by name."
  (let ((free 0) types)
    (dolist (e heapsize)
      (cl-incf free (* (nth 1 e) (or (nth 3 e) 0)))
      (setq types (append types (list (intern (format ":%s-mb" (car e))) (drgnx-heap--mb (* (nth 1 e) (nth 2 e)))))))
    (append (list :live-mb (drgnx-heap--mb (drgnx-heap--live-bytes heapsize)) :free-mb (drgnx-heap--mb free)) types)))

(defun drgnx-heap--smaps ()
  "/proc/self/smaps_rollup as (:rss-bytes N :pss-bytes N …), or nil where there is none."
  (when-let* (((eq system-type 'gnu/linux))
              (text (ignore-errors (drgnx-file-read-bounded "/proc/self/smaps_rollup" :max-bytes 65536))))
    (let (out)
      (dolist (line (split-string text "\n" t) out)
        (when (string-match "\\`\\([A-Za-z_]+\\):[ \t]+\\([0-9]+\\) kB" line)
          (setq out (append out (list (intern (format ":%s-bytes" (downcase (string-replace "_" "-" (match-string 1 line)))))
                                      (* 1024 (string-to-number (match-string 2 line)))))))))))

(defun drgnx-heap--non-heap ()
  "What is not the Lisp heap: RSS, the mappings, buffer text, the image cache (bytes)."
  (let ((default-directory "/") (file-name-handler-alist nil))
    (list :rss-bytes (let ((kb (alist-get 'rss (ignore-errors (process-attributes (emacs-pid)))))) (and kb (* 1024 kb)))
          :smaps (drgnx-heap--smaps)
          :buffer-text-bytes (drgnx-heap--buffer-text-bytes)
          :image-cache-bytes (if (fboundp 'image-cache-size) (image-cache-size) 0))))

(defun drgnx-heap--sum-by (rows key)
  "((VALUE . BYTES) …) of ROWS summed by their KEY (rows without it are left out), the largest first."
  (let (sums)
    (dolist (r rows)
      (when-let* ((k (plist-get r key)))
        (let ((cell (assoc k sums)))
          (if cell (setcdr cell (+ (cdr cell) (plist-get r :bytes))) (push (cons k (plist-get r :bytes)) sums)))))
    (sort sums (lambda (a b) (> (cdr a) (cdr b))))))

(defun drgnx-heap-dir ()
  "Where audits keep their snapshots: beside the GC census's day files (`drgnx-gc-census-directory')."
  (drgnx-gc-census-directory))

(defun drgnx-heap--json (x)
  "X, a snapshot or a part of it, as `json-serialize' takes it: a plist becomes an object with snake_case keys, any
other list an array, nil null, a symbol its name."
  (cond ((and (consp x) (keywordp (car x)))
         (let (out)
           (while x
             (push (cons (intern (string-replace "-" "_" (substring (symbol-name (car x)) 1))) (drgnx-heap--json (cadr x)))
                   out)
             (setq x (cddr x)))
           (nreverse out)))
        ((consp x) (vconcat (mapcar #'drgnx-heap--json x)))
        ((null x) :null)
        ((eq x t) t)
        ((symbolp x) (symbol-name x))
        (t x)))

(defun drgnx-heap--write (snapshot)
  "Write SNAPSHOT to heap-YYYY-MM-DD.json in `drgnx-heap-dir' (private); the file."
  (let ((file (expand-file-name (format "heap-%s.json" (substring (plist-get snapshot :at) 0 10)) (drgnx-heap-dir))))
    (drgnx-file-write-text file (concat (decode-coding-string (json-serialize (drgnx-heap--json snapshot)) 'utf-8) "\n")
                           :private t)
    file))

(cl-defun drgnx-heap-audit (&key churn)
  "Audit the heap now and return the snapshot, also written to heap-YYYY-MM-DD.json in `drgnx-heap-dir'.
One collection (origin `audit'), then the walk: a stall of seconds on a large heap.  Never asks anything.  With
CHURN the memory profiler then records allocation for `drgnx-heap-churn-seconds' (`drgnx-heap--churn-done' adds it
to this snapshot).  The snapshot: (:v 1 :type heap :at :pid :emacs :duration-ms :gc-ms :heap (:live-mb …)
:non-heap (:rss-bytes :smaps :buffer-text-bytes :image-cache-bytes) :owners ((:owner :bytes :module) …)
:sinks ((:sink :bytes) …) :undo-bytes :retainers ((:kind :name :owner :detail :bytes :sink) …, the
`drgnx-heap-top' largest) :skipped :churn :file)."
  (let* ((start (float-time))
         (gc-before gc-elapsed)
         (heapsize (or (drgnx-gc-collect 'audit) (garbage-collect-heapsize)))
         (gc-ms (* 1000 (- gc-elapsed gc-before)))
         (ctx (drgnx-heap--ctx-make)))
    (memory-report--set-size heapsize)        ; the walk's sizes per type, from this collection
    (drgnx-heap--definitions ctx)
    (let ((non-heap (drgnx-heap--non-heap)))
      (drgnx-heap--walk ctx)
      (let* ((rows (hash-table-values (drgnx-heap--ctx-rows ctx)))
             (largest (seq-take (sort (seq-filter (lambda (r) (> (plist-get r :bytes) 0)) rows)
                                      (lambda (a b) (> (plist-get a :bytes) (plist-get b :bytes))))
                                drgnx-heap-top))
             (snapshot
              (list :v 1 :type 'heap :at (format-time-string "%FT%T.%3N%:z" start) :pid (emacs-pid)
                    :emacs emacs-version
                    :duration-ms (round (* 1000 (- (float-time) start))) :gc-ms (/ (round (* 10 gc-ms)) 10.0)
                    :heap (drgnx-heap--by-type heapsize)
                    :non-heap non-heap
                    :owners (mapcar (lambda (c) (list :owner (car c) :bytes (cdr c)
                                                      :module (when-let* ((m (drgnx-owner-module-for-package (car c))))
                                                                (symbol-name m))))
                                    (drgnx-heap--sum-by rows :owner))
                    :sinks (mapcar (lambda (c) (list :sink (car c) :bytes (cdr c))) (drgnx-heap--sum-by rows :sink))
                    :undo-bytes (apply #'+ (mapcar (lambda (r) (if (eq (plist-get r :kind) 'undo) (plist-get r :bytes) 0))
                                                   rows))
                    :retainers largest
                    :skipped (drgnx-heap--ctx-skipped ctx)
                    :churn nil)))
        (setq snapshot (append snapshot (list :file (drgnx-heap--write snapshot))))
        (setq drgnx-heap--last snapshot)
        (when churn (drgnx-heap--churn-start))
        snapshot))))

;;;; Churn

(defun drgnx-heap--churn-start ()
  "Start the memory profiler for `drgnx-heap-churn-seconds'; nil (and a message) when it cannot."
  (cond ((not (fboundp 'profiler-memory-start)) (message "Heap Audit: this Emacs has no memory profiler") nil)
        ((profiler-memory-running-p) (message "Heap Audit: the memory profiler is in use; churn not recorded") nil)
        (t (profiler-memory-start)
           (drgnx-timer-start 'heap-churn drgnx-heap-churn-seconds #'drgnx-heap--churn-done :owner :core)
           (message "Heap Audit: recording allocation for %d s of your normal use" drgnx-heap-churn-seconds)
           t)))

(defun drgnx-heap--churn-top (log)
  "The top allocating callers of the memory profile LOG (backtrace vector → bytes): each backtrace's innermost
frame that is not a primitive, as ((:fn NAME :owner OWNER :bytes N) …), the 20 largest."
  (let ((by (make-hash-table :test #'equal)) out)
    (maphash (lambda (frames bytes)
               (when-let* ((f (seq-find (lambda (f) (and f (not (and (symbolp f) (fboundp f)
                                                                     (subr-primitive-p (symbol-function f))))))
                                        frames)))
                 (let ((name (if (symbolp f) (symbol-name f) "<lambda>")))
                   (puthash name (+ bytes (gethash name by 0)) by))))
             log)
    (maphash (lambda (name bytes)
               (let ((file (ignore-errors (symbol-file (intern-soft name) 'defun))))
                 (push (list :fn name :owner (car (or (drgnx-owner-of-file file) (list "unknown"))) :bytes bytes) out)))
             by)
    (seq-take (sort out (lambda (a b) (> (plist-get a :bytes) (plist-get b :bytes)))) 20)))

(defun drgnx-heap--churn-done ()
  "The churn time is over: stop the memory profiler, add the top callers to the last snapshot and its file."
  (let ((log (profiler-memory-log)))
    (profiler-memory-stop)
    (when drgnx-heap--last
      (setq drgnx-heap--last (plist-put drgnx-heap--last :churn (drgnx-heap--churn-top log)))
      (drgnx-heap--write drgnx-heap--last)
      (when (get-buffer drgnx-heap-buffer-name) (drgnx-heap--show drgnx-heap--last t)))
    (message "Heap Audit: allocation recorded (Help → Heap Audit's view, \"Allocation\")")))

;;;; Budgets

(defun drgnx-heap-check (snapshot-or-heapsize &optional budgets)
  "Judge SNAPSHOT-OR-HEAPSIZE against BUDGETS (default `drgnx-heap-budgets'): a list of rows (:owner :measure :cap
:value-mb :state :setting :fix), STATE `over', `near' (at `drgnx-heap-near-share' of the cap or more) or `under', in
the table's order.  Rows with no cap are left out.  From a heapsize list (`garbage-collect-heapsize', free after
every collection) only `live' rows are judged; a snapshot judges every row."
  (let* ((heapsize-p (consp (car-safe snapshot-or-heapsize)))
         (live-mb (if heapsize-p (drgnx-heap--mb (drgnx-heap--live-bytes snapshot-or-heapsize))
                    (plist-get (plist-get snapshot-or-heapsize :heap) :live-mb)))
         rows)
    (dolist (b (or budgets drgnx-heap-budgets))
      (let* ((cap (plist-get b :cap))
             (owner (plist-get b :owner))
             (value (pcase (plist-get b :measure)
                      ('live live-mb)
                      ('owner (unless heapsize-p
                                (/ (or (plist-get (seq-find (lambda (o) (equal (plist-get o :owner) owner))
                                                            (plist-get snapshot-or-heapsize :owners))
                                                  :bytes)
                                       0)
                                   drgnx-heap--mib)))
                      ('sink (unless heapsize-p
                               (/ (or (plist-get (seq-find (lambda (s) (equal (plist-get s :sink) owner))
                                                           (plist-get snapshot-or-heapsize :sinks))
                                                 :bytes)
                                      0)
                                  drgnx-heap--mib))))))
        (when (and (numberp cap) (numberp value))
          (push (list :owner owner :measure (plist-get b :measure) :cap cap :value-mb (/ (round (* 100 value)) 100.0)
                      :state (cond ((> value cap) 'over) ((>= value (* drgnx-heap-near-share cap)) 'near) (t 'under))
                      :setting (plist-get b :setting) :fix (plist-get b :fix))
                rows))))
    (nreverse rows)))

;;;; The view and the command

(define-derived-mode drgnx-heap-mode special-mode "Heap Audit"
  "The heap audit's view: the live heap, what is not the heap, owners against their budgets, the largest retainers.")

(defun drgnx-heap--fmt-mb (bytes)
  (format "%9.1f MB" (/ (or bytes 0) drgnx-heap--mib)))

(defun drgnx-heap--render (snapshot)
  "Insert SNAPSHOT's view at point."
  (let ((heap (plist-get snapshot :heap)) (non (plist-get snapshot :non-heap)))
    (insert (format "Heap Audit · %s · the walk took %.1f s, its collection %.0f ms\n\n"
                    (substring (plist-get snapshot :at) 0 16) (/ (plist-get snapshot :duration-ms) 1000.0)
                    (plist-get snapshot :gc-ms)))
    (insert "The Lisp heap (what a collection walks)\n")
    (insert (format "  live %.1f MB · free %.1f MB\n" (plist-get heap :live-mb) (plist-get heap :free-mb)))
    (let (types)
      (cl-loop for (k v) on heap by #'cddr
               unless (memq k '(:live-mb :free-mb)) do (push (cons (substring (symbol-name k) 1 -3) v) types))
      (insert "  " (mapconcat (lambda (c) (format "%s %.1f MB" (car c) (cdr c)))
                              (sort types (lambda (a b) (> (cdr a) (cdr b)))) " · ")
              "\n\n"))
    (insert "Not the Lisp heap (it does not lengthen a collection)\n")
    (insert (format "  RSS %s · buffer text %s · image cache %s\n\n"
                    (string-trim (drgnx-heap--fmt-mb (plist-get non :rss-bytes)))
                    (string-trim (drgnx-heap--fmt-mb (plist-get non :buffer-text-bytes)))
                    (string-trim (drgnx-heap--fmt-mb (plist-get non :image-cache-bytes)))))
    (insert "By owner (shared data counted once, by drgnx first, then Emacs, then packages)\n")
    (dolist (o (plist-get snapshot :owners))
      (insert (format "  %s  %s%s\n" (drgnx-heap--fmt-mb (plist-get o :bytes)) (plist-get o :owner)
                      (if (plist-get o :module) (format " (module %s)" (plist-get o :module)) ""))))
    (insert "\nBudgets\n")
    (let ((rows (drgnx-heap-check snapshot)))
      (if (null rows) (insert "  No budgets are set yet.\n")
        (dolist (r rows)
          (insert (format "  %-6s %s %s: %.1f of %s MB — %s\n" (plist-get r :state) (plist-get r :owner)
                          (plist-get r :measure) (plist-get r :value-mb) (plist-get r :cap) (plist-get r :fix))))))
    (insert "\nLargest retainers\n")
    (dolist (r (plist-get snapshot :retainers))
      (insert (format "  %s  %-8s %-40s %s%s%s\n" (drgnx-heap--fmt-mb (plist-get r :bytes)) (plist-get r :kind)
                      (truncate-string-to-width (plist-get r :name) 40 nil nil "…") (plist-get r :owner)
                      (if (plist-get r :detail) (format " (%s)" (plist-get r :detail)) "")
                      (if (plist-get r :sink) (format " · %s" (plist-get r :sink)) ""))))
    (insert (format "\nUndo lists: %s in all (each buffer's on its own row, kind undo)\n"
                    (string-trim (drgnx-heap--fmt-mb (plist-get snapshot :undo-bytes)))))
    (when (> (plist-get snapshot :skipped) 0)
      (insert (format "%d retainers could not be sized (counted as 0)\n" (plist-get snapshot :skipped))))
    (insert "\nAllocation (churn: how often a collection runs, not how long)\n")
    (if-let* ((churn (plist-get snapshot :churn)))
        (dolist (c churn)
          (insert (format "  %s  %s (%s)\n" (drgnx-heap--fmt-mb (plist-get c :bytes)) (plist-get c :fn) (plist-get c :owner))))
      (insert "  Not recorded (Heap Audit asks whether to record it).\n"))
    (insert (format "\nSnapshot: %s\n" (abbreviate-file-name (plist-get snapshot :file))))))

(defun drgnx-heap--show (snapshot &optional no-select)
  "Show SNAPSHOT in the view (NO-SELECT: redraw it where it is)."
  (let ((buffer (get-buffer-create drgnx-heap-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'drgnx-heap-mode) (drgnx-heap-mode) (buffer-disable-undo))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (drgnx-heap--render snapshot)
        (goto-char (point-min))))
    (unless no-select (pop-to-buffer buffer))
    buffer))

(defun drgnx-heap--expected ()
  "How long the next audit will stall, from the last snapshot (this session's, else the newest file), as text."
  (let ((ms (or (plist-get drgnx-heap--last :duration-ms)
                (when-let* ((dir (drgnx-heap-dir))
                            ((file-directory-p dir))
                            (newest (car (last (directory-files dir t "\\`heap-[0-9-]+\\.json\\'")))))
                  (ignore-errors
                    (plist-get (json-parse-string (drgnx-file-read-bounded newest :max-bytes (* 4 1024 1024))
                                                  :object-type 'plist)
                               :duration_ms))))))
    (if (numberp ms) (format "%d s" (max 1 (round ms 1000))) "a few seconds")))

(defun drgnx-heap-audit-command (&optional churn ask)
  "Heap Audit: what keeps the live Lisp heap large, by owner; the audit's view.
As a command it says first how long Emacs will not respond and asks (ASK), then whether to record allocation for
`drgnx-heap-churn-seconds' too.  Called from Lisp it never asks; CHURN records allocation."
  (interactive (list nil t))
  (let ((note (format "This walks the heap and collects garbage; Emacs will not respond for about %s."
                      (drgnx-heap--expected))))
    (if (not ask)
        (progn (message "%s" note) (drgnx-heap--show (drgnx-heap-audit :churn churn)))
      (when (y-or-n-p (concat note " Run it now? "))
        (let ((churn (y-or-n-p (format "Then record allocation (churn) for %d s of your normal use? "
                                       drgnx-heap-churn-seconds))))
          (message "Heap Audit: walking the heap…")
          (redisplay)
          (drgnx-heap--show (drgnx-heap-audit :churn churn)))))))

(provide 'drgnx-heap)
;;; drgnx-heap.el ends here
