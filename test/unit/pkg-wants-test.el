;;; pkg-wants-test.el --- batch children: wants in the lock, the queue of clicks, runs that change everything or nothing -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Each test runs the package CLI (`drgnx sync', `upgrade', `rollback') as a batch child, as bin/drgnx does, in temp
;; directories (HOME too) against archives that are local directories: never the network, the user's packages or ~.
;; A child that must be held in a state announces it and parks (test/fixtures/handshake-fixture.el) until the test lets
;; it go; every other child is waited for to its exit.  Pure parts (the queue file) run in this Emacs, in the same
;; sandbox.  See docs/guide/packages.md, "What you asked for" and "The queue".
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)
(require 'drgnx-handshake-fixture (expand-file-name "test/fixtures/handshake-fixture" drgnx-dir))
(require 'drgnx-wait-fixture (expand-file-name "test/fixtures/wait-fixture" drgnx-dir))

(defun drgnx-pkg-wants-test--lock-bytes (root)
  (let ((f (concat root "config/drgnx.lock.eld"))) (and (file-exists-p f) (drgnx-pkg-test--bytes f))))

(defun drgnx-pkg-wants-test--tickets (output)
  "The tickets of the `start' line in a child's OUTPUT."
  (when (string-match "^start tickets: \\([0-9 ]+\\)$" output)
    (mapcar #'string-to-number (split-string (match-string 1 output)))))

(defun drgnx-pkg-wants-test--archive (root packages)
  (drgnx-pkg-test--archive (concat root "arch") packages))

;;;; Wants in the lock

(ert-deftest drgnx-pkg/add-marks-wanted-only-on-success ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (let ((r (drgnx-pkg-child-run root '("sync" "--add" "fa" "fz"))))     ; no archive has fz: the run fails whole
      (should (eql (car r) 1))
      (should-not (drgnx-pkg-child-lock root))
      (should-not (drgnx-pkg-child-elpa root)))
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))
    (should (eq (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :wanted) 'user))
    (should (equal (drgnx-pkg-child-elpa root) '("fa-1.0")))))

(ert-deftest drgnx-pkg/a-partly-missing-add-changes-nothing ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fa "1.0") (fd "1.0") (fb "1.0" ((fc "1.0")))))   ; fc: no archive has it
    (drgnx-pkg-child-want root 'fd)
    (should (eql (car (drgnx-pkg-child-run root '("sync"))) 0))
    (let ((tree (drgnx-pkg-child-tree (concat root "data/elpa/"))) (lock (drgnx-pkg-wants-test--lock-bytes root))
          (gens (drgnx-pkg-child-generations root))
          (r (drgnx-pkg-child-run root '("sync" "--add" "fa" "fb"))))
      (should (eql (car r) 1))
      (should (string-match-p "nothing was changed" (cdr r)))
      (should (string-match-p "fb" (cdr r)))
      (should (equal (drgnx-pkg-child-tree (concat root "data/elpa/")) tree))
      (should (equal (drgnx-pkg-wants-test--lock-bytes root) lock))
      (should (equal (drgnx-pkg-child-generations root) gens)))))

(ert-deftest drgnx-pkg/a-wanted-mark-is-in-the-manifest ()
  ;; pure: the lock is written by hand, the manifest read in this Emacs
  (drgnx-pkg-test--with root
    (make-directory (concat root "mods") t)
    (drgnx-pkg-test--write (concat root "config/drgnx.lock.eld")
                           '(:version 1 :packages ((fx :version "1.0" :wanted user) (fy :version "1.0"))))
    (let ((m (drgnx-pkg-manifest (concat root "mods"))))
      (should (memq 'fx m))
      (should-not (memq 'fy m)))))

(ert-deftest drgnx-pkg/an-upgrade-keeps-the-wanted-mark ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))
    (drgnx-pkg-wants-test--archive root '((fa "1.1")))
    (let ((r (drgnx-pkg-child-run root '("upgrade"))))
      (should (eql (car r) 0)))
    (let ((e (alist-get 'fa (drgnx-pkg-child-lock root))))
      (should (equal (plist-get e :version) "1.1"))
      (should (eq (plist-get e :wanted) 'user)))))

;;;; Removal

(ert-deftest drgnx-pkg/remove-refuses-what-a-module-needs ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fm "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-pkg-child-module root 'extra/fm '(fm))
    (should (eql (car (drgnx-pkg-child-run root '("sync"))) 0))
    (let ((tree (drgnx-pkg-child-tree (concat root "data/elpa/"))) (lock (drgnx-pkg-wants-test--lock-bytes root))
          (r (drgnx-pkg-child-run root '("sync" "--remove" "fm"))))
      (should (eql (car r) 1))
      (should (string-match-p "module extra/fm needs it" (cdr r)))
      (should (string-match-p "nothing was changed" (cdr r)))
      (should (equal (drgnx-pkg-child-tree (concat root "data/elpa/")) tree))
      (should (equal (drgnx-pkg-wants-test--lock-bytes root) lock)))))

(ert-deftest drgnx-pkg/remove-takes-only-what-it-alone-needed ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fd "1.0") (fe "1.0") (fa "1.0" ((fd "1.0"))) (fb "1.0" ((fd "1.0") (fe "1.0")))))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa" "fb"))) 0))
    (should (equal (drgnx-pkg-child-elpa root) '("fa-1.0" "fb-1.0" "fd-1.0" "fe-1.0")))
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--remove" "fa"))) 0))
    (should (equal (drgnx-pkg-child-elpa root) '("fb-1.0" "fd-1.0" "fe-1.0")))
    (should (equal (mapcar #'car (drgnx-pkg-child-lock root)) '(fb fd fe)))
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--remove" "fb"))) 0))
    (should-not (drgnx-pkg-child-elpa root))
    (should-not (drgnx-pkg-child-lock root))))

(ert-deftest drgnx-pkg/remove-leaves-hand-installed-packages ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fh "1.0") (fa "1.0" ((fh "1.0")))))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))
    ;; fh as one installed by hand or seeded: its entry has no hash
    (let ((lock (drgnx-pkg-child-lock root)))
      (setf (alist-get 'fh lock) (list :version "1.0" :summary "by hand"))
      (drgnx-pkg-test--write (concat root "config/drgnx.lock.eld") (list :version 1 :packages lock)))
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--remove" "fa"))) 0))
    (should (equal (drgnx-pkg-child-elpa root) '("fh-1.0")))
    (should (equal (mapcar #'car (drgnx-pkg-child-lock root)) '(fh)))))

(ert-deftest drgnx-pkg/remove-snapshots-the-state-before ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--remove" "fa"))) 0))
    (let ((gens (drgnx-pkg-child-generations root)))
      (should (equal (mapcar #'cdr gens) '("remove fa" "before remove fa" "install fa")))
      ;; the state before still holds fa
      (should (file-directory-p (format "%sdata/generations/%d/elpa/fa-1.0" root (car (nth 1 gens))))))))

;;;; The queue

(ert-deftest drgnx-pkg/two-pending-runs-never-take-the-same-entry ()
  ;; handshake: a holds the sync lock with tickets 1 and 2 taken; 3 is queued; b waits for the lock; then both go
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fa "1.0") (fb "1.0") (fc "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (drgnx-pkg-pending-add '(:add fa)) 1))
    (should (eql (drgnx-pkg-pending-add '(:add fb)) 2))
    (let ((a (drgnx-pkg-child-start root '("sync" "--pending" "--wait") '("held"))))
      (drgnx-test-child-await a "held" :secs 300)
      (should (eql (drgnx-pkg-pending-add '(:add fc)) 3))
      (let ((b (drgnx-pkg-child-start root '("sync" "--pending" "--wait") '("wait"))))
        (drgnx-test-child-await b "wait" :secs 300)
        (drgnx-test-child-go b)
        (drgnx-test-child-go a)
        (drgnx-test-wait-ended (list a b) :secs 600 :what "both syncs to end")
        (should (eql (process-exit-status a) 0))
        (should (eql (process-exit-status b) 0))
        (should (equal (drgnx-pkg-wants-test--tickets (process-get a :out)) '(1 2)))
        (should (equal (drgnx-pkg-wants-test--tickets (process-get b :out)) '(3)))
        (should (equal (drgnx-pkg-child-elpa root) '("fa-1.0" "fb-1.0" "fc-1.0")))
        (should (equal (mapcar #'cdr (drgnx-pkg-child-generations root)) '("install fc" "install fa, fb")))))))

(ert-deftest drgnx-pkg/wait-takes-the-lock-when-it-frees ()
  ;; handshake: a holds the sync lock (nothing queued); b, with --wait, announces that it waits, then gets it
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (let ((a (drgnx-pkg-child-start root '("sync" "--pending" "--wait") '("held"))))
      (drgnx-test-child-await a "held" :secs 300)
      (drgnx-pkg-pending-add '(:add fa))
      (let ((b (drgnx-pkg-child-start root '("sync" "--pending" "--wait") '("wait"))))
        (drgnx-test-child-await b "wait" :secs 300)
        (should (file-exists-p (concat root "data/sync.lock")))      ; a holds it still
        (drgnx-test-child-go b)
        (drgnx-test-child-go a)
        (drgnx-test-wait-ended (list a b) :secs 600 :what "both syncs to end")
        (should (string-match-p "nothing queued" (process-get a :out)))
        (should (eql (process-exit-status b) 0))
        (should-not (string-match-p "another drgnx sync" (process-get b :out)))
        (should (equal (drgnx-pkg-child-elpa root) '("fa-1.0")))))))

(ert-deftest drgnx-pkg/pending-cancel-removes-a-queued-entry ()
  ;; pure: the queue file in this Emacs
  (drgnx-pkg-child-with root
    (should (eql (drgnx-pkg-pending-add '(:add fa)) 1))
    (should (eql (drgnx-pkg-pending-add '(:remove fb)) 2))
    (should (drgnx-pkg-pending-cancel 1))
    (should-not (drgnx-pkg-pending-cancel 1))
    (should (equal (drgnx-pkg-pending-take) '((:ticket 2 :remove fb))))
    (should-not (drgnx-pkg-pending-take))))

(ert-deftest drgnx-pkg/tickets-are-never-reused ()
  ;; pure: the queue file in this Emacs
  (drgnx-pkg-child-with root
    (should (equal (drgnx-pkg-pending-file) (concat root "state/drgnx/extensions/pending.eld")))
    (should (eql (drgnx-pkg-pending-add '(:add fa :version "1.0")) 1))
    (should (equal (drgnx-pkg-pending-take) '((:ticket 1 :add fa :version "1.0"))))
    (should (eql (drgnx-pkg-pending-add '(:add fa)) 2))
    (should (eql (drgnx-pkg-pending-cancel 2) t))
    (should (eql (drgnx-pkg-pending-add '(:add fa)) 3))))

(ert-deftest drgnx-pkg/pending-with-an-empty-queue-changes-nothing ()
  ;; handshake: the child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-child-want root)
    (let ((r (drgnx-pkg-child-run root '("sync" "--pending"))))
      (should (eql (car r) 0))
      (should (string-match-p "nothing queued" (cdr r)))
      (should-not (drgnx-pkg-child-generations root)))))

;;;; The shipped lock, rollback, the order of a run

(ert-deftest drgnx-pkg/the-shipped-lock-carries-no-wants ()
  ;; pure: lock --ship in this Emacs
  (drgnx-pkg-test--with root
    (let ((mods (concat root "mods/")))
      (make-directory mods t)
      (write-region "(drgnx-module-define 'x/a :packages '(fa))\n" nil (concat mods "drgnx-x.el") nil 'silent)
      (drgnx-pkg-write-lock '((fa :version "1.0" :archive "fx" :kind single :file "fa-1.0.el" :sha256 "aa" :wanted user)))
      (drgnx-pkg-ship-lock mods)
      (let ((shipped (drgnx-pkg--read-lock-file (drgnx-pkg-shipped-lock-file))))
        (should (equal (mapcar #'car shipped) '(fa)))
        (should (equal (plist-get (alist-get 'fa shipped) :sha256) "aa"))
        (should-not (plist-member (alist-get 'fa shipped) :wanted))))))

(ert-deftest drgnx-pkg/a-rollback-brings-back-its-wants ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fa "1.0") (fb "1.0")))
    (drgnx-pkg-child-want root 'fb)
    (should (eql (car (drgnx-pkg-child-run root '("sync"))) 0))                   ; 1
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))      ; 2
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--remove" "fa"))) 0))   ; 3 before, 4
    (should (equal (mapcar #'car (drgnx-pkg-child-generations root)) '(4 3 2 1)))
    (should-not (assq 'fa (drgnx-pkg-child-lock root)))
    (should (eql (car (drgnx-pkg-child-run root '("rollback" "2"))) 0))
    (ert-info ((format "%S" (drgnx-pkg-child-lock root)) :prefix "the lock: ")
      (should (eq (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :wanted) 'user)))
    (should (equal (drgnx-pkg-child-elpa root) '("fa-1.0" "fb-1.0")))))

(ert-deftest drgnx-pkg/a-stop-during-native-keeps-a-consistent-generation ()
  ;; handshake: the child parks at its first native compilation and is killed there
  (skip-unless (and (fboundp 'native-comp-available-p) (native-comp-available-p)))
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (let ((p (drgnx-pkg-child-start root '("sync" "--add" "fa") '("native") '("DRGNX_TEST_NATIVE=1"))))
      (drgnx-test-child-await p "native" :secs 120)
      (drgnx-test-child-signal p 'KILL)
      (drgnx-test-wait-ended p :secs 60 :what "the killed sync to end"))
    (let* ((gen (car (drgnx-pkg-child-generations root)))
           (gdir (format "%sdata/generations/%d/" root (car gen))))
      (should (equal (cdr gen) "install fa"))
      (should (equal (drgnx-pkg-child-elpa root) '("fa-1.0")))
      (should (equal (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :version) "1.0"))
      (should (eq (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :wanted) 'user))
      (should (equal (drgnx-pkg-test--bytes (concat gdir "drgnx.lock.eld")) (drgnx-pkg-wants-test--lock-bytes root)))
      (should (equal (drgnx-pkg-child-tree (concat gdir "elpa/")) (drgnx-pkg-child-tree (concat root "data/elpa/")))))))

(ert-deftest drgnx-pkg/an-unrelated-missing-package-does-not-block-an-add ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (drgnx-pkg-child-module root 'extra/fz '(fz))                ; the archive dropped fz
    (let ((r (drgnx-pkg-child-run root '("sync" "--add" "fa"))))
      (ert-info ((cdr r) :prefix "sync's output: ")
        (should (eql (car r) 0))
        (should (string-match-p "^MISSING fz" (cdr r)))))
    (should (equal (drgnx-pkg-child-elpa root) '("fa-1.0")))
    (should (eq (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :wanted) 'user))
    (should (equal (mapcar #'cdr (drgnx-pkg-child-generations root)) '("install fa")))))

(ert-deftest drgnx-pkg/add-a-version-installs-that-version ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-wants-test--archive root '((fa "1.0") (fa "1.1")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa@1.0"))) 0))
    (should (equal (drgnx-pkg-child-elpa root) '("fa-1.0")))
    (should (equal (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :version) "1.0"))))

;;; pkg-wants-test.el ends here
