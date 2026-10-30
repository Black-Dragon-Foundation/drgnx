;;; pkg-eld-test.el --- batch tests: packages.eld, drgnx.lock.eld, generation.eld, current and packages-wanted.eld on the config layer -*- lexical-binding: t -*-
;; Offline and in temp dirs, like pkg-test.el (its fixture): archives are local directories, nothing is installed
;; from a network.  The wanted-file test starts two child `emacs --batch -Q' processes, waited for under a 30 s bound.
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(require 'drgnx-pkg-activate)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)   ; archives as local dirs, the sandbox

(defun drgnx-pkg-eld-test--put (file text)
  "FILE holds exactly TEXT."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil file nil 'silent)))

(defun drgnx-pkg-eld-test--text (file)
  (with-temp-buffer (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents file)) (buffer-string)))

(defun drgnx-pkg-test--want-eld (root &rest names)
  "packages.eld in ROOT's config asking for NAMES."
  (drgnx-pkg-test--write (concat root "config/packages.eld") (list :packages names)))

(defun drgnx-pkg-eld-test--packages-eld ()(expand-file-name "packages.eld" (drgnx-user-dir)))

(defun drgnx-pkg-eld-test--leftovers (dir)
  "The temp files and locks the file layer leaves in DIR (none, when it cleans up)."
  (directory-files dir nil "\\.tmp-\\|\\.lock\\'"))

(defun drgnx-pkg-eld-test--sync-stopped (root)
  "Run a sync in ROOT that must stop with a `drgnx-pkg-error': its message.  The packages directory was never made."
  (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0")))))
    (let ((err (should-error (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :type 'drgnx-pkg-error)))
      (should-not (file-directory-p (drgnx-elpa-dir)))
      (cadr err))))

;;;; The lock

(ert-deftest drgnx-pkg-eld/a-lock-with-a-mistake-stops-sync-and-is-never-replaced ()
  (dolist (text (list "(:version 1 :packages ((aa :version\n"                    ; does not read
                      ";; mine\n(:version 1 :packages (3))\n"                    ; reads, is not a lock
                      "(:version 1 :packages ((aa :version 7)))\n"))            ; an entry that is not one
    (drgnx-pkg-test--with root
      (let ((lock (drgnx-pkg-lock-file)))
        (drgnx-pkg-eld-test--put lock text)
        (drgnx-pkg-test--want-eld root 'fa)
        (should (string-match-p "drgnx\\.lock\\.eld has a mistake at line [0-9]+: " (drgnx-pkg-eld-test--sync-stopped root)))
        (should-error (drgnx-pkg-read-lock) :type 'drgnx-pkg-error)
        (should-error (drgnx-pkg-write-lock '((zz :version "1.0"))) :type 'drgnx-pkg-error)
        (should (equal (drgnx-pkg-eld-test--text lock) text))                  ; the same bytes
        (should-not (directory-files (drgnx-user-dir) nil "\\.bak-"))
        (should-not (drgnx-pkg-eld-test--leftovers (drgnx-user-dir)))))))

(ert-deftest drgnx-pkg-eld/a-lock-from-a-newer-drgnx-is-read-and-never-written ()
  (drgnx-pkg-test--with root
    (let* ((lock (drgnx-pkg-lock-file))
           (text "(:version 2 :packages ((aa :version \"1.0\")))\n"))
      (drgnx-pkg-eld-test--put lock text)
      (drgnx-pkg-test--want-eld root 'fa)
      (should (equal (drgnx-pkg-read-lock) '((aa :version "1.0"))))
      (should (string-match-p "newer drgnx" (drgnx-pkg-eld-test--sync-stopped root)))   ; before anything is installed
      (should-error (drgnx-pkg-write-lock '((zz :version "1.0"))) :type 'drgnx-pkg-error)
      (should (equal (drgnx-pkg-eld-test--text lock) text))
      (should-not (directory-files (drgnx-user-dir) nil "\\.bak-")))))

(ert-deftest drgnx-pkg-eld/the-lock-keeps-a-users-comment ()
  (drgnx-pkg-test--with root
    (let ((lock (drgnx-pkg-lock-file)))
      (drgnx-pkg-eld-test--put lock ";; my lock\n(:version 1\n ;; these two are pinned on purpose\n :from-shipped t\n :packages ((aa :version \"1.0\")))\n")
      (drgnx-pkg-write-lock '((zz :version "2.0" :sha256 "b") (aa :version "1.0")))
      (let ((text (drgnx-pkg-eld-test--text lock)))
        (should (string-prefix-p ";; my lock\n(:version 1\n ;; these two are pinned on purpose\n" text))
        (should-not (string-search "from-shipped" text))          ; a sync completes a lock copied from the shipped one
        (should (equal (drgnx-pkg-read-lock) '((aa :version "1.0") (zz :version "2.0" :sha256 "b")))))
      ;; a key of the user's own stays too
      (drgnx-pkg-eld-test--put lock "(:version 1 :note \"mine\" :packages ((aa :version \"1.0\")))\n")
      (drgnx-pkg-write-lock '((aa :version "1.0") (bb :version "1.0")))
      (should (string-search ":note \"mine\"" (drgnx-pkg-eld-test--text lock)))
      (should (equal (mapcar #'car (drgnx-pkg-read-lock)) '(aa bb))))))

(ert-deftest drgnx-pkg-eld/a-lock-that-is-the-same-writes-nothing ()
  (drgnx-pkg-test--with root
    (let ((lock (drgnx-pkg-lock-file)))
      (drgnx-pkg-write-lock '((aa :version "1.0")))
      (let ((attrs (file-attributes lock)))
        (drgnx-pkg-write-lock '((aa :version "1.0")))
        (should (equal (file-attribute-inode-number attrs) (file-attribute-inode-number (file-attributes lock))))
        (should (equal (file-attribute-modification-time attrs) (file-attribute-modification-time (file-attributes lock))))))))

(ert-deftest drgnx-pkg-eld/a-new-user-lock-starts-from-the-shipped-one-and-a-mistaken-one-is-left-alone ()
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--write (drgnx-pkg-shipped-lock-file) '(:version 1 :packages ((aa :version "1.0") (bb :version "2.0"))))
    (drgnx-pkg--start-from-shipped-lock)
    (should (string-prefix-p ";; drgnx package lock" (drgnx-pkg-eld-test--text (drgnx-pkg-lock-file))))
    (should (equal (mapcar #'car (drgnx-pkg-read-lock)) '(aa bb)))
    (should (drgnx-pkg--lock-from-shipped-p))
    ;; a lock that is there, even with a mistake, is never started over
    (drgnx-pkg-eld-test--put (drgnx-pkg-lock-file) "(:version 1 :packages (")
    (drgnx-pkg--start-from-shipped-lock)
    (should (equal (drgnx-pkg-eld-test--text (drgnx-pkg-lock-file)) "(:version 1 :packages ("))))

(ert-deftest drgnx-pkg-eld/rollback-keeps-a-lock-with-a-mistake-in-a-backup ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0")))))
      (drgnx-pkg-test--want-eld root 'fa)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :ok))
      (let ((good (drgnx-pkg-eld-test--text (drgnx-pkg-lock-file))))
        (drgnx-pkg-eld-test--put (drgnx-pkg-lock-file) "(:version 1 :packages (3))\n")      ; the user's edit went wrong
        (drgnx-pkg-rollback 1)
        (should (equal (drgnx-pkg-eld-test--text (drgnx-pkg-lock-file)) good))              ; the generation's lock is back
        (let ((bak (directory-files (drgnx-user-dir) t "drgnx\\.lock\\.eld\\.bak-")))
          (should (= (length bak) 1))
          (should (equal (drgnx-pkg-eld-test--text (car bak)) "(:version 1 :packages (3))\n")))))))

(ert-deftest drgnx-pkg-eld/the-shipped-lock-and-a-new-file-fit-the-lock-schema ()
  (let ((schema (plist-get (drgnx-config-definition 'lock) :schema)))
    (should (drgnx-pkg--read-lock-file (expand-file-name "etc/drgnx.lock.eld" drgnx-dir)))
    (should-not (drgnx-schema-check schema '(:version 1 :packages nil)))
    (should-not (drgnx-schema-check schema '(:version 1 :from-shipped t
                                                      :packages ((aa) (bb :version "1" :kind git :commit "abc" :requires nil)))))
    (should (drgnx-schema-check schema '(:version 1)))                  ; :packages is required
    (should (drgnx-schema-check schema '(:packages ((:version "1")))))
    (should (drgnx-schema-check schema '(:packages ((aa :version)))))))

;;;; packages.eld

(ert-deftest drgnx-pkg-eld/packages-eld-mistake-stops-sync-with-the-line ()
  (drgnx-pkg-test--with root
    (let ((file (drgnx-pkg-eld-test--packages-eld)))
      (dolist (case '((";; mine\n(:packages (fa)\n :archives ((\"gnu\" . 3)))\n" . 2)           ; the wrong kind of value
                      ("(:packages (fa)\n :git (\n" . nil)))                                    ; does not read
        (drgnx-pkg-eld-test--put file (car case))
        (let ((msg (drgnx-pkg-eld-test--sync-stopped root)))
          (should (string-match "packages\\.eld has a mistake at line \\([0-9]+\\): \\(.+\\)" msg))
          (when (cdr case) (should (equal (match-string 1 msg) (number-to-string (cdr case)))))
          (should (equal (match-string 1 msg) (number-to-string (plist-get (drgnx-config-problem 'packages) :line)))))
        (should-error (drgnx-pkg-manifest (concat root "mods")) :type 'drgnx-pkg-error)
        (should-error (drgnx-pkg-archives) :type 'drgnx-pkg-error)
        (should (equal (drgnx-pkg-eld-test--text file) (car case)))
        (should-not (directory-files (drgnx-user-dir) nil "\\.bak-"))
        (should-not (file-exists-p (drgnx-pkg-lock-file)))))))                                  ; no lock made either

(ert-deftest drgnx-pkg-eld/a-fixed-packages-eld-is-read-again-by-the-next-sync ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0")))))
      (drgnx-pkg-eld-test--put (drgnx-pkg-eld-test--packages-eld) "(:packages (fa")
      (drgnx-pkg-eld-test--sync-stopped root)
      (drgnx-pkg-eld-test--put (drgnx-pkg-eld-test--packages-eld) "(:packages (fa))\n")
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :ok))
      (should (equal (drgnx-pkg-test--installed) '("fa-1.0"))))))

(ert-deftest drgnx-pkg-eld/the-forms-the-docs-teach-still-fit ()
  ;; A packages.eld written before the config layer keeps working (no version bump): local archives, Git sources with
  ;; :rev and :lisp-dir and a local URL or ssh, float priorities, an empty file, no keys at all.
  (let ((schema (plist-get (drgnx-config-definition 'packages) :schema)))
    (dolist (form '(nil
                    (:packages (rainbow-delimiters treesit-auto)
                               :archives (("gnu" . "https://elpa.gnu.org/packages/") ("local" . "/srv/elpa/")))
                    (:archives ())
                    (:archive-priorities (("gnu" . 3) ("melpa" . 1.5)))
                    (:archive-priorities nil)
                    (:git ((eglot-booster :url "https://github.com/jdtsmith/eglot-booster" :rev "main")
                           (my-tool :url "git@codeberg.org:me/my-tool.git" :rev "v1.2" :lisp-dir "lisp")
                           (local-one :url "/tmp/some/repo" :commit "0123abc")))
                    (:version 1 :packages (a) :something-of-mine (1 2))))
      (should-not (drgnx-schema-check schema form)))
    (dolist (bad '((:packages ("magit")) (:packages magit) (:git ((x . "url"))) (:archives ((gnu . "u")))
                   (:archive-priorities (("melpa" . "high"))) (:archive-priorities t)))
      (should (drgnx-schema-check schema bad)))))

(ert-deftest drgnx-pkg-eld/a-malformed-priority-names-the-key ()
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--write (drgnx-pkg-eld-test--packages-eld) '(:packages (magit) :archive-priorities (("melpa" . "high"))))
    (let ((err (should-error (drgnx-pkg-archive-priorities) :type 'drgnx-pkg-error)))
      (should (string-match-p ":archive-priorities" (cadr err))))))

;;;; generation.eld and current

(ert-deftest drgnx-pkg-eld/a-generation-and-its-current-marker-are-written-whole ()
  (drgnx-pkg-test--with root
    (let ((arch (drgnx-pkg-test--archive (concat root "arch") '((fa "1.0")))))
      (drgnx-pkg-test--want-eld root 'fa)
      (should (plist-get (drgnx-pkg-test--sync root :archives `(("fx" . ,arch))) :ok))
      (let ((gens (drgnx-generations-dir)))
        (should (equal (drgnx-pkg-eld-test--text (expand-file-name "current" gens)) "1"))
        (should (string-prefix-p ";; drgnx generation\n" (drgnx-pkg-eld-test--text (expand-file-name "1/generation.eld" gens))))
        (should (plist-get (cdr (car (drgnx-pkg-generations))) :time))
        (should-not (cl-remove-if-not (lambda (f) (string-search ".tmp-" f))
                                      (directory-files-recursively gens ".*" t)))))))

;;;; packages-wanted.eld

(ert-deftest drgnx-pkg-eld/a-want-is-recorded-once-and-keeps-the-others ()
  (drgnx-pkg-test--with root
    (drgnx-pkg-test--write (drgnx-pkg-wanted-file) '(old-one))
    (drgnx-pkg-ensure 'drgnx-no-such-package-x '(t) nil)
    (drgnx-pkg-ensure 'drgnx-no-such-package-x '(t) nil)
    (should (equal (drgnx-pkg--read-file (drgnx-pkg-wanted-file)) '(old-one drgnx-no-such-package-x)))
    (should-not (drgnx-pkg-eld-test--leftovers (file-name-directory (drgnx-pkg-wanted-file))))))

(ert-deftest drgnx-pkg-eld/a-busy-wanted-file-is-skipped-quietly-and-the-next-run-records ()
  (drgnx-pkg-test--with root
    (let* ((file (drgnx-pkg-wanted-file))
           (inhibit-message t) (messages nil))
      (drgnx-pkg-test--write file '(old-one))
      (let ((held (drgnx-file--lock (drgnx-file--target file) 0)))
        (unwind-protect
            (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
              (drgnx-pkg--record-want 'drgnx-no-such-package-x)            ; a timer-like call: no wait, no error
              (should-not messages)
              (should (equal (drgnx-pkg--read-file file) '(old-one))))
          (drgnx-file--unlock held)))
      (drgnx-pkg--record-want 'drgnx-no-such-package-x)
      (should (equal (drgnx-pkg--read-file file) '(old-one drgnx-no-such-package-x))))))

(ert-deftest drgnx-pkg-eld/an-unreadable-wanted-file-is-backed-up-not-lost ()
  (drgnx-pkg-test--with root
    (let ((file (drgnx-pkg-wanted-file)) (inhibit-message t))
      (drgnx-pkg-eld-test--put file "(old-one other\n")
      (drgnx-pkg--record-want 'drgnx-no-such-package-x)
      (should (equal (drgnx-pkg--read-file file) '(drgnx-no-such-package-x)))
      (let ((bak (directory-files (file-name-directory file) t "packages-wanted\\.eld\\.bak-")))
        (should (= (length bak) 1))
        (should (equal (drgnx-pkg-eld-test--text (car bak)) "(old-one other\n"))))))

(ert-deftest drgnx-pkg-eld/wanted-is-merged-across-processes ()
  (drgnx-pkg-test--with root
    (let* ((file (drgnx-pkg-wanted-file))
           (core (file-name-directory (locate-library "drgnx-pkg-activate")))
           (at (+ (float-time) 2)) (outs nil)
           (start (lambda (tag)
                    (let ((b (generate-new-buffer " *drgnx-wanted-child*" t)))
                      (push b outs)
                      (make-process
                       :name tag :buffer b :noquery t
                       :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                      "--eval" "(setq load-prefer-newer t)" "-L" core "-l" "drgnx-pkg-activate"
                                      "--eval"
                                      ;; a startup that finds the file busy skips the want; the next startup records it
                                      (format "(progn (sleep-for (max 0 (- %f (float-time))))
                                                      (dotimes (i 20)
                                                        (let ((name (intern (format \"%s-x%%d\" i))) (tries 0))
                                                          (while (and (not (memq name (plist-get (drgnx-file-read %S) :data)))
                                                                      (< (setq tries (1+ tries)) 5000))
                                                            (drgnx-pkg--record-want name))))
                                                      (princ \"DONE\\n\"))"
                                              at tag file))))))
           (procs (list (funcall start "a") (funcall start "b"))))
      (drgnx-pkg-test--write file '(old-one))
      (drgnx-test-wait (lambda () (not (cl-some #'process-live-p procs))) :secs 30 :what "the writer processes to end")
      (unwind-protect
          (progn
            (should (cl-every (lambda (p) (and (not (process-live-p p)) (= (process-exit-status p) 0))) procs))
            (dolist (b outs) (should (string-match-p "DONE" (with-current-buffer b (buffer-string)))))
            (let ((names (drgnx-pkg--read-file file)))
              (should (memq 'old-one names))
              (should (= (length names) 41))                                    ; old-one and 20 from each process
              (should (= (length (delete-dups (copy-sequence names))) 41)))
            (should-not (drgnx-pkg-eld-test--leftovers (file-name-directory file))))
        (mapc #'delete-process procs)
        (mapc #'kill-buffer outs)))))

(provide 'pkg-eld-test)
;;; pkg-eld-test.el ends here
