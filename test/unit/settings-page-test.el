;;; settings-page-test.el --- the Settings page -*- lexical-binding: t -*-
;; test-class: cond

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Preferences: Settings (design §7): scope tabs, groups, search and filters, a row's source and the §4.3 message,
;; Reset, the view drawing the visible rows first, safe mode, converting old project files.  Each test runs in a
;; child Emacs under a temp HOME (test/settings-child.el): provenance, files and registry must not reach the runner.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/settings-child" drgnx-dir) nil t)

(defconst drgnx-settings-page-test--head ";;; -*- lexical-binding: t -*-\n" "A Lisp file's first line.")

(defconst drgnx-settings-page-test--decls
  '((require 'drgnx-settings-page)
    (defgroup sat-pg nil "Test group." :group 'tools)
    (drgnx-defsetting sat-pg-buf 1 "A buffer setting.  More." :type 'integer :group 'sat-pg)
    (drgnx-defsetting sat-pg-glob 1 "A global setting." :type 'integer :group 'sat-pg :scope 'global)
    (drgnx-defsetting sat-pg-over 1 "Overridden by Lisp." :type 'integer :group 'sat-pg :scope 'global)
    (drgnx-defsetting sat-pg-mod 1 "Modified in settings." :type 'integer :group 'sat-pg :scope 'global)
    (drgnx-defsetting sat-pg-plain 1 "Never changed." :type 'integer :group 'sat-pg :scope 'global)
    (drgnx-defsetting sat-pg-rt 1 "Runtime." :type 'integer :group 'sat-pg :scope 'global :runtime t))
  "Forms that declare the settings the tests use.")

(defun drgnx-settings-page-test--run (files forms &optional env)
  "Run FORMS in a child with FILES after the declarations; the value of the last."
  (let ((r (drgnx-settings-test-child (append drgnx-settings-page-test--decls forms) :files files :env env)))
    (unless (and (null (plist-get r :error)) (equal (plist-get r :exit) 0))
      (ert-fail (list :error (plist-get r :error) :output (plist-get r :output))))
    (car (last (plist-get r :values)))))

(defconst drgnx-settings-page-test--files
  `(("settings.el" . "(drgnx-settings :version 1\n (sat-pg-mod 5)\n (sat-pg-over 2)\n (sat-pg-plain 1)\n (:mode python-mode (sat-pg-mod 7)))\n")
    ("config.el" . ,(concat drgnx-settings-page-test--head "(setq sat-pg-over 3)\n")))
  "A settings.el and a config.el that overrides one of its entries.")

(defconst drgnx-settings-page-test--load-config
  '(progn (drgnx-settings-prov-watch 'sat-pg-over)
          (let ((f (expand-file-name "config.el" (drgnx-user-dir))))
            (drgnx-settings-prov-with-load f (load f nil t t)))
          t)
  "The form that loads config.el as your Lisp.")

(ert-deftest drgnx-settings-page/opens-from-the-palette ()
  (let ((r (drgnx-settings-page-test--run
            nil
            '((drgnx-config-register-commands)
              (let ((c (drgnx-commands-get 'preferences-settings)))
                (with-current-buffer (drgnx-settings-page 'editor)
                  (drgnx-view-draw-now drgnx-view)
                  (list (and c (drgnx-cmd-title c)) (and c (drgnx-cmd-category c)) major-mode (and drgnx-view t)
                        (and (string-match-p "Scope: " (buffer-string)) t)
                        (and (drgnx-commands-get 'settings-undo) t))))))))
    (should (equal r '("Settings" "Preferences" drgnx-settings-page-mode t t t)))))

(ert-deftest drgnx-settings-page/groups-and-pages ()
  (let ((r (drgnx-settings-page-test--run
            nil
            '((list (mapcar (lambda (g) (cons (plist-get g :id) (plist-get g :kind))) (drgnx-settings-page-groups))
                    (and (progn (drgnx-defsetting drgnx-search-sat 1 "Doc." :type 'integer :group 'tools)
                                (memq 'drgnx-search-sat (drgnx-settings-page-vars '(area . search) nil))) t)
                    (cl-some (lambda (v) (string-prefix-p "drgnx-keys" (symbol-name v)))
                             (drgnx-settings-page-vars '(area . workbench) nil))
                    (drgnx-settings-page-vars '(package . sat-pg) nil)
                    (progn (require 'drgnx-modules)
                           (with-current-buffer (drgnx-settings-page)
                             (buffer-name (drgnx-settings-page-set-group 'modules)))))))))
    (let ((groups (nth 0 r)))
      (dolist (g '((keys . page) (modules . page) (lisp-files . page) (history . page) (editor . area) (look . area)
                   (packages . packages) (emacs . emacs) (workspace . workspace)))
        (should (member g groups))))
    (should (nth 1 r))
    (should-not (nth 2 r))
    (should (equal (nth 3 r) '(sat-pg-buf sat-pg-glob sat-pg-mod sat-pg-over sat-pg-plain sat-pg-rt)))
    (should (equal (nth 4 r) "*drgnx modules*"))))

(ert-deftest drgnx-settings-page/default-tab-follows-scope ()
  (let ((r (drgnx-settings-page-test--run
            '(("~/proj/.git/HEAD" . "ref: x\n"))
            '((let ((root (file-name-as-directory (expand-file-name "proj" (getenv "HOME"))))
                    (plain (file-name-as-directory (expand-file-name "plain" (getenv "HOME")))))
                (make-directory plain t)
                (drgnx-defsetting sat-pg-proj 1 "A project setting." :type 'integer :scope 'project)
                (list (drgnx-settings-page-default-tab 'sat-pg-buf root)
                      (drgnx-settings-page-default-tab 'sat-pg-proj root)
                      (drgnx-settings-page-default-tab 'sat-pg-glob root)
                      (drgnx-settings-page-default-tab 'sat-pg-buf plain)
                      (drgnx-settings-page-default-tab 'sat-pg-buf nil)))))))
    (should (equal r '(workspace workspace user user user)))))

(ert-deftest drgnx-settings-page/global-rows-have-no-workspace-tabs ()
  (let ((r (drgnx-settings-page-test--run
            '(("~/proj/.git/HEAD" . "ref: x\n"))
            '((let ((root (file-name-as-directory (expand-file-name "proj" (getenv "HOME")))))
                (list (drgnx-settings-page-tabs-for 'sat-pg-glob root)
                      (drgnx-settings-page-tabs-for 'sat-pg-buf root)
                      (drgnx-settings-page-tabs-for 'sat-pg-buf nil)
                      (and (string-match-p "one value for all of Emacs"
                                           (drgnx-settings-page-row-text (drgnx-settings-page-row 'sat-pg-glob 'workspace root)))
                           t)
                      (let ((enable-local-variables nil)) (and (drgnx-settings-page-tab-note 'workspace) t))
                      (drgnx-settings-page-tab-note 'user)
                      (condition-case nil (progn (drgnx-settings-page-reset 'sat-pg-glob 'workspace root) 'no)
                        (user-error 'refused))))))))
    (should (equal r '((user) (user workspace shared) (user) t t nil refused)))))

(ert-deftest drgnx-settings-page/filters ()
  (let ((r (drgnx-settings-page-test--run
            drgnx-settings-page-test--files
            (list drgnx-settings-page-test--load-config
                  '(let ((sel (lambda (q) (cl-remove-if-not (lambda (v) (string-prefix-p "sat-pg-" (symbol-name v)))
                                                            (drgnx-settings-page-select nil q nil nil)))))
                     (list (funcall sel "@modified sat-pg")
                           (funcall sel "@overridden sat-pg")
                           (funcall sel "@source:lisp sat-pg")
                           (funcall sel "@source:settings sat-pg")
                           (funcall sel "@runtime sat-pg")
                           (funcall sel "@lang:python sat-pg")
                           (funcall sel "@package:sat sat-pg-b")
                           (funcall sel "never changed")
                           (funcall sel "@modified sat-pg never")))))))
    (should (equal (nth 0 r) '(sat-pg-mod sat-pg-over sat-pg-plain)))
    (should (equal (nth 1 r) '(sat-pg-over)))
    (should (equal (nth 2 r) '(sat-pg-over)))
    (should (equal (nth 4 r) '(sat-pg-rt)))
    (should (equal (nth 5 r) '(sat-pg-mod)))
    (should (equal (nth 6 r) '(sat-pg-buf)))
    (should (equal (nth 7 r) '(sat-pg-plain)))
    (should (equal (nth 8 r) (quote (sat-pg-plain))))))

(ert-deftest drgnx-settings-page/overridden-message-with-actions ()
  (let ((s (drgnx-settings-page-test--run
            drgnx-settings-page-test--files
            (list drgnx-settings-page-test--load-config
                  '(substring-no-properties
                    (drgnx-settings-page-row-text (drgnx-settings-page-row 'sat-pg-over 'user nil)))))))
    (progn
      (should (string-match-p "Your Lisp sets this" s))
      (should (string-match-p "config.el:" s))
      (should (string-match-p "(setq sat-pg-over 3)" s))
      (should (string-match-p "so 3 stays in effect" s))
      (should (string-match-p "Your change (2)" s))
      (should (string-match-p "\\[Open config.el:[0-9]+\\]" s))
      (should (string-match-p "\\[Move into Settings\\]" s)))))

(ert-deftest drgnx-settings-page/reset-removes-this-scopes-entry ()
  (let ((r (drgnx-settings-page-test--run
            drgnx-settings-page-test--files
            '((list (drgnx-settings-page-reset 'sat-pg-mod 'user nil)
                    (drgnx-settings-page-reset 'sat-pg-mod 'user nil)
                    (with-temp-buffer
                      (insert-file-contents (expand-file-name "settings.el" (drgnx-user-dir)))
                      (buffer-string)))))))
    (should (eq (nth 0 r) t))
    (should-not (nth 1 r))
    (should-not (string-match-p "(sat-pg-mod 5)" (nth 2 r)))
    (should (string-match-p "(sat-pg-mod 7)" (nth 2 r)))   ; the language entry stays
    (should (string-match-p "(sat-pg-over 2)" (nth 2 r)))))

(ert-deftest drgnx-settings-page/draws-visible-rows-only ()
  (let ((r (drgnx-settings-page-test--run
            nil
            '((progn (defgroup sat-big nil "Many." :group 'tools)
                     (dotimes (i 300)
                       (eval `(defcustom ,(intern (format "sat-big-%03d" i)) 1 "Doc." :type 'integer :group 'sat-big) t))
                     t)
              (with-current-buffer (drgnx-settings-page)
                (switch-to-buffer (current-buffer))
                (drgnx-settings-page-set-group 'packages 'sat-big)
                (let ((total (length drgnx-settings-page--keys))
                      (drawn (drgnx-view--draw drgnx-view drgnx-view-slice)))
                  (list total drawn (and (string-match-p "Sat Big 000" (buffer-string)) t)
                        (and (string-match-p "Sat Big 299" (buffer-string)) t)))))))
        )
    (should (= (nth 0 r) 300))
    (should (> (nth 1 r) 0))
    (should (< (nth 1 r) 300))
    (should (nth 2 r))
    (should-not (nth 3 r))))

(ert-deftest drgnx-settings-page/a-search-keystroke-draws-no-row-that-stays ()
  "Pattern D.  A search changes which rows are listed, not what a row shows: the rows that stay are not drawn again
and a row that comes back takes its kept data (each row's data is a provenance lookup).  A refresh draws them all."
  (let ((r (drgnx-settings-page-test--run
            nil
            '((progn (defgroup sat-ks nil "Many." :group 'tools)
                     (dotimes (i 300)
                       (eval `(defcustom ,(intern (format "sat-ks-%03d" i)) 1 "Doc." :type 'integer :group 'sat-ks) t))
                     t)
              (with-current-buffer (drgnx-settings-page)
                (drgnx-settings-page-search "sat-ks")
                (drgnx-view-draw-now drgnx-view)
                (let ((drawn (lambda () (plist-get (drgnx-view-stats drgnx-view) :rows-drawn)))
                      (explained 0) narrowed back)
                  (advice-add 'drgnx-settings-explain :before (lambda (&rest _) (setq explained (1+ explained)))
                              '((name . sat-ks-count)))
                  (let ((before (funcall drawn)))
                    (drgnx-settings-page-search "sat-ks-1")          ; 300 rows to 100
                    (drgnx-view-draw-now drgnx-view)
                    (setq narrowed (list (length drgnx-settings-page--keys) (- (funcall drawn) before) explained)))
                  (let ((before (funcall drawn)))
                    (drgnx-settings-page-search "sat-ks")            ; the 200 come back
                    (drgnx-view-draw-now drgnx-view)
                    (setq back (list (length drgnx-settings-page--keys) (- (funcall drawn) before) explained)))
                  (let ((before (funcall drawn)))
                    (drgnx-settings-page-refresh)
                    (drgnx-view-draw-now drgnx-view)
                    (advice-remove 'drgnx-settings-explain 'sat-ks-count)
                    (list narrowed back (- (funcall drawn) before)))))))))
    (should (equal (nth 0 r) '(100 0 0)))
    (should (equal (nth 1 r) '(300 200 0)))
    (should (= (nth 2 r) 300))))

(ert-deftest drgnx-settings-page/typing-a-search-keeps-the-variable-list ()
  ;; a keystroke narrows the list it already has; a refresh reads the variables again; a term may match a value only
  (let ((r (drgnx-settings-page-test--run
            nil
            '((progn
                (eval '(defcustom sat-ks-a 4242 "Width." :type 'integer :group 'tools) t)
                (with-current-buffer (drgnx-settings-page)
                  (drgnx-settings-page-search "sat-ks")
                  (let ((all drgnx-settings-page--all))
                    (drgnx-settings-page-search "sat-ks-a")
                    (let ((kept (eq all drgnx-settings-page--all)) (keys drgnx-settings-page--keys)
                          (prior drgnx-settings-page--prior))
                      (drgnx-settings-page-search "4242")
                      (let ((by-value (and (memq 'sat-ks-a drgnx-settings-page--keys) t)))
                        (set-default 'sat-ks-a 9999)           ; a new value is found, the old one is not
                        (drgnx-settings-page-search "9999")
                        (let ((new (and (memq 'sat-ks-a drgnx-settings-page--keys) t)))
                          (drgnx-settings-page-search "4242")
                          (let ((old (and (memq 'sat-ks-a drgnx-settings-page--keys) t)))
                            (drgnx-settings-page-refresh)
                            (list kept keys prior by-value new old (eq all drgnx-settings-page--all)
                                  drgnx-settings-page--prior))))))))))))
    ;; a longer query starts from the last one's matches; a refresh searches again from all of them
    (should (equal r '(t (sat-ks-a) ("sat-ks-a" sat-ks-a) t t nil nil ("4242"))))))

(ert-deftest drgnx-settings-page/the-search-text-is-built-before-the-first-key ()
  ;; opening the page warms every setting's search text in idle time; the first character builds none of it
  (let ((r (drgnx-settings-page-test--run
            nil
            '((progn
                (eval '(defcustom sat-wm-a 4242 "Width." :type 'integer :group 'tools) t)
                (with-current-buffer (drgnx-settings-page)
                  (let* ((total (length (drgnx-settings-page--all-vars))) (pending (and drgnx-settings-page--warm t))
                         ;; the open itself builds the text of the rows it draws, not of the settings it lists
                         (at-open (< (hash-table-count drgnx-settings-page--hay) (/ total 10))))
                    (while (drgnx-settings-page--warm-step))
                    (let ((text (hash-table-count drgnx-settings-page--hay))
                          (values (hash-table-count drgnx-settings-page--value-hay)))
                      (drgnx-settings-page-search "sat-wm")
                      (list pending at-open (= text total) (= values total)
                            (= (hash-table-count drgnx-settings-page--hay) text)
                            (= (hash-table-count drgnx-settings-page--value-hay) values)
                            (and (memq 'sat-wm-a drgnx-settings-page--keys) t))))))))))
    (should (equal r '(t t t t t t t)))))

(ert-deftest drgnx-settings-page/works-in-safe-mode ()
  (let ((r (drgnx-settings-page-test--run
            drgnx-settings-page-test--files
            '((with-current-buffer (drgnx-settings-page)
                (drgnx-settings-page-search "sat-pg")
                (drgnx-view-draw-now drgnx-view)
                (list (getenv "DRGNX_SAFE") (and (string-match-p "Scope: " (buffer-string)) t)
                      (and (string-match-p "Sat Pg Mod" (buffer-string)) t))))
            '("DRGNX_SAFE=1"))))
    (should (equal r '("1" t t)))))

(ert-deftest drgnx-settings-page/convert-old-project-files ()
  (let ((r (drgnx-settings-page-test--run
            '(("~/proj/.git/HEAD" . "ref: x\n")
              ("~/proj/.drgnx/search.eld" . "(:include (\"*.md\") :exclude (\"vendor/\"))\n"))
            '((progn
                (require 'drgnx-settings-runtime)
                (let* ((root (file-name-as-directory (expand-file-name "proj" (getenv "HOME"))))
                       (n (drgnx-settings-page-convert root)))
                  (list n
                        (with-temp-buffer
                          (insert-file-contents (expand-file-name ".drgnx/settings.el" root))
                          (buffer-string))
                        (file-exists-p (expand-file-name ".drgnx/search.eld" root)))))))))
    (should (= (car r) 2))
    (should (string-match-p "drgnx-search-include" (nth 1 r)))
    (should (string-match-p "\"vendor/\"" (nth 1 r)))
    (should-not (nth 2 r))))

(provide 'settings-page-test)
;;; settings-page-test.el ends here
