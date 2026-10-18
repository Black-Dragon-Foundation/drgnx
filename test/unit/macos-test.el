;;; macos-test.el --- batch tests: the drgnx app on macOS (applet, Info.plist, install) -*- lexical-binding: t -*-
;; Fake osacompile, plutil, codesign and lsregister log their argv in a temp dir; the app goes into a temp
;; directory — never /Applications or ~/Applications.  `drgnx-platform' is stubbed.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-macos)

(ert-deftest drgnx-macos/the-applet-quotes-every-path ()
  ;; Finder sends files as an Apple Event: `on open' gets them, each through `quoted form of POSIX path of';
  ;; drgnx's own path (a space, a quote) is an AppleScript string, quoted for the shell at run time.
  (let* ((bin "/Users/a b/O'Neil/.local/bin/drgnx")
         (src (drgnx-macos-applet-source bin))
         (lines (split-string src "\n" t "[ \t]+")))
    (should (string-match-p "^on run$" src))
    (should (string-match-p "^on open theItems$" src))
    (should (string-search "quoted form of POSIX path of (item i of theItems)" src))
    (should (string-search "quoted form of \"/Users/a b/O'Neil/.local/bin/drgnx\"" src))
    ;; every shell command runs drgnx through `quoted form of', never a path spliced in as it is
    (dolist (l (seq-filter (lambda (l) (string-prefix-p "do shell script" l)) lines))
      (should (string-search "& quoted form of \"/Users/a b/O'Neil/.local/bin/drgnx\" & \" open" l))
      (should (string-search "export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH; " l))
      (should (string-suffix-p ">/dev/null 2>&1 &\"" l)))
    (should (= 2 (seq-count (lambda (l) (string-prefix-p "do shell script" l)) lines)))
    (should-not (string-search "'/Users" src))
    ;; an AppleScript string: a backslash and a double quote in the path are escaped
    (should (string-search "quoted form of \"/tmp/a\\\\b\\\"c/drgnx\""
                           (drgnx-macos-applet-source "/tmp/a\\b\"c/drgnx")))))

(ert-deftest drgnx-macos/document-types-are-folders-and-text-code-only ()
  (let* ((types (append (drgnx-macos-document-types) nil))
         (utis (apply #'append (mapcar (lambda (ty) (append (plist-get ty :LSItemContentTypes) nil)) types))))
    (dolist (u '("public.folder" "public.text" "public.source-code" "public.script"))
      (should (member u utis)))
    ;; M12a-35: public.data would offer drgnx for nearly every file (images, PDFs...); Other... still reaches any file
    (should-not (member "public.data" utis))
    (should (= 4 (length utis)))
    (dolist (ty types)
      (should (equal (plist-get ty :CFBundleTypeRole) "Editor"))
      (should (equal (plist-get ty :LSHandlerRank) "Alternate"))
      (should (stringp (plist-get ty :CFBundleTypeName))))
    ;; plutil -json gets it as JSON
    (should (string-prefix-p "[{\"CFBundleTypeName\":" (json-serialize (drgnx-macos-document-types))))))

(defmacro drgnx-macos-test--with-fakes (&rest body)
  "BODY with DIR a temp dir, BIN fake tools (first on `exec-path'), LOG their argv, the platform macOS."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "drgnx-macos" t)))
          (bin (concat dir "bin/"))
          (log (concat dir "tools.log"))
          (exec-path (cons bin exec-path))
          (drgnx-macos-lsregister (concat bin "lsregister")))
     (ignore log)
     (make-directory bin)
     (dolist (tool '("osacompile" "plutil" "codesign" "lsregister"))
       (write-region (concat "#!/bin/sh\nprintf '%s\\n' \"" tool " $*\" >> '" log "'\n"
                             ;; osacompile -o APP …: a bundle as osacompile makes one
                             (if (equal tool "osacompile")
                                 "mkdir -p \"$2/Contents/Resources\" && echo plist > \"$2/Contents/Info.plist\" && echo icon > \"$2/Contents/Resources/applet.icns\"\n"
                               ""))
                     nil (concat bin tool) nil 'silent)
       (set-file-modes (concat bin tool) #o755))
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'macos)))
           ,@body)
       (delete-directory dir t))))

(defun drgnx-macos-test--log (log)
  (if (file-exists-p log) (with-temp-buffer (insert-file-contents log) (split-string (buffer-string) "\n" t)) nil))

(ert-deftest drgnx-macos/install-app-runs-the-tools-in-order ()
  (drgnx-macos-test--with-fakes
    (let* ((apps (concat dir "Applications/"))
           (icon (concat dir "Emacs.icns")))
      (write-region "emacs icon" nil icon nil 'silent)
      ;; an older drgnx.app is replaced; another app is never touched
      (make-directory (concat apps "drgnx.app/Contents") t)
      (write-region "old" nil (concat apps "drgnx.app/Contents/old") nil 'silent)
      (make-directory (concat apps "Other.app") t)
      (let ((app (cl-letf (((symbol-function 'drgnx-macos--icon) (lambda () icon)))
                   (drgnx-macos-install-app apps)))
            (calls (drgnx-macos-test--log log)))
        (should (equal app (concat apps "drgnx.app")))
        (should (file-directory-p app))
        (should-not (file-exists-p (concat app "/Contents/old")))
        (should (file-directory-p (concat apps "Other.app")))
        (should (equal (directory-files apps nil directory-files-no-dot-files-regexp) '("Other.app" "drgnx.app")))
        (should (equal (with-temp-buffer (insert-file-contents (concat app "/Contents/Resources/applet.icns")) (buffer-string))
                       "emacs icon"))
        ;; osacompile, the Info.plist edits, the signature, then Launch Services — in that order
        (should (equal (mapcar (lambda (c) (car (split-string c " "))) calls)
                       '("osacompile" "plutil" "plutil" "plutil" "plutil" "codesign" "lsregister")))
        (should (string-match-p "^osacompile -o .*/drgnx\\.app -e on run " (nth 0 calls)))
        (should (string-search (concat "quoted form of \"" (expand-file-name "bin/drgnx" drgnx-dir) "\"") (nth 0 calls)))
        (should (string-search "-replace CFBundleIdentifier -string org.drgnx.app " (nth 1 calls)))
        (should (string-search "-replace CFBundleName -string drgnx " (nth 2 calls)))
        (should (string-search "-replace CFBundleDisplayName -string drgnx " (nth 3 calls)))
        (should (string-search "-replace CFBundleDocumentTypes -json [{" (nth 4 calls)))
        (should (string-search "public.folder" (nth 4 calls)))
        (should (string-match-p "/Contents/Info\\.plist$" (nth 4 calls)))
        (should (string-match-p "^codesign --force --sign - .*/drgnx\\.app$" (nth 5 calls)))
        (should (equal (nth 6 calls) (concat "lsregister -f " app)))))))

(ert-deftest drgnx-macos/install-app-without-lsregister-still-installs ()
  (drgnx-macos-test--with-fakes
    (let ((drgnx-macos-lsregister (concat dir "no-such-lsregister")))
      (cl-letf (((symbol-function 'drgnx-macos--icon) #'ignore))
        (should (file-directory-p (drgnx-macos-install-app (concat dir "Apps")))))
      (should-not (seq-find (lambda (c) (string-prefix-p "lsregister" c)) (drgnx-macos-test--log log))))))

(ert-deftest drgnx-macos/a-failing-tool-leaves-the-old-app ()
  (drgnx-macos-test--with-fakes
    (let ((apps (concat dir "Applications/")))
      (make-directory (concat apps "drgnx.app") t)
      (write-region "#!/bin/sh\necho 'plutil: bad' >&2\nexit 1\n" nil (concat bin "plutil") nil 'silent)
      (should-error (drgnx-macos-install-app apps))
      (should (file-directory-p (concat apps "drgnx.app")))
      (should (equal (directory-files apps nil directory-files-no-dot-files-regexp) '("drgnx.app"))))))   ; no temp left

(ert-deftest drgnx-macos/install-app-is-for-macos-with-osacompile ()
  (drgnx-macos-test--with-fakes
    (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux)))
      (should-error (drgnx-macos-install-app (concat dir "Apps")) :type 'user-error))
    (let ((exec-path (remove bin exec-path)))
      (unless (executable-find "osacompile")
        (should-error (drgnx-macos-install-app (concat dir "Apps")) :type 'user-error)))
    (should-not (file-exists-p (concat dir "Apps")))))

(ert-deftest drgnx-macos/the-cli-prints-the-path ()
  (drgnx-macos-test--with-fakes
    (let ((drgnx-macos-app-dir (concat dir "Apps/")) out code)
      (cl-letf (((symbol-function 'drgnx-macos--icon) #'ignore)
                ((symbol-function 'kill-emacs) (lambda (c) (setq code c))))
        (setq out (with-output-to-string (drgnx-macos-cli))))
      (should (eql code 0))
      (should (equal out (concat dir "Apps/drgnx.app\n")))
      (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux))
                ((symbol-function 'kill-emacs) (lambda (c) (setq code c)))
                ((symbol-function 'message) #'ignore))
        (drgnx-macos-cli))
      (should (eql code 1)))))

;;; macos-test.el ends here
