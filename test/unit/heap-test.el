;;; heap-test.el --- batch tests: the heap audit, its snapshot and the budget check (core/drgnx-heap.el) -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'package)                      ; loaded before its variables are let-bound below
(require 'drgnx-paths)
(require 'drgnx)
(require 'drgnx-heap)

(defconst drgnx-heap-test--elpa (expand-file-name "test/fixtures/heap/" drgnx-dir)
  "A packages directory holding the fixture package wdheap-1.0.")

(defvar nidhogg-watchdog-gc-origin)
(defvar drgnx-heap-test--origins nil "The origin of each collection while a test listens, newest first.")

(defun drgnx-heap-test--note-origin ()
  "On `post-gc-hook' while a test listens: note the collection's origin."
  (push (bound-and-true-p nidhogg-watchdog-gc-origin) drgnx-heap-test--origins))

(defmacro drgnx-heap-test--with-state (&rest body)
  "BODY with a temp state dir (XDG_STATE_HOME) and no heap audit buffer before or after."
  (declare (indent 0) (debug t))
  `(let* ((state (make-temp-file "drgnx-heap-test" t))
          (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
     (unwind-protect (progn ,@body)
       (when-let* ((b (get-buffer drgnx-heap-buffer-name))) (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
       (delete-directory state t))))

(defmacro drgnx-heap-test--with-fixture (&rest body)
  "BODY with the fixture package wdheap loaded from its package directory and filled, and a temp state dir.
Undo lists are not truncated by the collection meanwhile."
  (declare (indent 0) (debug t))
  `(drgnx-heap-test--with-state
     (let ((package-alist nil) (package-directory-list nil) (package-user-dir drgnx-heap-test--elpa)
           (undo-limit most-positive-fixnum) (undo-strong-limit most-positive-fixnum) (undo-outer-limit nil))
       (load (expand-file-name "wdheap-1.0/wdheap.el" drgnx-heap-test--elpa) nil t t)
       (unwind-protect (progn (wdheap-fill) ,@body)
         (wdheap-empty)))))

(defun drgnx-heap-test--row (snapshot kind name)
  "The retainer row of SNAPSHOT for KIND and NAME, or nil."
  (seq-find (lambda (r) (and (eq (plist-get r :kind) kind) (equal (plist-get r :name) name)))
            (plist-get snapshot :retainers)))

(defun drgnx-heap-test--owner-bytes (snapshot owner)
  (or (plist-get (seq-find (lambda (o) (equal (plist-get o :owner) owner)) (plist-get snapshot :owners)) :bytes) 0))

(defconst drgnx-heap-test--mib (* 1024 1024))

(ert-deftest drgnx-heap/audit ()
  (drgnx-heap-test--with-fixture
    (let ((drgnx-heap-test--origins nil) (drgnx-heap-top 100000) snapshot)   ; every row, not only the largest
      (add-hook 'post-gc-hook #'drgnx-heap-test--note-origin)
      (unwind-protect (setq snapshot (drgnx-heap-audit))
        (remove-hook 'post-gc-hook #'drgnx-heap-test--note-origin))
      ;; one collection of its own, origin audit
      (should (= 1 (cl-count 'audit drgnx-heap-test--origins)))
      (should (numberp (plist-get snapshot :duration-ms)))
      (should (> (plist-get (plist-get snapshot :heap) :live-mb) 0))
      ;; the package's total: 5 MiB of strings and the 1 MiB list (and the undo list)
      (should (> (drgnx-heap-test--owner-bytes snapshot "wdheap") (* 6 drgnx-heap-test--mib)))
      (let ((data (drgnx-heap-test--row snapshot 'variable "wdheap-data")))
        (should (equal (plist-get data :owner) "wdheap"))
        (should (> (plist-get data :bytes) (* 5 drgnx-heap-test--mib))))
      ;; the shared list is counted once: by one of the two variables, the other sees it as counted
      (let ((one (plist-get (drgnx-heap-test--row snapshot 'variable "wdheap-shared") :bytes))
            (two (plist-get (drgnx-heap-test--row snapshot 'variable "wdheap-shared-too") :bytes)))
        (should (>= (max (or one 0) (or two 0)) drgnx-heap-test--mib))
        (should (< (min (or one 0) (or two 0)) 1024)))
      ;; the buffer: its undo list on its own, its text apart from the Lisp heap
      (let ((undo (drgnx-heap-test--row snapshot 'undo "wdheap-undo"))
            (buffer (drgnx-heap-test--row snapshot 'buffer "wdheap-undo")))
        (should (equal (plist-get undo :owner) "wdheap"))
        (should (> (plist-get undo :bytes) (/ drgnx-heap-test--mib 2)))
        (should (< (or (plist-get buffer :bytes) 0) 100000)))
      (should (>= (plist-get (plist-get snapshot :non-heap) :buffer-text-bytes) (* 20000 20))))))

(ert-deftest drgnx-heap/snapshot-has-no-contents ()
  (drgnx-heap-test--with-fixture
    (let* ((snapshot (drgnx-heap-audit))
           (file (plist-get snapshot :file)))
      (should (equal (file-name-directory file) (expand-file-name "drgnx/watchdog/" (getenv "XDG_STATE_HOME"))))
      (should (string-match-p "\\`heap-[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\.json\\'" (file-name-nondirectory file)))
      (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (should (string-search "\"wdheap-data\"" text))   ; names and sizes
        (should-not (string-search "WDHEAP-PRIVATE-TEXT" text))
        (should-not (string-search "xxxxxxxx" text))
        (should (plist-get (json-parse-string text :object-type 'plist) :duration_ms))))))

(ert-deftest drgnx-heap/check-rows ()
  (let ((drgnx-heap-budgets
         '((:owner "total" :measure live :cap 100 :setting gc-cons-threshold :fix "Run Heap Audit")
           (:owner "wdheap" :measure owner :cap 6 :setting wdheap-limit :fix "Lower wdheap-limit")
           (:owner "drgnx" :measure owner :cap 10 :setting drgnx-agents-transcript-turns :fix "Fewer turns")
           (:owner "kill ring" :measure sink :cap nil :setting kill-ring-max :fix "Not set yet")))
        (snapshot `(:heap (:live-mb 150.0)
                          :owners ((:owner "wdheap" :bytes ,(* 5.6 drgnx-heap-test--mib)) (:owner "drgnx" :bytes ,(* 2 drgnx-heap-test--mib)))
                          :sinks ((:sink "kill ring" :bytes 10)))))
    (let ((rows (drgnx-heap-check snapshot)))
      (should (equal (mapcar (lambda (r) (list (plist-get r :owner) (plist-get r :state))) rows)
                     '(("total" over) ("wdheap" near) ("drgnx" under))))     ; a row with no cap is not judged
      (should (equal (plist-get (car rows) :fix) "Run Heap Audit"))
      (should (eq (plist-get (cadr rows) :setting) 'wdheap-limit)))
    ;; from `garbage-collect-heapsize' alone only the total live heap is judged: 2 MiB of conses
    (let ((rows (drgnx-heap-check `((conses 16 ,(/ (* 2 drgnx-heap-test--mib) 16) 0) (symbols 48 0 0)))))
      (should (equal (mapcar (lambda (r) (list (plist-get r :owner) (plist-get r :state))) rows) '(("total" under)))))))

(ert-deftest drgnx-heap/churn-top-callers ()
  ;; a memory profile: the innermost frame that is not a primitive gets the bytes, kept apart from the retainers
  (let ((log (make-hash-table :test #'equal)))
    (puthash (vector 'concat 'drgnx-heap-test--maker 'command-execute nil) 100 log)
    (puthash (vector 'make-string 'drgnx-heap-test--maker nil nil) 50 log)
    (puthash (vector 'cons 'drgnx-heap-test--other nil nil) 30 log)
    (let ((top (drgnx-heap--churn-top log)))
      (should (equal (mapcar (lambda (r) (list (plist-get r :fn) (plist-get r :bytes))) top)
                     '(("drgnx-heap-test--maker" 150) ("drgnx-heap-test--other" 30)))))))

(ert-deftest drgnx-heap/never-prompts-non-interactively ()
  (drgnx-heap-test--with-state
    (let ((asked nil))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest args) (push args asked) t))
                ((symbol-function 'yes-or-no-p) (lambda (&rest args) (push args asked) t)))
        (drgnx-heap-audit)
        (drgnx-heap-audit-command))
      (should-not asked)
      ;; the command showed the view
      (with-current-buffer drgnx-heap-buffer-name
        (should (string-search "By owner" (buffer-string)))
        (should (string-search "Not the Lisp heap" (buffer-string)))))))

(ert-deftest drgnx-heap/command-is-registered ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx--core-commands)
    (let ((cmd (drgnx-commands-get 'heap-audit)))
      (should (equal (drgnx-cmd-title cmd) "Heap Audit"))
      (should (equal (drgnx-cmd-category cmd) "Help"))
      (should (equal (drgnx-cmd-menu cmd) '("Help")))
      (should (eq (drgnx-cmd-command cmd) #'drgnx-heap-audit-command))))
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((text (with-temp-buffer
                  (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir)) (buffer-string))))
      (should (string-search "(heap-audit :none \"Help → Heap Audit\")" text)))))

;;; heap-test.el ends here
