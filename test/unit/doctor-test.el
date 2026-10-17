;;; doctor-test.el --- batch tests: drgnx doctor -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-doctor)

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
  (should (eq (drgnx-doctor-test--status 'gui (drgnx-doctor-test--facts :gui nil)) 'warn))
  (should (eq (drgnx-doctor-test--status 'gui (drgnx-doctor-test--facts :gui 'ns)) 'ok)))

(ert-deftest drgnx-doctor/security-notice-until-31.2 ()
  (should (eq (drgnx-doctor-test--status 'security (drgnx-doctor-test--facts)) 'warn))
  (should (string-search "31.2" (nth 1 (drgnx-doctor-check 'security (drgnx-doctor-test--facts)))))
  (should (eq (drgnx-doctor-test--status 'security (drgnx-doctor-test--facts :version "30.2")) 'warn))
  (should (eq (drgnx-doctor-test--status 'security (drgnx-doctor-test--facts :version "31.2")) 'ok)))

(ert-deftest drgnx-doctor/dev-checks-only-with-dev ()
  (let ((names (lambda (results) (mapcar (lambda (r) (plist-get r :name)) results))))
    (should-not (memq 'ui-mutter (funcall names (drgnx-doctor-run (drgnx-doctor-test--facts) nil))))
    (should (memq 'ui-mutter (funcall names (drgnx-doctor-run (drgnx-doctor-test--facts :mutter nil) t))))))

(ert-deftest drgnx-doctor/report-and-exit-code ()
  (let* ((results (drgnx-doctor-run (drgnx-doctor-test--facts :version "29.4") nil))
         (text (drgnx-doctor-format results)))
    (should (string-match-p "^FAIL +emacs-version" text))
    (should (= (drgnx-doctor-exit-code results) 1))
    (should (= (drgnx-doctor-exit-code (drgnx-doctor-run (drgnx-doctor-test--facts :version "31.2") nil)) 0))
    (let ((json (json-parse-string (drgnx-doctor-json results) :object-type 'plist)))
      (should (equal (plist-get (aref json 0) :status) "fail")))))

(ert-deftest drgnx-doctor/facts-from-this-emacs ()
  (let ((f (drgnx-doctor-facts)))
    (should (equal (plist-get f :version) emacs-version))
    (should (memq (plist-get f :native-available) '(t nil)))))

(defconst drgnx-doctor-test--bin
  (expand-file-name "../../bin/drgnx" (file-name-directory (or load-file-name buffer-file-name))))

(defun drgnx-doctor-test--run (&rest args)
  "Run bin/drgnx ARGS; return (EXIT . OUTPUT)."
  (with-temp-buffer
    (cons (apply #'call-process drgnx-doctor-test--bin nil t nil args) (buffer-string))))

(ert-deftest drgnx-doctor/cli-without-emacs ()
  (let* ((process-environment (cons "DRGNX_EMACS=/no/such/emacs" process-environment))
         (r (drgnx-doctor-test--run "doctor")))
    (should (= (car r) 1))
    (should (string-search "install.sh" (cdr r)))))

(ert-deftest drgnx-doctor/cli-with-this-emacs ()
  (let* ((process-environment (cons (concat "DRGNX_EMACS=" (expand-file-name invocation-name invocation-directory))
                                    process-environment))
         (r (drgnx-doctor-test--run "doctor")))
    (should (string-search "native-compilation" (cdr r)))
    (should-not (string-search "ui-mutter" (cdr r)))
    (should (string-search "ui-mutter" (cdr (drgnx-doctor-test--run "doctor" "--dev"))))
    (should (eq (aref (string-trim (cdr (drgnx-doctor-test--run "doctor" "--json"))) 0) ?\[))))

(ert-deftest drgnx-doctor/dev-needs-a-pgtk-emacs ()
  (should (eq (drgnx-doctor-test--status 'ui-pgtk (drgnx-doctor-test--facts :pgtk-emacs t)) 'ok))
  (should (eq (drgnx-doctor-test--status 'ui-pgtk (drgnx-doctor-test--facts :pgtk-emacs nil)) 'warn)))

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

(ert-deftest drgnx-doctor/keys-report-fact ()
  (let* ((state (make-temp-file "drgnx-state" t))
         (process-environment (cons (concat "XDG_STATE_HOME=" state) process-environment)))
    (unwind-protect
        (progn
          (should (null (plist-get (drgnx-doctor-facts) :keys-report)))
          (make-directory (expand-file-name "drgnx" state))
          (with-temp-file (expand-file-name "drgnx/keys-report.eld" state)
            (prin1 '(:layers ((vscode app)) :conflicts ("x") :problems nil) (current-buffer)))
          (should (equal (plist-get (plist-get (drgnx-doctor-facts) :keys-report) :conflicts) '("x"))))
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
  (let ((r (drgnx-doctor-test--search :embed-dims 768)))
    (should (eq (car r) 'warn))
    (should (string-match-p "built with 384 dims, provider gives 768" (nth 1 r)))
    (should (string-match-p "Search: Index Project with rebuild" (nth 1 r)))
    (should (string-match-p "Index Project" (nth 2 r)))))

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
