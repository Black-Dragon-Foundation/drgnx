;;; hub-file-test.el --- batch tests: the hub's kept files go through the file layer -*- lexical-binding: t -*-
;; hub/registrations.eld, hub/sessions.eld and the port file.  Every directory is under a fresh temp root and the
;; socket is under its state folder (XDG_RUNTIME_DIR unset): nothing here reaches `~' or a real hub.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-hub)
(require 'drgnx-file)

(defmacro drgnx-hub-file-test--with (&rest body)
  "BODY with every drgnx directory under a fresh ROOT, the gateway's registrations empty and the sessions unsaved."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-hub-file" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "DRGNX_DATA_DIR=" root "data")
                                             (concat "XDG_STATE_HOME=" root "state") (concat "HOME=" root "home")
                                             "XDG_RUNTIME_DIR" "DRGNX_NO_HUB_START"
                                             (format "DRGNX_HUB_PARENT_PID=%d" (emacs-pid)))
                                       process-environment))
          (drgnx-gateway--keys (make-hash-table :test #'eq))
          (drgnx-gateway--registrations (make-hash-table :test #'equal))
          (drgnx-hub--saved-sessions nil)
          (drgnx-hub--exit-function #'drgnx-hub-stop)
          (logged nil))
     (unwind-protect
         (cl-letf (((symbol-function 'message)
                    (lambda (fmt &rest args) (when fmt (push (apply #'format-message fmt args) logged)) nil)))
           ,@body)
       (ignore-errors (drgnx-hub-stop))
       (ignore-errors (delete-file (drgnx-hub-socket)))
       (ignore-errors (delete-directory (concat (drgnx-hub-socket) ".lock") t))
       (delete-directory root t))))

(defun drgnx-hub-file-test--bytes (file)
  "FILE's bytes."
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun drgnx-hub-file-test--put (file text)
  "Make FILE hold TEXT, folders made."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil file nil 'silent)))

(defun drgnx-hub-file-test--backups (file)
  "FILE's backups (NAME.bak-…), full paths."
  (and (file-directory-p (file-name-directory file))
       (directory-files (file-name-directory file) t (concat "\\`" (regexp-quote (file-name-nondirectory file)) "\\.bak-"))))

(defun drgnx-hub-file-test--logged (logged what)
  "The messages in LOGGED that mention WHAT."
  (seq-filter (lambda (m) (string-search what m)) logged))

(ert-deftest drgnx-hub-file/registrations-are-written-0600-atomically ()
  (drgnx-hub-file-test--with
    (let ((file (drgnx-hub--registrations-file)))
      (puthash "h1" '(:job "j" :chain ((openrouter . nil)) :budget 1.5) drgnx-gateway--registrations)
      ;; an old file with group and other bits loses them; the data is synced before the rename
      (drgnx-hub-file-test--put file "()")
      (set-file-modes file #o644)
      (let ((synced nil) (write (symbol-function 'write-region)))
        (cl-letf (((symbol-function 'write-region)
                   (lambda (start end target &rest args)
                     (when (string-match-p "registrations\\.eld" target) (push (not write-region-inhibit-fsync) synced))
                     (apply write start end target args))))
          (drgnx-hub--save-registrations))
        (should (equal synced '(t))))
      (should (equal (file-modes file) #o600))
      (should (equal (plist-get (drgnx-file-read file) :data) (drgnx-gateway-registrations)))
      ;; a new file starts private too
      (delete-file file)
      (drgnx-hub--save-registrations)
      (should (equal (file-modes file) #o600))
      ;; atomic: a write that dies at the rename leaves the old bytes whole and no temporary file
      (let ((before (drgnx-hub-file-test--bytes file)))
        (puthash "h2" '(:job "k") drgnx-gateway--registrations)
        (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "disk gone"))))
          (should-error (drgnx-hub--save-registrations)))
        (should (equal (drgnx-hub-file-test--bytes file) before))
        (should (equal (directory-files (file-name-directory file) nil "tmp") nil))))))

(ert-deftest drgnx-hub-file/an-unreadable-registrations-file-is-backed-up-not-ignored ()
  (drgnx-hub-file-test--with
    (let ((file (drgnx-hub--registrations-file)) (torn "((\"abc\" :job \"j\" :chain"))
      (drgnx-hub-file-test--put file torn)
      (drgnx-hub--load-registrations)
      (should (= (hash-table-count drgnx-gateway--registrations) 0))
      (let ((backups (drgnx-hub-file-test--backups file)))
        (should (= (length backups) 1))
        (should (equal (drgnx-hub-file-test--bytes (car backups)) torn)))
      (should (= (length (drgnx-hub-file-test--logged logged "registrations.eld")) 1))
      ;; the next save replaces the file; the backup keeps the user's bytes
      (puthash "h1" '(:job "j") drgnx-gateway--registrations)
      (drgnx-hub--save-registrations)
      (should (equal (drgnx-hub-file-test--bytes (car (drgnx-hub-file-test--backups file))) torn))
      ;; a good file is read, not backed up; a missing one is no problem
      (clrhash drgnx-gateway--registrations)
      (setq logged nil)
      (drgnx-hub--load-registrations)
      (should (gethash "h1" drgnx-gateway--registrations))
      (delete-file file)
      (clrhash drgnx-gateway--registrations)
      (drgnx-hub--load-registrations)
      (should (= (length (drgnx-hub-file-test--backups file)) 1))
      (should-not logged))))

(ert-deftest drgnx-hub-file/an-unreadable-sessions-file-likewise ()
  (drgnx-hub-file-test--with
    (let ((file (drgnx-hub--sessions-file)))
      (dolist (text '("((:id \"s1\" :profile" "(1 . 2)"))
        (dolist (old (drgnx-hub-file-test--backups file)) (delete-file old))
        (setq logged nil)
        (drgnx-hub-file-test--put file text)
        (drgnx-hub--resume-sessions)
        (should (null drgnx-hub--saved-sessions))
        (let ((backups (drgnx-hub-file-test--backups file)))
          (should (= (length backups) 1))
          (should (equal (drgnx-hub-file-test--bytes (car backups)) text)))
        (should (= (length (drgnx-hub-file-test--logged logged "sessions.eld")) 1)))
      ;; a good list is not backed up
      (dolist (old (drgnx-hub-file-test--backups file)) (delete-file old))
      (drgnx-hub-file-test--put file "()")
      (drgnx-hub--resume-sessions)
      (should-not (drgnx-hub-file-test--backups file)))))

(ert-deftest drgnx-hub-file/sessions-are-written-0600-through-the-file-layer ()
  (drgnx-hub-file-test--with
    (let ((file (drgnx-hub--sessions-file)))
      (cl-letf (((symbol-function 'drgnx-hub--resumable) (lambda () '((:id "s1" :name "n" :profile "p")))))
        (drgnx-hub--save-sessions))
      (should (equal (file-modes file) #o600))
      (should (equal (plist-get (drgnx-file-read file) :data) '((:id "s1" :name "n" :profile "p")))))))

(ert-deftest drgnx-hub-file/the-port-file-is-written-atomically-and-read-back-by-the-next-hub ()
  (drgnx-hub-file-test--with
    (let ((file (drgnx-hub--port-file)) (direct nil) (write (symbol-function 'write-region)))
      (cl-letf (((symbol-function 'write-region)
                 (lambda (start end target &rest args)
                   (when (equal (expand-file-name target) file) (push target direct))
                   (apply write start end target args))))
        (drgnx-hub-serve (drgnx-hub-socket)))
      (should-not direct)
      (should (equal (drgnx-hub-file-test--bytes file) (number-to-string (drgnx-gateway-port))))
      (should-not (directory-files (file-name-directory file) nil "tmp"))
      (let ((port (drgnx-gateway-port)))
        (drgnx-hub-stop)
        (drgnx-hub-serve (drgnx-hub-socket))
        (should (= (drgnx-gateway-port) port))))))
