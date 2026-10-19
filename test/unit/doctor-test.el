;;; doctor-test.el --- batch tests: drgnx doctor -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-doctor)
(require 'drgnx-macos)   ; so `drgnx-macos-app-dir' is special before a test let-binds it

(defun drgnx-doctor-test--facts (&rest kv)
  (append kv (list :version "31.1" :native-available t :native-compiles t :treesit t :gui 'pgtk :git t :sqlite t)))

(defun drgnx-doctor-test--status (name facts)
  (car (drgnx-doctor-check name facts)))

(ert-deftest drgnx-doctor/emacs-version ()
  (should (eq (drgnx-doctor-test--status 'emacs-version (drgnx-doctor-test--facts)) 'ok))
  (should (eq (drgnx-doctor-test--status 'emacs-version (drgnx-doctor-test--facts :version "31.2")) 'ok))
  (should (eq (drgnx-doctor-test--status 'emacs-version (drgnx-doctor-test--facts :version "30.2")) 'warn))
  (should (eq (drgnx-doctor-test--status 'emacs-version (drgnx-doctor-test--facts :version "29.4")) 'fail)))

(ert-deftest drgnx-doctor/native-compilation ()
  (should (eq (drgnx-doctor-test--status 'native-compilation (drgnx-doctor-test--facts)) 'ok))
  (let ((r (drgnx-doctor-check 'native-compilation
                               (drgnx-doctor-test--facts :native-compiles "libgccjit.so: cannot open"))))
    (should (eq (car r) 'fail))
    (should (string-search "libgccjit.so" (nth 1 r)))
    (should (string-search "install.sh" (nth 2 r))))
  (should (eq (drgnx-doctor-test--status 'native-compilation (drgnx-doctor-test--facts :native-available nil)) 'fail)))

(ert-deftest drgnx-doctor/tree-sitter-and-gui ()
  (should (eq (drgnx-doctor-test--status 'tree-sitter (drgnx-doctor-test--facts :treesit nil)) 'warn))
  (should (eq (drgnx-doctor-test--status 'gui (drgnx-doctor-test--facts :gui nil)) 'ok))   ; a terminal-only build is fine (M12b)
  (should (eq (drgnx-doctor-test--status 'gui (drgnx-doctor-test--facts :gui 'ns)) 'ok)))

(ert-deftest drgnx-doctor/security-notice-until-31.2 ()
  (should (eq (drgnx-doctor-test--status 'security (drgnx-doctor-test--facts)) 'warn))
  (should (string-search "31.2" (nth 1 (drgnx-doctor-check 'security (drgnx-doctor-test--facts)))))
  (should (eq (drgnx-doctor-test--status 'security (drgnx-doctor-test--facts :version "30.2")) 'warn))
  (should (eq (drgnx-doctor-test--status 'security (drgnx-doctor-test--facts :version "31.2")) 'ok)))

(ert-deftest drgnx-doctor/dev-checks-only-with-dev ()
  (let ((names (lambda (results) (mapcar (lambda (r) (plist-get r :name)) results))))
    ;; ui-magick: a dev check on every platform (ui-mutter is Linux-only)
    (should-not (memq 'ui-magick (funcall names (drgnx-doctor-run (drgnx-doctor-test--facts) nil))))
    (should (memq 'ui-magick (funcall names (drgnx-doctor-run (drgnx-doctor-test--facts :magick nil) t))))))

(ert-deftest drgnx-doctor/report-and-exit-code ()
  (let* ((results (drgnx-doctor-run (drgnx-doctor-test--facts :version "29.4") nil))
         (text (drgnx-doctor-format results)))
    (should (string-match-p "^FAIL +emacs-version" text))
    (should (= (drgnx-doctor-exit-code results) 1))
    (should (= (drgnx-doctor-exit-code (drgnx-doctor-run (drgnx-doctor-test--facts :version "31.2") nil)) 0))
    (let ((json (json-parse-string (drgnx-doctor-json results) :object-type 'plist)))
      (should (equal (plist-get (aref json 0) :status) "fail")))))

(ert-deftest drgnx-doctor/facts-from-this-emacs ()
  (let ((f (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts))))
    (should (equal (plist-get f :version) emacs-version))
    (should (memq (plist-get f :native-available) '(t nil)))))

(ert-deftest drgnx-doctor/gui-fallback-reads-its-own-match ()
  ;; A match an earlier caller left behind must not be what the build-features fallback reads.
  (string-match "z" "zz")
  (should (eq (drgnx-doctor--gui-from-features "A X11 B") 'x11))
  (string-match "z" "zz")
  (should (eq (drgnx-doctor--gui-from-features "PGTK THREADS") 'pgtk))
  (should-not (drgnx-doctor--gui-from-features "THREADS")))

(defconst drgnx-doctor-test--bin
  (expand-file-name "../../bin/drgnx" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-doctor-test--run (&rest args)
  "Run bin/drgnx ARGS; return (EXIT . STDOUT) — stderr is dropped (a --json run is read as JSON)."
  (with-temp-buffer
    (cons (apply #'call-process drgnx-doctor-test--bin nil '(t nil) nil args) (buffer-string))))

(ert-deftest drgnx-doctor/cli-without-emacs ()
  (let* ((process-environment (cons "DRGNX_EMACS=/no/such/emacs" process-environment))
         (r (drgnx-doctor-test--run "doctor")))
    (should (= (car r) 1))
    (should (string-search "install.sh" (cdr r)))))

(ert-deftest drgnx-doctor/cli-with-this-emacs ()
  ;; The Emacs may talk on stderr (a warning, a deprecation notice): the --json output is stdout only.
  (let* ((dir (make-temp-file "drgnx-doctor-wrap" t))
         (wrapper (expand-file-name "emacs-noisy" dir))
         (process-environment (cons (concat "DRGNX_EMACS=" wrapper) process-environment)))
    (unwind-protect
        (progn
          (with-temp-file wrapper
            (insert "#!/bin/sh\necho 'noise on stderr' >&2\nexec "
                    (shell-quote-argument (expand-file-name invocation-name invocation-directory)) " \"$@\"\n"))
          (set-file-modes wrapper #o755)
          (let ((r (drgnx-doctor-test--run "doctor")))
            (should (string-search "native-compilation" (cdr r)))
            (should-not (string-search "noise on stderr" (cdr r)))
            (should-not (string-search "ui-magick" (cdr r))))         ; a dev check on every platform
          (should (string-search "ui-magick" (cdr (drgnx-doctor-test--run "doctor" "--dev"))))
          (let ((out (cdr (drgnx-doctor-test--run "doctor" "--json"))))
            (should (plist-get (aref (json-parse-string (string-trim out) :object-type 'plist) 0) :name))))
      (delete-directory dir t))))

(ert-deftest drgnx-doctor/dev-needs-a-pgtk-emacs ()
  (should (eq (drgnx-doctor-test--status 'ui-pgtk (drgnx-doctor-test--facts :pgtk-emacs t)) 'ok))
  (should (eq (drgnx-doctor-test--status 'ui-pgtk (drgnx-doctor-test--facts :pgtk-emacs nil)) 'warn)))

(defun drgnx-doctor-test--names (results) (mapcar (lambda (r) (plist-get r :name)) results))

(ert-deftest drgnx-doctor/no-linux-dev-checks-on-macos ()
  (let ((facts (drgnx-doctor-test--facts :mutter nil :dbus-run-session nil :pgtk-emacs nil :magick t)))
    (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
      (let ((names (drgnx-doctor-test--names (drgnx-doctor-run facts t))))
        (should-not (memq 'ui-mutter names))
        (should-not (memq 'ui-dbus names))
        (should-not (memq 'ui-pgtk names))
        (should (memq 'ui-magick names))))
    (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
      (let ((names (drgnx-doctor-test--names (drgnx-doctor-run facts t))))
        (dolist (n '(ui-mutter ui-dbus ui-pgtk ui-magick)) (should (memq n names)))
        (dolist (n '(macos-app brew drgnx-on-path)) (should-not (memq n names)))))))

(ert-deftest drgnx-doctor/macos-checks-the-app-brew-and-path ()
  (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
    (let ((names (drgnx-doctor-test--names (drgnx-doctor-run (drgnx-doctor-test--facts :macos-app t :brew t :drgnx-on-path t) nil))))
      (dolist (n '(macos-app brew drgnx-on-path)) (should (memq n names))))
    (dolist (c '((macos-app :macos-app "drgnx macos-app") (brew :brew "brew.sh") (drgnx-on-path :drgnx-on-path ".local/bin")))
      (pcase-let ((`(,name ,key ,fix) c))
        (should (eq (drgnx-doctor-test--status name (drgnx-doctor-test--facts key t)) 'ok))
        (let ((r (drgnx-doctor-check name (drgnx-doctor-test--facts key nil))))
          (should (eq (car r) 'warn))
          (should (string-search fix (nth 2 r))))))
    (should (string-search "~/.zprofile" (nth 2 (drgnx-doctor-check 'drgnx-on-path (drgnx-doctor-test--facts :drgnx-on-path nil)))))))

(ert-deftest drgnx-doctor/macos-facts-look-at-the-app-and-the-homebrew-prefixes ()
  (let ((dir (file-name-as-directory (make-temp-file "drgnx-doctor" t))))
    (unwind-protect
        (let ((drgnx-macos-app-dir dir))
          (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos))
                    ((symbol-function 'drgnx-doctor--search) #'ignore)
                    ((symbol-function 'executable-find) (lambda (&rest _) nil))
                    ((symbol-function 'file-executable-p) (lambda (f) (equal f "/opt/homebrew/bin/brew"))))
            (let ((f (drgnx-doctor-facts)))
              (should (plist-member f :macos-app))
              (should-not (plist-get f :macos-app))
              (should (plist-get f :brew))
              (should-not (plist-get f :drgnx-on-path))
              (make-directory (expand-file-name "drgnx.app" dir))
              (should (plist-get (drgnx-doctor-facts) :macos-app))))
          (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux))
                    ((symbol-function 'drgnx-doctor--search) #'ignore))
            (should-not (plist-member (drgnx-doctor-facts) :brew))))
      (delete-directory dir t))))

(ert-deftest drgnx-doctor/drgnx-on-path-also-counts-the-zprofile-line ()
  ;; A daemon the app started has no ~/.local/bin on its PATH: ~/.local/bin/drgnx there and ~/.zprofile putting
  ;; ~/.local/bin on PATH is what Terminal sees — ok, not a warning.
  (let* ((home (file-name-as-directory (make-temp-file "drgnx-doctor-home" t)))
         (process-environment (append (list (concat "HOME=" home) "SHELL=/bin/zsh") process-environment))
         (zprofile (concat home ".zprofile")))
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
          (should-not (drgnx-doctor--drgnx-on-path))
          (make-directory (concat home ".local/bin") t)
          (write-region "" nil (concat home ".local/bin/drgnx"))
          (should-not (drgnx-doctor--drgnx-on-path))                         ; there, but no PATH line
          (write-region "# export PATH=\"$HOME/.local/bin:$PATH\"\n" nil zprofile)
          (should-not (drgnx-doctor--drgnx-on-path))                         ; a comment is not a PATH line
          (dolist (line (list "export PATH=\"$HOME/.local/bin:$PATH\"" "export PATH=\"${HOME}/.local/bin:$PATH\""
                              "export PATH=~/.local/bin:$PATH" (format "export PATH=\"%s.local/bin:$PATH\"" home)))
            (write-region (concat "eval \"$(/opt/homebrew/bin/brew shellenv)\"\n\n# added by the drgnx installer\n" line "\n")
                          nil zprofile)
            (should (drgnx-doctor--drgnx-on-path)))
          (delete-file (concat home ".local/bin/drgnx"))
          (should-not (drgnx-doctor--drgnx-on-path)))                        ; the line alone: no command
      (delete-directory home t)))
  (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (and (equal p "drgnx") "/x/drgnx"))))
    (should (drgnx-doctor--drgnx-on-path))))

(ert-deftest drgnx-doctor/drgnx-on-path-reads-the-shells-profile ()
  ;; The profile the installer writes follows the shell: zsh reads ~/.zprofile, any other login shell ~/.profile.
  (let* ((home (file-name-as-directory (make-temp-file "drgnx-doctor-home" t)))
         (line "export PATH=\"$HOME/.local/bin:$PATH\"\n"))
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
          (make-directory (concat home ".local/bin") t)
          (write-region "" nil (concat home ".local/bin/drgnx"))
          (let ((process-environment (append (list (concat "HOME=" home) "SHELL=/bin/bash") process-environment)))
            (should (equal (drgnx-doctor--shell-profile) "~/.profile"))
            (write-region line nil (concat home ".zprofile"))
            (should-not (drgnx-doctor--drgnx-on-path))                       ; bash never reads ~/.zprofile
            (write-region line nil (concat home ".profile"))
            (should (drgnx-doctor--drgnx-on-path)))
          (delete-file (concat home ".profile"))
          (let ((process-environment (append (list (concat "HOME=" home) "SHELL=/usr/bin/zsh") process-environment)))
            (should (equal (drgnx-doctor--shell-profile) "~/.zprofile"))
            (should (drgnx-doctor--drgnx-on-path))
            (write-region line nil (concat home ".profile") nil 'silent)
            (delete-file (concat home ".zprofile"))
            (should-not (drgnx-doctor--drgnx-on-path))))                     ; zsh never reads ~/.profile
      (delete-directory home t)))
  ;; The fix names the file.
  (let ((fix (nth 2 (drgnx-doctor-check 'drgnx-on-path (drgnx-doctor-test--facts :drgnx-on-path nil
                                                                                 :shell-profile "~/.profile")))))
    (should (string-search ">> ~/.profile" fix))
    (should-not (string-search "zprofile" fix)))
  (let ((process-environment (cons "SHELL=/bin/bash" process-environment)))
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil))
              ((symbol-function 'file-executable-p) #'ignore))
      (should (equal (plist-get (drgnx-doctor--macos-facts) :shell-profile) "~/.profile")))))

(ert-deftest drgnx-doctor/drgnx-on-path-also-counts-zsh-path-arrays ()
  (let* ((home (file-name-as-directory (make-temp-file "drgnx-doctor-home" t)))
         (process-environment (append (list (concat "HOME=" home) "SHELL=/bin/zsh") process-environment)))
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
          (make-directory (concat home ".local/bin") t)
          (write-region "" nil (concat home ".local/bin/drgnx"))
          (dolist (line '("path=(~/.local/bin $path)" "path=($HOME/.local/bin $path)" "path+=(~/.local/bin)"
                          "path=(/opt/x/bin ${HOME}/.local/bin $path)" "typeset -U path; path+=(\"$HOME/.local/bin\")"))
            (write-region (concat line "\n") nil (concat home ".zprofile"))
            (should (drgnx-doctor--drgnx-on-path)))
          (dolist (line '("# path=(~/.local/bin $path)" "path=(/opt/x/bin $path)" "export PATH=/usr/bin"))
            (write-region (concat line "\n") nil (concat home ".zprofile"))
            (should-not (drgnx-doctor--drgnx-on-path))))
      (delete-directory home t))))

(ert-deftest drgnx-doctor/key-conflicts ()
  ;; The doctor reads the report the last drgnx session wrote (batch Emacs loads no modules).
  (let ((check (lambda (report) (drgnx-doctor-check 'key-conflicts (drgnx-doctor-test--facts :keys-report report)))))
    (should (eq (car (funcall check nil)) 'info))
    (should (eq (car (funcall check '(:layers ((vscode app)) :conflicts nil :problems nil))) 'ok))
    (let ((r (funcall check '(:layers ((emacs editing) (vscode app)) :conflicts ("C-o: a" "C-s: b") :problems nil))))
      (should (eq (car r) 'info))
      (should (string-search "2 key conflicts" (nth 1 r)))
      (should (string-search "Keyboard Shortcuts" (nth 2 r))))
    (let ((r (funcall check '(:layers ((vscode app)) :conflicts nil :problems ("keys.eld: no command nope (in :bind)")))))
      (should (eq (car r) 'warn))
      (should (string-search "no command nope" (nth 1 r))))))

(ert-deftest drgnx-doctor/modules-check-says-stale-and-disabled ()
  (let* ((report '((a :status ok) (b :status disabled)))
         (r (drgnx-doctor-check 'modules (drgnx-doctor-test--facts :modules-report report
                                                                   :modules-report-time (- (float-time) 3.5 3600 3600)))))
    (should (eq (car r) 'ok))
    (should (string-search "1 ok" (nth 1 r)))
    (should (string-search "1 off" (nth 1 r)))
    (should (string-search "from the last session, 2 h ago" (nth 1 r))))
  (let ((r (drgnx-doctor-check 'modules (drgnx-doctor-test--facts :modules-report '((a :status disabled))
                                                                  :modules-report-time (- (float-time) 90)))))
    (should (string-search "0 ok, 1 off" (nth 1 r)))
    (should (string-search "1 min ago" (nth 1 r))))
  ;; a failure keeps its verdict and says how old the report is; without a time, no age
  (let ((r (drgnx-doctor-check 'modules (drgnx-doctor-test--facts :modules-report '((a :status failed :error "boom"))
                                                                  :modules-report-time (- (float-time) 3 (* 3 86400))))))
    (should (eq (car r) 'fail))
    (should (string-search "a: boom" (nth 1 r)))
    (should (string-search "3 d ago" (nth 1 r))))
  (should-not (string-search "ago" (nth 1 (drgnx-doctor-check 'modules (drgnx-doctor-test--facts :modules-report '((a :status ok))))))))

(ert-deftest drgnx-doctor/modules-report-time-fact ()
  (let* ((state (make-temp-file "drgnx-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (facts (lambda () (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts)))))
    (unwind-protect
        (progn
          (should-not (plist-get (funcall facts) :modules-report-time))
          (make-directory (expand-file-name "drgnx" state))
          (with-temp-file (expand-file-name "drgnx/modules-report.eld" state) (prin1 '((a :status ok)) (current-buffer)))
          (set-file-times (expand-file-name "drgnx/modules-report.eld" state) (time-subtract nil 7200))
          (let ((age (- (float-time) (plist-get (funcall facts) :modules-report-time))))
            (should (< 7190 age 7300))))
      (delete-directory state t))))

(ert-deftest drgnx-doctor/display-buffer-alist-entry-missing-warns ()
  (let ((check (lambda (report) (drgnx-doctor-check 'display-rules (drgnx-doctor-test--facts :wb-report report)))))
    (should (eq (car (funcall check nil)) 'info))
    (should (eq (car (funcall check '(:display-buffer-entry t))) 'ok))
    (let ((r (funcall check '(:display-buffer-entry nil))))
      (should (eq (car r) 'warn))
      (should (string-search "display-buffer-alist" (nth 1 r)))
      (should (string-search "display-buffer-alist" (nth 2 r))))))

(ert-deftest drgnx-doctor/builtin-in-manifest-is-not-missing ()
  ;; eglot ships with Emacs: a manifest that names it needs no install.
  (should (eq (car (drgnx-doctor-check 'packages (drgnx-doctor-test--facts :packages '(:manifest (eglot) :installed () :lock t))))
              'ok))
  (should (package-built-in-p 'eglot))
  (let ((r (drgnx-doctor-check 'packages (drgnx-doctor-test--facts
                                          :packages '(:manifest (eglot drgnx-no-such-pkg) :installed () :lock t)))))
    (should (eq (car r) 'warn))
    (should (string-search "drgnx-no-such-pkg" (nth 1 r)))
    (should-not (string-search "eglot" (nth 1 r)))))

(ert-deftest drgnx-doctor/keys-report-fact ()
  (let* ((state (make-temp-file "drgnx-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
    (unwind-protect
        (progn
          (should (null (plist-get (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts)) :keys-report)))
          (make-directory (expand-file-name "drgnx" state))
          (with-temp-file (expand-file-name "drgnx/keys-report.eld" state)
            (prin1 '(:layers ((vscode app)) :conflicts ("x") :problems nil) (current-buffer)))
          (should (equal (plist-get (plist-get (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts)) :keys-report) :conflicts) '("x"))))
      (delete-directory state t))))

(ert-deftest drgnx-doctor/a-relative-xdg-state-home-counts-as-unset ()
  ;; the state files the doctor reads are drgnx-paths' state dir: never under the current directory
  (let ((process-environment (append (list "XDG_STATE_HOME=rel" "HOME=/tmp/drgnx-home") process-environment)))
    (should (equal (drgnx-doctor--state-path "x.eld") "/tmp/drgnx-home/.local/state/drgnx/x.eld"))
    (let (read)
      (cl-letf (((symbol-function 'drgnx-file-read) (lambda (f &rest _) (push f read) (list :status 'absent))))
        (drgnx-doctor--keys-report))
      (should (equal read '("/tmp/drgnx-home/.local/state/drgnx/keys-report.eld"))))))

(ert-deftest drgnx-doctor/the-state-files-are-read-through-the-file-layer ()
  ;; data is data; a file with a mistake, a missing one and a huge one give nil, and no reader changes the bytes
  (let* ((state (make-temp-file "drgnx-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (dir (expand-file-name "drgnx" state)))
    (unwind-protect
        (progn
          (make-directory dir)
          (should-not (drgnx-doctor--state-file "wb-report.eld"))
          (should-not (drgnx-doctor--keys-report))
          (dolist (text '("(:time \"x\"" "(:time \"x\") (:more)" "#1=(:a . #1#)"))
            (dolist (name '("wb-report.eld" "keys-report.eld"))
              (write-region text nil (expand-file-name name dir) nil 'silent))
            (should-not (drgnx-doctor--state-file "wb-report.eld"))
            (should-not (drgnx-doctor--keys-report))
            (should (equal (with-temp-buffer (insert-file-contents (expand-file-name "wb-report.eld" dir)) (buffer-string))
                           text)))
          (write-region ";; note\n(:time \"x\" :display-buffer-entry t)\n" nil (expand-file-name "wb-report.eld" dir) nil 'silent)
          (should (equal (drgnx-doctor--state-file "wb-report.eld") '(:time "x" :display-buffer-entry t)))
          (write-region (make-string (1+ drgnx-file-max-bytes) ?\s) nil (expand-file-name "keys-report.eld" dir) nil 'silent)
          (should-not (drgnx-doctor--keys-report)))
      (delete-directory state t))))

;;;; search

(defun drgnx-doctor-test--search (&rest kv)
  "The `search' check on healthy search facts changed by KV (:indexes, :embed-dims …)."
  (drgnx-doctor-check 'search (drgnx-doctor-test--facts
                               :search (append kv (list :sqlite t :fts5 t :embed-up t :embed-dims 384 :unindexed 0
                                                        :indexes '(("/p/a" :chunks 120 :files 9 :dims 384 :stale 0)))))))

(ert-deftest drgnx-doctor/search-ok ()
  (let ((r (drgnx-doctor-test--search)))
    (should (eq (car r) 'ok))
    (should (string-match-p "1 index" (nth 1 r)))
    (should (string-match-p "120 chunks" (nth 1 r)))))

(ert-deftest drgnx-doctor/search-dims-mismatch-warns ()
  (let ((r (drgnx-doctor-test--search :embed-dims 768 :embed-provider 'tei :embed-model "bge"
                                      :indexes '(("/p/a" :chunks 5 :provider tei :model "bge" :dims 384 :stale 0)))))
    (should (eq (car r) 'warn))
    (should (string-match-p "built with tei/bge (384), the provider gives 768" (nth 1 r)))
    (should (string-match-p "Search: Index Project with rebuild" (nth 1 r)))
    (should (string-match-p "Index Project" (nth 2 r)))))

(ert-deftest drgnx-doctor/search-model-mismatch-names-both-models ()
  (let ((r (drgnx-doctor-test--search :embed-dims 384 :embed-provider 'ollama :embed-model "nomic"
                                      :indexes '(("/p/a" :chunks 5 :provider tei :model "bge" :dims 384 :stale 0)))))
    (should (eq (car r) 'warn))
    (should (string-match-p "built with tei/bge, the provider is ollama/nomic" (nth 1 r)))))

(ert-deftest drgnx-doctor/search-wrapper-turns-a-signal-into-an-error-fact ()
  (require 'drgnx-search-setup)
  (cl-letf (((symbol-function 'drgnx-search-setup--roots) (lambda () nil))
            ((symbol-function 'drgnx-search-doctor-facts) (lambda (_) (error "boom"))))
    (should (equal (drgnx-doctor--search) '(:error "boom")))))

(ert-deftest drgnx-doctor/search-stale-warns ()
  (let ((few (drgnx-doctor-test--search :indexes '(("/p/a" :chunks 5 :dims 384 :stale 20))))
        (many (drgnx-doctor-test--search :indexes '(("/p/a" :chunks 5 :dims 384 :stale 21)))))
    (should (eq (car few) 'ok))                                 ; more than 20 files
    (should (eq (car many) 'warn))
    (should (string-match-p "21 files" (nth 1 many)))
    (should (string-match-p "Index Project" (nth 2 many)))))

(ert-deftest drgnx-doctor/search-no-fts5-fails ()
  (let ((r (drgnx-doctor-test--search :fts5 nil)))
    (should (eq (car r) 'fail))
    (should (string-match-p "FTS5" (nth 1 r))))
  (let ((r (drgnx-doctor-test--search :sqlite nil :fts5 nil)))
    (should (eq (car r) 'fail))
    (should (string-match-p "SQLite" (nth 1 r)))))

(ert-deftest drgnx-doctor/search-no-provider-is-info ()
  (let ((r (drgnx-doctor-test--search :embed-up nil :embed-dims nil)))
    (should (eq (car r) 'info))
    (should (string-match-p "Set Up Semantic Search" (nth 2 r)))))

(ert-deftest drgnx-doctor/search-unindexed-projects-are-not-stale ()
  (let ((r (drgnx-doctor-test--search :indexes nil :unindexed 3)))
    (should (eq (car r) 'ok))
    (should (string-match-p "3 projects not indexed" (nth 1 r)))))

(ert-deftest drgnx-doctor/search-fact-failure-is-a-warning-not-a-crash ()
  (should (eq (car (drgnx-doctor-check 'search (drgnx-doctor-test--facts :search '(:error "boom")))) 'warn))
  (should (eq (car (drgnx-doctor-check 'search (drgnx-doctor-test--facts))) 'info)))   ; facts without :search

(ert-deftest drgnx-doctor/search-a-broken-config-warns ()
  (let ((r (drgnx-doctor-test--search
            :config-errors '(("/p/a" . ".drgnx/search.eld cannot be read: :off must be t or nil")))))
    (should (eq (car r) 'warn))
    (should (string-match-p "a: \\.drgnx/search\\.eld cannot be read: :off must be t or nil" (nth 1 r)))
    (should (string-match-p "search\\.eld" (nth 2 r)))))

(ert-deftest drgnx-doctor/drgnx-on-path-skips-a-profile-it-cannot-read ()
  ;; M12a-3 (review): a profile that is a directory, or unreadable, is skipped quietly: no signal, no stack trace.
  (let* ((home (file-name-as-directory (make-temp-file "drgnx-doctor-home" t)))
         (process-environment (append (list (concat "HOME=" home) "SHELL=/bin/zsh") process-environment))
         (zprofile (concat home ".zprofile")))
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
          (make-directory (concat home ".local/bin") t)
          (write-region "" nil (concat home ".local/bin/drgnx"))
          (make-directory zprofile)
          (should-not (drgnx-doctor--drgnx-on-path))                         ; a directory
          (delete-directory zprofile)
          (write-region "export PATH=\"$HOME/.local/bin:$PATH\"\n" nil zprofile)
          (cl-letf (((symbol-function 'insert-file-contents)
                     (lambda (&rest _) (signal 'file-error '("Reading" "denied")))))
            (should-not (drgnx-doctor--drgnx-on-path)))                      ; the read fails
          (should (drgnx-doctor--drgnx-on-path)))                            ; readable again: counted
      (delete-directory home t))))

(ert-deftest drgnx-doctor/with-no-shell-the-profile-that-exists-is-read ()
  ;; M12a-3 (review): SHELL unset (a daemon the app started): ~/.zprofile when it exists, then ~/.profile, so a Mac
  ;; zsh user gets no false warning.
  (let* ((home (file-name-as-directory (make-temp-file "drgnx-doctor-home" t)))
         (process-environment (append (list (concat "HOME=" home) "SHELL") process-environment)))   ; SHELL unset
    (unwind-protect
        (progn
          (should-not (getenv "SHELL"))
          (should (equal (drgnx-doctor--shell-profile) "~/.profile"))        ; neither exists
          (write-region "" nil (concat home ".profile"))
          (should (equal (drgnx-doctor--shell-profile) "~/.profile"))
          (write-region "" nil (concat home ".zprofile"))
          (should (equal (drgnx-doctor--shell-profile) "~/.zprofile"))       ; both: zsh's wins
          (delete-file (concat home ".profile"))
          (should (equal (drgnx-doctor--shell-profile) "~/.zprofile"))
          (let ((process-environment (cons "SHELL=/bin/bash" process-environment)))   ; a set SHELL still decides
            (should (equal (drgnx-doctor--shell-profile) "~/.profile"))))
      (delete-directory home t))))

(ert-deftest drgnx-doctor/the-claude-adapter-must-be-the-maintained-package ()
  ;; C2-3: the deprecated adapter never says which MCP server a tool is from
  (let* ((old '(:program "/p/bin/claude-agent-acp" :name "@zed-industries/claude-agent-acp" :version "0.23.1" :prefix "/p"))
         (new '(:program "/q/bin/claude-agent-acp" :name "@agentclientprotocol/claude-agent-acp" :version "0.93.0" :prefix "/q"))
         (check (lambda (a) (drgnx-doctor-check 'claude-adapter (drgnx-doctor-test--facts :claude-adapter a)))))
    (let ((r (funcall check old)))
      (should (eq (car r) 'warn))
      (should (string-search "deprecated" (nth 1 r)))
      (should (string-search "0.23.1" (nth 1 r)))
      (should (equal (nth 2 r) (concat "npm uninstall -g --prefix /p @zed-industries/claude-agent-acp"
                                       " && npm install -g --prefix /p @agentclientprotocol/claude-agent-acp"))))
    (let ((r (funcall check new)))
      (should (eq (car r) 'ok))
      (should (string-search "@agentclientprotocol/claude-agent-acp 0.93.0" (nth 1 r))))
    (should (eq (car (funcall check (plist-put (copy-sequence new) :version "1.2.0"))) 'ok))
    (let ((r (funcall check (plist-put (copy-sequence new) :version "0.59.0"))))
      (should (eq (car r) 'warn))
      (should (equal (nth 2 r) "npm install -g --prefix /q @agentclientprotocol/claude-agent-acp@latest")))
    ;; a program of no package drgnx knows: it cannot tell, so it warns
    (let ((r (funcall check '(:program "/r/claude-agent-acp"))))
      (should (eq (car r) 'warn))
      (should (string-search "/r/claude-agent-acp" (nth 1 r)))
      (should (string-search "@agentclientprotocol/claude-agent-acp 0.93.0 or newer" (nth 2 r)))
      (should (string-search "the tool that installed it" (nth 2 r))))
    ;; a known package outside a global npm prefix (pnpm, volta, a project): advice, no npm -g command
    (let ((r (funcall check (plist-put (copy-sequence old) :prefix nil))))
      (should (eq (car r) 'warn))
      (should-not (string-match-p "npm uninstall" (nth 2 r))))
    ;; none: only a notice (the agent panel is optional); never a failure, so the doctor's exit stays 0
    (let ((r (funcall check nil)))
      (should (eq (car r) 'info))
      (should (string-search "drgnx onboard --step agents" (nth 2 r))))
    (should (eq (car (funcall check '(:error "boom"))) 'warn))
    (should (= 0 (drgnx-doctor-exit-code (drgnx-doctor-run (drgnx-doctor-test--facts :version "31.2" :claude-adapter old) nil))))))

;;;; Config files and the checkout (config layer, Task 5)

(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)

(defun drgnx-doctor-test--define-config (name file &rest args)
  "Define the plist config file NAME in FILE (schema :a integer, :b string); ARGS come first."
  (apply #'drgnx-config-define name
         (append args (list :file file :schema '(plist (:a integer "A number") (:b string "A string"))
                            :default '(:a 1) :doc "A test file."))))

(defun drgnx-doctor-test--config-check ()
  "The `config-files' check on the facts a fresh read gives."
  (drgnx-doctor-check 'config-files (list :config-files (drgnx-doctor--config-files))))

(ert-deftest drgnx-doctor/config-files-ok ()
  (drgnx-test-with-config
    (drgnx-doctor-test--define-config 'doctor-test-a "a.eld")
    (drgnx-doctor-test--define-config 'doctor-test-b "b.eld")
    (drgnx-test-config-put 'doctor-test-a "(:a 2 :b \"x\")\n")
    (let ((r (drgnx-doctor-test--config-check)))
      (should (eq (car r) 'ok))
      (should (equal (nth 1 r) "2 files read")))
    ;; no definitions at all is fine too; a project file is not read (it needs a folder)
    (drgnx-config-undefine 'doctor-test-a)
    (drgnx-config-undefine 'doctor-test-b)
    (drgnx-doctor-test--define-config 'doctor-test-p "p.eld" :dir 'project)
    (should (equal (nth 1 (drgnx-doctor-test--config-check)) "0 files read"))
    (should (eq (car (drgnx-doctor-check 'config-files nil)) 'ok))))

(ert-deftest drgnx-doctor/config-files-fail-names-file-and-line ()
  (drgnx-test-with-config
    (drgnx-doctor-test--define-config 'doctor-test-a "a.eld")
    (drgnx-test-config-put 'doctor-test-a ";; mine\n\n(:a \"not a number\")\n")
    (let ((r (drgnx-doctor-test--config-check)))
      (should (eq (car r) 'fail))
      (should (string-match-p "\\`a\\.eld line 3: " (nth 1 r)))
      (should (string-search ":a" (nth 1 r)))
      (should (equal (nth 2 r) (concat "Preferences: Open Config File… or edit it; "
                                       "its last good copy is in use until then"))))
    ;; the doctor only reads: the file keeps its bytes
    (should (equal (drgnx-test-config-text 'doctor-test-a) ";; mine\n\n(:a \"not a number\")\n"))))

(ert-deftest drgnx-doctor/config-files-newer-warns ()
  (drgnx-test-with-config
    (drgnx-doctor-test--define-config 'doctor-test-a "a.eld")
    (drgnx-test-config-put 'doctor-test-a "(:version 99 :a 2)\n")
    (let ((r (drgnx-doctor-test--config-check)))
      (should (eq (car r) 'warn))
      (should (string-search "a.eld" (nth 1 r)))
      (should (string-search "written by a newer drgnx" (nth 1 r)))
      (should (string-search "update drgnx here" (concat (nth 1 r) (nth 2 r)))))))

(ert-deftest drgnx-doctor/config-files-unknown-keys-are-info ()
  (drgnx-test-with-config
    (drgnx-doctor-test--define-config 'doctor-test-a "a.eld")
    (drgnx-test-config-put 'doctor-test-a "(:a 2 :zzz 1)\n")
    (let ((r (drgnx-doctor-test--config-check)))
      (should (eq (car r) 'info))
      (should (string-search "a.eld: :zzz — a newer drgnx, or a typo?" (nth 1 r))))
    ;; a mistake outranks it, and both are said
    (drgnx-doctor-test--define-config 'doctor-test-b "b.eld")
    (drgnx-test-config-put 'doctor-test-b "(:a \"x\")\n")
    (let ((r (drgnx-doctor-test--config-check)))
      (should (eq (car r) 'fail))
      (should (string-search "b.eld line 1" (nth 1 r)))
      (should (string-search ":zzz" (nth 1 r))))))

(ert-deftest drgnx-doctor/config-files-migrated-is-info ()
  (drgnx-test-with-config
    (drgnx-doctor-test--define-config 'doctor-test-a "a.eld" :version 2 :migrate (list (cons 1 #'identity)))
    (drgnx-test-config-put 'doctor-test-a "(:a 2)\n")
    (let ((r (drgnx-doctor-test--config-check)))
      (should (eq (car r) 'info))
      (should (string-search "a.eld" (nth 1 r)))
      (should (string-search "older" (nth 1 r))))))

(ert-deftest drgnx-doctor/config-files-fact-failure-is-a-warning ()
  (let ((r (drgnx-doctor-check 'config-files '(:config-files (:error "boom")))))
    (should (eq (car r) 'warn))
    (should (string-search "boom" (nth 1 r)))))

(defun drgnx-doctor-test--git (dir &rest args)
  "Run git ARGS in DIR (a throwaway repo, no user config), failing the test when it does."
  (let ((process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_SYSTEM=/dev/null"
                                       "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@example.org"
                                       "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@example.org")
                                     process-environment)))
    (should (eql 0 (apply #'call-process "git" nil nil nil "-C" dir args)))))

(ert-deftest drgnx-doctor/checkout-clean-warns-on-a-changed-init ()
  (let ((dir (file-name-as-directory (make-temp-file "drgnx-doctor-checkout" t))))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "init" dir))
          (write-region "(a)\n" nil (expand-file-name "init/init.el" dir) nil 'silent)
          (write-region "x\n" nil (expand-file-name "other.txt" dir) nil 'silent)
          (drgnx-doctor-test--git dir "init" "-q")
          (drgnx-doctor-test--git dir "add" ".")
          (drgnx-doctor-test--git dir "commit" "-q" "-m" "first")
          (let ((facts (list :checkout-init (drgnx-doctor--checkout-init dir))))
            (should (eq (car (drgnx-doctor-check 'checkout-clean facts)) 'ok)))
          ;; a change outside init/ does not count; one inside does, and is named
          (write-region "y\n" nil (expand-file-name "other.txt" dir) nil 'silent)
          (should (eq (car (drgnx-doctor-check 'checkout-clean (list :checkout-init (drgnx-doctor--checkout-init dir)))) 'ok))
          (write-region "(b)\n" nil (expand-file-name "init/init.el" dir) nil 'silent)
          (let ((r (drgnx-doctor-check 'checkout-clean (list :checkout-init (drgnx-doctor--checkout-init dir)))))
            (should (eq (car r) 'warn))
            (should (string-search "init/init.el" (nth 1 r)))
            (should (string-search "config.el or custom.el" (nth 2 r)))
            (should (string-search (format "git -C %s checkout -- init/" (directory-file-name dir)) (nth 2 r)))))
      (delete-directory dir t))))

(ert-deftest drgnx-doctor/checkout-clean-absent-without-git ()
  (let ((dir (file-name-as-directory (make-temp-file "drgnx-doctor-nogit" t))))
    (unwind-protect
        (progn
          (should-not (drgnx-doctor--checkout-init dir))
          (should-not (drgnx-doctor-check 'checkout-clean (list :checkout-init (drgnx-doctor--checkout-init dir))))
          (should-not (drgnx-doctor-check 'checkout-clean nil)))
      (delete-directory dir t))))
(ert-deftest drgnx-doctor/timers-ok-without-a-report ()
  (let ((r (drgnx-doctor-check 'timers (drgnx-doctor-test--facts))))
    (should (eq (car r) 'ok))
    (should (equal (nth 1 r) "no timer stopped")))
  (should (eq 'ok (car (drgnx-doctor-check 'timers (drgnx-doctor-test--facts
                                                    :timers-report '((:file "timers-report.eld" :stopped nil :time 1.0))))))))

(ert-deftest drgnx-doctor/timers-lists-stopped-timers ()
  ;; the fact reads the session's and the hub's reports from the state dir; the check names each stopped timer
  (let* ((state (make-temp-file "drgnx-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment))
         (write (lambda (name report)
                  (let ((file (expand-file-name (concat "drgnx/" name) state)))
                    (with-temp-file file (prin1 report (current-buffer)))
                    (set-file-times file (time-subtract nil 7200))))))
    (unwind-protect
        (progn
          (should-not (drgnx-doctor--timers-report))
          (make-directory (expand-file-name "drgnx" state))
          (funcall write "timers-report.eld"
                   '(:stopped ((:key hub-tick :owner :core :fn drgnx-hub--tick :error "Boom" :failures 3 :stopped t
                                     :time 1.0))))
          (funcall write "hub-timers-report.eld"
                   '(:stopped ((:key (acp-watch . "#<process x>") :owner :core :fn drgnx-acp--watch :error "dead"
                                     :failures 3 :stopped t :time 2.0))))
          (let* ((facts (drgnx-doctor--timers-report))
                 (r (drgnx-doctor-check 'timers (drgnx-doctor-test--facts :timers-report facts))))
            (should (= 2 (length facts)))
            (should (eq (car r) 'warn))
            (should (string-search "hub-tick (drgnx-hub--tick): Boom" (nth 1 r)))
            (should (string-search "acp-watch" (nth 1 r)))
            (should (string-search "(drgnx-acp--watch): dead" (nth 1 r)))
            (should (string-search "from the last session, 2 h ago" (nth 1 r)))
            (should (equal (nth 2 r) "report the error; drgnx starts the timer again at the next start"))))
      (delete-directory state t))))
