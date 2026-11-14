;;; plugins-ui-test.el --- batch tests: the plugins page, approving, the per-project choice, the plugin notice -*- lexical-binding: t -*-
;; test-class: det

;; SPDX-License-Identifier: GPL-3.0-or-later

;; The hub is not running: `plugins/list' rows are fed to the page as the hub sends them (decoded JSON), and
;; `drgnx-hub-call' is stubbed to record the calls the user's commands make.  Pure (pattern D): no process, no timer.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-notice)
(require 'drgnx-hub-client)
(require 'drgnx-settings-workspace)
(require 'drgnx-settings-editors)
(load (expand-file-name "modules/tools/drgnx-plugins-ui" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/notice-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)

(defconst drgnx-plugins-ui-test--hash-a (make-string 64 ?a))
(defconst drgnx-plugins-ui-test--hash-b (make-string 64 ?b))

(defun drgnx-plugins-ui-test--row (&rest plist)
  "A `plugins/list' row (decoded JSON) for \"deny-rm\", with PLIST over its defaults."
  (append plist
          (list :name "deny-rm" :version "0.1" :hash drgnx-plugins-ui-test--hash-a :state "unapproved"
                :abilities '("rm_check")
                :hooks '((:point "before-tool" :verdicts ("allow" "deny" "change") :tool_kinds ("execute") :tools ("Bash"))
                         (:point "after-edit" :verdicts ("annotate" "change") :paths ("src/**"))
                         (:point "before-commit" :verdicts ("change")))
                :hosts '("api.example.com:443") :kv_bytes 65536)))

(defmacro drgnx-plugins-ui-test--with (rows calls &rest body)
  "BODY on a fresh page buffer showing ROWS, with `drgnx-hub-call' pushing (METHOD . PARAMS) onto CALLS and answering
done, and every prompt signalling."
  (declare (indent 2))
  `(let ((drgnx-plugins--rows ,rows) (,calls nil) (inhibit-message t))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params cb &rest _)
                  (push (cons method params) ,calls)
                  (funcall cb (and (equal method "plugins/list") (list :plugins ,rows)) nil)
                  1))
               ((symbol-function 'read-string) (lambda (&rest _) (error "prompted")))
               ((symbol-function 'completing-read) (lambda (&rest _) (error "prompted")))
               ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "prompted")))
               ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "prompted"))))
       (with-temp-buffer
         (drgnx-plugins-page-mode)
         ,@body))))

(defun drgnx-plugins-ui-test--draw ()
  (drgnx-plugins--render)
  (buffer-substring-no-properties (point-min) (point-max)))

;;;; The approval screen

(ert-deftest drgnx-plugins-ui/approval-lists-each-hooks-reach ()
  (drgnx-plugins-ui-test--with (list (drgnx-plugins-ui-test--row)) calls
    (let ((text (drgnx-plugins-ui-test--draw)))
      ;; the plugin and its hash, abilities and hosts
      (dolist (want (list "deny-rm 0.1" drgnx-plugins-ui-test--hash-a "rm_check" "api.example.com:443"
                          "not approved yet: it does not run"))
        (should (string-search want text)))
      ;; each hook: its point, the verdicts it may give, what it matches
      (should (string-search "before-tool: may allow, deny, change · only on kinds execute · tools Bash" text))
      (should (string-search "after-edit: may annotate, change · only on paths src/**" text))
      (should (string-search "before-commit: may change · on everything the point sees" text))
      ;; for change: what it may rewrite, by point
      (should (string-search "it may rewrite the arguments of Bash" text))
      (should (string-search "it may rewrite the file contents of writes" text))
      (should (string-search "it may rewrite the commit message" text))
      ;; what the plugin sees, where it may send it, and the shared store
      (should (string-search "diffs and file contents in the projects where it is enabled" text))
      (should (string-search "It may send it to: api.example.com:443" text))
      (should (string-search "up to 64 KiB, shared across the projects where it is enabled" text)))
    (should-not calls)))

(ert-deftest drgnx-plugins-ui/a-plugin-with-no-hooks-and-no-hosts-says-so ()
  (drgnx-plugins-ui-test--with (list (drgnx-plugins-ui-test--row :hooks nil :hosts nil :kv_bytes nil)) calls
    (let ((text (drgnx-plugins-ui-test--draw)))
      (should (string-search "Hooks: none" text))
      (should (string-search "It may send nothing out: it has no hosts." text))
      (should (string-search "nothing of your projects (it has no hooks)" text)))))

(ert-deftest drgnx-plugins-ui/a-changed-plugin-shows-what-you-approved-beside-what-it-asks-now ()
  (drgnx-plugins-ui-test--with
      (list (drgnx-plugins-ui-test--row :state "changed" :hosts '("api.example.com:443" "evil.example.com:443")
                                        :approved_reach '(:abilities ("rm_check") :hosts ("api.example.com:443")
                                                                     :hooks ((:point "before-tool" :verdicts ("deny"))))))
      calls
    (let ((text (drgnx-plugins-ui-test--draw)))
      (should (string-search "changed since you approved it: it does not run until you approve it again" text))
      (should (string-search "What you approved before" text))
      (should (string-search "before-tool: may deny" text))
      (should (string-search "evil.example.com:443" text))
      (should (string-search "[Approve this version]" text)))))

(ert-deftest drgnx-plugins-ui/approve-sends-the-displayed-hash ()
  (drgnx-plugins-ui-test--with (list (drgnx-plugins-ui-test--row)) calls
    (drgnx-plugins--render)
    ;; the files changed on disk after the page was drawn: a fresh `plugins/list' would say hash B; Approve must not use it
    (setq drgnx-plugins--rows (list (drgnx-plugins-ui-test--row :hash drgnx-plugins-ui-test--hash-b)))
    (goto-char (point-min))
    (drgnx-plugins-approve-at-point)
    (should (equal (seq-find (lambda (c) (equal (car c) "plugins/approve")) calls)
                   (list "plugins/approve" :name "deny-rm" :hash drgnx-plugins-ui-test--hash-a)))
    ;; and the button on the page does the same
    (setq calls nil)
    (goto-char (point-min))
    (search-forward "[Approve this version]")
    (backward-char 2)
    (push-button)
    (should (equal (seq-find (lambda (c) (equal (car c) "plugins/approve")) calls)
                   (list "plugins/approve" :name "deny-rm" :hash drgnx-plugins-ui-test--hash-a)))))

(ert-deftest drgnx-plugins-ui/approve-needs-a-plugin-at-point-and-a-readable-hash ()
  (drgnx-plugins-ui-test--with (list (drgnx-plugins-ui-test--row :hash nil :state "broken" :problem "bad json")) calls
    (let ((text (drgnx-plugins-ui-test--draw)))
      (should (string-search "broken: bad json" text))
      (should-not (string-search "[Approve" text)))
    (goto-char (point-min))
    (should-error (drgnx-plugins-approve-at-point) :type 'user-error)
    (should-not calls))
  (drgnx-plugins-ui-test--with nil calls
    (should (string-search "No plugins installed." (drgnx-plugins-ui-test--draw)))
    (should-error (drgnx-plugins-approve-at-point) :type 'user-error)))

(ert-deftest drgnx-plugins-ui/disable-asks-the-hub-and-draws-the-pages-again ()
  (drgnx-plugins-ui-test--with (list (drgnx-plugins-ui-test--row :state "approved")) calls
    (drgnx-plugins--render)
    (goto-char (point-min))
    (drgnx-plugins-disable-at-point)
    (should (equal (reverse (mapcar #'car calls)) '("plugins/disable" "plugins/list")))
    (should (equal (cdr (seq-find (lambda (c) (equal (car c) "plugins/disable")) calls)) '(:name "deny-rm")))))

;;;; In this project

(ert-deftest drgnx-plugins-ui/in-this-project-shows-the-projects-own-list ()
  (drgnx-plugins-ui-test--with (list (drgnx-plugins-ui-test--row :state "approved")) calls
    (cl-letf (((symbol-function 'drgnx-setting-for-root)
               (lambda (var _root)
                 (pcase var ('drgnx-agents-plugins '("other")) ('drgnx-agents-hook-rules '((:id "a") (:id "b")))
                        ('drgnx-agents-hook-rules-off '("b")))))
              ((symbol-function 'drgnx-plugins--project-root) (lambda () "/w/proj/")))
      (setq drgnx-plugins--root "/w/proj/")
      (let ((text (drgnx-plugins-ui-test--draw)))
        (should (string-search "In this project: does not run" text))
        (should (string-search "this project's plugins: other" text))
        (should (string-search "hook rules in force: 2 · switched off here: b" text))
        (should (string-search "[Turn on in this project]" text))))))

(ert-deftest drgnx-plugins-ui/the-project-choice-is-written-through-the-one-writer ()
  (let (written (list '("other")))
    (cl-letf (((symbol-function 'drgnx-setting-for-root) (lambda (&rest _) list))
              ((symbol-function 'drgnx-settings-editors-commit)
               (lambda (var tab root value) (push (list var tab root value) written) (setq list value))))
      (let ((inhibit-message t))
        (drgnx-plugins-project-toggle "deny-rm" "/w/proj/")
        (drgnx-plugins-project-toggle "other" "/w/proj/"))
      (should (equal (reverse written)
                     '((drgnx-agents-plugins workspace "/w/proj/" ("other" "deny-rm"))
                       (drgnx-agents-plugins workspace "/w/proj/" ("deny-rm"))))))))

(ert-deftest drgnx-plugins-ui/no-project-means-no-toggle ()
  (drgnx-plugins-ui-test--with (list (drgnx-plugins-ui-test--row :state "approved")) calls
    (setq drgnx-plugins--root nil)
    (let ((text (drgnx-plugins-ui-test--draw)))
      (should (string-search "no project" text))
      (should-not (string-search "in this project]" text)))
    (goto-char (point-min))
    (should-error (drgnx-plugins-project-toggle-at-point) :type 'user-error)))

(ert-deftest drgnx-plugins-ui/other-pages-add-sections-after-the-header ()
  (drgnx-plugins-ui-test--with (list (drgnx-plugins-ui-test--row)) calls
    (let ((drgnx-plugins-page-sections (list (lambda (name row) (insert (format "EXTRA %s %s\n" name (plist-get row :state)))))))
      (let ((text (drgnx-plugins-ui-test--draw)))
        (should (string-search "EXTRA deny-rm unapproved" text))
        (should (< (string-search "EXTRA" text) (string-search "What it may reach" text)))))))

;;;; The notice

(ert-deftest drgnx-plugins-ui/a-plugin_event-makes-a-notice-that-opens-its-page ()
  (drgnx-notice-test-with-model
    (cl-letf (((symbol-function 'drgnx-hub--event-proven-p) (lambda () t)))
      (drgnx-hub--note-plugin "plugin" '(:name "deny-rm" :state "unapproved"))
      (let ((n (car (drgnx-notices :source 'hub))))
        (should (string-search "Plugin deny-rm waits for your approval" (plist-get n :text)))
        (should (equal (plist-get n :command) '(drgnx-plugins-page-open "deny-rm"))))
      (drgnx-hub--note-plugin "plugin" '(:name "deny-rm" :state "changed"))
      (should (string-search "changed since you approved it" (plist-get (car (drgnx-notices :source 'hub)) :text)))
      (should (= 1 (length (drgnx-notices :source 'hub))))
      ;; approved, disabled or removed: nothing waits any more
      (drgnx-hub--note-plugin "plugin" '(:name "deny-rm" :state "approved"))
      (should-not (drgnx-notices :source 'hub))
      (drgnx-hub--note-plugin "plugin" '(:name "x" :state "broken"))
      (drgnx-hub--note-plugin "plugin" '(:name "x" :state "removed"))
      (should-not (drgnx-notices :source 'hub)))))

(ert-deftest drgnx-plugins-ui/a-plugin-card-makes-the-same-notice-and-a-stranger-makes-none ()
  (drgnx-notice-test-with-model
    (cl-letf (((symbol-function 'drgnx-hub--event-proven-p) (lambda () t)))
      (drgnx-hub--note-plugin "card" '(:id 3 :kind "plugin" :subject "deny-rm"))
      (should (string-search "deny-rm" (plist-get (car (drgnx-notices :source 'hub)) :text))))
    (drgnx-notice-clear 'hub 'plugin-deny-rm)
    (cl-letf (((symbol-function 'drgnx-hub--event-proven-p) (lambda () nil)))
      (drgnx-hub--note-plugin "plugin" '(:name "deny-rm" :state "unapproved"))
      (should-not (drgnx-notices :source 'hub)))))

(ert-deftest drgnx-plugins-ui/opening-never-prompts-and-approves-nothing ()
  (drgnx-plugins-ui-test--with (list (drgnx-plugins-ui-test--row)) calls
    (cl-letf (((symbol-function 'drgnx-hub-ensure) #'ignore) ((symbol-function 'pop-to-buffer) #'ignore)
              ((symbol-function 'drgnx-plugins--project-root) (lambda () nil)))
      (let ((inhibit-interaction t))
        (kill-buffer (drgnx-plugins-open))
        (kill-buffer (drgnx-plugins-page-open "deny-rm"))))
    (should (equal (delete-dups (mapcar #'car calls)) '("plugins/list")))))

;;;; The module

(ert-deftest drgnx-plugins-ui/the-module-sets-up-and-turns-off-cleanly ()
  (drgnx-test-with-modules '(tools/plugins) :strict t
                           (should (drgnx-commands-get 'plugins-open))
                           (should (drgnx-commands-get 'plugins-approve))
                           (should (equal (drgnx-cmd-category (drgnx-commands-get 'plugins-open)) "Settings"))))

(provide 'plugins-ui-test)
;;; plugins-ui-test.el ends here
