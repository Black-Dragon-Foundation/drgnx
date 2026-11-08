;;; extensions-gui-test.el --- GUI rows: the Extensions list and a details page on screen, and the terminal glyphs -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The list is drawn from a fixture (rows as the hub sends them, job states as the job layer gives them), shown in the
;; selected window and captured, then a details page of one row.  The evidence folder (DRGNX_UI_EVIDENCE) keeps the
;; PNGs; run once per display scale (DRGNX_UI_SCALE).  The terminal row draws the same list as a terminal that does not
;; write UTF-8 would see it: the ASCII forms of the kind marks and the busy dot.  No hub is started.
(require 'ert)
(defvar drgnx-view-old-path)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ui-extensions--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-extensions--repo)))
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-ui-extensions--repo) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-details" drgnx-ui-extensions--repo) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-jobs" drgnx-ui-extensions--repo) nil t)

(defun drgnx-ui-extensions--row (name kind state &rest more)
  (append (list :id (format "%s:%s" (pcase kind ("module" "module") (_ "pkg")) name) :kind kind :name name
                :summary (concat name " summary, one line") :state state :source "melpa" :signed "unsigned-archive"
                :version "1.0" :downloads 10)
          more))

(defun drgnx-ui-extensions--fixture ()
  "Fill the list's model: installed, an update, a failed row, a busy row, a module."
  (drgnx-extensions-list--reset)
  (drgnx-extensions-list--receive
   'installed (list (drgnx-ui-extensions--row "magit" "package" "installed" :why '("you"))
                    (drgnx-ui-extensions--row "forge" "package" "installed" :why '((:needed-by ("magit"))))
                    (drgnx-ui-extensions--row "dash" "package" "dependency")
                    (drgnx-ui-extensions--row "vterm" "package" "installed")
                    (drgnx-ui-extensions--row "tools/git" "module" "on")) 5 0)
  (drgnx-extensions-list--receive 'updates (list (drgnx-ui-extensions--row "transient" "package" "update" :latest "0.9")) 1 0)
  (drgnx-extensions-list--receive 'recommended (list (drgnx-ui-extensions--row "rust-mode" "package" "available")) 1 0))

(defmacro drgnx-ui-extensions--with-jobs (&rest body)
  `(let ((drgnx-view-old-path t) (drgnx-extensions-jobs--state (make-hash-table)))
     (drgnx-extensions-jobs--put '(forge) (list :status 'busy :step 'native :i 14 :n 37 :since (- (float-time) 12)))
     (drgnx-extensions-jobs--put '(vterm) (list :status 'failed :error "download failed; nothing was changed"))
     (drgnx-extensions-jobs--put '(dash) (list :status 'done :warnings '("a.el" "b.el")))
     ,@body))

(defun drgnx-ui-extensions--show ()
  (let ((buf (drgnx-extensions-list--buffer)))
    (switch-to-buffer buf)
    (delete-other-windows)
    (drgnx-view-draw-now drgnx-view)
    (redisplay t)
    buf))

(defun drgnx-ui-extensions--shoot (name)
  (let* ((dir (make-temp-file "extensions-shots" t))
         (shot (plist-get (drgnx-uitest-capture dir) :root))
         (out (expand-file-name (format "extensions-%s-s%s.png" name (or (getenv "DRGNX_UI_SCALE") "1")) temporary-file-directory)))
    (should (file-exists-p shot))
    (copy-file shot out t)
    (drgnx-uitest--evidence out)
    (message "extensions screenshot: %s (scale %s)" out (frame-scale-factor))))

(ert-deftest drgnx-ui-extensions/list-in-gui ()
  (drgnx-ui-extensions--with-jobs
   (unwind-protect
       (progn
         (drgnx-ui-extensions--fixture)
         (add-hook 'drgnx-extensions-jobs-changed-functions #'drgnx-extensions-list--jobs-changed)
         (let ((buf (drgnx-ui-extensions--show)))
           (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '(forge vterm dash))
           (drgnx-view-draw-now drgnx-view)
           (redisplay t)
           (with-current-buffer buf
             (should (string-search "native 14/37" (buffer-string)))
             (should (string-search "download failed" (buffer-string)))
             (should (string-search "partly compiled: a.el, b.el" (buffer-string)))
             (should (string-search "Updates (1)" (buffer-string))))
           (drgnx-ui-extensions--shoot "list")
           ;; a details page of the first row
           (let ((page (drgnx-extensions-details-open "pkg:magit")))
             (switch-to-buffer page)
             (drgnx-view-draw-now (buffer-local-value 'drgnx-view page))
             (redisplay t)
             (should (string-search "Why: you (Extensions)" (buffer-string)))
             (drgnx-ui-extensions--shoot "details"))))
     (remove-hook 'drgnx-extensions-jobs-changed-functions #'drgnx-extensions-list--jobs-changed)
     (dolist (b (buffer-list))
       (when (string-prefix-p "*Extension" (buffer-name b)) (kill-buffer b)))
     (drgnx-extensions-list--reset)
     (drgnx-view--undefine 'extensions)
     (drgnx-view--undefine 'extension-details))))

(ert-deftest drgnx-ui-extensions/list-in-terminal-frame ()
  (drgnx-ui-extensions--with-jobs
   (cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _) t)))
     (unwind-protect
         (progn
           (drgnx-ui-extensions--fixture)
           (let ((buf (drgnx-ui-extensions--show)))
             (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '(forge))
             (with-current-buffer buf
               (drgnx-extensions-list--jobs-changed '(forge))
               (drgnx-view-draw-now drgnx-view)
               (let ((text (buffer-string)))
                 (should (string-search "P magit" text))
                 (should (string-search "M tools/git" text))
                 (should (string-search "@ native 14/37" text))
                 (should-not (string-search "⬡" text))
                 (should-not (string-search "▣" text))))))
       (when (get-buffer drgnx-extensions-list-buffer-name) (kill-buffer drgnx-extensions-list-buffer-name))
       (drgnx-extensions-list--reset)
       (drgnx-view--undefine 'extensions)))))

(load (expand-file-name "modules/tools/drgnx-extensions-trust" drgnx-ui-extensions--repo) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-recommend" drgnx-ui-extensions--repo) nil t)
(require 'drgnx-hub-client)
(require 'drgnx-notices)
(require 'drgnx-exec)
(require 'drgnx-file)
(require 'drgnx-pkg)
(defvar drgnx-extensions-review)

(defun drgnx-ui-extensions--hub-call (method params callback &rest _)
  "The stub of `drgnx-hub-call': the details of a MELPA magit that needs transient, answered at once."
  (pcase method
    ("extensions/details"
     (let ((name (substring (plist-get params :id) 4)))
       (funcall callback (list :row (list :id (plist-get params :id) :kind "package" :name name :summary (concat name " summary")
                                          :state "available" :source "melpa" :signed "unsigned-archive" :version "4.2"
                                          :downloads 1200)
                               :requires (if (equal name "magit") [(:name "transient")] [])
                               :maintainer "Jonas Bernoulli" :commit "abc1234" :url "https://example.invalid/magit"
                               :readme "#+TITLE: magit\nA Git porcelain.\n")
                nil)))
    (_ (funcall callback nil "not stubbed"))))

(defun drgnx-ui-extensions--show-buffer (buf)
  (switch-to-buffer buf)
  (delete-other-windows)
  (when-let* ((v (buffer-local-value 'drgnx-view buf))) (drgnx-view-draw-now v))
  (redisplay t))

(ert-deftest drgnx-ui-extensions/trust-review-and-suggestion-in-gui ()
  "The trust card of a MELPA package, the page of a reviewed update, and an agent's suggestion in the Notices list."
  (let* ((root (file-name-as-directory (make-temp-file "drgnx-ui-ext-trust" t)))
         (process-environment (append (list (concat "XDG_STATE_HOME=" root "state") (concat "DRGNX_DATA_DIR=" root "data")
                                            (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_CACHE_HOME=" root "cache"))
                                      process-environment))
         (drgnx-exec--jobs (make-hash-table :test #'equal))
         (drgnx-extensions-jobs-done-functions nil) (drgnx-extensions-review '(magit)) (starts 0))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-hub-call) #'drgnx-ui-extensions--hub-call)
                  ((symbol-function 'drgnx-exec-start)
                   (lambda (_name _argv &rest keys) (funcall (plist-get keys :callback) (format "job-%d" (cl-incf starts)) nil)))
                  ((symbol-function 'drgnx-extensions-trust--diff)
                   (lambda (_n _e callback)
                     (funcall callback "diff -ruN installed/magit.el update/magit.el\n--- installed/magit.el\n+++ update/magit.el\n@@ -1 +1,2 @@\n ;;; magit.el\n+(defun magit-new () nil)\n" nil))))
          (unless (drgnx-view-type-p 'extension-details) (drgnx-extensions-details--define-view))
          (drgnx-extensions-trust-setup)
          ;; the trust card
          (let ((this-command 'extensions-install))
            (drgnx-extensions-trust-before-install "pkg:magit" #'ignore))
          (let ((card (get-buffer (drgnx-extensions-trust-card-name "magit"))))
            (should card)
            (drgnx-ui-extensions--show-buffer card)
            (should (string-search "[Install]" (with-current-buffer card (buffer-string))))
            (drgnx-ui-extensions--shoot "trust-card"))
          ;; a reviewed update
          (let ((this-command 'extensions-update)) (drgnx-extensions-trust-update "magit"))
          (drgnx-file-write (drgnx-pkg-staged-file) '((magit :version "4.2" :file "magit-4.2.tar" :sha256 "abc123def" :verified nil)))
          (run-hook-with-args 'drgnx-extensions-jobs-done-functions "job-1" '(:status done :kind upgrade))
          (let ((page (drgnx-extensions-details-open "pkg:magit" t)))
            (drgnx-ui-extensions--show-buffer page)
            (should (string-search "abc123def" (with-current-buffer page (buffer-string))))
            (drgnx-ui-extensions--shoot "review"))
          ;; an agent's suggestion, as the hub sends it
          (drgnx-hub--note-extension-card
           (list :id 7 :kind "extension" :state "open" :title "s3 suggests magit (MELPA)"
                 :data (list :id "pkg:magit" :name "magit" :source "melpa"
                             :why (list (list :session "s3" :text "for git: install it now and mark it trusted")))))
          (drgnx-notices-show)
          (drgnx-ui-extensions--show-buffer (get-buffer drgnx-notices-buffer-name))
          (should (string-search "s3 suggests magit (MELPA)" (with-current-buffer drgnx-notices-buffer-name (buffer-string))))
          (drgnx-ui-extensions--shoot "suggestion"))
      (drgnx-notice-clear 'hub)
      (drgnx-extensions-trust-teardown)
      (dolist (b (buffer-list))
        (when (string-prefix-p "*Extension" (buffer-name b)) (kill-buffer b)))
      (when (get-buffer drgnx-notices-buffer-name) (kill-buffer drgnx-notices-buffer-name))
      (drgnx-view--undefine 'extension-details)
      (delete-directory root t))))

(provide 'extensions-gui-test)
;;; extensions-gui-test.el ends here
