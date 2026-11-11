;;; extensions-trust-test.el --- batch tests: the trust card, inert text and review before an update -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: no process and no real clock.  The hub is stubbed at `drgnx-hub-call' (each call answers at once from a
;; table of rows and details) and at the job client (`drgnx-exec-start' records each start and answers a new id); the
;; diff of a review is stubbed at `drgnx-extensions-trust--diff'.  Every drgnx location is a temp directory.  The
;; inert tests count the calls of every mode function the text could reach, after `font-lock-ensure'.  See
;; docs/guide/extensions.md, "Where it comes from" and "Review before an update".
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-paths)
(require 'drgnx-file)
(require 'drgnx-exec)
(require 'drgnx-view)
(require 'drgnx-pkg)
(require 'diff-mode)                    ; its options are let-bound here: special before the first test
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-details" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-jobs" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-trust" drgnx-dir) nil t)
(defvar drgnx-extensions-review)        ; the module's setting (drgnx-extensions.el): bound here around the layer

;;;; Inert text

(defvar drgnx-extensions-trust-test--calls nil "The mode functions called, newest first.")

(defmacro drgnx-extensions-trust-test--counting (&rest body)
  "BODY with every mode function a package's text could reach counted (and not run), then: none was called and the
variable the text sets is unbound.  `hack-dir-local-variables' counts when it would read (local variables on): diff-mode
calls it for every buffer with no file."
  (declare (indent 0) (debug t))
  `(let ((drgnx-extensions-trust-test--calls nil))
     (cl-letf (,@(mapcar (lambda (f) `((symbol-function ',f) (lambda (&rest _) (push ',f drgnx-extensions-trust-test--calls))))
                         '(set-auto-mode org-mode markdown-mode emacs-lisp-mode flymake-mode hack-local-variables))
               ((symbol-function 'hack-dir-local-variables)
                (lambda () (when (and enable-local-variables enable-dir-local-variables)
                             (push 'hack-dir-local-variables drgnx-extensions-trust-test--calls)))))
       (let ((diff-mode-hook (list (lambda () (push 'diff-mode-hook drgnx-extensions-trust-test--calls))))
             (emacs-lisp-mode-hook (list (lambda () (push 'emacs-lisp-mode-hook drgnx-extensions-trust-test--calls))))
             (after-change-major-mode-hook
              (list (lambda () (push 'after-change-major-mode-hook drgnx-extensions-trust-test--calls)))))
         ,@body))
     (should-not drgnx-extensions-trust-test--calls)
     (should-not (boundp 'drgnx-extensions-trust-test-x))))

(defconst drgnx-extensions-trust-test--org
  "-*- eval: (setq drgnx-extensions-trust-test-x 1) -*-\n#+TITLE: Foo\n#+begin_src elisp\n(setq drgnx-extensions-trust-test-x 2)\n#+end_src\nSee [[elisp:(setq drgnx-extensions-trust-test-x 3)][this]].\n"
  "A hostile Org readme.")

(defconst drgnx-extensions-trust-test--diff
  (concat "diff -ruN installed/a.org update/a.org\n--- installed/a.org\n+++ update/a.org\n@@ -1 +1,3 @@\n #+TITLE: A\n"
          "+#+begin_src elisp\n+(setq drgnx-extensions-trust-test-x 1)\n"
          "diff -ruN installed/b.el update/b.el\n--- installed/b.el\n+++ update/b.el\n@@ -1 +1,2 @@\n"
          " ;;; b.el -*- lexical-binding: t; eval: (setq drgnx-extensions-trust-test-x 2) -*-\n"
          "+(eval-when-compile (setq drgnx-extensions-trust-test-x 3))\n")
  "A reviewed diff whose hunks are an Org file and a Lisp file.")

(ert-deftest drgnx-extensions-trust/a-fetched-readme-is-inert ()
  "D: an Org readme with a source block, a link that would run Lisp and an eval line is plain text: no mode, no hook,
no local variable, no face, no link."
  (drgnx-extensions-trust-test--counting
    (with-temp-buffer
      (drgnx-extensions-inert-insert drgnx-extensions-trust-test--org 'text)
      (font-lock-ensure)
      (should (eq major-mode 'fundamental-mode))
      (should (string-search "#+begin_src elisp" (buffer-string)))
      (should-not enable-local-variables)
      (should-not (next-single-property-change (point-min) 'face))
      (should-not (next-single-property-change (point-min) 'keymap)))
    (let ((s (drgnx-extensions-trust-inert-string drgnx-extensions-trust-test--org 'text)))
      (should (string-search "[[elisp:" s))
      (should-not (next-property-change 0 s)))))

(ert-deftest drgnx-extensions-trust/a-reviewed-diff-runs-no-mode ()
  "D: a diff whose hunks are a.org and b.el gets diff-mode's colours and nothing else: after `font-lock-ensure' no
`set-auto-mode', no Org or Lisp mode, no mode hook ran.  Plain `diff-mode' with its syntax colours from the hunks
\(`hunk-also', which `t' falls back to when the files are on disk) does call `set-auto-mode' for the same text: the
count would see it."
  (let ((drgnx-extensions-trust-test--calls nil))
    (cl-letf (((symbol-function 'set-auto-mode) (lambda (&rest _) (push 'set-auto-mode drgnx-extensions-trust-test--calls))))
      (with-temp-buffer
        (insert drgnx-extensions-trust-test--diff)
        (let ((diff-font-lock-syntax 'hunk-also)) (diff-mode) (font-lock-ensure))))
    (should (memq 'set-auto-mode drgnx-extensions-trust-test--calls)))
  (drgnx-extensions-trust-test--counting
    (with-temp-buffer
      (drgnx-extensions-inert-insert drgnx-extensions-trust-test--diff 'diff)
      (font-lock-ensure)
      (should (eq major-mode 'diff-mode))
      (should (local-variable-p 'diff-font-lock-syntax))
      (should-not diff-font-lock-syntax)
      (should-not delayed-mode-hooks)
      (should-not enable-local-variables)
      (should (next-single-property-change (point-min) 'face)))
    (let ((s (drgnx-extensions-trust-inert-string drgnx-extensions-trust-test--diff 'diff)))
      (should (string-search "eval-when-compile" s)))))

(ert-deftest drgnx-extensions-trust/a-reviewed-el-runs-nothing ()
  "D: a Lisp file of a package that is not installed, with an eval line and `eval-when-compile', shown read-only: the
variable stays unbound, no `emacs-lisp-mode-hook', no Flymake."
  (drgnx-extensions-trust-test--counting
    (with-temp-buffer
      (drgnx-extensions-inert-insert
       ";;; b.el --- b  -*- lexical-binding:t; eval: (setq drgnx-extensions-trust-test-x 1) -*-\n(eval-when-compile (setq drgnx-extensions-trust-test-x 2))\n;; Local Variables:\n;; eval: (setq drgnx-extensions-trust-test-x 3)\n;; End:\n"
       'text)
      (font-lock-ensure)
      (should (eq major-mode 'fundamental-mode))
      (should-not (bound-and-true-p flymake-mode)))))

;;;; The trust card

(defconst drgnx-extensions-trust-test--rows
  ;; the hub's own values: a package from an archive that signs and is not installed yet is "signing-archive"; "signed"
  ;; only once the lock says :verified t
  '(("pkg:compat" :id "pkg:compat" :kind "package" :name "compat" :state "available" :source "gnu"
     :signed "signing-archive")
    ("pkg:dash" :id "pkg:dash" :kind "package" :name "dash" :state "installed" :source "melpa" :signed "unsigned-archive")
    ("pkg:with-editor" :id "pkg:with-editor" :kind "package" :name "with-editor" :state "available" :source "melpa"
     :signed "unsigned-archive")
    ("pkg:transient" :id "pkg:transient" :kind "package" :name "transient" :state "available" :source "melpa"
     :signed "unsigned-archive")
    ("pkg:magit-section" :id "pkg:magit-section" :kind "package" :name "magit-section" :state "available"
     :source "melpa" :signed "unsigned-archive")
    ("pkg:magit" :id "pkg:magit" :kind "package" :name "magit" :state "available" :source "melpa"
     :signed "unsigned-archive" :summary "A Git porcelain" :downloads 1234567)
    ("pkg:gnu-a" :id "pkg:gnu-a" :kind "package" :name "gnu-a" :state "available" :source "gnu"
     :signed "signing-archive")
    ("pkg:needs-lost" :id "pkg:needs-lost" :kind "package" :name "needs-lost" :state "available" :source "melpa"
     :signed "unsigned-archive"))
  "The catalog the hub stub answers from.")

(defconst drgnx-extensions-trust-test--requires
  '(("pkg:magit" "emacs" "compat" "dash" "with-editor" "transient" "magit-section")
    ("pkg:magit-section" "dash" "compat")
    ("pkg:with-editor" "compat")
    ("pkg:transient" "compat")
    ("pkg:needs-lost" "lost-dep"))
  "ID → the names it requires (lost-dep is in no table: its details call fails).")

(defvar drgnx-extensions-trust-test--asked nil "The hub methods asked, newest first.")

(defun drgnx-extensions-trust-test--hub-call (method params callback &rest _)
  "The stub of `drgnx-hub-call': `extensions/details' answers from the tables at once; an unknown id is an error."
  (push method drgnx-extensions-trust-test--asked)
  (pcase method
    ("extensions/details"
     (let* ((id (plist-get params :id)) (row (cdr (assoc id drgnx-extensions-trust-test--rows))))
       (if (null row)
           (funcall callback nil (format "no extension %s" id))
         (funcall callback (list :row row
                                 :requires (vconcat (mapcar (lambda (n) (list :name n))
                                                            (cdr (assoc id drgnx-extensions-trust-test--requires))))
                                 :maintainer "Jonas\nBernoulli" :commit "abc1234" :url "https://example.invalid/magit"
                                 :readme "#+TITLE: the cached readme\n")
                  nil))))
    (_ (funcall callback nil "not stubbed"))))

(defvar drgnx-extensions-trust-test--starts nil "The jobs started, newest first: (:id ID :name NAME :argv ARGV KEYS…).")

(defun drgnx-extensions-trust-test--start (name argv &rest keys)
  "The stub of `drgnx-exec-start': records the start and answers the next id at once."
  (let ((id (format "job-%d" (1+ (length drgnx-extensions-trust-test--starts)))))
    (push (append (list :id id :name name :argv argv) keys) drgnx-extensions-trust-test--starts)
    (funcall (plist-get keys :callback) id nil)
    nil))

(defmacro drgnx-extensions-trust-test--with (&rest body)
  "BODY with every drgnx location a temp directory, the hub and the job client stubbed, the trust layer set up (torn
down after) and every card and page killed after."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-ext-trust" t)))
          (process-environment (append (list (concat "XDG_STATE_HOME=" root "state") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_CACHE_HOME=" root "cache"))
                                       process-environment))
          (drgnx-exec--jobs (make-hash-table :test #'equal))
          (drgnx-extensions-jobs-done-functions nil) (drgnx-extensions-jobs-changed-functions nil)
          (drgnx-extensions-review nil)
          (drgnx-extensions-trust-test--asked nil) (drgnx-extensions-trust-test--starts nil))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-hub-call) #'drgnx-extensions-trust-test--hub-call)
                   ((symbol-function 'drgnx-exec-start) #'drgnx-extensions-trust-test--start))
           (unless (drgnx-view-type-p 'extension-details) (drgnx-extensions-details--define-view))
           (drgnx-extensions-trust-setup)
           ,@body)
       (drgnx-extensions-trust-teardown)
       (dolist (b (buffer-list))
         (when (string-prefix-p "*Extension" (buffer-name b)) (kill-buffer b)))
       (drgnx-view--undefine 'extension-details)
       (clrhash drgnx-extensions-jobs--jobs) (clrhash drgnx-extensions-jobs--ids)
       (clrhash drgnx-extensions-jobs--tickets) (clrhash drgnx-extensions-jobs--state)
       (delete-directory root t))))

(defun drgnx-extensions-trust-test--card (name)
  "The text of NAME's trust card, or nil when none is shown."
  (when-let* ((b (get-buffer (drgnx-extensions-trust-card-name name))))
    (with-current-buffer b (buffer-substring-no-properties (point-min) (point-max)))))

(defun drgnx-extensions-trust-test--click (name command)
  "Run COMMAND in NAME's card as a click does."
  (with-current-buffer (get-buffer (drgnx-extensions-trust-card-name name))
    (let ((this-command command)) (funcall command))))

(ert-deftest drgnx-extensions-trust/the-card-shows-for-unsigned-only ()
  "D: a package from a signed archive installs at once; one from MELPA shows its card and installs nothing yet."
  (drgnx-extensions-trust-test--with
    (let ((this-command 'extensions-install) (ran nil))
      (drgnx-extensions-trust-before-install "pkg:gnu-a" (lambda () (push 'gnu-a ran)))
      (should (equal ran '(gnu-a)))
      (should-not (drgnx-extensions-trust-test--card "gnu-a"))
      (drgnx-extensions-trust-before-install "pkg:magit" (lambda () (push 'magit ran)))
      (should (equal ran '(gnu-a)))
      (let ((card (drgnx-extensions-trust-test--card "magit")))
        (should (string-search "unsigned archive" card))
        (should (string-search "Runs inside Emacs as you: it can read your files and reach the network." card))
        (should (string-search "After this install drgnx pins its hash in the lock." card))
        (should (string-search "abc1234" card))
        (should (string-search "Jonas Bernoulli" card))
        (should (string-search "[Install]" card))
        (should (string-search "[Cancel]" card))))))

(ert-deftest drgnx-extensions-trust/the-card-lists-unsigned-dependencies ()
  "D: magit needs three MELPA packages that are not installed, one that is (dash) and a GNU one (compat): the card
names the three, and only them."
  (drgnx-extensions-trust-test--with
    (let ((this-command 'extensions-install))
      (drgnx-extensions-trust-before-install "pkg:magit" #'ignore)
      (let ((card (drgnx-extensions-trust-test--card "magit")))
        (should (string-search "It also brings 3 unsigned packages it needs: magit-section, transient, with-editor" card))
        (should-not (string-search "dash" card))
        (should-not (string-search "compat" card))))))

(ert-deftest drgnx-extensions-trust/a-lookup-that-fails-is-said-and-hides-install ()
  "D: a dependency whose details the hub could not give is named, never dropped; when the package's own lookup fails
the card says so and has no Install."
  (drgnx-extensions-trust-test--with
    (let ((this-command 'extensions-install))
      (drgnx-extensions-trust-before-install "pkg:needs-lost" #'ignore)
      (let ((card (drgnx-extensions-trust-test--card "needs-lost")))
        (should (string-search "Not checked: lost-dep" card))
        (should (string-search "[Install]" card)))
      ;; the list knows the row, the hub cannot answer for it
      (let ((drgnx-extensions-list--rows (make-hash-table :test 'equal)))
        (puthash "pkg:ghost" (list :id "pkg:ghost" :kind 'package :name "ghost" :state 'available :source "melpa"
                                   :signed 'unsigned-archive)
                 drgnx-extensions-list--rows)
        (drgnx-extensions-trust-before-install "pkg:ghost" #'ignore)
        (let ((card (drgnx-extensions-trust-test--card "ghost")))
          (should (string-search "Could not check what ghost needs" card))
          (should-not (string-search "[Install]" card)))))))

(ert-deftest drgnx-extensions-trust/the-card-has-no-key-that-installs ()
  "D: the list's i opens the card; nothing on the card's keymap installs (only its Install button does)."
  (dolist (profile '("vscode" "emacs" "vim"))
    (let ((rows (with-temp-buffer
                  (insert-file-contents (expand-file-name (format "keys/%s.eld" profile) drgnx-dir))
                  (plist-get (read (current-buffer)) :bind))))
      (should (eq (cadr (assq 'extensions-trust-install rows)) :none)))))

(ert-deftest drgnx-extensions-trust/a-reviewed-update-with-a-new-dependency-applies ()
  "D: the staged update of magit brings b 2.0: both are compared and shown, and Apply goes through."
  (drgnx-extensions-trust-test--with
    (let ((this-command 'extensions-update) (drgnx-extensions-review '(magit)) (diffs nil))
      (cl-letf (((symbol-function 'drgnx-extensions-trust--diff)
                 (lambda (name entry callback) (push name diffs)
                   (funcall callback (format "+(new code of %s)\n" (car entry)) nil))))
        (drgnx-extensions-trust-update "magit")
        (drgnx-file-write (drgnx-pkg-staged-file)
                          '((magit :version "4.2" :file "magit-4.2.tar" :sha256 "abc123" :verified nil)
                            (b :version "2.0" :file "b-2.0.tar" :sha256 "bbb222" :verified t)))
        (run-hook-with-args 'drgnx-extensions-jobs-done-functions "job-1" '(:status done :kind upgrade))
        (should (equal (sort diffs #'string<) '("b" "magit")))
        (let ((page (with-current-buffer (drgnx-extensions-details-open "pkg:magit")
                      (drgnx-extensions-details--render-body))))
          (should (string-search "+(new code of magit)" page))
          (should (string-search "+(new code of b)" page))
          (should (string-search "bbb222" page)))
        (drgnx-extensions-trust-apply "magit")
        (should (= 2 (length drgnx-extensions-trust-test--starts)))))))

(ert-deftest drgnx-extensions-trust/the-card-shows-once-per-package ()
  "D: Install on the card records the package and what it brings and runs the install once; the next install of it
has no card."
  (drgnx-extensions-trust-test--with
    (let ((this-command 'extensions-install) (ran 0))
      (drgnx-extensions-trust-before-install "pkg:magit" (lambda () (cl-incf ran)))
      (should (= ran 0))
      (drgnx-extensions-trust-test--click "magit" #'drgnx-extensions-trust-install)
      (should (= ran 1))
      (should-not (drgnx-extensions-trust-test--card "magit"))
      (should (equal (plist-get (drgnx-file-read (drgnx-extensions-trust-file)) :data)
                     '(magit magit-section transient with-editor)))
      (drgnx-extensions-trust-before-install "pkg:magit" (lambda () (cl-incf ran)))
      (should (= ran 2))
      (should-not (drgnx-extensions-trust-test--card "magit")))))

(ert-deftest drgnx-extensions-trust/cancel-queues-nothing ()
  "D: the list's Install of a MELPA package, then Cancel on its card: no ticket, nothing recorded."
  (drgnx-extensions-trust-test--with
    (let ((this-command 'extensions-install) (queued nil))
      (cl-letf (((symbol-function 'drgnx-extensions-jobs-queue) (lambda (e) (push e queued) 1)))
        (drgnx-extensions--before-install '(:add magit))
        (should (drgnx-extensions-trust-test--card "magit"))
        (drgnx-extensions-trust-test--click "magit" #'drgnx-extensions-trust-cancel)
        (should-not (drgnx-extensions-trust-test--card "magit"))
        (should-not queued)
        (should-not (file-exists-p (drgnx-extensions-trust-file)))
        ;; a signed one goes through the same door to the queue
        (drgnx-extensions--before-install '(:add gnu-a :version "1.0"))
        (should (equal queued '((:add gnu-a :version "1.0"))))))))

(ert-deftest drgnx-extensions-trust/never-from-a-timer ()
  "D: called with no command (a timer, a hook, a process): no card, nothing queued, no hub call, a notice."
  (drgnx-extensions-trust-test--with
    (let ((this-command nil) (ran nil) (notices nil))
      (cl-letf (((symbol-function 'drgnx-notify) (lambda (&rest args) (push args notices))))
        (should-not (drgnx-extensions-trust-before-install "pkg:magit" (lambda () (setq ran t))))
        (should-not (drgnx-extensions-trust-before-install "pkg:gnu-a" (lambda () (setq ran t)))))
      (should-not ran)
      (should-not (drgnx-extensions-trust-test--card "magit"))
      (should-not drgnx-extensions-trust-test--asked)
      (should (= 2 (length notices))))))

(ert-deftest drgnx-extensions-trust/review-stages-then-applies-the-same-hash ()
  "D: magit is under review: Update starts a staging job (`upgrade --only magit --stage'), the page shows the staged
hash and the diff, Apply starts `upgrade --staged' alone.  A staged list that changed since the review (another
package staged over it) is refused: no job."
  (drgnx-extensions-trust-test--with
    (let ((this-command 'extensions-update) (drgnx-extensions-review '(magit)) (diffs nil))
      (cl-letf (((symbol-function 'drgnx-extensions-trust--diff)
                 (lambda (name entry callback) (push (cons name entry) diffs) (funcall callback "+(new code)\n" nil))))
        (drgnx-extensions-trust-update "magit")
        (let ((stage (car drgnx-extensions-trust-test--starts)))
          (should (equal (cdr (plist-get stage :argv)) (list "upgrade" "--only" "magit" "--stage" "--progress"
                                                             (car (last (plist-get stage :argv)))))))
        (should (eq (plist-get (drgnx-extensions-trust-review "magit") :state) 'staging))
        ;; the staging job ends: what it fetched is listed in staged.eld
        (drgnx-file-write (drgnx-pkg-staged-file) '((magit :version "4.2" :file "magit-4.2.tar" :sha256 "abc123" :verified nil)))
        (run-hook-with-args 'drgnx-extensions-jobs-done-functions "job-1" '(:status done :kind upgrade))
        (should (equal (caar diffs) "magit"))
        (let ((review (drgnx-extensions-trust-review "magit")))
          (should (eq (plist-get review :state) 'ready))
          (should (equal (plist-get (cdr (plist-get review :entry)) :sha256) "abc123")))
        (let ((page (with-current-buffer (drgnx-extensions-details-open "pkg:magit")
                      (drgnx-extensions-details--render-body))))
          (should (string-search "abc123" page))
          (should (string-search "+(new code)" page)))
        (drgnx-extensions-trust-apply "magit")
        (let ((apply (car drgnx-extensions-trust-test--starts)))
          (should (= 2 (length drgnx-extensions-trust-test--starts)))
          ;; the hashes the review showed travel with the job: the run compares them with the file it finds
          (should (equal (cdr (plist-get apply :argv)) (list "upgrade" "--staged" "--expect" "magit=abc123" "--progress"
                                                             (car (last (plist-get apply :argv))))))))
      ;; again, but another review staged over magit's before Apply
      (cl-letf (((symbol-function 'drgnx-extensions-trust--diff) (lambda (_n _e callback) (funcall callback "x\n" nil))))
        (run-hook-with-args 'drgnx-extensions-jobs-done-functions "job-2" '(:status done :kind upgrade))
        (should-not (drgnx-extensions-trust-review "magit"))
        (drgnx-extensions-trust-update "magit")
        (drgnx-file-write (drgnx-pkg-staged-file) '((magit :version "4.2" :file "magit-4.2.tar" :sha256 "abc123" :verified nil)))
        (run-hook-with-args 'drgnx-extensions-jobs-done-functions "job-3" '(:status done :kind upgrade))
        (drgnx-file-write (drgnx-pkg-staged-file) '((forge :version "0.5" :file "forge-0.5.tar" :sha256 "fff" :verified nil)))
        (should-error (drgnx-extensions-trust-apply "magit") :type 'user-error)
        (should (= 3 (length drgnx-extensions-trust-test--starts)))))))

(ert-deftest drgnx-extensions-trust/a-staged-update-that-differs-from-the-reviewed-one-stops-the-run ()
  "M12: `drgnx upgrade --staged --expect NAME=SHA256' stops before any change when the staged file is not exactly the
reviewed packages at the reviewed hashes (a second review replaced it after the Apply, before the job read it)."
  (drgnx-extensions-trust-test--with
    (drgnx-file-write (drgnx-pkg-staged-file) '((magit :version "4.2" :file "magit-4.2.tar" :sha256 "abc123" :verified nil)))
    (dolist (expect '((("magit" . "other")) (("forge" . "abc123")) (("magit" . "abc123") ("forge" . "fff"))))
      (let ((err (should-error (drgnx-pkg-upgrade :staged t :expect expect))))
        (should (string-search "changed since it was reviewed" (error-message-string err)))))
    (should (file-exists-p (drgnx-pkg-staged-file)))))   ; nothing ran: the list is still there

;;; extensions-trust-test.el ends here
