;;; drgnx-perf-settings.el --- perf workloads for the unified settings layer -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The settings layer's timing gates as perf-lab workloads (docs/develop/perf.md, "Settings"): `settings-start' (the
;; read and apply of a 200-entry settings.el), `settings-page' (the page open and a search keystroke over about 5,000
;; settings), `settings-prov' (provenance while a 500-line config.el loads), `settings-open' (a file opens the same
;; with the workspace and language layers in and out) and `settings-sync' (the index `drgnx sync' writes for 200
;; packages).  Each is a measure-only workload: the library below is evaluated in the session, the entry points
;; build the fixture under a temp config, state and cache directory (the session's own are put back afterwards),
;; time the real functions and take the fixture away again.  Sizes are in `drgnx-perf-settings-n'; the unit tests
;; shrink them.
;;
;; "No watcher on a hot variable while typing" is not a timing: `test/unit/settings-watch-test.el' asserts it.

;;; Code:
(require 'cl-lib)

(defconst drgnx-perf-settings--lib
  '(progn
     (require 'cl-lib)
     (require 'subr-x)
     (require 'drgnx-config)
     (require 'drgnx-settings-apply)
     (require 'drgnx-settings-page)
     (require 'drgnx-settings-index)
     (require 'drgnx-settings-prov)
     (require 'drgnx-settings-workspace)
     (require 'drgnx-settings-mode)

     (defvar drgnx-perf-settings-n '((start . 200) (page . 5000) (prov . 500) (sync . 200) (open . 30))
       "How big each fixture is: entries, settings, lines, packages, files.")
     (defvar drgnx-perf-settings--root nil "The fixture's temp directory, with the environment it replaced.")
     (defvar drgnx-perf-settings--vars nil "The fixture's variables, to forget again.")
     (defvar drgnx-perf-settings--sources nil "The fixture packages' (DIR . PACKAGE) pairs.")
     (defvar drgnx-perf-settings--files nil "The files the open workload visits.")

     (defun drgnx-perf-settings--size (key) (cdr (assq key drgnx-perf-settings-n)))
     (defun drgnx-perf-settings--r (x) (/ (round (* x 100)) 100.0))
     (defun drgnx-perf-settings--ms (fn)
       "FN's wall clock in milliseconds, after a collection that is not counted."
       (garbage-collect)
       (let ((t0 (float-time))) (funcall fn) (* 1000 (- (float-time) t0))))
     (defun drgnx-perf-settings--median (xs)
       (let ((s (sort (copy-sequence xs) #'<))) (nth (/ (length s) 2) s)))
     (defun drgnx-perf-settings--write (file text)
       (make-directory (file-name-directory file) t)
       (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil file nil 'silent)))

     (defun drgnx-perf-settings--enter ()
       "Point the config, state and cache directories at a fresh temp directory."
       (let ((dir (file-name-as-directory (make-temp-file "drgnx-perf-settings" t))))
         (setq drgnx-perf-settings--root
               (list dir (getenv "DRGNX_CONFIG_DIR") (getenv "XDG_STATE_HOME") (getenv "XDG_CACHE_HOME")))
         (setenv "DRGNX_CONFIG_DIR" (concat dir "config"))
         (setenv "XDG_STATE_HOME" (concat dir "state"))
         (setenv "XDG_CACHE_HOME" (concat dir "cache"))
         dir))

     (defun drgnx-perf-settings--leave ()
       "Put the environment back and delete the fixture directory."
       (when drgnx-perf-settings--root
         (setenv "DRGNX_CONFIG_DIR" (nth 1 drgnx-perf-settings--root))
         (setenv "XDG_STATE_HOME" (nth 2 drgnx-perf-settings--root))
         (setenv "XDG_CACHE_HOME" (nth 3 drgnx-perf-settings--root))
         (ignore-errors (delete-directory (car drgnx-perf-settings--root) t))
         (setq drgnx-perf-settings--root nil)))

     (defun drgnx-perf-settings--forget ()
       (dolist (v drgnx-perf-settings--vars)
         (ignore-errors (drgnx-settings-teardown v))
         (dolist (p '(standard-value theme-value saved-value custom-type custom-set variable-documentation))
           (put v p nil))
         (makunbound v)
         (unintern (symbol-name v) obarray))
       (setq drgnx-perf-settings--vars nil))

     (defun drgnx-perf-settings--defcustoms (prefix n)
       "N loaded customizable variables named PREFIX-I."
       (dotimes (i n)
         (let ((s (intern (format "%s-%d" prefix i))))
           (set-default s i)
           (put s 'standard-value (list i))
           (put s 'custom-type 'integer)
           (put s 'variable-documentation (format "Fixture setting number %d, a width in columns." i))
           (push s drgnx-perf-settings--vars))))

     ;; settings-start: the 200-entry settings.el, applied
     (defun drgnx-perf-settings-start-setup ()
       (drgnx-perf-settings--enter)
       (let* ((n (drgnx-perf-settings--size 'start)) (half (/ n 2)))
         (drgnx-perf-settings--defcustoms "drgnx-perf-sv" half)
         (dotimes (i (- n half)) (push (intern (format "drgnx-perf-sm-%d" i)) drgnx-perf-settings--vars))
         (drgnx-perf-settings--write
          (drgnx-config-file 'settings)
          (concat "(drgnx-settings\n :version 1\n"
                  (mapconcat (lambda (i) (format " (drgnx-perf-sv-%d %d)\n" i (+ i 100))) (number-sequence 0 (1- half)) "")
                  (mapconcat (lambda (i) (format " (drgnx-perf-sm-%d %S)\n" i (format "value %d" i)))
                             (number-sequence 0 (- n half 1)) "")
                  ")\n"))
         t))

     (defun drgnx-perf-settings-start-each ()
       "A second start's state: one apply done, everything torn down, the session's memory of it gone."
       (drgnx-settings-apply-global)
       (dolist (v drgnx-perf-settings--vars) (ignore-errors (drgnx-settings-teardown v)))
       (setq drgnx-settings-apply--entries nil)
       t)

     (defun drgnx-perf-settings-start-measure ()
       (let (r)
         (let ((ms (drgnx-perf-settings--ms (lambda () (setq r (drgnx-settings-apply-global))))))
           (unless (= (length r) (drgnx-perf-settings--size 'start))
             (error "settings.el applied %d entries, not %d" (length r) (drgnx-perf-settings--size 'start)))
           (list :read_ms (drgnx-perf-settings--r ms)))))

     (defun drgnx-perf-settings-start-teardown ()
       (drgnx-perf-settings--forget)
       (setq drgnx-settings-apply--entries nil)
       (drgnx-perf-settings--leave)
       t)

     ;; settings-page: the page open and a search keystroke
     (defun drgnx-perf-settings-page-setup ()
       (drgnx-perf-settings--enter)
       (drgnx-perf-settings--defcustoms "drgnx-edit-perf" (drgnx-perf-settings--size 'page))
       t)

     (defun drgnx-perf-settings-page-each ()
       (dolist (b (buffer-list)) (when (equal (buffer-name b) "*drgnx settings*") (kill-buffer b)))
       (setq drgnx-settings-page--all nil)
       t)

     (defun drgnx-perf-settings-page-measure ()
       (let* ((open (drgnx-perf-settings--ms (lambda () (pop-to-buffer (drgnx-settings-page)) (redisplay t))))
              ;; the page warms every setting's search text in idle time; here the idle time is spent on it at once
              (warm (progn (drgnx-timer-cancel 'settings-page-warm)
                           (drgnx-perf-settings--ms (lambda () (while (drgnx-settings-page--warm-step))))))
              (rows (with-current-buffer "*drgnx settings*" (length drgnx-settings-page--keys)))
              (query "") keys searches)
         (unless (>= rows (drgnx-perf-settings--size 'page)) (error "the page lists %d settings" rows))
         ;; typing one setting's name: the first key matches every setting, the last one
         (dolist (c (string-to-list (format "perf-%d" (/ (drgnx-perf-settings--size 'page) 2))))
           (setq query (concat query (string c)))
           (let ((search (drgnx-perf-settings--ms
                          (lambda () (with-current-buffer "*drgnx settings*" (drgnx-settings-page-search query)))))
                 (draw (drgnx-perf-settings--ms (lambda () (redisplay t)))))
             (push search searches)
             (push (+ search draw) keys)))
         (list :open_ms (drgnx-perf-settings--r open) :warm_ms (drgnx-perf-settings--r warm)
               :key_search_max_ms (drgnx-perf-settings--r (apply #'max searches))
               :key_p50_ms (drgnx-perf-settings--r (drgnx-perf-settings--median keys))
               :key_max_ms (drgnx-perf-settings--r (apply #'max keys)))))

     (defun drgnx-perf-settings-page-teardown ()
       (dolist (b (buffer-list)) (when (equal (buffer-name b) "*drgnx settings*") (kill-buffer b)))
       (drgnx-perf-settings--forget)
       (setq drgnx-settings-page--all nil)
       (drgnx-perf-settings--leave)
       t)

     ;; settings-prov: provenance while a 500-line config.el loads
     (defun drgnx-perf-settings--prov-reset ()
       (maphash (lambda (v _) (remove-variable-watcher v #'drgnx-settings-prov--watch)) drgnx-settings-prov--watched)
       (clrhash drgnx-settings-prov--watched)
       (clrhash drgnx-settings-prov--records)
       (setq drgnx-settings-prov--user-files nil)
       (dolist (v drgnx-perf-settings--vars) (when (string-prefix-p "drgnx-perf-pm-" (symbol-name v)) (set v 0)))
       (setq drgnx-perf-pv-hook nil))

     (defvar drgnx-perf-pv-hook nil "The hook the fixture's config.el adds its functions to.")

     (defun drgnx-perf-settings-prov-setup ()
       (drgnx-perf-settings--enter)
       ;; N lines: a header, one `load' of a small library of its own per 50 lines (the work a real config.el does besides
       ;; its settings), and 5-line blocks (a function, a managed variable's `setq', an `add-hook')
       (let* ((n (drgnx-perf-settings--size 'prov)) (loads (max 1 (/ n 50))) (blocks (/ (- n 1 loads) 5))
              (file (expand-file-name "config.el" (drgnx-user-dir))))
         (dotimes (k loads)
           (drgnx-perf-settings--write
            (expand-file-name (format "lisp/lib-%d.el" k) (drgnx-user-dir))
            (concat (format ";;; lib-%d.el --- fixture -*- lexical-binding: t -*-\n(defvar drgnx-perf-pl-%d 0)\n" k k)
                    (mapconcat (lambda (j) (format "(defun drgnx-perf-pl-%d-%d (x)\n  \"Add %d to X.\"\n  (+ x %d))\n" k j j j))
                               (number-sequence 0 11) "")
                    (format "(setq drgnx-perf-pl-%d %d)\n" k k))))
         (dotimes (i blocks)
           (let ((s (intern (format "drgnx-perf-pm-%d" i))))
             (defvar-1 s 0)
             (push s drgnx-perf-settings--vars)))
         (drgnx-perf-settings--write
          (drgnx-config-file 'settings)
          (concat "(drgnx-settings\n :version 1\n"
                  (mapconcat (lambda (i) (format " (drgnx-perf-pm-%d %d)\n" i i)) (number-sequence 0 (1- blocks)) "")
                  ")\n"))
         (drgnx-perf-settings--write
          file
          (concat ";;; config.el --- fixture -*- lexical-binding: t -*-\n"
                  (mapconcat
                   (lambda (i)
                     (concat (if (zerop (% i (max 1 (/ blocks loads))))
                                 (format "(load %S nil t t)\n"
                                         (expand-file-name (format "lisp/lib-%d.el" (min (1- loads) (/ i (max 1 (/ blocks loads)))))
                                                           (drgnx-user-dir)))
                               "")
                             (format (concat "(defun drgnx-perf-pf-%d (x)\n  \"Add %d to X.\"\n  (+ x %d))\n"
                                             "(setq drgnx-perf-pm-%d %d)\n(add-hook 'drgnx-perf-pv-hook #'drgnx-perf-pf-%d)\n")
                                     i i i i (+ i 1) i)))
                   (number-sequence 0 (1- blocks)) "")))
         t))

     (defun drgnx-perf-settings-prov-each ()
       (drgnx-perf-settings--prov-reset)
       (when (file-directory-p (drgnx-cache-dir))
         (dolist (f (directory-files (drgnx-cache-dir) t "\\`[^.]")) (ignore-errors (delete-directory f t))))
       t)

     (defun drgnx-perf-settings-prov-measure ()
       (let* ((file (expand-file-name "config.el" (drgnx-user-dir))) plain with first)
         (dotimes (round 9)
           (drgnx-perf-settings--prov-reset)
           (push (drgnx-perf-settings--ms (lambda () (load file nil t t))) plain)
           (drgnx-perf-settings--prov-reset)
           (let ((ms (drgnx-perf-settings--ms (lambda () (drgnx-settings-prov-with-load file (load file nil t t))))))
             (if (= round 0) (setq first ms) (push ms with))))
         (unless (> (hash-table-count drgnx-settings-prov--watched) 0) (error "provenance watched nothing"))
         (let ((a (drgnx-perf-settings--median plain)) (b (drgnx-perf-settings--median with)))
           (list :load_ms (drgnx-perf-settings--r a) :prov_load_ms (drgnx-perf-settings--r b)
                 :prov_pct (drgnx-perf-settings--r (* 100 (/ (- b a) a)))
                 :cold_extra_ms (drgnx-perf-settings--r (- first b))))))

     (defun drgnx-perf-settings-prov-teardown ()
       (drgnx-perf-settings--prov-reset)
       (drgnx-perf-settings--forget)
       (setq drgnx-perf-pv-hook nil)
       (drgnx-perf-settings--leave)
       t)

     ;; settings-sync: the index for 200 packages
     (defun drgnx-perf-settings-sync-setup ()
       (let ((dir (drgnx-perf-settings--enter)) (n (drgnx-perf-settings--size 'sync)))
         (setq drgnx-perf-settings--sources nil)
         (dotimes (p n)
           (let ((pkg (expand-file-name (format "elpa/fixpkg%d-1.%d" p p) dir)))
             (dotimes (f 3)
               (drgnx-perf-settings--write
                (expand-file-name (format "fixpkg%d-%d.el" p f) pkg)
                (concat (format ";;; fixpkg%d-%d.el --- fixture -*- lexical-binding: t -*-\n(require 'subr-x)\n" p f)
                        (format "(defgroup fixpkg%d-%d nil \"The fixture.\" :group 'tools)\n" p f)
                        (mapconcat
                         (lambda (i)
                           (format (concat "(defcustom fixpkg%d-%d-opt-%d %d\n  \"Option %d, a width.\n\nMore text about it.\"\n"
                                           "  :type 'integer :group 'fixpkg%d-%d :safe #'integerp)\n"
                                           "(defun fixpkg%d-%d-fn-%d (x)\n  \"Add one to X.\"\n  (let ((y x))\n    (when (> y 1)\n"
                                           "      (setq y (1+ y)))\n    (+ y 1)))\n")
                                   p f i i i p f p f i))
                         (number-sequence 0 14) ""))))
             (drgnx-perf-settings--write (expand-file-name (format "fixpkg%d-autoloads.el" p) pkg)
                                         "(defcustom skipped 1 \"Skipped.\" :type 'integer)\n")
             (push (cons pkg (format "fixpkg%d" p)) drgnx-perf-settings--sources)))
         t))

     (defun drgnx-perf-settings-sync-measure ()
       (let* ((file (expand-file-name "settings-index.eld" (drgnx-perf-settings--root-dir))) (entries 0)
              (ms (drgnx-perf-settings--ms
                   (lambda () (setq entries (drgnx-settings-index-build drgnx-perf-settings--sources file))))))
         (unless (= entries (* (drgnx-perf-settings--size 'sync) 3 16)) (error "the index holds %d entries" entries))
         (list :index_ms (drgnx-perf-settings--r ms))))

     (defun drgnx-perf-settings--root-dir () (car drgnx-perf-settings--root))

     (defun drgnx-perf-settings-sync-teardown ()
       (setq drgnx-perf-settings--sources nil drgnx-settings-index--cache nil)
       (drgnx-perf-settings--leave)
       t)

     ;; settings-open: a file opens the same with the workspace and language layers in and out
     (defun drgnx-perf-settings--layers (on)
       "Put the workspace layers (W1, W2) and the language layer (L1) in, or take them out."
       (if on
           (progn (drgnx-settings-workspace-enable)
                  (add-hook 'change-major-mode-after-body-hook #'drgnx-settings-mode--apply-mode-overrides))
         (drgnx-settings-workspace-disable)
         (remove-hook 'change-major-mode-after-body-hook #'drgnx-settings-mode--apply-mode-overrides)))

     (defun drgnx-perf-settings-open-setup ()
       (let* ((dir (drgnx-perf-settings--enter)) (project (file-truename (expand-file-name "project/" dir))) (n (drgnx-perf-settings--size 'open)))
         (make-directory (expand-file-name ".git" project) t)
         (setq drgnx-perf-settings--files nil)
         (dotimes (i n)
           (let ((f (expand-file-name (if (< i (/ n 3)) (format "src/f%d.txt" i) (format "src/f%d.el" i)) project)))
             (drgnx-perf-settings--write f "(defun f () nil)\nhello\n")
             (push f drgnx-perf-settings--files)))
         (drgnx-perf-settings--write
          (expand-file-name ".drgnx/settings.el" project)
          "(drgnx-workspace-settings\n :version 1\n (tab-width 3))\n")
         (drgnx-perf-settings--write
          (expand-file-name "workspaces/perf.el" (drgnx-user-dir))
          (format "(drgnx-workspace-settings\n :version 1\n :roots (%S)\n (fill-column 91))\n" project))
         (drgnx-perf-settings--write
          (drgnx-config-file 'settings)
          "(drgnx-settings\n :version 1\n (:mode emacs-lisp-mode (comment-column 40)))\n")
         (clrhash drgnx-settings-workspace--docs)
         (setq drgnx-settings-mode--cache nil)
         t))

     (defun drgnx-perf-settings--open-all (on)
       "The milliseconds each fixture file takes to open with the layers ON (a list), checked to have applied (or not)."
       (drgnx-perf-settings--layers on)
       (let (times)
         (dolist (f drgnx-perf-settings--files)
           (let (b)
             (push (drgnx-perf-settings--ms (lambda () (setq b (find-file-noselect f)))) times)
             (with-current-buffer b
               (unless (eq on (and (eql fill-column 91) (or (not (derived-mode-p 'emacs-lisp-mode)) (eql comment-column 40))))
                 (error "the layers were %s but %s opened with fill-column %s" (if on "on" "off") (file-name-nondirectory f) fill-column)))
             (let ((kill-buffer-query-functions nil)) (kill-buffer b))))
         times))

     (defun drgnx-perf-settings-open-measure ()
       (let (on off)
         (unwind-protect
             (progn
               (drgnx-perf-settings--open-all t) (drgnx-perf-settings--open-all nil)   ; both read their files once
               (dotimes (_ 8)
                 (push (drgnx-perf-settings--median (drgnx-perf-settings--open-all t)) on)
                 (push (drgnx-perf-settings--median (drgnx-perf-settings--open-all nil)) off)))
           (drgnx-perf-settings--layers t))
         (let ((a (drgnx-perf-settings--median on)) (b (drgnx-perf-settings--median off)))
           (list :open_on_ms (drgnx-perf-settings--r a) :open_off_ms (drgnx-perf-settings--r b)
                 :delta_ms (drgnx-perf-settings--r (- a b))))))

     (defun drgnx-perf-settings-open-teardown ()
       (drgnx-perf-settings--layers t)
       (dolist (f drgnx-perf-settings--files)
         (when-let* ((b (find-buffer-visiting f))) (let ((kill-buffer-query-functions nil)) (kill-buffer b))))
       (clrhash drgnx-settings-workspace--docs)
       (setq drgnx-settings-mode--cache nil drgnx-perf-settings--files nil)
       (drgnx-perf-settings--leave)
       t))
  "The library the workloads evaluate in the session (quoted code), with one `-setup', `-each', `-measure' and
`-teardown' function per workload.")

(defun drgnx-perf-settings--form (&rest calls)
  "A form for the session: the library, then CALLS (symbols, called with no arguments), as text."
  (prin1-to-string `(progn ,drgnx-perf-settings--lib ,@(mapcar #'list calls) t)))

(defun drgnx-perf-settings--measure-form (name)
  "The form of workload NAME's measure: its `-measure' function's plist."
  (prin1-to-string `(progn ,drgnx-perf-settings--lib (,(intern (format "drgnx-perf-settings-%s-measure" name))))))

(defun drgnx-perf-settings-workloads ()
  "The settings workloads, in the shape of `drgnx-perf-run--workloads'."
  (mapcar
   (lambda (name)
     (let ((fn (lambda (what) (intern (format "drgnx-perf-settings-%s-%s" name what)))))
       (append (list (intern (format "settings-%s" name))
                     :setup (drgnx-perf-settings--form (funcall fn "setup"))
                     :measure (drgnx-perf-settings--measure-form name)
                     :teardown (drgnx-perf-settings--form (funcall fn "teardown")))
               (when (memq name '(start page prov))
                 (list :each (drgnx-perf-settings--form (funcall fn "each")))))))
   '(start page prov sync open)))

(provide 'drgnx-perf-settings)
;;; drgnx-perf-settings.el ends here
