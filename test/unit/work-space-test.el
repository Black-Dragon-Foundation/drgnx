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
