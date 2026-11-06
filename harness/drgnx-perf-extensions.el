;;; drgnx-perf-extensions.el --- perf workloads for the Extensions view -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Extensions view's timing rows as perf-lab workloads (docs/develop/perf.md, "Extensions"): `extensions-open',
;; `extensions-search', `extensions-scroll', `extensions-details', `extensions-progress', `activate-live',
;; `install-overhead', `refresh-job' and `list-packages-compare'.  Each is a measure-only workload in the form of
;; drgnx-perf-settings.el: the library below is evaluated in the session, the entry points build the fixture under temp
;; data, config, state and cache directories (the session's own are put back afterwards), time the real functions and
;; take the fixture away again.
;;
;; The hub is a stub that answers from memory (`drgnx-perf-extensions--hub'): these rows time the editor's side (draw,
;; query, scroll, job reads, repointing); the hub's own search and catalog load are the Rust bench
;; (runtime/crates/drgnx-ratatoskr/benches/extensions.rs).  The four archives are local directories of
;; `archive-contents' at their 2026-11-06 sizes, written by `drgnx-perf-extensions-write-archives' (no network, no
;; package files: the catalog refresh and package.el read the contents only).  Sizes are in `drgnx-perf-extensions-n';
;; the unit tests shrink them.

;;; Code:
(require 'cl-lib)

(defconst drgnx-perf-extensions--lib
  '(progn
     (require 'cl-lib)
     (require 'subr-x)

     (defvar drgnx-perf-extensions-n
       '((gnu . 420) (nongnu . 480) (melpa . 5500) (melpa-stable . 750)
         (installed . 120) (updates . 15) (builtin . 60) (plugins . 5) (progress . 1.0) (live . 40) (scroll . 20))
       "How big each fixture is: packages per archive, rows per section, seconds of progress, repointed packages, scrolls.")
     (defvar drgnx-perf-extensions--root nil "The fixture's temp directory, with the environment it replaced.")
     (defvar drgnx-perf-extensions--pool nil "Vector of every archive package's row plist (state available).")
     (defvar drgnx-perf-extensions--sections nil "Alist SECTION → the rows the stub answers for it.")
     (defvar drgnx-perf-extensions--answers nil "Hash: query → (ROWS . TOTAL), made on first use.")
     (defvar drgnx-perf-extensions--procs 0 "Processes started since `drgnx-perf-extensions--count-start'.")
     (defvar drgnx-perf-extensions--saved nil "Variables and advice the fixture changed, to put back.")

     (defconst drgnx-perf-extensions--words
       ["magit" "org" "evil" "lsp" "dash" "helm" "ivy" "company" "flycheck" "projectile" "git" "rust" "go" "python"
        "docker" "yaml" "json" "web" "mode" "theme" "snippets" "tree" "sitter" "vterm"]
       "Words the fixture names are made of.")

     (defun drgnx-perf-extensions--size (key) (cdr (assq key drgnx-perf-extensions-n)))
     (defun drgnx-perf-extensions--r (x) (/ (round (* x 100)) 100.0))
     (defun drgnx-perf-extensions--ms (fn)
       "FN's wall clock in milliseconds, after a collection that is not counted."
       (garbage-collect)
       (let ((t0 (float-time))) (funcall fn) (* 1000 (- (float-time) t0))))
     (defun drgnx-perf-extensions--pct (xs p)
       (let* ((s (sort (copy-sequence xs) #'<)) (i (min (1- (length s)) (floor (* p (length s))))))
         (nth i s)))
     (defun drgnx-perf-extensions--write (file text)
       (make-directory (file-name-directory file) t)
       (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil file nil 'silent)))

     ;; the environment
     (defun drgnx-perf-extensions--enter ()
       "Point the data, config, state and cache directories at a fresh temp directory; its name.  A second call while
one is in force returns it (the comparison's setup calls the common one inside its own)."
       (if drgnx-perf-extensions--root
           (car drgnx-perf-extensions--root)
         (let ((dir (file-name-as-directory (make-temp-file "drgnx-perf-extensions" t))) (vars '("DRGNX_DATA_DIR" "DRGNX_CONFIG_DIR" "XDG_STATE_HOME" "XDG_CACHE_HOME")))
           (setq drgnx-perf-extensions--root (cons dir (mapcar #'getenv vars)))
           (setenv "DRGNX_DATA_DIR" (concat dir "data"))
           (setenv "DRGNX_CONFIG_DIR" (concat dir "config"))
           (setenv "XDG_STATE_HOME" (concat dir "state"))
           (setenv "XDG_CACHE_HOME" (concat dir "cache"))
           dir)))

     (defun drgnx-perf-extensions--leave ()
       "Put the environment back and delete the fixture directory."
       (when drgnx-perf-extensions--root
         (cl-mapc #'setenv '("DRGNX_DATA_DIR" "DRGNX_CONFIG_DIR" "XDG_STATE_HOME" "XDG_CACHE_HOME") (cdr drgnx-perf-extensions--root))
         (ignore-errors (delete-directory (car drgnx-perf-extensions--root) t))
         (setq drgnx-perf-extensions--root nil)))

     (defun drgnx-perf-extensions--load (&rest names)
       "Load the Extensions modules NAMES (\"list\", \"details\"…) from this checkout."
       (dolist (n names)
         (load (expand-file-name (concat "modules/tools/drgnx-extensions" (if (string-empty-p n) "" "-") n) drgnx-dir) nil t)))

     ;; the fixture's packages: the same names in the archives' contents and in the hub's rows
     (defun drgnx-perf-extensions--name (archive-index i)
       (let ((w drgnx-perf-extensions--words))
         (format "%s-%s-%c%d" (aref w (% (* i 7) (length w))) (aref w (% (+ (* i 13) archive-index) (length w)))
                 (+ ?a archive-index) i)))

     (defun drgnx-perf-extensions--archives ()
       "((ARCHIVE . COUNT)…) in the order gnu, nongnu, melpa, melpa-stable."
       (mapcar (lambda (a) (cons a (drgnx-perf-extensions--size a))) '(gnu nongnu melpa melpa-stable)))

     (defun drgnx-perf-extensions--entries (archive-index count)
       "The archive-contents entries of archive ARCHIVE-INDEX: (NAME . [VERSION REQS SUMMARY KIND EXTRAS])."
       (let (out)
         (dotimes (i count)
           (push (cons (intern (drgnx-perf-extensions--name archive-index i))
                       (vector (list 1 (% i 9)) (if (= 0 (% i 5)) '((emacs (29 1))) nil)
                               (format "Fixture package %d of archive %d, a %s helper" i archive-index
                                       (aref drgnx-perf-extensions--words (% i (length drgnx-perf-extensions--words))))
                               (if (= 0 (% i 3)) 'single 'tar)
                               (list (cons :keywords (list "tools" (aref drgnx-perf-extensions--words (% (* i 5) (length drgnx-perf-extensions--words)))))
                                     (cons :url "https://example.invalid/pkg"))))
                 out))
         (nreverse out)))

     (defun drgnx-perf-extensions-write-archives (dir)
       "Write the four archives as local directories under DIR (each an `archive-contents' file): ((NAME . DIRECTORY)…)."
       (let ((i -1))
         (mapcar (lambda (a)
                   (cl-incf i)
                   (let ((d (file-name-as-directory (expand-file-name (symbol-name (car a)) dir))))
                     (make-directory d t)
                     (with-temp-file (expand-file-name "archive-contents" d)
                       (let ((print-length nil) (print-level nil))
                         (prin1 (cons 1 (drgnx-perf-extensions--entries i (cdr a))) (current-buffer))))
                     (cons (symbol-name (car a)) d)))
                 (drgnx-perf-extensions--archives))))

     (defun drgnx-perf-extensions--row (name source state &optional downloads)
       (list :id (concat "pkg:" name) :kind "package" :name name :summary (format "%s helper for Emacs" name) :state state
             :source source :signed "unsigned-archive" :version "1.0" :latest (and (equal state "update") "1.1")
             :downloads (or downloads 100) :why nil))

     (defun drgnx-perf-extensions--build ()
       "The pool of archive rows and the stub's sections, from `drgnx-perf-extensions-n'."
       (let ((i -1) pool)
         (dolist (a (drgnx-perf-extensions--archives))
           (cl-incf i)
           (dotimes (j (cdr a))
             (push (drgnx-perf-extensions--row (drgnx-perf-extensions--name i j) (symbol-name (car a)) "available" (* 3 j)) pool)))
         (setq drgnx-perf-extensions--pool (vconcat (nreverse pool))
               drgnx-perf-extensions--answers (make-hash-table :test 'equal)
               drgnx-perf-extensions--sections
               (let ((mk (lambda (state prefix n)
                           (let (rows) (dotimes (k n) (push (drgnx-perf-extensions--row (format "%s-%d" prefix k) "melpa" state k) rows))
                                (nreverse rows)))))
                 (list (cons 'installed (funcall mk "installed" "perf-installed" (drgnx-perf-extensions--size 'installed)))
                       (cons 'updates (funcall mk "update" "perf-update" (drgnx-perf-extensions--size 'updates)))
                       (cons 'builtin (funcall mk "builtin" "perf-builtin" (drgnx-perf-extensions--size 'builtin)))
                       (cons 'plugins (funcall mk "enabled" "perf-plugin" (drgnx-perf-extensions--size 'plugins))))))))

     (defun drgnx-perf-extensions--answer (query)
       "(ROWS . TOTAL) for the typed QUERY: the first 200 pool rows whose name has it, kept once made."
       (or (gethash query drgnx-perf-extensions--answers)
           (puthash query
                    (let ((hits nil) (total 0))
                      (mapc (lambda (r)
                              (when (string-search query (plist-get r :name))
                                (cl-incf total) (when (< total 201) (push r hits))))
                            drgnx-perf-extensions--pool)
                      (cons (nreverse hits) total))
                    drgnx-perf-extensions--answers)))

     (defun drgnx-perf-extensions--hub (method params callback &rest _)
       "Stands for `drgnx-hub-call': answers from memory at once (the draw is what these rows time)."
       (pcase method
         ("extensions/search"
          (let* ((f (plist-get params :filters))
                 (section (cond ((plist-get f :installed) 'installed) ((plist-get f :updates) 'updates)
                                ((plist-get f :plugins) 'plugins) ((plist-get f :builtin) 'builtin)))
                 (answer (cond (section (let ((rows (cdr (assq section drgnx-perf-extensions--sections)))) (cons rows (length rows))))
                               ((plist-get f :ids) (cons nil 0))
                               (t (drgnx-perf-extensions--answer (downcase (or (plist-get params :query) ""))))))
                 (off (or (plist-get params :offset) 0)))
            (funcall callback (list :rows (vconcat (seq-take (nthcdr off (car answer)) 200)) :total (cdr answer)) nil)))
         ("extensions/details"
          (let ((id (plist-get params :id)))
            (funcall callback
                     (list :row (drgnx-perf-extensions--row (substring id 4) "melpa" "installed")
                           :readme (mapconcat (lambda (n) (format "Line %d of the readme, with a few words in it." n)) (number-sequence 1 60) "\n")
                           :requires nil :required-by nil :maintainer "A. Maintainer" :url "https://example.invalid/pkg"
                           :commit "9be04d7aa" :revdesc "1.0-1-g9be04d7")
                     nil)))
         (_ (funcall callback nil "the perf stub does not answer that"))))

     ;; the stub, the process counter, the settings the workloads must not trigger
     (defun drgnx-perf-extensions--count-start () (setq drgnx-perf-extensions--procs 0))
     (defun drgnx-perf-extensions--count (&rest _) (cl-incf drgnx-perf-extensions--procs))
     (defun drgnx-perf-extensions--install-stub ()
       (require 'drgnx-hub-client)
       (advice-add 'drgnx-hub-call :override #'drgnx-perf-extensions--hub)
       (dolist (f '(make-process call-process start-process)) (advice-add f :before #'drgnx-perf-extensions--count))
       (setq drgnx-perf-extensions--saved (list (bound-and-true-p drgnx-extensions-check-updates)))
       (setq drgnx-extensions-check-updates 'manual))
     (defun drgnx-perf-extensions--remove-stub ()
       (advice-remove 'drgnx-hub-call #'drgnx-perf-extensions--hub)
       (dolist (f '(make-process call-process start-process)) (advice-remove f #'drgnx-perf-extensions--count))
       (when drgnx-perf-extensions--saved (setq drgnx-extensions-check-updates (car drgnx-perf-extensions--saved)))
       (setq drgnx-perf-extensions--saved nil))

     (defun drgnx-perf-extensions--kill-pages ()
       (dolist (b (buffer-list))
         (when (or (equal (buffer-name b) "*Extensions*")
                   (ignore-errors (buffer-local-value 'drgnx-extensions-details--id b)))
           (let ((kill-buffer-query-functions nil)) (kill-buffer b)))))

     (defun drgnx-perf-extensions--common-setup (&rest modules)
       (drgnx-perf-extensions--enter)
       (apply #'drgnx-perf-extensions--load "list" "" modules)
       (drgnx-perf-extensions--build)
       (drgnx-perf-extensions--install-stub)
       t)

     (defun drgnx-perf-extensions--common-each ()
       (drgnx-perf-extensions--kill-pages)
       (drgnx-extensions-list--reset)
       t)

     (defun drgnx-perf-extensions--common-teardown ()
       (drgnx-perf-extensions--kill-pages)
       (when (fboundp 'drgnx-extensions-list--teardown) (drgnx-extensions-list--teardown))
       (when (fboundp 'drgnx-view--undefine) (ignore-errors (drgnx-view--undefine 'extensions)))
       (drgnx-perf-extensions--remove-stub)
       (setq drgnx-perf-extensions--pool nil drgnx-perf-extensions--sections nil drgnx-perf-extensions--answers nil)
       (drgnx-perf-extensions--leave)
       t)

     ;; the view's measures, shared by the rows and by the comparison
     (defun drgnx-perf-extensions--open-ms ()
       "Open the list and draw it: (MS . PROCESSES)."
       (drgnx-perf-extensions--count-start)
       (let ((ms (drgnx-perf-extensions--ms (lambda () (drgnx-extensions-open) (redisplay t)))))
         (cons ms drgnx-perf-extensions--procs)))

     (defun drgnx-perf-extensions--type-ms (word)
       "The milliseconds of each key of WORD typed into the search, the result drawn: a list."
       (let (times)
         (dotimes (k (length word))
           (let ((text (substring word 0 (1+ k))))
             (push (drgnx-perf-extensions--ms (lambda () (drgnx-extensions-list--apply-query text) (redisplay t))) times)))
         (nreverse times)))

     (defun drgnx-perf-extensions--scroll-ms (n)
       "Scroll the list N pages down and N up, each drawn, with its post-command work: the milliseconds of each."
       (let ((buf (get-buffer drgnx-extensions-list-buffer-name)) times)
         (with-current-buffer buf (goto-char (point-min)))
         (dotimes (i (* 2 n))
           (push (drgnx-perf-extensions--ms
                  (lambda ()
                    (with-current-buffer buf
                      (condition-case nil (if (< i n) (scroll-up-command) (scroll-down-command)) (error nil))
                      (run-hooks 'post-command-hook))
                    (redisplay t)))
                 times))
         (nreverse times)))

     ;; extensions-open
     (defun drgnx-perf-extensions-open-setup () (drgnx-perf-extensions--common-setup))
     (defun drgnx-perf-extensions-open-each () (drgnx-perf-extensions--common-each))
     (defun drgnx-perf-extensions-open-measure ()
       (let ((r (drgnx-perf-extensions--open-ms)))
         (unless (> (hash-table-count drgnx-extensions-list--rows) 0) (error "the list opened with no rows"))
         (list :open_ms (drgnx-perf-extensions--r (car r)) :processes (cdr r)
               :rows (hash-table-count drgnx-extensions-list--rows))))
     (defun drgnx-perf-extensions-open-teardown () (drgnx-perf-extensions--common-teardown))

     ;; extensions-search: "magit-todos" typed a key at a time over the 7,150 rows (the hub's ranking is the Rust bench's)
     (defvar drgnx-perf-extensions--word "dash-helm" "What the search rows type.")
     (defun drgnx-perf-extensions-search-setup ()
       (drgnx-perf-extensions--common-setup)
       (dotimes (k (length drgnx-perf-extensions--word))   ; the stub's answers are made before the timing
         (drgnx-perf-extensions--answer (substring drgnx-perf-extensions--word 0 (1+ k))))
       t)
     (defun drgnx-perf-extensions-search-each () (drgnx-perf-extensions--common-each))
     (defun drgnx-perf-extensions-search-measure ()
       (drgnx-perf-extensions--open-ms)
       (let ((times (drgnx-perf-extensions--type-ms drgnx-perf-extensions--word)))
         (list :key_p50_ms (drgnx-perf-extensions--r (drgnx-perf-extensions--pct times 0.5))
               :key_max_ms (drgnx-perf-extensions--r (apply #'max times)) :keys (length times))))
     (defun drgnx-perf-extensions-search-teardown () (drgnx-perf-extensions--common-teardown))

     ;; extensions-scroll: 200 rows, pages down and up
     (defun drgnx-perf-extensions-scroll-setup ()
       (drgnx-perf-extensions--common-setup)
       (drgnx-perf-extensions--answer "e")
       t)
     (defun drgnx-perf-extensions-scroll-each () (drgnx-perf-extensions--common-each))
     (defun drgnx-perf-extensions-scroll-measure ()
       (drgnx-perf-extensions--open-ms)
       (drgnx-extensions-list--apply-query "e") (redisplay t)
       (let ((times (drgnx-perf-extensions--scroll-ms (drgnx-perf-extensions--size 'scroll))))
         (list :key_p50_ms (drgnx-perf-extensions--r (drgnx-perf-extensions--pct times 0.5))
               :key_max_ms (drgnx-perf-extensions--r (apply #'max times)) :keys (length times))))
     (defun drgnx-perf-extensions-scroll-teardown () (drgnx-perf-extensions--common-teardown))

     ;; extensions-details: the page of an installed package, five of them, opened and drawn
     (defun drgnx-perf-extensions-details-setup () (drgnx-perf-extensions--common-setup "details"))
     (defun drgnx-perf-extensions-details-each () (drgnx-perf-extensions--common-each))
     (defun drgnx-perf-extensions-details-measure ()
       (let (times)
         (dotimes (k 5)
           (push (drgnx-perf-extensions--ms
                  (lambda () (pop-to-buffer (drgnx-extensions-details-open (format "pkg:perf-installed-%d" k) t)) (redisplay t)))
                 times))
         (list :open_ms (drgnx-perf-extensions--r (drgnx-perf-extensions--pct times 0.5))
               :open_max_ms (drgnx-perf-extensions--r (apply #'max times)))))
     (defun drgnx-perf-extensions-details-teardown () (drgnx-perf-extensions--common-teardown))

     ;; extensions-progress: a job writes steps, the layer reads them at most four times a second (no two reads closer
     ;; than the throttle's gap), the last write is always read, and typing goes on
     (defvar drgnx-perf-extensions--reads nil "When the progress directory was read, newest first.")
     (defun drgnx-perf-extensions--count-read (&rest _) (push (float-time) drgnx-perf-extensions--reads))
     (defun drgnx-perf-extensions-progress-setup ()
       (drgnx-perf-extensions--common-setup "jobs")
       (make-directory (drgnx-extensions-jobs-dir) t)
       (setq drgnx-extensions-jobs--on t)
       (puthash "perf-job" (list :token "perf-job" :kind 'upgrade :status 'running :since (float-time)
                                 :ids '(perf-installed-0 perf-installed-1 perf-installed-2) :id "perf-job")
                drgnx-extensions-jobs--jobs)
       (advice-add 'drgnx-extensions-jobs--read :before #'drgnx-perf-extensions--count-read)
       t)
     (defun drgnx-perf-extensions-progress-each () (drgnx-perf-extensions--common-each))
     (defun drgnx-perf-extensions--progress-run (storm)
       "A second or so of keys in a scratch buffer, each drawn; with STORM a progress file written and announced (the
event names it) before each, then a wait for the read after the last write: (TIMES . LAST-I), LAST-I the last step
written, or nil."
       (setq drgnx-perf-extensions--reads nil)
       (let* ((seconds (drgnx-perf-extensions--size 'progress)) (file (drgnx-extensions-jobs--file "perf-job"))
              (t0 (float-time)) (i 0) times (buf (get-buffer-create " *perf progress*")))
         (with-current-buffer buf (erase-buffer))
         (switch-to-buffer buf)
         (while (< (- (float-time) t0) seconds)
           (cl-incf i)
           (when storm
             (drgnx-perf-extensions--write file (format "{\"step\":\"native\",\"pkg\":\"perf-installed-0\",\"i\":%d,\"n\":400}" i))
             (drgnx-extensions-jobs--notify (list 'perf-watch 'changed file)))
           (push (drgnx-perf-extensions--ms (lambda () (with-current-buffer buf (insert "x")) (redisplay t))) times)
           (sit-for 0.01))
         (when storm                            ; the throttle's trailing read, at most 0.25 s after the last
           (let ((end (+ (float-time) 1.0)))
             (while (and (drgnx-timer-active-p 'extensions-jobs-read) (< (float-time) end)) (sit-for 0.02))))
         (kill-buffer buf)
         (cons times (and storm i))))
     (defun drgnx-perf-extensions--gaps ()
       "The gaps between the recorded reads, in milliseconds."
       (let ((ts drgnx-perf-extensions--reads) gaps)
         (while (cdr ts) (push (* 1000 (- (car ts) (cadr ts))) gaps) (setq ts (cdr ts)))
         gaps))
     (defun drgnx-perf-extensions-progress-measure ()
       (drgnx-perf-extensions--open-ms)
       (let* ((quiet (drgnx-perf-extensions--progress-run nil))
              (storm (drgnx-perf-extensions--progress-run t))
              (gaps (drgnx-perf-extensions--gaps))
              (seen (plist-get (gethash "perf-job" drgnx-extensions-jobs--jobs) :i))
              (p0 (drgnx-perf-extensions--pct (car quiet) 0.95)) (p1 (drgnx-perf-extensions--pct (car storm) 0.95)))
         (list :reads (length drgnx-perf-extensions--reads)
               :read_gap_min_ms (drgnx-perf-extensions--r (if gaps (apply #'min gaps) 0))
               :reads_too_close (seq-count (lambda (g) (< g 240)) gaps)
               :last_unread (if (eql seen (cdr storm)) 0 1)
               :typing_p95_ms (drgnx-perf-extensions--r p1)
               :typing_p95_idle_ms (drgnx-perf-extensions--r p0) :typing_delta_ms (drgnx-perf-extensions--r (- p1 p0)))))
     (defun drgnx-perf-extensions-progress-teardown ()
       (advice-remove 'drgnx-extensions-jobs--read #'drgnx-perf-extensions--count-read)
       (drgnx-timer-cancel 'extensions-jobs-read)
       (setq drgnx-extensions-jobs--on nil)
       (clrhash drgnx-extensions-jobs--jobs) (clrhash drgnx-extensions-jobs--state)
       (drgnx-perf-extensions--common-teardown))

     ;; activate-live: the job's plan repoints the running session into the generation that holds the copies
     (defvar drgnx-perf-extensions--load-path nil "The session's `load-path' before the fixture's entries.")
     (defvar drgnx-perf-extensions--live-dirs nil "The fixture's package directory names.")
     (defun drgnx-perf-extensions--live-paths ()
       (mapcar (lambda (d) (directory-file-name (expand-file-name d (drgnx-elpa-dir)))) drgnx-perf-extensions--live-dirs))
     (defun drgnx-perf-extensions-activate-setup ()
       (drgnx-perf-extensions--enter)
       (drgnx-perf-extensions--load "live")
       (require 'drgnx-pkg)
       (setq drgnx-perf-extensions--load-path load-path drgnx-perf-extensions--live-dirs nil)
       (dotimes (i (drgnx-perf-extensions--size 'live))
         (let ((d (format "perf%c-%d.0" (+ ?a (% i 20)) (+ 1 (/ i 20)))))
           (push d drgnx-perf-extensions--live-dirs)
           (make-directory (expand-file-name d (drgnx-elpa-dir)) t)
           (make-directory (expand-file-name d (concat (drgnx-extensions-live--gen-elpa 1))) t)))
       (make-directory (drgnx-pkg-in-use-dir) t)
       t)
     (defun drgnx-perf-extensions-activate-each ()
       "The session as before the swap: every fixture directory in `load-path' at elpa/, none in the generation."
       (setq load-path (append (drgnx-perf-extensions--live-paths) drgnx-perf-extensions--load-path))
       t)
     (defun drgnx-perf-extensions-activate-measure ()
       (let* ((plan (list :generation 1 :replaces (vconcat drgnx-perf-extensions--live-dirs)))
              (ms (drgnx-perf-extensions--ms (lambda () (drgnx-extensions-live-plan plan))))
              (moved (cl-count-if (lambda (e) (and (stringp e) (string-prefix-p (drgnx-extensions-live--gens) (expand-file-name e)))) load-path)))
         (unless (= moved (length drgnx-perf-extensions--live-dirs)) (error "%d of %d directories were repointed" moved (length drgnx-perf-extensions--live-dirs)))
         (list :activate_ms (drgnx-perf-extensions--r ms) :packages moved)))
     (defun drgnx-perf-extensions-activate-teardown ()
       (setq load-path drgnx-perf-extensions--load-path drgnx-perf-extensions--live-dirs nil
             drgnx-extensions-live--moved nil drgnx-extensions-live--restart nil drgnx-extensions-live--marked nil)
       (ignore-errors (delete-file (drgnx-extensions-live--in-use-file)))
       (drgnx-perf-extensions--leave)
       t)

     ;; activate-live-new: what the budget names, a package installed while the session runs: the job layer's end of
     ;; a sync that added one package, the session holding the fixture's packages (activated, nothing loaded)
     (defvar drgnx-perf-extensions--activated nil "`package-activated-list' before the fixture.")
     (defun drgnx-perf-extensions-activate-new-setup ()
       (drgnx-perf-extensions-activate-setup)
       (setq drgnx-perf-extensions--activated package-activated-list)
       (dolist (d drgnx-perf-extensions--live-dirs)
         (let ((name (car (drgnx-pkg--dir-package d))))
           (drgnx-perf-extensions--write (expand-file-name (format "%s/%s-pkg.el" d name) (drgnx-elpa-dir))
                                         (format "(define-package %S \"1.0\" \"fixture\" nil)\n" name))))
       (let ((dir (expand-file-name "perfnew-1.0" (drgnx-elpa-dir))))
         (drgnx-perf-extensions--write (expand-file-name "perfnew-pkg.el" dir) "(define-package \"perfnew\" \"1.0\" \"new\" nil)\n")
         (drgnx-perf-extensions--write (expand-file-name "perfnew-autoloads.el" dir)
                                       "(defun drgnx-perf-extensions-perfnew () 'perfnew)\n"))
       t)
     (defun drgnx-perf-extensions-activate-new-each ()
       (drgnx-perf-extensions-activate-each)
       (setq package-activated-list (append (mapcar (lambda (d) (intern (car (drgnx-pkg--dir-package d))))
                                                    drgnx-perf-extensions--live-dirs)
                                            drgnx-perf-extensions--activated))
       (when (fboundp 'drgnx-perf-extensions-perfnew) (fmakunbound 'drgnx-perf-extensions-perfnew))
       t)
     (defun drgnx-perf-extensions-activate-new-measure ()
       (let ((ms (drgnx-perf-extensions--ms (lambda () (drgnx-extensions-live-after '(:status done :kind sync))))))
         (unless (memq 'perfnew package-activated-list) (error "perfnew was not activated: %S" drgnx-extensions-live--restart))
         (list :activate_ms (drgnx-perf-extensions--r ms) :activated (if (fboundp 'drgnx-perf-extensions-perfnew) 1 0))))
     (defun drgnx-perf-extensions-activate-new-teardown ()
       (setq package-activated-list drgnx-perf-extensions--activated drgnx-perf-extensions--activated nil)
       (when (fboundp 'drgnx-perf-extensions-perfnew) (fmakunbound 'drgnx-perf-extensions-perfnew))
       (drgnx-perf-extensions-activate-teardown))

     ;; refresh-job: the catalog written from the four full archives by a batch Emacs, as the job runs it
     (defun drgnx-perf-extensions-refresh-setup ()
       (let ((dir (drgnx-perf-extensions--enter)))
         (let ((archives (drgnx-perf-extensions-write-archives (concat dir "archives"))))
           (drgnx-perf-extensions--write
            (concat dir "config/packages.eld")
            (prin1-to-string (list :archives archives :archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa-stable" . 1) ("melpa" . 0))))))
         t))
     (defun drgnx-perf-extensions-refresh-measure ()
       (let* ((file (expand-file-name "drgnx/extensions/catalog.json" (getenv "XDG_CACHE_HOME")))
              (r (drgnx-perf-extensions--run
                  (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "-L" (expand-file-name "core" drgnx-dir)
                        "-l" "drgnx-pkg" "-l" "drgnx-extensions-refresh" "--eval"
                        "(kill-emacs (drgnx-extensions-refresh-cli-run '(\"refresh\")))")
                  (list (concat "HOME=" (car drgnx-perf-extensions--root))))))
         (unless (eql (cadr r) 0) (error "the refresh failed (%S): %s" (cadr r) (nth 2 r)))
         (list :refresh_ms (drgnx-perf-extensions--r (car r))
               :packages (with-temp-buffer
                           (insert-file-contents file)
                           (length (plist-get (json-parse-buffer :object-type 'plist :array-type 'list) :packages)))
               :catalog_kb (/ (file-attribute-size (file-attributes file)) 1024))))
     (defun drgnx-perf-extensions-refresh-teardown () (drgnx-perf-extensions--leave) t)

     ;; install-overhead: `drgnx sync --add' of one fixture package against package.el installing the same
     (defun drgnx-perf-extensions--run (command env)
       "COMMAND (a list) run to its end with ENV first in the environment: the milliseconds, the exit code, the output."
       (let* ((process-environment (append env process-environment)) (code nil) (out nil) (t0 (float-time))
              (default-directory (file-name-as-directory (car drgnx-perf-extensions--root))))
         (with-temp-buffer (setq code (apply #'call-process (car command) nil t nil (cdr command)) out (buffer-string)))
         (list (* 1000 (- (float-time) t0)) code out)))
     (defun drgnx-perf-extensions-install-setup ()
       (let ((dir (drgnx-perf-extensions--enter)))
         (load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)
         (drgnx-pkg-test--archive (concat dir "arch") '((perfone "1.0")))
         (make-directory (concat dir "mods") t)
         (make-directory (concat dir "home") t)
         t))
     (defun drgnx-perf-extensions--sync-once (dir n)
       (let ((root (concat dir (format "run%d/" n))))
         (dolist (d '("config" "mods" "home")) (make-directory (concat root d) t))
         (drgnx-pkg-child-want root 'perfone)
         (copy-directory (concat dir "arch") (concat root "arch") nil t t)
         (drgnx-perf-extensions--run (drgnx-pkg-child-command '("sync" "--add" "perfone")) (drgnx-pkg-child-env root))))
     (defun drgnx-perf-extensions--plain-once (dir n)
       (let* ((root (concat dir (format "plain%d/" n))) (arch (concat dir "arch")))
         (make-directory root t)
         (drgnx-perf-extensions--run
          (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q" "--eval"
                (format "(progn (require 'package) (setq package-user-dir %S package-archives '((\"fx\" . %S)) package-check-signature nil) (package-initialize) (package-refresh-contents) (package-install 'perfone))"
                        (concat root "elpa") (file-name-as-directory arch)))
          (list (concat "HOME=" root)))))
     (defun drgnx-perf-extensions-install-measure ()
       (let* ((dir (car drgnx-perf-extensions--root)) sync plain)
         (dotimes (n 3)                    ; interleaved, the median of three
           (let ((s (drgnx-perf-extensions--sync-once dir n)) (p (drgnx-perf-extensions--plain-once dir n)))
             (unless (and (eql (cadr s) 0) (eql (cadr p) 0)) (error "a child failed: sync %S %S, plain %S %S" (cadr s) (nth 2 s) (cadr p) (nth 2 p)))
             (push (car s) sync) (push (car p) plain)))
         (let ((s (drgnx-perf-extensions--pct sync 0.5)) (p (drgnx-perf-extensions--pct plain 0.5)))
           (list :sync_ms (drgnx-perf-extensions--r s) :plain_ms (drgnx-perf-extensions--r p)
                 :overhead_ms (drgnx-perf-extensions--r (- s p))))))
     (defun drgnx-perf-extensions-install-teardown () (drgnx-perf-extensions--leave) t)

     ;; list-packages-compare: package.el's `list-packages' on the same four archives, then the view on the same rows
     (defun drgnx-perf-extensions--heap ()
       "Bytes the Lisp heap holds live, after a collection."
       (let ((total 0))
         (dolist (e (garbage-collect)) (when (and (consp e) (integerp (nth 1 e)) (integerp (nth 2 e))) (cl-incf total (* (nth 1 e) (nth 2 e)))))
         total))
     (defvar drgnx-perf-extensions--package-vars nil "package.el's variables before the comparison.")
     (defun drgnx-perf-extensions-compare-setup ()
       (let* ((dir (drgnx-perf-extensions--enter)) (archives (drgnx-perf-extensions-write-archives (concat dir "archives"))))
         (require 'package)
         (setq drgnx-perf-extensions--package-vars (list package-archives package-archive-contents package-user-dir package-alist))
         (setq package-user-dir (concat dir "elpa") package-archives archives package-archive-contents nil package-alist nil)
         (dolist (a archives)               ; where package.el reads a fetched archive's contents from
           (make-directory (concat package-user-dir "/archives/" (car a)) t)
           (copy-file (concat (cdr a) "archive-contents") (concat package-user-dir "/archives/" (car a) "/archive-contents") t))
         (drgnx-perf-extensions--common-setup)
         (dotimes (k (length drgnx-perf-extensions--word)) (drgnx-perf-extensions--answer (substring drgnx-perf-extensions--word 0 (1+ k))))
         (drgnx-perf-extensions--answer "e")
         t))
     (defun drgnx-perf-extensions-compare-each ()
       (when (get-buffer "*Packages*") (kill-buffer "*Packages*"))
       (drgnx-perf-extensions--common-each))
     (defun drgnx-perf-extensions--package-menu ()
       "package.el's list over the four archives, offline: (:first_ms :key_p50_ms :key_max_ms :scroll_max_ms :heap_kb)."
       (let* ((h0 (drgnx-perf-extensions--heap))
              (first (drgnx-perf-extensions--ms (lambda () (setq package-archive-contents nil) (package-read-all-archive-contents)
                                                  (list-packages t) (switch-to-buffer "*Packages*") (redisplay t))))
              (heap (- (drgnx-perf-extensions--heap) h0))
              (keys (let (times)
                      (dotimes (k (length drgnx-perf-extensions--word))
                        (let ((text (substring drgnx-perf-extensions--word 0 (1+ k))))
                          (push (drgnx-perf-extensions--ms (lambda () (with-current-buffer "*Packages*" (package-menu-filter-by-name text)) (redisplay t))) times)))
                      times))
              (scroll (let ((times nil) (n (drgnx-perf-extensions--size 'scroll)))
                        (with-current-buffer "*Packages*" (goto-char (point-min)))
                        (dotimes (i (* 2 n))
                          (push (drgnx-perf-extensions--ms (lambda () (with-current-buffer "*Packages*" (condition-case nil (if (< i n) (scroll-up-command) (scroll-down-command)) (error nil))) (redisplay t))) times))
                        times)))
         (list :first_ms first :key_p50_ms (drgnx-perf-extensions--pct keys 0.5) :key_max_ms (apply #'max keys)
               :scroll_max_ms (apply #'max scroll) :heap_kb (/ heap 1024))))
     (defun drgnx-perf-extensions--view-side ()
       "The view's list over the same rows: (:first_ms :key_p50_ms :key_max_ms :scroll_max_ms :heap_kb)."
       (let* ((h0 (drgnx-perf-extensions--heap))
              (first (car (drgnx-perf-extensions--open-ms)))
              (heap (- (drgnx-perf-extensions--heap) h0))
              (keys (drgnx-perf-extensions--type-ms drgnx-perf-extensions--word))
              (scroll (progn (drgnx-extensions-list--apply-query "e") (redisplay t)
                             (drgnx-perf-extensions--scroll-ms (drgnx-perf-extensions--size 'scroll)))))
         (list :first_ms first :key_p50_ms (drgnx-perf-extensions--pct keys 0.5) :key_max_ms (apply #'max keys)
               :scroll_max_ms (apply #'max scroll) :heap_kb (/ heap 1024))))
     (defun drgnx-perf-extensions-compare-measure ()
       (let* ((pm (drgnx-perf-extensions--package-menu))
              (_ (when (get-buffer "*Packages*") (kill-buffer "*Packages*")))
              (view (drgnx-perf-extensions--view-side)) out)
         (dolist (k '(:first_ms :key_p50_ms :key_max_ms :scroll_max_ms :heap_kb))
           (setq out (append out (list (intern (format ":menu_%s" (substring (symbol-name k) 1))) (drgnx-perf-extensions--r (plist-get pm k))
                                       (intern (format ":view_%s" (substring (symbol-name k) 1))) (drgnx-perf-extensions--r (plist-get view k))
                                       (intern (format ":beats_%s" (substring (symbol-name k) 1)))
                                       (if (< (plist-get view k) (plist-get pm k)) 1 0)))))
         out))
     (defun drgnx-perf-extensions-compare-teardown ()
       (when (get-buffer "*Packages*") (kill-buffer "*Packages*"))
       (when drgnx-perf-extensions--package-vars
         (setq package-archives (nth 0 drgnx-perf-extensions--package-vars) package-archive-contents (nth 1 drgnx-perf-extensions--package-vars)
               package-user-dir (nth 2 drgnx-perf-extensions--package-vars) package-alist (nth 3 drgnx-perf-extensions--package-vars)
               drgnx-perf-extensions--package-vars nil))
       (drgnx-perf-extensions--common-teardown)))
  "The library the workloads evaluate in the session (quoted code), with one `-setup', `-each', `-measure' and
`-teardown' function per workload.")

(defconst drgnx-perf-extensions--names
  '((open . extensions-open) (search . extensions-search) (scroll . extensions-scroll) (details . extensions-details)
    (progress . extensions-progress) (activate . activate-live) (activate-new . activate-live-new)
    (install . install-overhead) (refresh . refresh-job) (compare . list-packages-compare))
  "Library prefix → workload name.")

(defun drgnx-perf-extensions--form (&rest calls)
  "A form for the session: the library, then CALLS (symbols, called with no arguments), as text."
  (prin1-to-string `(progn ,drgnx-perf-extensions--lib ,@(mapcar #'list calls) t)))

(defun drgnx-perf-extensions--measure-form (prefix)
  "The form of workload PREFIX's measure: its `-measure' function's plist."
  (prin1-to-string `(progn ,drgnx-perf-extensions--lib (,(intern (format "drgnx-perf-extensions-%s-measure" prefix))))))

(defun drgnx-perf-extensions-workloads ()
  "The Extensions workloads, in the shape of `drgnx-perf-run--workloads'."
  (mapcar
   (lambda (cell)
     (let* ((prefix (car cell))
            (fn (lambda (what) (intern (format "drgnx-perf-extensions-%s-%s" prefix what)))))
       (append (list (cdr cell)
                     :setup (drgnx-perf-extensions--form (funcall fn "setup"))
                     :measure (drgnx-perf-extensions--measure-form prefix)
                     :teardown (drgnx-perf-extensions--form (funcall fn "teardown")))
               (when (memq prefix '(open search scroll details progress compare activate activate-new))
                 (list :each (drgnx-perf-extensions--form (funcall fn "each")))))))
   drgnx-perf-extensions--names))

(declare-function drgnx-perf-extensions-write-archives "drgnx-perf-extensions" (dir))   ; defined by the evaluated library

(defun drgnx-perf-extensions-fixture-main ()
  "Batch entry: write the full archives into the directory named by the last command-line argument (default
test/fixtures/extensions/full next to this checkout), for `drgnx pkg' or a by-hand look.  Never the network."
  (eval drgnx-perf-extensions--lib t)
  (let* ((dir (expand-file-name (or (car (last command-line-args-left))
                                    "test/fixtures/extensions/full" )
                                (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name))))))
         (archives (drgnx-perf-extensions-write-archives dir)))
    (dolist (a archives) (message "%s: %s" (car a) (cdr a)))
    (setq command-line-args-left nil)))

(provide 'drgnx-perf-extensions)
;;; drgnx-perf-extensions.el ends here
