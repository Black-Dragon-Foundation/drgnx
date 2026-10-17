;;; drgnx-macos.el --- The drgnx app on macOS: Finder, Spotlight, the Dock, Open With -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; drgnx.app (in ~/Applications) is a small AppleScript applet that runs `drgnx open' with what it was given:
;; nothing (opened from Finder, Spotlight or the Dock) or the files and folders dropped on it or opened with it
;; (Finder sends those as an Apple Event — `on open' — not as arguments, which is why it is an applet and not a
;; shell script in a bundle).  Its Info.plist names it drgnx (org.drgnx.app), lists folders and text and source
;; files as documents it can edit (so it shows in Open With) and carries Emacs's icon.  `drgnx macos-app' and
;; onboarding's Daemon and Desktop step install it.  See docs/guide/opening.md.

;;; Code:
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(defvar drgnx-macos-app-dir "~/Applications/" "Where `drgnx-macos-install-app' puts drgnx.app.")

(defvar drgnx-macos-lsregister
  "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  "Launch Services' tool: `lsregister -f APP' makes Finder, Spotlight and Open With see APP now.")

(defconst drgnx-macos--shell-path "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; "
  "`do shell script' runs with PATH /usr/bin:/bin:/usr/sbin:/sbin: Homebrew's git and rg come first for the
drgnx it starts.")

(defun drgnx-macos--string (s)
  "S as an AppleScript string literal."
  (concat "\"" (replace-regexp-in-string "[\\\"]" "\\\\\\&" s) "\""))

(defun drgnx-macos-applet-source (drgnx-bin)
  "The AppleScript of drgnx.app: `DRGNX-BIN open', with each item Finder opens with it as a path.
Every path reaches the shell through `quoted form of' — spaces, accents and quotes stay one argument."
  (let ((run (concat "do shell script " (drgnx-macos--string drgnx-macos--shell-path)
                     " & quoted form of " (drgnx-macos--string drgnx-bin) " & \" open")))
    (concat "on run\n"
            "\t" run " >/dev/null 2>&1 &\"\n"
            "end run\n"
            "\n"
            "on open theItems\n"
            "\tset args to \"\"\n"
            "\trepeat with i from 1 to count of theItems\n"
            "\t\tset args to args & \" \" & quoted form of POSIX path of (item i of theItems)\n"
            "\tend repeat\n"
            "\t" run " --\" & args & \" >/dev/null 2>&1 &\"\n"
            "end open\n")))

(defun drgnx-macos-document-types ()
  "The CFBundleDocumentTypes of drgnx.app (a vector of plists, for `json-serialize'): folders, and text and
source files, as an editor that is not the default (Alternate) — drgnx is offered, never imposed."
  (vector (list :CFBundleTypeName "Folder" :CFBundleTypeRole "Editor" :LSHandlerRank "Alternate"
                :LSItemContentTypes ["public.folder"])
          (list :CFBundleTypeName "Text and source code" :CFBundleTypeRole "Editor" :LSHandlerRank "Alternate"
                :LSItemContentTypes ["public.text" "public.source-code" "public.script" "public.data"])))

(defun drgnx-macos--icon ()
  "Emacs's icon: of the Emacs.app this Emacs runs from, else of /Applications/Emacs.app; nil if neither has one."
  (seq-find #'file-readable-p
            (list (expand-file-name "../Resources/Emacs.icns" invocation-directory)
                  "/Applications/Emacs.app/Contents/Resources/Emacs.icns")))

(defun drgnx-macos--run (program &rest args)
  "Run PROGRAM with ARGS; an error with its output when it fails."
  (with-temp-buffer
    (let ((status (apply #'call-process program nil t nil args)))
      (unless (eql status 0)
        (error "%s failed (%s): %s" (file-name-nondirectory program) status (string-trim (buffer-string)))))))

(defun drgnx-macos-install-app (&optional dir)
  "Build drgnx.app in DIR (default `drgnx-macos-app-dir', ~/Applications/), replacing the drgnx.app there (no
other app is touched), and register it with Launch Services; return its path.  It is built aside first, so a
failure leaves the old one.  A `user-error' when this is not macOS or osacompile is missing."
  (unless (eq (drgnx-platform) 'macos)
    (user-error "The drgnx app is for macOS; this is %s" (drgnx-platform)))
  (unless (executable-find "osacompile")
    (user-error "osacompile is missing (macOS has it in /usr/bin): the drgnx app cannot be built"))
  (let* ((dir (file-name-as-directory (expand-file-name (or dir drgnx-macos-app-dir))))
         (app (expand-file-name "drgnx.app" dir))
         (tmp (progn (make-directory dir t) (make-temp-file (expand-file-name ".drgnx-app-" dir) t)))
         (new (expand-file-name "drgnx.app" tmp))
         (plist (expand-file-name "Contents/Info.plist" new))
         (resources (expand-file-name "Contents/Resources/" new)))
    (unwind-protect
        (progn
          (apply #'drgnx-macos--run "osacompile" "-o" new
                 (mapcan (lambda (line) (list "-e" line))
                         (split-string (drgnx-macos-applet-source (expand-file-name "bin/drgnx" drgnx-dir)) "\n" t)))
          (pcase-dolist (`(,key ,type ,value)
                         `(("CFBundleIdentifier" "-string" "org.drgnx.app")
                           ("CFBundleName" "-string" "drgnx")
                           ("CFBundleDisplayName" "-string" "drgnx")
                           ("CFBundleDocumentTypes" "-json" ,(json-serialize (drgnx-macos-document-types)))))
            (drgnx-macos--run "plutil" "-replace" key type value plist))
          (when-let* ((icon (drgnx-macos--icon)))
            (copy-file icon (expand-file-name "applet.icns" resources) t)
            (when (file-exists-p (expand-file-name "Assets.car" resources))   ; its icon would win over applet.icns
              (delete-file (expand-file-name "Assets.car" resources))
              (call-process "plutil" nil nil nil "-remove" "CFBundleIconName" plist)))
          ;; the edits break osacompile's ad-hoc signature; Apple silicon runs no app whose signature is broken
          (when (executable-find "codesign") (drgnx-macos--run "codesign" "--force" "--sign" "-" new))
          (when (file-exists-p app) (delete-directory app t))
          (rename-file new app))
      (delete-directory tmp t))
    (if (file-executable-p drgnx-macos-lsregister)
        (drgnx-macos--run drgnx-macos-lsregister "-f" app)
      (message "drgnx: %s is missing: Finder and Spotlight find drgnx.app once they notice it" drgnx-macos-lsregister))
    app))

(defun drgnx-macos-cli ()
  "bin/drgnx macos-app: install the drgnx app, print its path (exit 0), or say why not (exit 1)."
  (kill-emacs (condition-case err
                  (progn (princ (concat (drgnx-macos-install-app) "\n")) 0)
                (error (message "drgnx macos-app: %s" (error-message-string err)) 1))))

(provide 'drgnx-macos)
;;; drgnx-macos.el ends here
