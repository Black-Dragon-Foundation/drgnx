;;; pkg-progress-test.el --- batch children: the progress file, the plan before every swap, upgrades of a few, generations in use -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Each test runs the package CLI as a batch child, as bin/drgnx does, in temp directories (HOME too) against archives
;; that are local directories, and waits for it to exit.  The child logs every step it writes (pkg-child-fixture.el,
;; DRGNX_TEST_STEP_LOG): right after each write it copies the progress file, the plan file and the packages
;; directory's listing into the log, so the test reads what any reader of the file could have read at that step.  The
;; rotation tests are pure, in this Emacs.  See docs/guide/packages.md, "Progress".
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-pkg)
(load (expand-file-name "test/fixtures/pkg-fixture" drgnx-dir) nil t)

(defun drgnx-pkg-progress-test--run (root log &rest args)
  "Run the CLI with ARGS and `--progress ROOT/progress/p.json', logging its steps into ROOT/LOG/: (EXIT . OUTPUT)."
  (drgnx-pkg-child-run root (append args (list "--progress" (concat root "progress/p.json")))
                       (list (concat "DRGNX_TEST_STEP_LOG=" root log))))

(defun drgnx-pkg-progress-test--log (root log)
  "The steps of ROOT/LOG/, in order: ((STEP OBJECT PLAN-FILE ELPA GENERATIONS)…), OBJECT the progress file then (parsed),
PLAN-FILE the plan file then (parsed, or nil), ELPA the packages directory's listing, GENERATIONS the generations."
  (let ((dir (concat root log "/")))
    (mapcar (lambda (f)
              (let ((base (file-name-sans-extension f)))
                (list (intern (replace-regexp-in-string "\\`[0-9]+-" "" (file-name-nondirectory base)))
                      (json-parse-string (drgnx-pkg-test--bytes f) :object-type 'plist :array-type 'list)
                      (and (file-exists-p (concat base ".plan"))
                           (json-parse-string (drgnx-pkg-test--bytes (concat base ".plan")) :object-type 'plist :array-type 'list))
                      (with-temp-buffer (insert-file-contents (concat base ".elpa")) (read (current-buffer)))
                      (with-temp-buffer (insert-file-contents (concat base ".gens")) (read (current-buffer))))))
            (directory-files dir t "\\.json\\'"))))

(defun drgnx-pkg-progress-test--steps (log)
  "The step names of LOG, a run of the same step counted once."
  (let (out) (dolist (e log) (unless (eq (car e) (car out)) (push (car e) out))) (nreverse out)))

(defun drgnx-pkg-progress-test--archive (root packages)
  (drgnx-pkg-test--archive (concat root "arch") packages))

(defun drgnx-pkg-progress-test--plan-file (root)
  (json-parse-string (drgnx-pkg-test--bytes (concat root "progress/p.json.plan.json")) :object-type 'plist :array-type 'list))

;;;; The progress file

(ert-deftest drgnx-pkg/progress-is-always-a-whole-object ()
  ;; handshake: the child is waited for to its exit; its log holds the file as it was at each step
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fa "1.0") (fb "1.0" ((fa "1.0")))))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-progress-test--run root "log" "sync" "--add" "fb")) 0))
    (let ((files (directory-files (concat root "log/") t "\\.json\\'")))
      (should (> (length files) 5))
      (dolist (f files)
        (should (<= (file-attribute-size (file-attributes f)) 1024))
        (should (plist-get (json-parse-string (drgnx-pkg-test--bytes f) :object-type 'plist) :step))))
    (let ((last (json-parse-string (drgnx-pkg-test--bytes (concat root "progress/p.json")) :object-type 'plist :array-type 'list)))
      (should (equal (plist-get last :step) "done"))
      (should (eq (plist-get last :ok) t))
      (should (eql (plist-get last :generation) 1)))
    (should-not (directory-files (concat root "progress/") nil "\\.tmp-"))))

(ert-deftest drgnx-pkg/the-plan-step-comes-before-the-swap ()
  ;; handshake: each child is waited for to its exit; the log shows the plan file and elpa/ at each step
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))           ; generation 1
    (drgnx-pkg-progress-test--archive root '((fa "1.1")))
    (let ((runs `(("sync" "--add" "fb") ("upgrade") ("rollback" "1")))
          (n 0))
      (drgnx-pkg-progress-test--archive root '((fa "1.1") (fb "1.0")))
      (dolist (args runs)
        (let ((before (drgnx-pkg-child-elpa root)) (log (format "log%d" (cl-incf n))))
          (should (eql (car (apply #'drgnx-pkg-progress-test--run root log args)) 0))
          (let* ((steps (drgnx-pkg-progress-test--log root log))
                 (plan (seq-find (lambda (e) (eq (car e) 'plan)) steps))
                 (swap (seq-find (lambda (e) (eq (car e) 'swap)) steps)))
            (should plan)
            (should swap)
            (should (< (seq-position steps plan) (seq-position steps swap)))
            (should (equal (nth 3 plan) before))                             ; the plan comes while elpa/ is as it was
            (should (equal (plist-get (nth 2 plan) :seq) 1))                 ; and its file is there already
            (should (equal (plist-get (nth 2 swap) :seq) (plist-get (nth 1 plan) :seq)))))))
    ;; an upgrade whose smoke test fails: its restore swaps again, after a second plan
    (drgnx-pkg-progress-test--archive root '((fa "2.0" nil "(error \"fa 2.0 is broken\")") (fb "1.0")))
    (should (eql (car (drgnx-pkg-progress-test--run root "log9" "upgrade")) 1))
    (let* ((steps (drgnx-pkg-progress-test--log root "log9"))
           (order (delq nil (mapcar (lambda (e) (and (memq (car e) '(plan swap)) (list (car e) (plist-get (nth 2 e) :seq))))
                                    steps))))
      (should (equal (seq-uniq order) '((plan 1) (swap 1) (plan 2) (swap 2)))))))

(ert-deftest drgnx-pkg/the-plan-file-outlives-later-steps ()
  ;; handshake: the child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-progress-test--run root "log1" "sync" "--add" "fa")) 0))
    (let ((plan (drgnx-pkg-progress-test--plan-file root)))
      (should (equal (plist-get plan :step) "plan"))
      (should (equal (plist-get plan :adds) '("fa-1.0"))))
    (drgnx-pkg-progress-test--archive root '((fa "2.0" nil "(error \"fa 2.0 is broken\")")))
    (should (eql (car (drgnx-pkg-progress-test--run root "log2" "upgrade")) 1))
    (let ((plan (drgnx-pkg-progress-test--plan-file root))
          (done (json-parse-string (drgnx-pkg-test--bytes (concat root "progress/p.json")) :object-type 'plist)))
      (should (equal (plist-get done :step) "done"))
      (should (eq (plist-get done :ok) :false))
      (should (eql (plist-get plan :seq) 2))                                 ; the restore's
      (should (equal (plist-get plan :replaces) '("fa-2.0"))))))

(ert-deftest drgnx-pkg/native-comes-after-lock-and-snapshot ()
  ;; handshake: the child is waited for to its exit
  (skip-unless (and (fboundp 'native-comp-available-p) (native-comp-available-p)))
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root (list "sync" "--add" "fa" "--progress" (concat root "progress/p.json"))
                                           (list (concat "DRGNX_TEST_STEP_LOG=" root "log") "DRGNX_TEST_NATIVE=1")))
                 0))
    (let ((steps (drgnx-pkg-progress-test--log root "log")))
      (should (equal (drgnx-pkg-progress-test--steps steps) '(start plan download unpack byte swap lock native done)))
      (let ((native (seq-find (lambda (e) (eq (car e) 'native)) steps)))
        (should (equal (nth 4 native) '(1)))                                 ; the generation is there before native code
        (should (equal (plist-get (nth 1 native) :pkg) "fa-1.0"))
        (should (eql (plist-get (nth 1 native) :i) 1))
        (should (eql (plist-get (nth 1 native) :n) 1))))))

(ert-deftest drgnx-pkg/plan-names-what-is-replaced ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fa "1.0") (fb "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa" "fb"))) 0))   ; generation 1
    (drgnx-pkg-progress-test--archive root '((fa "1.1") (fb "1.0")))
    (should (eql (car (drgnx-pkg-progress-test--run root "log1" "upgrade")) 0))
    (let ((plan (drgnx-pkg-progress-test--plan-file root)))
      (should (equal (plist-get plan :replaces) '("fa-1.0")))
      (should (equal (plist-get plan :removes) nil))
      (should (eql (plist-get plan :generation) 2)))                         ; the snapshot before the upgrade
    (should (eql (car (drgnx-pkg-progress-test--run root "log2" "sync" "--remove" "fb")) 0))
    (let ((plan (drgnx-pkg-progress-test--plan-file root)))
      (should (equal (plist-get plan :removes) '("fb-1.0")))
      (should (equal (plist-get plan :replaces) nil)))))

;;;; Upgrades of a few, staged

(ert-deftest drgnx-pkg/upgrade-only-leaves-the-rest-pinned ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fa "1.0") (fc "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa" "fc"))) 0))
    (let ((fc (alist-get 'fc (drgnx-pkg-child-lock root))))
      (drgnx-pkg-progress-test--archive root '((fa "1.1") (fc "1.1")))
      (should (eql (car (drgnx-pkg-child-run root '("upgrade" "--only" "fa"))) 0))
      (should (equal (drgnx-pkg-child-elpa root) '("fa-1.1" "fc-1.0")))
      (should (equal (alist-get 'fc (drgnx-pkg-child-lock root)) fc))
      (should (eq (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :wanted) 'user)))))

(ert-deftest drgnx-pkg/upgrade-only-takes-a-needed-dependency ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fd "1.0") (fa "1.0" ((fd "1.0")))))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))
    (drgnx-pkg-progress-test--archive root '((fd "2.0") (fa "1.1" ((fd "2.0")))))
    (should (eql (car (drgnx-pkg-progress-test--run root "log" "upgrade" "--only" "fa")) 0))
    (should (equal (drgnx-pkg-child-elpa root) '("fa-1.1" "fd-2.0")))
    (should (equal (sort (plist-get (drgnx-pkg-progress-test--plan-file root) :replaces) #'string<) '("fa-1.0" "fd-1.0")))))

(ert-deftest drgnx-pkg/stage-changes-nothing-and-staged-installs-it ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))
    (drgnx-pkg-progress-test--archive root '((fa "1.1")))
    (let ((tree (drgnx-pkg-child-tree (concat root "data/elpa/")))
          (lock (drgnx-pkg-test--bytes (concat root "config/drgnx.lock.eld")))
          (gens (drgnx-pkg-child-generations root))
          (sha (secure-hash 'sha256 (drgnx-pkg-test--bytes (concat root "arch/fa-1.1.el")))))
      (should (eql (car (drgnx-pkg-child-run root '("upgrade" "--only" "fa" "--stage"))) 0))
      (should (equal (drgnx-pkg-child-tree (concat root "data/elpa/")) tree))
      (should (equal (drgnx-pkg-test--bytes (concat root "config/drgnx.lock.eld")) lock))
      (should (equal (drgnx-pkg-child-generations root) gens))
      (let ((staged (with-temp-buffer (insert-file-contents (concat root "state/drgnx/extensions/staged.eld"))
                                      (read (current-buffer)))))
        (should (equal (plist-get (alist-get 'fa staged) :version) "1.1"))
        (should (equal (plist-get (alist-get 'fa staged) :sha256) sha)))
      (should (eql (car (drgnx-pkg-child-run root '("upgrade" "--staged"))) 0))
      (should (equal (drgnx-pkg-child-elpa root) '("fa-1.1")))
      (should (equal (plist-get (alist-get 'fa (drgnx-pkg-child-lock root)) :sha256) sha)))))

(ert-deftest drgnx-pkg/staged-refuses-a-changed-file ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))
    (drgnx-pkg-progress-test--archive root '((fa "1.1")))
    (should (eql (car (drgnx-pkg-child-run root '("upgrade" "--only" "fa" "--stage"))) 0))
    (write-region "(error \"changed after review\")\n" nil (concat root "cache/drgnx/packages/fa-1.1.el") nil 'silent)
    (let ((tree (drgnx-pkg-child-tree (concat root "data/elpa/")))
          (lock (drgnx-pkg-test--bytes (concat root "config/drgnx.lock.eld")))
          (r (drgnx-pkg-child-run root '("upgrade" "--staged"))))
      (should (eql (car r) 1))
      (should (string-match-p "sha256" (cdr r)))
      (should (equal (drgnx-pkg-child-tree (concat root "data/elpa/")) tree))
      (should (equal (drgnx-pkg-test--bytes (concat root "config/drgnx.lock.eld")) lock)))))

;;;; Generations a running drgnx uses

(defun drgnx-pkg-progress-test--in-use (pid start generations)
  (drgnx-pkg-test--write (expand-file-name (format "%d.eld" pid) (drgnx-pkg-in-use-dir))
                         (list :pid pid :start start :generations generations)))

(ert-deftest drgnx-pkg/rotation-keeps-a-live-sessions-generation ()
  ;; pure: the snapshots and the in-use file in this Emacs, whose own pid and start make the stamp live
  (drgnx-pkg-test--with root
    (should (eql (drgnx-pkg-snapshot "one") 1))
    (drgnx-pkg-progress-test--in-use (emacs-pid) (float-time (alist-get 'start (process-attributes (emacs-pid)))) '(1))
    (dotimes (_ 6) (drgnx-pkg-snapshot))
    (should (equal (mapcar #'car (drgnx-pkg-generations)) '(7 6 5 4 3 1)))
    (should (equal (drgnx-pkg-generations-in-use) '(1)))
    (should (file-exists-p (expand-file-name (format "%d.eld" (emacs-pid)) (drgnx-pkg-in-use-dir))))))

(ert-deftest drgnx-pkg/a-dead-sessions-generation-goes ()
  ;; pure: an in-use file whose pid is no process
  (drgnx-pkg-test--with root
    (should (eql (drgnx-pkg-snapshot "one") 1))
    (drgnx-pkg-progress-test--in-use 999999999 1.0 '(1))
    (dotimes (_ 4) (drgnx-pkg-snapshot))
    (should (equal (mapcar #'car (drgnx-pkg-generations)) '(5 4 3 2 1)))
    (drgnx-pkg-snapshot)                                                     ; the next rotation
    (should (equal (mapcar #'car (drgnx-pkg-generations)) '(6 5 4 3 2)))
    (should-not (file-exists-p (expand-file-name "999999999.eld" (drgnx-pkg-in-use-dir))))))

;;;; After a change

(ert-deftest drgnx-pkg/upgrade-and-rollback-write-the-settings-index ()
  ;; handshake: each child is waited for to its exit; the index is backdated before each, so its time moves
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fa "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))
    (let ((index (concat root "cache/drgnx/settings-index.eld")))
      (should (file-exists-p index))
      (drgnx-pkg-progress-test--archive root '((fa "1.1")))
      (dolist (args '(("upgrade") ("rollback" "1")))
        (set-file-times index (seconds-to-time 1000))
        (should (eql (car (drgnx-pkg-child-run root args)) 0))
        (should (time-less-p (seconds-to-time 100000) (file-attribute-modification-time (file-attributes index))))))))

(ert-deftest drgnx-pkg/generation-notes-name-the-change ()
  ;; handshake: each child is waited for to its exit
  (drgnx-pkg-child-with root
    (drgnx-pkg-progress-test--archive root '((fa "1.0") (fb "1.0")))
    (drgnx-pkg-child-want root)
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fa"))) 0))
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--add" "fb"))) 0))
    (drgnx-pkg-progress-test--archive root '((fa "1.1") (fb "1.0")))
    (should (eql (car (drgnx-pkg-child-run root '("upgrade" "--only" "fa"))) 0))
    (should (eql (car (drgnx-pkg-child-run root '("sync" "--remove" "fb"))) 0))
    (should (equal (mapcar #'cdr (drgnx-pkg-child-generations root))
                   '("remove fb" "before remove fb" "update fa" "before upgrade" "install fb")))))

;;; pkg-progress-test.el ends here
