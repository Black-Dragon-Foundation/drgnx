;;; extensions-plugins-shots-test.el --- plugins in the Extensions list and a changed plugin's page on screen -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The list and a changed plugin's page are drawn from fixture state (no hub) in the selected window and captured under
;; a dark and a light theme.  The evidence folder (DRGNX_UI_EVIDENCE) keeps the PNGs.
(require 'ert)
(defvar drgnx-view-old-path)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ext-plugins-shots--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ext-plugins-shots--repo)))
(require 'drgnx)
(require 'drgnx-agents-matrix)
(dolist (f '("drgnx-plugins-ui" "drgnx-extensions-list" "drgnx-extensions-details" "drgnx-extensions-plugins"))
  (load (expand-file-name (concat "modules/tools/" f) drgnx-ext-plugins-shots--repo) nil t))

(defconst drgnx-ext-plugins-shots--hash (make-string 64 ?9))

(defun drgnx-ext-plugins-shots--plugin (name state &rest more)
  "A `plugins/list' row."
  (append more (list :name name :version "0.2" :hash drgnx-ext-plugins-shots--hash :state state
                     :abilities '("rewrite") :hosts '("api.example.com:443")
                     :hooks '((:point "before-commit" :verdicts ("allow" "deny" "change"))
                              (:point "after-edit" :verdicts ("annotate"))))))

(defun drgnx-ext-plugins-shots--rows ()
  (list (drgnx-ext-plugins-shots--plugin
         "rewrite-msg" "changed"
         :approved_reach '(:abilities ("rewrite") :hosts ("docs.example.com:443")
                                      :hooks ((:point "before-commit" :verdicts ("allow" "deny")))))
        (drgnx-ext-plugins-shots--plugin "deny-rm" "approved")
        (drgnx-ext-plugins-shots--plugin "notify" "unapproved")
        (drgnx-ext-plugins-shots--plugin "old-tool" "disabled")))

(defun drgnx-ext-plugins-shots--list-row (p on)
  (let ((state (pcase (plist-get p :state)
                 ("approved" (if (member (plist-get p :name) on) "on" "off"))
                 (s s))))
    (list :id (concat "plugin:" (plist-get p :name)) :kind "plugin" :name (plist-get p :name) :version "0.2"
          :summary "Plugin: 1 ability, 2 hooks, 1 host" :state state :source "plugin"
          :signed (if (equal state "off") "hash-approved" (if (equal state "on") "hash-approved" "none")))))

(defun drgnx-ext-plugins-shots--shoot (name)
  (let* ((dir (make-temp-file "ext-plugins-shots" t))
         (shot (plist-get (drgnx-uitest-capture dir) :root))
         (out (expand-file-name (format "%s.png" name) temporary-file-directory)))
    (should (file-exists-p shot))
    (copy-file shot out t)
    (drgnx-uitest--evidence out)
    (message "extensions plugins screenshot: %s" out)))

(defun drgnx-ext-plugins-shots--views (theme)
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme theme t)
  (let* ((tag (if (eq theme 'modus-vivendi) "dark" "light"))
         (plugins (drgnx-ext-plugins-shots--rows))
         (drgnx-plugins--rows plugins)
         (default-value-on '("deny-rm")))
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) nil))
              ;; the page is shown as it is with the Extensions module on
              ((symbol-function 'drgnx-module-running-p) (lambda (m) (eq m 'tools/extensions)))
              ((default-value 'drgnx-agents-plugins) default-value-on))
      (unwind-protect
          (progn
            (add-hook 'drgnx-plugins-page-sections #'drgnx-extensions-plugins--diff-section)
            (drgnx-extensions-list--reset)
            (drgnx-extensions-list--receive
             'plugins (mapcar (lambda (p) (drgnx-ext-plugins-shots--list-row p default-value-on)) plugins) 4 0)
            (let* ((drgnx-view-old-path t) (buf (drgnx-extensions-list--buffer)))
              (switch-to-buffer buf)
              (delete-other-windows)
              (drgnx-view-draw-now drgnx-view)
              (redisplay t)
              (with-current-buffer buf
                (should (string-search "changed: approve it again" (buffer-string)))
                (should (string-search "not approved" (buffer-string))))
              (drgnx-ext-plugins-shots--shoot (format "plugins-list-%s" tag)))
            (let ((page (drgnx-extensions-details-open "plugin:rewrite-msg")))
              (switch-to-buffer page)
              (delete-other-windows)
              (drgnx-view-draw-now (buffer-local-value 'drgnx-view page))
              (redisplay t)
              (should (string-search "New host api.example.com:443" (with-current-buffer page (buffer-string))))
              (drgnx-ext-plugins-shots--shoot (format "plugin-changed-page-%s" tag)))
            (let ((page (drgnx-extensions-details-open "plugin:deny-rm")))
              (switch-to-buffer page)
              (drgnx-view-draw-now (buffer-local-value 'drgnx-view page))
              (redisplay t)
              (should (string-search "[Turn off]" (with-current-buffer page (buffer-string))))
              (drgnx-ext-plugins-shots--shoot (format "plugin-on-page-%s" tag))))
        (remove-hook 'drgnx-plugins-page-sections #'drgnx-extensions-plugins--diff-section)
        (dolist (b (buffer-list))
          (when (string-prefix-p "*Extension" (buffer-name b)) (kill-buffer b)))
        (when (get-buffer drgnx-extensions-list-buffer-name) (kill-buffer drgnx-extensions-list-buffer-name))
        (drgnx-extensions-list--reset)
        (drgnx-view--undefine 'extensions)
        (drgnx-view--undefine 'extension-details)
        (disable-theme theme)))))

(ert-deftest drgnx-ui-extensions-plugins/dark-and-light ()
  (drgnx-ext-plugins-shots--views 'modus-vivendi)
  (drgnx-ext-plugins-shots--views 'modus-operandi))

(provide 'extensions-plugins-shots-test)
;;; extensions-plugins-shots-test.el ends here
