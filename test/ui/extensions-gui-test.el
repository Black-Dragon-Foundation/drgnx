;;; extensions-gui-test.el --- GUI rows: the Extensions list and a details page on screen, and the terminal glyphs -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The list is drawn from a fixture (rows as the hub sends them, job states as the job layer gives them), shown in the
;; selected window and captured, then a details page of one row.  The evidence folder (DRGNX_UI_EVIDENCE) keeps the
;; PNGs; run once per display scale (DRGNX_UI_SCALE).  The terminal row draws the same list as a terminal that does not
;; write UTF-8 would see it: the ASCII forms of the kind marks and the busy dot.  No hub is started.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ui-extensions--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-extensions--repo)))
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-extensions-list" drgnx-ui-extensions--repo) nil t)
(load (expand-file-name "modules/tools/drgnx-extensions-details" drgnx-ui-extensions--repo) nil t)

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
  `(cl-letf (((symbol-function 'drgnx-extensions-jobs-state)
              (lambda (id)
                (pcase id
                  ("pkg:forge" (list :status 'busy :step 'native :i 14 :n 37 :since (- (float-time) 12)))
                  ("pkg:vterm" (list :status 'failed :error "download failed; nothing was changed"))
                  ("pkg:dash" (list :status 'done :warnings '("a.el" "b.el")))))))
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
           (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '("pkg:forge" "pkg:vterm" "pkg:dash"))
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
             (run-hook-with-args 'drgnx-extensions-jobs-changed-functions '("pkg:forge"))
             (with-current-buffer buf
               (drgnx-extensions-list--jobs-changed '("pkg:forge"))
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

(provide 'extensions-gui-test)
;;; extensions-gui-test.el ends here
