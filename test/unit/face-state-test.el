;;; face-state-test.el --- batch tests: face.eld — what the face remembers -*- lexical-binding: t -*-
;; Everything runs in a temp state directory: never the user's ~/.local/state, desktop file or systemd unit.
(require 'ert)
(require 'drgnx-paths)
(require 'drgnx-face-state)
(require 'drgnx-pkg)
(require 'drgnx-file)
(require 'drgnx-doctor)
(require 'drgnx-config-doc)

(defmacro drgnx-face-state-test--with (tmp &rest body)
  "BODY with TMP a temp directory that is the whole state directory."
  (declare (indent 1))
  `(let* ((,tmp (file-name-as-directory (make-temp-file "drgnx-face-state" t)))
          (process-environment (cons (concat "XDG_STATE_HOME=" ,tmp) process-environment)))
     (unwind-protect (progn ,@body)
       (delete-directory ,tmp t))))

(ert-deftest drgnx-face-state/round-trip-and-gtk-theme ()
  (drgnx-face-state-test--with tmp
    (should-not (drgnx-face-state-read))
    (should-not (drgnx-face-state-gtk-theme))
    (drgnx-face-state-write '(:variant dark :gtk-theme "Adwaita"))
    (should (equal (drgnx-face-state-read) '(:variant dark :gtk-theme "Adwaita")))
    (should (equal (drgnx-face-state-gtk-theme) "Adwaita:dark"))
    (drgnx-face-state-write '(:variant light :gtk-theme "Adwaita"))
    (should (equal (drgnx-face-state-gtk-theme) "Adwaita:light"))
    ;; `system': the module writes no variant, so nothing is forced on GTK
    (drgnx-face-state-write '(:variant nil :gtk-theme "Adwaita"))
    (should-not (drgnx-face-state-gtk-theme))
    (drgnx-face-state-write '(:gtk-theme "Adwaita"))
    (should-not (drgnx-face-state-gtk-theme))
    ;; no theme name, or one that is not a plain name (it ends up in a unit file and in the launcher's environment)
    (drgnx-face-state-write '(:variant dark :gtk-theme ""))
    (should-not (drgnx-face-state-gtk-theme))
    (drgnx-face-state-write '(:variant dark :gtk-theme "Bad Name\nExecStart=x"))
    (should-not (drgnx-face-state-gtk-theme))
    ;; unreadable: nil, no error
    (with-temp-file (drgnx-face-state-file) (insert "(:variant dark :gtk-theme"))
    (should-not (drgnx-face-state-read))
    (should-not (drgnx-face-state-gtk-theme))
    (with-temp-file (drgnx-face-state-file) (insert "(:variant dark :gtk-theme 7)"))
    (should-not (drgnx-face-state-gtk-theme))))

(ert-deftest drgnx-face-state/service-unit-carries-gtk-theme ()
  (drgnx-face-state-test--with tmp
    (should-not (string-match-p "GTK_THEME" (drgnx-pkg-service-unit)))
    (drgnx-face-state-write '(:variant dark :gtk-theme "Adwaita"))
    (let ((unit (drgnx-pkg-service-unit)))
      (should (string-match-p "^\\[Service\\]\n\\(.*\n\\)*Environment=GTK_THEME=Adwaita:dark\n" unit))
      (should (string-match-p "\\[Install\\]" (substring unit (string-match "Environment=GTK_THEME" unit)))))
    ;; written to the directory asked for, never installed
    (drgnx-pkg-service-unit (concat tmp "units"))
    (should (string-search "Environment=GTK_THEME=Adwaita:dark"
                           (with-temp-buffer (insert-file-contents (concat tmp "units/drgnx.service")) (buffer-string))))
    (drgnx-face-state-write '(:variant nil :gtk-theme "Adwaita"))
    (should-not (string-match-p "GTK_THEME" (drgnx-pkg-service-unit)))))

(defvar drgnx-face-state-test--evil nil)

(ert-deftest drgnx-face-state/reading-never-evaluates ()
  (drgnx-face-state-test--with tmp
    (make-directory (file-name-directory (drgnx-face-state-file)) t)
    (with-temp-file (drgnx-face-state-file)
      (insert "(:variant dark :gtk-theme #.(setq drgnx-face-state-test--evil t))"))
    (should-not (drgnx-face-state-read))
    (should-not drgnx-face-state-test--evil)))

;; File layer (config Task 26): face.eld keeps its bytes, its unknown keys and its one-line form for bin/drgnx.

(defun drgnx-face-state-test--text ()
  (with-temp-buffer (insert-file-contents (drgnx-face-state-file)) (buffer-string)))

(defun drgnx-face-state-test--baks ()
  (directory-files (file-name-directory (drgnx-face-state-file)) t "\\`face\\.eld\\.bak-"))

(defun drgnx-face-state-test--sed (key text-re)
  "What bin/drgnx's open_gtk_theme extracts for KEY (the sed expressions of the launcher, verbatim)."
  (string-trim
   (with-output-to-string
     (call-process "sed" nil standard-output nil "-n" "-E"
                   (format "s/.*:%s[[:space:]]+%s.*/\\1/p" key text-re) (drgnx-face-state-file)))))

(ert-deftest drgnx-face-state/the-file-stays-one-line-for-the-launcher ()
  (drgnx-face-state-test--with tmp
    (drgnx-face-state-put '(:variant dark :gtk-theme "Adwaita"))
    (drgnx-face-state-put '(:start-dismissed t))
    (drgnx-face-state-write '(:variant light :gtk-theme "Adwaita" :start-dismissed t :other (1 2 3)))
    (let* ((text (drgnx-face-state-test--text))
           (data-lines (seq-remove (lambda (l) (or (string-empty-p l) (string-prefix-p ";" l)))
                                   (split-string text "\n"))))
      (should (= (length data-lines) 1))                 ; prin1, never pp: one line
      (should (string-suffix-p "\n" text))
      ;; the launcher's own sed expressions find the variant and the theme in it
      (should (equal (drgnx-face-state-test--sed "variant" "(dark|light)[[:space:])]") "light"))
      (should (equal (drgnx-face-state-test--sed "gtk-theme" "\"([A-Za-z0-9._+-]+)\"") "Adwaita"))
      (should (equal (drgnx-face-state-read)
                     '(:variant light :gtk-theme "Adwaita" :start-dismissed t :other (1 2 3)))))))

(ert-deftest drgnx-face-state/an-unreadable-face-state-is-backed-up ()
  (drgnx-face-state-test--with tmp
    (make-directory (file-name-directory (drgnx-face-state-file)) t)
    (let ((bad "(:variant dark :gtk-theme \"Adw"))
      (with-temp-file (drgnx-face-state-file) (insert bad))
      (should-not (drgnx-face-state-read))
      (should-not (drgnx-face-state-test--baks))   ; reading copies nothing aside
      (drgnx-face-state-put '(:start-dismissed t))
      (let ((baks (drgnx-face-state-test--baks)))
        (should (= (length baks) 1))
        (should (equal (with-temp-buffer (insert-file-contents (car baks)) (buffer-string)) bad)))   ; the user's bytes
      (should (equal (drgnx-face-state-read) '(:start-dismissed t))))
    ;; a form that reads but is not a plist is the user's too: copied aside before the file is replaced
    (let ((odd "(just some words)\n"))
      (with-temp-file (drgnx-face-state-file) (insert odd))
      (should-not (drgnx-face-state-read))
      (drgnx-face-state-put '(:variant dark))
      (should (cl-some (lambda (b) (equal (with-temp-buffer (insert-file-contents b) (buffer-string)) odd))
                       (drgnx-face-state-test--baks)))
      (should (equal (drgnx-face-state-read) '(:variant dark))))))

(ert-deftest drgnx-face-state/put-keeps-the-other-keys-and-an-older-file-keeps-working ()
  (drgnx-face-state-test--with tmp
    (make-directory (file-name-directory (drgnx-face-state-file)) t)
    ;; the file as M12f-a wrote it: one line, no header, no version, and a key this drgnx does not know
    (with-temp-file (drgnx-face-state-file)
      (insert "(:variant dark :gtk-theme \"Adwaita\" :start-dismissed t :future-key (a b))"))
    (should (equal (drgnx-face-state-gtk-theme) "Adwaita:dark"))
    (should-not (drgnx-config-problem 'face))
    (should-not (plist-get (drgnx-config-read 'face) :problem))
    (drgnx-face-state-put '(:variant light))
    (should (equal (drgnx-face-state-read)
                   '(:variant light :gtk-theme "Adwaita" :start-dismissed t :future-key (a b))))
    ;; nothing changed, nothing written
    (let ((stamp (drgnx-file-stamp (drgnx-face-state-file))))
      (drgnx-face-state-put '(:variant light))
      (should (equal stamp (drgnx-file-stamp (drgnx-face-state-file)))))))

(ert-deftest drgnx-face-state/a-held-lock-skips-an-automatic-write-and-nothing-is-lost ()
  (drgnx-face-state-test--with tmp
    (drgnx-face-state-write '(:variant dark :gtk-theme "Adwaita"))
    (let ((busy nil))
      (drgnx-file-update (drgnx-face-state-file)
                         (lambda (d)
                           (setq busy (condition-case nil (drgnx-face-state-put '(:variant light) 0)
                                        (drgnx-file-busy 'busy)))
                           d))
      (should (eq busy 'busy)))
    (should (equal (drgnx-face-state-read) '(:variant dark :gtk-theme "Adwaita")))))

(ert-deftest drgnx-face-state/the-doctor-and-the-reference-know-face ()
  (should (drgnx-config-defined-p 'face))
  (should (memq 'drgnx-face-state drgnx-doctor-config-features))
  (should (member '(require drgnx-face-state) drgnx-config-doc-sources)))

;;; face-state-test.el ends here
