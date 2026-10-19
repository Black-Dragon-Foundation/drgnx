;;; portable-test.el --- batch tests: what travels to a second machine and what stays -*- lexical-binding: t -*-
;; Every test runs in a temp HOME with its own config, data and state dirs: never ~, ~/.config or the keyring.
;; Test keys are built at run time, never written literally (the pre-commit hook rejects them).
(require 'ert)
(require 'drgnx-portable)
(require 'drgnx-projects)
(require 'drgnx-doctor)
(require 'drgnx-onboard)
(require 'drgnx-acp)

(defmacro drgnx-portable-test--with (root &rest body)
  "BODY with ROOT a temp dir holding home/, config/, data/, state/ and org/ (HOME and drgnx's dirs set to them)."
  (declare (indent 1))
  `(let* ((,root (file-name-as-directory (make-temp-file "drgnx-portable" t)))
          (process-environment (append (list (concat "HOME=" ,root "home")
                                             "SHELL=/bin/sh" ; step 7 asks nothing about the shell here
                                             (concat "DRGNX_CONFIG_DIR=" ,root "config")
                                             (concat "DRGNX_DATA_DIR=" ,root "data")
                                             (concat "XDG_STATE_HOME=" ,root "state"))
                                       process-environment))
          (drgnx-projects-board-file (concat ,root "org/board.org"))
          (drgnx-modules--state nil))
     (dolist (d '("home" "config")) (make-directory (concat ,root d) t))
     (unwind-protect (progn ,@body) (delete-directory ,root t))))

(defun drgnx-portable-test--write (file text)
  (make-directory (file-name-directory file) t)
  (write-region text nil file nil 'silent))

(defun drgnx-portable-test--text (file) (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun drgnx-portable-test--key ()
  "An OpenRouter-shaped key, built here so no key is ever in a file of this repository."
  (concat "sk-or-v1-" (make-string 24 ?x)))

;;;; ~/ paths

(ert-deftest drgnx-portable/paths-under-home-are-tilde ()
  (drgnx-portable-test--with root
    (let ((home (concat root "home")))
      (should (equal (drgnx-portable-path (concat home "/ws/alpha")) "~/ws/alpha"))
      (should (equal (drgnx-portable-path (concat home "/ws/alpha/")) "~/ws/alpha/"))
      (should (equal (drgnx-portable-path (concat home "/My Projects/café")) "~/My Projects/café"))
      (should (equal (drgnx-portable-path "~/ws/beta") "~/ws/beta"))
      (should (equal (drgnx-portable-path home) "~")))))

(ert-deftest drgnx-portable/home-behind-a-symlink ()
  ;; Silverblue: /home/u is /var/home/u.  HOME is the link; a file named through either spelling is ~/….
  (drgnx-portable-test--with root
    (let ((real (concat root "var/home/u")) (link (concat root "linked-home")))
      (make-directory real t)
      (make-symbolic-link real link)
      (let ((process-environment (cons (concat "HOME=" link) process-environment)))
        (should (equal (drgnx-portable-path (concat link "/ws/alpha")) "~/ws/alpha"))
        (should (equal (drgnx-portable-path (concat real "/ws/alpha")) "~/ws/alpha")))
      ;; and the other way round: HOME is the real directory, the file is named through the link
      (let ((process-environment (cons (concat "HOME=" real) process-environment)))
        (should (equal (drgnx-portable-path (concat link "/ws/alpha")) "~/ws/alpha"))))))

(ert-deftest drgnx-portable/outside-home-stays-absolute ()
  (drgnx-portable-test--with root
    (should (equal (drgnx-portable-path "/opt/tools/x") "/opt/tools/x"))
    ;; a sibling whose name starts like home's is not under home
    (should (equal (drgnx-portable-path (concat root "home-other/x")) (concat root "home-other/x")))
    (let ((default-directory "/opt/"))
      (should (equal (drgnx-portable-path "rel/x") "/opt/rel/x")))
    ;; HOME=/ (some containers): nothing becomes ~/
    (let ((process-environment (cons "HOME=/" process-environment)))
      (should (equal (drgnx-portable-path "/opt/x") "/opt/x")))))

;;;; projects.eld

(ert-deftest drgnx-portable/projects-written-tilde-read-absolute ()
  (drgnx-portable-test--with root
    (let ((alpha (concat root "home/ws/alpha")))
      (make-directory alpha t)
      (let ((default-directory (file-name-as-directory alpha))) (call-process "git" nil nil nil "init" "-q"))
      (drgnx-projects-import (list alpha) :todos nil)
      (let ((text (drgnx-portable-test--text (drgnx-projects-file))))
        (should (string-search ":root \"~/ws/alpha\"" text))
        (should-not (string-search root text)))
      (should (equal (mapcar (lambda (p) (plist-get p :root)) (plist-get (drgnx-projects-read) :projects))
                     (list alpha)))
      ;; again: nothing is added
      (let ((before (drgnx-portable-test--text (drgnx-projects-file))))
        (drgnx-projects-import (list alpha) :todos nil)
        (should (equal (drgnx-portable-test--text (drgnx-projects-file)) before))))))

;;;; Machine-local files

(ert-deftest drgnx-portable/machine-local-items-move ()
  (drgnx-portable-test--with root
    (let ((config (drgnx-user-dir)) (data (drgnx-data-dir)))
      (drgnx-portable-test--write (expand-file-name "emacs" config) "/usr/bin/emacs\n")
      (drgnx-portable-test--write (expand-file-name "systemd/drgnx.service" config) "[Unit]\n")
      (drgnx-portable-test--write (expand-file-name "keys.eld" config) "(:profile vscode)\n")
      (should (equal (drgnx-portable-move-machine-local) '(("emacs" . moved) ("systemd/" . moved))))
      (should-not (file-exists-p (expand-file-name "emacs" config)))
      (should-not (file-exists-p (expand-file-name "systemd" config)))
      (should (file-exists-p (expand-file-name "keys.eld" config)))               ; portable: stays
      (should (equal (drgnx-portable-test--text (expand-file-name "emacs" data)) "/usr/bin/emacs\n"))
      (should (equal (drgnx-portable-test--text (expand-file-name "systemd/drgnx.service" data)) "[Unit]\n"))
      ;; an identical copy is in the data dir already: the config dir's is dropped
      (drgnx-portable-test--write (expand-file-name "emacs" config) "/usr/bin/emacs\n")
      (should (equal (drgnx-portable-move-machine-local) '(("emacs" . dropped))))
      (should-not (file-exists-p (expand-file-name "emacs" config)))
      ;; a different one: both are left as they are
      (drgnx-portable-test--write (expand-file-name "applications/drgnx.desktop" config) "mine\n")
      (drgnx-portable-test--write (expand-file-name "applications/drgnx.desktop" data) "theirs\n")
      (drgnx-portable-test--write (expand-file-name "emacs" config) "/opt/emacs\n")
      (should (equal (drgnx-portable-move-machine-local) '(("emacs" . kept) ("applications/" . kept))))
      (should (equal (drgnx-portable-test--text (expand-file-name "applications/drgnx.desktop" config)) "mine\n"))
      (should (equal (drgnx-portable-test--text (expand-file-name "applications/drgnx.desktop" data)) "theirs\n"))
      (should (equal (drgnx-portable-test--text (expand-file-name "emacs" config)) "/opt/emacs\n"))
      (should (equal (drgnx-portable-test--text (expand-file-name "emacs" data)) "/usr/bin/emacs\n"))
      ;; nothing there: nothing to say
      (delete-file (expand-file-name "emacs" config))
      (delete-directory (expand-file-name "applications" config) t)
      (should-not (drgnx-portable-move-machine-local)))))

;;;; The doctor's portable-config check

(ert-deftest drgnx-portable/a-plain-key-is-found-by-file-not-by-value ()
  (drgnx-portable-test--with root
    (let* ((config (drgnx-user-dir)) (key (drgnx-portable-test--key)))
      (drgnx-portable-test--write (expand-file-name "config.el" config) (format "(setenv \"OPENROUTER_API_KEY\" %S)\n" key))
      (drgnx-portable-test--write (expand-file-name "keys.eld" config) "(:profile vscode)\n")
      (drgnx-portable-test--write (expand-file-name "secrets.age" config) key)          ; ciphertext's place: not read
      (drgnx-portable-test--write (expand-file-name ".git/COMMIT_EDITMSG" config) key)  ; the repo's own files: not read
      (drgnx-portable-test--write (expand-file-name "lisp/.env" config) "X=1\n")       ; a secret by its name
      (let ((problems (drgnx-portable-config-problems)))
        (should (equal (plist-get problems :keys) '("config.el" "lisp/.env")))
        (should-not (string-search key (format "%S" problems))))
      (let* ((facts (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts)))
             (r (drgnx-doctor-check 'portable-config facts)))
        (should (eq (car r) 'warn))
        (should (string-search "config.el" (nth 1 r)))
        (should (string-search "keyring" (nth 2 r)))
        (should-not (string-search key (format "%S" r)))
        (should-not (string-search key (format "%S" facts)))))))

(ert-deftest drgnx-portable/machine-local-files-are-a-warning ()
  (drgnx-portable-test--with root
    (drgnx-portable-test--write (expand-file-name "emacs" (drgnx-user-dir)) "/usr/bin/emacs\n")
    (should (equal (plist-get (drgnx-portable-config-problems) :machine-local) '("emacs")))
    (let ((r (drgnx-doctor-check 'portable-config (list :portable (drgnx-portable-config-problems)))))
      (should (eq (car r) 'warn))
      (should (string-search "emacs" (nth 1 r)))
      (should (string-search "drgnx bootstrap --step config" (nth 2 r))))))

(ert-deftest drgnx-portable/missing-roots-are-info ()
  (drgnx-portable-test--with root
    (make-directory (concat root "home/ws/here") t)
    (drgnx-portable-test--write (drgnx-projects-file)
                                (format "%S" '(:version 1 :projects ((:name "here" :root "~/ws/here")
                                                                     (:name "gone" :root "~/ws/gone")))))
    (should (equal (plist-get (drgnx-portable-config-problems) :missing-roots) '("~/ws/gone")))
    (let ((r (drgnx-doctor-check 'portable-config (list :portable (drgnx-portable-config-problems)))))
      (should (eq (car r) 'info))
      (should (string-search "not cloned on this machine: ~/ws/gone" (nth 1 r))))
    (delete-file (drgnx-projects-file))
    (should (eq (car (drgnx-doctor-check 'portable-config (list :portable (drgnx-portable-config-problems)))) 'ok))))

;;;; Onboarding step 7 and agent commands

(ert-deftest drgnx-onboard/desktop-files-are-machine-local ()
  (drgnx-portable-test--with root
    (let ((r (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
               (car (drgnx-onboard-run :only '(daemon) :non-interactive t)))))
      (should (eq (cadr r) 'info))
      (should (file-exists-p (expand-file-name "systemd/drgnx.service" (drgnx-data-dir))))
      (should (file-exists-p (expand-file-name "applications/drgnx.desktop" (drgnx-data-dir))))
      (should-not (file-exists-p (expand-file-name "systemd" (drgnx-user-dir))))
      (should-not (file-exists-p (expand-file-name "applications" (drgnx-user-dir))))
      (should-not (plist-get (drgnx-portable-config-problems) :machine-local)))))

(ert-deftest drgnx-acp/a-tilde-command-starts ()
  (skip-unless (file-readable-p "/proc/self/fd/0"))
  (drgnx-portable-test--with root
    (let ((fake (concat root "home/bin/fake-acp")))
      (drgnx-portable-test--write fake (format "#!/bin/sh\nexec %s --batch -Q -l %s\n"
                                               (shell-quote-argument (expand-file-name invocation-name invocation-directory))
                                               (shell-quote-argument (expand-file-name "test/fixtures/mock-acp.el" drgnx-dir))))
      (set-file-modes fake #o755)
      (let ((conn (drgnx-acp-start '("~/bin/fake-acp"))) r)
        (unwind-protect
            (progn
              (drgnx-acp-request conn "initialize" '(:protocolVersion 1) (lambda (res) (setq r res)))
              (let ((deadline (+ (float-time) 10)))
                (while (and (not r) (< (float-time) deadline)) (accept-process-output nil 0.02)))
              (should (eql (plist-get (car r) :protocolVersion) 1)))
          (drgnx-acp-stop conn))))))

;;;; Fix round 1

(ert-deftest drgnx-portable/an-unreadable-directory-is-never-ok ()
  ;; A directory the scan cannot enter is skipped and named; the doctor never says the config dir can travel then.
  (skip-when (zerop (user-uid)))                                       ; root reads it anyway
  (drgnx-portable-test--with root
    (let* ((config (drgnx-user-dir)) (private (expand-file-name "lisp/private" config)))
      (drgnx-portable-test--write (expand-file-name "config.el" config) (format "%S\n" (drgnx-portable-test--key)))
      (drgnx-portable-test--write (expand-file-name "inner.el" private) "nothing\n")
      (drgnx-portable-test--write (expand-file-name "locked.el" config) "nothing\n")
      (set-file-modes private #o000)
      (set-file-modes (expand-file-name "locked.el" config) #o000)
      (unwind-protect
          (let ((facts (lambda () (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts)))))
            (let ((p (drgnx-portable-config-problems)))
              (should (equal (plist-get p :keys) '("config.el")))
              (should (equal (plist-get p :unchecked) '("lisp/private/" "locked.el"))))
            (should (eq (car (drgnx-doctor-check 'portable-config (funcall facts))) 'warn))
            ;; without the key: info, naming what was not checked
            (delete-file (expand-file-name "config.el" config))
            (let ((r (drgnx-doctor-check 'portable-config (funcall facts))))
              (should (eq (car r) 'info))
              (should (string-search "could not check 2 files: lisp/private/, locked.el" (nth 1 r))))
            ;; the scan itself failing: info with the reason, never ok
            (let ((r (drgnx-doctor-check 'portable-config
                                         (cl-letf (((symbol-function 'drgnx-portable-config-problems)
                                                    (lambda () (error "boom")))
                                                   ((symbol-function 'drgnx-doctor--search) #'ignore))
                                           (drgnx-doctor-facts)))))
              (should (eq (car r) 'info))
              (should (string-search "could not check the config dir: boom" (nth 1 r)))))
        (set-file-modes private #o755)
        (set-file-modes (expand-file-name "locked.el" config) #o644)))))

(ert-deftest drgnx-portable/a-root-under-a-linked-home-is-remembered-once ()
  ;; gryphn's projects.tsv may spell a root through a link to home (/home/u when HOME is /var/home/u)
  (drgnx-portable-test--with root
    (let* ((real (concat root "home")) (link (concat root "linked-home")) (alpha (concat real "/ws/alpha")))
      (make-symbolic-link real link)
      (make-directory alpha t)
      (let ((default-directory (file-name-as-directory alpha))) (call-process "git" nil nil nil "init" "-q"))
      (dolist (spelling (list (concat link "/ws/alpha") (concat link "/ws/alpha") alpha))
        (drgnx-projects-import (list spelling) :todos nil))
      (should (= 1 (length (plist-get (drgnx-projects-read) :projects))))
      (should (string-search ":root \"~/ws/alpha\"" (drgnx-portable-test--text (drgnx-projects-file)))))))

(defconst drgnx-portable-test--keys
  (list (concat "sk-proj-" (make-string 24 ?x)) (concat "sk-svcacct-" (make-string 24 ?x))
        (concat "sk-admin-" (make-string 24 ?x)) (concat "github_pat_" (make-string 30 ?x))
        (concat "xsk-or-v1-" (make-string 24 ?x)) (concat "KEY_sk-ant-" (make-string 24 ?x)))
  "Keys of today's formats, and keys after a word character.  Built here: no key is in a file of the repository.")

(ert-deftest drgnx-portable/todays-key-formats-are-found ()
  (drgnx-portable-test--with root
    (let ((config (drgnx-user-dir)) (n 0))
      (dolist (k drgnx-portable-test--keys)
        (drgnx-portable-test--write (expand-file-name (format "k%d.el" (cl-incf n)) config) (format "(setq k %S)\n" k)))
      ;; no false positives: words ending in "sk", hashes, long command names
      (drgnx-portable-test--write (expand-file-name "fine.eld" config)
                                  (format "(:task %S :id %S :cmd \"desk-admin-panel-component-name\")\n"
                                          (concat "task-" (make-string 40 ?a)) (concat "mask-" (make-string 32 ?b))))
      (should (equal (plist-get (drgnx-portable-config-problems) :keys)
                     (cl-loop for i from 1 to (length drgnx-portable-test--keys) collect (format "k%d.el" i)))))))

(ert-deftest drgnx-portable/the-pre-commit-hook-knows-the-new-formats ()
  ;; The hook (the CI leak scan, --all) refuses each of today's formats too.
  (skip-unless (executable-find "git"))
  (let ((repo (make-temp-file "drgnx-hook" t)) (hook (expand-file-name ".githooks/pre-commit" drgnx-dir)))
    (unwind-protect
        (let ((default-directory (file-name-as-directory repo)))
          (call-process "git" nil nil nil "init" "-q")
          (dolist (k (seq-take drgnx-portable-test--keys 4))
            (write-region (concat "x = " k "\n") nil "f.txt")
            (call-process "git" nil nil nil "add" "f.txt")
            (should (= 1 (call-process "bash" nil nil nil hook "--all"))))
          (write-region "x = 1\n" nil "f.txt")
          (call-process "git" nil nil nil "add" "f.txt")
          (should (= 0 (call-process "bash" nil nil nil hook "--all"))))
      (delete-directory repo t))))

(ert-deftest drgnx-portable/a-linked-item-moves-and-its-target-stays ()
  (drgnx-portable-test--with root
    (let ((units (concat root "elsewhere/units")) (link (expand-file-name "systemd" (drgnx-user-dir))))
      (drgnx-portable-test--write (expand-file-name "drgnx.service" units) "[Unit]\n")
      (make-symbolic-link units link)
      (should (equal (drgnx-portable-move-machine-local) '(("systemd/" . moved))))
      (should-not (file-symlink-p link))
      (should (file-exists-p (expand-file-name "drgnx.service" units)))
      (should (file-exists-p (expand-file-name "systemd/drgnx.service" (drgnx-data-dir))))
      ;; again, with the same files in the data dir: the link goes, its target stays
      (make-symbolic-link units link)
      (should (equal (drgnx-portable-move-machine-local) '(("systemd/" . dropped))))
      (should-not (file-symlink-p link))
      (should (file-exists-p (expand-file-name "drgnx.service" units))))))

(ert-deftest drgnx-portable/an-item-in-both-places-says-what-to-do ()
  (drgnx-portable-test--with root
    (drgnx-portable-test--write (expand-file-name "emacs" (drgnx-user-dir)) "/opt/old-emacs\n")
    (drgnx-portable-test--write (expand-file-name "emacs" (drgnx-data-dir)) "/usr/bin/emacs\n")
    (should (equal (plist-get (drgnx-portable-config-problems) :in-both) '("emacs")))
    (let ((r (drgnx-doctor-check 'portable-config (list :portable (drgnx-portable-config-problems)))))
      (should (eq (car r) 'warn))
      (should (string-search "emacs has its own copy in the data dir, which drgnx uses: compare them, then delete the config dir's"
                             (nth 2 r))))))

(ert-deftest drgnx-portable/an-empty-data-dir-variable-is-unset ()
  ;; bash's ${XDG_DATA_HOME:-…} treats empty as unset; so does drgnx-data-dir, or the two would pick different dirs
  (drgnx-portable-test--with root
    (let ((process-environment (append '("DRGNX_DATA_DIR=" "XDG_DATA_HOME=") process-environment)))
      (should (equal (drgnx-data-dir) (expand-file-name "~/.local/share/drgnx/"))))))

;;; portable-test.el ends here
