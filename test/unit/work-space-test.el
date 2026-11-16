;;; work-space-test.el --- the Work space module: its views open and close with it, its keys in every profile -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: the map client's calls are caught at `drgnx-work-client--call'.  The map on the hub's rows against a real
;; hub: test/ui/work-map-rows-gui-test.el and test/ui/work-space-gui-test.el; its keys: work-map-nav-test.el and
;; work-map-rows-test.el.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(require 'drgnx-keys)
(require 'drgnx-work-client)
;; what opening the Work space loads to start the hub (`drgnx-hub-start-for-command' → `drgnx-hub--ensure-running'
;; requires drgnx-ai, which drgnx loads at boot), loaded with the test: the census would read its load-time config
;; definitions and after-load forms as the module's
(require 'drgnx-hub-client)
(require 'drgnx-ai)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(declare-function drgnx-work-space-open "drgnx-work-space")
(defvar drgnx-work-space-command-ids)

(ert-deftest drgnx-work-space/module-off-closes-views-and-kills-buffers ()
  ;; with Sjá the map subscribes; turned off, the module closes the view and the buffer goes
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view--call) "nidhogg-view--call")
  (let (calls name)
    (cl-letf (((symbol-function 'drgnx-work-client--call)
               (lambda (method params &rest _) (push (cons method params) calls) t)))
      (drgnx-test-with-modules '(tools/work-space) :strict t
                               (setq name (buffer-name (drgnx-work-space-open (list :id "workspace:000000000002" :roots (list temporary-file-directory)))))
                               (should (get-buffer name))
                               (should (assoc "work/map/subscribe" calls))))
    (should-not (get-buffer name))
    (should (assoc "work/map/close" calls))
    (should-not (drgnx-work-client-views))))

(ert-deftest drgnx-work-space/without-sja-the-map-subscribes-to-nothing ()
  ;; an Emacs without Sjá cannot show the hub's rows: the map says so, opens no view, and goes with the module
  (let (calls name)
    (cl-letf (((symbol-function 'drgnx-work-client--call)
               (lambda (method params &rest _) (push (cons method params) calls) t)))
      (drgnx-test-with-modules '(tools/work-space) :strict t
                               (cl-letf (((symbol-function 'drgnx-work-map-rows-p) #'ignore))
                                 (let ((buf (drgnx-work-space-open (list :id "workspace:000000000003" :roots (list temporary-file-directory)) t)))
                                   (setq name (buffer-name buf))
                                   (with-current-buffer buf (drgnx-view-draw-now drgnx-view))
                                   (should (string-search "needs Sjá" (with-current-buffer buf (buffer-string))))
                                   (should-not calls)
                                   (should-not (drgnx-work-client-views))))))
    (should-not (get-buffer name))))

(defmacro drgnx-work-space-test--with-hub (up &rest body)
  "Run BODY, in the Work space module, with the map client's calls caught in `calls' ((METHOD . PARAMS) …, newest
first), the hub's general calls in `hub-calls' ((METHOD PARAMS CALLBACK) …, newest first), and the hub connection
counting as up when UP."
  (declare (indent 1))
  `(let (calls hub-calls)
     (drgnx-test-with-modules '(tools/work-space) :strict t
                              (cl-letf (((symbol-function 'drgnx-work-client--call)
                                         (lambda (method params &rest _) (push (cons method params) calls) ,up))
                                        ((symbol-function 'drgnx-work-space--hub-up-p) (lambda () ,up))
                                        ((symbol-function 'drgnx-hub-call)
                                         (lambda (method params callback &rest _) (push (list method params callback) hub-calls) 1)))
                                ,@body))))

(ert-deftest drgnx-work-space/a-map-that-cannot-load-says-why-in-its-buffer ()
  ;; UX audit (2026-11-16): the Work map stayed blank on a hub that was not there; only the mode line said
  ;; "reconnecting".  The reason is on the map itself now.
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view--call) "nidhogg-view--call")
  (drgnx-work-space-test--with-hub nil
    (cl-letf (((symbol-function 'drgnx-hub-start-for-command)
               (lambda (on-fail) (funcall on-fail "No drgnx hub runs"))))
      (let ((buf (drgnx-work-space-open (list :id "workspace:000000000004" :roots (list temporary-file-directory)) t)))
        (should (string-search "No drgnx hub runs" (format "%s" (buffer-local-value 'header-line-format buf))))))))

(ert-deftest drgnx-work-space/a-map-waiting-for-the-hub-says-so-until-its-rows-come ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view--call) "nidhogg-view--call")
  (drgnx-work-space-test--with-hub nil
    (cl-letf (((symbol-function 'drgnx-hub-start-for-command) #'ignore))
      (let ((buf (drgnx-work-space-open (list :id "workspace:000000000005" :roots (list temporary-file-directory)) t)))
        (should (string-search "hub" (format "%s" (buffer-local-value 'header-line-format buf))))
        (drgnx-work-client--status (drgnx-work-client--get "workspace:000000000005") (quote live))
        (should-not (buffer-local-value 'header-line-format buf))))))

(ert-deftest drgnx-work-space/the-first-open-adopts-the-roots-records-and-draws-them ()
  ;; "drgnx takes over": opening Work imports each root's specs and plans; when the hub answers, the map shows
  ;; finished items too (specs and plans are live only under an agent) and subscribes again to read the store.
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view--call) "nidhogg-view--call")
  (drgnx-work-space-test--with-hub t
    (cl-letf (((symbol-function 'drgnx-hub-start-for-command) #'ignore))
      (let* ((root (file-name-as-directory temporary-file-directory))
             (buf (drgnx-work-space-open (list :id "workspace:000000000006" :roots (list root)) t))
             (import (assoc "records/import" hub-calls)))
        (should import)
        (should (equal (directory-file-name root) (plist-get (nth 1 import) :root)))
        (should (string-search "Adopting" (format "%s" (buffer-local-value 'header-line-format buf))))
        (setq calls nil)
        (funcall (nth 2 import) (list :dry_run :false :files (vector (list :path "a.md" :kind "spec" :entities 1 :ops 1))) nil)
        (should-not (buffer-local-value 'header-line-format buf))
        (should (assoc "work/map/subscribe" calls))
        (should (eq t (plist-get (plist-get (cdr (assoc "work/map/subscribe" calls)) :filters) :finished)))
        ;; the same buffer asks once
        (setq hub-calls nil)
        (drgnx-work-space-open (list :id "workspace:000000000006" :roots (list root)) t)
        (should-not (assoc "records/import" hub-calls))))))

(ert-deftest drgnx-work-space/a-folder-without-records-keeps-its-filters ()
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view--call) "nidhogg-view--call")
  (drgnx-work-space-test--with-hub t
    (cl-letf (((symbol-function 'drgnx-hub-start-for-command) #'ignore))
      (let* ((root (file-name-as-directory temporary-file-directory))
             (buf (drgnx-work-space-open (list :id "workspace:000000000007" :roots (list root)) t))
             (import (assoc "records/import" hub-calls)))
        (setq calls nil)
        (funcall (nth 2 import) (list :dry_run :false :files []) nil)
        (should-not (buffer-local-value 'header-line-format buf))
        (should-not (assoc "work/map/subscribe" calls))))))

(defun drgnx-work-space-test--bound-ids (profile)
  "The command ids PROFILE (an alist entry of the loaded profiles) has a row for."
  (mapcar #'car (plist-get (cdr profile) :bind)))

(ert-deftest drgnx-work-space/keys-in-every-profile ()
  ;; every command of the module has a row in each shipped profile, and none of its keys meets another command's
  (let ((profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
    (should (equal '(emacs vim vscode) (sort (mapcar #'car profiles) (lambda (a b) (string< (symbol-name a) (symbol-name b))))))
    (drgnx-test-with-modules '(tools/work-space)
      (dolist (p profiles)
        (dolist (id drgnx-work-space-command-ids)
          (should (equal (list (car p) id t) (list (car p) id (and (memq id (drgnx-work-space-test--bound-ids p)) t)))))
        (let* ((r (drgnx-keys-resolve :commands (drgnx-commands-all) :profiles profiles
                                      :layers (list (list (car p) 'app 'editing 'window))
                                      :defaults (copy-keymap global-map)))
               ;; two commands on one key (a prefix clash of C-k t is the profile's own, older than this module)
               (mine (seq-filter (lambda (c)
                                   (and (eq (plist-get c :kind) 'same-key)
                                        (seq-some (lambda (b) (memq (plist-get b :id) drgnx-work-space-command-ids))
                                                  (cons (plist-get c :winner) (plist-get c :losers)))))
                                 (plist-get r :conflicts))))
          (should-not mine))))))

(provide 'work-space-test)
;;; work-space-test.el ends here
