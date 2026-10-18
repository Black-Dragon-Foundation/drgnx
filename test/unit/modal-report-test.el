;;; modal-report-test.el --- batch tests: the key sheet, which-key, Shortcuts and the doctor speak Vim -*- lexical-binding: t -*-
;; No evil: the shipped profiles applied for real in a temp config and state dir; the report file, the sheet and the
;; doctor read what that apply wrote.
(require 'ert)
(require 'drgnx)
(require 'drgnx-keys-modal)
(require 'drgnx-doctor)
(load (expand-file-name "modules/tools/drgnx-shortcuts" drgnx-dir) nil t)
(defvar which-key-replacement-alist)

(defmacro drgnx-modal-report-test--live (&rest body)
  "BODY with the core commands and the modules' startup stage, fresh drgnx-keys state, a temp config and state dir and
no registered modal engine; every binding is undone after."
  (declare (indent 0))
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-commands-problems nil) (drgnx-modules--table nil) (drgnx-modules--report nil)
         (find-file-hook find-file-hook) (drgnx-modal-engines nil) (drgnx-modal-running nil)
         (drgnx-keys-modal-snapshots drgnx-keys-modal-snapshots))
     (drgnx--core-commands)
     (drgnx-modules-load-directory (expand-file-name "modules" drgnx-dir))
     (drgnx-modules-run 'startup)
     (let* ((dir (make-temp-file "drgnx-modal-report" t))
            (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" dir) (concat "XDG_STATE_HOME=" dir "/state"))
                                         process-environment))
            (drgnx-keys--applied nil) (drgnx-keys--session-layers nil) (drgnx-keys-profiles nil)
            (drgnx-keys-problems nil) (drgnx-keys-last nil))
       (unwind-protect (progn ,@body)
         (drgnx-keys--restore)
         (delete-directory dir t)))))

(defconst drgnx-modal-report-test--vim '((vim app editing window)))
(defconst drgnx-modal-report-test--vscode '((vscode app editing window)))
(defconst drgnx-modal-report-test--mixed '((vscode app window) (vim editing)))

(defun drgnx-modal-report-test--report ()
  "keys-report.eld as the last apply wrote it."
  (with-temp-buffer (insert-file-contents (expand-file-name "keys-report.eld" (drgnx-state-dir)))
                    (read (current-buffer))))

(defun drgnx-modal-report-test--facts (&rest kv)
  (append kv (list :version "31.1" :native-available t :native-compiles t :treesit t :gui 'pgtk :git t :sqlite t)))

;;;; The key sheet

(ert-deftest drgnx-modal-report/sheet-shows-leader-keys-plain ()
  (drgnx-modal-report-test--live
    (drgnx-keys-use drgnx-modal-report-test--vim)
    (should (equal (drgnx-surfaces-key (drgnx-commands-get 'open-file)) "SPC f f"))
    ;; Go to Definition is on SPC c d (the leader) and on g d, which works in normal state only
    (let ((row (seq-find (lambda (r) (equal (nth 2 r) (drgnx-cmd-title (drgnx-commands-get 'code-definition))))
                         (drgnx-surfaces-sheet-rows))))
      (should (equal (nth 1 row) "SPC c d, g d (normal state)")))
    (should (equal (drgnx-surfaces--md-key "SPC c d, g d (normal state)") "`SPC c d`, `g d` (normal state)"))
    (should (equal (drgnx-surfaces--md-key "C-c y (in org)") "`C-c y` (in org)"))
    ;; the panel keys read "panels"
    (should (equal (drgnx-surfaces-key (drgnx-commands-get 'panel-next)) "j (panels)"))))

(ert-deftest drgnx-modal-report/other-stacks-keep-the-sheet-as-it-was ()
  (drgnx-modal-report-test--live
    (drgnx-keys-use drgnx-modal-report-test--vscode)
    (dolist (r (drgnx-surfaces-sheet-rows))
      (should-not (string-match-p "state)\\|panels)" (nth 1 r))))))

;;;; which-key

(defun drgnx-modal-report-test--label (key)
  "The title which-key shows for the key sequence KEY (a key-based replacement), or nil."
  (let ((regexp (concat "\\`" (regexp-quote (key-description (kbd key))) "\\'")))
    (cdr-safe (cdr (seq-find (lambda (e) (equal (car-safe (car e)) regexp)) which-key-replacement-alist)))))

(ert-deftest drgnx-modal-report/which-key-labels-the-leader ()
  (skip-unless (require 'which-key nil t))
  (let ((which-key-replacement-alist which-key-replacement-alist))
    (drgnx-modal-report-test--live
      (drgnx-keys-use drgnx-modal-report-test--vim)
      (should (equal (drgnx-modal-report-test--label "SPC f f") "Open File…"))
      (should (equal (drgnx-modal-report-test--label "SPC f") "+File"))
      (drgnx-keys-use drgnx-modal-report-test--vscode)
      (should-not (drgnx-modal-report-test--label "SPC f f"))
      (should-not (drgnx-modal-report-test--label "SPC f")))))

;;;; Shortcuts

(ert-deftest drgnx-modal-report/shortcuts-where-names-states ()
  (should (equal (drgnx-shortcuts--where 'drgnx-modal-leader-map) "normal, visual, motion state and panels"))
  (should (equal (drgnx-shortcuts--where '(evil . evil-normal-state-map)) "normal state"))
  (should (equal (drgnx-shortcuts--where 'drgnx-modal-panel-map) "panels"))
  (should (equal (drgnx-shortcuts--where nil) "global"))
  ;; the short form stays what `drgnx-modal-where' says without VERBOSE
  (should (equal (drgnx-modal-where 'drgnx-modal-leader-map) ""))
  (should (equal (drgnx-modal-where 'drgnx-modal-leader-map t) "normal, visual, motion state and panels"))
  (should (equal (drgnx-modal-where 'evil-motion-state-map t) "motion state")))

;;;; The report file

(ert-deftest drgnx-modal-report/report-carries-the-modal-state ()
  (drgnx-modal-report-test--live
    (drgnx-keys-use drgnx-modal-report-test--vim)
    (should (equal (plist-get (drgnx-modal-report-test--report) :modal) '(:engine evil :running nil :pending nil)))
    (should (equal (plist-get (drgnx-modal-report-test--report) :leader-menu-key) "M-SPC"))
    (drgnx-keys-use drgnx-modal-report-test--vscode)
    (should (equal (plist-get (drgnx-modal-report-test--report) :modal) '(:engine nil :running nil :pending nil)))
    (should-not (plist-get (drgnx-modal-report-test--report) :leader-menu-key))))

(ert-deftest drgnx-modal-report/report-reads-pending-layers-as-data ()
  (drgnx-modal-report-test--live
    (drgnx-keys-use drgnx-modal-report-test--vscode)
    (setq drgnx-keys-last (plist-put drgnx-keys-last :pending-layers '((vim app editing window))))
    (drgnx-keys--write-report)
    (should (equal (plist-get (plist-get (drgnx-modal-report-test--report) :modal) :pending) '((vim app editing window))))))

(ert-deftest drgnx-modal-report/report-follows-the-engine-start ()
  ;; The report is first written before the after-apply functions start the engine: it is written again.
  (drgnx-modal-report-test--live
    (let ((drgnx-modal-engines nil))
      (drgnx-modal-define-engine 'evil :module 'editor/evil :start #'ignore :stop #'ignore)
      (let ((drgnx-keys-after-apply-functions (list #'drgnx-modal-sync-engine)))
        (drgnx-keys-use drgnx-modal-report-test--vim)
        (should (equal (plist-get (drgnx-modal-report-test--report) :modal) '(:engine evil :running t :pending nil)))
        (drgnx-keys-use drgnx-modal-report-test--vscode)
        (should (equal (plist-get (drgnx-modal-report-test--report) :modal) '(:engine nil :running nil :pending nil)))))))

;;;; The doctor

(ert-deftest drgnx-modal-report/doctor-warns-without-the-engine ()
  (drgnx-modal-report-test--live
    (drgnx-keys-use drgnx-modal-report-test--vim)
    (let* ((report (drgnx-modal-report-test--report))
           (fix "drgnx sync, then restart — or Keyboard Profile… to choose another")
           (check (lambda (modules &optional other)
                    (drgnx-doctor-check 'modal (drgnx-modal-report-test--facts :keys-report (or other report)
                                                                               :modules-report modules)))))
      (let ((r (funcall check '((editor/evil :status missing-packages :missing (evil))))))
        (should (eq (car r) 'warn))
        (should (string-search "Vim keys need evil (not installed)" (nth 1 r)))
        (should (equal (nth 2 r) fix)))
      (let ((r (funcall check '((editor/evil :status ok)))))
        (should (eq (car r) 'warn))
        (should (string-search "Vim keys need evil (installed, not running: restart drgnx)" (nth 1 r)))
        (should (equal (nth 2 r) fix)))
      (let ((r (funcall check '((editor/evil :status ok))
                        (plist-put (copy-sequence report) :modal '(:engine evil :running t :pending nil)))))
        (should (eq (car r) 'ok))))
    (drgnx-keys-use drgnx-modal-report-test--vscode)
    (let ((r (drgnx-doctor-check 'modal (drgnx-modal-report-test--facts :keys-report (drgnx-modal-report-test--report)))))
      (should (eq (car r) 'ok))
      (should (string-search "no modal engine needed" (nth 1 r))))
    ;; no report yet, or one from before the modal state was reported
    (should (eq (car (drgnx-doctor-check 'modal (drgnx-modal-report-test--facts))) 'info))
    (should (eq (car (drgnx-doctor-check 'modal (drgnx-modal-report-test--facts :keys-report '(:layers ((vscode app)))))) 'ok))))

(ert-deftest drgnx-modal-report/doctor-says-vim-waits-for-sync ()
  (let ((r (drgnx-doctor-check 'modal (drgnx-modal-report-test--facts
                                       :keys-report '(:modal (:engine nil :running nil :pending ((vim app editing window))))))))
    (should (eq (car r) 'info))
    (should (string-search "Vim waits for drgnx sync" (nth 1 r)))))

(ert-deftest drgnx-modal-report/doctor-notes-gnome-alt-space ()
  (drgnx-modal-report-test--live
    (drgnx-keys-use drgnx-modal-report-test--vim)
    (let* ((running (plist-put (copy-sequence (drgnx-modal-report-test--report)) :modal '(:engine evil :running t :pending nil)))
           (check (lambda (desktop report)
                    (drgnx-doctor-check 'modal (drgnx-modal-report-test--facts :keys-report report :desktop desktop)))))
      (let ((r (funcall check "ubuntu:GNOME" running)))
        (should (eq (car r) 'info))
        (should (string-search "Alt+Space opens GNOME's window menu before drgnx sees it: Settings → Keyboard → Keyboard Shortcuts → Windows"
                               (nth 1 r)))
        (should (string-search "M-SPC replaces Emacs' cycle-spacing" (nth 1 r))))
      (let ((r (funcall check "KDE" running)))
        (should (eq (car r) 'ok))
        (should (string-search "M-SPC replaces Emacs' cycle-spacing" (nth 1 r))))
      ;; the Leader Menu on another key: nothing to say about GNOME or cycle-spacing
      (let ((r (funcall check "GNOME" (plist-put (copy-sequence running) :leader-menu-key "C-c SPC"))))
        (should (eq (car r) 'ok))
        (should-not (string-search "cycle-spacing" (nth 1 r)))))
    ;; the desktop is a fact
    (let ((process-environment (cons "XDG_CURRENT_DESKTOP=GNOME" process-environment)))
      (should (equal (plist-get (cl-letf (((symbol-function 'drgnx-doctor--search) #'ignore)) (drgnx-doctor-facts)) :desktop)
                     "GNOME")))))

(ert-deftest drgnx-modal-report/m-spc-over-cycle-spacing-is-listed ()
  (drgnx-modal-report-test--live
    (drgnx-keys-use drgnx-modal-report-test--vim)
    (should (seq-find (lambda (l) (string-search "cycle-spacing" l)) (drgnx-modal-default-notes)))
    (should (seq-find (lambda (l) (string-search "cycle-spacing" l)) (plist-get (drgnx-modal-report-test--report) :conflicts)))
    (drgnx-surfaces-cheatsheet)
    (with-current-buffer "*drgnx keys*"
      (should (string-match-p "Key conflicts[^z-a]*\n  M-SPC .*cycle-spacing" (buffer-string))))
    (drgnx-keys-use drgnx-modal-report-test--vscode)
    (should-not (drgnx-modal-default-notes))
    (should-not (seq-find (lambda (l) (string-search "cycle-spacing" l)) (plist-get (drgnx-modal-report-test--report) :conflicts)))))

(ert-deftest drgnx-modal-report/m-spc-is-listed-once-with-an-emacs-layer ()
  ;; With an Emacs layer the resolver reports the clash itself: the note would repeat it.
  (drgnx-modal-report-test--live
    (drgnx-keys-use '((emacs app editing window) (vim app editing window)))
    (should-not (drgnx-modal-default-notes))
    (should (= 1 (seq-count (lambda (l) (string-search "cycle-spacing" l))
                            (plist-get (drgnx-modal-report-test--report) :conflicts))))))

(ert-deftest drgnx-modal-report/state-conflicts-reach-the-doctor ()
  (drgnx-modal-report-test--live
    (drgnx-keys-use drgnx-modal-report-test--mixed)
    (let* ((report (drgnx-modal-report-test--report))
           (line (seq-find (lambda (l) (string-prefix-p "C-o " l)) (plist-get report :conflicts)))
           (r (drgnx-doctor-check 'key-conflicts (drgnx-modal-report-test--facts :keys-report report))))
      (should line)
      (should (string-search "in insert state and panels" line))
      (should (string-match-p (format "\\`%d key conflicts" (length (plist-get report :conflicts))) (nth 1 r))))))

(provide 'modal-report-test)
;;; modal-report-test.el ends here
