;;; git-fsmonitor-test.el --- the offer of git's untracked cache and file system monitor -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): a fixture index header on disk, git's answers and the notice stubbed.  No process.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-git)

(defun drgnx-git-fsmonitor-test--repo (entries)
  "A temp directory with a .git/index whose header says ENTRIES entries (12 bytes: DIRC, version 2, the count)."
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-fsm" t)))
         (git (expand-file-name ".git" root)))
    (make-directory git)
    (let ((coding-system-for-write 'no-conversion))
      (with-temp-file (expand-file-name "index" git)
        (set-buffer-multibyte nil)
        (insert "DIRC" (unibyte-string 0 0 0 2 (ash entries -24) (logand (ash entries -16) 255)
                                       (logand (ash entries -8) 255) (logand entries 255)))))
    root))

(defmacro drgnx-git-fsmonitor-test--offer (root-var entries config daemon &rest body)
  "BODY with ROOT-VAR a repository of ENTRIES entries whose git config is the alist CONFIG, DAEMON the answer of the
monitor check; NOTICES holds what was posted (newest first) and ASKED how often git was asked."
  (declare (indent 4))
  `(let* ((,root-var (drgnx-git-fsmonitor-test--repo ,entries)) (notices nil) (asked 0) (drgnx-git--offered nil))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-git--config) (lambda (_r key) (cl-incf asked) (cdr (assoc key ,config))))
                   ((symbol-function 'drgnx-git--daemon-p) (lambda (_r) ,daemon))
                   ((symbol-function 'drgnx-notify) (lambda (&rest a) (push a notices))))
           ,@body)
       (delete-directory ,root-var t))))

(ert-deftest drgnx-git/fsmonitor-offer-large-repo ()
  "Pattern D: over 50,000 index entries a notice offers the untracked cache and, where git has the monitor, fsmonitor;
a small repository, and one that has both, get none; the offer comes once; its action is a command, not a prompt."
  ;; the header: 12 bytes, big-endian count at 8..11
  (let ((root (drgnx-git-fsmonitor-test--repo 50001)))
    (unwind-protect
        (progn (should (= (drgnx-git--index-entries root) 50001))
               (should (= (drgnx-git--index-entries (drgnx-git-fsmonitor-test--repo 3)) 3))
               (should (= (drgnx-git--index-entries (drgnx-git-fsmonitor-test--repo #x01020304)) #x01020304)))
      (delete-directory root t)))
  (should-not (drgnx-git--index-entries (make-temp-file "drgnx-fsm-none" t)))
  ;; large, nothing set, a monitor: both
  (drgnx-git-fsmonitor-test--offer root 50001 nil t
    (drgnx-git--offer root)
    (should (= (length notices) 1))
    (let ((n (car notices)))
      (should (eq (nth 0 n) 'wb))
      (should (equal (plist-get (nthcdr 3 n) :command) (list 'drgnx-git-enable-speedups root t t)))
      (should (string-search "core.fsmonitor" (plist-get (nthcdr 3 n) :fix)))
      (should (string-search "core.untrackedCache" (plist-get (nthcdr 3 n) :fix))))
    (drgnx-git--offer root)                                       ; once per repository
    (should (= (length notices) 1)))
  ;; no monitor on this platform: only the untracked cache
  (drgnx-git-fsmonitor-test--offer root 60000 nil nil
    (drgnx-git--offer root)
    (should (equal (plist-get (nthcdr 3 (car notices)) :command) (list 'drgnx-git-enable-speedups root t nil)))
    (should-not (string-search "fsmonitor" (plist-get (nthcdr 3 (car notices)) :fix))))
  ;; the cache is on already: only fsmonitor
  (drgnx-git-fsmonitor-test--offer root 60000 '(("core.untrackedCache" . "true")) t
    (drgnx-git--offer root)
    (should (equal (plist-get (nthcdr 3 (car notices)) :command) (list 'drgnx-git-enable-speedups root nil t))))
  ;; both on: nothing to offer
  (drgnx-git-fsmonitor-test--offer root 60000 '(("core.untrackedCache" . "true") ("core.fsmonitor" . "true")) t
    (drgnx-git--offer root)
    (should-not notices))
  ;; small repository: not offered, and git is never asked
  (drgnx-git-fsmonitor-test--offer root 50000 nil t
    (drgnx-git--offer root)
    (should-not notices)
    (should (= asked 0))
    (should-not drgnx-git--offered)))

(ert-deftest drgnx-git/fsmonitor-offer-reads-a-worktree-index ()
  "Pattern D: a .git file (a worktree) points at the git directory whose index counts."
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-fsm-wt" t)))
         (real (drgnx-git-fsmonitor-test--repo 70000)))
    (unwind-protect
        (progn (with-temp-file (expand-file-name ".git" root)
                 (insert "gitdir: " (expand-file-name ".git" real) "\n"))
               (should (= (drgnx-git--index-entries root) 70000)))
      (delete-directory root t)
      (delete-directory real t))))

(ert-deftest drgnx-git/enable-speedups-sets-only-what-was-offered ()
  "Pattern D: the action sets the offered keys to true and says so; it asks nothing."
  (let (calls notices)
    (cl-letf (((symbol-function 'call-process) (lambda (_p _i _d _x &rest args) (push args calls) 0))
              ((symbol-function 'drgnx-notify) (lambda (&rest a) (push a notices))))
      (drgnx-git-enable-speedups "/r/" t nil)
      (should (equal (nreverse calls) '(("-C" "/r/" "config" "core.untrackedCache" "true"))))
      (setq calls nil)
      (drgnx-git-enable-speedups "/r/" nil t)
      (should (equal (nreverse calls) '(("-C" "/r/" "config" "core.fsmonitor" "true"))))
      (should (= (length notices) 2)))))
